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
# state.sh - State Management Module with Smart Locking
################################################################################
# Purpose: Manages JSON state files for backup tracking. Uses separate state
#          files per directory to enable parallel operations while preventing
#          race conditions. This design allows 10+ directories to be backed up
#          simultaneously with zero lock contention.
#
# Dependencies: core.sh, utils.sh
#
# Architecture:
#   state/
#     ├── current/               # Per-directory working state (enables parallelization)
#     │   ├── cHJvamVjdC1hbHBoYQ.state.json
#     │   └── cHJvamVjdC1iZXRh.state.json
#     ├── high-level/            # System-wide aggregate & audit files
#     │   ├── backup-state.json
#     │   ├── yesterday-backup-state.json
#     │   ├── permanent-deletions-history.json
#     │   └── directory-state.json
#     ├── s3/                    # S3 verification & reporting
#     │   ├── s3-cache.json
#     │   └── s3-report.json
#     └── .locks/                # Per-directory lock files
#
# Public API:
#   State File Management:
#   - init_state_files()          : Initialize all state files
#   - get_directory_state_file()  : Get path to directory's state file
#   - build_aggregate_state()     : Build aggregate from individual states
#
#   Locking (Per-Directory for Parallelization):
#   - acquire_directory_lock()    : Lock specific directory
#   - release_directory_lock()    : Release directory lock
#
#   State Operations:
#   - get_directory_state()       : Read directory state
#   - update_directory_state()    : Update directory state (with locking)
#   - update_file_metadata()      : Update file metadata in directory
#
#   Key Generation:
#   - generate_directory_key()    : Create consistent directory key
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly STATE_MODULE_VERSION="1.0.0"
readonly STATE_MODULE_NAME="state"
readonly STATE_MODULE_DEPS=("core" "utils")
readonly STATE_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${STATE_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: state.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# STATE FILE PATHS
################################################################################

# Main state directory structure
readonly STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/state}"
readonly CURRENT_STATE_DIR="${STATE_DIR}/current"           # Per-directory working states
readonly HIGH_LEVEL_STATE_DIR="${STATE_DIR}/high-level"     # Aggregate & audit files
readonly S3_STATE_DIR="${STATE_DIR}/s3"                     # S3 verification & reporting
readonly LOCKS_DIR="${STATE_DIR}/.locks"                    # Lock files

# High-level state files (system-wide views)
readonly AGGREGATE_STATE_FILE="${STATE_FILE:-${HIGH_LEVEL_STATE_DIR}/backup-state.json}"
readonly YESTERDAY_STATE_FILE="${YESTERDAY_BACKUP_STATE_FILE:-${HIGH_LEVEL_STATE_DIR}/yesterday-backup-state.json}"
readonly PERMANENT_DELETIONS_FILE="${PERMANENT_DELETIONS_HISTORY_FILE:-${HIGH_LEVEL_STATE_DIR}/permanent-deletions-history.json}"
readonly DIRECTORY_STATE_FILE="${DIRECTORY_STATE_FILE:-${HIGH_LEVEL_STATE_DIR}/directory-state.json}"

################################################################################
# STATE FILE INITIALIZATION
################################################################################

# Ensure state directories exist
mkdir -p "$STATE_DIR" "$CURRENT_STATE_DIR" "$HIGH_LEVEL_STATE_DIR" "$S3_STATE_DIR" "$LOCKS_DIR" 2>/dev/null || true

################################################################################
# PUBLIC API: KEY GENERATION
################################################################################

#------------------------------------------------------------------------------
# generate_directory_key
#
# Generates consistent, collision-free key for directory using URL-safe base64
#
# Parameters:
#   $1 - dir_path: Directory path
#
# Returns:
#   0 - Success, key printed to stdout
#   1 - Failed to generate key
#
# Output:
#   URL-safe base64 encoded key (no +/= characters)
#
# Example:
#   key=$(generate_directory_key "/mount/project1")
#   # Returns: L21vdW50L3Byb2plY3Qx
#------------------------------------------------------------------------------
generate_directory_key() {
    local dir_path="$1"
    
    if [[ -z "$dir_path" ]]; then
        log ERROR "generate_directory_key: dir_path required"
        return 1
    fi
    
    # Use safe base64 encoding (portable, URL-safe)
    safe_base64_encode_url "$dir_path"
}

