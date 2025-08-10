#!/bin/bash

# Firefly III Backup Script
# This script creates a backup of Firefly III Docker installation and uploads it to S3

set -e  # Exit on any error

# Configuration
BACKUP_DIR="/tmp/firefly_backup_$(date +%Y%m%d_%H%M%S)"
COMPOSE_DIR="/scripts"                                       # Scripts directory in container
DB_VOLUME="firefly_firefly_iii_db"                          # Database volume
UPLOAD_VOLUME="firefly_firefly_iii_upload"                  # Upload volume
DOCKER_COMPOSE_CMD=""                                       # Will be set automatically
LOCAL_BACKUP_DIR="/backup"                                  # Local backup storage (mounted volume)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_msg() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Load S3 configuration
load_s3_config() {
    if [ -f "/.s3.env" ]; then
        source "/.s3.env"
        log_msg "Loaded S3 configuration"
        return 0
    else
        log_msg "S3 configuration file .s3.env not found - will skip S3 operations"
        return 1
    fi
}

# Function to detect Docker Compose command
detect_docker_compose() {
    # Skip docker-compose detection when running in container
    if [ -f "/.dockerenv" ]; then
        log_msg "Running in container mode - skipping docker-compose detection"
        DOCKER_COMPOSE_CMD="echo 'container-mode'"
        return 0
    fi
    
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        error "Docker Compose is not installed or not in PATH"
    fi
}

# Function to check if volume exists
check_volume() {
    local volume_name=$1
    if ! docker volume inspect "$volume_name" > /dev/null 2>&1; then
        error "Volume $volume_name does not exist. Please check your volume names."
    fi
}

# Function to create backup directory
create_backup_dir() {
    log_msg "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
}

# Function to backup Docker volumes
backup_volumes() {
    log_msg "Backing up Docker volumes..."
    
    # Check if volumes exist
    check_volume "$DB_VOLUME"
    check_volume "$UPLOAD_VOLUME"
    
    # Backup database volume using direct access from mounted volumes
    log_msg "Backing up database volume: $DB_VOLUME"
    if [ -d "/data/firefly_iii_db" ]; then
        tar -czf "$BACKUP_DIR/firefly_db.tar.gz" -C /data/firefly_iii_db .
    else
        # Fallback to docker run method
        docker run --rm \
            -v "${DB_VOLUME}:/source" \
            -v "${BACKUP_DIR}:/backup" \
            ubuntu tar -czf /backup/firefly_db.tar.gz -C /source .
    fi
    
    # Backup upload volume using direct access from mounted volumes
    log_msg "Backing up upload volume: $UPLOAD_VOLUME"
    if [ -d "/data/firefly_iii_upload" ]; then
        tar -czf "$BACKUP_DIR/firefly_upload.tar.gz" -C /data/firefly_iii_upload .
    else
        # Fallback to docker run method
        docker run --rm \
            -v "${UPLOAD_VOLUME}:/source" \
            -v "${BACKUP_DIR}:/backup" \
            ubuntu tar -czf /backup/firefly_upload.tar.gz -C /source .
    fi
}

# Function to backup configuration files
backup_config() {
    log_msg "Backing up configuration files..."
    
    # Backup .env file from mounted location
    if [ -f "/.env" ]; then
        cp "/.env" "$BACKUP_DIR/"
        log_msg "Backed up .env file"
    else
        warn ".env file not found"
    fi
    
    # Backup .db.env file from mounted location  
    if [ -f "/.db.env" ]; then
        cp "/.db.env" "$BACKUP_DIR/"
        log_msg "Backed up .db.env file"
    else
        warn ".db.env file not found"
    fi
    
    # Note: docker-compose.yml is not included in backup as it's managed separately
    log_msg "Configuration backup completed"
}

# Function to create final backup archive
create_backup_archive() {
    local backup_filename="firefly_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local backup_path="/tmp/$backup_filename"
    
    log_msg "Creating final backup archive: $backup_filename" >&2
    tar -czf "$backup_path" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")" >&2
    
    # Only echo the path (no log messages)
    echo "$backup_path"
}

