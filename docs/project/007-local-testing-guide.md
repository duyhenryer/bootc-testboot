# Local Testing Guide

This document explains how to test your bootc image **locally** before deploying to any cloud (GCP, AWS, VMware). You no longer need to push to GHCR and deploy a VM just to check if your image works.

---

## The Problem

The old workflow was:

```
build image -> push to GHCR -> deploy to GCP -> SSH in -> discover it's broken -> fix -> repeat
```

Each cycle takes 10-20 minutes and costs money. Most issues (missing binary, wrong config path, service not enabled) can be caught locally in seconds.

---

## Three Levels of Testing

```
Level 1: Smoke Test     (30 seconds, no VM, catches 80% of issues)
Level 2: Integration    (1 minute, no VM, simulates read-only /usr)
Level 3: Full VM Boot   (5-10 minutes, requires qemu, catches everything)
```

Start with Level 1. Only go to Level 3 if you need to test the full boot sequence (cloud-init, multi-service interaction, networking).

---

## Level 1: Smoke Test

**What it checks:**
- All expected binaries exist in `/usr/bin/`
- All expected systemd units are enabled
- All immutable configs exist in `/usr/share/`
- `bootc container lint --fatal-warnings` passes

**How to run:**

```bash
make test-smoke
```

**What you see (success):**

```
==> Smoke testing ghcr.io/duyhenryer/bootc-testboot:latest
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

## Level 2: Integration Test

**What it checks:**
- App starts correctly with read-only `/usr` (simulates production)
- `tmpfiles.d` creates the correct `/var` directories
- App responds to HTTP requests

**How to run:**

```bash
make test-integration
```

**What you see (success):**

```
==> Integration testing ghcr.io/duyhenryer/bootc-testboot:latest (read-only /usr)
--- Verifying tmpfiles.d creates /var dirs ---
  OK: /var/log/nginx
  OK: /var/lib/testboot
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

## Level 3: Full VM Boot (QEMU)

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
sudo podman pull ghcr.io/duyhenryer/bootc-testboot:latest

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
  ghcr.io/duyhenryer/bootc-testboot:latest
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
ls -la /var/lib/hello/ /var/log/nginx/

# Verify /usr is read-only
touch /usr/test-write 2>&1 || echo "Good: /usr is read-only"
```

**When to use:** Before a major release to customers. This is the only test that exercises the full boot sequence including cloud-init, systemd ordering, and network configuration.

---

## Testing Cheat Sheet

| What you changed | Minimum test level | Command |
|------------------|--------------------|---------|
| Go app code | Level 1 | `make test-smoke` |
| systemd unit file | Level 1 | `make test-smoke` |
| nginx/redis/rabbitmq config | Level 1 | `make test-smoke` |
| New app binary added | Level 2 | `make test-integration` |
| Containerfile changed | Level 2 | `make test-integration` |
| cloud-init config | Level 3 | QEMU boot |
| Firewall rules | Level 3 | QEMU boot |
| Full release to customer | Level 3 | QEMU boot |

---

## Customizing the Checks

The smoke test checks are configured via Makefile variables:

```bash
# Default (just hello app)
make test-smoke

# When you add more apps, override the variables:
make test-smoke EXPECTED_BINS="hello app-api app-worker" EXPECTED_SVCS="hello app-api app-worker nginx"
```

---

## CI Integration

The CI pipeline (`ci.yml`) already runs Level 1 checks on every PR:

```yaml
- name: Strict lint
  run: podman run --rm $IMAGE:pr-check bootc container lint --fatal-warnings
```

You can add smoke tests to PR checks by adding `make test-smoke` to the `pr-check` job.

---

## Troubleshooting

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
