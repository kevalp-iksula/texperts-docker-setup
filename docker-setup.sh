#!/bin/bash

# Requires real bash: this script uses some combination of arrays, [[ ]], and
# `set -o pipefail`, none of which POSIX sh provides. On Debian and Ubuntu
# /bin/sh is dash, so invoking this as `sh <script>` fails in confusing ways
# ("Illegal option -o pipefail", a literal "-e" in the output, or
# `Syntax error: "(" unexpected`). Worse, dash misreads `cmd &> /dev/null` as
# "run in background", which makes `if which ...` tests always succeed.
# Re-exec under bash so how it is invoked cannot matter.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

################################################################################
# Docker Setup Script for Adobe Commerce 2.4.9 on Ubuntu
# Idempotent, version-aware, and safe to rerun
# 
# Usage: bash docker-setup.sh [--check-only] [--verbose]
#
# Installs Docker Engine only. Docker Desktop is intentionally not supported:
# it is not in any apt repository (manual .deb only), and on Linux it runs
# containers inside a VM, which makes bind-mounting large Magento source trees
# significantly slower than native Docker Engine.
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIREMENTS_FILE="${SCRIPT_DIR}/docker-requirements.json"
LOG_FILE="/tmp/docker-setup-$(date +%s).log"
VERBOSE=false
CHECK_ONLY=false

# Minimum versions (Adobe Commerce 2.4.9)
MIN_DOCKER_VERSION="20.10.0"
MIN_COMPOSE_VERSION="2.0.0"
MIN_UBUNTU_VERSION="20.04"

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" | tee -a "$LOG_FILE"
    fi
}

# Parse semantic versions for comparison
# Returns 0 if $1 >= $2, 1 otherwise
version_ge() {
    local version1="$1"
    local version2="$2"
    
    # Remove leading 'v' if present
    version1="${version1#v}"
    version2="${version2#v}"
    
    # Use sort -V for version comparison
    if [[ "$(printf '%s\n' "$version2" "$version1" | sort -V | head -n1)" == "$version2" ]]; then
        return 0
    else
        return 1
    fi
}

# Detect Ubuntu version
detect_ubuntu_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS. /etc/os-release not found."
        return 1
    fi
    
    . /etc/os-release
    echo "$VERSION_ID"
}

# Check if running with sudo/root
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo."
        return 1
    fi
}

# Set up download.docker.com apt repo. This carries docker-ce / docker-ce-cli /
# containerd.io / the plugins. It does NOT carry docker-desktop and never has —
# no `apt install docker-desktop` will ever work from it.
setup_docker_apt_repo() {
    log_info "Setting up Docker apt repository..."

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    log_debug "Docker apt repository configured"
}

################################################################################
# Docker Engine Installation
################################################################################

is_docker_installed() {
    command -v docker &> /dev/null
}

get_docker_version() {
    docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown"
}

install_docker_engine() {
    log_info "Installing Docker Engine..."

    setup_docker_apt_repo

    # Install Docker and related tools
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Verify installation
    if is_docker_installed; then
        log_success "Docker Engine installed successfully"
        return 0
    else
        log_error "Docker installation failed"
        return 1
    fi
}

upgrade_docker() {
    log_info "Upgrading Docker Engine to latest stable version..."
    apt-get update -qq
    apt-get upgrade -y -qq docker-ce docker-ce-cli docker-compose-plugin
    log_success "Docker upgraded successfully"
}

check_docker_version() {
    local current_version
    current_version=$(get_docker_version)
    
    log_info "Checking Docker version..."
    log_debug "Current Docker version: $current_version"
    
    if [[ "$current_version" == "unknown" ]]; then
        log_error "Could not determine Docker version"
        return 1
    fi
    
    if version_ge "$current_version" "$MIN_DOCKER_VERSION"; then
        log_success "Docker version $current_version (>= $MIN_DOCKER_VERSION)"
        return 0
    else
        log_warn "Docker version $current_version is below recommended $MIN_DOCKER_VERSION"
        if [[ "$CHECK_ONLY" == "false" ]]; then
            upgrade_docker
        fi
        return 0
    fi
}

start_docker_service() {
    log_info "Ensuring Docker service is started..."
    
    if systemctl is-active --quiet docker; then
        log_success "Docker service is running"
        return 0
    else
        log_info "Starting Docker service..."
        systemctl start docker
        if systemctl is-active --quiet docker; then
            log_success "Docker service started"
            return 0
        else
            log_error "Failed to start Docker service"
            return 1
        fi
    fi
}

