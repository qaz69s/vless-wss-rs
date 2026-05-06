#!/bin/bash
# vless-wss-rs — 交互式一键安装
set -euo pipefail

# ────────────────────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────────────────────
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local h; h=$(openssl rand -hex 16)
        printf '%s-%s-%s-%s-%s\n' \
            "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
    fi
}

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
    trap "rm -rf $TMP" RETURN
    if curl -sLf \
        "https://github.com/$REPO/releases/latest/download/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TMP/vless.tar.gz" 2>/dev/null; then
        tar xzf "$TMP/vless.tar.gz" -C "$TMP"
        chmod +x "$TMP/vless-wss-rs"
        mv "$TMP/vless-wss-rs" /usr/local/bin/
        echo "[+] 已从 Release 安装"
    else
        echo "[*] 未找到 Release，从源码编译..."
        command -v cargo &>/dev/null || {
            echo "[-] 未安装 cargo，请先运行："
            echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            exit 1
        }
        local BUILD; BUILD=$(mktemp -d)
        git clone "https://github.com/$REPO.git" --depth=1 "$BUILD/repo"
        cargo build --release --manifest-path "$BUILD/repo/Cargo.toml"
        mv "$BUILD/repo/target/release/vless-wss-rs" /usr/local/bin/
        rm -rf "$BUILD"
        echo "[+] 编译完成"
    fi
}

# ────────────────────────────────────────────────────────────
# 关键修复：curl | bash 时 stdin 是管道而非终端
# 重定向 stdin 到 /dev/tty，让 read 能读到键盘输入
# ────────────────────────────────────────────────────────────
exec </dev/tty

# ────────────────────────────────────────────────────────────
# 交互式输入
# ────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "        vless-wss-rs 一键安装配置向导"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "请选择模式："
echo "  1) 自动模式 — 随机子域名 + Cloudflare DNS + 自动申请证书"
echo "  2) 手动模式 — 使用已有证书文件"
echo ""
read -rp "输入选项 [1/2，默认 1]: " MODE_INPUT
MODE=${MODE_INPUT:-1}

echo ""

if [[ "$MODE" == "2" ]]; then
    # ── 手动证书模式 ─────────────────────────────────────────
    read -rp "证书路径 (fullchain.pem): " CERT
    read -rp "私钥路径 (privkey.pem):   " KEY
    [[ -f "$CERT" ]] || { echo "[-] 证书文件不存在"; exit 1; }
    [[ -f "$KEY"  ]] || { echo "[-] 私钥文件不存在"; exit 1; }

    read -rp "UUID [留空随机生成]: " UUID
    [[ -z "$UUID" ]] && UUID=$(gen_uuid) && echo "[*] 随机 UUID: $UUID"

    read -rp "监听地址 [默认 0.0.0.0:443]: " LISTEN
    LISTEN=${LISTEN:-0.0.0.0:443}

else
    # ── 自动模式 ─────────────────────────────────────────────
    read -rp "Cloudflare API Token (Zone:Read + DNS:Edit): " CF_TOKEN
    [[ -z "$CF_TOKEN" ]] && { echo "[-] Token 不能为空"; exit 1; }

    read -rp "根域名 (例: example.com): " BASE_DOMAIN
    [[ -z "$BASE_DOMAIN" ]] && { echo "[-] 域名不能为空"; exit 1; }

    read -rp "UUID [留空随机生成]: " UUID
    [[ -z "$UUID" ]] && UUID=$(gen_uuid) && echo "[*] 随机 UUID: $UUID"

    read -rp "监听地址 [默认 0.0.0.0:443]: " LISTEN
    LISTEN=${LISTEN:-0.0.0.0:443}

    EMAIL=$(gen_email)
    echo "[*] 注册邮箱: $EMAIL（随机生成，仅用于 Let's Encrypt）"

    echo ""

    install_binary

    SUB=$(openssl rand -hex 3)
    FQDN="${SUB}.${BASE_DOMAIN}"
    echo "[*] 随机子域名: $FQDN"

    SERVER_IP=$(get_public_ip)
    echo "[*] 本机公网 IP: $SERVER_IP"

    echo "[*] 查询 Cloudflare Zone ID..."
    ZONE_ID=$(cf_zone_id "$BASE_DOMAIN" "$CF_TOKEN") || {
        echo "[-] 未找到 ${BASE_DOMAIN} 对应的 Zone，请检查 Token 权限和域名"
        exit 1
    }
    echo "[+] Zone ID: $ZONE_ID"

    RECORD_ID=$(cf_create_a_record "$ZONE_ID" "$FQDN" "$SERVER_IP" "$CF_TOKEN")
    echo "[+] DNS A 记录已创建: $FQDN → $SERVER_IP (id=$RECORD_ID)"

    install_acme "$EMAIL"
    ACME=~/.acme.sh/acme.sh
    "$ACME" --set-default-ca --server letsencrypt 2>/dev/null || true
    echo "[*] 申请 TLS 证书（DNS-01）..."
    CF_Token="$CF_TOKEN" \
        "$ACME" --issue --dns dns_cf -d "$FQDN" --keylength ec-256 --server letsencrypt

    CERT_DIR=~/.acme.sh/${FQDN}_ecc
    [[ -f "${CERT_DIR}/fullchain.cer" ]] || { echo "[-] 证书申请失败"; exit 1; }
    CERT="${CERT_DIR}/fullchain.cer"
    KEY="${CERT_DIR}/${FQDN}.key"

    echo ""
    echo "┌──────────────────────────────────────────────────┐"
    echo "│  域名: $FQDN"
    echo "│  证书: $CERT"
    echo "│  私钥: $KEY"
    echo "└──────────────────────────────────────────────────┘"
fi

echo ""
echo "[*] 启动 vless-wss-rs..."
echo "    监听: $LISTEN"
echo "    UUID: $UUID"
echo ""

install_binary

exec /usr/local/bin/vless-wss-rs \
    --cert   "$CERT"   \
    --key    "$KEY"    \
    --uuid   "$UUID"   \
    --listen "$LISTEN"
