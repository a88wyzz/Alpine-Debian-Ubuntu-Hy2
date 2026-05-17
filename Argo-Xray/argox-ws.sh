#!/bin/bash
# onekey argox - WS 版本 (仅支持 Alpine / Debian / Ubuntu)

# ====================== 系统检测 ======================
if ! grep -qiE 'alpine|debian|ubuntu' /etc/os-release; then
    echo -e "\033[0;31m不支持的系统！本脚本仅支持 Alpine、Debian、Ubuntu\033[0m"
    exit 1
fi

linux_os=("Debian" "Ubuntu" "Alpine")
linux_update=("apt update" "apt update" "apk update")
linux_install=("apt -y install" "apt -y install" "apk add -f")
n=0

# 定义颜色变量
green='\033[0;32m'
cyan='\033[0;36m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

# 创建运行目录
mkdir -p /usr/local/argox
mkdir -p /usr/local/cloudflare

for i in `echo ${linux_os[@]}`
do
    if [ "$i" == "$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}')" ]
    then
        break
    else
        n=$[$n+1]
    fi
done

if [ $n == 3 ]; then
    echo 当前系统没有适配，默认使用APT
    n=0
fi

# 环境检查
for tool in unzip curl; do
    if [ -z "$(type -P $tool)" ]; then
        ${linux_update[$n]}
        ${linux_install[$n]} $tool
    fi
done

# Alpine 特殊依赖
if grep -qi Alpine /etc/os-release; then
    apk add gcompat
fi

function quicktunnel(){
cd /tmp
rm -rf xray cloudflared xray.zip
case "$(uname -m)" in
    x86_64 | x64 | amd64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
    ;;
    armv8 | arm64 | aarch64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared
    ;;
    * ) echo "架构不支持"; exit ;;
esac

unzip -j xray.zip xray -d ./ >/dev/null 2>&1
chmod +x cloudflared xray
mv xray /usr/local/argox/
mv cloudflared /usr/local/cloudflare/
rm -rf xray.zip
cd /usr/local/argox/

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath=$(echo $uuid | awk -F- '{print $1}')
port=$[$RANDOM+10000]

cat>config.json<<EOF
{
    "inbounds": [{"port": $port,"listen": "localhost","protocol": "vless","settings": {"decryption": "none","clients": [{"id": "$uuid"}]},"streamSettings": {"network": "ws","wsSettings": {"path": "$urlpath"}}}],
    "outbounds": [{"protocol": "freedom","settings": {}}]
}
EOF

./xray run>/dev/null 2>&1 &
/usr/local/cloudflare/cloudflared tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version $ips --protocol http2 >argo.log 2>&1 &
sleep 1
n=0
while true; do
    n=$[$n+1]
    clear
    echo 等待 Argo 生成地址... $n 秒
    argo=$(cat argo.log | grep trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
    if [ $n == 15 ]; then
        pkill -9 -f cloudflared; rm -rf argo.log; clear; echo "超时重试..."
        /usr/local/cloudflare/cloudflared tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version $ips --protocol http2 >argo.log 2>&1 &
        n=0
    elif [ -n "$argo" ]; then
        rm -rf argo.log; break
    fi
    sleep 1
done

clear
echo -e vless链接已经生成, www.shopify.com 可替换为CF优选域名或IP'\n' > argox.txt
echo -e "${green}vless://${uuid}@www.shopify.com:443?encryption=none&security=tls&type=ws&host=${argo}&path=${urlpath}&sni=${argo}#Argox-TLS${plain}" >> argox.txt
echo -e '\n'端口 443 可改为 2053 2083 2087 2096 8443'\n' >> argox.txt
echo -e "${green}vless://${uuid}@www.shopify.com:80?encryption=none&security=none&type=ws&host=${argo}&path=${urlpath}#Argox${plain}" >> argox.txt
echo -e '\n'端口 80 可改为 8080 8880 2052 2082 2086 2095 >> argox.txt

cat argox.txt
echo -e '\n'信息已经保存在 /usr/local/argox/argox.txt
echo -e 注意：临时模式重启服务器后失效！！！
}

