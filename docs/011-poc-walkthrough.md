# POC Walkthrough: Step-by-Step

This document walks through the entire bootc-testboot POC flow from prerequisites to adding a new app.

---

## 1. Prerequisites

Before starting, ensure you have:

| Requirement | Details |
|-------------|---------|
| **AWS account** | With permissions for EC2, S3, IAM |
| **EC2 builder instance** | For AMI creation: **t3.large** or larger, with **podman** installed, running as root |
| **VM Import service role** | Configured for S3/EC2 import (see [AWS VM Import prerequisites](https://docs.aws.amazon.com/vm-import/latest/userguide/vmie_prereqs.html)) |
| **S3 bucket** | For bootc-image-builder intermediate artifacts |
| **Go 1.22+** | For building apps locally (`go version`) |
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
├── apps/
│   └── hello/                 # Go HTTP hello world
│       ├── main.go
│       ├── main_test.go
│       ├── go.mod
│       ├── hello.service      # systemd unit
│       └── hello-tmpfiles.conf
├── output/                    # (gitignored) build artifacts
│   └── bin/                   # pre-built Go binaries
├── configs/
│   ├── nginx.conf
│   ├── sshd-hardening.conf
│   └── containers-auth.json
├── scripts/
│   ├── create-ami.sh
│   ├── create-vmdk.sh
│   ├── create-ova.sh
│   ├── upgrade-os.sh
│   ├── rollback-os.sh
│   └── verify-instance.sh
├── templates/
│   └── bootc-poc.ovf            # OVF descriptor for OVA packaging
├── .github/workflows/
│   ├── build-bootc.yml
│   ├── create-ami.yml
│   └── create-ova.yml
├── Containerfile              # Single-stage: COPY pre-built binaries + configs
├── config.toml                # bootc-image-builder customizations
└── Makefile
```

---

## 3. Run Tests Locally

```bash
make test
```

**Expected output:**

```
==> Testing apps/hello/
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

1. **`make apps`** — compiles all Go apps under `apps/*/` to `output/bin/` (static binaries, CGO disabled).
2. **`podman build`** — assembles the OS image from a single `FROM quay.io/fedora/fedora-bootc:41`, copying pre-built binaries + configs.

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

The workflow (`.github/workflows/build-bootc.yml`) runs `make build` then `make ci-push` using the built-in `GITHUB_TOKEN` -- no PAT or manual credentials required.

If you need to push manually for debugging, use the CI-only targets:

```bash
export GITHUB_USER=your-github-username
export GHCR_TOKEN=your-personal-access-token  # needs write:packages scope
make ci-login
make ci-push
```

---

## 6. Create AMI

Run on the **EC2 builder instance** (t3.large with podman):

```bash
export REGISTRY=ghcr.io/duyhenryer
export IMAGE=${REGISTRY}/bootc-testboot
export AWS_REGION=ap-southeast-1
export AWS_BUCKET=my-bootc-poc-bucket  # must exist

make ami
```

**Important:** `bootc-image-builder` runs in a **privileged** container and needs:
- `--privileged`
- `--security-opt label=type:unconfined_t`
- Access to `/var/lib/containers/storage` (for the image)
- AWS credentials (`~/.aws`)

**Expected output:**

```
==> Creating AMI: bootc-poc-dev
    Image:  ghcr.io/duyhenryer/bootc-testboot:dev
    Region: ap-southeast-1
    Bucket: my-bootc-poc-bucket
...
==> AMI bootc-poc-dev created. Check AWS Console for the new AMI.
```

---

## 6b. Create VMDK / OVA (for VMware vSphere)

If targeting VMware instead of (or in addition to) AWS, create a VMDK disk image and package it as an OVA:

```bash
# Create VMDK via bootc-image-builder (requires sudo)
make vmdk

# Package VMDK into OVA (VMDK + OVF descriptor + manifest)
make ova

# Or run both in one step (ova depends on vmdk):
make ova
```

Customize VM specs via environment variables:

```bash
NUM_CPUS=4 MEMORY_MB=8192 DISK_CAPACITY=100 make ova
```

**Expected output:**

```
==> Creating VMDK: bootc-poc-dev
    Image: ghcr.io/duyhenryer/bootc-testboot:dev
...
==> VMDK created at output/vmdk/disk.vmdk
==> Packaging OVA: bootc-poc-dev
...
==> OVA created at output/ova/bootc-poc-dev.ova
    Import into vSphere: Hosts > Deploy OVF Template > output/ova/bootc-poc-dev.ova
```

**Import into vSphere:**

1. In vSphere Client: **Hosts and Clusters** > right-click host > **Deploy OVF Template**
2. Select the `.ova` file
3. Follow the wizard (accept defaults or customize)
4. Power on the VM

---

## 7. Launch EC2 from AMI

This POC does not include Terraform. Launch manually:

**AWS Console:**
1. EC2 → Launch instance
2. Select **My AMIs** → choose `bootc-poc-dev`
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

On the instance, clone the repo and run health checks:

```bash
git clone https://github.com/duyhenryer/bootc-testboot.git
cd bootc-testboot
make verify
```

**Expected output:**

```
==> bootc status
Deployment: quay.io/fedora/fedora-bootc:41 ...

==> Health checks:
  [PASS] bootc status
  [PASS] nginx running
  [PASS] hello.service running
  [PASS] cloud-init running
  [PASS] curl localhost:80
  [PASS] curl localhost:8080
  [PASS] /usr is read-only

==> Results: 7 passed, 0 failed
```

---

## 9. Test OS Upgrade

Production-safe flow: download during business hours, apply during maintenance.

**Phase 1 — Download (no reboot):**

```bash
./scripts/upgrade-os.sh download
```

**Expected output:**

```
==> Phase 1: Downloading update (no apply, no reboot)
...
==> Staged deployment status:
Deployment: quay.io/fedora/fedora-bootc:41 ...

Download complete. Run './scripts/upgrade-os.sh apply' during maintenance window.
```

**Phase 2 — Apply (during maintenance):**

```bash
./scripts/upgrade-os.sh apply
```

When prompted, type `y` to confirm. The system will reboot into the new deployment.

---

## 10. Test Rollback

If the new deployment is problematic:

```bash
./scripts/rollback-os.sh
```

When prompted, type `y`. The system rolls back to the previous deployment and reboots.

**Expected output:**

```
==> Current status:
...
WARNING: /var data will NOT be rolled back.
         The system will reboot into the previous deployment.

Continue with rollback + reboot? [y/N] y
==> Rolling back...
==> Rebooting...
```

---

## 11. Verify /var Data Survives Rollback

Data in `/var` (logs, DB files, app state) is **not** rolled back. To confirm:

1. Before rollback, create a file: `echo "survives" | sudo tee /var/lib/hello/test-survives.txt`
2. Run `./scripts/rollback-os.sh` and reboot
3. After reboot: `cat /var/lib/hello/test-survives.txt` → `survives`

This is by design: DB migrations and app state in `/var` must be handled separately.

---

## 12. Adding a New App

Example: add `apps/api/` alongside `apps/hello/`.

### Step 1: Create app layout

```
apps/api/
├── main.go
├── main_test.go
├── go.mod
├── api.service
└── api-tmpfiles.conf  (if needed)
```

### Step 2: Update Containerfile

Add COPY + enable lines (the binary is auto-built by `make apps`):

```dockerfile
COPY apps/api/api.service /usr/lib/systemd/system/api.service
COPY apps/api/api-tmpfiles.conf /usr/lib/tmpfiles.d/api.conf
RUN systemctl enable api
```

### Step 3: Rebuild and redeploy

```bash
make build    # auto-discovers apps/api/, builds binary, assembles OS image
make push
make ami
```

Launch a new instance from the updated AMI (or use `bootc upgrade` on existing instances).

---

## Quick Reference

| Step           | Command                         |
|----------------|----------------------------------|
| Test           | `make test`                      |
| Build          | `make build`                     |
| Push (CI only) | Auto via GitHub Actions on merge to `main` |
| Create AMI     | `make ami`                       |
| Create VMDK    | `make vmdk`                      |
| Create OVA     | `make ova`                       |
| Verify         | `make verify` (on instance)      |
| Upgrade download | `./scripts/upgrade-os.sh download` |
| Upgrade apply  | `./scripts/upgrade-os.sh apply`   |
| Rollback       | `./scripts/rollback-os.sh`       |
