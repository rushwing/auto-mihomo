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
API_HOST="${MIHOMO_CONTROLLER_HOST:-127.0.0.1}"
API_SECRET="${MIHOMO_API_SECRET:-}"
PROXY_MODE="${AUTO_MIHOMO_PROXY_MODE:-process-proxy}"
HTTP_PROBE_URL="${MIHOMO_HTTP_PROBE_URL:-http://www.gstatic.com/generate_204}"
HTTP_PROBE_TIMEOUT="${MIHOMO_HTTP_PROBE_TIMEOUT:-12}"
MIHOMO_TEST_WORKERS="${MIHOMO_TEST_WORKERS:-50}"
MIHOMO_PROBE_TOP_N="${MIHOMO_PROBE_TOP_N:-10}"

SUB_FILE="${PROJECT_DIR}/subscription.yaml"
CONFIG_FILE="${PROJECT_DIR}/config.yaml"
LOG_FILE="${PROJECT_DIR}/update.log"

SKIP_PROXY=false
# PROBE_STRATEGY: first-success = stop at first passing node (fast, for startup/restart)
#                 best          = probe all candidates, pick lowest HTTP latency (for cron)
PROBE_STRATEGY="first-success"
for _arg in "$@"; do
    [[ "$_arg" == "--skip-proxy" ]]          && SKIP_PROXY=true
    [[ "$_arg" == "--probe-strategy=best" ]] && PROBE_STRATEGY="best"
done
unset _arg

