<!--
SPDX-FileCopyrightText: Copyright (c) 2024-2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Module Consistency Guide
## Maintaining Interface Contracts Between Scripts

**Purpose:** This guide ensures that when Script A calls Script B, changes to either script don't break the interface.

---

## The Problem: Breaking Changes

### Example of Breaking Change

```bash
# Script A (backup.sh) calls checksum function
# Version 1.0.0
result=$(calculate_checksum "$file" "md5")

# Someone updates checksum.sh to Version 2.0.0
# New signature: calculate_checksum FILE ALGORITHM OPTIONS
calculate_checksum "$file" "md5" "--fast"  # Added 3rd parameter

# Script A breaks! ❌
# It still calls: calculate_checksum "$file" "md5"
```

### Our Solution: Interface Contracts

We use **four mechanisms** to prevent breaking changes:

1. **Explicit interface definitions**
2. **Semantic versioning**
3. **Automated validation**
4. **Backward compatibility patterns**

---

## Mechanism 1: Interface Definitions

### Every Module Documents Its Public API

Each module has a header documenting every public function:

```bash
#!/bin/bash
# lib/checksum.sh - Checksum calculation module
# Version: 1.0.0

################################################################################
# PUBLIC API v1.0
# These functions are the contract with other modules
# NEVER change signatures without incrementing MAJOR version
################################################################################

#------------------------------------------------------------------------------
# calculate_checksum
# Version: 1.0 (introduced in module v1.0.0)
#
# Calculates checksum for a file
#
# SIGNATURE:
#   calculate_checksum FILE ALGORITHM
#
# PARAMETERS:
#   $1 - FILE (string, required): Path to file
#   $2 - ALGORITHM (string, optional): md5|sha256|mtime (default: md5)
#
# RETURNS:
#   0: Success, checksum printed to stdout
#   1: File not found
#   2: Invalid algorithm
#
# STDOUT:
#   Checksum string (no newline)
#
# EXAMPLE:
#   checksum=$(calculate_checksum "/path/file" "md5")
#   if [[ $? -eq 0 ]]; then
#       echo "Checksum: $checksum"
#   fi
#------------------------------------------------------------------------------
calculate_checksum() {
    local file="$1"
    local algorithm="${2:-md5}"
    
    # Implementation...
}
```

### Template for Function Documentation

Copy this template for every public function:

```bash
#------------------------------------------------------------------------------
# FUNCTION_NAME
# Version: X.Y (introduced in module vX.Y.Z)
#
# Brief description of what function does
#
# SIGNATURE:
#   function_name PARAM1 [PARAM2] [PARAM3...]
#
# PARAMETERS:
#   $1 - PARAM1 (type, required/optional): Description
#   $2 - PARAM2 (type, required/optional): Description
#   ... (ALL parameters documented)
#
# RETURNS:
#   0: Success condition
#   1: Error condition 1
#   2: Error condition 2
#   ... (ALL exit codes documented)
#
# STDOUT/STDERR:
#   What gets printed where
#
# SIDE EFFECTS:
#   - Sets global variables
#   - Modifies files
#   - Creates temp files
#   ... (ALL side effects documented)
#
# EXAMPLE:
#   result=$(function_name "arg1" "arg2")
#   [[ $? -eq 0 ]] && echo "Success: $result"
#------------------------------------------------------------------------------
```

---

## Mechanism 2: Semantic Versioning

### Version Format: MAJOR.MINOR.PATCH

```bash
# Module version
readonly CHECKSUM_MODULE_VERSION="1.2.3"
                                  │ │ │
                                  │ │ └─ PATCH: Bug fixes only
                                  │ └─── MINOR: New features (backward compatible)
                                  └───── MAJOR: Breaking changes
```

### When to Increment Each Number

#### PATCH Version (1.0.0 → 1.0.1)
**When:** Bug fixes that don't change behavior

```bash
# Example: Fix bug in checksum calculation
# Before (bug):
calculate_checksum() {
    md5sum "$1" | cut -d' ' -f1  # ❌ Fails on BSD
}

# After (fixed):
calculate_checksum() {
    md5sum "$1" 2>/dev/null | cut -d' ' -f1 || return 1  # ✅ Works everywhere
}

# Signature unchanged, behavior improved → PATCH
```

