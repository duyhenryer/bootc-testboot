# Test Case Registry

This document catalogues every test case used to validate the bootc image, both automated (Makefile targets) and manual (exec-based audits). Use this as a reference when writing formal unit tests, integration tests, or e2e test suites.

---

## Test Summary

| ID | Category | Name | Automation | Status |
|----|----------|------|------------|--------|
| TC-01 | Unit | Go unit tests | `make test` | Automated |
| TC-02 | Build | Build Go binaries | `make apps` | Automated |
| TC-03 | Build | Verify binary properties | Manual | Manual |
| TC-04 | Build | Build base image | `make base` | Automated |
| TC-05 | Build | Build app image | `make build` | Automated |
| TC-06 | Smoke | Smoke test suite | `make test-smoke` | Automated |
| TC-07 | Integration | Integration test suite | `make test-integration` | Automated |
| TC-08a | Audit | Immutable symlinks | Manual | Needs automation |
| TC-08b | Audit | Binary and shared lib permissions | Manual | Needs automation |
| TC-08c | Audit | systemd unit files and enablement | Manual | Needs automation |
| TC-08d | Audit | tmpfiles.d and sysusers.d entries | Manual | Needs automation |
| TC-08e | Audit | Middleware immutable configs | Manual | Needs automation |
| TC-08f | Audit | Nginx config syntax validation | Manual | Needs automation |
| TC-08g | Audit | Firewall port rules | Manual | Needs automation |
| TC-08h | Audit | Image labels | Manual | Needs automation |
| TC-09 | Structure | Project structure validation | Manual | Needs automation |
| TC-10 | Lint | bootc container lint | `make lint` | Automated |
| TC-10b | Lint | Lint warning analysis | Manual | Manual |
| TC-11 | Docs | Documentation cross-references | Manual | Needs automation |

**Total: 19 test cases** (7 automated, 5 manual-only, 7 candidates for automation)

---

## Category: Unit Tests

### TC-01: Go Unit Tests

- **Command:** `make test`
- **What it tests:** Application business logic (HTTP handlers, health endpoint)
- **Current coverage:** `TestHandleRoot`, `TestHandleHealth`
- **Expected output:**

```
=== RUN   TestHandleRoot
--- PASS: TestHandleRoot (0.00s)
=== RUN   TestHandleHealth
--- PASS: TestHandleHealth (0.00s)
PASS
```

- **Future expansion:** Add tests for each new app in `repos/*/`. The Makefile iterates `repos/*/` automatically, so any `*_test.go` files are picked up.

---

## Category: Build Verification

### TC-02: Build Go Binaries

- **Command:** `make apps`
- **What it tests:** All Go apps under `repos/*/` compile successfully with `CGO_ENABLED=0` (static linking)
- **Verification:** Binary exists at `output/bin/<app-name>`
- **Expected:** Exit code 0, binary files created

### TC-03: Verify Binary Properties

- **Command:** `file output/bin/hello`
- **What it tests:** Binary is statically linked, correct architecture, stripped
- **Expected output:**

```
output/bin/hello: ELF 64-bit LSB executable, x86-64, version 1 (SYSV),
  statically linked, Go BuildID=..., stripped
```

- **Checks:**
  - `ELF 64-bit` -- correct architecture
  - `statically linked` -- no external library dependencies
  - `stripped` -- debug symbols removed (smaller binary)
  - File size reasonable (< 10MB for a simple HTTP server)

### TC-04: Build Base Image (Layer 1)

- **Command:** `make base BASE_DISTRO=centos-stream9`
- **What it tests:** Base OS image builds from `base/centos/stream9/Containerfile`
- **Expected:** Image tagged as `<registry>/bootc-testboot-base:centos-stream9-latest`

### TC-05: Build App Image (Layer 2)

- **Command:** `make build BASE_DISTRO=centos-stream9`
- **What it tests:** Application image builds on top of base, copies binaries, configs, and enables services
- **Expected:** Image tagged as `<registry>/bootc-testboot:latest`

