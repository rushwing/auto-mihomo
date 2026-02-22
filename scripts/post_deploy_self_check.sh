#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

read_env_value() {
    local key="$1"
    local file="$2"
    awk -F= -v k="$key" '
        $0 ~ "^[[:space:]]*#" { next }
        $1 == k {
            sub(/^[^=]*=/, "", $0)
            print $0
            exit
        }
    ' "$file"
}

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }

FAILED=0

if [[ ! -f "$ENV_FILE" ]]; then
    fail ".env 不存在: $ENV_FILE"
    exit 1
fi

MIXED_PORT="$(read_env_value MIHOMO_MIXED_PORT "$ENV_FILE" || true)"
MIXED_PORT="${MIXED_PORT:-7893}"
MIHOMO_API_PORT="$(read_env_value MIHOMO_API_PORT "$ENV_FILE" || true)"
MIHOMO_API_PORT="${MIHOMO_API_PORT:-9090}"
MIHOMO_CONTROLLER_HOST="$(read_env_value MIHOMO_CONTROLLER_HOST "$ENV_FILE" || true)"
MIHOMO_CONTROLLER_HOST="${MIHOMO_CONTROLLER_HOST:-127.0.0.1}"
MIHOMO_API_SECRET="$(read_env_value MIHOMO_API_SECRET "$ENV_FILE" || true)"
MCP_SERVER_PORT="$(read_env_value MCP_SERVER_PORT "$ENV_FILE" || true)"
MCP_SERVER_PORT="${MCP_SERVER_PORT:-8900}"
MCP_SERVER_HOST="$(read_env_value MCP_SERVER_HOST "$ENV_FILE" || true)"
MCP_SERVER_HOST="${MCP_SERVER_HOST:-127.0.0.1}"
MCP_API_TOKEN="$(read_env_value MCP_API_TOKEN "$ENV_FILE" || true)"

check_service_active() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        pass "systemd 服务运行中: $svc"
    else
        fail "systemd 服务未运行: $svc"
        FAILED=1
    fi
}

check_openclaw_unit_safety() {
    if [[ ! -f /etc/systemd/system/openclaw-gateway.service ]]; then
        info "openclaw-gateway unit: 未安装, 跳过防呆检查"
        return
    fi

    if systemctl cat openclaw-gateway 2>/dev/null | grep -Eq '^[[:space:]]*Requires=.*\bmihomo\.service\b'; then
        fail "检测到旧版 openclaw-gateway unit 使用 Requires=mihomo.service (会导致重启循环)"
        echo "      处理方式: 重新执行 install.sh/upgrade.sh 后运行 sudo systemctl daemon-reload"
        FAILED=1
        return
    fi

    if systemctl cat openclaw-gateway 2>/dev/null | grep -Eq '^[[:space:]]*Wants=.*\bmihomo\.service\b'; then
        pass "openclaw-gateway unit 依赖关系正确 (Wants=mihomo.service)"
    else
        warn "未在 openclaw-gateway 生效 unit 中发现 Wants=mihomo.service，请确认模板已更新"
    fi
}

http_code() {
    curl -sS -o /dev/null -w '%{http_code}' "$@" || printf '000'
}

check_local_api() {
    local name="$1"
    local url="$2"
    shift 2
    local code
    code="$(http_code "$@" "$url")"
    if [[ "$code" == "200" || "$code" == "204" ]]; then
        pass "${name} 可用 (${code})"
    else
        fail "${name} 不可用 (HTTP ${code})"
        FAILED=1
    fi
}

check_proxy_target() {
    local name="$1"
    local url="$2"
    local expect_desc="$3"
    local code
    code="$(http_code \
        --connect-timeout 8 \
        --max-time 20 \
        -x "http://127.0.0.1:${MIXED_PORT}" \
        "$url")"

    if [[ "$code" == "000" ]]; then
        fail "代理链路失败: ${name} (${url}) -> HTTP 000"
        FAILED=1
        return
    fi

    pass "代理链路可达: ${name} (${url}) -> HTTP ${code} (${expect_desc})"
}

info "开始部署后自检 (project=${PROJECT_DIR})"

info "1) 检查关键服务"
check_service_active "mihomo"
check_service_active "auto-mihomo-mcp"
if [[ -f /etc/systemd/system/openclaw-gateway.service ]]; then
    check_service_active "openclaw-gateway"
else
    info "openclaw-gateway: 未安装, 跳过"
fi
check_openclaw_unit_safety

info "2) 检查本地监听接口"
MIHOMO_HEADERS=()
if [[ -n "$MIHOMO_API_SECRET" ]]; then
    MIHOMO_HEADERS+=( -H "Authorization: Bearer ${MIHOMO_API_SECRET}" )
fi
check_local_api "Mihomo /version" "http://${MIHOMO_CONTROLLER_HOST}:${MIHOMO_API_PORT}/version" "${MIHOMO_HEADERS[@]}"

MCP_HEADERS=()
if [[ -n "$MCP_API_TOKEN" ]]; then
    MCP_HEADERS+=( -H "Authorization: Bearer ${MCP_API_TOKEN}" )
fi
check_local_api "MCP /mcp/health" "http://${MCP_SERVER_HOST}:${MCP_SERVER_PORT}/mcp/health" "${MCP_HEADERS[@]}"

info "3) 检查代理链路 (通过 Mihomo mixed-port=${MIXED_PORT})"
check_proxy_target "Google 204" "http://www.gstatic.com/generate_204" "期望 204"
check_proxy_target "Google 首页" "https://www.google.com" "常见 200/301/302"
check_proxy_target "GitHub" "https://github.com" "常见 200/301/302"
check_proxy_target "Telegram API" "https://api.telegram.org" "常见 200/302/401/404"

info "4) 检查 OpenClaw 预加载代理日志 (最近 50 行)"
if [[ ! -f /etc/systemd/system/openclaw-gateway.service ]]; then
    info "openclaw-gateway 未安装, 跳过日志检查"
elif journalctl -u openclaw-gateway -n 50 --no-pager 2>/dev/null | grep -q "\[proxy-bootstrap\] patched"; then
    pass "OpenClaw 已加载 proxy-bootstrap.cjs"
else
    warn "未在 openclaw-gateway 最近日志中看到 proxy-bootstrap patched 日志（可能日志已滚动或启动较早）"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo
    fail "自检未通过，请查看:"
    echo "  sudo journalctl -u mihomo -n 100 --no-pager"
    echo "  sudo journalctl -u auto-mihomo-mcp -n 100 --no-pager"
    echo "  sudo journalctl -u openclaw-gateway -n 100 --no-pager"
    exit 1
fi

echo
pass "部署后自检通过"
