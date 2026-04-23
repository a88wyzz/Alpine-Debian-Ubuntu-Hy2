#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.json"
PORT_FILE="$WORKDIR/port.txt"
PASS_FILE="$WORKDIR/password.txt"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"
    exit 1
fi

# 重启服务
restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria restart
    else
        systemctl restart hysteria
    fi
}

# 获取并显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"
        return
    fi

    # 使用 jq 精确解析 JSON
    PORT=$(jq -r '.listen' "$CONF" | sed 's/://g')
    PASSWORD=$(jq -r '.auth.password' "$CONF")

    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== Hysteria2 配置信息 ==========${NC}"
    echo -e "📌 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "📌 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🔐 认证密码: ${YELLOW}$PASSWORD${NC}"
    
    [[ -n "$IP4" ]] && echo -e "\n${GREEN}📎 节点链接 (IPv4):${NC}\n${YELLOW}hy2://$PASSWORD@$IP4:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V4${NC}"
    [[ -n "$IP6" ]] && echo -e "\n${GREEN}📎 节点链接 (IPv6):${NC}\n${YELLOW}hy2://$PASSWORD@[$IP6]:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V6${NC}"
    
    if [[ -z "$IP4" && -z "$IP6" ]]; then
        echo -e "${RED}❌ 无法检测到公网 IP${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    OLD_PORT=$(jq -r '.listen' "$CONF" | sed 's/://g')
    echo -e "当前端口为: ${YELLOW}$OLD_PORT${NC}"
    read -p "请输入新端口 (回车10000-65535随机): " NEW_PORT
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 使用 jq 修改并回写
    jq --arg p ":$NEW_PORT" '.listen = $p' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/udp
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装
install_hy2() {
    echo -e "${YELLOW}▶ 正在安装依赖 ...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl ca-certificates bash jq
    else
        apt update && apt install -y curl openssl ca-certificates bash jq
    fi
    
    mkdir -p "$WORKDIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64) FILE="hysteria-linux-arm64" ;;
        *) echo "❌ 不支持的架构"; exit 1 ;;
    esac

    echo -e "${YELLOW}▶ 下载 Hysteria2...${NC}"
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"
    chmod +x "$BIN"

    PASSWORD=$(openssl rand -hex 4)
    PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    echo "$PASSWORD" > "$PASS_FILE"
    echo "$PORT" > "$PORT_FILE"

    echo -e "${YELLOW}▶ 生成自签证书...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$SERVER_NAME" 2>/dev/null

    # 使用 jq 构建初始 JSON 配置
    jq -n \
        --arg port ":$PORT" \
        --arg cert "$WORKDIR/cert.pem" \
        --arg key "$WORKDIR/key.pem" \
        --arg pass "$PASSWORD" \
        --arg sni "$SERVER_NAME" \
        '{
            "listen": $port,
            "tls": {
                "cert": $cert,
                "key": $key,
                "alpn": ["h3"]
            },
            "auth": {
                "type": "password",
                "password": $pass
            },
            "masquerade": {
                "type": "proxy",
                "proxy": {
                    "url": ("https://" + $sni),
                    "rewriteHost": true
                }
            }
        }' > "$CONF"

    # 服务部署
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/hysteria.pid"
supervisor="supervise-daemon"
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default
    else
        cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target
[Service]
ExecStart=$BIN server -c $CONF
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria
    fi
    
    restart_service
    echo -e "${GREEN}✅ Hysteria2 安装完成 ${NC}"
    show_info
}

# 卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria stop || true
        rc-update del hysteria || true
        rm -f /etc/init.d/hysteria
    else
        systemctl stop hysteria || true
        systemctl disable hysteria || true
        rm -f /etc/systemd/system/hysteria.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f "$BIN"
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

while true; do
# 状态检测逻辑
if [ "$OS" = "alpine" ]; then
    if rc-service hysteria status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
else
    if systemctl is-active --quiet hysteria 2>/dev/null; then
        STATUS="${GREEN}正在运行${NC}"
    else
        STATUS="${RED}未安装或未运行${NC}"
    fi
fi

# 菜单
clear
echo -e "${GREEN}===============================================${NC}"
echo -e "  Hysteria2 一键管理脚本"
echo -e "  当前系统: $OS"
echo -e "  Hy2状态： $STATUS"
echo -e "${GREEN}===============================================${NC}"
echo -e "  ${CYAN}[1]${NC}  安装 Hysteria2"
echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
echo -e "  ${CYAN}[3]${NC}  更改监听端口"
echo -e "  ${CYAN}[4]${NC}  重启服务"
echo -e "  ${CYAN}[5]${NC}  卸载 Hysteria2"
echo -e "  ${CYAN}[0]${NC}  退出脚本"
echo -e "${GREEN}===============================================${NC}"
echo -ne "请输入数字选择 [0-5]: "
read choice

case $choice in
        1)
            install_hy2
            ;;
        2)
            show_info
            ;;
        3)
            change_port
            ;;
        4)
            restart_service && echo -e "${GREEN}服务已重启${NC}"
            ;;
        5)
            uninstall_hy2
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，请重新选择${NC}"
            sleep 1
            ;;
    esac

    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
    clear
done
