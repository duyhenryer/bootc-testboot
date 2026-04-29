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
            mongodb-setup mongodb-init valkey-setup \
            testboot-infra.target testboot-apps.target \
            hello-healthcheck.timer worker-healthcheck.timer; do
    if systemctl is-enabled $unit >/dev/null 2>&1; then echo "  OK: $unit enabled"
    else echo "  FAIL: $unit not enabled"; FAIL=1; fi
done

echo "--- Checking firewalld is NOT enabled (cloud-first: rely on VPC) ---"
if systemctl is-enabled firewalld >/dev/null 2>&1; then
    echo "  FAIL: firewalld is enabled — should be disabled (VPC handles network ACL)"; FAIL=1
else echo "  OK: firewalld not enabled"; fi

echo "--- Checking unit files on disk ---"
test -f /etc/logrotate.d/bootc-testboot && echo "  OK: logrotate.d/bootc-testboot" || { echo "  FAIL: logrotate.d"; FAIL=1; }

echo "--- Checking immutable configs ---"
for f in /usr/share/nginx/nginx.conf /usr/share/nginx/conf.d/hello.conf \
         /etc/cloud/cloud.cfg.d/99-bootc-datasources.cfg; do
    if test -f $f; then echo "  OK: $f"
    else echo "  FAIL: $f missing"; FAIL=1; fi
done

echo "--- Checking setup scripts ---"
for s in /usr/libexec/testboot/mongodb-setup.sh \
         /usr/libexec/testboot/mongodb-init.sh \
         /usr/libexec/testboot/valkey-setup.sh \
         /usr/libexec/testboot/testboot-app-setup.sh; do
    if test -x $s; then echo "  OK: $s executable"
    else echo "  FAIL: $s missing or not executable"; FAIL=1; fi
done

echo "--- Checking MongoDB binds 0.0.0.0 + Valkey requires include ---"
if grep -q "^  bindIp: 0.0.0.0" /etc/mongod.conf; then echo "  OK: mongod binds 0.0.0.0"
else echo "  FAIL: mongod bindIp not 0.0.0.0"; FAIL=1; fi
if grep -q "^bind 0.0.0.0" /etc/valkey/valkey.conf; then echo "  OK: valkey binds 0.0.0.0"
else echo "  FAIL: valkey bind not 0.0.0.0"; FAIL=1; fi
if grep -q "^include /etc/valkey/auth.conf" /etc/valkey/valkey.conf; then echo "  OK: valkey includes auth.conf"
else echo "  FAIL: valkey.conf missing include"; FAIL=1; fi

echo "--- Running bootc lint ---"
bootc container lint --fatal-warnings || FAIL=1

if [ $FAIL -eq 0 ]; then echo "ALL SMOKE TESTS PASSED"
else echo "SMOKE TESTS FAILED"; exit 1; fi
'
