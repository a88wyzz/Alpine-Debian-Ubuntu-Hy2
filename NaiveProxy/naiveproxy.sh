#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
BOLD="\033[1m"
PLAIN="\033[0m"

red(){ echo -e "${RED}${BOLD}$1${PLAIN}"; }
green(){ echo -e "${GREEN}${BOLD}$1${PLAIN}"; }
yellow(){ echo -e "${YELLOW}${BOLD}$1${PLAIN}"; }
blue(){ echo -e "${BLUE}${BOLD}$1${PLAIN}"; }
cyan(){ echo -e "${CYAN}${BOLD}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

# --- 系统检测 ---
if [ -f /etc/alpine-release ]; then
    SYSTEM="Alpine"
    PACKAGE_INSTALL="apk add"
    PACKAGE_UPDATE="apk update"
elif [ -f /etc/debian_version ]; then
    SYSTEM=$(grep -Ei "ubuntu|debian" /etc/os-release | head -n 1 | awk -F'=' '{print $2}' | tr -d '"')
    [[ -z $SYSTEM ]] && SYSTEM="Debian"
    PACKAGE_INSTALL="apt -y install"
    PACKAGE_UPDATE="apt-get update"
else
    red "目前仅支持 Alpine, Debian 和 Ubuntu 系统！"
    exit 1
fi

ARCH=$(uname -m)

# --- 架构识别 ---
archAffix(){
    case "$ARCH" in
        x86_64 | amd64 ) echo 'amd64' ;;
        armv8 | arm64 | aarch64 ) echo 'arm64' ;;
        * ) red "不支持的CPU架构!" && exit 1 ;;
    esac
}

