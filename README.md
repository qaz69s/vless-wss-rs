# vless-wss-rs

纯 Rust 编写的 VLESS WebSocket + TLS 服务端，体积小（静态二进制），零运行时依赖。

## 功能特性

- VLESS TCP over WebSocket + TLS
- Let's Encrypt 证书（acme.sh HTTP-01 自动申请）
- 支持任意 CDN（如 Cloudflare）
- 纯 Rust，无 OpenSSL 依赖
- 静态编译，无需运行时

## 一键安装

```bash
curl -sL https://raw.githubusercontent.com/qaz69s/vless-wss-rs/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

交互式部署，只需输入 Cloudflare API Token，其余全部自动完成（域名检测 → DNS 录入 → 申请证书 → 启动服务）。

## 手动运行

### 已有证书

```bash
vless-wss-rs \
  --cert /root/.acme.sh/example.com/fullchain.cer \
  --key /root/.acme.sh/example.com/example.com.key \
  --domain example.com \
  --uuid 你的UUID \
  --listen 0.0.0.0:8443
```

### 所有参数

```
--cert <文件>     TLS 证书文件 (PEM)
--key <文件>      TLS 私钥文件 (PEM)
--domain <域名>   域名（用于 VLESS 节点链接）
--uuid <UUID>     VLESS 用户 UUID（可不填，自动生成）
--listen <地址>   监听地址 [默认: 0.0.0.0:8443]
```

## 工作原理

1. 客户端通过 TLS + WebSocket 连接
2. 服务端读取第一个二进制帧（VLESS 首包）
3. 从首包解析 UUID、指令、目标地址/端口
4. 服务端连接到目标上游
5. 双向转发：WebSocket ↔ 上游

## 节点链接格式

```
vless://<UUID>@<域名>:8443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=<域名>&fp=chrome&type=ws&host=<域名>&path=%2F#<域名>
```

服务启动后自动打印完整节点链接。

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
- 无连接数限制/流量统计
