# Phase 1 架构设计 — 我自己的 sing-box 管理脚本（SB-Panel）

> 一个内核 + 一个统一 service + 一个配置目录 + 多个独立协议配置文件 + 多个独立协议生成脚本。
> 技术基线：sing-box **v1.14.1**（stable）。所有 CLI 参数顺序：`sing-box -D ... -C ... run`。

## 1. 目录结构（服务器侧，对齐 xary-core 习惯：根在 /opt/sb-panel）

```
/opt/sb-panel/sing-box/
├── sing-box                  # 内核二进制（锁定版本）
├── bin/
│   └── version               # 记录当前安装版本（单一 state 锚点）
├── config/                   # 实际运行配置（sing-box -C 加载）
│   ├── 00-log.json           # 固定：日志
│   ├── 01-dns.json           # DNS 模块（由 dns.sh 管理）
│   ├── 02-route.json         # route + rule-set + experimental.cache_file（route_base.sh 管理）
│   └── NN-<proto>-<idx>.json # 协议节点（由 conf/<proto>.sh 管理）
│       实现：reality-01.json, hysteria2-01.json, vless-01.json,
│             shadowsocks-01.json, tuic-01.json, anyreality-01.json
├── conf/                     # 协议配置生成/管理模块（学习 xary-core）
│   ├── lib.sh                # 公共工具（UI 打印/safe_read/端口/编号/证书扫描/防火墙/校验+重载）
│   ├── reality.sh
│   ├── hysteria2.sh
│   ├── vless.sh
│   ├── shadowsocks.sh
│   ├── tuic.sh
│   ├── anyreality.sh
│   ├── dns.sh                # DNS 服务器/分流/去广告/FakeIP/hijack
│   ├── ruleset.sh            # rule-set 管理（remote .srs/inline，含官方 geosite/geoip 源）
│   ├── portforward.sh        # 端口转发（direct inbound + override，模块 4 高级功能）
│   └── core.sh               # 内核安装/更新/卸载/版本管理（含备份回滚）
├── out/                      # 客户端产物（沿用 xray out/ 习惯）
│   ├── sb_share-*.txt        # 分享链接（sb:// 或 URI 标准链接）
│   ├── sb_client-*.json      # sing-box 客户端 outbound 片段（给 CC 侧 -C 合并）
│   ├── sb_meta-*.json        # 持久化元数据（端口/证书路径/extra）
│   └── sb_links-all.txt      # 汇总
└── backup/                   # 更新/变更前自动备份（config + 内核 + meta）
```

## 2. 服务（单 service，官方式写法）

```
/etc/systemd/system/sing-box.service
[Unit]
Description=sing-box unified service (sb-panel)
After=network.target
[Service]
ExecStart=/opt/sb-panel/sing-box/sing-box -D /opt/sb-panel/sing-box -C /opt/sb-panel/sing-box/config run
ExecReload=/bin/kill -HUP $MAINPID          # SIGHUP 软重载：check 失败自动保留旧实例
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
[Install]
WantedBy=multi-user.target
```

- **不加协议不建 service**：新增协议 = conf/<proto>.sh 生成一个 config/<proto>-NN.json → `sing-box check` → `kill -HUP`（软重载）或 restart（大改动时）。
- 热重载失败 sing-box 自动保留旧实例——天然的崩溃闸门，配合脚本先 check 双保险。
- 目录文件命名 `NN-*` 让合并排序可预期（字典序=编号序，避免协议文件互相踩标量键）。

## 3. 公共库 conf/lib.sh（收敛 xary-core 中每个脚本重复的工具函数）

- UI：print_title/info/ok/warn/error（stderr 输出，可被 source）
- 输入：safe_read / safe_read_port（占用检测）/ choose_listen_ip（v4/v6/dual）/ clean_input
- 编号：get_next_index PROTO-NN.json（与 xary-core 同规则）
- 证书：scan_certs（沿用 8 目录清单）/ generate_selfsigned（ECDSA P-256）/ extract_cert_domain / cert_not_expired / reality_keypair（调用 sing-box generate reality-keypair）
- 防火墙：open_port（ufw/firewall-cmd/iptables 回退）
- **通用落盘流程**（所有模块共用）：write_config(json) → jq -e 校验 → `sing-box check -C config/` 全目录验证 → 失败则删除刚写入文件并显示错误 → 成功则 kill -HUP 重载 → 检查服务 active → 失败自动恢复备份并 restart 旧配置
- 产物输出：write_out()（share link + client outbound json + meta）

## 4. 内核与版本管理（core.sh + 主入口）

- 安装：GitHub release tar.gz（amd64/arm64 自检 `-m`），校验 sha256 → `/opt/sb-panel/sing-box/sing-box`；默认锁定写死的安全 stable 版本（脚本内 `DEFAULT_VERSION=v1.14.1`，新 stable 出现需用户手动追）。
- 版本：`current`（sing-box version）/ `latest`（GitHub API 查最新 stable）/ `install <version>` 指定版本（可 numeric-less alpha？默认拒绝 pre-release，可选 `--pre` 覆盖）。
- 更新流程（事务化）：
  1. 备份 config/ + out/ + 二进制 → backup/<ts>/
  2. 下载新版本到临时路径 + sha256 校验
  3. 新二进制对新配置做 `sing-box check -C config/`（模拟新语义）
     - **失败 → 不动现网**：保留旧二进制 + 恢复配置（如有改动）→ 报告具体错误
     - 成功 → 原子替换二进制 → restart → service 未 active 则回滚二进制并 restart
  4. 尝试 `sing-box format -w`，输出 1.14→1.15 的 deprecation 检查清单（grep config 中 deprecated 字段提醒用户）
