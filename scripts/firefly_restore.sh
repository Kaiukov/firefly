#!/bin/bash

# Firefly III Restore Script
# This script restores Firefly III from backup (local file or S3 download)

set -e  # Exit on any error

# Configuration
INSTALL_DIR="/scripts"                                     # Scripts directory in container
DB_VOLUME="firefly_firefly_iii_db"                         # Database volume (with compose prefix)
UPLOAD_VOLUME="firefly_firefly_iii_upload"                 # Upload volume (with compose prefix)
RESTORE_DIR="/tmp/firefly_restore_$(date +%Y%m%d_%H%M%S)"
DOCKER_COMPOSE_CMD=""                                      # Will be set automatically
LOCAL_BACKUP_DIR="/backup"                                 # Local backup storage (mounted volume)

# Load S3 configuration if available
if [ -f "/.s3.env" ]; then
    source "/.s3.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS] [backup_file]"
    echo ""
    echo "This script restores Firefly III from backup"
    echo ""
    echo "Options:"
    echo "  --auto         Run in automatic mode (no confirmation prompts)"
    echo "  -y, --yes      Same as --auto"
    echo "  --volume-only  Restore volumes only, skip container management"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Parameters:"
    echo "  backup_file    Optional: Path to backup file or filename in S3"
    echo "                 If not provided, downloads latest from S3"
    echo ""
    echo "Examples:"
    echo "  $0 --auto                                   # Auto restore latest from S3"
    echo "  $0 -y firefly_backup_20250807_020005.tar.gz # Auto restore specific from S3"
    echo "  $0 backup/firefly_backup_20250807.tar.gz   # Manual restore from local file"
    echo ""
    exit 1
}

# Function to check prerequisites
check_prerequisites() {
    log_msg "Checking prerequisites..."
    
    # Check if Docker is installed
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed. Please install Docker first."
    fi
    
    # Skip Docker Compose check in container mode (we're running inside the backup container)
    if [ -f "/.dockerenv" ]; then
        log_msg "Running in container mode - skipping Docker Compose check"
        DOCKER_COMPOSE_CMD="echo 'container-mode'"
    else
        # Check which Docker Compose command is available
        if command -v docker-compose >/dev/null 2>&1; then
            DOCKER_COMPOSE_CMD="docker-compose"
            log_msg "Using docker-compose command"
        elif docker compose version >/dev/null 2>&1; then
            DOCKER_COMPOSE_CMD="docker compose"
            log_msg "Using docker compose command"
        else
            error "Docker Compose is not installed. Please install Docker Compose first."
        fi
    fi
    
    # Check if tar is available
    if ! command -v tar >/dev/null 2>&1; then
        error "tar is not installed"
    fi
    
    # Check if AWS CLI is available for S3 operations
    if [ -f "$(pwd)/.s3.env" ]; then
        if ! command -v aws >/dev/null 2>&1; then
            error "AWS CLI is not installed. Required for S3 operations."
        fi
        log_msg "AWS CLI available for S3 operations"
    fi
    
    log_msg "Prerequisites check passed"
}

# Function to download backup from S3
download_from_s3() {
    local backup_file=$1
    local download_path="/tmp/$(basename "$backup_file")"
    
    log_msg "Downloading backup from S3: s3://$S3_BUCKET/$backup_file" >&2
    
    # Configure AWS CLI
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Download from S3 (redirect output to stderr to avoid contaminating return value)
    if aws s3 cp "s3://$S3_BUCKET/$backup_file" "$download_path" --endpoint-url="$S3_ENDPOINT" >&2; then
        log_msg "Backup downloaded successfully: $download_path" >&2
        echo "$download_path"
    else
        error "Failed to download backup from S3"
    fi
}

# Function to get latest backup from S3
get_latest_s3_backup() {
    log_msg "Finding latest backup in S3..." >&2
    
    # Configure AWS CLI
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Get latest backup filename
    latest_backup=$(aws s3 ls "s3://$S3_BUCKET/" --endpoint-url="$S3_ENDPOINT" 2>/dev/null | grep ".tar.gz" | sort | tail -n 1 | awk '{print $4}')
    
    if [ -n "$latest_backup" ]; then
        log_msg "Latest backup found: $latest_backup" >&2
        echo "$latest_backup"
    else
        error "No backups found in S3 bucket: $S3_BUCKET"
    fi
}

