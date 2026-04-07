#!/usr/bin/env bash
# Optional CVE scan. Install trivy: https://aquasecurity.github.io/trivy/
set -euo pipefail
IMAGE="${1:?Usage: $0 IMAGE_REF}"
if ! command -v trivy >/dev/null 2>&1; then
  echo "[WARN] trivy not installed — skipping CVE scan. Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
  exit 0
fi
echo "[INFO] Trivy scan: $IMAGE"
# --scanners vuln keeps CI/local runs faster than default (vuln+secret)
trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 0 "$IMAGE"