#### MINOR Version (1.0.0 → 1.1.0)
**When:** Add new features without breaking existing code

```bash
# Example: Add new function
# Version 1.0.0 had:
#   - calculate_checksum(file, algorithm)

# Version 1.1.0 adds:
#   - calculate_checksum_parallel(files[], algorithm)  # NEW!

# Existing code still works → MINOR
```

#### MAJOR Version (1.0.0 → 2.0.0)
**When:** Break backward compatibility

```bash
# Example: Change function signature
# Version 1.0.0:
calculate_checksum(file, algorithm)

# Version 2.0.0:
calculate_checksum(file, algorithm, options)  # ⚠️ Added parameter

# Existing callers break → MAJOR
```

### Version Compatibility Rules

```bash
# Rule: Same MAJOR version = compatible
checksum v1.0.0 + backup v1.5.0 = ✅ Compatible
checksum v1.9.0 + backup v1.0.0 = ✅ Compatible

# Rule: Different MAJOR version = incompatible
checksum v1.0.0 + backup v2.0.0 = ❌ Incompatible
checksum v2.0.0 + backup v1.0.0 = ❌ Incompatible
```

---

## Mechanism 3: Automated Validation

### A. Module Self-Validation

Every module validates itself on load:

```bash
# lib/checksum.sh

# Self-validation function
validate_module_checksum() {
    local errors=0
    
    # Check all public functions exist
    local public_functions=(
        "calculate_checksum"
        "calculate_checksum_parallel"
        "quick_metadata_check"
    )
    
    for func in "${public_functions[@]}"; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module checksum: Missing public function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for dep in "log" "get_file_size"; do
        if ! declare -F "$dep" >/dev/null 2>&1; then
            log ERROR "Module checksum: Missing dependency function $dep"
            ((errors++))
        fi
    done
    
    # Check module metadata is defined
    if [[ -z "${CHECKSUM_MODULE_VERSION:-}" ]]; then
        log ERROR "Module checksum: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

# Run validation if enabled
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_checksum || exit 1
fi
```

### B. Cross-Module Validation

Create a script that validates all modules work together:

```bash
#!/bin/bash
# scripts/validate-modules.sh - Validate all module interfaces

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/loader.sh"

# Enable validation mode
export MODULE_VALIDATE=true

# Load all modules
echo "Loading all modules..."
load_modules core utils config state filesystem checksum s3 backup deletion alignment

# Validate each module
echo ""
echo "Validating modules..."
errors=0

for module in core utils config state filesystem checksum s3 backup deletion alignment; do
    echo -n "Validating $module... "
    
    # Check version is defined
    version_var="${module^^}_MODULE_VERSION"
    if [[ -z "${!version_var:-}" ]]; then
        echo "❌ FAIL (no version)"
        ((errors++))
        continue
    fi
    
    # Run module validation if available
    validate_func="validate_module_${module}"
    if declare -F "$validate_func" >/dev/null 2>&1; then
        if "$validate_func"; then
            echo "✅ PASS"
        else
            echo "❌ FAIL"
            ((errors++))
        fi
    else
        echo "⚠️  SKIP (no validation function)"
    fi
done

echo ""
if [[ $errors -eq 0 ]]; then
    echo "✅ All modules validated successfully"
    exit 0
else
    echo "❌ Validation failed with $errors errors"
    exit 1
fi
```

### C. Pre-Commit Validation Hook

Automatically validate before commits:

```bash
#!/bin/bash
# .git/hooks/pre-commit

set -e

echo "Running module validation..."

# Validate modules
./scripts/validate-modules.sh || {
    echo ""
    echo "❌ Module validation failed!"
    echo "Fix errors before committing."
    exit 1
}

echo "✅ Validation passed"
```

---

## Mechanism 4: Backward Compatibility Patterns

### Pattern 1: Optional Parameters with Defaults

Make new parameters optional:

```bash
# ✅ GOOD: Backward compatible upgrade
# Version 1.0.0:
calculate_checksum() {
    local file="$1"
    local algorithm="${2:-md5}"  # Default if not provided
}

# Version 1.1.0: Add options parameter
calculate_checksum() {
    local file="$1"
    local algorithm="${2:-md5}"
    local options="${3:-}"  # NEW but optional with default
}

# Old code still works!
# Old: calculate_checksum "$file" "md5"
# New: calculate_checksum "$file" "md5" "--fast"
```

