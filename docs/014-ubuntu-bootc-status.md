# Ubuntu bootc: Current Status & Why Not Supported

> **Decision**: Ubuntu bootc is NOT production-ready. Use CentOS Stream 9 or Fedora instead.
>
> **Re-evaluate**: When Ubuntu 26.04 LTS ships (April 2026).

---

## Technical Blockers

### 1. No Official Base Image

Canonical does not maintain a bootc base image. The only option is the community project:
- **[bootcrew/ubuntu-bootc](https://github.com/bootcrew/ubuntu-bootc)** — 32 GitHub stars, community-maintained
- Based on **Ubuntu 25.10 (Plucky Puffin)** — NOT an LTS release (only ~9 months support)
- Ubuntu 24.04 LTS does not have the kernel/systemd versions needed for `bootc` + `composefs`

### 2. bootc-image-builder Not Supported

From [bootc-image-builder README](https://github.com/osbuild/bootc-image-builder):

> "A container to create disk images from bootc container inputs, **especially oriented towards Fedora/CentOS bootc** or derivatives."

This means:
- **No VMDK/OVA output** for Ubuntu images
- **No AMI/GCE/VHD output** for Ubuntu images
- Only `bootc install` to a raw disk is possible (manual, complex)

### 3. Upstream Blocker: bootupd

[coreos/bootupd#468](https://github.com/coreos/bootupd/issues/468) tracks the main blocker for non-Fedora distributions. `bootupd` manages the bootloader updates and is not yet compatible with Debian/Ubuntu boot layouts.

### 4. Immature Ecosystem

| Component | Fedora/CentOS | Ubuntu |
|-----------|--------------|--------|
| `bootc container lint` | ✅ Validated | ❌ Not validated |
| SELinux | ✅ Enforced | ❌ Uses AppArmor (different model) |
| composefs/ostree | ✅ Years of production use (Silverblue, CoreOS) | ⚠️ Experimental |

---

## Why CentOS Stream 9 Instead

| | CentOS Stream 9 | Ubuntu bootc |
|--|----------------|--------------|
| **Maintainer** | CentOS Project + Red Hat | Community (1-2 people) |
| **Lifecycle** | ~2027 | ~9 months (25.10 non-LTS) |
| **bootc-image-builder** | ✅ Official support | ❌ Not supported |
| **Disk formats** | AMI, VMDK, QCOW2, GCE, ISO, raw, VHD | None (manual only) |
| **Production risk** | LOW | HIGH |

---

## Go Binaries Are Distro-Agnostic

Since our applications are Go binaries built with `CGO_ENABLED=0`, they are **statically linked** and run identically on CentOS, Fedora, Ubuntu, or any Linux:

```bash
CGO_ENABLED=0 go build -ldflags="-s -w" -o myapp .
# This binary runs on ANY Linux distro, ANY version
```

The choice of base distro does NOT affect application behavior — only OS-level tooling (bootc, image-builder, package manager) differs.

---

## When Will Ubuntu Be Ready?

Monitor these signals:
1. **Ubuntu 26.04 LTS** (April 2026) — check if kernel ≥ 6.x and systemd ≥ 255 ship with composefs support
2. **bootcrew/ubuntu-bootc** — watch for migration to LTS base
3. **bootupd#468** — upstream fix for non-Fedora boot layouts
4. **bootc-image-builder** — official Ubuntu support announcement

---

## References

- [bootc: Installation / Base images](https://bootc-dev.github.io/bootc/installation.html)
- [bootupd#468: Non-Fedora distro blocker](https://github.com/coreos/bootupd/issues/468)
- [bootcrew/ubuntu-bootc](https://github.com/bootcrew/ubuntu-bootc)
- [docs/013-base-distro-comparison.md](013-base-distro-comparison.md) — full distro comparison table
