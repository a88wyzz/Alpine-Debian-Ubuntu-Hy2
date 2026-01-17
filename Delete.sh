#!/usr/bin/env bash
set -e

WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
OPENRC_SERVICE="/etc/init.d/hysteria"
SYSTEMD_SERVICE="/etc/systemd/system/hysteria.service"
PIDFILE="/run/hysteria.pid"

# 必须 root
if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 运行"
    exit 1
fi

# 判断系统
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
else
    echo "❌ 不支持的系统"
    exit 1
fi

echo "▶ 当前系统: $OS"
echo "▶ 开始卸载 Hysteria2..."

# ===== 停止并移除服务 =====
if [ "$OS" = "alpine" ]; then
    if [ -f "$OPENRC_SERVICE" ]; then
        echo "▶ 停止 OpenRC 服务..."
        rc-service hysteria stop || true
        rc-update del hysteria default || true
        rm -f "$OPENRC_SERVICE"
    fi
else
    if [ -f "$SYSTEMD_SERVICE" ]; then
        echo "▶ 停止 systemd 服务..."
        systemctl stop hysteria || true
        systemctl disable hysteria || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload
    fi
fi

# ===== 清理文件 =====
echo "▶ 删除配置与证书..."
rm -rf "$WORKDIR"

echo "▶ 删除可执行文件..."
rm -f "$BIN"

echo "▶ 清理 PID 文件..."
rm -f "$PIDFILE"

echo
echo "=============================="
echo "✅ Hysteria2 已完全卸载"
echo "🖥 系统: $OS"
echo "🧹 已清理内容："
echo "   - 服务（OpenRC / systemd）"
echo "   - 配置与证书 (/etc/hysteria)"
echo "   - 可执行文件 (/usr/local/bin/hysteria)"
echo "=============================="
