#!/bin/bash

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

# S3 Inspect - Dual-Purpose S3 State Management
# Generates optimized cache for backup verification + rich reports for users
# Architecture: s3-cache.json (minimal) + s3-report.json (comprehensive)

set -euo pipefail

# Script configuration
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_ROOT="$(dirname "$SCRIPT_DIR")"  # Parent of scripts/

# Default file locations (organized under state/s3/)
DEFAULT_CACHE_FILE="${BACKUP_ROOT}/state/s3/s3-cache.json"
DEFAULT_REPORT_FILE="${BACKUP_ROOT}/state/s3/s3-report.json" 
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/backup-config.conf"
DEFAULT_LOG_FILE="${SCRIPT_DIR}/s3-inspect.log"

# Global configuration variables (compatible with backup-config.conf)
# These will be populated by load_config() and can be overridden by environment variables
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
AWS_REGION="${AWS_REGION:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
CACHE_FILE="$DEFAULT_CACHE_FILE"
REPORT_FILE="$DEFAULT_REPORT_FILE"
# Initialize LOG_FILE early to prevent logging failures before config load
LOG_FILE="$DEFAULT_LOG_FILE"

# Options
CACHE_ENABLED="true"
REPORT_ENABLED="true"
INCLUDE_YESTERDAY_STATE="true"
SCAN_TIMEOUT="300"
CACHE_VERSION="1.0"

# Runtime variables
START_TIME=""
TOTAL_FILES_SCANNED=0
TOTAL_SIZE_BYTES=0
SCAN_ERRORS=0
TEMP_FILES=()

# Performance and safety limits
MAX_OBJECTS_PER_BATCH="${MAX_OBJECTS_PER_BATCH:-5000}"
MAX_RETRIES=3
RETRY_BASE_DELAY=1

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" >&2
}

# AWS command with timeout and proper security
aws_cmd_safe() {
    local timeout_duration="${SCAN_TIMEOUT:-300}"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_duration" "$@"
    else
        "$@"
    fi
}

# AWS command with exponential backoff retry
aws_cmd_with_retry() {
    local max_retries="$MAX_RETRIES"
    local retry_delay="$RETRY_BASE_DELAY"
    local attempt=0
    
    while (( attempt < max_retries )); do
        if aws_cmd_safe "$@"; then
            return 0
        fi
        
        local exit_code=$?
        ((attempt++))
        
        if (( attempt < max_retries )); then
            log WARN "AWS command failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        else
            log ERROR "AWS command failed after $max_retries attempts"
            return $exit_code
        fi
    done
}

# Clean up temporary files
cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
    done
}

# Setup signal handlers
setup_cleanup() {
    trap cleanup_temp_files EXIT INT TERM
}

# Validate numeric input for arithmetic operations
validate_number() {
    local value="$1"
    local name="${2:-value}"
    
    # Check if value is a valid positive integer
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log ERROR "Invalid numeric $name: '$value' (expected positive integer)"
        return 1
    fi
    
    # Check for bash arithmetic limits (2^63-1)
    if (( value > 9223372036854775807 )); then
        log ERROR "Numeric $name too large: '$value' (exceeds system limits)"
        return 1
    fi
    
    return 0
}

# Human readable size conversion using bash arithmetic (no external bc)
bytes_to_human() {
    local bytes="$1"
    
    # Validate input is numeric
    if ! validate_number "$bytes" "bytes"; then
        printf "INVALID B"
        return 1
    fi
    
    # Use bash arithmetic with integer division for performance
    if (( bytes >= 1073741824 )); then
        # For GB, use integer arithmetic to avoid bc
        local gb_int=$((bytes / 1073741824))
        local gb_frac=$(( (bytes * 10 / 1073741824) % 10 ))
        printf "%d.%d GB" "$gb_int" "$gb_frac"
    elif (( bytes >= 1048576 )); then
        local mb_int=$((bytes / 1048576))
        local mb_frac=$(( (bytes * 10 / 1048576) % 10 ))
        printf "%d.%d MB" "$mb_int" "$mb_frac"
    elif (( bytes >= 1024 )); then
        local kb_int=$((bytes / 1024))
        local kb_frac=$(( (bytes * 10 / 1024) % 10 ))
        printf "%d.%d KB" "$kb_int" "$kb_frac"
    else
        printf "%d B" "$bytes"
    fi
}