### Pattern 2: Feature Detection

Check if new features are available:

```bash
# Script A wants to use new feature if available
if declare -F "calculate_checksum_parallel" >/dev/null 2>&1; then
    # New feature available
    result=$(calculate_checksum_parallel "${files[@]}" "md5")
else
    # Fallback to old method
    for file in "${files[@]}"; do
        result=$(calculate_checksum "$file" "md5")
    done
fi
```

### Pattern 3: Version Checking

Require specific version:

```bash
# Script A requires checksum module v1.2+
require_module_version() {
    local module="$1"
    local required_version="$2"
    
    local version_var="${module^^}_MODULE_VERSION"
    local actual_version="${!version_var:-0.0.0}"
    
    # Compare versions (simple: just check major.minor)
    local actual_major="${actual_version%%.*}"
    local actual_minor="${actual_version#*.}"
    actual_minor="${actual_minor%%.*}"
    
    local required_major="${required_version%%.*}"
    local required_minor="${required_version#*.}"
    required_minor="${required_minor%%.*}"
    
    if [[ $actual_major -lt $required_major ]] || \
       [[ $actual_major -eq $required_major && $actual_minor -lt $required_minor ]]; then
        log ERROR "Module $module v$actual_version is too old (requires v$required_version)"
        return 1
    fi
    
    log DEBUG "Module $module v$actual_version meets requirement (v$required_version)"
    return 0
}

# Usage in backup.sh
require_module_version "checksum" "1.2" || die "Incompatible checksum module"
```

### Pattern 4: Deprecation Warnings

Warn about old interfaces:

```bash
# Version 2.0.0: Deprecated old signature
calculate_checksum_old() {
    log WARN "calculate_checksum_old is deprecated, use calculate_checksum instead"
    log WARN "This function will be removed in v3.0.0"
    
    # Forward to new function
    calculate_checksum "$@"
}

# Alias for backward compatibility
alias old_checksum_function=calculate_checksum_old
```

---

## Change Management Workflow

### Workflow: Adding a New Function (Safe)

```bash
# 1. Add function to module
# lib/checksum.sh v1.0.0 → v1.1.0

calculate_checksum_parallel() {
    # New function
}

# 2. Update version (MINOR++)
readonly CHECKSUM_MODULE_VERSION="1.1.0"  # Was 1.0.0

# 3. Document in interface
#------------------------------------------------------------------------------
# calculate_checksum_parallel (NEW in v1.1.0)
# ...
#------------------------------------------------------------------------------

# 4. Add to validation
validate_module_checksum() {
    local public_functions=(
        "calculate_checksum"
        "calculate_checksum_parallel"  # NEW
    )
    # ...
}

# 5. Test
./scripts/validate-modules.sh

# 6. Commit
git add lib/checksum.sh
git commit -m "feat(checksum): add parallel checksum calculation

- Added calculate_checksum_parallel() function
- Bumped version to 1.1.0
- Backward compatible change"
```

### Workflow: Changing Function Signature (Breaking)

```bash
# ⚠️ This is a BREAKING change! Follow carefully:

# 1. Plan migration
# OLD: calculate_checksum(file, algorithm)
# NEW: calculate_checksum(file, algorithm, options)

# 2. Create migration plan document
cat > docs/MIGRATION_v1_to_v2.md << 'EOF'
# Migration Guide: checksum v1.x → v2.0

## Breaking Changes

### calculate_checksum signature change

**Old (v1.x):**
```bash
calculate_checksum FILE ALGORITHM
```

**New (v2.0):**
```bash
calculate_checksum FILE ALGORITHM [OPTIONS]
```

**Migration:**
Add empty string as third parameter if using positional args:
```bash
# Before
result=$(calculate_checksum "$file" "md5")

