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
# backup.sh - Main Backup Workflow Orchestration Module
################################################################################
# Purpose: Orchestrates the complete backup workflow including file discovery,
#          change detection, S3 synchronization, and state management. This is
#          the heart of the backup system that ties all other modules together.
#
# Dependencies: core.sh, utils.sh, config.sh, state.sh, filesystem.sh,
#               checksum.sh, s3.sh
#
# Backup Flow:
#   1. Find directories to backup (filesystem.sh)
#   2. For each directory:
#      a. Get previous state
#      b. Scan current files
#      c. Detect changes (checksum.sh)
#      d. Upload to S3 (s3.sh)
#      e. Update state (state.sh)
#   3. Detect deleted files
#   4. Move deleted files to yesterday_state
#   5. Build aggregate state
#   6. Print summary
#
# Public API:
#   Main Workflow:
#   - run_backup_workflow()       : Main entry point
#   - backup_directory()          : Backup single directory
#
#   File Processing:
#   - process_new_file()          : Handle new file upload
#   - process_changed_file()      : Handle modified file
#   - process_deleted_file()      : Handle deleted file
#
#   Statistics:
#   - print_backup_summary()      : Print final statistics
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly BACKUP_MODULE_VERSION="1.0.0"
readonly BACKUP_MODULE_NAME="backup"
readonly BACKUP_MODULE_DEPS=("core" "utils" "config" "state" "filesystem" "checksum" "s3")
readonly BACKUP_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${BACKUP_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: backup.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# GLOBAL STATISTICS
################################################################################

# Initialize global counters for summary
declare -g BACKUP_STATS_FILES_NEW=0
declare -g BACKUP_STATS_FILES_CHANGED=0
declare -g BACKUP_STATS_FILES_DELETED=0
declare -g BACKUP_STATS_FILES_UNCHANGED=0
declare -g BACKUP_STATS_BYTES_UPLOADED=0
declare -g BACKUP_STATS_ERRORS=0

################################################################################
# CONFIGURATION
################################################################################

# Mount directory
MOUNT_DIR="${MOUNT_DIR:-/mount}"

# S3 paths
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"

# Dry run mode
DRY_RUN="${DRY_RUN:-false}"

################################################################################
# PUBLIC API: FILE PROCESSING
################################################################################

#------------------------------------------------------------------------------
# process_new_file
#
# Processes and uploads a new file to S3
#
# Parameters:
#   $1 - file_path: Full path to local file
#   $2 - s3_path: Destination S3 path
#   $3 - checksum: File checksum
#   $4 - source_dir: Parent directory
#
# Returns:
#   0 - File uploaded and state updated
#   1 - Upload or state update failed
#
# Side Effects:
#   Uploads file to S3
#   Updates directory state with file metadata
#   Increments BACKUP_STATS_FILES_NEW
#
# Example:
#   process_new_file "/mount/project/file.txt" "s3://bucket/current_state/project/file.txt" "abc123" "/mount/project"
#------------------------------------------------------------------------------
process_new_file() {
    local file_path="$1"
    local s3_path="$2"
    local checksum="$3"
    local source_dir="$4"
    
    log DEBUG "Processing new file: $(basename "$file_path")"
    
    # Check dry-run mode
    if [[ "${DRY_RUN}" == "true" ]]; then
        log INFO "[DRY-RUN] Would upload new file: $file_path -> $s3_path"
        ((BACKUP_STATS_FILES_NEW++))
        return 0
    fi
    
    # Upload to S3
    if ! s3_upload "$file_path" "$s3_path" true; then
        log ERROR "Failed to upload new file: $file_path"
        ((BACKUP_STATS_ERRORS++))
        return 1
    fi
    
    log INFO "✓ Uploaded new file: $(basename "$file_path")"
    ((BACKUP_STATS_FILES_NEW++))
    
    # Update state
    local file_size file_mtime filename
    file_size=$(get_file_size "$file_path")
    file_mtime=$(get_file_mtime "$file_path")
    filename=$(basename "$file_path")
    
    BACKUP_STATS_BYTES_UPLOADED=$((BACKUP_STATS_BYTES_UPLOADED + file_size))
    
    update_file_metadata "$source_dir" "$filename" "$checksum" "$file_size" "$file_mtime" || {
        log WARN "File uploaded but state update failed: $filename"
    }
    
    return 0
}

#------------------------------------------------------------------------------
# process_changed_file
#
# Processes a modified file (move old version to yesterday_state/versions_*, 
# upload new to current_state). Old version is preserved as version history.
#
# Parameters:
#   $1 - file_path: Full path to local file
#   $2 - s3_current_path: Current state S3 path
#   $3 - s3_yesterday_path: Yesterday state S3 path (should use versions_* prefix)
#   $4 - checksum: New file checksum
#   $5 - source_dir: Parent directory
#
# Returns:
#   0 - File processed successfully
#   1 - Processing failed
#
# Example:
#   process_changed_file "/mount/project/file.txt" "s3://bucket/current/file.txt" "s3://bucket/yesterday/versions_project/file.txt" "def456" "/mount/project"
#------------------------------------------------------------------------------
process_changed_file() {
    local file_path="$1"
    local s3_current_path="$2"
    local s3_yesterday_path="$3"
    local checksum="$4"
    local source_dir="$5"
    
    log DEBUG "Processing changed file: $(basename "$file_path")"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log INFO "[DRY-RUN] Would move old version to yesterday_state and upload new: $(basename "$file_path")"
        ((BACKUP_STATS_FILES_CHANGED++))
        return 0
    fi
    
    # Move old version to yesterday_state (versions_* for version history)
    if s3_exists "$s3_current_path"; then
        log DEBUG "Moving old version to versions_: $s3_current_path -> $s3_yesterday_path"
        s3_move "$s3_current_path" "$s3_yesterday_path" || {
            log WARN "Failed to move old version to yesterday_state/versions_"
        }
    fi
    
    # Upload new version to current_state
    if ! s3_upload "$file_path" "$s3_current_path" true; then
        log ERROR "Failed to upload changed file: $file_path"
        ((BACKUP_STATS_ERRORS++))
        return 1
    fi
    
    log INFO "✓ Uploaded changed file: $(basename "$file_path")"
    ((BACKUP_STATS_FILES_CHANGED++))
    
    # Update state
    local file_size file_mtime filename
    file_size=$(get_file_size "$file_path")
    file_mtime=$(get_file_mtime "$file_path")
    filename=$(basename "$file_path")
    
    BACKUP_STATS_BYTES_UPLOADED=$((BACKUP_STATS_BYTES_UPLOADED + file_size))
    
    update_file_metadata "$source_dir" "$filename" "$checksum" "$file_size" "$file_mtime"
    
    return 0
}

#------------------------------------------------------------------------------
# process_deleted_file
#
# Processes a deleted file (move to yesterday_state with deleted_ prefix)
#
# Parameters:
#   $1 - file_relative_path: Relative path of deleted file
#   $2 - s3_current_path: Current state S3 path
#   $3 - s3_yesterday_path: Yesterday state S3 path (with deleted_ prefix)
#   $4 - source_dir: Source directory path
#   $5 - dir_state: Previous directory state (for metadata extraction)
#
# Returns:
#   0 - File processed successfully
#   1 - Processing failed
#
# Example:
#   process_deleted_file "code/main.py" "s3://bucket/current/project/code/main.py" "s3://bucket/yesterday/deleted_project/code/main.py" "/mnt/project" "$state"
#------------------------------------------------------------------------------
process_deleted_file() {
    local file_relative_path="$1"
    local s3_current_path="$2"
    local s3_yesterday_path="$3"
    local source_dir="$4"
    local dir_state="$5"
    
    log DEBUG "Processing deleted file: $file_relative_path"
    
    # Extract metadata from previous state
    local checksum size mtime
    if [[ "$dir_state" != "{}" ]]; then
        IFS='|' read -r checksum size mtime < <(
            echo "$dir_state" | jq -r \
                --arg filepath "$file_relative_path" \
                '.metadata[$filepath] | "\(.checksum // "unknown")|\(.size // 0)|\(.mtime // 0)"'
        )
    else
        checksum="unknown"
        size="0"
        mtime="0"
    fi
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log INFO "[DRY-RUN] Would move to yesterday_state: $file_relative_path"
        ((BACKUP_STATS_FILES_DELETED++))
        return 0
    fi
    
    # Move to yesterday_state with deleted_ prefix (file was truly deleted)
    if s3_exists "$s3_current_path"; then
        log DEBUG "Moving deleted file to deleted_: $s3_current_path -> $s3_yesterday_path"
        
        if s3_move "$s3_current_path" "$s3_yesterday_path"; then
            log INFO "✓ Moved deleted file to yesterday_state/deleted_: $file_relative_path"
            ((BACKUP_STATS_FILES_DELETED++))
            
            # Track deletion in yesterday-backup-state.json
            track_file_deletion "$file_relative_path" "$source_dir" "$checksum" "$size" || {
                log WARN "Deletion tracked in S3 but state update failed: $file_relative_path"
            }
            
            # Remove from current state metadata
            remove_file_from_state "$source_dir" "$file_relative_path" || {
                log WARN "Failed to remove deleted file from state: $file_relative_path"
            }
        else
            log ERROR "Failed to move deleted file: $file_relative_path"
            ((BACKUP_STATS_ERRORS++))
            return 1
        fi
    else
        log DEBUG "Deleted file not in S3 (might be new since last backup): $file_relative_path"
        
        # Still remove from state if it was tracked
        if [[ "$dir_state" != "{}" ]]; then
            remove_file_from_state "$source_dir" "$file_relative_path" || {
                log WARN "Failed to remove file from state: $file_relative_path"
            }
        fi
    fi
    
    return 0
}

################################################################################
# PUBLIC API: DIRECTORY BACKUP
################################################################################

#------------------------------------------------------------------------------
# backup_directory
#
# Backs up a single directory in specified mode (shallow or deep)
#
# Parameters:
#   $1 - source_dir: Directory to backup
#   $2 - backup_mode: "shallow" (dir only) or "deep" (recursive)
#
# Returns:
#   0 - Backup successful
#   1 - Backup failed
#
# Workflow:
#   1. Get previous state
#   2. Scan current files
#   3. Compare with previous state
#   4. Upload new/changed files
#   5. Move deleted files to yesterday_state
#   6. Update state
#
# Example:
#   backup_directory "/mount/project1" "deep"
#------------------------------------------------------------------------------
backup_directory() {
    local source_dir="$1"
    local backup_mode="$2"
    
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "Backing up: $source_dir (mode: $backup_mode)"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Debug: Show directory key that will be generated
    local debug_dir_key
    debug_dir_key=$(generate_directory_key "$source_dir") || debug_dir_key="<failed>"
    log DEBUG "Directory state key: $debug_dir_key"
    
    # Validate directory exists
    if [[ ! -d "$source_dir" ]]; then
        log ERROR "Source directory does not exist: $source_dir"
        return 1
    fi
    
    # Build AWS command (matches original pattern)
    local aws_cmd="aws s3"
    [[ -n "$AWS_PROFILE" ]] && aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    [[ -n "$AWS_REGION" ]] && aws_cmd="$aws_cmd --region $AWS_REGION"
    log DEBUG "AWS command: $aws_cmd"
    
    # Build S3 paths
    local s3_path_component
    s3_path_component=$(get_s3_path_component "$source_dir")
    
    local s3_current_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_current_base+="/$S3_PREFIX"
    s3_current_base+="/current_state/"
    [[ -n "$s3_path_component" ]] && s3_current_base+="${s3_path_component}/"
    
    # Build SEPARATE yesterday_state paths for versions vs deletions
    # versions_ = Old versions of modified files (file still exists)
    # deleted_ = Truly deleted files (file no longer exists)
    local s3_yesterday_versions_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_yesterday_versions_base+="/$S3_PREFIX"
    s3_yesterday_versions_base+="/yesterday_state/"
    if [[ -n "$s3_path_component" ]]; then
        s3_yesterday_versions_base+="versions_${s3_path_component}/"
    else
        # Root directory - use explicit "root" component
        s3_yesterday_versions_base+="versions_root/"
    fi
    
    local s3_yesterday_deleted_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_yesterday_deleted_base+="/$S3_PREFIX"
    s3_yesterday_deleted_base+="/yesterday_state/"
    if [[ -n "$s3_path_component" ]]; then
        s3_yesterday_deleted_base+="deleted_${s3_path_component}/"
    else
        # Root directory - use explicit "root" component
        s3_yesterday_deleted_base+="deleted_root/"
    fi
    
    log DEBUG "S3 current: $s3_current_base"
    log DEBUG "S3 yesterday versions: $s3_yesterday_versions_base"
    log DEBUG "S3 yesterday deleted: $s3_yesterday_deleted_base"
    
    # Get previous state for this directory
    local dir_state
    dir_state=$(get_directory_state "$source_dir")
    
    # Debug: Show state loading
    local state_file_count=0
    if [[ "$dir_state" != "{}" ]]; then
        state_file_count=$(echo "$dir_state" | jq '.metadata | length' 2>/dev/null || echo "0")
        log DEBUG "Loaded previous state: $state_file_count files in metadata"
    else
        log DEBUG "No previous state found for: $source_dir"
    fi
    
    # Determine find depth based on backup mode
    local find_maxdepth=""
    case "$backup_mode" in
        shallow)
            find_maxdepth="-maxdepth 1"
            log DEBUG "Shallow mode: backing up directory only (no subdirectories)"
            ;;
        deep-root)
            find_maxdepth="-maxdepth 1"
            log DEBUG "Deep-root mode: backing up files at root level only"
            ;;
        deep-subdir)
            find_maxdepth=""
            log DEBUG "Deep-subdir mode: backing up all files recursively"
            ;;
        *)
            log WARN "Unknown backup mode: $backup_mode, defaulting to shallow"
            find_maxdepth="-maxdepth 1"
            ;;
    esac
    
    # Track files in this directory
    local files_processed=0
    local files_in_dir=()
    
    # Scan current files
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        
        # Get relative path from source_dir - THIS IS NOW THE KEY
        local file_relative_path
        file_relative_path=$(get_relative_path "$file" "$source_dir")
        
        # Track this file (using relative path)
        files_in_dir+=("$file_relative_path")
        
        # Get previous checksum for this file (using relative path as key)
        local previous_checksum=""
        if [[ "$dir_state" != "{}" ]]; then
            previous_checksum=$(echo "$dir_state" | jq -r --arg filepath "$file_relative_path" '.metadata[$filepath].checksum // ""')
            
            # Debug: Show lookup result for first few files
            if [[ -z "$previous_checksum" ]]; then
                log DEBUG "No previous checksum found for: $file_relative_path (treating as new)"
            else
                log DEBUG "Found previous checksum for: $file_relative_path"
            fi
        fi
        
        # Calculate current checksum (with S3 verification to prevent scope expansion bug)
        local current_checksum
        local needs_upload=false
        
        if current_checksum=$(enhanced_metadata_check "$file" "$file_relative_path" "$dir_state"); then
            # File unchanged AND verified in S3, skip upload
            log DEBUG "Unchanged: $file_relative_path (using cached checksum, S3 verified)"
            ((BACKUP_STATS_FILES_UNCHANGED++))
            continue
        else
            # File changed, new, or missing from S3 - calculate checksum
            current_checksum=$(calculate_checksum "$file") || {
                log ERROR "Failed to calculate checksum: $file"
                ((BACKUP_STATS_ERRORS++))
                continue
            }
            
            # Check if this was triggered by missing S3 file (scope expansion bug fix)
            if [[ -n "$previous_checksum" && "$current_checksum" == "$previous_checksum" ]]; then
                # Checksum unchanged BUT metadata check failed
                # This means file is missing from S3 - force upload!
                log DEBUG "SCOPE EXPANSION BUG FIX: Checksum matches but file missing from S3, forcing upload"
                needs_upload=true
            fi
        fi
        
        # Construct S3 paths using full relative path to preserve directory structure
        local s3_current_file="${s3_current_base}${file_relative_path}"
        # For modified files, use versions_ path (will be determined by file status)
        local s3_yesterday_versions_file="${s3_yesterday_versions_base}${file_relative_path}"
        
        # Determine file status and process
        if [[ -z "$previous_checksum" ]] || [[ "$needs_upload" == "true" ]]; then
            # New file OR file missing from S3 (scope expansion bug fix)
            if [[ "$needs_upload" == "true" ]]; then
                log DEBUG "Re-uploading file missing from S3: $file_relative_path"
            else
                log DEBUG "Processing new file: $file_relative_path"
            fi
            
            if [[ "${DRY_RUN}" == "true" ]]; then
                log INFO "[DRY-RUN] Would upload new file: $file_relative_path"
                ((BACKUP_STATS_FILES_NEW++))
            else
                if aws_cmd_safe $aws_cmd cp "$file" "$s3_current_file" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                    log INFO "✓ Uploaded new file: $file_relative_path"
                    ((BACKUP_STATS_FILES_NEW++))
                    
                    # Update state (using relative path as key)
                    local file_size file_mtime
                    file_size=$(get_file_size "$file")
                    file_mtime=$(get_file_mtime "$file")
                    BACKUP_STATS_BYTES_UPLOADED=$((BACKUP_STATS_BYTES_UPLOADED + file_size))
                    
                    update_file_metadata "$source_dir" "$file_relative_path" "$current_checksum" "$file_size" "$file_mtime"
                else
                    log ERROR "Failed to upload new file: $file_relative_path"
                    ((BACKUP_STATS_ERRORS++))
                fi
            fi
            
        elif [[ "$current_checksum" != "$previous_checksum" ]]; then
            # Changed file - move old version to versions_ folder (not deleted!)
            log DEBUG "Processing changed file: $file_relative_path"
            
            if [[ "${DRY_RUN}" == "true" ]]; then
                log INFO "[DRY-RUN] Would update changed file: $file_relative_path"
                ((BACKUP_STATS_FILES_CHANGED++))
            else
                # Move old version to yesterday_state/versions_* (file still exists, just modified)
                # Use s3_move with proper error checking (atomic operation, cost-efficient)
                if s3_exists "$s3_current_file"; then
                    log DEBUG "Moving old version to versions_: $s3_current_file -> $s3_yesterday_versions_file"
                    if ! s3_move "$s3_current_file" "$s3_yesterday_versions_file"; then
                        log ERROR "Failed to preserve old version to versions_, aborting file update: $file_relative_path"
                        ((BACKUP_STATS_ERRORS++))
                        continue  # Skip to next file, don't overwrite if we couldn't preserve old version
                    fi
                fi
                
                # Upload new version (only if old version successfully preserved)
                if aws_cmd_safe $aws_cmd cp "$file" "$s3_current_file" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                    log INFO "✓ Uploaded changed file: $file_relative_path"
                    ((BACKUP_STATS_FILES_CHANGED++))
                    
                    # Update state (using relative path as key)
                    local file_size file_mtime
                    file_size=$(get_file_size "$file")
                    file_mtime=$(get_file_mtime "$file")
                    BACKUP_STATS_BYTES_UPLOADED=$((BACKUP_STATS_BYTES_UPLOADED + file_size))
                    
                    update_file_metadata "$source_dir" "$file_relative_path" "$current_checksum" "$file_size" "$file_mtime"
                else
                    log ERROR "Failed to upload changed file: $file_relative_path"
                    ((BACKUP_STATS_ERRORS++))
                fi
            fi
            
        else
            # Unchanged (but metadata differed, so checksum was recalculated)
            log DEBUG "Unchanged after checksum: $file_relative_path"
            ((BACKUP_STATS_FILES_UNCHANGED++))
        fi
        
        ((files_processed++))
        
    done < <(find "$source_dir" $find_maxdepth -type f -print0 2>/dev/null)
    
    log INFO "Processed $files_processed files in $source_dir"
    
    # Detect deleted files (in previous state but not in current scan)
    if [[ "$dir_state" != "{}" ]]; then
        local previous_files
        previous_files=$(echo "$dir_state" | jq -r '.metadata | keys[]' 2>/dev/null)
        
        while IFS= read -r prev_filename; do
            [[ -z "$prev_filename" ]] && continue
            
            # Check if file still exists in current scan
            local still_exists=false
            for current_file in "${files_in_dir[@]}"; do
                if [[ "$current_file" == "$prev_filename" ]]; then
                    still_exists=true
                    break
                fi
            done
            
            if [[ "$still_exists" == false ]]; then
                # File was deleted - use deleted_ prefix (file no longer exists)
                local s3_current_file="${s3_current_base}${prev_filename}"
                local s3_yesterday_deleted_file="${s3_yesterday_deleted_base}${prev_filename}"
                
                log DEBUG "File deleted, will move to deleted_: $prev_filename"
                process_deleted_file "$prev_filename" "$s3_current_file" "$s3_yesterday_deleted_file" "$source_dir" "$dir_state"
            fi
        done <<< "$previous_files"
    fi
    
    log INFO "✅ Directory backup complete: $source_dir"
    return 0
}

