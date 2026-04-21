#!/bin/bash

# 颜色定义
green='\033[1;32m'
plain='\033[0m'
magenta='\033[1;35m'
yellow='\033[1;33m'
cyan='\033[1;36m' 

# 路径定义
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_PRIV_KEY="${XRAY_CONFIG_DIR}/private.key"
XRAY_PUB_KEY="${XRAY_CONFIG_DIR}/public.key"
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_INIT_ALPINE="/etc/init.d/xray"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${magenta}请在 root 用户下运行脚本${plain}" && exit 1

# 识别系统并安装依赖
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt-get update && apt-get install -y jq curl openssl lsof unzip wget ca-certificates
    elif command -v apk &>/dev/null; then
        apk add jq curl openssl bash lsof unzip wget ca-certificates
        update-ca-certificates
    else
        echo -e "${magenta}暂不支持的系统!${plain}" && exit 1
    fi
}

# 自动检测架构并下载
download_xray() {
    local arch=""
    case "$(uname -m)" in
        x86_64 | x64 | amd64) arch="64" ;;
        aarch64 | arm64) arch="arm64-v8a" ;;
        *) echo -e "${magenta}不支持的架构: $(uname -m)${plain}" && exit 1 ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    echo -e "${cyan}检测到架构: $(uname -m), 正在下载 Xray-core...${plain}"
    
    wget -qO /tmp/xray.zip "$url"
    if [[ $? -ne 0 ]]; then
        echo -e "${magenta}下载失败，请检查网络${plain}"
        exit 1
    fi

    mkdir -p /tmp/xray_temp
    unzip -qo /tmp/xray.zip -d /tmp/xray_temp
    mv -f /tmp/xray_temp/xray "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf /tmp/xray.zip /tmp/xray_temp
}

# 适配服务管理
manage_service() {
    local action=$1
    if command -v systemctl &>/dev/null; then
        systemctl $action xray
    elif command -v rc-service &>/dev/null; then
        rc-service xray $action
    fi
}

# 检查服务状态
is_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet xray
    elif command -v rc-service &>/dev/null; then
        rc-service xray status 2>/dev/null | grep -q "started"
    else
        pgrep -x "xray" >/dev/null
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${green}==================================================${plain}"
    echo -e "  VLESS-REALITY 一键管理脚本"
    echo -e "  当前系统：$(ID= && [ -f /etc/os-release ] && . /etc/os-release && echo $ID || echo "alpine")"
    
    if is_active; then
        echo -e "  Xray状态： ${green}正在运行${plain}"
    else
        echo -e "  Xray状态： ${magenta}未运行${plain}"
    fi
    echo -e "${green}==================================================${plain}"
    echo -e "  ${cyan}[1]${plain}  安装 VLESS-REALITY"
    echo -e "  ${cyan}[2]${plain}  查看节点链接"
    echo -e "  ${cyan}[3]${plain}  更改监听端口"
    echo -e "  ${cyan}[4]${plain}  重启服务"
    echo -e "  ${cyan}[5]${plain}  卸载 VLESS-REALITY"
    echo -e "  ${cyan}[0]${plain}  退出脚本"
    echo -e "${green}==================================================${plain}"
    echo -ne "请输入数字选择 [0-5]: "
    read num
}

