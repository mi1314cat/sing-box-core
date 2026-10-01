#!/usr/bin/env bash
# cdn_nginx.sh — 自动探测你的 Nginx 部署方式并定位站点配置文件
#
# 为什么必须探测而不是写死路径:
#   同一个 Nginx 有多种部署法, 配置目录各不相同:
#     - Docker 容器 (名字/镜像可能是 nginx / nginx-proxy / openresty,
#       配置目录要从容器挂载里读)
#     - 宿主 systemd (/etc/nginx/conf.d 或 sites-enabled)
#     - 宝塔面板 (/www/server/nginx/conf 或 /www/server/panel/vhost/nginx)
#   实测踩过的坑: 同一台机上宿主的 /etc/nginx/conf.d 是空的 (宿主 nginx 没在跑),
#   真正生效的配置挂在容器里的 /home/web/conf.d。只查 /etc/nginx 会得出
#   "找不到配置"的错误结论, 于是把片段写进没人读的地方, 以为配好了其实没生效。
#
#   所以探测顺序: Docker 挂载 → 宿主 → 常见面板目录,
#   且每一项都靠 cdn_find_site_file 实际 grep 确认, 确认不了就不写 —— 不猜路径。

# ---------- 探测 nginx 部署方式 ----------
# 输出: "docker\t<容器名>\t<宿主配置目录>" / "host\t-\t<目录>" / "none\t-\t-"
cdn_probe_nginx() {
    # 1) Docker 容器: 名字不写死, 只要容器名或镜像名里带 nginx 就试
    if command -v docker >/dev/null 2>&1; then
        local c img src
        while read -r c img; do
            [[ -z "$c" ]] && continue
            [[ "$c" =~ nginx ]] || [[ "$img" =~ nginx ]] || continue
            docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || continue
            # 优先读 conf.d 挂载; 没有就退回 nginx.conf 所在目录
            src=$(docker inspect "$c" \
                --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d"}}{{.Source}}{{end}}{{end}}' \
                2>/dev/null | head -1)
            [[ -n "$src" ]] || src=$(docker inspect "$c" \
                --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}' \
                2>/dev/null | head -1 | xargs -r dirname)
            [[ -n "$src" ]] || continue
            printf 'docker\t%s\t%s\n' "$c" "$src"
            return 0
        done < <(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null)
    fi
    # 2) 宿主 systemd
    if [[ -f /etc/nginx/nginx.conf ]]; then
        printf 'host\t-\t/etc/nginx/conf.d\n'
        return 0
    fi
    printf 'none\t-\t-\n'
}

# ---------- 给 cdn_apply.py 用的校验方式 ----------
# docker:<容器名> | systemd | none
cdn_nginx_mode() {
    local mode rest c
    mode=$(cdn_probe_nginx)
    rest="${mode#*$'\t'}"
    c="${rest%%$'\t'*}"
    case "${mode%%$'\t'*}" in
        docker) echo "docker:$c" ;;
        host)   echo "systemd" ;;
        *)      echo "none" ;;
    esac
}

# ---------- 候选配置目录 (按优先级, 全部来自探测或常见布局) ----------
# 这些只是**候选**; cdn_find_site_file 会逐个 grep 验证, 验证不通过就不写。
cdn_config_roots() {
    local probe dir
    probe=$(cdn_probe_nginx)
    dir="${probe##*$'\t'}"
    [[ -n "$dir" && -d "$dir" ]] && echo "$dir"
    [[ -d /etc/nginx/conf.d ]] && echo /etc/nginx/conf.d
    [[ -d /etc/nginx/sites-enabled ]] && echo /etc/nginx/sites-enabled
    [[ -d /www/server/nginx/conf ]] && echo /www/server/nginx/conf
    [[ -d /www/server/panel/vhost/nginx ]] && echo /www/server/panel/vhost/nginx
}

# ---------- 找出哪个文件里定义了某个 server_name ----------
# 找不到就返回失败, 绝不猜路径。
# 关键: server_name 必须锚定行首 —— proxy_ssl_server_name 这类指令里
# 也含 "server_name xxx" 字样, 不锚定会误判成站点。
cdn_find_site_file() {
    local domain="$1" r f
    while read -r r; do
        [[ -d "$r" ]] || continue
        for f in "$r"/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -qE "^[[:space:]]*server_name[[:space:]]+[^;]*\b${domain//./\\.}\b" "$f" 2>/dev/null; then
                echo "$f"; return 0
            fi
        done
    done < <(cdn_config_roots)
    return 1
}

# ---------- 列出所有已配置的站点 (域名|文件) ----------
cdn_list_sites() {
    local r f
    while read -r r; do
        [[ -d "$r" ]] || continue
        for f in "$r"/*.conf; do
            [[ -f "$f" ]] || continue
            sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;]+);.*/\1/p' "$f" 2>/dev/null |
                tr ' \t' '\n\n' | grep -vE '^(_|\*|~|=|$)' |
                while read -r dn; do echo "$dn|$f"; done
        done
    done < <(cdn_config_roots) | sort -u
}

# ---------- 站点是否配了 TLS (Cloudflare 回源必需) ----------
cdn_site_has_tls() {
    grep -qE "^[[:space:]]*ssl_certificate[[:space:]]" "$1" 2>/dev/null
}