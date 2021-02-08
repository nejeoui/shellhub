ifneq (,$(wildcard ./.env.override))
    include .env.override
    export
endif

DOCKER_COMPOSE = ./bin/docker-compose

define COMPOSE_TEMPLATE
version: '3.7'
services:
  mongo:
    image: mongo:_VERSION_
endef

export $COMPOSE_TEMPLATE

# Generate required private key for api service
api_private_key:
	@openssl genrsa -out api_private_key 2048

# Generate required public key for api service
api_public_key:
	@openssl rsa -in api_private_key -out api_public_key -pubout

# Generate required private key for ssh service
ssh_private_key:
	@openssl genrsa -out ssh_private_key 2048

.PHONY: setup
# Setup required files
setup: api_private_key api_public_key ssh_private_key

.PHONY: start
## Start services
start: setup 
ifeq ($(SHELLHUB_ENV),development)
	@echo Starting ShellHub in development mode...
	@echo
	@$(DOCKER_COMPOSE) up
else
	@echo Starting ShellHub in production mode...
	@echo

	@$(DOCKER_COMPOSE) up -d
endif

.PHONY: stop
## Stop services
stop:
	@$(DOCKER_COMPOSE) stop

.PHONY: build
## Build all services (append "SERVICE=<service>" to build a specific one)
build: check_development_mode
	@$(DOCKER_COMPOSE) build $(SERVICE)

.PHONY: check_development
# Check for development mode
check_development_mode:
ifneq ($(SHELLHUB_ENV),development)
	@echo Development mode disabled!
	@exit 1
endif

.SILENT:
.ONESHELL:
upgrade_mongodb: SHELL := sh
upgrade_mongodb:
	# Wait for mongodb to be available
	wait_for_mongo() {
		# Command used to ping mongodb
		MONGO_PING_CMD=$$(cat <<-EOF
			db.runCommand({ ping: 1 })
		EOF
		)

		while ! $(DOCKER_COMPOSE) exec mongo mongo --quiet --eval "quit($${MONGO_PING_CMD}.ok ? 0 : 1)" >/dev/null 2>&1; do
			sleep 1
		done
	}

	# Start mongodb using version provided by $1
	start_mongodb() {
		# Convert version to suitable format for 'setFeatureCompatibilityVersion'
		SERIES_VERSION=$$(echo $$1 | sed 's,\.[0-9]\+$$,,g')

		export EXTRA_COMPOSE_FILE=$$(mktemp)
		echo "$$COMPOSE_TEMPLATE" | sed "s,_VERSION_,$$1,g" > $$EXTRA_COMPOSE_FILE

		$(DOCKER_COMPOSE) stop mongo
		$(DOCKER_COMPOSE) up -d mongo

		wait_for_mongo

		# Command used to set compatibility version
		MONGO_SET_COMPAT_VERSION_CMD=$$(cat <<-EOF
			db.adminCommand({
				setFeatureCompatibilityVersion: '$$SERIES_VERSION'
			})
		EOF
		)

		$(DOCKER_COMPOSE) exec mongo mongo --quiet --eval "quit($${MONGO_SET_COMPAT_VERSION_CMD}.ok ? 1 : 0)"
	}

	MONGO_CONTAINER_ID=$$($(DOCKER_COMPOSE) images -q mongo)
	CURRENT_MONGO_VERSION=$$(docker image inspect \
		--format '{{range .RepoTags}}{{.}} {{end}}' \
		$$MONGO_CONTAINER_ID | tr -d ' ' | rev | cut -d' ' -f1 | rev | cut -d':' -f2
	)

	[[ $$CURRENT_MONGO_VERSION == 4.2* ]] && exit 0

	echo "Upgrading MongoDB instance..."

	start_mongodb $$CURRENT_MONGO_VERSION

	# Command used to get compatibility version
	MONGO_GET_COMPAT_VERSION_CMD=$$(cat <<-EOF
		db.adminCommand({
			getParameter: 1,
			featureCompatibilityVersion: 1
		})['featureCompatibilityVersion']
	EOF
	)

	# Before upgrading to 4.2-series, we need to upgrade earlier versions first
	while true; do
		# Starting from 4.0-series the 'featureCompatibilityVersion' is a object with a 'version' key
		MONGO_COMPAT_VERSION=$$($(DOCKER_COMPOSE) exec mongo mongo \
			--quiet \
			--eval "$${MONGO_GET_COMPAT_VERSION_CMD}.version" | tr -d '\r'
		)

		# Fallback to 3.0-series where the 'featureCompatibilityVersion' is a integer with the version
		if [ -z "$$MONGO_COMPAT_VERSION" ]; then
			MONGO_COMPAT_VERSION=$$($(DOCKER_COMPOSE) exec mongo mongo \
				--quiet \
				--eval "$$MONGO_GET_COMPAT_VERSION_CMD" | tr -d '\r'
			)
		fi

		case $$MONGO_COMPAT_VERSION in
			3.4*)
				echo "Upgrading MongoDB from 3.4-series to 3.6-series..."
				start_mongodb 3.6.21
				;;
			3.6*)
				echo "Upgrading MongoDB from 3.6-series to 4.0-series..."
				start_mongodb 4.0.22
				;;
			4.0*)
				echo "Upgrading MongoDB from 4.0-series to 4.2-series..."
				start_mongodb 4.2.12
				;;
			4.2*)
				echo "MongoDB upgrade successful!"
				break
				;;
	      esac
	done

	$(DOCKER_COMPOSE) stop mongo

.PHONY: help
help:
	@echo "$$(tput bold)Available commands:$$(tput sgr0)";echo;sed -ne"/^## /{h;s/.*//;:d" -e"H;n;s/^## //;td" -e"s/:.*//;G;s/\\n## /---/;s/\\n/ /g;p;}" ${MAKEFILE_LIST}|LC_ALL='C' sort -f|awk -F --- -v n=$$(tput cols) -v i=19 -v a="$$(tput setaf 6)" -v z="$$(tput sgr0)" '{printf"%s%*s%s ",a,-i,$$1,z;m=split($$2,w," ");l=n-i;for(j=1;j<=m;j++){l-=length(w[j])+1;if(l<= 0){l=n-i-length(w[j])-1;printf"\n%*s ",-i," ";}printf"%s ",w[j];}printf"\n";}'|more $(shell test $(shell uname) == Darwin && echo '-Xr')

.DEFAULT_GOAL := help
