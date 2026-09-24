#!/usr/bin/env bash
# Manage the Auto-Mihomo-owned login-shell proxy file without touching user-owned content.
set -euo pipefail

usage() {
    echo "Usage: manage_login_proxy.sh enable <file> <mixed-port> | disable <file>" >&2
    exit 2
}

is_managed_file() {
    local proxy_file="$1"
    [[ ! -s "$proxy_file" ]] \
        || grep -qE '^# Auto-Mihomo (system proxy configuration|login-shell proxy disabled|系统代理配置)' "$proxy_file"
}

enable_proxy() {
    local proxy_file="$1" mixed_port="$2"
    [[ -w "$proxy_file" ]] || return 2
    is_managed_file "$proxy_file" || return 3

    cat > "$proxy_file" <<PROXY_EOF
# Auto-Mihomo system proxy configuration (managed file)
export http_proxy="http://127.0.0.1:${mixed_port}"
export https_proxy="http://127.0.0.1:${mixed_port}"
export all_proxy="socks5://127.0.0.1:${mixed_port}"
export HTTP_PROXY="http://127.0.0.1:${mixed_port}"
export HTTPS_PROXY="http://127.0.0.1:${mixed_port}"
export ALL_PROXY="socks5://127.0.0.1:${mixed_port}"
export no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
PROXY_EOF
}

disable_proxy() {
    local proxy_file="$1"
    [[ -e "$proxy_file" ]] || return 0
    [[ -w "$proxy_file" ]] || return 2
    is_managed_file "$proxy_file" || return 3

    cat > "$proxy_file" <<'PROXY_EOF'
# Auto-Mihomo login-shell proxy disabled (managed file)
# The host stays DIRECT. Use proxy-run <command> or source auto_mihomo.sh --current.
PROXY_EOF
}

case "${1:-}" in
    enable)
        [[ $# -eq 3 && -n "$3" ]] || usage
        enable_proxy "$2" "$3"
        ;;
    disable)
        [[ $# -eq 2 ]] || usage
        disable_proxy "$2"
        ;;
    *)
        usage
        ;;
esac
