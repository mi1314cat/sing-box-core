# 协议完整性矩阵（基于 sing-box v1.14.1 官方文档 / fscarmen sing-box.sh L20-4862 全文 / mack-a install.sh L2478-5491 实读）

## 一、为什么当前只有 6 个 .sh（问题根因，必须回答）

1. **调研阶段（Phase 0）只针对指定重点做了深查**：Reality/Hysteria2/TUIC/AnyReality/DNS/多配置 —— 这些直接变成了脚本；
2. `vless.sh` 只实现了 WS+TLS 一种组合（菜单占位是"Phase 3 计划"概念，未覆盖 transport 组合维度）；
3. fscarmen 与 mack-a 当时只输出了"功能参考要点"，**没有逐行读取协议生成函数**（本次已补：全文实读 + 行号证据，见 audit-fscarmen-sing-box.md 与本报告 mack-a 节）；
4. 架构未遗漏扩展性——add_node_menu 是数据驱动可加行，缺的是模块，不是架构。
5. 错误归类问题：Shadowsocks 误按独立协议存在（正确抽象:协议=SS,认证=2022 PSK,与 ShadowTLS 内层共享）；"AnyReality"正确归类为 anytls+reality 组合而非独立协议。

## 二、官方 sing-box v1.14 完整协议面

### Inbound（节点侧，20 种）
direct / mixed / socks / http / shadowsocks / vmess / trojan / naive / hysteria / shadowtls / tuic / hysteria2 / vless / anytls / snell / tun / redirect / tproxy / cloudflared / tailcat

### Outbound（23 种）
direct / bridge / block / socks / http / shadowsocks / vmess / trojan / wireguard / hysteria / vless / shadowtls / tuic / hysteria2 / anytls / snell / tailcat / tor / ssh / dns / selector / urltest / naive

### Transport（共享字段，对 vless/vmess/trojan 可叠加）
TCP(默认) / ws / grpc / HTTP(HTTP/2) / httpupgrade / QUIC(hysteria/tuic/hy2 自带)

### TLS / Reality
- TLS: 全部 TCP 类协议 + vmess(trojan/vless/naive 有内嵌 tls)可叠加
- Reality: 官方共享 TLS 字段,rdf 与 transport **无限开会报错/退化的组合需实测**；已知可用:
  - vless+vision+reality ✅(本项目已测)
  - anytls+reality ✅(本项目实测)
  - vless+grpc+reality ✅(fscarmen j/k 节点 + mack-a 8 号, sing-box 可行)
  - vless+http(H2)+reality ✅(fscarmen j 节点)
- Reality+WS / Reality+HTTPUpgrade: 两个第三方都不提供；官方无 transport 白名单，但 ws/sidecar over reality 需要流量对齐，属实验性 → 暂不实现

## 三、第三方实际支持矩阵

