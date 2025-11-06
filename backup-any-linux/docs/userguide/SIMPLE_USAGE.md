# Simple Usage Guide
## Running the Backup System - No Module Loading Required!

**TL;DR:** Just run `./backup.sh` - that's it! All the complexity is handled for you.

---

## ✨ The Magic: It Just Works™

### You DON'T Need To:
- ❌ Source loader.sh manually
- ❌ Call load_modules
- ❌ Set up `set -euo pipefail`
- ❌ Worry about module dependencies
- ❌ Know which modules to load

### You JUST:
- ✅ Run: `./backup.sh`

**All module loading happens automatically!** 🎉

---

## 🚀 Usage Examples

### 1. Basic Run
```bash
# That's it! Just run the script
./backup.sh
```

**What happens internally (automatic):**
```bash
# 1. Set strict mode (set -euo pipefail)
# 2. Source lib/loader.sh
# 3. Load modules: core, utils, config
# 4. Load your configuration
# 5. Run backup workflow
# All handled for you! ✅
```

### 2. Dry Run (See What Would Happen)
```bash
# Command line option
./backup.sh --dry-run

# OR environment variable
DRY_RUN=true ./backup.sh
```

### 3. Debug Mode (Verbose Logging)
```bash
LOG_LEVEL=DEBUG ./backup.sh
```

### 4. Custom Configuration
```bash
# Command line option
./backup.sh --config /path/to/my-config.conf

# OR environment variable
CONFIG_FILE=/path/to/my-config.conf ./backup.sh
```

### 5. Forced Alignment Mode
```bash
# Command line option
./backup.sh --force-alignment

# OR environment variable
FORCE_ALIGNMENT_MODE=true ./backup.sh
```

**About Forced Alignment:**
Forced alignment reconciles S3 state with the current filesystem. By design, alignment does not run automatically to prevent accidental data loss. For example, if a `backupalldirs.txt` trigger file is accidentally deleted, the system will not remove those files from S3 during regular backup cycles. The files remain in S3 until forced alignment is explicitly run. This conservative approach prevents accidental deletion of terabytes of data due to temporary trigger file issues. All files removed during forced alignment are subject to the retention period specified in `backup-config.conf`.

### 6. Combination
```bash
# Multiple options together
LOG_LEVEL=DEBUG DRY_RUN=true ./backup.sh --config /path/to/config.conf
```

---

## 📅 Cron Job Setup

### Simple Daily Backup

```bash
# Edit crontab
crontab -e

# Add this line (run daily at 2 AM):
0 2 * * * /absolute/path/to/backup.sh >> /var/log/backup-cron.log 2>&1
```

**That's literally it!** No wrapper scripts, no complex setup.

### With Environment Variables

```bash
# Run with debug logging
0 2 * * * LOG_LEVEL=DEBUG /path/to/backup.sh >> /var/log/backup.log 2>&1

# Run in dry-run mode (testing)
0 2 * * * DRY_RUN=true /path/to/backup.sh >> /var/log/backup-test.log 2>&1
```

### Multiple Environments

```bash
# Production backup at 2 AM
0 2 * * * CONFIG_FILE=/etc/backup/prod.conf /path/to/backup.sh >> /var/log/backup-prod.log 2>&1

# Staging backup at 3 AM
0 3 * * * CONFIG_FILE=/etc/backup/staging.conf /path/to/backup.sh >> /var/log/backup-staging.log 2>&1
```

---

## 🐳 Docker Usage

### Simple Docker Run

```bash
docker run \
  -e S3_BUCKET=my-backup-bucket \
  -e AWS_REGION=us-east-1 \
  -e LOG_LEVEL=INFO \
  -v /data/to/backup:/mount:ro \
  backup-system
```

**Entry point is `/app/backup.sh` - runs automatically!**

### Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: backup-system:latest
            env:
            - name: S3_BUCKET
              value: "my-backup-bucket"
            - name: AWS_REGION
              value: "us-east-1"
            - name: LOG_LEVEL
              value: "INFO"
            volumeMounts:
            - name: data
              mountPath: /mount
              readOnly: true
          restartPolicy: OnFailure
