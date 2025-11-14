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
# core.sh - Foundation Module for Backup System
################################################################################
# Purpose: Provides fundamental functionality for all other modules including
#          logging, error handling, exit codes, and platform detection.
#
# Dependencies: None (leaf module - no dependencies by design)
#
# Public API:
#   - log()              : Structured logging with levels
#   - die()              : Fatal error with exit
#   - warn()             : Non-fatal warning
#   - require_command()  : Ensure external command exists
#   - require_file()     : Ensure file exists
#   - require_dir()      : Ensure directory exists
#   - detect_os()        : Platform detection
#   - is_linux()         : Check if running on Linux
#   - is_macos()         : Check if running on macOS
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly CORE_MODULE_VERSION="1.0.0"
readonly CORE_MODULE_NAME="core"
readonly CORE_API_VERSION="1.0"

################################################################################
# EXIT CODES (Following sysexits.h Convention)
################################################################################
# Using standard exit codes makes integration with monitoring systems easier
# and provides clear signal of failure type to calling processes.

readonly EX_OK=0           # Successful exit
readonly EX_USAGE=64       # Command line usage error
readonly EX_DATAERR=65     # Data format error
readonly EX_NOINPUT=66     # Cannot open input
readonly EX_NOUSER=67      # Addressee unknown
readonly EX_NOHOST=68      # Host name unknown
readonly EX_UNAVAILABLE=69 # Service unavailable
readonly EX_SOFTWARE=70    # Internal software error
readonly EX_OSERR=71       # System error (e.g., can't fork)
readonly EX_OSFILE=72      # Critical OS file missing
readonly EX_CANTCREAT=73   # Can't create (user) output file
readonly EX_IOERR=74       # Input/output error
readonly EX_TEMPFAIL=75    # Temporary failure; user is invited to retry
readonly EX_PROTOCOL=76    # Remote error in protocol
readonly EX_NOPERM=77      # Permission denied
readonly EX_CONFIG=78      # Configuration error

################################################################################
# LOGGING CONFIGURATION
################################################################################

# Default log level - can be overridden by environment variable or config
# Hierarchy: DEBUG < INFO < WARN < ERROR (lower levels include higher)
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Log file location - set by main script, defaults to stderr
LOG_FILE="${LOG_FILE:-}"

# ANSI color codes for enhanced terminal output
# Only used when outputting to terminal, not to file
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GRAY='\033[0;90m'

################################################################################
# PRIVATE HELPER FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# _should_log
#
# Determines if a message at given level should be logged based on LOG_LEVEL
#
# Parameters:
#   $1 - level: Message level (DEBUG|INFO|WARN|ERROR)
#
# Returns:
#   0 - Message should be logged
#   1 - Message should be suppressed
#
# Internal Use Only
#------------------------------------------------------------------------------
_should_log() {
    local level="$1"
    
    # Convert log levels to numeric for comparison
    local level_value=0
    local current_level_value=0
    
    case "$level" in
        DEBUG) level_value=0 ;;
        INFO)  level_value=1 ;;
        WARN)  level_value=2 ;;
        ERROR) level_value=3 ;;
        *)     return 1 ;;  # Invalid level, don't log
    esac
    
    case "$LOG_LEVEL" in
        DEBUG) current_level_value=0 ;;
        INFO)  current_level_value=1 ;;
        WARN)  current_level_value=2 ;;
        ERROR) current_level_value=3 ;;
        *)     current_level_value=1 ;;  # Default to INFO
    esac
    
    # Log if message level >= current log level
    [[ $level_value -ge $current_level_value ]]
}

#------------------------------------------------------------------------------
# _is_terminal
#
# Checks if output is going to a terminal (for color support)
#
# Returns:
#   0 - Output is a terminal
#   1 - Output is redirected/piped
#
# Internal Use Only
#------------------------------------------------------------------------------
_is_terminal() {
    [[ -t 2 ]]  # Check if stderr (fd 2) is a terminal
}

#------------------------------------------------------------------------------
# _colorize
#
# Adds ANSI color codes to text if outputting to terminal
#
# Parameters:
#   $1 - color: Color code
#   $2 - text: Text to colorize
#
# Returns:
#   Colored text if terminal, plain text otherwise
#
# Internal Use Only
#------------------------------------------------------------------------------
_colorize() {
    local color="$1"
    local text="$2"
    
    if _is_terminal; then
        echo -e "${color}${text}${COLOR_RESET}"
    else
        echo "$text"
    fi
}

