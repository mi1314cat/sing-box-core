#!/bin/bash
# ==============================================================
# client.sh — SB-Panel Sing-box Client (正式客户端)
# 内核: sing-box(唯一)  |  入站: mixed(HTTP+SOCKS) LAN 可用
# 多节点: 每节点一个 conf/node-<tag>.json, 90-selector.json 自动聚合
# 管理: Clash API (external_controller) + metacubexd Web UI
# 导入: client.sh add <share-url | local.json | sing-box URI>
# CLI: bash client.sh {install|init|add|list|update|del|start|stop|restart|status|info|check}
# 部署根目录默认 /opt/sb-client (可在 /etc/sb-client.env 覆盖)
# ==============================================================
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 环境 ----------
if [[ -f /etc/sb-client.env ]]; then source /etc/sb-client.env; fi
CLIENT_ROOT="${CLIENT_ROOT:-/opt/sb-client}"
CLIENT_BIN="${CLIENT_BIN:-$CLIENT_ROOT/core/sing-box}"
CLIENT_CONF="${CLIENT_CONF:-$CLIENT_ROOT/conf}"          # 客户端自己配置片段
CLIENT_UI="${CLIENT_UI:-$CLIENT_ROOT/ui}"                # external_ui 目录
CLIENT_NODE_DIR="${CLIENT_NODE_DIR:-$CLIENT_ROOT/nodes}" # 节点片段
PORT_MIXED="${PORT_MIXED:-2080}"         # LAN HTTP/SOCKS 入站 (避开 1080 10809)
PORT_CLASH="${PORT_CLASH:-19090}"   # 避碰: mihomo/clash 常占 9090         # clash api
BIND_LAN="${BIND_LAN:-0.0.0.0}"          # LAN 支持; 127.0.0.1=仅本机
CLASH_LISTEN="${CLASH_LISTEN:-0.0.0.0}"   # LAN Web UI(ui 由 secret 保护)
CLASH_SECRET_FILE="${CLASH_SECRET_FILE:-$CLIENT_ROOT/.clash-secret}"
UI_ZIP_URL="${UI_ZIP_URL:-https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip}"

print_msg(){ printf "\033[36m[SB-Client] %s\033[0m\n" "$1" >&2; }
print_ok(){ printf "\033[32m[OK]   %s\033[0m\n" "$1" >&2; }
print_err(){ printf "\033[31m[ERR]  %s\033[0m\n" "$1" >&2; }

crand(){ openssl rand -hex 16; }

# ---------- install: 单独下载内核到 client 目录 ----------
do_install() {
    local ver_url arch
    arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) print_err "arch=$arch"; return 1 ;; esac
    mkdir -p "$CLIENT_ROOT/core" "$CLIENT_ROOT/nodes" "$CLIENT_ROOT/share-state" "$CLIENT_UI"
    [[ -x "$CLIENT_BIN" ]] && { print_ok "内核已存在: $($CLIENT_BIN version|head -1)"; return; }
    ver_url=$(curl -fsSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -oE '"tag_name": *"[^"]+' | cut -d'"' -f4 | head -1)
    [[ -n "$ver_url" ]] || { print_err "获取最新版本号失败"; return 1; }
    local tag="$ver_url"
    local ok=0 url vn="${ver_url#v}"
    [[ "$vn" == "$ver_url" ]] && vn="$ver_url"        # 兼容 v 前缀缺失场景
    local libc_suffix=""
    for libc_suffix in "-glibc" "" "-musl"; do
        url="https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-${vn}-linux-${arch}${libc_suffix}.tar.gz"
        if curl -fsSL --max-time 300 "$url" -o "$CLIENT_ROOT/core/core.tgz" 2>/dev/null; then ok=1; break; fi
    done
    [[ "$ok" == 1 ]] || { print_err "内核下载失败 (试过 glibc/generic/musl 命名)"; return 1; }
    tar -xzf "$CLIENT_ROOT/core/core.tgz" -C "$CLIENT_ROOT/core" --strip-components=1 "sing-box-${vn}-linux-${arch}${libc_suffix}/sing-box" \
        || { print_err "解包失败"; return 1; }
    rm -f "$CLIENT_ROOT/core/core.tgz"
    chmod +x "$CLIENT_BIN" 2>/dev/null || true
    print_ok "client 内核: $($CLIENT_BIN version 2>/dev/null | head -1)"
}

