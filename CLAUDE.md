# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Firefly III personal finance manager setup using Docker Compose with automated backup system. The repository contains a fully automated backup service with S3 integration, daily scheduling, and startup restore functionality.

**Project Structure:**
- `/backend/` - Complete Firefly III Docker setup with automated backup system
- `/frontend/` - (Reserved for future frontend development)

**Working Directory:** All commands should be run from the root directory `/Users/oleksandrkaiukov/Code/firefly`

## Current Architecture

- **3-Service Docker Setup**: Firefly III app, MariaDB database, and automated backup service
- **Automated S3 Backup System**: Containerized backup service with S3 integration (Phase 2 complete)
- **Scheduled Backups**: Daily backups at 3 AM UTC with 30-day retention cleanup
- **Startup Restore**: Automatic restore from latest backup on container startup if no data exists
- **Local + S3 Storage**: Backups stored locally in `/backup` directory and uploaded to S3
- **Advanced Logging**: Comprehensive logging with rotation and health checks
- **External Network**: Uses external Docker network named "firefly"

## Current System Components

### Active Components
- `docker-compose.yml`: 3-service definition (Firefly III app + MariaDB + backup service)
- `scripts/backup_service.sh`: Main automated backup daemon with scheduling
- `scripts/firefly_backup.sh`: Backup creation with S3 upload + local storage
- `scripts/firefly_restore.sh`: Flexible restore from local files or S3 download
- `scripts/startup_restore.sh`: Automatic startup restore functionality
- `backup/`: Local backup directory
  - Current backups: Multiple timestamped .tar.gz files
- `logs/`: Service logs directory with rotation
- `.env`: Firefly III application configuration
- `.db.env`: Database credentials
- `.s3.env`: S3/Cloudflare R2 credentials (active and integrated)

### Volume Structure
- `firefly_iii_upload`: User upload data
- `firefly_iii_db`: MariaDB database data

## Current Commands

### Docker Operations
**Note: Run all commands from the root directory**

```bash
# Working directory should be root (firefly/)

# Start all services (app + database + backup)
docker-compose up -d

# Stop all services
docker-compose down

# View logs for all services
docker-compose logs

# View backup service logs specifically
docker-compose logs backup

# Check status
docker-compose ps
```

### Backup Operations
```bash
# Automated daily backups run at 3 AM UTC (no manual intervention needed)
# View backup service status
docker-compose logs backup

# Manual backup via backup service container
docker-compose exec backup sh /scripts/backup_service.sh daily_backup

# Manual S3 cleanup
docker-compose exec backup sh /scripts/backup_service.sh cleanup_s3

# Health check of backup system
docker-compose exec backup sh /scripts/backup_service.sh health_check

# View backup logs
docker-compose exec backup cat /logs/backup_service.log

# List local backups
ls -la backup/

# Manual restore from local backup (run from backup container)
docker-compose exec backup sh /scripts/firefly_restore.sh backup/firefly_backup_20250807_193028.tar.gz

# Manual restore from S3 (auto-downloads latest)
docker-compose exec backup sh /scripts/firefly_restore.sh

# Manual restore specific backup from S3
docker-compose exec backup sh /scripts/firefly_restore.sh firefly_backup_20250807_193028.tar.gz
```

### Network Setup
```bash
# Create external network (required)
docker network create firefly

# Inspect volumes
docker volume inspect firefly_iii_db
docker volume inspect firefly_iii_upload
```

## Configuration

### Current Required Files
- `.env`: Firefly III application configuration
- `.db.env`: Database credentials
- `.s3.env`: S3/Cloudflare R2 credentials (active and integrated)

### Current Setup Notes
- App runs on port 8081 (mapped from container port 8080)
- Database uses MariaDB LTS image
- External "firefly" network required
- S3 backup/restore system operational with Cloudflare R2
- Graceful fallback to local-only if S3 unavailable

### S3 Configuration Template (.s3.env)
```bash
S3_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
S3_BUCKET=fireflybackup
S3_ACCESS_KEY=your-access-key-here
S3_SECRET_KEY=your-secret-key-here
S3_REGION=auto
BACKUP_RETENTION_DAYS=30
```

## Planned Enhancements Roadmap

### Phase 1: S3 Integration ✅ COMPLETED
- [x] Update backup scripts to use S3 instead of webhook
- [x] Add S3 upload/download functionality  
- [x] Test S3 backup and restore workflow
- [x] Graceful fallback when S3 unavailable

### Phase 2: Automated Backup Service ✅ COMPLETED
- [x] Add backup service to docker-compose.yml
- [x] Implement daily backup scheduling (3 AM UTC)
- [x] Add 30-day backup retention cleanup
- [x] Advanced logging with rotation
- [x] Startup restore functionality
- [x] Health checks and monitoring
- [x] Manual backup commands via docker exec

