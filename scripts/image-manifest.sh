#!/usr/bin/env bash
# Write podman inspect JSON for an image (supply-chain / SBOM-adjacent metadata).
set -euo pipefail
IMAGE="${1:?Usage: $0 IMAGE_REF (e.g. ghcr.io/owner/bootc-testboot/centos-stream9:latest)}"
OUT_DIR="${OUT_DIR:-output}"
OUT_SAFE=$(echo "$IMAGE" | sed 's/[^a-zA-Z0-9._-]/_/g')
OUT_FILE="${OUT_DIR}/image-manifest-${OUT_SAFE}.json"
mkdir -p "$OUT_DIR"
podman inspect "$IMAGE" >"$OUT_FILE"
echo "[INFO] Wrote $OUT_FILE"
