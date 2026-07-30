################################################################################
# Adobe Commerce 2.4.9 Development Stack
# Run `make` or `make help` for the full list of targets.
################################################################################

.DEFAULT_GOAL := help
SHELL := /bin/bash

DC      := docker compose
# Magento and Composer must run as www-data. Running them as root leaves
# root-owned files in your bind mount that you then cannot edit on the host.
PHP     := $(DC) exec -u www-data php
PHP_TTY := $(DC) exec -T -u www-data php
MAGE    := $(PHP) php bin/magento

GREEN := \033[0;32m
YELLOW:= \033[1;33m
RED   := \033[0;31m
NC    := \033[0m

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  Adobe Commerce upgrade stack (2.4.7 <-> 2.4.9)"
	@echo "  =============================================="
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

################################################################################
# Lifecycle
################################################################################

.PHONY: init
init: ## First-time setup (creates .env, dirs, permissions)
	@./init-project.sh

.PHONY: up
up: check-env ## Start the stack
	@$(DC) up -d
	@echo -e "$(GREEN)Stack starting. Watch readiness with: make status$(NC)"

.PHONY: down
down: ## Stop the stack (data is kept)
	@$(DC) down

.PHONY: restart
restart: down up ## Restart the stack

.PHONY: build
build: check-env ## Build the PHP and Nginx images
	@$(DC) build

.PHONY: rebuild
rebuild: check-env ## Rebuild images from scratch, ignoring cache
	@$(DC) build --no-cache
	@$(DC) up -d --force-recreate

.PHONY: status
status: ## Show container health
	@$(DC) ps

.PHONY: logs
logs: ## Tail logs from all services (SERVICE=php to narrow)
	@$(DC) logs -f --tail=100 $(SERVICE)

.PHONY: ports
ports: ## Check that required host ports are free
	@./scripts/port-check.sh

.PHONY: net-check
net-check: ## Diagnose container internet access (run this if composer/downloads hang)
	@./scripts/net-check.sh

.PHONY: config
config: ## Validate and render the compose file
	@$(DC) config

################################################################################
# Version profiles (2.4.7 baseline <-> 2.4.9 target)
################################################################################

.PHONY: profile-247
profile-247: ## Switch .env to the 2.4.7 baseline (PHP 8.3 / MariaDB 10.6 / OpenSearch 2)
	@$(MAKE) --no-print-directory _apply-profile PROFILE=247

.PHONY: profile-249
profile-249: ## Switch .env to the 2.4.9 target (PHP 8.5 / MariaDB 11.4 / OpenSearch 3)
	@$(MAKE) --no-print-directory _apply-profile PROFILE=249

.PHONY: profile-status
profile-status: ## Show the active profile + versions (from .env)
	@[ -f .env ] || { echo -e "$(RED).env missing.$(NC) Run 'make init' first."; exit 1; }
	@mage=$$(grep -E '^MAGENTO_VERSION=' .env | cut -d= -f2-); \
	 php=$$(grep -E '^PHP_TAG=' .env | cut -d= -f2-); \
	 db=$$(grep -E '^DB_IMAGE=' .env | cut -d= -f2-); \
	 os=$$(grep -E '^OPENSEARCH_VERSION=' .env | cut -d= -f2-); \
	 case "$$mage" in 2.4.7*) prof="247 (baseline)";; 2.4.9*) prof="249 (target)";; *) prof="?";; esac; \
	 echo -e "$(GREEN)Active profile: $$prof$(NC)  Adobe Commerce $$mage"; \
	 echo    "  PHP $$php | $$db | OpenSearch $$os | Valkey 8"

.PHONY: _apply-profile
_apply-profile:
	@[ -f .env ] || { echo -e "$(RED).env missing.$(NC) Run 'make init' first."; exit 1; }
	@[ -f .env.$(PROFILE) ] || { echo -e "$(RED).env.$(PROFILE) not found.$(NC)"; exit 1; }
	@# Update each KEY=VALUE from the preset in .env (replace in place, or append
	@# if the key is absent). Comment lines in the preset are skipped.
	@while IFS='=' read -r key val; do \
		case "$$key" in ''|\#*) continue;; esac; \
		if grep -qE "^$$key=" .env; then \
			sed -i "s|^$$key=.*|$$key=$$val|" .env; \
		else \
			printf '%s=%s\n' "$$key" "$$val" >> .env; \
		fi; \
	done < .env.$(PROFILE)
	@echo -e "$(GREEN)Switched to profile $(PROFILE).$(NC) Now run: make build && make up"
	@grep -E '^(PHP_TAG|DB_IMAGE|OPENSEARCH_VERSION|MAGENTO_VERSION)=' .env | sed 's/^/  /'
	@echo -e "$(YELLOW)Note:$(NC) the DB engine differs across profiles (MariaDB 10.6 vs 11.4)."
	@echo    "      Switching wipes the DB volume — back up first with 'make db-backup'."

################################################################################
# Shells
################################################################################

.PHONY: shell
shell: ## Shell into the PHP container as www-data
	@$(PHP) bash

.PHONY: root-shell
root-shell: ## Shell into the PHP container as root (for apt, etc.)
	@$(DC) exec php bash

.PHONY: mysql-shell
mysql-shell: ## Open a MySQL prompt on the Magento database
	@$(DC) exec -e MYSQL_PWD="$$(grep -E '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)" \
		mysql mysql -u root "$$(grep -E '^MYSQL_DATABASE=' .env | cut -d= -f2-)"

################################################################################
# Magento
################################################################################

.PHONY: magento-cmd
magento-cmd: ## Run any bin/magento command. Usage: make magento-cmd CMD='cache:status'
	@if [ -z "$(CMD)" ]; then \
		echo -e "$(RED)Set CMD. Example: make magento-cmd CMD='setup:upgrade'$(NC)"; exit 1; \
	fi
	@$(MAGE) $(CMD)

.PHONY: composer
composer: ## Run any composer command with the EE key injected. Usage: make composer CMD='update --dry-run'
	@if [ -z "$(CMD)" ]; then \
		echo -e "$(RED)Set CMD. Example: make composer CMD='update --dry-run'$(NC)"; exit 1; \
	fi
	@# The clone's auth.json holds the CE key; inject the EE key from
	@# scripts/.composer-auth.json (overrides it) + unlimited memory, so any
	@# command touching Adobe Commerce packages works.
	@$(DC) exec -u www-data \
		-e COMPOSER_AUTH="$$(cat scripts/.composer-auth.json)" \
		-e COMPOSER_MEMORY_LIMIT=-1 \
		php composer $(CMD)

.PHONY: flush
flush: ## Flush Magento cache
	@$(MAGE) cache:flush

.PHONY: upgrade
upgrade: ## setup:upgrade + di:compile + cache flush
	@$(MAGE) setup:upgrade
	@$(MAGE) setup:di:compile
	@$(MAGE) cache:flush

.PHONY: reindex
reindex: ## Reindex all Magento indexers
	@$(MAGE) indexer:reindex

.PHONY: dev-mode
dev-mode: ## Switch Magento into developer mode
	@$(MAGE) deploy:mode:set developer

.PHONY: fix-perms
fix-perms: ## Fix ownership/permissions inside the Magento tree
	@$(DC) exec php bash -c 'chown -R www-data:www-data /var/www/magento && \
		find /var/www/magento/var /var/www/magento/generated /var/www/magento/pub/static \
		     /var/www/magento/pub/media /var/www/magento/app/etc \
		     -type d -exec chmod 2775 {} + 2>/dev/null; \
		find /var/www/magento/var /var/www/magento/generated /var/www/magento/pub/static \
		     /var/www/magento/pub/media /var/www/magento/app/etc \
		     -type f -exec chmod 0664 {} + 2>/dev/null; \
		chmod u+x /var/www/magento/bin/magento 2>/dev/null; true'
	@echo -e "$(GREEN)Permissions fixed.$(NC)"

################################################################################
# Magento installation (Phase 3)
#
# Edition comes from MAGENTO_EDITION in .env and maps to the repo.magento.com
# metapackage:
#   community  -> magento/project-community-edition   (Open Source, free)
#   enterprise -> magento/project-enterprise-edition  (Adobe Commerce, licensed)
################################################################################

CODE_DIR := volumes/code

.PHONY: magento-install
magento-install: check-env magento-download magento-setup ## Full install: download source + setup:install + post-config
	@echo -e "$(GREEN)Magento install complete.$(NC) Storefront: $$(grep -E '^BASE_URL=' .env | cut -d= -f2-)"
	@echo -e "$(YELLOW)Take a baseline backup now:$(NC) make db-backup LABEL=post-install"

.PHONY: magento-download
magento-download: check-env ## Download Magento source via Composer (edition from .env)
	@if [ ! -s scripts/.composer-auth.json ] || ! grep -q repo.magento.com scripts/.composer-auth.json; then \
		echo -e "$(RED)No Composer credentials found.$(NC) Run: make composer-auth"; exit 1; \
	fi
	@# Refuse only on a REAL install (bin/magento or a generated env.php). A bare
	@# composer.json is a failed/partial download — safe to clear and retry, which
	@# is what the find below does so a re-run just works.
	@if [ -f $(CODE_DIR)/bin/magento ] || [ -f $(CODE_DIR)/app/etc/env.php ]; then \
		echo -e "$(RED)$(CODE_DIR) already contains a Magento install.$(NC)"; \
		echo "Run 'make magento-uninstall' first to reinstall from scratch."; exit 1; \
	fi
	@edition=$$(grep -E '^MAGENTO_EDITION=' .env | cut -d= -f2- | tr -d "\"' "); \
	 version=$$(grep -E '^MAGENTO_VERSION=' .env | cut -d= -f2- | tr -d "\"' "); \
	 case "$$edition" in \
	   community|enterprise) ;; \
	   *) echo -e "$(RED)MAGENTO_EDITION must be 'community' or 'enterprise' (got '$$edition').$(NC)"; exit 1;; \
	 esac; \
	 pkg="magento/project-$$edition-edition=$$version"; \
	 echo -e "$(GREEN)Downloading $$pkg (10-20 min on first run)...$(NC)"; \
	 find $(CODE_DIR) -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; \
	 $(PHP) composer create-project --no-interaction \
	   --repository-url=https://repo.magento.com/ "$$pkg" /var/www/magento

