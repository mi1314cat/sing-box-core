#!/bin/bash

# ============================================================
#   sing-box 变量生成器（专业版）
#   不生成 dest_server，由伪装域名脚本提供
# ============================================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

print_info() { echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_error() { echo -e "${RED}[Error]${PLAIN} $1"; }

INSTALL_DIR="/root/catmi/singbox"
ENV_FILE="$INSTALL_DIR/install_info.env"
SbINSTALL_DIR="/root/catmi/singbox/sing-box"
mkdir -p "$INSTALL_DIR"

# ============================================================
# 加载 update_env / load_env
# ============================================================

source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")

# ============================================================
# 工具函数
# ============================================================

generate_uuid() { cat /proc/sys/kernel/random/uuid; }
generate_ws_path() { echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"; }
random_hex() { openssl rand -hex 8; }
random_hex16() { openssl rand -hex 16; }

# ============================================================
# 端口检测函数
# ============================================================

is_port_used() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":$port "
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":$port "
        return $?
    fi

    return 1
}

generate_free_port() {
    local port
    while true; do
        port=$((RANDOM % 55535 + 10000))
        if ! is_port_used "$port"; then
            echo "$port"
            return
        fi
    done
}

# ============================================================
# Reality 密钥
# ============================================================

generate_reality_keys() {
    print_info "生成 Reality 密钥对..."
    
    # 使用 sing-box 生成真正的 X25519 密钥对
    local keys=$("$SbINSTALL_DIR" generate reality-keypair 2>/dev/null)
    if [[ -z "$keys" ]]; then
        print_error "无法使用 sing-box 生成密钥对，请检查路径或版本"
        return 1
    fi
    PRIVATE_KEY=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
    
    SHORT_ID=$(random_hex)  # 短ID仍是随机十六进制
    
    update_env "$ENV_FILE" PRIVATE_KEY "$PRIVATE_KEY"
    update_env "$ENV_FILE" PUBLIC_KEY "$PUBLIC_KEY"
    update_env "$ENV_FILE" SHORT_ID "$SHORT_ID"
    
    print_info "Reality 密钥生成完成"
}

# ============================================================
# 生成端口（方案 A + 端口检测）
# ============================================================

generate_ports() {
    print_info "生成端口"

    update_env "$ENV_FILE" VLESS_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" ANYTLS_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" TUIC_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" HY2_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" TROJAN_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" SHADOWTLS_PORT "$(generate_free_port)"
    update_env "$ENV_FILE" SS_PORT "$(generate_free_port)"

    print_info "端口生成完成"
}

# ============================================================
# 公网 IP（你要求保留的逻辑）
# ============================================================

generate_public_ip() {
    print_info "检测公网 IP..."

    PUBLIC_IP_V4=$(curl -s4 https://api.ipify.org || true)
    PUBLIC_IP_V6=$(curl -s6 https://api64.ipify.org || true)

    if [ -z "$PUBLIC_IP_V4" ] && [ -z "$PUBLIC_IP_V6" ]; then
        print_error "无法检测公网 IP"
        exit 1
    fi

    echo "请选择要使用的公网 IP 地址:"
    [ -n "$PUBLIC_IP_V4" ] && echo "1. IPv4: $PUBLIC_IP_V4"
    [ -n "$PUBLIC_IP_V6" ] && echo "2. IPv6: $PUBLIC_IP_V6"

    read -p "请输入对应数字 [默认1]: " IP_CHOICE
    IP_CHOICE=${IP_CHOICE:-1}

    if [ "$IP_CHOICE" -eq 2 ] && [ -n "$PUBLIC_IP_V6" ]; then
        PUBLIC_IP="$PUBLIC_IP_V6"
    else
        PUBLIC_IP="${PUBLIC_IP_V4:-$PUBLIC_IP_V6}"
    fi

    if [[ "$PUBLIC_IP" =~ : ]]; then
        link_ip="[$PUBLIC_IP]"
    else
        link_ip="$PUBLIC_IP"
    fi

    print_info "选定公网 IP: $PUBLIC_IP"

    update_env "$ENV_FILE" PUBLIC_IP "$PUBLIC_IP"
    update_env "$ENV_FILE" IP_CHOICE "$IP_CHOICE"
    update_env "$ENV_FILE" link_ip "$link_ip"
}

# ============================================================
# 主流程
# ============================================================

print_info "开始生成环境变量..."

# -------------------------
# 检查 dest_server 是否存在
# -------------------------
load_env "$ENV_FILE"

if [ -z "$dest_server" ]; then
    print_error "未检测到 dest_server，请先运行伪装域名生成脚本！"
    print_error "install_info.env 中必须包含：dest_server=xxx"
    exit 1
fi

print_info "检测到 dest_server=$dest_server"

# -------------------------
# 生成基础变量
# -------------------------

UUID=$(generate_uuid)
PASSWORD=$(random_hex16)
WS_PATH=$(generate_ws_path)

update_env "$ENV_FILE" UUID "$UUID"
update_env "$ENV_FILE" PASSWORD "$PASSWORD"
update_env "$ENV_FILE" WS_PATH "$WS_PATH"

generate_reality_keys
generate_ports
generate_public_ip

print_info "所有变量已写入：$ENV_FILE"
