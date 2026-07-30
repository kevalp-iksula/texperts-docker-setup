# Troubleshooting

## Diagnose in this order

```bash
make status                  # which container is unhealthy?
make logs SERVICE=php        # what did it say? (also: nginx, mysql, opensearch)
make config                  # is .env resolving to what you expect?
docker stats --no-stream     # is something starving?
```

---

## `.env` is not writable (owned by root)

You ran `init-project.sh` **with `sudo`**, so `.env` (and `scripts/.composer-auth.json`) were
created as **root:root, mode 600** — your editor can't write them to set `PROJECT_PATH` /
`MYSQL_DATABASE`. `init-project.sh` does **not** need root.

```bash
sudo chown "$USER:$USER" .env scripts/.composer-auth.json    # take ownership back
```

Then edit `.env` normally. Next time, run `bash init-project.sh` **without** sudo (current
versions also chown these back to you automatically when run under sudo).

---

## `docker: 'compose' is not a docker command` (every `make` target fails)

That box has Docker Compose **v1** (`docker-compose`) but not the **v2** plugin. This stack
calls `docker compose` (v2) everywhere and relies on v2-only healthcheck gating, so v2 is
required — v1 is not a supported fallback.

```bash
docker compose version                          # errors on a v1-only box
sudo apt-get install docker-compose-plugin      # install v2  (or: sudo bash docker-setup.sh)
docker compose version                          # should now print v2.x
```

`make up` / `make build` now preflight this and print the same hint instead of the raw
docker error.

---

## php container (`ac-php`) is unhealthy

The php healthcheck is just `php-fpm -t` (a static config test), so it does **not** fail
because Magento isn't installed. A php container that *stays* unhealthy means php-fpm keeps
**restarting** — and because `nginx` waits for php to be healthy, the whole `make up` stalls.

Almost always it's an **install-order** problem: `make up` / `make build` was run before the
code was cloned and before `bash init-project.sh`. `init-project.sh` is what creates
`scripts/.composer-auth.json` as a real file and writes your real `UID`/`GID` into `.env`; skip
it and Docker auto-creates the bind-mount sources as **root-owned directories**, and the image
bakes the wrong UID.

**See the real reason, then rebuild in the right order:**

```bash
docker logs ac-php | tail -30          # the actual restart cause
make down
```

Then, from a clean state, in this order:

```bash
# 1. the code must exist first — it is bind-mounted
git clone <ttb.git> <MAGENTO_DIR>          # or point PROJECT_PATH at an existing checkout
bash init-project.sh                        # creates auth.json (as a file) + writes your UID/GID
#    edit .env: PROJECT_PATH=<MAGENTO_DIR>, MYSQL_DATABASE=<dump db>
make profile-247   # or profile-249
make build                                  # AFTER init, so the correct UID/GID bake in
make up && make status
```

If you had already built with the wrong UID, `make rebuild` (not just `make up`) is required —
`make up` alone reuses the stale image.

**Check the two mount sources are correct** (a directory where a file belongs is the tell):

```bash
ls -ld scripts/.composer-auth.json          # must be a FILE, not a directory
ls -ld "$(grep ^PROJECT_PATH= .env | cut -d= -f2-)"   # must exist and contain composer.json
```

If `scripts/.composer-auth.json` is a directory, remove it and re-run `bash init-project.sh`.

### `please specify user and group other than root` → `FPM initialization failed`

The php log shows this on a loop and the container never stays up:

```
ERROR: [pool www] please specify user and group other than root
ERROR: FPM initialization failed
```

`www.conf` runs the pool as `www-data`, and the image aligns `www-data` to the `UID`/`GID`
in `.env` (`usermod -u ${UID} www-data`). If **`UID=0`/`GID=0`**, `www-data` *becomes root*,
and php-fpm refuses to run its pool as root. This happens when `init-project.sh` was run **as
root or with `sudo`** — `id -u` returned 0 and got baked into `.env` and then the image.

```bash
grep -E '^(UID|GID)=' .env                  # 0 means this is your problem
sed -i 's/^UID=.*/UID=1000/; s/^GID=.*/GID=1000/' .env   # use your real login user's id
make down && make rebuild && make up         # rebuild — 'make up' alone reuses the bad image
```

Run `init-project.sh` as your **normal user**, not root. Current `init-project.sh` guards
against this (it substitutes the sudo user or 1000:1000 and warns), but an `.env` generated
by an older version can still carry `UID=0`.

