#!/bin/bash
# Render a config template by replacing @@VAR@@ placeholders with env values.
# Writes output atomically (temp file + mv) so services never see partial configs.
#
# Usage: render-env.sh <template> <output> [owner:group] [mode]
#   template:    Source file with @@PLACEHOLDER@@ markers
#   output:      Destination path (created/overwritten atomically)
#   owner:group: Optional chown target (default: no change)
#   mode:        Optional chmod mode (default: 0644)
#
# Example in a systemd unit:
#   ExecStartPre=/usr/libexec/testboot/gen-password.sh /var/lib/myapp/db-password 32
#   ExecStartPre=/bin/bash -c 'export DB_PASS=$(cat /var/lib/myapp/db-password); \
#       /usr/libexec/testboot/render-env.sh /usr/share/myapp/config.tmpl /run/myapp/config.conf'
#
# Template syntax:
#   connection_string = mongodb://admin:@@DB_PASS@@@ 127.0.0.1:27017/mydb
#   log_level = @@LOG_LEVEL@@
#
# Unset variables are replaced with an empty string and logged as warnings.

set -euo pipefail
source /usr/libexec/testboot/log.sh

TEMPLATE="${1:?Usage: render-env.sh <template> <output> [owner:group] [mode]}"
OUTPUT="${2:?Usage: render-env.sh <template> <output> [owner:group] [mode]}"
OWNER="${3:-}"
MODE="${4:-0644}"

if [ ! -f "$TEMPLATE" ]; then
    log_error "Template not found: $TEMPLATE"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
TMPFILE=$(mktemp "$(dirname "$OUTPUT")/.render-XXXXXX")

CONTENT=$(cat "$TEMPLATE")
VARS=$(echo "$CONTENT" | grep -oP '@@\K[A-Za-z_][A-Za-z0-9_]*(?=@@)' | sort -u) || true

for var in $VARS; do
    val="${!var:-}"
    if [ -z "$val" ]; then
        log_warn "Variable $var is unset or empty"
    fi
    CONTENT="${CONTENT//@@${var}@@/$val}"
done

echo "$CONTENT" > "$TMPFILE"
chmod "$MODE" "$TMPFILE"
if [ -n "$OWNER" ]; then
    chown "$OWNER" "$TMPFILE"
fi

mv -f "$TMPFILE" "$OUTPUT"
log_info "Rendered $TEMPLATE -> $OUTPUT"
