# Infrastructure Builder Layer

This directory contains configuration files used exclusively by the `bootc-image-builder` tool to convert OCI Container Images into various disk formats (e.g., AMI, VMDK, ISO, QCOW2).

## Structure

```
builder/
├── ami/config.toml       # AWS AMI builder customizations (Nitro NVMe timeout, serial console)
├── gce/config.toml       # GCE (Google Compute Engine) builder customizations
├── qcow2/config.toml     # QCOW2 builder customizations
├── vmdk/config.toml      # VMDK builder customizations
├── ova/bootc-testboot.ovf # OVF template for OVA packaging (VMDK → OVA, EFI firmware)
└── README.md
```

## Per-Format Configuration

Configurations are split by output format because different environments often require different system-level parameters:

- **Disk Partitioning:** e.g., allocating specific storage sizes for `/var/data`.
- **User Injection:** e.g., injecting SSH keys for `devops` user.
- **Kernel Boot Arguments:** e.g., serial console parameters.

### `ami/config.toml`

AWS-specific config. Uses `--type ami` with `bootc-image-builder`. Kernel args include `nvme_core.io_timeout=4294967295` (prevents NVMe timeout on Nitro instances) and `console=ttyS0,115200n8` for EC2 serial console. The raw disk output is uploaded to S3 and imported as an EBS snapshot via `aws ec2 import-snapshot`.

### `gce/config.toml`

GCE-specific config. Uses `--type raw` with `bootc-image-builder`, then the raw disk is packaged as `tar.gz` for GCE image import. Kernel args include `console=ttyS0,115200n8` for GCE serial console.

### `qcow2/config.toml` and `vmdk/config.toml`

Standard `bootc-image-builder` [Blueprint](https://github.com/osbuild/blueprint) configs with `[[customizations.user]]`, `[[customizations.filesystem]]`, and `[customizations.kernel]` sections.

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
