#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_NJS="${OPENCLAW_NJS:-$HOME/.openclaw/openclaw.njs}"
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
exec node "$OPENCLAW_NJS" gateway