# Function to determine backup file to use
get_backup_file() {
    local input_file=$1
    
    # If no file specified, get latest from S3
    if [ -z "$input_file" ]; then
        if [ -f "$(pwd)/.s3.env" ]; then
            log_msg "No backup file specified, downloading latest from S3..." >&2
            local latest_backup=$(get_latest_s3_backup)
            download_from_s3 "$latest_backup"
        else
            error "No backup file specified and no S3 configuration found"
        fi
    # If file exists locally, use it
    elif [ -f "$input_file" ]; then
        log_msg "Using local backup file: $input_file" >&2
        echo "$input_file"
    # If it's just a filename, try to download from S3
    elif [[ "$input_file" == *.tar.gz ]] && [ -f "$(pwd)/.s3.env" ]; then
        log_msg "Downloading specified backup from S3: $input_file" >&2
        download_from_s3 "$input_file"
    else
        error "Backup file not found: $input_file"
    fi
}

# Function to extract backup archive
extract_backup() {
    local backup_file=$1
    
    log_msg "Extracting backup archive..."
    
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
    fi
    
    # Create restore directory
    mkdir -p "$RESTORE_DIR"
    
    # Extract the backup
    tar -xzf "$backup_file" -C "$RESTORE_DIR" --strip-components=1
    
    log_msg "Backup extracted to: $RESTORE_DIR"
}

# Function to restore configuration files
restore_config() {
    log_msg "Restoring configuration files..."
    
    # Note: In containerized environment, .env files are mounted read-only
    # Configuration restoration is handled by the startup restore process
    
    # Log what configuration files are available in backup
    if [ -f "$RESTORE_DIR/.env" ]; then
        log_msg "Found .env file in backup"
    else
        warn ".env file not found in backup"
    fi
    
    if [ -f "$RESTORE_DIR/.db.env" ]; then
        log_msg "Found .db.env file in backup"
    else
        warn ".db.env file not found in backup"
    fi
    
    log_msg "Configuration file check completed"
}

# Function to create and restore Docker volumes
restore_volumes() {
    log_msg "Creating and restoring Docker volumes..."
    
    # Stop containers first via Docker commands (not compose)
    log_msg "Stopping Firefly containers before volume restore..."
    
    # Get container names dynamically
    local app_container=$(docker ps --filter "name=app" --format "{{.Names}}" | head -1)
    local db_container=$(docker ps --filter "name=db" --format "{{.Names}}" | head -1)
    
    # Stop containers if they exist
    if [ -n "$app_container" ]; then
        docker stop "$app_container" 2>/dev/null || true
    fi
    if [ -n "$db_container" ]; then
        docker stop "$db_container" 2>/dev/null || true
    fi
    
    # Remove volumes if they exist (cleanup)  
    log_msg "Removing existing volumes for clean restore..."
    docker volume rm "$DB_VOLUME" 2>/dev/null || true
    docker volume rm "$UPLOAD_VOLUME" 2>/dev/null || true
    
    # Create new volumes
    log_msg "Creating new volumes..."
    docker volume create "$DB_VOLUME"
    docker volume create "$UPLOAD_VOLUME"
    
    # Create temporary directory in shared backup location for Docker access
    local temp_restore_dir="/backup/temp_restore_$$"
    mkdir -p "$temp_restore_dir"
    
    # Copy backup files to shared location
    if [ -f "$RESTORE_DIR/firefly_db.tar.gz" ]; then
        log_msg "Copying database backup to shared directory..."
        cp "$RESTORE_DIR/firefly_db.tar.gz" "$temp_restore_dir/"
    else
        error "Database backup file not found: $RESTORE_DIR/firefly_db.tar.gz"
    fi
    
    if [ -f "$RESTORE_DIR/firefly_upload.tar.gz" ]; then
        log_msg "Copying upload backup to shared directory..."
        cp "$RESTORE_DIR/firefly_upload.tar.gz" "$temp_restore_dir/"
    else
        warn "Upload backup file not found: $RESTORE_DIR/firefly_upload.tar.gz"
    fi
    
    # Get the host path for the temp directory (container path /backup maps to host path)
    # Since the backup container mounts ./backup:/backup, we need to determine the actual host path
    # Extract the host backup path from docker inspect of our own container
    local backup_mount_info=$(docker inspect $(hostname) | grep -A1 "/backup")
    local host_backup_dir=$(echo "$backup_mount_info" | grep "Source" | cut -d'"' -f4)
    local host_temp_restore_dir="$host_backup_dir/temp_restore_$$"
    
    # Restore database volume
    if [ -f "$temp_restore_dir/firefly_db.tar.gz" ]; then
        log_msg "Restoring database volume..."
        docker run --rm \
            -v "${DB_VOLUME}:/target" \
            -v "$host_temp_restore_dir:/restore_data" \
            ubuntu tar -xzf /restore_data/firefly_db.tar.gz -C /target
        log_msg "Database volume restored"
    else
        error "Database backup file not accessible for Docker: $temp_restore_dir/firefly_db.tar.gz"
    fi
    
    # Restore upload volume
    if [ -f "$temp_restore_dir/firefly_upload.tar.gz" ]; then
        log_msg "Restoring upload volume..."
        docker run --rm \
            -v "${UPLOAD_VOLUME}:/target" \
            -v "$host_temp_restore_dir:/restore_data" \
            ubuntu tar -xzf /restore_data/firefly_upload.tar.gz -C /target
        log_msg "Upload volume restored"
    else
        warn "Upload backup file not accessible for Docker: $temp_restore_dir/firefly_upload.tar.gz"
    fi
    
    # Clean up temporary directory
    rm -rf "$temp_restore_dir"
}

