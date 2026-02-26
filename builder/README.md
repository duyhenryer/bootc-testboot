# Infrastructure Builder Layer

This directory contains configuration files used exclusively by the `bootc-image-builder` tool to convert OCI Container Images into various disk formats (e.g., AMI, VMDK, ISO, QCOW2).

## Architecture

Configurations are split by output format (`ami/`, `gce/`, `qcow2/`, etc.) because different cloud environments often require different system-level parameters:
- **Disk Partitioning:** e.g., allocating specific storage sizes for `/var/data`.
- **User Injection:** e.g., injecting SSH keys for `ec2-user` on AWS vs `sysadmin` on VMWare.
- **Kernel Boot Arguments:** e.g., cloud-specific serial console parameters.

## Usage

When the GitHub Actions workflow triggers, it automatically selects the configuration matching the target format:
`--config builder/${{ format }}/config.toml`

> Note: These configurations do **not** affect the base OS or application containers themselves. They are applied *after* the container image is built, during the artifact disk generation phase.