gen_clash_secret() {
    if [[ "${CLASH_LISTEN}" != "127.0.0.1" && "${CLASH_LISTEN}" != "::1" && ! -s "$CLASH_SECRET_FILE" ]]; then
        crand > "$CLASH_SECRET_FILE"; chmod 600 "$CLASH_SECRET_FILE"
        print_ok "已生成 Clash API secret (监听 $CLASH_LISTEN, 官方要求非 lo 监听必须设置 secret)"
    fi
}

# ---------- init: 基础配置 ----------
do_init() {
    mkdir -p "$CLIENT_ROOT/nodes" "$CLIENT_ROOT/share-state" "$CLIENT_UI"
    gen_clash_secret
    local secret=""; [[ -s "$CLASH_SECRET_FILE" ]] && secret=$(cat "$CLASH_SECRET_FILE")
    cat > "$CLIENT_CONF/00-mixed.json" <<EOF
{ "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "$BIND_LAN", "listen_port": $PORT_MIXED } ] }
EOF
    local secret_line=""
    [[ -n "$secret" ]] && secret_line=", \"secret\": \"$secret\""
    cat > "$CLIENT_CONF/01-clash.json" <<EOF
{
  "experimental": {
    "clash_api": {
      "external_controller": "$CLASH_LISTEN:$PORT_CLASH",
      "external_ui": "$CLIENT_UI"$secret_line
    }
  }
}
EOF
    regen_selector
    print_ok "基础配置完成 ($CLIENT_CONF): mixed=$BIND_LAN:$PORT_MIXED clash_api=$CLASH_LISTEN:$PORT_CLASH"
}

# 读 nodes/*.json 聚合 selector + urltest
regen_selector() {
    # 单文件聚合: 全部节点 outbound + selector + urltest (sing-box -C 只读顶层文件)
    local f
    python3 - "$CLIENT_ROOT/nodes" "$CLIENT_CONF/90-outbounds.json" <<'PYGEN'
import json,sys,glob,os
ndir,ofile,origin=sys.argv[1],sys.argv[2],sys.argv[3] if len(sys.argv)>3 else None
obs=[]
for f in sorted(glob.glob(os.path.join(ndir,"node-*.json"))):
    j=json.load(open(f))
    obs.extend(j.get("outbounds",[]))
htags=set(o["detour"] for o in obs if o.get("detour"))
tags=[o["tag"] for o in obs if o.get("type")!="direct" and o["tag"] not in htags]
tags=tags or [o["tag"] for o in obs]
if not tags:
    cfg={"outbounds":[]}
else:
    cfg={"outbounds":obs+[
       {"type":"selector","tag":"PROXY","outbounds":tags,"default":tags[0]},
       {"type":"urltest","tag":"AUTO","outbounds":tags,"url":"https://www.gstatic.com/generate_204","interval":"3m"}],
       "route":{"final":"PROXY"}}
json.dump(cfg,open(ofile,"w"),indent=2)
PYGEN
}



# ---------- add: share URL / 本地文件导入 ----------
add_node() {
    local src="$1"
    [[ -n "$src" ]] || { print_err "用法: client.sh add <share-url|本地配置文件>"; return 1; }
    local tmp; tmp=$(mktemp "$CLIENT_ROOT/share-state/.import.XXXXXX.json")

    if [[ "$src" =~ ^https?:// ]]; then
        local code
        code=$(curl -fsSL -o "$tmp" -w '%{http_code}' --max-time 30 "$src" 2>/dev/null) || { rm -f "$tmp"; print_err "下载失败"; return 1; }
        case "$code" in
            200) ;;
            410) rm -f "$tmp"; print_err "分享链接已失效(用尽/过期/禁用)"; return 1 ;;
            404) rm -f "$tmp"; print_err "链接不存在"; return 1 ;;
            503) rm -f "$tmp"; print_err "服务端配置暂不可用, 未消耗次数"; return 1 ;;
            *)   rm -f "$tmp"; print_err "HTTP $code"; return 1 ;;
        esac
        print_ok "分享配置已获取"
    else
        cp "$src" "$tmp"
    fi
    # 验证 (客户端 check)
    if ! "$CLIENT_BIN" check -c "$tmp" >/dev/null 2>&1 && ! "$CLIENT_BIN" check "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; print_err "sing-box check 失败, 旧配置未变"; return 1
    fi
    local tag
    tag=$(jq -r '.outbounds[0].tag // empty' "$tmp")
    [[ -n "$tag" ]] || { rm -f "$tmp"; print_err "配置无 outbound"; return 1; }
    # 节点池化: 只保留 outbound 定义 (去 route/selector 冲突)
    jq '{outbounds}' "$tmp" > "$CLIENT_NODE_DIR/node-$tag.json"
    echo "$src" > "$CLIENT_NODE_DIR/node-$tag.txt"          # 来源记录: share_url / local path
    echo "{\"tag\":\"$tag\",\"source\":\"share\",\"imported_at\":\"$(date -Is)\"}" > "$CLIENT_NODE_DIR/node-$tag.meta.json"
    rm -f "$tmp"
    regen_selector
    print_ok "节点 $tag 已导入 ($CLIENT_NODE_DIR/node-$tag.json); 共 $(ls "$CLIENT_NODE_DIR"/node-*.json 2>/dev/null | wc -l) 个节点"
}

