#!/bin/bash

# ShadowQUIC 自动化管理脚本 (跨平台多系统适配版)
# 支持架构: x86_64, aarch64
# 支持系统: Debian, Ubuntu (Systemd) / Alpine Linux (OpenRC)

APP_NAME="shadowquic"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowquic"
CONFIG_FILE="${CONFIG_DIR}/server.yaml"

# 检测当前系统名称
if [ -f /etc/os-release ]; then
    CURRENT_OS=$(source /etc/os-release && echo "$NAME")
else
    CURRENT_OS=$(uname -s)
fi

# 动态判断初始化服务类型
if [ -f /sbin/openrc-run ] || [ -d /etc/init.d ] && ! [ -x /bin/systemctl ]; then
    SERVICE_FILE="/etc/init.d/shadowquic"
else
    SERVICE_FILE="/etc/systemd/system/shadowquic@.service"
    SERVICE_INSTANCE="server"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

log_info() { echo -e "${YELLOW}$1${PLAIN}"; }
log_success() { echo -e "${GREEN}$1${PLAIN}"; }
log_error() { echo -e "${RED}$1${PLAIN}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本 (sudo)"
        exit 1
    fi
}

generate_random_8digit() {
    tr -dc '0-9' < /dev/urandom | fold -w 8 | head -n 1
}

install_binary() {
    local arch=$(uname -m)
    local download_url=""
    case $arch in
        x86_64) download_url="https://github.com/spongebob888/shadowquic/releases/latest/download/shadowquic-x86_64-linux-musl" ;;
        aarch64|arm64) download_url="https://github.com/spongebob888/shadowquic/releases/latest/download/shadowquic-aarch64-linux-musl" ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac
    
    log_info "检测到架构: $arch，正在下载最新版本..."
    curl -L -o "$INSTALL_DIR/$APP_NAME" "$download_url"
    if [ $? -ne 0 ]; then log_error "下载失败"; return 1; fi
    chmod +x "$INSTALL_DIR/$APP_NAME"
    log_success "二进制文件安装完成: $INSTALL_DIR/$APP_NAME"
}

# 获取服务运行状态
get_status() {
    if [ -x /bin/systemctl ] && [ -n "$SERVICE_INSTANCE" ]; then
        if systemctl is-active --quiet "shadowquic@${SERVICE_INSTANCE}"; then
            echo -e "${GREEN}运行中${PLAIN}"
        else
            echo -e "${RED}未运行${PLAIN}"
        fi
    else
        if pidof $APP_NAME >/dev/null; then
            echo -e "${GREEN}运行中${PLAIN}"
        else
            echo -e "${RED}未运行${PLAIN}"
        fi
    fi
}

# 创建系统服务文件
create_service() {
    if [ -x /bin/systemctl ] && [ -n "$SERVICE_INSTANCE" ]; then
        log_info "创建 systemd 服务..."
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ShadowQuic Server
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$APP_NAME -c $CONFIG_DIR/%i.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        log_info "创建 OpenRC 服务..."
        cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="shadowquic"
description="ShadowQuic Server"

command="$INSTALL_DIR/$APP_NAME"
command_args="-c $CONFIG_DIR/server.yaml"
pidfile="/run/\${RC_SVCNAME}.pid"

command_background=true
supervisor="supervise-daemon"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$SERVICE_FILE"
    fi
    log_success "服务创建完成"
}

# 启动服务通用抽象
start_service_engine() {
    if [ -x /bin/systemctl ] && [ -n "$SERVICE_INSTANCE" ]; then
        systemctl enable --now "shadowquic@${SERVICE_INSTANCE}"
    else
        rc-update add shadowquic default >/dev/null 2>&1
        rc-service shadowquic start
    fi
}

# 重启服务通用抽象
restart_service_engine() {
    if [ -x /bin/systemctl ] && [ -n "$SERVICE_INSTANCE" ]; then
        systemctl restart "shadowquic@${SERVICE_INSTANCE}"
        systemctl is-active --quiet "shadowquic@${SERVICE_INSTANCE}"
    else
        rc-service shadowquic restart
        pidof $APP_NAME >/dev/null
    fi
}

# 停止服务通用抽象
stop_service_engine() {
    if [ -x /bin/systemctl ] && [ -n "$SERVICE_INSTANCE" ]; then
        systemctl stop "shadowquic@${SERVICE_INSTANCE}" 2>/dev/null
        systemctl disable "shadowquic@${SERVICE_INSTANCE}" 2>/dev/null
    else
        rc-service shadowquic stop >/dev/null 2>&1
        rc-update del shadowquic default >/dev/null 2>&1
    fi
}

install_shadowquic() {
    check_root
    if [ -f "$INSTALL_DIR/$APP_NAME" ]; then
        log_info "ShadowQUIC 已安装，是否重新安装？(y/n)"
        read -r reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then return; fi
    fi

    mkdir -p "$CONFIG_DIR"
    install_binary || return 1
    
    PORT=$(shuf -i 10001-65535 -n 1)
    USERNAME=$(generate_random_8digit)
    PASSWORD=$(generate_random_8digit)
    SERVER_NAME="www.shopify.com"
    
    cat > "$CONFIG_FILE" <<EOF
inbound:
    type: shadowquic
    bind-addr: "[::]:${PORT}"
    users:
        - username: "${USERNAME}"
          password: "${PASSWORD}"
    jls-upstream:
        addr: "${SERVER_NAME}:443"
    alpn: ["h3"]
    congestion-control: bbr
    zero-rtt: true
    gso: true
outbound:
    type: direct
    dns-strategy: prefer-ipv4
log-level: "trace"
EOF

    create_service
    start_service_engine
    
    log_success "ShadowQUIC 安装完成！"
    show_config
    echo -e "\n按任意键返回主菜单..."
    read -n 1 -s
}

