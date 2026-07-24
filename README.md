# Adobe Commerce — Docker Development Stack

This repo is the **Docker stack, not the Magento app**. It stands up the services Adobe
Commerce needs (PHP, Nginx, MariaDB, OpenSearch, Valkey) and bind-mounts a Magento
checkout you supply. The stack is **version-switchable** — the same setup runs the **2.4.7**
baseline or the **2.4.9** target, flipped with one command.

---

## Start here — do you have Docker?

**→ No Docker yet?** Install it first, then set up the code:

```bash
git clone <this repo> /var/www/html/docker-setup
cd /var/www/html/docker-setup
sudo bash docker-setup.sh                 # installs Docker Engine + Compose v2
sudo usermod -aG docker "$USER"           # then log out and back in
sudo sysctl -w vm.max_map_count=262144    # OpenSearch needs this
```

Then follow **[docs/ONBOARDING.md](docs/ONBOARDING.md)** from step 1.

**→ Docker already installed?** You just need to get the Magento code + database running.
Each step below is a one-liner; **[docs/ONBOARDING.md](docs/ONBOARDING.md)** has the detail
and the ✓ checks for each:

```bash
cd /var/www/html/docker-setup
./init-project.sh                         # 1. generate .env, then set PROJECT_PATH + MYSQL_DATABASE
make profile-247   # or profile-249       # 2. pick the version profile
./scripts/composer-auth.sh                # 3. add Adobe EE + private-repo keys
make build && make up && make status      # 4. build images, start, wait for healthy
make composer CMD='install'               # 5. build vendor/ (needs the EE key)
./scripts/gen-env-php.sh                   # 6. write the container app/etc/env.php
./scripts/restore-db.sh <dump.sql.gz>     # 7. import the DB (auto DEFINER-strip)
make upgrade                              # 8. di:compile → setup:upgrade → flush
```

Full walkthrough, including getting the code into `PROJECT_PATH` and the prod→local DB
reconfiguration: **[docs/ONBOARDING.md](docs/ONBOARDING.md)**.

**→ Already set up and running?** Daily commands and health checks:
**[docs/QUICK_START.md](docs/QUICK_START.md)**.

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

## Prerequisites

Ubuntu (or any Linux with current Docker), **~4 GB free RAM**, **~20 GB free disk**, Docker
24+ / Compose v2, `vm.max_map_count >= 262144`, and Adobe Commerce **EE access keys** to
install dependencies. Full list and resource breakdown:
[docs/STACK_REFERENCE.md](docs/STACK_REFERENCE.md#requirements).

---

## Documentation

| Doc | For |
|---|---|
| [docs/ONBOARDING.md](docs/ONBOARDING.md) | **New teammate?** Full clone → Docker → code → DB → running |
| [docs/QUICK_START.md](docs/QUICK_START.md) | Getting running, daily commands |
| [docs/ENVIRONMENT_ARCHITECTURE.md](docs/ENVIRONMENT_ARCHITECTURE.md) | Directory layout + the version-switchable stack (2.4.7 ↔ 2.4.9) |
| [docs/STACK_REFERENCE.md](docs/STACK_REFERENCE.md) | Layout, how the stack works, design choices, requirements |
| [docs/PHASE_2_UCT_INSIGHTS.md](docs/PHASE_2_UCT_INSIGHTS.md) | 2.4.9 upgrade compatibility findings + backlog |
| [docs/PHASE_3_PLAN.md](docs/PHASE_3_PLAN.md) | Installing or importing Magento |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | When it breaks |
| `make help` | Every available command |
