# Infrastructure Builder Layer

This directory contains configuration files used exclusively by the `bootc-image-builder` tool to convert OCI Container Images into various disk formats (e.g., AMI, VMDK, ISO, QCOW2).

## Structure

```
builder/
├── gce/config.toml       # GCE (Google Compute Engine) builder customizations
├── qcow2/config.toml     # QCOW2 builder customizations
├── vmdk/config.toml      # VMDK builder customizations
├── ova/bootc-poc.ovf     # OVF template for OVA packaging (VMDK → OVA)
└── README.md
```

## Per-Format Configuration

Configurations are split by output format because different environments often require different system-level parameters:

- **Disk Partitioning:** e.g., allocating specific storage sizes for `/var/data`.
- **User Injection:** e.g., injecting SSH keys for `devops` user.
- **Kernel Boot Arguments:** e.g., serial console parameters.

### `gce/config.toml`

GCE-specific config. Uses `--type raw` with `bootc-image-builder`, then the raw disk is packaged as `tar.gz` for GCE image import. Kernel args include `console=ttyS0,115200n8` for GCE serial console.

### `qcow2/config.toml` and `vmdk/config.toml`

Standard `bootc-image-builder` [Blueprint](https://github.com/osbuild/blueprint) configs with `[[customizations.user]]`, `[[customizations.filesystem]]`, and `[customizations.kernel]` sections.

### `ova/bootc-poc.ovf`

OVF descriptor template with placeholders (`CPU_COUNT`, `MEMORY_MB`, `DISK_SIZE_GB`, `VMDK_FILENAME`, `VMDK_SIZE`). These are filled in by the CI pipeline during OVA packaging.

## Usage

When the GitHub Actions workflow triggers artifact generation, it automatically selects the configuration matching the target format:

```
--config /builder/${{ format }}/config.toml
```

For OVA, the CI pipeline first builds a VMDK, then packages it with the OVF template into a `.ova` tar archive.

> These configurations do **not** affect the base OS or application containers. They are applied *after* the container image is built, during the artifact disk generation phase.
