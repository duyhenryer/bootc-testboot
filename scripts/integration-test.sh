#!/bin/bash
# Integration test: run app in read-only mode (simulates production).
#
# Usage: integration-test.sh <podman> <image-ref>
#   podman:    container runtime (podman or docker)
#   image-ref: full image reference including tag
#
# Example:
#   ./scripts/integration-test.sh podman ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest

set -euo pipefail

PODMAN="${1:?Usage: integration-test.sh <podman> <image-ref>}"
IMAGE="${2:?Usage: integration-test.sh <podman> <image-ref>}"

echo "==> Integration testing ${IMAGE} (read-only /usr)"

${PODMAN} run --rm \
    --read-only \
    --tmpfs /var:rw,nosuid,nodev \
    --tmpfs /run:rw,nosuid,nodev \
    --tmpfs /tmp:rw,nosuid,nodev \
    "${IMAGE}" bash -c '
echo "--- Verifying tmpfiles.d creates /var dirs ---"
systemd-tmpfiles --create 2>/dev/null
for d in /var/log/nginx /var/lib/testboot; do
    if test -d $d; then echo "  OK: $d"
    else echo "  FAIL: $d not created"; exit 1; fi
done

echo "--- Starting hello service directly ---"
/usr/bin/hello & PID=$!; sleep 1
RESP=$(curl -sf http://127.0.0.1:8000/health 2>/dev/null)
kill $PID 2>/dev/null
if echo "$RESP" | grep -q "ok"; then echo "  OK: hello /health responded"
else echo "  FAIL: hello /health did not respond"; exit 1; fi

echo "ALL INTEGRATION TESTS PASSED"
'
