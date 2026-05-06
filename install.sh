#!/bin/bash
# vless-wss-rs 综合管理工具箱 (Standalone 独立证书模式)
# 包含：一键安装、日志查看、服务重启、彻底卸载

set -euo pipefail

# --- 颜色与提示 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 强制允许远程一键运行时的终端输入
exec </dev/tty

# ────────────────────────────────────────────────────────────
# 核心工具函数 (静默依赖)
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
    [[ -n "$ip" ]] || { echo -e "${RED}[-] 无法获取公网 IP${PLAIN}" >&2; exit 1; }
    echo "$ip"
}

install_acme() {
    local email="$1"
    [[ -f ~/.acme.sh/acme.sh ]] && return
    echo -e "${GREEN}[*] 安装 acme.sh...${PLAIN}"
    curl -sf https://get.acme.sh | sh -s "email=${email}"
    [[ -f ~/.acme.sh/acme.sh.env ]] && source ~/.acme.sh/acme.sh.env || true
}

install_binary() {
    echo -e "${GREEN}[*] 正在下载 vless-wss-rs...${PLAIN}"
    local REPO="qaz69s/vless-wss-rs"
    local TMP; TMP=$(mktemp -d)
    trap "rm -rf $TMP" RETURN
    if curl -sLf \
        "https://github.com/$REPO/releases/latest/download/vless-wss-rs-x86_64-unknown-linux-musl.tar.gz" \
        -o "$TMP/vless.tar.gz" 2>/dev/null; then
        tar xzf "$TMP/vless.tar.gz" -C "$TMP"
        chmod +x "$TMP/vless-wss-rs"
        mv "$TMP/vless-wss-rs" /usr/local/bin/
        echo -e "${GREEN}[+] 主程序已安装${PLAIN}"
    else
        echo -e "${RED}[-] 下载 Release 失败，请检查网络。${PLAIN}"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────
# 菜单功能模块
# ────────────────────────────────────────────────────────────

# 1. 安装模块
function do_install() {
    clear
    echo -e "${CYAN}================================================================${PLAIN}"
    echo -e "${CYAN}                开始安装 vless-wss-rs (独立证书版)              ${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"
    echo -e "${YELLOW}警告: 运行前请确保您的域名已经正确解析到本机的公网 IP！${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}\n"
    
    if [ -f "/etc/systemd/system/vless-wss-rs.service" ]; then
        echo -e "${YELLOW}[!] 检测到系统已安装 vless-wss-rs，继续安装将覆盖原配置。${PLAIN}"
    fi

    read -rp "1. 请输入已解析到本机的完整域名 (例如: vless.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}[-] 域名不能为空${PLAIN}"; return; }

    read -rp "2. 请输入 UUID [留空随机生成]: " UUID
    [[ -z "$UUID" ]] && UUID=$(gen_uuid) && echo -e "   ${YELLOW}[*] 已自动生成随机 UUID: $UUID${PLAIN}"

    read -rp "3. 请输入监听地址与端口 [默认 0.0.0.0:443]: " LISTEN
    LISTEN=${LISTEN:-0.0.0.0:443}
    PORT=$(echo "$LISTEN" | awk -F':' '{print $NF}')

    echo -e "\n${GREEN}================ 开始自动化部署 ==================${PLAIN}"

    EMAIL=$(gen_email)
    
    # 检查并安装独立模式所需依赖 (socat, lsof)
    echo -e "${GREEN}[*] 检查环境依赖...${PLAIN}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y socat lsof psmisc >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y socat lsof psmisc >/dev/null 2>&1 || true
    fi

    install_binary

    SERVER_IP=$(get_public_ip)
    echo -e "${GREEN}[*] 本机公网 IP: ${YELLOW}$SERVER_IP${PLAIN}"
    echo -e "${GREEN}[*] 您绑定的域名: ${YELLOW}$DOMAIN${PLAIN}"

    # 确保证书申请时 80 端口未被占用
    if lsof -i :80 > /dev/null 2>&1; then
        echo -e "${YELLOW}[!] 检测到 80 端口被占用，尝试临时解除占用以便申请证书...${PLAIN}"
        fuser -k 80/tcp || true
        sleep 2
    fi

    install_acme "$EMAIL"
    ACME=~/.acme.sh/acme.sh
    "$ACME" --set-default-ca --server letsencrypt 2>/dev/null || true
    echo -e "${GREEN}[*] 申请 TLS 证书（Standalone 模式）...${PLAIN}"
    
    if ! "$ACME" --issue -d "$DOMAIN" --standalone --keylength ec-256; then
        echo -e "${RED}[-] 证书申请失败！请检查域名是否已解析到 $SERVER_IP，且防火墙已放行 80 端口。${PLAIN}"
        return
    fi

    CERT_BASE_DIR="/etc/vless-wss-rs"
    mkdir -p "$CERT_BASE_DIR"
    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_BASE_DIR/cert.cer" \
        --key-file "$CERT_BASE_DIR/private.key"

    echo -e "${GREEN}[*] 配置 Systemd 后台服务...${PLAIN}"
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

    VLESS_LINK="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&type=ws&sni=${DOMAIN}#vless-wss-rs"

    echo -e "\n${CYAN}================================================================${PLAIN}"
    echo -e "${GREEN} 恭喜！vless-wss-rs 安装成功并已在后台稳定运行！${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"
    echo -e " 地址 (Address): ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e " 端口 (Port)   : ${YELLOW}${PORT}${PLAIN}"
    echo -e " 用户 (UUID)   : ${YELLOW}${UUID}${PLAIN}"
    echo -e " 伪装域名 (SNI): ${YELLOW}${DOMAIN}${PLAIN}"
    echo -e "${CYAN}================================================================${PLAIN}"
    echo -e " ${YELLOW}👇 一键导入链接 (复制以下全段内容):${PLAIN}"
    echo -e "\n${VLESS_LINK}\n"
    echo -e "${CYAN}================================================================${PLAIN}"
}

