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

bash <(curl -Ls https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install_singbox.sh)

openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /root/catmi/singbox/server.key -out /root/catmi/singbox/server.crt \
    -subj "/CN=bing.com" -days 36500 && \


nginx() {
    apt install -y nginx
    cat << EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    gzip on;

    server {
        listen $VALUE${PORT} ssl http2;
        server_name ${DOMAIN_LOWER};

        ssl_certificate       "${CERT_PATH}";
        ssl_certificate_key   "${KEY_PATH}";
        
        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;
        ssl_protocols    TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        location / {
            proxy_pass https://pan.imcxx.com; #伪装网址
            proxy_redirect off;
            proxy_ssl_server_name on;
            sub_filter_once off;
            sub_filter "pan.imcxx.com" \$server_name;
            proxy_set_header Host "pan.imcxx.com";
            proxy_set_header Referer \$http_referer;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header User-Agent \$http_user_agent;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Accept-Language "zh-CN";
        }

        location ${WS_PATH} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:9999;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
        location ${WS_PATH1} {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:9998;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
        
    }
}

EOF


    systemctl reload nginx
}

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


ssl() {
    set -e

# 提供操作选项供用户选择
echo "请选择要执行的操作："
echo "1) 有80和443端口"
echo "2) 无80 443端口"
read -p "请输入选项 (1 或 2): " choice

# 提示用户输入域名和电子邮件地址
read -p "请输入域名: " DOMAIN

# 将用户输入的域名转换为小写
DOMAIN_LOWER=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

read -p "请输入电子邮件地址: " EMAIL

# 创建目标目录
TARGET_DIR="/root/catmi"
mkdir -p "$TARGET_DIR"

if [ "$choice" -eq 1 ]; then
    # 选项 1: 安装更新、克隆仓库并执行脚本
    echo "执行安装acme证书..."

    # 更新系统并安装必要的依赖项
    echo "更新系统并安装依赖项..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install ufw -y
    sudo apt install -y curl socat git cron openssl
    ufw disable
    # 安装 acme.sh
    echo "安装 acme.sh..."
    curl https://get.acme.sh | sh

    # 设置路径
    export PATH="$HOME/.acme.sh:$PATH"

    # 注册账户
    echo "注册账户..."
    "$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL"

    # 申请 SSL 证书
    echo "申请 SSL 证书..."
    if ! "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN_LOWER"; then
        echo "证书申请失败，删除已生成的文件和文件夹。"
        rm -f "$HOME/${DOMAIN_LOWER}.key" "$HOME/${DOMAIN_LOWER}.crt"
        "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN_LOWER"
        exit 1
    fi

    # 安装 SSL 证书并移动到目标目录
    echo "安装 SSL 证书..."
    "$HOME/.acme.sh/acme.sh" --installcert -d "$DOMAIN_LOWER" \
        --key-file       "$TARGET_DIR/${DOMAIN_LOWER}.key" \
        --fullchain-file "$TARGET_DIR/${DOMAIN_LOWER}.crt"
        CERT_PATH="$TARGET_DIR/${DOMAIN_LOWER}.crt"
        KEY_PATH="$TARGET_DIR/${DOMAIN_LOWER}.key"

    # 提示用户证书已生成
    echo "SSL 证书和私钥已生成并移动到 $TARGET_DIR:"
    echo "证书: $TARGET_DIR/${DOMAIN_LOWER}.crt"
    echo "私钥: $TARGET_DIR/${DOMAIN_LOWER}.key"

    # 创建自动续期的脚本
    cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
\$HOME/.acme.sh/acme.sh --renew -d "$DOMAIN_LOWER" --key-file "$TARGET_DIR/${DOMAIN_LOWER}.key" --fullchain-file "$TARGET_DIR/${DOMAIN_LOWER}.crt"
EOF
    chmod +x /root/renew_cert.sh

    # 创建自动续期的 cron 任务，每天午夜执行一次
    (crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh >> /var/log/renew_cert.log 2>&1") | crontab -

    echo "完成！请确保在您的 Web 服务器配置中使用新的 SSL 证书。"

elif [ "$choice" -eq 2 ]; then
    # 选项 2: 手动获取 SSL 证书证书安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录 文件夹
    echo "将进行手动获取 SSL 证书证书安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录文件夹..."
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN_LOWER/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN_LOWER/privkey.pem"

    # 安装 Certbot
    echo "安装 Certbot..."
    sudo apt-get update
    sudo apt-get install -y certbot openssl

    # 手动获取证书
    echo "手动获取证书..."
    sudo certbot certonly --manual --preferred-challenges dns -d "$DOMAIN_LOWER"

    

    # 创建自动续期的 cron 任务
    (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew") | crontab -


    echo "SSL 证书已安装/etc/letsencrypt/live/$DOMAIN_LOWER 目录中"
else
    echo "无效选项，请输入 1 或 2."
fi
}
# 提示输入监听端口号
read -p "请输入 Vless 监听端口 (默认为 443): " PORT
PORT=${PORT:-443}
reality_port=$(generate_port "reality")
hysteria2_port=$(generate_port "hysteria2")
tuic_port=$(generate_port "tuic")
anytls_port=$(generate_port "anytls")
# 生成 UUID 和 WS 路径
UUID=$(generate_uuid)
WS_PATH=$(generate_ws_path)
WS_PATH1=$(generate_ws_path)


key_pair=$(/root/catmi/singbox/singbox generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
info "生成的公钥为:  $public_key"
info "生成的私钥为:  $private_key"
short_id=$(/root/catmi/singbox/singbox generate rand --hex 8)
hy_password=$(/root/catmi/singbox/singbox generate rand --hex 8)

# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
echo "公网 IPv4 地址: $PUBLIC_IP_V4"
echo "公网 IPv6 地址: $PUBLIC_IP_V6"

# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
echo "公网 IPv4 地址: $PUBLIC_IP_V4"
echo "公网 IPv6 地址: $PUBLIC_IP_V6"
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
ssl
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
      "type": "vless",
      "tag": "VLESS-WS",
      "listen": "127.0.0.1",
      "listen_port": 9999,
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    },
    {
      "type": "vmess",
      "tag": "VMESS-WS",
      "listen": "127.0.0.1",
      "listen_port": 9998,
      "users": [
        {
          "uuid": "${UUID}",
          "alter_id": 64
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
            "certificate_path": "/root/catmi/singbox/cert.pem",
            "key_path": "/root/catmi/singbox/private.key"
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
                "certificate_path":"/root/catmi/singbox/cert.pem",
                "key_path":"/root/catmi/singbox/private.key"
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
                "certificate_path":"/root/catmi/singbox/cert.pem",
                "key_path":"/root/catmi/singbox/private.key"
            }
        }
  ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
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
    server: "$PUBLIC_IP"
    port: $hysteria2_port
    type: hysteria2
    up: "40 Mbps"
    down: "150 Mbps"
    sni: bing.com
    password: $hy_password
    skip-cert-verify: true
    alpn:
      - h3
  - name: Reality
    port: $reality_port
    server: "$PUBLIC_IP"
    type: vless
    network: tcp
    udp: true
    tls: true
    servername: "$dest_server"
    skip-cert-verify: true
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    uuid: "$UUID"
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    
  - {"name":"vmess-ws-tls","type":"vmess","server":"$DOMAIN_LOWER","port":443,"cipher":"auto","uuid":"$UUID","alterId":0,"tls":true,"network":"ws","ws-opts":{"path":"${WS_PATH1}","headers":{"Host":"$DOMAIN_LOWER"}},"servername":"$DOMAIN_LOWER"}
  
  - {"type":"vless","name":"vless-ws-tls","server":"$DOMAIN_LOWER","port":443,"uuid":"$UUID","tls":true,"skip-cert-verify":true,"network":"ws","ws-opts":{"headers":{"Host":"$DOMAIN_LOWER"},"path":"${WS_PATH}"},"servername":"$DOMAIN_LOWER"}  
  
  - {name: "anytls", type: anytls, server: $PUBLIC_IP, port: $anytls_port, password: $UUID, client-fingerprint: chrome, udp: true, idle-session-check-interval: 30, idle-session-timeout: 30, skip-cert-verify: true }
  
  - {name: "tuic", type: tuic, server: $PUBLIC_IP, port: $tuic_port, uuid: $UUID, password: $hy_password, alpn: [h3], disable-sni: true, reduce-rtt: true, request-timeout: 8000, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true}

EOF



share_link="
tuic://$UUID:$hy_password@$link_ip:$tuic_port?alpn=h3&congestion_control=bbr#tuic
hysteria2://$hy_password@$link_ip:$hysteria2_port??sni=bing.com&insecure=1#Hysteria2
vless://$UUID@$link_ip:$reality_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Reality
vless://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH}#vless-ws-tls
vmess://$UUID@$DOMAIN_LOWER:443?encryption=none&security=tls&sni=$DOMAIN_LOWER&allowInsecure=1&type=ws&host=$DOMAIN_LOWER&path=${WS_PATH1}#vmess-ws-tls

"
echo "${share_link}" > /root/catmi/singbox/v2ray.txt



sudo systemctl status singbox
nginx 
cat /root/catmi/singbox/v2ray.txt
cat /root/catmi/singbox/clash-meta.yaml