- 卸载：stop/disable service + 删安装目录 + 保留 config 备份。

## 5. 协议模块契约（conf/<proto>.sh）

每个模块实现统一 CLI + 菜单接口：
```
add | list | del | modify | regen   子命令模式
bash conf/reality.sh                = 交互菜单
```
- add：输入集聚合（协议特定）→ 生成 json → 通用落盘流程 → 输出分享链接 + CC(sing-box client) outbound 片段 + mihomo 可用与否提示（如 anyreality 不支持写入 mihomo、reality 用 reality-opts 可写）
- del：删 config json + out 产物 +（如适用）撤销 iptables/hop；不产 service 变更
- 编号沿用 xary-core：`<proto>-NN.json` + tag `<proto>NN`
- 协议间共享 REALITY 证书体系：keypair 存 out/reality-keys.json，anyreality 与 reality 可复用

### 协议一（v1 覆盖，Phase 2/3）
| 模块 | 服务端 inbound | 客户端产物 |
|---|---|---|
| reality.sh | vless reality reality+vision | sb://vless 标准链接 + mihomo（reality-opts）|
| hysteria2.sh | hysteria2 + 证书扫描/自签 + mport（端口跳跃可选）| hysteria2:// + mihomo |
| anyreality.sh | anytls reality（同上 keypair，独立端口/short_id）| anytls:// + sing-box client only（mihomo 不可用提示）|
| vless.sh | vless ws+ tls | 标准链接 + mihomo |
| shadowsocks.sh | 2022-blake3 | ss:// |
| tuic.sh | tuic v5 证书 | tuic:// |

## 6. DNS / 分流 / 去广告 / FakeIP / hijack（dns.sh + ruleset.sh，按官方 1.14 格式）

- 01-dns.json 默认骨架（模块可改，schema 均用 1.14 对象格式）：
  - servers：`{"type":"udp","server":"223.5.5.5"}` 国内、`{"type":"tls","server":"8.8.8.8","domain_resolver":"dns-direct"}` 国外（需 bootstrap resolver）
  - rules：国内域名（rule-set geosite cn）→ dns-local；广告（rule-set category-ads-all）→ `action: reject`；FakeIP 可选
  - `optimistic:true`、`cache_capacity`、`timeout`
  - **不写** independent_cache / store_rdrc / 老 address 字段
- DNS 管理子菜单：服务器增删、分流规则增删、去广告开关（remote rule-set category-ads-all，可换 MetaCubeX 镜像）、自定义黑/白名单（inline rule 或 local rule-set）、FakeIP 池开关、hijack-dns 路由
- ruleset.sh：inline/local/remote 三种，管理 tag 清单 + update_interval + cache_file 缓存（experimental.cache_file.enabled）；不权威决定"该用哪套"，内置官方源推荐组（ads/cn/telegram/ai/streaming 类 .srs）

## 7. 路由骨架（02-route.json）

- route：default_domain_resolver、final outbound、rules（sniff → hijack-dns → 分流）
- out/ 下 target-*.json 片段：direct/chain outbound 由 outbound 管理子模块管理（对齐 xary-core 的 out-01.json 模式）
- 第一版 route 保持精简（direct + hijack-dns + ads reject），功能开关不在首版塞满

## 8. 端口转发（portforward.sh, Phase 4）

- 每条转发 = 一个 config 内文件：`{"type":"direct", listen, listen_port, override_address, override_port}` + route rule inbound→direct
- UI 与其他协议模块同构；不支持端口范围 → 明确提示逐条添加或建议 nftables

## 9. 配置验证与安全网（贯穿所有写路径）

1. `jq -e .` 语法
2. `sing-box check -D root -C config/`（新文件在内）
3. 失败：撤文件 + 显示错误，**当前运行实例不动**
4. 成功：kill -HUP 软重载（失败自动保留旧实例）→ restart 兜底可选
5. 更新内核时双层备份 + resilience（回滚，见 §4）

## 10. 开发阶段计划

- **Phase 2（最小可运行）**：sing-box.sh 主入口（菜单框架）+ lib.sh + core.sh（安装/版本/更新事务）+ 00-log + 统一 service + verify + 状态/日志
- **Phase 3（协议）**：reality → hysteria2 → anyreality → vless/ws → shadowsocks → tuic，每产 1 次可实测（RN 上真跑 + CC arm64 客户端互通验证）
- **Phase 4（高级）**：dns.sh（服务器/分流/去广告/FakeIP/hijack）+ ruleset.sh + portforward.sh + 客户端侧（CC arm64 部署一个 SB 客户端 service）
