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
# config.sh - Secure Configuration Management Module
################################################################################
# Purpose: Provides SECURE loading and validation of configuration files.
#          Implements safe parameter parsing WITHOUT using 'source' to prevent
#          command injection vulnerabilities. This module ensures that
#          configuration values cannot execute arbitrary code.
#
# Dependencies: core.sh, utils.sh
#
# Security Features:
#   - NO use of 'source' command (prevents code injection)
#   - Whitelist-based key validation (only known keys accepted)
#   - Input sanitization (dangerous patterns rejected)
#   - Safe variable assignment (no eval, no command substitution)
#
# Public API:
#   - load_config()           : Safely load configuration file
#   - validate_config()       : Validate required settings
#   - get_config_value()      : Get single configuration value
#   - set_config_value()      : Set configuration value at runtime
#   - validate_aws_credentials() : Validate AWS access
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly CONFIG_MODULE_VERSION="1.0.0"
readonly CONFIG_MODULE_NAME="config"
readonly CONFIG_MODULE_DEPS=("core" "utils")
readonly CONFIG_API_VERSION="1.0"

################################################################################
# DEPENDENCY VALIDATION
################################################################################

# Ensure required modules are loaded
for dep in "${CONFIG_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: config.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

################################################################################
# CONFIGURATION KEY WHITELIST
################################################################################
# SECURITY: Only these keys are accepted from configuration files
# This prevents arbitrary variable injection

readonly -a ALLOWED_CONFIG_KEYS=(
    # S3 Backend Configuration
    "S3_BUCKET"
    "S3_PREFIX"
    "AWS_REGION"
    "AWS_PROFILE"
    "AWS_ACCESS_KEY_ID"        # Note: Should use IAM roles instead
    "AWS_SECRET_ACCESS_KEY"    # Note: Should use IAM roles instead
    "AWS_SESSION_TOKEN"        # For temporary credentials
    
    # Backup Strategy
    "BACKUP_BACKEND"
    "BACKUP_STRATEGY"
    "PRESERVE_DIRECTORY_PATHS"
    "BACKUP_ORGANIZATION"
    "CHECKSUM_ALGORITHM"
    "INTEGRITY_MODE"
    "STRICT_EXTENSIONS"
    
    # Deletion Management
    "DELETED_FILE_RETENTION"
    
    # Operational Configuration
    "DRY_RUN"
    "MOUNT_DIR"
    
    # Alignment Configuration
    "FORCE_ALIGNMENT_MODE"
    "ALIGNMENT_HISTORY_RETENTION"
    
    # Filesystem Scan Management
    "FILESYSTEM_SCAN_REFRESH_HOURS"
    "FORCE_FILESYSTEM_SCAN_REFRESH"
    
    # Audit System
    "AUDIT_SYSTEM_ENABLED"
    
    # Logging Configuration
    "LOG_LEVEL"
    "MAX_LOG_SIZE"
    
    # File Paths
    "S3_CACHE_FILE"
    "S3_REPORT_FILE"
    "S3_INSPECT_LOG_FILE"
    
    # S3 Reporting
    "DETAILED_S3_REPORT"
)

################################################################################
# REQUIRED CONFIGURATION KEYS
################################################################################
# These keys MUST be present in configuration

readonly -a REQUIRED_CONFIG_KEYS=(
    "S3_BUCKET"
    "AWS_REGION"
)

################################################################################
# PRIVATE HELPER FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# _is_allowed_config_key
#
# Checks if configuration key is in whitelist
#
# Parameters:
#   $1 - key: Configuration key name
#
# Returns:
#   0 - Key is allowed
#   1 - Key is not in whitelist
#
# Internal Use Only
#------------------------------------------------------------------------------
_is_allowed_config_key() {
    local key="$1"
    
    for allowed_key in "${ALLOWED_CONFIG_KEYS[@]}"; do
        if [[ "$key" == "$allowed_key" ]]; then
            return 0
        fi
    done
    
    return 1
}

