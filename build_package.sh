#!/usr/bin/env bash
# =============================================================================
# build_package.sh - 构建部署包 (在开发机上运行)
#
# 在有网络的开发机上预下载所有依赖, 打包成可离线部署的 tarball。
# 解决树莓派"需要代理才能上网, 但需要上网才能装代理"的鸡生蛋问题。
#
# 包含:
#   - Mihomo 二进制 (ARM64)
#   - GeoIP 数据库
#   - uv 包管理器 (ARM64)
#   - Python 依赖 wheels (ARM64)
#   - 项目所有脚本和配置
#
# 用法:
#   bash build_package.sh                    # 默认 ARM64 (树莓派5)
#   bash build_package.sh --arch armv7       # 树莓派3/4 32位
#   bash build_package.sh --arch amd64       # x86_64
#   bash build_package.sh --mihomo v1.19.31  # 指定 Mihomo 版本
#   bash build_package.sh --py 3.12          # 指定 Python 版本
# =============================================================================
set -euo pipefail

# ===== 默认配置 =====
TARGET_ARCH="arm64"
MIHOMO_VERSION="v1.19.31"
PYTHON_VERSION="3.13"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 读取项目版本号
APP_VERSION=$(cat "${PROJECT_DIR}/version.txt" | tr -d '[:space:]')
GIT_HASH=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ===== 解析参数 =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)   TARGET_ARCH="$2";     shift 2 ;;
        --mihomo) MIHOMO_VERSION="$2";  shift 2 ;;
        --py)     PYTHON_VERSION="$2";  shift 2 ;;
        -h|--help)
            echo "用法: bash build_package.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --arch <ARCH>       目标架构: arm64 (默认), armv7, amd64"
            echo "  --mihomo <VERSION>  Mihomo 版本 (默认: ${MIHOMO_VERSION})"
            echo "  --py <VERSION>      目标 Python 版本: 3.11 (默认), 3.12"
            echo "  -h, --help          显示帮助"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# ===== 架构映射 =====
case "$TARGET_ARCH" in
    arm64|aarch64)
        MIHOMO_ARCH="linux-arm64"
        UV_ARCH="aarch64-unknown-linux-gnu"
        PIP_PLATFORMS=("manylinux2014_aarch64" "manylinux_2_17_aarch64" "linux_aarch64")
        ;;
    armv7|armhf)
        MIHOMO_ARCH="linux-armv7"
        UV_ARCH="armv7-unknown-linux-gnueabihf"
        PIP_PLATFORMS=("manylinux2014_armv7l" "linux_armv7l")
        ;;
    amd64|x86_64)
        MIHOMO_ARCH="linux-amd64"
        UV_ARCH="x86_64-unknown-linux-gnu"
        PIP_PLATFORMS=("manylinux2014_x86_64" "manylinux_2_17_x86_64" "linux_x86_64")
        ;;
    *)
        echo "错误: 不支持的架构: ${TARGET_ARCH}"
        echo "支持: arm64, armv7, amd64"
        exit 1
        ;;
esac

# Python 版本号 (去掉点: 3.13 -> 313)
PY_VER_SHORT="${PYTHON_VERSION//./}"

# ===== 主机平台和前置依赖检查 =====
HOST_PLATFORM=$(uname -s)
case "$HOST_PLATFORM" in
    Darwin)
        # macOS 自带 BSD tar; 使用 Homebrew GNU tar 避免写入 ._* 扩展属性文件。
        if ! command -v gtar &>/dev/null; then
            if command -v brew &>/dev/null; then
                echo "未检测到 GNU tar, 正在通过 Homebrew 安装..."
                brew install gnu-tar
            else
                echo "错误: macOS 需要 GNU tar (gtar)"
                echo "请先安装 Homebrew, 再运行: brew install gnu-tar"
                exit 1
            fi
        fi
        TAR_CMD="gtar"
        ;;
    Linux)
        # Debian/Ubuntu 等 Linux 发行版的 tar 默认为 GNU tar。
        if ! command -v tar &>/dev/null; then
            echo "错误: Linux 上未找到 tar, 请先安装 tar 软件包"
            exit 1
        fi
        if ! tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
            echo "错误: Linux 构建需要 GNU tar, 当前 tar 不是 GNU 实现"
            exit 1
        fi
        TAR_CMD="tar"
        ;;
    *)
        echo "错误: 不支持的构建平台: ${HOST_PLATFORM}"
        echo "支持的平台: macOS (Darwin), Linux"
        exit 1
        ;;
