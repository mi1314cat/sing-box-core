# SB-Panel 真实连通性测试矩阵（协议覆盖审计轮，2026-09）

测试执行位置：CC（aarch64 Armbian 客户端，真实家庭网络）→ RN（203.0.113.10，amd64 sing-box 服务端，v1.14.1）
全部节点由 RN 上 sb-panel 协议模块真实生成（`bash conf/<proto>.sh add`），产物 `out/sb_client-<tag>.json` 直接组装为客户端配置浮层，客户端服务端均为 **项目脚本产物，不是手工 JSON**。
验证口径：`curl -x <节点代理> http://ip.sb` 结果必须 == `203.0.113.10`（RN 主机 eth0 实 IP；已将 RN direct outbound `bind_interface=eth0`，规避测试机上的 WARP 干扰出站 IP 判定）。
> ⚠️ 重要教训：`curl --noproxy "*" -x ...` 会禁用 `-x` 泊位连空网桥（把本机直连当"通过"，出现 CC 出口 IP 假阳性）— 已修正测试方法。早前"验证失败"的客诉实为该命令错误+老节点 uuid 残留，非协议问题。

| 协议/组合 | L1 sing-box check | L2 服务+端口监听 | L3 客户端真实连接 | L4 实际公网请求 | 证据 |
|---|---|---|---|---|---|
| VLESS+Reality+Vision | PASS | PASS (52270) | PASS | PASS (203.0.113.10) | connectivity log + RN journal `inbound connection from 198.51.100.17` |
| VLESS+Reality+Vision (节点2) | PASS | PASS | PASS | PASS | e2e CSV reality02 |
| VLESS+Reality+Vision (domains.sh 随机 sni) | PASS | PASS (24665) | PASS（修复服务端 flow 缺失后） | PASS | e2e CSV reality03 + journal "flow mismatch"修复 |
| VLESS+Reality+gRPC | 已并入 reality.sh transport 选项 | 生成已验证 | （组合层更新，客户端末段） | — | reality.sh 第四步选择 2)gRPC 生成 grpc+reality |
| VLESS+Reality+H2(http) | 已并入 reality.sh transport 选项 | 生成已验证 | （组合层更新） | — | reality.sh 第四步选择 3)h2 |
| VLESS+WS+TLS（自签） | PASS | PASS (39646) | PASS | PASS | e2e CSV vless01 |
| VMess+TCP+TLS 自签 | PASS | PASS (48837) | PASS（SPKI pin 修复） | PASS | e2e CSV vmess01 |
| VMess+WS+TLS 自签 | PASS | PASS (29047) | PASS | PASS | e2e CSV vmess02 |
| Trojan+TLS 自签(pin) | PASS | PASS (34481) | PASS（SPKI base64 pin 修复） | PASS | e2e CSV trojan01 |
| NaiveProxy(HTTP/2 CONNECT) | PASS | PASS (32457) | PASS（官方 naiveproxy 客户端 + CA 信任链, `//padding` 原生） | PASS | `test-results/naive-e2e.md` + naive.log |
| Hysteria2 (UDP, 自签, SPKI pin) | PASS | PASS (29546, tcp+udp) | PASS（obfs NONE 与客户端字段一致性修复） | PASS | e2e CSV hysteria201 |
| TUIC v5 (UDP) | PASS | PASS | PASS | PASS | e2e CSV tuic01 |
| Shadowsocks-2022 (aes-128) | PASS | PASS | PASS | PASS | e2e CSV shadowsocks01 |
| ShadowTLS v3 + 内层 SS-2022 | PASS | PASS (外+内 127.0.0.1 双 inbound) | PASS（detour 结构勘察修复后） | PASS | e2e CSV shadowtls01 |
| AnyTLS+REALITY (AnyReality) | PASS | PASS (35175, domains.sh sni=software.download.prss.microsoft.com) | PASS（密钥对一致性修复后） | PASS | e2e CSV anyreality01 |
| AnyTLS plain | 同 anyreality 模块（不叠加 reality 时） | — | 未单独开户（与已 PASS 组合共用协议实现） | — | — |
| DNS 模块 / ruleset / outbound 管理 / portforward | PASS | PASS | n/a | n/a | RN sing-box check 通过 (全部配置合并合法) |

## 修复路径（全部按"定位→分类→修复→复测"）
| 现象 | 定性 | 修复 |
|---|---|---|
| `"inbound vless reality verification failed"` 前期大面积 | ⑧ 测试方法错误：`--noproxy "*"` 使 `-x` 失效 + 测试机 WARP | 去掉 --noproxy |
| reality03 "expected none, got vision" | ① G server 配置在 transport 未注入 vision flow | jq 补 users flow |
| trojan/vmess/hy2/naive pin 校验失败 | ① 模块只生成 cert-DER hex pin，应为 base64(SPKI) | lib.sh `cert_spki_pin_base64`，四模块统一换 |
| hy2 deadline 超时④ 场景 | ⑨ 客户端模板硬编码 obfs=salamander"none" | 模板与 mask 联动 |
| shadowtls "dependency[shadowtls-out] not found" | ⑨ 客户端缺 shadowtls 出站 | 双出站结构重写 |
| anyreality `lookup add: NXDOMAIN` | ⑨ 客户端 server 字段填充错 | 重新写入 $server_ip |
| naive "cronet: library not found" | ① sing-box 官方发行版无 cronet | 用官方 naiveproxy 客户端 + 自建 CA（真实证书的替代方案） |

## 证据文件
- e2e-results.csv — 每协议 PASS/FAIL (● latest run)
- <tag>-serverlog.txt — 每协议客户端运行日志（含 trace）
- naive-e2e.md — Naive 的专门记录（官方客户端通道）
