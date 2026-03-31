# Local testing and test case registry

This document explains how to test your bootc image **locally** before deploying to any cloud (GCP, AWS, VMware), and catalogues every **test case (TC-xx)** used to validate the image: automated Makefile targets, manual `podman` audits, and candidates for future automation.

You no longer need to push to GHCR and deploy a VM just to check if your image works.

## Table of Contents

- [Test summary (all TCs)](#test-summary-all-tcs)
- [The problem](#the-problem)
- [Three levels of testing](#three-levels-of-testing)
- [Level 1: Smoke test (TC-06)](#level-1-smoke-test-tc-06)
- [Level 2: Integration test (TC-07)](#level-2-integration-test-tc-07)
- [Level 3: Full VM boot (QEMU)](#level-3-full-vm-boot-qemu)
- [Testing cheat sheet](#testing-cheat-sheet)
- [Customizing the checks](#customizing-the-checks)
- [CI integration](#ci-integration)
- [Registry: unit tests and build (TC-01 through TC-05)](#registry-unit-tests-and-build-tc-01-through-tc-05)
- [Registry: smoke and integration reference (TC-06, TC-07)](#registry-smoke-and-integration-reference-tc-06-tc-07)
- [Registry: deep exec audit (TC-08a through TC-08h)](#registry-deep-exec-audit-tc-08a-through-tc-08h)
- [Registry: project structure (TC-09)](#registry-project-structure-tc-09)
- [Registry: lint (TC-10, TC-10b)](#registry-lint-tc-10-tc-10b)
- [Registry: post-publish GHCR (TC-12)](#registry-post-publish-ghcr-tc-12)
- [Registry: documentation (TC-11)](#registry-documentation-tc-11)
- [Troubleshooting](#troubleshooting)
- [Future test plan](#future-test-plan)

## Test summary (all TCs)

| ID | Category | Name | Level | Automation | Status |
|----|----------|------|-------|------------|--------|
| TC-01 | Unit | Go unit tests | — | `make test` | Automated |
| TC-02 | Build | Build Go binaries | — | `make apps` | Automated |
| TC-03 | Build | Verify binary properties | — | Manual | Manual |
| TC-04 | Build | Build base image | — | `make base` | Automated |
| TC-05 | Build | Build app image | — | `make build` | Automated |
| TC-06 | Smoke | Smoke test suite | 1 | `make test-smoke` | Automated |
| TC-07 | Integration | Integration test suite | 2 | `make test-integration` | Automated |
| TC-08a | Audit | Immutable symlinks | — | Manual | Needs automation |
| TC-08b | Audit | Binary and shared lib permissions | — | Manual | Needs automation |
| TC-08c | Audit | systemd unit files and enablement | — | Manual | Needs automation |
| TC-08d | Audit | tmpfiles.d and sysusers.d entries | — | Manual | Needs automation |
| TC-08e | Audit | Middleware immutable configs | — | Manual | Needs automation |
| TC-08f | Audit | Nginx config syntax validation | — | Manual | Needs automation |
| TC-08g | Audit | Firewall port rules | — | Manual | Needs automation |
| TC-08h | Audit | Image labels | — | Manual | Needs automation |
| TC-09 | Structure | Project structure validation | — | Manual | Needs automation |
| TC-10 | Lint | bootc container lint | — | `make lint` | Automated |
| TC-10b | Lint | Lint warning analysis | — | Manual | Manual |
| TC-11 | Docs | Documentation cross-references | — | Manual | Needs automation |
| TC-12 | Registry | Post-publish GHCR verification | — | `make verify-ghcr` (or `VERIFY_SKIP_PULL=1` for metadata-only) | Automated |

**Total: 20 test cases** (8 automated, 5 manual-only, 7 candidates for automation). **Level 3** (full QEMU boot) is documented below but not assigned a TC ID yet; see [Future test plan](#future-test-plan).

---

## The problem

The old workflow was:

```
build image -> push to GHCR -> deploy to GCP -> SSH in -> discover it's broken -> fix -> repeat
```

Each cycle takes 10-20 minutes and costs money. Most issues (missing binary, wrong config path, service not enabled) can be caught locally in seconds.

---

## Three levels of testing

```
Level 1: Smoke Test     (30 seconds, no VM, catches 80% of issues)
Level 2: Integration    (1 minute, no VM, simulates read-only /usr)
Level 3: Full VM Boot   (5-10 minutes, requires qemu, catches everything)
```

Start with Level 1. Only go to Level 3 if you need to test the full boot sequence (cloud-init, multi-service interaction, networking).

---

## Level 1: Smoke test (TC-06)

**What it checks:**
- All expected binaries exist in `/usr/bin/`
- All expected systemd units are enabled
- All immutable configs exist in `/usr/share/`
- `bootc container lint --fatal-warnings` passes

| Sub-check | What | Pass criteria |
|-----------|------|---------------|
| Binaries | `/usr/bin/hello` exists and is executable | `test -x` succeeds |
| systemd units | `hello`, `nginx` are enabled | `systemctl is-enabled` returns "enabled" |
| Immutable configs | `/usr/share/nginx/nginx.conf`, `conf.d/hello.conf` | `test -f` succeeds |
| bootc lint | `bootc container lint` | Exit code 0 (`--fatal-warnings` in this target) |

**How to run:**

```bash
make test-smoke
```

**What you see (success):**

```
==> Smoke testing ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
--- Checking binaries ---
  OK: /usr/bin/hello
--- Checking systemd units ---
  OK: hello enabled
  OK: nginx enabled
--- Checking immutable configs ---
  OK: /usr/share/nginx/nginx.conf
  OK: /usr/share/nginx/conf.d/hello.conf
--- Running bootc lint ---
  No warnings.
---
ALL SMOKE TESTS PASSED
```

**What you see (failure):**

```
--- Checking binaries ---
  FAIL: /usr/bin/hello missing
--- Checking systemd units ---
  FAIL: hello not enabled
SMOKE TESTS FAILED
```

**How it works under the hood:**

```bash
podman run --rm <image> bash -c '
  test -x /usr/bin/hello && echo "OK" || echo "FAIL"
  systemctl is-enabled hello && echo "OK" || echo "FAIL"
  bootc container lint --fatal-warnings
'
```

The image is a bootc container, which means it has `bash`, `systemctl`, and `bootc` inside. We run it as a normal container and check that everything is in place.

**When to use:** After every `make build`. This is your first line of defense.

---

## Level 2: Integration test (TC-07)

**What it checks:**
- App starts correctly with read-only `/usr` (simulates production)
- `tmpfiles.d` creates the correct `/var` directories
- App responds to HTTP requests

| Sub-check | What | Pass criteria |
|-----------|------|---------------|
| tmpfiles.d | `/var/log/nginx`, `/var/lib/bootc-testboot` after `systemd-tmpfiles --create` | Directories exist |
| App health | `hello` responds to `/health` | HTTP response contains expected body |

**Flags used:** `--read-only`, `--tmpfs /var`, `--tmpfs /run`, `--tmpfs /tmp` (see **How it works under the hood** below).

**How to run:**

```bash
make test-integration
```

**What you see (success):**

```
==> Integration testing ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest (read-only /usr)
--- Verifying tmpfiles.d creates /var dirs ---
  OK: /var/log/nginx
  OK: /var/lib/bootc-testboot
--- Starting hello service directly ---
  OK: hello /health responded
ALL INTEGRATION TESTS PASSED
```

**How it works under the hood:**

```bash
podman run --rm \
  --read-only \                    # /usr is read-only, like production
  --tmpfs /var:rw,nosuid,nodev \   # /var is writable, like production
  --tmpfs /run:rw,nosuid,nodev \   # /run is writable (needed for PID files)
  --tmpfs /tmp:rw,nosuid,nodev \
  <image> bash -c '
    systemd-tmpfiles --create      # create /var dirs from tmpfiles.d
    /usr/bin/hello &               # start the app
    sleep 1
    curl -sf http://127.0.0.1:8080/health  # check it responds
  '
```

The `--read-only` flag makes `/usr` read-only, just like it would be on a real booted system. If your app tries to write to `/usr`, it will fail here instead of on the customer's machine.

**When to use:** When you change app code, configs, or add new services. Catches issues that smoke tests miss (e.g., app crashes on startup, wrong port).

---

## Level 3: Full VM boot (QEMU)

**What it checks:**
- Full systemd boot sequence
- All services start in the correct order
- cloud-init runs correctly
- Multi-service interaction (e.g., nginx proxies to hello)
- SSH access works

**Prerequisites:**

```bash
# Install QEMU and UEFI firmware (one-time setup)
sudo dnf install -y qemu-kvm edk2-ovmf

# OR on Ubuntu/Debian:
sudo apt install -y qemu-system-x86 ovmf
```

**Step 1: Build a QCOW2 disk image**

If you have a QCOW2 from CI, extract it:

```bash
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest
CID=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest)
podman cp $CID:/qcow2/disk.qcow2 ./disk.qcow2
podman rm $CID
```

Or build locally with `bootc-image-builder`:

```bash
sudo podman pull ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest

sudo podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v $(pwd)/builder:/builder \
  -v $(pwd)/output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs ext4 \
  --chown $(id -u):$(id -g) \
  --config /builder/qcow2/config.toml \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

**Step 2: Boot the VM**

```bash
qemu-system-x86_64 \
  -M accel=kvm \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -serial stdio \
  -snapshot \
  output/qcow2/disk.qcow2
```

The `-snapshot` flag means changes are not written to disk, so you can re-run the same image repeatedly.

**Step 3: Verify inside the VM**

Once booted (you'll see a login prompt on the serial console), log in and check:

```bash
# Check bootc status
bootc status

# Check services are running
systemctl status hello nginx

# Check app responds
curl http://localhost:8080/health

# Check immutable configs
ls -la /etc/nginx/nginx.conf    # should be symlink -> /usr/share/nginx/nginx.conf
cat /usr/share/nginx/nginx.conf # should be your custom config

# Check data directories exist
ls -la /var/lib/bootc-testboot/hello/ /var/log/nginx/

# Verify /usr is read-only
touch /usr/test-write 2>&1 || echo "Good: /usr is read-only"
```

**When to use:** Before a major release to customers. This is the only test that exercises the full boot sequence including cloud-init, systemd ordering, and network configuration.

---

## Testing cheat sheet

| What you changed | Minimum test level | Command |
|------------------|--------------------|---------|
| Go app code | Level 1 | `make test-smoke` |
| systemd unit file | Level 1 | `make test-smoke` |
| nginx/valkey/rabbitmq config | Level 1 | `make test-smoke` |
| New app binary added | Level 2 | `make test-integration` |
| Containerfile changed | Level 2 | `make test-integration` |
| cloud-init config | Level 3 | QEMU boot |
| Firewall rules | Level 3 | QEMU boot |
| Full release to customer | Level 3 | QEMU boot |

---

## Customizing the checks

The smoke test checks are configured via Makefile variables:

```bash
# Default (just hello app)
make test-smoke

# When you add more apps, override the variables:
make test-smoke EXPECTED_BINS="hello app-api app-worker" EXPECTED_SVCS="hello app-api app-worker nginx"
```

---

## CI integration

The CI pipeline (`ci.yml`) already runs Level 1 checks on every PR:

```yaml
- name: Strict lint
  run: podman run --rm $IMAGE:pr-check bootc container lint --fatal-warnings
```

You can add smoke tests to PR checks by adding `make test-smoke` to the `pr-check` job.

---

## Registry: unit tests and build (TC-01 through TC-05)

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
- **Expected:** Image tagged as `<registry>/bootc-testboot/centos-stream9:latest` (path-style; parity with CI)

### TC-05: Build App Image (Layer 2)

- **Command:** `make build BASE_DISTRO=centos-stream9`
- **What it tests:** Application image builds on top of base, copies binaries, configs, and enables services
- **Expected:** Image tagged as `<registry>/bootc-testboot/<distro>:latest`

---

## Registry: smoke and integration reference (TC-06, TC-07)

**Procedures, sample output, and customization:** [Level 1: Smoke test (TC-06)](#level-1-smoke-test-tc-06) and [Level 2: Integration test (TC-07)](#level-2-integration-test-tc-07).

**Commands:** `make test-smoke` (TC-06), `make test-integration` (TC-07). Override smoke expectations with `EXPECTED_BINS` and `EXPECTED_SVCS` as documented in [Customizing the checks](#customizing-the-checks).

---

## Registry: deep exec audit (TC-08a through TC-08h)

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
  ls -la /usr/libexec/testboot/
'
```

- **Expected:**
  - `/usr/bin/hello` -- executable (`-rwxr-xr-x` or similar)
  - `/usr/libexec/testboot/gen-password.sh` -- executable
  - `/usr/libexec/testboot/wait-for-service.sh` -- executable

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
  ls /usr/lib/systemd/system/valkey.service.d/override.conf
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
  cat /usr/lib/tmpfiles.d/testboot-common.conf
  cat /usr/lib/tmpfiles.d/nginx.conf
  cat /usr/lib/tmpfiles.d/mongodb.conf
  cat /usr/lib/tmpfiles.d/valkey.conf
  cat /usr/lib/tmpfiles.d/rabbitmq.conf
  cat /usr/lib/sysusers.d/apps.conf
'
```

- **Expected tmpfiles.d entries:**

| File | Directories declared |
|------|---------------------|
| `base-requirements.conf` | `/var/lib/cloud`, `/var/lib/dhcpcd`, `/var/lib/dhclient`, `/var/lib/pcp`, `/var/lib/rhsm` |
| `testboot-common.conf` | `/var/lib/bootc-testboot`, `/var/log/bootc-testboot` |
| `nginx.conf` | `/var/lib/nginx`, `/var/lib/nginx/tmp`, `/var/log/nginx` |
| `mongodb.conf` | `/var/lib/mongodb`, `/var/log/mongodb` |
| `valkey.conf` | `/var/lib/valkey`, `/var/log/valkey` |
| `rabbitmq.conf` | `/var/lib/rabbitmq`, `/var/log/rabbitmq` |

- **Expected sysusers.d entries:**

| File | User |
|------|------|
| `apps.conf` | `apps` group (shared group for all Go app services) |

### TC-08e: Middleware Immutable Configs

- **Purpose:** Verify all middleware config files exist in `/usr/share/` (read-only at runtime)
- **Command:**

```bash
podman run --rm <image> bash -c '
  test -f /usr/share/mongodb/mongod.conf && echo "OK: mongod.conf"
  test -f /usr/share/valkey/valkey.conf && echo "OK: valkey.conf"
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

## Registry: project structure (TC-09)

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
├── scripts/verify-ghcr-packages.sh
├── .github/workflows/
└── docs/
    ├── bootc/               # bootc learning docs (001-012)
    └── project/             # Project docs (001-008)
```

- **Checks:**
  - Every app in `repos/*/` has a corresponding `bootc/apps/*/rootfs/` directory
  - Every service in `bootc/services/*/` has `rootfs/usr/share/<svc>/` config and `rootfs/usr/lib/tmpfiles.d/<svc>.conf`
  - `.github/workflows/` contains `build-base.yml`, `build-bootc.yml`, `build-artifacts.yml`, and `ci.yml`

---

## Registry: lint (TC-10, TC-10b)

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
| `/var/lib/bootc-testboot/shared/` | Shared app resources | TLS CA certs, environment files (owned by `root:apps`) |

- **Resolution:** These warnings cannot be fixed without modifying the CentOS base image itself. Use `make lint` (without `--fatal-warnings`) for local testing.

---

## Registry: post-publish GHCR (TC-12)

- **Command:** `make verify-ghcr` (runs [`scripts/verify-ghcr-packages.sh`](../../scripts/verify-ghcr-packages.sh))
- **What it tests:** Remote manifests (`skopeo inspect`) and, unless `VERIFY_SKIP_PULL=1`, full `podman pull` plus tarball path checks for disk artifacts and bootc labels for base/app images — see [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md).
- **Not the same as:** `make audit` (local rebuild + lint, no registry pull).

---

## Registry: documentation (TC-11)

### TC-11: Documentation Cross-References

- **Purpose:** Verify all internal markdown links point to existing files
- **Scope:** `README.md`, all files in `docs/bootc/`, all files in `docs/project/`
- **Checks:**
  - Every `[text](path.md)` link resolves to an existing file
  - No broken cross-references between `docs/bootc/` and `docs/project/`


---

## Troubleshooting

### Post-deploy audit (EC2 / VM)

For the full post-deploy VM audit checklist (services, SELinux, MongoDB, symlinks, logs), see
[005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md#post-deploy-vm-audit-checklist).

### `podman run` hangs or exits immediately

bootc images are designed to boot with systemd as PID 1. When you run them with `podman run ... bash -c '...'`, you are bypassing systemd and running bash directly. This is fine for testing -- the image still has all the files, they are just not "booted."

### `systemctl is-enabled` shows "disabled"

The service file exists but is not enabled. Check:
1. Does the service file have `[Install]` section with `WantedBy=multi-user.target`?
2. Did the Containerfile auto-enable loop run? Check with: `ls -la /etc/systemd/system/multi-user.target.wants/`

### `curl` fails in integration test

The app might need more than 1 second to start. Increase the `sleep` time in the test, or add a retry loop.

### QEMU boot shows "no bootable device"

Make sure you are using the UEFI firmware (`-bios /usr/share/OVMF/OVMF_CODE.fd`). bootc images require UEFI, not legacy BIOS.

---

## Future test plan

The following tests should be added as the project scales. **Manual QEMU workflow today:** [Level 3: Full VM boot (QEMU)](#level-3-full-vm-boot-qemu). The medium-term row below targets **automation** (expect scripts, CI) on top of that flow.

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
| Full VM boot test (QEMU) — automated | e2e | `qemu-system-x86_64` + expect scripts (procedure: [Level 3](#level-3-full-vm-boot-qemu)) | High |
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
