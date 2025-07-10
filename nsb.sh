#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(arch)

# 介绍信息
clear
cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                   catmi.singbox
       -----------------------------------------
EOF
echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
echo -e "${GREEN}Version: ${PLAIN}1.0.0"
echo -e "----------------------------------------"

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}
# 生成端口的函数
generate_port() {
    local protocol="$1"
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        ss -tuln | grep -q ":$port\b" || { echo "$port"; return $port; }
        echo "端口 $port 被占用，请输入其他端口"
    done
}
# 随机生成 WS 路径
generate_ws_path() {
    echo "/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)"
}
mkdir -p /root/catmi/singbox



#!/bin/bash

set -e

install_singbox() {
   
    echo "----------------------------------------"
    echo "请选择需要安装的 SING-BOX 版本:"
    echo "1. 正式版"
    echo "2. 测试版"
    read -p "输入你的选项 (1-2, 默认: 1): " version_choice
    version_choice=${version_choice:-1}

    echo "🛠 正在获取版本信息..."

    api_data=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases")

    if [ "$version_choice" -eq 2 ]; then
        # 测试版：找到第一个 "prerelease": true 的 tag
        latest_version_tag=$(echo "$api_data" | awk '
            /"prerelease": true/ {p=1}
            p && /"tag_name":/ {
                gsub(/"|,/, "", $2);
                print $2;
                exit
            }' FS=': ')
    else
        # 正式版：找到第一个 "prerelease": false 的 tag
        latest_version_tag=$(echo "$api_data" | awk '
            /"prerelease": false/ {p=1}
            p && /"tag_name":/ {
                gsub(/"|,/, "", $2);
                print $2;
                exit
            }' FS=': ')
    fi

    if [ -z "$latest_version_tag" ]; then
        echo "❌ 无法获取版本信息"
        exit 1
    fi

    latest_version=${latest_version_tag#v}
    echo "✅ 最新版本: $latest_version_tag"

    arch=$(uname -m)
    echo "🖥 本机架构: $arch"
    case ${arch} in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        armv7l | armv6l) arch="armv7" ;;
        i386 | i686) arch="386" ;;
        *) echo "❌ 不支持的架构: $arch" && exit 1 ;;
    esac
    echo "✅ 转换后架构: $arch"

    package_name="sing-box-${latest_version}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"
    temp_dir=$(mktemp -d)
    echo "📥 下载: $url"
    curl -L -o "${temp_dir}/${package_name}.tar.gz" "$url"
    if [ $? -ne 0 ]; then
        echo "❌ 下载失败"
        exit 1
    fi

    if ! tar -tzf "${temp_dir}/${package_name}.tar.gz" >/dev/null 2>&1; then
        echo "❌ 下载的文件不是有效的 tar.gz 包"
        exit 1
    fi

    tar -xzf "${temp_dir}/${package_name}.tar.gz" -C "$temp_dir"

    install_dir="/root/catmi/singbox"
    mkdir -p "$install_dir"
    mv "${temp_dir}/${package_name}/sing-box" "$install_dir/"
    chown root:root "$install_dir/sing-box"
    chmod +x "$install_dir/sing-box"

    rm -rf "$temp_dir"

    echo "✅ sing-box 已安装到 $install_dir"

    cat > /etc/systemd/system/singbox.service <<EOF
[Unit]
Description=sing-box Service
After=network.target

[Service]
ExecStart=$install_dir/sing-box run -c $install_dir/config.json
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable singbox

    echo "✅ 已生成并启用 systemd 服务文件: singbox.service"
    echo "👉 使用以下命令管理 sing-box："
    echo "   systemctl start singbox"
    echo "   systemctl stop singbox"
    echo "   systemctl status singbox"
    echo "🎉 安装完成"
}

install_singbox




openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /root/catmi/singbox/server.key -out /root/catmi/singbox/server.crt \
    -subj "/CN=bing.com" -days 36500 && \




# 定义函数，返回随机选择的域名
random_website() {
   domains=(
        "one-piece.com"
        "lovelive-anime.jp"
        "swift.com"
        "academy.nvidia.com"
        "cisco.com"
        "amd.com"
        "apple.com"
        "music.apple.com"
        "fandom.com"
        "tidal.com"
        "mora.jp"
        "booth.pm"
        "leercapitulo.com"
        "itunes.apple.com"
        "download-installer.cdn.mozilla.net"
        "images-na.ssl-images-amazon.com"
        "swdist.apple.com"
        "swcdn.apple.com"
        "updates.cdn-apple.com"
        "mensura.cdn-apple.com"
        "osxapps.itunes.apple.com"
        "aod.itunes.apple.com"
        "www.google-analytics.com"
        "dl.google.com"
    )


    total_domains=${#domains[@]}
    random_index=$((RANDOM % total_domains))
    
    # 输出选择的域名
    echo "${domains[random_index]}"
}
# 生成密钥
read -rp "请输入回落域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)



# 提示输入监听端口号

read -p "请输入 reality 监听端口: " reality_port
if [[ -z "$reality_port" ]]; then
    reality_port=$((RANDOM % 55535 + 10000))  # 生成 10000-65535 的随机端口
fi

hysteria2_port=$((reality_port + 1))
tuic_port=$((reality_port + 2))
anytls_port=$((reality_port + 3))
Vmess_port=$((reality_port + 4))
anyreality_port=$((reality_port + 5))

echo "已设置端口如下："
echo "reality:   $reality_port"
echo "hysteria2: $hysteria2_port"
echo "tuic:      $tuic_port"
echo "anytls:    $anytls_port"
echo "Vmess:    $Vmess_port"
# 生成 UUID 和 WS 路径
UUID=$(generate_uuid)

WS_PATH1=$(generate_ws_path)


key_pair=$(/root/catmi/singbox/sing-box generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')

short_id=$(/root/catmi/singbox/sing-box generate rand --hex 8)
hy_password=$(/root/catmi/singbox/sing-box generate rand --hex 8)



# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)

# 选择使用哪个公网 IP 地址
echo "请选择要使用的公网 IP 地址:"
echo "1. $PUBLIC_IP_V4"
echo "2. $PUBLIC_IP_V6"
read -p "请输入对应的数字选择 [默认1]: " IP_CHOICE

# 如果没有输入（即回车），则默认选择1
IP_CHOICE=${IP_CHOICE:-1}

# 选择公网 IP 地址
if [ "$IP_CHOICE" -eq 1 ]; then
    PUBLIC_IP=$PUBLIC_IP_V4
    # 设置第二个变量为“空”
    VALUE=""
    link_ip="$PUBLIC_IP"
elif [ "$IP_CHOICE" -eq 2 ]; then
    PUBLIC_IP=$PUBLIC_IP_V6
    # 设置第二个变量为 "[::]:"
    VALUE="[::]:"
    link_ip="[$PUBLIC_IP]"
else
    echo "无效选择，退出脚本"
    exit 1
fi

# 配置文件生成

cat <<EOF > /root/catmi/singbox/config.json
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
  
    {
      "type": "vmess",
      "tag": "VMESS-WS",
      "listen": "::",
      "listen_port": $Vmess_port,
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH1}"
      }
    },
    {
      "sniff": true,
      "sniff_override_destination": true,
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $reality_port,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$dest_server",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    },
    {
        "sniff": true,
        "sniff_override_destination": true,
        "type": "hysteria2",
        "tag": "hy2-in",
        "listen": "::",
        "listen_port": $hysteria2_port,
        "users": [
            {
                "password": "$hy_password"
            }
        ],
        "tls": {
            "enabled": true,
            "alpn": [
                "h3"
            ],
            "certificate_path": "/root/catmi/singbox/server.crt",
            "key_path": "/root/catmi/singbox/server.key"
        }
    },
    {
            "type":"tuic",
            "tag":"tuic",
            "listen":"::",
            "listen_port":$tuic_port,
            "users":[
                {
                    "uuid":"$UUID",
                    "password":"$hy_password"
                }
            ],
            "congestion_control": "bbr",
            "zero_rtt_handshake": false,
            "tls":{
                "enabled":true,
                "alpn":[
                    "h3"
                ],
                "certificate_path":"/root/catmi/singbox/server.crt",
                "key_path":"/root/catmi/singbox/server.key"
            }
        },
        {
            "type":"anytls",
            "tag":"anytls",
            "listen":"::",
            "listen_port":$anytls_port,
            "users":[
                {
                    "password":"$UUID"
                }
            ],
            "padding_scheme":[],
            "tls":{
                "enabled":true,
                "certificate_path":"/root/catmi/singbox/server.crt",
                "key_path":"/root/catmi/singbox/server.key"
            }
        },{
            "type": "anytls",
            "tag":"anyreality",
            "listen": "::",
            "listen_port": $anyreality_port,
            "users": [
                {
                    "name": "catmicos",
                    "password": "$UUID"
                }
            ],
            "padding_scheme": [
                "stop=8",
                "0=30-30",
                "1=100-400",
                "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000",
                "6=500-1000",
                "7=500-1000"
            ],
            "tls": {
                "enabled": true,
                "server_name": "$dest_server",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$dest_server",
                        "server_port": 443
                    },
                    "private_key": "$private_key",
                    "short_id": ["$short_id"]
                }
            }
        }
  ],
    "outbounds": [],
  "route": {
    "rules": [
      {
        "type": "default",
        "action": "direct"
      }
    ]
  }
}







