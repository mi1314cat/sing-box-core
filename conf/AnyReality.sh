#!/bin/bash
# ============================================================
# AnyReality（AnyTLS + Reality）全功能管理脚本

# ============================================================

# ================================
# 彩色定义
# ================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET} %s\n"  "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════════════╗\n" >&2
    printf "║ %-52s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ================================
# 基础路径（sing-box 版本）
# ================================
PROTO="AnyReality"

BASE_DIR="/root/catmi/singbox"
CONF_DIR="$BASE_DIR/conf"
OUT_DIR="$BASE_DIR/out"
ENV_FILE="$BASE_DIR/install_info.env"
PUB_DIR="$OUT_DIR/pub"
PUB_ENV="$PUB_DIR/public_key.env"

mkdir -p "$CONF_DIR" "$OUT_DIR" "$PUB_DIR"

# ================================
# 工具函数
# ================================
clean_input() { echo "$1" | tr -d '\000-\037'; }
trim()        { echo "$1" | sed 's/^[ \t]*//;s/[ \t]*$//'; }

# ================================
# 编号系统（AnyReality-01.json / AnyReality-02.json）
# ================================
get_next_index() {
    local used=() i=1
    shopt -s nullglob
    for f in "$CONF_DIR"/$PROTO-*.json; do
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^$PROTO-([0-9]{2})\.json$ ]]; then
            used+=("${BASH_REMATCH[1]}")
        fi
    done
    IFS=$'\n' used=($(printf "%s\n" "${used[@]}" | sort -n))
    for n in "${used[@]}"; do
        [[ "$n" -ne "$i" ]] && break
        ((i++))
    done
    printf "%02d\n" "$i"
}

# ================================
# 查看 AnyReality 配置
# ================================
list_configs() {
    print_title "AnyReality 配置列表"
    shopt -s nullglob
    files=("$CONF_DIR"/$PROTO-*.json)
    if [ ${#files[@]} -eq 0 ]; then
        print_error "没有找到任何 AnyReality 配置"
        return
    fi

    for f in "${files[@]}"; do
        num=$(basename "$f" .json | sed -E 's/.*-([0-9]+)/\1/')
        port=$(grep -m1 '"listen_port"' "$f" | sed -E 's/.*: *([0-9]+).*/\1/')
        pass=$(grep -m1 '"password"' "$f" | sed -E 's/.*"password": *"([^"]+)".*/\1/')
        sni=$(grep -m1 '"server_name"' "$f" | sed -E 's/.*"server_name": *"([^"]+)".*/\1/')
        printf "${GREEN}%s${RESET}) " "$num" >&2
        printf "端口:${BLUE}%s${RESET} " "$port" >&2
        printf "密码:${MAGENTA}%s${RESET} " "$pass" >&2
        printf "SNI:${YELLOW}%s${RESET}\n" "$sni" >&2
    done
}
# ================================
# 新增 AnyReality 节点（含 public_key 保存）
# ================================
add_config() {
    print_title "新增 AnyReality（AnyTLS + Reality）节点"

    DINSTALL_CATMI="/root/catmi"
    CATMIENV_FILE="$DINSTALL_CATMI/catmi.env"

    # 设置 mode=singbox
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/update_env.sh")
    update_env "$CATMIENV_FILE" mode singbox

    # 自动生成伪装域名
    bash <(curl -fsSL https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/domains.sh)

    # 自动生成所有变量
    bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/conf/XRevise.sh)

    # 加载 ENV
    source <(curl -fsSL "https://github.com/mi1314cat/One-click-script/raw/refs/heads/main/A/load_env.sh")
    load_env "$ENV_FILE"

    required_vars=(ANYTLS_PORT PASSWORD PRIVATE_KEY PUBLIC_KEY SHORT_ID dest_server PUBLIC_IP link_ip)
    for v in "${required_vars[@]}"; do
        [[ -z "${!v}" ]] && { print_error "缺少必要变量：$v"; return; }
    done

    # 端口可修改
    echo -e "默认 AnyTLS 端口: ${GREEN}$ANYTLS_PORT${RESET}"
    read -p "是否修改端口？直接回车使用默认: " custom_port
    [[ -n "$custom_port" ]] && ANYTLS_PORT="$custom_port"

    # 获取编号
    index=$(get_next_index)
    num2=$(printf "%02d" "$index")

    IN_FILE="$CONF_DIR/$PROTO-$num2.json"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.json"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    # 保存 public_key
    mkdir -p "$PUB_DIR"
    echo "PUBKEY_${num2}=$PUBLIC_KEY" >> "$PUB_ENV"

    # ================================
    # 写入服务端配置
    # ================================
    cat > "$IN_FILE" <<EOF
{
    "inbounds": [
        {
            "type": "anytls",
            "listen": "::",
            "listen_port": $ANYTLS_PORT,
            "users": [
                {
                    "name": "user",
                    "password": "$PASSWORD"
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
                    "private_key": "$PRIVATE_KEY",
                    "short_id": "$SHORT_ID"
                }
            }
        }
    ]
}
EOF

    # ================================
    # 写入客户端配置（含 public_key）
    # ================================
    cat > "$OUT_FILE" <<EOF
{
    "type": "anytls",
    "tag": "anytls-out",
    "server": "$PUBLIC_IP",
    "server_port": $ANYTLS_PORT,
    "password": "$PASSWORD",
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
            "public_key": "$PUBLIC_KEY",
            "short_id": "$SHORT_ID"
        }
    }
}
EOF

    # 分享链接
    echo "anyreality://user:$PASSWORD@$link_ip:$ANYTLS_PORT?sni=$dest_server&sid=$SHORT_ID#AnyReality-$num2" > "$SHARE_FILE"

    print_ok "AnyReality 节点创建成功（编号 $num2）"
}

