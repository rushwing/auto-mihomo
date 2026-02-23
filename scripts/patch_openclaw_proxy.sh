#!/usr/bin/env bash
# =============================================================================
# patch_openclaw_proxy.sh - Sync proxy.env HTTP proxy into openclaw.json
#
# 读取 /etc/auto-mihomo/proxy.env 中的 http_proxy URL,
# 若 openclaw.json 已配置 channels.telegram, 则写入 proxy 字段并确保
# network.autoSelectFamily=false.
#
# 用法:
#   bash scripts/patch_openclaw_proxy.sh [proxy.env路径] [openclaw.json路径]
#
# 环境变量:
#   OPENCLAW_JSON  — openclaw.json 路径 (默认 ~/.openclaw/openclaw.json)
# =============================================================================
set -euo pipefail

PROXY_ENV="${1:-/etc/auto-mihomo/proxy.env}"
OPENCLAW_JSON="${2:-${OPENCLAW_JSON:-$HOME/.openclaw/openclaw.json}}"

log() { echo "[patch-openclaw] $*" >&2; }

if [[ ! -f "$PROXY_ENV" ]]; then
    log "proxy.env 不存在: $PROXY_ENV — 跳过"
    exit 0
fi

if [[ ! -f "$OPENCLAW_JSON" ]]; then
    log "openclaw.json 不存在: $OPENCLAW_JSON — 跳过"
    exit 0
fi

# 从 proxy.env 提取 http_proxy 值 (http_proxy= 或 HTTP_PROXY=, 取首个)
HTTP_PROXY_URL=$(grep -E '^(http_proxy|HTTP_PROXY)=' "$PROXY_ENV" | head -1 | cut -d= -f2-)

if [[ -z "$HTTP_PROXY_URL" ]]; then
    log "proxy.env 中未找到 http_proxy — 跳过"
    exit 0
fi

log "proxy.env HTTP 代理: $HTTP_PROXY_URL"
log "openclaw.json: $OPENCLAW_JSON"

python3 - "$OPENCLAW_JSON" "$HTTP_PROXY_URL" <<'PYEOF'
import sys, json

json_path = sys.argv[1]
proxy_url = sys.argv[2]

with open(json_path, 'r', encoding='utf-8') as f:
    config = json.load(f)

telegram = config.get('channels', {}).get('telegram')
if telegram is None:
    print("[patch-openclaw] channels.telegram 未配置, 跳过", file=sys.stderr)
    sys.exit(0)

old_proxy = telegram.get('proxy', '(none)')
telegram['proxy'] = proxy_url

# 确保 network.autoSelectFamily = false (避免 IPv6 干扰代理连接)
telegram.setdefault('network', {})['autoSelectFamily'] = False

with open(json_path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"[patch-openclaw] telegram proxy 已更新: {old_proxy!r} -> {proxy_url!r}", file=sys.stderr)
PYEOF
