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
# loader.sh - Module Dependency Management System
################################################################################
# Purpose: Provides automatic dependency resolution and loading for all modules
#          in the lib/ directory. Ensures modules are loaded in correct order
#          based on their declared dependencies.
#
# Dependencies: None (bootstrap module - loads first)
#
# Public API:
#   - load_module()        : Load a single module with dependencies
#   - load_modules()       : Load multiple modules
#   - validate_modules()   : Validate all loaded modules
#   - list_loaded_modules(): List all currently loaded modules
#   - is_module_loaded()   : Check if specific module is loaded
#
# Usage:
#   source "${SCRIPT_DIR}/lib/loader.sh"
#   load_modules core utils config state
#   # All modules now available
#
# Version: 1.0.0
# Author: mpiercy@nvidia.com
# Last Modified: 2025-10-02
################################################################################

################################################################################
# MODULE METADATA
################################################################################

readonly LOADER_MODULE_VERSION="1.0.0"
readonly LOADER_MODULE_NAME="loader"

################################################################################
# CONFIGURATION
################################################################################

# Get library directory (where all modules are located)
readonly LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Track loaded modules (associative array: module_name => 1)
# Using global scope so all sourced modules can check
declare -gA LOADED_MODULES=()

# Module dependency graph
# Format: ["module_name"]="space-separated list of dependencies"
# Listed in topological order for clarity
declare -gA MODULE_DEPS=(
    # Layer 1: No dependencies
    ["core"]=""
    
    # Layer 2: Depend only on core
    ["utils"]="core"
    
    # Layer 3: Depend on core + utils
    ["config"]="core utils"
    ["state"]="core utils"
    
    # Layer 4: Depend on previous layers
    ["filesystem"]="core utils state"
    ["checksum"]="core utils state"
    ["s3"]="core utils config state"
    
    # Layer 5: Business logic (depend on everything)
    ["backup"]="core utils config state filesystem checksum s3"
    ["deletion"]="core utils config state s3"
    ["alignment"]="core utils config state filesystem s3"
    ["statebackup"]="core utils config state s3"
)

################################################################################
# PRIVATE HELPER FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# _get_module_path
#
# Constructs full path to module file
#
# Parameters:
#   $1 - module_name: Name of module (without .sh extension)
#
# Returns:
#   0 - Success, path printed to stdout
#   1 - Module file not found
#
# Internal Use Only
#------------------------------------------------------------------------------
_get_module_path() {
    local module_name="$1"
    local module_path="${LIB_DIR}/${module_name}.sh"
    
    if [[ -f "$module_path" ]]; then
        echo "$module_path"
        return 0
    else
        return 1
    fi
}

#------------------------------------------------------------------------------
# _validate_module_name
#
# Validates that module name is in the dependency graph
#
# Parameters:
#   $1 - module_name: Name of module to validate
#
# Returns:
#   0 - Module name is valid
#   1 - Module name is unknown
#
# Internal Use Only
#------------------------------------------------------------------------------
_validate_module_name() {
    local module_name="$1"
    
    # Check if module exists in dependency graph
    [[ -n "${MODULE_DEPS[$module_name]+x}" ]]
}

