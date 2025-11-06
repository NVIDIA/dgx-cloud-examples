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
# utils.sh - Cross-Platform Utility Functions Module
################################################################################
# Purpose: Provides portable utility functions that work across Linux, macOS,
#          and other Unix-like systems. Handles platform differences in common
#          operations like file metadata, encoding, and date parsing.
#
# Dependencies: core.sh (for logging and error handling)
#
# Public API:
#   File Operations:
#   - get_file_mtime()         : Get file modification time (cross-platform)
#   - get_file_size()          : Get file size (cross-platform)
#   - atomic_write()           : Atomic file write via temp + move
#   - create_temp_dir()        : Create secure temporary directory
#
#   Encoding:
#   - safe_base64_encode()     : Base64 encode (no line wrapping)
#   - safe_base64_encode_url() : URL-safe base64 encode
#   - json_escape()            : Escape string for JSON
#
#   Size Operations:
#   - bytes_to_human()         : Convert bytes to human readable
#   - bytes_to_gb()            : Convert bytes to GB with precision
#   - calculate_size_distribution() : Categorize file by size
#
#   Date/Time:
#   - parse_iso8601_date()     : Parse ISO 8601 date to Unix timestamp
#   - get_iso8601_timestamp()  : Get current time in ISO 8601 format
#
#   Validation:
#   - is_valid_json()          : Check if file contains valid JSON
#   - is_numeric()             : Check if string is numeric
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly UTILS_MODULE_VERSION="1.0.0"
readonly UTILS_MODULE_NAME="utils"
readonly UTILS_MODULE_DEPS=("core")
readonly UTILS_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

# Ensure core module is loaded (provides log, die, etc.)
if ! declare -F "log" >/dev/null 2>&1; then
    echo "ERROR: utils.sh requires core.sh to be loaded first" >&2
    exit 1
fi

################################################################################
# PUBLIC API: CROSS-PLATFORM FILE OPERATIONS
################################################################################

#------------------------------------------------------------------------------
# get_file_mtime
#
# Gets file modification time in Unix timestamp format (seconds since epoch)
# Works across Linux (GNU stat) and macOS (BSD stat)
#
# Parameters:
#   $1 - file_path: Path to file
#
# Returns:
#   0 - Success, timestamp printed to stdout
#   1 - File not found or unable to get modification time
#
# Output:
#   Unix timestamp (e.g., 1696262400)
#
# Example:
#   mtime=$(get_file_mtime "/path/to/file")
#   if [[ $? -eq 0 ]]; then
#       echo "Modified: $mtime"
#   fi
#------------------------------------------------------------------------------
get_file_mtime() {
    local file_path="$1"
    
    # Validate file exists
    if [[ ! -f "$file_path" ]]; then
        log DEBUG "File not found: $file_path"
        return 1
    fi
    
    # Try Linux stat (GNU coreutils)
    if stat -c %Y "$file_path" 2>/dev/null; then
        return 0
    fi
    
    # Try macOS/BSD stat
    if stat -f %m "$file_path" 2>/dev/null; then
        return 0
    fi
    
    # Try Perl fallback (widely available)
    if command -v perl >/dev/null 2>&1; then
        if perl -e 'print((stat($ARGV[0]))[9])' "$file_path" 2>/dev/null; then
            return 0
        fi
    fi
    
    # Try Python fallback (if available)
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import os; print(int(os.path.getmtime('$file_path')))" 2>/dev/null; then
            return 0
        fi
    fi
    
    # All methods failed
    log ERROR "Unable to get modification time for: $file_path"
    return 1
}

#------------------------------------------------------------------------------
# get_file_size
#
# Gets file size in bytes - works across Linux and macOS
#
# Parameters:
#   $1 - file_path: Path to file
#
# Returns:
#   0 - Success, size printed to stdout
#   1 - File not found
#
# Output:
#   File size in bytes
#
# Example:
#   size=$(get_file_size "/path/to/file")
#   echo "File is $size bytes"
#------------------------------------------------------------------------------
get_file_size() {
    local file_path="$1"
    
    # Validate file exists
    if [[ ! -f "$file_path" ]]; then
        log DEBUG "File not found: $file_path"
        return 1
    fi
    
    # Try Linux stat (GNU coreutils)
    if stat -c %s "$file_path" 2>/dev/null; then
        return 0
    fi
    
    # Try macOS/BSD stat
    if stat -f %z "$file_path" 2>/dev/null; then
        return 0
    fi
    
    # Fallback: use wc (POSIX-compliant, but slower)
    wc -c < "$file_path" 2>/dev/null || echo "0"
    return 0
}