################################################################################
# PUBLIC API: LOGGING FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# log
#
# Structured logging function with level-based filtering and optional color
#
# Parameters:
#   $1 - level: Log level (DEBUG|INFO|WARN|ERROR)
#   $@ - message: Log message (all remaining arguments)
#
# Returns:
#   0 - Message logged successfully
#   1 - Message filtered or error
#
# Output:
#   Logs to stderr and optionally to LOG_FILE
#   Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
#
# Example:
#   log INFO "Backup started"
#   log ERROR "Failed to connect to S3"
#   log DEBUG "Processing file: $filename"
#------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    
    # Check if this message should be logged based on LOG_LEVEL
    if ! _should_log "$level"; then
        return 0
    fi
    
    # Generate timestamp in ISO 8601 format
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Format the complete log line
    local log_line="[$timestamp] [$level] $message"
    
    # Colorize based on level (only for terminal output)
    local colored_line
    case "$level" in
        DEBUG)
            colored_line=$(_colorize "$COLOR_GRAY" "$log_line")
            ;;
        INFO)
            colored_line=$(_colorize "$COLOR_BLUE" "$log_line")
            ;;
        WARN)
            colored_line=$(_colorize "$COLOR_YELLOW" "$log_line")
            ;;
        ERROR)
            colored_line=$(_colorize "$COLOR_RED" "$log_line")
            ;;
        *)
            colored_line="$log_line"
            ;;
    esac
    
    # Output to stderr (colored if terminal)
    echo "$colored_line" >&2
    
    # Also write to log file if configured (always plain text)
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    return 0
}

################################################################################
# PUBLIC API: ERROR HANDLING FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# die
#
# Logs fatal error and exits script with specified exit code
#
# Parameters:
#   $1 - message: Error message to log
#   $2 - exit_code: Exit code (optional, defaults to EX_SOFTWARE)
#
# Returns:
#   Does not return (calls exit)
#
# Example:
#   die "Configuration file not found" $EX_CONFIG
#   die "Cannot connect to S3"  # Uses default exit code
#------------------------------------------------------------------------------
die() {
    local message="$1"
    local exit_code="${2:-$EX_SOFTWARE}"
    
    # Validate exit code is numeric
    if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        log ERROR "Invalid exit code: $exit_code (using $EX_SOFTWARE)"
        exit_code=$EX_SOFTWARE
    fi
    
    # Log the fatal error
    log ERROR "$message"
    
    # Exit with specified code
    exit "$exit_code"
}

#------------------------------------------------------------------------------
# warn
#
# Logs warning message and continues execution
#
# Parameters:
#   $@ - message: Warning message
#
# Returns:
#   0 - Always returns success
#
# Example:
#   warn "Configuration file not found, using defaults"
#------------------------------------------------------------------------------
warn() {
    log WARN "$*"
    return 0
}

################################################################################
# PUBLIC API: REQUIREMENT CHECK FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# require_command
#
# Ensures a required external command is available in PATH
#
# Parameters:
#   $1 - command: Command name to check
#   $2 - hint: Installation hint (optional)
#
# Returns:
#   0 - Command exists
#   Does not return if command missing (calls die)
#
# Example:
#   require_command "jq" "Install with: apt-get install jq"
#   require_command "aws"
#------------------------------------------------------------------------------
require_command() {
    local cmd="$1"
    local hint="${2:-Install $cmd to continue}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Required command not found: $cmd. $hint" $EX_UNAVAILABLE
    fi
    
    log DEBUG "Command available: $cmd"
    return 0
}

#------------------------------------------------------------------------------
# require_file
#
# Ensures a required file exists and is readable
#
# Parameters:
#   $1 - file_path: Path to required file
#   $2 - description: File description for error message (optional)
#
# Returns:
#   0 - File exists and is readable
#   Does not return if file missing (calls die)
#
# Example:
#   require_file "$CONFIG_FILE" "Configuration file"
#   require_file "/etc/passwd"
#------------------------------------------------------------------------------
require_file() {
    local file_path="$1"
    local description="${2:-File}"
    
    if [[ ! -f "$file_path" ]]; then
        die "$description not found: $file_path" $EX_NOINPUT
    fi
    
    if [[ ! -r "$file_path" ]]; then
        die "$description not readable: $file_path" $EX_NOPERM
    fi
    
    log DEBUG "$description exists: $file_path"
    return 0
}