# Function to update configuration
update_config() {
    log_msg "Updating configuration..."
    
    if [ -f "$INSTALL_DIR/.env" ]; then
        # Create backup of original .env
        cp "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.restored"
        
        info "Configuration restored from backup"
        
        # Show current APP_URL
        if grep -q "APP_URL" "$INSTALL_DIR/.env"; then
            current_url=$(grep "APP_URL" "$INSTALL_DIR/.env")
            info "Current APP_URL: $current_url"
        fi
    fi
    
    # Create .db.env file if docker-compose.yml references it and it doesn't exist
    if [ -f "$INSTALL_DIR/docker-compose.yml" ] && grep -q "\.db\.env" "$INSTALL_DIR/docker-compose.yml" ]; then
        if [ ! -f "$INSTALL_DIR/.db.env" ]; then
            log_msg "Creating .db.env file for database configuration..."
            cat > "$INSTALL_DIR/.db.env" << 'EOF'
MYSQL_RANDOM_ROOT_PASSWORD=yes
MYSQL_USER=firefly
MYSQL_PASSWORD=secret_firefly_password
MYSQL_DATABASE=firefly
EOF
            log_msg "Created .db.env file"
        else
            log_msg "Using existing .db.env file"
        fi
    fi
}

# Function to start containers
start_containers() {
    # Restart containers in container mode after restore
    if [ -f "/.dockerenv" ]; then
        log_msg "Running in container mode - restarting containers to load restored data"
        
        # Wait a moment for volumes to be fully ready
        sleep 5
        
        # Restart the main containers (app and db) to load restored data
        # Get container names dynamically
        local app_container=$(docker ps -a --filter "name=app" --format "{{.Names}}" | head -1)
        local db_container=$(docker ps -a --filter "name=db" --format "{{.Names}}" | head -1)
        
        if [ -n "$app_container" ]; then
            log_msg "Restarting Firefly III app container..."
            docker start "$app_container" || warn "Failed to start app container"
        fi
        
        if [ -n "$db_container" ]; then
            log_msg "Restarting Firefly III database container..."
            docker start "$db_container" || warn "Failed to start database container"
        fi
        
        log_msg "Waiting for containers to fully start..."
        sleep 15
        
        log_msg "Container restart completed - Firefly III should now have restored data"
        return 0
    fi
    
    log_msg "Starting Firefly III containers..."
    cd "$INSTALL_DIR"
    
    # Check if docker-compose file exists
    if [ -f "docker-compose.yml" ]; then
        compose_file="docker-compose.yml"
    elif [ -f "docker-compose.yaml" ]; then
        compose_file="docker-compose.yaml"
    else
        warn "No docker-compose file found in $INSTALL_DIR"
        warn "Available files:"
        ls -la "$INSTALL_DIR/"
        warn "Please manually copy the docker-compose file from the backup:"
        warn "Check: $RESTORE_DIR/ for compose files"
        return 1
    fi
    
    log_msg "Using compose file: $compose_file"
    log_msg "Using Docker Compose command: $DOCKER_COMPOSE_CMD"
    
    # Pull latest images
    log_msg "Pulling Docker images..."
    if ! $DOCKER_COMPOSE_CMD pull; then
        warn "Failed to pull images, continuing with existing images..."
    fi
    
    # Start containers
    log_msg "Starting containers..."
    if $DOCKER_COMPOSE_CMD up -d; then
        log_msg "Containers started successfully"
        
        # Wait for containers to be ready
        log_msg "Waiting for containers to start..."
        sleep 30
        
        # Show container status
        $DOCKER_COMPOSE_CMD ps
        return 0
    else
        error "Failed to start containers"
        return 1
    fi
}