EOF

# 重载systemd服务配置
sudo systemctl daemon-reload
sudo systemctl enable singbox
sudo systemctl restart singbox || { echo "重启 singbox 服务失败"; exit 1; }


# 保存信息到文件
OUTPUT_DIR="/root/catmi/singbox"
mkdir -p "$OUTPUT_DIR"
cat << EOF > /root/catmi/singbox/clash-meta.yaml
  - name: Hysteria2
    server: $PUBLIC_IP
    port: $hysteria2_port
    type: hysteria2
    up: 40 Mbps
    down: 150 Mbps
    sni: bing.com
    password: $hy_password
    skip-cert-verify: true
    alpn:
      - h3
  - name: Reality
    port: $reality_port
    server: $PUBLIC_IP
    type: vless
    network: tcp
    udp: true
    tls: true
    servername: $dest_server
    skip-cert-verify: true
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    uuid: $UUID
    flow: xtls-rprx-vision
    client-fingerprint: chrome
  - name: vmess-ws-tls
    type: vmess
    server: $PUBLIC_IP
    port: $Vmess_port
    cipher: auto
    uuid: $UUID
    alterId: 0
    tls: false
    network: ws
    ws-opts:
      path: ${WS_PATH1}
      headers: {}

  - name: anytls
    type: anytls
    server: $PUBLIC_IP
    port: $anytls_port
    password: $UUID
    client-fingerprint: chrome
    udp: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    skip-cert-verify: true
  - name: tuic
    type: tuic
    server: $PUBLIC_IP
    port: $tuic_port
    uuid: $UUID
    password: $hy_password
    alpn:
      - h3
    disable-sni: true
    reduce-rtt: true
    request-timeout: 8000
    udp-relay-mode: native
    congestion-controller: bbr
    skip-cert-verify: true
    
 
