.PHONY: base apps build test lint lint-strict ami vmdk ova gce qcow2 \
       help clean

# ---------------------------------------------------------------------------
# Variables (override via env or command line)
# ---------------------------------------------------------------------------
REGISTRY   ?= ghcr.io/duyhenryer
IMAGE      ?= $(REGISTRY)/bootc-testboot
BASE_IMAGE ?= $(REGISTRY)/bootc-testboot-base
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PODMAN     ?= podman

# Base distro selection (centos-stream9 | centos-stream10 | fedora-40 | fedora-41)
BASE_DISTRO ?= centos-stream9

# Map BASE_DISTRO to Containerfile path
BASE_MAP_centos-stream9  = base/centos/stream9/Containerfile
BASE_MAP_centos-stream10 = base/centos/stream10/Containerfile
BASE_MAP_fedora-40       = base/fedora/40/Containerfile
BASE_MAP_fedora-41       = base/fedora/41/Containerfile
BASE_FILE = $(BASE_MAP_$(BASE_DISTRO))

# Cloud config
AWS_REGION ?= ap-southeast-1
AWS_BUCKET ?= my-bootc-poc-bucket

# ---------------------------------------------------------------------------
# Base Image (Layer 1: OS + tuning, build weekly)
# ---------------------------------------------------------------------------

base: ## Build base image (BASE_DISTRO=centos-stream9|fedora-41|...)
	@if [ -z "$(BASE_FILE)" ]; then \
		echo "ERROR: Unknown BASE_DISTRO=$(BASE_DISTRO)"; \
		echo "       Valid: centos-stream9, centos-stream10, fedora-40, fedora-41"; \
		exit 1; \
	fi
	$(PODMAN) build -f $(BASE_FILE) \
		-t $(BASE_IMAGE)-$(BASE_DISTRO):$(VERSION) \
		-t $(BASE_IMAGE)-$(BASE_DISTRO):latest .

# ---------------------------------------------------------------------------
# Apps (build Go binaries to output/bin/)
# ---------------------------------------------------------------------------

apps: ## Build all Go apps to output/bin/
	@mkdir -p output/bin
	@for d in repos/*/; do \
		name=$$(basename "$$d"); \
		if [ -f "$$d/go.mod" ]; then \
			echo "==> Building $$name"; \
			(cd "$$d" && CGO_ENABLED=0 go build \
				-ldflags="-s -w -X main.version=$(VERSION)" \
				-o ../../output/bin/$$name .); \
		fi; \
	done

test: ## Run Go tests for all apps
	@for d in repos/*/; do \
		if [ -f "$$d/go.mod" ]; then \
			echo "==> Testing $$d"; \
			(cd "$$d" && go test -v ./...); \
		fi; \
	done

# ---------------------------------------------------------------------------
# Application Image (Layer 2: middleware + apps, build per commit)
# ---------------------------------------------------------------------------

build: apps ## Build application image (uses base, BASE_DISTRO=centos-stream9|...)
	$(PODMAN) build \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		--build-arg BASE_DISTRO=$(BASE_DISTRO) \
		-t $(IMAGE):$(BASE_DISTRO)-$(VERSION) \
		-t $(IMAGE):latest .

lint: ## Run bootc container lint on the built image
	$(PODMAN) run --rm $(IMAGE):latest bootc container lint

lint-strict: ## Run bootc container lint --fatal-warnings
	$(PODMAN) run --rm $(IMAGE):latest bootc container lint --fatal-warnings

# ---------------------------------------------------------------------------
# Disk Images (bootc-image-builder)
# ---------------------------------------------------------------------------

ami: ## Create AMI via bootc-image-builder (auto-upload to AWS)
	scripts/create-image.sh ami

vmdk: ## Create VMDK disk image
	scripts/create-image.sh vmdk

qcow2: ## Create qcow2 for KVM/libvirt testing
	scripts/create-image.sh qcow2

gce: ## Create GCE image (build + upload to GCP)
	scripts/create-image.sh gce

ova: vmdk ## Create OVA from VMDK (VMDK + OVF -> .ova tar)
	scripts/create-ova.sh

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

clean: ## Clean build artifacts
	rm -rf output/
	$(PODMAN) rmi -f $(IMAGE):latest 2>/dev/null || true

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
