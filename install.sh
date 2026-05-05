#!/bin/bash
set -e

REPO="qaz69s/vless-wss-rs"
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[*] Downloading vless-wss-rs..."
curl -sL "https://github.com/$REPO/releases/download/v1.0.0/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" -o vless.tar.gz

if [ -f vless.tar.gz ] && [ -s vless.tar.gz ]; then
    tar xzf vless.tar.gz
    chmod +x vless-wss-rs
    mv vless-wss-rs /usr/local/bin/
    rm -rf "$TMPDIR"
    echo "[+] Installed to /usr/local/bin/vless-wss-rs"
else
    echo "[-] Download failed."
    exit 1
fi

echo ""
echo "=== VLESS WSS Server Setup ==="
echo ""

read -p "Cloudflare API Token: " CF_TOKEN

# Step 1: Auto-detect domain from CF token (pure bash, no jq/python)
echo "[*] Fetching domains from Cloudflare..."
RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

# Check if response indicates success
SUCCESS=$(echo "$RESP" | grep -o '"success":true' | head -1)
if [ -z "$SUCCESS" ]; then
    echo "[-] Cloudflare API error. Check your CF Token."
    echo "$RESP"
    exit 1
fi

# Extract first domain name using grep/sed (pure bash)
DOMAIN=$(echo "$RESP" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"$//')
if [ -z "$DOMAIN" ]; then
    echo "[-] No domains found in CF account."
    exit 1
fi

# If multiple domains, let user choose
DOMAIN_COUNT=$(echo "$RESP" | grep -oc '"name":"[^"]*"')
if [ "$DOMAIN_COUNT" -gt 1 ]; then
    echo "[*] Available domains:"
    echo "$RESP" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//' | nl -v 0
    echo ""
    read -p "Select domain index: " IDX
    DOMAIN=$(echo "$RESP" | grep -o '"name":"[^"]*"' | sed -n "$((IDX+1))p" | sed 's/"name":"//;s/"$//')
fi

echo "[+] Using domain: $DOMAIN"

# Step 2: Auto-detect server public IP
echo "[*] Detecting server public IP..."
SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    read -p "Could not detect IP, please enter manually: " SERVER_IP
else
    echo "[+] Server IP: $SERVER_IP"
fi

# Step 3: Auto-add DNS A record via CF API
echo "[*] Adding DNS A record $DOMAIN -> $SERVER_IP ..."

ZONE_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')
if [ -z "$ZONE_ID" ]; then
    echo "[-] Could not find zone ID."
    exit 1
fi

# Check if A record already exists
RECORD_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

RECORD_ID=$(echo "$RECORD_RESP" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"$//')

if [ -n "$RECORD_ID" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null
    echo "[+] Updated existing A record"
else
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"proxied\":false}" > /dev/null
    echo "[+] Created A record"
fi

# Step 4: Wait for DNS propagation
echo "[*] Waiting for DNS propagation (15s)..."
sleep 15

# Step 5: Issue Let's Encrypt certificate via HTTP-01 (port 80)
echo "[*] Installing acme.sh..."
if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=letsencrypt@"$DOMAIN"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[*] Issuing Let's Encrypt certificate (HTTP-01 on port 80)..."
~/.acme.sh/acme.sh --issue --standalone --httpport 80 -d "$DOMAIN" --keylength 2048 --server letsencrypt

CERT_DIR="/root/.acme.sh/$DOMAIN"
KEY_FILE=$(echo "$CERT_DIR"/*.key 2>/dev/null | head -1)
FULLCHAIN="$CERT_DIR/fullchain.cer"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$KEY_FILE" ]; then
    echo "[-] Certificate issue failed. Check that port 80 is free and DNS has propagated."
    exit 1
fi
echo "[+] Certificate issued: $FULLCHAIN"

# Step 6: Generate UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "[+] Generated UUID: $UUID"

# Step 7: Save config and start
mkdir -p /etc/vless-wss-rs
cat > /etc/vless-wss-rs/config.json << EOF
{
  "uuid": "$UUID",
  "domain": "$DOMAIN"
}
EOF

echo ""
echo "[*] Starting vless-wss-rs..."
exec vless-wss-rs \
    --cert "$FULLCHAIN" \
    --key "$KEY_FILE" \
    --domain "$DOMAIN" \
    --uuid "$UUID"
