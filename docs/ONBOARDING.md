# Onboarding — stand up the texperts environment from a fresh clone

For a teammate who just cloned this `docker-setup` repo and needs a working local
Adobe Commerce environment. This repo is the **Docker stack, not the Magento app** — you
supply the code, secrets, and a DB. See [ENVIRONMENT_ARCHITECTURE.md](ENVIRONMENT_ARCHITECTURE.md)
for how the pieces fit.

**The stack is version-switchable — it installs either Magento version.** Pick the profile
that matches the code you're setting up (step 3), and switch anytime later:

| Profile | Magento | Runtime |
|---|---|---|
| `make profile-247` | 2.4.7 | PHP 8.3 / MariaDB 10.6 / OpenSearch 2 |
| `make profile-249` | 2.4.9 | PHP 8.5 / MariaDB 11.4 / OpenSearch 3 |

Throughout, `<MAGENTO_DIR>` = wherever your Magento checkout lives, e.g.
`/var/www/html/texperts-docker`. It is a **separate directory** from this repo.

Each step ends with a quick check (✓) so you catch problems early rather than at the end.

---

## 0. Get these first (the repo deliberately excludes them)

| Need | Why | Where from |
|---|---|---|
| **Bitbucket SSH access** | to clone the Magento code | your Git admin |
| **Adobe Commerce EE composer keys** | `composer install` pulls Enterprise packages | the Adobe account owner (commercemarketplace.adobe.com → Access Keys) |
| **Prod app `crypt/key`** | to decrypt the imported DB (payment tokens, OAuth…) | a teammate / the Cloud env's `app/etc/env.php` |
| **A DB dump** (`.sql.gz`) | the store data | a teammate / a Cloud DB export |

Host: Ubuntu, ~4 GB RAM free, ~20 GB disk.

---

## 1. Install Docker

```bash
git clone <this docker-setup repo> /var/www/html/docker-setup
cd /var/www/html/docker-setup

sudo bash docker-setup.sh                       # installs Docker Engine + Compose v2
sudo usermod -aG docker "$USER"                 # then LOG OUT and back in (group takes effect on new login)
sudo sysctl -w vm.max_map_count=262144          # OpenSearch needs this
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf

docker info >/dev/null && echo "Docker OK (no sudo)"
```

If `docker` still needs `sudo`, you haven't re-logged in after the `usermod` — do that.

**✓ Check:** `docker info` prints without `sudo`, and `docker compose version` shows v2.

---

## 2. Get the Magento code into `<MAGENTO_DIR>`

**Either** use an existing checkout — skip cloning, just note its path — **or** clone fresh:

```bash
git clone git@bitbucket.org:textile-trade-buddy/ttb.git /var/www/html/texperts-docker
cd /var/www/html/texperts-docker
git checkout <the branch you want>              # e.g. master or an upgrade branch
```

`vendor/` is gitignored, so a fresh clone has no dependencies yet — step 6 builds them.

**✓ Check:** `ls <MAGENTO_DIR>/composer.json` exists and `git -C <MAGENTO_DIR> branch --show-current` is the branch you want.

---

## 3. Initialise the stack config

```bash
cd /var/www/html/docker-setup
./init-project.sh                               # creates .env with generated passwords, checks prereqs
```

Then edit **`.env`**:
```ini
PROJECT_PATH=/var/www/html/texperts-docker      # <-- your <MAGENTO_DIR>
MYSQL_DATABASE=<db name matching your dump>      # e.g. ttb-prod-jan
```

Pick the version profile that matches the code you're running:
```bash
make profile-247      # 2.4.7 baseline  (PHP 8.3 / MariaDB 10.6 / OpenSearch 2)
# or
make profile-249      # 2.4.9 target    (PHP 8.5 / MariaDB 11.4 / OpenSearch 3)
```

**✓ Check:** `make config` validates (no error), and `grep -E 'PROJECT_PATH|PHP_TAG|DB_IMAGE' .env` shows your dir + the profile you picked.

---

## 4. Add your composer keys

```bash
./scripts/composer-auth.sh                       # enter the EE public/private key
```
Also add the private-repo keys (vnecoms / mageplaza / magecomp) — the store won't
`composer install` without them. They go into `scripts/.composer-auth.json` (gitignored).

**✓ Check:** `make composer-validate` reports the credentials are valid.

---

## 5. Build the images and start the stack

```bash
make build && make up && make status             # wait until all 5 services are healthy
```
The PHP-FPM container runs even before Magento is installed, so this succeeds with an
empty `vendor/`.

**✓ Check:** `make status` shows all 5 services (nginx, php, mysql, opensearch, valkey) `healthy`.

---

## 6. Install Magento dependencies

```bash
make composer CMD='install'                      # uses your EE key; builds vendor/ (~10-20 min)
```
`make composer` injects the EE key + unlimited memory automatically. If this fails on
auth, your keys lack Adobe Commerce entitlement — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**✓ Check:** `<MAGENTO_DIR>/bin/magento` and `<MAGENTO_DIR>/vendor/` now exist.

---

## 7. Generate the container `env.php`

```bash
./scripts/gen-env-php.sh
```
This writes `<MAGENTO_DIR>/app/etc/env.php` pointing DB → `mysql` and search →
`opensearch` (the service names), reading DB creds from `.env`. It **prompts for the
crypt key** (from step 0) unless an `env.php` already exists (then it reuses that key).
No hand-editing PHP.

**✓ Check:** `make composer CMD='--version'` runs, and
`docker compose exec -u www-data php php bin/magento --version` prints the Magento version.

---

## 8. Import the database

```bash
./scripts/restore-db.sh /path/to/your-dump.sql.gz    # auto-strips prod DEFINERs
```
Then make the prod data usable locally (a production dump points at the prod domain,
forces HTTPS, uses Fastly, etc.). Follow **[PHASE_3_PLAN.md](PHASE_3_PLAN.md) §3B** —
set base URLs to `http://localhost:8080/`, disable secure/frontend+adminhtml, set
`system/full_page_cache/caching_application=2`, turn off any custom admin path, and
create a local admin with `bin/magento admin:user:create`.

---

## 9. Compile, reconcile, verify

```bash
M="docker compose exec -u www-data php php -d memory_limit=5G bin/magento"
$M setup:di:compile        # MUST run before setup:upgrade (DataExporter virtualType)
$M setup:upgrade --keep-generated
$M indexer:reindex
$M cache:flush
```
Then check:
```bash
curl -I http://localhost:8080/                   # storefront -> 200
curl -I http://localhost:8080/<admin-frontName>  # admin -> 200  (e.g. /jp or /admin)
```

Admin login uses the `ADMIN_*` values from `.env` (the local admin you created in step 8).

---

## Quick reference

| Step | Command |
|---|---|
| Install Docker | `sudo bash docker-setup.sh` |
| Get code | `git clone <ttb.git> <MAGENTO_DIR>` |
| Init | `./init-project.sh` → edit `.env` (`PROJECT_PATH`, `MYSQL_DATABASE`) → `make profile-247\|249` |
| Keys | `./scripts/composer-auth.sh` |
| Up | `make build && make up` |
| Deps | `make composer CMD='install'` |
| env.php | `./scripts/gen-env-php.sh` |
| DB | `./scripts/restore-db.sh <dump>` + PHASE_3_PLAN §3B |
| Finish | `di:compile` → `setup:upgrade` → reindex → flush |

**Stuck?** [TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers the common ones (OpenSearch
`vm.max_map_count`, `sudo`/docker-group, composer auth, permissions).
