#!/usr/bin/env bash
set -e

SERVICE="/etc/init.d/hysteria"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"

echo "▶ 停止 Hysteria 服务..."
if [ -f "$SERVICE" ]; then
    rc-service hysteria stop || true
    rc-update del hysteria default || true
fi

echo "▶ 删除 OpenRC 服务文件..."
rm -f "$SERVICE"

echo "▶ 删除 Hysteria 配置与证书..."
rm -rf "$WORKDIR"

echo "▶ 删除 Hysteria 可执行文件..."
rm -f "$BIN"

echo "▶ 清理 PID 文件..."
rm -f /run/hysteria.pid

echo
echo "=============================="
echo "✅ Hysteria2 已完全卸载"
echo "🧹 已移除以下内容："
echo "   - OpenRC 服务"
echo "   - 配置文件 / 证书"
echo "   - 可执行文件"
echo "=============================="
