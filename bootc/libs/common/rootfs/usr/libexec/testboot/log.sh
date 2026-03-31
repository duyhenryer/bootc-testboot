#!/bin/bash
# Shared logging functions for testboot scripts.
# Source this file; do NOT execute it directly.
#
# Usage:
#   source /usr/libexec/testboot/log.sh
#   log_info  "Service starting on port 8000"
#   log_warn  "Config not found, using defaults"
#   log_error "Connection refused"
#
# Environment:
#   LOG_FILE  - optional path to also append logs (default: stderr only -> journald)
#   LOG_TAG   - optional prefix tag (default: caller script basename)
#
# Output format:
#   [2025-03-05T14:30:00+0000] [INFO] [gen-password.sh] message here

_LOG_TAG="${LOG_TAG:-$(basename "${BASH_SOURCE[1]:-$0}")}"

_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    local msg="[$ts] [$level] [$_LOG_TAG] $*"
    echo "$msg" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
