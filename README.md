# Adobe Commerce 2.4.9 — Docker Development Stack

A Docker development environment for Adobe Commerce 2.4.9, with live code reload,
secure credential handling, and a Makefile covering the day-to-day work.

| Component | Version | Why |
|---|---|---|
| PHP-FPM | 8.5 | 2.4.9 supports 8.4 and 8.5; 8.3 is upgrade-only |
| Nginx | 1.27 | Web entrypoint |
| MySQL | 8.4 | The version 2.4.9 targets |
| OpenSearch | 3.x | **Required** — 2.4.9 dropped OpenSearch 2.x and Elasticsearch |
| Valkey | 8 | Cache and sessions; Redis-compatible |

**Status:** Phase 2 complete — the platform runs, Magento is not installed yet.
Phase 3 (`docs/PHASE_3_PLAN.md`) installs it.

---

## Quick start

```bash
sudo sysctl -w vm.max_map_count=262144   # OpenSearch needs this
./init-project.sh                        # .env, permissions, validation
./scripts/composer-auth.sh               # Adobe access keys
make build && make up
make status
curl http://localhost:8080/health        # -> healthy
```

Full walkthrough: [docs/QUICK_START.md](docs/QUICK_START.md).

---

## Layout

```
docker-setup/
├── docker-compose.yml               # The stack
├── docker-compose.override.yml.example  # Optional local tweaks (MailHog, RabbitMQ, limits)
├── .env.example                     # Config template — copy to .env
├── .gitignore / .dockerignore       # Keep secrets and bulk out of git and images
├── Makefile                         # make help
├── init-project.sh                  # Idempotent first-time setup
│
├── php/
│   ├── 8.5/Dockerfile               # PHP 8.5 + Magento extensions + Composer
│   ├── 8.5/php.ini                  # Memory, OPcache, error display
│   ├── www.conf                     # FPM pool
│   └── docker-entrypoint.sh         # Xdebug toggle, preflight warnings
│
├── nginx/
│   ├── Dockerfile
│   ├── nginx.conf                   # Global: gzip, buffers, timeouts
│   ├── conf.d/ac-249.conf           # Magento vhost
│   └── upstream/php-249.conf        # FPM upstream
│
├── mysql/
│   ├── my.cnf                       # InnoDB tuning for a 16GB dev box
│   └── init/                        # *.sql here runs on first boot only
│
├── scripts/
│   ├── composer-auth.sh             # Store + verify Adobe keys (600, gitignored)
│   ├── port-check.sh                # Catch port conflicts early
│   ├── backup-db.sh                 # Timestamped .sql.gz
│   └── restore-db.sh                # Restore, with a safety dump first
│
├── volumes/
│   ├── ac-249/code/                 # YOUR MAGENTO SOURCE (bind-mounted)
│   └── backups/                     # Database dumps
│
└── docs/
    ├── QUICK_START.md
    ├── PHASE_3_PLAN.md              # Install / import — next phase
    └── TROUBLESHOOTING.md
```

---

## How a few things work

### Live code reload

`volumes/ac-249/code/` is bind-mounted to `/var/www/magento`, and OPcache runs
with `validate_timestamps=1`. Save a PHP file, hit refresh, see the change.

DI and layout changes still need `make upgrade` / `make flush` — that is Magento,
not Docker.

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

---

## Notes and deliberate choices

**Security plugin is off in OpenSearch, and the stack binds to localhost.** This
is a development environment. Do not put it on a shared or public host as-is.

**`innodb_flush_log_at_trx_commit = 2`** trades crash durability for speed. Right
for a dev box, wrong for production.

**Single stack, not dual.** 2.4.7 was dropped from this setup by choice — a
second stack roughly doubles memory. Everything here is version-parameterised, so
a 2.4.7 stack can be added later without a rewrite.

**Resource use:** measured at idle on this machine — about **2.2GB** total:

| | |
|---|---|
| OpenSearch (1g heap) | ~1.6GB |
| MySQL | ~510MB |
| PHP-FPM | ~64MB |
| Nginx | ~17MB |
| Valkey | ~9MB |

It climbs during `composer install` and `di:compile`, which are the real peaks.
Lower `OPENSEARCH_HEAP_SIZE` in `.env` if you need the headroom back.

---

## Requirements

- Ubuntu 22.04 LTS (or any Linux with a current Docker)
- Docker 24+ and Compose v2
- `vm.max_map_count >= 262144`
- ~4GB free RAM (idles at ~2.2GB; Composer/di:compile peak higher), ~20GB free disk
- Adobe Commerce access keys, for Phase 3

---

## Documentation

| Doc | For |
|---|---|
| [docs/ONBOARDING.md](docs/ONBOARDING.md) | **New teammate?** Full clone → Docker → code → DB → running |
| [docs/QUICK_START.md](docs/QUICK_START.md) | Getting running, daily commands |
| [docs/ENVIRONMENT_ARCHITECTURE.md](docs/ENVIRONMENT_ARCHITECTURE.md) | Directory layout + the version-switchable stack (2.4.7 ↔ 2.4.9) |
| [docs/WORKLOG.md](docs/WORKLOG.md) | Date-wise worklog of the upgrade effort |
| [docs/PHASE_2_UCT_INSIGHTS.md](docs/PHASE_2_UCT_INSIGHTS.md) | 2.4.9 upgrade compatibility findings + backlog |
| [docs/PHASE_3_PLAN.md](docs/PHASE_3_PLAN.md) | Installing or importing Magento |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | When it breaks |
| `make help` | Every available command |
