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
# Optional: TRIVY_SKIP_DIRS="path1,path2" — comma-separated; each becomes --skip-dirs (reduces noise from e.g. OSTree object store; see docs/project/002-building-images.md).
skip_args=()
if [ -n "${TRIVY_SKIP_DIRS:-}" ]; then
	IFS=',' read -r -a _dirs <<< "$TRIVY_SKIP_DIRS"
	for d in "${_dirs[@]}"; do
		d="${d#"${d%%[![:space:]]*}"}"
		d="${d%"${d##*[![:space:]]}"}"
		[ -z "$d" ] && continue
		skip_args+=( --skip-dirs "$d" )
	done
fi
trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 0 "${skip_args[@]}" "$IMAGE"
