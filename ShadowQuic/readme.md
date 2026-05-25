# 🚀 ShadowQuic 管理脚本（由Ai生成）

支持系统： Alpine / Debian / Ubuntu

支持架构： x86_64 / ARM64

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/a88wyzz/Alpine-Debian-Ubuntu-Hy2/main/ShadowQuic/shadowquic.sh)

```

# ✨ 功能

* 安装卸载 ShadowQuic
* 自动设置开机启动
* 输出 IPv4 / IPv6 客户端配置
* 支持 systemd / openrc 进程监视守护

# ⚠️ 注意

* ShadowQuic 使用 UDP 端口
* 新建一个client.yaml文件，把服务端输出的客户端配置复制进去
* 使用 shadowquic.exe -c client.yaml 批处理运行
* 默认监听 127.0.0.1:12088 可以在图形客户端新建socks5进行分流
