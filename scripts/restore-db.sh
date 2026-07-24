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
# Restore a Magento database dump into the running MySQL container.
#
# Usage: ./scripts/restore-db.sh <file.sql|file.sql.gz>
#
# THIS DROPS AND RECREATES THE TARGET DATABASE. It asks first unless FORCE=1.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

cd "$ROOT_DIR"
[[ -f .env ]] || { echo "${RED}.env not found. Run ./init-project.sh first.${NC}" >&2; exit 1; }
# Filter UID/GID: they are readonly in bash, and sourcing them under `set -e`
# aborts the script. docker compose reads them from .env directly; scripts don't.
set -a; . <(grep -vE '^(UID|GID)=' ./.env); set +a

DUMP="${1:-${DB_IMPORT_FILE:-}}"

if [[ -z "$DUMP" ]]; then
    echo "Usage: $0 <file.sql|file.sql.gz>" >&2
    echo "Available dumps in volumes/backups/:" >&2
    ls -1sh volumes/backups/*.sql* 2>/dev/null || echo "  (none)" >&2
    exit 1
fi

[[ -f "$DUMP" ]] || { echo "${RED}No such file: ${DUMP}${NC}" >&2; exit 1; }

if ! docker compose ps mysql 2>/dev/null | grep -qE 'Up|running'; then
    echo "${RED}MySQL container is not running. Start it with 'make up'.${NC}" >&2
    exit 1
fi

echo "${YELLOW}About to DROP and recreate database '${MYSQL_DATABASE}'${NC}"
echo "  restoring from: ${DUMP} ($(du -h "$DUMP" | cut -f1))"
echo "${YELLOW}Everything currently in that database will be lost.${NC}"
echo

if [[ "${FORCE:-0}" != "1" ]]; then
    read -rp "Type the database name to confirm: " confirm
    if [[ "$confirm" != "$MYSQL_DATABASE" ]]; then
        echo "Did not match. Aborted; nothing was changed."
        exit 1
    fi
fi

# Take a safety dump first, but only if the DB has tables worth keeping.
existing="$(docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -u root -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';" 2>/dev/null | tr -d '\r' || echo 0)"

if [[ "${existing:-0}" -gt 0 ]]; then
    echo "Existing database has ${existing} tables. Taking a safety backup first..."
    "${SCRIPT_DIR}/backup-db.sh" "pre-restore"
fi

echo "Recreating schema..."
docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -u root -e \
    "DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
     CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
     GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
     FLUSH PRIVILEGES;"

echo "Importing (this can take several minutes for a large catalog)..."

# Decompress on the host and stream in, so the dump never needs to be copied
# into the container.
if [[ "$DUMP" == *.gz ]]; then
    reader=(gzip -dc "$DUMP")
else
    reader=(cat "$DUMP")
fi

# Strip DEFINER=`user`@`host` clauses by default. Cross-environment dumps (e.g. a
# prod/Cloud export) carry definers for DB users that do not exist locally, which
# makes every view/trigger/routine throw "definer does not exist" at runtime.
# Removing them recreates each object owned by the importing user (root).
# Opt out with STRIP_DEFINERS=0 if you deliberately want the original definers.
if [[ "${STRIP_DEFINERS:-1}" == "1" ]]; then
    definer_filter=(sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g')
    echo "  (stripping DEFINER clauses; set STRIP_DEFINERS=0 to keep them)"
else
    definer_filter=(cat)
fi

set +e
"${reader[@]}" | "${definer_filter[@]}" | docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -u root --default-character-set=utf8mb4 "${MYSQL_DATABASE}"
import_status="${PIPESTATUS[2]}"
set -e

if [[ "$import_status" -ne 0 ]]; then
    echo "${RED}Import failed (exit ${import_status}).${NC}" >&2
    echo "The pre-restore safety backup, if one was taken, is in volumes/backups/." >&2
    exit 1
fi

tables="$(docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -u root -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';" | tr -d '\r')"

echo "${GREEN}Restore complete: ${tables} tables in ${MYSQL_DATABASE}.${NC}"
echo
echo "Next steps for a restored Magento database:"
echo "  make magento-cmd CMD='setup:upgrade'"
echo "  make magento-cmd CMD='config:set web/unsecure/base_url http://localhost:${NGINX_PORT:-8080}/'"
echo "  make magento-cmd CMD='config:set web/secure/base_url http://localhost:${NGINX_PORT:-8080}/'"
echo "  make flush"
