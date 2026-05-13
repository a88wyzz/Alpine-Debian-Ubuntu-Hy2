#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
YQ_BIN="/usr/local/bin/yq"
CONF="$WORKDIR/config.yaml"
PORT_FILE="$WORKDIR/port.txt"
PASS_FILE="$WORKDIR/password.txt"
REALM_FILE="$WORKDIR/realm.txt"
CLIENT_CONF="$WORKDIR/client.yaml"
### =====================

### ===== Realms 配置 =====
REALM_SERVER="public@realm.hy2.io"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

# Root 检查
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
        rc-service hysteria restart || true
    else
        systemctl restart hysteria || true
    fi
}

get_mode() {
    [ -f "$REALM_FILE" ] && echo "realms" || echo "public"
}

# 生成客户端配置（按你提供的格式）
generate_client_config() {
    if [ ! -f "$REALM_FILE" ]; then return; fi
    
    REALM_NAME=$(cat "$REALM_FILE")
    PASSWORD=$(cat "$PASS_FILE" 2>/dev/null)

    cat > "$CLIENT_CONF" <<EOF
server: realm://$REALM_SERVER/$REALM_NAME

auth: $PASSWORD

tls:
  sni: $SERVER_NAME
  insecure: true

socks5:
  listen: 127.0.0.1:20886

http:
  listen: 127.0.0.1:20887
EOF
}

# 显示信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"
        return
    fi

    MODE=$(get_mode)
    PASSWORD=$($YQ_BIN '.auth.password' "$CONF" 2>/dev/null || echo "未知")

    echo -e "${YELLOW}正在检测公网 IP...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    if [ "$MODE" = "realms" ]; then
        REALM_NAME=$(cat "$REALM_FILE" 2>/dev/null)
        generate_client_config

        echo -e "\n${GREEN}========== Hysteria2 配置信息 (Realms模式) ==========${NC}"
        echo -e "🌐 Realm名称 : ${YELLOW}$REALM_NAME${NC}"
        echo -e "🔐 认证密码 : ${YELLOW}$PASSWORD${NC}"

        echo -e "\n${GREEN}📎 Realms 节点链接:${NC}"
        echo -e "${YELLOW}hy2://$PASSWORD@$REALM_NAME.$REALM_SERVER?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}${NC}"

        echo -e "\n${GREEN}📄 客户端配置文件 (已保存到 $CLIENT_CONF):${NC}"
        cat "$CLIENT_CONF"
    else
        PORT=$($YQ_BIN '.listen' "$CONF" | sed 's/://g' 2>/dev/null || echo "未知")
        echo -e "\n${GREEN}========== Hysteria2 配置信息 (公网模式) ==========${NC}"
        echo -e "🎲 监听端口 : ${YELLOW}$PORT${NC}"
        echo -e "🔐 认证密码 : ${YELLOW}$PASSWORD${NC}"

        echo -e "\n${GREEN}📎 IPv4 节点链接:${NC}"
        [[ -n "$IP4" ]] && echo -e "${YELLOW}hy2://$PASSWORD@$IP4:$PORT?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V4${NC}" || echo -e "${RED}无法获取 IPv4${NC}"

        echo -e "\n${GREEN}📎 IPv6 节点链接:${NC}"
        [[ -n "$IP6" ]] && echo -e "${YELLOW}hy2://$PASSWORD@[$IP6]:$PORT?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}_V6${NC}" || echo -e "${RED}无法获取 IPv6${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 修改密码
change_password() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    NEW_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    $YQ_BIN -i ".auth.password = \"$NEW_PASSWORD\"" "$CONF"
    echo "$NEW_PASSWORD" > "$PASS_FILE"
    restart_service
    echo -e "${GREEN}✅ 密码修改成功${NC}"
    show_info
}

# 更新 Hysteria2
update_hy2() {
    echo -e "${YELLOW}▶ 检查并更新 Hysteria2...${NC}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64) FILE="hysteria-linux-arm64" ;;
        *) echo -e "${RED}❌ 不支持的架构${NC}"; return ;;
    esac

    [ -f "$BIN" ] && cp "$BIN" "${BIN}.bak.$(date +%F_%H%M)"
    curl -L -o "$BIN.new" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"

    if [ $? -eq 0 ] && [ -s "$BIN.new" ]; then
        mv "$BIN.new" "$BIN"
        chmod +x "$BIN"
        restart_service
        echo -e "${GREEN}✅ Hysteria2 已更新到最新版本${NC}"
    else
        echo -e "${RED}❌ 更新失败${NC}"
        rm -f "$BIN.new"
    fi
}

