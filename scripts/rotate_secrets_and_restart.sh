#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
VAULT=""
ITEM=""
SKIP_SYNC=false
SKIP_RESTART=false
SKIP_HEALTH=false

usage() {
    cat <<'EOF'
用法:
  bash scripts/rotate_secrets_and_restart.sh --vault <VAULT> --item <ITEM>
  bash scripts/rotate_secrets_and_restart.sh --vault auto-mihomo --item raspi-prod --env /path/to/.env
  bash scripts/rotate_secrets_and_restart.sh --skip-sync --skip-restart

功能:
  1) 生成新的 MIHOMO_API_SECRET / MCP_API_TOKEN 并写入 .env
  2) (可选) 同步到 1Password
  3) 重启 mihomo / auto-mihomo-mcp / openclaw-gateway
  4) (可选) 使用新 MCP token 做本地健康检查

选项:
  --vault <VAULT>      1Password vault 名称 (不传且未 --skip-sync 时会报错)
  --item <ITEM>        1Password item 名称或ID (不传且未 --skip-sync 时会报错)
  --env <PATH>         指定 .env 路径 (默认: 项目根目录 .env)
  --skip-sync          不同步到 1Password
  --skip-restart       不重启服务
  --skip-health        不做 MCP 健康检查
  -h, --help           显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault)
            VAULT="${2:?缺少 vault 名称}"
            shift 2
            ;;
        --item)
            ITEM="${2:?缺少 item 名称或ID}"
            shift 2
            ;;
        --env)
            ENV_FILE="${2:?缺少 .env 路径}"
            shift 2
            ;;
        --skip-sync)
            SKIP_SYNC=true
            shift
            ;;
        --skip-restart)
            SKIP_RESTART=true
            shift
            ;;
        --skip-health)
            SKIP_HEALTH=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$SKIP_SYNC" != "true" && ( -z "$VAULT" || -z "$ITEM" ) ]]; then
    echo "错误: 未使用 --skip-sync 时必须提供 --vault 和 --item" >&2
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/generate_secrets.sh" ]]; then
    echo "错误: 缺少脚本 ${SCRIPT_DIR}/generate_secrets.sh" >&2
    exit 1
fi

if [[ "$SKIP_SYNC" != "true" && ! -f "${SCRIPT_DIR}/sync_secrets_to_1password.sh" ]]; then
    echo "错误: 缺少脚本 ${SCRIPT_DIR}/sync_secrets_to_1password.sh" >&2
    exit 1
fi

echo "[1/4] 生成并写入 .env: ${ENV_FILE}"
bash "${SCRIPT_DIR}/generate_secrets.sh" --env "$ENV_FILE" --write-env

if [[ "$SKIP_SYNC" == "true" ]]; then
    echo "[2/4] 跳过 1Password 同步 (--skip-sync)"
else
    echo "[2/4] 同步到 1Password (vault=${VAULT}, item=${ITEM})"
    bash "${SCRIPT_DIR}/sync_secrets_to_1password.sh" --vault "$VAULT" --item "$ITEM" --env "$ENV_FILE"
fi

if [[ "$SKIP_RESTART" == "true" ]]; then
    echo "[3/4] 跳过服务重启 (--skip-restart)"
else
    echo "[3/4] 重启服务: mihomo / auto-mihomo-mcp / openclaw-gateway"
    sudo systemctl restart mihomo
    sudo systemctl restart auto-mihomo-mcp
    sudo systemctl restart openclaw-gateway
fi

if [[ "$SKIP_HEALTH" == "true" ]]; then
    echo "[4/4] 跳过健康检查 (--skip-health)"
    exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[4/4] 未找到 .env，跳过健康检查"
    exit 0
fi

read_env_value() {
    local key="$1"
    awk -F= -v k="$key" '
        $0 ~ "^[[:space:]]*#" { next }
        $1 == k {
            sub(/^[^=]*=/, "", $0)
            print $0
            exit
        }
    ' "$ENV_FILE"
}

MCP_SERVER_HOST="$(read_env_value MCP_SERVER_HOST || true)"
MCP_SERVER_PORT="$(read_env_value MCP_SERVER_PORT || true)"
MCP_API_TOKEN="$(read_env_value MCP_API_TOKEN || true)"

MCP_SERVER_HOST="${MCP_SERVER_HOST:-127.0.0.1}"
MCP_SERVER_PORT="${MCP_SERVER_PORT:-8900}"

echo "[4/4] MCP 健康检查: http://${MCP_SERVER_HOST}:${MCP_SERVER_PORT}/mcp/health"

curl_args=( -sS --max-time 8 "http://${MCP_SERVER_HOST}:${MCP_SERVER_PORT}/mcp/health" )
if [[ -n "$MCP_API_TOKEN" ]]; then
    curl_args=( -sS --max-time 8 -H "Authorization: Bearer ${MCP_API_TOKEN}" "http://${MCP_SERVER_HOST}:${MCP_SERVER_PORT}/mcp/health" )
fi

if ! curl "${curl_args[@]}"; then
    echo
    echo "健康检查失败，请查看日志:"
    echo "  sudo journalctl -u mihomo -n 50 --no-pager"
    echo "  sudo journalctl -u auto-mihomo-mcp -n 50 --no-pager"
    echo "  sudo journalctl -u openclaw-gateway -n 50 --no-pager"
    exit 1
fi

echo
echo "轮换完成"