```

**No CMD/ENTRYPOINT needed - defaults to `backup.sh`**

---

## 🔧 Configuration

### Option 1: Configuration File (Recommended)

```bash
# Edit the config file
vim scripts/backup-config.conf

# Set your values:
S3_BUCKET="my-backup-bucket"
AWS_REGION="us-east-1"
S3_PREFIX="backups"

# Run backup
./backup.sh
```

### Option 2: Environment Variables

```bash
# Set environment variables
export S3_BUCKET="my-backup-bucket"
export AWS_REGION="us-east-1"
export S3_PREFIX="backups"

# Run backup
./backup.sh
```

### Option 3: Mix Both

```bash
# Some from config file, some from environment
export LOG_LEVEL="DEBUG"  # Override log level
export DRY_RUN="true"     # Override dry-run mode

# Rest from config file
./backup.sh
```

**Priority:** Environment variables > Config file > Defaults

---

## 🎯 All You Need to Know

### To Run a Backup:
```bash
./backup.sh
```

### To Test First:
```bash
./backup.sh --dry-run
```

### To Debug Issues:
```bash
LOG_LEVEL=DEBUG ./backup.sh
```

### To Schedule Daily:
```bash
# Add to crontab:
0 2 * * * /absolute/path/to/backup.sh >> /var/log/backup.log 2>&1
```

---

## ⚙️ What Happens Automatically

When you run `./backup.sh`, the script automatically:

1. ✅ Sets strict error handling (`set -euo pipefail`)
2. ✅ Finds its own directory (works with symlinks)
3. ✅ Sources the module loader
4. ✅ Loads required modules in correct order
5. ✅ Sets up logging
6. ✅ Loads configuration
7. ✅ Validates AWS credentials
8. ✅ Runs backup workflow
9. ✅ Handles cleanup on exit

**You don't have to think about any of this!** 🎉

---

## 📊 Available Options

### Command Line Flags
- `--dry-run` - Test mode
- `--force-alignment` - Reconciliation mode
- `--config FILE` - Custom config
- `--help` - Show help
- `--version` - Show version

### Environment Variables
- `CONFIG_FILE` - Config file path
- `LOG_LEVEL` - DEBUG, INFO, WARN, ERROR
- `LOG_FILE` - Where to write logs
- `DRY_RUN` - true/false
- `FORCE_ALIGNMENT_MODE` - true/false

### Mix and Match
```bash
# Command line
./backup.sh --dry-run --config /path/to/config

# Environment variables
DRY_RUN=true CONFIG_FILE=/path/to/config ./backup.sh

# Both together
LOG_LEVEL=DEBUG ./backup.sh --force-alignment
```

---

## 🔍 Quick Troubleshooting

### Issue: "Module not found"
```bash
# Check lib/ directory exists
ls -la lib/

# Expected:
# core.sh, utils.sh, loader.sh, config.sh
```

### Issue: "Configuration not found"
```bash
# Check config file exists
ls -la scripts/backup-config.conf

# Or specify custom location
./backup.sh --config /path/to/your/config.conf
```

### Issue: "AWS credentials invalid"
```bash
# Check AWS CLI is configured
aws sts get-caller-identity

# Or set credentials in config file
# See scripts/backup-config.conf for examples
```



## 📝 Summary

### For Manual Execution
```bash
./backup.sh
```

### For Cron Jobs
```bash
0 2 * * * /absolute/path/to/backup.sh >> /var/log/backup.log 2>&1
```

### For Docker/Kubernetes
```bash
docker run -e S3_BUCKET=bucket -e AWS_REGION=us-east-1 backup-system
```

**No module loading. No sourcing. No complexity.**  
**Just run the script!** 🎯

---


**Try it now:**
```bash
cd /path/to/backup
./backup.sh --help
./backup.sh --version
LOG_LEVEL=DEBUG DRY_RUN=true ./backup.sh
```

