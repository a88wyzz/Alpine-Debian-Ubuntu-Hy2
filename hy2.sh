#!/usr/bin/env bash
set -e

### ===== 可修改参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
CONF="$WORKDIR/config.yaml"
PORT_FILE="$WORKDIR/port.txt"
SERVICE="/etc/init.d/hysteria"
### =====================

# 只支持 Alpine
if ! command -v apk >/dev/null 2>&1; then
    echo "❌ 只支持 Alpine 系统"
    exit 1
fi

echo "▶ 安装依赖..."
apk add --no-cache curl openssl ca-certificates bash >/dev/null

PASSWORD=$(openssl rand -hex 8)
mkdir -p "$WORKDIR"

# 随机端口（仅首次）
if [ ! -f "$PORT_FILE" ]; then
    PORT=$(( ( RANDOM % 40000 ) + 20000 ))
    echo "$PORT" > "$PORT_FILE"
else
    PORT=$(cat "$PORT_FILE")
fi

# 获取 IPv4
IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me)
[ -z "$IP" ] && { echo "❌ 获取 IPv4 失败"; exit 1; }

# 获取 IPv6
IPV6=$(curl -6 -s https://api64.ipify.org 2>/dev/null || true)

echo "▶ 下载 Hysteria2..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) FILE="hysteria-linux-amd64" ;;
  aarch64) FILE="hysteria-linux-arm64" ;;
  *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

curl -L -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/$FILE"
chmod +x "$BIN"

echo "▶ 生成自签证书..."
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$WORKDIR/key.pem" \
  -out "$WORKDIR/cert.pem" \
  -days 3650 \
  -subj "/CN=$SERVER_NAME"

echo "▶ 写入配置文件..."
cat > "$CONF" <<EOF
listen: :$PORT

tls:
  cert: $WORKDIR/cert.pem
  key: $WORKDIR/key.pem
  alpn:
    - h3

auth:
  type: password
  password: "$PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: https://$SERVER_NAME
    rewriteHost: true
EOF

echo "▶ 写入 OpenRC 服务（真进程守护）..."
cat > "$SERVICE" <<'EOF'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Server"

command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true

pidfile="/run/${name}.pid"
supervisor="supervise-daemon"

depend() {
    need net
}
EOF

chmod +x "$SERVICE"

rc-update del hysteria default 2>/dev/null || true
rc-update add hysteria default
rc-service hysteria restart

# 生成链接
LINK_V4="hy2://$PASSWORD@$IP:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#$TAG"

if [ -n "$IPV6" ]; then
  LINK_V6="hy2://$PASSWORD@[$IPV6]:$PORT/?sni=$SERVER_NAME&alpn=h3&insecure=1#${TAG}-IPv6"
fi

echo
echo "=============================="
echo "✅ Hysteria2 安装完成（Alpine）"
echo "📌 IPv4: $IP"
[ -n "$IPV6" ] && echo "📌 IPv6: $IPV6"
echo "🎲 端口: $PORT"
echo "🔐 密码: $PASSWORD"
echo "📎 v2rayN 链接："
echo "$LINK_V4"
[ -n "$LINK_V6" ] && echo "$LINK_V6"
echo "=============================="
