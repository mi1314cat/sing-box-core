# 简介一键安装脚本
## sing-box内核6+nginx
```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/singbox.sh)
```
## sing-box 4 
```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/nsb.sh)
```
### reality hysteria2二合一脚本

```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/install.sh)
```
### reality和hysteria2 VLESS-Vision-TLS 三合一脚本 **需要域名**

```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/SING.sh)
```
### reality和hysteria2 vmess ws三合一脚本

```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/beta.sh)
```
# sing-box max 多协议选择
```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-max/raw/refs/heads/main/sing-box.sh)
```
## tcp-brutal reality(双端sing-box 1.7.0及以上可用)



```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/tcp-brutal-reality.sh)
```
 brutal reality vision reality hysteria2三合一(双端sing-box 1.7.0及以上可用)，warp分类，端口跳跃等功能

```bash
bash <(curl -fsSL https://github.com/mi1314cat/sing-box-core/raw/refs/heads/main/brutal-reality-hysteria.sh)
```
# sing-box服务管理

## 启用
```
sudo systemctl enable sing-box
```
## 禁用
```
sudo systemctl disable sing-box
```
## 启动
```
sudo systemctl start sing-box
```
## 停止	
```
sudo systemctl stop sing-box
```
## 强行停止
```
sudo systemctl kill sing-box
```
## 重新启动	
```
sudo systemctl restart sing-box
```
## 查看状态
```
sudo systemctl status sing-box
```
## 查看日志	
```
sudo journalctl -u sing-box --output cat -e
```
## 实时日志	
```
sudo journalctl -u sing-box --output cat -f
```


