# ===== 日志 =====
log() {
    local level="$1"; shift
    # >&2: log lines go to stderr so $() captures of functions only get their return value
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$LOG_FILE" >&2
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

mihomo_auth_header_args() {
    if [[ -n "$API_SECRET" ]]; then
        printf '%s\n' "-H" "Authorization: Bearer ${API_SECRET}"
    fi
}

mihomo_curl() {
    local args=()
    while IFS= read -r line; do
        args+=("$line")
    done < <(mihomo_auth_header_args)
    curl "${args[@]}" "$@"
}

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

    # 先尝试直连 (绕过代理), 因为代理可能未启动或配置错误
    # 订阅提供商通常可直连访问, 不需要代理
    http_code=$(curl -sL -w '%{http_code}' -o "$tmp_file" \
        --noproxy '*' \
        --connect-timeout 15 \
        --max-time 60 \
        --retry 3 \
        --retry-delay 5 \
        -H "User-Agent: clash-meta" \
        "$SUB_URL")

    # 直连失败则尝试通过代理下载 (订阅地址可能在境外)
    if [[ "$http_code" != "200" ]]; then
        log_warn "直连下载失败 (HTTP ${http_code}), 尝试通过代理..."
        http_code=$(curl -sL -w '%{http_code}' -o "$tmp_file" \
            --connect-timeout 15 \
            --max-time 60 \
            --retry 2 \
            --retry-delay 3 \
            -H "User-Agent: clash-meta" \
            "$SUB_URL")
    fi

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
get_first_node_name() {
    python3 -c "
import yaml, sys
with open('${SUB_FILE}', encoding='utf-8') as f:
    d = yaml.safe_load(f) or {}
proxies = d.get('proxies') or []
if not proxies:
    sys.exit(1)
print(proxies[0].get('name', ''))
"
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
        --api-port "$API_PORT" \
        --controller-host "$API_HOST" \
        --api-secret "$API_SECRET" \
        --proxy-mode "$PROXY_MODE"

    log_info "配置文件已生成: ${CONFIG_FILE}"
}

# ===== 4. 重载 Mihomo 配置 =====
reload_mihomo() {
    log_info "正在重载 Mihomo 配置..."

    # 方式 1: 通过 Mihomo RESTful API 热重载 (无需 root 权限)
    #   PUT /configs 让 Mihomo 重新加载配置文件, 无需重启进程
    local api_url="http://${API_HOST}:${API_PORT}"

    if mihomo_curl -s --max-time 3 "${api_url}/version" &>/dev/null; then
        local http_code
        http_code=$(mihomo_curl -s -o /dev/null -w '%{http_code}' \
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

# ===== 5a. TCP 并发预筛选 — 返回延迟最低的前 N 个节点名称 =====
tcp_prefilter_nodes() {
    log_info "TCP 预筛选节点 (workers=${MIHOMO_TEST_WORKERS}, top=${MIHOMO_PROBE_TOP_N})..."
    python3 "${SCRIPT_DIR}/test_nodes.py" \
        --subscription "$SUB_FILE" \
        --workers "$MIHOMO_TEST_WORKERS" \
        --top-n "$MIHOMO_PROBE_TOP_N" \
        --timeout 3
}

# ===== 5b. 通过 Mihomo 实际 HTTP 探测选择节点 =====
# 参数 $1 (可选): 换行分隔的候选节点名称; 为空则探测订阅中所有节点
probe_and_select_best_node() {
    local node_shortlist="${1:-}"

    # 仅在 process-proxy 模式下使用本机 mixed-port 做服务级探测
    if [[ "$PROXY_MODE" != "process-proxy" ]]; then
        log_warn "当前模式为 ${PROXY_MODE}; 跳过 process-proxy HTTP 探测选节点"
        return 0
    fi

    local api_url="http://${API_HOST}:${API_PORT}"
    local best_node=""
    local best_ms=999999
    local node total tested
    total=0
    tested=0

    if [[ -n "$node_shortlist" ]]; then
        local count
        count=$(printf '%s\n' "$node_shortlist" | grep -c '.' || true)
        log_info "开始 HTTP 探测候选节点 ${count} 个 (策略=${PROBE_STRATEGY}, url=${HTTP_PROBE_URL}, timeout=${HTTP_PROBE_TIMEOUT}s)..."
    else
        log_info "开始 HTTP 探测所有节点 (策略=${PROBE_STRATEGY}, url=${HTTP_PROBE_URL}, timeout=${HTTP_PROBE_TIMEOUT}s)..."
    fi

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        total=$((total + 1))

        local payload
        payload=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}, ensure_ascii=False))' "$node")

        local switch_code
        switch_code=$(mihomo_curl -s -o /dev/null -w '%{http_code}' \
            -X PUT "${api_url}/proxies/Proxy" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --max-time 8) || switch_code=""

        if [[ "$switch_code" != "204" ]]; then
            log_warn "切换节点失败, 跳过: ${node} (HTTP ${switch_code:-ERR})"
            continue
        fi

        local probe_out http_code time_total latency_ms
        probe_out=$(curl -sL -o /dev/null \
            -w '%{http_code} %{time_total}' \
            --connect-timeout 5 \
            --max-time "$HTTP_PROBE_TIMEOUT" \
            -x "http://127.0.0.1:${MIXED_PORT}" \
            "$HTTP_PROBE_URL" 2>/dev/null) || probe_out=""

        http_code="${probe_out%% *}"
        time_total="${probe_out#* }"
        [[ "$probe_out" == "$http_code" ]] && time_total=""

        if [[ "$http_code" != "204" && "$http_code" != "200" ]]; then
            log_warn "HTTP 探测失败: ${node} (HTTP ${http_code:-ERR})"
            continue
        fi

        latency_ms=$(python3 -c 'import sys; print(int(float(sys.argv[1])*1000))' "${time_total:-999}") || latency_ms=999999
        tested=$((tested + 1))
        log_info "HTTP 探测: ${node} -> ${latency_ms}ms"

        if [[ "$PROBE_STRATEGY" == "first-success" ]]; then
            # 启动/重启: 候选已按 TCP 延迟排序，第一个通过即最佳，立即返回
            best_node="$node"
            best_ms=$latency_ms
            break
        else
            # 定时任务: 探测全部候选，选 HTTP 延迟最低的
            if (( latency_ms < best_ms )); then
                best_ms=$latency_ms
                best_node="$node"
            fi
        fi
    done < <(
        if [[ -n "$node_shortlist" ]]; then
            printf '%s\n' "$node_shortlist"
        else
            python3 -c "
import yaml
with open('${SUB_FILE}', encoding='utf-8') as f:
    d = yaml.safe_load(f) or {}
for p in d.get('proxies', []) or []:
    print(p.get('name', ''))
"
        fi
    )

    if [[ -z "$best_node" ]]; then
        log_warn "HTTP 探测未选出可用节点 (总节点=${total}, 成功=${tested})"
        return 1
    fi

    log_info "HTTP 探测最佳节点: ${best_node} (${best_ms}ms)"
    echo "$best_node"
}