# Function to verify installation
verify_installation() {
    log_msg "Verifying installation..."
    
    # Skip verification in container mode
    if [ -f "/.dockerenv" ]; then
        log_msg "Running in container mode - skipping Docker Compose verification"
        info "Restore completed!"
        info "Volume data has been restored successfully"
        info "Containers will use restored data when they restart"
        return 0
    fi
    
    cd "$INSTALL_DIR"
    
    # Check container status
    log_msg "Container status:"
    $DOCKER_COMPOSE_CMD ps
    
    # Check logs for errors
    log_msg "Checking logs for any errors..."
    $DOCKER_COMPOSE_CMD logs --tail=20
    
    info "Restore completed!"
    info "Installation directory: $INSTALL_DIR"
    info "Please check your Firefly III installation by visiting your configured URL"
    info "Configuration backup saved as: $INSTALL_DIR/.env.restored"
}

# Function to cleanup
cleanup() {
    if [ -d "$RESTORE_DIR" ]; then
        warn "Keeping restore directory for reference: $RESTORE_DIR"
        warn "You can delete it manually after verifying the installation"
    fi
}

# Function to show manual completion instructions
show_manual_completion_instructions() {
    echo
    warn "=== MANUAL COMPLETION REQUIRED ==="
    warn "The docker-compose file was not found or copied properly."
    warn "Please complete the setup manually:"
    echo
    info "1. Check what files are in the backup:"
    info "   ls -la $RESTORE_DIR/"
    echo
    info "2. Copy the docker-compose file manually:"
    info "   sudo cp $RESTORE_DIR/docker-compose.yml $NEW_INSTALL_DIR/"
    info "   (Replace with the actual filename you see)"
    echo
    info "3. Create .db.env file if needed:"
    info "   sudo nano $NEW_INSTALL_DIR/.db.env"
    echo
    info "4. Start the containers:"
    info "   cd $NEW_INSTALL_DIR"
    info "   sudo $DOCKER_COMPOSE_CMD up -d"
    echo
    info "5. Check container status:"
    info "   sudo $DOCKER_COMPOSE_CMD ps"
    echo
}

# Function to show post-installation instructions
show_post_install_instructions() {
    echo
    info "=== POST-INSTALLATION CHECKLIST ==="
    info "1. Update APP_URL in .env file if needed"
    info "2. Check firewall settings for port access"
    info "3. Set up SSL/reverse proxy if needed"
    info "4. Verify all data was restored correctly"
    info "5. Test login and functionality"
    info "6. Set up new backup schedule on this machine"
    echo
    info "Configuration files location: $INSTALL_DIR"
    info "To view logs: cd $INSTALL_DIR && $DOCKER_COMPOSE_CMD logs"
    info "To stop: cd $INSTALL_DIR && $DOCKER_COMPOSE_CMD down"
    info "To start: cd $INSTALL_DIR && $DOCKER_COMPOSE_CMD up -d"
}

# Main execution
main() {
    local auto_mode=false
    local volume_only_mode=false
    local input_file=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto|-y|--yes)
                auto_mode=true
                shift
                ;;
            --volume-only)
                volume_only_mode=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                echo "Unknown option $1"
                usage
                ;;
            *)
                # This is the backup file argument
                input_file="$1"
                shift
                ;;
        esac
    done
    
    log_msg "Starting Firefly III restore process..."
    log_msg "Installation directory: $INSTALL_DIR"
    
    # Get the backup file (download from S3 if needed)
    local backup_file=$(get_backup_file "$input_file")
    log_msg "Using backup file: $backup_file"
    
    # Confirm the operation (skip confirmation in automated mode)
    echo -e "${YELLOW}This will restore Firefly III data from backup. Existing data will be replaced.${NC}"
    if [ "$auto_mode" = true ]; then
        # Automatic mode - proceed without confirmation
        log_msg "Running in automatic mode, proceeding with restore"
    elif [ ! -t 0 ]; then
        # Non-interactive mode (stdin not a terminal) - proceed automatically
        log_msg "Non-interactive mode detected, proceeding with restore"
    else
        # Interactive mode - ask for confirmation
        read -p "Are you sure you want to continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_msg "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Trap to ensure cleanup on exit
    trap cleanup EXIT
    
    # Execute restore steps
    check_prerequisites
    extract_backup "$backup_file"
    restore_config
    restore_volumes
    update_config
    
    # Skip container management in volume-only mode
    if [ "$volume_only_mode" = true ]; then
        log_msg "Volume-only mode: Skipping container startup"
        info "Volume restoration completed successfully"
        info "Containers will be started by orchestration service"
    else
        # Try to start containers (normal mode)
        if start_containers; then
            verify_installation
            show_post_install_instructions
        else
            warn "Container startup failed, but data restoration was successful"
            warn "Please check the configuration and try starting manually"
        fi
    fi
    
    log_msg "Restore process completed successfully!"
}

# Run main function
main "$@"
