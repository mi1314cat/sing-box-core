# SB-Panel — 我自己的 sing-box 管理脚本

> 一个内核 + 一个统一 systemd service + 一个配置目录多个 JSON + 每协议一个独立 conf/*.sh
> 架构对齐 xary-core (xray-panel.sh) 的使用习惯，配置生成以 sing-box v1.14.x 官方为唯一事实源。

## 使用
```bash
bash /root/catmi/sing-box/sing-box.sh          # 菜单
bash sing-box.sh {init|check|reload|restart|status|list|node}   # CLI
```

## 结构
```
/root/catmi/sing-box/
├── sing-box            内核 (core.sh 锁定版本安装, latest stable 默认)
├── config/*.json       运行配置（sing-box -C 合并, API: check/reload/format/merge）
├── conf/*.sh           协议与功能模块（每协议一文件, 生成 <proto>-NN.json）
├── out/                客户端产物: sb_share-*.txt / sb_client-*.json|yaml / sb_meta-*.json
└── backup/             自动备份（写 CONFIG 前自动, 保留 5 份）
```

## 模块
| 模块 | 职责 |
|---|---|
| core.sh | 安装/卸载/指定版本/更新事务（备份→下载→新内核预检→原子替换→失败回滚） |
| reality.sh | VLESS-REALITY/Vision; keypair 共享 out/reality-keys.json; dest 默认 www.oracle.com |
| hysteria2.sh | hysteria2; 证书扫描（xary-core 清单）+自签 ECDSA+pin 分享; 端口跳跃 DNAT |
| anyreality.sh | AnyTLS+REALITY(1.12+); 复用 REALITY keypair; mihomo 不兼容提示 |
| vless.sh | VLESS WS+TLS |
| shadowsocks.sh | 2022-blake3 |
| tuic.sh | TUIC v5 (1.14: 无 authentication_timeout) |
| dns.sh | 01-dns.json: 服务器/分流/去广告/FakeIP; 1.14 对象格式 (永不生成 legacy 字段) |
| ruleset.sh | 02-rule-set.json 远程 .srs + 03-route.json 路由规则 |
| portforward.sh | direct inbound + override_* 原生 TCP/UDP 转发 (无端口范围, 官方知情决定) |
| outbound.sh | 出站管理 (direct/socks/http), 删除联动 route 清理 |
| lib.sh | 公共: UI/端口/编号/证书/防火墙/check/SIGHUP 软重载/备份 |

## 安全流程（所有写路径）
```
备份 → jq 语法 → sing-box check 整目录 (check 不过自动撤文件)
     → systemctl reload (SIGHUP 软重载, 零断流; 失败自动 restart 兜底)
     → 运行期失败 (如 rule-set 下载) → dns_edit 自动回滚 + restart 恢复
```

## sing-box 1.14 技术红线（生成配置永不包含）
- 老式 DNS `address"/"tls://`、`dns.fakeip` 顶层、geosite/geoip 字段、block/dns outbound、
  DNS rule inline `server`、`authentication_timeout`(TUIC)、`download_detour`(rule-set)
- `http_clients[0].outbound` → 必须用 Dial Fields `detour`；且 detour 到空 direct outbound 会被运行期 FATAL
- 1.14 起 outbound 请求域名需 `route.default_domain_resolver`

## 实测记录 (2026-09)
- RN (amd64): 1.14.1 安装 服务 check / 软重载 / 更新跳过 / 5 协议节点 / 端口转发 / DNS / rule-set ✅
- CC (arm64): 1.14.1 arm64 客户端 mixed:2090 → RN reality01 → 出站 ✅ (104.28.201.80 与 RN 一致)
- reality: java.com 作 dest 会因 301 导致 `REALITY: processed invalid connection` — 用 www.oracle.com ✅

## 维护原则
- 协议字段变化 → 只改对应 conf/<proto>.sh
- 新 stable 发布 → 用户主动 `core.sh update`（已最新则跳过；预检失败不改动现网）