################################################################################
# PUBLIC API: MAIN WORKFLOW
################################################################################

#------------------------------------------------------------------------------
# run_backup_workflow
#
# Main backup workflow - orchestrates entire backup process
#
# Parameters:
#   None (uses global configuration)
#
# Returns:
#   0 - Backup completed successfully
#   1 - Backup failed
#
# Workflow:
#   1. Find directories to backup
#   2. Backup each directory (can be parallelized)
#   3. Build aggregate state
#   4. Print summary
#
# Example:
#   if run_backup_workflow; then
#       echo "Backup successful"
#   fi
#------------------------------------------------------------------------------
run_backup_workflow() {
    log INFO "╔══════════════════════════════════════════════════════════════════╗"
    log INFO "║           STARTING BACKUP WORKFLOW                               ║"
    log INFO "╚══════════════════════════════════════════════════════════════════╝"
    log INFO ""
    
    local start_time=$(date +%s)
    
    # Load S3 cache for scope expansion bug prevention (if available)
    log INFO "Loading S3 cache for verification..."
    if load_s3_cache; then
        log INFO "✅ S3 cache loaded - scope expansion bug prevention active"
    else
        log WARN "S3 cache not available - using metadata-only verification"
        log WARN "  Note: Run scripts/s3-inspect.sh to generate cache for better verification"
    fi
    log INFO ""
    
    # Find directories to backup
    log INFO "Step 1: Discovering directories with backup triggers..."
    local trigger_directories
    if ! trigger_directories=$(find_backup_directories); then
        log ERROR "No directories found to backup"
        return 1
    fi
    
    log INFO "Step 2: Expanding deep-mode directories for per-subdirectory state..."
    local backup_directories
    if ! backup_directories=$(echo "$trigger_directories" | expand_deep_directories); then
        log ERROR "Failed to expand directories"
        return 1
    fi
    
    # Count directories
    local dir_count
    dir_count=$(echo "$backup_directories" | wc -l)
    log INFO "✅ Total directories to backup (after expansion): $dir_count"
    log INFO ""
    
    # Backup each directory
    log INFO "Step 3: Backing up directories..."
    local successful_backups=0
    local failed_backups=0
    
    while IFS= read -r dir_with_mode; do
        [[ -z "$dir_with_mode" ]] && continue
        
        # Parse dir:mode format
        if [[ "$dir_with_mode" =~ ^(.+):([^:]+)$ ]]; then
            local dir="${BASH_REMATCH[1]}"
            local mode="${BASH_REMATCH[2]}"
        else
            log ERROR "Invalid directory format: $dir_with_mode"
            continue
        fi
        
        # Backup directory
        if backup_directory "$dir" "$mode"; then
            ((successful_backups++))
        else
            ((failed_backups++))
        fi
        
        log INFO ""
        
    done <<< "$backup_directories"
    
    # Detect deleted directories (state files exist but directories don't)
    log INFO "Step 4: Detecting deleted directories..."
    if detect_deleted_directories; then
        log INFO "✅ Deleted directory detection complete"
    else
        log WARN "Deleted directory detection had errors"
    fi
    log INFO ""
    
    # Build aggregate state from individual directory states
    log INFO "Step 5: Building aggregate state..."
    if build_aggregate_state; then
        log INFO "✅ Aggregate state built successfully"
    else
        log WARN "Failed to build aggregate state"
    fi
    log INFO ""
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Print summary
    print_backup_summary "$duration"
    
    # Update S3 cache after successful backup (if not in dry-run mode)
    if [[ "${DRY_RUN:-false}" != "true" ]] && [[ $failed_backups -eq 0 ]] && [[ $BACKUP_STATS_ERRORS -eq 0 ]]; then
        log INFO ""
        log INFO "Updating S3 cache for future verification..."
        if update_s3_cache; then
            log INFO "✅ S3 cache updated successfully"
        else
            log WARN "⚠️  S3 cache update failed - future backups will use existing cache or metadata-only verification"
        fi
    fi
    
    # Return status
    if [[ $failed_backups -gt 0 ]] || [[ $BACKUP_STATS_ERRORS -gt 0 ]]; then
        log ERROR "Backup completed with errors"
        return 1
    else
        log INFO "✅ Backup completed successfully"
        return 0
    fi
}

