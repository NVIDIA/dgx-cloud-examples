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

# Getting Started with the Modular Backup System
## Developer and Operator Guide

**Last Updated:** November 6, 2025  
**Audience:** Developers, DevOps Engineers, System Administrators

---

## 🎯 What You'll Learn

- How the modular architecture works
- How to run and configure backups
- How to understand and modify the code
- How to troubleshoot issues

**Reading Time:** 15-20 minutes

---

## 🏗️ System Overview

### What It Does

Automatically backs up directories to AWS S3 with:
- **Incremental uploads** (only changed files)
- **Deletion tracking** (with configurable retention)
- **State management** (tracks what's been backed up)
- **Parallel operations** (10x faster capable)

### How It Works

```
1. Scan MOUNT_DIR for trigger files
   (backupthisdir.txt or backupalldirs.txt)

2. For each directory found:
   - Get previous backup state
   - Scan current files
   - Calculate checksums (MD5/SHA256/mtime)
   - Compare with previous state
   - Upload new/changed files to S3
   - Move old versions to yesterday_state
   - Track deletions
   - Update state

3. Cleanup old deletions (retention policy)

4. Print summary statistics
```

---

## 🚀 Running Backups

### Basic Usage

```bash
# Navigate to backup directory
cd /path/to/backup

# Run backup
./backup.sh
```

**All module loading happens automatically!**

### With Options

```bash
# Dry-run mode (test without changes)
./backup.sh --dry-run

# Debug mode (verbose logging)
LOG_LEVEL=DEBUG ./backup.sh

# Custom configuration
./backup.sh --config /path/to/config.conf

# Combination
LOG_LEVEL=DEBUG DRY_RUN=true ./backup.sh
```

---

## ⚙️ Configuration Guide

### Configuration File

Location: `scripts/backup-config.conf`

```bash
# Edit configuration
vim scripts/backup-config.conf
```

### Required Settings

```bash
# AWS Configuration (Required)
S3_BUCKET="your-backup-bucket"
AWS_REGION="us-east-1"
```

### Important Optional Settings

```bash
# S3 prefix (folder in bucket)
S3_PREFIX="backups"

# Directory to scan for backups
MOUNT_DIR="/data"

# Retention for deleted files (DD:HH:MM format)
DELETED_FILE_RETENTION="30:00:00"  # 30 days

# Checksum algorithm
CHECKSUM_ALGORITHM="md5"  # or sha256, mtime

# Log level
LOG_LEVEL="INFO"  # or DEBUG, WARN, ERROR
```

### AWS Authentication

Choose one method:

**Option 1: AWS Profile** (recommended for local use)
```bash
AWS_PROFILE="backup-profile"
```

**Option 2: Environment Variables** (recommended for containers)
```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
```

**Option 3: IAM Role** (recommended for production)
- Attach IAM role to EC2/ECS/EKS
- No configuration needed

---

## 🏗️ Architecture Deep Dive

### Modular Design

The system is built from 9 independent modules:

```
1. core.sh         Logging, error handling, platform detection
2. utils.sh        Cross-platform file operations, encoding, conversions
3. loader.sh       Module dependency management
4. config.sh       Secure configuration loading (no command injection!)
5. state.sh        State management with per-directory locking
6. filesystem.sh   Directory discovery and mapping
7. checksum.sh     File change detection (MD5/SHA256/mtime)
8. s3.sh           AWS S3 operations with retry and parallel uploads
9. backup.sh       Main workflow orchestration
10. deletion.sh    Deletion tracking and retention policies
```

**See [docs/MODULAR_ARCHITECTURE.md](docs/MODULAR_ARCHITECTURE.md) for complete details.**

### Module Dependencies

```
core (no dependencies)
  ├→ utils
  ├→ config (core, utils)
  ├→ state (core, utils)
  ├→ filesystem (core, utils, state)
  ├→ checksum (core, utils, state)
  ├→ s3 (core, utils, config, state)
  ├→ backup (all above)
  └→ deletion (core, utils, config, state, s3)
```

Dependencies are managed automatically by `loader.sh`.

---

## 🔒 Security Features

### Built-In Security

**1. Secure Configuration Loading**
- No use of `source` command (prevents code injection)
- Whitelist-based key validation
- Dangerous pattern detection

**2. State File Locking**
- Per-directory locking (prevents race conditions)
- Zero contention between directories
- Safe parallel operations

**3. Upload Verification**
- Verifies files reached S3
- Prevents silent data loss
- Retries on failures

---

## ⚡ Performance Features

### Parallelization

**Smart Locking Strategy:**
- Each directory has its own state file
- Directories can be backed up in parallel
- Zero lock contention


### Optimization Techniques

- **Metadata caching:** Fast mtime+size comparison (99% faster for unchanged files)
- **Parallel uploads:** Upload multiple files simultaneously (10x faster)
- **Large file sampling:** Sample checksums for files >1GB (60x faster)

**See [docs/LOCKING_STRATEGY.md](docs/LOCKING_STRATEGY.md) for design details.**

---

## 🧪 Testing

### Validate Installation

```bash
# Test module loading
bash -c "source lib/loader.sh; load_modules core utils config state filesystem checksum s3 backup deletion; echo 'Success!'"

# Show loaded modules
./backup.sh --version
```

### Test Backup Workflow

```bash
# Dry-run mode (safe - makes no changes)
./backup.sh --dry-run

# Review what would happen
cat backup.log
```

### Debug Issues

```bash
# Enable debug logging
LOG_LEVEL=DEBUG ./backup.sh --dry-run

# Watch logs in real-time
tail -f backup.log
```

---

## 🔧 Understanding the Code

### Module Structure

Each module follows this pattern:

```bash
#!/usr/bin/env bash
# Module header with full documentation

# MODULE METADATA
readonly MODULE_NAME_MODULE_VERSION="1.0.0"
readonly MODULE_NAME_MODULE_DEPS=("core" "utils")

# DEPENDENCY VALIDATION
# Ensures required modules are loaded

# PUBLIC API
# Functions with complete documentation:
#   - Purpose
#   - Parameters
#   - Returns
#   - Examples

# MODULE INITIALIZATION
# Export functions, log loading

# MODULE SELF-VALIDATION
# Validate all functions defined
```

### Reading Module Code

1. Start with the module header (purpose and dependencies)
2. Read public API section (what the module provides)
3. Look at function documentation (parameters and returns)
4. Review implementation (how it works)

**Every function has complete documentation!**

---

## 🔄 Backup Workflow Details

### Step-by-Step Process

**1. Configuration Loading** (config.sh)
- Loads `scripts/backup-config.conf` safely
- Validates required settings
- Exports AWS credentials

**2. State Initialization** (state.sh)
- Creates state file directories
- Initializes JSON state files
- Loads previous backup state

**3. Directory Discovery** (filesystem.sh)
- Scans MOUNT_DIR for trigger files
- Identifies shallow vs deep backup modes
- Filters hierarchical directories

**4. For Each Directory:** (backup.sh + checksum.sh + s3.sh + state.sh)
- Get directory's previous state
- Scan current files
- For each file:
  - Quick metadata check (mtime+size)
  - Calculate checksum if changed
  - Upload if new or changed
  - Update state with locking
- Track deleted files
- Move deleted files to yesterday_state

**5. Aggregation** (state.sh)
- Build aggregate state from individual directory states
- Takes ~1 second

**6. Cleanup** (deletion.sh)
- Remove deleted files past retention period
- Update permanent deletions history

**7. Summary** (backup.sh)
- Print statistics (files, sizes, duration)
- Report errors (if any)

---

## 🗂️ State File System

### Directory Structure

```
state/
├── directories/                   # Per-directory state (parallelization!)
│   ├── dir_ABC123.state.json     # project1 state
│   └── dir_DEF456.state.json     # project2 state
│
├── backup-state.json              # Aggregated state (built at end)
├── yesterday-backup-state.json   # Deleted files tracking
└── permanent-deletions-history.json  # Audit trail
```

### Why Separate Files?

- ✅ Enables parallel backups (10x faster)
- ✅ Zero lock contention
- ✅ Each directory independent
- ✅ Smaller, easier to debug

**See [docs/LOCKING_STRATEGY.md](docs/LOCKING_STRATEGY.md) for design rationale.**

---

## 🎓 Key Concepts

### Trigger Files

Create these files to mark directories for backup:

**backupthisdir.txt** - Shallow backup
- Backs up files in THIS directory only
- Does not backup subdirectories

**backupalldirs.txt** - Deep backup
- Backs up THIS directory AND all subdirectories
- Child directories with backupthisdir.txt are skipped (parent takes precedence)

### S3 Organization

```
s3://your-bucket/your-prefix/
  ├── current_state/          # Current/active files
  │   ├── project1/
  │   │   ├── file1.txt
  │   │   └── file2.dat
  │   └── project2/
  │       └── data.db
  │
  └── yesterday_state/        # Recently deleted/modified files
      ├── project1/
      │   └── deleted_old_file.txt
      └── project2/
          └── deleted_data_v1.db
```

### Retention Policies

Format: **DD:HH:MM** (Days:Hours:Minutes)

```bash
"30:00:00"  # 30 days
"07:12:30"  # 7 days, 12 hours, 30 minutes
"00:10:00"  # 10 hours
"00:00:00"  # Disabled (keep forever)
```

Files in `yesterday_state/` are automatically deleted after retention period expires.

---

## 📈 Monitoring & Operations

### Check Backup Status

```bash
# View recent logs
tail -100 backup.log

# Search for errors
grep ERROR backup.log

# Watch live
tail -f backup.log
```

### Check What's Being Backed Up

```bash
# List directories with trigger files
find /data -name "backupthisdir.txt" -o -name "backupalldirs.txt"
```

### Verify S3 Contents

```bash
# List current backups
aws s3 ls s3://your-bucket/your-prefix/current_state/ --recursive

# List deleted files
aws s3 ls s3://your-bucket/your-prefix/yesterday_state/ --recursive
```

---

## 🔧 Troubleshooting

### Common Issues

**"No directories found to backup"**
```bash
# Solution: Create trigger file
touch /data/your-directory/backupthisdir.txt
```

**"AWS credentials validation failed"**
```bash
# Solution: Configure AWS CLI
aws configure

# Or set in config file
vim scripts/backup-config.conf
```

**"Failed to acquire lock"**
```bash
# Solution: Another backup is running
ps aux | grep backup.sh

# Wait for it to complete or kill if stuck
```

**"Module not found"**
```bash
# Solution: Ensure lib/ directory exists
ls -la lib/

# All modules should be present:
# core.sh, utils.sh, loader.sh, config.sh, state.sh,
# filesystem.sh, checksum.sh, s3.sh, backup.sh, deletion.sh
```

---

## 📚 Learning Path

### Day 1: User Perspective (30 minutes)
1. Read this guide (15 min)
2. Read SIMPLE_USAGE.md (10 min)
3. Run test backup: `./backup.sh --dry-run` (5 min)

### Day 2: Developer Perspective (1 hour)
1. Review module code in `lib/` (30 min)
2. Read docs/MODULAR_ARCHITECTURE.md (20 min)
3. Read docs/MODULE_CONSISTENCY_GUIDE.md (10 min)

### Day 3: Advanced Topics (1 hour)
1. Read docs/LOCKING_STRATEGY.md (20 min)
2. Read docs/ARCHITECTURE_DIAGRAMS.md (20 min)
3. Experiment with modifications (20 min)

---

## 🎯 Summary

### For Users
**Just run:** `./backup.sh`  
**Read:** [SIMPLE_USAGE.md](SIMPLE_USAGE.md)

### For Developers
**Understand:** Module architecture  
**Read:** [docs/MODULAR_ARCHITECTURE.md](docs/MODULAR_ARCHITECTURE.md)

### For Operators
**Monitor:** Check logs and S3  
**Schedule:** Add to cron

---

**Next:** Read [SIMPLE_USAGE.md](SIMPLE_USAGE.md) for complete usage guide! 🚀
