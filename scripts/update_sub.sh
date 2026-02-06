#!/usr/bin/env bash
# =============================================================================
# update_sub.sh - 自动更新 Mihomo 订阅、测试节点、生成配置并重启服务
#
# 功能:
#   1. 下载 Clash 订阅
#   2. 并发测试所有节点延迟 (委托 test_nodes.py)
#   3. 生成 Mihomo 配置文件 (委托 generate_config.py)
#   4. 重启 Mihomo 服务
#   5. 设置系统代理环境变量
#
# 用法:
#   bash scripts/update_sub.sh
#   bash scripts/update_sub.sh --skip-proxy   # 跳过系统代理设置
# =============================================================================
set -euo pipefail

# ===== 路径 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ===== 加载环境变量 =====
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/.env"
    set +a
fi

# ===== 配置 =====
SUB_URL="${MIHOMO_SUB_URL:?错误: 请在 .env 中设置 MIHOMO_SUB_URL}"
MIHOMO_BIN="${MIHOMO_BIN:-/opt/mihomo/mihomo}"
MIHOMO_HOME="${MIHOMO_HOME:-/opt/mihomo}"
MIXED_PORT="${MIHOMO_MIXED_PORT:-7893}"
API_PORT="${MIHOMO_API_PORT:-9090}"
MAX_WORKERS="${MIHOMO_TEST_WORKERS:-50}"
TCP_TIMEOUT="${MIHOMO_TCP_TIMEOUT:-3}"

SUB_FILE="${PROJECT_DIR}/subscription.yaml"
CONFIG_FILE="${PROJECT_DIR}/config.yaml"
LOG_FILE="${PROJECT_DIR}/update.log"

SKIP_PROXY=false
[[ "${1:-}" == "--skip-proxy" ]] && SKIP_PROXY=true

