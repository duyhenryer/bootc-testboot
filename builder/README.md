# Infrastructure Builder Layer

This directory contains configuration files used exclusively by the `bootc-image-builder` tool to convert OCI Container Images into various disk formats (e.g., AMI, VMDK, ISO, QCOW2).

## Structure

```
builder/
├── ami/config.toml       # AWS AMI builder customizations (Nitro NVMe timeout, serial console)
├── anaconda-iso/config.toml # Anaconda ISO builder customizations
├── gce/config.toml       # GCE (Google Compute Engine) builder customizations
├── qcow2/config.toml     # QCOW2 builder customizations
├── raw/config.toml       # Generic raw disk builder customizations
├── vmdk/config.toml      # VMDK builder customizations
├── ova/bootc-testboot.ovf # OVF template for OVA packaging (VMDK → OVA, EFI firmware)
└── README.md
```

## Per-Format Configuration

Configurations are split by output format because different environments often require different system-level parameters:

- **Disk Partitioning:** e.g., allocating specific storage sizes for `/var/data`.
- **User Injection:** e.g., injecting SSH keys for `devops` user.
- **Kernel Boot Arguments:** e.g., serial console parameters.

### Filesystem profiles (single source of truth)

All `[[customizations.filesystem]]` values follow one of these profiles:

| Profile | Layout intent | Typical mountpoints |
|---|---|---|
| `cloud-minimal` | Keep image root small; attach data volumes outside image | `/` (optionally `/boot`) |
| `portable-minimal` | Hypervisor-neutral baseline for generic artifacts | `/` (optionally `/boot`) |
| `onprem-stateful` | Bake required data/log partitions into disk image | `/`, `/var/lib/mongodb`, `/var/log` |

Profile mapping by build type:

| Build type | Config path | Profile |
|---|---|---|
| `ami` | `builder/ami/config.toml` | `cloud-minimal` |
| `raw` for GCE workflow | `builder/gce/config.toml` | `cloud-minimal` |
| `raw` generic | `builder/raw/config.toml` | `portable-minimal` |
| `qcow2` | `builder/qcow2/config.toml` | `portable-minimal` |
| `vmdk` | `builder/vmdk/config.toml` | `onprem-stateful` |
| `anaconda-iso` | `builder/anaconda-iso/config.toml` | `portable-minimal` (default) |

Upstream mountpoint rules to keep in mind:
- Allowed: `/`, `/boot`, and mountpoints under `/var/*`.
- Disallowed: `/var` itself and symlink-based mountpoints such as `/var/home`, `/var/run`.
- If rootfs is `btrfs`, only `/` and `/boot` should be configured.

### `ami/config.toml`

AWS-specific config. Uses `--type ami` with `bootc-image-builder`. Kernel args include `nvme_core.io_timeout=4294967295` (prevents NVMe timeout on Nitro instances) and `console=ttyS0,115200n8` for EC2 serial console. The raw disk output is uploaded to S3 and imported as an EBS snapshot via `aws ec2 import-snapshot`.

### `gce/config.toml`

GCE-specific config. Uses `--type raw` with `bootc-image-builder`, then the raw disk is packaged as `tar.gz` for GCE image import. Kernel args include `console=ttyS0,115200n8` for GCE serial console.

### `qcow2/config.toml` and `vmdk/config.toml`

Standard `bootc-image-builder` [Blueprint](https://github.com/osbuild/blueprint) configs with `[[customizations.user]]`, `[[customizations.filesystem]]`, and `[customizations.kernel]` sections.

#### VMDK / OVA — console password for `devops`

[`vmdk/config.toml`](vmdk/config.toml) sets a **`password`** field (SHA-512 crypt) on the `devops` user so you can **log in on the local console** (vSphere VM console, serial) when no SSH is available yet. **SSH still uses the SSH key** from the same `[[customizations.user]]` block; [`PasswordAuthentication` is disabled in the base image](../base/rootfs/etc/ssh/sshd_config.d/99-hardening.conf), so remote SSH with a password is not enabled unless you add a separate `sshd` drop-in.

> **Note:** OVA/VMDK is for **VMware vSphere / ESXi only**. For Xen Orchestra (XCP-ng), use the **QCOW2** artifact — OVA imports into Xen strip VMware-specific hardware (VmxNet3, vmx-19 hardware version) and can cause boot and SELinux initialisation issues. See [docs/project/009-selinux-mongodb.md](../docs/project/009-selinux-mongodb.md) §2 for details.

**Lab console password (plaintext, documented only — not in `config.toml`):** `BootcOvaConsoleDevAb` (20 letters, mixed case). Use user **`devops`** on the vSphere VM console. **Change after first login** (`passwd`) or replace the hash before production builds.

To change the password, generate a new SHA-512 hash and update [`vmdk/config.toml`](vmdk/config.toml):

```bash
openssl passwd -6
# enter password when prompted; put the full $6$... line as password = "..." in config.toml
```

**Same password on every VM** built from the same `config.toml` — acceptable for lab; rebuild after changing the hash to revoke the old one.

**SELinux / FTDC:** The upstream [mongodb/mongodb-selinux](https://github.com/mongodb/mongodb-selinux) policy module and a local supplemental module (`mongodb-ftdc-local`) are both compiled in a throwaway build stage and **installed into the image at build time** via `semodule` in the Containerfile. There is no runtime `semodule` service. After deploying a new disk image, confirm with `semodule -l | grep mongodb` — you should see both `mongodb` and `mongodb_ftdc_local`. For the full history and rationale see [docs/project/009-selinux-mongodb.md](../docs/project/009-selinux-mongodb.md).

### `ova/bootc-testboot.ovf`

OVF descriptor template with placeholders (`CPU_COUNT`, `MEMORY_MB`, `DISK_SIZE_GB`, `VMDK_FILENAME`, `VMDK_SIZE`). These are filled in by the CI pipeline (or manually via `sed`) during OVA packaging.

Key settings:

- **Firmware:** `vmw:firmware="efi"` -- required because `bootc-image-builder` produces EFI-bootable disks. Without this, vSphere defaults to BIOS and the VM will not boot.
- **SCSI Controller:** `lsilogic` for broad compatibility (ESXi 5.x+, Workstation, VirtualBox). For vSphere 6.5+ production workloads, change `<rasd:ResourceSubType>` to `pvscsi` (paravirtual) for better I/O performance.
- **Hardware version:** `vmx-19` (vSphere 7.0+) by default. Lower to `vmx-14` or `vmx-17` in the OVF if you must target very old ESXi clusters that do not support hardware version 19. Raise to `vmx-21` for vSphere 8.0+ features if needed.
- **Network:** VmxNet3 adapter on `VM Network`. Adjust the network name to match your vSphere environment.

## Usage

When the GitHub Actions workflow triggers artifact generation, it automatically selects the configuration matching the target format:

```
--config /builder/${{ format }}/config.toml
```

For OVA, the CI pipeline first builds a VMDK, then packages it with the OVF template into a `.ova` tar archive.

> These configurations do **not** affect the base OS or application containers. They are applied *after* the container image is built, during the artifact disk generation phase.
