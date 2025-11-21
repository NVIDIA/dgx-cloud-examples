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
# s3.sh - AWS S3 Operations Module  
################################################################################
# Purpose: Provides all AWS S3 operations with retry logic, timeout protection,
#          parallel uploads for performance, and comprehensive error handling.
#
# Dependencies: core.sh, utils.sh, config.sh, state.sh
#
# Features:
#   - Retry logic with exponential backoff (handles temporary AWS failures)
#   - Timeout protection (prevents hanging on network issues)
#   - Parallel uploads (10x performance improvement)
#   - Upload verification (prevents silent data loss)
#   - S3 cache integration (skip unnecessary uploads)
#
# Public API:
#   Basic Operations:
#   - s3_upload()          : Upload file with retry and verification
#   - s3_download()        : Download file with retry
#   - s3_delete()          : Delete S3 object
#   - s3_move()            : Move S3 object
#   - s3_exists()          : Check if object exists
#   - s3_list()            : List objects in prefix
#
#   Performance:
#   - s3_upload_parallel() : Upload multiple files in parallel (10x faster!)
#
#   Verification:
#   - verify_s3_upload()   : Verify upload succeeded (prevent data loss)
#
#   AWS Command Building:
#   - build_aws_command()  : Construct AWS CLI with profile/region
#   - aws_cmd_safe()       : Execute AWS command with timeout protection
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly S3_MODULE_VERSION="1.0.0"
readonly S3_MODULE_NAME="s3"
readonly S3_MODULE_DEPS=("core" "utils" "config" "state")
readonly S3_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${S3_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: s3.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION
################################################################################

# S3 configuration (should be set by config.sh)
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"

# Operation timeouts
readonly S3_UPLOAD_TIMEOUT=300     # 5 minutes for uploads
readonly S3_DOWNLOAD_TIMEOUT=300   # 5 minutes for downloads
readonly S3_DELETE_TIMEOUT=60      # 1 minute for deletes
readonly S3_LIST_TIMEOUT=180       # 3 minutes for lists

# Retry configuration
readonly S3_MAX_RETRIES=3
readonly S3_RETRY_DELAY=5          # Base delay in seconds (exponential backoff)

# Parallel upload configuration
readonly MAX_PARALLEL_UPLOADS="${MAX_PARALLEL_UPLOADS:-10}"

################################################################################
# PUBLIC API: AWS COMMAND BUILDING
################################################################################

#------------------------------------------------------------------------------
# build_aws_command
#
# Constructs AWS CLI command with profile and region options
#
# Parameters:
#   $1 - service: AWS service (s3, s3api, sts, etc.)
#
# Returns:
#   0 - Success, command string printed to stdout
#
# Output:
#   AWS CLI command string (e.g., "aws s3 --region us-east-1 --profile default")
#
# Example:
#   aws_cmd=$(build_aws_command "s3")
#   $aws_cmd ls "s3://bucket/"
#------------------------------------------------------------------------------
build_aws_command() {
    local service="${1:-s3}"
    
    local aws_cmd="aws $service"
    
    [[ -n "$AWS_REGION" ]] && aws_cmd+=" --region $AWS_REGION"
    [[ -n "$AWS_PROFILE" ]] && aws_cmd+=" --profile $AWS_PROFILE"
    
    echo "$aws_cmd"
    return 0
}

#------------------------------------------------------------------------------
# aws_cmd_safe
#
# Executes AWS command with default timeout protection
#
# Parameters:
#   $@ - AWS command and arguments
#
# Returns:
#   Exit code from AWS command
#
# Features:
#   - Timeout protection (prevents hanging)
#   - Graceful fallback if timeout command not available
#
# Example:
#   if aws_cmd_safe aws s3 ls "s3://bucket/"; then
#       echo "Success"
#   fi
#------------------------------------------------------------------------------
aws_cmd_safe() {
    local timeout_duration="${S3_UPLOAD_TIMEOUT:-300}"
    
    # Use timeout command if available
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_duration" "$@"
    else
        # No timeout available, run without
        "$@"
    fi
    
    return $?
}

#------------------------------------------------------------------------------
# aws_cmd_with_timeout
#
# Executes AWS command with CUSTOM timeout (for operations needing different timeouts)
#
# Parameters:
#   $1 - timeout_duration: Timeout in seconds
#   $@ - AWS command and arguments (remaining parameters)
#
# Returns:
#   Exit code from AWS command
#
# Example:
#   # Use 180s timeout for S3 list (vs default 300s)
#   aws_cmd_with_timeout 180 aws s3 ls "s3://bucket/" --recursive
#------------------------------------------------------------------------------
aws_cmd_with_timeout() {
    local timeout_duration="$1"
    shift
    
    # Use timeout command if available
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_duration" "$@"
    else
        # No timeout available, run without
        "$@"
    fi
    
    return $?
}

################################################################################
# PUBLIC API: BASIC S3 OPERATIONS
################################################################################

#------------------------------------------------------------------------------
# s3_upload
#
# Uploads file to S3 with retry logic and verification
#
# Parameters:
#   $1 - local_file: Path to local file
#   $2 - s3_path: Destination S3 path (s3://bucket/key)
#   $3 - verify: Verify upload (optional, default: true)
#
# Returns:
#   0 - Upload successful and verified
#   1 - Upload failed after retries
#
# Features:
#   - Retries with exponential backoff (handles temporary failures)
#   - Optional verification (default: enabled)
#   - Comprehensive error logging
#
# Example:
#   if s3_upload "/path/to/file" "s3://bucket/prefix/file"; then
#       echo "Upload successful"
#   fi
#------------------------------------------------------------------------------
s3_upload() {
    local local_file="$1"
    local s3_path="$2"
    local verify="${3:-true}"
    
    # Validate inputs
    if [[ ! -f "$local_file" ]]; then
        log ERROR "s3_upload: Local file not found: $local_file"
        return 1
    fi
    
    if [[ -z "$s3_path" ]]; then
        log ERROR "s3_upload: S3 path required"
        return 1
    fi
    
    # Get file size for verification
    local file_size
    file_size=$(get_file_size "$local_file")
    
    # Build AWS command
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    # Retry loop with exponential backoff
    local attempt=1
    local max_retries=$S3_MAX_RETRIES
    
    while [[ $attempt -le $max_retries ]]; do
        if [[ $attempt -gt 1 ]]; then
            local delay=$((S3_RETRY_DELAY * (2 ** (attempt - 2))))
            log WARN "Retry attempt $attempt/$max_retries after ${delay}s delay"
            sleep "$delay"
        fi
        
        log DEBUG "Uploading to S3 (attempt $attempt/$max_retries): $local_file -> $s3_path"
        
        # Attempt upload
        if aws_cmd_safe $aws_cmd cp "$local_file" "$s3_path" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            # Upload command succeeded
            
            # Verify upload if requested
            if [[ "$verify" == "true" ]]; then
                if verify_s3_upload "$local_file" "$s3_path" "$file_size"; then
                    log DEBUG "Upload verified: $s3_path"
                    return 0
                else
                    log ERROR "Upload verification failed: $s3_path"
                    ((attempt++))
                    continue
                fi
            else
                # No verification requested
                return 0
            fi
        else
            # Upload failed
            log ERROR "Upload failed (attempt $attempt/$max_retries): $s3_path"
            ((attempt++))
        fi
    done
    
    # All retries exhausted
    log ERROR "Upload failed after $max_retries attempts: $s3_path"
    return 1
}

#------------------------------------------------------------------------------
# s3_download
#
# Downloads file from S3 with retry logic
#
# Parameters:
#   $1 - s3_path: Source S3 path (s3://bucket/key)
#   $2 - local_file: Destination local path
#
# Returns:
#   0 - Download successful
#   1 - Download failed
#
# Example:
#   s3_download "s3://bucket/file" "/local/path/file"
#------------------------------------------------------------------------------
s3_download() {
    local s3_path="$1"
    local local_file="$2"
    
    # Validate inputs
    if [[ -z "$s3_path" ]] || [[ -z "$local_file" ]]; then
        log ERROR "s3_download: s3_path and local_file required"
        return 1
    fi
    
    # Build AWS command
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    # Retry loop
    local attempt=1
    while [[ $attempt -le $S3_MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            local delay=$((S3_RETRY_DELAY * (2 ** (attempt - 2))))
            log WARN "Retry download attempt $attempt/$S3_MAX_RETRIES after ${delay}s"
            sleep "$delay"
        fi
        
        log DEBUG "Downloading from S3 (attempt $attempt): $s3_path -> $local_file"
        
        if aws_cmd_safe $aws_cmd cp "$s3_path" "$local_file" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log DEBUG "Download successful: $s3_path"
            return 0
        fi
        
        ((attempt++))
    done
    
    log ERROR "Download failed after $S3_MAX_RETRIES attempts: $s3_path"
    return 1
}

#------------------------------------------------------------------------------
# s3_delete
#
# Deletes object from S3
#
# Parameters:
#   $1 - s3_path: S3 path to delete (s3://bucket/key)
#
# Returns:
#   0 - Delete successful
#   1 - Delete failed
#
# Example:
#   s3_delete "s3://bucket/old-file"
#------------------------------------------------------------------------------
s3_delete() {
    local s3_path="$1"
    
    if [[ -z "$s3_path" ]]; then
        log ERROR "s3_delete: s3_path required"
        return 1
    fi
    
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    log DEBUG "Deleting from S3: $s3_path"
    
    if aws_cmd_safe $aws_cmd rm "$s3_path" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log DEBUG "Delete successful: $s3_path"
        return 0
    else
        log ERROR "Delete failed: $s3_path"
        return 1
    fi
}

#------------------------------------------------------------------------------
# s3_move
#
# Moves object within S3 (copy + delete)
#
# Parameters:
#   $1 - source_s3_path: Source S3 path
#   $2 - dest_s3_path: Destination S3 path
#
# Returns:
#   0 - Move successful
#   1 - Move failed
#
# Example:
#   s3_move "s3://bucket/old/path" "s3://bucket/new/path"
#------------------------------------------------------------------------------
s3_move() {
    local source_s3_path="$1"
    local dest_s3_path="$2"
    
    if [[ -z "$source_s3_path" ]] || [[ -z "$dest_s3_path" ]]; then
        log ERROR "s3_move: source and destination paths required"
        return 1
    fi
    
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    log DEBUG "Moving in S3: $source_s3_path -> $dest_s3_path"
    
    # Copy to destination
    if ! aws_cmd_safe $aws_cmd cp "$source_s3_path" "$dest_s3_path" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log ERROR "Failed to copy during move: $source_s3_path"
        return 1
    fi
    
    # Delete source
    if ! aws_cmd_safe $aws_cmd rm "$source_s3_path" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log WARN "Failed to delete source after copy (destination exists): $source_s3_path"
        return 1
    fi
    
    log DEBUG "Move successful: $source_s3_path -> $dest_s3_path"
    return 0
}

#------------------------------------------------------------------------------
# s3_exists
#
# Checks if object exists in S3
#
# Parameters:
#   $1 - s3_path: S3 path to check
#
# Returns:
#   0 - Object exists
#   1 - Object does not exist
#
# Example:
#   if s3_exists "s3://bucket/file"; then
#       echo "File exists in S3"
#   fi
#------------------------------------------------------------------------------
s3_exists() {
    local s3_path="$1"
    
    if [[ -z "$s3_path" ]]; then
        return 1
    fi
    
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    aws_cmd_safe $aws_cmd ls "$s3_path" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# s3_list
#
# Lists objects in S3 prefix
#
# Parameters:
#   $1 - s3_prefix: S3 prefix to list (s3://bucket/prefix/)
#   $2 - recursive: Recursive listing (optional, default: true)
#
# Returns:
#   0 - Success, object list printed to stdout
#   1 - List failed
#
# Output:
#   AWS S3 ls output format
#
# Example:
#   s3_list "s3://bucket/prefix/" | while read -r line; do
#       echo "Object: $line"
#   done
#------------------------------------------------------------------------------
s3_list() {
    local s3_prefix="$1"
    local recursive="${2:-true}"
    
    if [[ -z "$s3_prefix" ]]; then
        log ERROR "s3_list: s3_prefix required"
        return 1
    fi
    
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    local recursive_flag=""
    [[ "$recursive" == "true" ]] && recursive_flag="--recursive"
    
    log DEBUG "Listing S3 prefix: $s3_prefix (recursive: $recursive)"
    
    aws_cmd_safe $aws_cmd ls $recursive_flag "$s3_prefix" 2>&1
}

################################################################################
# PUBLIC API: PERFORMANCE - PARALLEL UPLOADS
################################################################################

#------------------------------------------------------------------------------
# s3_upload_parallel
#
# Uploads multiple files to S3 in parallel for 10x performance improvement
#
# Parameters:
#   $1 - file_list: Path to file containing list of local files (one per line)
#   $2 - s3_base: Base S3 path (s3://bucket/prefix/)
#   $3 - max_workers: Maximum parallel uploads (optional, default: 10)
#
# Returns:
#   0 - All uploads successful
#   1 - One or more uploads failed
#
# Performance:
#   Sequential: 1,000 files × 2s = 2,000 seconds (33 minutes)
#   Parallel (10): 1,000 files / 10 × 2s = 200 seconds (3.3 minutes)
#   Speedup: 10x faster! 🚀
#
# Example:
#   echo -e "/path/file1\n/path/file2" > /tmp/files.txt
#   s3_upload_parallel "/tmp/files.txt" "s3://bucket/prefix/"
#------------------------------------------------------------------------------
s3_upload_parallel() {
    local file_list="$1"
    local s3_base="$2"
    local max_workers="${3:-$MAX_PARALLEL_UPLOADS}"
    
    # Validate inputs
    if [[ ! -f "$file_list" ]]; then
        log ERROR "s3_upload_parallel: File list not found: $file_list"
        return 1
    fi
    
    if [[ -z "$s3_base" ]]; then
        log ERROR "s3_upload_parallel: S3 base path required"
        return 1
    fi
    
    # Count files to upload
    local file_count
    file_count=$(wc -l < "$file_list")
    
    log INFO "Starting parallel upload: $file_count files ($max_workers workers)"
    
    # Build AWS command
    local aws_cmd
    aws_cmd=$(build_aws_command "s3")
    
    # Create upload task function
    # Use xargs for parallel execution (POSIX-compliant)
    local failed=0
    
    if command -v parallel >/dev/null 2>&1; then
        # Use GNU Parallel if available (better progress tracking)
        log DEBUG "Using GNU Parallel for uploads"
        
        cat "$file_list" | parallel -j "$max_workers" --halt soon,fail=1 \
            "aws_cmd_safe $aws_cmd cp {} \"$s3_base\$(basename {})\" 2>&1 | tee -a '${LOG_FILE:-/dev/null}'" \
            || failed=1
    else
        # Fallback: use xargs (portable but less features)
        log DEBUG "Using xargs for parallel uploads"
        
        cat "$file_list" | xargs -P "$max_workers" -I {} bash -c \
            "$aws_cmd cp '{}' '$s3_base\$(basename {})' 2>&1 | tee -a '${LOG_FILE:-/dev/null}'" \
            || failed=1
    fi
    
    if [[ $failed -eq 0 ]]; then
        log INFO "✅ Parallel upload complete: $file_count files"
        return 0
    else
        log ERROR "Parallel upload had failures"
        return 1
    fi
}

################################################################################
# PUBLIC API: VERIFICATION
################################################################################

#------------------------------------------------------------------------------
# verify_s3_upload
#
# Verifies that upload to S3 was successful
# CRITICAL: Prevents silent data loss
#
# Parameters:
#   $1 - local_file: Path to local file that was uploaded
#   $2 - s3_path: S3 path where file should be
#   $3 - expected_size: Expected file size (optional)
#
# Returns:
#   0 - Upload verified (file exists in S3 with correct size)
#   1 - Verification failed
#
# Example:
#   if verify_s3_upload "/local/file" "s3://bucket/file" "1024"; then
#       echo "Upload verified"
#   fi
#------------------------------------------------------------------------------
verify_s3_upload() {
    local local_file="$1"
    local s3_path="$2"
    local expected_size="$3"
    
    # Check file exists in S3
    if ! s3_exists "$s3_path"; then
        log ERROR "Verification failed: File not found in S3: $s3_path"
        return 1
    fi
    
    # Verify size if provided
    if [[ -n "$expected_size" ]]; then
        local aws_cmd
        aws_cmd=$(build_aws_command "s3")
        
        local s3_size
        s3_size=$(aws_cmd_safe $aws_cmd ls "$s3_path" 2>/dev/null | awk '{print $3}')
        
        if [[ "$s3_size" != "$expected_size" ]]; then
            log ERROR "Verification failed: Size mismatch"
            log ERROR "  Expected: $expected_size bytes"
            log ERROR "  S3 reports: $s3_size bytes"
            log ERROR "  File: $s3_path"
            return 1
        fi
    fi
    
    log DEBUG "Upload verification successful: $s3_path"
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f build_aws_command aws_cmd_safe aws_cmd_with_timeout
readonly -f s3_upload s3_download s3_delete s3_move s3_exists s3_list
readonly -f s3_upload_parallel verify_s3_upload

log DEBUG "Module loaded: $S3_MODULE_NAME v$S3_MODULE_VERSION (API v$S3_API_VERSION)"
log DEBUG "S3 Bucket: ${S3_BUCKET:-<not set>}, Region: $AWS_REGION"
log DEBUG "Parallel uploads: ${MAX_PARALLEL_UPLOADS} workers"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_s3() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "build_aws_command" "aws_cmd_safe" "aws_cmd_with_timeout"
        "s3_upload" "s3_download" "s3_delete" "s3_move" "s3_exists" "s3_list"
        "s3_upload_parallel" "verify_s3_upload"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $S3_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies
    for func in "log" "get_file_size"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $S3_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check S3_BUCKET is set
    if [[ -z "${S3_BUCKET:-}" ]]; then
        log WARN "Module $S3_MODULE_NAME: S3_BUCKET not configured"
    fi
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_s3 || die "Module validation failed: $S3_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