---

## OpenSearch will not start

**`max virtual memory areas vm.max_map_count [65530] is too low`**

The single most common failure. The host kernel setting is too low:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
make restart
```

**Container exits immediately, no useful log** — usually the JVM failing to get
its heap. Lower it in `.env`:

```bash
OPENSEARCH_HEAP_SIZE=512m
```

**Healthcheck never goes healthy** — OpenSearch can take 60s+ on first boot.
`start_period` allows for it. If it is still red after two minutes:

```bash
make logs SERVICE=opensearch
curl localhost:9201/_cluster/health?pretty
```

A single-node cluster reporting **yellow is normal** — replicas have nowhere to
go. Only red is a problem.

---

## MySQL

**`Access denied for user`** — the credentials in `.env` changed *after* the data
volume was created. MySQL only reads `MYSQL_ROOT_PASSWORD` on first
initialisation; later edits do nothing. Either use the original password, or
wipe and re-init:

```bash
make destroy        # deletes the database. Back up first if it matters.
make up
```

**Container restarts in a loop** — read the log; it is usually a corrupt volume
or a config error in `mysql/my.cnf`:

```bash
make logs SERVICE=mysql
```

**Import dies on a large dump** — raise `max_allowed_packet` in `mysql/my.cnf`
(already 256M) and confirm the dump is not truncated:

```bash
gzip -t volumes/backups/your-dump.sql.gz && echo "archive is intact"
```

---

## PHP / Magento

**`Permission denied` writing `var/`, `generated/`, `pub/static/`**

Something ran as root and left root-owned files in the bind mount.

```bash
make fix-perms
```

Prevent it: use `make shell` (already `www-data`), not `docker compose exec php bash`.
If your host UID is not 1000, `init-project.sh` writes the real one into `.env` —
but the image bakes it at build time, so after changing it:

```bash
make rebuild
```

**Code edits have no effect** — check OPcache is still validating timestamps:

```bash
grep OPCACHE_VALIDATE .env                            # want 1
docker compose exec -u www-data php php -i | grep validate_timestamps
```

If it is 1 and edits still do nothing, you are probably editing a different
directory than the one bind-mounted. Confirm:

```bash
make config | grep -A2 'PROJECT_PATH\|/var/www/magento'
```

**`bin/magento` not found** — Magento is not installed yet. That is the expected
state after Phase 2. See `docs/PHASE_3_PLAN.md`.

**Out of memory during `di:compile`** — `PHP_MEMORY_LIMIT=2G` in `.env`, and
`COMPOSER_MEMORY_LIMIT=-1` is already set in the container. Raise to `4G` if the
machine allows.

---

## Nginx

**502 Bad Gateway** — PHP-FPM is down or still starting:

```bash
make status
make logs SERVICE=php
```

**504 Gateway Timeout** — a genuinely slow request (`setup:upgrade` via web,
huge reindex). Timeouts are already 600s.

**403 / blank page at `/`** — before Phase 3, `pub/index.php` does not exist and
you get the placeholder message. That is correct. After Phase 3, check the code
actually landed in `volumes/code/`.

**Config change ignored** — the config is bind-mounted, but Nginx must reload:

```bash
make nginx-reload
```

---

## Ports

**`bind: address already in use`**

```bash
make ports        # names the port and, where visible, the process holding it
```

Change the offending port in `.env` and `make up` again. Nothing here uses a
default port precisely to avoid this.

---

## Memory pressure

This stack wants ~6GB. On a 16GB box that is fine unless something else is
already large.

```bash
free -h
docker stats --no-stream
```

To trim: lower `OPENSEARCH_HEAP_SIZE` to `512m` and `VALKEY_MAXMEMORY` to `256mb`
in `.env`, then `make restart`.

---

## Starting over

```bash
make clean          # containers and networks; keeps data and code
make destroy        # + all volumes: database, indexes, cache. Asks first.
rm -rf volumes/code/*    # + the source. Nothing left.
```

`make destroy` never touches your source code — only Docker volumes.

---

## Composer

**402 / "Could not authenticate against repo.magento.com"**

```bash
make composer-validate
bash scripts/composer-auth.sh      # re-enter keys
```

Keys live at <https://commercemarketplace.adobe.com> → My Profile → Access Keys.
A key that works for 2.4.7 will not necessarily carry a 2.4.9 entitlement.

**`composer-auth.sh` seems to hang at "Verifying credentials…"** — after writing the keys it
checks them against `repo.magento.com`. On a slow/blocked network that request now times out
in ~25s and reports the keys were still saved (it no longer blocks for minutes or exits with
an error). To skip the check entirely:

```bash
SKIP_VERIFY=1 bash scripts/composer-auth.sh     # writes keys, no network check
make composer-validate                           # verify later, once the network is fine
```

**auth.json is a directory, not a file** — Docker creates a directory when it
bind-mounts a path that does not exist. `init-project.sh` pre-creates the file to
prevent this. If it happened:

```bash
make down
rm -rf scripts/.composer-auth.json
bash init-project.sh
bash scripts/composer-auth.sh
```

**`Composer could not find a composer.json file in /var/www/magento`** — the bind mount is
empty: `PROJECT_PATH` in `.env` isn't pointing at a Magento checkout. Clone the code into
`PROJECT_PATH` (composer can't create the project — `install` needs an existing
`composer.json`), then recreate so the mount updates:

```bash
ls "$(grep ^PROJECT_PATH= .env | cut -d= -f2-)/composer.json"   # must exist
make down && make up
docker compose exec php ls /var/www/magento/composer.json        # container now sees it
```

**`Your lock file does not contain a compatible set of packages. Please run composer update`**
— you're running `composer install` on the **wrong profile for the code**. A 2.4.7 codebase
(its `composer.lock` pins PHP 8.1–8.3) cannot install on the 2.4.9 profile (PHP 8.5). Install
the baseline on 2.4.7; reach 2.4.9 via `composer update`, not `install`:

```bash
make profile-247 && make rebuild && make up      # baseline runtime for a 2.4.7 lock
make composer CMD='install'
```

Do **not** use `--ignore-platform-reqs` to force it — that produces a broken 2.4.7-on-8.5 tree.

**`curl error 28 ... Timeout was reached` for every repo (including `repo.packagist.org`)** —
the container has no outbound internet/DNS; composer can't download packages. The
`ignore-unreachable` lines for magento/vnecoms/etc. are only the advisory fetch and are
harmless, but packagist timing out is fatal. Test and fix:

```bash
docker compose exec php getent hosts repo.packagist.org                       # DNS?
docker compose exec php curl -sSI --max-time 10 https://repo.packagist.org/packages.json | head -1
```

- On a corporate network, set `HTTP_PROXY`/`HTTPS_PROXY` on the `php` service (in
  `docker-compose.override.yml`) and `make down && make up`.
- DNS: add `dns: [8.8.8.8, 1.1.1.1]` to the `php` service or `/etc/docker/daemon.json`, then
  restart Docker. Confirm the **host** itself has internet first.

**`curl error 28 ... api.github.com` (only GitHub times out; packagist worked)** — composer
fetches package zips (e.g. `cweagans/composer-patches`) through the GitHub API. The usual
cause is an **IPv6 dead-end**: the host has no working IPv6 route, GitHub has AAAA records,
and libcurl blocks the full 10s connect timeout on IPv6 before it would fall back.

**The PHP image now prefers IPv4** (`/etc/gai.conf`, baked into `php/8.3` + `php/8.5`), which
fixes this for new builds. If you hit it on an existing image, **rebuild to pick up the fix**:

```bash
make down && make rebuild && make up
make composer CMD='install'
```

Still failing? Diagnose and escalate:

```bash
docker compose exec php curl -sSI  --max-time 10 https://api.github.com | head -1   # default
docker compose exec php curl -4 -sSI --max-time 10 https://api.github.com | head -1  # force IPv4
```

- **`-4` works, default still hangs after a rebuild** → force it harder: add
  `sysctls: ["net.ipv6.conf.all.disable_ipv6=1"]` to the `php` service in
  `docker-compose.override.yml`, then `make down && make up`. (Not forced in the base compose
  file — it fails to start on hosts with IPv6 fully compiled out.)
- **A GitHub token** removes API rate-limit stalls (a full install exceeds 60 req/hr
  unauthenticated). `bash scripts/composer-auth.sh` now prompts for one, or add it manually to
  `scripts/.composer-auth.json`:
  ```json
  { "github-oauth": { "github.com": "ghp_your_token" }, "http-basic": { "…": "…" } }
  ```
  Token: GitHub → Settings → Developer settings → Personal access tokens (no scopes needed).
- **Both hang** → firewall/proxy blocking GitHub; apply the proxy block above.
