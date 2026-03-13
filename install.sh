#!/usr/bin/env bash
# =============================================================================
# Auto-Mihomo 安装脚本
#
# 适用于树莓派5 (ARM64) / Debian / Ubuntu 系统
#
# 两种使用方式:
#   1. 从部署包安装 (离线): bash build_package.sh → scp → bash install.sh
#      自动检测 vendor/ 目录, 使用本地预下载的二进制和 wheels
#   2. 从源码安装 (在线): git clone → bash install.sh
#      在线下载 Mihomo、GeoIP、uv 和 Python 依赖
#
# 用法:
#   sudo bash install.sh                    # 服务用户 = openclaw
#   sudo bash install.sh --user openclaw    # 指定服务用户
# =============================================================================
set -euo pipefail

# ===== 配置 =====
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
MIHOMO_HOME="/opt/mihomo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/auto-mihomo"
VENDOR_DIR="${SCRIPT_DIR}/vendor"

# ===== 解析参数 =====
SERVICE_USER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) SERVICE_USER="$2"; shift 2 ;;
        -h|--help)
            echo "用法: sudo bash install.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --user <USERNAME>  指定运行服务的用户 (默认: openclaw)"
            echo "  -h, --help         显示帮助"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

CURRENT_USER="${SERVICE_USER:-openclaw}"

# ===== 检测已有安装 → 引导至 upgrade.sh =====
# 从已安装的 systemd 服务文件推断安装目录
_existing_install=""
if [[ -f /etc/systemd/system/auto-mihomo-mcp.service ]]; then
    _existing_install=$(grep -m1 '^WorkingDirectory=' /etc/systemd/system/auto-mihomo-mcp.service \
        | cut -d= -f2- | xargs 2>/dev/null || true)
fi
# 若推断路径存在且不是固定安装目录本身, 则视为已有安装
if [[ -n "$_existing_install" && -d "$_existing_install" && "$_existing_install" != "$INSTALL_DIR" ]]; then
    echo ""
    echo "  检测到已有安装: ${_existing_install}"
    echo "  当前版本: $(head -1 "${_existing_install}/version.txt" 2>/dev/null || echo '未知')"
    echo "  新版本:   $(head -1 "${SCRIPT_DIR}/version.txt" 2>/dev/null || echo '未知')"
    echo ""
    echo "  提示: 升级现有安装请使用 upgrade.sh, 它会自动迁移 .env 并重启服务。"
    echo ""
    printf "  继续执行 install.sh (全新安装/覆盖) 还是切换到 upgrade.sh? [I=install / U=upgrade (默认: U)]: "
    read -r _ans </dev/tty
    _ans="${_ans:-U}"
    if [[ "$_ans" =~ ^[Uu] ]]; then
        exec bash "${SCRIPT_DIR}/upgrade.sh" ${SERVICE_USER:+--install-dir "$_existing_install"}
    fi
    echo ""
fi
unset _existing_install _ans

# 验证用户存在
if ! id "$CURRENT_USER" &>/dev/null; then
    echo "错误: 用户 '${CURRENT_USER}' 不存在"
    exit 1
fi

USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)

# 检测是否从部署包安装
if [[ -d "$VENDOR_DIR" ]]; then
    OFFLINE=true
    echo "============================================"
    echo "  Auto-Mihomo 安装 (离线部署包)"
    echo "============================================"
else
    OFFLINE=false
    echo "============================================"
    echo "  Auto-Mihomo 安装 (在线)"
    echo "============================================"
fi
echo "  服务用户: ${CURRENT_USER}"
echo ""

# ===== [0/7] 部署项目文件 =====
echo "[0/7] 部署项目文件到 ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
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
    "${SCRIPT_DIR}/" "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
echo "  完成"

# ===== [1/7] 检测架构 =====
ARCH=$(uname -m)
case "$ARCH" in
    aarch64)  MIHOMO_ARCH="linux-arm64"   ;;
    armv7l)   MIHOMO_ARCH="linux-armv7"   ;;
    x86_64)   MIHOMO_ARCH="linux-amd64"   ;;
    *)
        echo "错误: 不支持的架构: $ARCH"
        exit 1
        ;;
