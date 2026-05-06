#!/bin/bash
# vless-wss-rs — 纯静默一键安装版 (完整后台服务与输出版)
set -euo pipefail

# --- 颜色与提示 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ────────────────────────────────────────────────────────────
# 参数校验
# ────────────────────────────────────────────────────────────
if [[ -z "${CF_TOKEN:-}" ]] || [[ -z "${BASE_DOMAIN:-}" ]]; then
    echo "[-] 错误: 必须提供 CF_TOKEN 和 BASE_DOMAIN 环境变量！"
    echo "用法示例:"
    echo "CF_TOKEN=\"你的Token\" BASE_DOMAIN=\"example.com\" bash auto-install.sh"
    exit 1
fi

MODE=${MODE:-1}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
LISTEN=${LISTEN:-"0.0.0.0:443"}
# 提取端口号用于生成分享链接
PORT=$(echo "$LISTEN" | awk -F':' '{print $NF}')

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────
gen_email() {
    local user; user=$(openssl rand -hex 5)
    echo "${user}@$(openssl rand -hex 4).net"
}

get_public_ip() {
    local ip
    ip=$(curl -sf --max-time 5 https://api.ipify.org \
      || curl -sf --max-time 5 https://ifconfig.me \
      || curl -sf --max-time 5 https://icanhazip.com) || true
    [[ -n "$ip" ]] || { echo "[-] 无法获取公网 IP" >&2; exit 1; }
    echo "$ip"
}

cf_zone_id() {
    local domain="$1" token="$2"
    local IFS='.'; read -ra parts <<< "$domain"
    local n=${#parts[@]}
    for ((i=0; i<n-1; i++)); do
        local candidate="${parts[*]:$i}"
        local zone_id
        zone_id=$(curl -sf \
            "https://api.cloudflare.com/client/v4/zones?name=${candidate}&status=active" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        [[ -n "$zone_id" ]] && { echo "$zone_id"; return 0; }
    done
    return 1
}

cf_create_a_record() {
    local zone_id="$1" fqdn="$2" ip="$3" token="$4"
    local resp
    resp=$(curl -sf -X POST \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false}")
    echo "$resp" | grep -q '"success":true' \
        || { echo "[-] CF 建 DNS 记录失败: $resp" >&2; exit 1; }
    echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

install_acme() {
    local email="$1"
    [[ -f ~/.acme.sh/acme.sh ]] && return
    echo "[*] 安装 acme.sh..."
    curl -sf https://get.acme.sh | sh -s "email=${email}"
    [[ -f ~/.acme.sh/acme.sh.env ]] && source ~/.acme.sh/acme.sh.env || true
}

install_binary() {
    if command -v vless-wss-rs &>/dev/null; then
        echo "[+] vless-wss-rs 已安装，跳过下载"; return
    fi
    echo "[*] 正在下载 vless-wss-rs..."
    local REPO="qaz69s/vless-wss-rs"
    local TMP; TMP=$(mktemp -d)
    if curl -sLf \
        "https://github.com/$REPO/releases/latest/download/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TMP/vless.tar.gz" 2>/dev/null; then
        tar xzf "$TMP/vless.tar.gz" -C "$TMP"
        chmod +x "$TMP/vless-wss-rs"
        mv "$TMP/vless-wss-rs" /usr/local/bin/
        echo "[+] 已从 Release 安装"
    else
        echo "[-] 下载 Release 失败，请检查网络。"
        exit 1
    fi
    rm -rf "$TMP"
}

# ────────────────────────────────────────────────────────────
# 核心执行逻辑
# ────────────────────────────────────────────────────────────
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
echo -e "${GREEN}  vless-wss-rs 纯静默一键安装 (Cloudflare DNS 版)${PLAIN}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"

EMAIL=$(gen_email)
install_binary

SUB=$(openssl rand -hex 3)
FQDN="${SUB}.${BASE_DOMAIN}"
echo -e "[*] 随机 UUID: ${YELLOW}$UUID${PLAIN}"
echo -e "[*] 随机子域名: ${YELLOW}$FQDN${PLAIN}"

SERVER_IP=$(get_public_ip)
echo -e "[*] 本机公网 IP: ${YELLOW}$SERVER_IP${PLAIN}"

echo "[*] 查询 Cloudflare Zone ID..."
ZONE_ID=$(cf_zone_id "$BASE_DOMAIN" "$CF_TOKEN") || {
    echo "[-] 未找到 ${BASE_DOMAIN} 对应的 Zone，请检查 Token 权限和域名"
    exit 1
}

RECORD_ID=$(cf_create_a_record "$ZONE_ID" "$FQDN" "$SERVER_IP" "$CF_TOKEN")
echo -e "[+] DNS A 记录已创建: ${YELLOW}$FQDN → $SERVER_IP${PLAIN}"

install_acme "$EMAIL"
ACME=~/.acme.sh/acme.sh
"$ACME" --set-default-ca --server letsencrypt 2>/dev/null || true
echo "[*] 申请 TLS 证书（DNS-01）..."
export CF_Token="$CF_TOKEN"
"$ACME" --issue --dns dns_cf -d "$FQDN" --keylength ec-256 --server letsencrypt

# 规范化证书路径
CERT_BASE_DIR="/etc/vless-wss-rs"
mkdir -p "$CERT_BASE_DIR"
"$ACME" --install-cert -d "$FQDN" --ecc \
    --fullchain-file "$CERT_BASE_DIR/cert.cer" \
    --key-file "$CERT_BASE_DIR/private.key"

echo -e "[+] 证书已安装至: ${YELLOW}$CERT_BASE_DIR${PLAIN}"

# 配置 Systemd 守护进程
echo "[*] 配置 Systemd 后台服务..."
cat > /etc/systemd/system/vless-wss-rs.service <<EOF
[Unit]
Description=vless-wss-rs Lightweight VLESS WebSocket Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/vless-wss-rs --cert $CERT_BASE_DIR/cert.cer --key $CERT_BASE_DIR/private.key --uuid $UUID --listen $LISTEN
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vless-wss-rs
systemctl restart vless-wss-rs

# 生成 VLESS 导入链接并输出节点信息
VLESS_LINK="vless://${UUID}@${FQDN}:${PORT}?encryption=none&security=tls&type=ws&sni=${FQDN}#vless-wss-rs"

echo ""
echo -e "${GREEN}================================================================${PLAIN}"
echo -e "${GREEN} 恭喜！vless-wss-rs 安装成功并已在后台稳定运行！${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 地址 (Address): ${YELLOW}${FQDN}${PLAIN}"
echo -e " 端口 (Port)   : ${YELLOW}${PORT}${PLAIN}"
echo -e " 用户 (UUID)   : ${YELLOW}${UUID}${PLAIN}"
echo -e " 传输协议 (Net): ${YELLOW}ws${PLAIN}"
echo -e " 伪装域名 (SNI): ${YELLOW}${FQDN}${PLAIN}"
echo -e " 底层传输安全  : ${YELLOW}tls${PLAIN}"
echo -e " 证书存放目录  : ${YELLOW}${CERT_BASE_DIR}${PLAIN}"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " ${YELLOW}👇 一键导入链接 (复制以下全段内容至客户端):${PLAIN}"
echo -e "\n${VLESS_LINK}\n"
echo -e "${GREEN}================================================================${PLAIN}"
echo -e " 日志查看命令: journalctl -u vless-wss-rs -f"
echo -e " 服务重启命令: systemctl restart vless-wss-rs"