#------------------------------------------------------------------------------
# atomic_write
#
# Atomically writes content to file using temp file + move pattern
# Ensures either complete write or no write (no partial files)
#
# Parameters:
#   $1 - target_file: Destination file path
#   $2 - content: Content to write
#
# Returns:
#   0 - Write successful
#   1 - Write failed
#
# Side Effects:
#   Creates temporary file in same directory as target
#   Replaces target file atomically
#
# Example:
#   if atomic_write "/path/to/config" "key=value"; then
#       echo "Config updated"
#   fi
#------------------------------------------------------------------------------
atomic_write() {
    local target_file="$1"
    local content="$2"
    
    # Validate inputs
    if [[ -z "$target_file" ]]; then
        log ERROR "atomic_write: target_file cannot be empty"
        return 1
    fi
    
    # Create temp file in same directory as target (ensures same filesystem)
    # This is critical for atomic mv operation
    local target_dir
    target_dir=$(dirname "$target_file")
    
    local temp_file
    temp_file=$(mktemp "${target_dir}/.tmp.XXXXXX") || {
        log ERROR "Failed to create temp file in: $target_dir"
        return 1
    }
    
    # Set restrictive permissions on temp file
    chmod 600 "$temp_file" || {
        log WARN "Failed to set permissions on temp file"
    }
    
    # Write content to temp file
    echo "$content" > "$temp_file" || {
        log ERROR "Failed to write to temp file: $temp_file"
        rm -f "$temp_file"
        return 1
    }
    
    # Atomic move (replaces target atomically)
    # mv is atomic when source and dest are on same filesystem
    mv "$temp_file" "$target_file" || {
        log ERROR "Failed to move temp file to target: $target_file"
        rm -f "$temp_file"
        return 1
    }
    
    log DEBUG "Atomic write successful: $target_file"
    return 0
}

#------------------------------------------------------------------------------
# create_temp_dir
#
# Creates a secure temporary directory with restrictive permissions
#
# Parameters:
#   $1 - prefix: Directory name prefix (optional, default: "backup")
#
# Returns:
#   0 - Success, directory path printed to stdout
#   1 - Failed to create directory
#
# Output:
#   Path to created temporary directory
#
# Example:
#   temp_dir=$(create_temp_dir "myapp")
#   if [[ $? -eq 0 ]]; then
#       # Use $temp_dir
#       rm -rf "$temp_dir"  # Clean up when done
#   fi
#------------------------------------------------------------------------------
create_temp_dir() {
    local prefix="${1:-backup}"
    
    # Create temp directory with mktemp
    local temp_dir
    temp_dir=$(mktemp -d -t "${prefix}.XXXXXXXXXX") || {
        log ERROR "Failed to create temporary directory"
        return 1
    }
    
    # Set secure permissions (owner only)
    chmod 700 "$temp_dir" || {
        log WARN "Failed to set permissions on temp directory"
    }
    
    log DEBUG "Created temp directory: $temp_dir"
    echo "$temp_dir"
    return 0
}

################################################################################
# PUBLIC API: ENCODING FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# safe_base64_encode
#
# Base64 encodes string without line wrapping (works on Linux and macOS)
#
# Parameters:
#   $1 - input: String to encode
#
# Returns:
#   0 - Success, encoded string printed to stdout
#   1 - Encoding failed
#
# Output:
#   Base64 encoded string (no newlines)
#
# Example:
#   encoded=$(safe_base64_encode "hello world")
#   echo "$encoded"  # aGVsbG8gd29ybGQ=
#------------------------------------------------------------------------------
safe_base64_encode() {
    local input="$1"
    
    # Encode and remove all newlines/carriage returns
    # This works around macOS base64 not supporting -w flag
    echo -n "$input" | base64 2>/dev/null | tr -d '\n\r'
    return ${PIPESTATUS[0]}
}

#------------------------------------------------------------------------------
# safe_base64_encode_url
#
# Base64 encodes string in URL-safe format (replaces +/ with -_)
#
# Parameters:
#   $1 - input: String to encode
#
# Returns:
#   0 - Success, encoded string printed to stdout
#   1 - Encoding failed
#
# Output:
#   URL-safe base64 encoded string (no padding)
#
# Example:
#   encoded=$(safe_base64_encode_url "hello/world+test")
#   echo "$encoded"  # aGVsbG8vd29ybGQrdGVzdA (URL-safe)
#------------------------------------------------------------------------------
safe_base64_encode_url() {
    local input="$1"
    
    # Encode, make URL-safe, and remove padding
    safe_base64_encode "$input" | tr '+/' '-_' | tr -d '='
}

