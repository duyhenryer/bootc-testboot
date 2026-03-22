#!/usr/bin/env bash
# Verify published GHCR images (public registry — no login).
#   1) skopeo inspect — metadata only, no full layer download
#   2) podman pull + check paths in scratch artifacts (see docs/project/005-manual-deployments.md)
#
# Needs: skopeo, podman, jq. Lots of free disk for full pulls.
#
# Usage:
#   ./scripts/verify-ghcr-packages.sh
#   VERIFY_SKIP_PULL=1 ./scripts/verify-ghcr-packages.sh    # metadata only, no large downloads
#
# Env:
#   REGISTRY_PREFIX   default ghcr.io/duyhenryer
#   DISTRO            default centos-stream9
#   ARCH_SUFFIX       default latest-amd64
#   VERIFY_SKIP_PULL  set 1 to skip podman pull + tarball checks
#   VERIFY_SKIP_SKOPEO set 1 to skip skopeo

set -uo pipefail

REGISTRY_PREFIX="${REGISTRY_PREFIX:-ghcr.io/duyhenryer}"
DISTRO="${DISTRO:-centos-stream9}"
ARCH_SUFFIX="${ARCH_SUFFIX:-latest-amd64}"

REPORT_FAIL=0
REPORT_OK=0

ok() { REPORT_OK=$((REPORT_OK + 1)); echo "  [OK] $*"; }
fail() { REPORT_FAIL=$((REPORT_FAIL + 1)); echo "  [FAIL] $*" >&2; }

section() { echo ""; echo "=== $* ==="; }

skopeo_inspect_ref() {
  local ref=$1
  local name=$2
  if [[ "${VERIFY_SKIP_SKOPEO:-0}" == "1" ]]; then
    echo "  (skopeo skipped) $name"
    return 0
  fi
  if ! command -v skopeo >/dev/null 2>&1; then
    echo "  skopeo not installed; skip inspect for $name"
    return 0
  fi
  if skopeo inspect "docker://${ref}" >/tmp/skopeo_$$.json 2>/tmp/skopeo_err_$$; then
    jq -r '"  digest: " + .Digest + "\n  arch: " + .Architecture + " os: " + .Os + "\n  created: " + (.Created // "n/a")' /tmp/skopeo_$$.json
    rm -f /tmp/skopeo_$$.json /tmp/skopeo_err_$$
    ok "skopeo inspect $name"
  else
    cat /tmp/skopeo_err_$$ >&2 || true
    rm -f /tmp/skopeo_$$.json /tmp/skopeo_err_$$
    fail "skopeo inspect $name"
  fi
  return 0
}

section "1. skopeo inspect (remote metadata, no layer download)"
BASE_IMG="${REGISTRY_PREFIX}/bootc-testboot-base:${DISTRO}-${ARCH_SUFFIX}"
APP_IMG="${REGISTRY_PREFIX}/bootc-testboot:${DISTRO}-${ARCH_SUFFIX}"
for suffix in ami qcow2 raw vmdk ova anaconda-iso; do
  skopeo_inspect_ref "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-${suffix}:${ARCH_SUFFIX}" "artifact-${suffix}"
done
skopeo_inspect_ref "$BASE_IMG" "base"
skopeo_inspect_ref "$APP_IMG" "app"

verify_artifact_paths() {
  local title=$1
  local image=$2
  local pattern=$3

  echo ""
  echo ">>> $title"
  echo "    image: $image"
  podman pull "$image"
  ctr=$(podman create "$image" /bin/true)
  listing=$(podman export "$ctr" | tar -tf -)
  podman rm "$ctr" >/dev/null

  if echo "$listing" | grep -qE "$pattern"; then
    ok "found path matching: $pattern"
    echo "$listing" | grep -E "$pattern" | head -5 | sed 's/^/       /'
  else
    fail "no path matching: $pattern"
    echo "    --- tar listing (first 40 lines) ---"
    echo "$listing" | head -40 | sed 's/^/       /'
  fi
}

verify_bootc_image() {
  local title=$1
  local image=$2

  echo ""
  echo ">>> $title"
  echo "    image: $image"
  podman pull "$image"
  if podman inspect "$image" --format '{{index .Config.Labels "containers.bootc"}}' | grep -q '1'; then
    ok "label containers.bootc=1"
  else
    fail "missing or wrong containers.bootc label"
  fi
  arch=$(podman inspect "$image" --format '{{.Architecture}}')
  echo "    architecture: $arch"
  if podman run --rm --entrypoint /bin/bash "$image" -c 'test -f /etc/os-release' 2>/dev/null; then
    ok "filesystem readable (bash + /etc/os-release)"
  else
    if podman run --rm --entrypoint /bin/sh "$image" -c 'test -f /etc/os-release' 2>/dev/null; then
      ok "filesystem readable (sh + /etc/os-release)"
    else
      fail "could not read /etc/os-release in container"
    fi
  fi
}

section "2. podman pull + verify (needs free disk — large layers)"

if [[ "${VERIFY_SKIP_PULL:-0}" == "1" ]]; then
  echo "VERIFY_SKIP_PULL=1 — skipping podman pull and tarball checks."
else
  verify_artifact_paths "AMI artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-ami:${ARCH_SUFFIX}" \
    '(^|\./)image/disk\.raw$'

  verify_artifact_paths "QCOW2 artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-qcow2:${ARCH_SUFFIX}" \
    '(^|\./)qcow2/disk\.qcow2$'

  verify_artifact_paths "Raw artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-raw:${ARCH_SUFFIX}" \
    '(^|\./)image/disk\.raw$'

  verify_artifact_paths "VMDK artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-vmdk:${ARCH_SUFFIX}" \
    '(^|\./)vmdk/disk\.vmdk$'

  verify_artifact_paths "OVA artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-ova:${ARCH_SUFFIX}" \
    '\.ova$'

  verify_artifact_paths "Anaconda ISO artifact" \
    "${REGISTRY_PREFIX}/bootc-testboot-${DISTRO}-anaconda-iso:${ARCH_SUFFIX}" \
    '(^|\./)bootiso/disk\.iso$'

  verify_bootc_image "Base image" "$BASE_IMG"
  verify_bootc_image "Application image" "$APP_IMG"
fi

section "3. Report"
echo "Checks marked [OK]: $REPORT_OK"
echo "Checks marked [FAIL]: $REPORT_FAIL"
if [[ "$REPORT_FAIL" -gt 0 ]]; then
  echo "Overall: FAILED"
  exit 1
fi
echo "Overall: PASSED"
exit 0
