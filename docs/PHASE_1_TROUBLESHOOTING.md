# Phase 1 Troubleshooting Guide - Adobe Commerce 2.4.9

## Common Issues and Solutions

### 1. Script Requires Root/Sudo

**Error**: "This script must be run as root or with sudo."

**Solution**:

```bash
sudo bash docker-setup.sh
```

### 2. Ubuntu Version Not Detected

**Error**: "Cannot determine OS. /etc/os-release not found."

**Solution**:

```bash
cat /etc/os-release
# If file doesn't exist, your Ubuntu installation may be corrupted
# Try: lsb_release -a
```

### 3. Docker Desktop Installation Prompt

**Prompt**: "Do you want to install Docker Desktop for Ubuntu?"

**What to choose**:

- **Yes**: Install Docker Desktop (GUI-based, includes Docker Engine + Compose)
  - Best for: Developers who prefer a GUI, need container visualization
  - Trade-off: Larger resource footprint
- **No**: Use Docker Engine CLI only (lighter weight)
  - Best for: Server environments, resource-constrained systems
  - Trade-off: No GUI, CLI-only management

**To skip prompt in future runs**:

```bash
sudo bash docker-setup.sh --skip-desktop
```

### 4. Docker Installation Fails (Network)

**Error**: "Failed to connect to download.docker.com"

**Solutions**:

- Verify internet connectivity: `ping 8.8.8.8`
- Check proxy settings if behind corporate firewall
- Try manual installation: https://docs.docker.com/engine/install/ubuntu/

### 5. Docker Daemon Won't Start

**Error**: "Failed to start Docker service"

**Diagnostic**:

```bash
sudo systemctl status docker
sudo journalctl -u docker --no-pager | tail -20
```

**Common Causes**:

- Existing Docker installation conflict
- Cgroups2 compatibility issues on older systems
- Port 2375 already in use

**Solution**:

```bash
# Uninstall conflicting packages
sudo apt-get remove -y docker docker-engine docker.io containerd runc

# Then rerun setup
sudo bash docker-setup.sh --skip-desktop
```

### 6. Docker Compose Not Found

**Error**: "command not found: docker compose"

**Verify installation**:

```bash
docker compose version
docker --version
```

**Solution** (if missing):

```bash
sudo apt-get install -y docker-compose-plugin
```

### 7. "Permission Denied" When Running Docker

**Error**: "Got permission denied while trying to connect to the Docker daemon"

**Solutions**:

Option 1 (Temporary - current session only):

```bash
sudo -s  # Run as root
docker ps  # Test
```

Option 2 (Persistent - recommended after setup):

```bash
sudo usermod -aG docker $USER
# Log out and back in for changes to take effect
newgrp docker
docker ps  # Test
```

### 8. Hello-world Container Test Fails

**Error**: "docker run --rm hello-world" fails

**Diagnostic**:

```bash
sudo docker run --rm hello-world
sudo docker info
sudo systemctl restart docker
```

**Solution**:

- Restart Docker: `sudo systemctl restart docker`
- Check disk space: `df -h`
- Check daemon logs: `sudo journalctl -u docker -n 50`

### 9. Insufficient Disk Space

**Error**: "no space left on device"

**Check disk usage**:

```bash
df -h /
du -sh ~/.docker/
```

**Solutions**:

- Clean up Docker images/containers:

```bash
  docker system prune -a --volumes
```

- Increase disk space allocation
- Move Docker data directory (advanced):

```bash
  sudo systemctl stop docker
  sudo rsync -av /var/lib/docker/ /new/path/docker/
  # Update /etc/docker/daemon.json with "data-root": "/new/path/docker"
  sudo systemctl start docker
```

### 10. Script Hangs During Installation

**Cause**: Large package downloads on slow connection

**Solution**:

- Be patient; first install takes 10-15 minutes
- Run with `--verbose` flag to monitor progress:

```bash
  sudo bash docker-setup.sh --verbose
```

- Check connection: `ping download.docker.com`

### 11. Daemon Configuration Issues

**Error**: "Failed to restart Docker after configuration change"

**Diagnostic**:

```bash
sudo cat /etc/docker/daemon.json
sudo docker info | grep "storage-driver"
```

**Manual fix**:

```bash
# Reset to defaults
sudo rm /etc/docker/daemon.json
sudo systemctl restart docker
# Rerun setup
sudo bash docker-setup.sh
```

### 12. Docker Desktop Uninstall Issues

**Issue**: Need to switch from Desktop to Engine or vice versa

**To uninstall Docker Desktop and use Engine only**:

```bash
# Remove Docker Desktop package
sudo apt-get remove -y docker-desktop

# Reinstall Docker Engine
sudo bash docker-setup.sh --skip-desktop
```

---

## Verification Checklist

After running the script, verify all components:

```bash
# 1. Docker version (should be >= 20.10.0)
docker --version

# 2. Docker Compose version (should be >= 2.0.0)
docker compose version

# 3. Docker daemon is running
sudo systemctl is-active docker

# 4. User can access Docker
docker ps

# 5. Hello-world test
docker run --rm hello-world

# 6. Verify daemon config (should show overlay2 storage driver)
sudo cat /etc/docker/daemon.json | jq .

# 7. Check system resources
free -h
df -h /

# 8. Verify AC 2.4.9 compatibility
cat docker-requirements.json | jq '.adobe_commerce_2_4_9'
```

**All checks should pass before proceeding to Phase 2.**

---

## System Requirements for Adobe Commerce 2.4.9

Verify your system meets these requirements:

| Software       | Required Version | Status                |
| -------------- | ---------------- | --------------------- |
| PHP            | 8.5              | Check in Phase 2      |
| Nginx          | 1.30             | Check in Phase 2      |
| MySQL          | 8.4              | Check in Phase 2      |
| OpenSearch     | 3                | Check in Phase 2      |
| Docker Engine  | 20.10+           | ✓ Verified in Phase 1 |
| Docker Compose | 2.0+             | ✓ Verified in Phase 1 |
| Ubuntu         | 20.04+           | ✓ Verified in Phase 1 |

---

## Rollback / Recovery

If setup causes issues, recover as follows:

### Rollback to Previous Docker Version

```bash
# 1. Stop Docker
sudo systemctl stop docker

# 2. Uninstall
sudo apt-get remove -y docker-ce docker-ce-cli

# 3. Restore backup daemon.json if it exists
sudo cp /etc/docker/daemon.json.backup /etc/docker/daemon.json

# 4. Reinstall with previous version or defaults
sudo apt-get install -y docker-ce=<PREVIOUS_VERSION>
sudo systemctl start docker
```

### Remove All Docker Data (Clean Slate)

**WARNING**: This deletes all images, containers, and volumes.

```bash
sudo systemctl stop docker
sudo rm -rf /var/lib/docker
sudo rm -rf /etc/docker/daemon.json
sudo systemctl start docker
sudo bash docker-setup.sh --skip-desktop
```

### Switch from Docker Desktop to Engine

```bash
sudo apt-get remove -y docker-desktop
sudo bash docker-setup.sh --skip-desktop
```

---

## Support

For more information:

- Docker installation docs: https://docs.docker.com/engine/install/ubuntu/
- Docker Desktop for Linux: https://docs.docker.com/desktop/install/linux-install/
- Docker daemon config: https://docs.docker.com/config/daemon/
- Adobe Commerce 2.4.9 requirements: https://experienceleague.adobe.com/en/docs/commerce-operations/installation-guide/system-requirements
- Ubuntu/Systemd: https://man.ubuntu.com/
