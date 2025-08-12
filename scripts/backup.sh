#!/bin/bash

# Simple Firefly III Backup Script
# Creates backup of volumes and uploads to S3

set -e

# Configuration
BACKUP_NAME="firefly_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/tmp/${BACKUP_NAME}"
LOCAL_BACKUP_DIR="./backup"
PROJECT_NAME="firefly"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    exit 1
}

# Load S3 configuration
load_s3_config() {
    if [ -f ".s3.env" ]; then
        source ".s3.env"
        log "S3 configuration loaded"
        return 0
    else
        error "S3 configuration file .s3.env not found"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    command -v docker >/dev/null 2>&1 || error "Docker not found"
    command -v docker-compose >/dev/null 2>&1 || command -v docker compose version >/dev/null 2>&1 || error "Docker Compose not found"
    command -v aws >/dev/null 2>&1 || error "AWS CLI not found"
    
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        DOCKER_COMPOSE="docker compose"
    fi
    
    # Create required network if it doesn't exist
    if ! docker network inspect firefly >/dev/null 2>&1; then
        log "Creating firefly network..."
        docker network create firefly
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    log "Prerequisites check passed"
}

# Stop containers
stop_containers() {
    log "Stopping containers..."
    $DOCKER_COMPOSE down
    log "Containers stopped"
}

# Start containers
start_containers() {
    log "Starting containers..."
    $DOCKER_COMPOSE up -d
    log "Containers started"
}

# Create backup
create_backup() {
    log "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    # Backup database volume
    log "Backing up database volume..."
    docker run --rm \
        -v "${PROJECT_NAME}_firefly_iii_db:/source:ro" \
        -v "$BACKUP_DIR:/backup" \
        ubuntu tar -czf /backup/database.tar.gz -C /source .
    
    # Backup upload volume
    log "Backing up upload volume..."
    docker run --rm \
        -v "${PROJECT_NAME}_firefly_iii_upload:/source:ro" \
        -v "$BACKUP_DIR:/backup" \
        ubuntu tar -czf /backup/uploads.tar.gz -C /source .
    
    # Copy environment files
    log "Backing up configuration files..."
    [ -f ".env" ] && cp ".env" "$BACKUP_DIR/" || warn ".env file not found"
    [ -f ".db.env" ] && cp ".db.env" "$BACKUP_DIR/" || warn ".db.env file not found"
    
    # Create final archive
    local backup_archive="/tmp/${BACKUP_NAME}.tar.gz"
    log "Creating final backup archive..."
    tar -czf "$backup_archive" -C /tmp "$BACKUP_NAME"
    
    # Verify archive was created
    if [ ! -f "$backup_archive" ]; then
        error "Failed to create backup archive: $backup_archive"
    fi
    
    # Copy to local backup directory
    cp "$backup_archive" "$LOCAL_BACKUP_DIR/"
    log "Backup saved locally: $LOCAL_BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    
    echo "$backup_archive"
}

# Upload to S3
upload_to_s3() {
    local backup_file=$1
    local filename=$(basename "$backup_file")
    
    log "Configuring S3 credentials..."
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    log "Uploading backup to S3: s3://$S3_BUCKET/$filename"
    
    # Check if backup file exists and has content
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
    fi
    
    local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null)
    log "Backup file size: $file_size bytes"
    
    if [ "$file_size" -eq 0 ]; then
        error "Backup file is empty: $backup_file"
    fi
    
    if aws s3 cp "$backup_file" "s3://$S3_BUCKET/$filename" --endpoint-url="$S3_ENDPOINT"; then
        log "Backup successfully uploaded to S3"
        
        # Verify upload
        local s3_size=$(aws s3 ls "s3://$S3_BUCKET/$filename" --endpoint-url="$S3_ENDPOINT" | awk '{print $3}')
        local local_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null)
        
        if [ "$s3_size" = "$local_size" ]; then
            log "Upload verified successfully ($local_size bytes)"
        else
            warn "Upload size mismatch: local=$local_size, S3=$s3_size"
        fi
    else
        error "Failed to upload backup to S3"
    fi
}

# Cleanup old backups (keep last 30 days)
cleanup_old_backups() {
    log "Cleaning up old local backups (keep last 30)..."
    find "$LOCAL_BACKUP_DIR" -name "firefly_backup_*.tar.gz" -type f | sort -r | tail -n +31 | xargs rm -f
    
    log "Cleaning up old S3 backups (30+ days)..."
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Delete backups older than 30 days
    local cutoff_date=$(date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-30d '+%Y-%m-%d' 2>/dev/null)
    
    aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" | while read -r line; do
        local file_date=$(echo "$line" | awk '{print $1}')
        local filename=$(echo "$line" | awk '{print $4}')
        
        if [[ "$filename" == firefly_backup_*.tar.gz ]] && [[ "$file_date" < "$cutoff_date" ]]; then
            log "Deleting old S3 backup: $filename (date: $file_date)"
            aws s3 rm "s3://$S3_BUCKET/$filename" --endpoint-url="$S3_ENDPOINT"
        fi
    done
}

# Cleanup temporary files
cleanup() {
    log "Cleaning up temporary files..."
    if [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
    fi
    if [ -n "$backup_archive" ] && [ -f "$backup_archive" ]; then
        rm -f "$backup_archive"
    fi
}

# Main execution
main() {
    log "Starting Firefly III backup process..."
    
    load_s3_config
    check_prerequisites
    
    stop_containers
    backup_archive=$(create_backup)
    start_containers
    
    upload_to_s3 "$backup_archive"
    cleanup_old_backups
    
    # Manual cleanup after successful operations
    cleanup
    
    log "Backup completed successfully!"
    log "Local backup: $LOCAL_BACKUP_DIR/$(basename "$backup_archive")"
    log "S3 backup: s3://$S3_BUCKET/$(basename "$backup_archive")"
}

main "$@"