get_latest_ver(){
    latest_ver=$(curl -s https://api.github.com/repos/passeway/naiveproxy/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z $latest_ver ]] && latest_ver="v2.11.2"
    echo "$latest_ver"
}

restart_service(){
    if [[ -d /run/systemd/system ]] || [[ $SYSTEM != "Alpine" ]]; then
        systemctl restart caddy
    else
        rc-service caddy restart
    fi
}

installProxy(){
    cyan ">>> 正在为 $SYSTEM 安装必要依赖..."
    $PACKAGE_UPDATE
    if [[ $SYSTEM == "Alpine" ]]; then
        $PACKAGE_INSTALL curl wget sudo tar bash openrc
    else
        $PACKAGE_INSTALL curl wget sudo tar
    fi

    version=$(get_latest_ver)
    ver_num=${version#v}
    arch=$(archAffix)
    download_url="https://github.com/passeway/naiveproxy/releases/download/${version}/caddy_${ver_num}_linux_${arch}.tar.gz"
    
    cyan ">>> 正在下载 Caddy $version ($arch)..."
    wget -qO /tmp/caddy.tar.gz "$download_url"
    tar -zxf /tmp/caddy.tar.gz -C /tmp
    mv /tmp/caddy /usr/bin/caddy
    chmod +x /usr/bin/caddy
    rm -f /tmp/caddy.tar.gz

    mkdir -p /etc/caddy /root/naive
    echo ""
    read -rp " 请输入监听端口 [回车随机]：" proxyport
    [[ -z $proxyport ]] && proxyport=$(shuf -i 10000-65535 -n 1)
    read -rp " 请输入你的域名 (Domain)：" domain
    [[ -z $domain ]] && red " 错误: 必须提供域名！" && exit 1
    read -rp " 请输入用户名 [回车随机]：" proxyname
    [[ -z $proxyname ]] && proxyname=$(date +%s | md5sum | cut -c 1-8)
    read -rp " 请输入密码 [回车随机]：" proxypwd
    [[ -z $proxypwd ]] && proxypwd=$(date +%s%N | md5sum | cut -c 1-12)

    cat << EOF >/etc/caddy/Caddyfile
{
    http_port $(shuf -i 2000-8000 -n 1)
}
:$proxyport, $domain:$proxyport {
    tls admin@seewo.com
    route {
        forward_proxy {
            basic_auth $proxyname $proxypwd
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy https://www.bing.com {
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
        }
    }
}
EOF

    cat <<EOF > /root/naive/naive-client.json
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${proxyname}:${proxypwd}@${domain}:${proxyport}",
  "log": ""
}
EOF
    echo "naive+https://${proxyname}:${proxypwd}@${domain}:${proxyport}?padding=true#Naive" > /root/naive/naive-url.txt

    if [[ -d /run/systemd/system ]] || [[ $SYSTEM != "Alpine" ]]; then
        cat << EOF >/etc/systemd/system/caddy.service
[Unit]
Description=Caddy for NaiveProxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable caddy
        systemctl restart caddy
    else
        cat << 'EOF' > /etc/init.d/caddy
#!/sbin/openrc-run
name="caddy"
description="Caddy for NaiveProxy"
command="/usr/bin/caddy"
command_args="run --config /etc/caddy/Caddyfile --adapter caddyfile"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
supervisor="supervise-daemon"
EOF
        chmod +x /etc/init.d/caddy
        rc-update add caddy default
        rc-service caddy restart
    fi

    green "\n恭喜！NaiveProxy 安装成功！"
    showconf
}

changePort(){
    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        red "未检测到配置文件，请先执行安装！"
        return
    fi
    oldport=$(grep -oP '^:\d+' /etc/caddy/Caddyfile | head -n 1 | tr -d ':')
    yellow "\n当前正在使用的端口为: $oldport"
    read -rp " 请输入新端口 [回车随机]: " newport
    [[ -z $newport ]] && newport=$(shuf -i 10000-65535 -n 1)

    sed -i "s/:$oldport,/:$newport,/g" /etc/caddy/Caddyfile
    sed -i "s/:$oldport\"/:$newport\"/g" /root/naive/naive-client.json
    sed -i "s/:$oldport?/:$newport?/g" /root/naive/naive-url.txt

    restart_service
    green "\n端口修改成功！已更新为: $newport 并重启了服务。"
    showconf
}

uninstallProxy(){
    yellow "\n确定要卸载 NaiveProxy 吗？(y/n)"
    read -rp " 选择: " confirm
    [[ "$confirm" != "y" ]] && return
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop caddy && systemctl disable caddy
    else
        rc-service caddy stop && rc-update del caddy default
    fi
    rm -rf /etc/caddy /root/naive /usr/bin/caddy /etc/systemd/system/caddy.service /etc/init.d/caddy
    green "\n卸载已完成。系统已恢复干净状态。"
}

showconf(){
    echo -e "\n${CYAN}${BOLD}==================== 节点配置信息 ====================${PLAIN}"
    if [[ ! -f /root/naive/naive-client.json ]]; then
        red " 错误: 配置文件不存在，请确认是否已安装！"
    else
        yellow " [1] 节点 JSON 配置 (V2RayN / Clash):"
        echo -e "${RED}$(cat /root/naive/naive-client.json)${PLAIN}"
        echo ""
        yellow " [2] 节点分享链接 (Throne / V2RayN):"
        echo -e "${GREEN}$(cat /root/naive/naive-url.txt)${PLAIN}"
    fi
    echo -e "${CYAN}${BOLD}======================================================${PLAIN}"
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

menu(){
    while true; do
        clear
        echo -e "${CYAN}┌──────────────────────────────────────────────────┐${PLAIN}"
        echo -e "${CYAN}│${PLAIN}  ${BOLD}${YELLOW}NaiveProxy${PLAIN} 一键管理脚本 ${CYAN}│${PLAIN}  内核: ${BLUE}${BOLD}Caddy v2.x${PLAIN} ${CYAN}│${PLAIN}"
        echo -e "${CYAN}├──────────────────────────────────────────────────┤${PLAIN}"
        echo -e "${CYAN}│${PLAIN}  系统: ${GREEN}$SYSTEM${PLAIN}"
        echo -e "${CYAN}│${PLAIN}  架构: ${GREEN}$ARCH${PLAIN}"
        echo -e "${CYAN}└──────────────────────────────────────────────────┘${PLAIN}"
        echo ""
        echo -e "  ${BOLD}${BLUE}1.${PLAIN} ${BOLD}安装 NaiveProxy${PLAIN}"
        echo -e "  ${BOLD}${BLUE}2.${PLAIN} ${BOLD}查看 配置信息${PLAIN}"
        echo -e "  ${BOLD}${BLUE}3.${PLAIN} ${BOLD}修改 节点端口${PLAIN}"
        echo -e "  ${BOLD}${BLUE}4.${PLAIN} ${BOLD}${RED}卸载 NaiveProxy${PLAIN}"
        echo -e "  ${BOLD}${BLUE}0.${PLAIN} 退出脚本"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────${PLAIN}"
        read -rp " 请选择操作 [0-4] ：" answer
        case $answer in
            1) installProxy ;;
            2) showconf ;;
            3) changePort ;;
            4) uninstallProxy ;;
            0) exit 0 ;;
            *) red "请输入正确选项！" && sleep 2 ;;
        esac
    done
}

menu
