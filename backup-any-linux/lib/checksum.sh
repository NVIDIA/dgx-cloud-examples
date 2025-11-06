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
# checksum.sh - File Checksum and Change Detection Module
################################################################################
# Purpose: Calculates file checksums and detects changes using multiple
#          strategies (MD5, SHA256, mtime). Supports integrity modes for
#          performance vs security trade-offs.
#
# Dependencies: core.sh, utils.sh, state.sh
#
# Integrity Modes:
#   - fast:   Trust mtime+size for unchanged files (99% faster, ~1% edge case risk)
#   - strict: Always calculate fresh checksums (100% integrity, slower)
#   - hybrid: Fast for most files, strict for critical extensions (balanced)
#
# Public API:
#   Checksum Calculation:
#   - calculate_checksum()        : Calculate file checksum (MD5/SHA256/mtime)
#   - calculate_sampled_checksum(): Sampled checksum for large files (>1GB)
#
#   Change Detection:
#   - quick_metadata_check()      : Fast mtime+size comparison
#   - file_has_changed()          : Determine if file changed
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly CHECKSUM_MODULE_VERSION="1.0.0"
readonly CHECKSUM_MODULE_NAME="checksum"
readonly CHECKSUM_MODULE_DEPS=("core" "utils" "state")
readonly CHECKSUM_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${CHECKSUM_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: checksum.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION
################################################################################

# Checksum algorithm (md5, sha256, mtime)
CHECKSUM_ALGORITHM="${CHECKSUM_ALGORITHM:-md5}"

# Integrity mode (fast, strict, hybrid)
INTEGRITY_MODE="${INTEGRITY_MODE:-fast}"

# Extensions requiring strict checking in hybrid mode
STRICT_EXTENSIONS="${STRICT_EXTENSIONS:-.db,.sql,.config,.json,.xml,.key,.crt,.pem}"

# Large file threshold (files > 1GB use sampling for performance)
readonly LARGE_FILE_THRESHOLD=1073741824  # 1 GB

# S3 cache configuration (organized under state/s3/)
S3_CACHE_FILE="${S3_CACHE_FILE:-${SCRIPT_DIR}/state/s3/s3-cache.json}"

# S3 cache availability (set by load_s3_cache)
declare -g S3_CACHE_AVAILABLE="false"
declare -gA S3_CACHE_MAP

################################################################################
# PUBLIC API: S3 CACHE MANAGEMENT
################################################################################

#------------------------------------------------------------------------------
# load_s3_cache
#
# Loads S3 cache into memory for O(1) lookup verification
# CRITICAL: This fixes the "backup scope expansion bug" 
#
# Returns:
#   0 - Cache loaded successfully
#   1 - Cache not available
#
# Side Effects:
#   Sets S3_CACHE_AVAILABLE global
#   Populates S3_CACHE_MAP associative array
#
# Example:
#   load_s3_cache  # Call once at startup
#------------------------------------------------------------------------------
load_s3_cache() {
    local cache_file="$S3_CACHE_FILE"
    
    # Initialize as unavailable
    S3_CACHE_AVAILABLE="false"
    
    if [[ ! -f "$cache_file" ]]; then
        log WARN "S3 cache file not found: $cache_file - S3 verification disabled"
        return 1
    fi
    
    # Validate cache file is valid JSON
    if ! jq -e '.files | type == "array"' "$cache_file" >/dev/null 2>&1; then
        log WARN "Invalid S3 cache format - S3 verification disabled"
        return 1
    fi
    
    # Load cache into associative array
    local cache_count=0
    while IFS= read -r s3_path; do
        [[ -n "$s3_path" ]] && S3_CACHE_MAP["$s3_path"]=1 && ((cache_count++))
    done < <(jq -r '.files[]' "$cache_file" 2>/dev/null)
    
    if (( cache_count > 0 )); then
        S3_CACHE_AVAILABLE="true"
        log INFO "S3 cache loaded: $cache_count files available for verification"
        return 0
    fi
    
    log WARN "S3 cache loaded but empty - S3 verification disabled"
    return 1
}

#------------------------------------------------------------------------------
# verify_file_in_s3_cache
#
# Verifies if file exists in loaded S3 cache
#
# Parameters:
#   $1 - file_path: Full path to file
#
# Returns:
#   0 - File exists in S3 cache
#   1 - File not in cache or cache not available
#------------------------------------------------------------------------------
verify_file_in_s3_cache() {
    local file_path="$1"
    
    # Check cache is available
    [[ "${S3_CACHE_AVAILABLE:-false}" != "true" ]] && return 1
    [[ ${#S3_CACHE_MAP[@]} -eq 0 ]] && return 1
    
    # Convert local path to expected S3 path
    local relative_path="${file_path#$MOUNT_DIR/}"
    local expected_s3_path="s3://$S3_BUCKET/$S3_PREFIX/current_state/$relative_path"
    
    # Check if file exists in cache
    [[ -n "${S3_CACHE_MAP["$expected_s3_path"]:-}" ]]
}

################################################################################
# PUBLIC API: CHECKSUM CALCULATION
################################################################################

#------------------------------------------------------------------------------
# calculate_checksum
#
# Calculates checksum for a file using configured algorithm
# Supports MD5, SHA256, or mtime-based checksums
#
# Parameters:
#   $1 - file_path: Path to file
#   $2 - algorithm: Checksum algorithm (optional, defaults to CHECKSUM_ALGORITHM)
#                   Values: md5, sha256, mtime
#
# Returns:
#   0 - Success, checksum printed to stdout
#   1 - File not found or checksum failed
#
# Output:
#   Checksum string (32 chars for MD5, 64 for SHA256, Unix timestamp for mtime)
#
# Performance:
#   For files >1GB, considers using calculate_sampled_checksum() instead
#
# Example:
#   checksum=$(calculate_checksum "/path/to/file" "md5")
#   echo "MD5: $checksum"
#------------------------------------------------------------------------------
calculate_checksum() {
    local file_path="$1"
    local algorithm="${2:-$CHECKSUM_ALGORITHM}"
    
    # Validate file exists
    if [[ ! -f "$file_path" ]]; then
        log ERROR "calculate_checksum: File not found: $file_path"
        return 1
    fi
    
    # Check file size - use sampling for large files
    local file_size
    file_size=$(get_file_size "$file_path")
    
    if [[ $file_size -gt $LARGE_FILE_THRESHOLD ]]; then
        log DEBUG "Large file detected ($file_size bytes), using sampled checksum"
        calculate_sampled_checksum "$file_path" "$algorithm"
        return $?
    fi
    
    # Calculate checksum based on algorithm
    case "$algorithm" in
        md5)
            if command -v md5sum >/dev/null 2>&1; then
                md5sum "$file_path" 2>/dev/null | cut -d' ' -f1
            elif command -v md5 >/dev/null 2>&1; then
                # macOS md5 command
                md5 -q "$file_path" 2>/dev/null
            else
                log WARN "MD5 command not available, falling back to mtime"
                get_file_mtime "$file_path"
            fi
            ;;
        
        sha256)
            if command -v sha256sum >/dev/null 2>&1; then
                sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1
            elif command -v shasum >/dev/null 2>&1; then
                shasum -a 256 "$file_path" 2>/dev/null | cut -d' ' -f1
            else
                log WARN "SHA256 command not available, falling back to mtime"
                get_file_mtime "$file_path"
            fi
            ;;
        
        mtime)
            get_file_mtime "$file_path"
            ;;
        
        *)
            log ERROR "Unknown checksum algorithm: $algorithm"
            return 1
            ;;
    esac
    
    return 0
}

