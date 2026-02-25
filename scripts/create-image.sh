#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Unified disk image builder
# =============================================================================
# Usage: create-image.sh <type>
#
# Supported types: ami, vmdk, qcow2, gce, raw, vhd
#
# Common env vars:
#   REGISTRY, IMAGE, VERSION         — container image to convert
#   configs/builder/config.toml      — bootc-image-builder config
#
# Type-specific env vars:
#   ami  : AWS_REGION, AWS_BUCKET, AMI_NAME, AWS_PROFILE
#   gce  : GCP_PROJECT, GCP_BUCKET, GCE_IMAGE_NAME
#   vmdk : VMDK_NAME
#   qcow2: (none)
# =============================================================================

TYPE="${1:?Usage: create-image.sh <ami|vmdk|qcow2|gce|raw|vhd>}"

REGISTRY="${REGISTRY:-ghcr.io/duyhenryer}"
IMAGE="${IMAGE:-${REGISTRY}/bootc-testboot}"
VERSION="${VERSION:-latest}"

echo "==> Creating ${TYPE} image"
echo "    Source: ${IMAGE}:${VERSION}"

# --- Pull image ---
echo "==> Pulling image: ${IMAGE}:${VERSION}"
sudo podman pull "${IMAGE}:${VERSION}"

# --- Prepare output ---
mkdir -p output

# --- Build common args ---
BUILDER_ARGS=(
    --rm --privileged
    --pull=newer
    --security-opt label=type:unconfined_t
    -v ./configs/builder/config.toml:/config.toml:ro
    -v ./output:/output
    -v /var/lib/containers/storage:/var/lib/containers/storage
)

BIB_ARGS=(
    --type "${TYPE}"
    --rootfs ext4
    --config /config.toml
)

# --- Type-specific args ---
case "${TYPE}" in
    ami)
        AWS_REGION="${AWS_REGION:-ap-southeast-1}"
        AWS_BUCKET="${AWS_BUCKET:-my-bootc-poc-bucket}"
        AMI_NAME="${AMI_NAME:-bootc-poc-${VERSION}}"

        BUILDER_ARGS+=(
            -v "${HOME}/.aws:/root/.aws:ro"
            --env "AWS_PROFILE=${AWS_PROFILE:-default}"
        )
        BIB_ARGS+=(
            --aws-ami-name "${AMI_NAME}"
            --aws-bucket "${AWS_BUCKET}"
            --aws-region "${AWS_REGION}"
        )

        echo "    AMI:    ${AMI_NAME}"
        echo "    Region: ${AWS_REGION}"
        echo "    Bucket: ${AWS_BUCKET}"
        ;;

    gce)
        GCP_PROJECT="${GCP_PROJECT:?ERROR: GCP_PROJECT is required}"
        GCP_BUCKET="${GCP_BUCKET:?ERROR: GCP_BUCKET is required}"
        GCE_IMAGE_NAME="${GCE_IMAGE_NAME:-bootc-poc-${VERSION//[^a-z0-9-]/-}}"

        echo "    GCE:     ${GCE_IMAGE_NAME}"
        echo "    Project: ${GCP_PROJECT}"
        echo "    Bucket:  ${GCP_BUCKET}"
        ;;

    vmdk)
        VMDK_NAME="${VMDK_NAME:-bootc-poc-${VERSION}}"
        echo "    VMDK: ${VMDK_NAME}"
        ;;

    qcow2|raw|vhd)
        echo "    Output: output/${TYPE}/"
        ;;

    *)
        echo "ERROR: Unknown type '${TYPE}'"
        echo "       Supported: ami, vmdk, qcow2, gce, raw, vhd"
        exit 1
        ;;
esac

# --- Run bootc-image-builder ---
echo "==> Running bootc-image-builder --type ${TYPE}"
sudo podman run \
    "${BUILDER_ARGS[@]}" \
    quay.io/centos-bootc/bootc-image-builder:latest \
    "${BIB_ARGS[@]}" \
    "${IMAGE}:${VERSION}"

# --- Post-build: type-specific steps ---
case "${TYPE}" in
    ami)
        echo "==> AMI created. Check AWS Console."
        ;;

    gce)
        TAR_PATH="output/gce/image.tar.gz"
        if [[ ! -f "${TAR_PATH}" ]]; then
            echo "ERROR: image.tar.gz not found at ${TAR_PATH}"
            ls -la output/gce/ 2>/dev/null || echo "  output/gce/ does not exist"
            exit 1
        fi

        echo "==> Uploading to gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz"
        gsutil cp "${TAR_PATH}" "gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz"

        echo "==> Creating Compute Engine image: ${GCE_IMAGE_NAME}"
        gcloud compute images create "${GCE_IMAGE_NAME}" \
            --project="${GCP_PROJECT}" \
            --source-uri="gs://${GCP_BUCKET}/${GCE_IMAGE_NAME}.tar.gz" \
            --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE \
            --description="bootc OS image built from ${IMAGE}:${VERSION}"

        echo "==> GCE image '${GCE_IMAGE_NAME}' created successfully."
        echo "    View: https://console.cloud.google.com/compute/images?project=${GCP_PROJECT}"
        ;;

    vmdk)
        echo "==> VMDK created at output/vmdk/disk.vmdk"
        ;;

    qcow2)
        echo "==> QCOW2 created at output/qcow2/disk.qcow2"
        ;;

    raw)
        echo "==> RAW created at output/image/disk.raw"
        ;;

    vhd)
        echo "==> VHD created at output/vpc/disk.vhd"
        ;;
esac
