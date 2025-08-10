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

# Check if Firefly III has existing data
check_existing_data() {
    log_msg "INFO" "Checking for existing Firefly III data"
    
    # Wait for database to be ready
    local max_attempts=3   # Testing: very quick timeout
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if database is ready by trying to connect
        if docker exec firefly-db-1 mysql -u firefly -pstrongpassword123 -e "SELECT 1;" >/dev/null 2>&1; then
            log_msg "INFO" "Database connection successful"
            
            # Check if firefly database exists and has tables
            local table_count=$(docker exec firefly-db-1 mysql -u firefly -pstrongpassword123 -e "USE firefly; SHOW TABLES;" 2>/dev/null | wc -l || echo "0")
            
            if [ "$table_count" -gt 1 ]; then
                # Database has tables, check for user data
                local user_count=$(docker exec firefly-db-1 mysql -u firefly -pstrongpassword123 -e "USE firefly; SELECT COUNT(*) FROM users;" 2>/dev/null | tail -1 || echo "0")
                
                if [ "$user_count" -gt 0 ]; then
                    log_msg "INFO" "Existing data found ($user_count users), skipping restore"
                    return 1
                else
                    log_msg "INFO" "Database exists but no users found, restore needed"
                    return 0
                fi
            else
                log_msg "INFO" "Database exists but no tables found (fresh installation), restore needed"
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        log_msg "INFO" "Waiting for database... (attempt $attempt/$max_attempts)"
        sleep 5
    done
    
    # After 15 attempts, assume fresh database and restore
    log_msg "INFO" "Database connection timeout - assuming fresh installation, proceeding with restore"
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

# Perform startup restore
perform_startup_restore() {
    log_msg "INFO" "Starting automatic startup restore"
    
    # Try to get latest backup (prefer S3, fallback to local)
    local backup_source=""
    local backup_file=""
    
    if backup_file=$(get_latest_s3_backup 2>/dev/null); then
        backup_source="s3"
        log_msg "INFO" "Found S3 backup: $backup_file"
    elif backup_file=$(get_latest_local_backup 2>/dev/null); then
        backup_source="local"
        log_msg "INFO" "Found local backup: $backup_file"
    else
        log_msg "INFO" "No backups available for restore"
        return 0
    fi
    
    # Execute restore
    if [ -x "/scripts/firefly_restore.sh" ]; then
        log_msg "INFO" "Executing restore from $backup_source"
        
        if [ "$backup_source" = "s3" ]; then
            # For S3 restore, pass just the filename
            if sh /scripts/firefly_restore.sh "$backup_file"; then
                log_msg "INFO" "Startup restore completed successfully from S3"
                return 0
            else
                log_msg "ERROR" "Startup restore from S3 failed"
                return 1
            fi
        else
            # For local restore, pass full path
            if sh /scripts/firefly_restore.sh "$backup_file"; then
                log_msg "INFO" "Startup restore completed successfully from local backup"
                return 0
            else
                log_msg "ERROR" "Startup restore from local backup failed"
                return 1
            fi
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