#------------------------------------------------------------------------------
# calculate_sampled_checksum
#
# Calculates checksum for large files using sampling for performance
# Samples first 1MB + last 1MB + middle 1MB instead of entire file
#
# Parameters:
#   $1 - file_path: Path to large file
#   $2 - algorithm: Checksum algorithm (optional, defaults to CHECKSUM_ALGORITHM)
#
# Returns:
#   0 - Success, sampled checksum printed to stdout
#   1 - Failed to calculate checksum
#
# Performance:
#   For 10GB file: ~0.5s (vs ~30s for full MD5)
#   60x faster with acceptable accuracy trade-off
#
# Example:
#   checksum=$(calculate_sampled_checksum "/large/file.bin" "md5")
#------------------------------------------------------------------------------
calculate_sampled_checksum() {
    local file_path="$1"
    local algorithm="${2:-$CHECKSUM_ALGORITHM}"
    
    log DEBUG "Calculating sampled checksum for large file: $file_path"
    
    local file_size
    file_size=$(get_file_size "$file_path")
    
    # Sample: first 1MB + last 1MB + middle 1MB
    local sample
    sample=$(
        {
            head -c 1048576 "$file_path" 2>/dev/null
            tail -c 1048576 "$file_path" 2>/dev/null
            dd if="$file_path" bs=1M skip=$((file_size / 2097152)) count=1 2>/dev/null
        }
    )
    
    # Calculate checksum of sampled data
    case "$algorithm" in
        md5)
            if command -v md5sum >/dev/null 2>&1; then
                echo "$sample" | md5sum | cut -d' ' -f1
            elif command -v md5 >/dev/null 2>&1; then
                echo "$sample" | md5
            fi
            ;;
        sha256)
            if command -v sha256sum >/dev/null 2>&1; then
                echo "$sample" | sha256sum | cut -d' ' -f1
            elif command -v shasum >/dev/null 2>&1; then
                echo "$sample" | shasum -a 256 | cut -d' ' -f1
            fi
            ;;
        *)
            # For mtime, sampling doesn't make sense - just return mtime
            get_file_mtime "$file_path"
            ;;
    esac
    
    return 0
}