# ===== 日志 =====
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$LOG_FILE"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ===== 激活 Python 虚拟环境 (uv 默认 .venv) =====
if [[ -f "${PROJECT_DIR}/.venv/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/.venv/bin/activate"
fi

# ===== 1. 下载订阅 =====
download_subscription() {
    log_info "正在下载订阅..."

    local tmp_file="${SUB_FILE}.tmp"
    local http_code
    http_code=$(curl -sL -w '%{http_code}' -o "$tmp_file" \
        --connect-timeout 15 \
        --max-time 60 \
        --retry 3 \
        --retry-delay 5 \
        -H "User-Agent: clash-meta" \
        "$SUB_URL")

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmp_file"
        log_error "下载订阅失败, HTTP 状态码: ${http_code}"
        return 1
    fi

    # 校验文件是否为有效 YAML 且包含 proxies
    if ! python3 -c "
import yaml, sys
with open('${tmp_file}') as f:
    d = yaml.safe_load(f)
if not d or not d.get('proxies'):
    sys.exit(1)
" 2>/dev/null; then
        rm -f "$tmp_file"
        log_error "订阅内容无效 (不包含 proxies 字段)"
        return 1
    fi

    mv "$tmp_file" "$SUB_FILE"
    local count
    count=$(python3 -c "
import yaml
with open('${SUB_FILE}') as f:
    d = yaml.safe_load(f)
print(len(d.get('proxies', [])))
")
    log_info "订阅下载完成, 共 ${count} 个节点"
}

# ===== 2. 测试节点延迟 =====
test_nodes() {
    log_info "开始并发测试节点延迟 (workers=${MAX_WORKERS}, timeout=${TCP_TIMEOUT}s)..."

    local best_node
    best_node=$(python3 "${SCRIPT_DIR}/test_nodes.py" \
        --subscription "$SUB_FILE" \
        --workers "$MAX_WORKERS" \
        --timeout "$TCP_TIMEOUT" \
        2> >(tee -a "$LOG_FILE" >&2))

    if [[ -z "$best_node" ]]; then
        log_error "无法确定最快节点"
        return 1
    fi

    log_info "最快节点: ${best_node}"
    echo "$best_node"
}

# ===== 3. 生成配置 =====
generate_config() {
    local best_node="$1"
    log_info "正在生成 Mihomo 配置..."

    python3 "${SCRIPT_DIR}/generate_config.py" \
        --subscription "$SUB_FILE" \
        --output "$CONFIG_FILE" \
        --best-node "$best_node" \
        --mixed-port "$MIXED_PORT" \
        --api-port "$API_PORT"

    log_info "配置文件已生成: ${CONFIG_FILE}"
}

# ===== 4. 重载 Mihomo 配置 =====
reload_mihomo() {
    log_info "正在重载 Mihomo 配置..."

    # 方式 1: 通过 Mihomo RESTful API 热重载 (无需 root 权限)
    #   PUT /configs 让 Mihomo 重新加载配置文件, 无需重启进程
    local api_url="http://127.0.0.1:${API_PORT}"

    if curl -s --max-time 3 "${api_url}/version" &>/dev/null; then
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -X PUT "${api_url}/configs" \
            -H "Content-Type: application/json" \
            -d "{\"path\": \"${CONFIG_FILE}\"}" \
            --max-time 10)

        if [[ "$http_code" == "204" ]]; then
            log_info "Mihomo 配置已通过 API 热重载"
            return 0
        else
            log_warn "API 热重载失败 (HTTP ${http_code}), 尝试 systemd 重启..."
        fi
    else
        log_warn "Mihomo API 不可达, 尝试 systemd 启动..."
    fi

    # 方式 2: 通过 systemd 重启 (需要 sudoers NOPASSWD 或 polkit 策略)
    if command -v systemctl &>/dev/null && systemctl list-unit-files mihomo.service &>/dev/null; then
        sudo systemctl restart mihomo
        sleep 2
        if systemctl is-active --quiet mihomo; then
            log_info "Mihomo 已通过 systemd 重启"
            return 0
        else
            log_error "Mihomo systemd 服务启动失败"
            systemctl status mihomo --no-pager 2>&1 | tail -5 | tee -a "$LOG_FILE" >&2
            return 1
        fi
    fi

    # 方式 3: 直接启动 (首次运行 or 无 systemd 环境)
    log_warn "使用直接启动方式..."

    if [[ ! -x "$MIHOMO_BIN" ]]; then
        log_error "Mihomo 二进制不存在或无执行权限: ${MIHOMO_BIN}"
        return 1
    fi

    pkill -f "mihomo" 2>/dev/null || true
    sleep 1

    nohup "$MIHOMO_BIN" -d "$MIHOMO_HOME" -f "$CONFIG_FILE" \
        >> "${PROJECT_DIR}/mihomo.log" 2>&1 &
    local pid=$!
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        log_info "Mihomo 已直接启动 (PID: ${pid})"
    else
        log_error "Mihomo 启动失败"
        return 1
    fi
}

# ===== 5. 设置系统代理 =====
setup_proxy() {
    if [[ "$SKIP_PROXY" == "true" ]]; then
        log_info "跳过系统代理设置 (--skip-proxy)"
        return 0
    fi

    log_info "正在设置系统代理..."

    # proxy.sh 在 install.sh 中已由 root 创建并 chown 给服务用户,
    # 此处直接写入, 无需 sudo
    local proxy_file="/etc/profile.d/proxy.sh"

    if [[ ! -w "$proxy_file" ]]; then
        log_warn "${proxy_file} 不可写, 跳过系统代理 (请运行 install.sh 修复权限)"
        return 0
    fi

    cat > "$proxy_file" <<PROXY_EOF
# Auto-Mihomo 系统代理配置 (自动生成, 请勿手动修改)
export http_proxy="http://127.0.0.1:${MIXED_PORT}"
export https_proxy="http://127.0.0.1:${MIXED_PORT}"
export all_proxy="socks5://127.0.0.1:${MIXED_PORT}"
export HTTP_PROXY="http://127.0.0.1:${MIXED_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${MIXED_PORT}"
export ALL_PROXY="socks5://127.0.0.1:${MIXED_PORT}"
export no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
PROXY_EOF

    log_info "系统代理已设置 (mixed-port: ${MIXED_PORT})"
    log_info "运行 'source /etc/profile.d/proxy.sh' 使当前终端生效"
}

# ===== 6. 验证代理 =====
verify_proxy() {
    log_info "正在验证代理连通性..."
    sleep 1

    local test_url="http://www.gstatic.com/generate_204"
    local http_code
    http_code=$(curl -sL -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 \
        --max-time 15 \
        -x "http://127.0.0.1:${MIXED_PORT}" \
        "$test_url" 2>/dev/null) || true

    if [[ "$http_code" == "204" ]]; then
        log_info "代理验证通过 (204 No Content)"
    else
        log_warn "代理验证未通过 (HTTP ${http_code}), 请手动检查"
    fi
}

# ===== 主流程 =====
main() {
    log_info "========== 开始更新订阅 =========="

    # 确保工作目录存在
    mkdir -p "$MIHOMO_HOME"

    # Step 1: 下载订阅
    download_subscription || { log_error "下载订阅失败, 中止"; exit 1; }

    # Step 2: 测试节点
    local best_node
    best_node=$(test_nodes) || { log_error "节点测试失败, 中止"; exit 1; }

    # Step 3: 生成配置
    generate_config "$best_node" || { log_error "生成配置失败, 中止"; exit 1; }

    # Step 4: 重载 Mihomo
    reload_mihomo || { log_error "重载 Mihomo 失败, 中止"; exit 1; }

    # Step 5: 设置系统代理
    setup_proxy

    # Step 6: 验证
    verify_proxy

    log_info "========== 更新完成 =========="
}

main "$@"
