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
# backup.sh - Main Backup System Entry Point
################################################################################
# Purpose: Single entry point for the backup system. Handles all module loading
#          and initialization automatically. Can be run directly or as a cron job.
#
# Usage:
#   ./backup.sh [OPTIONS]
#
#   OR with environment variables:
#   DRY_RUN=true LOG_LEVEL=DEBUG ./backup.sh
#
#   OR in cron:
#   0 2 * * * /path/to/backup.sh >> /var/log/backup-cron.log 2>&1
#
# Options:
#   --dry-run              Simulate operations without making changes
#   --force-alignment      Run forced alignment mode
#   --config FILE          Use alternative configuration file
#   --help, -h             Show help message
#   --version              Show version information
#
# Environment Variables (Optional):
#   CONFIG_FILE            Path to configuration file
#   LOG_LEVEL             Logging level (DEBUG, INFO, WARN, ERROR)
#   DRY_RUN               Set to "true" for dry-run mode
#   FORCE_ALIGNMENT_MODE  Set to "true" for alignment mode
#
# Exit Codes:
#   0  - Success
#   1  - General error
#   64 - Command line usage error
#   66 - Required file not found
#   70 - Internal software error
#   78 - Configuration error
# 
# Version: 2.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# STRICT MODE - Enable early before any operations
################################################################################

set -euo pipefail

################################################################################
# BOOTSTRAP - Setup script environment
################################################################################

# Get script directory (works even when called via symlink)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration file (can be overridden)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/scripts/backup-config.conf}"


# Default log file (can be overridden)
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/backup.log}"

# Default log level (can be overridden)
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Export for modules to use (CRITICAL: SCRIPT_DIR needed for state file paths!)
export SCRIPT_DIR
export CONFIG_FILE  # Needed by alignment.sh to disable forced alignment mode
export LOG_FILE
export LOG_LEVEL

################################################################################
# MODULE LOADING - Load all required modules automatically
################################################################################

# Check if module system exists
if [[ ! -f "${SCRIPT_DIR}/lib/loader.sh" ]]; then
    echo "ERROR: Module system not found: ${SCRIPT_DIR}/lib/loader.sh" >&2
    echo "Please ensure the lib/ directory is present" >&2
    exit 70
fi

# Source module loader
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/loader.sh"

# Load ALL required modules for complete backup system
if ! load_modules core utils config state filesystem checksum s3 backup deletion alignment statebackup; then
    echo "ERROR: Failed to load required modules" >&2
    exit 70
fi

log DEBUG "✅ All modules loaded successfully"

################################################################################
# VERSION INFORMATION
################################################################################

readonly BACKUP_SYSTEM_VERSION="2.0.0"
readonly BACKUP_SYSTEM_NAME="S3 Backup System (Modular Architecture)"

################################################################################
# COMMAND LINE INTERFACE
################################################################################

#------------------------------------------------------------------------------
# show_help
#
# Displays usage information
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
${BACKUP_SYSTEM_NAME} v${BACKUP_SYSTEM_VERSION}

USAGE:
    $(basename "$0") [OPTIONS]

DESCRIPTION:
    Automated backup system that syncs local directories to AWS S3 with
    incremental change tracking, deletion management, and reconciliation.

OPTIONS:
    --dry-run              Simulate all operations without making changes
                          (Shows what would be done without doing it)
    
    --force-alignment      Run forced alignment to reconcile filesystem vs S3
                          (Moves orphaned S3 objects to yesterday_state)
    
    --config FILE          Use alternative configuration file
                          (Default: ${CONFIG_FILE})
    
    --help, -h             Show this help message and exit
    
    --version              Show version information and exit

ENVIRONMENT VARIABLES:
    CONFIG_FILE           Configuration file path
                          Default: ${SCRIPT_DIR}/scripts/backup-config.conf
    
    LOG_LEVEL            Logging verbosity: DEBUG, INFO, WARN, ERROR
                          Default: INFO
    
    LOG_FILE             Log file path
                          Default: ${SCRIPT_DIR}/backup.log
    
    DRY_RUN              Set to "true" to enable dry-run mode
    
    FORCE_ALIGNMENT_MODE Set to "true" to enable alignment mode

