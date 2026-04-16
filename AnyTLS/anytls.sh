#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
WORK_DIR="/usr/local/anytls"
BIN="${WORK_DIR}/anytls"
CONF="${WORK_DIR}/config.json"
SERVICE_NAME="anytls"
### =====================

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
NC='\033[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
else
    echo -e "${RED}❌ 不支持的系统${NC}"; exit 1
fi

install_dependencies() {
    echo -e "${YELLOW}▶ 正在检查并安装必要依赖...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl bash openrc jq unzip
    else
        apt update -y && apt install -y curl openssl jq unzip
    fi
}

# 核心功能：更新系统服务启动参数
update_service_config() {
    local port=$1
    local pass=$2
    local bind_addr="0.0.0.0"

    if command -v systemctl >/dev/null; then
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target
[Service]
ExecStart=${BIN} -l ${bind_addr}:${port} -p ${pass}
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="AnyTLS-Go Server"
command="${BIN}"
command_args="-l ${bind_addr}:${port} -p ${pass}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
    fi
}

restart_service() {
    if command -v systemctl >/dev/null; then
        systemctl restart ${SERVICE_NAME}
    else
        rc-service ${SERVICE_NAME} restart
    fi
}

show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"; return
    fi
    
    LISTEN=$(jq -r '.listen' "$CONF")
    PORT=$(echo $LISTEN | rev | cut -d: -f1 | rev)
    PASS=$(jq -r '.password' "$CONF")
    
    echo -e "${YELLOW}正在检测公网 IP...${NC}"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== AnyTLS 配置信息 ==========${NC}"
    echo -e "🔐 密码: ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}"
    
    [[ -n "$IP4" ]] && echo -e "\n${GREEN}📎 IPv4 链接:${NC}\n${YELLOW}anytls://$PASS@$IP4:$PORT?insecure=1#AnyTLS_v4${NC}"
    [[ -n "$IP6" ]] && echo -e "\n${GREEN}📎 IPv6 链接:${NC}\n${YELLOW}anytls://$PASS@[$IP6]:$PORT?insecure=1#AnyTLS_v6${NC}"
    echo -e "${GREEN}=======================================${NC}\n"
}

# 更改端口功能
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 AnyTLS${NC}"; return
    fi

    OLD_LISTEN=$(jq -r '.listen' "$CONF")
    OLD_PORT=$(echo $OLD_LISTEN | rev | cut -d: -f1 | rev)
    PASS=$(jq -r '.password' "$CONF")

    echo -e "当前端口为: ${YELLOW}$OLD_PORT${NC}"
    echo -ne "${GREEN}请输入新端口 (回车随机): ${NC}"
    read NEW_PORT

    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 更新 JSON 记录
    tmp=$(mktemp)
    jq --arg nl "0.0.0.0:$NEW_PORT" '.listen = $nl' "$CONF" > "$tmp" && mv "$tmp" "$CONF"

    # 更新系统服务参数
    update_service_config "$NEW_PORT" "$PASS"

    # 放行防火墙
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$NEW_PORT"/udp
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p udp --dport "$NEW_PORT" -j ACCEPT
    fi

    restart_service
    echo -e "${GREEN}✅ 端口已成功更改为 $NEW_PORT 并重启服务${NC}"
    show_info
}

install_anytls() {
    install_dependencies
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) AT_ARCH="amd64" ;;
        aarch64|arm64) AT_ARCH="arm64" ;;
        *) echo "❌ 不支持架构: $ARCH"; exit 1 ;;
    esac

    mkdir -p $WORK_DIR
    echo -e "${YELLOW}▶ 正在从 GitHub 下载最新版本...${NC}"
    
    LATEST_JSON=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest")
    DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r ".assets[] | select(.name | contains(\"linux_${AT_ARCH}\") and endswith(\".zip\")) | .browser_download_url")

    curl -L -o "${WORK_DIR}/anytls.zip" "$DOWNLOAD_URL"
    unzip -o "${WORK_DIR}/anytls.zip" -d $WORK_DIR
    
    if [ -f "${WORK_DIR}/anytls-server" ]; then
        mv "${WORK_DIR}/anytls-server" $BIN
    fi
    chmod +x $BIN
    rm -f "${WORK_DIR}/anytls.zip" "${WORK_DIR}/anytls-client" "${WORK_DIR}/readme.md"

    echo -ne "\n${GREEN}请输入监听端口 (回车随机): ${NC}"
    read INPUT_PORT
    [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && PORT=$INPUT_PORT || PORT=$(( ( RANDOM % 50000 ) + 10000 ))

    PASS=$(openssl rand -hex 4)

    # 存入 JSON 记录
    cat > $CONF <<EOF
{
  "listen": "0.0.0.0:${PORT}",
  "password": "${PASS}"
}
EOF

    # 初始创建服务配置
    update_service_config "$PORT" "$PASS"
    
    if command -v systemctl >/dev/null; then
        systemctl enable ${SERVICE_NAME}
    else
        rc-update add ${SERVICE_NAME} default
    fi

    restart_service
    echo -e "${GREEN}✅ AnyTLS 安装完成！${NC}"
    show_info
}

# 菜单
clear
echo -e "${GREEN}--- AnyTLS-Go 管理脚本 ---${NC}"
echo "--------------------------"
echo "1. 安装 AnyTLS"
echo "2. 查看配置信息"
echo "3. 更改监听端口"
echo "4. 重启服务"
echo "5. 卸载 AnyTLS"
echo "0. 退出"
echo "--------------------------"
read -p "选择: " choice

case $choice in
    1) install_anytls ;;
    2) show_info ;;
    3) change_port ;;
    4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;;
    5) 
        if command -v systemctl >/dev/null; then
            systemctl stop ${SERVICE_NAME} && systemctl disable ${SERVICE_NAME}
            rm -f /etc/systemd/system/${SERVICE_NAME}.service
        else
            rc-service ${SERVICE_NAME} stop && rc-update del ${SERVICE_NAME}
            rm -f /etc/init.d/${SERVICE_NAME}
        fi
        rm -rf $WORK_DIR
        echo -e "${GREEN}✅ AnyTLS 已完全卸载${NC}"
        ;;
    *) exit 0 ;;
esac