---

## Category: Smoke Tests

### TC-06: Smoke Test Suite

- **Command:** `make test-smoke`
- **What it tests (in a single `podman run`):**

| Sub-check | What | Pass criteria |
|-----------|------|---------------|
| Binaries | `/usr/bin/hello` exists and is executable | `test -x` succeeds |
| systemd units | `hello`, `nginx` are enabled | `systemctl is-enabled` returns "enabled" |
| Immutable configs | `/usr/share/nginx/nginx.conf` exists | `test -f` succeeds |
| Immutable configs | `/usr/share/nginx/conf.d/hello.conf` exists | `test -f` succeeds |
| bootc lint | `bootc container lint` passes | Exit code 0 (warnings OK) |

- **Customization:** Override `EXPECTED_BINS` and `EXPECTED_SVCS` for more apps:

```bash
make test-smoke EXPECTED_BINS="hello app-api app-worker" EXPECTED_SVCS="hello app-api app-worker nginx"
```

- **Expected output:**

```
--- Checking binaries ---
  OK: /usr/bin/hello
--- Checking systemd units ---
  OK: hello enabled
  OK: nginx enabled
--- Checking immutable configs ---
  OK: /usr/share/nginx/nginx.conf
  OK: /usr/share/nginx/conf.d/hello.conf
--- Running bootc lint ---
Checks passed: 11
---
ALL SMOKE TESTS PASSED
```

---

## Category: Integration Tests

### TC-07: Integration Test Suite

- **Command:** `make test-integration`
- **What it tests:** App behavior under production-like constraints
- **Flags used:** `--read-only`, `--tmpfs /var`, `--tmpfs /run`, `--tmpfs /tmp`

| Sub-check | What | Pass criteria |
|-----------|------|---------------|
| tmpfiles.d | `/var/log/nginx` created by `systemd-tmpfiles --create` | Directory exists |
| tmpfiles.d | `/var/lib/bootc-poc` created by `systemd-tmpfiles --create` | Directory exists |
| App health | `hello` starts and responds to `/health` | HTTP response contains "ok" |

- **Expected output:**

```
--- Verifying tmpfiles.d creates /var dirs ---
  OK: /var/log/nginx
  OK: /var/lib/bootc-poc
--- Starting hello service directly ---
  OK: hello /health responded
ALL INTEGRATION TESTS PASSED
```

---

## Category: Deep Exec Audit (Manual)

These tests are run manually via `podman run --rm <image> bash -c '...'`. They are candidates for automation in a future test harness.

### TC-08a: Immutable Symlinks

- **Purpose:** Verify `/etc/` configs are symlinked to read-only `/usr/share/`
- **Command:**

```bash
podman run --rm <image> ls -la /etc/nginx/nginx.conf /etc/nginx/conf.d
```

- **Expected:**

```
/etc/nginx/nginx.conf -> /usr/share/nginx/nginx.conf
/etc/nginx/conf.d -> /usr/share/nginx/conf.d
```

- **Why it matters:** If symlinks are broken, nginx reads default configs instead of ours. In production, `/usr/` is read-only so configs cannot be modified by customers.

### TC-08b: Binary and Shared Lib Permissions

- **Purpose:** Verify all binaries and shared scripts are executable
- **Command:**

```bash
podman run --rm <image> bash -c '
  ls -la /usr/bin/hello
  ls -la /usr/libexec/bootc-poc/
'
```

- **Expected:**
  - `/usr/bin/hello` -- executable (`-rwxr-xr-x` or similar)
  - `/usr/libexec/bootc-poc/gen-password.sh` -- executable
  - `/usr/libexec/bootc-poc/wait-for-service.sh` -- executable

### TC-08c: systemd Unit Files and Enablement

- **Purpose:** Verify all expected service files exist and are enabled
- **Command:**

