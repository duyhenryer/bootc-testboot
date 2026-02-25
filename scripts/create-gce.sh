#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Create GCE image via bootc-image-builder + upload to Google Cloud
# ---------------------------------------------------------------------------
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - GCS bucket already exists in target project
#   - podman installed, running as root (sudo)
#   - Permissions: roles/compute.imageAdmin + roles/storage.objectAdmin
# ---------------------------------------------------------------------------

REGISTRY="${REGISTRY:-ghcr.io/duyhenryer}"
IMAGE="${IMAGE:-${REGISTRY}/bootc-testboot}"
VERSION="${VERSION:-latest}"
GCP_PROJECT="${GCP_PROJECT:?ERROR: GCP_PROJECT is required}"
GCP_BUCKET="${GCP_BUCKET:?ERROR: GCP_BUCKET is required}"
GCE_IMAGE_NAME="${GCE_IMAGE_NAME:-bootc-poc-${VERSION//[^a-z0-9-]/-}}"

echo "==> Creating GCE image: ${GCE_IMAGE_NAME}"
echo "    Image:   ${IMAGE}:${VERSION}"
echo "    Project: ${GCP_PROJECT}"
echo "    Bucket:  ${GCP_BUCKET}"

# --- Step 1: Pull the bootc image ---
echo "==> Pulling image: ${IMAGE}:${VERSION}"
sudo podman pull "${IMAGE}:${VERSION}"

# --- Step 2: Build raw disk via bootc-image-builder ---
mkdir -p output

sudo podman run \
    --rm --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./configs/builder/config.toml:/config.toml:ro \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type gce \
    --rootfs ext4 \
    --config /config.toml \
    "${IMAGE}:${VERSION}"

# --- Step 3: Verify output and upload to GCS ---
# bootc-image-builder --type gce produces image.tar.gz (disk.raw already packaged)
TAR_PATH="output/gce/image.tar.gz"

if [[ ! -f "${TAR_PATH}" ]]; then
    echo "ERROR: image.tar.gz not found at ${TAR_PATH}"
    echo "       bootc-image-builder may have failed."
    echo "       Actual output contents:"
    ls -la output/gce/ 2>/dev/null || echo "       output/gce/ does not exist"
    exit 1
fi

echo "==> Uploading to gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz"
gsutil cp "${TAR_PATH}" "gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz"

# --- Step 5: Create GCE image ---
echo "==> Creating Compute Engine image: ${GCE_IMAGE_NAME}"
gcloud compute images create "${GCE_IMAGE_NAME}" \
    --project="${GCP_PROJECT}" \
    --source-uri="gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz" \
    --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE \
    --description="bootc OS image built from ${IMAGE}:${VERSION}"

echo "==> GCE image '${GCE_IMAGE_NAME}' created successfully."
echo "    View: https://console.cloud.google.com/compute/images?project=${GCP_PROJECT}"
