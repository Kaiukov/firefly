# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a simplified Firefly III personal finance manager setup using Docker Compose with S3 backup integration. The project has been overhauled to be as simple as possible while maintaining reliable backup functionality.

**Project Structure:**
- `docker-compose.yml` - Simple 2-service setup (app + database)
- `scripts/backup.sh` - Manual backup script with S3 upload
- `scripts/restore.sh` - Manual restore script with S3 download
- `setup-cron.sh` - One-time cron job setup script

**Working Directory:** All commands should be run from the root directory `/root/firefly`

## Simple Architecture

- **2-Service Docker Setup**: Only Firefly III app and MariaDB database
- **No Container Orchestration**: Simple docker-compose up/down operation
- **Host-based Cron**: Daily backups scheduled at 3 AM Kyiv time via system cron
- **S3 Integration**: All backups stored in S3 bucket (with local copies)
- **Manual Commands**: Two simple scripts for backup and restore operations
- **No Startup Restore**: Clean startup every time, no automatic data restoration

## System Components

### Active Components
- `docker-compose.yml`: 2-service definition (Firefly III app + MariaDB only)
- `scripts/backup.sh`: Simple backup with S3 upload
- `scripts/restore.sh`: Simple restore with S3 download
- `setup-cron.sh`: One-time cron setup script
- `.env`: Firefly III application configuration
- `.db.env`: Database credentials
- `.s3.env`: S3/Cloudflare R2 credentials

### Volume Structure
- `firefly_iii_upload`: User upload data
- `firefly_iii_db`: MariaDB database data

## Current Commands

### Docker Operations
```bash
# Start services
docker-compose up -d

# Stop services
docker-compose down

# View logs (all services)
docker-compose logs

# View specific service logs
docker-compose logs app
docker-compose logs db

# Check status
docker-compose ps
```

### Backup & Restore Operations
```bash
# Manual backup (uploads to S3 + saves locally)
./scripts/backup.sh

# Manual restore (downloads from S3 + restores volumes)
./scripts/restore.sh firefly_backup_20250812_030000.tar.gz

# View backup logs
tail -f /var/log/firefly-backup.log

# List local backups
ls -la backup/
```

### One-time Setup
```bash
# Create external network (required once)
docker network create firefly

# Setup daily backup cron job (run once)
./setup-cron.sh

# View configured cron jobs
crontab -l
```

## Configuration

### Required Files
- `.env`: Firefly III application configuration
- `.db.env`: Database credentials
- `.s3.env`: S3/Cloudflare R2 credentials

### Setup Notes
- App runs on port 8081 (mapped from container port 8080)
- Database uses MariaDB LTS image with Europe/Kyiv timezone
- External "firefly" network required
- Automatic restarts enabled (`unless-stopped`)
- Daily backups at 3 AM Kyiv time (1:00 UTC)

### S3 Configuration (.s3.env)
```bash
S3_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
S3_BUCKET=fireflybackup
S3_ACCESS_KEY=your-access-key-here
S3_SECRET_KEY=your-secret-key-here
S3_REGION=auto
```

## Simple Workflow

### Daily Operation
1. **Automated Backup**: Cron runs `backup.sh` at 3 AM Kyiv time
2. **Backup Process**: Stop containers → Create volume archives → Upload to S3 → Start containers
3. **Cleanup**: Keeps last 30 backups locally and in S3

### Manual Operations
1. **Manual Backup**: Run `./scripts/backup.sh` anytime
2. **Manual Restore**: Run `./scripts/restore.sh filename.tar.gz` when needed
3. **Container Management**: Standard `docker-compose up -d` / `docker-compose down`

## Architecture Details

### Backup Flow
1. **backup.sh** stops containers via docker-compose
2. Creates tar.gz archives of both Docker volumes
3. Includes .env and .db.env configuration files
4. Uploads final archive to S3 bucket
5. Saves local copy in ./backup/ directory
6. Restarts containers
7. Cleans up old backups (30-day retention)

### Restore Flow
1. **restore.sh** downloads specified backup from S3
2. Stops containers via docker-compose
3. Removes existing volumes completely
4. Recreates volumes from backup archives
5. Restarts containers with restored data
6. Cleans up temporary files

### Critical Dependencies
- External Docker network "firefly"
- Environment files: `.env`, `.db.env`, `.s3.env`
- S3/Cloudflare R2 bucket with proper API tokens
- AWS CLI installed on host system
- System cron daemon running

## S3/Cloudflare R2 Setup

### 1. Create Cloudflare R2 Bucket
1. Log into Cloudflare dashboard
2. Go to R2 Object Storage
3. Create bucket named `fireflybackup`

### 2. Generate API Credentials
1. Go to R2 → Manage R2 API tokens
2. Create API token with Object Read & Write permissions
3. Save Account ID, Access Key, and Secret Key to `.s3.env`

## Troubleshooting

### Backup Issues
- Check cron job: `crontab -l`
- View backup logs: `tail -f /var/log/firefly-backup.log`
- Test manual backup: `./scripts/backup.sh`
- Check S3 configuration: ensure `.s3.env` is correct
- Verify AWS CLI: `aws --version`

### Restore Issues
- Ensure containers are stopped before restore
- Check S3 connectivity: verify backup file exists in bucket
- Check disk space: ensure sufficient space for download and extraction
- Review restore logs for error messages

### Container Issues
- Check external network exists: `docker network ls | grep firefly`
- Verify environment files exist: `.env`, `.db.env`
- Check container logs: `docker-compose logs`
- Verify port 8081 is available

### Storage Issues
- Check local backup space: `df -h backup/`
- Monitor S3 bucket usage in Cloudflare R2 dashboard
- Verify backup retention cleanup is working

## Key Differences from Previous Version

### Removed Complexity
- ❌ Complex backup service container with orchestration
- ❌ Automatic startup restore functionality
- ❌ Container lifecycle management via Docker socket
- ❌ Advanced logging and rotation systems
- ❌ Daemon-based backup service with multiple scripts

### New Simplicity
- ✅ Simple 2-container setup (app + db only)
- ✅ Host-based cron for scheduling
- ✅ Two manual commands: backup and restore
- ✅ Direct S3 integration without complexity
- ✅ Standard docker-compose operations
- ✅ Clean startup every time (no restore automation)

This simplified architecture maintains all essential functionality while being much easier to understand, maintain, and troubleshoot.