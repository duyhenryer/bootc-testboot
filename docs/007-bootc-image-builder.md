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
  -v ./config.toml:/config.toml:ro \
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
  -v ./config.toml:/config.toml:ro \
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
- [ ] Filesystem: only `/`, `/boot`, and `/var/*` subdirs (no `/var` itself, no symlinks)
