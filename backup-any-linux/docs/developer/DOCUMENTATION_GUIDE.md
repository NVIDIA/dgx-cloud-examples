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

# Documentation Organization Guide
## Up-to-Date, Relevant Documentation Structure

**Last Updated:** November 6, 2025  
**Status:** ✅ Documentation Reorganized and Current

---

## 📁 Current Documentation Structure

### **Root Level** (User-Facing, Operational)

| Document | Purpose | Audience | Read Time |
|----------|---------|----------|-----------|
| **START_HERE.md** | First stop for new users | Everyone | 2 min |
| **README.md** | Project overview | Everyone | 5 min |
| **SIMPLE_USAGE.md** | How to use the backup system | Users, Operators | 10 min |
| **GETTING_STARTED.md** | Developer and operator guide | Developers, DevOps | 15 min |
| **QUICK_REFERENCE.md** | Command reference card | Everyone | 2 min |

**Purpose:** Quick access to operational information  
**Status:** ✅ All current and updated

---

### **docs/** (Technical, Architectural)

| Document | Purpose | Audience | Read Time |
|----------|---------|----------|-----------|
| **README.md** | Documentation index | Everyone | 2 min |
| **MODULAR_ARCHITECTURE.md** | Complete architecture reference | Developers, Architects | 30 min |
| **ARCHITECTURE_DIAGRAMS.md** | Visual system diagrams | Everyone | 15 min |
| **MODULE_CONSISTENCY_GUIDE.md** | How to maintain interfaces | Developers | 20 min |
| **LOGIC_FLOW_DIAGRAMS.md** | Detailed execution flows | Developers | 30 min |
| **VARIABLE_FUNCTION_REFERENCE.md** | Complete variable and function index | Developers | 20 min |

**Purpose:** Technical reference for developers and maintainers  
**Status:** ✅ All current and relevant

---


## 🎯 Documentation Philosophy

### What Stays in Active Documentation

**✅ Keep:** Operational guides (how to use the system)  
**✅ Keep:** Architecture references (how it works)  
**✅ Keep:** Development guidelines (how to maintain/extend)  
**✅ Keep:** Design decisions (why it was built this way)


---

## 📖 Reading Guide by Role

### I'm a New User

**Start:** [START_HERE.md](START_HERE.md) (2 min)  
**Then:** [SIMPLE_USAGE.md](SIMPLE_USAGE.md) (10 min)  
**Reference:** [QUICK_REFERENCE.md](QUICK_REFERENCE.md)

**You're ready to run backups!**

### I'm a Developer

**Start:** [GETTING_STARTED.md](GETTING_STARTED.md) (15 min)  
**Then:** [docs/MODULAR_ARCHITECTURE.md](docs/MODULAR_ARCHITECTURE.md) (30 min)  
**Reference:** [docs/MODULE_CONSISTENCY_GUIDE.md](docs/MODULE_CONSISTENCY_GUIDE.md)

**You understand the architecture!**

### I'm a DevOps Engineer

**Start:** [SIMPLE_USAGE.md](SIMPLE_USAGE.md) (10 min)  
**Then:** [GETTING_STARTED.md](GETTING_STARTED.md) (15 min)  
**Reference:** [docs/LOGIC_FLOW_DIAGRAMS.md](docs/LOGIC_FLOW_DIAGRAMS.md)

**You can deploy and maintain!**

### I'm a Security Auditor

**Start:** Review `lib/config.sh` source code (15 min)  
**Then:** [docs/MODULAR_ARCHITECTURE.md](docs/MODULAR_ARCHITECTURE.md) (30 min)  
**Reference:** [docs/MODULE_CONSISTENCY_GUIDE.md](docs/MODULE_CONSISTENCY_GUIDE.md)

**You understand the security posture!**

---

## 🗺️ Document Map

### User Journey

```
START_HERE.md
    │
    ├─→ Want to run backups?
    │   └─→ SIMPLE_USAGE.md
    │       └─→ QUICK_REFERENCE.md
    │
    └─→ Want to understand code?
        └─→ GETTING_STARTED.md
            └─→ docs/MODULAR_ARCHITECTURE.md
                ├─→ docs/ARCHITECTURE_DIAGRAMS.md
                ├─→ docs/MODULE_CONSISTENCY_GUIDE.md
                └─→ docs/LOCKING_STRATEGY.md
```

### By Topic

**Usage:**
- START_HERE.md → SIMPLE_USAGE.md → QUICK_REFERENCE.md

**Architecture:**
- GETTING_STARTED.md → docs/MODULAR_ARCHITECTURE.md → docs/ARCHITECTURE_DIAGRAMS.md

**Development:**
- docs/MODULAR_ARCHITECTURE.md → docs/MODULE_CONSISTENCY_GUIDE.md

**Performance:**
- docs/LOGIC_FLOW_DIAGRAMS.md → docs/ARCHITECTURE_DIAGRAMS.md

**Security:**
- lib/config.sh (source code) → docs/MODULAR_ARCHITECTURE.md

---

## 📊 Documentation Stats

### Current (Operational)

**Root Level:** 5 documents (user-facing)  
**docs/:** 6 documents (technical)  
**Total Active:** 11 documents

### In Code (API Documentation)

**lib/*.sh:** 9 modules  
**Documentation:** 100% of functions documented inline  
**Format:** Comprehensive header comments for every function

---

## 🔄 Keeping Documentation Current

### When to Update Documentation

**README.md** - When adding major features  
**SIMPLE_USAGE.md** - When adding new commands/options  
**docs/MODULAR_ARCHITECTURE.md** - When adding/removing modules  
**docs/MODULE_CONSISTENCY_GUIDE.md** - When changing interface standards  

### Documentation Maintenance

- ✅ Review quarterly for accuracy
- ✅ Update when making significant changes
- ✅ Keep examples current with actual code
- ✅ Archive obsolete documents (don't delete)

---

## 🎯 Quick Reference

### Need to...

**Run a backup?**  
→ Read: [SIMPLE_USAGE.md](SIMPLE_USAGE.md)

**Understand architecture?**  
→ Read: [docs/MODULAR_ARCHITECTURE.md](docs/MODULAR_ARCHITECTURE.md)

**Make code changes?**  
→ Read: [docs/MODULE_CONSISTENCY_GUIDE.md](docs/MODULE_CONSISTENCY_GUIDE.md)

**See diagrams?**  
→ Read: [docs/ARCHITECTURE_DIAGRAMS.md](docs/ARCHITECTURE_DIAGRAMS.md)

**Understand execution flows?**  
→ Read: [docs/LOGIC_FLOW_DIAGRAMS.md](docs/LOGIC_FLOW_DIAGRAMS.md)

**Review code structure?**  
→ Read: [docs/VARIABLE_FUNCTION_REFERENCE.md](docs/VARIABLE_FUNCTION_REFERENCE.md)

---

## ✅ Documentation Organization Complete

**Active Documentation:**
- 3 user guides (userguide/)
- 6 technical docs (developer/)
- All current and relevant ✅

**Organization:** Clear, logical, up-to-date ✅

---

**Start reading:** [START_HERE.md](../userguide/START_HERE.md) 🚀

