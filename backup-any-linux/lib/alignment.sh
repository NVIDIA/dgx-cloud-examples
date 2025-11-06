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
# alignment.sh - Forced Alignment and Orphan Cleanup Module
################################################################################
# Purpose: Detects and cleans orphaned S3 objects when backup triggers change.
#          Implements forced alignment mode to reconcile filesystem state with
#          S3 storage, moving orphaned objects to yesterday_state for retention.
#
# Dependencies: core.sh, utils.sh, config.sh, state.sh, filesystem.sh, s3.sh, deletion.sh
#
# Alignment Scenarios:
#   1. Backup trigger file removed (backupalldirs.txt/backupthisdir.txt)
#   2. Backup mode changed (deep → shallow)
#   3. Directory deleted but S3 objects remain
#
# Public API:
#   Discovery:
#   - discover_active_directories()      : Find currently active backup directories
#   - identify_orphaned_state_files()    : Find state files for inactive directories
#   - identify_orphaned_s3_objects()     : Find S3 objects without active directories
#
#   Processing:
#   - move_orphaned_objects_to_yesterday() : Move orphaned S3 objects
#   - archive_orphaned_state_files()     : Archive inactive state files
#
#   Tracking:
#   - record_alignment_operation()       : Update directory-state.json
#   - update_alignment_metrics()         : Track per-directory metrics
#
#   Main Entry Point:
#   - perform_forced_alignment()         : Main orchestrator (exclusive operation)
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-03
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly ALIGNMENT_MODULE_VERSION="1.0.0"
readonly ALIGNMENT_MODULE_NAME="alignment"
readonly ALIGNMENT_MODULE_DEPS=("core" "utils" "config" "state" "filesystem" "s3" "deletion")
readonly ALIGNMENT_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${ALIGNMENT_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: alignment.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION
################################################################################

# Directory state file (use from state.sh if already defined)
if [[ -z "${DIRECTORY_STATE_FILE:-}" ]]; then
    DIRECTORY_STATE_FILE="${SCRIPT_DIR}/state/high-level/directory-state.json"
fi

# Archived state directory
readonly ARCHIVED_STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/state}/archived"

# Alignment history retention (number of operations to keep in history)
ALIGNMENT_HISTORY_RETENTION="${ALIGNMENT_HISTORY_RETENTION:-50}"

# Ensure archived directory exists
mkdir -p "$ARCHIVED_STATE_DIR" 2>/dev/null || true

################################################################################
# GLOBAL ALIGNMENT STATISTICS
################################################################################

# Track alignment operation metrics
declare -g ALIGNMENT_STATS_ORPHANED_OBJECTS=0
declare -g ALIGNMENT_STATS_OBJECTS_MOVED=0
declare -g ALIGNMENT_STATS_OBJECTS_FAILED=0
declare -g ALIGNMENT_STATS_BYTES_MOVED=0
declare -g ALIGNMENT_STATS_STATE_FILES_ARCHIVED=0
declare -g ALIGNMENT_STATS_DIRECTORIES_AFFECTED=0

################################################################################
# PUBLIC API: DISCOVERY FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# discover_active_directories
#
# Discovers all directories that should currently be backed up
# REUSES: find_backup_directories() and expand_deep_directories()
#
# Parameters:
#   None
#
# Returns:
#   0 - Success, active directories printed to stdout
#   1 - Discovery failed
#
# Output:
#   Lines of "directory:mode" format for all active directories
#
# Example:
#   active_dirs=$(discover_active_directories)
#   # Output:
#   # /data:deep-root
#   # /data/project-alpha:deep-subdir
#------------------------------------------------------------------------------
discover_active_directories() {
    log INFO "Discovering currently active backup directories..."
    
    # Use existing discovery logic (respects hierarchy filtering!)
    local trigger_dirs
    if ! trigger_dirs=$(find_backup_directories); then
        log WARN "No backup trigger files found - all state files may be orphaned"
        # Return empty (no active directories)
        return 0  # Success but no results
    fi
    
    # Validate we got actual data (guard against empty string edge case)
    if [[ -z "$trigger_dirs" || "$trigger_dirs" == "" ]]; then
        log WARN "Empty result from find_backup_directories"
        return 0  # Success but no results
    fi
    
    # Expand deep directories to per-subdirectory level
    local expanded_dirs
    if ! expanded_dirs=$(echo "$trigger_dirs" | expand_deep_directories); then
        log ERROR "Failed to expand directories"
        return 1
    fi
    
    # Count results
    local dir_count
    dir_count=$(echo "$expanded_dirs" | wc -l)
    log INFO "✅ Found $dir_count active backup directories (after expansion)"
    
    echo "$expanded_dirs"
    return 0
}

