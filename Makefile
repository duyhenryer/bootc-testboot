.PHONY: apps build test lint lint-strict ami vmdk ova \
       os-upgrade os-apply os-rollback os-status verify \
       help clean

# ---------------------------------------------------------------------------
# Variables (override via env or command line)
# ---------------------------------------------------------------------------
REGISTRY   ?= ghcr.io/duyhenryer
IMAGE      ?= $(REGISTRY)/bootc-testboot
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
AWS_REGION ?= ap-southeast-1
AWS_BUCKET ?= my-bootc-poc-bucket
PODMAN     ?= podman
# Workaround: fedora-bootc + rootless runc can fail mounting /etc/resolv.conf.
# chroot isolation avoids the runc mount path and builds reliably.
BUILD_FLAGS ?= --isolation=chroot

# ---------------------------------------------------------------------------
# Apps (build Go binaries to output/bin/)
# ---------------------------------------------------------------------------

apps: ## Build all Go apps to output/bin/
	@mkdir -p output/bin
	@for d in apps/*/; do \
		name=$$(basename "$$d"); \
		echo "==> Building $$name"; \
		(cd "$$d" && CGO_ENABLED=0 go build \
			-ldflags="-s -w -X main.version=$(VERSION)" \
			-o ../../output/bin/$$name .); \
	done

test: ## Run Go tests for all apps
	@for d in apps/*/; do \
		echo "==> Testing $$d"; \
		(cd "$$d" && go test -v ./...); \
	done

# ---------------------------------------------------------------------------
# Image (Containerfile COPYs pre-built binaries from output/bin/)
# ---------------------------------------------------------------------------

build: apps ## Build bootc image (pre-builds apps, then assembles OS)
	$(PODMAN) build $(BUILD_FLAGS) -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

lint: ## Run bootc container lint on the built image
	$(PODMAN) run --rm $(IMAGE):$(VERSION) bootc container lint

lint-strict: ## Run bootc container lint --fatal-warnings (used in CI)
	$(PODMAN) run --rm $(IMAGE):$(VERSION) bootc container lint --fatal-warnings

# ---------------------------------------------------------------------------
# Disk Images (bootc-image-builder)
# ---------------------------------------------------------------------------

ami: ## Create AMI via bootc-image-builder (auto-upload to AWS)
	scripts/create-ami.sh

vmdk: ## Create VMDK disk image via bootc-image-builder
	scripts/create-vmdk.sh

ova: vmdk ## Create OVA from VMDK (VMDK + OVF -> .ova tar)
	scripts/create-ova.sh

# ---------------------------------------------------------------------------
# Operations (run ON the EC2 instance)
# ---------------------------------------------------------------------------

os-upgrade: ## Download-only upgrade (safe for business hours)
	sudo bootc upgrade --download-only
	sudo bootc status --verbose

os-apply: ## Apply staged upgrade + reboot
	sudo bootc upgrade --from-downloaded --apply

os-rollback: ## Rollback to previous deployment + reboot
	scripts/rollback-os.sh

os-status: ## Show bootc status
	sudo bootc status

verify: ## Post-boot health checks
	scripts/verify-instance.sh

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

clean: ## Clean build artifacts
	rm -rf output/
	$(PODMAN) rmi -f $(IMAGE):$(VERSION) 2>/dev/null || true

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
