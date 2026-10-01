#!/usr/bin/env bash
# SB-Panel 防火墙规则同步 —— 由 systemd 单元 sb-panel-nft.service 在开机时调用。
#
# 为什么需要这个脚本:
#   用户常用的另一套 nftables.sh, 其 persist_dynamic_ports() 会把链上所有
#   "dport N accept" 的规则扫走、去注释、存进它自己的文件。于是:
#     1. 本面板关掉某端口后, 对方文件里那条**仍然留着**
#     2. 下次重启, 对方单元先加载它, 端口被重新打开
#   而此时那条规则已没有任何标记, 从外面看不出它曾经属于哪个节点。
#
# 做法: 本面板每次主动关闭端口时把端口记进 .fw-closed-ports。
# 开机时按这份记录清理"已关闭端口的残留", 再加载自己的规则文件。
# 标记为 SSH 的规则永远不动 —— 那是唯一碰不得的。
#
# 本面板自己开的端口按 .fw-ports 登记表重新放行, 登记表是唯一真实来源,
# 因此规则文件与实际状态不会漂移。
#
# 刻意不 source lib.sh: 开机路径上的依赖越少越稳, 这里只需要几个路径。

set -u

SB_ROOT="${SB_ROOT:-/root/catmi/sing-box}"
SB_NFT_OWN_FILE="${SB_NFT_OWN_FILE:-/etc/nftables.d/zz-sb-panel.nft}"
CLOSED_LIST="$SB_ROOT/.fw-closed-ports"
FW_LIST="$SB_ROOT/.fw-ports"

command -v nft >/dev/null 2>&1 || exit 0
# 只在确实由原生 nft 管理时才动手 —— 装 iptables/ufw 的机器不该被本脚本碰
nft list table inet filter >/dev/null 2>&1 || exit 0

# ---- 第一步: 清理已关闭端口的残留 (对方文件里的无标记副本) ----
if [[ -f "$CLOSED_LIST" ]]; then
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        # 已在登记表里的端口是要放行的, 不算残留
        grep -qxF "$p" "$FW_LIST" 2>/dev/null && continue
        # 系统常用端口不归节点放行逻辑管
        case "$p" in
            22|80|443|8443|3306|5432|6379|27017) continue ;;
        esac
        handles=$(nft -a list chain inet filter input 2>/dev/null \
                  | grep -E "dport ${p}([[:space:]]|$)" \
                  | grep -v 'UFW_PANEL_SSH' \
                  | grep -oE "handle [0-9]+" | awk '{print $2}')
        for h in $handles; do
            nft delete rule inet filter input handle "$h" 2>/dev/null \
                && echo "  已清理关闭端口 $p 的残留规则"
        done
    done < "$CLOSED_LIST"
fi

# ---- 第二步: 加载本面板的规则文件 (nft -f 为追加语义, 不影响别人的规则) ----
if [[ -f "$SB_NFT_OWN_FILE" ]]; then
    nft -f "$SB_NFT_OWN_FILE" 2>/dev/null && echo "  已加载 $SB_NFT_OWN_FILE"
fi

exit 0