################################################################################
# PUBLIC API: DIRECTORY DELETION DETECTION
################################################################################

#------------------------------------------------------------------------------
# detect_deleted_directories
#
# Detects directories that have state files but no longer exist in filesystem
# This indicates the entire directory was deleted
#
# Parameters:
#   None
#
# Returns:
#   0 - Detection completed (may or may not find deleted directories)
#   1 - Detection failed
#
# Side Effects:
#   Calls track_directory_deletion() for each deleted directory
#   Moves all directory files to yesterday_state in S3
#
# Example:
#   detect_deleted_directories
#------------------------------------------------------------------------------
detect_deleted_directories() {
    log INFO "Detecting deleted directories..."
    
    local deleted_count=0
    local checked_count=0
    
    # Iterate through all directory state files
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
        
        # Check if directory still exists
        if [[ ! -d "$dir_path" ]]; then
            log WARN "Directory deleted: $dir_path"
            
            # Load directory state for metadata
            local dir_state
            dir_state=$(cat "$state_file" 2>/dev/null || echo "{}")
            
            # Track directory deletion with comprehensive metadata
            if track_directory_deletion "$dir_path" "$dir_state"; then
                ((deleted_count++))
                
                # Move all files from current_state to yesterday_state in S3
                move_deleted_directory_to_s3 "$dir_path" "$dir_state" || {
                    log ERROR "Failed to move deleted directory files to S3: $dir_path"
                }
            else
                log ERROR "Failed to track directory deletion: $dir_path"
            fi
        fi
    done
    
    if [[ $deleted_count -gt 0 ]]; then
        log INFO "✅ Detected and tracked $deleted_count deleted directories (checked $checked_count state files)"
    else
        log DEBUG "No deleted directories found (checked $checked_count state files)"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# move_deleted_directory_to_s3
#
# Moves all files from a deleted directory to yesterday_state in S3
#
# Parameters:
#   $1 - dir_path: Directory path that was deleted
#   $2 - dir_state: Previous directory state
#
# Returns:
#   0 - Files moved successfully
#   1 - Move failed
#------------------------------------------------------------------------------
move_deleted_directory_to_s3() {
    local dir_path="$1"
    local dir_state="$2"
    
    log DEBUG "Moving deleted directory files to S3: $dir_path"
    
    # Build S3 paths
    local s3_path_component
    s3_path_component=$(get_s3_path_component "$dir_path")
    
    local s3_current_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_current_base+="/$S3_PREFIX"
    s3_current_base+="/current_state/"
    [[ -n "$s3_path_component" ]] && s3_current_base+="${s3_path_component}/"
    
    local s3_yesterday_base="s3://$S3_BUCKET"
    [[ -n "$S3_PREFIX" ]] && s3_yesterday_base+="/$S3_PREFIX"
    s3_yesterday_base+="/yesterday_state/"
    [[ -n "$s3_path_component" ]] && s3_yesterday_base+="deleted_${s3_path_component}/"
    
    # Get list of files from state
    local file_list
    file_list=$(echo "$dir_state" | jq -r '.metadata | keys[]' 2>/dev/null)
    
    local moved_count=0
    local failed_count=0
    
    while IFS= read -r file_relative_path; do
        [[ -z "$file_relative_path" ]] && continue
        
        local s3_current_file="${s3_current_base}${file_relative_path}"
        local s3_yesterday_file="${s3_yesterday_base}${file_relative_path}"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            log DEBUG "[DRY-RUN] Would move: $file_relative_path"
            ((moved_count++))
        else
            if s3_exists "$s3_current_file"; then
                if s3_move "$s3_current_file" "$s3_yesterday_file"; then
                    log DEBUG "Moved deleted directory file: $file_relative_path"
                    ((moved_count++))
                else
                    log WARN "Failed to move deleted directory file: $file_relative_path"
                    ((failed_count++))
                fi
            else
                log DEBUG "File not in S3: $file_relative_path"
            fi
        fi
    done <<< "$file_list"
    
    log INFO "Moved $moved_count files from deleted directory to yesterday_state ($failed_count failures)"
    
    return 0
}

################################################################################
# PUBLIC API: S3 CACHE MANAGEMENT
################################################################################

#------------------------------------------------------------------------------
# update_s3_cache
#
# Updates S3 cache by running s3-inspect.sh after successful backup
# This prevents "backup scope expansion bug" by maintaining accurate S3 state
#
# Parameters:
#   None
#
# Returns:
#   0 - Cache updated successfully
#   1 - Cache update failed (non-fatal)
#
# Example:
#   if update_s3_cache; then
#       echo "Cache refreshed"
#   fi
#------------------------------------------------------------------------------
update_s3_cache() {
    local s3_inspect_script="${SCRIPT_DIR}/scripts/s3-inspect.sh"
    
    # Check if s3-inspect.sh exists
    if [[ ! -f "$s3_inspect_script" ]]; then
        log WARN "s3-inspect.sh not found: $s3_inspect_script - cache update skipped"
        return 1
    fi
    
    # Make executable if needed
    if [[ ! -x "$s3_inspect_script" ]]; then
        chmod +x "$s3_inspect_script" 2>/dev/null || {
            log WARN "Cannot make s3-inspect.sh executable - cache update skipped"
            return 1
        }
    fi
    
    log DEBUG "Running s3-inspect.sh to update cache..."
    log DEBUG "Using same configuration as backup:"
    log DEBUG "  CONFIG_FILE: ${CONFIG_FILE}"
    log DEBUG "  S3_BUCKET: ${S3_BUCKET}"
    log DEBUG "  S3_PREFIX: ${S3_PREFIX:-<empty>}"
    log DEBUG "  AWS_REGION: ${AWS_REGION}"
    log DEBUG "  AWS_PROFILE: ${AWS_PROFILE:-<not set>}"
    
    # Debug: Show AWS credentials availability
    log DEBUG "AWS credentials check:"
    log DEBUG "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:+<set (${#AWS_ACCESS_KEY_ID} chars)>}${AWS_ACCESS_KEY_ID:-<not set>}"
    log DEBUG "  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:+<set (${#AWS_SECRET_ACCESS_KEY} chars)>}${AWS_SECRET_ACCESS_KEY:-<not set>}"
    log DEBUG "  AWS_SESSION_TOKEN: ${AWS_SESSION_TOKEN:+<set>}${AWS_SESSION_TOKEN:-<not set>}"
    
    # Export AWS credentials so s3-inspect.sh subprocess inherits them
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
    [[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION
    
    # Create temporary log file to capture s3-inspect output
    local temp_log=$(mktemp)
    
    # Pass the same config file that backup.sh is using
    # This ensures 100% consistency without relying on environment variable inheritance
    if "$s3_inspect_script" --cache-only --config "$CONFIG_FILE" >"$temp_log" 2>&1; then
        log DEBUG "S3 cache updated successfully"
        rm -f "$temp_log"
        return 0
    else
        local inspect_exit_code=$?
        log ERROR "S3 cache update failed (exit code: $inspect_exit_code)"
        log ERROR "s3-inspect.sh output:"
        while IFS= read -r line; do
            log ERROR "  $line"
        done < "$temp_log"
        log ERROR "Check: ${SCRIPT_DIR}/scripts/s3-inspect.log for details"
        rm -f "$temp_log"
        return 1
    fi
}

#------------------------------------------------------------------------------
# generate_detailed_s3_report
#
# Generates detailed S3 report by running s3-inspect.sh in report-only mode
# Uses --report-only flag to avoid regenerating cache (already updated)
#
# Called once at the very end of backup if DETAILED_S3_REPORT=true
# Performs fresh S3 scan to ensure report reflects final state after cleanup
#
# Parameters:
#   None (uses global configuration)
#
# Returns:
#   0 - Report generated successfully
#   1 - Report generation failed (non-critical, backup still succeeded)
#
# Example:
#   if generate_detailed_s3_report; then
#       echo "Report ready at state/s3/s3-report.json"
#   fi
#------------------------------------------------------------------------------
generate_detailed_s3_report() {
    local s3_inspect_script="${SCRIPT_DIR}/scripts/s3-inspect.sh"
    
    # Check if s3-inspect.sh exists
    if [[ ! -f "$s3_inspect_script" ]]; then
        log WARN "s3-inspect.sh not found: $s3_inspect_script - report generation skipped"
        return 1
    fi
    
    # Make executable if needed
    if [[ ! -x "$s3_inspect_script" ]]; then
        chmod +x "$s3_inspect_script" 2>/dev/null || {
            log WARN "Cannot make s3-inspect.sh executable - report generation skipped"
            return 1
        }
    fi
    
    log DEBUG "Running s3-inspect.sh to generate detailed report (report-only mode)..."
    log DEBUG "Configuration: S3_BUCKET=${S3_BUCKET}, S3_PREFIX=${S3_PREFIX:-<empty>}"
    
    # Export AWS credentials so s3-inspect.sh subprocess inherits them
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
    [[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION
    
    # Create temporary log file to capture output
    local temp_log=$(mktemp)
    
    # Run s3-inspect.sh with --report-only flag
    # This scans S3 and generates report WITHOUT touching s3-cache.json
    if "$s3_inspect_script" --report-only --config "$CONFIG_FILE" >"$temp_log" 2>&1; then
        log DEBUG "Detailed S3 report generated successfully"
        rm -f "$temp_log"
        return 0
    else
        local inspect_exit_code=$?
        log WARN "S3 report generation failed (exit code: $inspect_exit_code)"
        log WARN "This is not critical - backup was successful"
        log DEBUG "s3-inspect.sh output:"
        while IFS= read -r line; do
            log DEBUG "  $line"
        done < "$temp_log"
        rm -f "$temp_log"
        return 1
    fi
}

################################################################################
# PUBLIC API: STATISTICS
################################################################################

#------------------------------------------------------------------------------
# print_backup_summary
#
# Prints comprehensive backup summary with statistics
#
# Parameters:
#   $1 - duration: Backup duration in seconds
#
# Returns:
#   0 - Always succeeds
#
# Example:
#   print_backup_summary 120  # Print summary for 2-minute backup
#------------------------------------------------------------------------------
print_backup_summary() {
    local duration="${1:-0}"
    
    log INFO "╔══════════════════════════════════════════════════════════════════╗"
    log INFO "║              BACKUP SUMMARY                                      ║"
    log INFO "╚══════════════════════════════════════════════════════════════════╝"
    log INFO ""
    log INFO "File Statistics:"
    log INFO "  New files:       $BACKUP_STATS_FILES_NEW"
    log INFO "  Changed files:   $BACKUP_STATS_FILES_CHANGED"
    log INFO "  Deleted files:   $BACKUP_STATS_FILES_DELETED"
    log INFO "  Unchanged files: $BACKUP_STATS_FILES_UNCHANGED"
    log INFO "  Errors:          $BACKUP_STATS_ERRORS"
    log INFO ""
    log INFO "Data Transfer:"
    log INFO "  Bytes uploaded:  $(bytes_to_human $BACKUP_STATS_BYTES_UPLOADED)"
    log INFO ""
    log INFO "Performance:"
    log INFO "  Duration:        ${duration}s"
    
    if [[ $duration -gt 0 ]]; then
        local total_files=$((BACKUP_STATS_FILES_NEW + BACKUP_STATS_FILES_CHANGED))
        if [[ $total_files -gt 0 ]]; then
            local files_per_sec
            files_per_sec=$(echo "scale=2; $total_files / $duration" | bc 2>/dev/null || echo "N/A")
            log INFO "  Files/second:    $files_per_sec"
        fi
    fi
    
    log INFO ""
    log INFO "Mode: ${DRY_RUN:-false}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log INFO ""
        log INFO "⚠️  DRY-RUN MODE - No changes were made"
    fi
    
    log INFO ""
    
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f process_new_file process_changed_file process_deleted_file
readonly -f backup_directory run_backup_workflow
readonly -f detect_deleted_directories move_deleted_directory_to_s3
readonly -f update_s3_cache print_backup_summary

log DEBUG "Module loaded: $BACKUP_MODULE_NAME v$BACKUP_MODULE_VERSION (API v$BACKUP_API_VERSION)"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_backup() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "process_new_file" "process_changed_file" "process_deleted_file"
        "backup_directory" "run_backup_workflow"
        "detect_deleted_directories" "move_deleted_directory_to_s3"
        "update_s3_cache" "print_backup_summary"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $BACKUP_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check critical dependencies are loaded
    for func in "find_backup_directories" "s3_upload" "calculate_checksum" "get_directory_state"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $BACKUP_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_backup || die "Module validation failed: $BACKUP_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

