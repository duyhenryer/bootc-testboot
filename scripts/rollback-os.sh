#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Rollback OS to previous deployment
# ---------------------------------------------------------------------------
# WARNING: /var is NOT rolled back (by design).
#   - Database data, logs, app state in /var survive rollback.
#   - If the new version ran schema migrations, you must handle
#     the database rollback separately.
# ---------------------------------------------------------------------------

echo "==> Current status:"
sudo bootc status
echo ""
echo "WARNING: /var data will NOT be rolled back."
echo "         The system will reboot into the previous deployment."
echo ""
read -p "Continue with rollback + reboot? [y/N] " confirm

if [[ "${confirm}" =~ ^[yY]$ ]]; then
    echo "==> Rolling back..."
    sudo bootc rollback
    echo "==> Rebooting..."
    sudo systemctl reboot
else
    echo "Aborted."
fi
