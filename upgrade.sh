#!/usr/bin/env bash
# =============================================================================
# upgrade.sh - Auto-Mihomo 升级向导
#
# 从新的部署包升级现有安装:
#   - 自动检测已安装目录 (解析 systemd 服务文件)
#   - .env 迁移向导: 对比新旧 .env.example, 智能提示新增/变更项
#   - 停止服务 → 备份 → 部署 → 更新 systemd → 重启
#
# 用法 (在解压后的新部署包目录中运行):
#   sudo bash upgrade.sh                                  # 自动检测安装目录
#   sudo bash upgrade.sh --install-dir /opt/auto-mihomo  # 指定安装目录
#   sudo bash upgrade.sh --yes                           # 非交互模式 (保留旧值)
#   sudo bash upgrade.sh --skip-check                    # 跳过升级后自检
# =============================================================================
set -euo pipefail

# ===== 颜色 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ===== 路径 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_PKG_DIR="$SCRIPT_DIR"   # 新版本包 = upgrade.sh 所在目录

# ===== 参数 =====
INSTALL_DIR=""
YES_MODE=false
SKIP_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --yes|-y)      YES_MODE=true;  shift ;;
        --skip-check)  SKIP_CHECK=true; shift ;;
        -h|--help)
            echo "用法: sudo bash upgrade.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --install-dir DIR  指定现有安装目录 (默认: 自动检测)"
            echo "  --yes              非交互模式 (保留旧值, 自动生成新密钥)"
            echo "  --skip-check       跳过升级后服务自检"
            echo "  -h, --help         显示帮助"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# ===== 日志函数 =====
info()    { printf "  ${BLUE}ℹ${NC}  %s\n" "$*"; }
ok()      { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
err()     { printf "  ${RED}✗${NC}  %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}%s${NC}\n" "$*"; printf '%s\n' "$(printf '─%.0s' {1..50})"; }
ask()     { printf "  ${CYAN}?${NC}  %s " "$*"; }

# ===== .env 工具函数 =====

# 从 .env 风格文件中读取指定 key 的值 (跳过注释行)
read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 == k { sub(/^[^=]*=/, "", $0); print; exit }
    ' "$file"
}

# 列出文件中所有非注释 key (按出现顺序)
list_env_keys() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" | cut -d= -f1
}

