# Adobe Commerce — Docker Development Stack

This repo is the **Docker stack, not the Magento app**. It stands up the services Adobe
Commerce needs (PHP, Nginx, MariaDB, OpenSearch, Valkey) and bind-mounts a Magento
checkout you supply. The stack is **version-switchable** — the same setup runs the **2.4.7**
baseline or the **2.4.9** target, flipped with one command.

> The setup scripts are real bash (arrays, `[[ ]]`, `pipefail`) and may not run when
> launched directly (`./script.sh`) if your shell resolves `sh` to dash or the exec bit is
> missing. **Always invoke them with `bash …`**, exactly as shown below.

Throughout, `<MAGENTO_DIR>` = wherever your Magento checkout lives (e.g.
`/var/www/html/texperts-docker`). It is a **separate directory** from this repo — see
[docs/ENVIRONMENT_ARCHITECTURE.md](docs/ENVIRONMENT_ARCHITECTURE.md).

---

## 0. Get these first (the repo deliberately excludes them)

| Need | Why | Where from |
|---|---|---|
| **Bitbucket SSH access** | to clone the Magento code | your Git admin |
| **Adobe Commerce EE composer keys** | `composer install` pulls Enterprise packages | the Adobe account owner (commercemarketplace.adobe.com → Access Keys) |
| **Prod app `crypt/key`** | to decrypt the imported DB (payment tokens, OAuth…) | a teammate / the Cloud env's `app/etc/env.php` |
| **A DB dump** (`.sql.gz`) | the store data | a teammate / a Cloud DB export |