esac

echo "============================================"
echo "  Auto-Mihomo 构建部署包"
echo "============================================"
echo "  项目版本:     ${APP_VERSION} (${GIT_HASH})"
echo "  构建平台:     ${HOST_PLATFORM} (${TAR_CMD})"
echo "  目标架构:     ${TARGET_ARCH} (${MIHOMO_ARCH})"
echo "  Mihomo 版本:  ${MIHOMO_VERSION}"
echo "  Python 版本:  ${PYTHON_VERSION}"
echo "  构建时间:     ${BUILD_DATE}"
echo "============================================"
echo ""

# ===== 准备构建目录 =====
BUILD_DIR=$(mktemp -d)
VENDOR_DIR="${BUILD_DIR}/auto-mihomo/vendor"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$VENDOR_DIR/wheels"

# ===== 1. 复制项目文件 =====
echo "[1/5] 复制项目文件..."
rsync -a \
    --exclude='.git' \
    --exclude='.idea' \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.env' \
    --exclude='subscription.yaml' \
    --exclude='config.yaml' \
    --exclude='*.log' \
    --exclude='dist/' \
    --exclude='vendor/' \
    --exclude='.DS_Store' \
    --exclude='._*' \
    "${PROJECT_DIR}/" "${BUILD_DIR}/auto-mihomo/"
echo "  完成"

# ===== 2. 下载 Mihomo 二进制 =====
echo "[2/5] 下载 Mihomo ${MIHOMO_VERSION} (${MIHOMO_ARCH})..."
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"
MIHOMO_ARCHIVE="${BUILD_DIR}/mihomo.gz"
MIHOMO_TMP="${VENDOR_DIR}/mihomo.tmp"

if ! curl --fail --show-error --location \
    --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout 15 --max-time 300 \
    --output "$MIHOMO_ARCHIVE" "$MIHOMO_URL"; then
    echo "错误: Mihomo 下载失败: ${MIHOMO_URL}" >&2
    exit 1
fi

if ! gzip -t "$MIHOMO_ARCHIVE" 2>/dev/null; then
    echo "错误: Mihomo 压缩包不完整或格式无效: ${MIHOMO_ARCHIVE}" >&2
    exit 1
fi

gunzip -c "$MIHOMO_ARCHIVE" > "$MIHOMO_TMP"
if [[ ! -s "$MIHOMO_TMP" ]]; then
    echo "错误: Mihomo 解压后文件为空" >&2
    exit 1
fi
mv "$MIHOMO_TMP" "${VENDOR_DIR}/mihomo"
chmod +x "${VENDOR_DIR}/mihomo"
echo "  $(ls -lh "${VENDOR_DIR}/mihomo" | awk '{print $5}') — ${VENDOR_DIR}/mihomo"

# ===== 3. 下载 GeoIP 数据 =====
echo "[3/5] 下载 GeoIP 数据库..."
GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
for file in geoip.dat geosite.dat country.mmdb; do
    echo "  下载 ${file}..."
    curl -sL "${GEO_BASE}/${file}" -o "${VENDOR_DIR}/${file}"
done
echo "  完成"

# ===== 4. 下载 uv (目标架构) =====
echo "[4/5] 下载 uv (${UV_ARCH})..."
UV_URL="https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}.tar.gz"
curl -sL "$UV_URL" | "$TAR_CMD" xz -C "${VENDOR_DIR}/" --strip-components=1 uv-${UV_ARCH}/uv uv-${UV_ARCH}/uvx 2>/dev/null || \
curl -sL "$UV_URL" | "$TAR_CMD" xz -C "${VENDOR_DIR}/" --strip-components=1
# 只保留 uv 和 uvx 二进制
find "${VENDOR_DIR}" -maxdepth 1 -type f ! -name 'uv' ! -name 'uvx' ! -name 'mihomo' ! -name '*.dat' ! -name '*.mmdb' -delete 2>/dev/null || true
chmod +x "${VENDOR_DIR}/uv" "${VENDOR_DIR}/uvx" 2>/dev/null || true
echo "  $(ls -lh "${VENDOR_DIR}/uv" | awk '{print $5}') — ${VENDOR_DIR}/uv"