update_node() {
    # 对来源为 share URL 的节点重新拉取 (仅 max_uses>1 的链接可用)
    local f src tag
    for f in "$CLIENT_NODE_DIR"/node-*.txt; do
        [[ -f "$f" ]] || continue
        src=$(cat "$f")
        case "$src" in http*) tag=$(basename "$f" .txt); tag=${tag#node-}; print_msg "更新 $tag"; add_node "$src" ;; esac
    done
}

del_node() {
    local tag="$1"
    [[ -f "$CLIENT_NODE_DIR/node-$tag.json" ]] || { print_err "无此节点"; return 1; }
    rm -f "$CLIENT_NODE_DIR"/node-"$tag".{json,txt,meta.json}
    regen_selector
    print_ok "已删除 $tag"
}

client_check() {
    "$CLIENT_BIN" check -D "$CLIENT_CONF" -C "$CLIENT_CONF" 2>&1 | tail -2 || true
}

do_start(){ systemctl enable -q --now sb-client 2>/dev/null || systemd-run --unit=sb-client-adhoc "$CLIENT_BIN" run -D "$CLIENT_CONF" -C "$CLIENT_CONF"; }
do_stop(){ systemctl stop sb-client 2>/dev/null; systemctl stop sb-client-adhoc 2>/dev/null; pkill -f "sing-box run -D $CLIENT_CONF" 2>/dev/null; }
do_restart(){ do_stop; sleep 1; do_start; }
do_status(){
    echo "service: $(systemctl is-active sb-client 2>/dev/null || echo inactive)"
    ss -tlnp 2>/dev/null | grep -E ":$PORT_MIXED|:$PORT_CLASH" | head -4
    local n=0; for f in "$CLIENT_NODE_DIR"/node-*.json; do [[ -f $f ]] && n=$((n+1)); done
    echo "nodes: $n mixed: $PORT_MIXED clash: $PORT_CLASH"
}

do_info(){
    echo "root=$CLIENT_ROOT"
    echo "mixed=$BIND_LAN:$PORT_MIXED"
    echo "clash_api=$CLASH_LISTEN:$PORT_CLASH $( [[ -s $CLASH_SECRET_FILE ]] && echo "(secret 已设置)" || echo "(no secret, lo-only)" )"
    echo "ui=$CLIENT_UI (metacubexd)"
    client_check || true
}

download_ui() {
    print_msg "下载 metacubexd UI"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL --max-time 240 "$UI_ZIP_URL" -o "$tmp/ui.zip" || { print_err "UI 下载失败"; return 1; }
    unzip -q -o "$tmp/ui.zip" -d "$tmp/x"
    rm -rf "$CLIENT_UI"
    mv "$tmp/x/metacubexd-gh-pages" "$CLIENT_UI"
    rm -rf "$tmp"
    print_ok "UI 已就绪: $CLIENT_UI (访问 http://<client_ip>:$PORT_CLASH/ui (带 secret))"
}

case "${1:-}" in
    install) do_install ;;
    init) do_init ;;
    add) shift; add_node "$@" ;;
    list) regen_selector; ls "$CLIENT_NODE_DIR" | sed 's/^node-//;s/\.json$//' ;;
    del) del_node "$@" ;;
    update) update_node "$@" ;;
    check) client_check ;;
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    status) do_status ;;
    install-ui) download_ui ;;
    info) do_info ;;
    *) echo "用法: client.sh {install|init|add <url>|list|del <tag>|update|start|stop|restart|status|install-ui}"; exit 1 ;;
esac