.PHONY: magento-setup
magento-setup: check-env ## Run setup:install against the running stack + post-config
	@if [ ! -f $(CODE_DIR)/composer.json ]; then \
		echo -e "$(RED)No Magento source in $(CODE_DIR).$(NC) Run 'make magento-download' first."; exit 1; \
	fi
	@if $(MAGE) setup:db:status >/dev/null 2>&1; then \
		echo -e "$(RED)Magento already appears installed (app/etc/env.php exists).$(NC)"; \
		echo "Run 'make magento-uninstall' first, or 'make upgrade' to apply changes."; exit 1; \
	fi
	@echo -e "$(GREEN)Running setup:install (several minutes)...$(NC)"
	@set -a; . <(grep -vE '^(UID|GID)=' .env); set +a; \
	 $(MAGE) setup:install \
	   --base-url="$$BASE_URL" \
	   --db-host=mysql --db-name="$$MYSQL_DATABASE" \
	   --db-user="$$MYSQL_USER" --db-password="$$MYSQL_PASSWORD" \
	   --admin-firstname="$$ADMIN_FIRSTNAME" --admin-lastname="$$ADMIN_LASTNAME" \
	   --admin-email="$$ADMIN_EMAIL" --admin-user="$$ADMIN_USER" \
	   --admin-password="$$ADMIN_PASSWORD" \
	   --language=en_US --currency=USD --timezone=UTC --use-rewrites=1 \
	   --search-engine=opensearch \
	   --opensearch-host=opensearch --opensearch-port=9200 \
	   --opensearch-index-prefix=magento2 --opensearch-timeout=15 \
	   --session-save=redis --session-save-redis-host=valkey \
	   --session-save-redis-port=6379 --session-save-redis-db=2 \
	   --cache-backend=redis --cache-backend-redis-server=valkey \
	   --cache-backend-redis-port=6379 --cache-backend-redis-db=0 \
	   --page-cache=redis --page-cache-redis-server=valkey \
	   --page-cache-redis-port=6379 --page-cache-redis-db=1
	@echo -e "$(GREEN)Setting developer mode and finishing up...$(NC)"
	@$(MAGE) deploy:mode:set developer
	@$(MAKE) --no-print-directory fix-perms
	@$(MAGE) indexer:reindex
	@$(MAGE) cache:flush

