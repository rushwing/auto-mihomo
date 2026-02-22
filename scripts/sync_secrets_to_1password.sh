#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
OP_VAULT=""
OP_ITEM=""

usage() {
    cat <<'EOF'
用法:
  bash scripts/sync_secrets_to_1password.sh --vault <VAULT> --item <ITEM>
  bash scripts/sync_secrets_to_1password.sh --vault auto-mihomo --item raspi-prod --env /path/to/.env

功能:
  从 .env 读取并同步以下字段到 1Password item:
    - MIHOMO_SUB_URL
    - MIHOMO_API_SECRET
    - MCP_API_TOKEN

要求:
  1) 已安装并登录 1Password CLI (`op`)
  2) 目标 item 已存在
  3) item 中字段标签建议使用环境变量同名:
     MIHOMO_SUB_URL, MIHOMO_API_SECRET, MCP_API_TOKEN

说明:
  脚本会优先尝试用同名字段标签更新；若 item 没有对应字段，op 会报错。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault)
            OP_VAULT="${2:?缺少 vault 名称}"
            shift 2
            ;;
        --item)
            OP_ITEM="${2:?缺少 item 名称或ID}"
            shift 2
            ;;
        --env)
            ENV_FILE="${2:?缺少 .env 路径}"
            shift 2
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

if [[ -z "$OP_VAULT" || -z "$OP_ITEM" ]]; then
    echo "错误: 必须提供 --vault 和 --item" >&2
    usage >&2
    exit 1
fi

if ! command -v op >/dev/null 2>&1; then
    echo "错误: 未找到 1Password CLI 'op'" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "错误: .env 文件不存在: $ENV_FILE" >&2
    exit 1
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

MIHOMO_SUB_URL="$(read_env_value MIHOMO_SUB_URL || true)"
MIHOMO_API_SECRET="$(read_env_value MIHOMO_API_SECRET || true)"
MCP_API_TOKEN="$(read_env_value MCP_API_TOKEN || true)"

for key in MIHOMO_SUB_URL MIHOMO_API_SECRET MCP_API_TOKEN; do
    if [[ -z "${!key:-}" ]]; then
        echo "错误: $key 在 $ENV_FILE 中为空或不存在" >&2
        exit 1
    fi
done

# 检查 item 是否存在（也顺便验证登录态）
if ! op item get "$OP_ITEM" --vault "$OP_VAULT" >/dev/null 2>&1; then
    echo "错误: 无法读取 1Password item (请确认已登录、vault/item 存在): vault=$OP_VAULT item=$OP_ITEM" >&2
    exit 1
fi

echo "同步到 1Password: vault=$OP_VAULT item=$OP_ITEM"

op item edit "$OP_ITEM" \
    --vault "$OP_VAULT" \
    "MIHOMO_SUB_URL[text]=$MIHOMO_SUB_URL" \
    "MIHOMO_API_SECRET[password]=$MIHOMO_API_SECRET" \
    "MCP_API_TOKEN[password]=$MCP_API_TOKEN" \
    >/dev/null

echo "同步完成: MIHOMO_SUB_URL, MIHOMO_API_SECRET, MCP_API_TOKEN"
