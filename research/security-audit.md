# GitHub 公开信息安全审计（第二阶段 Phase 1-2 产出）

审计对象: github.com/mi1314cat/sing-box-core 全部 HEAD 文件 + 全部历史 commit 的 blob 级扫描（rev-list --all × ls-tree × show 全量，两个阶段脚本）。

## 发现
| 类型 | 位置 | 处置 |
|---|---|---|
| 真实服务器公网 IPv4 | 仅我方两个提交 (8eec484/cf87e12) 的 5 个文件（test-results/*.md+csv、test/e2e.sh、README、phase0-report、coverage-report） | 已 rewrite 为 RFC5737 `203.0.113.x`/`198.51.100.x` |
| 内网 IP/MAC（LAN 网关、192.168.1.178） | 11 个 test-results 日志 | 已 rewrite 为 `192.0.2.x`/`xx:xx..` |
| 本地部署路径 /root/catmi | README/design/lib.sh 默认 SB_ROOT/scripts | 已统一为 `/opt/sb-panel`（SB_ROOT 环境变量可覆盖） |
| 主机名/环境代号 (racknerd/armbian/RN/CC/104.28 WARP egress IP) | README 2 行 | 已改写为 Server-A/Client-B 结构化描述 |
| 真实节点凭证（uuid/password/私钥/分享链接） | **未出现在任何 HEAD blob 或历史 blob** | 无 | 
| SSH key / GitHub PAT / API key / BEGIN PRIVATE KEY | 历史 blob 全量扫描 | 无命中 |
| 废弃项目历史 (nsb.sh/singbox.sh 等旧提交) | 本阶段前原仓库历史 | 无上述敏感值 |

## Git 历史处理建议
真实 IP 存在于两个可识别提交的两个历史版本 → **不建议自行 rewrite**；建议把仓库 GitHub 端做一次 Garbage-fetch 或接受"已是公开 IP、短期暴露"的现状:
- 若 CN 出口对 203.0.113.x 已不再有效（服务器在下轮直接下线/换 IP），可考虑 contact GitHub Support 做 Dangling-branch 清理；
- 如历史必须保留真实内容以便引用，可后续 archive 到私有仓库。当前公网 HEAD 已完全脱敏。

## 残余可接受项 (非 secret)
- 域名清单测试出现的公共 CDN 域名（npm/MSN/Apple 下载域，domains.sh 原始表本身就是公开资源，不算部署信息）
- 测试日志里的 `sing-box` 框架 trace 行（无任何凭据）
- link 装饰符号 ANSI codes (纯色彩代码)