```bash
podman run --rm <image> bash -c '
  # Check unit files exist
  ls /usr/lib/systemd/system/hello.service
  ls /usr/lib/systemd/system/nginx.service

  # Check enabled
  systemctl is-enabled hello nginx

  # Check overrides for middleware
  ls /usr/lib/systemd/system/mongod.service.d/override.conf
  ls /usr/lib/systemd/system/redis.service.d/override.conf
  ls /usr/lib/systemd/system/rabbitmq-server.service.d/override.conf
'
```

- **Expected:**
  - `hello.service` and `nginx.service`: exist and enabled
  - Middleware overrides: exist (services not yet installed via dnf, but configs are pre-placed)

### TC-08d: tmpfiles.d and sysusers.d Entries

- **Purpose:** Verify all persistent directory declarations and system user declarations are in place
- **Command:**

```bash
podman run --rm <image> bash -c '
  cat /usr/lib/tmpfiles.d/base-requirements.conf
  cat /usr/lib/tmpfiles.d/bootc-poc-common.conf
  cat /usr/lib/tmpfiles.d/nginx.conf
  cat /usr/lib/tmpfiles.d/mongodb.conf
  cat /usr/lib/tmpfiles.d/redis.conf
  cat /usr/lib/tmpfiles.d/rabbitmq.conf
  cat /usr/lib/sysusers.d/appuser.conf
'
```

- **Expected tmpfiles.d entries:**

| File | Directories declared |
|------|---------------------|
| `base-requirements.conf` | `/var/lib/cloud`, `/var/lib/dhcpcd`, `/var/lib/dhclient`, `/var/lib/pcp`, `/var/lib/rhsm`, `/var/home/appuser` |
| `bootc-poc-common.conf` | `/var/lib/bootc-poc` |
| `nginx.conf` | `/var/lib/nginx`, `/var/lib/nginx/tmp`, `/var/log/nginx` |
| `mongodb.conf` | `/var/lib/mongodb`, `/var/log/mongodb` |
| `redis.conf` | `/var/lib/redis`, `/var/log/redis` |
| `rabbitmq.conf` | `/var/lib/rabbitmq`, `/var/log/rabbitmq` |

- **Expected sysusers.d entries:**

| File | User |
|------|------|
| `appuser.conf` | `appuser` (member of `wheel`) |

### TC-08e: Middleware Immutable Configs

- **Purpose:** Verify all middleware config files exist in `/usr/share/` (read-only at runtime)
- **Command:**

```bash
podman run --rm <image> bash -c '
  test -f /usr/share/mongodb/mongod.conf && echo "OK: mongod.conf"
  test -f /usr/share/redis/redis.conf && echo "OK: redis.conf"
  test -f /usr/share/rabbitmq/rabbitmq.conf && echo "OK: rabbitmq.conf"
'
```

- **Expected:** All three configs present

### TC-08f: Nginx Config Syntax Validation

- **Purpose:** Verify nginx configuration is syntactically valid
- **Command:**

```bash
podman run --rm <image> nginx -t
```

- **Expected:**

```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

- **Why it matters:** A syntax error in nginx.conf will prevent the nginx service from starting on a real VM.

### TC-08g: Firewall Port Rules

- **Purpose:** Verify expected ports are open in the firewall zone
- **Command:**

```bash
podman run --rm <image> firewall-offline-cmd --zone=public --list-ports
```

- **Expected:** `22/tcp 80/tcp 443/tcp 8080/tcp`

### TC-08h: Image Labels

- **Purpose:** Verify OCI labels required by bootc and bootc-image-builder
- **Command:**

```bash
podman inspect <image> --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}'
```

- **Required labels:**

| Label | Expected value |
|-------|---------------|
| `containers.bootc` | `1` |
| `ostree.bootable` | `1` (added automatically by base image) |
| `org.opencontainers.image.source` | `https://github.com/duyhenryer/bootc-testboot` |

---

## Category: Project Structure

### TC-09: Project Structure Validation

- **Purpose:** Verify the expected directory layout is consistent

