#!/bin/bash
# Xray Hysteria2 一键管理脚本

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m错误: 请使用 root 权限运行此脚本。\033[0m"
    exit 1
fi

# ==================== 颜色定义 ====================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
CYAN='\033[36m'
RESET='\033[0m'
BOLD='\033[1m'

# ==================== 路径定义 ====================
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BINARY_PATH="/usr/local/bin/xray"
CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"
LOG_FILE="/var/log/xray.log"
SERVICE_FILE="/etc/systemd/system/xray-hy2.service"
ALPINE_INIT_FILE="/etc/init.d/xray-hy2"

# ==================== 系统环境检测 ====================
IS_ALPINE=0
if [ -x "$(command -v apk)" ]; then
    IS_ALPINE=1
fi

# ==================== 依赖安装与系统检查 ====================
init_depends() {
    echo -e "${YELLOW}▶ 正在安装系统依赖...${RESET}"
    if [ "$IS_ALPINE" -eq 1 ]; then
        apk update && apk add jq curl bash unzip ca-certificates openssl
    elif [ -x "$(command -v apt-get)" ]; then
        apt-get update && apt-get install -y jq curl unzip ca-certificates openssl
    else
        echo -e "${RED}错误: 不支持的系统，仅支持 Alpine / Debian / Ubuntu${RESET}"
        exit 1
    fi
}

# ==================== 生成证书 ====================
generate_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo -e "${YELLOW}自签证书已存在，跳过生成。${RESET}"
        return 0
    fi

    echo -e "${YELLOW}▶ 正在生成 Xray 自签证书...${RESET}"
    mkdir -p "$CONFIG_DIR"
    chmod +x "$BINARY_PATH" 2>/dev/null

    $BINARY_PATH tls cert \
        --domain="hy2.local" \
        --name="hy2.local" \
        --org="Xray" \
        --expire=87600h \
        --file="${CONFIG_DIR}/server" >/dev/null 2>&1

    [ -f "$CERT_FILE" ] && echo -e "${GREEN}证书生成完成。${RESET}" || echo -e "${RED}证书生成失败！${RESET}"
}

# ==================== 安装 Xray ====================
install_xray_binary() {
    if [ -f "$BINARY_PATH" ]; then
        echo -e "${YELLOW}Xray 已安装，跳过下载。${RESET}"
        return 0
    fi

    echo -e "${YELLOW}▶ 正在下载 Xray 最新核心...${RESET}"
    mkdir -p "$CONFIG_DIR"

    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    elif [[ "$ARCH" = "aarch64" || "$ARCH" = "arm64" ]]; then
        URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
    else
        echo -e "${RED}不支持的架构: $ARCH${RESET}"
        exit 1
    fi

    curl -L -o /tmp/xray.zip "$URL"
    unzip -o /tmp/xray.zip -d /tmp/xray_bin
    mv /tmp/xray_bin/xray "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf /tmp/xray.zip /tmp/xray_bin

    echo -e "${GREEN}Xray 核心安装成功。${RESET}"
}

# ==================== 初始化配置 ===================
init_config() {
    mkdir -p "$CONFIG_DIR"
    local port=$((RANDOM % 55536 + 10000))
    local default_auth=$(openssl rand -hex 8)

    echo -e "${YELLOW}▶ 正在生成 Hysteria2 配置文件（端口：$port）...${RESET}"

    cat > "$CONFIG_FILE" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "hysteria",
    "tag": "hy2-in"
    },
    "streamSettings": {
      "network": "hysteria",
      "hysteriaSettings": {
          "version": 2,
          "auth": "$default_auth",
          "udpIdleTimeout": 60
            },
      "security": "tls",
      "tlsSettings": {
        "alpn": ["h3"],
        "certificates": [{ "certificateFile": "$CERT_FILE", "keyFile": "$KEY_FILE" }]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }],
  "dns": {
    "servers": ["https://dns.google/dns-query"],
    "queryStrategy": "UseIP"
  }
}
EOF

    echo -e "${GREEN}配置文件生成完成${RESET}"
}

