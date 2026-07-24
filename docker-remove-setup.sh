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
# AGGRESSIVE Docker Complete Removal Script
# Removes Docker from ALL possible locations
# Run as: sudo bash docker-aggressive-removal.sh
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $*"
}

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      AGGRESSIVE Docker Complete Removal - All Sources          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Ask for confirmation
read -r -p "This will completely remove Docker from ALL sources. Continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    log_warn "Removal cancelled"
    exit 0
fi

echo ""
log_info "Starting aggressive Docker removal..."
echo ""

################################################################################
# 1. Stop all Docker services and processes
################################################################################

log_info "Step 1: Stopping Docker services and processes..."

# Stop systemd services
systemctl stop docker 2>/dev/null || true
systemctl stop docker.socket 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true
systemctl stop docker-desktop 2>/dev/null || true

sleep 1

# Kill lingering processes.
# NOTE: never use a bare `pkill -f docker` here — `-f` matches the full command
# line, so it matches this script's own `bash docker-remove-setup.sh` and kills us.
# Match process names only (-x, no -f), and exclude self/parents where -f is needed.
for proc in dockerd containerd containerd-shim containerd-shim-runc-v2 docker-proxy docker-desktop; do
    pkill -9 -x "$proc" 2>/dev/null || true
done

# Desktop helpers need -f (they run via long paths), so exclude this script's own tree
pgrep -f "com.docker" 2>/dev/null | grep -v -w "$$" | xargs -r kill -9 2>/dev/null || true

# Disable services
systemctl disable docker 2>/dev/null || true
systemctl disable docker.socket 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true
systemctl disable docker-desktop 2>/dev/null || true

log_success "Services stopped and disabled"

################################################################################
# 2. Remove apt packages (comprehensive list)
################################################################################

log_info "Step 2: Removing apt packages..."

packages=(
    "docker-desktop"
    "docker-ce"
    "docker-ce-cli"
    "docker-ce-rootless-extras"
    "docker-compose-plugin"
    "containerd.io"
    "docker-scan-plugin"
    "docker-buildx-plugin"
    "docker"
    "docker-engine"
    "docker-io"
    "docker.io"
    "moby-cli"
    "moby-engine"
)

for package in "${packages[@]}"; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*$package"; then
        log_info "  Removing $package..."
        apt-get remove -y --purge "$package" 2>/dev/null || true
    fi
done

log_success "Apt packages removed"

################################################################################
# 3. Remove snap packages
################################################################################

log_info "Step 3: Removing snap packages..."

if command -v snap &> /dev/null; then
    if snap list 2>/dev/null | grep -q docker; then
        log_info "  Removing docker snap..."
        snap remove --purge docker 2>/dev/null || true
    fi
    log_success "Snap packages checked"
else
    log_warn "Snap not installed (skipped)"
fi

################################################################################
# 4. Remove Docker binaries from all locations
################################################################################

log_info "Step 4: Removing Docker binaries..."

binary_locations=(
    "/usr/bin/docker"
    "/usr/bin/dockerd"
    "/usr/bin/docker-compose"
    "/usr/bin/docker-buildx"
    "/usr/bin/docker-scan"
    "/usr/bin/containerd"
    "/usr/bin/ctr"
    "/usr/bin/containerd-shim"
    "/usr/local/bin/docker"
    "/usr/local/bin/dockerd"
    "/usr/local/bin/docker-compose"
    "/opt/docker-desktop/bin/docker"
    "/opt/docker-desktop/bin/dockerd"
)

for binary in "${binary_locations[@]}"; do
    if [[ -e "$binary" ]]; then
        log_info "  Removing $binary..."
        rm -f "$binary"
    fi
done

log_success "Docker binaries removed"

################################################################################
# 5. Remove Docker data directories
################################################################################

log_info "Step 5: Removing Docker data directories..."

data_dirs=(
    "/var/lib/docker"
    "/var/lib/containerd"
    "/var/lib/docker-volume"
    "/opt/docker"
    "/opt/docker-desktop"
    "/opt/docker-cli"
)

for dir in "${data_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
        log_info "  Removing $dir..."
        rm -rf "$dir"
    fi
done

log_success "Docker data directories removed"

################################################################################
# 6. Remove Docker configuration directories
################################################################################

log_info "Step 6: Removing Docker configuration..."

config_dirs=(
    "/etc/docker"
    "/etc/dockerd"
    "/etc/docker-desktop"
    "/etc/apt/sources.list.d/docker.list"
    "/etc/apt/sources.list.d/docker-*.list"
    "/etc/apt/keyrings/docker.gpg"
    "/etc/apt/trusted.gpg.d/docker.gpg"
)

for config in "${config_dirs[@]}"; do
    if [[ -e "$config" ]]; then
        log_info "  Removing $config..."
        rm -rf "$config"
    fi
