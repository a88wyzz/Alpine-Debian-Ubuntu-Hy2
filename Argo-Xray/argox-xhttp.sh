#!/bin/bash
# Argo-Xray 管理脚本 - 仅支持固定隧道

# ====================== 颜色 ======================
green='\033[0;32m'
cyan='\033[0;36m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

# ====================== 系统检测 ======================
if grep -qi Alpine /etc/os-release; then
    OS="alpine"
elif grep -qiE 'debian|ubuntu' /etc/os-release; then
    OS="debian"
else
    echo -e "${red}不支持的系统！${plain}"
    echo -e "本脚本仅支持：${green}Alpine、Debian、Ubuntu${plain}"
    exit 1
fi

echo -e "${cyan}检测到系统：${green}$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)${plain}"

# ====================== 环境准备 ======================
mkdir -p /usr/local/argox
mkdir -p /usr/local/cloudflare

# 安装依赖
if [ "$OS" = "alpine" ]; then
    apk update
    apk add curl jq unzip gcompat
else
    apt update -y
    apt install -y curl jq unzip
fi

# ====================== 配置生成 ======================
generate_config() {
    local port=$1
    local uuid=$2
    local path=$3

    jq -n \
    --arg port "$port" \
    --arg uuid "$uuid" \
    --arg path "/$path" '
    {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "port": ($port | tonumber),
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [{ "id": $uuid }]
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "path": $path,
                    "mode": "auto"
                }
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {}
        }]
    }' > /usr/local/argox/config.json
}

# ====================== 重启服务 ======================
restart_service() {
    echo -e "${yellow}正在重启 ArgoX 服务...${plain}"
    if [ "$OS" = "alpine" ]; then
        rc-service argox restart
    else
        systemctl restart argox 2>/dev/null
    fi
    sleep 2
    echo -e "${green}服务重启完成！${plain}"
}

# ====================== 固定隧道安装 ======================
installtunnel() {
    cd /tmp
    rm -rf xray cloudflared xray.zip

    case "$(uname -m)" in
        x86_64|amd64|x64)
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
            ;;
        arm64|aarch64)
            curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared
            ;;
        *) echo -e "${red}不支持的架构！${plain}"; exit 1 ;;
    esac

    unzip -j xray.zip xray -d ./ >/dev/null 2>&1
    chmod +x cloudflared xray
    mv xray /usr/local/argox/
    mv cloudflared /usr/local/cloudflare/
    rm -rf xray.zip

    cd /usr/local/argox/
    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=$(echo "$uuid" | awk -F- '{print $1}')
    port=$((RANDOM + 10000))

    generate_config "$port" "$uuid" "$urlpath"

    echo -e "${cyan}正在进行 Cloudflare 登录...${plain}"
    /usr/local/cloudflare/cloudflared tunnel login

    clear
    echo -e "${cyan}当前已绑定的 Argo Tunnel 如下：${plain}\n"
    /usr/local/cloudflare/cloudflared tunnel list

    read -p "请输入你要绑定的完整域名 (例如：argo.example.com): " domain
    name=$(echo "$domain" | awk -F. '{print $1}')

    /usr/local/cloudflare/cloudflared tunnel create "$name" >/dev/null 2>&1
    /usr/local/cloudflare/cloudflared tunnel route dns --overwrite-dns "$name" "$domain" >/dev/null 2>&1

    tunneluuid=$(/usr/local/cloudflare/cloudflared tunnel list | grep "$name" | awk '{print $1}')
    if [ -z "$tunneluuid" ]; then
        echo -e "${red}获取隧道ID失败，请检查是否已登录${plain}"
        exit 1
    fi

    # 生成节点信息
    cat > /usr/local/argox/argox.txt <<EOF
======================== ArgoX 固定隧道节点 ========================

EOF
    echo -e "${green}vless://${uuid}@www.shopify.com:443?encryption=none&security=tls&type=xhttp&host=${domain}&path=/${urlpath}&sni=${domain}#ArgoX-TLS${plain}" >> /usr/local/argox/argox.txt
    echo "" >> /usr/local/argox/argox.txt
    echo -e "${green}vless://${uuid}@www.shopify.com:80?encryption=none&security=none&type=xhttp&host=${domain}&path=/${urlpath}#ArgoX${plain}" >> /usr/local/argox/argox.txt
    echo "" >> /usr/local/argox/argox.txt
    echo -e "${yellow}提示：${plain}" >> /usr/local/argox/argox.txt
    echo -e "${yellow}1. www.shopify.com 可替换为任意支持 Cloudflare 的优选域名或IP${plain}" >> /usr/local/argox/argox.txt
    echo -e "${yellow}2. TLS 端口推荐：443, 8443, 2053, 2083, 2087, 2096${plain}" >> /usr/local/argox/argox.txt
    echo -e "${yellow}3. 普通端口推荐：80, 8080, 8880, 2052, 2082, 2086, 2095${plain}" >> /usr/local/argox/argox.txt

    # 创建 config.yaml
    cat > /usr/local/cloudflare/config.yaml <<EOF
