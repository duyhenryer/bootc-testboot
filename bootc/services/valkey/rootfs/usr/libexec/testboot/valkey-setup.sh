#!/bin/bash
# Valkey first-boot credential setup.
# Generates: requirepass for AUTH (binds 0.0.0.0; rely on VPC + password).
# Runs once; skips if /var/lib/valkey/.setup-done exists.
#
# Called by valkey-setup.service (Before=valkey.service).

set -euo pipefail
source /usr/libexec/testboot/log.sh

FLAG="/var/lib/valkey/.setup-done"
PW_FILE="/var/lib/valkey/.password"
AUTH_CONF="/etc/valkey/auth.conf"
APP_SETUP_FLAG="/var/lib/bootc-testboot/shared/.app-setup-done"

if [ -f "$FLAG" ]; then
    log_info "Valkey setup already done (flag exists: $FLAG)"
    exit 0
fi

log_info "Starting Valkey credential setup"

# --- Generate password ---
log_info "Generating Valkey password"
/usr/libexec/testboot/gen-password.sh "$PW_FILE" 32
chown valkey:valkey "$PW_FILE"

# --- Write requirepass into config drop-in (included by /usr/share/valkey/valkey.conf) ---
log_info "Writing $AUTH_CONF"
mkdir -p "$(dirname "$AUTH_CONF")"
PW=$(cat "$PW_FILE")
TMP=$(mktemp "$(dirname "$AUTH_CONF")/.auth-XXXXXX")
printf 'requirepass %s\n' "$PW" > "$TMP"
chmod 0640 "$TMP"
chown root:valkey "$TMP"
mv -f "$TMP" "$AUTH_CONF"
unset PW

# --- Force testboot-app-setup to re-run so valkey.env picks up the new password ---
# Important for upgrade path: a prior image with no Valkey auth would have set
# .app-setup-done and the env file would be missing VALKEY_PASSWORD.
if [ -f "$APP_SETUP_FLAG" ]; then
    log_info "Invalidating $APP_SETUP_FLAG so testboot-app-setup regenerates valkey.env"
    rm -f "$APP_SETUP_FLAG"
fi

touch "$FLAG"
log_info "Valkey setup complete (requirepass written to $AUTH_CONF)"