# 安装逻辑
install_reality() {
    install_dependencies
    download_xray
    
    mkdir -p "$XRAY_CONFIG_DIR"
    
    local key_pair=$($XRAY_BIN x25519 2>&1)
    priv_key=$(echo "${key_pair}" | grep -i 'Private' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    pub_key=$(echo "${key_pair}" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    if [[ -z "$priv_key" ]]; then
        priv_key=$(echo "${key_pair}" | awk '/Private/{print $2}' | tr -d '[:space:]')
        pub_key=$(echo "${key_pair}" | awk '/Public/{print $2}' | tr -d '[:space:]')
    fi

    echo "$priv_key" > "$XRAY_PRIV_KEY"
    echo "$pub_key" > "$XRAY_PUB_KEY"

    RANDOM_PORT=$(shuf -i 10000-65535 -n 1)
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    sid=$(openssl rand -hex 8)

    jq -n \
        --arg port "$RANDOM_PORT" --arg uuid "$UUID" \
        --arg priv "$priv_key" --arg sid "$sid" \
        '
        {
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "port": ($port | tonumber),
            "protocol": "vless",
            "settings": {
              "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
              "decryption": "none"
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "show": false,
                "dest": "www.shopify.com:443",
                "xver": 0,
                "serverNames": ["www.shopify.com"],
                "privateKey": $priv,
                "shortIds": [$sid]
              }
            }
          }],
          "outbounds": [{"protocol": "freedom", "tag": "direct"}]
        }
        ' > "$XRAY_CONFIG"

    if command -v systemctl &>/dev/null; then
        cat <<EOF > "$XRAY_SERVICE"
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    elif command -v rc-service &>/dev/null; then
        cat <<EOF > "$XRAY_INIT_ALPINE"
#!/sbin/openrc-run
description="Xray Service"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG"
command_background="yes"
pidfile="/run/xray.pid"
respawn_delay=5
supervise_daemon_args="--respawn"
depend() {
    need net
    after firewall
}
EOF
        chmod +x "$XRAY_INIT_ALPINE"
        rc-update add xray default >/dev/null 2>&1
    fi
    
    manage_service restart
    echo -e "${green}安装成功！端口：$RANDOM_PORT${plain}"
    view_config
}

# 查看配置
view_config() {
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${magenta}未发现配置文件！${plain}"
    else
        UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
        PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
        sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
        
        if [ ! -s "$XRAY_PUB_KEY" ]; then
            local priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
            pubKey=$($XRAY_BIN x25519 -i "$priv" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')
            [[ -z "$pubKey" ]] && pubKey=$($XRAY_BIN x25519 -i "$priv" | awk '/Public/{print $2}' | tr -d '[:space:]')
            echo "$pubKey" > "$XRAY_PUB_KEY"
        else
            pubKey=$(cat "$XRAY_PUB_KEY")
        fi

        IPV4=$(curl -s4m 5 ipv4.ip.sb || curl -s4m 5 api.ipify.org)
        echo -e "\n${green}--- 节点链接信息 ---${plain}"
        echo -e "${yellow}vless://${UUID}@${IPV4}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.shopify.com&fp=chrome&pbk=${pubKey}&sid=${sid}&type=tcp&headerType=none#REALITY_v4${plain}\n"
    fi
    read -p "按回车键返回菜单..."
}

# 修改端口
change_port() {
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${magenta}未安装服务！${plain}"
    else
        echo -ne "请输入新端口: "
        read input_port
        NEW_PORT=${input_port:-$(shuf -i 10000-65535 -n 1)}
        tmp=$(mktemp)
        jq --argjson p "$NEW_PORT" '.inbounds[0].port = $p' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        manage_service restart
        echo -e "${green}端口已改为 $NEW_PORT 并重启服务${plain}"
        view_config
    fi
}

# 卸载
uninstall_reality() {
    manage_service stop
    if command -v systemctl &>/dev/null; then
        systemctl disable xray >/dev/null 2>&1
        rm -f "$XRAY_SERVICE"
    elif command -v rc-service &>/dev/null; then
        rc-update del xray >/dev/null 2>&1
        rm -f "$XRAY_INIT_ALPINE"
    fi
    rm -rf "$XRAY_BIN" "$XRAY_CONFIG_DIR"
    echo -e "${green}卸载完成${plain}"
    sleep 2
}

while true; do
    show_menu
    case "$num" in
        1) install_reality ;;
        2) view_config ;;
        3) change_port ;;
        4) manage_service restart && echo -e "${green}已执行重启${plain}" && sleep 2 ;;
        5) uninstall_reality ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
