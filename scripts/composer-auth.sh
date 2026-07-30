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

# The keys are already written above; verification is a best-effort convenience.
# Skip it entirely with SKIP_VERIFY=1 (useful on a slow/blocked network).
if [[ "${SKIP_VERIFY:-0}" == "1" ]]; then
    echo "${YELLOW}SKIP_VERIFY=1 — not checking the keys against repo.magento.com.${NC}"
    echo "Run 'make composer-validate' later to verify."
elif command -v docker >/dev/null 2>&1 && docker compose ps php 2>/dev/null | grep -q 'Up\|running'; then
    echo "Verifying credentials against repo.magento.com (up to ~25s) ..."
    # --connect-timeout/--max-time keep this from hanging for minutes on a blocked
    # network; curl exits 28 on timeout, 22 on an HTTP >=400 (bad keys, via -f).
    set +e
    docker compose exec -T -u www-data php \
        curl -fsS -o /dev/null --connect-timeout 10 --max-time 25 \
        -u "${PUBLIC_KEY}:${PRIVATE_KEY}" \
        https://repo.magento.com/packages.json 2>/dev/null
    rc=$?
    set -e
    case "$rc" in
        0)  echo "${GREEN}Credentials accepted by repo.magento.com.${NC}" ;;
        22) echo "${RED}repo.magento.com rejected these keys (HTTP error).${NC}"
            echo "Double-check them at commercemarketplace.adobe.com -> My Profile -> Access Keys,"
            echo "then re-run this script. (The file was still written; fix and overwrite.)"
            exit 1 ;;
        *)  # 28 timeout, 6/7 DNS/connect, etc. — not a key problem. Keys are saved.
            echo "${YELLOW}Could not reach repo.magento.com to verify (network unreachable/slow — curl ${rc}).${NC}"
            echo "Your keys were saved. Verify later with 'make composer-validate'." ;;
    esac
else
    echo "${YELLOW}PHP container is not running, so the keys were not verified.${NC}"
    echo "Start the stack with 'make up', then run 'make composer-validate'."
fi
