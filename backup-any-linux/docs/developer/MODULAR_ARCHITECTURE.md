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

# Modular Architecture Guide
## Refactoring s3-backup-linux.sh into Maintainable Components

**Version:** 1.0  
**Date:** November 6, 2025

---

## Table of Contents

1. [Proposed Module Structure](#1-proposed-module-structure)
2. [Interface Contracts & API Design](#2-interface-contracts--api-design)
3. [Dependency Management](#3-dependency-management)
4. [Versioning Strategy](#4-versioning-strategy)
5. [Testing Strategy](#5-testing-strategy)
6. [Migration Path](#6-migration-path)
7. [Implementation Examples](#7-implementation-examples)

---

## 1. Proposed Module Structure

### 1.1 Directory Layout

```
scripts/
├── s3-backup-linux.sh              # Main orchestrator (200 lines)
├── s3-inspect.sh                   # S3 scanner (keep as-is)
├── lib/                            # Reusable library modules
│   ├── core.sh                     # Core constants and utilities (150 lines)
│   ├── config.sh                   # Configuration management (200 lines)
│   ├── state.sh                    # State file operations (400 lines)
│   ├── filesystem.sh               # Filesystem scanning (300 lines)
│   ├── checksum.sh                 # Checksum calculations (200 lines)
│   ├── s3.sh                       # S3 operations (300 lines)
│   ├── backup.sh                   # Backup workflow (500 lines)
│   ├── deletion.sh                 # Deletion tracking (300 lines)
│   ├── alignment.sh                # Forced alignment (600 lines)
│   └── utils.sh                    # Utility functions (250 lines)
├── lib/interfaces/                 # Interface definitions
│   ├── module.interface.sh         # Module interface template
│   └── api.sh                      # Public API contracts
├── tests/                          # Test suite
│   ├── unit/                       # Unit tests per module
│   │   ├── test_config.bats
│   │   ├── test_state.bats
│   │   └── test_checksum.bats
│   └── integration/                # Integration tests
│       └── test_backup_flow.sh
├── config/
│   └── backup-config.conf          # Configuration file
└── docs/
    ├── API_REFERENCE.md            # Complete API documentation
    └── MODULAR_ARCHITECTURE.md     # This document
```

### 1.2 Module Breakdown by Responsibility

#### **core.sh** - Foundation Layer
**Purpose:** Core constants, logging, error handling  
**Lines:** ~150  
**Dependencies:** None (leaf module)

```bash
# Provides:
- Script version and metadata
- Exit codes (EX_OK, EX_CONFIG, EX_DATAERR, etc.)
- Logging functions (log, log_debug, log_error)
- Error handling (die, warn, require_*)
- Platform detection (detect_os, detect_shell)
```

#### **utils.sh** - Utility Layer
**Purpose:** Cross-platform utilities  
**Lines:** ~250  
**Dependencies:** core.sh

```bash
# Provides:
- Portable stat wrapper (get_file_mtime, get_file_size)
- Portable date wrapper (parse_iso8601_date)
- Base64 encoding (safe_base64_encode)
- JSON utilities (json_escape, json_validate)
- File operations (atomic_write, create_temp_dir)
- Size calculations (bytes_to_human, calculate_size_distribution)
```

#### **config.sh** - Configuration Layer
**Purpose:** Safe configuration loading and validation  
**Lines:** ~200  
**Dependencies:** core.sh, utils.sh

```bash
# Provides:
- load_config() - Safe parameter-based config parsing
- validate_config() - Configuration validation
- get_config_value(key) - Get configuration value
- update_config_value(key, value) - Atomic config updates
- AWS credential validation
```

#### **state.sh** - State Management Layer
**Purpose:** JSON state file operations  
**Lines:** ~400  
**Dependencies:** core.sh, utils.sh

```bash
# Provides:
- init_state_file(type) - Initialize state files
- read_state(file, query) - Read state with jq query
- update_state(file, operation) - Atomic state updates
- validate_state_file(file, schema) - Validation
- State locking (acquire_state_lock, release_state_lock)
- State recovery (recover_state_file)
```

#### **filesystem.sh** - Filesystem Operations
**Purpose:** Directory scanning and mapping  
**Lines:** ~300  
**Dependencies:** core.sh, utils.sh, state.sh

```bash
# Provides:
- find_backup_directories() - Scan for trigger files
- build_filesystem_map() - Create directory map
- filter_hierarchical_directories() - Handle nested dirs
- generate_directory_key(path) - Consistent key generation
- should_refresh_filesystem_cache() - Cache validation
```

#### **checksum.sh** - Checksum Operations
**Purpose:** File integrity verification  
**Lines:** ~200  
**Dependencies:** core.sh, utils.sh

```bash
# Provides:
- calculate_checksum(file, algorithm) - Checksum calculation
- calculate_checksum_parallel(files[], algorithm) - Batch processing
- quick_metadata_check(file, stored_metadata) - Fast comparison
- verify_file_integrity(file, expected_checksum) - Verification
```

#### **s3.sh** - S3 Operations
**Purpose:** AWS S3 interactions  
**Lines:** ~300  
**Dependencies:** core.sh, utils.sh, config.sh

```bash
# Provides:
- s3_upload(local_path, s3_path) - Upload with retry
- s3_upload_parallel(files[], s3_base) - Parallel upload
- s3_download(s3_path, local_path) - Download with retry
- s3_list(prefix) - List objects
- s3_delete(s3_path) - Delete object
- s3_move(src, dest) - Move object
- verify_s3_upload(local, s3_path) - Upload verification
- load_s3_cache(cache_file) - Cache loading
```

#### **backup.sh** - Backup Workflow
**Purpose:** Main backup orchestration  
**Lines:** ~500  
**Dependencies:** core.sh, utils.sh, state.sh, filesystem.sh, checksum.sh, s3.sh

```bash
# Provides:
- backup_directory(dir, mode) - Backup single directory
- backup_with_current_state(dirs[]) - Current state workflow
- track_file_change(file, action) - Change tracking
- handle_new_file(file) - New file processing
- handle_modified_file(file) - Modified file processing
- handle_deleted_file(file) - Deleted file processing
```

#### **deletion.sh** - Deletion Management
**Purpose:** Deleted file tracking and cleanup  
**Lines:** ~300  
**Dependencies:** core.sh, utils.sh, state.sh, s3.sh

```bash
# Provides:
- track_file_deletion(file) - Add to yesterday_state
- cleanup_old_deleted_files() - Retention policy cleanup
- parse_retention_time(retention_string) - Parse retention
- move_to_permanent_deleted(file) - Permanent deletion
- add_deleted_file_entry(file, metadata) - State tracking
- is_ready_for_permanent_deletion(file) - Check eligibility
```

#### **alignment.sh** - Forced Alignment
**Purpose:** S3 reconciliation and orphan cleanup  
**Lines:** ~600  
**Dependencies:** core.sh, utils.sh, state.sh, filesystem.sh, s3.sh

```bash
# Provides:
- perform_forced_alignment() - Main alignment workflow
- build_current_filesystem_map() - Current filesystem state
- build_s3_current_state_list() - S3 object list
- find_orphaned_s3_objects(fs_map, s3_map) - Orphan detection
- init_alignment_operation() - Alignment tracking
- track_alignment_metrics(tracking_file, size, dir) - Metrics
- finalize_alignment_history(tracking_file) - Complete alignment
- generate_alignment_report(results) - User report
```

---

## 2. Interface Contracts & API Design

### 2.1 The Problem: Maintaining Consistency

When Script A calls Script B, we need to ensure:
1. **Function signatures don't change unexpectedly**
2. **Return values are predictable**
3. **Error handling is consistent**
4. **Dependencies are explicit**

### 2.2 Solution: Interface Contracts

Create a standardized interface that all modules must follow:

```bash
# lib/interfaces/module.interface.sh
# This file defines the contract that all modules must implement

################################################################################
# MODULE INTERFACE CONTRACT
# All library modules must implement these sections:
################################################################################

# 1. MODULE METADATA
#    - MODULE_NAME: Unique module identifier
#    - MODULE_VERSION: Semantic version (MAJOR.MINOR.PATCH)
#    - MODULE_DEPENDENCIES: Array of required modules
#    - MODULE_DESCRIPTION: Brief description

# 2. PUBLIC API
#    - Exported functions that other modules can call
#    - Must be documented with:
#      * Purpose
#      * Parameters (name, type, required/optional)
#      * Return value (type, meaning)
#      * Exit codes (0=success, 1=error, 2=warning)
#      * Side effects (file modifications, state changes)

# 3. PRIVATE FUNCTIONS
#    - Internal functions prefixed with _
#    - Not part of public API, can change without notice

# 4. INITIALIZATION
#    - Module initialization code
#    - Dependency validation
#    - Feature detection

# 5. VALIDATION
#    - validate_module() function
#    - Self-test capabilities
```

### 2.3 Example: config.sh Interface

```bash
#!/bin/bash
# lib/config.sh - Configuration Management Module

################################################################################
# MODULE METADATA
################################################################################

readonly MODULE_NAME="config"
readonly MODULE_VERSION="1.0.0"
readonly MODULE_DEPENDENCIES=("core" "utils")
readonly MODULE_DESCRIPTION="Safe configuration loading and validation"

################################################################################
# MODULE INTERFACE VERSION
# Increment MINOR version when adding functions (backward compatible)
# Increment MAJOR version when changing signatures (breaking change)
################################################################################

readonly CONFIG_API_VERSION="1.0"

################################################################################
# PUBLIC API - These functions are the contract with other modules
################################################################################

#------------------------------------------------------------------------------
# load_config
#
# Purpose:
#   Load and validate configuration from backup-config.conf
#
# Parameters:
#   $1 - config_file (string, optional): Path to config file
#        Default: $CONFIG_FILE from environment
#
# Returns:
#   0 - Configuration loaded successfully
#   1 - Configuration file not found or invalid
#
# Exit Codes:
#   Uses die() for fatal errors (calls exit)
#
# Side Effects:
#   - Sets global configuration variables (S3_BUCKET, AWS_REGION, etc.)
#   - Logs configuration loading status
#
# Example:
#   load_config "/path/to/config.conf"
#   if [[ $? -eq 0 ]]; then
#       echo "Config loaded: S3_BUCKET=$S3_BUCKET"
#   fi
#------------------------------------------------------------------------------
load_config() {
    local config_file="${1:-${CONFIG_FILE}}"
    
    # Implementation...
}

#------------------------------------------------------------------------------
# validate_config
#
# Purpose:
#   Validate all required configuration values are set
#
# Parameters:
#   None
#
# Returns:
#   0 - Configuration is valid
#   1 - Configuration is invalid (specific errors logged)
#
# Exit Codes:
#   Does NOT call exit - returns error codes only
#
# Side Effects:
#   - Logs validation errors
#
# Example:
#   if validate_config; then
#       log INFO "Configuration validated"
#   else
#       die "Invalid configuration" $EX_CONFIG
#   fi
#------------------------------------------------------------------------------
validate_config() {
    # Implementation...
}

#------------------------------------------------------------------------------
# get_config_value
#
# Purpose:
#   Get a single configuration value by key
#
# Parameters:
#   $1 - key (string, required): Configuration key name
#
# Returns:
#   0 - Value found and printed to stdout
#   1 - Key not found
#
# Output:
#   Configuration value to stdout (no newline)
#
# Example:
#   bucket=$(get_config_value "S3_BUCKET")
#   [[ $? -eq 0 ]] && echo "Bucket: $bucket"
#------------------------------------------------------------------------------
get_config_value() {
    local key="$1"
    # Implementation...
}

################################################################################
# PRIVATE FUNCTIONS - Internal use only, not part of public API
################################################################################

_parse_config_line() {
    local line="$1"
    # Implementation...
}

_validate_config_key() {
    local key="$1"
    # Implementation...
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Validate dependencies are loaded
for dep in "${MODULE_DEPENDENCIES[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: ${MODULE_NAME} requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

# Feature detection
if ! command -v jq >/dev/null 2>&1; then
    log WARN "${MODULE_NAME}: jq not available, some features disabled"
fi

################################################################################
# MODULE VALIDATION
################################################################################

# Self-test function
validate_module_config() {
    local errors=0
    
    # Check all public functions are defined
    for func in load_config validate_config get_config_value; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module ${MODULE_NAME}: Missing function $func"
            ((errors++))
        fi
    done
    
    return $errors
}

# Run self-test if MODULE_VALIDATE is set
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_config || exit 1
fi
```

### 2.4 API Registry

Create a central registry of all public functions:

```bash
# lib/interfaces/api.sh
# Central API registry - documents all public interfaces

################################################################################
# BACKUP SYSTEM PUBLIC API - Version 1.0
################################################################################

declare -gA API_REGISTRY=(
    # core.sh functions
    ["log"]="1.0:core:Log message with level"
    ["die"]="1.0:core:Fatal error exit"
    ["warn"]="1.0:core:Warning message"
    ["require_command"]="1.0:core:Ensure command exists"
    
    # utils.sh functions
    ["get_file_mtime"]="1.0:utils:Get file modification time"
    ["get_file_size"]="1.0:utils:Get file size"
    ["atomic_write"]="1.0:utils:Atomic file write"
    ["bytes_to_human"]="1.0:utils:Convert bytes to human readable"
    
    # config.sh functions
    ["load_config"]="1.0:config:Load configuration file"
    ["validate_config"]="1.0:config:Validate configuration"
    ["get_config_value"]="1.0:config:Get config value by key"
    
    # state.sh functions
    ["init_state_file"]="1.0:state:Initialize state file"
    ["read_state"]="1.0:state:Read state with jq query"
    ["update_state"]="1.0:state:Update state atomically"
    ["acquire_state_lock"]="1.0:state:Acquire exclusive lock"
    
    # filesystem.sh functions
    ["find_backup_directories"]="1.0:filesystem:Find dirs with trigger files"
    ["build_filesystem_map"]="1.0:filesystem:Build directory map"
    
    # checksum.sh functions
    ["calculate_checksum"]="1.0:checksum:Calculate file checksum"
    ["quick_metadata_check"]="1.0:checksum:Fast metadata comparison"
    
    # s3.sh functions
    ["s3_upload"]="1.0:s3:Upload file to S3"
    ["s3_upload_parallel"]="1.0:s3:Parallel upload multiple files"
    ["s3_list"]="1.0:s3:List S3 objects"
    
    # backup.sh functions
    ["backup_directory"]="1.0:backup:Backup single directory"
    ["backup_with_current_state"]="1.0:backup:Run current state workflow"
    
    # deletion.sh functions
    ["track_file_deletion"]="1.0:deletion:Track deleted file"
    ["cleanup_old_deleted_files"]="1.0:deletion:Clean expired deletions"
    
    # alignment.sh functions
    ["perform_forced_alignment"]="1.0:alignment:Run forced alignment"
)

# Get function info from registry
get_function_info() {
    local func_name="$1"
    local info="${API_REGISTRY[$func_name]}"
    
    if [[ -z "$info" ]]; then
        echo "ERROR: Function '$func_name' not in API registry" >&2
        return 1
    fi
    
    # Parse: version:module:description
    local version="${info%%:*}"
    local rest="${info#*:}"
    local module="${rest%%:*}"
    local description="${rest#*:}"
    
    echo "Function: $func_name"
    echo "Version:  $version"
    echo "Module:   $module"
    echo "Description: $description"
}

# Validate a function exists and is correct version
validate_function() {
    local func_name="$1"
    local required_version="${2:-1.0}"
    
    # Check function exists
    if ! declare -F "$func_name" >/dev/null 2>&1; then
        echo "ERROR: Required function not found: $func_name" >&2
        return 1
    fi
    
    # Check version compatibility
    local info="${API_REGISTRY[$func_name]}"
    local actual_version="${info%%:*}"
    
    # Simple version check (major version must match)
    local required_major="${required_version%%.*}"
    local actual_major="${actual_version%%.*}"
    
    if [[ "$required_major" != "$actual_major" ]]; then
        echo "ERROR: Function $func_name version mismatch" >&2
        echo "  Required: $required_version (major: $required_major)" >&2
        echo "  Actual:   $actual_version (major: $actual_major)" >&2
        return 1
    fi
    
    return 0
}
```

---

## 3. Dependency Management

### 3.1 Module Loading Pattern

Use a central loader that manages dependencies:

```bash
# lib/loader.sh
# Module dependency loader with topological sorting

################################################################################
# MODULE LOADER - Ensures correct load order
################################################################################

# Track loaded modules
declare -gA LOADED_MODULES=()

# Module dependency graph
declare -gA MODULE_DEPS=(
    ["core"]=""                                    # No dependencies
    ["utils"]="core"
    ["config"]="core utils"
    ["state"]="core utils"
    ["filesystem"]="core utils state"
    ["checksum"]="core utils"
    ["s3"]="core utils config"
    ["backup"]="core utils state filesystem checksum s3"
    ["deletion"]="core utils state s3"
    ["alignment"]="core utils state filesystem s3"
)

# Load a single module
load_module() {
    local module_name="$1"
    
    # Check if already loaded
    if [[ -n "${LOADED_MODULES[$module_name]:-}" ]]; then
        return 0
    fi
    
    # Get dependencies
    local deps="${MODULE_DEPS[$module_name]:-}"
    
    # Load dependencies first
    for dep in $deps; do
        load_module "$dep" || return 1
    done
    
    # Load the module
    local module_path="${SCRIPT_DIR}/lib/${module_name}.sh"
    
    if [[ ! -f "$module_path" ]]; then
        echo "ERROR: Module not found: $module_path" >&2
        return 1
    fi
    
    source "$module_path" || {
        echo "ERROR: Failed to load module: $module_name" >&2
        return 1
    }
    
    # Mark as loaded
    LOADED_MODULES[$module_name]=1
    
    return 0
}

# Load multiple modules
load_modules() {
    local modules=("$@")
    
    for module in "${modules[@]}"; do
        load_module "$module" || return 1
    done
    
    return 0
}

# Validate all modules are loaded
validate_modules() {
    local errors=0
    
    for module in "${!MODULE_DEPS[@]}"; do
        if [[ -z "${LOADED_MODULES[$module]:-}" ]]; then
            echo "ERROR: Module not loaded: $module" >&2
            ((errors++))
        fi
    done
    
    return $errors
}
```

### 3.2 Main Script Structure

The main script becomes a thin orchestrator:

```bash
#!/bin/bash
# s3-backup-linux.sh - Main backup orchestrator

set -euo pipefail

# Get script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load module loader
source "${SCRIPT_DIR}/lib/loader.sh"

# Load required modules in correct order
load_modules core utils config state filesystem checksum s3 backup || {
    echo "ERROR: Failed to load required modules" >&2
    exit 1
}

# Main function
main() {
    # Simple orchestration - delegate to modules
    log INFO "Backup starting..."
    
    # Load and validate configuration
    load_config || die "Configuration loading failed" $EX_CONFIG
    validate_config || die "Configuration invalid" $EX_CONFIG
    
    # Initialize state
    init_state_file "backup" || die "State initialization failed"
    
    # Validate AWS access
    validate_aws_credentials || die "AWS credentials invalid"
    
    # Run backup workflow
    if [[ "${FORCE_ALIGNMENT_MODE}" == "true" ]]; then
        load_module alignment || die "Failed to load alignment module"
        perform_forced_alignment || die "Alignment failed"
    else
        backup_with_current_state || die "Backup failed"
    fi
    
    log INFO "Backup completed successfully"
}

# Execute
main "$@"
```

### 3.3 Dependency Visualization

```
                    ┌──────────┐
                    │  core.sh │ (no deps)
                    └─────┬────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
         ┌─────────┐            ┌──────────┐
         │utils.sh │            │config.sh │
         └────┬────┘            └─────┬────┘
              │                       │
         ┌────┴────┬──────────────────┴────┬────────────┐
         ▼         ▼                       ▼            ▼
    ┌────────┐ ┌─────────┐          ┌──────────┐  ┌──────┐
    │state.sh│ │checksum │          │   s3.sh  │  │  ... │
    └───┬────┘ └─────────┘          └────┬─────┘  └──────┘
        │                                 │
        └──────────┬──────────────────────┘
                   ▼
            ┌──────────────┐
            │filesystem.sh │
            └──────┬───────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
   ┌─────────┐          ┌───────────┐
   │backup.sh│          │deletion.sh│
   └─────────┘          └───────────┘
        │                     │
        └──────────┬──────────┘
                   ▼
            ┌──────────────┐
            │alignment.sh  │
            └──────────────┘
```

---

## 4. Versioning Strategy

### 4.1 Semantic Versioning for Modules

Each module has independent versioning:

```bash
# Module version format: MAJOR.MINOR.PATCH

# MAJOR: Breaking changes (function signatures changed)
#        Example: load_config() changes parameter order
#
# MINOR: New features (backward compatible)
#        Example: Adding new function get_config_section()
#
# PATCH: Bug fixes (no API changes)
#        Example: Fixing validation logic bug
```

### 4.2 Compatibility Matrix

Track which module versions work together:

```bash
# lib/versions.sh
# Module compatibility matrix

readonly COMPATIBILITY_MATRIX="
core:1.0       -> utils:1.0-1.x
utils:1.0      -> config:1.0-1.x, state:1.0-1.x
config:1.0     -> s3:1.0-1.x, backup:1.0-1.x
state:1.0      -> filesystem:1.0-1.x, backup:1.0-1.x
filesystem:1.0 -> backup:1.0-1.x, alignment:1.0-1.x
checksum:1.0   -> backup:1.0-1.x
s3:1.0         -> backup:1.0-1.x, deletion:1.0-1.x, alignment:1.0-1.x
"

# Check if module versions are compatible
check_compatibility() {
    local module1="$1"
    local version1="$2"
    local module2="$3"
    local version2="$4"
    
    # Extract major versions
    local major1="${version1%%.*}"
    local major2="${version2%%.*}"
    
    # Major versions must match
    if [[ "$major1" != "$major2" ]]; then
        echo "ERROR: Incompatible module versions" >&2
        echo "  $module1 v$version1 <-> $module2 v$version2" >&2
        return 1
    fi
    
    return 0
}
```

### 4.3 Version Declaration in Modules

Every module declares its version and required versions:

```bash
# lib/backup.sh
readonly MODULE_NAME="backup"
readonly MODULE_VERSION="1.0.0"

# Required versions of dependencies
declare -gA REQUIRED_MODULE_VERSIONS=(
    ["core"]="1.0"
    ["utils"]="1.0"
    ["state"]="1.0"
    ["filesystem"]="1.0"
    ["checksum"]="1.0"
    ["s3"]="1.0"
)

# Validate dependencies at load time
for module in "${!REQUIRED_MODULE_VERSIONS[@]}"; do
    required_version="${REQUIRED_MODULE_VERSIONS[$module]}"
    
    # Check module is loaded
    if [[ -z "${LOADED_MODULES[$module]:-}" ]]; then
        die "Module $module required by ${MODULE_NAME} is not loaded"
    fi
    
    # Get actual version (each module exports ${MODULE}_VERSION)
    actual_version_var="${module^^}_VERSION"  # Convert to uppercase
    actual_version="${!actual_version_var:-0.0}"
    
    # Validate compatibility
    check_compatibility "$module" "$required_version" "${MODULE_NAME}" "$MODULE_VERSION" || exit 1
done
```

---

## 5. Testing Strategy

### 5.1 Unit Testing Per Module

Each module gets its own test file:

```bash
# tests/unit/test_config.bats
#!/usr/bin/env bats

# Setup - load only the module under test and its dependencies
setup() {
    load ../lib/loader
    load_modules core utils config
}

@test "config: load_config loads valid configuration" {
    # Create test config
    cat > "$BATS_TMPDIR/test.conf" <<EOF
S3_BUCKET="test-bucket"
AWS_REGION="us-west-2"
EOF
    
    # Test
    CONFIG_FILE="$BATS_TMPDIR/test.conf"
    run load_config
    
    # Assert
    [ "$status" -eq 0 ]
    [ "$S3_BUCKET" = "test-bucket" ]
    [ "$AWS_REGION" = "us-west-2" ]
}

@test "config: load_config rejects command injection" {
    # Create malicious config
    cat > "$BATS_TMPDIR/evil.conf" <<EOF
S3_BUCKET="\$(rm -rf /tmp/test)"
EOF
    
    CONFIG_FILE="$BATS_TMPDIR/evil.conf"
    run load_config
    
    # Should sanitize or reject
    [ "$S3_BUCKET" != "\$(rm -rf /tmp/test)" ]
}

@test "config: validate_config detects missing required fields" {
    S3_BUCKET=""  # Empty required field
    run validate_config
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "S3_BUCKET" ]]
}

@test "config: get_config_value returns correct value" {
    S3_BUCKET="my-bucket"
    run get_config_value "S3_BUCKET"
    
    [ "$status" -eq 0 ]
    [ "$output" = "my-bucket" ]
}
```

### 5.2 Integration Testing

Test module interactions:

```bash
# tests/integration/test_backup_workflow.bats
#!/usr/bin/env bats

setup() {
    # Load all modules
    load ../lib/loader
    load_modules core utils config state filesystem checksum s3 backup
    
    # Setup test environment
    export TEST_DIR="$BATS_TMPDIR/integration_test"
    export MOUNT_DIR="$TEST_DIR/mount"
    export S3_BUCKET="test-bucket"
    
    mkdir -p "$MOUNT_DIR/project1"
    echo "test" > "$MOUNT_DIR/project1/backupthisdir.txt"
    echo "data" > "$MOUNT_DIR/project1/file1.txt"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "integration: full backup cycle" {
    # Initialize state
    run init_state_file "backup"
    [ "$status" -eq 0 ]
    
    # Find backup directories
    run find_backup_directories
    [ "$status" -eq 0 ]
    [[ "$output" =~ "project1" ]]
    
    # Run backup (mock S3 operations)
    MOCK_S3=true run backup_with_current_state
    [ "$status" -eq 0 ]
}

@test "integration: module dependencies are satisfied" {
    # Verify all required modules are loaded
    for module in core utils config state filesystem checksum s3 backup; do
        [ -n "${LOADED_MODULES[$module]:-}" ]
    done
}
```

### 5.3 Contract Testing

Verify module interfaces don't break:

```bash
# tests/contract/test_interfaces.bats
#!/usr/bin/env bats

@test "contract: core.sh exports required functions" {
    load ../lib/core
    
    # Required functions
    declare -F log >/dev/null
    declare -F die >/dev/null
    declare -F warn >/dev/null
}

@test "contract: log function has correct signature" {
    load ../lib/core
    
    # Should accept 2+ arguments: level, message...
    run log INFO "test message"
    [ "$status" -eq 0 ]
    
    # Should fail with 0 arguments
    run log
    [ "$status" -ne 0 ]
}

@test "contract: module versions are defined" {
    load ../lib/core
    load ../lib/utils
    
    # Each module must export MODULE_VERSION
    [ -n "$CORE_VERSION" ]
    [ -n "$UTILS_VERSION" ]
    
    # Versions should be semantic (X.Y.Z)
    [[ "$CORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
```

---

## 6. Migration Path

### 6.1 Phased Migration Strategy

**Phase 1: Extract Core & Utils (Week 1)**
```bash
# Day 1-2: Extract core.sh
- Move logging functions
- Move error handling
- Test in isolation

# Day 3-4: Extract utils.sh  
- Move portable wrappers
- Move size calculations
- Test in isolation

# Day 5: Integration
- Update main script to load core + utils
- Run full test suite
- Validate no regressions
```

**Phase 2: Extract Config & State (Week 2)**
```bash
# Day 1-2: Extract config.sh
- Rewrite configuration loading (fix security!)
- Add validation
- Test config loading

# Day 3-4: Extract state.sh
- Move JSON state operations
- Add locking
- Test state operations

# Day 5: Integration
- Update main script
- Run full test suite
```

**Phase 3: Extract Business Logic (Week 3-4)**
```bash
# Week 3:
- Extract filesystem.sh, checksum.sh, s3.sh
- Test independently

# Week 4:
- Extract backup.sh, deletion.sh, alignment.sh
- Final integration
- Comprehensive testing
```

### 6.2 Backwards Compatibility During Migration

Create compatibility shims:

```bash
# s3-backup-linux.sh (during migration)

# Load new modular code
if [[ -f "${SCRIPT_DIR}/lib/loader.sh" ]]; then
    # New modular system
    source "${SCRIPT_DIR}/lib/loader.sh"
    load_modules core utils config state
    USE_MODULAR=true
else
    # Old monolithic code
    USE_MODULAR=false
fi

# Compatibility wrapper
backup_directory() {
    if [[ "$USE_MODULAR" == "true" ]]; then
        # Call new modular function
        backup::backup_directory "$@"
    else
        # Use old inline code
        _old_backup_directory "$@"
    fi
}
```

---

## 7. Implementation Examples

### 7.1 Complete Example: config.sh Module

```bash
#!/bin/bash
# lib/config.sh - Configuration Management Module
# Version: 1.0.0
# Dependencies: core, utils

################################################################################
# MODULE METADATA
################################################################################

readonly CONFIG_MODULE_VERSION="1.0.0"
readonly CONFIG_MODULE_NAME="config"
readonly CONFIG_MODULE_DEPS=("core" "utils")

################################################################################
# CONFIGURATION VALIDATION
################################################################################

# Configuration keys whitelist
readonly ALLOWED_CONFIG_KEYS=(
    "S3_BUCKET"
    "S3_PREFIX"
    "AWS_REGION"
    "AWS_PROFILE"
    "BACKUP_STRATEGY"
    "PRESERVE_DIRECTORY_PATHS"
    "BACKUP_ORGANIZATION"
    "DELETED_FILE_RETENTION"
    "LOG_LEVEL"
    "MAX_LOG_SIZE"
    "CHECKSUM_ALGORITHM"
    "INTEGRITY_MODE"
    "DRY_RUN"
    "MOUNT_DIR"
    "FORCE_ALIGNMENT_MODE"
    "ALIGNMENT_HISTORY_RETENTION"
    "FILESYSTEM_SCAN_REFRESH_HOURS"
    "FORCE_FILESYSTEM_SCAN_REFRESH"
    "AUDIT_SYSTEM_ENABLED"
)

# Required configuration keys
readonly REQUIRED_CONFIG_KEYS=(
    "S3_BUCKET"
    "AWS_REGION"
)

################################################################################
# PUBLIC API
################################################################################

#------------------------------------------------------------------------------
# load_config
#
# Load and validate configuration from file using SAFE parameter parsing
# (NOT using source - prevents command injection)
#
# Parameters:
#   $1 - config_file (optional): Path to config file
#
# Returns:
#   0 - Configuration loaded successfully
#   1 - Configuration file not found or invalid
#
# Side Effects:
#   Sets global configuration variables
#------------------------------------------------------------------------------
load_config() {
    local config_file="${1:-${CONFIG_FILE}}"
    
    if [[ ! -f "$config_file" ]]; then
        log WARN "Configuration file not found: $config_file"
        return 1
    fi
    
    # Validate file is not executable (security check)
    if [[ -x "$config_file" ]]; then
        log ERROR "Configuration file must not be executable: $config_file"
        return 1
    fi
    
    log DEBUG "Loading configuration from: $config_file"
    
    # Parse configuration safely (line by line, no sourcing!)
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        
        # Parse KEY=VALUE format
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Validate key is in whitelist
            if ! _is_allowed_config_key "$key"; then
                log WARN "Unknown configuration key ignored: $key (line $line_num)"
                continue
            fi
            
            # Strip quotes from value
            value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//' | xargs)
            
            # Validate value doesn't contain dangerous patterns
            if _contains_dangerous_pattern "$value"; then
                log ERROR "Configuration value contains dangerous pattern: $key=$value"
                return 1
            fi
            
            # Safe assignment using printf (avoids command substitution)
            printf -v "$key" '%s' "$value"
            log DEBUG "Config: $key=$value"
        else
            log WARN "Invalid configuration line ignored (line $line_num): $line"
        fi
    done < "$config_file"
    
    # Validate configuration
    validate_config || return 1
    
    log INFO "Configuration loaded successfully from: $config_file"
    return 0
}

#------------------------------------------------------------------------------
# validate_config
#
# Validate all required configuration values are set and valid
#
# Returns:
#   0 - Configuration is valid
#   1 - Configuration is invalid
#------------------------------------------------------------------------------
validate_config() {
    local errors=0
    
    # Check required keys
    for key in "${REQUIRED_CONFIG_KEYS[@]}"; do
        local value="${!key:-}"
        if [[ -z "$value" ]]; then
            log ERROR "Required configuration missing: $key"
            ((errors++))
        fi
    done
    
    # Validate S3_BUCKET format
    if [[ -n "${S3_BUCKET:-}" ]]; then
        if ! [[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
            log ERROR "Invalid S3_BUCKET format: $S3_BUCKET"
            ((errors++))
        fi
    fi
    
    # Validate AWS_REGION format
    if [[ -n "${AWS_REGION:-}" ]]; then
        if ! [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
            log ERROR "Invalid AWS_REGION format: $AWS_REGION"
            ((errors++))
        fi
    fi
    
    # Validate CHECKSUM_ALGORITHM
    if [[ -n "${CHECKSUM_ALGORITHM:-}" ]]; then
        case "$CHECKSUM_ALGORITHM" in
            md5|sha256|mtime) ;;
            *)
                log ERROR "Invalid CHECKSUM_ALGORITHM: $CHECKSUM_ALGORITHM (must be md5, sha256, or mtime)"
                ((errors++))
                ;;
        esac
    fi
    
    # Validate LOG_LEVEL
    if [[ -n "${LOG_LEVEL:-}" ]]; then
        case "$LOG_LEVEL" in
            DEBUG|INFO|WARN|ERROR) ;;
            *)
                log ERROR "Invalid LOG_LEVEL: $LOG_LEVEL (must be DEBUG, INFO, WARN, or ERROR)"
                ((errors++))
                ;;
        esac
    fi
    
    if [[ $errors -gt 0 ]]; then
        log ERROR "Configuration validation failed with $errors errors"
        return 1
    fi
    
    log DEBUG "Configuration validation passed"
    return 0
}

#------------------------------------------------------------------------------
# get_config_value
#
# Get a configuration value by key
#
# Parameters:
#   $1 - key: Configuration key name
#
# Returns:
#   0 - Value found and printed to stdout
#   1 - Key not found or not set
#------------------------------------------------------------------------------
get_config_value() {
    local key="$1"
    
    if [[ -z "${!key:-}" ]]; then
        return 1
    fi
    
    echo -n "${!key}"
    return 0
}

################################################################################
# PRIVATE FUNCTIONS
################################################################################

_is_allowed_config_key() {
    local key="$1"
    
    for allowed_key in "${ALLOWED_CONFIG_KEYS[@]}"; do
        if [[ "$key" == "$allowed_key" ]]; then
            return 0
        fi
    done
    
    return 1
}

_contains_dangerous_pattern() {
    local value="$1"
    
    # Check for command substitution attempts
    if [[ "$value" =~ \$\( ]] || [[ "$value" =~ \` ]]; then
        return 0
    fi
    
    # Check for semicolons (command chaining)
    if [[ "$value" =~ \; ]]; then
        return 0
    fi
    
    # Check for pipe attempts
    if [[ "$value" =~ \| ]]; then
        return 0
    fi
    
    return 1
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Validate dependencies
for dep in "${CONFIG_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: config.sh requires ${dep}.sh to be loaded first" >&2
        exit 1
    fi
done

log DEBUG "Module loaded: $CONFIG_MODULE_NAME v$CONFIG_MODULE_VERSION"
```

### 7.2 Complete Example: Main Orchestrator

```bash
#!/bin/bash
# s3-backup-linux.sh - Modular Backup System
# Version: 2.0.0 (Modular Architecture)

set -euo pipefail

################################################################################
# BOOTSTRAP
################################################################################

# Get script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Constants
readonly BACKUP_SYSTEM_VERSION="2.0.0"
readonly CONFIG_FILE="${SCRIPT_DIR}/config/backup-config.conf"
readonly STATE_FILE="${SCRIPT_DIR}/backup-state.json"

################################################################################
# MODULE LOADING
################################################################################

# Load module system
if [[ ! -f "${SCRIPT_DIR}/lib/loader.sh" ]]; then
    echo "ERROR: Module loader not found: ${SCRIPT_DIR}/lib/loader.sh" >&2
    exit 1
fi

source "${SCRIPT_DIR}/lib/loader.sh"

# Load required modules
log INFO "Loading backup system modules..."
load_modules core utils config state filesystem checksum s3 backup || {
    echo "ERROR: Failed to load required modules" >&2
    exit 1
}

log INFO "✅ All modules loaded successfully"

################################################################################
# COMMAND LINE INTERFACE
################################################################################

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Modular S3 Backup System v${BACKUP_SYSTEM_VERSION}

OPTIONS:
    --dry-run              Simulate operations without making changes
    --force-alignment      Run forced alignment to reconcile S3 state
    --config FILE          Use alternative configuration file
    --help, -h             Show this help message
    --version              Show version information
    --validate-modules     Validate all modules and exit

EXAMPLES:
    # Dry run
    $(basename "$0") --dry-run
    
    # Force alignment
    $(basename "$0") --force-alignment
    
    # Use custom config
    $(basename "$0") --config /path/to/config.conf

CONFIGURATION:
    Edit: $CONFIG_FILE

LOGS:
    View: $SCRIPT_DIR/backup.log

EOF
}

show_version() {
    echo "S3 Backup System v${BACKUP_SYSTEM_VERSION}"
    echo ""
    echo "Loaded Modules:"
    for module in "${!LOADED_MODULES[@]}"; do
        version_var="${module^^}_MODULE_VERSION"
        version="${!version_var:-unknown}"
        echo "  - $module: v$version"
    done
}

################################################################################
# ARGUMENT PARSING
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                export DRY_RUN=true
                shift
                ;;
            --force-alignment)
                export FORCE_ALIGNMENT_MODE=true
                shift
                ;;
            --config)
                export CONFIG_FILE="$2"
                shift 2
                ;;
            --validate-modules)
                validate_modules
                echo "✅ All modules validated successfully"
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
}

################################################################################
# MAIN WORKFLOW
################################################################################

main() {
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "S3 Backup System v${BACKUP_SYSTEM_VERSION} Starting"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Load configuration
    log INFO "Loading configuration..."
    load_config "$CONFIG_FILE" || die "Configuration loading failed" $EX_CONFIG
    
    # Initialize state files
    log INFO "Initializing state files..."
    init_state_file "backup" || die "State initialization failed"
    
    # Validate AWS credentials
    log INFO "Validating AWS credentials..."
    validate_aws_credentials || die "AWS credentials invalid"
    
    # Run appropriate workflow
    if [[ "${FORCE_ALIGNMENT_MODE:-false}" == "true" ]]; then
        log INFO "Running forced alignment mode..."
        load_module alignment || die "Failed to load alignment module"
        perform_forced_alignment || die "Forced alignment failed"
    else
        log INFO "Running backup workflow..."
        backup_with_current_state || die "Backup workflow failed"
    fi
    
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "✅ Backup completed successfully"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Execute main
main "$@"
```

---

## 8. Benefits of Modular Architecture

### 8.1 Development Benefits

| Aspect | Before (Monolithic) | After (Modular) |
|--------|---------------------|-----------------|
| **Lines per file** | 6,097 lines | 150-600 lines per module |
| **Time to understand** | Hours | Minutes per module |
| **Time to make changes** | High risk, slow | Low risk, fast |
| **Testing** | Full script only | Unit test each module |
| **Debugging** | Grep 6K lines | Debug single module |
| **Code reuse** | Copy/paste | Import module |

### 8.2 Maintenance Benefits

| Scenario | Before | After |
|----------|--------|-------|
| **Fix checksum bug** | Edit 6K line file, test everything | Edit checksum.sh (200 lines), run unit tests |
| **Add new S3 operation** | Find s3 code scattered across file | Add to s3.sh, update API registry |
| **Change config format** | Touch 50+ locations | Edit config.sh only |
| **Upgrade to Bash 5** | Test entire script | Test modules individually |

### 8.3 Collaboration Benefits

- **Multiple developers** can work on different modules simultaneously
- **Code reviews** are faster (review 200 lines vs 6,000)
- **Onboarding** is easier (understand one module at a time)
- **Ownership** is clearer (person A owns checksum.sh, person B owns s3.sh)

---

## 9. Conclusion

### 9.1 Summary

By splitting the monolithic 6,097-line script into 10 focused modules:

1. **Each module has a single responsibility**
2. **Interfaces are explicitly defined and versioned**
3. **Dependencies are managed automatically**
4. **Testing is granular and fast**
5. **Changes are isolated and safe**

### 9.2 Next Steps

1. **Week 1:** Extract core.sh and utils.sh
2. **Week 2:** Extract config.sh and state.sh
3. **Week 3-4:** Extract remaining business logic modules
4. **Week 5:** Comprehensive testing and documentation

### 9.3 Maintenance Going Forward

**When adding a new function:**
1. Add to appropriate module
2. Update module version (MINOR++)
3. Add to API registry
4. Write unit test
5. Update documentation

**When changing a function signature:**
1. Increment MAJOR version
2. Update all callers
3. Update compatibility matrix
4. Add migration guide

---

**End of Modular Architecture Guide**

For questions or suggestions, please open an issue in the project repository.