# ===== 5. 下载 Python wheels =====
echo "[5/5] 下载 Python wheels (${TARGET_ARCH}, Python ${PYTHON_VERSION})..."

# 先确保本地有 uv.lock
cd "$PROJECT_DIR"
if [[ ! -f "uv.lock" ]]; then
    echo "  生成 uv.lock..."
    uv lock
fi
cp uv.lock "${BUILD_DIR}/auto-mihomo/uv.lock"

# 导出依赖列表
REQUIREMENTS_TMP=$(mktemp)
uv export --format requirements-txt --no-hashes > "$REQUIREMENTS_TMP"

# 创建临时 venv 并安装 pip (uv 默认不包含 pip)
echo "  准备 pip 环境..."
PIP_VENV=$(mktemp -d)/venv
uv venv --seed --quiet "$PIP_VENV"
PIP_CMD="${PIP_VENV}/bin/pip"

# 构建 --platform 参数
PLATFORM_ARGS=()
for plat in "${PIP_PLATFORMS[@]}"; do
    PLATFORM_ARGS+=(--platform "$plat")
done

# 使用 pip download 进行跨平台下载
echo "  下载 wheels..."
"$PIP_CMD" download \
    -r "$REQUIREMENTS_TMP" \
    "${PLATFORM_ARGS[@]}" \
    --python-version "$PY_VER_SHORT" \
    --only-binary=:all: \
    -d "${VENDOR_DIR}/wheels/" \
    --quiet 2>/dev/null || {
        echo "  批量下载失败, 尝试逐包下载..."
        while IFS= read -r line; do
            # 跳过注释和空行
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            # 提取包名 (去掉版本约束)
            pkg=$(echo "$line" | sed 's/[>=<;].*//' | xargs)
            [[ -z "$pkg" ]] && continue
            "$PIP_CMD" download \
                "$pkg" \
                "${PLATFORM_ARGS[@]}" \
                --python-version "$PY_VER_SHORT" \
                --only-binary=:all: \
                -d "${VENDOR_DIR}/wheels/" \
                --quiet 2>/dev/null \
            && echo "    ${pkg}" \
            || echo "    ${pkg} (跳过, 将在线安装)"
        done < "$REQUIREMENTS_TMP"
    }

rm -f "$REQUIREMENTS_TMP"
rm -rf "$(dirname "$PIP_VENV")"

WHEEL_COUNT=$(find "${VENDOR_DIR}/wheels" -name '*.whl' | wc -l | tr -d ' ')
echo "  共 ${WHEEL_COUNT} 个 wheels"

# ===== 写入版本信息 =====
cat > "${BUILD_DIR}/auto-mihomo/version.txt" <<VERSION_EOF
${APP_VERSION}
commit: ${GIT_HASH}
build:  ${BUILD_DATE}
arch:   ${TARGET_ARCH}
mihomo: ${MIHOMO_VERSION}
VERSION_EOF

# ===== 打包 =====
echo ""
echo "正在打包..."

DIST_DIR="${PROJECT_DIR}/dist"
mkdir -p "$DIST_DIR"
TARBALL="${DIST_DIR}/auto-mihomo-${APP_VERSION}-${TARGET_ARCH}-${GIT_HASH}.tar.gz"

# macOS 使用 gtar, Linux 使用系统 GNU tar。
"$TAR_CMD" -czf "$TARBALL" -C "$BUILD_DIR" auto-mihomo

# ===== 输出摘要 =====
TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')

echo ""
echo "============================================"
echo "  构建完成!"
echo "============================================"
echo ""
echo "  版本:   ${APP_VERSION} (${GIT_HASH})"
echo "  构建:   ${BUILD_DATE}"
echo "  部署包: ${TARBALL}"
echo "  大小:   ${TARBALL_SIZE}"
echo ""
echo "  包含:"
echo "    - Mihomo ${MIHOMO_VERSION} (${MIHOMO_ARCH})"
echo "    - GeoIP 数据 (geoip.dat, geosite.dat, country.mmdb)"
echo "    - uv 包管理器 (${UV_ARCH})"
echo "    - Python wheels x${WHEEL_COUNT}"
echo "    - 项目脚本和配置"
echo ""
echo "  部署到树莓派:"
echo "    scp ${TARBALL} pi@<IP>:~/"
echo "    ssh pi@<IP>"
echo "    tar xzf $(basename "$TARBALL")"
echo "    cd auto-mihomo"
echo "    bash install.sh"