enable_docker_service() {
    log_info "Enabling Docker service on boot..."
    systemctl enable docker
    log_success "Docker service enabled on boot"
}

################################################################################
# System Checks
################################################################################

check_ubuntu_version() {
    log_info "Checking Ubuntu version..."
    local ubuntu_version
    ubuntu_version=$(detect_ubuntu_version)
    
    if version_ge "$ubuntu_version" "$MIN_UBUNTU_VERSION"; then
        log_success "Ubuntu $ubuntu_version detected (>= $MIN_UBUNTU_VERSION)"
        return 0
    else
        log_error "Ubuntu version $ubuntu_version is not supported. Minimum: $MIN_UBUNTU_VERSION"
        return 1
    fi
}

check_system_resources() {
    log_info "Checking system resources..."
    
    # Check RAM (minimum 4GB recommended)
    local ram_gb
    ram_gb=$(free -g | awk 'NR==2 {print $2}')
    
    if [[ $ram_gb -ge 4 ]]; then
        log_success "Available RAM: ${ram_gb}GB (sufficient)"
    else
        log_warn "Available RAM: ${ram_gb}GB (recommended: 4GB or more)"
    fi
    
    # Check disk space (minimum 20GB for AC + dependencies)
    local disk_gb
    disk_gb=$(df / | awk 'NR==2 {print $4/1024/1024}' | cut -d. -f1)
    
    if [[ $disk_gb -ge 20 ]]; then
        log_success "Available disk space: ${disk_gb}GB (sufficient)"
    else
        log_warn "Available disk space: ${disk_gb}GB (recommended: 20GB or more)"
    fi
}

################################################################################
# Docker Compose Detection and Installation
################################################################################

is_docker_compose_installed() {
    docker compose version &> /dev/null
}

get_docker_compose_version() {
    docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown"
}

check_docker_compose_version() {
    local current_version
    current_version=$(get_docker_compose_version)
    
    log_info "Checking Docker Compose version..."
    log_debug "Current Docker Compose version: $current_version"
    
    if [[ "$current_version" == "unknown" ]]; then
        log_error "Docker Compose V2 plugin not found. Installing..."
        if [[ "$CHECK_ONLY" == "false" ]]; then
            apt-get install -y -qq docker-compose-plugin
        fi
        return 0
    fi
    
    if version_ge "$current_version" "$MIN_COMPOSE_VERSION"; then
        log_success "Docker Compose version $current_version (>= $MIN_COMPOSE_VERSION)"
        return 0
    else
        log_warn "Docker Compose version $current_version is below recommended $MIN_COMPOSE_VERSION"
    fi
}

################################################################################
# Docker Daemon Configuration
################################################################################

configure_docker_daemon() {
    log_info "Configuring Docker daemon..."
    
    local daemon_config="/etc/docker/daemon.json"
    
    # Backup existing config
    if [[ -f "$daemon_config" ]]; then
        cp "$daemon_config" "${daemon_config}.backup.$(date +%s)"
        log_debug "Backed up existing daemon.json"
    fi
    
    # Create or update daemon.json with optimal settings for development
    cat > "$daemon_config" << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EOF
    
    log_debug "Docker daemon configuration updated"
    
    # Restart Docker to apply config
    systemctl restart docker
    sleep 2
    
    if systemctl is-active --quiet docker; then
        log_success "Docker daemon configured and restarted"
        return 0
    else
        log_error "Failed to restart Docker after configuration change"
        # Restore backup if restart failed
        if [[ -f "${daemon_config}.backup" ]]; then
            cp "${daemon_config}.backup" "$daemon_config"
            systemctl restart docker
        fi
        return 1
    fi
}

################################################################################
# Non-root User Configuration (Optional)
################################################################################

configure_docker_user_group() {
    log_info "Configuring docker group for current user..."
    
    # Create docker group if it doesn't exist
    if ! getent group docker > /dev/null; then
        groupadd docker
        log_debug "Created docker group"
    fi
    
    # Add current user to docker group (if running with sudo)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_success "Added $SUDO_USER to docker group"
        log_warn "User must log out and back in for group changes to take effect"
    fi
}

################################################################################
# Validation
################################################################################