#------------------------------------------------------------------------------
# _contains_dangerous_pattern
#
# SECURITY: Detects dangerous patterns in configuration values
#
# Parameters:
#   $1 - value: Configuration value to check
#
# Returns:
#   0 - Dangerous pattern detected
#   1 - Value appears safe
#
# Internal Use Only
#------------------------------------------------------------------------------
_contains_dangerous_pattern() {
    local value="$1"
    
    # Check for command substitution attempts
    if [[ "$value" =~ \$\( ]] || [[ "$value" =~ \` ]]; then
        log WARN "Dangerous pattern detected: command substitution"
        return 0
    fi
    
    # Check for command chaining
    if [[ "$value" =~ [^\\]\; ]] || [[ "$value" =~ ^\; ]]; then
        log WARN "Dangerous pattern detected: command chaining (semicolon)"
        return 0
    fi
    
    # Check for pipe attempts (but allow single | in middle of strings)
    if [[ "$value" =~ ^\| ]] || [[ "$value" =~ \|\| ]] || [[ "$value" =~ \|[[:space:]]*$ ]]; then
        log WARN "Dangerous pattern detected: pipe operator"
        return 0
    fi
    
    # Check for redirection operators
    if [[ "$value" =~ \>\> ]] || [[ "$value" =~ \<\< ]]; then
        log WARN "Dangerous pattern detected: redirection operator"
        return 0
    fi
    
    # Check for variable expansion that could be exploited
    if [[ "$value" =~ \$\{ ]] && [[ "$value" =~ \} ]]; then
        # Allow simple variable references like ${HOME}, but warn about complex ones
        if [[ "$value" =~ \$\{[^}]*[^A-Za-z0-9_}] ]]; then
            log WARN "Dangerous pattern detected: complex variable expansion"
            return 0
        fi
    fi
    
    return 1
}

#------------------------------------------------------------------------------
# _sanitize_config_value
#
# Removes quotes and trims whitespace from configuration value
#
# Parameters:
#   $1 - value: Raw configuration value
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   Sanitized value to stdout
#
# Internal Use Only
#------------------------------------------------------------------------------
_sanitize_config_value() {
    local value="$1"
    
    # Trim leading whitespace
    value="${value#"${value%%[![:space:]]*}"}"
    
    # Trim trailing whitespace
    value="${value%"${value##*[![:space:]]}"}"
    
    # Remove surrounding quotes (both single and double)
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    
    echo "$value"
}

################################################################################
# PUBLIC API: CONFIGURATION LOADING
################################################################################

#------------------------------------------------------------------------------
# load_config
#
# Safely loads configuration from file using parameter parsing
# SECURITY: Does NOT use 'source' - prevents command injection
#
# Parameters:
#   $1 - config_file: Path to configuration file (optional)
#                     Defaults to ${CONFIG_FILE} environment variable
#
# Returns:
#   0 - Configuration loaded successfully
#   1 - Configuration file not found or invalid
#
# Side Effects:
#   Sets global variables for each configuration key
#   Exports AWS credential variables if present
#
# Example:
#   if load_config "/path/to/config.conf"; then
#       echo "Config loaded: S3_BUCKET=$S3_BUCKET"
#   fi
#
# Security Notes:
#   - Only whitelisted keys are accepted
#   - Values are sanitized for dangerous patterns
#   - No code execution possible from config file
#------------------------------------------------------------------------------
load_config() {
    local config_file="${1:-${CONFIG_FILE:-}}"
    
    # Validate config file path is provided
    if [[ -z "$config_file" ]]; then
        log ERROR "Configuration file path not specified"
        return 1
    fi
    
    # Check file exists
    if [[ ! -f "$config_file" ]]; then
        log ERROR "Configuration file not found: $config_file"
        return 1
    fi
    
    # SECURITY: Validate file is not executable
    if [[ -x "$config_file" ]]; then
        log ERROR "Configuration file must not be executable: $config_file"
        log ERROR "This is a security measure to prevent code injection"
        return 1
    fi
    
    log INFO "Loading configuration from: $config_file"
    
    # Parse configuration file line by line (SAFE: no sourcing)
    local line_num=0
    local keys_loaded=0
    
    while IFS= read -r line; do
        ((line_num++))
        
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Parse KEY=VALUE format
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Validate key is in whitelist
            if ! _is_allowed_config_key "$key"; then
                log WARN "Unknown configuration key ignored: $key (line $line_num)"
                continue
            fi
            
            # Sanitize value (remove quotes, trim whitespace)
            value=$(_sanitize_config_value "$value")
            
            # SECURITY: Check for dangerous patterns
            if _contains_dangerous_pattern "$value"; then
                log ERROR "Configuration value contains dangerous pattern: $key=$value"
                log ERROR "This is a security violation (line $line_num)"
                return 1
            fi
            
            # Safe assignment using printf (avoids command substitution)
            # This is the SECURE way to set variables from untrusted input
            printf -v "$key" '%s' "$value"
            
            ((keys_loaded++))
            log DEBUG "Config: $key=$value"
            
        elif [[ -n "$line" ]] && ! [[ "$line" =~ ^[[:space:]]*$ ]]; then
            # Non-empty, non-comment line that doesn't match KEY=VALUE
            log WARN "Invalid configuration line ignored (line $line_num): $line"
        fi
        
    done < "$config_file"
    
    log INFO "Configuration loaded: $keys_loaded keys from $config_file"
    
    # Export AWS credentials if present (needed by AWS CLI)
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
        log DEBUG "AWS_ACCESS_KEY_ID exported"
    fi
    
    if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_SECRET_ACCESS_KEY
        log DEBUG "AWS_SECRET_ACCESS_KEY exported (hidden)"
    fi
    
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
        export AWS_SESSION_TOKEN
        log DEBUG "AWS_SESSION_TOKEN exported"
    fi
    
    # Validate configuration after loading
    if ! validate_config; then
        return 1
    fi
    
    # Lock MOUNT_DIR to prevent accidental modification (matches original behavior)
    if [[ -n "${MOUNT_DIR:-}" ]]; then
        readonly MOUNT_DIR
        log DEBUG "MOUNT_DIR locked for protection: $MOUNT_DIR"
    fi
    
    return 0
}

################################################################################
# PUBLIC API: CONFIGURATION VALIDATION
################################################################################

#------------------------------------------------------------------------------
# validate_config
#
# Validates that all required configuration is present and valid
#
# Parameters:
#   None
#
# Returns:
#   0 - Configuration is valid
#   1 - Configuration is invalid (errors logged)
#
# Example:
#   if validate_config; then
#       echo "Configuration is valid"
#   else
#       echo "Configuration has errors"
#   fi
#------------------------------------------------------------------------------
validate_config() {
    local errors=0
    
    log DEBUG "Validating configuration..."
    
    # Check required keys are present
    for key in "${REQUIRED_CONFIG_KEYS[@]}"; do
        local value="${!key:-}"
        if [[ -z "$value" ]]; then
            log ERROR "Required configuration missing: $key"
            ((errors++))
        fi
    done
    
    # Validate S3_BUCKET format (if present)
    if [[ -n "${S3_BUCKET:-}" ]]; then
        if ! [[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
            log ERROR "Invalid S3_BUCKET format: $S3_BUCKET"
            log ERROR "Bucket names must be lowercase, 3-63 characters, alphanumeric/hyphens/dots"
            ((errors++))
        fi
        
        # Check bucket name length
        local bucket_length=${#S3_BUCKET}
        if [[ $bucket_length -lt 3 ]] || [[ $bucket_length -gt 63 ]]; then
            log ERROR "Invalid S3_BUCKET length: $bucket_length (must be 3-63 characters)"
            ((errors++))
        fi
    fi
    
    # Validate AWS_REGION format (if present)
    if [[ -n "${AWS_REGION:-}" ]]; then
        if ! [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            log ERROR "Invalid AWS_REGION format: $AWS_REGION"
            log ERROR "Expected format: us-east-1, eu-west-2, ap-south-1, etc."
            ((errors++))
        fi
    fi
    
    # Validate CHECKSUM_ALGORITHM (if present)
    if [[ -n "${CHECKSUM_ALGORITHM:-}" ]]; then
        case "$CHECKSUM_ALGORITHM" in
            md5|sha256|mtime) ;;
            *)
                log ERROR "Invalid CHECKSUM_ALGORITHM: $CHECKSUM_ALGORITHM"
                log ERROR "Must be one of: md5, sha256, mtime"
                ((errors++))
                ;;
        esac
    fi
    
    # Validate LOG_LEVEL (if present)
    if [[ -n "${LOG_LEVEL:-}" ]]; then
        case "$LOG_LEVEL" in
            DEBUG|INFO|WARN|ERROR) ;;
            *)
                log ERROR "Invalid LOG_LEVEL: $LOG_LEVEL"
                log ERROR "Must be one of: DEBUG, INFO, WARN, ERROR"
                ((errors++))
                ;;
        esac
    fi
    
    # Validate boolean values
    for bool_key in "DRY_RUN" "PRESERVE_DIRECTORY_PATHS" "FORCE_ALIGNMENT_MODE" \
                    "FORCE_FILESYSTEM_SCAN_REFRESH" "AUDIT_SYSTEM_ENABLED"; do
        local bool_value="${!bool_key:-}"
        if [[ -n "$bool_value" ]] && [[ "$bool_value" != "true" && "$bool_value" != "false" ]]; then
            log ERROR "Invalid boolean value for $bool_key: $bool_value (must be 'true' or 'false')"
            ((errors++))
        fi
    done
    
    # Validate numeric values
    if [[ -n "${ALIGNMENT_HISTORY_RETENTION:-}" ]]; then
        if ! is_numeric "$ALIGNMENT_HISTORY_RETENTION"; then
            log ERROR "ALIGNMENT_HISTORY_RETENTION must be numeric: $ALIGNMENT_HISTORY_RETENTION"
            ((errors++))
        fi
    fi
    
    if [[ -n "${FILESYSTEM_SCAN_REFRESH_HOURS:-}" ]]; then
        if ! [[ "$FILESYSTEM_SCAN_REFRESH_HOURS" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            log ERROR "FILESYSTEM_SCAN_REFRESH_HOURS must be numeric: $FILESYSTEM_SCAN_REFRESH_HOURS"
            ((errors++))
        fi
    fi
    
    # Summary
    if [[ $errors -gt 0 ]]; then
        log ERROR "Configuration validation failed with $errors errors"
        return 1
    fi
    
    log DEBUG "Configuration validation passed"
    return 0
}

################################################################################
# PUBLIC API: CONFIGURATION ACCESS
################################################################################

#------------------------------------------------------------------------------
# get_config_value
#
# Gets a single configuration value by key
#
# Parameters:
#   $1 - key: Configuration key name
#
# Returns:
#   0 - Value found and printed to stdout
#   1 - Key not found or not set
#
# Output:
#   Configuration value (if found)
#
# Example:
#   bucket=$(get_config_value "S3_BUCKET")
#   [[ $? -eq 0 ]] && echo "Bucket: $bucket"
#------------------------------------------------------------------------------
get_config_value() {
    local key="$1"
    
    # Check if key exists and has value
    if [[ -z "${!key:-}" ]]; then
        return 1
    fi
    
    echo -n "${!key}"
    return 0
}

#------------------------------------------------------------------------------
# set_config_value
#
# Sets a configuration value at runtime (does NOT modify config file)
#
# Parameters:
#   $1 - key: Configuration key name
#   $2 - value: Value to set
#
# Returns:
#   0 - Value set successfully
#   1 - Invalid key or value
#
# Example:
#   set_config_value "DRY_RUN" "true"
#------------------------------------------------------------------------------
set_config_value() {
    local key="$1"
    local value="$2"
    
    # Validate key is in whitelist
    if ! _is_allowed_config_key "$key"; then
        log ERROR "Cannot set unknown configuration key: $key"
        return 1
    fi
    
    # Check for dangerous patterns
    if _contains_dangerous_pattern "$value"; then
        log ERROR "Cannot set configuration value with dangerous pattern: $key=$value"
        return 1
    fi
    
    # Safe assignment
    printf -v "$key" '%s' "$value"
    log DEBUG "Configuration updated: $key=$value"
    return 0
}

################################################################################
# PUBLIC API: AWS VALIDATION
################################################################################

#------------------------------------------------------------------------------
# validate_aws_credentials
#
# Validates AWS credentials and S3 bucket access
#
# Parameters:
#   None
#
# Returns:
#   0 - AWS credentials valid and S3 accessible
#   1 - AWS credentials invalid or S3 inaccessible
#
# Example:
#   if validate_aws_credentials; then
#       echo "AWS access validated"
#   fi
#------------------------------------------------------------------------------
validate_aws_credentials() {
    log INFO "Validating AWS credentials and S3 access..."
    
    # Build AWS command with profile/region options
    local aws_cmd="aws"
    [[ -n "${AWS_PROFILE:-}" ]] && aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    [[ -n "${AWS_REGION:-}" ]] && aws_cmd="$aws_cmd --region $AWS_REGION"
    
    # Test AWS credentials
    log DEBUG "Testing AWS credentials..."
    if ! $aws_cmd sts get-caller-identity >/dev/null 2>&1; then
        log ERROR "AWS credentials validation failed"
        log ERROR "Please check your AWS configuration:"
        log ERROR "  - AWS CLI installed: $(command -v aws)"
        log ERROR "  - AWS_PROFILE: ${AWS_PROFILE:-default}"
        log ERROR "  - AWS_REGION: ${AWS_REGION:-not set}"
        return 1
    fi
    
    # Get caller identity for logging
    local caller_identity
    if caller_identity=$($aws_cmd sts get-caller-identity 2>/dev/null); then
        # Parse account ID and ARN (if jq available)
        if command -v jq >/dev/null 2>&1; then
            local account_id
            local user_arn
            account_id=$(echo "$caller_identity" | jq -r '.Account // "unknown"')
            user_arn=$(echo "$caller_identity" | jq -r '.Arn // "unknown"')
            log INFO "AWS credentials validated - Account: $account_id"
            log DEBUG "User ARN: $user_arn"
        else
            log INFO "AWS credentials validated"
        fi
    fi
    
    # Test S3 bucket access
    log DEBUG "Testing S3 bucket access: $S3_BUCKET"
    if ! $aws_cmd s3 ls "s3://$S3_BUCKET/" >/dev/null 2>&1; then
        log ERROR "S3 bucket access failed: $S3_BUCKET"
        log ERROR "Please check:"
        log ERROR "  - Bucket exists"
        log ERROR "  - Bucket name is correct"
        log ERROR "  - IAM permissions allow s3:ListBucket"
        return 1
    fi
    
    log INFO "S3 bucket access validated: $S3_BUCKET"
    
    # Test write permissions (create small test object)
    local test_key="${S3_PREFIX:+$S3_PREFIX/}.config-test-$(date +%s)"
    log DEBUG "Testing S3 write permissions..."
    
    if echo "test" | $aws_cmd s3 cp - "s3://$S3_BUCKET/$test_key" >/dev/null 2>&1; then
        # Clean up test object
        $aws_cmd s3 rm "s3://$S3_BUCKET/$test_key" >/dev/null 2>&1 || true
        log INFO "S3 write permissions validated"
    else
        log ERROR "S3 write permissions test failed"
        log ERROR "Please check IAM permissions allow s3:PutObject"
        return 1
    fi
    
    log INFO "✅ AWS credentials and S3 access validated successfully"
    return 0
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f load_config validate_config
readonly -f get_config_value set_config_value
readonly -f validate_aws_credentials

# Log module initialization
log DEBUG "Module loaded: $CONFIG_MODULE_NAME v$CONFIG_MODULE_VERSION (API v$CONFIG_API_VERSION)"
log DEBUG "Security: Command injection protection enabled"

################################################################################
# MODULE SELF-VALIDATION
################################################################################

validate_module_config() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "load_config" "validate_config"
        "get_config_value" "set_config_value"
        "validate_aws_credentials"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $CONFIG_MODULE_NAME: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for func in "log" "is_numeric"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module $CONFIG_MODULE_NAME: Missing dependency function $func"
            ((errors++))
        fi
    done
    
    # Check module metadata
    if [[ -z "${CONFIG_MODULE_VERSION:-}" ]]; then
        log ERROR "Module $CONFIG_MODULE_NAME: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

# Run validation if MODULE_VALIDATE environment variable is set
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    if ! validate_module_config; then
        die "Module validation failed: $CONFIG_MODULE_NAME" $EX_SOFTWARE
    fi
fi

################################################################################
# END OF MODULE
################################################################################

