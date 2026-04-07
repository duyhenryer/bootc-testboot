#!/bin/bash
# Check an HTTP health endpoint. Returns 0 if healthy, 1 otherwise.
#
# Usage: healthcheck.sh <url> [timeout_seconds] [expected_status] [max_attempts] [retry_delay_sec]
#   url:          HTTP URL to check
#   timeout:      Per-attempt curl max time in seconds (default: 5)
#   status:       Expected HTTP status code (default: 200)
#   max_attempts: Retries on mismatch (default: 1 = single attempt)
#   retry_delay:  Sleep between attempts (default: 1)
#
# Example in a systemd unit (boot liveness; retry tolerates startup races):
#   ExecStartPost=/usr/libexec/testboot/healthcheck.sh http://127.0.0.1:8001/ 5 200 30 1

set -euo pipefail
source /usr/libexec/testboot/log.sh

URL="${1:?Usage: healthcheck.sh <url> [timeout] [expected_status] [max_attempts] [retry_delay_sec]}"
TIMEOUT="${2:-5}"
EXPECTED="${3:-200}"
MAX_ATTEMPTS="${4:-1}"
RETRY_DELAY="${5:-1}"

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    STATUS=$(curl -sf -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$URL" 2>/dev/null) || STATUS=000
    if [ "$STATUS" = "$EXPECTED" ]; then
        log_info "Health OK: $URL (HTTP $STATUS) attempt=$attempt/$MAX_ATTEMPTS"
        exit 0
    fi
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        log_error "Health FAIL: $URL (HTTP $STATUS, expected $EXPECTED) attempt=$attempt/$MAX_ATTEMPTS"
        exit 1
    fi
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
done
