#!/bin/bash

################################################################################
# Docker Installation Diagnostic Script
# Finds all Docker installations, packages, and configurations
################################################################################

# This script needs real bash: it uses arrays and 'echo -e', and POSIX sh has
# neither. Running it as `sh docker-diagnostic.sh` picks up dash on Debian and
# Ubuntu, which prints "-e" literally, fails on the first array with
# 'Syntax error: "(" unexpected', and — worst of all — silently misparses
# `cmd &> /dev/null` as "run in background", making every `if which ...` test
# succeed and report tools that are not installed.
# Re-exec under bash so the invocation cannot cause that.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Docker Installation Diagnostic Scanner               ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

found_docker=0

# 1. Check Docker in PATH
echo -e "${BLUE}[1] Checking Docker in PATH...${NC}"
if which docker &> /dev/null; then
    docker_path=$(which docker)
    echo -e "${RED}✗ Docker found: $docker_path${NC}"
    found_docker=1
    file "$docker_path"
else
    echo -e "${GREEN}✓ No Docker in PATH${NC}"
fi

# 2. Check Docker Compose in PATH
echo ""
echo -e "${BLUE}[2] Checking Docker Compose in PATH...${NC}"
if which docker-compose &> /dev/null; then
    compose_path=$(which docker-compose)
    echo -e "${RED}✗ Docker Compose found: $compose_path${NC}"
    found_docker=1
    file "$compose_path"
fi

if which docker-buildx &> /dev/null; then
    buildx_path=$(which docker-buildx)
    echo -e "${RED}✗ Docker buildx found: $buildx_path${NC}"
    found_docker=1
fi

# 3. Check common installation paths
echo ""
echo -e "${BLUE}[3] Checking common installation paths...${NC}"
paths_to_check=(
    "/usr/bin/docker"
    "/usr/bin/dockerd"
    "/usr/bin/docker-compose"
    "/usr/local/bin/docker"
    "/usr/local/bin/dockerd"
    "/usr/local/bin/docker-compose"
    "/opt/docker"
    "/opt/docker-desktop"
    "/home/$USER/.docker"
    "/home/$USER/.config/Docker"
)

for path in "${paths_to_check[@]}"; do
    if [[ -e "$path" ]]; then
        echo -e "${RED}✗ Found: $path${NC}"
        ls -lh "$path" 2>/dev/null | head -3
        found_docker=1
    fi
done

# 4. Check apt packages
echo ""
echo -e "${BLUE}[4] Checking apt packages...${NC}"
docker_packages=$(dpkg -l 2>/dev/null | grep -i docker | grep "^ii")
if [[ -n "$docker_packages" ]]; then
    echo -e "${RED}✗ Found Docker packages:${NC}"
    echo "$docker_packages"
    found_docker=1
else
    echo -e "${GREEN}✓ No Docker apt packages installed${NC}"
fi

# 5. Check snap packages
echo ""
echo -e "${BLUE}[5] Checking snap packages...${NC}"
if command -v snap &> /dev/null; then
    snap_docker=$(snap list 2>/dev/null | grep -i docker)
    if [[ -n "$snap_docker" ]]; then
        echo -e "${RED}✗ Found Docker snap:${NC}"
        echo "$snap_docker"
        found_docker=1
    else
        echo -e "${GREEN}✓ No Docker snap packages${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Snap not installed (skipped)${NC}"
fi

# 6. Check systemd services
echo ""
echo -e "${BLUE}[6] Checking systemd Docker services...${NC}"
if systemctl list-unit-files 2>/dev/null | grep -i docker; then
    echo -e "${RED}✗ Found Docker systemd services${NC}"
    found_docker=1
else
    echo -e "${GREEN}✓ No Docker systemd services${NC}"
fi

# 7. Check running Docker processes
echo ""
echo -e "${BLUE}[7] Checking running Docker processes...${NC}"
if ps aux | grep -E '[d]ocker|[d]ockerd|[d]esktop' &> /dev/null; then
    echo -e "${RED}✗ Found running Docker processes:${NC}"
    ps aux | grep -E '[d]ocker|[d]ockerd|[d]esktop' | grep -v grep
    found_docker=1
else
    echo -e "${GREEN}✓ No Docker processes running${NC}"
fi

# 8. Check Docker socket
echo ""
echo -e "${BLUE}[8] Checking Docker sockets...${NC}"
sockets_to_check=(
    "/var/run/docker.sock"
    "/home/$USER/.docker/run/docker.sock"
    "/home/$USER/.docker/desktop/docker.sock"
    "/run/docker.sock"
)

for socket in "${sockets_to_check[@]}"; do
    if [[ -e "$socket" ]]; then
        echo -e "${RED}✗ Found: $socket${NC}"
        ls -lh "$socket"
        found_docker=1
    fi
done

# 9. Check Docker data directory
echo ""
echo -e "${BLUE}[9] Checking Docker data directories...${NC}"
data_dirs=(
    "/var/lib/docker"
    "/var/lib/containerd"
    "/home/$USER/.docker"
)

for dir in "${data_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo -e "${RED}✗ Found: $dir ($size)${NC}"
        found_docker=1
    fi
done

# 10. Check Docker configuration
echo ""
echo -e "${BLUE}[10] Checking Docker configuration files...${NC}"
config_files=(
    "/etc/docker/daemon.json"
    "/etc/docker"
    "/etc/apt/sources.list.d/docker.list"
    "/etc/apt/keyrings/docker.gpg"
)

for file in "${config_files[@]}"; do
    if [[ -e "$file" ]]; then
        echo -e "${RED}✗ Found: $file${NC}"
        found_docker=1
    fi
done

# 11. Check for docker command in bash history or aliases
echo ""
echo -e "${BLUE}[11] Checking bash aliases/functions...${NC}"
if grep -r "docker" ~/.bashrc ~/.bash_aliases 2>/dev/null | grep -E "^[^#].*docker"; then
    echo -e "${YELLOW}⚠ Found docker references in bash config${NC}"
fi

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
if [[ $found_docker -eq 0 ]]; then
    echo -e "${GREEN}║                  Docker is REMOVED ✓                       ║${NC}"
else
    echo -e "${RED}║              Docker is STILL INSTALLED ✗                  ║${NC}"
fi
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ $found_docker -eq 1 ]]; then
    echo "Docker components are still on your system. Run the aggressive removal script."
    exit 1
else
    echo "System is clean! Ready for Phase 1 Docker setup."
    exit 0
fi