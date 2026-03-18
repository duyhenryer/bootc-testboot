#!/bin/bash
# Generate self-signed CA and server TLS certificates.
# Used by services that need TLS on first boot (e.g., MongoDB).
#
# Usage: gen-tls-cert.sh <cert-dir> [hostname] [days]
#   cert-dir:  Directory to write certs (created if missing)
#   hostname:  CN and SAN for server cert (default: localhost)
#   days:      Validity in days (default: 3650)
#
# Outputs:
#   <cert-dir>/ca.pem       - CA certificate
#   <cert-dir>/server.pem   - Server certificate + private key (combined)
#
# Idempotent: skips if ca.pem already exists.
#
# Example:
#   gen-tls-cert.sh /var/lib/mongodb/tls localhost

set -euo pipefail
source /usr/libexec/testboot/log.sh

CERT_DIR="${1:?Usage: gen-tls-cert.sh <cert-dir> [hostname] [days]}"
HOSTNAME="${2:-localhost}"
DAYS="${3:-3650}"

if [ -f "$CERT_DIR/ca.pem" ]; then
    log_info "TLS certs already exist: $CERT_DIR/ca.pem"
    exit 0
fi

mkdir -p "$CERT_DIR"
TMPDIR=$(mktemp -d "$CERT_DIR/.tls-gen-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "$TMPDIR/ca-key.pem" \
    -out "$TMPDIR/ca.pem" \
    -days "$DAYS" \
    -subj "/CN=testboot-ca" \
    2>/dev/null

openssl req -newkey rsa:4096 -nodes \
    -keyout "$TMPDIR/server-key.pem" \
    -out "$TMPDIR/server-csr.pem" \
    -subj "/CN=$HOSTNAME" \
    2>/dev/null

openssl x509 -req \
    -in "$TMPDIR/server-csr.pem" \
    -CA "$TMPDIR/ca.pem" \
    -CAkey "$TMPDIR/ca-key.pem" \
    -CAcreateserial \
    -out "$TMPDIR/server-cert.pem" \
    -days "$DAYS" \
    -extfile <(printf "subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1" "$HOSTNAME") \
    2>/dev/null

cat "$TMPDIR/server-cert.pem" "$TMPDIR/server-key.pem" > "$TMPDIR/server.pem"

chmod 0600 "$TMPDIR/ca.pem" "$TMPDIR/server.pem"
mv "$TMPDIR/ca.pem" "$CERT_DIR/ca.pem"
mv "$TMPDIR/server.pem" "$CERT_DIR/server.pem"

log_info "Generated TLS certs -> $CERT_DIR (CN=$HOSTNAME, valid ${DAYS}d)"