#------------------------------------------------------------------------------
# require_dir
#
# Ensures a required directory exists and is accessible
#
# Parameters:
#   $1 - dir_path: Path to required directory
#   $2 - description: Directory description for error message (optional)
#
# Returns:
#   0 - Directory exists and is accessible
#   Does not return if directory missing (calls die)
#
# Example:
#   require_dir "$MOUNT_DIR" "Mount directory"
#   require_dir "/tmp"
#------------------------------------------------------------------------------
require_dir() {
    local dir_path="$1"
    local description="${2:-Directory}"
    
    if [[ ! -d "$dir_path" ]]; then
        die "$description not found: $dir_path" $EX_NOINPUT
    fi
    
    if [[ ! -r "$dir_path" || ! -x "$dir_path" ]]; then
        die "$description not accessible: $dir_path" $EX_NOPERM
    fi
    
    log DEBUG "$description exists: $dir_path"
    return 0
}

################################################################################
# PUBLIC API: PLATFORM DETECTION FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# detect_os
#
# Detects the operating system platform
#
# Parameters:
#   None
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   Prints one of: linux, macos, windows, unknown
#
# Example:
#   os=$(detect_os)
#   if [[ "$os" == "linux" ]]; then
#       echo "Running on Linux"
#   fi
#------------------------------------------------------------------------------
detect_os() {
    local os_type
    os_type=$(uname -s)
    
    case "$os_type" in
        Linux*)
            echo "linux"
            ;;
        Darwin*)
            echo "macos"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
    
    return 0
}

#------------------------------------------------------------------------------
# is_linux
#
# Checks if running on Linux
#
# Returns:
#   0 - Running on Linux
#   1 - Not running on Linux
#
# Example:
#   if is_linux; then
#       use_linux_specific_command
#   fi
#------------------------------------------------------------------------------
is_linux() {
    [[ "$(detect_os)" == "linux" ]]
}

#------------------------------------------------------------------------------
# is_macos
#
# Checks if running on macOS
#
# Returns:
#   0 - Running on macOS
#   1 - Not running on macOS
#
# Example:
#   if is_macos; then
#       use_macos_specific_command
#   fi
#------------------------------------------------------------------------------
is_macos() {
    [[ "$(detect_os)" == "macos" ]]
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only to prevent accidental redefinition
readonly -f log die warn
readonly -f require_command require_file require_dir
readonly -f detect_os is_linux is_macos

# Log module initialization (only in DEBUG mode)
if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
    log DEBUG "Module loaded: $CORE_MODULE_NAME v$CORE_MODULE_VERSION (API v$CORE_API_VERSION)"
fi

################################################################################
# MODULE SELF-VALIDATION (Optional, enabled via MODULE_VALIDATE flag)
################################################################################

#------------------------------------------------------------------------------
# validate_module_core
#
# Validates that all public functions are properly defined
#
# Returns:
#   0 - All validations pass
#   1 - One or more validations failed
#
# Example:
#   MODULE_VALIDATE=true source lib/core.sh
#------------------------------------------------------------------------------
validate_module_core() {
    local errors=0
    
    # Check all public functions are defined
    local public_functions=(
        "log" "die" "warn"
        "require_command" "require_file" "require_dir"
        "detect_os" "is_linux" "is_macos"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            echo "ERROR: Module $CORE_MODULE_NAME: Missing function $func" >&2
            ((errors++))
        fi
    done
    
    # Check module metadata is defined
    if [[ -z "${CORE_MODULE_VERSION:-}" ]]; then
        echo "ERROR: Module $CORE_MODULE_NAME: VERSION not defined" >&2
        ((errors++))
    fi
    
    # Check exit codes are defined
    local exit_codes=("EX_OK" "EX_CONFIG" "EX_SOFTWARE" "EX_NOINPUT")
    for code in "${exit_codes[@]}"; do
        if [[ -z "${!code:-}" ]]; then
            echo "ERROR: Module $CORE_MODULE_NAME: Exit code $code not defined" >&2
            ((errors++))
        fi
    done
    
    return $errors
}

# Run validation if MODULE_VALIDATE environment variable is set
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    if ! validate_module_core; then
        echo "FATAL: Module validation failed: $CORE_MODULE_NAME" >&2
        exit 1
    fi
fi

################################################################################
# END OF MODULE
################################################################################

