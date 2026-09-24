#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/scripts/manage_login_proxy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

managed="$TMP_DIR/managed.sh"
cat > "$managed" <<'EOF'
# Auto-Mihomo 系统代理配置 (自动生成, 请勿手动修改)
export HTTP_PROXY=http://127.0.0.1:7893
EOF

bash "$HELPER" disable "$managed"
! grep -q '^export ' "$managed" || fail "managed exports were not cleared"
grep -q '^# Auto-Mihomo login-shell proxy disabled' "$managed" \
    || fail "disabled marker missing"

bash "$HELPER" enable "$managed" 17890
grep -q '^export HTTP_PROXY="http://127.0.0.1:17890"$' "$managed" \
    || fail "enable did not write requested port"

unmanaged="$TMP_DIR/unmanaged.sh"
printf 'export CUSTOM_PROXY=keep-me\n' > "$unmanaged"
if bash "$HELPER" disable "$unmanaged"; then
    fail "unmanaged file should not be overwritten"
else
    status=$?
fi
[[ $status -eq 3 ]] || fail "unmanaged file returned $status instead of 3"
grep -q '^export CUSTOM_PROXY=keep-me$' "$unmanaged" \
    || fail "unmanaged content was changed"

if bash "$HELPER" enable "$unmanaged" 7893; then
    fail "enable should not overwrite an unmanaged file"
else
    status=$?
fi
[[ $status -eq 3 ]] || fail "unmanaged enable returned $status instead of 3"
grep -q '^export CUSTOM_PROXY=keep-me$' "$unmanaged" \
    || fail "enable changed unmanaged content"

echo "PASS: manage_login_proxy.sh"