esac
echo "[1/7] 检测到架构: ${ARCH} → ${MIHOMO_ARCH}"

# ===== [2/7] 检查系统依赖 =====
echo "[2/7] 检查系统依赖..."
if [[ "$OFFLINE" == "true" ]]; then
    # 离线模式: 跳过 apt-get (无网络), 仅验证已安装
    for cmd in python3 curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "  错误: 离线模式下缺少 ${cmd}, 请先在线安装"
            exit 1
        fi
    done
    echo "  python3 和 curl 已就绪"
else
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3 curl
fi

# ===== [3/7] 安装 uv =====
echo "[3/7] 安装 uv 包管理器..."
if command -v uv &>/dev/null; then
    echo "  uv 已安装: $(uv --version)"
elif [[ "$OFFLINE" == "true" && -f "${VENDOR_DIR}/uv" ]]; then
    echo "  从部署包安装 uv..."
    sudo install -m 755 "${VENDOR_DIR}/uv" /usr/local/bin/uv
    [[ -f "${VENDOR_DIR}/uvx" ]] && sudo install -m 755 "${VENDOR_DIR}/uvx" /usr/local/bin/uvx
    echo "  uv 版本: $(uv --version)"
else
    echo "  在线安装 uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo "  uv 版本: $(uv --version)"
fi

# ===== [4/7] 安装 Mihomo 二进制 =====
echo "[4/7] 安装 Mihomo..."
sudo mkdir -p "$MIHOMO_HOME"
sudo chown "${CURRENT_USER}:${CURRENT_USER}" "$MIHOMO_HOME"

# 停止正在运行的 mihomo (Linux 不允许覆盖运行中的二进制: "Text file busy")
MIHOMO_WAS_RUNNING=false
if command -v systemctl &>/dev/null && systemctl is-active --quiet mihomo 2>/dev/null; then
    echo "  停止运行中的 Mihomo 服务..."
    sudo systemctl stop mihomo
    MIHOMO_WAS_RUNNING=true
elif pgrep -x mihomo &>/dev/null; then
    echo "  停止运行中的 Mihomo 进程..."
    sudo pkill -x mihomo || true
    sleep 1
    MIHOMO_WAS_RUNNING=true
fi

if [[ "$OFFLINE" == "true" && -f "${VENDOR_DIR}/mihomo" ]]; then
    echo "  从部署包复制 Mihomo..."
    cp "${VENDOR_DIR}/mihomo" "${MIHOMO_HOME}/mihomo"
    chmod +x "${MIHOMO_HOME}/mihomo"
else
    echo "  在线下载 Mihomo ${MIHOMO_VERSION} (${MIHOMO_ARCH})..."
    MIHOMO_FILENAME="mihomo-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${MIHOMO_FILENAME}"

    if [[ -f "${MIHOMO_HOME}/mihomo" ]]; then
        mv "${MIHOMO_HOME}/mihomo" "${MIHOMO_HOME}/mihomo.bak"
    fi

    curl -sL "$MIHOMO_URL" | gunzip > "${MIHOMO_HOME}/mihomo"
    chmod +x "${MIHOMO_HOME}/mihomo"
fi
echo "  Mihomo 已安装: ${MIHOMO_HOME}/mihomo"
echo "  版本: $(${MIHOMO_HOME}/mihomo -v 2>/dev/null || echo '未知')"

# 如果之前在运行, 重新启动
if [[ "$MIHOMO_WAS_RUNNING" == "true" ]]; then
    echo "  重新启动 Mihomo 服务..."
    sudo systemctl start mihomo 2>/dev/null || true
fi

# ===== [5/7] 安装 GeoIP 数据 =====
echo "[5/7] 安装 GeoIP 数据库..."
if [[ "$OFFLINE" == "true" ]]; then
    for file in geoip.dat geosite.dat country.mmdb; do
        if [[ -f "${VENDOR_DIR}/${file}" ]]; then
            cp "${VENDOR_DIR}/${file}" "${MIHOMO_HOME}/${file}"
            echo "  复制 ${file}"
        fi
    done
