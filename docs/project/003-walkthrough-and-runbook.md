# Walkthrough and operations runbook

**Part A** walks through the bootc-testboot flow from prerequisites to verifying an EC2 instance and adding a new app. **Part B** is the production runbook for upgrades, rollbacks, debugging, and emergencies on bootc-managed hosts—use it as the single source of truth for operator commands (the short upgrade/rollback steps that used to appear only in the walkthrough are superseded by Part B).

## Table of Contents

- [Part A — Walkthrough](#part-a--walkthrough)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Clone repo and explore structure](#2-clone-repo-and-explore-structure)
  - [3. Run tests locally](#3-run-tests-locally)
  - [4. Build bootc image](#4-build-bootc-image)
  - [5. Push to GHCR (CI only)](#5-push-to-ghcr-ci-only)
  - [6. Create disk images (CI only)](#6-create-disk-images-ci-only)
  - [7. Launch EC2 from AMI](#7-launch-ec2-from-ami)
  - [8. Verify instance](#8-verify-instance)
  - [9. Adding a new app](#9-adding-a-new-app)
- [Part B — Operations runbook](#part-b--operations-runbook)
  - [1. Upgrade OS (Production-Safe)](#1-upgrade-os-production-safe)
  - [2. Rollback OS](#2-rollback-os)
  - [3. Debug on Immutable OS](#3-debug-on-immutable-os)
  - [4. Handle /opt (Read-Only) Apps](#4-handle-opt-read-only-apps)
  - [5. Common Gotchas](#5-common-gotchas)
  - [6. Emergency Procedures](#6-emergency-procedures)
  - [7. Build Disk Images (CI only)](#7-build-disk-images-ci-only)
- [Quick reference](#quick-reference)

---

## Part A — Walkthrough

---

## 1. Prerequisites

Before starting, ensure you have:

| Requirement | Details |
|-------------|---------|
| **AWS account** | With permissions for EC2, S3, IAM |
| **EC2 builder instance** | For AMI creation: **t3.large** or larger, with **podman** installed, running as root |
| **VM Import service role** | Configured for S3/EC2 import (see [AWS VM Import prerequisites](https://docs.aws.amazon.com/vm-import/latest/userguide/vmie_prereqs.html)) |
| **S3 bucket** | For bootc-image-builder intermediate artifacts |
| **Go 1.25+** | For building apps locally (`go version`) |
| **GitHub account** | With access to GitHub Container Registry (GHCR) |

---

## 2. Clone Repo and Explore Structure

```bash
git clone https://github.com/duyhenryer/bootc-testboot.git
cd bootc-testboot
```

### Project structure

```
bootc-testboot/
├── base/
│   ├── rootfs/                   # Base OS config overlay (SSH, sysctl, systemd)
│   ├── centos/stream9/Containerfile
│   ├── centos/stream10/Containerfile
│   ├── fedora/40/Containerfile
│   └── fedora/41/Containerfile
├── bootc/
│   ├── libs/common/rootfs/       # Shared libraries and scripts
│   ├── apps/hello/rootfs/        # App config overlay (systemd unit, tmpfiles)
│   ├── services/nginx/rootfs/    # nginx config overlay
│   ├── services/mongodb/rootfs/  # MongoDB config overlay
│   ├── services/valkey/rootfs/   # Valkey config overlay
│   └── services/rabbitmq/rootfs/ # RabbitMQ config overlay (x86_64 only)
├── repos/
│   └── hello/                    # Go HTTP hello world
│       ├── main.go
│       ├── go.mod
│       └── main_test.go
├── output/                       # (gitignored) build artifacts
│   └── bin/                      # pre-built Go binaries
├── builder/                      # bootc-image-builder configs (per format)
│   ├── ami/config.toml
│   ├── gce/config.toml
│   ├── qcow2/config.toml
│   ├── vmdk/config.toml
│   ├── ova/bootc-testboot.ovf
│   └── README.md
├── .github/workflows/
│   ├── build-base.yml            # Base image CI (weekly/manual)
│   ├── build-bootc.yml           # App image CI (push to main)
│   ├── build-artifacts.yml       # Disk artifact generation (manual dispatch)
│   └── ci.yml                    # PR checks (build, lint, test)
├── Containerfile                 # Layer 2: app image
└── Makefile                      # Local dev targets (apps/test/build/lint/clean)
```

---

## 3. Run Tests Locally

```bash
make test
```

**Expected output:**

```
==> Testing repos/hello/
=== RUN   TestHandleRoot
--- PASS: TestHandleRoot (0.00s)
=== RUN   TestHandleHealth
--- PASS: TestHandleHealth (0.00s)
PASS
ok      hello   0.002s
```

---

## 4. Build bootc Image

```bash
make build
```

This runs two steps automatically:

1. **`make apps`** — compiles all Go apps under `repos/*/` to `output/bin/` (static binaries, CGO disabled).
2. **`podman build`** — assembles the OS image from the base OCI image, copying pre-built binaries + `bootc/apps/*/rootfs/` and `bootc/services/*/rootfs/` overlays.

**Expected output:**

```
==> Building hello
STEP 1/14: FROM quay.io/fedora/fedora-bootc:41
...
STEP 14/14: RUN bootc container lint
COMMIT ghcr.io/duyhenryer/bootc-testboot:dev
--> 7a3b2c1d4e5f
Successfully tagged ghcr.io/duyhenryer/bootc-testboot:dev
```

---

## 5. Push to GHCR (CI only)

Pushing to GHCR is handled **automatically by GitHub Actions** when you merge to `main`. There is no need to login or push locally.

The workflow (`.github/workflows/build-bootc.yml`) builds the image with `podman build` then pushes using the built-in `GITHUB_TOKEN` — no PAT or manual credentials required.

---

## 6. Create Disk Images (CI only)

Disk images (AMI, VMDK, OVA, QCOW2, ISO) are built in CI, not locally. Use `workflow_dispatch` on `build-artifacts.yml`:

1. Go to **Actions** > **Build disk artifacts** > **Run workflow**
2. Select distro, platforms, and fill in `formats` (e.g. `qcow2,vmdk,ami`)
3. The workflow builds disk images and pushes them as OCI scratch artifacts to GHCR

### Pulling and deploying disk artifacts

For step-by-step extraction and deployment instructions (AWS, GCP, VMware, bare metal), see [004-manual-build-and-deployment.md](004-manual-build-and-deployment.md). That document covers:

- How to extract disk files from OCI artifacts (`podman create` + `podman cp`)
- Artifact path reference table for all formats (AMI, QCOW2, VMDK, OVA, ISO)
- Complete deployment walkthroughs for AWS EC2 and GCP

---

## 7. Launch EC2 from AMI

This project does not include Terraform. Launch manually:

**AWS Console:**
1. EC2 → Launch instance
2. Select **My AMIs** → choose `bootc-testboot-dev`
3. Instance type: t3.small or larger
4. Configure security group (SSH 22, HTTP 80, 8080 for hello)
5. Attach IAM instance profile with **SSM** permissions (for Session Manager)

**AWS CLI:**

```bash
aws ec2 run-instances \
  --image-id ami-0123456789abcdef0 \
  --instance-type t3.small \
  --key-name my-key \
  --security-group-ids sg-xxxxx \
  --iam-instance-profile Name=SSMInstanceProfile
```

---

## 8. Verify Instance

Connect via **AWS Systems Manager Session Manager** (or SSH if configured):

```bash
aws ssm start-session --target i-0123456789abcdef0
```

On the instance there is **no** project `Makefile` — the OS is the bootc deployment, not a dev checkout. Verify by hand. For production-safe upgrades, rollbacks, debugging, and emergencies on the host, continue to [Part B](#part-b--operations-runbook) below.

```bash
# Booted image and deployment
sudo bootc status

# Expected services (adjust names to match your image)
systemctl is-active nginx hello.service sshd chronyd || true

# HTTP (nginx → hello on 8080, if configured)
curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1/ || true
curl -sf http://127.0.0.1:8080/health || true

# Immutable /usr
touch /usr/bin/.test 2>&1 || echo "/usr is not writable (expected)"
```

**Registry audit (on your laptop, not on the VM):** after CI publishes to GHCR, run `make verify-ghcr` or `./scripts/verify-ghcr-packages.sh` to pull and verify artifact images — [008-ghcr-audit.md](008-ghcr-audit.md).

---

## 9. Adding a New App

Example: add `repos/api/` alongside `repos/hello/`.

### Step 1: Create app layout

```
repos/api/
├── main.go
├── main_test.go
├── go.mod
└── rootfs/
    ├── usr/lib/systemd/system/api.service
    └── usr/lib/tmpfiles.d/api.conf
```

### Step 2: Update Containerfile

Add COPY + enable lines (the binary is auto-built by `make apps`):

```dockerfile
COPY bootc/apps/api/rootfs/ /
RUN systemctl enable api
```

### Step 3: Rebuild and test locally

```bash
make build    # auto-discovers repos/api/, builds binary, assembles OS image
make lint     # verify bootc compliance
```

Push to `main` to trigger CI build. Use `workflow_dispatch` for disk artifacts. On existing instances, use the upgrade flow in [Part B §1](#1-upgrade-os-production-safe).

---

## Part B — Operations runbook

Quick reference for day-to-day operations on bootc-managed EC2 instances.

---

## 1. Upgrade OS (Production-Safe)

### Pre-download (business hours, safe to run anytime)

```bash
sudo bootc upgrade --download-only
```

This pulls the new image and stages it. The running system is **not affected**. The staged deployment will **not** apply on reboot until explicitly unlocked.

### Verify staged deployment

```bash
sudo bootc status --verbose
```

Look for `Download-only: yes` -- this confirms the update is staged but won't apply on reboot.

### Check for updates without side effects

```bash
sudo bootc upgrade --check
```

Only downloads metadata. Does not change the download-only state.

### Apply during maintenance window

**Option A**: Apply the specific version you downloaded (does not check for newer):

```bash
sudo bootc upgrade --from-downloaded --apply
```

System reboots immediately into the new deployment.

**Option B**: Check for newer updates first, then apply:

```bash
sudo bootc upgrade --apply
```

Pulls from image source to check for newer versions before applying.

### GOTCHA: Unexpected reboot

If the system reboots before you apply a download-only update, the staged deployment is **discarded**. However, the downloaded image data remains cached, so re-running `bootc upgrade --download-only` will be fast.

---

## 2. Rollback OS

```bash
sudo bootc rollback
sudo systemctl reboot
```

This swaps the bootloader ordering to the previous deployment. No download needed -- just a pointer swap.

**Time**: ~1-2 minutes (reboot time only).

> **WARNING**: `/var` is **NOT** rolled back. Database data, logs, and application state in `/var` survive the rollback. If the new version ran schema migrations, you must handle the database rollback separately.

### Verify after rollback

```bash
sudo bootc status
# Booted image should show the previous version
```

### Hands-on: verify /var survives rollback

Data in `/var` (logs, DB files, app state) is **not** rolled back. To confirm:

1. Before rollback, create a file: `echo "survives" | sudo tee /var/lib/bootc-testboot/hello/test-survives.txt`
2. Run `sudo bootc rollback && sudo systemctl reboot`
3. After reboot: `cat /var/lib/bootc-testboot/hello/test-survives.txt` → `survives`

This is by design: DB migrations and app state in `/var` must be handled separately.

---

## 3. Debug on Immutable OS

### Temporary writable /usr

```bash
sudo bootc usr-overlay
```

Creates a temporary writable overlay on `/usr`. Changes are **not persistent** across reboot. Useful for quick debugging (e.g., installing a tool temporarily).

### Check local /etc modifications

```bash
sudo ostree admin config-diff
```

Shows files in `/etc` that differ from the image defaults. Includes metadata changes (uid, gid, xattrs).

### View deployment status

```bash
sudo bootc status --verbose
```

Shows:
- Booted deployment (current)
- Staged deployment (if any)
- Rollback deployment (previous)
- Download-only status

### View service logs

```bash
journalctl -u hello -n 100          # app logs
journalctl -u nginx -n 50           # nginx logs
systemctl status hello nginx        # service status
```

---

## 4. Handle /opt (Read-Only) Apps

When deployed, `/opt` is read-only. Software that writes to `/opt` needs one of these solutions:

### Solution 1: Symlinks to /var (best -- maximum immutability)

```dockerfile
# In Containerfile:
RUN mkdir -p /opt/myapp && \
    ln -sr /var/log/myapp /opt/myapp/logs && \
    ln -sr /var/lib/myapp /opt/myapp/data
```

### Solution 2: BindPaths in systemd unit

```ini
[Service]
ExecStart=/opt/myapp/bin/myapp
BindPaths=/var/log/myapp:/opt/myapp/logs
BindPaths=/var/lib/myapp:/opt/myapp/data
```

### Solution 3: ostree-state-overlay (easiest, but allows some drift)

```dockerfile
# In Containerfile:
RUN systemctl enable ostree-state-overlay@opt.service
```

Creates a persistent writable overlay on `/opt`. Changes survive reboots but are overwritten on updates.

| Solution | Immutability | Complexity | Persistence | Use when |
|----------|-------------|------------|-------------|----------|
| Symlinks | Maximum | Medium | Via /var | You control the app layout |
| BindPaths | High | Low | Via /var | App has fixed paths, launched by systemd |
| State overlay | Lower | Lowest | Yes (until update) | Legacy app, hard to modify |

---

## 5. Common Gotchas

| Gotcha | Details |
|--------|---------|
| `rpm-ostree install` breaks `bootc upgrade` | Never use rpm-ostree to install packages on a bootc host. All packages must go in the Containerfile. |
| Bootloader needs separate update | `bootc upgrade` does NOT update the bootloader. Run `sudo bootupctl update` separately. |
| `/var` from Containerfile = first boot only | Content you COPY into `/var` in the Containerfile only takes effect on first install. Use `tmpfiles.d` or `StateDirectory=` instead. |
| Staged download-only discarded on reboot | If you reboot before applying, the staged deployment is lost. Image data remains cached. |
| Cannot SSH and `dnf install` | `/usr` is read-only. All changes must go through the Containerfile and a new image build. Use `bootc usr-overlay` for temporary debugging only. |
| `/etc` 3-way merge conflicts | Service configs are symlinked to `/usr/share/` (read-only), so merge conflicts do not occur for managed configs. Only machine-local files in `/etc` (hostname, SSH keys) are subject to merge. |

---

## 6. Emergency Procedures

### Instance won't boot

Launch a new EC2 instance from the previous known-good AMI. The old AMI is still available in AWS.

### Bad update deployed to fleet

```bash
sudo bootc rollback
sudo systemctl reboot
```

Time: ~2 minutes per instance. Can be parallelized across fleet via SSM Run Command.

### Need to debug a live issue

```bash
# Temporary writable access (lost on reboot)
sudo bootc usr-overlay

# Now you can install debug tools
sudo dnf install -y strace tcpdump

# Debug the issue...

# Reboot to return to clean immutable state
sudo systemctl reboot
```

### Check what image is running

```bash
sudo bootc status
```

Shows the exact container image reference and digest for the booted deployment.

---

## 7. Build Disk Images (CI only)

Disk images (AMI, VMDK, OVA, QCOW2, ISO) are built in CI via `workflow_dispatch` on `build-artifacts.yml`:

1. Go to **Actions** > **Build disk artifacts** > **Run workflow**
2. **Base distro** defaults to **all** (builds centos-stream9, centos-stream10, fedora-40, and fedora-41). Pick a single distro to limit the run. Set `platforms` and `formats` as needed (e.g. `qcow2,vmdk,ami`).
3. Artifacts are pushed to GHCR as OCI scratch images

For extraction, deployment, and verification steps, see [004-manual-build-and-deployment.md](004-manual-build-and-deployment.md).

---

## Quick reference

| Area | Task | Command or pointer |
|------|------|---------------------|
| Dev | Run unit tests | `make test` |
| Dev | Build app image | `make build` |
| Dev | Lint image | `make lint` |
| CI | Push to GHCR | Automatic on merge to `main` |
| CI | Create disk images | `workflow_dispatch` on `build-artifacts.yml` with `formats=...` (optional `base_distro=all`) |
| CI / deploy | Pull / deploy disk artifact | [004-manual-build-and-deployment.md](004-manual-build-and-deployment.md) |
| Ops | Check status | `sudo bootc status` |
| Ops | Pre-download update | `sudo bootc upgrade --download-only` |
| Ops | Apply update + reboot | `sudo bootc upgrade --from-downloaded --apply` or `sudo bootc upgrade --apply` |
| Ops | Rollback + reboot | `sudo bootc rollback && sudo systemctl reboot` |
| Ops | Temp writable /usr | `sudo bootc usr-overlay` |
| Ops | Check /etc drift | `sudo ostree admin config-diff` |
| Ops | Update bootloader | `sudo bootupctl update` |
| Registry | Verify GHCR after CI | [008-ghcr-audit.md](008-ghcr-audit.md), `make verify-ghcr` |