EXAMPLES:
    # Normal backup
    $(basename "$0")
    
    # Dry run to see what would happen
    $(basename "$0") --dry-run
    
    # Force alignment
    $(basename "$0") --force-alignment
    
    # Debug mode with alternative config
    LOG_LEVEL=DEBUG $(basename "$0") --config /path/to/config.conf
    
    # Dry run with environment variable
    DRY_RUN=true LOG_LEVEL=DEBUG $(basename "$0")

CRON USAGE:
    # Run daily at 2 AM
    0 2 * * * /path/to/backup.sh >> /var/log/backup-cron.log 2>&1

CONFIGURATION:
    Edit: ${CONFIG_FILE}
    Required: S3_BUCKET, AWS_REGION
    Optional: S3_PREFIX, AWS_PROFILE, DELETED_FILE_RETENTION, etc.

FILES:
    Configuration: ${CONFIG_FILE}
    State Files:   ${SCRIPT_DIR}/state/high-level/backup-state.json
                   ${SCRIPT_DIR}/state/high-level/yesterday-backup-state.json
                   ${SCRIPT_DIR}/state/current/*.state.json
    S3 Cache:      ${SCRIPT_DIR}/state/s3/s3-cache.json
    Logs:          ${LOG_FILE}

For more information, see:
    ${SCRIPT_DIR}/GETTING_STARTED.md
    ${SCRIPT_DIR}/docs/README.md

EOF
}

#------------------------------------------------------------------------------
# show_version
#
# Displays version and module information
#------------------------------------------------------------------------------
show_version() {
    echo "${BACKUP_SYSTEM_NAME}"
    echo "Version: ${BACKUP_SYSTEM_VERSION}"
    echo ""
    echo "Loaded Modules:"
    
    # List loaded modules with versions
    for module in core utils config; do
        local version_var="${module^^}_MODULE_VERSION"
        local version="${!version_var:-unknown}"
        echo "  - ${module}: v${version}"
    done
    
    echo ""
    echo "Platform: $(detect_os)"
    echo "Bash Version: ${BASH_VERSION}"
}

################################################################################
# ARGUMENT PARSING
################################################################################

#------------------------------------------------------------------------------
# parse_arguments
#
# Parses command line arguments and sets appropriate flags
#
# Parameters:
#   $@ - All command line arguments
#------------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                export DRY_RUN=true
                log INFO "Dry-run mode enabled"
                shift
                ;;
            
            --force-alignment)
                export FORCE_ALIGNMENT_MODE=true
                log INFO "Forced alignment mode enabled"
                shift
                ;;
            
            --config)
                if [[ -z "${2:-}" ]]; then
                    log ERROR "Option --config requires a file path"
                    exit 64  # EX_USAGE
                fi
                CONFIG_FILE="$2"
                export CONFIG_FILE
                shift 2
                ;;
            
            --help|-h)
                show_help
                exit 0
                ;;
            
            --version)
                show_version
                exit 0
                ;;
            
            *)
                log ERROR "Unknown option: $1"
                echo "" >&2
                show_help
                exit 64  # EX_USAGE
                ;;
        esac
    done
}

################################################################################
# MAIN WORKFLOW - Placeholder for full implementation
################################################################################

#------------------------------------------------------------------------------
# main
#
# Main backup workflow
# Note: This is a simplified version for Week 1 (foundation modules only)
#       Full backup logic will be added in Weeks 2-4 when remaining modules
#       are implemented (state, filesystem, checksum, s3, backup, etc.)
#------------------------------------------------------------------------------
main() {
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "${BACKUP_SYSTEM_NAME} v${BACKUP_SYSTEM_VERSION}"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO ""
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Load configuration
    log INFO "Loading configuration..."
    if ! load_config "$CONFIG_FILE"; then
        die "Configuration loading failed" 78  # EX_CONFIG
    fi
    
    log INFO "Configuration loaded successfully"
    log DEBUG "  S3 Bucket: ${S3_BUCKET}"
    log DEBUG "  AWS Region: ${AWS_REGION}"
    log DEBUG "  S3 Prefix: ${S3_PREFIX:-<none>}"
    log DEBUG "  Dry Run: ${DRY_RUN:-false}"
    log INFO ""
    
    # Validate AWS credentials and S3 access (if not in dry-run mode)
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        log INFO "Validating AWS credentials and S3 access..."
        if ! validate_aws_credentials; then
            die "AWS credentials validation failed" 78
        fi
        log INFO "✅ AWS credentials validated"
        log INFO ""
    else
        log INFO "Dry-run mode: Skipping AWS credentials validation"
        log INFO ""
    fi
    
    # Initialize state files
    log INFO "Initializing state files..."
    if ! init_state_files; then
        die "State file initialization failed" 73
    fi
    log INFO "✅ State files initialized"
    log INFO ""
    
    # Check for state recovery from S3 (disaster recovery)
    log INFO "Checking for state recovery from S3..."
    recover_high_level_states_from_s3 || {
        log WARN "State recovery had issues (continuing with local state)"
    }
    log INFO ""
    
    # Check for forced alignment mode (EXCLUSIVE operation)
    if [[ "${FORCE_ALIGNMENT_MODE:-false}" == "true" ]]; then
        log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log INFO "FORCED ALIGNMENT MODE ENABLED"
        log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log INFO ""
        log INFO "Running forced alignment to detect and clean orphaned S3 objects..."
        log INFO "This is an EXCLUSIVE operation - regular backup will be skipped."
        log INFO ""
        
        # Run forced alignment
        if perform_forced_alignment; then
            log INFO "Forced alignment completed successfully"
            exit 0  # Alignment is exclusive - exit after completion
        else
            log ERROR "Forced alignment failed"
            exit 1
        fi
    fi
    
    # Run backup workflow
    log INFO "Starting backup workflow..."
    log INFO ""
    
    if run_backup_workflow; then
        log INFO ""
        log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log INFO "✅ BACKUP COMPLETED SUCCESSFULLY"
        log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Cleanup old deleted files (if not in dry-run)
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            log INFO ""
            log INFO "Running retention policy cleanup..."
            local s3_yesterday_base="s3://$S3_BUCKET"
            [[ -n "$S3_PREFIX" ]] && s3_yesterday_base+="/$S3_PREFIX"
            s3_yesterday_base+="/yesterday_state/"
            
            local cleanup_result=0
            cleanup_old_deleted_files "$s3_yesterday_base" || {
                log WARN "Cleanup had errors but backup succeeded"
                cleanup_result=1
            }
            
            # Refresh S3 cache after cleanup to reflect deleted files
            # Only if cleanup ran (even if it had errors)
            log INFO ""
            log INFO "Refreshing S3 cache after cleanup operations..."
            if update_s3_cache; then
                log INFO "✅ S3 cache updated to reflect cleanup changes"
            else
                log WARN "⚠️  S3 cache refresh failed after cleanup (cache may be stale)"
            fi
            
            # Backup state files to S3 (disaster recovery protection)
            log INFO ""
            log INFO "Backing up state files to S3..."
            if backup_high_level_states_to_s3; then
                log INFO "✅ State files backed up to S3"
            else
                log WARN "⚠️  State backup to S3 failed (local state preserved)"
            fi
            
            # Generate detailed S3 report if enabled (FINAL operation)
            if [[ "${DETAILED_S3_REPORT:-false}" == "true" ]]; then
                log INFO ""
                log INFO "Generating detailed S3 report (final operation)..."
                if generate_detailed_s3_report; then
                    log INFO "✅ Detailed S3 report generated: ${SCRIPT_DIR}/state/s3/s3-report.json"
                else
                    log WARN "⚠️  Detailed S3 report generation failed (not critical)"
                fi
            fi
        fi
        
        return 0
    else
        log ERROR ""
        log ERROR "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ERROR "✗ BACKUP FAILED"
        log ERROR "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    
    return 0
}

################################################################################
# CLEANUP HANDLER
################################################################################

#------------------------------------------------------------------------------
# cleanup
#
# Cleanup function called on exit (success or failure)
#------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    
    # Log final status
    if [[ $exit_code -eq 0 ]]; then
        log INFO "Backup completed successfully (exit code: $exit_code)"
    else
        log ERROR "Backup failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

# Register cleanup handler
trap cleanup EXIT

################################################################################
# ENTRY POINT
################################################################################

# Execute main function with all arguments
main "$@"

################################################################################
# END OF SCRIPT
################################################################################

