.PHONY: base apps build test test-all lint \
       test-vm test-vm-upgrade test-vm-ssh \
       audit audit-all manifest scan-image verify-ghcr help clean

# ---------------------------------------------------------------------------
# Variables (override via env or command line)
# Path-style images (parity with CI): $(IMAGE_ROOT)/base/$(BASE_DISTRO):tag and $(IMAGE_ROOT)/$(BASE_DISTRO):tag
# ---------------------------------------------------------------------------
REGISTRY   ?= ghcr.io/duyhenryer
IMAGE_ROOT ?= $(REGISTRY)/bootc-testboot
BASE_IMAGE_REF = $(IMAGE_ROOT)/base/$(BASE_DISTRO)
APP_IMAGE_REF = $(IMAGE_ROOT)/$(BASE_DISTRO)
VERSION    ?= latest
BASE_IMAGE_VERSION ?= $(VERSION)
GIT_SHA    ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
PODMAN     ?= podman

# Base distro selection (centos-stream9 | centos-stream10 | fedora-40 | fedora-41)
BASE_DISTRO ?= centos-stream9

# Override upstream base image tag (e.g. BASE_TAG=stream9-20250414 to pin a specific bootc release)
BASE_TAG    ?=

# Map BASE_DISTRO to Containerfile path
BASE_MAP_centos-stream9  = base/centos/stream9/Containerfile
BASE_MAP_centos-stream10 = base/centos/stream10/Containerfile
BASE_MAP_fedora-40       = base/fedora/40/Containerfile
BASE_MAP_fedora-41       = base/fedora/41/Containerfile
BASE_FILE = $(BASE_MAP_$(BASE_DISTRO))

ALL_DISTROS = centos-stream9 centos-stream10 fedora-40 fedora-41

# ---------------------------------------------------------------------------
# Base Image (Layer 1: OS + tuning, build weekly)
# ---------------------------------------------------------------------------

base: ## Build base image (BASE_DISTRO=centos-stream9|fedora-41|... BASE_TAG= to pin upstream tag)
	@if [ -z "$(BASE_FILE)" ]; then \
		echo "ERROR: Unknown BASE_DISTRO=$(BASE_DISTRO)"; \
		echo "       Valid: centos-stream9, centos-stream10, fedora-40, fedora-41"; \
		exit 1; \
	fi
	$(PODMAN) build --isolation chroot -f $(BASE_FILE) \
		$(if $(BASE_TAG),--build-arg BASE_TAG=$(BASE_TAG)) \
		-t $(BASE_IMAGE_REF):$(VERSION) .

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
	$(PODMAN) build --isolation chroot \
		--build-arg IMAGE_ROOT=$(IMAGE_ROOT) \
		--build-arg BASE_DISTRO=$(BASE_DISTRO) \
		--build-arg BASE_IMAGE_VERSION=$(BASE_IMAGE_VERSION) \
		--build-arg GIT_SHA=$(GIT_SHA) \
		-t $(APP_IMAGE_REF):$(VERSION) .

lint: ## Run bootc container lint --fatal-warnings
	$(PODMAN) run --rm $(APP_IMAGE_REF):$(VERSION) bootc container lint --fatal-warnings

# ---------------------------------------------------------------------------
# VM Testing (requires bcvk + KVM)
# ---------------------------------------------------------------------------

test-vm: build ## VM test: boot as real VM, verify all services (requires bcvk + /dev/kvm)
	@./scripts/vm-test.sh "$(APP_IMAGE_REF):$(VERSION)"

test-all: test lint test-vm ## Run all tests: Go unit, bootc lint, and VM boot test

test-vm-upgrade: build ## VM upgrade test: persistent VM + bootc upgrade + reboot (requires bcvk + libvirt)
	@./scripts/vm-upgrade-test.sh "$(APP_IMAGE_REF):$(VERSION)"

test-vm-ssh: build ## Boot image as VM and SSH in (interactive, auto-cleanup on exit)
	bcvk ephemeral run-ssh "$(APP_IMAGE_REF):$(VERSION)"

# ---------------------------------------------------------------------------
# Audit & Validation
# ---------------------------------------------------------------------------

audit: manifest scan-image ## Local gate: manifest + Trivy (no build)
	@echo "=== audit completed (see output/ for manifest). Also: make test-all ==="

audit-all: apps ## Build + strict-lint ALL base images and app image
	@for d in $(ALL_DISTROS); do \
		echo "==> [audit-all] base $$d"; \
		$(MAKE) base BASE_DISTRO=$$d || exit 1; \
		$(PODMAN) run --rm $(IMAGE_ROOT)/base/$$d:latest \
			bootc container lint --fatal-warnings || exit 1; \
	done
	@echo "==> [audit-all] app $(BASE_DISTRO)"
	@$(MAKE) build
	@$(PODMAN) run --rm $(APP_IMAGE_REF):$(VERSION) \
		bootc container lint --fatal-warnings
	@echo "=== ALL AUDIT CHECKS PASSED ==="

manifest: ## Write podman inspect JSON for $(APP_IMAGE_REF):$(VERSION) to output/
	@mkdir -p output
	@./scripts/image-manifest.sh "$(APP_IMAGE_REF):$(VERSION)"

scan-image: ## Trivy CVE scan (optional; skips if trivy not installed)
	@./scripts/scan-image-trivy.sh "$(APP_IMAGE_REF):$(VERSION)"

verify-ghcr: ## Pull + verify all GHCR packages (needs disk space)
	@./scripts/verify-ghcr-packages.sh

clean: ## Clean build artifacts
	rm -rf output/
	$(PODMAN) rmi -f $(APP_IMAGE_REF):$(VERSION) 2>/dev/null || true

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