# Atomic file write with locking
atomic_write_file() {
    local temp_file="$1"
    local target_file="$2"
    local lock_file="${target_file}.lock.$$"
    
    # Acquire lock with timeout
    local lock_fd
    exec {lock_fd}>"$lock_file"
    if ! flock -w 30 "$lock_fd"; then
        log ERROR "Failed to acquire lock for $target_file after 30s"
        exec {lock_fd}>&-
        rm -f "$lock_file"
        return 1
    fi
    
    # Atomic move
    if mv "$temp_file" "$target_file"; then
        log DEBUG "Successfully wrote $target_file"
    else
        log ERROR "Failed to write $target_file"
        exec {lock_fd}>&-
        rm -f "$lock_file"
        return 1
    fi
    
    # Release lock
    exec {lock_fd}>&-
    rm -f "$lock_file"
    return 0
}

# Generate collision-safe temporary file
make_temp_file() {
    local prefix="$1"
    mktemp "/tmp/s3-inspect-${prefix}.$$.$RANDOM.XXXXXX"
}

# ===============================================================================
# INPUT VALIDATION
# ===============================================================================

# Validate S3 bucket name format
validate_s3_bucket() {
    local bucket="$1"
    
    # Check basic format and length
    if [[ ${#bucket} -lt 3 || ${#bucket} -gt 63 ]]; then
        log ERROR "Invalid S3 bucket name length: $bucket (must be 3-63 characters)"
        return 1
    fi
    
    # Check character set (basic validation)
    if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        log ERROR "Invalid S3 bucket name format: $bucket"
        log ERROR "Must start/end with alphanumeric, contain only lowercase letters, numbers, dots, hyphens"
        return 1
    fi
    
    return 0
}

# Validate AWS region format
validate_aws_region() {
    local region="$1"
    
    # Basic AWS region format check
    if [[ ! "$region" =~ ^[a-z0-9-]+$ ]]; then
        log ERROR "Invalid AWS region format: $region (must contain only lowercase letters, numbers, hyphens)"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# CONFIGURATION MANAGEMENT  
# ===============================================================================

# Load configuration from backup-config.conf with environment variable override support
load_config() {
    local config_file="$DEFAULT_CONFIG_FILE"
    
    log INFO "Loading configuration with environment variable override support"
    
    # Load config file values into temporary variables first
    local config_s3_bucket=""
    local config_s3_prefix=""
    local config_aws_region=""
    local config_aws_profile=""
    local config_cache_file=""
    local config_report_file=""
    local config_log_file=""
    
    if [[ -f "$config_file" ]]; then
        log INFO "Reading configuration from: $config_file"
        
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            key=$(echo "$key" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//')
            
            case "$key" in
                "S3_BUCKET") config_s3_bucket="$value" ;;
                "S3_PREFIX") config_s3_prefix="$value" ;;
                "AWS_REGION") config_aws_region="$value" ;;
                "AWS_PROFILE") config_aws_profile="$value" ;;
                "S3_CACHE_FILE") config_cache_file="$value" ;;
                "S3_REPORT_FILE") config_report_file="$value" ;;
                "S3_INSPECT_LOG_FILE") config_log_file="$value" ;;
            esac
        done < "$config_file"
    else
        log WARN "Configuration file not found: $config_file"
        log INFO "Will use environment variables or defaults"
    fi
    
    # Apply environment variable overrides (environment takes precedence over config file)
    S3_BUCKET="${S3_BUCKET:-$config_s3_bucket}"
    S3_PREFIX="${S3_PREFIX:-$config_s3_prefix}"
    AWS_REGION="${AWS_REGION:-$config_aws_region}"
    AWS_PROFILE="${AWS_PROFILE:-$config_aws_profile}"
    
    # Log environment variable overrides
    [[ -n "${S3_BUCKET:-}" && "$S3_BUCKET" != "$config_s3_bucket" ]] && log INFO "Using S3_BUCKET from environment: $S3_BUCKET"
    [[ -n "${S3_PREFIX:-}" && "$S3_PREFIX" != "$config_s3_prefix" ]] && log INFO "Using S3_PREFIX from environment: $S3_PREFIX"
    [[ -n "${AWS_REGION:-}" && "$AWS_REGION" != "$config_aws_region" ]] && log INFO "Using AWS_REGION from environment: $AWS_REGION"
    [[ -n "${AWS_PROFILE:-}" && "$AWS_PROFILE" != "$config_aws_profile" ]] && log INFO "Using AWS_PROFILE from environment: $AWS_PROFILE"
    
    # Use standard AWS environment variable patterns
    if [[ -n "${AWS_DEFAULT_REGION:-}" && -z "$AWS_REGION" ]]; then
        AWS_REGION="$AWS_DEFAULT_REGION"
        log INFO "Using AWS_DEFAULT_REGION for AWS_REGION: $AWS_REGION"
    fi
    
    # Set file path defaults (environment variables can override config and defaults)
    CACHE_FILE="${S3_CACHE_FILE:-${config_cache_file:-$DEFAULT_CACHE_FILE}}"
    REPORT_FILE="${S3_REPORT_FILE:-${config_report_file:-$DEFAULT_REPORT_FILE}}"
    LOG_FILE="${S3_INSPECT_LOG_FILE:-${config_log_file:-$DEFAULT_LOG_FILE}}"
    
    # Validate required configuration
    if [[ -z "$S3_BUCKET" ]]; then
        log ERROR "S3_BUCKET not configured in config file or environment variables"
        log ERROR "Set S3_BUCKET in backup-config.conf or export S3_BUCKET=your-bucket-name"
        return 1
    fi
    validate_s3_bucket "$S3_BUCKET" || return 1
    
    if [[ -z "$AWS_REGION" ]]; then
        log ERROR "AWS_REGION not configured in config file or environment variables"
        log ERROR "Set AWS_REGION in backup-config.conf or export AWS_REGION=your-region"
        return 1
    fi
    validate_aws_region "$AWS_REGION" || return 1
    
    log INFO "Configuration loaded successfully:"
    log INFO "  S3 Bucket: $S3_BUCKET"
    log INFO "  S3 Prefix: ${S3_PREFIX:-"(none)"}"
    log INFO "  AWS Region: $AWS_REGION"
    log INFO "  AWS Profile: ${AWS_PROFILE:-"(default)"}"
    log INFO "  Cache File: $CACHE_FILE"
    log INFO "  Report File: $REPORT_FILE"
    
    return 0
}

