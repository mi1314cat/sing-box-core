install_singbox() {
    BASE_DIR="/root/catmi/singbox"
    CONF_DIR="$BASE_DIR/conf"
    BIN_PATH="$BASE_DIR/sing-box"
    SERVICE_FILE="/etc/systemd/system/sing-box.service"

    echo "请选择需要安装的 SING-BOX 版本:"
    echo "1. 正式版"
    echo "2. 测试版"
    read -p "输入选项 (1-2, 默认: 1): " version_choice
    version_choice=${version_choice:-1}

    mkdir -p "$CONF_DIR"

    # 获取版本
    if [ "$version_choice" -eq 2 ]; then
        echo "Installing Alpha version..."
        latest_version_tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases \
            | jq -r '[.[] | select(.prerelease==true)][0].tag_name')
    else
        echo "Installing Stable version..."
        latest_version_tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases \
            | jq -r '[.[] | select(.prerelease==false)][0].tag_name')
    fi

    latest_version=${latest_version_tag#v}
    echo "Latest version: $latest_version"

    # 架构识别
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) echo "不支持的架构: $arch" ; return 1 ;;
    esac

    echo "本机架构: $arch"

    package_name="sing-box-${latest_version}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"

    TMP_DIR="/tmp/singbox_install"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    echo "下载中..."
    curl -L -o "$TMP_DIR/pkg.tar.gz" "$url" || {
        echo "下载失败"
        return 1
    }

    tar -xzf "$TMP_DIR/pkg.tar.gz" -C "$TMP_DIR"

    install -m 755 "$TMP_DIR/${package_name}/sing-box" "$BIN_PATH"

    rm -rf "$TMP_DIR"

    echo "安装完成: $BIN_PATH"

    # 创建 systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH run -c $CONF_DIR
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box

    echo "systemd 服务已创建: sing-box"
    echo "配置目录: $CONF_DIR"
    echo "请手动创建 config.json 后启动:"
    echo "systemctl start sing-box"
}


install_singbox
