#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_MJS="${OPENCLAW_MJS:-$HOME/.openclaw/openclaw.mjs}"
LOG_FILE="${PROJECT_DIR}/openclaw-startup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

has_stale_requires_unit() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl cat openclaw-gateway 2>/dev/null | grep -Eq '^[[:space:]]*Requires=.*\bmihomo\.service\b'
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

# systemd 已通过 EnvironmentFile 注入代理环境，这里额外 source 以兼容子进程环境。
if [[ -f /etc/profile.d/proxy.sh ]]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/proxy.sh
    log "startup: sourced /etc/profile.d/proxy.sh"
fi

log "startup: exec openclaw gateway"

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
log "startup: node → ${NODE_BIN}"
exec "$NODE_BIN" "$OPENCLAW_MJS" gateway