Host: Ubuntu, ~4 GB RAM free, ~20 GB disk. Full requirements:
[docs/STACK_REFERENCE.md](docs/STACK_REFERENCE.md#requirements).

---

## 1. Install Docker — *do you have it already?*

**→ No Docker yet:**

```bash
git clone <this repo> /var/www/html/docker-setup
cd /var/www/html/docker-setup

sudo bash docker-setup.sh                       # installs Docker Engine + Compose v2
sudo usermod -aG docker "$USER"                 # add yourself to the docker group
sudo sysctl -w vm.max_map_count=262144          # OpenSearch needs this
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
```

**Then activate the group — this is the step people miss.** `usermod` does **not** affect
your current shell: the login session was created *before* you were in the `docker` group,
so `make` still needs `sudo` until you get a fresh session. Do one of:

```bash
newgrp docker            # applies to THIS terminal immediately (simplest)
# — or fully log out of your desktop session and back in (permanent, all terminals)
# — or reboot
```

Closing one terminal window is **not** enough — the group set is inherited from the
graphical login, so you must re-login to the whole session (or use `newgrp docker` per
terminal). Then verify:

```bash
id -nG | tr ' ' '\n' | grep -qx docker && echo "in docker group ✓"
docker info >/dev/null && echo "Docker OK (no sudo)"
```

Avoid habitual `sudo make` — running the stack as root drops root-owned files into your
bind mount that then break live-reload editing.

**→ Docker already installed:** skip straight to step 2. (If `make` still needs `sudo`
there too, it's the same group-not-active issue — run `newgrp docker` or re-login.)

**✓ Check:** `id -nG` lists `docker`, `docker info` prints without `sudo`, and
`docker compose version` shows v2.

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
bash init-project.sh                            # creates .env with generated passwords, checks prereqs
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

**✓ Check:** `make config` validates, and `grep -E 'PROJECT_PATH|PHP_TAG|DB_IMAGE' .env` shows your dir + the profile you picked.

---

## 4. Add your composer keys

```bash
bash scripts/composer-auth.sh                    # enter the EE public/private key
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

> **Order matters.** Steps 2–4 must be done *before* this: the code must be cloned (it's
> bind-mounted), and `init-project.sh` must have run (it creates `scripts/.composer-auth.json`
> as a file and bakes your real UID/GID into `.env`). If you run `make build`/`make up` first,
> `ac-php-249` comes up **unhealthy** — Docker created the mount sources as root-owned dirs
> and the image baked the wrong UID. Fix: `docker logs ac-php-249 | tail -30`, then
> `make down && make rebuild && make up`. See
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#php-container-ac-php-249-is-unhealthy).

**✓ Check:** `make status` shows all 5 services (nginx, php, mysql, opensearch, valkey) `healthy`.

---

## 6. Install Magento dependencies

```bash
make composer CMD='install'                      # uses your EE key; builds vendor/ (~10-20 min)
```
`make composer` injects the EE key + unlimited memory automatically. If this fails on
auth, your keys lack Adobe Commerce entitlement — see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

**✓ Check:** `<MAGENTO_DIR>/bin/magento` and `<MAGENTO_DIR>/vendor/` now exist.

---

## 7. Generate the container `env.php`

```bash
bash scripts/gen-env-php.sh
```
This writes `<MAGENTO_DIR>/app/etc/env.php` pointing DB → `mysql` and search →
`opensearch` (the service names), reading DB creds from `.env`. It **prompts for the
crypt key** (from step 0) unless an `env.php` already exists (then it reuses that key).
No hand-editing PHP.

**✓ Check:** `docker compose exec -u www-data php php bin/magento --version` prints the Magento version.

---

## 8. Import the database

```bash
bash scripts/restore-db.sh /path/to/your-dump.sql.gz    # auto-strips prod DEFINERs
```
Then make the prod data usable locally (a production dump points at the prod domain,
forces HTTPS, uses Fastly, etc.). Follow **[docs/PHASE_3_PLAN.md](docs/PHASE_3_PLAN.md) §3B** —
set base URLs to `http://localhost:8080/`, disable secure frontend+adminhtml, set
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

Admin login uses the local admin you created in step 8.

---

## Runtime — one stack, two profiles

Switch with `make profile-247` / `make profile-249` (each copies `.env.247` / `.env.249`
over `.env`), then `make build && make up`:

| Profile | PHP | Database | Search | Cache |
|---|---|---|---|---|
| **2.4.7** (`make profile-247`) | 8.3 | MariaDB 10.6 | OpenSearch 2 | Valkey 8 |
| **2.4.9** (`make profile-249`) | 8.5 | MariaDB 11.4 | OpenSearch 3 | Valkey 8 |

Nginx 1.27 is the web entrypoint in both. 2.4.9 **requires OpenSearch** (Elasticsearch and
OpenSearch 2.x were dropped). Why two versions and how the code is upgraded in place:
[docs/ENVIRONMENT_ARCHITECTURE.md](docs/ENVIRONMENT_ARCHITECTURE.md).

---

## Quick reference

| Step | Command |
|---|---|
| Install Docker | `sudo bash docker-setup.sh` |
| Get code | `git clone <ttb.git> <MAGENTO_DIR>` |
| Init | `bash init-project.sh` → edit `.env` (`PROJECT_PATH`, `MYSQL_DATABASE`) → `make profile-247\|249` |
| Keys | `bash scripts/composer-auth.sh` |
| Up | `make build && make up` |
| Deps | `make composer CMD='install'` |
| env.php | `bash scripts/gen-env-php.sh` |
| DB | `bash scripts/restore-db.sh <dump>` + PHASE_3_PLAN §3B |
| Finish | `di:compile` → `setup:upgrade` → reindex → flush |

Already set up? Daily commands: [docs/QUICK_START.md](docs/QUICK_START.md).

---

## Documentation

| Doc | For |
|---|---|
| [docs/QUICK_START.md](docs/QUICK_START.md) | Getting running, daily commands |
| [docs/ENVIRONMENT_ARCHITECTURE.md](docs/ENVIRONMENT_ARCHITECTURE.md) | Directory layout + the version-switchable stack (2.4.7 ↔ 2.4.9) |
| [docs/STACK_REFERENCE.md](docs/STACK_REFERENCE.md) | Layout, how the stack works, design choices, requirements |
| [docs/PHASE_2_UCT_INSIGHTS.md](docs/PHASE_2_UCT_INSIGHTS.md) | 2.4.9 upgrade compatibility findings + backlog |
| [docs/PHASE_3_PLAN.md](docs/PHASE_3_PLAN.md) | Installing or importing Magento |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | When it breaks |
| `make help` | Every available command |