# ===============================================================================
# S3 SCANNING FUNCTIONS
# ===============================================================================

# Build AWS CLI command array with proper authentication (prevents injection)
build_aws_command_array() {
    local cmd_array=("aws" "s3api" "--region" "$AWS_REGION")
    [[ -n "$AWS_PROFILE" ]] && cmd_array+=("--profile" "$AWS_PROFILE")
    printf '%s\n' "${cmd_array[@]}"
}

# Scan S3 prefix with pagination support and return all objects
scan_s3_prefix() {
    local prefix="$1"
    local aws_cmd_array
    readarray -t aws_cmd_array < <(build_aws_command_array)
    
    log INFO "Scanning S3 prefix: s3://$S3_BUCKET/$prefix"
    
    local all_objects="[]"
    local continuation_token=""
    local page_count=0
    
    # Paginated scanning to handle buckets with >1000 objects
    while true; do
        ((page_count++))
        log DEBUG "Fetching page $page_count for prefix: $prefix"
        
        local list_cmd=("${aws_cmd_array[@]}" "list-objects-v2" "--bucket" "$S3_BUCKET")
        [[ -n "$prefix" ]] && list_cmd+=("--prefix" "$prefix")
        [[ -n "$continuation_token" ]] && list_cmd+=("--continuation-token" "$continuation_token")
        list_cmd+=("--query" '{Contents: Contents, NextToken: NextContinuationToken}' "--output" "json")
        
        log DEBUG "AWS command: ${list_cmd[*]}"
        
        local page_result
        if page_result=$(aws_cmd_with_retry "${list_cmd[@]}" 2>&1); then
            local page_contents next_token
            page_contents=$(echo "$page_result" | jq '.Contents // [] | map([.Key, .Size, .LastModified, .ETag, .StorageClass])')
            next_token=$(echo "$page_result" | jq -r '.NextToken // empty')
            
            # Safely merge this page with accumulated results using proper jq
            all_objects=$(jq -n --argjson existing "$all_objects" --argjson new "$page_contents" '$existing + $new')
            
            # Validate merged JSON to prevent corruption
            if ! echo "$all_objects" | jq empty 2>/dev/null; then
                log ERROR "JSON merge failed for prefix $prefix - corrupted data detected"
                ((SCAN_ERRORS++))
                echo "[]"
                return 1
            fi
            
            local page_object_count
            page_object_count=$(echo "$page_contents" | jq 'length')
            log DEBUG "Page $page_count: $page_object_count objects"
            
            [[ -z "$next_token" || "$next_token" == "null" ]] && break
            continuation_token="$next_token"
        else
            log ERROR "Failed to scan S3 prefix: $prefix - $page_result"
            ((SCAN_ERRORS++))
            echo "[]"
            return 1
        fi
        
        # Safety check to prevent infinite loops
        if (( page_count > 10000 )); then
            log ERROR "Too many pages ($page_count) for prefix $prefix, possible infinite loop"
            break
        fi
    done
    
    local total_objects
    total_objects=$(echo "$all_objects" | jq 'length')
    log DEBUG "Successfully scanned prefix $prefix: $total_objects objects across $page_count pages"
    
    echo "$all_objects"
    return 0
}

