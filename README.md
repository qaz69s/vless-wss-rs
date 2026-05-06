# vless-wss-rs

纯 Rust 编写的 VLESS WebSocket + TLS 服务端，静态二进制，零运行时依赖。

## 功能特性

- VLESS TCP over WebSocket + TLS
- Let's Encrypt 证书（acme.sh DNS-01 自动申请，Cloudflare API 集成）
- 支持任意 CDN（如 Cloudflare）
- 纯 Rust，无 OpenSSL 依赖
- Systemd 后台守护进程，开机自启
- 一键导入链接，复制即用

## 一键安装

服务器上运行（只需提供 CF Token 和根域名）：

```bash
CF_TOKEN="你的CFToken" BASE_DOMAIN="你的域名" bash <(curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh)
```

**示例：**
```bash
CF_TOKEN="cfat_xxxxx" BASE_DOMAIN="xxvx.de" bash <(curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh)
```

安装过程全自动：随机子域名 → DNS 自动录入 → 证书申请 → Systemd 部署 → 后台运行。

## 安装参数（可选）

可通过环境变量覆盖默认值：

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `CF_TOKEN` | 必填 | Cloudflare API Token（Zone:Read + DNS:Edit） |
| `BASE_DOMAIN` | 必填 | 根域名（如 `example.com`） |
| `UUID` | 自动生成 | VLESS 用户 UUID |
| `MODE` | `1` | 固定为 1（自动模式） |
| `LISTEN` | `0.0.0.0:443` | 监听地址 |

## 手动运行

### 下载二进制

```bash
curl -sL https://github.com/qaz69s/vless-wss-rs/releases/latest/download/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz -o /tmp/vless.tar.gz
tar xzf /tmp/vless.tar.gz -C /tmp
chmod +x /tmp/vless-wss-rs
mv /tmp/vless-wss-rs /usr/local/bin/
```

### 运行

```bash
vless-wss-rs \
  --cert /etc/vless-wss-rs/cert.cer \
  --key /etc/vless-wss-rs/private.key \
  --uuid 你的UUID \
  --listen 0.0.0.0:443
```

## 全部参数

```
--cert <文件>   TLS 证书文件 (PEM)，必填
--key <文件>    TLS 私钥文件 (PEM)，必填
--uuid <UUID>   VLESS 用户 UUID，必填
--listen <地址>  监听地址 [默认: 0.0.0.0:443]
```

## 证书说明

证书由 acme.sh 通过 DNS-01 自动申请，存放在 `/etc/vless-wss-rs/` 目录，acme.sh 自动续期，无需手动操作。

## 节点导入链接格式

```
vless://<UUID>@<子域名>:<端口>?encryption=none&security=tls&type=ws&sni=<子域名>#vless-wss-rs
```

安装完成后脚本自动打印完整导入链接。

## 管理命令

```bash
# 查看日志
journalctl -u vless-wss-rs -f

# 重启服务
systemctl restart vless-wss-rs

# 停止服务
systemctl stop vless-wss-rs

# 卸载
systemctl disable vless-wss-rs
rm /etc/systemd/system/vless-wss-rs.service
rm /usr/local/bin/vless-wss-rs
```

## 工作原理

1. 客户端通过 TLS + WebSocket 连接
2. 服务端读取第一个二进制帧（VLESS 首包）
3. 从首包解析 UUID、指令、目标地址/端口
4. 服务端连接到目标上游
5. 双向转发：WebSocket ↔ 上游

## 自行编译

```bash
git clone https://github.com/qaz69s/vless-wss-rs.git
cd vless-wss-rs
cargo build --release
./target/release/vless-wss-rs --help
```

## 已知限制

- 仅支持 TCP（暂无 UDP/XUDP）
- TLS 内部传输为明文，VLESS 头未加密
- 无连接数限制 / 流量统计