# ==================== 创建服务守护 ====================
create_service() {
    if [ "$IS_ALPINE" -eq 1 ]; then
        echo "正在创建 Alpine OpenRC 服务（带进程守护）..."
        cat > "$ALPINE_INIT_FILE" << 'EOF'
#!/sbin/openrc-run

description="Xray Hysteria2 Service"
supervisor="supervise-daemon"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$ALPINE_INIT_FILE"
        rc-update add xray-hy2 default >/dev/null 2>&1
        echo -e "${GREEN}OpenRC 服务创建完成。${RESET}"
    else
        echo "正在创建 systemd 服务..."
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Xray Hysteria2 Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$BINARY_PATH run -config $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        echo -e "${GREEN}Systemd 服务创建完成。${RESET}"
    fi
}

# ==================== 重启服务 ====================
restart_service() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 配置文件不存在，请先执行完整安装！${RESET}"
        return 1
    fi

    local port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE" 2>/dev/null)
    if command -v ufw >/dev/null; then
        ufw allow "$port"/udp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    local is_active=0
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service xray-hy2 restart >/dev/null 2>&1
        sleep 1.5
        if rc-service xray-hy2 status | grep -q "started"; then is_active=1; fi
    else
        systemctl restart xray-hy2 2>/dev/null
        systemctl enable --now xray-hy2 >/dev/null 2>&1
        sleep 1.5
        if systemctl is-active --quiet xray-hy2; then is_active=1; fi
    fi

    if [ "$is_active" -eq 1 ]; then
        echo -e "${GREEN}✅ Hysteria2 服务重启成功！${RESET}"
        show_status
    else
        echo -e "${RED}❌ 重启失败！请查看日志: $LOG_FILE${RESET}"
    fi
}

# ==================== 查看状态与节点链接 ====================
show_status() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}【错误】: 配置文件不存在，请先安装。${RESET}"
        return
    fi

    local port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
    local auth=$(jq -r '.inbounds[0].settings.clients[0].auth' "$CONFIG_FILE")

    local pin_sha256=$($BINARY_PATH tls hash --cert "$CERT_FILE" 2>/dev/null | grep -oE '[A-Za-z0-9+/=]{43,}' | head -n1)
    if [ -z "$pin_sha256" ]; then
        pin_sha256=$(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null)
    fi
    pin_sha256=$(echo -n "$pin_sha256" | tr -d '\n\r ')

    local ip4=$(curl -s4 --connect-timeout 5 api.ipify.org || curl -s4 --connect-timeout 5 ip.sb)
    local ip6=$(curl -s6 --connect-timeout 5 api6.ipify.org || curl -s6 --connect-timeout 5 v6.ip.sb)
    local encoded_pin=$(echo -n "$pin_sha256" | jq -sRr @uri | tr -d '\n\r')

    local SUB_LINE="${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    echo ""
    echo -e "$SUB_LINE"
    echo -e " ${BOLD}Xray Hysteria2 配置参数${RESET}"
    echo -e "$SUB_LINE"
    echo -e "  端口 (UDP) : ${GREEN}$port${RESET}"
    echo -e "  认证密码   : ${GREEN}$auth${RESET}"
    echo -e "  PinSHA256  : ${GREEN}$pin_sha256${RESET}"
    echo -e "$SUB_LINE"
    echo -e " ${BOLD}节点链接${RESET}"
    echo -e "$SUB_LINE"

    if [ -n "$ip4" ]; then
        echo -e "  ${GREEN}🔵 IPv4 节点:${RESET}"
        echo -e "  ${YELLOW}hy2://${auth}@${ip4}:${port}?pinSHA256=${encoded_pin}&insecure=1&alpn=h3#Hy2-IPv4${RESET}"
        echo ""
    fi
    if [ -n "$ip6" ]; then
        echo -e "  ${GREEN}🟢 IPv6 节点:${RESET}"
        echo -e "  ${YELLOW}hy2://${auth}@[${ip6}]:${port}?pinSHA256=${encoded_pin}&insecure=1&alpn=h3#Hy2-IPv6${RESET}"
        echo ""
    fi
    echo -e " ${CYAN}💡 长按或双击链接即可复制${RESET}"
    echo -e "$SUB_LINE"
}