#------------------------------------------------------------------------------
# json_escape
#
# Escapes string for safe use in JSON values
#
# Parameters:
#   $1 - input: String to escape
#
# Returns:
#   0 - Success, escaped string printed to stdout
#
# Output:
#   JSON-safe escaped string
#
# Example:
#   safe=$(json_escape 'He said "hello"')
#   echo "{\"msg\":\"$safe\"}"
#------------------------------------------------------------------------------
json_escape() {
    local input="$1"
    
    # Escape special characters for JSON
    # Order matters: backslash first, then quotes, then control chars
    echo "$input" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\t/\\t/g' \
        -e 's/\n/\\n/g' \
        -e 's/\r/\\r/g'
}

################################################################################
# PUBLIC API: SIZE CONVERSION FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# bytes_to_human
#
# Converts bytes to human-readable format (B, KB, MB, GB, TB)
#
# Parameters:
#   $1 - bytes: Size in bytes
#
# Returns:
#   0 - Success, formatted string printed to stdout
#   1 - Invalid input
#
# Output:
#   Human-readable size (e.g., "1.5 GB")
#
# Example:
#   echo "File size: $(bytes_to_human 1536000000)"  # File size: 1.4 GB
#------------------------------------------------------------------------------
bytes_to_human() {
    local bytes="$1"
    
    # Validate input is numeric
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return 1
    fi
    
    # Convert to appropriate unit
    if (( bytes >= 1099511627776 )); then
        # >= 1 TB
        if command -v bc >/dev/null 2>&1; then
            printf "%.1f TB" "$(echo "scale=1; $bytes / 1099511627776" | bc)"
        else
            printf "%d TB" "$((bytes / 1099511627776))"
        fi
    elif (( bytes >= 1073741824 )); then
        # >= 1 GB
        if command -v bc >/dev/null 2>&1; then
            printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
        else
            printf "%d GB" "$((bytes / 1073741824))"
        fi
    elif (( bytes >= 1048576 )); then
        # >= 1 MB
        if command -v bc >/dev/null 2>&1; then
            printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
        else
            printf "%d MB" "$((bytes / 1048576))"
        fi
    elif (( bytes >= 1024 )); then
        # >= 1 KB
        if command -v bc >/dev/null 2>&1; then
            printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
        else
            printf "%d KB" "$((bytes / 1024))"
        fi
    else
        # < 1 KB
        printf "%d B" "$bytes"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# bytes_to_gb
#
# Converts bytes to gigabytes with 2 decimal precision
#
# Parameters:
#   $1 - bytes: Size in bytes
#
# Returns:
#   0 - Success, GB value printed to stdout
#   1 - Invalid input
#
# Output:
#   Size in GB (e.g., "1.45")
#
# Example:
#   gb=$(bytes_to_gb 1536000000)
#   echo "Size: ${gb} GB"
#------------------------------------------------------------------------------
bytes_to_gb() {
    local bytes="$1"
    
    # Validate input is numeric
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0.00"
        return 1
    fi
    
    # Use bc for precise decimal calculation if available
    if command -v bc >/dev/null 2>&1; then
        echo "scale=2; $bytes / 1073741824" | bc 2>/dev/null || echo "0.00"
    else
        # Fallback: integer division with basic decimal approximation
        local gb=$((bytes / 1073741824))
        local remainder=$((bytes % 1073741824))
        local decimal=$((remainder * 100 / 1073741824))
        printf "%d.%02d" "$gb" "$decimal"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# calculate_size_distribution
#
# Categorizes file size into distribution bucket
#
# Parameters:
#   $1 - size_bytes: File size in bytes
#
# Returns:
#   0 - Success, category printed to stdout
#   1 - Invalid input
#
# Output:
#   One of: small, medium, large, xlarge, unknown
#
# Categories:
#   small:  < 100 MB
#   medium: 100 MB - 1 GB
#   large:  1 GB - 10 GB
#   xlarge: > 10 GB
#
# Example:
#   category=$(calculate_size_distribution 524288000)  # 500 MB
#   echo "Category: $category"  # Category: medium
#------------------------------------------------------------------------------
calculate_size_distribution() {
    local size_bytes="$1"
    
    # Validate input is numeric
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return 1
    fi
    
    # Convert to MB for comparison
    local size_mb=$((size_bytes / 1048576))
    
    # Categorize by size
    if [[ $size_mb -lt 100 ]]; then
        echo "small"
    elif [[ $size_mb -lt 1024 ]]; then
        echo "medium"
    elif [[ $size_mb -lt 10240 ]]; then
        echo "large"
    else
        echo "xlarge"
    fi
    
    return 0
}

################################################################################
# PUBLIC API: DATE/TIME FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# parse_iso8601_date
#
# Parses ISO 8601 date string to Unix timestamp (cross-platform)
#
# Parameters:
#   $1 - date_string: Date in ISO 8601 format (YYYY-MM-DDTHH:MM:SSZ)
#
# Returns:
#   0 - Success, Unix timestamp printed to stdout
#   1 - Parse failed
#
# Output:
#   Unix timestamp (seconds since epoch)
#
# Example:
#   timestamp=$(parse_iso8601_date "2025-10-02T14:30:00Z")
#   echo "Timestamp: $timestamp"
#------------------------------------------------------------------------------
parse_iso8601_date() {
    local date_string="$1"
    
    # Try GNU date (Linux)
    if date -d "$date_string" +%s 2>/dev/null; then
        return 0
    fi
    
    # Try BSD date (macOS)
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$date_string" +%s 2>/dev/null; then
        return 0
    fi
    
    # Try Python fallback
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import datetime
dt = datetime.datetime.fromisoformat('${date_string}'.replace('Z', '+00:00'))
print(int(dt.timestamp()))
" 2>/dev/null && return 0
    fi
    
    log ERROR "Unable to parse date: $date_string"
    return 1
}

#------------------------------------------------------------------------------
# get_iso8601_timestamp
#
# Gets current time in ISO 8601 format (UTC)
#
# Parameters:
#   None
#
# Returns:
#   0 - Success, timestamp printed to stdout
#
# Output:
#   ISO 8601 timestamp (e.g., "2025-10-02T14:30:00Z")
#
# Example:
#   now=$(get_iso8601_timestamp)
#   echo "Current time: $now"
#------------------------------------------------------------------------------
get_iso8601_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

################################################################################
# PUBLIC API: VALIDATION FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# is_valid_json
#
# Checks if file contains valid JSON
#
# Parameters:
#   $1 - file_path: Path to JSON file
#
# Returns:
#   0 - File contains valid JSON
#   1 - File contains invalid JSON or jq not available
#
# Example:
#   if is_valid_json "/path/to/file.json"; then
#       echo "Valid JSON"
#   fi
#------------------------------------------------------------------------------
is_valid_json() {
    local file_path="$1"
    
    # Check file exists
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    # Check jq is available
    if ! command -v jq >/dev/null 2>&1; then
        log WARN "jq not available, cannot validate JSON"
        return 1
    fi
    
    # Validate JSON structure
    jq . "$file_path" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# is_numeric
#
# Checks if string contains only numeric characters
#
# Parameters:
#   $1 - value: String to check
#
# Returns:
#   0 - String is numeric
#   1 - String is not numeric
#
# Example:
#   if is_numeric "$user_input"; then
#       echo "Valid number"
#   fi
#------------------------------------------------------------------------------
is_numeric() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]]
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f get_file_mtime get_file_size atomic_write create_temp_dir
readonly -f safe_base64_encode safe_base64_encode_url json_escape
readonly -f bytes_to_human bytes_to_gb calculate_size_distribution
readonly -f parse_iso8601_date get_iso8601_timestamp
readonly -f is_valid_json is_numeric

# Log module initialization (only in DEBUG mode)
log DEBUG "Module loaded: $UTILS_MODULE_NAME v$UTILS_MODULE_VERSION (API v$UTILS_API_VERSION)"

################################################################################
# MODULE SELF-VALIDATION (Optional, enabled via MODULE_VALIDATE flag)
################################################################################

validate_module_utils() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "get_file_mtime" "get_file_size" "atomic_write" "create_temp_dir"
        "safe_base64_encode" "safe_base64_encode_url" "json_escape"
        "bytes_to_human" "bytes_to_gb" "calculate_size_distribution"
        "parse_iso8601_date" "get_iso8601_timestamp"
        "is_valid_json" "is_numeric"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $UTILS_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    if ! declare -F "log" >/dev/null 2>&1; then
        log ERROR "Module $UTILS_MODULE_NAME: Missing dependency function 'log' from core.sh"
        ((errors++))
    fi
    
    # Check module metadata
    if [[ -z "${UTILS_MODULE_VERSION:-}" ]]; then
        log ERROR "Module $UTILS_MODULE_NAME: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

# Run validation if MODULE_VALIDATE environment variable is set
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    if ! validate_module_utils; then
        die "Module validation failed: $UTILS_MODULE_NAME" $EX_SOFTWARE
    fi
fi

################################################################################
# END OF MODULE
################################################################################

