# Creating Disk Images (AMIs) with bootc-image-builder

A deep-dive guide for DevOps teams converting bootc OCI images into disk images (QCOW2, AMI, etc.) using bootc-image-builder.

**Sources:**
- [bootc-image-builder (GitHub)](https://github.com/osbuild/bootc-image-builder)
- [osbuild: bootc-image-builder](https://osbuild.org/docs/bootc/)

---

## What It Is

bootc-image-builder is a **container** that converts bootc OCI images into disk images. You run it with podman; it uses osbuild under the hood to produce QCOW2, AMI, VMDK, raw, and other formats.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **podman** | Required. Use package manager on Linux or Podman Desktop on macOS/Windows |
| **--privileged** | Required. Cannot run in ECS/Fargate or other restricted environments |
| **osbuild-selinux** | Required on SELinux-enforced systems (e.g. Fedora, RHEL) |
| **Rootful podman** | On macOS, run `podman machine set --rootful` before starting |

---

## Image Types

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

---

## Volumes

| Volume | Purpose | Required |
|--------|----------|----------|
| `/output` | Artifact output directory | Yes (unless AMI auto-upload) |
| `/var/lib/containers/storage` | Container storage for image cache | Yes |
| `/store` | osbuild store cache | No |
| `/rpmmd` | DNF cache | No |

You must mount `/var/lib/containers/storage` so the builder can pull and reuse your bootc image.

---

## Build Config (config.toml)

The config file is mounted at `/config.toml`. It follows the [Blueprint schema](https://github.com/osbuild/blueprint); bootc-image-builder supports a subset.

### Users

```toml
[[customizations.user]]
name = "devops"
password = "optional-plaintext"
key = "ssh-rsa AAAA... devops@company.com"
groups = ["wheel"]
```

Fields: `name` (required), `password`, `key`, `groups`.

### Filesystem

Set minimum sizes for `/`, `/boot`, and extra partitions under `/var`:

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/data"
minsize = "50 GiB"
```

**Rules:**
- `/` — root filesystem (mounted at `/sysroot` when booted)
- `/boot` — boot partition
- Subdirectories of `/var` supported, e.g. `/var/data`
- `/var` itself cannot be a mountpoint
- Symlinks in `/var` (e.g. `/var/home`, `/var/run`) cannot be mountpoints

### Kernel Arguments

```toml
[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

---

## QCOW2 Local Build

```bash
# Pull the bootc image (or use one you built)
sudo podman pull quay.io/fedora/fedora-bootc:41

mkdir -p output

sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./builder/qcow2/config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --use-librepo=True \
  quay.io/fedora/fedora-bootc:41
```

For Fedora, you may need `--rootfs btrfs` if the image defaults to btrfs.

Output: `output/qcow2/disk.qcow2`

---

## AWS AMI Auto-Upload

Use `--aws-ami-name`, `--aws-bucket`, and `--aws-region` **together**. If all three are set:
- No `/output` mount needed
- Image is uploaded to AWS; no local file
- Bucket must already exist
- Requires [vmimport service role](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html) with S3 permissions

### AWS Credentials: Mount $HOME/.aws

```bash
sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v $HOME/.aws:/root/.aws:ro \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  --env AWS_PROFILE=default \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  --aws-ami-name my-bootc-ami \
  --aws-bucket my-bootc-import-bucket \
  --aws-region us-east-1 \
  quay.io/fedora/fedora-bootc:41
```

### AWS Credentials: env-file (Never --env with Plain Values)

Never pass secrets via `--env AWS_ACCESS_KEY_ID=xxx`; they can leak in process lists.

Use `--env-file`:

```bash
# aws.secrets (chmod 600, add to .gitignore)
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...

sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  --env-file=aws.secrets \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  --aws-ami-name my-bootc-ami \
  --aws-bucket my-bootc-import-bucket \
  --aws-region us-east-1 \
  quay.io/fedora/fedora-bootc:41
```

---

## Our POC: Exact config.toml and Command

### config.toml

```toml
# bootc-image-builder customizations
# Docs: https://github.com/osbuild/bootc-image-builder#-build-config

[[customizations.user]]
name = "devops"
# Replace with your actual SSH public key
key = "ssh-rsa AAAA... devops@company.com"
groups = ["wheel"]

[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/data"
minsize = "50 GiB"

[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

### QCOW2 Build (Local)

```bash
sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./builder/qcow2/config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --use-librepo=True \
  --rootfs btrfs \
  quay.io/fedora/fedora-bootc:41
```

### AMI Build (Auto-upload)

```bash
sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v $HOME/.aws:/root/.aws:ro \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  --env AWS_PROFILE=default \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  --aws-ami-name bootc-poc-ami \
  --aws-bucket YOUR_BOOTC_IMPORT_BUCKET \
  --aws-region us-east-1 \
  --rootfs btrfs \
  quay.io/fedora/fedora-bootc:41
```

Replace `YOUR_BOOTC_IMPORT_BUCKET` with an S3 bucket that exists and has the vmimport role configured. To use your own built bootc image (e.g. from this repo's `Containerfile`), build it first with `podman build -t my-bootc:latest .` and replace the image reference.

---

## VMDK Build (VMware / vSphere)

Use `--type vmdk` to create a VMDK disk image suitable for VMware vSphere, ESXi, or VirtualBox.

```bash
sudo podman run \
  --rm \
  -it \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./builder/qcow2/config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type vmdk \
  --config /config.toml \
  ghcr.io/duyhenryer/bootc-testboot:latest
```

Output: `output/vmdk/disk.vmdk`

For our POC: `make vmdk` wraps this command.

See also: [Red Hat: Creating VMDK images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-with-bootc-image-builder_using-image-mode-for-rhel-to-build-deploy-and-manage-operating-systems#creating-vmdk-images-by-using-bootc-image-builder_creating-bootc-compatible-base-disk-images-with-bootc-image-builder)

---

## OVA Packaging (VMDK + OVF)

bootc-image-builder does not produce OVA directly. An OVA is a tar archive containing:

| File | Purpose |
|------|---------|
| `*.ovf` | OVF descriptor (XML defining VM specs: CPU, RAM, disk, network) |
| `disk.vmdk` | The VMDK disk image |
| `*.mf` | SHA256 manifest for integrity verification |

### Creating an OVA

1. Build the VMDK: `make vmdk`
2. Package as OVA: `make ova`

The `make ova` target runs `scripts/create-ova.sh`, which:
- Takes the VMDK from `output/vmdk/disk.vmdk`
- Fills in `templates/bootc-poc.ovf` with VM specs (CPU, memory, disk size)
- Generates a SHA256 manifest
- Packages everything as `output/ova/bootc-poc-<version>.ova`

### Customizing VM Specs

Override via environment variables:

```bash
NUM_CPUS=4 MEMORY_MB=8192 DISK_CAPACITY=100 make ova
```

| Variable | Default | Description |
|----------|---------|-------------|
| `NUM_CPUS` | 2 | Virtual CPU count |
| `MEMORY_MB` | 4096 | Memory in MB |
| `DISK_CAPACITY` | 60 | Disk capacity in GiB |

### Importing into vSphere

1. In vSphere Client: **Hosts and Clusters** > right-click host > **Deploy OVF Template**
2. Select the `.ova` file
3. Follow the wizard (accept defaults or customize)
4. Power on the VM

---

## GCE Build (Google Compute Engine)

Use `--type gce` to create a disk image for Google Compute Engine. The builder outputs `image.tar.gz` (disk.raw already packaged) — ready to upload to GCS.

### How It Works

```
bootc-image-builder --type gce → output/gce/image.tar.gz
                                     ↓
                       gsutil cp → gs://BUCKET/image.tar.gz
                                     ↓
              gcloud compute images create --source-uri → GCE custom image
```

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| **gcloud CLI** | Installed and authenticated (`gcloud auth login`) |
| **gsutil** | Included with gcloud SDK |
| **GCS bucket** | Must already exist in your project |
| **IAM permissions** | `roles/compute.imageAdmin` + `roles/storage.objectAdmin` |
| **podman** | Required, running as root (sudo) |

### Build Command (Local)

```bash
# Step 1: Build GCE image (outputs image.tar.gz directly)
sudo podman run \
  --rm --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./builder/qcow2/config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type gce \
  --rootfs ext4 \
  --config /config.toml \
  ghcr.io/duyhenryer/bootc-testboot:latest

# Step 2: Upload to GCS
gsutil cp output/gce/image.tar.gz gs://YOUR_BUCKET/bootc-poc.tar.gz

# Step 3: Create GCE image
gcloud compute images create bootc-poc-latest \
  --project=YOUR_PROJECT \
  --source-uri=gs://YOUR_BUCKET/bootc-poc.tar.gz \
  --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE
```

For our POC: `make gce` wraps all three steps into `scripts/create-gce.sh`.

### Environment Variables

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `GCP_PROJECT` | — | **Yes** | GCP project ID |
| `GCP_BUCKET` | — | **Yes** | GCS bucket for staging the raw disk |
| `GCE_IMAGE_NAME` | `bootc-poc-<version>` | No | Name of the Compute Engine image |

### Launching a VM from the Image

```bash
gcloud compute instances create bootc-test \
  --project=YOUR_PROJECT \
  --zone=asia-southeast1-a \
  --machine-type=e2-medium \
  --image=bootc-poc-latest \
  --image-project=YOUR_PROJECT
```

---

## Running the QCOW2

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

Or with virt-install:

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

## Passwordless sudo (Optional)

Base images may not enable passwordless sudo. Add to your derived bootc Containerfile:

```dockerfile
ADD wheel-passwordless-sudo /etc/sudoers.d/wheel-passwordless-sudo
```

Content of `wheel-passwordless-sudo`:

```
%wheel ALL=(ALL) NOPASSWD: ALL
```

---

## Target Architecture

Use `--target-arch` to build for a different architecture (e.g. amd64 from arm64 Mac):

```bash
--target-arch amd64
```

The bootc OCI image and bootc-image-builder image must support the target arch. Check [Quay](https://quay.io/repository/centos-bootc/bootc-image-builder?tab=tags) for supported architectures.

---

## Summary Checklist

- [ ] Install podman and osbuild-selinux (if SELinux)
- [ ] Use `--privileged`; not suitable for ECS/Fargate
- [ ] Mount `/var/lib/containers/storage`
- [ ] Mount config as `/config.toml`
- [ ] For AMI: all of `--aws-ami-name`, `--aws-bucket`, `--aws-region`
- [ ] Use `--env-file` for AWS secrets, never plain `--env`
- [ ] Add vmimport role and S3 permissions for AMI
- [ ] For VMDK: mount `./output:/output` for local output
- [ ] For OVA: run `make ova` (builds VMDK first, then packages with OVF)
- [ ] For GCE: `--type gce` → tar.gz → `gsutil cp` → `gcloud compute images create`
- [ ] For GCE: IAM `roles/compute.imageAdmin` + `roles/storage.objectAdmin`
- [ ] Filesystem: only `/`, `/boot`, and `/var/*` subdirs (no `/var` itself, no symlinks)
