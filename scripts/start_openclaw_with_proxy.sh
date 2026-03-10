#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_APP_DIR="${OPENCLAW_APP_DIR:-$HOME/.openclaw}"
OPENCLAW_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
LOG_FILE="${PROJECT_DIR}/openclaw-startup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_warn() {
    log "WARN: $*"
    echo "[auto-mihomo] WARN: $*" >&2
}

log_error() {
    log "ERROR: $*"
    echo "[auto-mihomo] ERROR: $*" >&2
}

has_stale_requires_unit() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl cat openclaw-gateway 2>/dev/null | grep -Eq '^[[:space:]]*Requires=.*\bmihomo\.service\b'
}

reload_proxy_env() {
    local proxy_env="/etc/auto-mihomo/proxy.env"
    if [[ ! -f "$proxy_env" ]]; then
        return 0
    fi
    set -a
    # shellcheck source=/dev/null
    source "$proxy_env"
    set +a
    log "startup: sourced ${proxy_env}"
}

resolve_openclaw_entry() {
    local candidate=""

    for candidate in \
        "${OPENCLAW_ENTRY:-}" \
        "${OPENCLAW_MJS:-}" \
        "${OPENCLAW_APP_DIR}/dist/index.js" \
        "${OPENCLAW_APP_DIR}/openclaw.mjs"; do
        [[ -n "$candidate" && -f "$candidate" ]] && printf '%s\n' "$candidate" && return 0
    done

    return 1
}

cd "$PROJECT_DIR"

if has_stale_requires_unit; then
    log "startup: detected stale openclaw-gateway systemd unit (Requires=mihomo.service)"
    log "startup: skip update_sub.sh to avoid restart loop; run install.sh/upgrade.sh and systemctl daemon-reload to fix"
else
    log "startup: begin update_sub.sh"
    if bash "${PROJECT_DIR}/scripts/update_sub.sh"; then
        log "startup: update_sub.sh success"
    else
        log "startup: update_sub.sh failed, continue with existing config"
    fi
fi

reload_proxy_env

# Resolve the node binary: systemd PATH may not include nvm's bin dir.
# install.sh injects the correct PATH via Environment=; this fallback
# handles manual invocations or installs that pre-date the PATH injection.
_find_node() {
    # 1. Already on PATH (covers services with proper Environment=PATH and SSH sessions)
    if command -v node &>/dev/null; then
        command -v node; return 0
    fi
    # 2. nvm: scan for the newest installed version
    if [[ -d "$HOME/.nvm/versions/node" ]]; then
        local p
        p=$(find "$HOME/.nvm/versions/node" -maxdepth 3 -name node -type f 2>/dev/null \
            | sort -rV | head -1)
        [[ -n "$p" ]] && echo "$p" && return 0
    fi
    # 3. Common static paths
    local s
    for s in /usr/local/bin/node /usr/bin/node; do
        [[ -x "$s" ]] && echo "$s" && return 0
    done
    return 1
}

NODE_BIN=$(_find_node) || { log "startup: ERROR: node not found in PATH or ~/.nvm"; exit 1; }
OPENCLAW_ENTRY=$(resolve_openclaw_entry) || {
    log_error "cannot find OpenClaw entrypoint under ${OPENCLAW_APP_DIR}"
    exit 1
}

cd "$OPENCLAW_APP_DIR"
log "startup: node → ${NODE_BIN}"
log "startup: entry → ${OPENCLAW_ENTRY}"
log "startup: cwd → ${OPENCLAW_APP_DIR}"

# Preload proxy-bootstrap.cjs so undici's global dispatcher is upgraded to
# EnvHttpProxyAgent before OpenClaw makes any fetch calls.
# Upstream PR openclaw/openclaw#42320 (not yet in v2026.3.7) would make this
# unnecessary; until it merges we must inject it ourselves via NODE_OPTIONS.
BOOTSTRAP="${SCRIPT_DIR}/proxy-bootstrap.cjs"
if [[ -f "$BOOTSTRAP" ]]; then
    export NODE_OPTIONS="-r ${BOOTSTRAP}${NODE_OPTIONS:+ ${NODE_OPTIONS}}"
    log "startup: NODE_OPTIONS → ${NODE_OPTIONS}"
fi

log "startup: exec openclaw gateway --port ${OPENCLAW_PORT}"
exec "$NODE_BIN" "$OPENCLAW_ENTRY" gateway --port "$OPENCLAW_PORT"
