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
# state-backup.sh - State File Backup and Recovery Module
################################################################################
# Purpose: Backs up state files to S3 for disaster recovery and recovers them
#          when local state is missing or corrupted. Implements conservative
#          automation with no user prompts for unattended cron operations.
#
# Dependencies: core.sh, utils.sh, config.sh, state.sh, s3.sh
#
# Recovery Strategy:
#   - Conservative: Prefer local state when both valid and close in age
#   - Safe: Never blind overwrite - always validate and backup first
#   - Automated: No user prompts - decisions based on validation and age
#   - Audited: Log every recovery decision for troubleshooting
#
# Decision Rules (Automated):
#   - Local missing → Use S3
#   - Local corrupt → Use S3 (if S3 valid)
#   - S3 much newer (>2h) → Use S3 (likely recovery scenario)
#   - S3 slightly newer (<2h) → Keep local (likely clock skew)
#   - Local newer or equal → Keep local (default to local)
#
# Public API:
#   Backup:
#   - backup_high_level_states_to_s3()   : Upload state files to S3
#   - validate_before_upload()            : Validate state before uploading
#
#   Recovery:
#   - recover_high_level_states_from_s3() : Recover states if needed
#   - recover_single_state_file()         : Handle one state file
#   - decide_state_version()              : Automated decision logic
#
#   Validation:
#   - validate_state_file_safe()          : Multi-level state validation
#   - get_state_age_seconds()             : Calculate state file age
#
#   Safety:
#   - safe_replace_state()                : Backup + atomic replace
#   - log_recovery_decision()             : Audit recovery decisions
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-03
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly STATEBACKUP_MODULE_VERSION="1.0.0"
readonly STATEBACKUP_MODULE_NAME="statebackup"
readonly STATEBACKUP_MODULE_DEPS=("core" "utils" "config" "state" "s3")
readonly STATEBACKUP_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

for dep in "${STATE_BACKUP_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: state-backup.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION
################################################################################

# Age threshold for automated decisions (2 hours in seconds)
readonly STATE_AGE_THRESHOLD_SECONDS=7200  # 2 hours

# Recovery audit log
readonly RECOVERY_AUDIT_LOG="${STATE_DIR:-${SCRIPT_DIR}/state}/recovery-audit.jsonl"