show_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在，请先安装"
        return
    fi
    
    echo "========================================"
    echo "          ShadowQUIC 服务端配置"
    echo "========================================"
    cat "$CONFIG_FILE"
    echo "========================================"
    
    PORT=$(grep 'bind-addr:' "$CONFIG_FILE" | grep -oE '[0-9]+')
    USERNAME=$(grep 'username:' "$CONFIG_FILE" | head -n 1 | awk -F '"' '{print $2}')
    PASSWORD=$(grep 'password:' "$CONFIG_FILE" | head -n 1 | awk -F '"' '{print $2}')
    
    local_ipv4=$(curl -s4m 5 api.ipify.org || curl -s4m 5 ip.sb)
    local_ipv6=$(curl -s6m 5 api.ipify.org || curl -s6m 5 ip.sb)

    echo -e "\n${GREEN}【IPv4 客户端配置 (client.yaml)】${PLAIN}"
    if [ -n "$local_ipv4" ]; then
        cat <<EOF
inbound:
    type: socks
    bind-addr: "127.0.0.1:12088"
outbound:
    type: shadowquic
    addr: "${local_ipv4}:${PORT}"
    username: "${USERNAME}"
    password: "${PASSWORD}"
    server-name: "${SERVER_NAME}"
    alpn: ["h3"]
    initial-mtu: 1300
    congestion-control: bbr
    zero-rtt: true
    gso: true
    over-stream: false
log-level: "trace"
EOF
    else
        log_error "未检测到公网 IPv4 地址"
    fi

    if [ -n "$local_ipv6" ]; then
        echo -e "\n${GREEN}【IPv6 客户端配置 (client.yaml)】${PLAIN}"
        cat <<EOF
inbound:
    type: socks
    bind-addr: "127.0.0.1:12088"
outbound:
    type: shadowquic
    addr: "[${local_ipv6}]:${PORT}"
    username: "${USERNAME}"
    password: "${PASSWORD}"
    server-name: "${SERVER_NAME}"
    alpn: ["h3"]
    initial-mtu: 1300
    congestion-control: bbr
    zero-rtt: true
    gso: true
    over-stream: false
log-level: "trace"
EOF
    fi
    echo "========================================"
}

change_port() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "请先安装 ShadowQUIC"
        return
    fi
    
    echo -n "请输入新端口 (10001-65535): "
    read -r NEW_PORT
    
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -le 10000 ] || [ "$NEW_PORT" -gt 65535 ]; then
        log_error "端口必须在 10001-65535 之间"
        return
    fi
    
    sed -i -E "s/(bind-addr:[[:space:]]*\"[^ \"]+):[0-9]+\"/\1:${NEW_PORT}\"/" "$CONFIG_FILE"
    restart_service_engine
    
    log_success "端口已修改为 ${NEW_PORT}"
    show_config
}

restart_service() {
    check_root
    if restart_service_engine; then
        log_success "服务重启成功"
    else
        log_error "服务重启失败"
    fi
}

update_shadowquic() {
    check_root
    log_info "正在更新 ShadowQUIC..."
    stop_service_engine
    sleep 1
    
    install_binary
    if [ $? -ne 0 ]; then
        log_error "更新下载失败，正在尝试拉起原服务..."
        start_service_engine
        return 1
    fi
    
    start_service_engine
    log_success "更新完成并重启服务"
}

uninstall_shadowquic() {
    check_root
    echo -n "确定要卸载 ShadowQUIC 吗？(y/n): "
    read -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then return; fi
    
    stop_service_engine
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    rm -f "$INSTALL_DIR/$APP_NAME"
    [ -x /bin/systemctl ] && systemctl daemon-reload
    
    log_success "ShadowQUIC 已完全卸载"
}

show_menu() {
    clear
    echo "========================================"
    echo "ShadowQUIC 管理脚本 "
    echo "当前系统: ${CURRENT_OS}"
    echo "运行状态: $(get_status)"
    echo "========================================"
    echo "1. 安装 ShadowQUIC"
    echo "2. 查看配置"
    echo "3. 修改端口"
    echo "4. 重启服务"
    echo "5. 更新程序"
    echo "6. 卸载 ShadowQUIC"
    echo "0. 退出"
    echo "========================================"
    echo -n "请输入选项 [0-6]: "
}

main() {
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) install_shadowquic ;;
            2) show_config ;;
            3) change_port ;;
            4) restart_service ;;
            5) update_shadowquic ;;
            6) uninstall_shadowquic ;;
            0) echo -e  "${YELLOW}感谢使用,后会有期！${PLAIN}"; exit 0 ;;
            *) log_error "无效选项，请重试" ;;
        esac
        echo -e "\n按任意键返回主菜单..."
        read -n 1 -s
    done
}

main
