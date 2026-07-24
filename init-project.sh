#!/usr/bin/env bash

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
# Adobe Commerce 2.4.9 - project initialisation
#
# Idempotent: safe to re-run. It never overwrites an existing .env without
# asking, and never touches your source code.
#
#   ./init-project.sh
################################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

step()  { echo; echo "${BLUE}==> $*${NC}"; }
ok()    { echo "  ${GREEN}ok${NC}   $*"; }
warn()  { echo "  ${YELLOW}warn${NC} $*"; }
fail()  { echo "  ${RED}fail${NC} $*" >&2; }

echo "############################################################"
echo "#  Adobe Commerce 2.4.9 - development stack initialisation  #"
echo "############################################################"

################################################################################
step "Checking prerequisites"
################################################################################
missing=0

if command -v docker >/dev/null 2>&1; then
    ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
else
    fail "docker not found"; missing=1
fi

if docker compose version >/dev/null 2>&1; then
    ok "docker compose $(docker compose version --short)"
else
    fail "docker compose v2 not found"; missing=1
fi

# Docker must be usable without sudo, or every make target will need it.
if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable as $(whoami)"
else
    fail "cannot talk to the docker daemon as $(whoami)"
    echo "       Try: sudo usermod -aG docker $(whoami) && newgrp docker"
    missing=1
fi

(( missing )) && { echo; fail "Fix the above, then re-run."; exit 1; }

# OpenSearch refuses to start below this; the failure it gives is cryptic.
current_max_map="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
if (( current_max_map < 262144 )); then
    warn "vm.max_map_count is ${current_max_map}; OpenSearch needs >= 262144"
    echo "       Fix now  : sudo sysctl -w vm.max_map_count=262144"
    echo "       Persist  : echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf"
    NEEDS_SYSCTL=1
else
    ok "vm.max_map_count = ${current_max_map}"
    NEEDS_SYSCTL=0
fi

# Measured idle use is ~2.2GB; Composer and di:compile peak well above that.
# Warn rather than block, since page cache is reclaimable.
avail_mb="$(free -m | awk '/^Mem:/{print $7}')"
if (( avail_mb < 3500 )); then
    warn "only ${avail_mb}MB RAM available; the stack idles at ~2200MB and peaks higher"
    echo "       It will still start, but Composer/di:compile may swap."
    echo "       Lower OPENSEARCH_HEAP_SIZE in .env to reclaim ~500MB."
else
    ok "${avail_mb}MB RAM available"
fi

avail_disk="$(df -BG --output=avail . | tail -1 | tr -dc '0-9')"
if (( avail_disk < 20 )); then
    warn "only ${avail_disk}GB free here; images + database want ~20GB"
else
    ok "${avail_disk}GB disk free"
fi

################################################################################
step "Creating directories"
################################################################################
for d in php/8.5 nginx/conf.d nginx/upstream nginx/ssl mysql/init scripts \
         volumes/ac-249/code volumes/backups docs; do
    mkdir -p "$d"
done
touch mysql/init/.gitkeep volumes/backups/.gitkeep nginx/ssl/.gitkeep volumes/ac-249/code/.gitkeep
ok "directory tree present"

################################################################################
step "Configuring .env"
################################################################################
if [[ -f .env ]]; then
    warn ".env already exists; leaving it alone"
    echo "       Delete it first if you want a clean regeneration."
else
    cp .env.example .env

    # Match container www-data to the host user so bind-mounted files written
    # by Composer/Magento stay editable outside the container.
    #
    # 'id -g "$(id -un)"' reads the primary group from passwd rather than the
    # session's current group. Plain 'id -g' would report 'docker' when this is
    # run under newgrp/sg docker — which is exactly what the prerequisite check
    # above tells people to do — and bake the wrong GID into the image.
    host_uid="$(id -u)"
    host_gid="$(id -g "$(id -un)")"
    sed -i "s/^UID=.*/UID=${host_uid}/" .env
    sed -i "s/^GID=.*/GID=${host_gid}/" .env
    ok "mapped container www-data to ${host_uid}:${host_gid}"

    # Generate real passwords rather than shipping the CHANGE_ME placeholders.
    #
    # Read a fixed 512 bytes rather than streaming /dev/urandom into head:
    # an unbounded source whose reader exits early gets SIGPIPE, and with
    # pipefail that kills the script (exit 141). 512 random bytes reliably
    # yields well over the 24 alphanumerics needed.
    gen() { head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24; }

    root_pw="$(gen)"
    app_pw="$(gen)"
    # Magento requires letters AND numbers, 7+ chars, so the shape is forced.
    admin_pw="Admin$(gen | cut -c1-10)1"

    sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${root_pw}|" .env
    sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${app_pw}|" .env
    sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${admin_pw}|" .env

    ok ".env created with generated passwords"
fi

# .env holds database credentials; keep it owner-only.
chmod 600 .env
ok ".env permissions set to 600"

################################################################################
step "Setting file permissions"
################################################################################
chmod +x init-project.sh 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true
chmod +x php/docker-entrypoint.sh 2>/dev/null || true
ok "scripts are executable"

if [[ -f scripts/.composer-auth.json ]]; then
    chmod 600 scripts/.composer-auth.json
    ok "composer auth file secured (600)"
else
    # Compose bind-mounts this path. If it does not exist, Docker would create
    # a DIRECTORY there and the PHP container would fail in a confusing way.
    echo '{}' > scripts/.composer-auth.json
    chmod 600 scripts/.composer-auth.json
    warn "no Composer credentials yet; created an empty placeholder"
    echo "       Run ./scripts/composer-auth.sh before installing Magento."
fi

################################################################################
step "Checking host ports"
################################################################################
if ./scripts/port-check.sh >/dev/null 2>&1; then
    ok "all required ports are free"
else
    warn "one or more ports are in use"
    ./scripts/port-check.sh || true
    echo "       Change the port in .env, or stop whatever holds it."
fi

################################################################################
step "Validating the compose file"
################################################################################
if docker compose config >/dev/null 2>&1; then
    ok "docker-compose.yml is valid"
else
    fail "docker-compose.yml did not validate:"
    docker compose config 2>&1 | sed 's/^/       /' | head -20
    exit 1
fi

################################################################################
echo
echo "############################################################"
echo "${GREEN}#  Initialisation complete                                 #${NC}"
echo "############################################################"
echo
echo "Configured for Adobe Commerce 2.4.9:"
echo "  PHP 8.5 | Nginx | MySQL 8.4 | OpenSearch 3.x | Valkey 8"
echo
echo "Next steps:"
n=1
if (( NEEDS_SYSCTL )); then
    echo "  ${n}. ${YELLOW}sudo sysctl -w vm.max_map_count=262144${NC}   (OpenSearch will not start without this)"
    n=$((n+1))
fi
echo "  ${n}. ./scripts/composer-auth.sh    # Adobe Commerce access keys"; n=$((n+1))
echo "  ${n}. make build                    # build images (first run: 5-10 min)"; n=$((n+1))
echo "  ${n}. make up                       # start the stack"; n=$((n+1))
echo "  ${n}. make status                   # wait for all services healthy"; n=$((n+1))
echo "  ${n}. curl http://localhost:$(grep -E '^NGINX_PORT=' .env | cut -d= -f2-)/health"
echo
echo "Then follow docs/PHASE_3_PLAN.md to install Magento."
echo
echo "${YELLOW}Generated credentials are in .env (mode 600). Passwords were randomised;${NC}"
echo "${YELLOW}read them with: grep PASSWORD .env${NC}"
echo
