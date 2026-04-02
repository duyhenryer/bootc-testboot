#!/bin/bash
# Validate app port assignments at build time.
# Checks: range (8000-8099), uniqueness, env ↔ nginx consistency.
#
# Usage: validate-ports.sh [apps_dir]
#   apps_dir: path to bootc/apps/ (default: auto-detected from script location)
#
# Exit codes: 0 = all checks passed, 1 = validation failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Try to source log.sh for structured logging; fall back to simple echo
if [ -f "${SCRIPT_DIR}/log.sh" ]; then
    source "${SCRIPT_DIR}/log.sh"
elif [ -f "/usr/libexec/testboot/log.sh" ]; then
    source /usr/libexec/testboot/log.sh
else
    log_info()  { echo "[INFO]  $*"; }
    log_warn()  { echo "[WARN]  $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

# Locate apps directory
if [ -n "${1:-}" ]; then
    APPS_DIR="$1"
else
    # Walk up from script location to find bootc/apps/
    REPO_ROOT="${SCRIPT_DIR}"
    while [ "$REPO_ROOT" != "/" ]; do
        if [ -d "${REPO_ROOT}/bootc/apps" ]; then
            break
        fi
        REPO_ROOT="$(dirname "$REPO_ROOT")"
    done
    APPS_DIR="${REPO_ROOT}/bootc/apps"
fi

if [ ! -d "$APPS_DIR" ]; then
    log_error "Apps directory not found: $APPS_DIR"
    exit 1
fi

PORT_MIN=8000
PORT_MAX=8099
FAIL=0

declare -A PORT_MAP  # port -> app name
declare -A APP_ENV_PORT  # app -> port from env
declare -A APP_NGINX_PORT  # app -> port from nginx

log_info "Validating app ports (range ${PORT_MIN}-${PORT_MAX})"
log_info "Scanning: ${APPS_DIR}"

# ---------------------------------------------------------------------------
# 1. Scan env files for LISTEN_ADDR
# ---------------------------------------------------------------------------
for env_file in "${APPS_DIR}"/*/rootfs/usr/share/bootc-testboot/*/*.env; do
    [ -f "$env_file" ] || continue
    app=$(echo "$env_file" | sed -E 's|.*/apps/([^/]+)/.*|\1|')
    port=$(grep -oP 'LISTEN_ADDR=:?\K[0-9]+' "$env_file" 2>/dev/null || true)

    if [ -z "$port" ]; then
        continue  # no LISTEN_ADDR in this env file (e.g., worker with no HTTP)
    fi

    APP_ENV_PORT[$app]=$port
    log_info "  ${app}: env port = ${port} (from ${env_file##*/})"

    # Range check
    if [ "$port" -lt "$PORT_MIN" ] || [ "$port" -gt "$PORT_MAX" ]; then
        log_error "  ${app}: port ${port} is outside range ${PORT_MIN}-${PORT_MAX}"
        FAIL=1
    fi

    # Uniqueness check
    if [ -n "${PORT_MAP[$port]:-}" ]; then
        log_error "  ${app}: port ${port} conflicts with '${PORT_MAP[$port]}'"
        FAIL=1
    else
        PORT_MAP[$port]=$app
    fi
done

# ---------------------------------------------------------------------------
# 2. Scan nginx upstream configs
# ---------------------------------------------------------------------------
for nginx_file in "${APPS_DIR}"/*/rootfs/usr/share/nginx/conf.d/*.conf; do
    [ -f "$nginx_file" ] || continue
    app=$(echo "$nginx_file" | sed -E 's|.*/apps/([^/]+)/.*|\1|')
    port=$(grep -oP 'server\s+127\.0\.0\.1:\K[0-9]+' "$nginx_file" 2>/dev/null | head -1 || true)

    if [ -z "$port" ]; then
        continue
    fi

    APP_NGINX_PORT[$app]=$port
    log_info "  ${app}: nginx upstream = ${port} (from ${nginx_file##*/})"
done

# ---------------------------------------------------------------------------
# 3. Cross-check: env port must match nginx upstream
# ---------------------------------------------------------------------------
for app in "${!APP_ENV_PORT[@]}"; do
    env_port="${APP_ENV_PORT[$app]}"
    nginx_port="${APP_NGINX_PORT[$app]:-}"

    if [ -z "$nginx_port" ]; then
        log_warn "  ${app}: has env port ${env_port} but no nginx upstream (OK if not web-facing)"
    elif [ "$env_port" != "$nginx_port" ]; then
        log_error "  ${app}: env port (${env_port}) != nginx upstream (${nginx_port})"
        FAIL=1
    else
        log_info "  ${app}: env ↔ nginx consistent (port ${env_port})"
    fi
done

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
    log_info "All port checks passed (${#APP_ENV_PORT[@]} app(s) validated)"
    exit 0
else
    log_error "Port validation FAILED — fix errors above"
    exit 1
fi
