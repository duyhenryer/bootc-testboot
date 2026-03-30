#!/bin/bash
# MongoDB first-boot credential and TLS setup.
# Generates: admin password, TLS certs, keyFile.
# Runs once; skips if /var/lib/mongodb/.setup-done exists.
#
# Called by mongodb-setup.service (Before=mongod.service).

set -euo pipefail
source /usr/libexec/testboot/log.sh

FLAG="/var/lib/mongodb/.setup-done"
if [ -f "$FLAG" ]; then
    log_info "MongoDB setup already done (flag exists: $FLAG)"
    exit 0
fi

log_info "Starting MongoDB credential and TLS setup"

# --- Admin password ---
log_info "Generating admin password"
/usr/libexec/testboot/gen-password.sh /var/lib/mongodb/.admin-pw 32

# --- TLS certificates (CA + server) ---
log_info "Generating TLS certificates"
/usr/libexec/testboot/gen-tls-cert.sh /var/lib/mongodb/tls localhost

# --- Replica set keyFile (internal auth between members) ---
log_info "Generating replica set keyFile"
/usr/libexec/testboot/gen-password.sh /var/lib/mongodb/.keyFile 756
chmod 0400 /var/lib/mongodb/.keyFile

# --- Fix ownership ---
log_info "Setting ownership to mongod:mongod"
chown -R mongod:mongod /var/lib/mongodb/tls \
                        /var/lib/mongodb/.keyFile \
                        /var/lib/mongodb/.admin-pw

touch "$FLAG"
log_info "MongoDB setup complete (creds + TLS + keyFile)"