else
    GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
    for file in geoip.dat geosite.dat country.mmdb; do
        echo "  下载 ${file}..."
        curl -sL "${GEO_BASE}/${file}" -o "${MIHOMO_HOME}/${file}"
    done
fi
echo "  完成"

# ===== [6/7] Python 虚拟环境 =====
echo "[6/7] 创建 Python 虚拟环境并安装依赖..."
cd "$INSTALL_DIR"

if [[ "$OFFLINE" == "true" && -d "${VENDOR_DIR}/wheels" ]]; then
    WHEEL_COUNT=$(find "${VENDOR_DIR}/wheels" -name '*.whl' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$WHEEL_COUNT" -gt 0 ]]; then
        echo "  从部署包安装 (${WHEEL_COUNT} wheels)..."
        uv venv
        uv pip install --no-index --find-links "${VENDOR_DIR}/wheels/" \
            fastapi "uvicorn[standard]" pyyaml httpx
    else
        echo "  vendor/wheels 为空, 回退到在线安装..."
        uv sync
    fi
else
    uv sync
fi
echo "  Python 依赖安装完成 (.venv)"

# ===== 确保脚本可执行 =====
chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true

# ===== 设置项目目录权限 =====
echo ""
echo "设置目录权限 (用户: ${CURRENT_USER})..."
chown -R "${CURRENT_USER}:${CURRENT_USER}" "$INSTALL_DIR"
chown -R "${CURRENT_USER}:${CURRENT_USER}" "$MIHOMO_HOME"
echo "  ${INSTALL_DIR} → ${CURRENT_USER}"
echo "  ${MIHOMO_HOME} → ${CURRENT_USER}"

# ===== [7/7] 安装 systemd 服务 =====
echo "[7/7] 安装 systemd 服务..."

MIHOMO_BIN="${MIHOMO_HOME}/mihomo"
CONFIG_FILE="${MIHOMO_HOME}/config.yaml"

# 处理 mihomo.service
sed \
    -e "s|__USER__|${CURRENT_USER}|g" \
    -e "s|__MIHOMO_BIN__|${MIHOMO_BIN}|g" \
    -e "s|__MIHOMO_HOME__|${MIHOMO_HOME}|g" \
    -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
    -e "s|__PROJECT_DIR__|${INSTALL_DIR}|g" \
    "${INSTALL_DIR}/systemd/mihomo.service" \
    | sudo tee /etc/systemd/system/mihomo.service > /dev/null

# 处理 auto-mihomo-mcp.service
sed \
    -e "s|__USER__|${CURRENT_USER}|g" \
    -e "s|__PROJECT_DIR__|${INSTALL_DIR}|g" \
    "${INSTALL_DIR}/systemd/auto-mihomo-mcp.service" \
    | sudo tee /etc/systemd/system/auto-mihomo-mcp.service > /dev/null

# 安装 openclaw-gateway drop-in (仅当检测到 OpenClaw 应用目录时)
# Base unit 由 OpenClaw 自身管理 (openclaw onboard --install-daemon)
OPENCLAW_APP_DIR="${USER_HOME}/.openclaw"
DROPIN_DIR="/etc/systemd/system/openclaw-gateway.service.d"
INSTALL_OPENCLAW_GW=false

if [[ -d "$OPENCLAW_APP_DIR" ]]; then
    echo "  检测到 OpenClaw: ${OPENCLAW_APP_DIR}"

    # 解析 Node.js 可执行文件路径, 优先使用 nvm (systemd PATH 中没有 nvm bin dir)
    _node_bin=""
    # 1. nvm: 扫描最新版本
    if [[ -d "${USER_HOME}/.nvm/versions/node" ]]; then
        _node_bin=$(find "${USER_HOME}/.nvm/versions/node" -maxdepth 3 -name node -type f 2>/dev/null \
            | sort -rV | head -1)
    fi
    # 2. 当前 PATH (SSH 会话下可能已有)
    [[ -z "$_node_bin" ]] && _node_bin=$(command -v node 2>/dev/null || true)
    # 3. 常见系统路径
    if [[ -z "$_node_bin" ]]; then
        for _p in /usr/local/bin/node /usr/bin/node; do
            [[ -x "$_p" ]] && _node_bin="$_p" && break
        done
    fi
    NODE_DIR=$(dirname "${_node_bin:-/usr/bin/node}")
    echo "  Node.js: ${_node_bin:-未找到, 使用默认路径} → PATH 注入: ${NODE_DIR}"
    unset _node_bin _p

    sudo mkdir -p "$DROPIN_DIR"
    sed \
        -e "s|__PROJECT_DIR__|${INSTALL_DIR}|g" \
        -e "s|__NODE_DIR__|${NODE_DIR}|g" \
        "${INSTALL_DIR}/systemd/openclaw-gateway.service.d/10-auto-mihomo.conf" \
        | sudo tee "${DROPIN_DIR}/10-auto-mihomo.conf" > /dev/null
    echo "  drop-in 已安装: ${DROPIN_DIR}/10-auto-mihomo.conf"
    INSTALL_OPENCLAW_GW=true
else
    echo "  跳过 openclaw-gateway drop-in (未检测到 ${OPENCLAW_APP_DIR})"
fi

sudo systemctl daemon-reload
sudo systemctl enable mihomo
sudo systemctl enable auto-mihomo-mcp
if [[ "$INSTALL_OPENCLAW_GW" == "true" ]]; then
    # openclaw-gateway 由 OpenClaw 自身管理; 按当前状态决定操作
    if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
        sudo systemctl restart openclaw-gateway
        echo "  openclaw-gateway 已重启 (drop-in 已生效)"
    elif systemctl list-unit-files openclaw-gateway.service &>/dev/null 2>&1 \
         && systemctl cat openclaw-gateway &>/dev/null 2>&1; then
        sudo systemctl start openclaw-gateway
        echo "  openclaw-gateway 已启动"
    else
        echo "  提示: openclaw-gateway base unit 未注册, 请运行: openclaw onboard --install-daemon"
    fi
fi
echo "  systemd 服务已安装并设为开机启动"

# ===== 预创建代理环境文件 =====
echo ""
echo "预创建代理环境文件..."

# /etc/profile.d/proxy.sh — 登录 shell 用 (bash/zsh)
sudo touch /etc/profile.d/proxy.sh
sudo chown "${CURRENT_USER}:${CURRENT_USER}" /etc/profile.d/proxy.sh
sudo chmod 644 /etc/profile.d/proxy.sh
echo "  /etc/profile.d/proxy.sh (登录 shell)"

# /etc/auto-mihomo/proxy.env — systemd 服务用 (EnvironmentFile=)
sudo mkdir -p /etc/auto-mihomo
sudo touch /etc/auto-mihomo/proxy.env
sudo chown "${CURRENT_USER}:${CURRENT_USER}" /etc/auto-mihomo /etc/auto-mihomo/proxy.env
sudo chmod 644 /etc/auto-mihomo/proxy.env
echo "  /etc/auto-mihomo/proxy.env (systemd 服务)"
echo "  已授权给 ${CURRENT_USER}"

# 兼容旧排障路径: 安装目录中的 config.yaml 指向 Mihomo workdir 配置
ln -sfn "${MIHOMO_HOME}/config.yaml" "${INSTALL_DIR}/config.yaml" 2>/dev/null || true

# ===== 配置 sudoers =====
echo ""
echo "配置 sudoers (仅限 mihomo 服务管理)..."
SUDOERS_FILE="/etc/sudoers.d/auto-mihomo"
sudo tee "$SUDOERS_FILE" > /dev/null <<SUDOERS_EOF
# Auto-Mihomo: 允许服务用户免密管理 mihomo 服务 (最小权限)
${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mihomo
${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start mihomo
${CURRENT_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop mihomo
SUDOERS_EOF
sudo chmod 440 "$SUDOERS_FILE"
if sudo visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    echo "  sudoers 规则已安装: ${SUDOERS_FILE}"
else
    echo "  错误: sudoers 语法校验失败, 已移除"
    sudo rm -f "$SUDOERS_FILE"
fi

# ===== 配置定时任务 (以服务用户身份) =====
echo ""
echo "配置定时任务 (北京时间每天 12:00 自动更新订阅, 用户: ${CURRENT_USER})..."
CRON_TZ_LINE="CRON_TZ=Asia/Shanghai"
CRON_CMD="0 12 * * * ${INSTALL_DIR}/scripts/cron_update_proxy.sh"

CURRENT_CRONTAB="$(sudo -u "$CURRENT_USER" crontab -l 2>/dev/null || true)"

# 清理旧版本默认任务，避免重复执行 (每日 03:00 update_sub.sh)
CURRENT_CRONTAB="$(printf '%s\n' "$CURRENT_CRONTAB" | grep -vF "${INSTALL_DIR}/scripts/update_sub.sh >> ${INSTALL_DIR}/cron.log 2>&1" || true)"

if printf '%s\n' "$CURRENT_CRONTAB" | grep -qF "${INSTALL_DIR}/scripts/cron_update_proxy.sh"; then
    echo "  定时任务已存在, 跳过"
else
    {
        # 先写入现有 crontab（去除末尾空行由 crontab 自己处理）
        if [[ -n "${CURRENT_CRONTAB//$'\n'/}" ]]; then
            printf '%s\n' "$CURRENT_CRONTAB"
        fi
        # 没有 CRON_TZ=Asia/Shanghai 时再添加，避免重复行
        if ! printf '%s\n' "$CURRENT_CRONTAB" | grep -qFx "$CRON_TZ_LINE"; then
            printf '%s\n' "$CRON_TZ_LINE"
        fi
        printf '%s\n' "$CRON_CMD"
    } | sudo -u "$CURRENT_USER" crontab -
    echo "  定时任务已添加: ${CRON_CMD}"
fi

# ===== .env 文件 =====
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
    chown "${CURRENT_USER}:${CURRENT_USER}" "${INSTALL_DIR}/.env"
    echo ""
    echo "已创建 .env 文件, 请编辑填写订阅 URL"
fi

# ===== 完成 =====
echo ""
echo "============================================"
echo "  安装完成!"
echo "============================================"
echo ""
echo "  服务用户: ${CURRENT_USER}"
echo "  项目目录: ${INSTALL_DIR}"
echo "  Mihomo:   ${MIHOMO_HOME}"
echo ""
echo "后续步骤:"
echo ""
echo "  1. 编辑 .env 填写 Clash 订阅 URL:"
echo "     nano ${INSTALL_DIR}/.env"
echo ""
echo "  2. 首次运行更新脚本 (以 ${CURRENT_USER} 身份):"
echo "     sudo -u ${CURRENT_USER} bash ${INSTALL_DIR}/scripts/update_sub.sh"
echo ""
echo "  3. 启动 MCP 服务:"
echo "     sudo systemctl start auto-mihomo-mcp"
echo ""
echo "  4. 验证代理:"
echo "     source /etc/profile.d/proxy.sh"
echo "     curl -I https://www.google.com"
echo ""
echo "  5. 查看 MCP API 文档:"
echo "     http://<树莓派IP>:8900/docs"
echo ""
echo "定时任务: 北京时间每天 12:00 自动更新订阅 (用户: ${CURRENT_USER})"
echo "日志文件: ${INSTALL_DIR}/update.log"
echo "Cron 日志: ${INSTALL_DIR}/cron-noon-update.log"
echo ""
echo "常用维护命令:"
echo "  自检:       bash ${INSTALL_DIR}/scripts/post_deploy_self_check.sh"
echo "  生成密钥:   bash ${INSTALL_DIR}/scripts/generate_secrets.sh --write-env"
echo "  同步1Password: bash ${INSTALL_DIR}/scripts/sync_secrets_to_1password.sh --vault auto-mihomo --item <ITEM>"
echo "  一键轮换:   bash ${INSTALL_DIR}/scripts/rotate_secrets_and_restart.sh --vault auto-mihomo --item <ITEM>"
