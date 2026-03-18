# Manual VM Deployments

The CI pipeline generates disk images (AMI, QCOW2, VMDK, etc.) and packages them into OCI containers on GitHub Container Registry (GHCR). This document explains how to get those disk images and deploy them to your cloud environment.

You have **two options** for every deployment target:

- **Option A** — Build the disk image locally from the bootc OCI image (you control the config)
- **Option B** — Pull a pre-built disk image from GHCR (built by CI)

Currently tested end-to-end: **AWS EC2** and **Google Cloud Platform**. VMware and bare metal sections are included for reference but not yet validated.

---

## 1. How Artifacts Work

### What is an OCI artifact?

When CI runs `bootc-image-builder`, it produces a disk file (e.g. `disk.raw`, `disk.qcow2`). That file is then packaged into a minimal container image (`FROM scratch` + `COPY . /`) and pushed to GHCR. This means you can use normal `podman pull` to download disk images, just like pulling any container image.

### Image naming and tags

Pattern: `ghcr.io/duyhenryer/bootc-testboot-{distro}-{format}:{tag}`

Tags follow this scheme:

| Tag | Meaning |
|-----|---------|
| `latest-amd64` | Latest build for x86_64 |
| `latest-arm64` | Latest build for aarch64 |
| `latest` | Multi-arch manifest (auto-selects your platform) |
| `v3-amd64` | Version 3 for x86_64 |
| `v3` | Multi-arch manifest for version 3 |

### Artifact path reference

The disk file path **inside** the OCI container depends on the format. These paths have been verified against the actual CI output:

| Format | OCI image suffix | Path inside container | Example image |
|--------|-----------------|----------------------|---------------|
| AMI | `-ami` | `/image/disk.raw` | `*-centos-stream9-ami:latest-amd64` |
| QCOW2 | `-qcow2` | `/qcow2/disk.qcow2` | `*-centos-stream9-qcow2:latest-amd64` |
| Raw (for GCE) | `-raw` | `/image/disk.raw` | `*-centos-stream9-raw:latest-amd64` |
| VMDK | `-vmdk` | `/vmdk/disk.vmdk` | `*-centos-stream9-vmdk:latest-amd64` |
| OVA | `-ova` | `/*.ova` | `*-centos-stream9-ova:latest-amd64` |
| Anaconda ISO | `-anaconda-iso` | `/bootiso/disk.iso` | `*-centos-stream9-anaconda-iso:latest-amd64` |

### How to extract a disk file (generic steps)

This 3-step pattern works for any format:

```bash
# 1. Pull the artifact image
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest-amd64

# 2. Create a temporary container (the image has no OS, so we use /bin/true as a dummy command)
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest-amd64 /bin/true)

# 3. Copy the disk file out of the container
podman cp "$ctr":/qcow2/disk.qcow2 ./disk.qcow2

# 4. Clean up
podman rm "$ctr"
```

Change the image name and path to match your format (see the table above).

> **Why `/bin/true`?** These are `FROM scratch` images with no operating system inside. `podman create` requires an entrypoint, but we never actually run the container -- we just use it to access the filesystem layer. `/bin/true` is a dummy value that satisfies the requirement.

### Auditing an artifact image

To see everything inside an artifact image without extracting:

```bash
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ami:latest-amd64 /bin/true)
podman export "$ctr" | tar -t
podman rm "$ctr"
```

---

## 2. bootc-image-builder Reference