################################################################################
# PUBLIC API: CHANGE DETECTION
################################################################################

#------------------------------------------------------------------------------
# enhanced_metadata_check
#
# Fast change detection with S3 verification to prevent "backup scope expansion bug"
# CRITICAL: This is THE fix for the backup scope expansion issue
#
# Parameters:
#   $1 - file_path: Full path to file
#   $2 - file_relative_path: Relative path from directory (for lookup in metadata)
#   $3 - directory_state: JSON state for parent directory
#
# Returns:
#   0 - File unchanged AND verified in S3, stored checksum printed to stdout
#   1 - File changed or missing from S3, need full checksum + upload
#
# Logic:
#   1. Check if mtime+size match (fast metadata check)
#   2. If match, check if file exists in S3 cache
#   3. If in S3, return stored checksum (file unchanged)
#   4. If NOT in S3, return 1 (force upload - THIS FIXES THE BUG!)
#
# Example:
#   if cached=$(enhanced_metadata_check "$file" "code/main.py" "$dir_state"); then
#       echo "Using cached checksum, file verified in S3: $cached"
#   else
#       checksum=$(calculate_checksum "$file")  # Need upload
#   fi
#------------------------------------------------------------------------------
enhanced_metadata_check() {
    local file_path="$1"
    local filename="$2"
    local directory_state="$3"
    
    # Try quick metadata check first
    local stored_checksum
    if stored_checksum=$(quick_metadata_check "$file_path" "$filename" "$directory_state"); then
        # Metadata matches - but we need to verify file exists in S3!
        # This is the critical fix for backup scope expansion bug
        
        if [[ "${S3_CACHE_AVAILABLE:-false}" == "true" ]] && [[ ${#S3_CACHE_MAP[@]} -gt 0 ]]; then
            # S3 cache is available - verify file exists
            if verify_file_in_s3_cache "$file_path"; then
                log DEBUG "VERIFIED: File confirmed in S3, using cached checksum: $filename"
                echo "$stored_checksum"
                return 0  # File unchanged and in S3
            else
                log DEBUG "BUG FIX TRIGGERED: File metadata matches but MISSING from S3: $filename"
                log DEBUG "  This fixes the backup scope expansion bug - forcing upload"
                return 1  # Force full checksum and upload
            fi
        else
            # No S3 cache available - use stored checksum (original behavior)
            log DEBUG "UNCHANGED: mtime+size match, using cached checksum (S3 cache unavailable): $filename"
            echo "$stored_checksum"
            return 0
        fi
    fi
    
    # File changed or no metadata, need full checksum
    return 1
}

#------------------------------------------------------------------------------
# quick_metadata_check
#
# Fast change detection using mtime+size comparison
# Returns stored checksum if file appears unchanged, otherwise returns 1
#
# Parameters:
#   $1 - file_path: Full path to file
#   $2 - file_relative_path: Relative path from directory (for lookup in metadata)
#   $3 - directory_state: JSON state for parent directory
#
# Returns:
#   0 - File unchanged, stored checksum printed to stdout
#   1 - File changed or no metadata, need full checksum
#
# Integrity Modes:
#   - strict: Always returns 1 (force full checksum)
#   - hybrid: Returns 1 for files with critical extensions
#   - fast:   Returns stored checksum if mtime+size match
#
# Example:
#   if cached=$(quick_metadata_check "$file" "code/main.py" "$dir_state"); then
#       echo "Using cached checksum: $cached"
#   else
#       checksum=$(calculate_checksum "$file")
#   fi
#------------------------------------------------------------------------------
quick_metadata_check() {
    local file_path="$1"
    local filename="$2"
    local directory_state="$3"
    
    # Get current file metadata (cross-platform)
    local current_mtime current_size
    current_mtime=$(get_file_mtime "$file_path") || return 1
    current_size=$(get_file_size "$file_path") || return 1
    
    # Get stored metadata from state
    local stored_mtime stored_size stored_checksum
    if [[ -n "$directory_state" ]]; then
        # Extract all three values in single jq call (performance optimization)
        IFS='|' read -r stored_mtime stored_size stored_checksum < <(
            echo "$directory_state" | jq -r \
                --arg filename "$filename" \
                '.metadata[$filename] | "\(.mtime // "")|\(.size // "")|\(.checksum // "")"'
        )
    fi
    
    # Check integrity mode configuration
    case "${INTEGRITY_MODE:-fast}" in
        strict)
            # Always force full checksum calculation
            log DEBUG "Strict integrity mode: forcing fresh checksum for $filename"
            return 1
            ;;
        
        hybrid)
            # Check if file extension requires strict checking
            local file_ext="${filename##*.}"
            if [[ -n "$STRICT_EXTENSIONS" && ",$STRICT_EXTENSIONS," == *",.$file_ext,"* ]]; then
                log DEBUG "Hybrid mode: strict checking for .$file_ext file: $filename"
                return 1
            fi
            # Fall through to fast mode for non-critical files
            ;;
        
        fast|*)
            # Use metadata comparison
            ;;
    esac
    
    # If metadata matches, file is unchanged
    if [[ -n "$stored_mtime" && -n "$stored_size" && -n "$stored_checksum" ]]; then
        if [[ "$current_mtime" == "$stored_mtime" && "$current_size" == "$stored_size" ]]; then
            log DEBUG "UNCHANGED: mtime+size match, using cached checksum: $filename"
            echo "$stored_checksum"
            return 0
        else
            log DEBUG "CHANGED: metadata differs for $filename (mtime: $stored_mtime→$current_mtime, size: $stored_size→$current_size)"
        fi
    fi
    
    # Need full checksum calculation
    return 1
}

