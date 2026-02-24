#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Create AMI via bootc-image-builder with auto-upload to AWS
# ---------------------------------------------------------------------------
# Prerequisites:
#   - vmimport service role configured in AWS account
#   - S3 bucket already exists in target region
#   - AWS credentials available (~/.aws or env vars)
#   - podman installed, running as root
# ---------------------------------------------------------------------------

REGISTRY="${REGISTRY:-ghcr.io/duyhenryer}"
IMAGE="${IMAGE:-${REGISTRY}/bootc-testboot}"
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
AWS_BUCKET="${AWS_BUCKET:-my-bootc-poc-bucket}"
AMI_NAME="${AMI_NAME:-bootc-poc-${VERSION}}"

echo "==> Creating AMI: ${AMI_NAME}"
echo "    Image:  ${IMAGE}:${VERSION}"
echo "    Region: ${AWS_REGION}"
echo "    Bucket: ${AWS_BUCKET}"

echo "==> Pulling image: ${IMAGE}:${VERSION}"
sudo podman pull "${IMAGE}:${VERSION}"

sudo podman run \
    --rm --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./configs/builder/config.toml:/config.toml:ro \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "${HOME}/.aws:/root/.aws:ro" \
    --env AWS_PROFILE="${AWS_PROFILE:-default}" \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type ami \
    --rootfs ext4 \
    --aws-ami-name "${AMI_NAME}" \
    --aws-bucket "${AWS_BUCKET}" \
    --aws-region "${AWS_REGION}" \
    "${IMAGE}:${VERSION}"

echo "==> AMI ${AMI_NAME} created. Check AWS Console for the new AMI."
