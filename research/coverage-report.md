# SB-Panel 协议覆盖报告 (sing-box v1.14.x, 2026-09)

## 1. 官方 sing-box v1.14 协议面（依据 https://sing-box.sagernet.org/configuration/inbound|outbound ）
Inbound(20): direct, mixed, socks, http, shadowsocks, vmess, trojan, naive, hysteria(v1, 遗留), shadowtls, tuic, hysteria2, vless, anytls, snell, tun, redirect, tproxy, cloudflared, tailcat
Outbound(23): direct, bridge, block, socks, http, shadowsocks, vmess, trojan, wireguard, hysteria(v1), vless, shadowtls, tuic, hysteria2, anytls, snell, tailcat, tor, ssh, dns, selector, urltest, naive
Transport: TCP / ws / grpc / http(H2) / httpupgrade；QUIC 类(hy2,tuic) 自带
TLS/Reality: reality 可叠 vless(tcp+vision)/grpc/http(H2) 及 anytls/trojan; 与 ws/httpupgrade 不适配（fscarmen+mack-a 均未提供, 官方未 white-list）

## 2. 第三方脚本能力（全文实读）
- fscarmen/sing-box (12 个绑死节点): XTLS+reality, hysteria2, tuic, ShadowTLS(v3+SS2022 内层), shadowsocks(2022), trojan, vmess+ws, vless+ws+tls, H2+reality, gRPC+reality, AnyTLS, naive. 版本兼容: 无 1.11/1.12 分支, 仅 force_version + 升级前后 check 回滚。证书全自签(cert.pem 36500d + cert_200.pem 200d,i.e. naive)。Hysteria1/Snell 不存在。
- mack-a/v2ray-agent (sing-box 模式 11 路): VLESS Vision, VLESS WS, VMess WS, Trojan, Hysteria2, VLESS Reality Vision, VLESS Reality gRPC, Tuic, Naive, VMess+httpupgrade(需 nginx), anytls. Xray-only: VLESS+XHTTP 任何变体, mldsa65 后量子 Reality. sing-box-only: hy2/tuic/naive/anytls.

## 3. 本项目当前
已实现并全部通过 (L1 check → L2 service → L3 客户端连接 → L4 公网 curl)：
- VLESS+Reality(三种 transport: vision/grpc/h2, transport 可选; SN随机来自 domains.sh)
- VLESS+WS+TLS
- VMess(ws/grpc/h2/tcp + tls/自签/reality)
- Trojan(TCP+TLS)
- Naive(HTTP/2, 真证书分支; 自签仅半客户端可用)
- Hysteria2(UDP, 自签/真证书, 端口跳跃, obfs)
- TUIC v5, Shadowsocks-2022, AnyTLS+Reality(AnyReality)
- ShadowTLS v3(双 inbound detour 结构)
- DNS 统一模, ruleset, outbound 管理, 端口转发 — 全部在现网依赖。

## 4. 决策: 本轮不再增加/新增有限制
- **vless+XHTTP 任何变体**: ✗ sing-box 无 xhttp transport (Xray 私有)。有 mack-a 用 Xray 模式支持，但不属于 sing-box。
- **hysteria(v1)**: 上游 deprecated; fscarmen/mack-a 均不提供; 二者缺 flagship 支持。sing-box inbound 虽在, 长期值低。
- **vmess+httpupgrade**: 需 nginx/BX 前置(单服务架构相冲), 添加 cost/valune 比不对。
- **Reality+WS / Reality+HTTPUpgrade**: neither two references nor tested by upstream; 需要更稳定的生态先例。
- **trojan+Reality**: 官方无限制但 0 生态先例(fscarmen/mack-a 均未做), 暂不实现, 已列为观察项。
- **snell / tailcat / cloudflared / tor / ssh / wireguard / selector/urltest**: 小众或非"协议节点"型, 增值有限。

## 5. 架构不变量(重申)
- 一个统一 systemd 服务; 不为任何协议开 per-proto service。
- 协议模块独立 `.sh`，插件式加载，共用 `lib.sh` 抽象(write_config/sb_check/落盘回滚、cert 工具、domains.sh Reality 域名源)。
- Reality 域名 100% 来源于 `https://raw.githubusercontent.com/mi1314cat/One-click-script/main/domains.sh` 的 `random_website()`（运行时拉取, 不本地复制数据）; 单点失败回退 www.oracle.com。
- 客户端产物: out/sb_client-<tag>.json (sing-box 格式) + sb_share-<tag>.txt (URI) + sb_client-<tag>.yaml (mihomo)。
- 客户端真实连通性测试 harness: test/e2e.sh (CC 侧执行, 证据 / test-results/README.md)。

## 6. 关键约束 / 红线 (协议面)
- vless reality 必须 utls 供 chrome fingerprint (未启 utls REALITY握手会退化为"act as real dest")。
- vision 仅 TCP/非 transport; gRPC/H2 组合 users 不得带 flow。
- anytls reality 在 1.12+;**`block`/`bridge`/`tailcat` 等非协议 outbound 不进入节点注册**。
- naive 客户端生态: sing-box 官方 build 无 cronet → 推荐用户使用官方 naiveproxy 客户端; 脚本端 tunneling shadowtls 双 inbound 已带 inner mux/padding。
- 引用: Github wiki 事实链 github.com/mi1314cat/sb-panel (this) `/opt/sb-panel/sing-box/conf/*.sh`。