#------------------------------------------------------------------------------
# identify_orphaned_state_files
#
# Identifies state files for directories that are no longer actively backed up
#
# Parameters:
#   $1 - active_dirs: Newline-separated list of "dir:mode" entries
#
# Returns:
#   0 - Success, orphaned states JSON printed to stdout
#   1 - Identification failed
#
# Output:
#   JSON array of orphaned state file information
#
# Example:
#   orphaned=$(identify_orphaned_state_files "$active_dirs")
#------------------------------------------------------------------------------
identify_orphaned_state_files() {
    local active_dirs="$1"
    
    log INFO "Analyzing state files to identify orphaned directories..."
    
    # Build associative array of active directories for O(1) lookup
    declare -A active_dirs_lookup
    local active_count=0
    
    while IFS=: read -r dir mode; do
        [[ -z "$dir" ]] && continue
        active_dirs_lookup["$dir"]=1
        ((active_count++))
    done <<< "$active_dirs"
    
    log DEBUG "Built active directory lookup table: $active_count directories"
    
    # Scan all state files
    local orphaned_states=()
    local checked_count=0
    local orphaned_count=0
    
    for state_file in "${CURRENT_STATE_DIR}"/*.state.json; do
        # Skip if no state files exist
        [[ -f "$state_file" ]] || continue
        
        ((checked_count++))
        
        # Extract directory path from state file
        local dir_path
        dir_path=$(jq -r '.directory_path // ""' "$state_file" 2>/dev/null)
        
        if [[ -z "$dir_path" ]]; then
            log WARN "State file has no directory_path: $state_file"
            continue
        fi
        
        # Check if this directory is in active list
        if [[ -z "${active_dirs_lookup[$dir_path]:-}" ]]; then
            # ORPHANED!
            log INFO "Orphaned state detected: $dir_path"
            
            # Extract metadata from state file
            local file_count total_size
            file_count=$(jq '.metadata | length' "$state_file" 2>/dev/null || echo "0")
            total_size=$(jq '[.metadata[].size] | add // 0' "$state_file" 2>/dev/null || echo "0")
            
            # Build orphaned state entry
            local state_entry
            state_entry=$(jq -n \
                --arg state_file "$state_file" \
                --arg dir_path "$dir_path" \
                --argjson file_count "$file_count" \
                --argjson total_size "$total_size" \
                '{
                    state_file: $state_file,
                    directory_path: $dir_path,
                    file_count: $file_count,
                    total_size_bytes: $total_size
                }')
            
            orphaned_states+=("$state_entry")
            ((orphaned_count++))
        else
            log DEBUG "State file is active: $dir_path"
        fi
    done
    
    log INFO "State file analysis: checked $checked_count, found $orphaned_count orphaned"
    
    # Build JSON array output
    if [[ ${#orphaned_states[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${orphaned_states[@]}" | jq -s '.'
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# identify_orphaned_s3_objects
#
# Identifies S3 objects that don't belong to any active backup directory
# SMART: Uses s3-cache.json instead of live S3 API calls!
#
# Parameters:
#   $1 - active_dirs: Newline-separated list of "dir:mode" entries
#
# Returns:
#   0 - Success, orphaned objects JSON printed to stdout
#   1 - Identification failed
#
# Output:
#   JSON array of orphaned S3 object information
#
# Example:
#   orphaned=$(identify_orphaned_s3_objects "$active_dirs")
#------------------------------------------------------------------------------
identify_orphaned_s3_objects() {
    local active_dirs="$1"
    
    log INFO "Analyzing S3 objects to identify orphans (using s3-cache.json)..."
    
    # Check if S3 cache exists (use variable from checksum.sh for consistency)
    local s3_cache_file="${S3_CACHE_FILE:-${SCRIPT_DIR}/state/s3/s3-cache.json}"
    if [[ ! -f "$s3_cache_file" ]]; then
        log ERROR "S3 cache not found: $s3_cache_file"
        log ERROR "Run backup first to generate S3 cache before forced alignment"
        return 1
    fi
    
    log DEBUG "Using S3 cache: $s3_cache_file"
    
    # Build associative array of active directory components for O(1) lookup
    declare -A active_components_lookup
    local active_count=0
    
    while IFS=: read -r dir mode; do
        [[ -z "$dir" ]] && continue
        
        # Get S3 path component for this directory
        local s3_component
        s3_component=$(get_s3_path_component "$dir")
        
        if [[ -n "$s3_component" ]]; then
            active_components_lookup["$s3_component"]=1
            ((active_count++))
            log DEBUG "Active S3 component: $s3_component (from $dir)"
        fi
    done <<< "$active_dirs"
    
    log DEBUG "Built active S3 component lookup table: $active_count components"
    
    # Read S3 objects from cache (instant, free, no API call!)
    local s3_files
    s3_files=$(jq -r '.files[]? // empty' "$s3_cache_file" 2>/dev/null)
    
    if [[ -z "$s3_files" ]]; then
        log WARN "No files in S3 cache"
        echo "[]"
        return 0
    fi
    
    local orphaned_objects=()
    local checked_count=0
    local orphaned_count=0
    local total_orphaned_size=0
    
    # Process each S3 file from cache
    while IFS= read -r s3_path; do
        [[ -z "$s3_path" ]] && continue
        
        ((checked_count++))
        
        # Parse S3 path to extract directory component
        # Example: s3://bucket/prefix/current_state/project-beta/src/main.py
        #          → directory_component: project-beta
        
        local path_after_prefix
        if [[ "$s3_path" =~ current_state/(.+)$ ]]; then
            path_after_prefix="${BASH_REMATCH[1]}"
        else
            log DEBUG "Skipping non-current_state object: $s3_path"
            continue
        fi
        
        # Extract directory component (first path segment after current_state/)
        local dir_component
        if [[ "$path_after_prefix" == */* ]]; then
            dir_component=$(echo "$path_after_prefix" | cut -d'/' -f1)
        else
            # File at root of current_state
            dir_component=""
        fi
        
        log DEBUG "Checking S3 object: $s3_path (component: ${dir_component:-<root>})"
        
        # Check if this directory component is active
        local is_orphaned=false
        
        if [[ -z "$dir_component" ]]; then
            # Root-level file - check if MOUNT_DIR is active
            if [[ -z "${active_components_lookup[""]:-}" ]]; then
                is_orphaned=true
                log DEBUG "Root-level file orphaned (no active root trigger): $s3_path"
            fi
        else
            # Directory file - check if directory component is active
            if [[ -z "${active_components_lookup[$dir_component]:-}" ]]; then
                is_orphaned=true
                log DEBUG "Orphaned S3 object (directory not active): $s3_path"
            fi
        fi
        
        # If orphaned, add to results
        if [[ "$is_orphaned" == "true" ]]; then
            # Extract size from cache if available (would need to re-read cache with full metadata)
            # For now, we'll get size from orphaned state files when we process
            
            local orphan_entry
            orphan_entry=$(jq -n \
                --arg s3_path "$s3_path" \
                --arg dir_component "$dir_component" \
                --arg path_after_prefix "$path_after_prefix" \
                '{
                    s3_path: $s3_path,
                    directory_component: $dir_component,
                    relative_path: $path_after_prefix
                }')
            
            orphaned_objects+=("$orphan_entry")
            ((orphaned_count++))
        fi
        
    done <<< "$s3_files"
    
    log INFO "S3 object analysis: checked $checked_count, found $orphaned_count orphaned"
    
    # Build JSON array output
    if [[ ${#orphaned_objects[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${orphaned_objects[@]}" | jq -s '.'
    fi
    
    return 0
}

################################################################################
# PUBLIC API: PROCESSING FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# move_orphaned_objects_to_yesterday
#
# Moves orphaned S3 objects from current_state to yesterday_state
# Uses efficient aws s3 mv command (single operation, atomic)
#
# Parameters:
#   $1 - orphaned_objects_json: JSON array of orphaned objects
#   $2 - orphaned_states_json: JSON array of orphaned state files
#
# Returns:
#   0 - All objects moved successfully
#   1 - Some or all moves failed
#
# Side Effects:
#   Updates ALIGNMENT_STATS_* global variables
#   Tracks deletions in yesterday-backup-state.json
#
# Example:
#   move_orphaned_objects_to_yesterday "$orphaned_obj" "$orphaned_states"
#------------------------------------------------------------------------------
move_orphaned_objects_to_yesterday() {
    local orphaned_objects_json="$1"
    local orphaned_states_json="$2"
    
    # Count orphaned objects
    local object_count
    object_count=$(echo "$orphaned_objects_json" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$object_count" == "0" ]]; then
        log INFO "No orphaned objects to move"
        return 0
    fi
    
    log INFO "Moving $object_count orphaned objects from current_state to yesterday_state..."
    
    # Build S3 base paths
    local s3_current_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_current_base+="/$S3_PREFIX"
    s3_current_base+="/current_state/"
    
    local s3_yesterday_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_yesterday_base+="/$S3_PREFIX"
    s3_yesterday_base+="/yesterday_state/"
    
    local moved_count=0
    local failed_count=0
    local total_size_moved=0
    
    # Process each orphaned object
    local index=0
    while [[ $index -lt $object_count ]]; do
        # Progress indication for large operations (every 10 objects or 10%)
        if [[ $((index % 10)) -eq 0 ]] || [[ $((index * 100 / object_count)) -ne $(((index - 1) * 100 / object_count)) ]]; then
            local progress_pct=$((index * 100 / object_count))
            log INFO "Progress: $index/$object_count objects processed (${progress_pct}%)"
        fi
        
        # Extract object details
        local s3_path relative_path dir_component
        s3_path=$(echo "$orphaned_objects_json" | jq -r ".[$index].s3_path" 2>/dev/null)
        relative_path=$(echo "$orphaned_objects_json" | jq -r ".[$index].relative_path" 2>/dev/null)
        dir_component=$(echo "$orphaned_objects_json" | jq -r ".[$index].directory_component" 2>/dev/null)
        
        if [[ -z "$s3_path" || -z "$relative_path" ]]; then
            log WARN "Skipping orphaned object with missing data at index $index"
            ((index++))
            continue
        fi
        
        # Build source and destination paths
        local s3_source="$s3_path"
        local s3_dest
        
        # Orphaned objects are treated as "deleted" from backup perspective because:
        # 1. Directory was deleted, OR
        # 2. Backup trigger removed (directory no longer under backup management)
        # In both cases, files are being removed from active protection → use deleted_ prefix
        # 
        # Note: We use deleted_ prefix here (not versions_) because these objects are
        # being removed from the backup scope entirely, not just modified versions.
        # Future enhancement could check filesystem to distinguish truly deleted vs
        # merely untracked, but current conservative approach is correct.
        
        if [[ -n "$dir_component" ]]; then
            # Apply deleted_ prefix to directory component
            # Extract path within directory (everything after first slash)
            local path_within_dir
            if [[ "$relative_path" == */* ]]; then
                path_within_dir="${relative_path#*/}"  # Remove first component
            else
                path_within_dir="$relative_path"  # No slash, use as-is
            fi
            s3_dest="${s3_yesterday_base}deleted_${dir_component}/${path_within_dir}"
        else
            # Root-level file
            s3_dest="${s3_yesterday_base}deleted_$(basename "$relative_path")"
        fi
        
        log DEBUG "Moving orphaned object: $s3_source → $s3_dest"
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log INFO "[DRY-RUN] Would move: $relative_path"
            ((moved_count++))
        else
            # Use s3_move (efficient: uses aws s3 mv, single atomic operation)
            if s3_move "$s3_source" "$s3_dest"; then
                log INFO "✓ Moved orphaned object: $relative_path"
                ((moved_count++))
                
                # Get metadata from orphaned state file
                local checksum size source_dir
                checksum=$(get_orphan_metadata "$relative_path" "$orphaned_states_json" "checksum")
                size=$(get_orphan_metadata "$relative_path" "$orphaned_states_json" "size")
                source_dir=$(get_orphan_metadata "$relative_path" "$orphaned_states_json" "source_dir")
                
                # Track as deletion with alignment reason
                track_file_deletion "$relative_path" "$source_dir" "$checksum" "$size" "forced_alignment_orphan_cleanup" || {
                    log WARN "Orphan moved but deletion tracking failed: $relative_path"
                }
                
                # Update statistics
                if [[ "$size" =~ ^[0-9]+$ ]]; then
                    total_size_moved=$((total_size_moved + size))
                fi
            else
                log ERROR "Failed to move orphaned object: $relative_path"
                ((failed_count++))
            fi
        fi
        
        ((index++))
    done
    
    # Update global statistics
    ALIGNMENT_STATS_ORPHANED_OBJECTS=$object_count
    ALIGNMENT_STATS_OBJECTS_MOVED=$moved_count
    ALIGNMENT_STATS_OBJECTS_FAILED=$failed_count
    ALIGNMENT_STATS_BYTES_MOVED=$total_size_moved
    
    log INFO "Orphan movement complete: $moved_count moved, $failed_count failed"
    
    [[ $failed_count -eq 0 ]] && return 0 || return 1
}

#------------------------------------------------------------------------------
# get_orphan_metadata
#
# Helper function to extract metadata for orphaned file from state files
#
# Parameters:
#   $1 - file_relative_path: Relative path of file
#   $2 - orphaned_states_json: JSON array of orphaned states
#   $3 - field: Field to extract (checksum, size, source_dir)
#
# Returns:
#   0 - Success, value printed to stdout
#   1 - Not found
#
# Output:
#   Requested metadata value or default
#------------------------------------------------------------------------------
get_orphan_metadata() {
    local file_relative_path="$1"
    local orphaned_states_json="$2"
    local field="$3"
    
    # Extract directory component from file path
    local dir_component file_key
    if [[ "$file_relative_path" == */* ]]; then
        dir_component=$(echo "$file_relative_path" | cut -d'/' -f1)
        # File key is path WITHIN that directory (remove dir_component prefix)
        file_key="${file_relative_path#*/}"  # Remove everything up to first slash
    else
        # Root-level file (no directory component)
        dir_component=""
        file_key="$file_relative_path"
    fi
    
    log DEBUG "get_orphan_metadata: Looking for '$file_relative_path' (component: '${dir_component:-<root>}', key: '$file_key')"
    
    # Find the state file for this directory component
    # CRITICAL: Use exact path matching, not endswith (prevents wrong state file selection)
    local state_file=""
    
    # Search through all orphaned states to find the right one
    local states_count
    states_count=$(echo "$orphaned_states_json" | jq 'length' 2>/dev/null || echo "0")
    
    local idx=0
    while [[ $idx -lt $states_count ]] && [[ -z "$state_file" ]]; do
        local candidate_dir candidate_file
        candidate_dir=$(echo "$orphaned_states_json" | jq -r ".[$idx].directory_path" 2>/dev/null)
        candidate_file=$(echo "$orphaned_states_json" | jq -r ".[$idx].state_file" 2>/dev/null)
        
        # Match logic:
        # For root files (dir_component=""): Match directory ending with root path component
        # For subdir files (dir_component="edge-cases"): Match directory ending with that component
        local match=false
        if [[ -z "$dir_component" ]]; then
            # Root file - look for state without subdirectory in path
            # Match paths like "/mnt/data" but not "/mnt/data/subdir"
            if [[ -n "$candidate_dir" ]]; then
                # Count slashes to determine depth
                local slash_count=$(echo "$candidate_dir" | tr -cd '/' | wc -c)
                local mount_slash_count=$(echo "$MOUNT_DIR" | tr -cd '/' | wc -c)
                if [[ $slash_count -eq $mount_slash_count ]]; then
                    match=true
                fi
            fi
        else
            # Subdirectory file - match directory ending with component
            if [[ "$candidate_dir" == *"/$dir_component" ]]; then
                match=true
            fi
        fi
        
        if [[ "$match" == "true" ]]; then
            state_file="$candidate_file"
            log DEBUG "Matched state file for '$file_relative_path': $candidate_dir → $state_file"
            break
        fi
        ((idx++))
    done
    
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        log WARN "No state file found for '$file_relative_path' (component: '${dir_component:-<root>}')"
        # Defaults
        case "$field" in
            checksum) echo "unknown" ;;
            size) echo "0" ;;
            source_dir) echo "" ;;
            *) echo "" ;;
        esac
        return 1
    fi
    
    # Get metadata from state file
    case "$field" in
        checksum)
            jq -r --arg key "$file_key" '.metadata[$key].checksum // "unknown"' "$state_file" 2>/dev/null
            ;;
        size)
            jq -r --arg key "$file_key" '.metadata[$key].size // 0' "$state_file" 2>/dev/null
            ;;
        source_dir)
            jq -r '.directory_path // ""' "$state_file" 2>/dev/null
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
    
    return 0
}

