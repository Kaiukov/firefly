#!/bin/bash

# Firefly III Automated Backup Service
# This service runs inside a Docker container and handles:
# - Daily scheduled backups at 3 AM UTC
# - Startup restore functionality
# - S3 bucket cleanup and version management
# - Advanced logging and monitoring

set -e

# Configuration
BACKUP_SCRIPT="/scripts/firefly_backup.sh"
RESTORE_SCRIPT="/scripts/firefly_restore.sh"
STARTUP_RESTORE_SCRIPT="/scripts/startup_restore.sh"
LOG_DIR="/logs"
LOG_FILE="$LOG_DIR/backup_service.log"
CRON_LOG_FILE="$LOG_DIR/cron.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Enhanced logging function
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Log rotation function
rotate_logs() {
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        log_msg "INFO" "Rotating log files (>10MB)"
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d_%H%M%S)"
        gzip "$LOG_FILE.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        # Keep only last 5 rotated logs
        find "$LOG_DIR" -name "backup_service.log.*.gz" | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
}

# Health check function
health_check() {
    log_msg "INFO" "Running health check"
    
    # Check S3 connectivity
    if [ -f "/.s3.env" ]; then
        source "/.s3.env"
        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
        export AWS_DEFAULT_REGION="$S3_REGION"
        
        if aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" >/dev/null 2>&1; then
            log_msg "INFO" "S3 connectivity: OK"
        else
            log_msg "WARNING" "S3 connectivity: FAILED"
        fi
    fi
    
    # Check Docker connectivity
    if docker ps >/dev/null 2>&1; then
        log_msg "INFO" "Docker connectivity: OK"
    else
        log_msg "WARNING" "Docker connectivity: FAILED"
    fi
    
    # Check available disk space
    local available=$(df /backup 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    if [ "$available" -lt 1048576 ]; then  # Less than 1GB
        log_msg "WARNING" "Low disk space: ${available}KB available"
    else
        log_msg "INFO" "Disk space: ${available}KB available"
    fi
}

# Daily backup function
daily_backup() {
    log_msg "INFO" "Starting daily backup"
    rotate_logs
    
    if [ -f "$BACKUP_SCRIPT" ]; then
        if sh "$BACKUP_SCRIPT" >> "$LOG_FILE" 2>&1; then
            log_msg "INFO" "Daily backup completed successfully"
        else
            log_msg "ERROR" "Daily backup failed"
            return 1
        fi
    else
        log_msg "ERROR" "Backup script not found: $BACKUP_SCRIPT"
        return 1
    fi
}

# S3 cleanup function
cleanup_s3_backups() {
    log_msg "INFO" "Starting S3 backup cleanup (30-day retention)"
    
    if [ -f "/.s3.env" ]; then
        source "/.s3.env"
        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
        export AWS_DEFAULT_REGION="$S3_REGION"
        
        # Calculate cutoff timestamp (30 days ago)
        local retention_days=${BACKUP_RETENTION_DAYS:-30}
        local cutoff_timestamp=$(($(date +%s) - (retention_days * 24 * 3600)))
        
        # List and delete old backups
        aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" | while read -r line; do
            local file_date=$(echo "$line" | awk '{print $1}')
            local filename=$(echo "$line" | awk '{print $4}')
            
            if echo "$filename" | grep -q "^firefly_backup_.*\.tar\.gz$" && [ -n "$file_date" ]; then
                # Convert file date to timestamp for comparison  
                local file_timestamp=$(date -d "$file_date" +%s 2>/dev/null || echo "0")
                
                if [ "$file_timestamp" -lt "$cutoff_timestamp" ] && [ "$file_timestamp" -gt "0" ]; then
                    log_msg "INFO" "Deleting old backup from S3: $filename (date: $file_date)"
                    aws s3 rm "s3://$S3_BUCKET/$filename" --endpoint-url="$S3_ENDPOINT" || log_msg "WARNING" "Failed to delete $filename"
                fi
            fi
        done
        
        log_msg "INFO" "S3 cleanup completed"
    else
        log_msg "WARNING" "S3 configuration not found, skipping S3 cleanup"
    fi
}

# Setup cron job
setup_cron() {
    log_msg "INFO" "Setting up cron job for daily backups at 3 AM UTC"
    
    # Create cron job that runs daily backup
    cat > /etc/crontabs/root << 'EOF'
# Daily backup at 3 AM UTC
0 3 * * * /scripts/backup_service.sh daily_backup >> /logs/cron.log 2>&1
# Weekly S3 cleanup on Sundays at 4 AM UTC
0 4 * * 0 /scripts/backup_service.sh cleanup_s3 >> /logs/cron.log 2>&1
# Daily health check at 6 AM UTC
0 6 * * * /scripts/backup_service.sh health_check >> /logs/cron.log 2>&1
EOF
    
    # Start cron daemon
    crond -f &
    log_msg "INFO" "Cron daemon started with backup schedule"
}

# Startup restore check
startup_restore() {
    log_msg "INFO" "Checking if startup restore is needed"
    
    if [ -f "$STARTUP_RESTORE_SCRIPT" ]; then
        if sh "$STARTUP_RESTORE_SCRIPT" >> "$LOG_FILE" 2>&1; then
            log_msg "INFO" "Startup restore check completed"
        else
            log_msg "WARNING" "Startup restore check failed"
        fi
    else
        log_msg "WARNING" "Startup restore script not found: $STARTUP_RESTORE_SCRIPT"
    fi
}

# Main service function
main() {
    log_msg "INFO" "Firefly III Backup Service starting..."
    log_msg "INFO" "Service PID: $$"
    log_msg "INFO" "Current time: $(date)"
    
    # Handle different command modes
    case "${1:-daemon}" in
        "daily_backup")
            daily_backup
            ;;
        "cleanup_s3")
            cleanup_s3_backups
            ;;
        "health_check")
            health_check
            ;;
        "startup_restore")
            startup_restore
            ;;
        "daemon"|"")
            # Full daemon mode
            startup_restore
            setup_cron
            
            # Keep the service running
            log_msg "INFO" "Backup service running in daemon mode"
            while true; do
                sleep 3600  # Sleep for 1 hour
                rotate_logs  # Check for log rotation hourly
            done
            ;;
        *)
            echo "Usage: $0 [daily_backup|cleanup_s3|health_check|startup_restore|daemon]"
            exit 1
            ;;
    esac
}

# Handle signals gracefully
trap 'log_msg "INFO" "Backup service stopping..."; exit 0' SIGTERM SIGINT

# Start the service
main "$@"