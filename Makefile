.PHONY: help docker-build deps lint validate snapshot-update snapshot-diff security bump ci

# ============================================================================
# Configuration
# ============================================================================
CHART_PATH          ?= .
KUBERNETES_VERSION  ?= 1.30.0
SCENARIOS_DIR       ?= tests/scenarios
SNAPSHOTS_DIR       ?= tests/snapshots

# Docker configuration
DOCKER_IMAGE        ?= helm-validate:local
BUILD_WORKFLOW      ?= ../build-workflow

# Resolve BUILD_WORKFLOW to absolute path for Docker mount
BW_ABS_PATH := $(shell cd $(BUILD_WORKFLOW) 2>/dev/null && pwd)

# Version check: disabled for local dev (CI sets to true)
RUN_VERSION_CHECK ?= false

# Docker run base command
DOCKER_RUN = docker run --rm \
	-v $(shell pwd):/workspace \
	-v $(BW_ABS_PATH):/opt/build-workflow \
	-w /workspace \
	-e CHART_PATH=$(CHART_PATH) \
	-e KUBERNETES_VERSION=$(KUBERNETES_VERSION) \
	-e SCENARIOS_DIR=$(SCENARIOS_DIR) \
	-e SNAPSHOTS_DIR=$(SNAPSHOTS_DIR) \
	-e CONFIGS_DIR=/opt/build-workflow/configs \
	-e RUN_VERSION_CHECK=$(RUN_VERSION_CHECK) \
	$(DOCKER_IMAGE)

SCRIPTS = /opt/build-workflow/scripts

# ============================================================================
# Targets
# ============================================================================

help: ## Show this help message
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

docker-build: ## Build the validation Docker image locally
	@echo "Building validation Docker image ($(DOCKER_IMAGE))..."
	@docker build -t $(DOCKER_IMAGE) $(BW_ABS_PATH)/docker/

deps: ## Build Helm chart dependencies from Chart.lock
	@echo "Building chart dependencies..."
	@if ! $(DOCKER_RUN) -c "helm dependency build $(CHART_PATH)"; then \
		echo ""; \
		echo "Dependency build failed."; \
		echo "If your validation image is hosted in GHCR, authenticate Docker first:"; \
		echo "  echo <TOKEN> | docker login ghcr.io -u <USER> --password-stdin"; \
		exit 1; \
	fi

lint: deps ## Run syntax checks (yamllint + helm lint --strict)
	@$(DOCKER_RUN) $(SCRIPTS)/validate-syntax.sh

validate: deps ## Run full validation pipeline (all layers, sequential)
	@$(DOCKER_RUN) $(SCRIPTS)/validate-orchestrator.sh

snapshot-update: deps ## Regenerate snapshots from all scenarios
	@echo "Updating snapshots for all scenarios..."
	@$(DOCKER_RUN) $(SCRIPTS)/update-snapshots.sh
	@echo ""
	@echo "Snapshots updated. Review changes with: make snapshot-diff"

snapshot-diff: ## Show snapshot differences
	@echo "Snapshot differences:"
	@git diff --stat $(SNAPSHOTS_DIR)/ || true
	@echo ""
	@git diff $(SNAPSHOTS_DIR)/ || true

security: deps ## Run security checks (checkov + kube-linter)
	@$(DOCKER_RUN) $(SCRIPTS)/validate-policy.sh

bump: ## Bump chart version, refresh lock, and regenerate snapshots (requires VERSION=x.y.z)
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is required. Usage: make bump VERSION=x.y.z"; \
		exit 1; \
	fi
	@./scripts/bump-version.sh $(VERSION)

ci: validate ## Run local CI equivalent (reusable 5-layer pipeline)
	@echo ""
	@echo "All CI checks passed!"