# ================================
# 删除 AnyReality 节点
# ================================
delete_config() {
    print_title "删除 AnyReality 节点"
    list_configs
    printf "\n请输入要删除的编号: "
    read num
    num2=$(printf "%02d" "$num")

    IN_FILE="$CONF_DIR/$PROTO-$num2.json"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num2.json"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num2.txt"

    [[ ! -f "$IN_FILE" ]] && { print_error "编号不存在"; return; }

    rm -f "$IN_FILE" "$OUT_FILE" "$SHARE_FILE"

    # 删除 public_key
    sed -i "/^PUBKEY_${num2}=/d" "$PUB_ENV"

    print_ok "已删除 AnyReality 节点 $num2"
}


# ================================
# 重建客户端文件
# ================================
rebuild_client() {
    print_title "重建 AnyReality 客户端文件"
    list_configs
    printf "\n请输入要重建的编号: "
    read -r num_raw
    num=$(printf "%02d" "$num_raw")

    IN_FILE="$CONF_DIR/${PROTO}-$num.json"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num.json"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num.txt"

    if [[ ! -f "$IN_FILE" ]]; then
        print_error "编号不存在：$num"
        return
    fi

    # 从服务端配置读取参数
    port=$(grep -m1 '"listen_port"' "$IN_FILE" | sed -E 's/.*: *([0-9]+).*/\1/')
    pass=$(grep -m1 '"password"' "$IN_FILE" | sed -E 's/.*"password": *"([^"]+)".*/\1/')
    sni=$(grep -m1 '"server_name"' "$IN_FILE" | sed -E 's/.*"server_name": *"([^"]+)".*/\1/')
    sid=$(grep -m1 '"short_id"' "$IN_FILE" | sed -E 's/.*"short_id": *"([^"]+)".*/\1/')

    # 从 public_key.env 读取 public_key
    PUBLIC_KEY=$(grep "^PUBKEY_${num}=" "$PUB_ENV" | cut -d= -f2)

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

    # 写客户端配置
    cat > "$OUT_FILE" <<EOF
{
    "type": "anytls",
    "tag": "anytls-out",
    "server": "$SERVER_IP",
    "server_port": $port,
    "password": "$pass",
    "idle_session_check_interval": "30s",
    "idle_session_timeout": "30s",
    "min_idle_session": 5,
    "tls": {
        "enabled": true,
        "disable_sni": false,
        "server_name": "$sni",
        "insecure": false,
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        },
        "reality": {
            "enabled": true,
            "public_key": "$PUBLIC_KEY",
            "short_id": "$sid"
        }
    }
}
EOF

    SHARE_LINK="anyreality://user:$pass@$SERVER_IP:$port?sni=$sni&sid=$sid#AnyReality-$num"
    echo "$SHARE_LINK" > "$SHARE_FILE"

    print_ok "客户端文件已重建：$num"

    # ================================
    # ★★★ 关键：展开显示客户端 JSON ★★★
    # ================================
    echo -e "\n${CYAN}===== 客户端 JSON =====${RESET}"
    cat "$OUT_FILE"

    echo -e "\n${CYAN}===== 分享链接 =====${RESET}"
    echo "$SHARE_LINK"
}