bootc-image-builder is a **container** that converts bootc OCI images into disk images. You run it with podman; it uses [osbuild](https://osbuild.org/docs/bootc/) under the hood to produce QCOW2, AMI, VMDK, raw, and other formats.

**Sources:**
- [bootc-image-builder (GitHub)](https://github.com/osbuild/bootc-image-builder)
- [osbuild: bootc-image-builder](https://osbuild.org/docs/bootc/)

### Tool prerequisites

| Requirement | Notes |
|-------------|-------|
| **podman** | Required. Use package manager on Linux or Podman Desktop on macOS/Windows |
| **--privileged** | Required. Cannot run in ECS/Fargate or other restricted environments |
| **osbuild-selinux** | Required on SELinux-enforced systems (e.g. Fedora, RHEL) |
| **Rootful podman** | On macOS, run `podman machine set --rootful` before starting |

### Image types

| Type | Target |
|------|--------|
| `ami` | Amazon Machine Image |
| `qcow2` (default) | QEMU/KVM |
| `vmdk` | vSphere, VMware |
| `vhd` | Virtual PC, Hyper-V |
| `gce` | Google Compute Engine |
| `raw` | Raw disk |
| `bootc-installer` | Installer ISO |
| `anaconda-iso` | Anaconda installer ISO |

Pass multiple types: `--type qcow2 --type ami` (comma/space separation does not work).

### Volumes

| Volume | Purpose | Required |
|--------|----------|----------|
| `/output` | Artifact output directory | Yes (unless AMI auto-upload) |
| `/var/lib/containers/storage` | Container storage for image cache | Yes |
| `/store` | osbuild store cache | No |
| `/rpmmd` | DNF cache | No |

You must mount `/var/lib/containers/storage` so the builder can pull and reuse your bootc image.

### Build config (config.toml)

The config file is mounted at `/config.toml` (or `/config/config.toml` when mounting a directory). It follows the [Blueprint schema](https://github.com/osbuild/blueprint); bootc-image-builder supports a subset.

**Users:**

```toml
[[customizations.user]]
name = "devops"
password = "optional-plaintext"
key = "ssh-rsa AAAA... devops@company.com"
groups = ["wheel"]
```

Fields: `name` (required), `password`, `key`, `groups`.

**Filesystem:**

Set minimum sizes for `/`, `/boot`, and extra partitions under `/var`:

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/data"
minsize = "50 GiB"
```

Rules:
- `/` -- root filesystem (mounted at `/sysroot` when booted)
- `/boot` -- boot partition
- Subdirectories of `/var` supported, e.g. `/var/data`
- `/var` itself cannot be a mountpoint
- Symlinks in `/var` (e.g. `/var/home`, `/var/run`) cannot be mountpoints

**Kernel arguments:**

```toml
[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

### Target architecture

Use `--target-arch` to build for a different architecture (e.g. amd64 from arm64 Mac):

```bash
--target-arch amd64
```

The bootc OCI image and bootc-image-builder image must support the target arch. Check [Quay](https://quay.io/repository/centos-bootc/bootc-image-builder?tab=tags) for supported architectures.

For builder configs per format, see [builder/README.md](../../builder/README.md).

---

## 3. Deploying to AWS EC2 (AMI)

**Status: Tested**

The flow: bootc OCI image → raw disk → S3 → AMI → EC2 instance.

The image includes nginx, MongoDB 8.0, Redis, and the hello app. RabbitMQ is included on x86_64 only (no upstream arm64 packages).

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| **AWS CLI v2** | Installed and configured (`aws configure`) |
| **IAM permissions** | `s3:PutObject`, `s3:CreateBucket`, `ec2:RunInstances` + Method A: `ec2:ImportImage`, `ec2:DescribeImportImageTasks` + Method B: `ec2:ImportSnapshot`, `ec2:DescribeImportSnapshotTasks`, `ec2:RegisterImage` |
| **VM Import role** | The `vmimport` service role must exist ([AWS docs](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html)) |
| **podman** | Required for Option A (local build) and Option B (pulling from GHCR) |

### Option A: Build locally with bootc-image-builder

This builds the disk image on your machine. You need the bootc OCI image already built (`make build`).

**Step 1: Copy your image to root podman storage**

`bootc-image-builder` runs with `sudo` and uses root's container storage, not your user storage. You must copy the image across:

```bash
podman save ghcr.io/duyhenryer/bootc-testboot:latest | sudo podman load
```

**Step 2: Build the raw disk**

Run from the **repository root**. Use `$(pwd)` so paths resolve correctly with `sudo`:

```bash
mkdir -p output/ami
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$(pwd)/builder/ami":/config:ro \
    -v "$(pwd)/output/ami":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type ami --rootfs ext4 \
    --config /config/config.toml \
    ghcr.io/duyhenryer/bootc-testboot:latest
```

Output: `output/ami/image/disk.raw`

> **Gotcha:** `builder/ami/config.toml` must be a **regular file**, not a symlink. If it's a symlink, the container can't follow it (the symlink target is outside the mounted volume). The config includes AWS-tuned kernel args: `nvme_core.io_timeout=4294967295` for Nitro NVMe and `console=ttyS0` for EC2 serial console.

### Option B: Pull from GHCR

If CI has already built the AMI artifact, pull and extract it:

```bash
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ami:latest-amd64

ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ami:latest-amd64 /bin/true)
podman cp "$ctr":/image/disk.raw ./disk.raw
podman rm "$ctr"
```

### Upload and deploy

AWS offers two ways to turn a disk image in S3 into a launchable AMI:

| | import-image (recommended) | import-snapshot (advanced) |
|---|---|---|
| **Result** | AMI created directly | EBS snapshot (must manually register as AMI) |
| **AWS commands** | 4: `s3 cp` → `import-image` → `describe-import-image-tasks` → `run-instances` | 6: `s3 cp` → `import-snapshot` → `describe-import-snapshot-tasks` → `register-image` → `run-instances` |
| **Disk formats** | raw, VMDK, VHD, VHDX, OVA | raw, VMDK, VHD, VHDX |
| **When to use** | Default choice for most users | Need fine control over AMI flags (boot-mode, device mapping, etc.) |

> **Note:** Both methods accept **raw** and **VMDK** (our CI builds both). `import-image` also supports **OVA**; `import-snapshot` does not. For this project you can use either raw (e.g. from `--type ami`) or VMDK (from `--type vmdk`) with either method.

Reference: [AWS VM Import/Export comparison](https://docs.aws.amazon.com/vm-import/latest/userguide/vmimport-differences.html)

#### Method A: import-image (recommended)

This is the simplest path. One command creates the AMI directly -- no `register-image` needed.

```bash
# Step 1: Set your region and create an S3 bucket
export AWS_REGION=ap-southeast-1
export BUCKET=bootc-testboot-$(date +%Y%m%d)
aws s3 mb "s3://${BUCKET}" --region "$AWS_REGION"

# Step 2: Upload the raw disk to S3
# If you used Option A, the file is at output/ami/image/disk.raw
# If you used Option B, the file is at ./disk.raw
aws s3 cp output/ami/image/disk.raw "s3://${BUCKET}/bootc-testboot.raw"

# Step 3: Import directly as AMI
aws ec2 import-image \
    --region "$AWS_REGION" \
    --description "bootc-testboot CentOS Stream 9" \
    --license-type BYOL \
    --disk-containers "[{\"Format\":\"raw\",\"UserBucket\":{\"S3Bucket\":\"${BUCKET}\",\"S3Key\":\"bootc-testboot.raw\"}}]"
# Output contains ImportTaskId, e.g. "import-ami-0123456789abcdef0"
# Save it -- you need it for the next step.

# Step 4: Wait for the import to finish
# Re-run this command until Status shows "completed":
aws ec2 describe-import-image-tasks \
    --region "$AWS_REGION" \
    --import-task-ids import-ami-XXXXX
# When done, the output contains ImageId (e.g. "ami-0123456789abcdef0")
# The AMI is ready to launch -- no register-image needed.

# Step 5: Launch an EC2 instance
aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id ami-XXXXX \
    --instance-type t3.medium \
    --key-name YOUR_KEY_PAIR \
    --security-group-ids sg-XXXXX \
    --subnet-id subnet-XXXXX \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bootc-testboot}]'
```

Replace `XXXXX` placeholders with the actual IDs from the output of each previous step.

> **VMDK format also works.** If you built with `--type vmdk` instead of `--type ami`, change `"Format":"raw"` to `"Format":"vmdk"` and the S3 key accordingly. `import-image` handles the conversion.

**For aarch64 (arm64) builds:** use a Graviton instance type (e.g. `t4g.medium`). `import-image` detects the architecture automatically. RabbitMQ is not available on arm64.

#### Method B: import-snapshot (advanced)

Use this if you need precise control over AMI registration flags (e.g. custom `--boot-mode`, `--block-device-mappings`, or specific `--architecture` overrides).

```bash
# Steps 1-2 are the same as Method A (create bucket, upload raw disk)

# Step 3: Import as EBS snapshot
aws ec2 import-snapshot \
    --region "$AWS_REGION" \
    --description "bootc-testboot CentOS Stream 9" \
    --disk-container "Format=raw,UserBucket={S3Bucket=${BUCKET},S3Key=bootc-testboot.raw}"
# Output contains ImportTaskId, e.g. "import-snap-0123456789abcdef0"

# Step 4: Wait for the import to finish
aws ec2 describe-import-snapshot-tasks \
    --region "$AWS_REGION" \
    --import-task-ids import-snap-XXXXX
# When done, note the SnapshotId (e.g. "snap-0123456789abcdef0")

# Step 5: Register the snapshot as an AMI (manual -- you control every flag)
aws ec2 register-image \
    --region "$AWS_REGION" \
    --name "bootc-testboot-centos9-$(date +%Y%m%d)" \
    --description "bootc CentOS Stream 9 - hello + nginx + MongoDB + Redis" \
    --architecture x86_64 \
    --root-device-name /dev/xvda \
    --virtualization-type hvm \
    --ena-support \
    --boot-mode uefi \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=snap-XXXXX,VolumeType=gp3}"
# Output contains ImageId, e.g. "ami-0123456789abcdef0"

# Step 6: Launch (same as Method A Step 5)
aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id ami-XXXXX \
    --instance-type t3.medium \
    --key-name YOUR_KEY_PAIR \
    --security-group-ids sg-XXXXX \
    --subnet-id subnet-XXXXX \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bootc-testboot}]'
```

**For aarch64 (arm64) builds:** use `--architecture arm64` in `register-image` and a Graviton instance type (e.g. `t4g.medium`).

### SSH in and verify

```bash
ssh -i ~/.ssh/YOUR_KEY.pem devops@EC2_PUBLIC_IP

systemctl status hello nginx mongod redis
curl -sf http://127.0.0.1:8080/health
```

If the security group allows inbound HTTP (port 80), nginx reverse-proxies to the hello app:

```bash
curl -sf http://EC2_PUBLIC_IP/
```

### Alternative: AMI auto-upload (skip S3 manually)

bootc-image-builder can upload the AMI directly to AWS if you pass `--aws-ami-name`, `--aws-bucket`, and `--aws-region` **together**. When all three are set, no `/output` mount is needed -- the image goes straight to AWS.

The S3 bucket must already exist, and the [vmimport service role](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html) must be configured.

**Credentials via `$HOME/.aws`:**

```bash
sudo podman run \
  --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v $HOME/.aws:/root/.aws:ro \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  --env AWS_PROFILE=default \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami --rootfs ext4 \
  --aws-ami-name bootc-testboot-ami \
  --aws-bucket YOUR_BOOTC_IMPORT_BUCKET \
  --aws-region us-east-1 \
  ghcr.io/duyhenryer/bootc-testboot:latest
```

**Credentials via env-file (recommended for CI):**

Never pass secrets via `--env AWS_ACCESS_KEY_ID=xxx` -- they leak in process lists. Use `--env-file` instead:

```bash
# aws.secrets (chmod 600, add to .gitignore)
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...

sudo podman run \
  --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  --env-file=aws.secrets \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami --rootfs ext4 \
  --aws-ami-name bootc-testboot-ami \
  --aws-bucket YOUR_BOOTC_IMPORT_BUCKET \
  --aws-region us-east-1 \
  ghcr.io/duyhenryer/bootc-testboot:latest
```

---

## 4. Deploying to Google Cloud Platform (GCE)

**Status: Tested**

GCP requires a `.tar.gz` containing exactly one file named `disk.raw`. The flow: bootc OCI image → raw disk → tar.gz → GCS → GCE image → VM instance.

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| **gcloud CLI** | Installed and authenticated (`gcloud auth login`) |
| **gsutil** | Included with gcloud SDK |
| **GCS bucket** | Must exist in your project |
| **IAM permissions** | `roles/compute.imageAdmin` + `roles/storage.objectAdmin` |
| **podman** | Required for building and extracting |

### Option A: Build locally with bootc-image-builder

**Step 1: Copy your image to root podman storage**

```bash
podman save ghcr.io/duyhenryer/bootc-testboot:latest | sudo podman load
```

**Step 2: Build the raw disk and package for GCE**

```bash
mkdir -p output/gce
sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$(pwd)/builder/gce":/config:ro \
    -v "$(pwd)/output/gce":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type raw --rootfs ext4 \
    --config /config/config.toml \
    ghcr.io/duyhenryer/bootc-testboot:latest

# Package for GCE (the tar.gz must contain exactly "disk.raw")
cd output/gce/image
tar -Szcf ../bootc-centos9.tar.gz disk.raw
```

### Option B: Pull from GHCR

```bash
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-raw:latest-amd64

ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-raw:latest-amd64 /bin/true)
podman cp "$ctr":/image/disk.raw ./disk.raw
podman rm "$ctr"

tar -Szcf bootc-centos9.tar.gz disk.raw
```

### Upload and deploy

```bash
# Upload to GCS
gsutil cp ./output/gce/bootc-centos9.tar.gz \
    gs://bootc-testboot-drive/bootc-centos9.tar.gz

# Create GCE custom image
gcloud compute images create "bootc-centos9-v4" \
    --project="skilled-box-481815-k8" \
    --source-uri="gs://bootc-testboot-drive/bootc-centos9.tar.gz" \
    --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE \
    --description="bootc CentOS Stream 9 - hello app + nginx + MongoDB 8.0 + Redis + RabbitMQ"

# Create VM instance
gcloud compute instances create "vm-bootc-test" \
    --project="skilled-box-481815-k8" \
    --zone="asia-southeast1-a" \
    --machine-type="e2-small" \
    --image="bootc-centos9-v4" \
    --boot-disk-size=20GB \
    --tags=http-server,https-server
```

### SSH in and verify

```bash
gcloud compute ssh devops@vm-bootc-test \
    --project=skilled-box-481815-k8 \
    --zone=asia-southeast1-a \
    --command="systemctl status hello nginx mongod redis rabbitmq-server && curl -sf http://127.0.0.1:8080/health"
```

### Bugs found and fixed

Issues discovered during GCE deployment:

| Bug | Fix |
|-----|-----|
| sudoers files had 664 permissions (must be 0440) | `chmod 0440` on sudoers.d files |
| MongoDB 8.0 removed `storage.journal.enabled` option | Removed obsolete config from `mongod.conf` |
| Redis SELinux: `redis_t` cannot read `usr_t` (config in `/usr/share/`) | systemd override reads Redis config from `/usr/share/` directly instead of symlink |

---

## 5. Deploying to VMware (VMDK / OVA)

**Status: Not yet tested end-to-end.** The CI builds VMDK and OVA artifacts, but manual deployment to vSphere has not been validated.

### Option B: Pull from GHCR

```bash
# VMDK
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-vmdk:latest-amd64
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-vmdk:latest-amd64 /bin/true)
podman cp "$ctr":/vmdk/disk.vmdk ./disk.vmdk
podman rm "$ctr"

# OVA (ready-to-import archive with OVF + VMDK + manifest)
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ova:latest-amd64
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ova:latest-amd64 /bin/true)
podman export "$ctr" | tar -xf - -C ./output-ova/
podman rm "$ctr"
```

### Import into vSphere

1. In vSphere Client: **Hosts and Clusters** > right-click host > **Deploy OVF Template**
2. Select the `.ova` file
3. Follow the wizard (accept defaults or customize CPU/RAM)
4. Power on the VM

---

## 6. Bare Metal (Anaconda ISO)

**Status: Not yet tested end-to-end.** The CI builds Anaconda ISO artifacts.

### Pull from GHCR

```bash
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-anaconda-iso:latest-amd64
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-anaconda-iso:latest-amd64 /bin/true)
podman cp "$ctr":/bootiso/disk.iso ./bootc-installer.iso
podman rm "$ctr"
```

### Flash and boot

```bash
sudo dd if=./bootc-installer.iso of=/dev/sdX bs=4M status=progress
```

Boot the physical machine from the USB drive. The Anaconda installer automatically lays down the bootc image onto the hard drive.

---

## 7. Adding New Deployment Targets

All deployment targets follow the same two-option pattern:

1. **Option A (local):** `bootc-image-builder --type <format>` with a `builder/<format>/config.toml`
2. **Option B (CI):** Pull from `ghcr.io/duyhenryer/bootc-testboot-{distro}-{format}:{tag}` and extract using `podman cp`

For builder configs per format, see [builder/README.md](../../builder/README.md).

---

## 8. Running QCOW2 Locally

If you built a QCOW2 image (via `--type qcow2`), you can boot it locally without deploying to any cloud.

**With QEMU:**

```bash
qemu-system-x86_64 \
  -M accel=kvm \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -serial stdio \
  -snapshot output/qcow2/disk.qcow2
```

**With virt-install:**

```bash
sudo virt-install \
  --name fedora-bootc \
  --cpu host \
  --vcpus 4 \
  --memory 4096 \
  --import --disk ./output/qcow2/disk.qcow2,format=qcow2 \
  --os-variant fedora-eln
```

---

## 9. Tips and Checklist

### Passwordless sudo

Base images may not enable passwordless sudo. Add to your derived bootc Containerfile:

```dockerfile
ADD wheel-passwordless-sudo /etc/sudoers.d/wheel-passwordless-sudo
```

Content of `wheel-passwordless-sudo`:

```
%wheel ALL=(ALL) NOPASSWD: ALL
```

### Pre-flight checklist

- [ ] Install podman and osbuild-selinux (if SELinux)
- [ ] Use `--privileged`; not suitable for ECS/Fargate
- [ ] Mount `/var/lib/containers/storage`
- [ ] Mount config as `/config.toml` or `/config/config.toml`
- [ ] For AWS: prefer `import-image` (creates AMI directly) over `import-snapshot` + `register-image`
- [ ] For AMI auto-upload: all of `--aws-ami-name`, `--aws-bucket`, `--aws-region`
- [ ] Use `--env-file` for AWS secrets, never plain `--env`
- [ ] Add vmimport role and S3 permissions for AMI (required for both `import-image` and `import-snapshot`)
- [ ] Always `podman pull` the target image before running bootc-image-builder
- [ ] Always pass `--rootfs ext4` to avoid "no default fs set" errors
- [ ] Do not use `-it` flags -- they break CI/non-interactive builds
- [ ] For VMDK: mount `./output:/output` for local output
- [ ] For OVA: CI auto-packages from VMDK when `vmdk` is in `formats` input
- [ ] For GCE: `--type raw` then tar.gz, or `--type gce` for direct tar.gz output
- [ ] For GCE: IAM `roles/compute.imageAdmin` + `roles/storage.objectAdmin`
- [ ] Filesystem: only `/`, `/boot`, and `/var/*` subdirs (no `/var` itself, no symlinks)