| 协议组合 | sing-box 官方 | Server | Client | fscarmen | mack-a | 当前项目 | TLS | Reality | TCP | UDP | WS | gRPC | H2 | XHTTP | 复杂度 | 独立模块? |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| vless+vision+reality | 是 | ✅ | ✅ | 是(节点b) | 是(7号) | ✅ | ✔ | ✔ | ✔ | - | - | - | - | 高 | 中 | ✅ reality.sh |
| vless+grpc+reality | 是 | ✅ | ✅ | 是(k) | 是(8号) | ❌缺失 | ✔ | ✔ | ✔ | - | - | ✔ | - | 中 | 并入 reality.sh(组合) |
| vless+http(H2)+reality | 是 | ✅ | ✅ | 是(j) | 否 | ❌ | ✔ | ✔ | ✔ | - | - | - | ✔ | 中 | 并入 reality.sh(组合) |
| vless/plain+tls(ws 等) | 是 | ✅ | ✅ | 是(i) | 是(1号) | ✅ vless.sh | ✔ | - | ✔ | - | ✔ | - | - | 低 | ✅ |
| vmess(+ws/csv 等) | 是 | ✅ | ✅ | 是(h) | 是(3/11号) | ❌ | (可选) | - | ✔ | ✔ | (ws) | - | - | 中 | 新增 vmess.sh |
| trojan(+tls) | 是 | ✅ | ✅ | 是(g) | 是(4号) | ❌ | ✔ | (可叠加) | ✔ | - | - | - | - | 低 | 新增 trojan.sh |
| hysteria2 | 是 | ✅ | ✅ | 是(c) | 是(6号) | ✅ | ✔ | - | - | ✔ | - | - | - | 中 | ✅ |
| tuic(v5) | 是 | ✅ | ✅ | 是(d) | 是(9号) | ✅ | ✔ | - | - | ✔UDP | - | - | - | 中 | ✅ |
| shadowsocks(2022) | 是 | ✅ | ✅ | 是(f,内层) | - | ✅ | - | - | ✔ | ✔ | - | - | - | 低 | ✅ + shadowtls 内层复用 |
| shadowtls+ss2022 内层 | 是 | ✅ | ✅ | 是(e,双inbound) | - | ❌ | ✔(伪装) | - | ✔ | - | - | - | - | 中 | 新增 shadowtls.sh |
| anytls(+reality=AnyReality) | 是(1.12+) | ✅ | ✅ | 是(l) | 是(13号) | ✅ anyreality.sh | ✔+ | ✔ | ✔ | - | - | - | - | 中 | ✅ |
| naive | 是 | ✅ | ✅ | 是(m) | 是(10号) | ❌ | ✔(必真证书) | - | ✔ | - | ✔(H2) | - | - | 中 | 新增 naive.sh |
| hysteria(v1) | 是(遗留) | ✅ | ✅ | **无**(fscarmen/mpack-a 均无) | - | ❌ | ✔ | - | - | ✔UDP | - | - | - | 中 | 暂不(详见下) |
| socks/mixed/http(inbound) | 是 | ✅ | ✅ | 中转用 | - | 出站管理含 socks/http | - | - | ✔ | ✔ | - | - | - | 低 | 已含于 outbound.sh 思路 |
| vmess+httpupgrade | 是 | ✅ | ✅ | ❌(fscarmen无) | 是(11号,需nginx) | ❌ | ✔(需前置) | - | ✔ | - | - | - | httpupgrade | 高 | 暂不(需 nginx 前置) |
| vless+xhttp(全变体) | **否**(Xray 私有) | n/a | n/a | ❌ | Xray-only(12/14号) | 不可 | ✔ | ✔ | ✔ | - | - | - | - | - | **禁止迁移**(sing-box 无 xhttp) |
| hysteria over UDP hopping | 是 | ✅ | ✅ | 是(c) | 是(6号) | ✅(hop opt) | - | - | - | ✔ | - | - | - | 中 | ✅ |
| trojan+reality | 可(官方共享TLS) | ✅ | ✅ | ❌ | ❌ | ❌ | ✔ | ✔ | ✔ | - | - | - | - | 中 | 暂不(第三方均无先例,风险高) |
| shadowsocks+tls-in-tls 检测 | - | - | - | - | - | - | - | - | - | - | - | - | - | 低 | 非独立模块 |

## 四、决策清单

### 必须增加（本轮实施）
1. **vless+grpc+reality** 与 **vless+http(H2)+reality** → reality.sh 会话新增 transport 选择（vision/grpc/h2），不新建文件
2. **vmess.sh**（transport ws 默认，可无 TLS 或 Reality 可叠加）
3. **trojan.sh**（TCP+TLS，支持真证书/自签 pin）
4. **naive.sh**（HTTP/2 H2 authentication, 需真证书或专用 200 天自签）
5. **shadowtls.sh**（v3 + strict_mode + detour 内层 SS2022，双 inbound 同文件）

### 暂不增加（理由）
- **vless+XHTTP 任何变体**：sing-box 根本无 xhttp transport（Xray 私有，两脚本同证）
- **hysteria(v1)**：生态已 deprecated、两个参考脚本都未提供、sing-box inbound 仍在但因主管部门版本 dolly 剧烈变化并有 v2 继任
- **vmess+httpupgrade / reality+ws**：需 nginx/BX/边界前提，与"脚本主机直起"场景不符；mack-a 已实现但走 nginx 前置
- **trojan+reality**：官方无白名单禁止但两大脚本均无先例，列入观察
- **snell / tailcat / cloudflared / tor / ssh / wireguard endpoint**：小众或属链路功能非协议节点，价值低于维护成本
- **Hysteria1-sniff/combo**：同 v1 理由
