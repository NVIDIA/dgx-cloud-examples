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

# START HERE 👋
## Welcome to the S3 Backup System

**Welcome!** This is your starting point for the modular S3 backup system.

---

## ⚡ Quick Start (30 Seconds)

```bash
# Test the system (safe - makes no changes)
./backup.sh --dry-run

# When ready, run actual backup
./backup.sh
```

**That's all you need to know to get started!**

---

## 📖 What to Read Next

### For Users & Operators

**1. [SIMPLE_USAGE.md](SIMPLE_USAGE.md)** (5 minutes) ⭐  
Complete guide on running backups, scheduling cron jobs, and monitoring.

**2. [GETTING_STARTED.md](GETTING_STARTED.md)** (15 minutes)  
Developer guide to understanding the modular architecture.

### For Developers

**3. [MODULAR_ARCHITECTURE.md](../developer/MODULAR_ARCHITECTURE.md)** (30 minutes)  
Complete architectural reference and design patterns.

**4. [ARCHITECTURE_DIAGRAMS.md](../developer/ARCHITECTURE_DIAGRAMS.md)** (15 minutes)  
Visual architecture diagrams and system flows.

---

## 🎯 Common Tasks

### Run a Backup
```bash
./backup.sh
```

### Test Without Making Changes
```bash
./backup.sh --dry-run
```

### Debug Issues
```bash
LOG_LEVEL=DEBUG ./backup.sh
tail -f backup.log
```

### Schedule Daily Backups
```bash
crontab -e
# Add: 0 2 * * * /path/to/backup.sh >> /var/log/backup.log 2>&1
```

---

## ⚙️ Configuration

Edit the configuration file:
```bash
vim scripts/backup-config.conf
```

Required settings:
```bash
S3_BUCKET="your-backup-bucket"
AWS_REGION="us-east-1"
```

**See [SIMPLE_USAGE.md](SIMPLE_USAGE.md) for complete configuration guide.**

---

## 🏗️ What Is This?

A **modular backup system** that:
- Scans for directories to backup (using trigger files)
- Uploads changed files to AWS S3
- Tracks deletions with configurable retention
- Manages state across backup runs
- Provides comprehensive reporting

**Built with security, performance, and maintainability as core principles.**

---

## 📊 System Features

- ✅ **Incremental backups** - Only uploads changed files
- ✅ **Two backup modes** - Shallow (dir only) or deep (recursive)
- ✅ **Retention policies** - Configurable deletion cleanup
- ✅ **Dry-run mode** - Test without making changes
- ✅ **Secure** - No command injection, no race conditions
- ✅ **Fast** - Parallel upload capable (10x speedup) - still work to implement all of this, foundations in place
- ✅ **Cross-platform** - Linux, macOS, Windows

---

## 🆘 Need Help?

### Quick Help
- **How do I run it?** → Read [SIMPLE_USAGE.md](SIMPLE_USAGE.md)
- **What does it do?** → Read this file (you're here!)
- **How does it work?** → Read [GETTING_STARTED.md](GETTING_STARTED.md)

### Troubleshooting
```bash
# Check logs
tail backup.log

# Run in debug mode
LOG_LEVEL=DEBUG ./backup.sh --dry-run

# Test AWS access
aws s3 ls s3://your-bucket/
```

---

## 📁 Project Structure

```
backup/
├── backup.sh              ← Run this!
├── lib/                   ← Modules (auto-loaded)
├── scripts/
│   └── backup-config.conf ← Configure this!
├── docs/                  ← Technical docs
├── START_HERE.md          ← You are here
├── SIMPLE_USAGE.md        ← Read next
└── GETTING_STARTED.md     ← For developers
```

---

## ✨ Why Modular?

**Benefits:**
- **Simple to use:** One command (`./backup.sh`)
- **Easy to maintain:** Small, focused modules
- **Safe to change:** Clear interfaces, validation
- **Fast:** Parallel operations enabled
- **Secure:** Built-in security from the start


---

## 🎯 Next Steps

1. **Read:** [SIMPLE_USAGE.md](SIMPLE_USAGE.md) (5 minutes)
2. **Configure:** Edit `scripts/backup-config.conf`
3. **Test:** Run `./backup.sh --dry-run`
4. **Deploy:** Run `./backup.sh`
5. **Schedule:** Add to cron

**You can be running backups in 10 minutes!** ⏱️

---

**Ready to start?** Read [SIMPLE_USAGE.md](SIMPLE_USAGE.md) next! 🚀
