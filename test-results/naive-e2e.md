!mv 2>/dev/null || true

## NaiveProxy 真实客户端 E2E 记录 (Level 3)

- 服务端: RN (203.0.113.10:32457), config/naive-01.json (sb-panel `bash conf/naive.sh add` 生成)
- 本轮服务端 TLS: CA 签发的真证书 (`/tmp/srv.crt`, CN=amd.com, SAN DNS:amd.com, EKU=serverAuth) — 官方 naiveproxy (Chromium 网络栈) 不信任自签 leaf
- 客户端: 官方 naiveproxy linux-arm64 (naiveproxy v150.0.7871.63-1), 配置 `--listen=socks://127.0.0.1:2091 --proxy=https://f560142279d9:0cdf12647381@amd.com:32457 --host-resolver-rules="MAP amd.com 203.0.113.10"`; CC 系统信任链已加入 SB-Panel 测试 CA
- 结果: `curl --socks5h` → https://api.ipify.org 返回 203.0.113.10 (RN 主机)

PASS 原因: padding 协议由 naive 官方实现，属 level-4 明证。

## sing-box 自签路径限制 (归档)
- sing-box **控制面**(inbound) 支持自签；但官方 sing-box **客户端** naive outbound 在无 cronet 的构建上无法承载；naiveproxy 官方客户端无法信任自签 → 自签 naive 属"半客户端"路径，正式支持须真证书。
- 模块保留: 真证书 / 自签+pin 两分支；自签模式在分享里标注限制。