# Function to upload backup to S3
upload_to_s3() {
    local backup_file=$1
    local filename=$(basename "$backup_file")
    
    log_msg "Uploading backup to S3: s3://$S3_BUCKET/$filename"
    
    # Check if backup file exists and has content
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
    fi
    
    local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null)
    log_msg "Backup file size: $file_size bytes"
    
    if [ "$file_size" -eq 0 ]; then
        error "Backup file is empty: $backup_file"
    fi
    
    # Configure AWS CLI for S3-compatible storage
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Upload to S3
    log_msg "Uploading backup file: $filename"
    if aws s3 cp "$backup_file" "s3://$S3_BUCKET/$filename" --endpoint-url="$S3_ENDPOINT"; then
        log_msg "Backup successfully uploaded to S3"
        log_msg "File size uploaded: $file_size bytes"
        log_msg "S3 location: s3://$S3_BUCKET/$filename"
    else
        error "Failed to upload backup to S3"
    fi
}

# Function to save backup locally
save_backup_locally() {
    local backup_file=$1
    local filename=$(basename "$backup_file")
    
    log_msg "Saving backup locally to: $LOCAL_BACKUP_DIR/$filename"
    
    # Create local backup directory if it doesn't exist
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    # Copy backup to local directory
    cp "$backup_file" "$LOCAL_BACKUP_DIR/$filename"
    log_msg "Backup saved locally: $LOCAL_BACKUP_DIR/$filename"
}

# Function to cleanup old backups
cleanup_old_backups() {
    if [ -n "$BACKUP_RETENTION_DAYS" ] && [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then
        log_msg "Cleaning up S3 backups older than $BACKUP_RETENTION_DAYS days"
        
        # Configure AWS CLI
        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
        export AWS_DEFAULT_REGION="$S3_REGION"
        
        # List and delete old backups
        aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" | while read -r line; do
            # Extract date and filename
            backup_date=$(echo "$line" | awk '{print $1}')
            backup_file=$(echo "$line" | awk '{print $4}')
            
            if [ -n "$backup_date" ] && [ -n "$backup_file" ]; then
                # Calculate age of backup
                backup_timestamp=$(date -d "$backup_date" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$backup_date" +%s 2>/dev/null)
                current_timestamp=$(date +%s)
                age_days=$(( (current_timestamp - backup_timestamp) / 86400 ))
                
                if [ "$age_days" -gt "$BACKUP_RETENTION_DAYS" ]; then
                    log_msg "Deleting old backup: $backup_file (age: $age_days days)"
                    aws s3 rm "s3://$S3_BUCKET/$backup_file" --endpoint-url="$S3_ENDPOINT"
                fi
            fi
        done
        
        log_msg "Cleanup completed"
    else
        log_msg "Backup retention not configured, skipping cleanup"
    fi
}

# Function to cleanup temporary files
cleanup() {
    log_msg "Cleaning up temporary files..."
    if [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
    fi
    if [ ! -z "$backup_archive" ] && [ -f "$backup_archive" ]; then
        rm -f "$backup_archive"
    fi
}

# Main execution
main() {
    log_msg "Starting Firefly III backup process..."
    
    # Trap to ensure cleanup on exit
    trap cleanup EXIT
    
    # Load S3 configuration
    S3_AVAILABLE=false
    if load_s3_config; then
        S3_AVAILABLE=true
        # Check if AWS CLI is available for S3 operations
        if ! command -v aws >/dev/null 2>&1; then
            warn "AWS CLI is not installed - S3 upload will be skipped"
            S3_AVAILABLE=false
        fi
    fi
    
    # Check if required tools are available
    command -v docker >/dev/null 2>&1 || error "Docker is not installed or not in PATH"
    
    # Detect Docker Compose command
    detect_docker_compose
    
    # Create backup
    create_backup_dir
    backup_volumes
    backup_config
    
    # Create archive
    backup_archive=$(create_backup_archive)
    
    # Verify the backup file was created
    if [ ! -f "$backup_archive" ]; then
        error "Failed to create backup archive: $backup_archive"
    fi
    
    # Save backup locally
    save_backup_locally "$backup_archive"
    
    # Upload to S3 if available
    if [ "$S3_AVAILABLE" = true ]; then
        upload_to_s3 "$backup_archive"
        cleanup_old_backups
    else
        log_msg "S3 not available - skipping S3 upload and cleanup"
    fi
    
    log_msg "Backup process completed successfully!"
}

# Check if script is run with correct permissions
if [ "$EUID" -eq 0 ]; then
    warn "Running as root. Make sure this is intended."
fi

# Run main function
main "$@"
