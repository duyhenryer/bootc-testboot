# Local testing and test case registry

This document explains how to test your bootc image **locally** before deploying to any cloud (GCP, AWS, VMware), and catalogues every **test case (TC-xx)** used to validate the image: automated Makefile targets, manual `podman` audits, and candidates for future automation.

You no longer need to push to GHCR and deploy a VM just to check if your image works.

## Table of Contents

- [Test summary (all TCs)](#test-summary-all-tcs)
- [The problem](#the-problem)
- [Two levels of testing](#two-levels-of-testing)
- [Level 1: Full VM boot (QEMU)](#level-1-full-vm-boot-qemu)
- [Level 2: bcvk VM test (automated)](#level-2-bcvk-vm-test-automated)
- [Testing cheat sheet](#testing-cheat-sheet)
- [Customizing the checks](#customizing-the-checks)
- [CI integration](#ci-integration)
- [Registry: unit tests and build (TC-01 through TC-05)](#registry-unit-tests-and-build-tc-01-through-tc-05)
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

| TC-13 | VM | bcvk ephemeral VM boot | 2 | `make test-vm` | Automated |
| TC-14 | VM | bcvk upgrade test | 2 | `make test-vm-upgrade` | Automated |

**Total: 20 test cases** (10 automated, 5 manual-only, 7 candidates for automation). **Level 1** (full QEMU boot) is documented below for manual verification. **Level 2** (bcvk) automates the full VM lifecycle end-to-end on every PR.

---

## The problem

The old workflow was:

```
build image -> push to GHCR -> deploy to GCP -> SSH in -> discover it's broken -> fix -> repeat
```

Each cycle takes 10-20 minutes and costs money. Most issues (missing binary, wrong config path, service not enabled) can be caught locally in seconds.

---

## Two levels of testing

```
Level 1: Full VM Boot   (5-10 minutes, requires qemu, manual verification)
Level 2: bcvk VM Test   (2-8 minutes, requires bcvk + KVM, automated end-to-end)
```

Level 2 is the canonical local + CI gate. Level 1 stays documented for manual cloud-init or boot-loader investigations.

---

## Level 1: Full VM boot (QEMU)

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
podman pull ghcr.io/duyhenryer/bootc-testboot/centos-stream9/qcow2:latest
CID=$(podman create ghcr.io/duyhenryer/bootc-testboot/centos-stream9/qcow2:latest)
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
curl http://localhost:8000/health

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

## Level 2: bcvk VM test (automated)

Level 1 (QEMU) requires building a disk image first and manual verification. **Level 2** uses [bcvk](https://github.com/bootc-dev/bcvk) to boot the OCI container image directly as a VM — no disk image build step, fully automated, and scripted pass/fail assertions.

For comprehensive bcvk documentation (modes, flags, internals), see [docs/bootc/015-bcvk-virtualization-kit.md](../bootc/015-bcvk-virtualization-kit.md).

### How bcvk works (architecture)

bcvk orchestrates three processes inside a single podman container to turn an OCI image into a running VM:

```
┌─────────────────────────────────────────────────────────────┐
│  Podman Container (--name testboot-vm-$$)                   │
│                                                             │
│  ┌──────────────┐    VHOST-USER     ┌────────────────────┐  │
│  │  virtiofsd    │ ◄──────────────► │  QEMU              │  │
│  │  (FUSE server)│    protocol      │  (KVM-accelerated) │  │
│  └──────┬───────┘                   └────────┬───────────┘  │
│         │                                    │              │
│   reads container                    boots guest kernel     │
│   rootfs as /                        with rootfstype=       │
│                                      virtiofs               │
│                                                             │
│                                    ┌─────────────────────┐  │
│                                    │  Guest VM            │  │
│                                    │  ├─ systemd (PID 1)  │  │
│                                    │  ├─ sshd :22         │  │
│                                    │  ├─ hello :8000      │  │
│                                    │  ├─ worker :8001     │  │
│                                    │  ├─ mongod :27017    │  │
│                                    │  ├─ nginx :80        │  │
│                                    │  └─ ...              │  │
│                                    └─────────────────────┘  │
│                                                             │
│  Port forwarding: hostfwd=tcp::2222-:22 (inside container)  │
└─────────────────────────────────────────────────────────────┘

Host machine
  └─ bcvk ephemeral ssh <name> '<command>'
       └─ podman exec <container> ssh -i <key> -p 2222 root@127.0.0.1
```

**Key points:**

1. **No disk image conversion.** The container's rootfs is shared directly into the VM via virtio-fs. This is why bcvk is fast (~40s to SSH-ready) compared to bootc-image-builder (~10-20 minutes to produce a QCOW2).
2. **SSH key injection.** bcvk generates an ephemeral SSH key pair and injects the public key into the guest via SMBIOS systemd credentials (`tmpfiles.extra`). The guest's `systemd-tmpfiles` creates `/root/.ssh/authorized_keys` on boot.
3. **Port forwarding is container-internal.** QEMU forwards guest port 22 to container port 2222. `bcvk ephemeral ssh` uses `podman exec` to reach the container, then SSH to `127.0.0.1:2222` inside it.
4. **Ephemeral = read-write overlay.** The guest sees a writable filesystem, but writes go to a temporary overlay. Nothing persists after `podman stop`.

### Why virtiofsd is required

bcvk runs in **ephemeral mode** by default: instead of converting the container image into a disk image, it mounts the container's rootfs directly into the VM using the **virtio-fs** protocol. This is what makes bcvk fast (no `bootc-image-builder` step, no QCOW2 conversion).

The virtio-fs pipeline works like this:

```
Host: container rootfs → virtiofsd (FUSE server) → /dev/vhost-user → QEMU → Guest: / (root filesystem)
```

**`virtiofsd`** is the userspace daemon that serves the host filesystem into the VM via the VHOST-USER protocol. Without it, QEMU cannot mount the container rootfs and the VM will fail to boot with a kernel panic (`VFS: Unable to mount root fs`).

This is different from Level 1 (QEMU + QCOW2) where the filesystem is embedded in the disk image itself — no filesystem sharing daemon is needed.

### Prerequisites

```bash
# 1. Install Rust toolchain (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# 2. Install bcvk
cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk

# 3. Install QEMU
# Fedora/CentOS:
sudo dnf install -y qemu-system-x86
# Ubuntu/Debian:
sudo apt install -y qemu-system-x86

# 4. Install virtiofsd build dependencies + build from crates.io
#
# WARNING: distro packages (apt/dnf) ship virtiofsd 1.10.x which is too old
#          for bcvk 0.13+. bcvk passes --allow-mmap to virtiofsd, which was
#          added in virtiofsd 1.12.0 (Oct 2024). You MUST build from source.
#
# Ubuntu/Debian build deps:
sudo apt install -y libseccomp-dev libcap-ng-dev
# Fedora/CentOS build deps:
# sudo dnf install -y libseccomp-devel libcap-ng-devel

cargo install virtiofsd
sudo cp ~/.cargo/bin/virtiofsd /usr/libexec/virtiofsd

# 5. Verify everything is installed correctly
bcvk --version        # tested with 0.13.0
virtiofsd --version   # must be >= 1.12.0
qemu-system-x86_64 --version
test -w /dev/kvm && echo "OK: KVM available" || echo "FAIL: no KVM"

# 6. (Optional, only for test-vm-upgrade) Install and start libvirtd
sudo dnf install -y libvirt-daemon-system   # or sudo apt install -y libvirt-daemon-system
sudo systemctl enable --now libvirtd
```

> **Version compatibility:** bcvk 0.13.0 passes `--allow-mmap` to virtiofsd, which was added in virtiofsd 1.12.0 (Oct 2024). The `apt` and `dnf` packages typically ship 1.10.x which **will fail** with `virtiofsd failed to start for socket`. Always install virtiofsd from [crates.io](https://crates.io/crates/virtiofsd) to get a compatible version.

> **Build dependency note:** `cargo install virtiofsd` compiles from source and requires C library headers for `libseccomp` and `libcap-ng`. Without them, the build fails with `cannot find -lseccomp` or `cannot find -lcap-ng`. Install `libseccomp-dev` + `libcap-ng-dev` (Debian/Ubuntu) or `libseccomp-devel` + `libcap-ng-devel` (Fedora/CentOS) before running `cargo install`.

| Dependency | Why needed | Version requirement |
|------------|-----------|---------------------|
| `bcvk` | Orchestrates podman + virtiofsd + QEMU into a single command | Tested with 0.13.0 |
| `virtiofsd` | Shares the container rootfs into the VM via virtio-fs (ephemeral mode) | >= 1.12.0 (must build from crates.io) |
| `qemu-system-x86_64` | Runs the actual virtual machine with KVM acceleration | System package |
| `/dev/kvm` | Hardware virtualization — without it, tests gracefully skip | Must be writable |
| `podman` | Container runtime used by bcvk to hold the rootfs | System package |
| `libvirtd` | Only for `test-vm-upgrade` (persistent VM with reboot support) | System package |

### TC-13: bcvk ephemeral VM boot

- **Command:** `make test-vm`
- **Script:** [`scripts/vm-test.sh`](../../scripts/vm-test.sh)
- **What it tests:** Boot the OCI image as a real VM, then verify via SSH:
  - 8 critical systemd services are active (hello, worker, mongod, valkey, rabbitmq-server, nginx, firewalld, sshd)
  - 1 non-critical service checked with warning only (chronyd — may fail in ephemeral mode)
  - 2 custom targets reached (`testboot-infra.target`, `testboot-apps.target`)
  - 2 healthcheck timers enabled (`hello-healthcheck.timer`, `worker-healthcheck.timer`)
  - HTTP endpoints respond (hello `/health`, nginx `/`)
  - SELinux status reported (Enforcing on real VMs, Disabled in ephemeral mode — see [Known limitations](#known-limitations-of-ephemeral-mode))
  - 8 firewalld ports are open (22, 80, 443, 8000, 5672, 6379, 15672, 27017)
  - `bootc status` reports healthy
- **Total assertions:** 22 checks
- **Duration:** ~2 minutes (40s SSH ready + 70s boot + checks)
- **Graceful skip:** If `/dev/kvm` is not writable or `bcvk` is not installed, exits 0 (no failure).

**What you see (success):**

```
==> Preflight checks
  OK: bcvk=bcvk 0.13.0
  OK: /dev/kvm writable
==> Booting VM from ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
a1654aef728b...
==> Waiting for SSH (timeout 120s)
  OK: SSH ready after 40s
==> Waiting for system boot to complete (timeout 180s)
  OK: system degraded after 68s
--- Checking systemd services ---
  OK: hello is active
  OK: worker is active
  OK: mongod is active
  OK: valkey is active
  OK: rabbitmq-server is active
  OK: nginx is active
  OK: firewalld is active
  OK: sshd is active
  OK: chronyd is active
--- Checking systemd targets ---
  OK: testboot-infra.target is active
  OK: testboot-apps.target is active
--- Checking healthcheck timers ---
  OK: hello-healthcheck.timer is enabled
  OK: worker-healthcheck.timer is enabled
--- Checking HTTP endpoints ---
  OK: hello /health responded ok
  OK: nginx is serving
--- Checking SELinux ---
  OK: SELinux is Disabled (expected in bcvk ephemeral mode, selinux=0 kernel arg)
--- Checking firewalld ports ---
  OK: port 22/tcp open
  OK: port 80/tcp open
  OK: port 443/tcp open
  OK: port 8000/tcp open
  OK: port 5672/tcp open
  OK: port 6379/tcp open
  OK: port 15672/tcp open
  OK: port 27017/tcp open
--- Checking bootc status ---
  OK: bootc status OK

=== ALL VM TESTS PASSED ===
==> Cleaning up VM testboot-vm-12345
```

**What you see (failure):**

```
--- Checking systemd services ---
  FAIL: mongod is NOT active
  FAIL: worker is NOT active
--- Checking HTTP endpoints ---
  FAIL: hello /health did not respond

=== VM TESTS FAILED ===
```

### TC-14: bcvk upgrade test

- **Command:** `make test-vm-upgrade`
- **Script:** [`scripts/vm-upgrade-test.sh`](../../scripts/vm-upgrade-test.sh)
- **What it tests:** Full upgrade lifecycle:
  1. Boot v1 as a persistent libvirt VM (with real disk, not ephemeral)
  2. Verify all services are running
  3. Run `bootc upgrade` inside the VM
  4. Reboot the VM
  5. Re-verify all services after upgrade
  6. Confirm deployment digest changed (new OS version applied)
- **Duration:** ~5-8 minutes
- **Requires:** `libvirtd` running (in addition to bcvk + KVM + virtiofsd)
- **Graceful skip:** If `/dev/kvm` is not writable, `bcvk` is not installed, or `libvirtd` is not running, exits 0.

**Note:** If the same image tag is used (no new version pushed to GHCR), `bootc upgrade` reports "no update available" and the test skips the reboot phase. This is expected — the upgrade test requires a newer image to be available.

### Boot timing reference

Understanding the boot timeline helps when debugging timeout failures:

| Phase | Time from start | What happens |
|-------|----------------|--------------|
| Container start | 0s | podman starts, virtiofsd initializes |
| QEMU boot | ~5s | Kernel loads, initramfs mounts virtiofs root |
| systemd starts | ~10s | PID 1, basic.target, network-online.target |
| SSH ready | ~40s | sshd accepts connections (key injected via SMBIOS) |
| MongoDB ready | ~50-60s | mongodb-setup → mongod → mongodb-init chain |
| Infrastructure target | ~60s | testboot-infra.target reached |
| Apps target | ~65s | testboot-app-setup → hello + worker start |
| System "degraded" | ~68s | All services up except bootloader-update |
| cloud-init final | ~90-100s | cloud-init completes (if present) |

The test script uses two timeouts:

- `SSH_TIMEOUT=120` — waits for SSH to become available
- `BOOT_TIMEOUT=180` — waits for `systemctl is-system-running` to return `running` or `degraded`

### Known limitations of ephemeral mode

bcvk ephemeral mode has several differences from a real deployed VM. These are by design and the test script accounts for them:

| Behavior | Ephemeral mode | Real VM (QCOW2/AMI) | Impact on tests |
|----------|---------------|---------------------|-----------------|
| SELinux | **Disabled** (`selinux=0` kernel arg) | Enforcing | Test accepts both states |
| Bootloader | No real bootloader | GRUB/systemd-boot | `bootloader-update.service` always fails → system reports `degraded` instead of `running` |
| Filesystem | virtio-fs (shared from host) | ext4/xfs on disk | Writes go to temporary overlay, nothing persists |
| `bootc upgrade` | Cannot stage — no real disk | Works normally | Use `test-vm-upgrade` (libvirt mode) for upgrade testing |
| chronyd | May fail (no NTP servers) | Works normally | Checked with warning only (non-critical) |
| `bootc status` | Reports healthy but shows virtiofs root | Reports real deployment info | Test only checks exit code |

**Why `degraded` is accepted:** In ephemeral mode, `bootloader-update.service` always fails because there is no real disk or bootloader to update. This is harmless — it means the system state is `degraded` instead of `running`. The test script accepts both states as success.

**Why SELinux is disabled:** bcvk ephemeral mode passes `selinux=0` on the kernel command line. This is a bcvk design choice for ephemeral/testing scenarios. To test SELinux enforcement, use Level 1 (QCOW2 + QEMU) or deploy to a real VM.

### How the test script handles bcvk SSH

bcvk wraps SSH inside `podman exec`, which introduces two quirks that the test script handles:

1. **Exit code propagation.** When a remote command exits non-zero (e.g., `systemctl is-active foo` returns 3 for inactive), bcvk reports it as SSH failure. The `vm_ssh()` helper wraps all remote commands with `|| true` to prevent this from breaking the test flow:

   ```bash
   vm_ssh() {
       bcvk ephemeral ssh "${VM_NAME}" "($*) || true" 2>/dev/null | tr -d '\r' || true
   }
   ```

2. **Carriage returns in output.** SSH output from bcvk may contain `\r` (carriage return) characters from the pseudo-terminal. The `vm_ssh()` helper pipes through `tr -d '\r'` to strip them, ensuring `grep -q "^active$"` matches correctly.

### Interactive SSH (debugging)

```bash
make test-vm-ssh   # Boot VM and drop into SSH session, auto-cleanup on exit
```

**When to use:** When you need to manually inspect a running VM — debug service failures, check logs, verify network. This is the bcvk equivalent of Level 1's manual QEMU verification, but without the disk image build step.

**Useful commands once inside the VM:**

```bash
# Service status overview
systemctl list-units --type=service --state=running
systemctl list-units --failed

# Check specific service logs
journalctl -u hello -u worker --no-pager -n 50
journalctl -u mongod --no-pager -n 20

# Verify boot ordering
systemctl status testboot-infra.target testboot-apps.target

# Check app health endpoints
curl -sf http://127.0.0.1:8000/health
curl -sf http://127.0.0.1:8001/health

# Verify filesystem layout
ls -la /etc/nginx/nginx.conf           # should be symlink → /usr/share/nginx/nginx.conf
ls -la /var/lib/bootc-testboot/shared/env/  # generated credentials
bootc status                           # deployment info

# Check firewall
firewall-cmd --list-ports

# View VM console output (from host, not inside VM)
# podman logs <container-name>
```

### Troubleshooting Level 2

| Symptom | Cause | Fix |
|---------|-------|-----|
| `virtiofsd failed to start for socket` | virtiofsd version too old (< 1.12.0) | `cargo install virtiofsd` (requires `libseccomp-dev libcap-ng-dev`) |
| `cannot find -lseccomp` during `cargo install virtiofsd` | Missing C library headers | `sudo apt install -y libseccomp-dev libcap-ng-dev` (Ubuntu) or `sudo dnf install -y libseccomp-devel libcap-ng-devel` (Fedora) |
| SSH timeout (120s) | VM boot slow, or virtiofsd/QEMU crash | Check `podman logs <container>` for QEMU errors |
| Boot timeout (180s) | Services failing to start | SSH in manually (`make test-vm-ssh`) and check `systemctl list-units --failed` |
| `FAIL: <service> is NOT active` | Service failed or not yet started | Check `journalctl -u <service>` inside VM |
| `Permission denied` on SSH | `PermitRootLogin no` in sshd config | Must be `PermitRootLogin prohibit-password` (bcvk uses key-based root SSH) |
| All service checks fail but HTTP checks pass | `\r` in SSH output breaking grep | Verify `vm_ssh()` includes `tr -d '\r'` |
| `SKIP: bcvk not found` | bcvk not in PATH | `cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk` |
| `SKIP: /dev/kvm not writable` | No KVM access | `sudo chmod 666 /dev/kvm` or add user to `kvm` group |
| Container already exists | Previous test run did not clean up | `podman rm -f testboot-vm-*` |

---

## Testing cheat sheet

| What you changed | Minimum test level | Command |
|------------------|--------------------|---------|
| Go app code | Level 2 | `make test-vm` |
| systemd unit file | Level 2 | `make test-vm` |
| nginx/valkey/rabbitmq config | Level 2 | `make test-vm` |
| New app binary added | Level 2 | `make test-vm` |
| Containerfile changed | Level 2 | `make test-vm` |
| Service ordering / boot chain | Level 2 | `make test-vm` |
| cloud-init config | Level 1 | QEMU boot |
| Firewall rules | Level 2 | `make test-vm` |
| OS upgrade / rollback | Level 2 | `make test-vm-upgrade` |
| Full release to customer | Level 2 | `make test-all` + `make test-vm-upgrade` |

---

## Customizing the checks

VM checks live in [`scripts/vm-test.sh`](../../scripts/vm-test.sh) (service-active loops, target checks, healthcheck timers, HTTP endpoints, SELinux probe, Valkey AUTH, bind-address checks, `bootc status`). Edit that script to add a new app or service expectation. There are no `EXPECTED_*` Makefile variables.

```bash
make test-vm             # build + boot + verify (default)
make test-all            # Go unit + bootc lint + test-vm
make test-vm-upgrade     # build + persistent VM + bootc upgrade + reboot
```

---

## CI integration

The CI pipeline (`ci.yml`) `test-vm` job builds the base + app image, runs `bootc container lint --fatal-warnings` on both, boots the image via `bcvk` and runs [`scripts/vm-test.sh`](../../scripts/vm-test.sh) for every distro in the matrix.

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

- **Expected:** `22/tcp 80/tcp 443/tcp 5672/tcp 6379/tcp 8000/tcp 15672/tcp 27017/tcp`

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
    └── project/             # Project docs (001-010)
```

- **Checks:**
  - Every app in `repos/*/` has a corresponding `bootc/apps/*/rootfs/` directory
  - Every service in `bootc/services/*/` has `rootfs/usr/share/<svc>/` config and `rootfs/usr/lib/tmpfiles.d/<svc>.conf`
  - `.github/workflows/` contains `build-base.yml`, `build-bootc.yml`, `build-artifacts.yml`, and `ci.yml`

---

## Registry: lint (TC-10, TC-10b)

### TC-10: bootc Container Lint

- **Command:** `make lint`
- **What it tests:** Official bootc lint checks (11 checks as of bootc 1.12), always with `--fatal-warnings`.
- **Expected:** All checks pass. Warnings from CentOS base image are acceptable.

### TC-10b: Lint Warning Analysis

- **Purpose:** Document known warnings and their root cause
- **Current warnings (all from CentOS Stream 9 base, not project code):**

| Warning item | Source | Why |
|-------------|--------|-----|
| `/var/lib/pcp/config/` | CentOS pcp package | Sub-directories not declared in upstream tmpfiles.d |
| `/var/roothome/buildinfo/` | CentOS build metadata | Baked into the base image at compose time |
| `/var/lib/rhsm/productid.js` | Red Hat Subscription Manager | File (not directory) in /var |
| `/var/lib/bootc-testboot/shared/` | Shared app resources | TLS CA certs, environment files (owned by `root:apps`) |

- **Resolution:** These warnings cannot be fixed without modifying the CentOS base image itself.

---

## Registry: post-publish GHCR (TC-12)

- **Command:** `make verify-ghcr` (runs [`scripts/verify-ghcr-packages.sh`](../../scripts/verify-ghcr-packages.sh))
- **What it tests:** Remote manifests (`skopeo inspect`) and, unless `VERIFY_SKIP_PULL=1`, full `podman pull` plus tarball path checks for disk artifacts and bootc labels for base/app images — see [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md).
- **Not the same as:** `make audit-all` (local rebuild + lint, no registry pull).

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
1. Does the service file have `[Install]` section with `WantedBy=` set? Apps in this project use `WantedBy=testboot-apps.target`; infra services use `WantedBy=testboot-infra.target` or `multi-user.target`.
2. Did the Containerfile auto-enable loop run? Check with: `ls -la /etc/systemd/system/testboot-apps.target.wants/ /etc/systemd/system/multi-user.target.wants/`

### `curl` fails in integration test

The app might need more than 1 second to start. Increase the `sleep` time in the test, or add a retry loop.

### QEMU boot shows "no bootable device"

Make sure you are using the UEFI firmware (`-bios /usr/share/OVMF/OVMF_CODE.fd`). bootc images require UEFI, not legacy BIOS.

---

## Future test plan

The following tests should be added as the project scales. **Level 2 (bcvk)** now automates the full VM boot and upgrade lifecycle — see [Level 2: bcvk VM test (automated)](#level-2-bcvk-vm-test-automated). The items below are **beyond** what bcvk currently covers.

### Short-term (next sprint)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| Automate TC-08a through TC-08h | Shell script | Makefile `test-audit` target | High |
| Nginx reverse proxy e2e | Integration | `podman run` + `curl` through nginx | High |
| Multi-app boot probe | VM | Extend [`scripts/vm-test.sh`](../../scripts/vm-test.sh) | Medium |
| Go test coverage report | Unit | `go test -coverprofile` | Medium |

### Medium-term (next quarter)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| ~~Full VM boot test — automated~~ | ~~e2e~~ | ~~Done: `make test-vm` (TC-13)~~ | ~~Done~~ |
| MongoDB data persistence across upgrade | e2e | Boot v1 → write data → upgrade to v2 → read data | High |
| Rollback verification | e2e | Boot v2 → rollback to v1 → verify services | Medium |
| cloud-init validation | e2e | QEMU + cloud-init metadata | Medium |
| OVA/GCE artifact validation | e2e | Build artifact → import to virt platform | Low |

### Long-term (100+ apps)

| Test | Type | Tool | Priority |
|------|------|------|----------|
| Per-app health check matrix | Integration | Auto-discover `/health` endpoints | High |
| Service dependency ordering | e2e | Verify `After=` ordering in systemd | Medium |
| Image size regression | CI | Track image size per commit | Medium |
| Security scan (CVE) | CI | `trivy image` or `grype` | High |
| Config drift detection | e2e | Compare running VM state vs declared state | Low |