validate_docker_installation() {
    log_info "Validating Docker installation..."
    
    local errors=0
    
    # Test docker info
    if docker info > /dev/null 2>&1; then
        log_success "Docker daemon is accessible"
    else
        log_error "Cannot access Docker daemon"
        errors=$((errors + 1))
    fi
    
    # Test docker run
    if docker run --rm hello-world > /dev/null 2>&1; then
        log_success "Docker can run containers"
    else
        log_error "Docker cannot run containers"
        errors=$((errors + 1))
    fi
    
    # Test docker compose
    if docker compose version > /dev/null 2>&1; then
        log_success "Docker Compose is functional"
    else
        log_error "Docker Compose is not functional"
        errors=$((errors + 1))
    fi
    
    return $errors
}

################################################################################
# Main Execution Flow
################################################################################

main() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         Docker Setup for Adobe Commerce 2.4.9 on Ubuntu        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    log_info "Log file: $LOG_FILE"
    log_info "Verbose mode: $VERBOSE"
    log_info "Check-only mode: $CHECK_ONLY"
    
    # Check prerequisites
    if ! check_sudo; then
        log_error "Setup aborted."
        exit 1
    fi
    
    if ! check_ubuntu_version; then
        log_error "Setup aborted."
        exit 1
    fi
    
    check_system_resources

    # Docker installation/upgrade flow
    if is_docker_installed; then
        log_info "Docker is already installed"
        if ! check_docker_version; then
            exit 1
        fi
    else
        if [[ "$CHECK_ONLY" == "false" ]]; then
            if ! install_docker_engine; then
                exit 1
            fi
        else
            log_warn "Docker is not installed (--check-only mode, skipping installation)"
        fi
    fi
    
    # Docker Compose installation/upgrade flow
    if is_docker_compose_installed; then
        log_info "Docker Compose V2 is already installed"
        if ! check_docker_compose_version; then
            exit 1
        fi
    else
        if [[ "$CHECK_ONLY" == "false" ]]; then
            if ! check_docker_compose_version; then
                exit 1
            fi
        else
            log_warn "Docker Compose V2 is not installed (--check-only mode, skipping installation)"
        fi
    fi
    
    # Service configuration
    if [[ "$CHECK_ONLY" == "false" ]]; then
        if ! start_docker_service; then
            exit 1
        fi
        enable_docker_service
        
        if ! configure_docker_daemon; then
            exit 1
        fi
        
        configure_docker_user_group
    fi
    
    # Validation
    if ! validate_docker_installation; then
        log_error "Docker validation failed. See log: $LOG_FILE"
        exit 1
    fi
    
    # Summary
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Docker Setup Completed Successfully                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    log_success "Docker version: $(get_docker_version)"
    log_success "Docker Compose version: $(get_docker_compose_version)"
    log_info "Next: Review this output and run 'docker ps' to verify connectivity"
    log_info "Then proceed to Phase 2: Adobe Commerce 2.4.9 Development Stack"
    log_info "Log file saved to: $LOG_FILE"
    
    echo ""
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-only)
                CHECK_ONLY=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --skip-desktop)
                # Deprecated no-op: this script is Engine-only, so there is no
                # Desktop step to skip. Accepted so existing documented commands
                # and shell history keep working instead of hard-failing.
                log_warn "--skip-desktop is deprecated and has no effect (Docker Engine is always installed)"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
Usage: bash docker-setup.sh [OPTIONS]

Installs Docker Engine, Docker Compose V2 and the buildx plugin from Docker's
official apt repository, then configures the daemon for Adobe Commerce 2.4.9.

Docker Desktop is not supported: it is not available from any apt repository
(manual .deb download only), and on Linux it runs containers inside a VM, which
makes bind-mounting large Magento source trees slower than native Engine.

Options:
  --check-only       Only check requirements without installing or upgrading
  --verbose          Enable verbose output for debugging
  --skip-desktop     Deprecated, no effect (kept for backwards compatibility)
  --help             Show this help message

Examples:
  bash docker-setup.sh                           # Full setup
  bash docker-setup.sh --check-only              # Check current state only
  bash docker-setup.sh --verbose                 # Setup with detailed output
  bash docker-setup.sh --check-only --verbose    # Check with detailed output
EOF
}

################################################################################
# Entry Point
################################################################################

parse_arguments "$@"
main