# 更改端口
change_port() {
    if [ "$(get_mode)" = "realms" ]; then
        echo -e "${RED}❌ Realms模式下不支持更改端口${NC}"; return
    fi
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi

    OLD_PORT=$($YQ_BIN '.listen' "$CONF" | sed 's/://g')
    echo -e "当前端口: ${YELLOW}$OLD_PORT${NC}"
    echo -ne "${YELLOW}请输入新端口 (回车随机10000-65535): ${NC}"
    read NEW_PORT
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 10000 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 端口无效${NC}"; return
    fi

    $YQ_BIN -i ".listen = \":$NEW_PORT\"" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"
    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/udp
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装 Hysteria2（默认公网模式 + QUIC调优）
install_hy2() {
    echo -e "${YELLOW}▶ 正在安装依赖 ...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl ca-certificates bash
    else
        apt update && apt install -y curl openssl ca-certificates bash
    fi

    if [ ! -f "$YQ_BIN" ]; then
        echo -e "${YELLOW}▶ 安装 yq ...${NC}"
        YQ_ARCH=$(uname -m)
        case "$YQ_ARCH" in
            x86_64) YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
            aarch64) YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
            *) echo -e "${RED}❌ 不支持的架构${NC}"; exit 1 ;;
        esac
        curl -L -o "$YQ_BIN" "$YQ_URL" && chmod +x "$YQ_BIN"
    fi

    mkdir -p "$WORKDIR"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64) FILE="hysteria-linux-arm64" ;;
        *) echo -e "${RED}❌ 不支持的架构${NC}"; exit 1 ;;
    esac
    echo -e "${YELLOW}▶ 下载 Hysteria2...${NC}"
    curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"
    chmod +x "$BIN"

    PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)

    echo -e "\n${YELLOW}请选择运行模式：${NC}"
    echo -e " ${CYAN}[1]${NC} 传统公网模式（VPS有公网IP + 开放端口）"
    echo -e " ${CYAN}[2]${NC} Realms-P2P模式 （VPS没有公网IP）"
    echo -ne "请输入 [1-2，默认1]: "
    read MODE_CHOICE
    [[ -z "$MODE_CHOICE" ]] && MODE_CHOICE=1

    if [ "$MODE_CHOICE" = "1" ]; then
        MODE="public"
        echo -ne "${YELLOW}请输入监听端口 (回车随机): ${NC}"
        read PORT
        [[ -z "$PORT" ]] && PORT=$(( ( RANDOM % 55535 ) + 10000 ))
        LISTEN=":$PORT"
        echo "$PORT" > "$PORT_FILE"
    else
        MODE="realms"
        REALM_NAME=$(openssl rand -hex 12)
        echo "$REALM_NAME" > "$REALM_FILE"
        LISTEN="realm://$REALM_SERVER/$REALM_NAME"
        echo -e "${GREEN}✅ Realms名称已生成: ${YELLOW}$REALM_NAME${NC}"
    fi

    echo "$PASSWORD" > "$PASS_FILE"

    echo -e "${YELLOW}▶ 生成自签证书...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=$SERVER_NAME" 2>/dev/null
    chmod 600 "$WORKDIR/key.pem" "$WORKDIR/cert.pem"

    # 服务端配置 + QUIC 调优
    cat > "$CONF" <<EOF
listen: $LISTEN

auth:
  type: password
  password: $PASSWORD

resolver:
  type: tls
  tls:
    addr: 1.1.1.1:853
    timeout: 5s

tls:
  cert: $WORKDIR/cert.pem
  key: $WORKDIR/key.pem
  alpn:
    - h3

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024

masquerade:
  type: proxy
  proxy:
    url: https://$SERVER_NAME
    rewriteHost: true
EOF

    # 服务部署
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/\$RC_SVCNAME.pid"
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
Type=simple
ExecStart=$BIN server -c $CONF
Restart=always
RestartSec=3
LimitNOFILE=2097152
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria
    fi

    restart_service
    echo -e "${GREEN}✅ Hysteria2 安装完成 (${MODE}模式)${NC}"
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

# 主菜单
while true; do
    clear
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria status 2>/dev/null | grep -q "started" && STATUS="${GREEN}运行中${NC}" || STATUS="${RED}停止${NC}"
    else
        systemctl is-active --quiet hysteria 2>/dev/null && STATUS="${GREEN}运行中${NC}" || STATUS="${RED}停止${NC}"
    fi

    echo -e "${GREEN}===============================================${NC}"
    echo -e "     Hysteria2 一键管理脚本（支持Realms）"
    echo -e "     系统: $OS    状态: $STATUS"
    echo -e "${GREEN}===============================================${NC}"
    echo -e " ${CYAN}[1]${NC} 安装 Hysteria2"
    echo -e " ${CYAN}[2]${NC} 查看配置 & 节点链接"
    echo -e " ${CYAN}[3]${NC} 更改监听端口（仅公网）"
    echo -e " ${CYAN}[4]${NC} 重启服务"
    echo -e " ${CYAN}[5]${NC} 修改认证密码"
    echo -e " ${CYAN}[6]${NC} 更新 Hysteria2"
    echo -e " ${CYAN}[7]${NC} 卸载 Hysteria2"
    echo -e " ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    echo -ne "请输入数字选择 [0-7]: "
    read choice

    case $choice in
        1) install_hy2 ;;
        2) show_info ;;
        3) change_port ;;
        4) restart_service && echo -e "${GREEN}✅ 服务已重启${NC}" ;;
        5) change_password ;;
        6) update_hy2 ;;
        7) uninstall_hy2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择${NC}"; sleep 1 ;;
    esac

    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
done
