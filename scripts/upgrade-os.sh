#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Production-safe OS upgrade flow
# ---------------------------------------------------------------------------
# Phase 1 (business hours):  ./scripts/upgrade-os.sh download
# Phase 2 (maintenance):     ./scripts/upgrade-os.sh apply
# ---------------------------------------------------------------------------

ACTION="${1:-download}"

case "${ACTION}" in
    download)
        echo "==> Phase 1: Downloading update (no apply, no reboot)"
        sudo bootc upgrade --download-only
        echo ""
        echo "==> Staged deployment status:"
        sudo bootc status --verbose
        echo ""
        echo "Download complete. Run './scripts/upgrade-os.sh apply' during maintenance window."
        ;;
    apply)
        echo "==> Phase 2: Applying staged update + reboot"
        echo "    WARNING: System will reboot!"
        echo ""
        read -p "Continue? [y/N] " confirm
        if [[ "${confirm}" =~ ^[yY]$ ]]; then
            sudo bootc upgrade --from-downloaded --apply
        else
            echo "Aborted."
        fi
        ;;
    check)
        echo "==> Checking for updates (no side effects)"
        sudo bootc upgrade --check
        ;;
    *)
        echo "Usage: $0 {download|apply|check}"
        exit 1
        ;;
esac
