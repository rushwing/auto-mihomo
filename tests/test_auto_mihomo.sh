#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

sudo() {
    printf '<%s>\n' "$@"
}
export -f sudo

best_output=$(
    AUTO_MIHOMO_INSTALL_DIR="$REPO_DIR" \
        source "$REPO_DIR/auto_mihomo.sh" --best
)
[[ "$best_output" == $'<-u>\n<openclaw>\n<bash>\n<'"$REPO_DIR"$'/scripts/update_sub.sh>\n<--probe-strategy=best>' ]] \
    || fail "--best 参数转发错误: $best_output"

set_output=$(
    AUTO_MIHOMO_INSTALL_DIR="$REPO_DIR" \
        source "$REPO_DIR/auto_mihomo.sh" --set "美国 F"
)
[[ "$set_output" == $'<-u>\n<openclaw>\n<bash>\n<'"$REPO_DIR"$'/scripts/update_sub.sh>\n<--set>\n<美国 F>' ]] \
    || fail "--set 参数转发错误: $set_output"

printf 'export http_proxy="http://127.0.0.1:7893"\n' > "$TMP_DIR/proxy.sh"
set +u
AUTO_MIHOMO_PROXY_FILE="$TMP_DIR/proxy.sh" source "$REPO_DIR/auto_mihomo.sh" --current >/dev/null
[[ "${http_proxy:-}" == "http://127.0.0.1:7893" ]] || fail "--current 未应用代理变量"
[[ "$-" != *u* ]] || fail "--current 污染了调用者的 shell 选项"

if AUTO_MIHOMO_PROXY_FILE="$TMP_DIR/proxy.sh" bash "$REPO_DIR/auto_mihomo.sh" --current >/dev/null 2>&1; then
    fail "直接执行 --current 应该提示使用 source"
else
    status=$?
    [[ $status -eq 2 ]] || fail "直接执行 --current 应返回 2, 实际为 $status"
fi

echo "PASS: auto_mihomo.sh"
