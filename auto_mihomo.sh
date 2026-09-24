#!/usr/bin/env bash
# auto_mihomo.sh - Auto-Mihomo 常用操作的单一入口
IS_SOURCED=false
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    IS_SOURCED=true
else
    set -euo pipefail
fi

INSTALL_DIR="${AUTO_MIHOMO_INSTALL_DIR:-/opt/auto-mihomo}"
UPDATE_SCRIPT="${INSTALL_DIR}/scripts/update_sub.sh"
SERVICE_USER="${AUTO_MIHOMO_SERVICE_USER:-openclaw}"
PROXY_FILE="${AUTO_MIHOMO_PROXY_FILE:-/etc/profile.d/proxy.sh}"

usage() {
    cat <<'EOF'
用法:
  auto_mihomo.sh --best
  auto_mihomo.sh --set "节点名称"
  source auto_mihomo.sh --current

选项:
  --best          探测所有候选节点并选择 HTTP 延迟最低者
  --set NAME      跳过自动探测, 强制使用订阅中名称完全匹配的节点
  --current       将已生成的代理环境变量应用到当前 shell
  -h, --help      显示帮助
EOF
}

run_update() {
    if [[ ! -f "$UPDATE_SCRIPT" ]]; then
        echo "错误: 找不到更新脚本: ${UPDATE_SCRIPT}" >&2
        return 1
    fi
    sudo -u "$SERVICE_USER" bash "$UPDATE_SCRIPT" "$@"
}

apply_current_proxy() {
    if [[ ! -r "$PROXY_FILE" ]]; then
        echo "错误: 代理环境文件不存在或不可读: ${PROXY_FILE}" >&2
        echo "请先运行 auto_mihomo.sh --best 或 auto_mihomo.sh --set \"节点名称\"" >&2
        return 1
    fi

    if [[ "$IS_SOURCED" != "true" ]]; then
        echo "错误: --current 需要修改当前 shell 的环境变量, 请使用:" >&2
        printf '  source %q --current\n' "$0" >&2
        return 2
    fi

    # shellcheck source=/dev/null
    source "$PROXY_FILE"
    echo "当前 shell 已应用 Auto-Mihomo 代理: ${http_proxy:-${HTTP_PROXY:-}}"
}

case "${1:-}" in
    --best)
        [[ $# -eq 1 ]] || { echo "错误: --best 不接受其他参数" >&2; usage >&2; exit 2; }
        run_update --probe-strategy=best
        ;;
    --set)
        [[ $# -eq 2 && -n "$2" ]] || { echo "错误: --set 需要一个非空节点名称" >&2; usage >&2; exit 2; }
        run_update --set "$2"
        ;;
    --current)
        [[ $# -eq 1 ]] || { echo "错误: --current 不接受其他参数" >&2; usage >&2; return 2 2>/dev/null || exit 2; }
        apply_current_proxy
        ;;
    -h|--help)
        usage
        ;;
    "")
        usage >&2
        return 2 2>/dev/null || exit 2
        ;;
    *)
        echo "错误: 未知参数: $1" >&2
        usage >&2
        return 2 2>/dev/null || exit 2
        ;;
esac