#------------------------------------------------------------------------------
# archive_orphaned_state_files
#
# Archives orphaned state files to state/archived/ directory
#
# Parameters:
#   $1 - orphaned_states_json: JSON array of orphaned state files
#
# Returns:
#   0 - All state files archived successfully
#   1 - Some or all archives failed
#
# Side Effects:
#   Moves state files from state/current/ to state/archived/
#   Updates ALIGNMENT_STATS_STATE_FILES_ARCHIVED
#
# Example:
#   archive_orphaned_state_files "$orphaned_states"
#------------------------------------------------------------------------------
archive_orphaned_state_files() {
    local orphaned_states_json="$1"
    
    # Count orphaned states
    local state_count
    state_count=$(echo "$orphaned_states_json" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$state_count" == "0" ]]; then
        log INFO "No orphaned state files to archive"
        return 0
    fi
    
    log INFO "Archiving $state_count orphaned state files..."
    
    # Ensure archive directory exists
    mkdir -p "$ARCHIVED_STATE_DIR" || {
        log ERROR "Failed to create archive directory: $ARCHIVED_STATE_DIR"
        return 1
    }
    
    local archived_count=0
    local failed_count=0
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Process each orphaned state
    local index=0
    while [[ $index -lt $state_count ]]; do
        # Extract state file info
        local state_file dir_path
        state_file=$(echo "$orphaned_states_json" | jq -r ".[$index].state_file" 2>/dev/null)
        dir_path=$(echo "$orphaned_states_json" | jq -r ".[$index].directory_path" 2>/dev/null)
        
        if [[ -z "$state_file" || ! -f "$state_file" ]]; then
            log WARN "State file not found or invalid at index $index"
            ((index++))
            continue
        fi
        
        # Build archive filename
        local state_basename=$(basename "$state_file" .state.json)
        local archive_file="${ARCHIVED_STATE_DIR}/${state_basename}_${timestamp}.state.json"
        
        log DEBUG "Archiving state: $state_file → $archive_file"
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log INFO "[DRY-RUN] Would archive state for: $dir_path"
            ((archived_count++))
        else
            if mv "$state_file" "$archive_file"; then
                log INFO "✓ Archived state file for: $dir_path"
                ((archived_count++))
            else
                log ERROR "Failed to archive state file: $state_file"
                ((failed_count++))
            fi
        fi
        
        ((index++))
    done
    
    # Update global statistics
    ALIGNMENT_STATS_STATE_FILES_ARCHIVED=$archived_count
    
    log INFO "State archival complete: $archived_count archived, $failed_count failed"
    
    [[ $failed_count -eq 0 ]] && return 0 || return 1
}

################################################################################
# PUBLIC API: AUDIT TRAIL AND TRACKING
################################################################################

#------------------------------------------------------------------------------
# record_alignment_operation
#
# Records forced alignment operation to directory-state.json
# Tracks statistics in GB (2 decimal places) as per requirements
#
# Parameters:
#   $1 - orphaned_dirs_list: Array of orphaned directory paths
#   $2 - duration_seconds: Operation duration
#
# Returns:
#   0 - Recorded successfully
#   1 - Recording failed
#
# Side Effects:
#   Updates state/high-level/directory-state.json
#
# Example:
#   record_alignment_operation "$orphaned_dirs" "45"
#------------------------------------------------------------------------------
record_alignment_operation() {
    local orphaned_dirs_json="$1"
    local duration_seconds="$2"
    
    log INFO "Recording alignment operation to directory-state.json..."
    
    # Calculate size in GB (2 decimal places)
    local size_gb
    size_gb=$(bytes_to_gb "$ALIGNMENT_STATS_BYTES_MOVED")
    
    # Build alignment history entry
    local timestamp
    timestamp=$(get_iso8601_timestamp)
    
    # Convert orphaned dirs array to JSON
    local orphaned_dirs_array
    orphaned_dirs_array=$(echo "$orphaned_dirs_json" | jq '[.[].directory_path]' 2>/dev/null || echo "[]")
    
    local history_entry
    history_entry=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg trigger "manual" \
        --argjson orphaned_objects "$ALIGNMENT_STATS_ORPHANED_OBJECTS" \
        --argjson objects_moved "$ALIGNMENT_STATS_OBJECTS_MOVED" \
        --argjson objects_failed "$ALIGNMENT_STATS_OBJECTS_FAILED" \
        --argjson state_files_archived "$ALIGNMENT_STATS_STATE_FILES_ARCHIVED" \
        --arg size_gb "$size_gb" \
        --arg duration "$duration_seconds" \
        --argjson orphaned_dirs "$orphaned_dirs_array" \
        '{
            timestamp: $timestamp,
            trigger: $trigger,
            orphaned_directories: $orphaned_dirs,
            orphaned_objects_found: $orphaned_objects,
            objects_moved: $objects_moved,
            objects_failed: $objects_failed,
            state_files_archived: $state_files_archived,
            total_size_gb: ($size_gb | tonumber),
            duration_seconds: ($duration | tonumber),
            status: (if $objects_failed == 0 then "completed_successfully" else "completed_with_errors" end)
        }')
    
    # Update directory-state.json
    local temp_file
    temp_file=$(mktemp) || {
        log ERROR "Failed to create temp file for directory state update"
        return 1
    }
    
    # Update summary and add to alignment_history
    if jq --argjson entry "$history_entry" \
       --arg timestamp "$timestamp" \
       --arg size_gb "$size_gb" \
       '.last_updated = $timestamp |
        .summary.total_alignment_operations = (.summary.total_alignment_operations // 0) + 1 |
        .summary.last_forced_alignment = $timestamp |
        .summary.total_objects_cleaned_all_time = (.summary.total_objects_cleaned_all_time // 0) + '"$ALIGNMENT_STATS_OBJECTS_MOVED"' |
        .summary.total_size_moved_all_time_gb = ((.summary.total_size_moved_all_time_gb // 0) + ($size_gb | tonumber) | . * 100 | round / 100) |
        .alignment_history = ((.alignment_history // []) + [$entry])' \
       "$DIRECTORY_STATE_FILE" > "$temp_file"; then
        
        mv "$temp_file" "$DIRECTORY_STATE_FILE" || {
            log ERROR "Failed to move temp file to directory state"
            rm -f "$temp_file"  # Cleanup on failure
            return 1
        }
    else
        log ERROR "Failed to update directory state with jq"
        rm -f "$temp_file"  # Cleanup on failure
        return 1
    fi
    
    log INFO "✅ Alignment operation recorded to directory-state.json"
    return 0
}

#------------------------------------------------------------------------------
# update_directory_tracking
#
# Updates per-directory tracking in directory-state.json
#
# Parameters:
#   $1 - orphaned_states_json: JSON array of orphaned states
#
# Returns:
#   0 - Updated successfully
#   1 - Update failed
#
# Example:
#   update_directory_tracking "$orphaned_states"
#------------------------------------------------------------------------------
update_directory_tracking() {
    local orphaned_states_json="$1"
    
    local state_count
    state_count=$(echo "$orphaned_states_json" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$state_count" == "0" ]]; then
        return 0
    fi
    
    log DEBUG "Updating directory tracking for $state_count directories..."
    
    local timestamp
    timestamp=$(get_iso8601_timestamp)
    
    # Build tracking updates for ALL directories in a SINGLE jq operation (performance!)
    # This prevents multiple file writes and race conditions
    local tracking_updates
    tracking_updates=$(echo "$orphaned_states_json" | jq -c \
        --arg timestamp "$timestamp" \
        --argjson objects_moved "$ALIGNMENT_STATS_OBJECTS_MOVED" \
        'map({
            key: .directory_path,
            value: {
                last_alignment: $timestamp,
                objects_moved: $objects_moved,
                size_moved_gb: ((.total_size_bytes // 0) / 1073741824 | . * 100 | round / 100)
            }
        }) | from_entries' 2>/dev/null)
    
    if [[ -z "$tracking_updates" || "$tracking_updates" == "null" ]]; then
        log WARN "Failed to build tracking updates"
        return 1
    fi
    
    # Single atomic update to directory-state.json
    local temp_file
    temp_file=$(mktemp) || {
        log ERROR "Failed to create temp file for directory tracking"
        return 1
    }
    
    # Merge all directory tracking updates in ONE operation
    if jq --argjson updates "$tracking_updates" \
       --arg timestamp "$timestamp" \
       '.last_updated = $timestamp |
        .directory_tracking = (.directory_tracking // {}) + $updates' \
       "$DIRECTORY_STATE_FILE" > "$temp_file"; then
        
        mv "$temp_file" "$DIRECTORY_STATE_FILE" || {
            log ERROR "Failed to move temp file for directory tracking"
            rm -f "$temp_file"  # Cleanup on failure
            return 1
        }
    else
        log ERROR "Failed to update directory tracking with jq"
        rm -f "$temp_file"  # Cleanup on failure
        return 1
    fi
    
    log DEBUG "Directory tracking updated (batched $state_count directories in single operation)"
    return 0
}

################################################################################
# PUBLIC API: MAIN ORCHESTRATOR
################################################################################

#------------------------------------------------------------------------------
# perform_forced_alignment
#
# Main orchestrator for forced alignment operation
# EXCLUSIVE OPERATION: Runs instead of regular backup, then exits
#
# Parameters:
#   None (uses global configuration)
#
# Returns:
#   0 - Alignment completed successfully
#   1 - Alignment failed
#
# Workflow:
#   1. Discover active directories (respects current triggers)
#   2. Identify orphaned state files
#   3. Identify orphaned S3 objects (uses s3-cache.json!)
#   4. Move orphaned objects to yesterday_state
#   5. Archive orphaned state files
#   6. Record operation in directory-state.json
#   7. Auto-disable FORCE_ALIGNMENT_MODE
#
# Example:
#   if perform_forced_alignment; then
#       echo "Alignment completed"
#   fi
#------------------------------------------------------------------------------
perform_forced_alignment() {
    log INFO "════════════════════════════════════════════════════════════"
    log INFO "FORCED ALIGNMENT MODE - Orphan Detection and Cleanup"
    log INFO "════════════════════════════════════════════════════════════"
    log INFO ""
    
    local start_time=$(date +%s)
    
    # Reset global statistics
    ALIGNMENT_STATS_ORPHANED_OBJECTS=0
    ALIGNMENT_STATS_OBJECTS_MOVED=0
    ALIGNMENT_STATS_OBJECTS_FAILED=0
    ALIGNMENT_STATS_BYTES_MOVED=0
    ALIGNMENT_STATS_STATE_FILES_ARCHIVED=0
    ALIGNMENT_STATS_DIRECTORIES_AFFECTED=0
    
    # STEP 0: Refresh S3 cache FIRST to ensure we have current S3 state
    # CRITICAL: This prevents stale cache from causing false orphan detection
    # SAFETY: If cache refresh fails, we ABORT (forced alignment requires accurate S3 view)
    log INFO "Step 0/6: Refreshing S3 cache to get current S3 state..."
    log INFO "This is MANDATORY - forced alignment requires fresh S3 data"
    
    if ! update_s3_cache; then
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "❌ FAILED TO REFRESH S3 CACHE"
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "Cannot proceed with forced alignment without current S3 state"
        log ERROR ""
        log ERROR "Possible causes:"
        log ERROR "  - s3-inspect.sh not found or not executable"
        log ERROR "  - AWS credentials invalid or expired"
        log ERROR "  - S3 bucket inaccessible"
        log ERROR "  - Network connectivity issues"
        log ERROR ""
        log ERROR "Please resolve the issue and try again"
        log ERROR "════════════════════════════════════════════════════════════"
        return 1
    fi
    
    # Verify cache file actually exists and has content
    local s3_cache_file="${S3_CACHE_FILE:-${SCRIPT_DIR}/state/s3/s3-cache.json}"
    if [[ ! -f "$s3_cache_file" ]]; then
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "❌ S3 CACHE FILE NOT CREATED"
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "Cache refresh reported success but file doesn't exist: $s3_cache_file"
        log ERROR "This is a critical error - aborting forced alignment"
        return 1
    fi
    
    # Verify cache has data (at least the basic structure)
    local cache_file_count
    cache_file_count=$(jq '.files | length' "$s3_cache_file" 2>/dev/null || echo "-1")
    
    if [[ "$cache_file_count" == "-1" ]]; then
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "❌ S3 CACHE FILE INVALID"
        log ERROR "════════════════════════════════════════════════════════════"
        log ERROR "Cache file exists but is not valid JSON: $s3_cache_file"
        log ERROR "This is a critical error - aborting forced alignment"
        return 1
    fi
    
    log INFO "✅ S3 cache refreshed successfully - working with current S3 state"
    log INFO "   Cache contains: $cache_file_count S3 objects"
    log INFO ""
    
    # STEP 1: Discover currently active backup directories
    log INFO "Step 1/6: Discovering active backup directories..."
    local active_dirs
    if ! active_dirs=$(discover_active_directories); then
        log ERROR "Failed to discover active directories"
        return 1
    fi
    
    local active_count
    active_count=$(echo "$active_dirs" | grep -c '.' || echo "0")
    log INFO "✅ Found $active_count active backup directories"
    log INFO ""
    
    # STEP 2: Identify orphaned state files
    log INFO "Step 2/6: Identifying orphaned state files..."
    local orphaned_states
    if ! orphaned_states=$(identify_orphaned_state_files "$active_dirs"); then
        log ERROR "Failed to identify orphaned state files"
        return 1
    fi
    
    local orphaned_state_count
    orphaned_state_count=$(echo "$orphaned_states" | jq 'length' 2>/dev/null || echo "0")
    log INFO "✅ Found $orphaned_state_count orphaned state files"
    
    # Show orphaned directories
    if [[ "$orphaned_state_count" -gt 0 ]]; then
        log INFO "Orphaned directories:"
        echo "$orphaned_states" | jq -r '.[].directory_path' | while read -r dir; do
            log INFO "  - $dir"
        done
    fi
    log INFO ""
    
    # STEP 3: Identify orphaned S3 objects
    log INFO "Step 3/6: Identifying orphaned S3 objects (using s3-cache.json)..."
    local orphaned_objects
    if ! orphaned_objects=$(identify_orphaned_s3_objects "$active_dirs"); then
        log ERROR "Failed to identify orphaned S3 objects"
        return 1
    fi
    
    local orphaned_object_count
    orphaned_object_count=$(echo "$orphaned_objects" | jq 'length' 2>/dev/null || echo "0")
    log INFO "✅ Found $orphaned_object_count orphaned S3 objects"
    log INFO ""
    
    # Check if any orphans found
    if [[ "$orphaned_object_count" == "0" && "$orphaned_state_count" == "0" ]]; then
        log INFO "════════════════════════════════════════════════════════════"
        log INFO "✅ NO ORPHANS FOUND - System is in perfect alignment"
        log INFO "════════════════════════════════════════════════════════════"
        log INFO ""
        log INFO "No cleanup actions needed. Disabling forced alignment mode..."
        
        # Auto-disable forced alignment mode
        if disable_force_alignment_mode; then
            log INFO "✅ Forced alignment mode disabled"
        fi
        
        # Record zero-orphan operation for audit trail
        record_alignment_operation "$orphaned_states" "$(($(date +%s) - start_time))"
        
        return 0
    fi
    
    log INFO "════════════════════════════════════════════════════════════"
    log INFO "⚠️  ORPHANS DETECTED - Cleanup Required"
    log INFO "  Orphaned State Files: $orphaned_state_count"
    log INFO "  Orphaned S3 Objects:  $orphaned_object_count"
    log INFO "════════════════════════════════════════════════════════════"
    log INFO ""
    
    # STEP 4: Move orphaned objects to yesterday_state
    log INFO "Step 4/6: Moving orphaned S3 objects to yesterday_state..."
    if ! move_orphaned_objects_to_yesterday "$orphaned_objects" "$orphaned_states"; then
        log ERROR "Failed to move orphaned objects (may be partial)"
        # Continue anyway to archive states
    fi
    log INFO ""
    
    # STEP 5: Archive orphaned state files
    log INFO "Step 5/6: Archiving orphaned state files..."
    if ! archive_orphaned_state_files "$orphaned_states"; then
        log ERROR "Failed to archive orphaned state files (may be partial)"
    fi
    log INFO ""
    
    # STEP 6: Record alignment operation
    log INFO "Step 6/6: Recording alignment operation..."
    local duration=$(($(date +%s) - start_time))
    if ! record_alignment_operation "$orphaned_states" "$duration"; then
        log WARN "Failed to record alignment operation"
    fi
    
    # Update per-directory tracking
    update_directory_tracking "$orphaned_states"
    
    # Update S3 cache at end to reflect alignment changes (best practice)
    # NOTE: This is a second refresh - first one at START was mandatory
    # This ensures the cache reflects our changes for next backup/alignment
    log INFO ""
    log INFO "Updating S3 cache to reflect alignment changes..."
    if update_s3_cache; then
        log INFO "✅ S3 cache updated - next operation will see current state"
    else
        log WARN "⚠️  S3 cache update failed (non-critical - was refreshed at start)"
        log WARN "   Cache may be briefly stale but will refresh on next backup"
    fi
    
    # Auto-disable forced alignment mode
    log INFO ""
    log INFO "Disabling forced alignment mode..."
    if disable_force_alignment_mode; then
        log INFO "✅ Forced alignment mode disabled"
    else
        log WARN "Failed to auto-disable forced alignment mode - please disable manually in config"
    fi
    
    # Print summary
    log INFO ""
    log INFO "════════════════════════════════════════════════════════════"
    log INFO "✅ FORCED ALIGNMENT COMPLETED"
    log INFO "════════════════════════════════════════════════════════════"
    log INFO "Duration: ${duration}s"
    log INFO "Orphaned Objects: $ALIGNMENT_STATS_ORPHANED_OBJECTS"
    log INFO "Objects Moved: $ALIGNMENT_STATS_OBJECTS_MOVED"
    log INFO "Objects Failed: $ALIGNMENT_STATS_OBJECTS_FAILED"
    log INFO "Data Moved: $(bytes_to_gb $ALIGNMENT_STATS_BYTES_MOVED) GB"
    log INFO "State Files Archived: $ALIGNMENT_STATS_STATE_FILES_ARCHIVED"
    log INFO "════════════════════════════════════════════════════════════"
    log INFO ""
    
    # Return success if no failures
    [[ $ALIGNMENT_STATS_OBJECTS_FAILED -eq 0 ]] && return 0 || return 1
}

#------------------------------------------------------------------------------
# disable_force_alignment_mode
#
# Disables FORCE_ALIGNMENT_MODE in configuration file
# This prevents accidental re-runs of alignment
#
# Parameters:
#   None
#
# Returns:
#   0 - Disabled successfully
#   1 - Failed to disable
#
# Example:
#   disable_force_alignment_mode
#------------------------------------------------------------------------------
disable_force_alignment_mode() {
    # Check if CONFIG_FILE is set and exists
    if [[ -z "${CONFIG_FILE:-}" ]]; then
        log WARN "CONFIG_FILE environment variable not set, cannot auto-disable alignment mode"
        log WARN "This is likely due to CONFIG_FILE not being exported from backup.sh"
        return 1
    fi
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log WARN "Config file not found: $CONFIG_FILE"
        log WARN "Cannot auto-disable alignment mode"
        return 1
    fi
    
    log INFO "Disabling FORCE_ALIGNMENT_MODE in: $CONFIG_FILE"
    log DEBUG "Config file location: $CONFIG_FILE"
    
    # Create backup of config
    local config_backup="${CONFIG_FILE}.pre-alignment-$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$config_backup" || {
        log WARN "Failed to backup config file"
    }
    
    # Update config file (change true to false)
    local temp_config
    temp_config=$(mktemp) || {
        log ERROR "Failed to create temp file for config update"
        return 1
    }
    
    # Replace FORCE_ALIGNMENT_MODE=true with false (handles quoted and unquoted)
    # Pattern matches:
    #   FORCE_ALIGNMENT_MODE=true → FORCE_ALIGNMENT_MODE=false
    #   FORCE_ALIGNMENT_MODE="true" → FORCE_ALIGNMENT_MODE="false"
    #   FORCE_ALIGNMENT_MODE='true' → FORCE_ALIGNMENT_MODE='false'
    # Preserves quote style, no comments added
    sed -E 's/^FORCE_ALIGNMENT_MODE=(["'\'']?)true\1$/FORCE_ALIGNMENT_MODE=\1false\1/' "$CONFIG_FILE" > "$temp_config"
    
    # Move back
    if mv "$temp_config" "$CONFIG_FILE"; then
        log DEBUG "Config updated: FORCE_ALIGNMENT_MODE disabled"
        log DEBUG "Config backup: $config_backup"
        return 0
    else
        log ERROR "Failed to update config file"
        rm -f "$temp_config"
        return 1
    fi
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f discover_active_directories
readonly -f identify_orphaned_state_files identify_orphaned_s3_objects
readonly -f move_orphaned_objects_to_yesterday get_orphan_metadata
readonly -f archive_orphaned_state_files
readonly -f record_alignment_operation update_directory_tracking
readonly -f perform_forced_alignment disable_force_alignment_mode

log DEBUG "Module loaded: $ALIGNMENT_MODULE_NAME v$ALIGNMENT_MODULE_VERSION (API v$ALIGNMENT_API_VERSION)"
log DEBUG "Archived state directory: $ARCHIVED_STATE_DIR"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_alignment() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "discover_active_directories"
        "identify_orphaned_state_files"
        "identify_orphaned_s3_objects"
        "move_orphaned_objects_to_yesterday"
        "get_orphan_metadata"
        "archive_orphaned_state_files"
        "record_alignment_operation"
        "update_directory_tracking"
        "perform_forced_alignment"
        "disable_force_alignment_mode"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $ALIGNMENT_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for func in "log" "find_backup_directories" "expand_deep_directories" "get_s3_path_component" "s3_move" "track_file_deletion" "bytes_to_gb" "update_s3_cache"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $ALIGNMENT_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check module metadata
    if [[ -z "${ALIGNMENT_MODULE_VERSION:-}" ]]; then
        log ERROR "Module $ALIGNMENT_MODULE_NAME: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_alignment || die "Module validation failed: $ALIGNMENT_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

