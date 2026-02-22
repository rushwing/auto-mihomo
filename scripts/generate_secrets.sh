#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
WRITE_ENV=false

usage() {
    cat <<'EOF'
用法:
  bash scripts/generate_secrets.sh
  bash scripts/generate_secrets.sh --write-env
  bash scripts/generate_secrets.sh --env /path/to/.env --write-env

功能:
  - 生成 MIHOMO_API_SECRET 和 MCP_API_TOKEN 随机字符串
  - 可选写入 .env (若变量存在则覆盖，不存在则追加)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --write-env)
            WRITE_ENV=true
            shift
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

rand_token() {
    # URL-safe token，适合放 .env / HTTP Header
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr '+/' '-_' | tr -d '=' | tr -d '\n'
    else
        python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
    fi
}

set_env_kv() {
    local file="$1"
    local key="$2"
    local value="$3"

    touch "$file"
    if grep -qE "^${key}=" "$file"; then
        # macOS / GNU sed 兼容写法：先生成临时文件
        local tmp="${file}.tmp.$$"
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ ("^" k "=") && done == 0 { print k "=" v; done = 1; next }
            { print }
            END { if (done == 0) print k "=" v }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

MIHOMO_API_SECRET="$(rand_token)"
MCP_API_TOKEN="$(rand_token)"

echo "MIHOMO_API_SECRET=${MIHOMO_API_SECRET}"
echo "MCP_API_TOKEN=${MCP_API_TOKEN}"

if [[ "$WRITE_ENV" == "true" ]]; then
    set_env_kv "$ENV_FILE" "MIHOMO_API_SECRET" "$MIHOMO_API_SECRET"
    set_env_kv "$ENV_FILE" "MCP_API_TOKEN" "$MCP_API_TOKEN"
    echo ""
    echo "已写入: ${ENV_FILE}"
fi
