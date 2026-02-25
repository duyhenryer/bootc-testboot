#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Create VMDK disk image via bootc-image-builder
# ---------------------------------------------------------------------------
# Prerequisites:
#   - podman installed, running as root (sudo)
#   - bootc image already built and available in local container storage
#   - osbuild-selinux installed (if SELinux enforced)
# ---------------------------------------------------------------------------

REGISTRY="${REGISTRY:-ghcr.io/duyhenryer}"
IMAGE="${IMAGE:-${REGISTRY}/bootc-testboot}"
VERSION="${VERSION:-latest}"
VMDK_NAME="${VMDK_NAME:-bootc-poc-${VERSION}}"

echo "==> Creating VMDK: ${VMDK_NAME}"
echo "    Image: ${IMAGE}:${VERSION}"

mkdir -p output

echo "==> Pulling image: ${IMAGE}:${VERSION}"
sudo podman pull "${IMAGE}:${VERSION}"

sudo podman run \
    --rm --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./configs/builder/config.toml:/config.toml:ro \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type vmdk \
    --rootfs ext4 \
    --config /config.toml \
    "${IMAGE}:${VERSION}"

echo "==> VMDK created at output/vmdk/disk.vmdk"
