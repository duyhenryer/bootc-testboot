# Deep Dive: The Limitations of `bootc`

As a capable DevOps engineer, you must clearly outline the boundaries and trade-offs of this Containerized OS architecture to management, preparing for potential roadblocks:

## 1. Conflict with Legacy Apps
- **Filesystem Read-Only:** This is the most critical barrier. `bootc` locks down (Read-Only) `/usr` and almost the entire operating system, leaving only `/etc` (for configuration) and `/var` (for data) as Read-Write.
- If legacy applications (e.g., older banking software) arbitrarily dump logs into their root installation directories like `/opt/myapp/logs`, they will immediately **crash** on bootc. Overcoming this requires standardizing the applications or heavily utilizing `systemd-tmpfiles`.

## 2. Configuration Management & State Drift
- **No Hot-Fixes:** Imagine a network error at 2 AM. A Sysadmin SSHes into the VM and edits an OS file to restore the app. The next morning, upon reboot or a bootc image update, that manual fix **vaporizes**, as the system reverts back to the exact Container Image state from GitHub.
- **Mindset Shift:** All OS configuration changes must be committed as Infrastructure as Code into the `Containerfile`, rebuilt via CI, and pulled by the server. Local state mutability is completely abolished.

## 3. Disconnect in Managing Out-of-Tree Drivers (e.g., GPUs)
- For VMs running complex peripherals, like NVIDIA GPUs for AI workloads, loading third-party or Out-of-Tree kernel modules into bootc is a severe challenge.
- Drivers must be compiled (kmod pull, akmods) directly into the Container Image during the GitHub Actions pipeline, which massively increases complexity and build times.

## 4. An Evolving Ecosystem (Primarily Red Hat)
- `bootc` originated from Red Hat's OSTree ecosystem (CoreOS), performing flawlessly on Fedora, CentOS Stream, and RHEL.
- Porting `bootc` to Ubuntu or Debian remains highly experimental (as noted in earlier status docs). It requires maturation of `systemd-sysupdate` alongside APT architecture.

## 5. Debugging & Observability
- You cannot arbitrarily run `dnf install strace tcpdump` on a production machine due to the Read-Only `/usr` filesystem.
- Sysadmins must rely on isolated utility containers (using `toolbox` or `distrobox`) packed with debug tools, then cross-mount process namespaces to diagnose issues. The systemic mindset forces a pivot toward Kubernetes-style operations rather than traditional Linux VM administration.
- `bootc usr-overlay` provides a **temporary** writable `/usr` (lost on reboot) for emergency debugging. See [operations runbook](../project/003-deploying-and-upgrading.md).

---

## 6. bootc-image-builder Limitations

`bootc-image-builder` (BIB) converts bootc OCI images into deployable disk artifacts (AMI, VMDK, QCOW2, etc.). It has its own set of limitations separate from bootc itself.

> **Upstream docs:** [osbuild.org/docs/bootc](https://osbuild.org/docs/bootc/) and [github.com/osbuild/bootc-image-builder](https://github.com/osbuild/bootc-image-builder)

### 6.1 Deprecation Timeline (Critical)

bootc-image-builder is being **deprecated** in favor of the unified `image-builder` CLI:

| Milestone | What happens |
|-----------|-------------|
| **RHEL 9.8 / 10.2** | New major BIB versions no longer backported |
| **RHEL 9.9 / 10.3** | BIB container wraps `image-builder` as backward-compatible entry point |
| **RHEL 11** | `image-builder` only; standalone BIB **removed** |

**Action:** Current CI uses `quay.io/centos-bootc/bootc-image-builder:latest`. Plan migration to `image-builder` CLI before RHEL 11 cutoff. Config.toml format is expected to remain compatible during the transition.

### 6.2 Filesystem Constraints

| Rule | Detail |
|------|--------|
| Allowed mountpoints | `/`, `/boot`, and subdirectories under `/var/*` |
| `/var` itself | **Cannot** be a mountpoint |
| Symlink paths | `/var/home`, `/var/run` are **not valid** (they are symlinks in bootc) |
| `minsize` | Specifies minimum requested size; final partition size may differ |
| btrfs rootfs | Only `/` and `/boot` allowed — **no custom `/var/*` mountpoints** |
| ext4 / xfs rootfs | Full support for `/var/*` sub-mountpoints |

### 6.3 Format-Specific Limitations

| Format | Limitation |
|--------|-----------|
| **GCE** | No native `--type gce` disk image in BIB; requires `--type raw` then manual `tar.gz` packaging for GCE import |
| **Azure** | No native Azure disk support; use `--type raw` + conversion, or `bootc install to-existing-root` |
| **OVA** | BIB does **not** output OVA directly; must build VMDK then package with OVF template manually (this project does this in CI) |
| **btrfs** | Cannot define custom `/var/*` subvolumes at build time |
| **anaconda-iso** | Scheduled for **deprecation** in RHEL 11; prefer `bootc-installer` for new work |
| **pxe-tar-xz** | Requires `dracut-live` + `squashfs-tools` in the container image and initramfs rebuild with `dmsquash-live` module |

### 6.4 Rootless Builds (`--in-vm`)

BIB has **experimental** support for rootless builds using KVM:

```bash
podman run --rm \
  --in-vm \
  --type qcow2 \
  --rootfs ext4 \
  ghcr.io/example/my-image:latest
```

| Aspect | Detail |
|--------|--------|
| Status | **Experimental** — not recommended for production CI |
| Mechanism | Spawns a nested VM inside the container via KVM |
| Requirement | KVM available on host (`/dev/kvm`); user-level container storage |
| No `sudo` | Runs without root |
| Performance | Slower than rootful builds (nested VM overhead) |
| Stability | Limited testing; SELinux corner cases may not be handled |

**This project uses rootful builds** (`sudo podman run --privileged`) — the standard, stable approach.

### 6.5 Configuration Conflicts

| Conflict | Detail |
|----------|--------|
| Kickstart + `customizations.user` | **Cannot combine** custom kickstart (anaconda-iso) with `customizations.user`; choose one method |
| Single `--config` per run | When building multiple `--type` in one run, all types share the same config.toml. If types need different partition layouts, run separate builds. |

### 6.6 Architecture Constraints

- Target architecture **must match** the bootc-image-builder container image architecture
- Cross-compilation is experimental; use `--target-arch` and ensure source image matches
- This project builds **linux/amd64 only**; aarch64 is not tested

### 6.7 What bootc-image-builder Does NOT Control

These must be handled in the **Containerfile**, not in config.toml:

| Feature | Where to configure |
|---------|--------------------|
| Package installation | `RUN dnf install` in Containerfile |
| Service enablement | `RUN systemctl enable` in Containerfile |
| SELinux policy | `RUN semodule` in Containerfile |
| Firewall rules | `RUN firewall-offline-cmd` in Containerfile |
| Config files | `COPY rootfs/` in Containerfile |
| NTP / chrony | Drop-in in `base/rootfs/` |

BIB only handles: user injection, filesystem partitioning, kernel boot args, and (for anaconda-iso) kickstart/installer modules.

---

## References

- [bootc: Filesystem](https://bootc-dev.github.io/bootc/filesystem.html)
- [bootc: Building guidance](https://bootc-dev.github.io/bootc/building/guidance.html)
- [osbuild: bootc-image-builder](https://osbuild.org/docs/bootc/)
- [Fedora bootc: Getting started](https://docs.fedoraproject.org/en-US/bootc/getting-started/)
- [Red Hat: Creating bootc disk images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-with-bootc-image-builder_using-image-mode-for-rhel-to-build-deploy-and-manage-operating-systems)