.PHONY: magento-uninstall
magento-uninstall: ## Remove Magento: drop DB + wipe code dir (asks first). Stack must be up.
	@if ! $(DC) ps mysql 2>/dev/null | grep -qE 'Up|running'; then \
		echo -e "$(RED)MySQL is not running.$(NC) Start the stack first: make up"; exit 1; \
	fi
	@echo -e "$(RED)This DROPS the Magento database and DELETES everything in $(CODE_DIR).$(NC)"
	@read -p "Type 'uninstall' to confirm: " c; \
	if [ "$$c" != "uninstall" ]; then echo "Aborted; nothing changed."; exit 1; fi; \
	set -a; . <(grep -vE '^(UID|GID)=' .env); set +a; \
	echo "Recreating empty database $$MYSQL_DATABASE ..."; \
	$(DC) exec -T -e MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" mysql \
	  mysql -u root -e "DROP DATABASE IF EXISTS \`$$MYSQL_DATABASE\`; CREATE DATABASE \`$$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; GRANT ALL ON \`$$MYSQL_DATABASE\`.* TO '$$MYSQL_USER'@'%'; FLUSH PRIVILEGES;"; \
	echo "Wiping $(CODE_DIR) ..."; \
	$(DC) exec -T php bash -c 'rm -rf /var/www/magento/* /var/www/magento/.[!.]* 2>/dev/null; true'; \
	touch $(CODE_DIR)/.gitkeep; \
	echo -e "$(GREEN)Uninstalled. Ready for a fresh 'make magento-install'.$(NC)"

################################################################################
# Credentials
################################################################################

.PHONY: composer-auth
composer-auth: ## Set up repo.magento.com credentials
	@./scripts/composer-auth.sh

.PHONY: composer-validate
composer-validate: ## Check that stored Composer credentials still work
	@# PHP code must stay on ONE physical line: it is passed to `php -r` inside
	@# single quotes, and PHP does not treat a backslash-newline as a line
	@# continuation the way bash does — splitting it makes PHP see a literal '\'.
	@#
	@# CONNECTTIMEOUT/TIMEOUT are mandatory, not tuning. libcurl's DEFAULT connect
	@# timeout is 300s, so on a host whose container has no egress this target hung
	@# for a full 5 minutes and then blamed the credentials. Exit codes now separate
	@# the three outcomes: 2 = no auth entry, 3 = never reached the host (HTTP code
	@# 0, a network fault), 1 = the server actually rejected the keys.
	@$(PHP_TTY) php -r '$$a=json_decode(file_get_contents("/var/www/.composer/auth.json"),true)["http-basic"]["repo.magento.com"]??null; if(!$$a){fwrite(STDERR,"no repo.magento.com entry in auth.json\n");exit(2);} $$ch=curl_init("https://repo.magento.com/packages.json"); curl_setopt_array($$ch,[CURLOPT_USERPWD=>$$a["username"].":".$$a["password"],CURLOPT_RETURNTRANSFER=>true,CURLOPT_NOBODY=>true,CURLOPT_CONNECTTIMEOUT=>10,CURLOPT_TIMEOUT=>25]); curl_exec($$ch); $$c=curl_getinfo($$ch,CURLINFO_HTTP_CODE); if($$c===0){fwrite(STDERR,"could not reach repo.magento.com: ".curl_error($$ch)."\n");exit(3);} exit($$c===200?0:1);'; \
	 rc=$$?; \
	 case $$rc in \
	   0) echo -e "$(GREEN)Composer credentials are valid.$(NC)" ;; \
	   2) echo -e "$(RED)No repo.magento.com entry in auth.json.$(NC) Run: make composer-auth"; exit 1 ;; \
	   3) echo -e "$(RED)Could not reach repo.magento.com — a NETWORK fault, not your keys.$(NC)"; \
	      echo -e "$(YELLOW)Diagnose it with: make net-check$(NC)"; exit 1 ;; \
	   *) echo -e "$(RED)repo.magento.com rejected these keys. Re-run: make composer-auth$(NC)"; exit 1 ;; \
	 esac

################################################################################
# Database
################################################################################

.PHONY: db-backup
db-backup: ## Dump the database to volumes/backups/
	@./scripts/backup-db.sh $(LABEL)

.PHONY: db-restore
db-restore: ## Restore a dump. Usage: make db-restore FILE=volumes/backups/x.sql.gz
	@if [ -z "$(FILE)" ]; then \
		echo -e "$(RED)Set FILE. Example: make db-restore FILE=volumes/backups/dump.sql.gz$(NC)"; \
		ls -1sh volumes/backups/*.sql* 2>/dev/null || true; exit 1; \
	fi
	@./scripts/restore-db.sh $(FILE)

################################################################################
# Services
################################################################################

.PHONY: nginx-reload
nginx-reload: ## Test and reload Nginx config without dropping connections
	@$(DC) exec nginx nginx -t && $(DC) exec nginx nginx -s reload
	@echo -e "$(GREEN)Nginx reloaded.$(NC)"

.PHONY: opensearch-health
opensearch-health: ## Show OpenSearch cluster health
	@curl -fsS "http://localhost:$$(grep -E '^OPENSEARCH_PORT=' .env | cut -d= -f2-)/_cluster/health?pretty" \
		|| echo -e "$(RED)OpenSearch is not responding.$(NC)"

.PHONY: xdebug-on
xdebug-on: ## Turn Xdebug on and restart PHP
	@sed -i 's/^XDEBUG_ENABLED=.*/XDEBUG_ENABLED=1/' .env
	@$(DC) up -d --force-recreate php
	@echo -e "$(GREEN)Xdebug on. Trigger with the XDEBUG_TRIGGER cookie or ?XDEBUG_TRIGGER=1$(NC)"

.PHONY: xdebug-off
xdebug-off: ## Turn Xdebug off and restart PHP
	@sed -i 's/^XDEBUG_ENABLED=.*/XDEBUG_ENABLED=0/' .env
	@$(DC) up -d --force-recreate php
	@echo -e "$(GREEN)Xdebug off.$(NC)"

################################################################################
# Teardown
################################################################################

.PHONY: clean
clean: ## Remove containers and networks. Volumes and code are kept.
	@$(DC) down --remove-orphans
	@echo -e "$(GREEN)Containers removed. Data volumes untouched.$(NC)"

.PHONY: destroy
destroy: ## DELETE ALL DATA - containers, volumes, database. Asks first.
	@echo -e "$(RED)This deletes the database, OpenSearch indexes, and all volumes.$(NC)"
	@echo -e "$(YELLOW)Your source code in the bind mount is NOT touched.$(NC)"
	@read -p "Type 'destroy' to confirm: " c; \
	if [ "$$c" = "destroy" ]; then \
		$(DC) down -v --remove-orphans; \
		echo -e "$(GREEN)All volumes removed.$(NC)"; \
	else \
		echo "Aborted; nothing was changed."; \
	fi

################################################################################
# Guards
################################################################################

.PHONY: check-env
check-env:
	@docker compose version >/dev/null 2>&1 || { \
		echo -e "$(RED)Docker Compose v2 is required$(NC) (this stack uses 'docker compose', not the v1 'docker-compose')."; \
		echo    "Install it:  sudo apt-get install docker-compose-plugin   (or re-run: sudo bash docker-setup.sh)"; \
		echo    "Then check:  docker compose version"; \
		exit 1; \
	}
	@if [ ! -f .env ]; then \
		echo -e "$(RED).env is missing.$(NC) Run 'make init' first."; exit 1; \
	fi
	@if grep -qE '^(MYSQL_ROOT_PASSWORD|MYSQL_PASSWORD)=CHANGE_ME' .env; then \
		echo -e "$(RED).env still has placeholder passwords.$(NC) Edit it before starting."; exit 1; \
	fi