# 在 .env 文件中写入/更新 key=value (保留文件中其他内容和注释)
set_env_kv() {
    local file="$1" key="$2" value="$3"
    touch "$file"
    if grep -qE "^${key}=" "$file"; then
        local tmp="${file}.tmp.$$"
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ ("^" k "=") && done == 0 { print k "=" v; done = 1; next }
            { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# 生成随机 URL-safe token
rand_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr '+/' '-_' | tr -d '=' | tr -d '\n'
    else
        python3 -c "import secrets; print(secrets.token_urlsafe(48))"
    fi
}

# 掩码显示密钥 (保留首4位和末2位)
mask_value() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then echo "${DIM}(空)${NC}"; return; fi
    if [[ ${#v} -le 8 ]]; then echo "****"; return; fi
    printf '%s****%s' "${v:0:4}" "${v: -2}"
}

# 判断是否为占位符 (非真实值)
is_placeholder() {
    local v="${1:-}"
    [[ -z "$v" ]] ||
    [[ "$v" == *CHANGE_ME* ]] ||
    [[ "$v" == *YOUR_TOKEN* ]] ||
    [[ "$v" == "https://example.com"* ]]
}

# 判断是否为有效真实值
is_real_value() {
    local v="${1:-}"
    [[ -n "$v" ]] && ! is_placeholder "$v"
}

# ===== 检测安装目录 =====
detect_install_dir() {
    local detected=""

    # 优先从 auto-mihomo-mcp.service 的 WorkingDirectory= 推断
    if [[ -f /etc/systemd/system/auto-mihomo-mcp.service ]]; then
        detected=$(grep -m1 '^WorkingDirectory=' /etc/systemd/system/auto-mihomo-mcp.service \
            | cut -d= -f2- | xargs 2>/dev/null || true)
        if [[ -n "$detected" && -d "$detected" ]]; then
            echo "$detected"; return
        fi
    fi

    # 从 openclaw-gateway drop-in 的 ExecStartPre= 推断 (新版)
    local dropin="/etc/systemd/system/openclaw-gateway.service.d/10-auto-mihomo.conf"
    if [[ -f "$dropin" ]]; then
        detected=$(grep -m1 '^ExecStartPre=' "$dropin" \
            | sed 's|ExecStartPre=-\?bash \(.*\)/scripts/.*|\1|' | xargs 2>/dev/null || true)
        if [[ -n "$detected" && -d "$detected" ]]; then
            echo "$detected"; return
        fi
    fi

    # 兼容旧版: 从 openclaw-gateway.service 的 ExecStart= 推断
    if [[ -f /etc/systemd/system/openclaw-gateway.service ]]; then
        detected=$(grep -m1 '^ExecStart=' /etc/systemd/system/openclaw-gateway.service \
            | sed 's|ExecStart=\(.*\)/scripts/.*|\1|' | xargs 2>/dev/null || true)
        if [[ -n "$detected" && -d "$detected" ]]; then
            echo "$detected"; return
        fi
    fi

    # 默认路径
    echo "/opt/auto-mihomo"
}

# ===== 检测服务用户 =====
detect_service_user() {
    local user=""
    if [[ -f /etc/systemd/system/mihomo.service ]]; then
        user=$(grep -m1 '^User=' /etc/systemd/system/mihomo.service \
            | cut -d= -f2 | xargs 2>/dev/null || true)
    fi
    echo "${user:-openclaw}"
}

# ===== 读取版本号 (取第一行) =====
read_version() {
    local file="$1"
    [[ -f "$file" ]] && head -1 "$file" | tr -d '[:space:]' || echo "(未知)"
}

# =============================================================================
# .env 迁移向导
# =============================================================================
wizard_env_migration() {
    local old_install="$1"   # 现有安装目录
    local new_pkg="$2"       # 新版本包目录

    local old_env="${old_install}/.env"
    local old_example="${old_install}/.env.example"
    local new_example="${new_pkg}/.env.example"
    local work_env="${old_install}/.env.new.$$"   # 临时新 .env

    # ---- 从新 .env.example 开始, 包含注释 ----
    cp "$new_example" "$work_env"

    # ---- 将旧 .env 中的值迁移到新文件 ----
    if [[ -f "$old_env" ]]; then
        while IFS= read -r key; do
            local old_val
            old_val=$(read_env_value "$key" "$old_env")
            if [[ -n "$old_val" ]]; then
                set_env_kv "$work_env" "$key" "$old_val"
            fi
        done < <(list_env_keys "$new_example")
    fi

    # ---- 对比新旧 .env.example, 找出变化 ----
    local old_keys=() new_keys=()

    if [[ -f "$old_example" ]]; then
        while IFS= read -r k; do old_keys+=("$k"); done < <(list_env_keys "$old_example")
    fi
    while IFS= read -r k; do new_keys+=("$k"); done < <(list_env_keys "$new_example")

    local added_keys=() removed_keys=()
    for k in "${new_keys[@]}"; do
        printf '%s\n' "${old_keys[@]:-__none__}" | grep -qxF "$k" || added_keys+=("$k")
    done
    for k in "${old_keys[@]:-}"; do
        printf '%s\n' "${new_keys[@]}" | grep -qxF "$k" || removed_keys+=("$k")
    done

    # ---- 显示变更摘要 ----
    if [[ ${#added_keys[@]} -gt 0 || ${#removed_keys[@]} -gt 0 ]]; then
        echo ""
        info "检测到 .env 配置项变化:"
        if [[ ${#added_keys[@]} -gt 0 ]]; then
            printf "  ${GREEN}+ 新增:${NC} %s\n" "${added_keys[*]}"
        fi
        if [[ ${#removed_keys[@]} -gt 0 ]]; then
            printf "  ${YELLOW}- 移除:${NC} %s\n" "${removed_keys[*]}"
        fi
    else
        info ".env 配置项无变化, 自动迁移所有旧值"
    fi

    # ================================================================
    # 逐项向导 (敏感 key)
    # ================================================================

    echo ""
    printf '%s\n' "  ┌─ 配置向导 ──────────────────────────────────────┐"

    # ---- MIHOMO_SUB_URL ----
    _wizard_sub_url "$work_env" "$old_env"

    # ---- MIHOMO_API_SECRET ----
    _wizard_secret "$work_env" "MIHOMO_API_SECRET" "Mihomo REST API 密钥"

    # ---- MCP_API_TOKEN ----
    _wizard_secret "$work_env" "MCP_API_TOKEN" "MCP HTTP API Token"

    # ---- 其他新增非敏感 key ----
    local sensitive=("MIHOMO_SUB_URL" "MIHOMO_API_SECRET" "MCP_API_TOKEN")
    for key in "${added_keys[@]:-}"; do
        [[ -z "$key" ]] && continue
        # 跳过已在向导中处理的 key
        if printf '%s\n' "${sensitive[@]}" | grep -qxF "$key"; then continue; fi
        _wizard_new_key "$work_env" "$key"
    done

    printf '%s\n' "  └──────────────────────────────────────────────────┘"

    # ---- 写入最终 .env ----
    mv "$work_env" "$old_env"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$old_env"
    chmod 600 "$old_env"
    ok ".env 迁移完成"
}

# 处理 MIHOMO_SUB_URL
_wizard_sub_url() {
    local env_file="$1" old_env="$2"
    local key="MIHOMO_SUB_URL"
    local cur_val
    cur_val=$(read_env_value "$key" "$env_file")

    echo ""
    printf "  │  ${BOLD}订阅 URL${NC} (%s)\n" "$key"

    if is_real_value "$cur_val"; then
        local display="${cur_val:0:50}"
        [[ ${#cur_val} -gt 50 ]] && display="${display}..."
        printf "  │  当前值: ${CYAN}%s${NC}\n" "$display"

        if [[ "$YES_MODE" == "true" ]]; then
            printf "  │  ${GREEN}→ 保留旧值${NC}\n"
            return
        fi

        ask "│  [K] 保留 / [E] 修改 (默认: K):"
        read -r ans </dev/tty; ans="${ans:-K}"
        if [[ "$ans" =~ ^[Ee] ]]; then
            ask "│  新的订阅 URL:"
            read -r new_url </dev/tty
            if [[ -n "$new_url" ]] && ! is_placeholder "$new_url"; then
                set_env_kv "$env_file" "$key" "$new_url"
                printf "  │  ${GREEN}✓ 已更新${NC}\n"
            else
                printf "  │  ${YELLOW}→ 输入无效, 保留旧值${NC}\n"
            fi
        else
            printf "  │  ${GREEN}→ 保留旧值${NC}\n"
        fi
    else
        # 没有有效值, 必须要求用户输入
        printf "  │  ${RED}⚠ 未找到有效的订阅 URL (必填)${NC}\n"

        if [[ "$YES_MODE" == "true" ]]; then
            err "非交互模式下未检测到有效的 MIHOMO_SUB_URL"
            err "请升级后手动编辑: ${env_file}"
            printf "  │  ${YELLOW}→ 将使用占位符, 请手动修改后重启服务${NC}\n"
            return
        fi

        while true; do
            ask "│  请输入 Clash 订阅 URL:"
            read -r new_url </dev/tty
            if [[ -n "$new_url" ]] && ! is_placeholder "$new_url"; then
                set_env_kv "$env_file" "$key" "$new_url"
                printf "  │  ${GREEN}✓ 已设置${NC}\n"
                break
            fi
            printf "  │  ${YELLOW}请输入有效的订阅 URL${NC}\n"
        done
    fi
}

# 处理密钥类型的 key (MIHOMO_API_SECRET / MCP_API_TOKEN)
_wizard_secret() {
    local env_file="$1" key="$2" label="$3"
    local cur_val
    cur_val=$(read_env_value "$key" "$env_file")

    echo ""
    printf "  │  ${BOLD}%s${NC} (%s)\n" "$label" "$key"

    if is_real_value "$cur_val"; then
        printf "  │  当前值: ${CYAN}%s${NC}\n" "$(mask_value "$cur_val")"

        if [[ "$YES_MODE" == "true" ]]; then
            printf "  │  ${GREEN}→ 保留旧值${NC}\n"
            return
        fi

        ask "│  [K] 保留 / [G] 重新生成 / [E] 输入新值 (默认: K):"
        read -r ans </dev/tty; ans="${ans:-K}"
        case "$ans" in
            [Gg]*)
                local new_val; new_val=$(rand_token)
                set_env_kv "$env_file" "$key" "$new_val"
                printf "  │  ${GREEN}✓ 已重新生成: %s${NC}\n" "$(mask_value "$new_val")"
                ;;
            [Ee]*)
                ask "│  请输入新值:"
                read -r new_val </dev/tty
                if [[ -n "$new_val" ]]; then
                    set_env_kv "$env_file" "$key" "$new_val"
                    printf "  │  ${GREEN}✓ 已更新${NC}\n"
                else
                    printf "  │  ${YELLOW}→ 输入为空, 保留旧值${NC}\n"
                fi
                ;;
            *)
                printf "  │  ${GREEN}→ 保留旧值${NC}\n"
                ;;
        esac
    else
        # 无有效值 → 自动生成, 可选手动覆盖
        local new_val; new_val=$(rand_token)
        set_env_kv "$env_file" "$key" "$new_val"
        printf "  │  ${GREEN}+ 新增, 已自动生成: ${CYAN}%s${NC}\n" "$(mask_value "$new_val")"

        if [[ "$YES_MODE" != "true" ]]; then
            ask "│  [Enter 接受 / 输入自定义值]:"
            read -r custom_val </dev/tty
            if [[ -n "$custom_val" ]]; then
                set_env_kv "$env_file" "$key" "$custom_val"
                printf "  │  ${GREEN}✓ 已使用自定义值${NC}\n"
            fi
        fi
    fi
}

# 处理新增的普通 key
_wizard_new_key() {
    local env_file="$1" key="$2"
    local default_val
    default_val=$(read_env_value "$key" "$env_file")

    echo ""
    printf "  │  ${GREEN}+ 新配置项:${NC} ${BOLD}%s${NC}\n" "$key"
    printf "  │  默认值: ${DIM}%s${NC}\n" "$default_val"

    if [[ "$YES_MODE" == "true" ]]; then
        printf "  │  ${GREEN}→ 使用默认值${NC}\n"
        return
    fi

    ask "│  [Enter 接受默认值 / 输入新值]:"
    read -r custom_val </dev/tty
    if [[ -n "$custom_val" ]]; then
        set_env_kv "$env_file" "$key" "$custom_val"
        printf "  │  ${GREEN}✓ 已设置: %s${NC}\n" "$custom_val"
    else
        printf "  │  ${GREEN}→ 使用默认值${NC}\n"
    fi
}

mask_openclaw_user_unit() {
    local svc_user="$1"
    local user_home="$2"
    local user_config_dir="${user_home}/.config"
    local user_systemd_dir="${user_config_dir}/systemd"
    local user_unit_dir="${user_systemd_dir}/user"
    local user_unit="${user_unit_dir}/openclaw-gateway.service"
    local backup=""
    local user_uid=""
    local runtime_dir=""

    if [[ "${AUTO_MIHOMO_MASK_OPENCLAW_USER_UNIT:-1}" == "0" ]]; then
        info "跳过 mask openclaw user unit (AUTO_MIHOMO_MASK_OPENCLAW_USER_UNIT=0)"
        return 0
    fi

    install -d -m 755 -o "$svc_user" -g "$svc_user" "$user_config_dir" "$user_systemd_dir" "$user_unit_dir"

    if [[ -L "$user_unit" ]] && [[ "$(readlink "$user_unit")" == "/dev/null" ]]; then
        info "openclaw user unit 已是 masked"
    else
        if [[ -e "$user_unit" || -L "$user_unit" ]]; then
            backup="${user_unit}.pre-mask.$(date +%Y%m%d-%H%M%S).bak"
            mv "$user_unit" "$backup"
            chown "$svc_user:$svc_user" "$backup" 2>/dev/null || true
            info "已备份 user unit → $backup"
        fi
        ln -sfn /dev/null "$user_unit"
        chown -h "$svc_user:$svc_user" "$user_unit" 2>/dev/null || true
        ok "已 mask openclaw user unit → $user_unit"
    fi

    user_uid=$(id -u "$svc_user" 2>/dev/null || true)
    runtime_dir="/run/user/${user_uid}"
    if [[ -n "$user_uid" && -S "${runtime_dir}/bus" ]]; then
        sudo -u "$svc_user" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
            systemctl --user disable --now openclaw-gateway.service >/dev/null 2>&1 || true
        sudo -u "$svc_user" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
            systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# 安装 systemd 服务文件 (复用 install.sh 中的 sed 替换逻辑)
# =============================================================================
install_systemd_services() {
    local install_dir="$1"
    local svc_user="$2"
    local user_home="$3"

    local mihomo_bin="${MIHOMO_HOME}/mihomo"
    local config_file="${MIHOMO_HOME}/config.yaml"

    # mihomo.service
    sed \
        -e "s|__USER__|${svc_user}|g" \
        -e "s|__MIHOMO_BIN__|${mihomo_bin}|g" \
        -e "s|__MIHOMO_HOME__|${MIHOMO_HOME}|g" \
        -e "s|__CONFIG_FILE__|${config_file}|g" \
        -e "s|__PROJECT_DIR__|${install_dir}|g" \
        "${install_dir}/systemd/mihomo.service" \
        | sudo tee /etc/systemd/system/mihomo.service > /dev/null
    ok "mihomo.service"

    # auto-mihomo-mcp.service
    sed \
        -e "s|__USER__|${svc_user}|g" \
        -e "s|__PROJECT_DIR__|${install_dir}|g" \
        "${install_dir}/systemd/auto-mihomo-mcp.service" \
        | sudo tee /etc/systemd/system/auto-mihomo-mcp.service > /dev/null
    ok "auto-mihomo-mcp.service"

    # openclaw-gateway drop-in (仅注入代理环境和订阅更新预启动任务)
    # Base unit 由 OpenClaw 自身管理 (openclaw onboard --install-daemon)
    local openclaw_app_dir="${user_home}/.openclaw"
    local dropin_dir="/etc/systemd/system/openclaw-gateway.service.d"
    if [[ -d "$openclaw_app_dir" ]]; then
        # 迁移检测: 旧版全量 unit 由 auto-mihomo 安装时含 start_openclaw_with_proxy.sh
        if [[ -f /etc/systemd/system/openclaw-gateway.service ]] && \
           grep -q "start_openclaw_with_proxy.sh" /etc/systemd/system/openclaw-gateway.service 2>/dev/null; then
            warn "检测到旧版 auto-mihomo 全量 unit — 迁移说明见升级完成后提示"
            MIGRATE_OLD_UNIT=true
        fi

        # 解析 Node.js 可执行文件路径 (systemd PATH 中没有 nvm bin dir)
        local _node_bin=""
        if [[ -d "${user_home}/.nvm/versions/node" ]]; then
            _node_bin=$(find "${user_home}/.nvm/versions/node" -maxdepth 3 -name node -type f 2>/dev/null \
                | sort -rV | head -1)
        fi
        [[ -z "$_node_bin" ]] && _node_bin=$(command -v node 2>/dev/null || true)
        if [[ -z "$_node_bin" ]]; then
            for _p in /usr/local/bin/node /usr/bin/node; do
                [[ -x "$_p" ]] && _node_bin="$_p" && break
            done
        fi
        local node_dir; node_dir=$(dirname "${_node_bin:-/usr/bin/node}")
        info "Node.js: ${_node_bin:-未找到} → PATH 注入: ${node_dir}"
        unset _node_bin _p

        sudo mkdir -p "$dropin_dir"
        sed \
            -e "s|__PROJECT_DIR__|${install_dir}|g" \
            -e "s|__NODE_DIR__|${node_dir}|g" \
            "${install_dir}/systemd/openclaw-gateway.service.d/10-auto-mihomo.conf" \
            | sudo tee "${dropin_dir}/10-auto-mihomo.conf" > /dev/null
        ok "openclaw-gateway.service.d/10-auto-mihomo.conf (drop-in)"
        INSTALL_OPENCLAW_GW=true
    else
        info "openclaw 未检测到, 跳过 openclaw-gateway drop-in"
        INSTALL_OPENCLAW_GW=false
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable mihomo auto-mihomo-mcp 2>/dev/null || true
    # openclaw-gateway enablement is managed by OpenClaw (openclaw onboard --install-daemon)
    if [[ "$INSTALL_OPENCLAW_GW" == "true" ]]; then
        mask_openclaw_user_unit "$svc_user" "$user_home"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {

    # ===== Root 检查 =====
    if [[ "$EUID" -ne 0 ]]; then
        err "请以 root 权限运行: sudo bash upgrade.sh"
        exit 1
    fi

    # ===== 检测安装目录 =====
    [[ -z "$INSTALL_DIR" ]] && INSTALL_DIR=$(detect_install_dir)

    # ===== 检测服务配置 =====
    SERVICE_USER=$(detect_service_user)
    USER_HOME=$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$SERVICE_USER")
    MIHOMO_HOME="${MIHOMO_HOME:-/opt/mihomo}"

    # ===== 版本信息 =====
    OLD_VERSION=$(read_version "${INSTALL_DIR}/version.txt")
    NEW_VERSION=$(read_version "${NEW_PKG_DIR}/version.txt")

    # ===== 标题 =====
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Auto-Mihomo 升级向导                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  当前版本  ${YELLOW}${OLD_VERSION}${NC}"
    echo -e "  新版本    ${GREEN}${NEW_VERSION}${NC}"
    echo -e "  安装目录  ${INSTALL_DIR}"
    echo -e "  新版本包  ${NEW_PKG_DIR}"
    echo -e "  服务用户  ${SERVICE_USER}"
    [[ "$YES_MODE" == "true" ]] && echo -e "  模式      ${DIM}非交互 (--yes)${NC}"
    echo ""

    # =========================================================================
    # [1/7] 前置检查
    # =========================================================================
    step "[1/7] 前置检查"

    # 防止在安装目录中原地升级
    if [[ "$INSTALL_DIR" == "$NEW_PKG_DIR" ]]; then
        err "安装目录与新版本包目录相同 (${INSTALL_DIR})"
        err "请将新的部署包解压到不同路径后再运行升级"
        exit 1
    fi

    # 检查新包完整性
    for required in scripts systemd .env.example version.txt; do
        if [[ ! -e "${NEW_PKG_DIR}/${required}" ]]; then
            err "新版本包缺少必要文件/目录: ${required}"
            err "请确保使用完整的部署包"
            exit 1
        fi
    done
    ok "新版本包完整"

    # 检查是否有现有安装
    if [[ ! -d "$INSTALL_DIR" ]]; then
        warn "未检测到现有安装: ${INSTALL_DIR}"
        echo ""
        if [[ "$YES_MODE" == "true" ]]; then
            info "非交互模式: 转为全新安装"
            exec bash "${NEW_PKG_DIR}/install.sh" --user "$SERVICE_USER"
        fi
        ask "未找到现有安装, 是否执行全新安装? [y/N]:"
        read -r ans </dev/tty
        if [[ "$ans" =~ ^[Yy] ]]; then
            exec bash "${NEW_PKG_DIR}/install.sh"
        else
            info "升级取消"
            exit 0
        fi
    fi
    ok "现有安装: ${INSTALL_DIR}"

    if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
        warn "现有安装缺少 .env 文件, 将运行完整配置向导"
    fi

    # =========================================================================
    # [2/7] 停止服务
    # =========================================================================
    step "[2/7] 停止服务"

    STOPPED_SERVICES=()
    for svc in openclaw-gateway auto-mihomo-mcp mihomo; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
            && systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            STOPPED_SERVICES+=("$svc")
            ok "已停止 ${svc}"
        else
            info "${svc}: 未运行"
        fi
    done

    # =========================================================================
    # [3/7] 备份现有安装
    # =========================================================================
    step "[3/7] 备份现有安装"

    BACKUP_DIR="${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    info "备份目录: ${BACKUP_DIR}"

    # 备份时排除 .venv (可重建, 体积大) 和运行时生成的大文件
    rsync -a \
        --exclude='.venv/' \
        --exclude='__pycache__/' \
        --exclude='*.pyc' \
        --exclude='vendor/' \
        "${INSTALL_DIR}/" "${BACKUP_DIR}/"

    ok "备份完成: ${BACKUP_DIR}"

    # =========================================================================
    # [4/7] .env 迁移向导
    # =========================================================================
    step "[4/7] .env 配置迁移"

    wizard_env_migration "$INSTALL_DIR" "$NEW_PKG_DIR"

    # =========================================================================
    # [5/7] 部署新版本文件
    # =========================================================================
    step "[5/7] 部署新版本文件"

    # 同步项目文件 (保留 .env / subscription.yaml / config.yaml / 日志 / .venv)
    rsync -a \
        --exclude='.env' \
        --exclude='subscription.yaml' \
        --exclude='config.yaml' \
        --exclude='*.log' \
        --exclude='.venv/' \
        --exclude='vendor/' \
        --exclude='__pycache__/' \
        --exclude='*.pyc' \
        --exclude='dist/' \
        "${NEW_PKG_DIR}/" "${INSTALL_DIR}/"
    ok "脚本和配置模板已更新"

    # 确保脚本可执行
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/upgrade.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true
    ln -sfn "${MIHOMO_HOME}/config.yaml" "${INSTALL_DIR}/config.yaml" 2>/dev/null || true

    # ---- 更新 Mihomo 二进制 (离线包) ----
    VENDOR_DIR="${NEW_PKG_DIR}/vendor"
    MIHOMO_UPDATED=false
    if [[ -f "${VENDOR_DIR}/mihomo" ]]; then
        mkdir -p "$MIHOMO_HOME"
        cp "${VENDOR_DIR}/mihomo" "${MIHOMO_HOME}/mihomo"
        chmod +x "${MIHOMO_HOME}/mihomo"
        chown "${SERVICE_USER}:${SERVICE_USER}" "${MIHOMO_HOME}/mihomo"
        MIHOMO_UPDATED=true
        ok "Mihomo 二进制已更新 ($(${MIHOMO_HOME}/mihomo -v 2>/dev/null | head -1 || echo '版本未知'))"
    else
        info "vendor/mihomo 不存在, 跳过 Mihomo 二进制更新"
    fi

    # ---- 更新 GeoIP 数据 (离线包) ----
    GEO_UPDATED=false
    for geo_file in geoip.dat geosite.dat country.mmdb; do
        if [[ -f "${VENDOR_DIR}/${geo_file}" ]]; then
            cp "${VENDOR_DIR}/${geo_file}" "${MIHOMO_HOME}/${geo_file}"
            chown "${SERVICE_USER}:${SERVICE_USER}" "${MIHOMO_HOME}/${geo_file}"
            GEO_UPDATED=true
        fi
    done
    [[ "$GEO_UPDATED" == "true" ]] && ok "GeoIP 数据已更新" || info "vendor/ 无 GeoIP 数据, 跳过"

    # ---- 重建 Python 虚拟环境 ----
    cd "$INSTALL_DIR"
    if [[ -d "${VENDOR_DIR}/wheels" ]]; then
        WHEEL_COUNT=$(find "${VENDOR_DIR}/wheels" -name '*.whl' 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$WHEEL_COUNT" -gt 0 ]]; then
            info "从部署包安装 Python 依赖 (${WHEEL_COUNT} wheels)..."
            uv venv --quiet
            uv pip install --quiet --no-index \
                --find-links "${VENDOR_DIR}/wheels/" \
                fastapi "uvicorn[standard]" pyyaml httpx
            ok "Python 依赖已更新 (离线)"
        else
            info "vendor/wheels 为空, 在线安装..."
            uv sync --quiet
            ok "Python 依赖已更新 (在线)"
        fi
    else
        info "在线安装 Python 依赖..."
        uv sync --quiet
        ok "Python 依赖已更新 (在线)"
    fi

    # 修正目录权限
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
    [[ "$MIHOMO_UPDATED" == "true" || "$GEO_UPDATED" == "true" ]] && \
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "$MIHOMO_HOME" 2>/dev/null || true

    # =========================================================================
    # [5b/7] cron 任务迁移
    # =========================================================================
    step "[5b/7] cron 任务迁移"

    CRON_TZ_LINE="CRON_TZ=Asia/Shanghai"
    CRON_CMD="0 12 * * * ${INSTALL_DIR}/scripts/cron_update_proxy.sh"

    CURRENT_CRONTAB="$(sudo -u "$SERVICE_USER" crontab -l 2>/dev/null || true)"

    # 清理旧版本 update_sub.sh cron 条目 (pre-v1 遗留)
    CURRENT_CRONTAB="$(printf '%s\n' "$CURRENT_CRONTAB" \
        | grep -vF "${INSTALL_DIR}/scripts/update_sub.sh" \
        | grep -vF "${BACKUP_DIR}/scripts/update_sub.sh" \
        || true)"

    if printf '%s\n' "$CURRENT_CRONTAB" | grep -qF "${INSTALL_DIR}/scripts/cron_update_proxy.sh"; then
        info "cron 任务已存在, 跳过"
    else
        {
            if [[ -n "${CURRENT_CRONTAB//$'\n'/}" ]]; then
                printf '%s\n' "$CURRENT_CRONTAB"
            fi
            if ! printf '%s\n' "$CURRENT_CRONTAB" | grep -qFx "$CRON_TZ_LINE"; then
                printf '%s\n' "$CRON_TZ_LINE"
            fi
            printf '%s\n' "$CRON_CMD"
        } | sudo -u "$SERVICE_USER" crontab -
        ok "cron 任务已更新: ${CRON_CMD}"
    fi

    # =========================================================================
    # [6/7] 更新 systemd 服务
    # =========================================================================
    step "[6/7] 更新 systemd 服务"

    INSTALL_OPENCLAW_GW=false
    MIGRATE_OLD_UNIT=false
    install_systemd_services "$INSTALL_DIR" "$SERVICE_USER" "$USER_HOME"
    ok "systemd daemon 已重载"

    # =========================================================================
    # [7/7] 启动服务
    # =========================================================================
    step "[7/7] 启动服务"

    systemctl start mihomo
    ok "mihomo 已启动"
    sleep 2

    systemctl start auto-mihomo-mcp
    ok "auto-mihomo-mcp 已启动"
    sleep 1

    if [[ "$INSTALL_OPENCLAW_GW" == "true" ]]; then
        if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
            systemctl restart openclaw-gateway
            ok "openclaw-gateway 已重启 (drop-in 已生效)"
        elif systemctl list-unit-files openclaw-gateway.service &>/dev/null 2>&1 \
             && systemctl cat openclaw-gateway &>/dev/null 2>&1; then
            systemctl start openclaw-gateway
            ok "openclaw-gateway 已启动"
        else
            warn "openclaw-gateway base unit 未注册 — drop-in 已就位"
            echo "  请运行: openclaw onboard --install-daemon"
        fi
    fi
    if [[ "$MIGRATE_OLD_UNIT" == "true" ]]; then
        echo ""
        warn "旧版全量 unit 仍存在: /etc/systemd/system/openclaw-gateway.service"
        echo "  迁移到 drop-in 模式后可手动清理旧 unit:"
        echo "  1) sudo systemctl stop openclaw-gateway"
        echo "  2) sudo rm /etc/systemd/system/openclaw-gateway.service"
        echo "  3) openclaw onboard --install-daemon  # 让 OpenClaw 重装 base unit"
        echo "  4) sudo systemctl daemon-reload && sudo systemctl start openclaw-gateway"
    fi

    # =========================================================================
    # 升级后自检
    # =========================================================================
    if [[ "$SKIP_CHECK" == "false" && -f "${INSTALL_DIR}/scripts/post_deploy_self_check.sh" ]]; then
        echo ""
        info "执行升级后自检..."
        sleep 3   # 等待服务稳定
        bash "${INSTALL_DIR}/scripts/post_deploy_self_check.sh" || \
            warn "自检未完全通过, 请查看上方输出"
    fi

    # =========================================================================
    # 完成
    # =========================================================================
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ${GREEN}✓ 升级完成!${NC}${BOLD}                                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}${OLD_VERSION}${NC}  →  ${GREEN}${NEW_VERSION}${NC}"
    echo ""
    echo -e "  安装目录  ${INSTALL_DIR}"
    echo -e "  备份位置  ${DIM}${BACKUP_DIR}${NC}"
    echo ""
    echo "  常用命令:"
    echo "    查看日志:    sudo journalctl -u mihomo -f"
    echo "    自检:        bash ${INSTALL_DIR}/scripts/post_deploy_self_check.sh"
    echo "    更新订阅:    sudo -u ${SERVICE_USER} bash ${INSTALL_DIR}/scripts/update_sub.sh"
    echo ""
    echo -e "  如需回滚:"
    echo -e "    ${DIM}sudo bash ${BACKUP_DIR}/install.sh${NC}"
    echo ""
}

main "$@"