# ===== 6. 设置系统代理 =====
setup_proxy() {
    if [[ "$SKIP_PROXY" == "true" ]]; then
        log_info "跳过系统代理设置 (--skip-proxy)"
        return 0
    fi

    if [[ "$PROXY_MODE" != "process-proxy" ]]; then
        log_warn "当前模式为 ${PROXY_MODE}; 跳过环境变量代理注入 (仅 process-proxy 使用)"
        return 0
    fi

    log_info "正在设置系统代理 (process-proxy)..."

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

    # 同时写入 systemd 兼容格式 (无 export, 供 EnvironmentFile= 使用)
    local proxy_env="/etc/auto-mihomo/proxy.env"
    if [[ -w "$(dirname "$proxy_env")" ]]; then
        cat > "$proxy_env" <<SYSENV_EOF
# Auto-Mihomo systemd 代理配置 (自动生成, 请勿手动修改)
# 用法: 在 systemd service 中添加 EnvironmentFile=/etc/auto-mihomo/proxy.env
http_proxy=http://127.0.0.1:${MIXED_PORT}
https_proxy=http://127.0.0.1:${MIXED_PORT}
all_proxy=socks5://127.0.0.1:${MIXED_PORT}
HTTP_PROXY=http://127.0.0.1:${MIXED_PORT}
HTTPS_PROXY=http://127.0.0.1:${MIXED_PORT}
ALL_PROXY=socks5://127.0.0.1:${MIXED_PORT}
no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
GLOBAL_AGENT_HTTP_PROXY=http://127.0.0.1:${MIXED_PORT}
SYSENV_EOF
        log_info "systemd 代理环境文件已写入: ${proxy_env}"
    fi

    log_info "系统代理已设置 (mixed-port: ${MIXED_PORT})"
    log_info "运行 'source /etc/profile.d/proxy.sh' 使当前终端生效"
}

# ===== 7. 验证代理 =====
verify_proxy() {
    log_info "正在验证代理连通性..."
    sleep 1

    local test_url="$HTTP_PROBE_URL"
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

    # Step 2: 选一个临时节点生成配置 (真实选优在 Mihomo 启动后进行 HTTP 探测)
    local best_node
    best_node=$(get_first_node_name) || { log_error "无法读取订阅中的首个节点, 中止"; exit 1; }
    log_info "临时默认节点: ${best_node}"

    # Step 3: 生成配置
    generate_config "$best_node" || { log_error "生成配置失败, 中止"; exit 1; }

    # Step 4: 重载 Mihomo
    reload_mihomo || { log_error "重载 Mihomo 失败, 中止"; exit 1; }

    # Step 5: TCP 并发预筛选 + HTTP 探测重新选优
    local tcp_shortlist=""
    if [[ "$PROXY_MODE" == "process-proxy" ]]; then
        tcp_shortlist=$(tcp_prefilter_nodes) || true
        if [[ -n "$tcp_shortlist" ]]; then
            local shortlist_count
            shortlist_count=$(printf '%s\n' "$tcp_shortlist" | grep -c '.' || true)
            log_info "TCP 预筛选完成，候选节点: ${shortlist_count} 个"
        else
            log_warn "TCP 预筛选无结果，HTTP 探测将覆盖所有节点"
        fi
    fi

    local probed_best_node=""
    probed_best_node=$(probe_and_select_best_node "$tcp_shortlist") || true
    if [[ -n "$probed_best_node" && "$probed_best_node" != "$best_node" ]]; then
        log_info "应用 HTTP 探测结果并重载配置: ${best_node} -> ${probed_best_node}"
        generate_config "$probed_best_node" || { log_error "重新生成配置失败, 中止"; exit 1; }
        reload_mihomo || { log_error "应用 HTTP 探测结果失败, 中止"; exit 1; }
        best_node="$probed_best_node"
    fi

    # Step 6: 设置系统代理
    setup_proxy

    # Step 7: 验证
    verify_proxy

    log_info "========== 更新完成 =========="
}

main "$@"
