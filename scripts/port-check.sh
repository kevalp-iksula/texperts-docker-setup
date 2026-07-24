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
# Verify the host ports this stack needs are free before starting it.
# A busy port otherwise shows up as an opaque "bind: address already in use".
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

# Read a port from .env when present, else fall back to the compose default.
get() {
    local key="$1" default="$2" val=""
    if [[ -f "$ENV_FILE" ]]; then
        val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d "\"'" | tr -d '[:space:]' || true)"
    fi
    echo "${val:-$default}"
}

# Parallel indexed arrays, not an associative array: the port is the value here,
# not a key, so two services configured to the same port still both get reported
# instead of one silently overwriting the other.
names=("Nginx (web)" "MySQL 8.4" "OpenSearch 3.x" "Valkey 8")
ports=(
    "$(get NGINX_PORT 8080)"
    "$(get MYSQL_PORT 3307)"
    "$(get OPENSEARCH_PORT 9201)"
    "$(get VALKEY_PORT 6380)"
)

# Ports this project already publishes. Without this, re-running the check on a
# healthy running stack reports every port BUSY and looks like a conflict, when
# in fact the holder is us. Empty when the stack is down or docker is
# unreachable, which is the correct fallback.
mine=" $(cd "${SCRIPT_DIR}/.." && docker compose ps --format '{{range .Publishers}}{{.PublishedPort}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -v '^0$' | sort -un | tr '\n' ' ') "

echo "Checking host port availability"
echo "==============================="

fail=0
ours=0
for i in "${!ports[@]}"; do
    port="${ports[$i]}"
    label="${names[$i]}"

    if ! ss -ltn "sport = :${port}" 2>/dev/null | tail -n +2 | grep -q .; then
        printf '%bFREE%b  %-6s %s\n' "$GREEN" "$NC" "$port" "$label"
    elif [[ "$mine" == *" ${port} "* ]]; then
        printf '%bUSED%b  %-6s %-16s already published by this stack\n' "$YELLOW" "$NC" "$port" "$label"
        ours=1
    else
        # ss only reveals the process name when it belongs to you or you are
        # root; docker-proxy runs as root, hence the fallback text.
        holder="$(ss -ltnp "sport = :${port}" 2>/dev/null | tail -n +2 | head -1 | grep -oP 'users:\(\("\K[^"]+' || true)"
        printf '%bBUSY%b  %-6s %-16s held by: %s\n' "$RED" "$NC" "$port" "$label" "${holder:-another process (run with sudo to see which)}"
        fail=1
    fi
done

# A port used twice in .env fails at 'docker compose up' with a confusing error,
# so catch it here instead.
dupes="$(printf '%s\n' "${ports[@]}" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
    echo
    echo "${RED}Two services are configured on the same port:${NC} ${dupes//$'\n'/ }"
    echo "Give each its own port in .env."
    fail=1
fi

echo
if (( fail )); then
    echo "${YELLOW}Not all ports are available.${NC}"
    echo "Stop whatever holds them, or change the port in .env and re-run."
    exit 1
fi

if (( ours )); then
    echo "${GREEN}No conflicts. Some ports are held by this stack, which is already running.${NC}"
else
    echo "${GREEN}All required ports are free.${NC}"
fi
