#!/bin/bash
# Check an HTTP health endpoint. Returns 0 if healthy, 1 otherwise.
#
# Usage: healthcheck.sh <url> [timeout_seconds] [expected_status]
#   url:      HTTP URL to check
#   timeout:  Curl timeout in seconds (default: 5)
#   status:   Expected HTTP status code (default: 200)
#
# Example in a systemd unit:
#   ExecStartPost=/usr/libexec/testboot/healthcheck.sh http://127.0.0.1:8080/health 10

set -euo pipefail
source /usr/libexec/testboot/log.sh

URL="${1:?Usage: healthcheck.sh <url> [timeout] [expected_status]}"
TIMEOUT="${2:-5}"
EXPECTED="${3:-200}"

STATUS=$(curl -sf -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$URL" 2>/dev/null) || STATUS=000

if [ "$STATUS" = "$EXPECTED" ]; then
    log_info "Health OK: $URL (HTTP $STATUS)"
    exit 0
else
    log_error "Health FAIL: $URL (HTTP $STATUS, expected $EXPECTED)"
    exit 1
fi
