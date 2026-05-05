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
    echo "[-] Download failed. Try building from source:"
    echo "    git clone https://github.com/$REPO.git ~/vless-wss-rs"
    echo "    cd ~/vless-wss-rs && cargo build --release"
    exit 1
fi

echo ""
echo "=== VLESS WSS Server Setup ==="
echo ""

read -p "Cloudflare API Token: " CF_TOKEN

# Step 1: Auto-detect domain from CF token
echo "[*] Fetching domains from Cloudflare..."
DOMAINS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" | \
    python3 -c "import sys,json; data=json.load(sys.stdin); [print(z['name']) for z in data.get('result',[])]" 2>/dev/null)

if [ -z "$DOMAINS" ]; then
    echo "[-] Failed to fetch domains. Ensure CF Token has Zone.Read permission."
    exit 1
fi

DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)
if [ "$DOMAIN_COUNT" -eq 1 ]; then
    DOMAIN="$DOMAINS"
    echo "[+] Auto-detected domain: $DOMAIN"
else
    echo "[*] Available domains:"
    echo "$DOMAINS"
    echo ""
    read -p "Select domain: " DOMAIN
fi

# Step 2: Auto-detect server public IP
echo "[*] Detecting server public IP..."
SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null)
if [ -z "$SERVER_IP" ]; then
    read -p "Could not detect IP, please enter manually: " SERVER_IP
else
    echo "[+] Server IP: $SERVER_IP"
fi

# Step 3: Auto-add DNS A record
echo "[*] Adding DNS A record $DOMAIN -> $SERVER_IP ..."

ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" | \
    python3 -c "import sys,json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)

if [ -z "$ZONE_ID" ]; then
    echo "[-] Could not find zone ID for $DOMAIN"
    exit 1
fi

RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" | \
    python3 -c "import sys,json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)

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
echo "[*] Waiting for DNS propagation (10s)..."
sleep 10

# Step 5: Issue Let's Encrypt certificate via HTTP-01 (port 80)
echo "[*] Installing acme.sh..."
if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=letsencrypt@$DOMAIN
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[*] Issuing Let's Encrypt certificate (HTTP-01 on port 80)..."
~/.acme.sh/acme.sh --issue --standalone --httpport 80 -d "$DOMAIN" --keylength 2048 --server letsencrypt

CERT_DIR="/root/.acme.sh/$DOMAIN"
if [ ! -f "$CERT_DIR/fullchain.cer" ]; then
    echo "[-] Certificate issue failed. Check port 80 is free."
    exit 1
fi
echo "[+] Certificate issued: $CERT_DIR/fullchain.cer"

# Step 6: Generate UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "[+] Generated UUID: $UUID"

# Step 7: Start vless-wss-rs
echo ""
echo "[*] Starting vless-wss-rs..."
exec vless-wss-rs \
    --cert "$CERT_DIR/fullchain.cer" \
    --key "$CERT_DIR/$DOMAIN"_key.pem \
    --uuid "$UUID" \
    --domain "$DOMAIN"