```
bootc-testboot/
├── repos/<app>/             # Go source code (one dir per app)
├── base/                    # Layer 1: base OS Containerfiles + rootfs
├── bootc/
│   ├── apps/<app>/rootfs/   # Per-app: systemd unit, tmpfiles, nginx vhost
│   ├── services/<svc>/rootfs/ # Per-service: immutable config, override, tmpfiles
│   └── libs/<lib>/rootfs/   # Shared libraries/scripts
├── builder/                 # Disk image builder configs (QCOW2, VMDK, OVA)
├── Containerfile            # Layer 2 build
├── Makefile
├── .github/workflows/
└── docs/
    ├── bootc/               # bootc learning docs (001-012)
    └── project/             # Project docs (001-009)
```

- **Checks:**
  - Every app in `repos/*/` has a corresponding `bootc/apps/*/rootfs/` directory
  - Every service in `bootc/services/*/` has `rootfs/usr/share/<svc>/` config and `rootfs/usr/lib/tmpfiles.d/<svc>.conf`
  - `.github/workflows/` contains `build-base.yml` and `build-bootc.yml`

---

## Category: Lint

### TC-10: bootc Container Lint

- **Command:** `make lint`
- **What it tests:** Official bootc lint checks (11 checks as of bootc 1.12)
- **Expected:** All checks pass. Warnings from CentOS base image are acceptable.
- **Strict mode (CI):** `make lint-strict` runs `--fatal-warnings` which will fail on any warning.

### TC-10b: Lint Warning Analysis

- **Purpose:** Document known warnings and their root cause
- **Current warnings (all from CentOS Stream 9 base, not project code):**

| Warning item | Source | Why |
|-------------|--------|-----|
| `/var/lib/pcp/config/` | CentOS pcp package | Sub-directories not declared in upstream tmpfiles.d |
| `/var/roothome/buildinfo/` | CentOS build metadata | Baked into the base image at compose time |
| `/var/lib/rhsm/productid.js` | Red Hat Subscription Manager | File (not directory) in /var |
| `/var/home/appuser/.bashrc` | useradd skeleton | Skeleton dotfiles copied during user creation |

- **Resolution:** These warnings cannot be fixed without modifying the CentOS base image itself. Use `make lint` (without `--fatal-warnings`) for local testing.

---

## Category: Documentation

### TC-11: Documentation Cross-References

- **Purpose:** Verify all internal markdown links point to existing files
- **Scope:** `README.md`, all files in `docs/bootc/`, all files in `docs/project/`
- **Checks:**
  - Every `[text](path.md)` link resolves to an existing file
  - No broken cross-references between `docs/bootc/` and `docs/project/`

---

## Future Test Plan

The following tests should be added as the project scales:

### Short-term (next sprint)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| Automate TC-08a through TC-08h | Shell script | Makefile `test-audit` target | High |
| Nginx reverse proxy e2e | Integration | `podman run` + `curl` through nginx | High |
| Multi-app smoke test | Smoke | Extend `EXPECTED_BINS`/`EXPECTED_SVCS` | Medium |
| Go test coverage report | Unit | `go test -coverprofile` | Medium |

### Medium-term (next quarter)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| Full VM boot test (QEMU) | e2e | `qemu-system-x86_64` + expect scripts | High |
| MongoDB data persistence across upgrade | e2e | Boot v1 -> write data -> upgrade to v2 -> read data | High |
| Rollback verification | e2e | Boot v2 -> rollback to v1 -> verify services | Medium |
| cloud-init validation | e2e | QEMU + cloud-init metadata | Medium |
| OVA/GCE artifact validation | e2e | Build artifact -> import to virt platform | Low |

### Long-term (100+ apps)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| Per-app health check matrix | Integration | Auto-discover `/health` endpoints | High |
| Service dependency ordering | e2e | Verify `After=` ordering in systemd | Medium |
| Image size regression | CI | Track image size per commit | Medium |
| Security scan (CVE) | CI | `trivy image` or `grype` | High |
| Config drift detection | e2e | Compare running VM state vs declared state | Low |