################################################################################
# PRIVATE HELPER FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# _get_s3_state_backup_prefix
#
# Constructs S3 state backup prefix dynamically (after config is loaded)
# Uses state_backups (underscore) for consistency with current_state/yesterday_state
#
# Parameters:
#   None (uses global S3_PREFIX from config)
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   S3 prefix path for state backups (without s3://bucket/)
#
# Example:
#   prefix=$(_get_s3_state_backup_prefix)
#   # Returns: "Internal-sa-cluster/state_backups" or "state_backups"
#
# Internal Use Only
#------------------------------------------------------------------------------
_get_s3_state_backup_prefix() {
    # Construct prefix: S3_PREFIX/state_backups (or just state_backups if no prefix)
    if [[ -n "${S3_PREFIX:-}" ]]; then
        echo "${S3_PREFIX}/state_backups"
    else
        echo "state_backups"
    fi
}

################################################################################
# PUBLIC API: VALIDATION
################################################################################

#------------------------------------------------------------------------------
# validate_state_file_safe
#
# Multi-level validation of state file for safety
#
# Parameters:
#   $1 - state_file: Path to state file
#   $2 - file_type: Type (backup, yesterday, permanent, directory)
#
# Returns:
#   0 - State file is valid
#   1 - State file is invalid or corrupt
#
# Example:
#   if validate_state_file_safe "$file" "backup"; then
#       echo "State is valid"
#   fi
#------------------------------------------------------------------------------
validate_state_file_safe() {
    local state_file="$1"
    local file_type="${2:-unknown}"
    
    log DEBUG "Validating $file_type state file: $state_file"
    
    # Level 1: File exists and is readable
    if [[ ! -f "$state_file" ]]; then
        log DEBUG "Validation failed: File does not exist"
        return 1
    fi
    
    if [[ ! -r "$state_file" ]]; then
        log ERROR "Validation failed: File not readable: $state_file"
        return 1
    fi
    
    # Level 2: Non-empty file
    if [[ ! -s "$state_file" ]]; then
        log DEBUG "Validation failed: File is empty"
        return 1
    fi
    
    # Level 3: Valid JSON
    if ! jq empty "$state_file" 2>/dev/null; then
        log WARN "Validation failed: Invalid JSON in $file_type state file"
        return 1
    fi
    
    # Level 4: Required fields exist
    if ! jq -e '.state_file_version' "$state_file" >/dev/null 2>&1; then
        log WARN "Validation failed: Missing state_file_version"
        return 1
    fi
    
    if ! jq -e '.last_updated' "$state_file" >/dev/null 2>&1; then
        log WARN "Validation failed: Missing last_updated timestamp"
        return 1
    fi
    
    # Level 5: Timestamp sanity check
    local ts=$(jq -r '.last_updated' "$state_file" 2>/dev/null)
    local ts_epoch=$(parse_iso8601_date "$ts" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local age=$((now - ts_epoch))
    
    # Reject future timestamps (corrupted or clock issue)
    if [[ $age -lt -3600 ]]; then
        log WARN "Validation failed: Timestamp is >1h in future (corrupted?)"
        return 1
    fi
    
    # Warn if very old (>30 days) but don't fail
    if [[ $age -gt 2592000 ]]; then
        log WARN "$file_type state is $((age/86400)) days old - might be stale"
    fi
    
    log DEBUG "$file_type state validation passed"
    return 0
}

#------------------------------------------------------------------------------
# get_state_age_seconds
#
# Calculate age of state file in seconds
#
# Parameters:
#   $1 - state_file: Path to state file
#
# Returns:
#   0 - Success, age in seconds printed to stdout
#   1 - Failed to get age
#
# Output:
#   Age in seconds (or "unknown")
#------------------------------------------------------------------------------
get_state_age_seconds() {
    local state_file="$1"
    
    if [[ ! -f "$state_file" ]]; then
        echo "unknown"
        return 1
    fi
    
    local ts=$(jq -r '.last_updated // ""' "$state_file" 2>/dev/null)
    if [[ -z "$ts" ]]; then
        echo "unknown"
        return 1
    fi
    
    local ts_epoch=$(parse_iso8601_date "$ts" 2>/dev/null || echo "0")
    if [[ "$ts_epoch" == "0" ]]; then
        echo "unknown"
        return 1
    fi
    
    local now=$(date +%s)
    local age=$((now - ts_epoch))
    
    echo "$age"
    return 0
}

################################################################################
# PUBLIC API: BACKUP TO S3
################################################################################

#------------------------------------------------------------------------------
# backup_high_level_states_to_s3
#
# Uploads high-level state files to S3 after validation
# Safe: Only uploads valid files, non-blocking on failures
#
# Parameters:
#   None (uses global configuration)
#
# Returns:
#   0 - All files backed up successfully
#   1 - Some or all uploads failed
#
# Example:
#   backup_high_level_states_to_s3
#------------------------------------------------------------------------------
backup_high_level_states_to_s3() {
    log INFO "Backing up state files to S3..."
    
    # Get S3 prefix dynamically (after config is loaded)
    local s3_state_backup_prefix
    s3_state_backup_prefix=$(_get_s3_state_backup_prefix)
    
    # Define state files to backup
    local -a state_files=(
        "${AGGREGATE_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/backup-state-LATEST.json|backup"
        "${YESTERDAY_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/yesterday-backup-state-LATEST.json|yesterday"
        "${PERMANENT_DELETIONS_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/permanent-deletions-history-LATEST.json|permanent"
        "${DIRECTORY_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/directory-state-LATEST.json|directory"
    )
    
    local upload_count=0
    local error_count=0
    
    for state_entry in "${state_files[@]}"; do
        # Parse entry: local_file|s3_path|type
        if [[ "$state_entry" =~ ^([^|]+)\|([^|]+)\|(.+)$ ]]; then
            local local_file="${BASH_REMATCH[1]}"
            local s3_path="${BASH_REMATCH[2]}"
            local file_type="${BASH_REMATCH[3]}"
        else
            log ERROR "Invalid state entry format: $state_entry"
            ((error_count++))
            continue
        fi
        
        # Skip if file doesn't exist (not an error - might not be created yet)
        if [[ ! -f "$local_file" ]]; then
            log DEBUG "Skipping $file_type state (doesn't exist yet): $local_file"
            continue
        fi
        
        # Validate before uploading
        if ! validate_state_file_safe "$local_file" "$file_type"; then
            log ERROR "Skipping $file_type state upload (validation failed)"
            ((error_count++))
            continue
        fi
        
        log DEBUG "Uploading $file_type state: $local_file → $s3_path"
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log INFO "[DRY-RUN] Would upload $file_type state to S3"
            ((upload_count++))
        else
            # Upload to S3
            if s3_upload "$local_file" "$s3_path" false; then
                log INFO "✓ Uploaded $file_type state to S3"
                ((upload_count++))
            else
                log ERROR "✗ Failed to upload $file_type state to S3"
                ((error_count++))
            fi
        fi
    done
    
    log INFO "State backup summary: $upload_count uploaded, $error_count errors"
    
    [[ $error_count -eq 0 ]] && return 0 || return 1
}

################################################################################
# PUBLIC API: RECOVERY FROM S3
################################################################################

#------------------------------------------------------------------------------
# recover_high_level_states_from_s3
#
# Recovers high-level state files from S3 if needed
# Automated: Makes safe decisions without user prompts
#
# Parameters:
#   None (uses global configuration)
#
# Returns:
#   0 - Recovery completed successfully
#   1 - Recovery had errors
#
# Example:
#   recover_high_level_states_from_s3
#------------------------------------------------------------------------------
recover_high_level_states_from_s3() {
    log INFO "Checking state files for S3 recovery..."
    
    # Get S3 prefix dynamically (after config is loaded)
    local s3_state_backup_prefix
    s3_state_backup_prefix=$(_get_s3_state_backup_prefix)
    
    # Define state files to check
    local -a state_files=(
        "${AGGREGATE_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/backup-state-LATEST.json|backup"
        "${YESTERDAY_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/yesterday-backup-state-LATEST.json|yesterday"
        "${PERMANENT_DELETIONS_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/permanent-deletions-history-LATEST.json|permanent"
        "${DIRECTORY_STATE_FILE}|s3://${S3_BUCKET}/${s3_state_backup_prefix}/directory-state-LATEST.json|directory"
    )
    
    local recovery_count=0
    local error_count=0
    
    for state_entry in "${state_files[@]}"; do
        # Parse entry
        if [[ "$state_entry" =~ ^([^|]+)\|([^|]+)\|(.+)$ ]]; then
            local local_file="${BASH_REMATCH[1]}"
            local s3_path="${BASH_REMATCH[2]}"
            local file_type="${BASH_REMATCH[3]}"
        else
            log ERROR "Invalid state entry format: $state_entry"
            continue
        fi
        
        if recover_single_state_file "$local_file" "$s3_path" "$file_type"; then
            ((recovery_count++))
        else
            ((error_count++))
        fi
    done
    
    if [[ $recovery_count -gt 0 ]]; then
        log INFO "✅ State recovery: $recovery_count files recovered, $error_count errors"
    else
        log DEBUG "No state recovery needed (all local states are current)"
    fi
    
    [[ $error_count -eq 0 ]] && return 0 || return 1
}

#------------------------------------------------------------------------------
# recover_single_state_file
#
# Recovers a single state file from S3 if needed
# Implements automated decision logic with conservative bias
#
# Parameters:
#   $1 - local_file: Local state file path
#   $2 - s3_path: S3 path to state file
#   $3 - file_type: Type (backup, yesterday, permanent, directory)
#
# Returns:
#   0 - Recovery successful or not needed
#   1 - Recovery failed
#
# Example:
#   recover_single_state_file "$AGGREGATE_STATE_FILE" "s3://..." "backup"
#------------------------------------------------------------------------------
recover_single_state_file() {
    local local_file="$1"
    local s3_path="$2"
    local file_type="$3"
    
    log DEBUG "Checking $file_type state for recovery..."
    
    # Validate local state
    local local_valid=false
    local local_age="unknown"
    if validate_state_file_safe "$local_file" "$file_type" 2>/dev/null; then
        local_valid=true
        local_age=$(get_state_age_seconds "$local_file")
        log DEBUG "Local $file_type state: VALID (age: ${local_age}s)"
    else
        log DEBUG "Local $file_type state: INVALID or MISSING"
    fi
    
    # Download S3 state to temp location
    local temp_s3_file
    temp_s3_file=$(mktemp) || {
        log ERROR "Failed to create temp file for S3 download"
        return 1
    }
    
    local s3_valid=false
    local s3_age="unknown"
    if s3_download "$s3_path" "$temp_s3_file" false 2>/dev/null; then
        if validate_state_file_safe "$temp_s3_file" "$file_type" 2>/dev/null; then
            s3_valid=true
            s3_age=$(get_state_age_seconds "$temp_s3_file")
            log DEBUG "S3 $file_type state: VALID (age: ${s3_age}s)"
        else
            log DEBUG "S3 $file_type state: INVALID"
            rm -f "$temp_s3_file"
        fi
    else
        log DEBUG "S3 $file_type state: NOT AVAILABLE"
        rm -f "$temp_s3_file"
    fi
    
    # Make automated decision
    local decision
    local reason
    decision=$(decide_state_version "$local_valid" "$s3_valid" "$local_age" "$s3_age")
    
    case "$decision" in
        use_s3)
            reason="S3 version selected"
            log INFO "Recovering $file_type state from S3"
            
            if safe_replace_state "$temp_s3_file" "$local_file" "$file_type"; then
                log_recovery_decision "$file_type" "used_s3" "$reason" "$local_age" "$s3_age"
                return 0
            else
                log ERROR "Failed to replace local with S3 version"
                rm -f "$temp_s3_file"
                return 1
            fi
            ;;
            
        keep_local)
            reason="Local version is current"
            log DEBUG "Keeping local $file_type state"
            log_recovery_decision "$file_type" "kept_local" "$reason" "$local_age" "$s3_age"
            rm -f "$temp_s3_file"
            return 0
            ;;
            
        init_new)
            reason="No valid state available"
            log INFO "$file_type state will be initialized"
            log_recovery_decision "$file_type" "initialized" "$reason" "$local_age" "$s3_age"
            rm -f "$temp_s3_file"
            return 0
            ;;
            
        fail)
            reason="Both local and S3 are corrupt"
            log ERROR "Cannot recover $file_type state - both local and S3 are invalid"
            log_recovery_decision "$file_type" "failed" "$reason" "$local_age" "$s3_age"
            rm -f "$temp_s3_file"
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# decide_state_version
#
# Automated decision logic for which state version to use
# Conservative: Prefers local when both valid and close in age
#
# Parameters:
#   $1 - local_valid: "true" or "false"
#   $2 - s3_valid: "true" or "false"
#   $3 - local_age: Age in seconds or "unknown"
#   $4 - s3_age: Age in seconds or "unknown"
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   Decision: "use_s3", "keep_local", "init_new", or "fail"
#
# Example:
#   decision=$(decide_state_version "true" "true" "3600" "7200")
#------------------------------------------------------------------------------
decide_state_version() {
    local local_valid="$1"
    local s3_valid="$2"
    local local_age="$3"
    local s3_age="$4"
    
    # Decision matrix (conservative automation)
    
    # Case 1: Local missing or corrupt
    if [[ "$local_valid" != "true" ]]; then
        if [[ "$s3_valid" == "true" ]]; then
            echo "use_s3"  # Recovery scenario
        else
            echo "init_new"  # Both missing/corrupt
        fi
        return 0
    fi
    
    # Case 2: Local valid, S3 missing or corrupt
    if [[ "$s3_valid" != "true" ]]; then
        echo "keep_local"  # Local is good, S3 isn't
        return 0
    fi
    
    # Case 3: Both valid - compare ages
    if [[ "$local_age" == "unknown" || "$s3_age" == "unknown" ]]; then
        echo "keep_local"  # Can't compare, default to local
        return 0
    fi
    
    local age_diff=$((s3_age - local_age))
    local age_diff_abs=${age_diff#-}  # Absolute value
    
    # S3 is newer (negative age_diff means S3 is younger)
    if [[ $age_diff -lt 0 ]]; then
        age_diff_abs=${age_diff#-}
        
        if [[ $age_diff_abs -gt $STATE_AGE_THRESHOLD_SECONDS ]]; then
            echo "use_s3"  # S3 much newer (>2h) - likely recovery
        else
            echo "keep_local"  # S3 slightly newer (<2h) - likely clock skew
        fi
    else
        # Local is newer or same age
        echo "keep_local"  # Default to local
    fi
    
    return 0
}

################################################################################
# PUBLIC API: SAFETY OPERATIONS
################################################################################

#------------------------------------------------------------------------------
# safe_replace_state
#
# Safely replaces local state file with backup before replacing
#
# Parameters:
#   $1 - new_file: New state file (from S3)
#   $2 - target_file: Target local file to replace
#   $3 - file_type: Type for logging
#
# Returns:
#   0 - Replacement successful
#   1 - Replacement failed
#
# Example:
#   safe_replace_state "$temp_s3_file" "$AGGREGATE_STATE_FILE" "backup"
#------------------------------------------------------------------------------
safe_replace_state() {
    local new_file="$1"
    local target_file="$2"
    local file_type="$3"
    
    # Create backup of existing file (even if we think it's corrupt)
    if [[ -f "$target_file" ]]; then
        local backup_file="${target_file}.pre-recovery-$(date +%Y%m%d_%H%M%S)"
        if cp "$target_file" "$backup_file"; then
            log INFO "Created backup of local $file_type state: $backup_file"
        else
            log WARN "Failed to backup existing $file_type state"
        fi
    fi
    
    # Ensure target directory exists
    local target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir" 2>/dev/null || {
        log ERROR "Failed to create target directory: $target_dir"
        rm -f "$new_file"
        return 1
    }
    
    # Atomic replace
    if mv "$new_file" "$target_file"; then
        log INFO "✓ Successfully replaced local $file_type state with S3 version"
        return 0
    else
        log ERROR "Failed to replace $file_type state file"
        rm -f "$new_file"
        return 1
    fi
}

#------------------------------------------------------------------------------
# log_recovery_decision
#
# Logs recovery decision to audit trail
#
# Parameters:
#   $1 - file_type: Type of state file
#   $2 - decision: Decision made (used_s3, kept_local, initialized, failed)
#   $3 - reason: Reason for decision
#   $4 - local_age: Local file age
#   $5 - s3_age: S3 file age
#
# Returns:
#   0 - Always succeeds
#
# Example:
#   log_recovery_decision "backup" "used_s3" "local_corrupt" "unknown" "3600"
#------------------------------------------------------------------------------
log_recovery_decision() {
    local file_type="$1"
    local decision="$2"
    local reason="$3"
    local local_age="$4"
    local s3_age="$5"
    
    # Ensure recovery audit log directory exists
    local audit_dir=$(dirname "$RECOVERY_AUDIT_LOG")
    mkdir -p "$audit_dir" 2>/dev/null || true
    
    # Build audit entry
    local timestamp=$(get_iso8601_timestamp)
    
    local audit_entry
    audit_entry=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg file_type "$file_type" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --arg local_age "$local_age" \
        --arg s3_age "$s3_age" \
        '{
            recovery_time: $timestamp,
            file_type: $file_type,
            decision: $decision,
            reason: $reason,
            local_age_seconds: $local_age,
            s3_age_seconds: $s3_age
        }')
    
    # Append to audit log
    echo "$audit_entry" >> "$RECOVERY_AUDIT_LOG" 2>/dev/null || true
    
    log INFO "Recovery decision: $file_type → $decision ($reason)"
    
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f validate_state_file_safe get_state_age_seconds
readonly -f backup_high_level_states_to_s3
readonly -f recover_high_level_states_from_s3 recover_single_state_file
readonly -f decide_state_version
readonly -f safe_replace_state log_recovery_decision

log DEBUG "Module loaded: $STATEBACKUP_MODULE_NAME v$STATEBACKUP_MODULE_VERSION (API v$STATEBACKUP_API_VERSION)"
log DEBUG "Recovery audit log: $RECOVERY_AUDIT_LOG"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_state_backup() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "validate_state_file_safe"
        "get_state_age_seconds"
        "backup_high_level_states_to_s3"
        "recover_high_level_states_from_s3"
        "recover_single_state_file"
        "decide_state_version"
        "safe_replace_state"
        "log_recovery_decision"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $STATEBACKUP_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for func in "log" "s3_upload" "s3_download" "parse_iso8601_date" "get_iso8601_timestamp"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $STATEBACKUP_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check module metadata
    if [[ -z "${STATEBACKUP_MODULE_VERSION:-}" ]]; then
        log ERROR "Module $STATEBACKUP_MODULE_NAME: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_state_backup || die "Module validation failed: $STATEBACKUP_MODULE_NAME" $EX_SOFTWARE
fi

################################################################################
# END OF MODULE
################################################################################