# After
result=$(calculate_checksum "$file" "md5" "")
```

Or use named parameters pattern (recommended).
EOF

# 3. Implement with backward compatibility period
# Version 2.0.0 (keeps old signature working)
calculate_checksum() {
    local file="$1"
    local algorithm="$2"
    local options="${3:-}"  # NEW parameter, optional
    
    # Implementation with options support
}

# Keep old wrapper for 1 version
calculate_checksum_legacy() {
    log WARN "Legacy checksum interface used. Update to v2.0 signature."
    log WARN "See docs/MIGRATION_v1_to_v2.md"
    calculate_checksum "$1" "$2" ""
}

# 4. Update version (MAJOR++)
readonly CHECKSUM_MODULE_VERSION="2.0.0"  # Was 1.x.x

# 5. Update all callers
# Find all usages:
grep -r "calculate_checksum" scripts/

# Update each one:
# Before: calculate_checksum "$file" "md5"
# After:  calculate_checksum "$file" "md5" ""

# 6. Test everything
./scripts/validate-modules.sh
./scripts/run-tests.sh

# 7. Commit with detailed message
git add lib/checksum.sh docs/MIGRATION_v1_to_v2.md
git commit -m "feat(checksum)!: add options parameter to calculate_checksum

BREAKING CHANGE: calculate_checksum signature changed

- Added OPTIONS parameter (optional, defaults to empty)
- Kept backward compatibility wrapper for 1 release
- Updated all internal callers
- See docs/MIGRATION_v1_to_v2.md for migration guide

Closes #123"
```

---

## Quick Reference Checklist

### ✅ Before Making Any Change

- [ ] Is this change backward compatible?
- [ ] If NO: Is this change worth breaking compatibility?
- [ ] Have I documented the change?
- [ ] Have I updated the version number correctly?
- [ ] Have I updated all callers?
- [ ] Have I tested the change?
- [ ] Have I created migration guide (if breaking)?

### ✅ When Adding New Function

- [ ] Document function with full signature
- [ ] Add to module's public function list
- [ ] Add to validation function
- [ ] Write unit test
- [ ] Increment MINOR version
- [ ] Commit with "feat(module): description"

### ✅ When Changing Function Signature

- [ ] Create migration plan document
- [ ] Update MAJOR version
- [ ] Add deprecation warnings
- [ ] Update all callers
- [ ] Test extensively
- [ ] Commit with "feat(module)!: description" (note the !)

### ✅ When Fixing Bug

- [ ] Fix bug without changing signature
- [ ] Add regression test
- [ ] Increment PATCH version
- [ ] Commit with "fix(module): description"

---

## Validation Scripts

### Run These Before Every Commit

```bash
# 1. Validate module interfaces
./scripts/validate-modules.sh

# 2. Run unit tests
./scripts/run-unit-tests.sh

# 3. Run integration tests
./scripts/run-integration-tests.sh

# 4. Check for breaking changes
./scripts/check-api-compatibility.sh
```

### Example: check-api-compatibility.sh

```bash
#!/bin/bash
# scripts/check-api-compatibility.sh

# Compare current API with last release

readonly CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
readonly LAST_RELEASE=$(git describe --tags --abbrev=0 2>/dev/null || echo "main")

echo "Checking API compatibility: $LAST_RELEASE → $CURRENT_BRANCH"
echo ""

# Extract function signatures from modules
extract_signatures() {
    local ref="$1"
    git show "$ref:lib/checksum.sh" 2>/dev/null | \
        grep -A 5 "^[[:alnum:]_]*() {" | \
        grep -v "^_" | \
        sed 's/() {.*/()/'
}

# Compare
OLD_API=$(extract_signatures "$LAST_RELEASE")
NEW_API=$(extract_signatures "$CURRENT_BRANCH")

# Check for removed functions
while IFS= read -r func; do
    if ! echo "$NEW_API" | grep -q "^${func}$"; then
        echo "⚠️  WARNING: Function removed: $func"
        echo "   This is a BREAKING CHANGE!"
        echo ""
    fi
done <<< "$OLD_API"

# Check for changed signatures (would need more sophisticated diff)
echo "✅ API compatibility check complete"
```

---

## Example: Complete Module with All Mechanisms

The following example demonstrates all consistency mechanisms:

```bash
#!/bin/bash
# lib/example.sh - Example module with all consistency mechanisms
# Version: 1.2.3

################################################################################
# MODULE METADATA
################################################################################

readonly EXAMPLE_MODULE_VERSION="1.2.3"
readonly EXAMPLE_MODULE_NAME="example"
readonly EXAMPLE_MODULE_DEPS=("core" "utils")

# API version (increment MAJOR when breaking changes)
readonly EXAMPLE_API_VERSION="1.0"

################################################################################
# PUBLIC API v1.0
################################################################################

#------------------------------------------------------------------------------
# example_function
# Version: 1.0 (introduced in v1.0.0)
#
# Example function demonstrating best practices
#
# SIGNATURE:
#   example_function FILE [OPTIONS]
#
# PARAMETERS:
#   $1 - FILE (string, required): Path to file
#   $2 - OPTIONS (string, optional): Additional options
#
# RETURNS:
#   0: Success
#   1: File not found
#
# STDOUT:
#   Result string
#
# EXAMPLE:
#   result=$(example_function "/path/file" "--fast")
#   [[ $? -eq 0 ]] && echo "$result"
#------------------------------------------------------------------------------
example_function() {
    local file="$1"
    local options="${2:-}"
    
    # Validate required parameters
    if [[ -z "$file" ]]; then
        log ERROR "example_function: FILE parameter required"
        return 1
    fi
    
    # Check file exists
    if [[ ! -f "$file" ]]; then
        log ERROR "example_function: File not found: $file"
        return 1
    fi
    
    # Implementation
    echo "Processing $file with options: $options"
    return 0
}

################################################################################
# MODULE VALIDATION
################################################################################

validate_module_example() {
    local errors=0
    
    # Check public functions exist
    for func in example_function; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module example: Missing function $func"
            ((errors++))
        fi
    done
    
    # Check dependencies are loaded
    for func in log; do
        if ! declare -F "$func" >/dev/null 2>&1; then
            log ERROR "Module example: Missing dependency $func"
            ((errors++))
        fi
    done
    
    # Check metadata
    if [[ -z "${EXAMPLE_MODULE_VERSION:-}" ]]; then
        log ERROR "Module example: VERSION not defined"
        ((errors++))
    fi
    
    return $errors
}

################################################################################
# MODULE INITIALIZATION
################################################################################

# Validate dependencies
for dep in "${EXAMPLE_MODULE_DEPS[@]}"; do
    if ! declare -F "log" >/dev/null 2>&1; then
        echo "ERROR: example.sh requires ${dep}.sh" >&2
        exit 1
    fi
done

# Run validation if enabled
if [[ "${MODULE_VALIDATE:-false}" == "true" ]]; then
    validate_module_example || exit 1
fi

log DEBUG "Module loaded: example v${EXAMPLE_MODULE_VERSION} (API v${EXAMPLE_API_VERSION})"
```

---

## Summary

### Four Keys to Consistency

1. **Document Everything** - Full function signatures in header comments
2. **Version Properly** - Semantic versioning (MAJOR.MINOR.PATCH)
3. **Validate Automatically** - Self-validation + cross-module validation
4. **Maintain Compatibility** - Optional parameters, feature detection, deprecation

### When Script A Calls Script B

**Before changes:**
- Script A knows: "I call function X with 2 parameters"
- Script B provides: "I have function X with 2 parameters"
- ✅ Works!

**After safe change (new optional parameter):**
- Script A: "I call function X with 2 parameters"
- Script B: "I have function X with 2-3 parameters (3rd optional)"
- ✅ Still works! (Backward compatible)

**After breaking change (wrong way):**
- Script A: "I call function X with 2 parameters"
- Script B: "I have function X with 3 REQUIRED parameters"
- ❌ Breaks! (Not backward compatible)

**After breaking change (right way):**
- Increment MAJOR version (1.x → 2.0)
- Update Script A to use new signature
- Keep compatibility wrapper for 1 version
- Document migration path
- ✅ Controlled upgrade

### Your Workflow

1. **Planning:** Check if change is breaking
2. **Implementation:** Update code + version + docs
3. **Validation:** Run validation scripts
4. **Testing:** Unit + integration tests
5. **Commit:** Use conventional commits format
6. **Deploy:** Follow migration guide if breaking

This ensures **Script A** and **Script B** always stay in sync! 🎯

