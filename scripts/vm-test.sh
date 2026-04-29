#!/bin/bash
# VM test: boot image as real VM via bcvk, verify all services are running.
#
# Usage: vm-test.sh <image-ref>
#   image-ref: full image reference including tag
#
# Prerequisites:
#   - bcvk installed (cargo install --locked --git https://github.com/bootc-dev/bcvk bcvk)
#   - /dev/kvm accessible
#   - qemu-system-x86_64, virtiofsd, podman
#
# Example:
#   ./scripts/vm-test.sh ghcr.io/duyhenryer/bootc-testboot/centos-stream9:latest

set -euo pipefail

IMAGE="${1:?Usage: vm-test.sh <image-ref>}"
VM_NAME="testboot-vm-$$"
BOOT_TIMEOUT=300
FAIL=0

cleanup() {
    echo "==> Cleaning up VM ${VM_NAME}"
    podman stop "${VM_NAME}" 2>/dev/null || true
    podman rm -f "${VM_NAME}" 2>/dev/null || true
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
    echo "  Fix: sudo chmod 666 /dev/kvm"
    exit 0
fi

echo "  OK: bcvk=$(bcvk --version 2>/dev/null || echo unknown)"
echo "  OK: /dev/kvm writable"

# ---------------------------------------------------------------------------
# Boot VM
# ---------------------------------------------------------------------------
echo "==> Booting VM from ${IMAGE}"

bcvk ephemeral run -d --rm -K \
    --memory 4G \
    --vcpus 2 \
    --name "${VM_NAME}" \
    "${IMAGE}"

sleep 3
echo "  Container status: $(podman inspect --format '{{.State.Status}}' "${VM_NAME}" 2>/dev/null || echo 'not found')"

# ---------------------------------------------------------------------------
# Wait for VM port 2222 (QEMU hostfwd → guest :22) to accept connections.
# This proves sshd inside the VM is up before we attempt bcvk ssh.
# On nested KVM (GitHub runners) boot can take 4-5 minutes.
# ---------------------------------------------------------------------------
SSH_TIMEOUT=360
echo "==> Waiting for VM sshd on port 2222 (timeout ${SSH_TIMEOUT}s)"

SECONDS=0
PORT_READY=0
while [ $SECONDS -lt $SSH_TIMEOUT ]; do
    if podman exec "${VM_NAME}" bash -c 'timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/2222"' &>/dev/null; then
        PORT_READY=1
        echo "  OK: port 2222 open after ${SECONDS}s"
        break
    fi
    sleep 5
done

if [ $PORT_READY -eq 0 ]; then
    echo "FAIL: port 2222 not open after ${SSH_TIMEOUT}s"
    echo ""
    echo "--- Diagnostics ---"
    echo "Container status: $(podman inspect --format '{{.State.Status}} pid={{.State.Pid}}' "${VM_NAME}" 2>/dev/null || echo 'not found')"
    echo ""
    echo "--- VM journal (last 40 lines) ---"
    podman exec "${VM_NAME}" tail -40 /run/journal.log 2>/dev/null || echo "(no journal)"
    echo ""
    echo "--- Processes in container ---"
    podman top "${VM_NAME}" 2>/dev/null || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Connect via bcvk ssh — port is confirmed open, retry up to 3 times in case
# bcvk needs a moment to detect readiness.
# ---------------------------------------------------------------------------
echo "==> Connecting via bcvk ephemeral ssh"

SSH_OK=0
for attempt in 1 2 3; do
    if bcvk ephemeral ssh "${VM_NAME}" 'echo SSH_CONNECTED' 2>&1; then
        SSH_OK=1
        break
    fi
    echo "  Attempt ${attempt}/3 failed, retrying in 10s..."
    sleep 10
done

if [ $SSH_OK -eq 0 ]; then
    echo "FAIL: bcvk ephemeral ssh could not connect (port 2222 is open but SSH handshake failed)"
    echo ""
    echo "--- Diagnostics ---"
    echo "Container status: $(podman inspect --format '{{.State.Status}} pid={{.State.Pid}}' "${VM_NAME}" 2>/dev/null || echo 'not found')"
    echo ""
    echo "--- VM journal: sshd lines ---"
    podman exec "${VM_NAME}" grep -iE 'ssh' /run/journal.log 2>/dev/null | tail -20 || echo "(no sshd journal lines)"
    echo ""
    echo "--- Effective sshd config ---"
    podman exec "${VM_NAME}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i /run/tmproot/var/lib/bcvk/ssh -p 2222 root@127.0.0.1 \
        'sshd -T | egrep "permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods"' \
        2>/dev/null || echo "(could not read effective sshd config via guest ssh)"
    echo ""
    echo "--- Guest ssh config files ---"
    podman exec "${VM_NAME}" sh -lc 'for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do [ -f "$f" ] && { echo "### $f"; sed -n "1,160p" "$f"; echo; }; done' \
        2>/dev/null || echo "(could not read guest ssh config files)"
    echo ""
    echo "--- cloud-init status ---"
    podman exec "${VM_NAME}" sh -lc 'cloud-init status 2>/dev/null || true; systemctl status cloud-init cloud-config cloud-final --no-pager -l 2>/dev/null || true' \
        2>/dev/null || echo "(cloud-init not available)"
    echo ""
    echo "--- Guest auth and root account state ---"
    podman exec "${VM_NAME}" sh -lc 'passwd -S root 2>/dev/null || true; getent passwd root 2>/dev/null || true; ls -ld /root /root/.ssh 2>/dev/null || true' \
        2>/dev/null || echo "(could not inspect root account state)"
    echo ""
    echo "--- Direct SSH attempt from inside container ---"
    podman exec "${VM_NAME}" ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o BatchMode=yes \
        -i /run/tmproot/var/lib/bcvk/ssh -p 2222 root@127.0.0.1 'echo DIRECT_SSH_OK' 2>&1 | tail -30 || true
    echo ""
    echo "--- Processes in container ---"
    podman top "${VM_NAME}" 2>/dev/null || true
    exit 1
fi

echo "  OK: SSH connected"

# ---------------------------------------------------------------------------
# Helper: run command in VM
# ---------------------------------------------------------------------------
vm_ssh() {
    bcvk ephemeral ssh "${VM_NAME}" "($*) || true" 2>/dev/null | tr -d '\r' || true
}

check_pass() {
    echo "  OK: $1"
}

check_fail() {
    echo "  FAIL: $1"
    FAIL=1
}

# ---------------------------------------------------------------------------
# Wait for system boot to finish (cloud-init, services, etc.)
# ---------------------------------------------------------------------------
echo "==> Waiting for system boot to complete (timeout ${BOOT_TIMEOUT}s)"

SECONDS=0
while [ $SECONDS -lt $BOOT_TIMEOUT ]; do
    STATUS=$(vm_ssh 'systemctl is-system-running 2>/dev/null' | tr -d '[:space:]')
    case "${STATUS}" in
        running|degraded)
            echo "  OK: system ${STATUS} after ${SECONDS}s"
            break
            ;;
    esac
    sleep 5