tunnel: ${tunneluuid}
credentials-file: /root/.cloudflared/${tunneluuid}.json
ingress:
  - hostname: ${domain}
    service: http://localhost:${port}
  - service: http_status:404
EOF

    # ==================== 服务部署 ====================
    if [ "$OS" = "alpine" ]; then
        echo -e "${cyan}正在创建 Alpine OpenRC 服务 ...${plain}"
        
        cat > /etc/init.d/argox <<'EOF'
#!/sbin/openrc-run

name="argox"
description="ArgoX - Cloudflared + Xray"

command="/usr/local/cloudflare/cloudflared"
command_args="tunnel --config /usr/local/cloudflare/config.yaml run ${name}"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true

depend() {
    need net
}

start_pre() {
    mkdir -p /run/${RC_SVCNAME}
}

start_post() {
    # 启动 Xray 并记录 PID
    /usr/local/argox/xray run -config /usr/local/argox/config.json > /dev/null 2>&1 &
    echo $! > /run/argox-xray.pid
}

stop_post() {
    if [ -f /run/argox-xray.pid ]; then
        kill $(cat /run/argox-xray.pid) 2>/dev/null
        rm -f /run/argox-xray.pid
    fi
}
EOF

        chmod +x /etc/init.d/argox
        rc-update add argox default
        rc-service argox restart

    else
        # Debian / Ubuntu
        cat > /lib/systemd/system/argox.service <<EOF
[Unit]
Description=ArgoX Service (Cloudflared + Xray)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/cloudflare/cloudflared tunnel --config /usr/local/cloudflare/config.yaml run ${name}
WorkingDirectory=/usr/local/cloudflare
Restart=always
RestartSec=3
LimitNOFILE=65535

ExecStartPost=/usr/bin/env bash -c '/usr/local/argox/xray run -config /usr/local/argox/config.json &'

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now argox >/dev/null 2>&1
    fi

    clear
    echo -e "${green}固定隧道安装完成！${plain}"
    cat /usr/local/argox/argox.txt
    echo -e "\n节点信息已保存至：${green}/usr/local/argox/argox.txt${plain}"
}

# ====================== 主菜单 ======================
clear

argostatus=$(ps -ef | grep -v grep | grep -c cloudflared)
xraystatus=$(ps -ef | grep -v grep | grep -c xray)

if [ -f "/usr/local/cloudflare/config.yaml" ]; then
    mode_type="${green}固定隧道${plain}"
else
    mode_type="${yellow}未安装${plain}"
fi

echo -e "${cyan}======================================================${plain}"
echo -e " Argo-Xray 管理脚本 - [XHTTP仅支持固定隧道]"
echo -e " 当前系统：${yellow}$(grep -i PRETTY_NAME /etc/os-release | cut -d'"' -f2)${plain}"
echo -n " Argo 状态: "
[ $argostatus -gt 0 ] && echo -ne "${green}● running${plain} ($mode_type)" || echo -ne "${red}○ stopped${plain}"
echo -n "   |   Xray 状态: "
[ $xraystatus -gt 0 ] && echo -e "${green}● running${plain}" || echo -e "${red}○ stopped${plain}"
echo -e "${cyan}======================================================${plain}"
echo -e " ${green}[1]${plain} 安装固定隧道(需要cloudflare域名)"
echo -e " ${green}[2]${plain} 查看节点链接"
echo -e " ${green}[3]${plain} 重启服务"
echo -e " ${green}[4]${plain} 卸载服务"
echo -e " ${green}[0]${plain} 退出脚本"
echo -e "${cyan}======================================================${plain}"

read -p " 请输入数字选择 [0-4]: " mode

case "$mode" in
    1) installtunnel ;;
    2) [ -f /usr/local/argox/argox.txt ] && cat /usr/local/argox/argox.txt || echo -e "${red}未找到节点信息${plain}" ;;
    3) restart_service ;;
    4)
        echo -e "${yellow}正在卸载...${plain}"
        if [ "$OS" = "alpine" ]; then
            rc-service argox stop 2>/dev/null
            rc-update del argox 2>/dev/null
            rm -f /etc/init.d/argox
        else
            systemctl disable --now argox 2>/dev/null
            rm -f /lib/systemd/system/argox.service
            systemctl daemon-reload
        fi
        pkill -9 -f xray 2>/dev/null
        pkill -9 -f cloudflared 2>/dev/null
        rm -rf /usr/local/argox /usr/local/cloudflare /root/.cloudflared
        echo -e "${green}卸载完成！${plain}"
        ;;
    *) exit 0 ;;
esac
