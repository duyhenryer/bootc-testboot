# Walkthrough: Step-by-Step

This document walks through the entire bootc-testboot flow from prerequisites to adding a new app.

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

For step-by-step extraction and deployment instructions (AWS, GCP, VMware, bare metal), see [005-manual-build-and-deployment.md](005-manual-build-and-deployment.md). That document covers:

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

On the instance there is **no** project `Makefile` — the OS is the bootc deployment, not a dev checkout. Verify by hand (see also [004-runbook.md](004-runbook.md)):

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

**Registry audit (on your laptop, not on the VM):** after CI publishes to GHCR, run `make verify-ghcr` or `./scripts/verify-ghcr-packages.sh` to pull and verify artifact images — [010-ghcr-audit.md](010-ghcr-audit.md).

---

## 9. Test OS Upgrade

Production-safe flow: download during business hours, apply during maintenance.

**Phase 1 — Download (no reboot):**

```bash
sudo bootc upgrade --check    # see what's available
sudo bootc upgrade            # download + stage (no reboot yet)
```

**Phase 2 — Apply (during maintenance):**

```bash
sudo systemctl reboot         # boots into the new deployment
```

After reboot, verify the upgrade:

```bash
sudo bootc status
```

---

## 10. Test Rollback

If the new deployment is problematic:

```bash
sudo bootc rollback           # marks previous deployment as default
sudo systemctl reboot         # boots into the previous deployment
```

> **Warning:** `/var` data is **not** rolled back. Database migrations and app state
> in `/var` must be handled separately.

---

## 11. Verify /var Data Survives Rollback

Data in `/var` (logs, DB files, app state) is **not** rolled back. To confirm:

1. Before rollback, create a file: `echo "survives" | sudo tee /var/lib/bootc-testboot/hello/test-survives.txt`
2. Run `sudo bootc rollback && sudo systemctl reboot`
3. After reboot: `cat /var/lib/bootc-testboot/hello/test-survives.txt` → `survives`

This is by design: DB migrations and app state in `/var` must be handled separately.

---

## 12. Adding a New App

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

Push to `main` to trigger CI build. Use `workflow_dispatch` for disk artifacts. On existing instances, `bootc upgrade` pulls the new image.

---

## Quick Reference

| Step | Command |
|------|---------|
| Test | `make test` |
| Build | `make build` |
| Lint | `make lint` |
| Push (CI only) | Auto via GitHub Actions on merge to `main` |
| Create disk images | `workflow_dispatch` on `build-artifacts.yml` with `formats=...` |
| Upgrade | `sudo bootc upgrade && sudo systemctl reboot` |
| Rollback | `sudo bootc rollback && sudo systemctl reboot` |
| Status | `sudo bootc status` |
