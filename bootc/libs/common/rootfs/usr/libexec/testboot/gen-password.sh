#!/bin/bash
# Generate a random password and write it to a file.
# Used by services that need auto-generated credentials on first boot.
#
# Usage: gen-password.sh <output-file> [length]
#   output-file: Path to write the password (created only if it doesn't exist)
#   length:      Password length (default: 32)
#
# Example in a systemd unit:
#   ExecStartPre=/usr/libexec/testboot/gen-password.sh /var/lib/myapp/db-password 48

set -euo pipefail
source /usr/libexec/testboot/log.sh

OUTPUT_FILE="${1:?Usage: gen-password.sh <output-file> [length]}"
LENGTH="${2:-32}"

if [ -f "$OUTPUT_FILE" ]; then
    log_info "Password file already exists: $OUTPUT_FILE"
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

TMPFILE=$(mktemp "$(dirname "$OUTPUT_FILE")/.pw-XXXXXX")
chmod 0600 "$TMPFILE"
PW=$(openssl rand -base64 "$LENGTH" | tr -d '\n')
printf '%s' "${PW:0:$LENGTH}" > "$TMPFILE"

mv -n "$TMPFILE" "$OUTPUT_FILE" 2>/dev/null || true
rm -f "$TMPFILE"

log_info "Generated password -> $OUTPUT_FILE"