function installtunnel(){
cd /tmp
rm -rf xray cloudflared xray.zip
case "$(uname -m)" in
    x86_64 | x64 | amd64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
    ;;
    armv8 | arm64 | aarch64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared
    ;;
esac

unzip -j xray.zip xray -d ./ >/dev/null 2>&1
chmod +x cloudflared xray
mv xray /usr/local/argox/
mv cloudflared /usr/local/cloudflare/
rm -rf xray.zip
cd /usr/local/argox/

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath=$(echo $uuid | awk -F- '{print $1}')
port=$[$RANDOM+10000]

cat>config.json<<EOF
{
    "inbounds": [{"port": $port,"listen": "localhost","protocol": "vless","settings": {"decryption": "none","clients": [{"id": "$uuid"}]},"streamSettings": {"network": "ws","wsSettings": {"path": "$urlpath"}}}],
    "outbounds": [{"protocol": "freedom","settings": {}}]
}
EOF

/usr/local/cloudflare/cloudflared --edge-ip-version $ips --protocol http2 tunnel login
/usr/local/cloudflare/cloudflared --edge-ip-version $ips --protocol http2 tunnel list >argo.log 2>&1
clear
echo -e ARGO TUNNEL当前已经绑定的服务如下'\n'
sed 1,2d argo.log | awk '{print $2}'
read -p "输入绑定域名的完整二级域名: " domain
name=$(echo $domain | awk -F\. '{print $1}')
/usr/local/cloudflare/cloudflared --edge-ip-version $ips --protocol http2 tunnel create "$name" >/dev/null 2>&1
/usr/local/cloudflare/cloudflared --edge-ip-version $ips --protocol http2 tunnel route dns --overwrite-dns "$name" "$domain" >/dev/null 2>&1

tunneluuid=$(/usr/local/cloudflare/cloudflared tunnel list | grep "$name" | awk '{print $1}')
if [ -z "$tunneluuid" ]; then echo -e "${red}未能获取隧道ID，请检查登录状态${plain}"; exit 1; fi

echo -e vless链接已经生成, www.shopify.com 可替换为CF优选域名或IP'\n' > argox.txt
echo -e "${green}vless://${uuid}@www.shopify.com:443?encryption=none&security=tls&type=ws&host=${domain}&path=${urlpath}&sni=${domain}#Argox-TLS${plain}" >> argox.txt
echo -e '\n'端口 443 可改为 2053 2083 2087 2096 8443'\n' >> argox.txt
echo -e "${green}vless://${uuid}@www.shopify.com:80?encryption=none&security=none&type=ws&host=${domain}&path=${urlpath}#Argox${plain}" >> argox.txt
echo -e '\n'端口 80 可改为 8080 8880 2052 2082 2086 2095'\n' >> argox.txt

cat>/usr/local/cloudflare/config.yaml<<EOF
tunnel: ${tunneluuid}
credentials-file: /root/.cloudflared/${tunneluuid}.json

ingress:
  - hostname: ${domain}
    service: http://localhost:${port}
  - service: http_status:404
EOF

if grep -qi Alpine /etc/os-release; then
    echo -e "${cyan}检测到 Alpine 系统，正在创建服务...${plain}"
    cat > /etc/init.d/argox <<'EOF'
#!/sbin/openrc-run
name="argox"
command="/usr/local/cloudflare/cloudflared"
command_args="tunnel --config /usr/local/cloudflare/config.yaml run ${name}"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true

depend() { need net; }

start_post() {
    /usr/local/argox/xray run -config /usr/local/argox/config.json >/dev/null 2>&1 &
}
EOF
    chmod +x /etc/init.d/argox
    rc-update add argox default
    rc-service argox restart
else
    cat>/lib/systemd/system/argox-cf.service<<EOF
[Unit]
Description=ArgoX Cloudflared
After=network.target
[Service]
ExecStart=/usr/local/cloudflare/cloudflared --edge-ip-version $ips --protocol http2 tunnel --config /usr/local/cloudflare/config.yaml run "$name"
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    cat>/lib/systemd/system/argox-xray.service<<EOF
[Unit]
Description=ArgoX Xray
After=network.target
[Service]
ExecStart=/usr/local/argox/xray run -config /usr/local/argox/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now argox-cf argox-xray >/dev/null 2>&1
fi
clear
cat argox.txt
}

# --- 主菜单 ---
clear
# 检测运行状态
argostatus=$(ps -ef | grep cloudflared | grep -v grep | wc -l)
xraystatus=$(ps -ef | grep xray | grep -v grep | wc -l)

if [ -f "/usr/local/cloudflare/config.yaml" ]; then
    mode_type="${green}固定隧道${plain}"
else
    mode_type="${yellow}临时隧道${plain}"
fi

echo -e "${cyan}======================================================${plain}"
echo -e "  Argo-Xray 管理脚本 - (Websocket)"
echo -e "  当前系统：${yellow}$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)${plain}"
echo -n "  Argo 状态: "
if [ $argostatus -gt 0 ]; then echo -ne "${green}● running${plain} ($mode_type)"; else echo -ne "${red}○ stop${plain}"; fi
echo -n "  |  Xray 状态: "
if [ $xraystatus -gt 0 ]; then echo -e "${green}● running${plain}"; else echo -e "${red}○ stop${plain}"; fi

echo -e "${cyan}======================================================${plain}"
echo -e "  ${green}[1]${plain}  临时隧道 无需Cloudflare域名 重启失效"
echo -e "  ${green}[2]${plain}  固定隧道 需要Cloudflare域名 重启正常"
echo -e "  ${green}[3]${plain}  查看当前节点链接"
echo -e "  ${green}[4]${plain}  卸载服务"
echo -e "  ${green}[0]${plain}  退出脚本"
echo -e "${cyan}======================================================${plain}"

read -p " 请输入数字选择 [0-4]: " mode
case "$mode" in
    1) ips=4; isp=$(curl -4 -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g'); quicktunnel ;;
    2) ips=4; isp=$(curl -4 -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g'); installtunnel ;;
    3) clear; [ -f /usr/local/argox/argox.txt ] && cat /usr/local/argox/argox.txt || echo "未找到链接" ;;
    4) 
        echo "正在卸载..."
        if [ -f "/lib/systemd/system/argox-cf.service" ]; then
            systemctl disable --now argox-cf argox-xray >/dev/null 2>&1
            rm -f /lib/systemd/system/argox-cf.service /lib/systemd/system/argox-xray.service
            systemctl daemon-reload
        fi
        if [ -f "/etc/init.d/argox" ]; then
            rc-service argox stop 2>/dev/null
            rc-update del argox 2>/dev/null
            rm -f /etc/init.d/argox
        fi
        pkill -9 -f xray >/dev/null 2>&1
        pkill -9 -f cloudflared >/dev/null 2>&1
        rm -f /etc/local.d/argox.start /usr/bin/argox /usr/local/argox/argox.sh
        rm -rf /usr/local/argox /usr/local/cloudflare /root/.cloudflared
        echo "卸载完成。" ;;
    *) exit ;;
esac
