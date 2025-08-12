#!/bin/bash

# Firefly III Initialization Script
# Checks for and installs required dependencies: Docker, Docker Compose, AWS CLI, and Git

set -e

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

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release)
    else
        error "Cannot detect operating system"
    fi
    
    log "Detected OS: $OS $VER"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root or with sudo"
    fi
}

# Update package manager
update_packages() {
    log "Updating package manager..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
    elif command -v apk >/dev/null 2>&1; then
        apk update
    else
        warn "Unknown package manager, skipping package update"
    fi
}

# Install Git
install_git() {
    log "Installing Git..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y git
    elif command -v yum >/dev/null 2>&1; then
        yum install -y git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git
    elif command -v apk >/dev/null 2>&1; then
        apk add git
    else
        error "Cannot install Git - unknown package manager"
    fi
    
    log "Git installed successfully"
}

# Install Docker
install_docker() {
    log "Installing Docker..."
    
    if command -v apt-get >/dev/null 2>&1; then
        # Ubuntu/Debian
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo \
          "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v apk >/dev/null 2>&1; then
        # Alpine
        apk add docker docker-compose
        
    else
        error "Cannot install Docker - unknown package manager"
    fi
    
    # Start and enable Docker service
    systemctl start docker || service docker start || true
    systemctl enable docker || chkconfig docker on || true
    
    log "Docker installed successfully"
}

# Install Docker Compose (standalone version as fallback)
install_docker_compose() {
    log "Installing Docker Compose standalone..."
    
    # Get latest version
    local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    
    if [ -z "$compose_version" ]; then
        compose_version="v2.21.0"  # Fallback version
        warn "Could not detect latest Docker Compose version, using fallback: $compose_version"
    fi
    
    # Download and install
    curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # Create symlink for docker compose (v2 style)
    ln -sf /usr/local/bin/docker-compose /usr/local/bin/docker-compose-v1
    
    log "Docker Compose standalone installed successfully"
}

# Install AWS CLI
install_aws_cli() {
    log "Installing AWS CLI..."
    
    # Install dependencies
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y unzip curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y unzip curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip curl
    elif command -v apk >/dev/null 2>&1; then
        apk add unzip curl py3-pip
        # For Alpine, use pip installation
        pip3 install awscli
        log "AWS CLI installed via pip"
        return 0
    fi
    
    # Download and install AWS CLI v2
    local arch=$(uname -m)
    local aws_cli_url=""
    
    if [ "$arch" = "x86_64" ]; then
        aws_cli_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    elif [ "$arch" = "aarch64" ]; then
        aws_cli_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    else
        error "Unsupported architecture: $arch"
    fi
    
    cd /tmp
    curl -L "$aws_cli_url" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
    
    log "AWS CLI installed successfully"
}

# Check if Git is installed
check_git() {
    if command -v git >/dev/null 2>&1; then
        local git_version=$(git --version)
        log "Git is already installed: $git_version"
        return 0
    else
        warn "Git is not installed"
        return 1
    fi
}

# Check if Docker is installed
check_docker() {
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version)
        log "Docker is already installed: $docker_version"
        return 0
    else
        warn "Docker is not installed"
        return 1
    fi
}

# Check if Docker Compose is installed
check_docker_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        local compose_version=$(docker-compose --version)
        log "Docker Compose (standalone) is already installed: $compose_version"
        return 0
    elif docker compose version >/dev/null 2>&1; then
        local compose_version=$(docker compose version)
        log "Docker Compose (plugin) is already installed: $compose_version"
        return 0
    else
        warn "Docker Compose is not installed"
        return 1
    fi
}

# Check if AWS CLI is installed
check_aws_cli() {
    if command -v aws >/dev/null 2>&1; then
        local aws_version=$(aws --version)
        log "AWS CLI is already installed: $aws_version"
        return 0
    else
        warn "AWS CLI is not installed"
        return 1
    fi
}

# Main execution
main() {
    log "Starting Firefly III initialization..."
    
    detect_os
    check_root
    update_packages
    
    # Check and install Git
    if ! check_git; then
        install_git
    fi
    
    # Check and install Docker
    if ! check_docker; then
        install_docker
    fi
    
    # Check and install Docker Compose
    if ! check_docker_compose; then
        install_docker_compose
    fi
    
    # Check and install AWS CLI
    if ! check_aws_cli; then
        install_aws_cli
    fi
    
    log "All dependencies installed successfully!"
    
    # Final verification
    info "=== DEPENDENCY VERIFICATION ==="
    info "Git version: $(git --version)"
    info "Docker version: $(docker --version)"
    
    if command -v docker-compose >/dev/null 2>&1; then
        info "Docker Compose version: $(docker-compose --version)"
    elif docker compose version >/dev/null 2>&1; then
        info "Docker Compose version: $(docker compose version)"
    fi
    
    info "AWS CLI version: $(aws --version)"
    
    info "=== NEXT STEPS ==="
    info "1. Configure AWS CLI: aws configure"
    info "2. Create environment files: .env, .db.env, .s3.env"
    info "3. Create Docker network: docker network create firefly"
    info "4. Start services: docker-compose up -d"
    info "5. Set up cron backup: ./setup-cron.sh"
    
    log "Initialization completed successfully!"
}

main "$@"