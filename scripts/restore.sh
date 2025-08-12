#!/bin/bash

# Simple Firefly III Restore Script
# Downloads backup from S3 and restores volumes

set -e

# Configuration
PROJECT_NAME="firefly"
TEMP_DIR="/tmp/restore_$$"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" >&2
}

# Show usage
usage() {
    echo "Usage: $0 <backup_filename>"
    echo ""
    echo "Examples:"
    echo "  $0 firefly_backup_20250812_030000.tar.gz"
    echo ""
    echo "This will:"
    echo "  1. Download the backup from S3"
    echo "  2. Stop Firefly containers"
    echo "  3. Restore database and upload volumes"
    echo "  4. Start containers with restored data"
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
    
    log "Prerequisites check passed"
}

# Download backup from S3
download_backup() {
    local backup_filename=$1
    local download_path="$TEMP_DIR/backup.tar.gz"
    
    log "Downloading backup from S3: $backup_filename"
    
    # Configure AWS CLI
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    mkdir -p "$TEMP_DIR"
    
    if aws s3 cp "s3://$S3_BUCKET/$backup_filename" "$download_path" --endpoint-url="$S3_ENDPOINT"; then
        log "Backup downloaded successfully: $download_path"
        
        # Verify download
        local file_size=$(stat -c%s "$download_path" 2>/dev/null || stat -f%z "$download_path" 2>/dev/null)
        log "Downloaded file size: $file_size bytes"
        
        if [ "$file_size" -eq 0 ]; then
            error "Downloaded backup file is empty"
        fi
        
        echo "$download_path"
    else
        error "Failed to download backup from S3"
    fi
}

# Extract backup
extract_backup() {
    local backup_file=$1
    local extract_dir="$TEMP_DIR"
    
    log "Extracting backup archive..."
    
    mkdir -p "$extract_dir"
    tar -xzf "$backup_file" -C "$extract_dir" --strip-components=1
    
    log "Backup extracted to: $extract_dir"
    echo "$extract_dir"
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
    
    log "Waiting for containers to start..."
    sleep 10
    
    # Check container status
    $DOCKER_COMPOSE ps
    log "Containers started"
}

# Restore volumes
restore_volumes() {
    local extract_dir=$1
    
    log "Removing existing volumes..."
    docker volume rm "${PROJECT_NAME}_firefly_iii_db" 2>/dev/null || true
    docker volume rm "${PROJECT_NAME}_firefly_iii_upload" 2>/dev/null || true
    
    log "Creating new volumes..."
    docker volume create "${PROJECT_NAME}_firefly_iii_db"
    docker volume create "${PROJECT_NAME}_firefly_iii_upload"
    
    # Restore database volume (support both old and new format)
    local db_backup=""
    if [ -f "$extract_dir/database.tar.gz" ]; then
        db_backup="database.tar.gz"
    elif [ -f "$extract_dir/firefly_db.tar.gz" ]; then
        db_backup="firefly_db.tar.gz"
    else
        error "Database backup not found: $extract_dir/database.tar.gz or $extract_dir/firefly_db.tar.gz"
    fi
    
    log "Restoring database volume from $db_backup..."
    docker run --rm \
        -v "${PROJECT_NAME}_firefly_iii_db:/target" \
        -v "$extract_dir:/backup" \
        ubuntu tar -xzf "/backup/$db_backup" -C /target
    log "Database volume restored"
    
    # Restore upload volume (support both old and new format)
    local upload_backup=""
    if [ -f "$extract_dir/uploads.tar.gz" ]; then
        upload_backup="uploads.tar.gz"
    elif [ -f "$extract_dir/firefly_upload.tar.gz" ]; then
        upload_backup="firefly_upload.tar.gz"
    else
        warn "Upload backup not found: $extract_dir/uploads.tar.gz or $extract_dir/firefly_upload.tar.gz"
        return 0
    fi
    
    log "Restoring upload volume from $upload_backup..."
    docker run --rm \
        -v "${PROJECT_NAME}_firefly_iii_upload:/target" \
        -v "$extract_dir:/backup" \
        ubuntu tar -xzf "/backup/$upload_backup" -C /target
    log "Upload volume restored"
}

# Restore configuration files
restore_config() {
    local extract_dir=$1
    
    log "Checking configuration files in backup..."
    
    if [ -f "$extract_dir/.env" ]; then
        info "Found .env in backup - you may want to review and update it manually"
    fi
    
    if [ -f "$extract_dir/.db.env" ]; then
        info "Found .db.env in backup - using existing configuration"
    fi
    
    log "Configuration check completed"
}

# Cleanup temporary files
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Show post-restore information
show_post_restore_info() {
    echo ""
    info "=== RESTORE COMPLETED ==="
    info "Firefly III has been restored from backup"
    info "Access your application at: http://localhost:8081"
    echo ""
    info "Post-restore checklist:"
    info "1. Verify application is working correctly"
    info "2. Check that all data has been restored"
    info "3. Update .env file if needed (check backup for reference)"
    info "4. Test login and functionality"
    echo ""
    info "Container management:"
    info "  View logs: docker-compose logs"
    info "  Stop: docker-compose down"
    info "  Start: docker-compose up -d"
}

# Main execution
main() {
    # Check for backup filename argument
    if [ $# -eq 0 ]; then
        error "Backup filename required"
        usage
    fi
    
    local backup_filename="$1"
    
    log "Starting Firefly III restore process..."
    log "Backup file: $backup_filename"
    
    # Confirm the operation
    echo -e "${YELLOW}This will restore Firefly III from backup. Existing data will be REPLACED.${NC}"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Operation cancelled by user"
        exit 0
    fi
    
    trap cleanup EXIT
    
    load_s3_config
    check_prerequisites
    
    # Determine if backup file is local or needs to be downloaded from S3
    local backup_file=""
    if [ -f "$backup_filename" ]; then
        log "Using local backup file: $backup_filename"
        backup_file="$backup_filename"
    else
        log "Downloading from S3: $backup_filename"
        backup_file=$(download_backup "$backup_filename")
    fi
    
    local extract_dir=$(extract_backup "$backup_file")
    
    stop_containers
    restore_volumes "$extract_dir"
    restore_config "$extract_dir"
    start_containers
    
    show_post_restore_info
    log "Restore process completed successfully!"
}

main "$@"