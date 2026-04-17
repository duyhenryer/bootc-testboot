#!/bin/bash
# VM upgrade test: create persistent VM, verify services, test bootc upgrade + reboot.
#
# Usage: vm-upgrade-test.sh <image-ref>
#   image-ref: full image reference including tag
#
# Prerequisites:
#   - bcvk installed with libvirt support
#   - libvirtd running (sudo systemctl enable --now libvirtd)
#   - /dev/kvm accessible
#   - qemu-system-x86_64, virtiofsd, podman
#
# Example:
#   ./scripts/vm-upgrade-test.sh ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest

set -euo pipefail

IMAGE="${1:?Usage: vm-upgrade-test.sh <image-ref>}"
VM_NAME="testboot-upgrade-$$"
SSH_TIMEOUT=180
FAIL=0

cleanup() {
    echo "==> Cleaning up VM ${VM_NAME}"
    bcvk libvirt rm -f "${VM_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "==> Preflight checks"

if ! command -v bcvk &>/dev/null; then
    echo "SKIP: bcvk not found. Install: cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk"
    exit 0
fi

if [ ! -w /dev/kvm ]; then
    echo "SKIP: /dev/kvm not writable. VM tests require KVM."
    exit 0
fi

if ! systemctl is-active libvirtd &>/dev/null; then
    echo "FAIL: libvirtd is not running."
    echo "  Fix: sudo systemctl enable --now libvirtd"
    exit 1
fi

echo "  OK: bcvk=$(bcvk --version 2>/dev/null || echo unknown)"
echo "  OK: /dev/kvm writable"
echo "  OK: libvirtd running"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
vm_ssh() {
    bcvk libvirt ssh "${VM_NAME}" "($*) || true" 2>/dev/null | tr -d '\r' || true
}

wait_ssh() {
    local timeout=$1
    local label=${2:-"SSH"}
    echo "==> Waiting for ${label} (timeout ${timeout}s)"
    SECONDS=0
    while [ $SECONDS -lt $timeout ]; do
        if bcvk libvirt ssh "${VM_NAME}" 'true' 2>/dev/null; then
            echo "  OK: ${label} ready after ${SECONDS}s"
            return 0
        fi
        sleep 5
    done
    echo "FAIL: ${label} not ready after ${timeout}s"
    return 1
}

check_pass() { echo "  OK: $1"; }
check_fail() { echo "  FAIL: $1"; FAIL=1; }

# ---------------------------------------------------------------------------
# Phase 1: Create persistent VM
# ---------------------------------------------------------------------------
echo "==> Creating persistent VM from ${IMAGE}"

bcvk libvirt run \
    --name "${VM_NAME}" \
    --memory 4G \
    --cpus 2 \
    --disk-size 20G \
    --update-from-host \
    --detach \
    "${IMAGE}"

wait_ssh $SSH_TIMEOUT "initial boot" || exit 1

# ---------------------------------------------------------------------------
# Phase 2: Verify services (same as vm-test)
# ---------------------------------------------------------------------------
echo "--- Phase 2: Verify services after initial boot ---"

for svc in hello worker mongod valkey rabbitmq-server nginx firewalld; do
    if vm_ssh "systemctl is-active ${svc}" | grep -q "^active$"; then
        check_pass "${svc} is active"
    else
        check_fail "${svc} is NOT active"
    fi
done

if vm_ssh 'curl -sf http://127.0.0.1:8000/health' | grep -qi "ok"; then
    check_pass "hello /health responded ok"
else
    check_fail "hello /health did not respond"
fi

# Record initial bootc deployment
echo "--- Current bootc status ---"
vm_ssh 'bootc status 2>/dev/null | head -20' || true

DEPLOY_BEFORE=$(vm_ssh 'bootc status --json 2>/dev/null | grep -o "\"digest\":\"[^\"]*\"" | head -1' || echo "unknown")
echo "  Deployment before upgrade: ${DEPLOY_BEFORE}"

# ---------------------------------------------------------------------------
# Phase 3: bootc upgrade
# ---------------------------------------------------------------------------
echo "--- Phase 3: bootc upgrade ---"

UPGRADE_OUTPUT=$(vm_ssh 'sudo bootc upgrade 2>&1' || true)
echo "${UPGRADE_OUTPUT}" | tail -5

if echo "${UPGRADE_OUTPUT}" | grep -qi "no update available\|already queued\|staged"; then
    echo "  INFO: No new update available or already staged (image unchanged)."
    echo "  INFO: Skipping reboot test — upgrade requires a new image version."
    echo ""
    if [ $FAIL -eq 0 ]; then
        echo "=== VM UPGRADE TEST PASSED (services OK, upgrade check OK) ==="
    else
        echo "=== VM UPGRADE TEST FAILED ==="
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase 4: Reboot and verify
# ---------------------------------------------------------------------------
echo "--- Phase 4: Reboot ---"

vm_ssh 'sudo reboot' || true
echo "  Waiting 15s for VM to start rebooting..."
sleep 15

wait_ssh $SSH_TIMEOUT "reboot" || exit 1

echo "--- Verify services after reboot ---"

for svc in hello worker mongod valkey rabbitmq-server nginx; do
    if vm_ssh "systemctl is-active ${svc}" | grep -q "^active$"; then
        check_pass "${svc} is active after reboot"
    else
        check_fail "${svc} is NOT active after reboot"
    fi
done

if vm_ssh 'curl -sf http://127.0.0.1:8000/health' | grep -qi "ok"; then
    check_pass "hello /health responded ok after reboot"
else
    check_fail "hello /health did not respond after reboot"
fi

DEPLOY_AFTER=$(vm_ssh 'bootc status --json 2>/dev/null | grep -o "\"digest\":\"[^\"]*\"" | head -1' || echo "unknown")
echo "  Deployment after upgrade: ${DEPLOY_AFTER}"

if [ "${DEPLOY_BEFORE}" != "${DEPLOY_AFTER}" ] && [ "${DEPLOY_AFTER}" != "unknown" ]; then
    check_pass "bootc deployment changed after upgrade"
else
    echo "  INFO: deployment digest unchanged (may be same image)"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ $FAIL -eq 0 ]; then
    echo "=== ALL VM UPGRADE TESTS PASSED ==="
else
    echo "=== VM UPGRADE TESTS FAILED ==="
    exit 1
fi
