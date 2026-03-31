.PHONY: base apps build test lint lint-strict test-smoke test-integration audit verify-ghcr validate-ports help clean

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

# Map BASE_DISTRO to Containerfile path
BASE_MAP_centos-stream9  = base/centos/stream9/Containerfile
BASE_MAP_centos-stream10 = base/centos/stream10/Containerfile
BASE_MAP_fedora-40       = base/fedora/40/Containerfile
BASE_MAP_fedora-41       = base/fedora/41/Containerfile
BASE_FILE = $(BASE_MAP_$(BASE_DISTRO))

# ---------------------------------------------------------------------------
# Base Image (Layer 1: OS + tuning, build weekly)
# ---------------------------------------------------------------------------

base: ## Build base image (BASE_DISTRO=centos-stream9|fedora-41|...)
	@if [ -z "$(BASE_FILE)" ]; then \
		echo "ERROR: Unknown BASE_DISTRO=$(BASE_DISTRO)"; \
		echo "       Valid: centos-stream9, centos-stream10, fedora-40, fedora-41"; \
		exit 1; \
	fi
	$(PODMAN) build --isolation chroot -f $(BASE_FILE) \
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

lint: ## Run bootc container lint on the built image
	$(PODMAN) run --rm $(APP_IMAGE_REF):latest bootc container lint

lint-strict: ## Run bootc container lint --fatal-warnings (used in CI)
	$(PODMAN) run --rm $(APP_IMAGE_REF):latest bootc container lint --fatal-warnings || exit 1

# ---------------------------------------------------------------------------
# Local Testing (no cloud deploy needed)
# ---------------------------------------------------------------------------

EXPECTED_BINS ?= hello
EXPECTED_SVCS ?= hello nginx

test-smoke: build ## Smoke test: verify image contents (binaries, units, configs, lint)
	@echo "==> Smoke testing $(APP_IMAGE_REF):latest"
	@$(PODMAN) run --rm $(APP_IMAGE_REF):latest bash -c '\
		FAIL=0; \
		echo "--- Checking binaries ---"; \
		for bin in $(EXPECTED_BINS); do \
			if test -x /usr/bin/$$bin; then echo "  OK: /usr/bin/$$bin"; \
			else echo "  FAIL: /usr/bin/$$bin missing"; FAIL=1; fi; \
		done; \
		echo "--- Checking systemd units ---"; \
		for svc in $(EXPECTED_SVCS); do \
			if systemctl is-enabled $$svc >/dev/null 2>&1; then echo "  OK: $$svc enabled"; \
			else echo "  FAIL: $$svc not enabled"; FAIL=1; fi; \
		done; \
		echo "--- Checking immutable configs ---"; \
		for f in /usr/share/nginx/nginx.conf /usr/share/nginx/conf.d/hello.conf; do \
			if test -f $$f; then echo "  OK: $$f"; \
			else echo "  FAIL: $$f missing"; FAIL=1; fi; \
		done; \
		echo "--- Running bootc lint ---"; \
		bootc container lint || FAIL=1; \
		echo "---"; \
		if [ $$FAIL -eq 0 ]; then echo "ALL SMOKE TESTS PASSED"; \
		else echo "SMOKE TESTS FAILED"; exit 1; fi'

test-integration: build ## Integration test: run app in read-only mode (simulates production)
	@echo "==> Integration testing $(APP_IMAGE_REF):latest (read-only /usr)"
	@$(PODMAN) run --rm \
		--read-only \
		--tmpfs /var:rw,nosuid,nodev \
		--tmpfs /run:rw,nosuid,nodev \
		--tmpfs /tmp:rw,nosuid,nodev \
		$(APP_IMAGE_REF):latest bash -c '\
		echo "--- Verifying tmpfiles.d creates /var dirs ---"; \
		systemd-tmpfiles --create 2>/dev/null; \
		for d in /var/log/nginx /var/lib/testboot; do \
			if test -d $$d; then echo "  OK: $$d"; \
			else echo "  FAIL: $$d not created"; exit 1; fi; \
		done; \
		echo "--- Starting hello service directly ---"; \
		/usr/bin/hello & PID=$$!; sleep 1; \
		RESP=$$(curl -sf http://127.0.0.1:8000/health 2>/dev/null); \
		kill $$PID 2>/dev/null; \
		if echo "$$RESP" | grep -q "ok"; then echo "  OK: hello /health responded"; \
		else echo "  FAIL: hello /health did not respond"; exit 1; fi; \
		echo "ALL INTEGRATION TESTS PASSED"'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ALL_DISTROS = centos-stream9 centos-stream10 fedora-40 fedora-41

audit: apps ## Build + strict-lint ALL base images and app image locally
	@for d in $(ALL_DISTROS); do \
		echo "==> [audit] base $$d"; \
		$(MAKE) base BASE_DISTRO=$$d || exit 1; \
		$(PODMAN) run --rm $(IMAGE_ROOT)/base/$$d:latest \
			bootc container lint --fatal-warnings || exit 1; \
	done
	@echo "==> [audit] app $(BASE_DISTRO)"
	@$(MAKE) build
	@$(PODMAN) run --rm $(APP_IMAGE_REF):latest \
		bootc container lint --fatal-warnings
	@echo "=== ALL AUDIT CHECKS PASSED ==="

validate-ports: ## Validate app port assignments (range, uniqueness, env ↔ nginx)
	@./bootc/libs/common/rootfs/usr/libexec/testboot/validate-ports.sh

verify-ghcr: ## Pull + verify all GHCR packages (scripts/verify-ghcr-packages.sh; needs disk space)
	@./scripts/verify-ghcr-packages.sh

clean: ## Clean build artifacts
	rm -rf output/
	$(PODMAN) rmi -f $(APP_IMAGE_REF):latest 2>/dev/null || true

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
