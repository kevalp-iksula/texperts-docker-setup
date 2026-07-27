# Stack Reference

The build and operational detail behind the Docker stack — directory layout, how the
moving parts work, the deliberate design choices, and full requirements. The
[README](../README.md) routes you to the right setup path; this is the reference you
reach for once you're set up. For the *why two versions / which directory does what*
picture, see [ENVIRONMENT_ARCHITECTURE.md](ENVIRONMENT_ARCHITECTURE.md).

---

## Layout

```
docker-setup/
├── docker-compose.yml               # The stack (images/versions read from .env)
├── docker-compose.override.yml.example  # Optional local tweaks (MailHog, RabbitMQ, limits)
├── .env.example                     # Config template — copy to .env
├── .env.247 / .env.249              # Version profiles (make profile-247 | profile-249)
├── .gitignore / .dockerignore       # Keep secrets and bulk out of git and images
├── Makefile                         # make help
├── init-project.sh                  # Idempotent first-time setup
│
├── php/
│   ├── 8.3/Dockerfile               # PHP 8.3 (2.4.7 profile)
│   ├── 8.5/Dockerfile               # PHP 8.5 (2.4.9 profile) + Magento extensions + Composer
│   ├── 8.5/php.ini                  # Memory, OPcache, error display
│   ├── www.conf                     # FPM pool (shared)
│   └── docker-entrypoint.sh         # Xdebug toggle, preflight warnings (shared)
│
├── nginx/
│   ├── Dockerfile
│   ├── nginx.conf                   # Global: gzip, buffers, timeouts
│   ├── conf.d/ac-249.conf           # Magento vhost
│   └── upstream/php-249.conf        # FPM upstream
│
├── mysql/
│   ├── my.cnf                       # MariaDB-compatible InnoDB tuning for a dev box
│   └── init/                        # *.sql here runs on first boot only
│
├── scripts/
│   ├── composer-auth.sh             # Store + verify Adobe keys (600, gitignored)
│   ├── gen-env-php.sh               # Generate/patch the container app/etc/env.php
│   ├── port-check.sh                # Catch port conflicts early
│   ├── backup-db.sh                 # Timestamped .sql.gz
│   └── restore-db.sh                # Restore (auto DEFINER-strip), with a safety dump first
│
├── volumes/
│   └── backups/                     # Database dumps
│
└── docs/
    ├── QUICK_START.md               # Daily commands
    ├── ENVIRONMENT_ARCHITECTURE.md  # The version-switchable layout (2.4.7 ↔ 2.4.9)
    ├── STACK_REFERENCE.md           # This file
    ├── PHASE_3_PLAN.md              # Installing / importing Magento
    └── TROUBLESHOOTING.md
```

The Magento source is **not** in this repo — it lives in a separate directory the stack
bind-mounts via `PROJECT_PATH` in `.env`. See
[ENVIRONMENT_ARCHITECTURE.md](ENVIRONMENT_ARCHITECTURE.md).

---

## How a few things work

### Live code reload

Your Magento checkout (`PROJECT_PATH`) is bind-mounted into the PHP container, and OPcache
runs with `validate_timestamps=1`. Save a PHP file, hit refresh, see the change.

DI and layout changes still need `make upgrade` / `make flush` — that is Magento, not
Docker.

### Credentials

Nothing secret is ever baked into an image:

- `.env` — generated passwords, mode 600, gitignored
- `scripts/.composer-auth.json` — mode 600, gitignored, bind-mounted **read-only**
  at runtime, and excluded via `.dockerignore` so it cannot reach a build context

`docker history` on these images shows no keys. `.env.example` carries only
`CHANGE_ME` placeholders, and `docker-compose.yml` refuses to start if the
database passwords are unset.

### File ownership

`init-project.sh` writes your real UID/GID into `.env`, and the image maps
`www-data` to it. Files Composer writes inside the container stay editable on the
host. If your UID is not 1000, `make rebuild` after the first init.

The FPM master runs as root (it must, to spawn workers); every worker touching
your code runs as `www-data`. `make shell` puts you in as `www-data` — use it
rather than `docker compose exec php bash`, or you will leave root-owned files
behind.

### Ports

All host ports are non-default (8080, 3307, 9201, 6380) so they don't collide
with anything already on the machine. PHP-FPM is not published at all — only
Nginx talks to it, over the internal network. `make ports` checks availability.

| Service | Host | Container |
|---|---|---|
| Nginx | 8080 | 80 |
| MySQL/MariaDB | 3307 | 3306 |
| OpenSearch | 9201 | 9200 |
| Valkey | 6380 | 6379 |
| PHP-FPM | *not published* | 9000 |

Change them in `.env`, then `make ports` to check.

---

## Notes and deliberate choices

**Security plugin is off in OpenSearch, and the stack binds to localhost.** This
is a development environment. Do not put it on a shared or public host as-is.

**`innodb_flush_log_at_trx_commit = 2`** trades crash durability for speed. Right
for a dev box, wrong for production.

**Single stack, not dual.** Rather than running two environments side by side, one stack
swaps its PHP / DB / search container versions to match whichever Magento version you're
on (`make profile-247` / `make profile-249`). A second concurrent stack would roughly
double memory; everything here is version-parameterised instead. See
[ENVIRONMENT_ARCHITECTURE.md](ENVIRONMENT_ARCHITECTURE.md).

**Resource use:** measured at idle on this machine — about **2.2GB** total:

| | |
|---|---|
| OpenSearch (1g heap) | ~1.6GB |
| MariaDB | ~510MB |
| PHP-FPM | ~64MB |
| Nginx | ~17MB |
| Valkey | ~9MB |

It climbs during `composer install` and `di:compile`, which are the real peaks.
Lower `OPENSEARCH_HEAP_SIZE` in `.env` if you need the headroom back.

---

## Requirements

- Ubuntu 22.04 LTS (or any Linux with a current Docker)
- Docker 24+ and Compose v2
- `vm.max_map_count >= 262144` (OpenSearch will not start without it)
- ~4GB free RAM (idles at ~2.2GB; Composer/di:compile peak higher), ~20GB free disk
- Adobe Commerce EE access keys, to install Magento dependencies
