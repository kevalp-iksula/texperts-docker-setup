# Phase 3 — Magento Installation & Database Import

**Status:** planned, not started.
**Precondition:** Phase 2 complete — `make status` shows every service healthy
and `curl http://localhost:8080/health` returns `healthy`.

Phase 2 delivered an empty, running platform. Phase 3 puts Adobe Commerce on it.

---

## Decide first: fresh install or import?

These are different paths. Pick one before running anything.

| | Fresh install | Import existing database |
|---|---|---|
| Use when | Learning, new build, clean baseline | Migrating a real store, reproducing a bug |
| Source | `composer create-project` from repo.magento.com | An existing `.sql.gz` dump |
| Time | 20–40 min | 10 min + import time (large catalogs: hours) |
| Main risk | Composer auth failures | Version and base-URL mismatches |

Sections 3A and 3B below cover each.

---

## Step 1 — Composer credentials

Needed for both paths.

```bash
bash scripts/composer-auth.sh
```

Keys come from <https://commercemarketplace.adobe.com> → My Profile → Access Keys.
Public key is the username, private key the password. The script writes
`scripts/.composer-auth.json` at mode 600, gitignored, mounted read-only into the
container and never baked into an image.

**Verify before going further** — a bad key surfaces 15 minutes into a download
as an opaque 402:

```bash
make composer-validate
```

---

## Step 2 — Confirm the platform matches 2.4.9's requirements

```bash
make shell
php -v                    # must be 8.5.x
php -m | grep -E 'bcmath|intl|soap|sodium|xsl|zip|opcache|pdo_mysql'
exit

curl -s localhost:9201 | grep number      # must be 3.x — 2.4.9 rejects OpenSearch 2.x
```

AC 2.4.9 requires PHP 8.4 or 8.5 (8.3 is upgrade-only), MySQL 8.4, and
OpenSearch 3.x. Elasticsearch is not supported at all.

---

## 3A — Fresh install

The fastest path is `make magento-install`, which does everything in this
section (download + setup:install + post-config) and reads the edition from
`MAGENTO_EDITION` in `.env`. The manual steps below are what that target runs,
for when you want to do it by hand or understand a failure.

### Download the source

```bash
make shell

# Magento Open Source (free):
composer create-project --repository-url=https://repo.magento.com/ \
    magento/project-community-edition=2.4.9 /var/www/magento

# Adobe Commerce (needs a paid license entitlement on your keys) instead:
#   magento/project-enterprise-edition=2.4.9
```

`/var/www/magento` must be empty or Composer refuses — remove the `.gitkeep`
that `init-project.sh` leaves in `volumes/code/` first. (The
`make magento-download` target handles this for you.) The path maps to
`volumes/code/` on the host.

Expect 10–20 minutes and ~2GB in `vendor/`. If it dies with a memory error,
`COMPOSER_MEMORY_LIMIT=-1` is already set in the container.

### Run the installer

Run this from the host (not inside `make shell`), so `source .env` supplies the
generated passwords instead of you retyping them:

```bash
cd /var/www/html/docker-setup
source .env

make magento-cmd CMD="setup:install \
  --base-url=${BASE_URL} \
  --db-host=mysql \
  --db-name=${MYSQL_DATABASE} \
  --db-user=${MYSQL_USER} \
  --db-password=${MYSQL_PASSWORD} \
  --admin-firstname=${ADMIN_FIRSTNAME} \
  --admin-lastname=${ADMIN_LASTNAME} \
  --admin-email=${ADMIN_EMAIL} \
  --admin-user=${ADMIN_USER} \
  --admin-password=${ADMIN_PASSWORD} \
  --language=en_US \
  --currency=USD \
  --timezone=UTC \
  --use-rewrites=1 \
  --search-engine=opensearch \
  --opensearch-host=opensearch \
  --opensearch-port=9200 \
  --opensearch-index-prefix=magento2 \
  --opensearch-timeout=15 \
  --session-save=redis \
  --session-save-redis-host=valkey \
  --session-save-redis-port=6379 \
  --session-save-redis-db=2 \
  --cache-backend=redis \
  --cache-backend-redis-server=valkey \
  --cache-backend-redis-port=6379 \
  --cache-backend-redis-db=0 \
  --page-cache=redis \
  --page-cache-redis-server=valkey \
  --page-cache-redis-port=6379 \
  --page-cache-redis-db=1"
```

Note the hostnames: `mysql`, `opensearch`, `valkey` — Docker service names, not
`localhost`. Inside a container `localhost` is that container itself. This is the
single most common install failure.

Valkey is wire-compatible with Redis, so Magento's `redis` options drive it
unchanged. The three separate DB numbers (0/1/2) keep cache, page cache, and
sessions from flushing each other.