EOF
cat << EOF > /root/catmi/singbox/anyreality.json
{
    "dns": {
        "servers": [
            {
                "tag": "google",
                "type": "tls",
                "server": "8.8.8.8"
            },
            {
                "tag": "local",
                "type": "udp",
                "server": "223.5.5.5"
            }
        ],
        "strategy": "ipv4_only"
    },
    "inbounds": [
        {
            "type": "tun",
            "address": "172.19.0.1/30",
            "auto_route": true,
            "strict_route": true
        }
    ],
    "outbounds": [
        {
            "type": "anytls",
            "tag": "anytls-out",
            "server": "$PUBLIC_IP",
            "server_port": $anyreality_port,
            "password": "$UUID",
            "idle_session_check_interval": "30s",
            "idle_session_timeout": "30s",
            "min_idle_session": 5,
            "tls": {
                "enabled": true,
                "disable_sni": false,
                "server_name": "$dest_server",
                "insecure": false,
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                },
                "reality": {
                    "enabled": true,
                    "public_key": "$public_key",
                    "short_id": "$short_id"
                }
            }
        },
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rules": [
            {
                "action": "sniff"
            },
            {
                "protocol": "dns",
                "action": "hijack-dns"
            },
            {
                "ip_is_private": true,
                "outbound": "direct"
            }
        ],
        "default_domain_resolver": "local",
        "auto_detect_interface": true
    }
}

EOF
share_link="
tuic://$UUID:$hy_password@$link_ip:$tuic_port?alpn=h3&congestion_control=bbr#tuic
hysteria2://$hy_password@$link_ip:$hysteria2_port??sni=bing.com&insecure=1#Hysteria2
vless://$UUID@$link_ip:$reality_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Reality
vmess://$UUID@$link_ip:$Vmess_port?encryption=none&allowInsecure=1&type=ws&path=${WS_PATH1}#vmess-ws-tls

"
echo "${share_link}" > /root/catmi/singbox/v2ray.txt



sudo systemctl status singbox

cat /root/catmi/singbox/v2ray.txt
cat /root/catmi/singbox/clash-meta.yaml
