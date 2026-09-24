#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: Linux-specific build_package smoke test"
    exit 0
fi

# Stop before any real copy/network work. curl writes a deliberately truncated archive.
rsync() {
    return 0
}

curl() {
    local previous=""
    local argument
    for argument in "$@"; do
        if [[ "$previous" == "--output" ]]; then
            printf 'truncated-gzip' > "$argument"
            return 0
        fi
        previous="$argument"
    done
    return 1
}

export -f rsync curl

if bash "$REPO_DIR/build_package.sh" --arch amd64 >"$OUTPUT_FILE" 2>&1; then
    fail "build should reject a truncated Mihomo archive"
else
    status=$?
fi

[[ $status -eq 1 ]] || fail "expected exit 1, got $status"
grep -q '构建平台:     Linux (tar)' "$OUTPUT_FILE" \
    || fail "Linux platform did not select GNU tar"
grep -q 'Mihomo 压缩包不完整或格式无效' "$OUTPUT_FILE" \
    || fail "corrupt archive error was not reported"

echo "PASS: build_package.sh Linux platform and gzip validation"
