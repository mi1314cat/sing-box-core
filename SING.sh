#!/bin/bash
# 介绍信息
printf "\e[92m"
printf "                       |\\__/,|   (\\\\ \n"
printf "                     _.|o o  |_   ) )\n"
printf "       -------------(((---(((-------------------\n"
printf "                    catmi.sing-box \n"
printf "       -----------------------------------------\n"
printf "\e[0m"

# 打印带延迟的消息
print_with_delay() {
    local message="$1"
    local delay="$2"
    for (( i=0; i<${#message}; i++ )); do
        printf "%s" "${message:$i:1}"
        sleep "$delay"
    done
    echo ""
}
TARGET_DIR="/root/sing-box"
mkdir -p "$TARGET_DIR"
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
# 随机生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}
sudo apt install openssl -y

print_with_delay "**************sing-box*************" 0.03
# 自动安装 sing-box
print_with_delay "正在安装 sing-box" 0.03
bash <(curl -fsSL https://sing-box.app/deb-install.sh)


# reality
# 随机生成域名
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
        "amazon.com"
        "fandom.com"
        "tidal.com"
        "zoro.to"
        "pixiv.co.jp"
        "mora.jp"
        "j-wave.co.jp"
        "dmm.com"
        "booth.pm"
        "ivi.tv"
        "leercapitulo.com"
        "sky.com"
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
    echo "${domains[$random_index]}"
}

# 生成随机 ID
short_id=$(dd bs=4 count=2 if=/dev/urandom | xxd -p -c 8)
# 提示输入监听端口号
reality_PORT=$(generate_port "vless-reality")
# 提示输入回落域名
read -rp "请输入回落域名: " dest_server
[ -z "$dest_server" ] && dest_server=$(random_website)
# 生成 UUID 
reality_UUID=$(generate_uuid)
# 生成密钥并保存输出
output=$(sing-box generate reality-keypair)

# 提取私钥和公钥
private_key=$(echo "$output" | grep "PrivateKey" | awk '{print $2}')
public_key=$(echo "$output" | grep "PublicKey" | awk '{print $2}')

# 保存私钥和公钥到不同文件
echo "$private_key" > $TARGET_DIR/private_key.txt
echo "$public_key" > $TARGET_DIR/public_key.txt

# 输出保存成功的提示
echo "私钥已保存到 $TARGET_DIR/private_key.txt"
echo "公钥已保存到 $TARGET_DIR/public_key.txt"


# Hysteria2
Hysteria2_PORT=$(generate_port "Hysteria2")
# 生成自签证书
print_with_delay "生成自签名证书..." 0.03
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout $TARGET_DIR/server.key -out $TARGET_DIR/server.crt \
    -subj "/CN=bing.com" -days 36500 && \
    sudo chown sing-box $TARGET_DIR/server.key && \
    sudo chown sing-box $TARGET_DIR/server.crt

# 自动生成密码
AUTH_PASSWORD=$(openssl rand -base64 16)

# vless_tls
vless_PORT=$(generate_port "vless")
# 生成 UUID 
vless_UUID=$(generate_uuid)
# 提示用户输入域名
read -p "请输入域名: " DOMAIN

# 将用户输入的域名转换为小写
DOMAIN_LOWER=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

# 申请证书
echo "将进行手动获取 SSL 证书并移动到 $TARGET_DIR 文件夹..."

    # 安装 Certbot
    echo "安装 Certbot..."
    sudo apt-get update
    sudo apt-get install -y certbot openssl

    # 手动获取证书
    echo "手动获取证书..."
    sudo certbot certonly --manual --preferred-challenges dns -d "$DOMAIN_LOWER"

    
    # 创建自动续期的 cron 任务
    (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew") | crontab -


    echo "SSL 证书已安装至 /etc/letsencrypt/live/$DOMAIN_LOWER 目录中"

# 获取公网 IP 地址
PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
echo "公网 IPv4 地址: $PUBLIC_IP_V4"
echo "公网 IPv6 地址: $PUBLIC_IP_V6"

# 选择使用哪个公网 IP 地址
echo "请选择要使用的公网 IP 地址:"
echo "1. $PUBLIC_IP_V4"
echo "2. $PUBLIC_IP_V6"
read -p "请输入对应的数字选择: " IP_CHOICE

if [ "$IP_CHOICE" -eq 1 ]; then
    PUBLIC_IP=$PUBLIC_IP_V4
elif [ "$IP_CHOICE" -eq 2 ]; then
    PUBLIC_IP=$PUBLIC_IP_V6
else
    echo "无效选择，退出脚本"
    exit 1
fi

# 创建sing-box 服务端配置文件
print_with_delay "生成 sing-box 配置文件..." 0.03
cat << EOF > /etc/sing-box/config.json
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "sniff": true,
      "sniff_override_destination": true,
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $reality_PORT,
      "users": [
        {
          "uuid": "$reality_UUID",
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
          "short_id": [
            "$short_id"
          ]
        }
      }
    },
    {
      "sniff": true,
      "sniff_override_destination": true,
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $Hysteria2_PORT,
      "users": [
        {
          "password": "$AUTH_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TARGET_DIR/server.crt",
        "key_path": "$TARGET_DIR/server.key"
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $vless_PORT,
      "users": [
        {
          "uuid": "$vless_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/letsencrypt/live/$DOMAIN_LOWER/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/$DOMAIN_LOWER/privkey.pem"
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

# 重启 sing-box 服务以应用配置
print_with_delay "重启 sing-box服务以应用新配置..." 0.03
sudo systemctl restart sing-box

# 启动并启用 sing-box 服务
print_with_delay "启动 sing-box 服务..." 0.03
sudo systemctl enable sing-box



# 生成客户端配置文件
print_with_delay "生成客户端配置文件..." 0.03
cat << EOF > $TARGET_DIR/config.yaml
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
ipv6: true

dns:
  enable: true
  listen: :53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: 
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.0.0.1/dns-query
    - tls://dns.google
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:        
  - name: SING-Hysteria2
    server: $PUBLIC_IP
    port: $Hysteria2_PORT
    type: hysteria2
    up: "45 Mbps"
    down: "150 Mbps"
    sni: bing.com
    password: $AUTH_PASSWORD
    skip-cert-verify: true
    alpn:
      - h3
  - name: SING-Reality
    port:  $reality_PORT
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
    uuid: "$reality_UUID"
    flow: xtls-rprx-vision
    client-fingerprint: chrome  
  - name: SING-vless
    port: $vless_PORT  
    server: $DOMAIN_LOWER
    type: vless
    uuid: "$vless_UUID"
    flow: xtls-rprx-vision
    tls:
      enabled: true
      server_name: "$DOMAIN_LOWER"
      utls:
        enabled: true
        fingerprint: chrome
    packet_encoding: xudp    

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - 负载均衡-轮询
      - SING-Reality
      - SING-Hysteria2
      - SING-vless
      - DIRECT
  - name: 负载均衡-轮询
    type: load-balance
    proxies:
      - SING-Reality
      - SING-Hysteria2
      - SING-vless 
  
    url: 'https://www.gstatic.com/generate_204'
    interval: 300
    strategy: round-robin
  - name: 自动选择
    type: url-test
    proxies:
      - SING-Reality
      - SING-Hysteria2
      - SING-vless
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF

# 显示生成的密码
print_with_delay "sing-box 安装和配置完成！" 0.03
print_with_delay "服务端配置文件已保存到 /etc/sing-box/config.json" 0.03
print_with_delay "客户端配置文件已保存到 $TARGET_DIR/config.yaml" 0.03

# 显示 sing-box 服务状态
sudo systemctl status sing-box
print_with_delay "**************sing-box.客户端配置*************" 0.03
cat $TARGET_DIR/config.yaml
print_with_delay "**************sing-box.catmi.end*************" 0.03
