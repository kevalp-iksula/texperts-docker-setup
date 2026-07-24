#!/usr/bin/env bash
################################################################################
# Generate (or patch) the container app/etc/env.php for the Magento code that
# this stack bind-mounts. Removes the one manual, error-prone onboarding step.
#
#   ./scripts/gen-env-php.sh
#
# - DB creds, project path, base URL, DB name come from .env.
# - The container service hosts are fixed: db=mysql, search=opensearch.
# - You are prompted for the Magento **crypt key** — the one true external secret.
#   It MUST match the key that encrypted the DB dump you import, or saved data
#   (payment tokens, OAuth, etc.) will not decrypt. Get it from a teammate / the
#   Cloud env's app/etc/env.php.
#
# Two modes, chosen automatically:
#   * env.php EXISTS  -> PATCH it (rewrite db/search hosts + creds; keep the rest,
#     including the existing crypt key and admin frontName).
#   * env.php MISSING -> GENERATE a minimal, valid env.php.
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

[[ -f .env ]] || { echo "${RED}.env not found. Run ./init-project.sh first.${NC}" >&2; exit 1; }
# Filter UID/GID: readonly in bash, abort sourcing under set -e.
set -a; . <(grep -vE '^(UID|GID)=' ./.env); set +a

# --- resolve the target Magento dir + env.php path -------------------------------------------------
PROJECT_PATH="${PROJECT_PATH:?PROJECT_PATH must be set in .env}"
case "$PROJECT_PATH" in
    /*) CODE_DIR="$PROJECT_PATH" ;;                 # absolute
    *)  CODE_DIR="$(cd "$PROJECT_PATH" && pwd)" ;;  # relative to docker-setup/
esac
[[ -d "$CODE_DIR/app/etc" ]] || { echo "${RED}$CODE_DIR/app/etc not found — is PROJECT_PATH a Magento checkout?${NC}" >&2; exit 1; }
ENV_FILE="$CODE_DIR/app/etc/env.php"

# --- values from .env (with sensible container defaults) -------------------------------------------
DB_NAME="${MYSQL_DATABASE:-magento}"
# Use root by default — setup:upgrade needs privileges to (re)create triggers.
DB_USER="root"
DB_PASS="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set in .env}"
BASE_URL="${BASE_URL:-http://localhost:${NGINX_PORT:-8080}/}"

# --- crypt key ------------------------------------------------------------------------------------
# Reuse the existing env.php's key if present; otherwise prompt.
EXISTING_KEY=""
if [[ -f "$ENV_FILE" ]]; then
    EXISTING_KEY="$(php -r '$e=@require $argv[1]; echo $e["crypt"]["key"] ?? "";' "$ENV_FILE" 2>/dev/null || true)"
fi
if [[ -n "$EXISTING_KEY" ]]; then
    CRYPT_KEY="$EXISTING_KEY"
    echo "${GREEN}Reusing the crypt key already in env.php.${NC}"
else
    echo "Enter the Magento crypt key (from a teammate / Cloud env.php's crypt.key)."
    echo "It must match the key that encrypted the DB dump you will import."
    read -rsp "  crypt key: " CRYPT_KEY; echo
    [[ -n "$CRYPT_KEY" ]] || { echo "${RED}A crypt key is required.${NC}" >&2; exit 1; }
fi

# --- admin frontName (only asked when generating fresh) -------------------------------------------
FRONT_NAME="${ADMIN_FRONTNAME:-admin}"

echo
echo "Target : $ENV_FILE"
echo "Mode   : $([[ -f "$ENV_FILE" ]] && echo 'PATCH existing' || echo 'GENERATE new')"
echo "DB     : mysql / db=$DB_NAME user=$DB_USER"
echo "Search : opensearch:9200"
echo

[[ -f "$ENV_FILE" ]] && { cp -p "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"; echo "  backed up existing env.php"; }

# --- build/patch via PHP (var_export keeps it valid) ----------------------------------------------
ENV_FILE="$ENV_FILE" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" \
CRYPT_KEY="$CRYPT_KEY" FRONT_NAME="$FRONT_NAME" php <<'PHP'
<?php
$f    = getenv('ENV_FILE');
$db   = getenv('DB_NAME'); $user = getenv('DB_USER'); $pass = getenv('DB_PASS');
$key  = getenv('CRYPT_KEY'); $front = getenv('FRONT_NAME');

$conn = [
    'host' => 'mysql', 'dbname' => $db, 'username' => $user, 'password' => $pass,
    'active' => '1', 'driver_options' => [1014 => false],
];
$search = [
    'engine' => 'opensearch',
    'opensearch_server_hostname' => 'opensearch',
    'opensearch_server_port' => '9200',
    'opensearch_index_prefix' => 'magento2',
    'opensearch_server_timeout' => '15',
];

if (file_exists($f)) {                       // ---- PATCH: keep everything, fix hosts ----
    $e = require $f;
    foreach (($e['db']['connection'] ?? []) as $k => $_) {
        $e['db']['connection'][$k]['host']     = 'mysql';
        $e['db']['connection'][$k]['dbname']   = $db;
        $e['db']['connection'][$k]['username'] = $user;
        $e['db']['connection'][$k]['password'] = $pass;
    }
    if (empty($e['db']['connection'])) $e['db']['connection']['default'] = $conn;
    $e['crypt']['key'] = $key;
    $e['system']['default']['catalog']['search'] = array_merge(
        $e['system']['default']['catalog']['search'] ?? [], $search
    );
    // No RabbitMQ in the stack -> fall back to the DB queue.
    unset($e['queue']);
} else {                                     // ---- GENERATE: minimal valid env.php ----
    $e = [
        'backend' => ['frontName' => $front],
        'db' => ['table_prefix' => '', 'connection' => ['default' => $conn]],
        'resource' => ['default_setup' => ['connection' => 'default']],
        'x-frame-options' => 'SAMEORIGIN',
        'MAGE_MODE' => 'developer',
        'crypt' => ['key' => $key],
        'session' => ['save' => 'files'],
        'cache_types' => array_fill_keys([
            'config','layout','block_html','collections','reflection','db_ddl',
            'compiled_config','eav','customer_notification','config_integration',
            'config_integration_api','full_page','config_webservice','translate',
        ], 1),
        'install' => ['date' => date('r')],
        'directories' => ['document_root_is_pub' => true],
        'system' => ['default' => ['catalog' => ['search' => $search]]],
    ];
}

file_put_contents($f, "<?php\nreturn " . var_export($e, true) . ";\n");
echo "  wrote $f\n";
PHP

# --- validate ---------------------------------------------------------------------------------------
if php -l "$ENV_FILE" >/dev/null 2>&1; then
    echo "${GREEN}env.php generated and syntactically valid.${NC}"
    echo "Next: make composer CMD='install' (if needed), then di:compile -> setup:upgrade."
else
    echo "${RED}Generated env.php failed php -l — check it.${NC}" >&2; exit 1
fi
