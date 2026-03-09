#!/bin/bash
# Wait for a TCP service to become available before proceeding.
# Useful in ExecStartPre= to ensure dependencies are ready.
#
# Usage: wait-for-service.sh <host> <port> [timeout_seconds]
#   host:    Hostname or IP to connect to
#   port:    TCP port number
#   timeout: Max seconds to wait (default: 30)
#
# Example in a systemd unit:
#   ExecStartPre=/usr/libexec/testboot/wait-for-service.sh 127.0.0.1 27017 60

set -euo pipefail
source /usr/libexec/testboot/log.sh

HOST="${1:?Usage: wait-for-service.sh <host> <port> [timeout]}"
PORT="${2:?Usage: wait-for-service.sh <host> <port> [timeout]}"
TIMEOUT="${3:-30}"

log_info "Waiting for ${HOST}:${PORT} (timeout: ${TIMEOUT}s)..."

ELAPSED=0
while ! bash -c "echo >/dev/tcp/${HOST}/${PORT}" 2>/dev/null; do
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        log_error "${HOST}:${PORT} not available after ${TIMEOUT}s"
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

log_info "${HOST}:${PORT} is available (took ${ELAPSED}s)"