################################################################################
# PUBLIC API: MODULE LOADING FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# load_module
#
# Loads a single module and all its dependencies (recursive)
#
# Parameters:
#   $1 - module_name: Name of module to load (without .sh extension)
#
# Returns:
#   0 - Module and all dependencies loaded successfully
#   1 - Failed to load module or one of its dependencies
#
# Side Effects:
#   Sources the module file and all dependency files
#   Updates LOADED_MODULES tracking array
#
# Example:
#   if load_module "config"; then
#       echo "Config module ready"
#   fi
#
# Note:
#   Safe to call multiple times - already-loaded modules are skipped
#------------------------------------------------------------------------------
load_module() {
    local module_name="$1"
    
    # Validate module name
    if ! _validate_module_name "$module_name"; then
        echo "ERROR: Unknown module: $module_name" >&2
        echo "Available modules: ${!MODULE_DEPS[*]}" >&2
        return 1
    fi
    
    # Check if already loaded (idempotent operation)
    if [[ -n "${LOADED_MODULES[$module_name]:-}" ]]; then
        return 0  # Already loaded, nothing to do
    fi
    
    # Get module dependencies
    local deps="${MODULE_DEPS[$module_name]:-}"
    
    # Load dependencies first (recursive depth-first traversal)
    for dep in $deps; do
        if ! load_module "$dep"; then
            echo "ERROR: Failed to load dependency '$dep' (required by '$module_name')" >&2
            return 1
        fi
    done
    
    # Get module file path
    local module_path
    if ! module_path=$(_get_module_path "$module_name"); then
        echo "ERROR: Module file not found: ${LIB_DIR}/${module_name}.sh" >&2
        return 1
    fi
    
    # Source the module file
    # shellcheck disable=SC1090
    if ! source "$module_path"; then
        echo "ERROR: Failed to source module: $module_name" >&2
        return 1
    fi
    
    # Mark module as loaded
    LOADED_MODULES[$module_name]=1
    
    # Log loading (if log function is available from core module)
    if declare -F "log" >/dev/null 2>&1; then
        # Get module version if defined
        local version_var="${module_name^^}_MODULE_VERSION"
        local version="${!version_var:-unknown}"
        log DEBUG "Loaded module: $module_name v$version"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# load_modules
#
# Loads multiple modules in one call (convenience function)
#
# Parameters:
#   $@ - module_names: Space-separated list of module names
#
# Returns:
#   0 - All modules loaded successfully
#   1 - One or more modules failed to load
#
# Example:
#   load_modules core utils config state || exit 1
#   # Now all four modules are available
#------------------------------------------------------------------------------
load_modules() {
    local modules=("$@")
    local failed_modules=()
    
    # Validate we have at least one module
    if [[ ${#modules[@]} -eq 0 ]]; then
        echo "ERROR: load_modules: No modules specified" >&2
        return 1
    fi
    
    # Load each module
    for module in "${modules[@]}"; do
        if ! load_module "$module"; then
            failed_modules+=("$module")
        fi
    done
    
    # Report failures
    if [[ ${#failed_modules[@]} -gt 0 ]]; then
        echo "ERROR: Failed to load modules: ${failed_modules[*]}" >&2
        return 1
    fi
    
    return 0
}

################################################################################
# PUBLIC API: MODULE VALIDATION FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# validate_modules
#
# Validates all loaded modules are correctly configured
#
# Parameters:
#   None
#
# Returns:
#   0 - All loaded modules passed validation
#   1 - One or more modules failed validation
#
# Example:
#   if validate_modules; then
#       echo "All modules validated successfully"
#   fi
#------------------------------------------------------------------------------
validate_modules() {
    local errors=0
    
    # Check if any modules are loaded
    if [[ ${#LOADED_MODULES[@]} -eq 0 ]]; then
        echo "WARN: No modules loaded to validate" >&2
        return 0
    fi
    
    # Validate each loaded module
    for module in "${!LOADED_MODULES[@]}"; do
        # Check module exports expected metadata
        local version_var="${module^^}_MODULE_VERSION"
        if [[ -z "${!version_var:-}" ]]; then
            echo "ERROR: Module '$module' missing version metadata (${version_var})" >&2
            ((errors++))
        fi
        
        # Run module-specific validation if available
        local validate_func="validate_module_${module}"
        if declare -F "$validate_func" >/dev/null 2>&1; then
            if ! "$validate_func"; then
                echo "ERROR: Module '$module' validation failed" >&2
                ((errors++))
            fi
        fi
    done
    
    # Summary
    if [[ $errors -eq 0 ]]; then
        if declare -F "log" >/dev/null 2>&1; then
            log DEBUG "Module validation passed: ${#LOADED_MODULES[@]} modules OK"
        fi
    else
        echo "ERROR: Module validation failed with $errors errors" >&2
    fi
    
    return $errors
}

################################################################################
# PUBLIC API: MODULE QUERY FUNCTIONS
################################################################################

#------------------------------------------------------------------------------
# is_module_loaded
#
# Checks if a specific module is loaded
#
# Parameters:
#   $1 - module_name: Name of module to check
#
# Returns:
#   0 - Module is loaded
#   1 - Module is not loaded
#
# Example:
#   if is_module_loaded "config"; then
#       echo "Config module is available"
#   fi
#------------------------------------------------------------------------------
is_module_loaded() {
    local module_name="$1"
    [[ -n "${LOADED_MODULES[$module_name]:-}" ]]
}

#------------------------------------------------------------------------------
# list_loaded_modules
#
# Lists all currently loaded modules with versions
#
# Parameters:
#   None
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   Prints list of loaded modules to stdout
#
# Example:
#   list_loaded_modules
#   # Output:
#   # Loaded modules:
#   #   - core: v1.0.0
#   #   - utils: v1.0.0
#------------------------------------------------------------------------------
list_loaded_modules() {
    if [[ ${#LOADED_MODULES[@]} -eq 0 ]]; then
        echo "No modules loaded"
        return 0
    fi
    
    echo "Loaded modules:"
    for module in "${!LOADED_MODULES[@]}"; do
        local version_var="${module^^}_MODULE_VERSION"
        local version="${!version_var:-unknown}"
        echo "  - $module: v$version"
    done
}

#------------------------------------------------------------------------------
# get_module_version
#
# Gets version of a loaded module
#
# Parameters:
#   $1 - module_name: Name of module
#
# Returns:
#   0 - Module loaded, version printed to stdout
#   1 - Module not loaded
#
# Example:
#   version=$(get_module_version "core")
#   echo "Core module version: $version"
#------------------------------------------------------------------------------
get_module_version() {
    local module_name="$1"
    
    # Check if module is loaded
    if ! is_module_loaded "$module_name"; then
        return 1
    fi
    
    # Get version
    local version_var="${module_name^^}_MODULE_VERSION"
    local version="${!version_var:-unknown}"
    echo "$version"
    return 0
}

################################################################################
# PUBLIC API: MODULE DEPENDENCY INFORMATION
################################################################################

#------------------------------------------------------------------------------
# get_module_dependencies
#
# Gets list of dependencies for a module
#
# Parameters:
#   $1 - module_name: Name of module
#
# Returns:
#   0 - Dependencies printed to stdout (may be empty)
#   1 - Module not found in dependency graph
#
# Example:
#   deps=$(get_module_dependencies "backup")
#   echo "Backup module depends on: $deps"
#------------------------------------------------------------------------------
get_module_dependencies() {
    local module_name="$1"
    
    # Check if module exists
    if ! _validate_module_name "$module_name"; then
        return 1
    fi
    
    # Get dependencies (may be empty string)
    echo "${MODULE_DEPS[$module_name]}"
    return 0
}

#------------------------------------------------------------------------------
# print_dependency_graph
#
# Prints the complete module dependency graph
#
# Parameters:
#   None
#
# Returns:
#   0 - Always succeeds
#
# Output:
#   Prints dependency graph to stdout
#
# Example:
#   print_dependency_graph
#------------------------------------------------------------------------------
print_dependency_graph() {
    echo "Module Dependency Graph:"
    echo "========================"
    
    for module in "${!MODULE_DEPS[@]}"; do
        local deps="${MODULE_DEPS[$module]}"
        if [[ -z "$deps" ]]; then
            echo "  $module: (no dependencies)"
        else
            echo "  $module: $deps"
        fi
    done
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Export all public functions as read-only
readonly -f load_module load_modules validate_modules
readonly -f is_module_loaded list_loaded_modules get_module_version
readonly -f get_module_dependencies print_dependency_graph

# Log loader initialization (basic echo, since core.sh not loaded yet)
if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "[DEBUG] Module loader initialized: ${LIB_DIR}" >&2
fi

################################################################################
# LOADER SELF-TEST (Optional, enabled via LOADER_TEST flag)
################################################################################

#------------------------------------------------------------------------------
# test_loader
#
# Self-test function for the loader system
#
# Returns:
#   0 - All tests passed
#   1 - One or more tests failed
#------------------------------------------------------------------------------
test_loader() {
    local errors=0
    
    echo "Running loader self-tests..."
    
    # Test 1: Can we load core module?
    echo -n "  Test 1: Loading core module... "
    if load_module "core"; then
        echo "PASS"
    else
        echo "FAIL"
        ((errors++))
    fi
    
    # Test 2: Is core module marked as loaded?
    echo -n "  Test 2: Checking if core is loaded... "
    if is_module_loaded "core"; then
        echo "PASS"
    else
        echo "FAIL"
        ((errors++))
    fi
    
    # Test 3: Can we load utils module (has dependency on core)?
    echo -n "  Test 3: Loading utils module with dependencies... "
    if load_module "utils"; then
        echo "PASS"
    else
        echo "FAIL"
        ((errors++))
    fi
    
    # Test 4: Invalid module name handling
    echo -n "  Test 4: Rejecting invalid module name... "
    if ! load_module "nonexistent_module" 2>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
        ((errors++))
    fi
    
    # Test 5: Module validation
    echo -n "  Test 5: Validating loaded modules... "
    if validate_modules 2>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
        ((errors++))
    fi
    
    # Summary
    echo ""
    if [[ $errors -eq 0 ]]; then
        echo "All tests passed! ✓"
        return 0
    else
        echo "Tests failed: $errors errors"
        return 1
    fi
}

# Run self-test if LOADER_TEST environment variable is set
if [[ "${LOADER_TEST:-false}" == "true" ]]; then
    test_loader
    exit $?
fi

################################################################################
# END OF MODULE
################################################################################

