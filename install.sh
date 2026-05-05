#!/bin/bash

echo ""
echo "=== VLESS WSS 一键部署 ==="
echo ""

read -p "请输入 Cloudflare API Token: " CF_TOKEN

REPO="qaz69s/vless-wss-rs"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo ""
echo "[*] 下载 vless-wss-rs..."
curl -sL --max-time 60 "https://github.com/$REPO/releases/download/v1.0.0/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" -o vless.tar.gz

if [ ! -f vless.tar.gz ] || [ ! -s vless.tar.gz ]; then
    echo "[-] 下载失败，请检查网络"
    exit 1
fi

tar xzf vless.tar.gz
chmod +x vless-wss-rs
mv vless-wss-rs /usr/local/bin/
rm -rf "$TMPDIR"
echo "[+] 已安装到 /usr/local/bin/vless-wss-rs"

echo ""
echo "[*] 从 Cloudflare 获取域名列表..."

RESP=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

if echo "$RESP" | grep -q '"success":false'; then
    MSG=$(echo "$RESP" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    echo "[-] Cloudflare API 错误: $MSG"
    echo "    请确认 Token 有 Zone.Read 权限"
    exit 1
fi

if ! echo "$RESP" | grep -q '"name":"'; then
    echo "[-] 未找到域名，请确认 Token 正确"
    exit 1
fi

# 提取所有域名
DOMAINS=$(echo "$RESP" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//')
DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)

if [ "$DOMAIN_COUNT" -eq 0 ]; then
    echo "[-] Cloudflare 账号下没有域名"
    exit 1
fi

if [ "$DOMAIN_COUNT" -eq 1 ]; then
    DOMAIN=$(echo "$DOMAINS")
    echo "[+] 检测到域名: $DOMAIN"
else
    echo ""
    echo "[*] 检测到多个域名，请选择:"
    n=0
    for d in $DOMAINS; do
        echo "    [$n] $d"
        n=$((n+1))
    done
    echo ""
    read -p "请输入序号 [0]: " IDX
    IDX=${IDX:-0}
    DOMAIN=$(echo "$DOMAINS" | sed -n "$((IDX+1))p")
fi

# 获取 zone_id
ZONE_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')

# 检测公网 IP
echo ""
echo "[*] 检测服务器公网 IP..."
SERVER_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null)
fi
if [ -z "$SERVER_IP" ]; then
    read -p "无法检测 IP，请手动输入: " SERVER_IP
else
    echo "[+] 服务器 IP: $SERVER_IP"
fi

# 录入 DNS A 记录
echo ""
echo "[*] 自动添加 DNS A 记录..."

RECORD_RESP=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

RECORD_ID=$(echo "$RECORD_RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')

if [ -n "$RECORD_ID" ]; then
    curl -s --max-time 15 -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null 2>&1
    echo "[+] 已更新现有 A 记录: $DOMAIN -> $SERVER_IP"
else
    curl -s --max-time 15 -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null 2>&1
    echo "[+] 已创建 A 记录: $DOMAIN -> $SERVER_IP"
fi

# 等待 DNS 生效
echo ""
echo "[*] 等待 DNS 生效 (15秒)..."
sleep 15

# 申请证书
echo ""
echo "[*] 安装 acme.sh..."
if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=letsencrypt@"$DOMAIN" 2>&1 | tail -3
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>&1 | tail -1

echo ""
echo "[*] 申请 Let's Encrypt 证书 (HTTP-01 端口 80)..."
~/.acme.sh/acme.sh --issue --standalone --httpport 80 -d "$DOMAIN" --keylength 2048 --server letsencrypt 2>&1

CERT_DIR="/root/.acme.sh/$DOMAIN"
KEY_FILE=$(ls "$CERT_DIR"/*.key 2>/dev/null | head -1)
FULLCHAIN="$CERT_DIR/fullchain.cer"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$KEY_FILE" ]; then
    echo ""
    echo "[-] 证书申请失败！"
    echo "    请确认:"
    echo "    1. 端口 80 未被占用 (nginx/apache 等)"
    echo "    2. DNS 已生效 (nslookup $DOMAIN 应返回 $SERVER_IP)"
    exit 1
fi
echo "[+] 证书申请成功: $FULLCHAIN"

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "[+] UUID: $UUID"

# 保存配置
mkdir -p /etc/vless-wss-rs
cat > /etc/vless-wss-rs/config.json << EOF
{
  "uuid": "$UUID",
  "domain": "$DOMAIN"
}
EOF

# 启动服务
echo ""
echo "[*] 启动 vless-wss-rs..."
echo ""
exec vless-wss-rs \
    --cert "$FULLCHAIN" \
    --key "$KEY_FILE" \
    --domain "$DOMAIN" \
    --uuid "$UUID"