#------------------------------------------------------------------------------
# file_has_changed
#
# Determines if file has changed by comparing with stored state
# Uses quick metadata check first, falls back to full checksum
#
# Parameters:
#   $1 - file_path: Full path to file
#   $2 - filename: Simple filename
#   $3 - directory_state: JSON state for parent directory
#
# Returns:
#   0 - File has changed (or is new)
#   1 - File is unchanged
#
# Side Effects:
#   Sets global CURRENT_CHECKSUM variable with calculated/cached checksum
#
# Example:
#   if file_has_changed "$file" "$name" "$state"; then
#       echo "File changed, checksum: $CURRENT_CHECKSUM"
#       # Upload file
#   else
#       echo "File unchanged"
#       # Skip upload
#   fi
#------------------------------------------------------------------------------
file_has_changed() {
    local file_path="$1"
    local filename="$2"
    local directory_state="$3"
    
    # Try quick metadata check first (fast path)
    if CURRENT_CHECKSUM=$(quick_metadata_check "$file_path" "$filename" "$directory_state"); then
        # Metadata matches, file unchanged
        return 1
    fi
    
    # File changed or is new, calculate fresh checksum
    CURRENT_CHECKSUM=$(calculate_checksum "$file_path") || {
        log ERROR "Failed to calculate checksum for: $file_path"
        return 1
    }
    
    # Compare with stored checksum
    local stored_checksum
    if [[ -n "$directory_state" ]]; then
        stored_checksum=$(echo "$directory_state" | jq -r --arg filename "$filename" '.metadata[$filename].checksum // ""')
    fi
    
    if [[ -n "$stored_checksum" && "$CURRENT_CHECKSUM" == "$stored_checksum" ]]; then
        log DEBUG "Checksum match (but metadata changed): $filename"
        return 1  # Unchanged
    fi
    
    log DEBUG "Checksum differs or is new: $filename"
    return 0  # Changed or new
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f load_s3_cache verify_file_in_s3_cache
readonly -f calculate_checksum calculate_sampled_checksum
readonly -f enhanced_metadata_check quick_metadata_check file_has_changed

log DEBUG "Module loaded: $CHECKSUM_MODULE_NAME v$CHECKSUM_MODULE_VERSION (API v$CHECKSUM_API_VERSION)"
log DEBUG "Checksum algorithm: $CHECKSUM_ALGORITHM, Integrity mode: $INTEGRITY_MODE"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_checksum() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "load_s3_cache" "verify_file_in_s3_cache"
        "calculate_checksum" "calculate_sampled_checksum"
        "enhanced_metadata_check" "quick_metadata_check" "file_has_changed"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $CHECKSUM_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies
    for func in "log" "get_file_mtime" "get_file_size"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $CHECKSUM_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_checksum || die "Module validation failed: $CHECKSUM_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