# Process S3 scan results into structured data with optimized JSON generation
process_s3_objects() {
    local prefix="$1"
    local scan_data="$2"
    
    local temp_objects_file
    temp_objects_file=$(make_temp_file "objects")
    TEMP_FILES+=("$temp_objects_file")
    
    if [[ "$scan_data" == "[]" || -z "$scan_data" ]]; then
        echo "[]" > "$temp_objects_file"
        echo "$temp_objects_file:0:0"  # Return file:count:size format
        return 0
    fi
    
    log DEBUG "Processing S3 objects for prefix: $prefix"
    
    local file_count=0
    local size_sum=0
    
    # Pre-allocate JSON array
    echo "[" > "$temp_objects_file"
    local first_object=true
    
    # Use process substitution to avoid subshell variable loss
    while IFS= read -r object; do
        local s3_key size last_modified etag storage_class
        s3_key=$(echo "$object" | jq -r '.[0] // ""')
        size=$(echo "$object" | jq -r '.[1] // 0')
        last_modified=$(echo "$object" | jq -r '.[2] // ""')
        etag=$(echo "$object" | jq -r '.[3] // ""')
        storage_class=$(echo "$object" | jq -r '.[4] // "STANDARD"')
        
        # Validate size is numeric before using in arithmetic
        if ! validate_number "$size" "file size for $s3_key"; then
            log WARN "Skipping object with invalid size: $s3_key"
            continue
        fi
        
        [[ -z "$s3_key" ]] && continue
        
        # Calculate relative paths
        local relative_key="$s3_key"
        [[ -n "$S3_PREFIX" ]] && relative_key="${s3_key#$S3_PREFIX/}"
        
        # Determine backup prefix
        local backup_prefix="unknown"
        local logical_path="$relative_key"
        if [[ "$relative_key" == current_state/* ]]; then
            backup_prefix="current_state"
            logical_path="${relative_key#current_state/}"
        elif [[ "$relative_key" == yesterday_state/* ]]; then
            backup_prefix="yesterday_state"
            logical_path="${relative_key#yesterday_state/}"
        fi
        
        # Extract filename and extension
        local filename
        filename=$(basename "$logical_path")
        local file_extension=""
        [[ "$filename" == *.* ]] && file_extension="${filename##*.}"
        
        # Build object with essential metadata
        local absolute_path="s3://$S3_BUCKET/$s3_key"
        local size_human
        size_human=$(bytes_to_human "$size")
        local directory_path
        directory_path=$(dirname "$relative_key")/
        [[ "$directory_path" == "./" ]] && directory_path=""
        
        # Add comma before object (except first)
        [[ "$first_object" == "false" ]] && echo "," >> "$temp_objects_file"
        
        # Generate JSON object safely using jq (prevents injection from Linux filenames)
        local json_object
        json_object=$(jq -n \
            --arg s3_key "$s3_key" \
            --arg absolute_path "$absolute_path" \
            --arg relative_path "$relative_key" \
            --arg backup_prefix "$backup_prefix" \
            --arg logical_path "$logical_path" \
            --arg filename "$filename" \
            --arg file_extension "$file_extension" \
            --arg directory_path "$directory_path" \
            --argjson size_bytes "$size" \
            --arg size_human "$size_human" \
            --arg last_modified "$last_modified" \
            --arg etag "$etag" \
            --arg storage_class "$storage_class" \
            '{
                s3_key: $s3_key,
                absolute_path: $absolute_path,
                relative_path: $relative_path,
                backup_prefix: $backup_prefix,
                logical_path: $logical_path,
                filename: $filename,
                file_extension: $file_extension,
                directory_path: $directory_path,
                size_bytes: $size_bytes,
                size_human: $size_human,
                last_modified: $last_modified,
                etag: $etag,
                storage_class: $storage_class
            }')
        
        # Add object to file (comma already handled above)
        echo "    $json_object" >> "$temp_objects_file"
        
        first_object=false
        ((file_count++))
        # Safe arithmetic with validated size
        ((size_sum += size))
        
        # Progress feedback for large datasets
        if (( file_count % MAX_OBJECTS_PER_BATCH == 0 )); then
            log DEBUG "Processed $file_count objects for prefix: $prefix"
        fi
        
    done < <(echo "$scan_data" | jq -c '.[]')
    
    # Close JSON array
    echo "]" >> "$temp_objects_file"
    
    log DEBUG "Processed $file_count objects for prefix: $prefix ($(bytes_to_human $size_sum))"
    echo "$temp_objects_file:$file_count:$size_sum"
}

# ===============================================================================
# CACHE GENERATION (OPTIMIZED FOR SPEED)
# ===============================================================================

# Generate minimal cache for O(1) backup verification lookups
generate_s3_cache() {
    local all_objects_file="$1"
    local cache_temp_file
    cache_temp_file=$(make_temp_file "cache")
    TEMP_FILES+=("$cache_temp_file")
    
    # Ensure output directory exists
    local cache_dir=$(dirname "$CACHE_FILE")
    mkdir -p "$cache_dir" 2>/dev/null || {
        log ERROR "Failed to create cache directory: $cache_dir"
        return 1
    }
    
    log INFO "Generating S3 cache file: $CACHE_FILE"
    
    # Extract only absolute paths for ultra-fast lookups
    local cache_files_array
    if [[ -f "$all_objects_file" ]] && [[ "$(jq -s 'flatten | length' "$all_objects_file")" -gt 0 ]]; then
        cache_files_array=$(jq -s 'flatten | map(.absolute_path) | sort | unique' "$all_objects_file")
    else
        cache_files_array="[]"
    fi
    
    local current_time
    current_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local scan_duration=$(($(date +%s) - START_TIME))
    
    # Build minimal cache structure
    jq -n \
        --arg generated_at "$current_time" \
        --arg total_files "$TOTAL_FILES_SCANNED" \
        --arg cache_version "$CACHE_VERSION" \
        --arg s3_bucket "$S3_BUCKET" \
        --arg scan_duration_seconds "$scan_duration" \
        --argjson files "$cache_files_array" \
        '{
            cache_metadata: {
                generated_at: $generated_at,
                total_files: ($total_files | tonumber),
                cache_version: $cache_version,
                s3_bucket: $s3_bucket,
                scan_duration_seconds: ($scan_duration_seconds | tonumber)
            },
            files: $files
        }' > "$cache_temp_file"
    
    # Atomic write with locking
    if atomic_write_file "$cache_temp_file" "$CACHE_FILE"; then
        log INFO "Generated cache: $CACHE_FILE ($(du -h "$CACHE_FILE" 2>/dev/null | cut -f1 || echo "unknown size"))"
        return 0
    else
        log ERROR "Failed to write cache file: $CACHE_FILE"
        return 1
    fi
}

# ===============================================================================
# REPORT GENERATION (COMPREHENSIVE FOR USERS)
# ===============================================================================

# Generate comprehensive report with rich metadata
generate_s3_report() {
    local all_objects_file="$1"
    local report_temp_file
    report_temp_file=$(make_temp_file "report")
    TEMP_FILES+=("$report_temp_file")
    
    # Ensure output directory exists
    local report_dir=$(dirname "$REPORT_FILE")
    mkdir -p "$report_dir" 2>/dev/null || {
        log ERROR "Failed to create report directory: $report_dir"
        return 1
    }
    
    log INFO "Generating S3 report file: $REPORT_FILE"
    
    local current_time
    current_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local scan_duration=$(($(date +%s) - START_TIME))
    local total_size_human
    total_size_human=$(bytes_to_human "$TOTAL_SIZE_BYTES")
    
    # Build comprehensive report structure
    jq -n \
        --arg generated_at "$current_time" \
        --arg scan_duration_seconds "$scan_duration" \
        --arg aws_region "$AWS_REGION" \
        --arg s3_bucket "$S3_BUCKET" \
        --arg s3_prefix "$S3_PREFIX" \
        --arg total_files "$TOTAL_FILES_SCANNED" \
        --arg total_size_bytes "$TOTAL_SIZE_BYTES" \
        --arg total_size_human "$total_size_human" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg scan_errors "$SCAN_ERRORS" \
        '{
            scan_metadata: {
                generated_at: $generated_at,
                scan_duration_seconds: ($scan_duration_seconds | tonumber),
                aws_region: $aws_region,
                s3_bucket: $s3_bucket,
                s3_prefix: $s3_prefix,
                total_files: ($total_files | tonumber),
                total_size_bytes: ($total_size_bytes | tonumber),
                total_size_human: $total_size_human,
                script_version: $script_version,
                scan_errors: ($scan_errors | tonumber)
            }
        }' > "$report_temp_file"
    
    # Add files array from processed objects
    if [[ -f "$all_objects_file" ]] && [[ -s "$all_objects_file" ]]; then
        jq --slurpfile files "$all_objects_file" \
           '. + {files: $files}' "$report_temp_file" > "${report_temp_file}.tmp"
        mv "${report_temp_file}.tmp" "$report_temp_file"
    else
        jq '. + {files: []}' "$report_temp_file" > "${report_temp_file}.tmp"
        mv "${report_temp_file}.tmp" "$report_temp_file"
    fi
    
    # Pretty print final report
    local report_final
    report_final=$(make_temp_file "report-final")
    TEMP_FILES+=("$report_final")
    
    if jq --indent 2 . "$report_temp_file" > "$report_final"; then
        # Atomic write with locking
        if atomic_write_file "$report_final" "$REPORT_FILE"; then
            log INFO "Generated report: $REPORT_FILE ($(du -h "$REPORT_FILE" 2>/dev/null | cut -f1 || echo "unknown size"))"
            return 0
        else
            log ERROR "Failed to write report file: $REPORT_FILE"
            return 1
        fi
    else
        log ERROR "Failed to format report JSON"
        return 1
    fi
}

# ===============================================================================
# MAIN WORKFLOW
# ===============================================================================

# Validate AWS access with cost-effective operation
validate_aws_access() {
    local aws_cmd_array
    readarray -t aws_cmd_array < <(build_aws_command_array)
    
    log DEBUG "Validating AWS access to bucket: $S3_BUCKET"
    
    # Use head-bucket instead of list-objects (cheaper and faster)
    if aws_cmd_with_retry "${aws_cmd_array[@]}" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
        log DEBUG "AWS access validation successful"
        return 0
    else
        log ERROR "Cannot access S3 bucket: $S3_BUCKET"
        log ERROR "Check your AWS credentials, region, and bucket permissions"
        return 1
    fi
}

# Main scanning and generation workflow
main_scan_workflow() {
    log INFO "Starting S3 scan workflow"
    START_TIME=$(date +%s)
    
    # Validate AWS access first
    validate_aws_access || return 1
    
    # Determine prefixes to scan
    local prefixes_to_scan=()
    local base_prefix="${S3_PREFIX}"
    
    if [[ -n "$base_prefix" ]]; then
        prefixes_to_scan+=("${base_prefix}/current_state")
        [[ "$INCLUDE_YESTERDAY_STATE" == "true" ]] && prefixes_to_scan+=("${base_prefix}/yesterday_state")
    else
        prefixes_to_scan+=("current_state")
        [[ "$INCLUDE_YESTERDAY_STATE" == "true" ]] && prefixes_to_scan+=("yesterday_state")
    fi
    
    log INFO "Will scan ${#prefixes_to_scan[@]} prefixes: ${prefixes_to_scan[*]}"
    
    # Scan all prefixes and collect objects
    local all_objects_file
    all_objects_file=$(make_temp_file "all-objects")
    TEMP_FILES+=("$all_objects_file")
    
    # Initialize as empty JSON array
    echo "[]" > "$all_objects_file"
    
    local prefix_count=0
    for prefix in "${prefixes_to_scan[@]}"; do
        log INFO "Scanning prefix ($((++prefix_count))/${#prefixes_to_scan[@]}): $prefix"
        
        local scan_result objects_info objects_file prefix_files prefix_size
        scan_result=$(scan_s3_prefix "$prefix")
        objects_info=$(process_s3_objects "$prefix" "$scan_result")
        
        # Parse returned info: file:count:size
        IFS=':' read -r objects_file prefix_files prefix_size <<< "$objects_info"
        
        # Validate numeric values before arithmetic
        if ! validate_number "$prefix_files" "prefix_files for $prefix"; then
            log ERROR "Invalid file count from prefix processing: $prefix"
            return 1
        fi
        
        if ! validate_number "$prefix_size" "prefix_size for $prefix"; then
            log ERROR "Invalid size total from prefix processing: $prefix"
            return 1
        fi
        
        # Update totals (fixed: no longer lost in subshell)
        TOTAL_FILES_SCANNED=$((TOTAL_FILES_SCANNED + prefix_files))
        TOTAL_SIZE_BYTES=$((TOTAL_SIZE_BYTES + prefix_size))
        
        # Merge objects into all_objects_file
        if [[ -f "$objects_file" ]] && [[ -s "$objects_file" ]]; then
            # Use jq to merge JSON arrays
            local merged_file
            merged_file=$(make_temp_file "merged")
            TEMP_FILES+=("$merged_file")
            
            jq -s 'add' "$all_objects_file" "$objects_file" > "$merged_file"
            mv "$merged_file" "$all_objects_file"
        fi
        
        log INFO "Prefix $prefix: $prefix_files files, $(bytes_to_human $prefix_size)"
    done
    
    log INFO "Scan complete: $TOTAL_FILES_SCANNED files, $(bytes_to_human $TOTAL_SIZE_BYTES)"
    
    # Generate cache if enabled
    if [[ "$CACHE_ENABLED" == "true" ]]; then
        if ! generate_s3_cache "$all_objects_file"; then
            log ERROR "Cache generation failed"
            return 1
        fi
    fi
    
    # Generate report if enabled  
    if [[ "$REPORT_ENABLED" == "true" ]]; then
        if ! generate_s3_report "$all_objects_file"; then
            log ERROR "Report generation failed"
            return 1
        fi
    fi
    
    local scan_duration=$(($(date +%s) - START_TIME))
    log INFO "✅ Workflow completed in ${scan_duration}s"
    
    return 0
}

# Usage information
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

S3 Inspect - Dual-Purpose S3 State Management
Generates optimized cache + comprehensive reports from S3 scan.

OPTIONS:
    --cache-only      Generate only cache file (fast lookups)
    --report-only     Generate only report file (user visibility)  
    --no-yesterday    Exclude yesterday_state from scan
    --config FILE     Use alternative configuration file
    --help           Show this help

EXAMPLES:
    $SCRIPT_NAME                    # Generate both cache and report
    $SCRIPT_NAME --cache-only       # Generate only cache
    $SCRIPT_NAME --report-only      # Generate only report
    $SCRIPT_NAME --config /path/to/backup-config.conf  # Use specific config

OUTPUTS:
    ../state/s3/s3-cache.json    - Minimal cache for backup verification (O(1) lookups)
    ../state/s3/s3-report.json   - Comprehensive report for users
    s3-inspect.log               - Operation log (in scripts/)

CONFIG:
    Reads settings from backup-config.conf:
    - S3_BUCKET, AWS_REGION (required)
    - S3_PREFIX, AWS_PROFILE (optional)
    Can be overridden with --config option
    
ENVIRONMENT VARIABLES:
    Can be overridden via environment variables:
    - S3_BUCKET, S3_PREFIX, AWS_REGION, AWS_PROFILE
    - AWS_DEFAULT_REGION (fallback for AWS_REGION)
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cache-only)
                CACHE_ENABLED="true"
                REPORT_ENABLED="false"
                shift
                ;;
            --report-only)
                CACHE_ENABLED="false" 
                REPORT_ENABLED="true"
                shift
                ;;
            --no-yesterday)
                INCLUDE_YESTERDAY_STATE="false"
                shift
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    log ERROR "Option --config requires a file path"
                    exit 1
                fi
                DEFAULT_CONFIG_FILE="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# ===============================================================================
# MAIN EXECUTION
# ===============================================================================

main() {
    # Setup cleanup early
    setup_cleanup
    
    # Ensure log directory exists before any logging
    local initial_log_dir
    initial_log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$initial_log_dir" ]] && mkdir -p "$initial_log_dir" 2>/dev/null || true
    
    # Parse arguments (may cause early logging)
    parse_arguments "$@"
    
    # Load configuration (this may update LOG_FILE)
    if ! load_config; then
        log ERROR "Configuration loading failed"
        exit 1
    fi
    
    # Update log directory if LOG_FILE changed during config load
    local final_log_dir
    final_log_dir=$(dirname "$LOG_FILE")
    [[ ! -d "$final_log_dir" ]] && mkdir -p "$final_log_dir"
    
    log INFO "S3 Inspect v$SCRIPT_VERSION starting (PID: $$)"
    log INFO "Cache: $CACHE_ENABLED, Report: $REPORT_ENABLED"
    
    # Validate required commands
    for cmd in jq aws; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log ERROR "Required command not found: $cmd"
            log ERROR "Please install $cmd and ensure it's in PATH"
            exit 1
        fi
    done
    
    # Execute workflow
    if main_scan_workflow; then
        log INFO "S3 Inspect completed successfully"
        exit 0
    else
        log ERROR "S3 Inspect failed"
        exit 1
    fi
}

# Execute main with all arguments
main "$@"