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
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
VMDK_NAME="${VMDK_NAME:-bootc-poc-${VERSION}}"

echo "==> Creating VMDK: ${VMDK_NAME}"
echo "    Image: ${IMAGE}:${VERSION}"

mkdir -p output

sudo podman run \
    --rm --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./configs/builder/config.toml:/config.toml:ro \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type vmdk \
    --config /config.toml \
    "${IMAGE}:${VERSION}"

echo "==> VMDK created at output/vmdk/disk.vmdk"