done

log_success "Docker configuration removed"

################################################################################
# 7. Remove user Docker directories
################################################################################

log_info "Step 7: Removing user Docker directories..."

# Get all users (except system users)
for user_dir in /home/*; do
    if [[ -d "$user_dir" ]]; then
        username=$(basename "$user_dir")
        user_docker_dirs=(
            "$user_dir/.docker"
            "$user_dir/.config/Docker"
            "$user_dir/.config/docker"
        )
        
        for dir in "${user_docker_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                log_info "  Removing $dir..."
                rm -rf "$dir"
            fi
        done
    fi
done

# Root user
if [[ -d "/root/.docker" ]]; then
    rm -rf /root/.docker
fi

log_success "User Docker directories removed"

################################################################################
# 8. Remove Docker sockets
################################################################################

log_info "Step 8: Removing Docker sockets..."

sockets=(
    "/var/run/docker.sock"
    "/var/run/docker.pid"
    "/run/docker.sock"
    "/run/docker.pid"
)

for socket in "${sockets[@]}"; do
    if [[ -e "$socket" ]]; then
        log_info "  Removing $socket..."
        rm -f "$socket"
    fi
done

log_success "Docker sockets removed"

################################################################################
# 9. Remove Docker systemd files
################################################################################

log_info "Step 9: Removing Docker systemd files..."

systemd_files=(
    "/etc/systemd/system/docker.service"
    "/etc/systemd/system/docker.socket"
    "/etc/systemd/system/containerd.service"
    "/etc/systemd/system/docker-desktop.service"
    "/lib/systemd/system/docker.service"
    "/lib/systemd/system/docker.socket"
    "/lib/systemd/system/containerd.service"
)

for file in "${systemd_files[@]}"; do
    if [[ -e "$file" ]]; then
        log_info "  Removing $file..."
        rm -f "$file"
    fi
done

# Reload systemd
systemctl daemon-reload 2>/dev/null || true
log_success "Docker systemd files removed"

################################################################################
# 10. Remove Docker user and group
################################################################################

log_info "Step 10: Removing Docker user and group..."

if id docker &>/dev/null 2>&1; then
    log_info "  Removing docker user..."
    userdel -r docker 2>/dev/null || true
fi

if getent group docker >/dev/null 2>&1; then
    log_info "  Removing docker group..."
    groupdel docker 2>/dev/null || true
fi

log_success "Docker user and group removed"

################################################################################
# 11. Clean package manager
################################################################################

log_info "Step 11: Cleaning package manager cache..."

apt-get update -qq 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get autoclean -y -qq 2>/dev/null || true
apt-get clean -qq 2>/dev/null || true

log_success "Package manager cleaned"

################################################################################
# 12. Verify removal
################################################################################

log_info "Step 12: Verifying Docker removal..."

echo ""
errors=0

# Check binaries
if which docker &>/dev/null; then
    log_error "Docker binary still found: $(which docker)"
    errors=$((errors + 1))
else
    log_success "Docker binary removed"
fi

# Check systemd service
if systemctl list-unit-files 2>/dev/null | grep -q "^docker.service"; then
    log_error "Docker systemd service still exists"
    errors=$((errors + 1))
else
    log_success "Docker systemd services removed"
fi

# Check directories
if [[ -d /var/lib/docker ]]; then
    log_error "/var/lib/docker still exists"
    errors=$((errors + 1))
else
    log_success "/var/lib/docker removed"
fi

if [[ -d /etc/docker ]]; then
    log_error "/etc/docker still exists"
    errors=$((errors + 1))
else
    log_success "/etc/docker removed"
fi

# Check processes. Match on process name only — matching the full command line
# would match this script's own `bash docker-remove-setup.sh` and always fail.
remaining=$(pgrep -x 'dockerd|containerd|docker-proxy|containerd-shim.*' 2>/dev/null || true)
if [[ -n "$remaining" ]]; then
    log_error "Docker processes still running"
    ps -o pid,comm,args -p $remaining 2>/dev/null || true
    errors=$((errors + 1))
else
    log_success "No Docker processes running"
fi

echo ""

################################################################################
# Summary
################################################################################

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"

if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}║       Docker Completely Removed Successfully ✓              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_success "System is clean and ready for Phase 1 Docker setup"
    echo ""
    echo "Next steps:"
    echo "  cd ./docker-setup"
    echo "  chmod +x docker-setup.sh"
    echo "  sudo bash docker-setup.sh"
    echo ""
else
    echo -e "${RED}║         Docker Removal INCOMPLETE - Errors Found ✗           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_error "Found $errors issue(s) during verification"
    echo ""
    echo "Try running again or check manually:"
    echo "  docker --version"
    echo "  which docker"
    echo "  ls -la /var/lib/docker"
    exit 1
fi