# ================================
# 静默重建（订阅用）
# ================================
rebuild_client_silent() {
    local num=$(printf "%02d" "$1")

    IN_FILE="$CONF_DIR/${PROTO}-$num.json"
    OUT_FILE="$OUT_DIR/${PROTO}_client-$num.json"
    SHARE_FILE="$OUT_DIR/${PROTO}_share-$num.txt"

    [[ ! -f "$IN_FILE" ]] && return

    port=$(grep -m1 '"listen_port"' "$IN_FILE" | sed -E 's/.*: *([0-9]+).*/\1/')
    pass=$(grep -m1 '"password"' "$IN_FILE" | sed -E 's/.*"password": *"([^"]+)".*/\1/')
    sni=$(grep -m1 '"server_name"' "$IN_FILE" | sed -E 's/.*"server_name": *"([^"]+)".*/\1/')
    sid=$(grep -m1 '"short_id"' "$IN_FILE" | sed -E 's/.*"short_id": *"([^"]+)".*/\1/')

    PUBLIC_KEY=$(grep "^PUBKEY_${num}=" "$PUB_ENV" | cut -d= -f2)

    SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s6 https://api64.ipify.org)

    cat > "$OUT_FILE" <<EOF
{
    "type": "anytls",
    "tag": "anytls-out",
    "server": "$SERVER_IP",
    "server_port": $port,
    "password": "$pass",
    "idle_session_check_interval": "30s",
    "idle_session_timeout": "30s",
    "min_idle_session": 5,
    "tls": {
        "enabled": true,
        "disable_sni": false,
        "server_name": "$sni",
        "insecure": false,
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        },
        "reality": {
            "enabled": true,
            "public_key": "$PUBLIC_KEY",
            "short_id": "$sid"
        }
    }
}
EOF

    echo "anytls://user:$pass@$SERVER_IP:$port?sni=$sni&sid=$sid#AnyReality-$num" > "$SHARE_FILE"
}


# ================================
# 导出订阅（展开 JSON + 链接）
# ================================
export_subscription() {
    print_title "导出所有 AnyReality 节点订阅（展开格式）"
    SUB_FILE="$OUT_DIR/AnyReality_subscribe.txt"

    echo "# AnyReality 全节点订阅（自动生成）" > "$SUB_FILE"

    shopt -s nullglob
    local files=("$CONF_DIR"/${PROTO}-*.json)

    if [[ ${#files[@]} -eq 0 ]]; then
        print_warn "无配置，无法导出订阅"
        return
    fi

    IFS=$'\n' files=($(printf "%s\n" "${files[@]}" | sort))

    for f in "${files[@]}"; do
        num=$(basename "$f" | sed -E 's/.*-([0-9]+)\.json/\1/')
        num2=$(printf "%02d" "$num")

        # 静默重建客户端
        rebuild_client_silent "$num2"

        CLIENT_FILE="$OUT_DIR/${PROTO}_client-$num2.json"
        SHARE_LINK=$(cat "$OUT_DIR/${PROTO}_share-$num2.txt")

        cat >> "$SUB_FILE" <<EOF

# ============================
# AnyReality-$num2
# ============================
$(sed 's/^/  /' "$CLIENT_FILE")
$SHARE_LINK
EOF
    done

    print_ok "订阅文件已生成：$SUB_FILE"

    # ================================
    # ★★★ 关键：展开显示订阅内容 ★★★
    # ================================
    echo -e "\n${CYAN}===== 订阅内容预览 =====${RESET}"
    cat "$SUB_FILE"
}



# ================================
# 主菜单
# ================================
main_menu() {
    while true; do
        print_title "AnyReality（AnyTLS + Reality）管理面板"
        echo "1) 查看配置" >&2
        echo "2) 新增配置" >&2
        echo "3) 删除配置" >&2
        echo "4) 重建客户端文件" >&2
        echo "5) 导出所有节点订阅" >&2
        echo "0) 退出" >&2
        printf "请选择: " >&2
        read c
        c=$(clean_input "$c")
        case $c in
            1) list_configs ;;
            2) add_config ;;
            3) delete_config ;;
            4) rebuild_client ;;
            5) export_subscription ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        printf "按回车继续..." >&2
        read
    done
}

main_menu