### Phase 3: Future Enhancements
- [ ] Backup verification and integrity testing
- [ ] Email/webhook notifications for backup failures
- [ ] Multiple backup retention policies (daily/weekly/monthly)
- [ ] Backup encryption
- [ ] Multi-region S3 replication

### Phase 4: Advanced Features (Optional)
- [ ] Web UI for backup management
- [ ] Database migration tools
- [ ] Incremental backups
- [ ] Backup compression optimization

## S3/Cloudflare R2 Setup Instructions

### 1. Create Cloudflare R2 Bucket
1. Log into Cloudflare dashboard
2. Go to R2 Object Storage  
3. Create bucket named `fireflybackup`

### 2. Generate API Credentials
1. Go to R2 → Manage R2 API tokens
2. Create API token with Object Read & Write permissions
3. Save Account ID, Access Key, and Secret Key to `.s3.env`

### 3. S3 Commands (Active Integration)
```bash
# Test S3 connection
docker-compose exec backup /scripts/backup_service.sh health_check

# List S3 backups
docker-compose exec backup aws s3 ls s3://fireflybackup/ --endpoint-url=https://dd7ab9be93db46931523f62d3fe7f581.r2.cloudflarestorage.com

# Manual backup to S3
docker-compose exec backup sh /scripts/backup_service.sh daily_backup
```

## Current Automated Workflow

1. **Automated Daily Backups**: Backup service runs daily at 3 AM UTC, uploads to S3 + saves locally
2. **Startup Restore**: On container startup, automatically restores from latest backup if no data exists
3. **Dual Storage**: All backups stored in `/backup` directory and S3 bucket with 30-day retention
4. **Health Monitoring**: Automated health checks verify S3 connectivity and disk space
5. **Advanced Logging**: Comprehensive logs with rotation in `/logs` directory
6. **Manual Operations**: All backup operations available via docker exec commands

## Architecture Details

### Container Relationships
- **Firefly App** connects to **MariaDB** via internal "firefly" network
- **Backup Service** monitors both containers via Docker socket and volume mounts  
- **External Network**: "firefly" must be created manually before startup
- **Volume Dependencies**: App and DB volumes are mounted read-only to backup service

### Data Flow
1. **Normal Operation**: App ↔ Database (port 8081 exposed externally)
2. **Backup Flow**: Service creates archives from volumes → Local storage → S3 upload
3. **Restore Flow**: S3 download → Volume recreation → Container restart
4. **Logging**: All operations logged to `/logs` with rotation

### Critical Dependencies
- External Docker network "firefly" 
- Environment files: `.env`, `.db.env`, `.s3.env` (gitignored for security)
- Docker socket access for backup service container management
- S3/Cloudflare R2 bucket with proper API tokens

## Known Issues & Limitations

### Active Issues
- **Cron Job Execution**: Some log entries show script path issues in backup container
- **Volume Name Dependencies**: Scripts assume specific Docker Compose project naming
- **Missing Config Templates**: No `.env.example` files for new deployments
- **Docker Socket Security**: Backup service has full Docker daemon access

### Architecture Limitations  
- **Single Point of Failure**: S3 bucket is only backup destination
- **No Backup Verification**: Created backups are not integrity checked
- **Root Container Privileges**: Backup service runs with elevated permissions
- **Manual Network Setup**: External network requires manual creation

## Troubleshooting Automated System

### Backup Service Issues
- Check backup service logs: `docker-compose logs backup`
- Verify service is running: `docker-compose ps`
- Run health check: `docker-compose exec backup sh /scripts/backup_service.sh health_check`
- Check cron jobs: `docker-compose exec backup crontab -l`
- View detailed logs: `docker-compose exec backup cat /logs/backup_service.log`

### S3 Issues  
- Verify S3 connectivity: `docker-compose exec backup sh /scripts/backup_service.sh health_check`
- Check `.s3.env` credentials are correct (bucket name: `fireflybackup`)
- Check Cloudflare R2 bucket permissions and API token access
- Ensure network connectivity to S3 endpoint
- List S3 backups: `docker-compose exec backup aws s3 ls s3://fireflybackup/`

### Restore Issues
- Verify backup file integrity in `/backup` directory
- Check Docker volume permissions and existence
- Ensure sufficient disk space for restore operation
- Review restore logs for specific error messages
- For manual restore, ensure containers are stopped first

### Storage Issues
- Check disk space: `df -h backup/` and `df -h logs/`
- Verify volume mounts: `docker-compose exec backup df -h`
- Check log rotation: `docker-compose exec backup ls -la /logs/`
- Monitor backup retention: `ls -la backup/ | wc -l` (should not exceed ~30 files)