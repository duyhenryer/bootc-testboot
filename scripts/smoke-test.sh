#!/bin/bash
# Smoke test: verify image contents (binaries, units, configs, lint).
#
# Usage: smoke-test.sh <podman> <image-ref>
#   podman:    container runtime (podman or docker)
#   image-ref: full image reference including tag
#
# Example:
#   ./scripts/smoke-test.sh podman ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest

set -euo pipefail

PODMAN="${1:?Usage: smoke-test.sh <podman> <image-ref>}"
IMAGE="${2:?Usage: smoke-test.sh <podman> <image-ref>}"

echo "==> Smoke testing ${IMAGE}"

${PODMAN} run --rm "${IMAGE}" bash -c '
FAIL=0

echo "--- Checking binaries ---"
for bin in hello worker; do
    if test -x /usr/bin/$bin; then echo "  OK: /usr/bin/$bin"
    else echo "  FAIL: /usr/bin/$bin missing"; FAIL=1; fi
done

echo "--- Checking systemd units (enabled) ---"
for unit in hello worker nginx mongod valkey rabbitmq-server \
            testboot-infra.target testboot-apps.target \
            hello-healthcheck.timer worker-healthcheck.timer; do
    if systemctl is-enabled $unit >/dev/null 2>&1; then echo "  OK: $unit enabled"
    else echo "  FAIL: $unit not enabled"; FAIL=1; fi
done

echo "--- Checking unit files on disk ---"
test -f /etc/logrotate.d/bootc-testboot && echo "  OK: logrotate.d/bootc-testboot" || { echo "  FAIL: logrotate.d"; FAIL=1; }

echo "--- Checking immutable configs ---"
for f in /usr/share/nginx/nginx.conf /usr/share/nginx/conf.d/hello.conf; do
    if test -f $f; then echo "  OK: $f"
    else echo "  FAIL: $f missing"; FAIL=1; fi
done

echo "--- Running bootc lint ---"
bootc container lint --fatal-warnings || FAIL=1

if [ $FAIL -eq 0 ]; then echo "ALL SMOKE TESTS PASSED"
else echo "SMOKE TESTS FAILED"; exit 1; fi
'
