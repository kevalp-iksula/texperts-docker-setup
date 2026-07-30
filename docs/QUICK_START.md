# Quick Start

Adobe Commerce, version-switchable (2.4.7: PHP 8.3 / MariaDB 10.6 / OpenSearch 2 · 2.4.9:
PHP 8.5 / MariaDB 11.4 / OpenSearch 3), Nginx, Valkey 8.

> **New teammate setting up from a fresh clone?** The full clone → Docker → code → DB →
> running walkthrough now lives in the [README](../README.md). This Quick Start assumes the
> stack is already set up.

## From zero to a running stack

Full install (clone code → `init-project` → **build & start** → keys → `composer install`
→ env.php → import DB) lives in the **[README](../README.md)**, in the correct order. The
short version, once the host is tuned:

```bash
cd /var/www/html/docker-setup
sudo sysctl -w vm.max_map_count=262144           # one-time; OpenSearch needs it
bash init-project.sh                             # writes .env — run WITHOUT sudo
#   edit .env: PROJECT_PATH + MYSQL_DATABASE
make build && make up && make status             # bring the stack up FIRST
bash scripts/composer-auth.sh                    # then add keys (validate needs the stack up)
make composer CMD='install'                      # build vendor/
```

Order matters: the stack comes up **before** composer keys/validate and `composer install`,
because those run inside the container. See the [README](../README.md) for each step's detail.

## "Why do I have to run `make` with `sudo`?"

You don't, and you shouldn't. If `make up` fails without `sudo`, it means your
shell can't reach the Docker socket — almost always because you were added to the
`docker` group *after* your current login session started, so the session doesn't
carry the group yet (`id` won't list `docker`).

You already have the permission. Refresh the session to pick it up:

```bash
# Add yourself to the group if you are not in it at all:
sudo usermod -aG docker "$USER"

# Then activate it. Pick one:
newgrp docker          # this terminal only, takes effect immediately
# — or fully log out of your desktop session and back in (permanent)
# — or reboot

# Verify (no sudo):
docker info >/dev/null && echo "OK, no sudo needed"
```

Closing a single terminal window is not enough — the group set is inherited from
the graphical login. Avoid habitual `sudo make`: running the stack as root can
drop root-owned files into your bind mount that then break live-reload editing.

## Getting Magento running

This project bind-mounts an **existing** Magento checkout (`PROJECT_PATH`) and builds its
dependencies — see the [README](../README.md) (build → keys → `make composer CMD='install'`
→ `gen-env-php.sh` → `restore-db.sh` → compile).

`make magento-install` is a *different* path — a brand-new `setup:install` (edition from
`MAGENTO_EDITION` in `.env`), for standing up an empty store rather than running the
texperts codebase. Don't use it for the upgrade flow.

## Confirm the stack is healthy

```bash
curl http://localhost:8080/health
# -> healthy

curl http://localhost:9201/_cluster/health?pretty
# -> "status": "green" or "yellow"   (yellow is normal for a single node)

make magento-cmd CMD='--version'
# -> prints the version once vendor/ + env.php + DB are in place (README steps 5-8)
```

## Everyday commands

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make status` | Container health |
| `make logs` | Tail all logs (`make logs SERVICE=php` to narrow) |
| `make shell` | Bash in the PHP container as `www-data` |
| `make magento-install` | Download + install Magento (edition from `.env`) |
| `make magento-uninstall` | Drop DB + wipe code, to reinstall cleanly (asks first) |
| `make flush` | Flush Magento cache |
| `make upgrade` | `setup:upgrade` + `di:compile` + cache flush |
| `make reindex` | Rebuild all indexers |
| `make db-backup` | Dump the database to `volumes/backups/` |
| `make db-restore FILE=...` | Restore a dump (asks before dropping) |
| `make xdebug-on` / `make xdebug-off` | Toggle the debugger |
| `make destroy` | Delete all data (asks first) |

Run `make` alone for the full list.

## Where things live

| What | Where |
|---|---|
| Your Magento code | `PROJECT_PATH` (set in `.env`) → `/var/www/magento` in the container |
| Secrets | `.env`, `scripts/.composer-auth.json` (both mode 600, both gitignored) |
| Backups | `volumes/backups/` |
| Local-only tweaks | `docker-compose.override.yml` (copy the `.example`) |

## Ports

| Service | Host | Container |
|---|---|---|
| Nginx | 8080 | 80 |
| MariaDB | 3307 | 3306 |
| OpenSearch | 9201 | 9200 |
| Valkey | 6380 | 6379 |
| PHP-FPM | *not published* | 9000 |

Host ports are deliberately non-default so they don't collide with anything you
already run. Change them in `.env`, then `make ports` to check.

## Live code reload

Your checkout (`PROJECT_PATH`) is bind-mounted, and OPcache runs with
`validate_timestamps=1`, so a saved PHP file takes effect on the next request —
no restart, no flush.

Two exceptions that still need a command:

- DI/config changes → `make upgrade`
- Layout XML / static assets → `make flush`

## If something breaks

```bash
make logs SERVICE=php        # or nginx, mysql, opensearch
make status                  # who is unhealthy?
make config                  # is .env being read as expected?
```

See `docs/TROUBLESHOOTING.md`.