### Post-install

```bash
make dev-mode        # developer mode: no static caching, real error messages
make fix-perms
make upgrade
make reindex
```

---

## 3B — Import an existing database

### Get the code to match the database

The source tree must be the same Magento version as the dump. A 2.4.7 database
against a 2.4.9 codebase needs a real upgrade, not an import.

```bash
# Either copy an existing project in:
rsync -a --info=progress2 /path/to/existing/magento/ volumes/code/

# Or create the matching version from Composer, then import over it.
```

### Import

```bash
cp /path/to/dump.sql.gz volumes/backups/
make db-restore FILE=volumes/backups/dump.sql.gz
```

The restore script drops and recreates the schema, so it asks for confirmation
and takes a safety dump of anything already there first.

### Repoint the imported store at this environment

A dump from another environment carries that environment's URLs, cache config,
and search host. All of it must be rewritten or the site will not load.

```bash
source .env

# Base URLs
make magento-cmd CMD="config:set web/unsecure/base_url ${BASE_URL}"
make magento-cmd CMD="config:set web/secure/base_url ${BASE_URL}"

# Search must point at this container, not the old host
make magento-cmd CMD="config:set catalog/search/engine opensearch"
make magento-cmd CMD="config:set catalog/search/opensearch_server_hostname opensearch"
make magento-cmd CMD="config:set catalog/search/opensearch_server_port 9200"
make magento-cmd CMD="config:set catalog/search/opensearch_index_prefix magento2"
```

Then clear the inherited caches and rebuild:

```bash
make magento-cmd CMD='app:config:import'
make upgrade
make reindex
make flush
```

`app/etc/env.php` came from the old environment too. Check its `db`, `cache`,
and `session` hosts point at `mysql` and `valkey`, and delete any `crypt/key`
mismatch concerns — if the key differs from the one the data was encrypted with,
saved payment credentials and OAuth tokens will not decrypt. Keep the original
`crypt/key` from the source environment.

### Create yourself an admin user

The imported admin accounts likely have unknown passwords:

```bash
source .env
make magento-cmd CMD="admin:user:create \
  --admin-user=${ADMIN_USER} \
  --admin-password=${ADMIN_PASSWORD} \
  --admin-email=${ADMIN_EMAIL} \
  --admin-firstname=${ADMIN_FIRSTNAME} \
  --admin-lastname=${ADMIN_LASTNAME}"
```

---

## Step 3 — Verify (both paths)

```bash
curl -I http://localhost:8080/                    # 200
make magento-cmd CMD='--version'                  # 2.4.9
make magento-cmd CMD='setup:db:status'            # up to date
make magento-cmd CMD='indexer:status'             # no invalid
make magento-cmd CMD='cache:status'               # enabled
```

Then in a browser:

- Storefront <http://localhost:8080> — renders with CSS, products list
- Admin <http://localhost:8080/admin> — log in, load a product grid, run a search

A storefront with no styling almost always means static content or base URL, not
a broken install.

---

## Step 4 — Disable the cron-driven surprises (development only)

```bash
# Stop Magento reindexing on a schedule while you work
make magento-cmd CMD='indexer:set-mode realtime'
```

Cron is not running in this stack by default. If you need it, add a `cron`
service to `docker-compose.override.yml` rather than the base compose file.

---

## Known sharp edges

**Composer 402 / "Could not authenticate"** — keys are wrong or the account has
no 2.4.9 entitlement. Re-run `make composer-validate`.

**`setup:install` cannot reach the database** — you used `localhost` instead of
`mysql`.

**OpenSearch rejected** — 2.4.9 requires 3.x. Check `curl -s localhost:9201 | grep number`.

**Storefront unstyled** — in developer mode, `rm -rf pub/static/frontend` then
reload; Magento regenerates on demand.

**Permission denied writing `generated/` or `var/`** — something ran as root.
`make fix-perms`, and use `make shell` (which is already `www-data`) rather than
`docker compose exec php`.

**Install is very slow** — expected on a bind mount. `di:compile` on 2.4.9 takes
several minutes even on fast hardware.

---

## What Phase 3 delivers

- [ ] Composer credentials stored and validated
- [ ] Magento 2.4.9 source in `volumes/code/`
- [ ] Database installed or imported, schema current
- [ ] OpenSearch and Valkey wired to container hostnames
- [ ] Storefront and admin both load
- [ ] Developer mode on, live reload confirmed by editing a template
- [ ] `make db-backup` taken as a clean post-install baseline

That last one matters: take a baseline dump the moment the install is clean, so
you can always get back here without re-running Phase 3.
