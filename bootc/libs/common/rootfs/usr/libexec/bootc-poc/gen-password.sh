#!/bin/bash
# Generate a random password and write it to a file.
# Used by services that need auto-generated credentials on first boot.
#
# Usage: gen-password.sh <output-file> [length]
#   output-file: Path to write the password (created only if it doesn't exist)
#   length:      Password length (default: 32)
#
# Example in a systemd unit:
#   ExecStartPre=/usr/libexec/bootc-poc/gen-password.sh /var/lib/myapp/db-password 48

set -euo pipefail

OUTPUT_FILE="${1:?Usage: gen-password.sh <output-file> [length]}"
LENGTH="${2:-32}"

if [ -f "$OUTPUT_FILE" ]; then
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c "$LENGTH" > "$OUTPUT_FILE"
chmod 0600 "$OUTPUT_FILE"
