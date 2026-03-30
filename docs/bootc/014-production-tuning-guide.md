# Production Tuning Guide

Practical guide to bootc-image-builder customization options, organized by real-world use case.
Shows what to tune for each deployment scenario and what this project currently uses vs what's
available.

> **Pre-requisite reading:**
> - [013-bootc-image-builder-guide.md](013-bootc-image-builder-guide.md) — command reference and build flags
> - [012-bootc-limitations.md](012-bootc-limitations.md) — known limitations and deprecation timeline
> - [builder/README.md](../../builder/README.md) — per-format config files in this project

**Sources:**
- [osbuild: bootc-image-builder](https://osbuild.org/docs/bootc/)
- [github.com/osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- [Red Hat: Creating bootc disk images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-with-bootc-image-builder_using-image-mode-for-rhel-to-build-deploy-and-manage-operating-systems)
- [bootc: Building guidance](https://bootc-dev.github.io/bootc/building/guidance.html)

---

## Table of Contents

- [1. Available Customizations Reference](#1-available-customizations-reference)
- [2. Use Case: Cloud Appliance (AWS / GCE)](#2-use-case-cloud-appliance-aws--gce)
- [3. Use Case: On-Prem Customer Delivery (VMware / Xen)](#3-use-case-on-prem-customer-delivery-vmware--xen)
- [4. Use Case: Edge / Bare Metal](#4-use-case-edge--bare-metal)
- [5. Use Case: Multi-Tenant / Fleet](#5-use-case-multi-tenant--fleet)
- [6. Rootless Builds](#6-rootless-builds)
- [7. Production Readiness Checklist](#7-production-readiness-checklist)
- [8. Migration Plan: bootc-image-builder to image-builder](#8-migration-plan-bootc-image-builder-to-image-builder)

---

## 1. Available Customizations Reference

Everything configurable via `builder/<format>/config.toml`. These are applied **after** the
container image is built, during the disk artifact generation phase. They do not affect the OS
inside the container — that is controlled by the Containerfile.

### Users (`[[customizations.user]]`)

```toml
[[customizations.user]]
name = "devops"                    # Required: Linux username
key = "ssh-ed25519 AAAA... user"   # Optional: SSH public key
password = "$6$salt$hash..."       # Optional: SHA-512 crypt hash for console login
groups = ["wheel"]                 # Optional: secondary group memberships
```

| Field | Notes |
|-------|-------|
| `name` | Created in the disk image; available at first boot |
| `key` | Injected to `~/.ssh/authorized_keys` |
| `password` | For **local console only** if `PasswordAuthentication no` in sshd. Generate with `openssl passwd -6` |
| `groups` | Added to existing groups; group must exist in the image |

**This project:** All configs inject `devops` with SSH key + `wheel`. Only `vmdk/config.toml` adds a password for vSphere console access.

### Filesystem (`[[customizations.filesystem]]`)

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/lib/mongodb"
minsize = "50 GiB"
```

| Rule | Detail |
|------|--------|
| Allowed | `/`, `/boot`, `/var/<anything>` |
| Forbidden | `/var` itself, symlink paths (`/var/home`, `/var/run`) |
| `minsize` | Minimum; actual size may be larger |
| btrfs rootfs | Only `/` and `/boot` — no `/var/*` sub-mountpoints |

### Kernel Arguments (`[customizations.kernel]`)

```toml
[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

Common production kernel args:

| Arg | Purpose | When to use |
|-----|---------|-------------|
| `console=ttyS0,115200n8` | Serial console output | All cloud + VMware (for remote console / serial log) |
| `console=tty0` | Local framebuffer console | VMware / bare metal (for vSphere console, physical monitor) |
| `nvme_core.io_timeout=4294967295` | Infinite NVMe timeout | AWS Nitro instances (prevents spurious timeouts) |
| `rd.driver.blacklist=nouveau` | Blacklist nouveau GPU driver | Servers with NVIDIA GPUs (use proprietary driver instead) |
| `transparent_hugepage=never` | Disable THP | MongoDB production (THP causes latency spikes) |
| `numa=off` | Disable NUMA | Small VMs where NUMA scheduling overhead is worse than benefit |
| `audit=1` | Enable kernel audit | When audit logging is required for compliance |
| `selinux=1 enforcing=1` | Force SELinux enforcing | Already default on CentOS/Fedora; explicit for compliance |

### Anaconda ISO Installer (`[customizations.installer]`)

```toml
[customizations.installer.kickstart]
contents = """
text --non-interactive
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --noswap --type=lvm
network --bootproto=dhcp --device=link --activate --onboot=on
"""

[customizations.installer.modules]
enable = ["org.fedoraproject.Anaconda.Modules.Localization"]
disable = ["org.fedoraproject.Anaconda.Modules.Users"]
```

> **Deprecation notice:** `anaconda-iso` is scheduled for removal in RHEL 11. Prefer
> `bootc-installer` for new installer workflows.

**Conflict:** Cannot combine custom kickstart with `[[customizations.user]]` — pick one.

### ISO Media Labels (`[customizations.iso]`)

```toml
[customizations.iso]
volume_id = "BOOTC-TESTBOOT"
application_id = "bootc-testboot-installer"
publisher = "YourOrg"
```

### What Belongs in Containerfile, NOT config.toml

| Feature | Containerfile | config.toml |
|---------|:------------:|:-----------:|
| Package installation (`dnf install`) | Yes | No |
| Service enablement (`systemctl enable`) | Yes | No |
| SELinux policy (`semodule`) | Yes | No |
| Firewall rules (`firewall-offline-cmd`) | Yes | No |
| Config files (`COPY rootfs/`) | Yes | No |
| sysctl tuning | Yes | No |
| NTP / chrony / journald | Yes | No |
| User injection (SSH key, password) | No | Yes |
| Disk partitioning | No | Yes |
| Kernel boot args | No | Yes |
| Installer kickstart | No | Yes |

---

## 2. Use Case: Cloud Appliance (AWS / GCE)

**Pattern:** Minimal root partition. Attach cloud-native data volumes post-deploy. Let cloud-init
handle hostname and network.

### Recommended config.toml

```toml
# Cloud-minimal: small root, no baked-in data partitions
[[customizations.user]]
name = "devops"
key = "ssh-ed25519 AAAA..."
groups = ["wheel"]
# No password — SSH-key only (PasswordAuthentication disabled in base image)

[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"
# Data volumes (EBS, Persistent Disk) attached post-deploy — not in the image

[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

### AWS-specific additions

```toml
[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8 nvme_core.io_timeout=4294967295"
```

The `nvme_core.io_timeout` prevents NVMe timeouts on Nitro instances when EBS volumes are
temporarily unavailable during host maintenance.

### GCE-specific notes

- Build with `--type raw`, then package as `tar.gz` for GCE import (no native `--type gce` in BIB)
- GCE serial console uses `ttyS0` only (no local framebuffer)
- cloud-init handles SSH keys via GCE metadata — the `key` in config.toml is a fallback

### What to handle in Containerfile (not config.toml)

```dockerfile
# Cloud-init for hostname, network, SSH keys from cloud metadata
RUN systemctl enable cloud-init

# No baked-in passwords — SSH-key only
# PasswordAuthentication disabled in base/rootfs/etc/ssh/sshd_config.d/99-hardening.conf
```

### Post-deploy: attach data volumes

```bash
# AWS: attach EBS
aws ec2 create-volume --size 50 --volume-type gp3 --az us-east-1a
aws ec2 attach-volume --volume-id vol-xxx --instance-id i-xxx --device /dev/xvdf

# On the instance: format + mount (first time only)
sudo mkfs.ext4 /dev/xvdf
sudo mount /dev/xvdf /var/lib/mongodb
# Add to /etc/fstab for persistence
```

---

## 3. Use Case: On-Prem Customer Delivery (VMware / Xen)

**Pattern:** Bake data partitions into the disk image. Include console password for first-login
access. Customers receive a self-contained OVA or QCOW2 — no cloud metadata service available.

### Recommended config.toml

```toml
[[customizations.user]]
name = "devops"
key = "ssh-ed25519 AAAA..."
# Console password for vSphere/Xen VM console (before SSH is reachable)
password = "$6$salt$hash..."
groups = ["wheel"]

[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/lib/mongodb"
minsize = "50 GiB"

[[customizations.filesystem]]
mountpoint = "/var/log"
minsize = "5 GiB"

[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8"
```

### Why bake partitions for on-prem

- No cloud-native volume attachment; disk layout must be in the image
- Separate `/var/lib/mongodb` prevents data growth from filling root
- Separate `/var/log` prevents log flooding from affecting the OS
- Customer can resize partitions post-deploy with standard LVM/growpart tools

### Format selection

| Target hypervisor | Build format | Notes |
|-------------------|-------------|-------|
| VMware vSphere / ESXi | `--type vmdk` → package as OVA | OVF must declare `vmw:firmware="efi"` |
| Xen Orchestra / XCP-ng | `--type qcow2` | **Do not use OVA for Xen** — see [006-selinux-reference.md](../project/006-selinux-reference.md) Case Study |
| Hyper-V | `--type vhd` | VHD format for Microsoft hypervisors |
| KVM / libvirt | `--type qcow2` | Standard for QEMU/KVM |

### Password rotation for production

The lab password should **never** ship to customers. For each production build:

```bash
# Generate a unique password per release
NEW_PW=$(openssl rand -base64 16)
HASH=$(openssl passwd -6 "$NEW_PW")

# Update config.toml (or inject via CI variable)
sed -i "s|^password = .*|password = \"$HASH\"|" builder/vmdk/config.toml

# Document the password securely (vault, sealed secret, etc.)
```

### MongoDB tuning for on-prem

Add to the Containerfile for MongoDB production:

```toml
# builder/vmdk/config.toml — add to kernel args
[customizations.kernel]
append = "console=tty0 console=ttyS0,115200n8 transparent_hugepage=never"
```

Transparent Huge Pages cause latency spikes in MongoDB. The kernel arg disables them at boot,
before mongod starts. MongoDB docs explicitly recommend this.

---

## 4. Use Case: Edge / Bare Metal

**Pattern:** Ship a bootable installer (ISO or PXE) that deploys the bootc image to local disk.
Network may be intermittent or offline.

### Anaconda ISO (current, deprecated path)

```bash
# Build installer ISO
sudo podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type anaconda-iso \
  --rootfs ext4 \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

Flash to USB and boot:

```bash
sudo dd if=output/bootiso/disk.iso of=/dev/sdX bs=4M status=progress
```

### bootc-installer (future path)

`anaconda-iso` is deprecated in RHEL 11. The replacement is `bootc-installer`:

```bash
sudo podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type bootc-installer \
  --rootfs ext4 \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

### PXE boot (stateless / network install)

Requires image-level changes:

```dockerfile
# Add to Containerfile for PXE support
RUN dnf install -y dracut-live squashfs-tools && \
    dracut --add dmsquash-live --force
```

Then build with `--type pxe-tar-xz`. Serve the output via TFTP/HTTP for network boot.

### Offline registry for air-gapped sites

If the deployment site has no internet:

1. Mirror the bootc image to a local registry before shipping
2. Configure `/etc/containers/registries.conf` to point to the local mirror
3. `bootc upgrade` will pull from the local registry instead of GHCR

See [007-registries-and-offline.md](007-registries-and-offline.md) for registry mirroring details.

---

## 5. Use Case: Multi-Tenant / Fleet

**Pattern:** Deploy the same image to many VMs. Each needs unique identity, monitoring, and
centralized management.

### Per-VM identity

Each VM gets a unique identity via cloud-init (cloud) or first-boot scripts (on-prem):

| Mechanism | Cloud | On-prem |
|-----------|-------|---------|
| Hostname | cloud-init metadata | `hostnamectl set-hostname` in first-boot script |
| SSH host keys | Auto-generated on first boot | Auto-generated on first boot |
| TLS certs | cloud-init or `mongodb-setup.sh` | `mongodb-setup.sh` (already implemented) |
| Passwords | cloud-init user-data | Baked in config.toml (rotate per release) |

### Monitoring agent

Add a monitoring agent to the Containerfile for fleet observability:

```dockerfile
# Option 1: Prometheus node_exporter
RUN dnf install -y golang-github-prometheus-node-exporter && \
    systemctl enable node_exporter

# Option 2: Datadog agent (requires DD_API_KEY at runtime)
# Option 3: Cloud-native (AWS CloudWatch agent, GCP Ops Agent)
```

The agent runs as a systemd service, exports metrics on a known port, and is upgraded atomically
with the rest of the OS via `bootc upgrade`.

### Centralized log shipping

For fleet-wide log aggregation:

```dockerfile
# Option 1: journald → rsyslog → remote syslog server
RUN dnf install -y rsyslog && systemctl enable rsyslog

# Option 2: journald → Fluent Bit → Elasticsearch/Loki
# (Fluent Bit is lightweight and reads from journald directly)
```

### Fleet upgrade strategy

```bash
# On each VM (can be parallelized via Ansible or AWS SSM Run Command):
sudo bootc upgrade --download-only     # Phase 1: pre-download (business hours)
sudo bootc upgrade --from-downloaded --apply  # Phase 2: apply (maintenance window)
```

For large fleets, use **canary deployments**:

1. Upgrade 1 VM → verify health
2. Upgrade 10% of fleet → monitor for 24h
3. Upgrade remaining fleet

### Day-2 configuration management

bootc handles OS; application configuration needs a separate mechanism:

| Approach | Pros | Cons |
|----------|------|------|
| **Ansible** (push-based) | Familiar, agentless (SSH) | Requires control node, manual trigger |
| **GitOps** (pull-based) | Auto-sync, auditable | Requires agent (e.g., systemd timer + git pull) |
| **cloud-init** (first-boot only) | Zero agents | Only runs once; no ongoing sync |
| **systemd timer + curl** | Lightweight, no dependencies | Custom code to maintain |

### Multi-arch considerations

If your fleet includes aarch64 (ARM) machines:

- Build separate images per architecture (BIB requires matching arch)
- Use separate CI jobs with `--target-arch` or ARM runners
- Tag images with arch suffix: `ghcr.io/.../centos-stream9:latest-amd64`, `...:latest-arm64`

---

## 6. Rootless Builds

### What it is

bootc-image-builder can run without root using KVM-based nested virtualization:

```bash
# Rootless build (no sudo)
podman run --rm \
  --in-vm \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs ext4 \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

### Requirements

| Requirement | Detail |
|-------------|--------|
| KVM | `/dev/kvm` must be available to the user |
| User storage | `~/.local/share/containers/storage` (not root storage) |
| Image visibility | The source image must be in user-level podman storage |
| No `sudo` | The entire build runs unprivileged |

### When to use

| Scenario | Use rootless? |
|----------|:------------:|
| CI pipeline (GitHub Actions) | **No** — use rootful (faster, more stable) |
| Developer laptop (no root) | **Maybe** — if KVM is available |
| Security-restricted environments | **Maybe** — evaluate stability vs risk |
| Production artifact builds | **No** — use rootful (proven path) |

### Limitations

- **Experimental** — not covered by stability guarantees
- **Slower** — nested VM adds overhead vs direct rootful build
- **SELinux corner cases** — some label operations may fail inside the nested VM
- **Limited testing** — upstream test matrix is smaller than rootful

**This project's recommendation:** Use rootful builds for all CI and production artifact
generation. Consider rootless only for developer workflows where `sudo` is unavailable.

---

## 7. Production Readiness Checklist

Assessment of this project's current state against production requirements.

### Currently production-ready

| Area | Status | How |
|------|--------|-----|
| Multi-distro base images | Done | 4 distros (CentOS 9/10, Fedora 40/41) |
| Multi-format artifacts | Done | AMI, VMDK/OVA, QCOW2, raw (GCE) |
| SELinux enforcing | Done | Build-time `semodule` + supplemental modules |
| Immutable configs | Done | All configs in `/usr/share/`, symlinked from `/etc/` |
| Atomic upgrade / rollback | Done | `bootc upgrade` / `bootc rollback` |
| MongoDB TLS + auth | Done | Auto-generated certs, keyFile, admin password |
| CI pipeline | Done | PR lint + build all distros + weekly rebuild |
| Post-deploy audit | Done | Checklist in [005-ghcr-audit-and-post-deploy.md](../project/005-ghcr-audit-and-post-deploy.md) |
| Persistent logging | Done | Dual output (journald + file) for all services |

### Gaps to close for production

| Gap | Priority | What to do |
|-----|----------|-----------|
| **Password rotation** | High | Generate unique hash per production build; never ship lab password |
| **MongoDB THP** | High | Add `transparent_hugepage=never` to kernel args in all configs |
| **Monitoring agent** | High | Add `node_exporter` or cloud-native agent to Containerfile |
| **GCE automation** | Medium | Script the `raw → tar.gz → gcloud compute images create` flow |
| **Image signing** | Medium | Add cosign signing in CI; configure `policy.json` on VMs |
| **SBOM** | Medium | Add syft/trivy SBOM generation to CI for compliance |
| **Bootloader updates** | Medium | Document `bootupctl update` in ops runbook; consider automation |
| **Multi-arch** | Low | Add aarch64 CI jobs if ARM fleet is planned |
| **Day-2 config management** | Low | Evaluate Ansible or GitOps for post-deploy app config |
| **`image-builder` migration** | Low (until RHEL 11) | Track upstream; test new CLI when available |
| **Azure support** | Low | Add raw → VHD conversion if Azure deployment needed |

### Distro x format test matrix

Before a production release, validate all combinations you ship:

| | AMI | VMDK/OVA | QCOW2 | raw (GCE) |
|---|:---:|:---:|:---:|:---:|
| **CentOS Stream 9** | ? | ? | ? | ? |
| **CentOS Stream 10** | ? | ? | ? | ? |
| **Fedora 40** | ? | ? | ? | ? |
| **Fedora 41** | ? | ? | ? | ? |

Mark each cell after testing: boot, services healthy, MongoDB init, `bootc upgrade`, rollback.

---

## 8. Migration Plan: bootc-image-builder to image-builder

### Timeline

| Phase | When | Action |
|-------|------|--------|
| **Now** | Current | Continue using `quay.io/centos-bootc/bootc-image-builder:latest` |
| **RHEL 9.9 / 10.3** | ~2025-2026 | BIB wraps `image-builder`; test backward compatibility |
| **Before RHEL 11** | ~2027 | Migrate CI to `image-builder` CLI; update all `podman run` commands |

### What changes

| Aspect | bootc-image-builder | image-builder |
|--------|-------------------|---------------|
| Container image | `quay.io/centos-bootc/bootc-image-builder` | TBD (unified image) |
| Config format | `config.toml` (Blueprint) | Expected to remain compatible |
| `--type` flags | Same | Same (plus potential new types) |
| Rootless (`--in-vm`) | Experimental | Expected to stabilize |

### What to do now

1. **Pin BIB version** in CI instead of using `:latest` — prevents surprise breakage
2. **Track upstream** — watch [github.com/osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder) releases
3. **Test early** — when `image-builder` CLI is available, run it alongside BIB to compare output
4. **Config is portable** — `config.toml` format is expected to be forward-compatible

---

## References

- [osbuild: bootc-image-builder](https://osbuild.org/docs/bootc/)
- [github.com/osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- [bootc: Building guidance](https://bootc-dev.github.io/bootc/building/guidance.html)
- [Fedora bootc: Getting started](https://docs.fedoraproject.org/en-US/bootc/getting-started/)
- [Red Hat: Image mode for RHEL](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-with-bootc-image-builder_using-image-mode-for-rhel-to-build-deploy-and-manage-operating-systems)
- [MongoDB: Disable THP](https://www.mongodb.com/docs/manual/tutorial/transparent-huge-pages/)
- [013-bootc-image-builder-guide.md](013-bootc-image-builder-guide.md) — command reference for this project
- [012-bootc-limitations.md](012-bootc-limitations.md) — bootc + BIB limitations
