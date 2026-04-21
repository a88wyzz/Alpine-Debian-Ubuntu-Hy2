#!/bin/bash

# 颜色定义
green='\033[1;32m'
plain='\033[0m'
magenta='\033[1;35m'
yellow='\033[1;33m'
cyan='\033[1;36m' # 浅蓝色

# 路径定义
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${magenta}请在 root 用户下运行脚本${plain}" && exit 1

# 识别系统并安装依赖
install_dependencies() {
    if command -v apt &>/dev/null; then
        apt-get update && apt-get install -y jq curl openssl lsof
    elif command -v apk &>/dev/null; then
        apk add jq curl openssl bash lsof
    else
        echo -e "${magenta}暂不支持的系统!${plain}" && exit 1
    fi
}

# 检查服务状态
is_active() {
    systemctl is-active --quiet xray
}

# 显示菜单
show_menu() {
    clear
    echo -e "${green}=============================================${plain}"
    echo -e "  VLESS-REALITY 一键管理脚本"
    echo -e "  当前系统：$(ID= && [ -f /etc/os-release ] && . /etc/os-release && echo $ID || echo "unknown")"
    
    if is_active; then
        echo -e "  Xray状态： ${green}正在运行${plain}"
    else
        echo -e "  Xray状态： ${magenta}未运行${plain}"
    fi
    echo -e "${green}=============================================${plain}"
    echo -e "  ${cyan}[1]${plain}  安装 VLESS-REALITY"
    echo -e "  ${cyan}[2]${plain}  查看节点链接"
    echo -e "  ${cyan}[3]${plain}  更改监听端口"
    echo -e "  ${cyan}[4]${plain}  重启服务"
    echo -e "  ${cyan}[5]${plain}  卸载 VLESS-REALITY"
    echo -e "  ${cyan}[0]${plain}  退出脚本"
    echo -e "${green}=============================================${plain}"
    echo -ne "请输入数字选择 [0-5]: "
    read num
}

# 安装逻辑
install_reality() {
    install_dependencies
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    RANDOM_PORT=$(shuf -i 10000-65535 -n 1)
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    output=$(/usr/local/bin/xray x25519)
    privKey=$(echo "${output}" | grep 'PrivateKey:' | awk '{print $2}')
    sid=$(openssl rand -hex 8)
    mkdir -p /usr/local/etc/xray

    jq -n \
        --arg port "$RANDOM_PORT" \
        --arg uuid "$UUID" \
        --arg priv "$privKey" \
        --arg sid "$sid" \
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
        ' > $XRAY_CONFIG

    chown -R nobody:nogroup /usr/local/etc/xray >/dev/null 2>&1 || chown -R nobody:nobody /usr/local/etc/xray >/dev/null 2>&1
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    echo -e "${green}安装成功！初始端口：$RANDOM_PORT${plain}"
    view_config
}

# 查看配置
view_config() {
    if [ ! -f $XRAY_CONFIG ]; then
        echo -e "${magenta}未发现配置文件！${plain}"
    else
        UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONFIG)
        PORT=$(jq -r '.inbounds[0].port' $XRAY_CONFIG)
        privKey=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' $XRAY_CONFIG)
        sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $XRAY_CONFIG)
        pubKey=$(/usr/local/bin/xray x25519 -i "$privKey" | grep 'Password' | awk '{print $3}')
        IPV4=$(curl -s4m 5 ipv4.ip.sb || curl -s4m 5 api.ipify.org)
        IPV6=$(curl -s6m 5 ipv6.ip.sb || curl -s6m 5 api6.ipify.org)

        echo -e "\n${green}--- 节点链接信息 ---${plain}"
        if [ -n "$IPV4" ]; then
            echo -e "${green}[IPv4 节点]:${plain}"
            echo -e "${yellow}vless://${UUID}@${IPV4}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.shopify.com&fp=chrome&pbk=${pubKey}&sid=${sid}&type=tcp&headerType=none#REALITY_v4${plain}\n"
        fi
        if [ -n "$IPV6" ]; then
            echo -e "${green}[IPv6 节点]:${plain}"
            echo -e "${yellow}vless://${UUID}@[${IPV6}]:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.shopify.com&fp=chrome&pbk=${pubKey}&sid=${sid}&type=tcp&headerType=none#REALITY_v6${plain}\n"
        fi
    fi
    read -p "按回车键返回菜单..."
}

# 修改端口 (回车随机)
change_port() {
    if [ ! -f $XRAY_CONFIG ]; then
        echo -e "${magenta}未安装服务！${plain}"
    else
        echo -ne "请输入新的端口号 (回车随机生成): "
        read input_port
        
        if [ -z "$input_port" ]; then
            NEW_PORT=$(shuf -i 10000-65535 -n 1)
            echo -e "${yellow}已随机生成端口: $NEW_PORT${plain}"
        else
            if ! [[ "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -gt 65535 ] || [ "$input_port" -lt 1 ]; then
                echo -e "${magenta}错误：请输入 1000-65535 之间的数字！${plain}"
                sleep 2 && return
            fi
            NEW_PORT=$input_port
        fi

        # 检查占用
        if lsof -i:"$NEW_PORT" >/dev/null 2>&1; then
            echo -e "${magenta}错误：端口 $NEW_PORT 已被占用！${plain}"
            sleep 2 && return
        fi
        
        # 写入并修复权限
        tmp=$(mktemp)
        jq --argjson p "$NEW_PORT" '.inbounds[0].port = $p' $XRAY_CONFIG > "$tmp" && mv "$tmp" $XRAY_CONFIG
        chown -R nobody:nogroup /usr/local/etc/xray >/dev/null 2>&1 || chown -R nobody:nobody /usr/local/etc/xray >/dev/null 2>&1
        
        # 重启序列
        systemctl stop xray >/dev/null 2>&1
        pkill -9 xray >/dev/null 2>&1
        systemctl daemon-reload
        systemctl start xray
        
        sleep 3
        if is_active; then
            echo -e "${green}成功：端口已改为 $NEW_PORT 并且 Xray 已重启${plain}"
        else
            echo -e "${magenta}失败：服务未能自动启动，请手动检查配置${plain}"
        fi
    fi
    sleep 3
}

# 卸载
uninstall_reality() {
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    rm -rf /usr/local/etc/xray
    echo -e "${green}卸载完成${plain}"
    sleep 2
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1) install_reality ;;
        2) view_config ;;
        3) change_port ;;
        4) systemctl restart xray && echo -e "${green}已执行 systemctl restart xray${plain}" && sleep 2 ;;
        5) uninstall_reality ;;
        0) exit 0 ;;
        *) echo -e "${magenta}选择错误！${plain}" && sleep 2 ;;
    esac
done
