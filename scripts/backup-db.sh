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
# Dump the Magento database to volumes/backups/ as a timestamped .sql.gz
#
# Usage: ./scripts/backup-db.sh [label]
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${ROOT_DIR}/volumes/backups"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'

cd "$ROOT_DIR"
[[ -f .env ]] || { echo "${RED}.env not found. Run ./init-project.sh first.${NC}" >&2; exit 1; }
# Filter UID/GID: they are readonly in bash, and sourcing them under `set -e`
# aborts the script. docker compose reads them from .env directly; scripts don't.
set -a; . <(grep -vE '^(UID|GID)=' ./.env); set +a

LABEL="${1:-manual}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${BACKUP_DIR}/${MYSQL_DATABASE}_${LABEL}_${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

if ! docker compose ps mysql 2>/dev/null | grep -qE 'Up|running'; then
    echo "${RED}MySQL container is not running. Start it with 'make up'.${NC}" >&2
    exit 1
fi

echo "Dumping ${MYSQL_DATABASE} -> ${OUT}"

# --single-transaction keeps the dump consistent without locking the whole DB.
# MYSQL_PWD passes the password without exposing it in the container's argv.
#
# 'set +e' around the pipeline: with pipefail active, a mysqldump failure would
# otherwise trip set -e and skip the cleanup below, leaving a truncated .gz that
# looks like a valid backup.
set +e
docker compose exec -T \
    -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" \
    mysql \
    mysqldump \
        --user=root \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --default-character-set=utf8mb4 \
        --no-tablespaces \
        "${MYSQL_DATABASE}" \
    | gzip -c > "$OUT"
dump_status="${PIPESTATUS[0]}"
set -e

# mysqldump failing mid-pipe still yields a valid (tiny) gzip, so check the
# real exit status rather than trusting that the file exists.
if [[ "$dump_status" -ne 0 ]]; then
    echo "${RED}mysqldump failed (exit ${dump_status}). Removing incomplete ${OUT}${NC}" >&2
    rm -f "$OUT"
    exit 1
fi

echo "${GREEN}Backup complete: ${OUT} ($(du -h "$OUT" | cut -f1))${NC}"
