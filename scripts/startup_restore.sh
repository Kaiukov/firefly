#!/bin/bash

# Startup Restore Script
# Automatically restores from the latest backup if no existing data is found
# This runs when the backup service container starts

set -e

# Configuration - Configurable startup delay (default 5 seconds)
STARTUP_DELAY=${STARTUP_DELAY:-5}

# Enhanced logging function
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
    echo "[$timestamp] [$level] $message"
}

# Check if restore is needed (always restore in new orchestration model)
check_existing_data() {
    log_msg "INFO" "Checking if restore is needed"
    
    # In the new orchestration model, we always restore from latest S3 backup
    # since containers are not running yet and we want fresh data each startup
    log_msg "INFO" "New deployment detected, restore from latest backup required"
    return 0
}

# Get latest backup from S3
get_latest_s3_backup() {
    if [ ! -f "/.s3.env" ]; then
        return 1
    fi
    
    source "/.s3.env"
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Get latest backup filename from S3 (no log messages to avoid contamination)
    local latest_backup=$(aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" 2>/dev/null | grep "firefly_backup_" | sort -k1,2 | tail -1 | awk '{print $4}')
    
    if [ -z "$latest_backup" ]; then
        return 1
    fi
    
    echo "$latest_backup"
    return 0
}

# Check local backup directory
get_latest_local_backup() {
    log_msg "INFO" "Checking for latest local backup"
    
    if [ ! -d "/backup" ]; then
        log_msg "INFO" "No local backup directory found"
        return 1
    fi
    
    local latest_local=$(ls -t /backup/firefly_backup_*.tar.gz 2>/dev/null | head -1 || echo "")
    
    if [ -z "$latest_local" ]; then
        log_msg "INFO" "No local backups found"
        return 1
    fi
    
    log_msg "INFO" "Latest local backup: $(basename "$latest_local")"
    echo "$latest_local"
    return 0
}

# Perform volume-only restore (no container management)
perform_startup_restore() {
    log_msg "INFO" "Starting volume-only restore from S3"
    
    # Always get latest backup from S3
    local backup_file=""
    
    if backup_file=$(get_latest_s3_backup 2>/dev/null); then
        log_msg "INFO" "Found latest S3 backup: $backup_file"
    else
        log_msg "ERROR" "No S3 backups available for restore"
        return 1
    fi
    
    # Execute volume-only restore (containers will be started by orchestration)
    if [ -x "/scripts/firefly_restore.sh" ]; then
        log_msg "INFO" "Executing volume-only restore from S3: $backup_file"
        
        # Use volume-only restore mode (new flag we'll add)
        if sh /scripts/firefly_restore.sh --auto --volume-only "$backup_file"; then
            log_msg "INFO" "Volume-only restore completed successfully from S3"
            return 0
        else
            log_msg "ERROR" "Volume-only restore from S3 failed"
            return 1
        fi
    else
        log_msg "ERROR" "Restore script not found or not executable"
        return 1
    fi
}

# Main function
main() {
    log_msg "INFO" "Startup restore check beginning"
    
    # Wait a bit for other services to start - now configurable!
    log_msg "INFO" "Waiting $STARTUP_DELAY seconds for services to initialize (configurable via STARTUP_DELAY)"
    sleep $STARTUP_DELAY
    
    # Check if restore is needed
    if check_existing_data; then
        # No existing data, attempt restore
        if perform_startup_restore; then
            log_msg "INFO" "Startup restore process completed successfully"
        else
            log_msg "WARNING" "Startup restore process failed, continuing with fresh installation"
        fi
    else
        log_msg "INFO" "Existing data found or database not ready, skipping restore"
    fi
    
    log_msg "INFO" "Startup restore check completed"
}

# Run main function
main "$@"