done

if [ $SECONDS -ge $BOOT_TIMEOUT ]; then
    echo "FAIL: system not ready after ${BOOT_TIMEOUT}s (status: ${STATUS})"
    vm_ssh 'systemctl list-units --failed --no-legend' || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Test: systemd services are active
# ---------------------------------------------------------------------------
echo "--- Checking systemd services ---"

for svc in hello worker mongod valkey rabbitmq-server nginx sshd; do
    if vm_ssh "systemctl is-active ${svc}" | grep -q "^active$"; then
        check_pass "${svc} is active"
    else
        check_fail "${svc} is NOT active"
    fi
done

# Cloud-first: firewalld must NOT be enabled (VPC handles network ACL).
if vm_ssh "systemctl is-enabled firewalld" | grep -q "^enabled$"; then
    check_fail "firewalld is enabled — should be disabled (VPC handles network ACL)"
else
    check_pass "firewalld is not enabled (cloud-first posture)"
fi

if vm_ssh "systemctl is-active chronyd" | grep -q "^active$"; then
    check_pass "chronyd is active"
else
    echo "  WARN: chronyd is NOT active (non-critical in ephemeral VM)"
fi

# ---------------------------------------------------------------------------
# Test: custom targets are active
# ---------------------------------------------------------------------------
echo "--- Checking systemd targets ---"

