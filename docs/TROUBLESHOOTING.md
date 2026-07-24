# Troubleshooting

## Diagnose in this order

```bash
make status                  # which container is unhealthy?
make logs SERVICE=php        # what did it say? (also: nginx, mysql, opensearch)
make config                  # is .env resolving to what you expect?
docker stats --no-stream     # is something starving?
```

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
actually landed in `volumes/ac-249/code/`.

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
rm -rf volumes/ac-249/code/*    # + the source. Nothing left.
```

`make destroy` never touches your source code — only Docker volumes.

---

## Composer

**402 / "Could not authenticate against repo.magento.com"**

```bash
make composer-validate
./scripts/composer-auth.sh      # re-enter keys
```

Keys live at <https://commercemarketplace.adobe.com> → My Profile → Access Keys.
A key that works for 2.4.7 will not necessarily carry a 2.4.9 entitlement.

**auth.json is a directory, not a file** — Docker creates a directory when it
bind-mounts a path that does not exist. `init-project.sh` pre-creates the file to
prevent this. If it happened:

```bash
make down
rm -rf scripts/.composer-auth.json
./init-project.sh
./scripts/composer-auth.sh
```