# ==================== 修改端口 ====================
change_port() {
    if [ ! -f "$CONFIG_FILE" ]; then 
        echo -e "${RED}配置文件不存在${RESET}"; 
        return 
    fi
    
    read -p "▶ 请输入新端口 (直接回车随机生成): " p
    
    # 判断是否直接敲了回车
    if [ -z "$p" ]; then
        p=$((RANDOM % 55536 + 10000))
        echo -e "${YELLOW}未输入端口，已自动分配随机端口: $p${RESET}"
    fi

    jq --argjson port "$p" '.inbounds[0].port = $port' "$CONFIG_FILE" > /tmp/config.tmp && mv /tmp/config.tmp "$CONFIG_FILE"
    echo -e "${GREEN}端口已修改为 $p，正在配置防火墙并重启服务...${RESET}"
    restart_service
}

# ==================== 彻底卸载 ====================
uninstall_all() {
    read -p "⚠️ 确定要彻底卸载所有文件吗？(y/n): " c
    if [[ "$c" == "y" || "$c" == "Y" ]]; then
        if [ "$IS_ALPINE" -eq 1 ]; then
            rc-service xray-hy2 stop 2>/dev/null
            rc-update del xray-hy2 default 2>/dev/null
            rm -f "$ALPINE_INIT_FILE"
        else
            systemctl stop xray-hy2 2>/dev/null
            systemctl disable xray-hy2 2>/dev/null
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
        fi
        rm -f "$BINARY_PATH" "$LOG_FILE"
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✅ 已彻底卸载 Xray Hysteria2 相关组件。${RESET}"
    fi
}

# ==================== 主菜单 ====================
menu() {
    clear
    local sys_info
    if [ -f /etc/os-release ]; then
        sys_info=$(grep -w "ID" /etc/os-release | cut -d'=' -f2 | tr -d '"')
    else
        sys_info="unknown"
    fi
    
    local service_status
    if [ ! -f "$CONFIG_FILE" ]; then
        service_status="${YELLOW}未安装${RESET}"
    else
        local is_run=0
        if [ "$IS_ALPINE" -eq 1 ]; then
            if rc-service xray-hy2 status 2>/dev/null | grep -q "started"; then is_run=1; fi
        else
            if systemctl is-active --quiet xray-hy2 2>/dev/null; then is_run=1; fi
        fi
        
        if [ "$is_run" -eq 1 ]; then
            service_status="${GREEN}正在运行${RESET}"
        else
            service_status="${RED}已停止${RESET}"
        fi
    fi

    local LINE="${GREEN}============================================================${RESET}"

    echo -e "$LINE"
    echo -e "  ${BOLD}Xray-Hysteria2 一键管理脚本${RESET}"
    echo -e "  当前系统：${BLUE}$sys_info${RESET}"
    echo -e "  Xray状态： $service_status"
    echo -e "$LINE"
    echo -e "  ${CYAN}[1]${RESET} 安装 Xray-Hysteria2"
    echo -e "  ${CYAN}[2]${RESET} 查看配置节点链接"
    echo -e "  ${CYAN}[3]${RESET} 更改监听端口"
    echo -e "  ${CYAN}[4]${RESET} 重启服务"
    echo -e "  ${CYAN}[5]${RESET} 卸载 Xray-Hysteria2"
    echo -e "  ${CYAN}[0]${RESET} 退出脚本"
    echo -e "$LINE"
}

# ==================== 主循环 ====================
while true; do
    menu
    read -p "请输入数字选择操作 [0-5]: " num

    case "$num" in
        1)
            init_depends
            install_xray_binary
            generate_cert
            init_config
            create_service
            restart_service
            ;;
        2) show_status ;;
        3) change_port ;;
        4) restart_service ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择。${RESET}" ;;
    esac

    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