################################################################################
# PUBLIC API: DIRECTORY LOCKING (Fine-Grained for Parallelization)
################################################################################

#------------------------------------------------------------------------------
# acquire_directory_lock
#
# Acquires exclusive lock for specific directory's state file
# PERFORMANCE: Multiple directories can acquire locks simultaneously!
#
# Parameters:
#   $1 - directory_key: Unique directory identifier
#   $2 - timeout: Lock timeout in seconds (optional, default: 300)
#
# Returns:
#   0 - Lock acquired
#   1 - Failed to acquire lock (timeout or error)
#
# Side Effects:
#   Opens file descriptor 200 for lock file
#
# Performance Note:
#   This is fine-grained locking - each directory locks independently.
#   10 directories = 10 parallel processes with zero contention!
#
# Example:
#   if acquire_directory_lock "$dir_key" 60; then
#       # Update state
#       release_directory_lock "$dir_key"
#   fi
#------------------------------------------------------------------------------
acquire_directory_lock() {
    local directory_key="$1"
    local timeout="${2:-300}"
    
    if [[ -z "$directory_key" ]]; then
        log ERROR "acquire_directory_lock: directory_key required"
        return 1
    fi
    
    local lock_file="${LOCKS_DIR}/${directory_key}.lock"
    
    # Ensure locks directory exists
    mkdir -p "$LOCKS_DIR" 2>/dev/null || true
    
    # Open file descriptor 200 for this lock
    eval "exec 200>'$lock_file'" 2>/dev/null || {
        log ERROR "Failed to open lock file: $lock_file"
        return 1
    }
    
    # Try to acquire lock with timeout
    local elapsed=0
    while ! flock -n 200 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log ERROR "Failed to acquire lock for $directory_key after ${timeout}s"
            log ERROR "Another process may be backing up this directory"
            return 1
        fi
        
        # Log warning every 30 seconds
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            log WARN "Waiting for lock on $directory_key (${elapsed}s elapsed)"
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    log DEBUG "Lock acquired for directory: $directory_key (waited ${elapsed}s)"
    return 0
}

#------------------------------------------------------------------------------
# release_directory_lock
#
# Releases directory-specific lock
#
# Parameters:
#   $1 - directory_key: Unique directory identifier
#
# Returns:
#   0 - Always succeeds (safe to call even if not locked)
#
# Example:
#   release_directory_lock "$dir_key"
#------------------------------------------------------------------------------
release_directory_lock() {
    local directory_key="$1"
    
    # Release file descriptor 200 (safe if not locked)
    flock -u 200 2>/dev/null || true
    
    log DEBUG "Lock released for directory: $directory_key"
    return 0
}

################################################################################
# PUBLIC API: STATE FILE PATH MANAGEMENT
################################################################################

#------------------------------------------------------------------------------
# get_directory_state_file
#
# Gets the state file path for a specific directory
# Each directory has its own state file for maximum parallelization
#
# Parameters:
#   $1 - directory_key: Unique directory identifier
#
# Returns:
#   0 - Success, path printed to stdout
#
# Output:
#   Path to directory's state file
#
# Example:
#   state_file=$(get_directory_state_file "$dir_key")
#   cat "$state_file"
#------------------------------------------------------------------------------
get_directory_state_file() {
    local directory_key="$1"
    
    if [[ -z "$directory_key" ]]; then
        log ERROR "get_directory_state_file: directory_key required"
        return 1
    fi
    
    echo "${CURRENT_STATE_DIR}/${directory_key}.state.json"
    return 0
}

################################################################################
# PUBLIC API: STATE FILE OPERATIONS
################################################################################

