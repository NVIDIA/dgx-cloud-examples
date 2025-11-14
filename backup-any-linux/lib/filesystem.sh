#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################
# filesystem.sh - Filesystem Scanning and Directory Discovery Module
################################################################################
# Purpose: Scans filesystem to discover directories requiring backup based on
#          trigger files (backupthisdir.txt or backupalldirs.txt). Handles
#          hierarchical directory relationships and builds filesystem maps.
#
# Dependencies: core.sh, utils.sh, state.sh
#
# Backup Modes:
#   - shallow: Backup files in THIS directory only (backupthisdir.txt)
#   - deep:    Backup THIS directory and all subdirectories (backupalldirs.txt)
#
# Public API:
#   Directory Discovery:
#   - find_backup_directories()           : Find all dirs with trigger files
#   - filter_hierarchical_directories()   : Remove child dirs if parent is deep
#
#   Filesystem Mapping:
#   - build_filesystem_map()              : Build directory map with caching
#   - should_refresh_filesystem_cache()   : Check if cache needs refresh
#
#   Path Utilities:
#   - get_relative_path()                 : Get path relative to mount
#   - get_s3_path_component()             : Generate S3 path from directory
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly FILESYSTEM_MODULE_VERSION="1.0.0"
readonly FILESYSTEM_MODULE_NAME="filesystem"
readonly FILESYSTEM_MODULE_DEPS=("core" "utils" "state")
readonly FILESYSTEM_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${FILESYSTEM_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: filesystem.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION
################################################################################

# Mount directory (where to scan for backups)
MOUNT_DIR="${MOUNT_DIR:-/mount}"

# Filesystem scan refresh threshold (hours)
FILESYSTEM_SCAN_REFRESH_HOURS="${FILESYSTEM_SCAN_REFRESH_HOURS:-2}"

# Force filesystem scan refresh flag
FORCE_FILESYSTEM_SCAN_REFRESH="${FORCE_FILESYSTEM_SCAN_REFRESH:-false}"

# Preserve directory paths in S3
PRESERVE_DIRECTORY_PATHS="${PRESERVE_DIRECTORY_PATHS:-true}"

################################################################################
# PUBLIC API: DIRECTORY DISCOVERY
################################################################################

#------------------------------------------------------------------------------
# find_backup_directories
#
# Finds all directories containing backup trigger files and applies
# hierarchical filtering to avoid redundant backups
#
# Trigger Files:
#   - backupthisdir.txt  : Shallow backup (this directory only)
#   - backupalldirs.txt  : Deep backup (this directory + all subdirectories)
#
# Returns:
#   0 - Directories found, printed to stdout (format: "dir:mode")
#   1 - No directories found
#
# Output:
#   One line per directory in format: "/path/to/dir:mode"
#   Mode is either "shallow" or "deep"
#
# Performance:
#   Uses find with -print0 for safety with special characters
#   Caches results to avoid repeated scans
#
# Example:
#   while IFS= read -r dir_with_mode; do
#       dir="${dir_with_mode%:*}"
#       mode="${dir_with_mode##*:}"
#       echo "Backup $dir in $mode mode"
#   done < <(find_backup_directories)
#------------------------------------------------------------------------------
find_backup_directories() {
    log INFO "Scanning $MOUNT_DIR for directories with backup trigger files"
    
    if [[ ! -d "$MOUNT_DIR" ]]; then
        log ERROR "Mount directory does not exist: $MOUNT_DIR"
        return 1
    fi
    
    local directories_with_mode=()
    local processed_dirs=()
    
    # Find all backup trigger files (both types)
    while IFS= read -r -d '' file; do
        local dir
        dir=$(dirname "$file")
        local filename
        filename=$(basename "$file")
        
        # Check if we've already processed this directory
        local already_processed=false
        for processed_dir in "${processed_dirs[@]}"; do
            if [[ "$processed_dir" == "$dir" ]]; then
                already_processed=true
                break
            fi
        done
        
        if [[ "$already_processed" == true ]]; then
            continue  # Skip, already processed this directory
        fi
        
        # Determine backup mode for this directory
        local backup_mode=""
        if [[ -f "$dir/backupalldirs.txt" ]]; then
            backup_mode="deep"
            log DEBUG "Found deep backup directory: $dir (backupalldirs.txt)"
        elif [[ -f "$dir/backupthisdir.txt" ]]; then
            backup_mode="shallow"
            log DEBUG "Found shallow backup directory: $dir (backupthisdir.txt)"
        fi
        
        if [[ -n "$backup_mode" ]]; then
            directories_with_mode+=("$dir:$backup_mode")
            processed_dirs+=("$dir")
            
            # Log if both files exist (deep wins)
            if [[ -f "$dir/backupalldirs.txt" && -f "$dir/backupthisdir.txt" ]]; then
                log INFO "Directory has both trigger files, using deep mode: $dir"
            fi
        fi
    done < <(find "$MOUNT_DIR" \( -name "backupthisdir.txt" -o -name "backupalldirs.txt" \) -type f -print0 2>/dev/null)
    
    if [[ ${#directories_with_mode[@]} -eq 0 ]]; then
        log INFO "No directories with backup trigger files found in $MOUNT_DIR"
        return 1
    fi
    
    log INFO "Found ${#directories_with_mode[@]} directories before hierarchy filtering"
    
    # Apply hierarchy filtering to remove child directories when parent has backupalldirs.txt
    local filtered_directories
    if ! filtered_directories=$(printf '%s\n' "${directories_with_mode[@]}" | filter_hierarchical_directories); then
        log ERROR "Failed to apply hierarchy filtering"
        return 1
    fi
    
    # Count filtered results
    local filtered_count
    filtered_count=$(echo "$filtered_directories" | grep -c '.' || echo "0")
    
    if [[ "$filtered_count" -eq 0 ]]; then
        log INFO "No directories to backup after hierarchy filtering"
        return 1
    fi
    
    log INFO "✅ Final count: $filtered_count directories to backup after hierarchy filtering"
    echo "$filtered_directories"
    return 0
}

#------------------------------------------------------------------------------
# expand_deep_directories
#
# Expands deep-mode directories to include their first-level subdirectories
# This enables per-subdirectory state files for parallelization
#
# Parameters:
#   Reads from stdin: Lines of "dir:mode" format
#
# Returns:
#   0 - Success, expanded list printed to stdout
#   1 - Failure
#
# Output:
#   Lines of "dir:mode" for each directory to backup
#
# Logic:
#   - Shallow mode: Keep as-is (single directory)
#   - Deep mode: Expand to root + first-level subdirectories
#
# Example:
#   Input:  /data:deep
#   Output: /data:deep-root
#           /data/subdir1:deep-subdir
#           /data/subdir2:deep-subdir
#------------------------------------------------------------------------------
expand_deep_directories() {
    local expanded_dirs=()
    
    while IFS=: read -r dir mode; do
        [[ -z "$dir" ]] && continue
        
        if [[ "$mode" == "deep" ]]; then
            log DEBUG "Expanding deep directory: $dir"
            
            # Add root directory itself (for files at root level)
            expanded_dirs+=("$dir:deep-root")
            log DEBUG "  Added root: $dir"
            
            # Find first-level subdirectories
            local subdir_count=0
            while IFS= read -r -d '' subdir; do
                [[ -d "$subdir" ]] || continue
                expanded_dirs+=("$subdir:deep-subdir")
                log DEBUG "  Added subdirectory: $subdir"
                ((subdir_count++))
            done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
            
            log INFO "Expanded $dir into 1 root + $subdir_count subdirectories"
            
        else
            # Shallow mode - keep as-is
            expanded_dirs+=("$dir:$mode")
            log DEBUG "Shallow directory (no expansion): $dir"
        fi
    done
    
    # Output expanded list
    if [[ ${#expanded_dirs[@]} -eq 0 ]]; then
        log WARN "No directories after expansion"
        return 1
    fi
    
    printf '%s\n' "${expanded_dirs[@]}"
    return 0
}

#------------------------------------------------------------------------------
# filter_hierarchical_directories
#
# Filters out child directories when parent has backupalldirs.txt (deep mode)
# This prevents redundant backups of subdirectories already covered by parent
#
# Input:
#   Reads from stdin, one directory per line in format: "dir:mode"
#
# Returns:
#   0 - Success, filtered directories printed to stdout
#
# Output:
#   Filtered directories in same format: "dir:mode"
#
# Logic:
#   - If parent has backupalldirs.txt (deep), skip child backupthisdir.txt (shallow)
#   - Deep directories are never skipped (highest priority)
#   - Shallow directories only skipped if ancestor is deep
#
# Example:
#   echo -e "/mount/parent:deep\n/mount/parent/child:shallow" | filter_hierarchical_directories
#   # Output: /mount/parent:deep (child skipped)
#------------------------------------------------------------------------------
filter_hierarchical_directories() {
    # Read input directories from stdin
    local input_dirs=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            input_dirs+=("$line")
        fi
    done
    
    local filtered_dirs=()
    local skipped_dirs=()
    
    log DEBUG "Starting hierarchy filtering with ${#input_dirs[@]} directories"
    
    # For each directory, check if it has a parent with backupalldirs.txt
    for entry in "${input_dirs[@]}"; do
        # Parse dir:mode format (split on last colon)
        if [[ "$entry" =~ ^(.+):([^:]+)$ ]]; then
            local dir="${BASH_REMATCH[1]}"
            local mode="${BASH_REMATCH[2]}"
        else
            log ERROR "Invalid entry format (expected dir:mode): $entry"
            continue
        fi
        
        local should_skip=false
        local parent_dir=""
        
        # Only check for parents if this is a shallow backup directory
        if [[ "$mode" == "shallow" ]]; then
            log DEBUG "Checking parents for shallow directory: $dir"
            
            # Check all parent directories for backupalldirs.txt
            local current_path="$dir"
            while [[ "$current_path" != "$MOUNT_DIR" && "$current_path" != "/" ]]; do
                current_path=$(dirname "$current_path")
                
                # Stop if we've gone above MOUNT_DIR
                if [[ "${current_path#$MOUNT_DIR}" == "$current_path" ]]; then
                    break
                fi
                
                if [[ -f "$current_path/backupalldirs.txt" ]]; then
                    log DEBUG "Found backupalldirs.txt in parent: $current_path"
                    
                    # Check if this parent is in our list of directories to backup
                    for parent_entry in "${input_dirs[@]}"; do
                        if [[ "$parent_entry" =~ ^(.+):([^:]+)$ ]]; then
                            local parent_candidate="${BASH_REMATCH[1]}"
                            if [[ "$parent_candidate" == "$current_path" ]]; then
                                should_skip=true
                                parent_dir="$current_path"
                                log DEBUG "Will skip '$dir' due to parent '$parent_dir'"
                                break 2
                            fi
                        fi
                    done
                fi
            done
        else
            log DEBUG "Deep directory, no parent check needed: $dir"
        fi
        
        if [[ "$should_skip" == true ]]; then
            skipped_dirs+=("$dir")
            log INFO "Skipping '$dir' (shallow) - parent '$parent_dir' has deep backup"
        else
            filtered_dirs+=("$entry")
            log DEBUG "Keeping '$dir' (mode: $mode)"
        fi
    done
    
    if [[ ${#skipped_dirs[@]} -gt 0 ]]; then
        log INFO "Hierarchy filtering: Skipped ${#skipped_dirs[@]} child directories"
    fi
    
    # Return filtered directories
    printf '%s\n' "${filtered_dirs[@]}"
    return 0
}

################################################################################
# PUBLIC API: KEY GENERATION
################################################################################

#------------------------------------------------------------------------------
# generate_s3_consistent_directory_key
#
# Generates directory key that's consistent with S3 path structure
# This ensures state file keys align with S3 organization
#
# Parameters:
#   $1 - source_dir: Full directory path
#
# Returns:
#   0 - Success, key printed to stdout
#
# Output:
#   URL-safe base64 encoded key
#
# Example:
#   key=$(generate_s3_consistent_directory_key "/mount/project1")
#------------------------------------------------------------------------------
generate_s3_consistent_directory_key() {
    local source_dir="$1"
    
    if [[ -z "$source_dir" ]]; then
        log ERROR "generate_s3_consistent_directory_key: source_dir required"
        return 1
    fi
    
    # Get S3 path component (respects PRESERVE_DIRECTORY_PATHS)
    local s3_path_component
    s3_path_component=$(get_s3_path_component "$source_dir")
    
    # Generate key from S3 path component
    generate_directory_key "$s3_path_component"
}

################################################################################
# PUBLIC API: PATH UTILITIES
################################################################################

#------------------------------------------------------------------------------
# get_relative_path
#
# Gets path relative to mount directory
#
# Parameters:
#   $1 - full_path: Full path to file/directory
#   $2 - base_path: Base path to remove (optional, defaults to MOUNT_DIR)
#
# Returns:
#   0 - Success, relative path printed to stdout
#
# Output:
#   Relative path (without leading /)
#
# Example:
#   rel=$(get_relative_path "/mount/project1/file.txt" "/mount")
#   # Returns: project1/file.txt
#------------------------------------------------------------------------------
get_relative_path() {
    local full_path="$1"
    local base_path="${2:-$MOUNT_DIR}"
    
    # Remove base path prefix
    local relative="${full_path#$base_path/}"
    
    # If nothing was removed, path is not under base
    if [[ "$relative" == "$full_path" ]]; then
        log WARN "Path is not under base: $full_path (base: $base_path)"
        echo "$full_path"
    else
        echo "$relative"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# get_s3_path_component
#
# Generates S3 path component for directory based on PRESERVE_DIRECTORY_PATHS
#
# Parameters:
#   $1 - source_dir: Full path to directory
#
# Returns:
#   0 - Success, S3 path component printed to stdout
#
# Output:
#   S3 path component (either full relative path or just directory name)
#
# Example:
#   s3_path=$(get_s3_path_component "/mount/folder1/folder2/data")
#   # If PRESERVE_DIRECTORY_PATHS=true: folder1/folder2/data
#   # If PRESERVE_DIRECTORY_PATHS=false: data
#------------------------------------------------------------------------------
get_s3_path_component() {
    local source_dir="$1"
    
    if [[ "${PRESERVE_DIRECTORY_PATHS:-true}" == "true" ]]; then
        # Preserve full directory path structure
        local dir_relative_path
        dir_relative_path=$(get_relative_path "$source_dir" "$MOUNT_DIR")
        
        # If the source_dir is exactly MOUNT_DIR, use empty string (files go directly under current_state/)
        if [[ "$dir_relative_path" == "$source_dir" ]]; then
            echo ""
        else
            echo "$dir_relative_path"
        fi
    else
        # Use only directory name (legacy behavior)
        basename "$source_dir"
    fi
    
    return 0
}

################################################################################
# PUBLIC API: FILESYSTEM MAPPING
################################################################################

#------------------------------------------------------------------------------
# should_refresh_filesystem_cache
#
# Determines if filesystem cache needs to be refreshed based on age
#
# Parameters:
#   None
#
# Returns:
#   0 - Cache should be refreshed
#   1 - Cache is still valid
#
# Example:
#   if should_refresh_filesystem_cache; then
#       build_filesystem_map
#   fi
#------------------------------------------------------------------------------
should_refresh_filesystem_cache() {
    # Check if forced refresh is enabled
    if [[ "${FORCE_FILESYSTEM_SCAN_REFRESH:-false}" == "true" ]]; then
        log DEBUG "Forced filesystem scan refresh enabled"
        return 0
    fi
    
    # Check if aggregate state file exists
    if [[ ! -f "$AGGREGATE_STATE_FILE" ]]; then
        log DEBUG "Aggregate state file not found, refresh needed"
        return 0
    fi
    
    # Get last scan timestamp
    local last_scan_time
    last_scan_time=$(jq -r '.filesystem_scan_timestamp // empty' "$AGGREGATE_STATE_FILE" 2>/dev/null)
    
    if [[ -z "$last_scan_time" ]]; then
        log DEBUG "No filesystem scan timestamp, refresh needed"
        return 0
    fi
    
    # Calculate age of scan
    local scan_epoch current_epoch
    scan_epoch=$(parse_iso8601_date "$last_scan_time" 2>/dev/null || echo "0")
    current_epoch=$(date +%s)
    
    if [[ "$scan_epoch" -eq 0 ]]; then
        log DEBUG "Invalid scan timestamp, refresh needed"
        return 0
    fi
    
    # Calculate age in hours
    local age_seconds=$((current_epoch - scan_epoch))
    local age_hours
    
    if command -v bc >/dev/null 2>&1; then
        age_hours=$(echo "scale=2; $age_seconds / 3600" | bc)
    else
        age_hours=$((age_seconds / 3600))
    fi
    
    # Compare with threshold
    local threshold="${FILESYSTEM_SCAN_REFRESH_HOURS:-2}"
    
    if command -v bc >/dev/null 2>&1; then
        local needs_refresh
        needs_refresh=$(echo "$age_hours > $threshold" | bc)
        if [[ "$needs_refresh" == "1" ]]; then
            log DEBUG "Filesystem cache age ${age_hours}h exceeds threshold ${threshold}h"
            return 0
        fi
    else
        if [[ ${age_hours%.*} -gt ${threshold%.*} ]]; then
            log DEBUG "Filesystem cache age ${age_hours}h exceeds threshold ${threshold}h"
            return 0
        fi
    fi
    
    log DEBUG "Filesystem cache is current (age: ${age_hours}h, threshold: ${threshold}h)"
    return 1
}

#------------------------------------------------------------------------------
# build_filesystem_map
#
# Builds complete filesystem map of all directories under MOUNT_DIR
# Uses caching to avoid expensive scans on every backup
#
# Parameters:
#   None
#
# Returns:
#   0 - Map built successfully
#   1 - Build failed
#
# Side Effects:
#   Updates aggregate state file with filesystem map
#   Preserves existing metadata for directories
#
# Performance:
#   - First run: Scans entire filesystem (~30-60s for 1000 dirs)
#   - Subsequent runs: Uses cache if recent (<2 hours old)
#   - Preserves metadata: Doesn't lose file checksums on refresh
#
# Example:
#   if should_refresh_filesystem_cache; then
#       build_filesystem_map
#   fi
#------------------------------------------------------------------------------
build_filesystem_map() {
    log INFO "Building filesystem map for: $MOUNT_DIR"
    local start_time=$(date +%s)
    
    if [[ ! -d "$MOUNT_DIR" ]]; then
        log ERROR "Mount directory does not exist: $MOUNT_DIR"
        return 1
    fi
    
    local current_time
    current_time=$(get_iso8601_timestamp)
    
    # Preserve existing metadata before rebuilding
    local existing_metadata="{}"
    if [[ -f "$AGGREGATE_STATE_FILE" ]]; then
        log DEBUG "Preserving existing metadata during filesystem map refresh"
        existing_metadata=$(jq -r '.filesystem_map // {}' "$AGGREGATE_STATE_FILE" 2>/dev/null || echo "{}")
    fi
    
    # Start building temporary map
    local temp_map
    temp_map=$(mktemp) || {
        log ERROR "Failed to create temp file for filesystem map"
        return 1
    }
    
    # Initialize map structure
    jq -n \
        --arg version "2.0.0" \
        --arg timestamp "$current_time" \
        --arg mount_dir "$MOUNT_DIR" \
        '{
            state_file_version: $version,
            last_updated: $timestamp,
            filesystem_scan_timestamp: $timestamp,
            mount_directory: $mount_dir,
            filesystem_map: {}
        }' > "$temp_map"
    
    local dir_count=0
    local preserved_count=0
    
    # Scan all directories under MOUNT_DIR
    while IFS= read -r -d '' dir; do
        # Generate directory key
        local s3_path_component
        s3_path_component=$(get_s3_path_component "$dir")
        
        local dir_key
        dir_key=$(generate_directory_key "$s3_path_component")
        
        # Check if this directory exists in preserved metadata
        local preserved_state="{}"
        if [[ "$existing_metadata" != "{}" ]]; then
            preserved_state=$(echo "$existing_metadata" | jq -r --arg key "$dir_key" '.[$key] // {}')
            if [[ "$preserved_state" != "{}" ]]; then
                ((preserved_count++))
                log DEBUG "Preserved metadata for: $s3_path_component"
            fi
        fi
        
        # Add directory to map (with preserved metadata if available)
        jq --arg key "$dir_key" \
           --arg abs_path "$dir" \
           --arg rel_path "$s3_path_component" \
           --arg timestamp "$current_time" \
           --argjson preserved "$preserved_state" \
           '.filesystem_map[$key] = {
               absolute_path: $abs_path,
               relative_path: $rel_path,
               s3_path_component: $rel_path,
               last_scanned: $timestamp,
               files: ($preserved.files // {}),
               metadata: ($preserved.metadata // {})
           }' "$temp_map" > "${temp_map}.tmp" && mv "${temp_map}.tmp" "$temp_map"
        
        ((dir_count++))
        
        # Progress logging for large filesystems
        if [[ $((dir_count % 1000)) -eq 0 ]]; then
            log DEBUG "Processed $dir_count directories..."
        fi
        
    done < <(find "$MOUNT_DIR" -type d -print0 2>/dev/null)
    
    # Add scan statistics
    local duration=$(($(date +%s) - start_time))
    jq --argjson count "$dir_count" \
       --argjson duration "$duration" \
       '.scan_statistics = {
           total_directories: $count,
           scan_duration_seconds: $duration
       }' "$temp_map" > "${temp_map}.tmp" && mv "${temp_map}.tmp" "$temp_map"
    
    # Atomic replace
    mv "$temp_map" "$AGGREGATE_STATE_FILE" || {
        log ERROR "Failed to write filesystem map"
        rm -f "$temp_map"
        return 1
    }
    
    log INFO "✅ Filesystem map built: $dir_count directories in ${duration}s"
    log INFO "Metadata preservation: $preserved_count dirs preserved"
    
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f generate_s3_consistent_directory_key
readonly -f find_backup_directories expand_deep_directories filter_hierarchical_directories
readonly -f get_relative_path get_s3_path_component
readonly -f should_refresh_filesystem_cache build_filesystem_map

log DEBUG "Module loaded: $FILESYSTEM_MODULE_NAME v$FILESYSTEM_MODULE_VERSION (API v$FILESYSTEM_API_VERSION)"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_filesystem() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "generate_s3_consistent_directory_key"
        "find_backup_directories" "filter_hierarchical_directories"
        "get_relative_path" "get_s3_path_component"
        "should_refresh_filesystem_cache" "build_filesystem_map"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $FILESYSTEM_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies
    for func in "log" "generate_directory_key"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $FILESYSTEM_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check MOUNT_DIR is set
    if [[ -z "${MOUNT_DIR:-}" ]]; then
        log ERROR "Module $FILESYSTEM_MODULE_NAME: MOUNT_DIR not set"
        ((errors++))
    fi
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_filesystem || die "Module validation failed: $FILESYSTEM_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

