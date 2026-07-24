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
# Composer credential setup for repo.magento.com
#
# Writes scripts/.composer-auth.json (chmod 600, gitignored). The file is
# bind-mounted read-only into the PHP container at runtime and never baked
# into an image layer — so credentials cannot leak via `docker history`
# or a pushed image.
#
# Get your keys: https://commercemarketplace.adobe.com/customer/account/login/
#                -> My Profile -> Access Keys
#   Public key  = Composer username
#   Private key = Composer password
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_FILE="${SCRIPT_DIR}/.composer-auth.json"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

echo "Adobe Commerce Composer authentication setup"
echo "==========================================="
echo

if [[ -s "$AUTH_FILE" ]]; then
    echo "${YELLOW}An auth file already exists at ${AUTH_FILE}${NC}"
    read -rp "Overwrite it? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Left unchanged."; exit 0; }
fi

read -rp "Public key (Composer username): " PUBLIC_KEY
# -s keeps the private key off the terminal and out of scrollback.
read -rsp "Private key (Composer password): " PRIVATE_KEY
echo

if [[ -z "$PUBLIC_KEY" || -z "$PRIVATE_KEY" ]]; then
    echo "${RED}Both keys are required. Nothing written.${NC}" >&2
    exit 1
fi

# Create with restrictive permissions BEFORE writing, so the secret is never
# briefly world-readable between creation and chmod.
umask 077
cat > "$AUTH_FILE" <<EOF
{
    "http-basic": {
        "repo.magento.com": {
            "username": "${PUBLIC_KEY}",
            "password": "${PRIVATE_KEY}"
        }
    }
}
EOF
chmod 600 "$AUTH_FILE"

echo "${GREEN}Wrote ${AUTH_FILE} (mode 600)${NC}"
echo

if command -v docker >/dev/null 2>&1 && docker compose ps php 2>/dev/null | grep -q 'Up\|running'; then
    echo "Verifying credentials against repo.magento.com ..."
    if docker compose exec -T -u www-data php \
        curl -fsS -o /dev/null -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
        https://repo.magento.com/packages.json 2>/dev/null; then
        echo "${GREEN}Credentials accepted by repo.magento.com.${NC}"
    else
        echo "${RED}repo.magento.com rejected these keys, or the network is unreachable.${NC}"
        echo "Double-check the keys at commercemarketplace.adobe.com -> My Profile -> Access Keys."
        exit 1
    fi
else
    echo "${YELLOW}PHP container is not running, so the keys were not verified.${NC}"
    echo "Start the stack with 'make up', then run 'make composer-validate'."
fi
