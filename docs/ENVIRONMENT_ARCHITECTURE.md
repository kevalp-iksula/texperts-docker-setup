# Environment Architecture — a version-switchable Docker stack for two Magento versions

This environment runs **one Magento codebase** on a **single Docker stack whose service
versions switch on demand** — so the same setup serves both the **2.4.7** baseline and the
**2.4.9** target. You flip between them with one command; the code is upgraded **in place**
in one directory rather than duplicated.

`/var/www/html/docker-setup` holds **no Magento code** — it is only the stack config.

---

## The three directories (three different jobs)

| Directory | Role | Contents | Version / branch |
|---|---|---|---|
| `/var/www/html/docker-setup` | **Docker stack config** — the "control room" | `docker-compose.yml`, `Makefile`, `php/ nginx/ mysql/` Dockerfiles, `scripts/`, `docs/`, `.env` | *(no Magento code)* |
| `/var/www/html/texperts` | **Local** dev copy (runs **outside** Docker) | Full Magento checkout on `localhost` + local MySQL | 2.4.7-p1, branch `production` — **untouched** |
| `<PROJECT_PATH>` (e.g. `/var/www/html/texperts-upgrade`) | The **checkout the stack bind-mounts** | Full Magento checkout — where the upgrade runs | now **2.4.9**, branch `master` |

```
                 ┌─────────────────────────────────────────┐
                 │  /var/www/html/docker-setup              │
                 │  (CONTROL ROOM — no app code)            │
                 │   docker-compose.yml · Makefile · .env   │
                 │   php/ nginx/ mysql/ scripts/ docs/      │
                 └───────────────┬─────────────────────────┘
                                 │ bind-mounts ONE code dir
                                 │ (PROJECT_PATH in .env)
                                 ▼
   ┌──────────────────────────┐          ┌──────────────────────────────────┐
   │ /var/www/html/texperts   │          │ <PROJECT_PATH>                   │
   │ LOCAL 2.4.7 (production)  │ isolated │ DOCKER checkout (master)         │
   │ localhost + local MySQL   │   from   │ upgraded in place to 2.4.9       │
   │ runs OUTSIDE Docker       │          │ — this is what the stack runs    │
   └──────────────────────────┘          └──────────────────────────────────┘
```

The stack only ever touches whatever `PROJECT_PATH` points at, so the local `texperts`
checkout stays completely independent of the Docker environment.

---

## Version-switchable: one stack, two Magento versions

Rather than maintaining two separate environments, **one stack swaps its PHP / DB / search
container versions** to match whichever Magento version you're running. The
`docker-compose.yml` reads every image/version from `.env`:

| Setting | **2.4.7 profile** | **2.4.9 profile** |
|---|---|---|
| PHP (`PHP_DOCKERFILE` / `PHP_TAG`) | `8.3/Dockerfile` / `8.3` | `8.5/Dockerfile` / `8.5` |
| DB (`DB_IMAGE`) | `mariadb:10.6` | `mariadb:11.4` |
| Search (`OPENSEARCH_VERSION`) | `2` | `3` |

Switch with one command — it copies a preset (`.env.247` / `.env.249`) over `.env`, then
rebuild + restart:

```bash
make profile-247      # → PHP 8.3 / MariaDB 10.6 / OpenSearch 2   (2.4.7 baseline)
make profile-249      # → PHP 8.5 / MariaDB 11.4 / OpenSearch 3   (2.4.9 target)
make build && make up
```

Both call the `_apply-profile` target in the `Makefile`. These are the two "versions of
the setup" — same stack, different service versions.

### The code is upgraded in place — not two copies
The bind-mounted checkout is a **single git clone**. It started at 2.4.7-p1, and
`composer update` moved it to 2.4.9 **in the same directory** — one codebase that advanced
in version, not a "2.4.7 folder" and a "2.4.9 folder." (The untouched
`/var/www/html/texperts` still holds the original 2.4.7 if you need to compare.)

---

## The database: one shared volume

All profiles share **one** Docker volume, `ac-mysql-data`. That's why the imported
`ttb-prod-jan` data survived the 2.4.7 → 2.4.9 switch — the code and PHP/search containers
changed, but the DB volume persisted and was migrated in place (MariaDB 10.6 → 11.4).

⚠️ **One-way caveat:** MariaDB upgrades its data files in place when 11.4 first opens a
10.6 volume, and it **cannot downgrade** them. So `make profile-247` alone will *not*
cleanly return you to a working 2.4.7 DB — you also restore the DB from a snapshot (below).

---

## Switching back to the 2.4.7 setup

```bash
cd <PROJECT_PATH>
git reset --hard <2.4.7 commit>        # or re-clone the branch
composer install                       # rebuilds vendor/ back to the 2.4.7 lock
cd /var/www/html/docker-setup
make profile-247 && make build && make up
bash scripts/restore-db.sh volumes/backups/ttb-prod-jan_baseline-2.4.7-june-prod_*.sql.gz
```

The baseline snapshot in `volumes/backups/` is the clean 2.4.7-p1 "before" state, kept
exactly for this round-trip.

---

## Why a 2.4.7-p10 state appeared (and isn't "in use")

It was a **transient step, not a target.** When `composer update` ran while the metapackage
constraint was still `>=2.4.5 <2.4.8`, composer pulled the newest release *allowed by that
constraint* — the latest patch **within** 2.4.7 (p1 → p10) — plus fresher Vnecoms/3rd-party
point releases.

- **Harmless and mildly useful:** it pulled the latest 2.4.7 security patches and Vnecoms
  builds before the big jump.
- **Superseded:** raising the constraint to `>=2.4.9 <2.4.10` and updating again moved the
  same directory to 2.4.9. There is no separate p10 environment — the one clone passed
  through p10 on its way to 2.4.9.

---

## One-line summary

`docker-setup` = the stack (no code). `texperts` = the local 2.4.7 copy (left alone).
`<PROJECT_PATH>` = the checkout the stack runs, upgraded in place to 2.4.9. **One stack,
version-switchable via `.env` profiles, serves both the 2.4.7 and 2.4.9 setups.**