# 2. 查看日志模块
function do_view_logs() {
    clear
    if ! systemctl is-active --quiet vless-wss-rs; then
        echo -e "${YELLOW}服务未运行或未安装，无法查看日志。${PLAIN}"
    else
        echo -e "${CYAN}正在显示最新的 50 条日志 (按 q 退出日志视图):${PLAIN}"
        echo -e "----------------------------------------------------"
        journalctl -u vless-wss-rs -n 50 --no-pager
        echo -e "----------------------------------------------------"
    fi
}

# 3. 重启核心模块
function do_restart() {
    clear
    if [ -f "/etc/systemd/system/vless-wss-rs.service" ]; then
        echo -e "${GREEN}[*] 正在重启 vless-wss-rs 服务...${PLAIN}"
        systemctl restart vless-wss-rs
        if systemctl is-active --quiet vless-wss-rs; then
            echo -e "${GREEN}[+] 重启成功！服务正在运行。${PLAIN}"
        else
            echo -e "${RED}[-] 重启失败，请使用菜单中的“查看运行日志”排查报错。${PLAIN}"
        fi
    else
        echo -e "${YELLOW}[!] 未检测到 vless-wss-rs 服务，请先安装。${PLAIN}"
    fi
}

# 4. 彻底卸载模块
function do_uninstall() {
    clear
    echo -e "${RED}================================================================${PLAIN}"
    echo -e "${RED}  警告：此操作将彻底删除 vless-wss-rs 的所有文件、配置和证书。${PLAIN}"
    echo -e "${RED}================================================================${PLAIN}"
    read -rp "您确定要继续卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}[*] 正在停止并禁用服务...${PLAIN}"
        systemctl stop vless-wss-rs &>/dev/null || true
        systemctl disable vless-wss-rs &>/dev/null || true
        
        echo -e "${YELLOW}[*] 正在删除程序文件与配置...${PLAIN}"
        rm -f /etc/systemd/system/vless-wss-rs.service
        rm -f /usr/local/bin/vless-wss-rs
        rm -rf /etc/vless-wss-rs
        systemctl daemon-reload
        
        echo -e "${GREEN}[+] 清理完成！vless-wss-rs 已彻底卸载。${PLAIN}"
    else
        echo -e "${GREEN}[*] 已取消卸载操作。${PLAIN}"
    fi
}

# ────────────────────────────────────────────────────────────
# 主程序入口 (无限循环菜单)
# ────────────────────────────────────────────────────────────
while true; do
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${CYAN}         vless-wss-rs 综合管理工具箱 v1.0         ${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 安装 vless-wss-rs (独立证书全自动部署)"
    echo -e " ${GREEN}2.${PLAIN} 查看运行日志 (排查连接问题)"
    echo -e " ${GREEN}3.${PLAIN} 重启核心服务"
    echo -e " ${GREEN}4.${PLAIN} 彻底卸载程序"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    
    read -rp "请输入选项数字 [0-4]: " num
    case "$num" in
        1) do_install
           ;;
        2) do_view_logs
           ;;
        3) do_restart
           ;;
        4) do_uninstall
           ;;
        0) echo -e "${GREEN}[*] 感谢使用，已退出！${PLAIN}"; exit 0
           ;;
        *) echo -e "${RED}[-] 输入有误，请输入 0-4 之间的数字。${PLAIN}"
           ;;
    esac
    
    # 执行完任意非退出操作后，暂停一下，等待用户按回车继续
    echo ""
    read -rp "按下 回车键 (Enter) 返回主菜单..."
    clear
done
