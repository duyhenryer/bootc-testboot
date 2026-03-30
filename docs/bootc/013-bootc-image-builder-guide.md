# bootc-image-builder

This guide is beginner-friendly in wording, but complete enough for real day-1 build/deploy work.
It follows upstream bootc-image-builder behavior and maps it to this repository's workflows.

**Canonical upstream source:** [osbuild bootc-image-builder docs](https://osbuild.org/docs/bootc/)

**Project references:**
- [Manual build and deployment](../project/003-deploying-and-upgrading.md)
- [Builder config README](../../builder/README.md)

---

## 1) Mental Model

`bootc OCI image -> bootc-image-builder -> disk artifact(s) -> platform import`

1. Build or pull a bootc OCI image.
2. Run bootc-image-builder (BIB) with one or more `--type` values.
3. Import the resulting artifact to your target (Xen, vSphere, cloud, etc.).

---

## 2) Image Types: What to Build for Which Platform

| `--type` | Typical target | Typical output path | When to choose | Common pitfall |
|---|---|---|---|---|
| `raw` | Generic raw-disk pipelines; practical Xen/XCP-ng handoff | `/output/image/disk.raw` | You want maximum portability and platform-side import control | Assuming all platforms consume raw directly without additional import steps |
| `vmdk` | VMware vSphere / VMware ecosystem | `/output/vmdk/disk.vmdk` | Deploying to vSphere or VMware tools | Mixing up VMDK with OVA (BIB does not directly output OVA) |
| `vhd` | Hyper-V / Virtual PC ecosystem | `/output/vhd/disk.vhd` (environment-dependent) | Microsoft virtualization stack | Treating it as primary format for non-Hyper-V environments |
| `qcow2` | QEMU/KVM | `/output/qcow2/disk.qcow2` | Local virtualization / KVM | Using it directly where platform expects other formats |
| `ami` | AWS AMI flow | `/output/image/disk.raw` (or direct upload flags) | AWS-focused workflow | Using wrong AWS import path for bootc/ostree layouts |
| `gce` | GCE image flow | GCE-formatted output tree | GCP deployment | Confusing `gce` and `raw` packaging requirements |
| `anaconda-iso` | Anaconda unattended installer | `/output/bootiso/disk.iso` | Installer-driven deployment | Expecting same behavior as direct disk import types |
| `bootc-installer` | bootc installer ISO flow | output tree varies by builder version | Installer-based workflows | Treating it like a VM disk format |

Notes:
- Upstream supports passing `--type` multiple times.
- In this repo, artifact container packaging paths are documented in [manual deployment doc](../project/003-deploying-and-upgrading.md).

---

## 3) Build Flags You Actually Need

| Flag | Meaning | Typical value in this repo | Default / behavior |
|---|---|---|---|
| `--type` | Artifact type to build (repeatable) | `--type raw --type vmdk` | Default is `qcow2` |
| `--rootfs` | Root filesystem type | `--rootfs ext4` | If omitted, use source image default |
| `--chown` | Set ownership of output files | `--chown $(id -u):$(id -g)` | Not set by default |
| `--output` | Output directory inside container | usually `/output` mount | Default `.` |
| `--progress` | Progress renderer | `term` or `verbose` | `auto` |
| `--target-arch` | Target architecture | e.g. `amd64` | Host arch if omitted |
| `--use-librepo` | RPM download path optimization | optional | `false` |
| `--log-level` | Log verbosity | `error`, `info`, `debug` | `error` |
| `-v` / `--verbose` | Verbose mode | optional | `false` (implies info logs) |

---

## 4) Filesystem Deep Dive (`customizations.filesystem`)

`customizations.filesystem` controls partition sizing/layout in the output disk image. This is independent from `--type` itself, but each target platform has different practical sizing strategy.

Core rules (upstream behavior):
- Allowed mountpoints are `/`, `/boot`, and subdirectories under `/var` (for example `/var/lib/mongodb`).
- `/var` itself cannot be a mountpoint.
- Symlink mountpoints under `/var` (for example `/var/home`, `/var/run`) are not valid.
- If `--rootfs btrfs` is used, additional custom mountpoints under `/var` are not supported; only `/` and `/boot` should be configured.
- `minsize` is minimum requested size, not an exact final size.

Recommended strategy by build target in this repo:

| Build target (`--type`) | Recommended `filesystem` pattern | Why |
|---|---|---|
| `ami` | Keep only `/` small (for example 10 GiB) in image; attach EBS for data | Better snapshot/resize/backup workflow on AWS |
| `gce` (or `raw` for GCE import) | Keep only `/` small in image; attach Persistent Disk for data | Same cloud pattern as AWS, simpler base image lifecycle |
| `raw` (generic on-prem) | `/` only by default; add `/var/*` only when environment needs fixed partitioning | Keeps raw artifact portable across hypervisors/import tools |
| `vmdk` | Define `/` + required `/var/*` partitions explicitly (for example `/var/lib/mongodb`, `/var/log`) | VMware deployments often want predictable baked-in layout |
| `qcow2` | Usually same as `raw` unless you are targeting fixed lab topology | Best default for local/KVM testing |
| `anaconda-iso` / `bootc-installer` | Keep conservative partition config unless installer customization requires more | Installer-based flows may apply additional storage policy |

Example for on-prem stateful VM:

```toml
[[customizations.filesystem]]
mountpoint = "/"
minsize = "10 GiB"

[[customizations.filesystem]]
mountpoint = "/var/lib/mongodb"
minsize = "50 GiB"

[[customizations.filesystem]]
mountpoint = "/var/log"
minsize = "5 GiB"
```

---

## 5) Prerequisites (High-Impact)

- Install `podman`.
- If host SELinux is enforcing, install host-side `osbuild-selinux` (or equivalent).
- Use rootful flow for predictable behavior with BIB:
  - mount `/var/lib/containers/storage:/var/lib/containers/storage`
  - make sure root podman can see your source image (`podman save ... | sudo podman load`).
- Use format-specific config from `builder/<format>/config.toml`.

---

## 6) Command Matrix (Copy-Paste)

Run from repo root.

### A) Build source OCI image

```bash
make base BASE_DISTRO=centos-stream9
make build BASE_DISTRO=centos-stream9
```

### B) Copy image to root podman storage

```bash
podman save ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest | sudo podman load
```

### C1) Build `raw` only

```bash
mkdir -p output/raw
sudo podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/builder/raw":/config:ro \
  -v "$(pwd)/output/raw":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw --rootfs ext4 \
  --chown $(id -u):$(id -g) \
  --config /config/config.toml \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

Expected: `output/raw/image/disk.raw`

### C2) Build `vmdk` only

```bash
mkdir -p output/vmdk
sudo podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/builder/vmdk":/config:ro \
  -v "$(pwd)/output/vmdk":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type vmdk --rootfs ext4 \
  --chown $(id -u):$(id -g) \
  --config /config/config.toml \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

Expected: `output/vmdk/vmdk/disk.vmdk`

### C3) Build `raw` + `vmdk` in one run

```bash
mkdir -p output/multi
sudo podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/builder/vmdk":/config:ro \
  -v "$(pwd)/output/multi":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw \
  --type vmdk \
  --rootfs ext4 \
  --chown $(id -u):$(id -g) \
  --config /config/config.toml \
  ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest
```

Typical outputs:
- `output/multi/image/disk.raw`
- `output/multi/vmdk/disk.vmdk`

Note:
- A single run uses one `--config` for all requested `--type` values.
- If you need different filesystem layouts per artifact type, run separate commands per type with the matching `builder/<format>/config.toml`.

### D) Optional experimental rootless mode

Upstream documents rootless `--in-vm` as experimental. Use it only if your environment requires rootless execution and you understand the trade-offs.

---

## 7) Platform Handoff

### Xen / XCP-ng

- Preferred artifact in this project context: `raw`.
- Typical handoff is raw-disk import through your XAPI/XCP-ng tooling.
- Example operator pattern often used:
  - `xe vdi-import filename=disk.raw format=raw sr-uuid=<SR_UUID> --progress`

### VMware vSphere

- Preferred artifact: `vmdk`.
- For OVA workflows, package VMDK + OVF + manifest (BIB does not have `--type ova`).
- Use full packaging/deploy steps in:
  - [VMware section in manual deployment doc](../project/003-deploying-and-upgrading.md)
  - [builder/README.md](../../builder/README.md)

---

## 8) Troubleshooting Matrix

| Symptom | Likely cause | What to check | Fix |
|---|---|---|---|
| Artifact exists but wrong platform import | Wrong `--type` | Command history + output tree | Rebuild with correct type (`raw`/`vmdk` etc.) |
| BIB cannot find source image | Root/user storage mismatch | `sudo podman images` vs `podman images` | `podman save ... | sudo podman load` |
| SELinux errors on build host | Missing host policy prerequisites | host package state | Install `osbuild-selinux` or equivalent |
| `--config` not applied | Wrong mount path | container mount and `--config` arg | Mount to `/config` and use `/config/config.toml` |
| Output files owned by root | No `--chown` | output file owner | Add `--chown $(id -u):$(id -g)` |
| Wrong architecture artifact | Arch mismatch | source image arch + builder arch | set `--target-arch` and align images |

Quick validation after build:

```bash
ls -R output
test -f output/multi/image/disk.raw && echo "raw OK"
test -f output/multi/vmdk/disk.vmdk && echo "vmdk OK"
```

Filesystem validation after first boot:

```bash
lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS
findmnt -R /sysroot
findmnt /var/lib/mongodb /var/log || true
```

Sizing checks against plan:

```bash
df -h /sysroot /var/lib/mongodb /var/log
```

---

## 9) Newbie Checklist

- [ ] I built the OCI image for the intended distro/tag.
- [ ] Root podman can see my source image.
- [ ] I selected format by target platform, not by guess.
- [ ] I mounted `/var/lib/containers/storage` and `/output`.
- [ ] I used `--chown` for local ownership sanity.
- [ ] I confirmed artifact paths before import.
- [ ] I used platform-specific import instructions from project docs.

---

## 10) References

- [osbuild bootc-image-builder docs](https://osbuild.org/docs/bootc/)
- [Manual build and deployment](../project/003-deploying-and-upgrading.md)
- [Builder config README](../../builder/README.md)