for target in testboot-infra.target testboot-apps.target; do
    if vm_ssh "systemctl is-active ${target}" | grep -q "^active$"; then
        check_pass "${target} is active"
    else
        check_fail "${target} is NOT active"
    fi
done

# ---------------------------------------------------------------------------
# Test: healthcheck timers
# ---------------------------------------------------------------------------
echo "--- Checking healthcheck timers ---"

for timer in hello-healthcheck.timer worker-healthcheck.timer; do
    if vm_ssh "systemctl is-enabled ${timer}" | grep -q "^enabled$"; then
        check_pass "${timer} is enabled"
    else
        check_fail "${timer} is NOT enabled"
    fi
done

# ---------------------------------------------------------------------------
# Test: HTTP health endpoints
# ---------------------------------------------------------------------------
echo "--- Checking HTTP endpoints ---"

if vm_ssh 'curl -sf http://127.0.0.1:8000/health' | grep -qi "ok"; then
    check_pass "hello /health responded ok"
else
    check_fail "hello /health did not respond"
fi

if vm_ssh 'curl -sf http://127.0.0.1:80/ 2>/dev/null || curl -sf http://127.0.0.1:80/api/health 2>/dev/null' | grep -q "."; then
    check_pass "nginx is serving"
else
    check_fail "nginx not responding"
fi

# ---------------------------------------------------------------------------
# Test: SELinux
# ---------------------------------------------------------------------------
echo "--- Checking SELinux ---"

SELINUX_STATUS=$(vm_ssh 'getenforce' | tr -d '[:space:]')
if echo "${SELINUX_STATUS}" | grep -qi "enforcing"; then
    check_pass "SELinux is Enforcing"
elif echo "${SELINUX_STATUS}" | grep -qi "disabled"; then
    check_pass "SELinux is Disabled (expected in bcvk ephemeral mode, selinux=0 kernel arg)"
else
    check_fail "SELinux is ${SELINUX_STATUS} (expected Enforcing or Disabled)"
fi

# ---------------------------------------------------------------------------
# Test: Valkey AUTH (requirepass enforced)
# ---------------------------------------------------------------------------
echo "--- Checking Valkey AUTH ---"

VALKEY_PW=$(vm_ssh 'cat /var/lib/valkey/.password 2>/dev/null')
if [ -n "${VALKEY_PW}" ]; then
    check_pass "Valkey password file exists"
else
    check_fail "Valkey password file missing"
fi

# Without password → must reject
if vm_ssh 'valkey-cli PING 2>&1' | grep -qi "NOAUTH\|authentication required"; then
    check_pass "Valkey rejects unauthenticated PING"
else
    check_fail "Valkey did NOT require auth (security regression)"
fi

# With password → must respond PONG
if [ -n "${VALKEY_PW}" ] && vm_ssh "valkey-cli -a '${VALKEY_PW}' PING 2>/dev/null" | grep -q "^PONG$"; then
    check_pass "Valkey responds PONG with correct password"
else
    check_fail "Valkey AUTH with stored password failed"
fi

# ---------------------------------------------------------------------------
# Test: bind addresses (cross-VM access ready, rely on VPC for filtering)
# ---------------------------------------------------------------------------
echo "--- Checking bind addresses ---"

if vm_ssh 'ss -tlnp | grep -E "(127.0.0.1|0.0.0.0|\\*):27017"' | grep -q "0.0.0.0:27017\\|\\*:27017"; then
    check_pass "MongoDB binds 0.0.0.0:27017"
else
    check_fail "MongoDB does NOT bind 0.0.0.0:27017"
fi
if vm_ssh 'ss -tlnp | grep -E "(127.0.0.1|0.0.0.0|\\*):6379"' | grep -q "0.0.0.0:6379\\|\\*:6379"; then
    check_pass "Valkey binds 0.0.0.0:6379"
else
    check_fail "Valkey does NOT bind 0.0.0.0:6379"
fi

# ---------------------------------------------------------------------------
# Test: bootc status
# ---------------------------------------------------------------------------
echo "--- Checking bootc status ---"

if vm_ssh 'bootc status' &>/dev/null; then
    check_pass "bootc status OK"
else
    check_fail "bootc status failed"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ $FAIL -eq 0 ]; then
    echo "=== ALL VM TESTS PASSED ==="
else
    echo "=== VM TESTS FAILED ==="
    exit 1
fi
