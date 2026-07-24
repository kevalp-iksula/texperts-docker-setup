#!/usr/bin/env bash
################################################################################
# Run the Adobe Upgrade Compatibility Tool (UCT) against the code mounted in the
# php container, for a chosen target version. Read-only analysis — it never
# changes code or the database; it only writes an HTML + JSON report.
#
#   ./scripts/run-uct.sh [coming-version] [current-version]
#
#   ./scripts/run-uct.sh 2.4.8            # check 2.4.7-p1 -> 2.4.8
#   ./scripts/run-uct.sh 2.4.9            # check 2.4.7-p1 -> 2.4.9
#   ./scripts/run-uct.sh 2.4.8-p5 2.4.7-p1
#
# Reports land in the clone at var/uct-<version>.{html,json} and are copied to
# docker-setup/docs/uct/ so they persist and are easy to share.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

COMING="${1:-2.4.9}"
CURRENT="${2:-2.4.7-p1}"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

# UCT is installed inside the container at /var/www/uct (one-time). If missing,
# install it — needs the EE key from scripts/.composer-auth.json.
if ! docker compose exec -T -u www-data php test -f /var/www/uct/bin/uct 2>/dev/null; then
    echo "${YELLOW}UCT not installed in the container — installing (one-time)...${NC}"
    COMPOSER_AUTH="$(cat scripts/.composer-auth.json)" docker compose exec -T -u www-data \
        -e COMPOSER_AUTH -e COMPOSER_MEMORY_LIMIT=-1 php \
        composer create-project magento/upgrade-compatibility-tool /var/www/uct \
        --repository-url=https://repo.magento.com --ignore-platform-reqs --no-interaction
fi

echo "${GREEN}Running UCT: ${CURRENT} -> ${COMING}${NC} (this takes ~10-15 min)"

# memory_limit 6G: the API-index dictionary for 125 modules exceeds the 2G default.
# COMPOSER_AUTH is passed in case UCT needs to fetch version metadata.
COMPOSER_AUTH="$(cat scripts/.composer-auth.json)" docker compose exec -T -u www-data \
    -e COMPOSER_AUTH -e COMPOSER_MEMORY_LIMIT=-1 php \
    php -d memory_limit=6G /var/www/uct/bin/uct upgrade:check /var/www/magento \
        --current-version="${CURRENT}" \
        --coming-version="${COMING}" \
        --html-output-path="/var/www/magento/var/uct-${COMING}.html" \
        --json-output-path="/var/www/magento/var/uct-${COMING}.json"

# Persist the reports outside the (gitignored, ephemeral) clone var/ dir.
CODE_DIR="$(grep -E '^PROJECT_PATH=' .env | cut -d= -f2-)"
mkdir -p docs/uct
if [[ -f "${CODE_DIR}/var/uct-${COMING}.html" ]]; then
    cp "${CODE_DIR}/var/uct-${COMING}.html" "${CODE_DIR}/var/uct-${COMING}.json" docs/uct/ 2>/dev/null || true
    echo "${GREEN}Reports saved:${NC} docs/uct/uct-${COMING}.html (open in a browser), docs/uct/uct-${COMING}.json"
else
    echo "${RED}Report not found — check the output above for errors.${NC}"
    exit 1
fi
