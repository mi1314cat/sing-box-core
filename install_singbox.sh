#!/bin/bash

set -e

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
    ARCH="arm64"
elif [[ "$ARCH" == "armv7l" ]] || [[ "$ARCH" == "armv6l" ]]; then
    ARCH="armv7"
elif [[ "$ARCH" == "i386" ]] || [[ "$ARCH" == "i686" ]]; then
    ARCH="386"
else
    echo "❌ 不支持的架构: $ARCH"
    exit 1
fi

# 检测系统类型
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif grep -qi ubuntu /etc/os-release; then
    OS="ubuntu"
elif grep -qi debian /etc/os-release; then
    OS="debian"
else
    echo "❌ 不支持的系统，仅支持 Ubuntu、Debian、Alpine"
    exit 1
fi

# 获取最新版本号
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
if [ -z "$VERSION" ]; then
    echo "❌ 无法获取 sing-box 最新版本"
    exit 1
fi

echo "✅ 检测到系统: $OS"
echo "✅ 检测到架构: $ARCH"
echo "✅ 最新版本: $VERSION"

# 下载文件
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
echo "📥 正在下载 $DOWNLOAD_URL"
curl -L -o "sing-box-${VERSION}-linux-${ARCH}.tar.gz" "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo "❌ 下载失败"
    exit 1
fi

# 检查 tar 包有效性
if ! tar -tzf "sing-box-${VERSION}-linux-${ARCH}.tar.gz" >/dev/null 2>&1; then
    echo "❌ 下载的文件不是有效的 tar.gz 包"
    exit 1
fi

# 解压
tar -xzf "sing-box-${VERSION}-linux-${ARCH}.tar.gz"

# 创建目标目录
TARGET_DIR="/root/catmi/singbox"
mkdir -p "$TARGET_DIR"

# 移动文件
cp "sing-box-${VERSION}-linux-${ARCH}/sing-box" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/sing-box"

echo "✅ sing-box 已安装到 $TARGET_DIR"

# 设置 systemd (Ubuntu/Debian) 或 OpenRC (Alpine)
if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
    cat > /etc/systemd/system/singbox.service <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
ExecStart=$TARGET_DIR/sing-box run -c $TARGET_DIR/config.json
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable singbox
    echo "✅ 已安装 systemd 服务文件：singbox.service"
    echo "👉 使用以下命令管理："
    echo "   systemctl start singbox"
    echo "   systemctl stop singbox"
    echo "   systemctl status singbox"

elif [ "$OS" == "alpine" ]; then
    cat > /etc/init.d/singbox <<EOF
#!/sbin/openrc-run

description="sing-box Service"

command="$TARGET_DIR/sing-box"
command_args="run -c $TARGET_DIR/config.json"
pidfile="/run/singbox.pid"
command_background=true
start_stop_daemon_args="--background --make-pidfile --pidfile \$pidfile"

depend() {
    need net
}
EOF

    chmod +x /etc/init.d/singbox
    rc-update add singbox default
    echo "✅ 已安装 OpenRC 服务文件：singbox"
    echo "👉 使用以下命令管理："
    echo "   rc-service singbox start"
    echo "   rc-service singbox stop"
    echo "   rc-service singbox status"
fi

# 清理临时文件
cd ~
rm -rf "$TEMP_DIR"

echo "🎉 安装完成"