#------------------------------------------------------------------------------
# get_directory_state
#
# Reads the complete state for a directory
#
# Parameters:
#   $1 - source_dir: Full path to directory
#
# Returns:
#   0 - Success, state JSON printed to stdout
#   1 - Directory not found or error
#
# Output:
#   JSON object with directory state, or {} if not found
#
# Example:
#   state=$(get_directory_state "/mount/project1")
#   files=$(echo "$state" | jq '.files')
#------------------------------------------------------------------------------
get_directory_state() {
    local source_dir="$1"
    
    if [[ -z "$source_dir" ]]; then
        echo "{}"
        return 0
    fi
    
    # Generate directory key
    local dir_key
    dir_key=$(generate_directory_key "$source_dir") || {
        log ERROR "Failed to generate directory key for: $source_dir"
        echo "{}"
        return 1
    }
    
    # Get state file path
    local state_file
    state_file=$(get_directory_state_file "$dir_key")
    
    # Debug: Show what we're looking for
    log DEBUG "get_directory_state: Looking for state file: $state_file"
    log DEBUG "get_directory_state: File exists check: $(test -f "$state_file" && echo "YES" || echo "NO")"
    
    # Return state if file exists, empty object otherwise
    if [[ -f "$state_file" ]]; then
        log DEBUG "get_directory_state: Reading state file for: $source_dir"
        cat "$state_file" 2>/dev/null || echo "{}"
    else
        log DEBUG "get_directory_state: State file not found: $state_file"
        echo "{}"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# update_directory_state
#
# Updates state for a specific directory with fine-grained locking
# PERFORMANCE: Multiple directories can update simultaneously!
#
# Parameters:
#   $1 - source_dir: Full path to directory
#   $2 - updates: JSON object with updates to merge
#
# Returns:
#   0 - Update successful
#   1 - Update failed
#
# Side Effects:
#   Acquires and releases directory lock
#   Updates directory's state file atomically
#
# Example:
#   updates='{"last_backup": "2025-10-02T14:30:00Z"}'
#   update_directory_state "/mount/project1" "$updates"
#------------------------------------------------------------------------------
update_directory_state() {
    local source_dir="$1"
    local updates="$2"
    
    # Validate inputs
    if [[ -z "$source_dir" ]] || [[ -z "$updates" ]]; then
        log ERROR "update_directory_state: source_dir and updates required"
        return 1
    fi
    
    # Validate updates is valid JSON
    if ! echo "$updates" | jq . >/dev/null 2>&1; then
        log ERROR "update_directory_state: updates is not valid JSON"
        return 1
    fi
    
    # Generate directory key
    local dir_key
    dir_key=$(generate_directory_key "$source_dir") || {
        log ERROR "Failed to generate directory key for: $source_dir"
        return 1
    }
    
    # Get state file path
    local state_file
    state_file=$(get_directory_state_file "$dir_key")
    
    # Acquire lock for THIS directory only
    if ! acquire_directory_lock "$dir_key" 120; then
        log ERROR "Failed to acquire lock for directory: $source_dir"
        return 1
    fi
    
    # Initialize state file if doesn't exist
    if [[ ! -f "$state_file" ]]; then
        jq -n \
            --arg dir "$source_dir" \
            --arg timestamp "$(get_iso8601_timestamp)" \
            '{
                directory_path: $dir,
                last_updated: $timestamp,
                files: {},
                metadata: {}
            }' > "$state_file"
    fi
    
    # Update atomically (temp + move)
    local temp_file
    temp_file=$(mktemp "${state_file}.XXXXXX") || {
        log ERROR "Failed to create temp file for state update"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Merge updates into state (deep merge with * operator)
    jq --argjson updates "$updates" \
       --arg timestamp "$(get_iso8601_timestamp)" \
       '.last_updated = $timestamp | . * $updates' \
       "$state_file" > "$temp_file" || {
        log ERROR "Failed to update state with jq"
        rm -f "$temp_file"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Atomic replace
    mv "$temp_file" "$state_file" || {
        log ERROR "Failed to replace state file"
        rm -f "$temp_file"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Release lock
    release_directory_lock "$dir_key"
    
    log DEBUG "Updated state for directory: $source_dir"
    return 0
}

#------------------------------------------------------------------------------
# update_file_metadata
#
# Updates metadata for a single file in directory's state
#
# Parameters:
#   $1 - source_dir: Directory path
#   $2 - file_relative_path: Relative path from source_dir (e.g., "code/main.py")
#   $3 - checksum: File checksum
#   $4 - file_size: File size in bytes
#   $5 - file_mtime: File modification time (Unix timestamp)
#
# Returns:
#   0 - Metadata updated
#   1 - Update failed
#
# Example:
#   update_file_metadata "/mount/project1" "code/main.py" "abc123" "1024" "1696262400"
#------------------------------------------------------------------------------
update_file_metadata() {
    local source_dir="$1"
    local filename="$2"
    local checksum="$3"
    local file_size="$4"
    local file_mtime="$5"
    
    # Validate inputs
    if [[ -z "$source_dir" ]] || [[ -z "$filename" ]] || [[ -z "$checksum" ]]; then
        log ERROR "update_file_metadata: Missing required parameters"
        return 1
    fi
    
    if ! is_numeric "$file_size" || ! is_numeric "$file_mtime"; then
        log ERROR "update_file_metadata: size and mtime must be numeric"
        return 1
    fi
    
    # Build updates JSON
    local updates
    updates=$(jq -n \
        --arg filename "$filename" \
        --arg checksum "$checksum" \
        --argjson size "$file_size" \
        --argjson mtime "$file_mtime" \
        '{
            metadata: {
                ($filename): {
                    checksum: $checksum,
                    size: $size,
                    mtime: $mtime
                }
            }
        }')
    
    # Update using main function (handles locking)
    update_directory_state "$source_dir" "$updates"
}

#------------------------------------------------------------------------------
# remove_file_from_state
#
# Removes a file from directory's state metadata
#
# Parameters:
#   $1 - source_dir: Directory path
#   $2 - file_relative_path: Relative path of file to remove
#
# Returns:
#   0 - File removed from state
#   1 - Removal failed
#
# Example:
#   remove_file_from_state "/mount/project1" "code/main.py"
#------------------------------------------------------------------------------
remove_file_from_state() {
    local source_dir="$1"
    local file_relative_path="$2"
    
    # Validate inputs
    if [[ -z "$source_dir" ]] || [[ -z "$file_relative_path" ]]; then
        log ERROR "remove_file_from_state: source_dir and file_relative_path required"
        return 1
    fi
    
    # Generate directory key
    local dir_key
    dir_key=$(generate_directory_key "$source_dir") || {
        log ERROR "Failed to generate directory key for: $source_dir"
        return 1
    }
    
    # Get state file path
    local state_file
    state_file=$(get_directory_state_file "$dir_key")
    
    # Check if state file exists
    if [[ ! -f "$state_file" ]]; then
        log DEBUG "State file doesn't exist, nothing to remove: $state_file"
        return 0
    fi
    
    # Acquire lock for THIS directory only
    if ! acquire_directory_lock "$dir_key" 120; then
        log ERROR "Failed to acquire lock for directory: $source_dir"
        return 1
    fi
    
    # Update atomically (temp + move)
    local temp_file
    temp_file=$(mktemp "${state_file}.XXXXXX") || {
        log ERROR "Failed to create temp file for state update"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Remove file from metadata
    jq --arg filepath "$file_relative_path" \
       --arg timestamp "$(get_iso8601_timestamp)" \
       '.last_updated = $timestamp | del(.metadata[$filepath])' \
       "$state_file" > "$temp_file" || {
        log ERROR "Failed to remove file from state with jq"
        rm -f "$temp_file"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Atomic replace
    mv "$temp_file" "$state_file" || {
        log ERROR "Failed to replace state file"
        rm -f "$temp_file"
        release_directory_lock "$dir_key"
        return 1
    }
    
    # Release lock
    release_directory_lock "$dir_key"
    
    log DEBUG "Removed file from state: $file_relative_path"
    return 0
}

#------------------------------------------------------------------------------
# build_aggregate_state
#
# Builds aggregate backup-state.json from all directory state files
# Called ONCE after all parallel backups complete
#
# Parameters:
#   None
#
# Returns:
#   0 - Aggregate built successfully
#   1 - Build failed
#
# Performance:
#   Processes 100 directories in ~1 second
#   Non-blocking (no locks needed during aggregation)
#
# Example:
#   build_aggregate_state  # Call after all backups complete
#------------------------------------------------------------------------------
build_aggregate_state() {
    log INFO "Building aggregate state from individual directory states..."
    
    local aggregate_file="$AGGREGATE_STATE_FILE"
    local temp_aggregate
    temp_aggregate=$(mktemp) || {
        log ERROR "Failed to create temp file for aggregate state"
        return 1
    }
    
    # Start with metadata
    jq -n \
        --arg version "2.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg mount_dir "${MOUNT_DIR:-/mount}" \
        '{
            state_file_version: $version,
            last_updated: $timestamp,
            filesystem_scan_timestamp: $timestamp,
            mount_directory: $mount_dir,
            filesystem_map: {}
        }' > "$temp_aggregate"
    
    # Count directories processed
    local dir_count=0
    
    # Merge all directory state files
    for state_file in "${CURRENT_STATE_DIR}"/*.state.json; do
        # Skip if no state files exist
        [[ -f "$state_file" ]] || continue
        
        # Extract directory key from filename
        local dir_key
        dir_key=$(basename "$state_file" .state.json)
        
        # Merge this directory's state into aggregate
        jq --arg key "$dir_key" \
           --slurpfile dir_state "$state_file" \
           '.filesystem_map[$key] = $dir_state[0]' \
           "$temp_aggregate" > "${temp_aggregate}.tmp" && \
           mv "${temp_aggregate}.tmp" "$temp_aggregate"
        
        ((dir_count++))
        
        # Progress logging for large filesystems
        if [[ $((dir_count % 100)) -eq 0 ]]; then
            log DEBUG "Aggregated $dir_count directories..."
        fi
    done
    
    # Atomic replace
    mv "$temp_aggregate" "$aggregate_file" || {
        log ERROR "Failed to write aggregate state file"
        rm -f "$temp_aggregate"
        return 1
    }
    
    log INFO "✅ Aggregate state built: $dir_count directories"
    log DEBUG "Aggregate file: $aggregate_file ($(du -h "$aggregate_file" 2>/dev/null | cut -f1))"
    
    return 0
}

#------------------------------------------------------------------------------
# init_state_files
#
# Initializes all state files if they don't exist
#
# Parameters:
#   None
#
# Returns:
#   0 - All state files initialized
#   1 - Initialization failed
#
# Side Effects:
#   Creates state directories
#   Creates initial state files
#
# Example:
#   init_state_files || die "State initialization failed"
#------------------------------------------------------------------------------
init_state_files() {
    log INFO "Initializing state file system..."
    
    # Ensure all state directories exist
    mkdir -p "$STATE_DIR" "$CURRENT_STATE_DIR" "$HIGH_LEVEL_STATE_DIR" "$S3_STATE_DIR" "$LOCKS_DIR" || {
        log ERROR "Failed to create state directories"
        return 1
    }
    
    local current_time
    current_time=$(get_iso8601_timestamp)
    
    # Initialize aggregate state file if doesn't exist
    if [[ ! -f "$AGGREGATE_STATE_FILE" ]] || [[ ! -s "$AGGREGATE_STATE_FILE" ]]; then
        log INFO "Creating aggregate state file: $AGGREGATE_STATE_FILE"
        jq -n \
            --arg version "2.0.0" \
            --arg timestamp "$current_time" \
            --arg mount_dir "${MOUNT_DIR:-/mount}" \
            '{
                state_file_version: $version,
                last_updated: $timestamp,
                filesystem_scan_timestamp: $timestamp,
                mount_directory: $mount_dir,
                filesystem_map: {},
                scan_statistics: {
                    total_directories: 0,
                    scan_duration_seconds: 0
                }
            }' > "$AGGREGATE_STATE_FILE" || {
            log ERROR "Failed to create aggregate state file"
            return 1
        }
    fi
    
    # Initialize yesterday state file if doesn't exist
    if [[ ! -f "$YESTERDAY_STATE_FILE" ]] || [[ ! -s "$YESTERDAY_STATE_FILE" ]]; then
        log INFO "Creating yesterday state file: $YESTERDAY_STATE_FILE"
        jq -n \
            --arg version "2.0.0" \
            --arg timestamp "$current_time" \
            --arg mount_dir "${MOUNT_DIR:-/mount}" \
            '{
                state_file_version: $version,
                last_updated: $timestamp,
                mount_directory: $mount_dir,
                summary: {
                    total_deleted_files: 0,
                    total_deleted_directories: 0,
                    unique_file_paths: 0,
                    oldest_deletion: null,
                    total_original_size: 0,
                    total_deletion_size: 0
                },
                deleted_files: {},
                deleted_directories: {}
            }' > "$YESTERDAY_STATE_FILE" || {
            log ERROR "Failed to create yesterday state file"
            return 1
        }
    fi
    
    # Initialize permanent deletions file if doesn't exist
    if [[ ! -f "$PERMANENT_DELETIONS_FILE" ]] || [[ ! -s "$PERMANENT_DELETIONS_FILE" ]]; then
        log INFO "Creating permanent deletions file: $PERMANENT_DELETIONS_FILE"
        jq -n \
            --arg version "2.0.0" \
            --arg timestamp "$current_time" \
            --arg mount_dir "${MOUNT_DIR:-/mount}" \
            '{
                state_file_version: $version,
                last_updated: $timestamp,
                mount_directory: $mount_dir,
                summary: {
                    total_permanently_deleted: 0,
                    unique_file_paths: 0,
                    oldest_permanent_deletion: null,
                    total_storage_freed: 0
                },
                permanently_deleted_files: {}
            }' > "$PERMANENT_DELETIONS_FILE" || {
            log ERROR "Failed to create permanent deletions file"
            return 1
        }
    fi
    
    # Initialize directory state file if doesn't exist
    if [[ ! -f "$DIRECTORY_STATE_FILE" ]] || [[ ! -s "$DIRECTORY_STATE_FILE" ]]; then
        log INFO "Creating directory state file: $DIRECTORY_STATE_FILE"
        jq -n \
            --arg version "2.0.0" \
            --arg timestamp "$current_time" \
            '{
                state_file_version: $version,
                last_updated: $timestamp,
                summary: {
                    total_alignment_operations: 0,
                    last_forced_alignment: null,
                    total_objects_cleaned_all_time: 0,
                    total_size_moved_all_time_gb: 0.00
                },
                directory_tracking: {},
                alignment_history: []
            }' > "$DIRECTORY_STATE_FILE" || {
            log ERROR "Failed to create directory state file"
            return 1
        }
    fi
    
    log INFO "✅ State file system initialized"
    log DEBUG "State directory: $STATE_DIR"
    log DEBUG "  ├─ Current states: $CURRENT_STATE_DIR"
    log DEBUG "  ├─ High-level states: $HIGH_LEVEL_STATE_DIR"
    log DEBUG "  ├─ S3 states: $S3_STATE_DIR"
    log DEBUG "  └─ Locks: $LOCKS_DIR"
    
    return 0
}

#------------------------------------------------------------------------------
# validate_state_file
#
# Validates that a state file contains valid JSON with expected structure
#
# Parameters:
#   $1 - state_file: Path to state file
#
# Returns:
#   0 - State file is valid
#   1 - State file is invalid
#
# Example:
#   if validate_state_file "$STATE_FILE"; then
#       echo "State is valid"
#   fi
#------------------------------------------------------------------------------
validate_state_file() {
    local state_file="$1"
    
    if [[ ! -f "$state_file" ]]; then
        log ERROR "validate_state_file: File does not exist: $state_file"
        return 1
    fi
    
    # Check it's valid JSON
    if ! is_valid_json "$state_file"; then
        log ERROR "validate_state_file: Invalid JSON: $state_file"
        return 1
    fi
    
    # Check has expected structure (state_file_version, last_updated)
    local has_version has_updated
    has_version=$(jq -e '.state_file_version' "$state_file" >/dev/null 2>&1 && echo "true" || echo "false")
    has_updated=$(jq -e '.last_updated' "$state_file" >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [[ "$has_version" != "true" ]] || [[ "$has_updated" != "true" ]]; then
        log ERROR "validate_state_file: Missing required fields (state_file_version or last_updated)"
        return 1
    fi
    
    log DEBUG "validate_state_file: Valid state file: $state_file"
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f generate_directory_key
readonly -f acquire_directory_lock release_directory_lock
readonly -f get_directory_state_file get_directory_state
readonly -f update_directory_state update_file_metadata remove_file_from_state
readonly -f build_aggregate_state init_state_files
readonly -f validate_state_file

log DEBUG "Module loaded: $STATE_MODULE_NAME v$STATE_MODULE_VERSION (API v$STATE_API_VERSION)"
log DEBUG "Architecture: Separate state files per directory (enables parallelization)"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_state() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "generate_directory_key"
        "acquire_directory_lock" "release_directory_lock"
        "get_directory_state_file" "get_directory_state"
        "update_directory_state" "update_file_metadata" "remove_file_from_state"
        "build_aggregate_state" "init_state_files"
        "validate_state_file"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $STATE_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for func in "log" "safe_base64_encode_url" "get_iso8601_timestamp"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $STATE_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check module metadata
    if [[ -z "${STATE_MODULE_VERSION:-}" ]]; then
        log ERROR "Module $STATE_MODULE_NAME: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_state || die "Module validation failed: $STATE_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

