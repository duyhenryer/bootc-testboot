#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Post-boot health checks
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  [PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo "==> bootc status"
sudo bootc status
echo ""

echo "==> Health checks:"

check "bootc status"           sudo bootc status
check "nginx running"          systemctl is-active nginx
check "hello.service running"  systemctl is-active hello
check "cloud-init running"     systemctl is-active cloud-init
check "curl localhost:80"      curl -sf http://localhost:80/
check "curl localhost:8080"    curl -sf http://localhost:8080/health
check "/usr is read-only"      test ! -w /usr/bin/

echo ""
echo "==> Results: ${PASS} passed, ${FAIL} failed"

if [[ ${FAIL} -gt 0 ]]; then
    echo "Some checks failed. Investigate above."
    exit 1
fi
