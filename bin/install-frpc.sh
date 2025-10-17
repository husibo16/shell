#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "[错误] 请使用 root 权限运行此脚本。" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[错误] 当前系统缺少 systemctl，暂不支持自动配置 systemd 服务。" >&2
  exit 1
fi

usage() {
  cat <<'USAGE'
用法: install-frpc.sh [--version <FRP版本>]

该脚本会在当前服务器上安装并配置 frp 客户端 (frpc)。
- 默认自动获取 GitHub 上最新的稳定版本。
- 通过 FRPC_* 环境变量可以覆盖常用配置项。
USAGE
}

FRP_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      shift
      FRP_VERSION=${1:-}
      if [[ -z "$FRP_VERSION" ]]; then
        echo "[错误] --version 选项需要指定版本号，例如 --version 0.58.1" >&2
        exit 1
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[错误] 未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "[错误] 未找到 curl，请先安装 curl。" >&2
  exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH=amd64
    ;;
  aarch64|arm64)
    ARCH=arm64
    ;;
  armv7l|armv7)
    ARCH=arm
    ;;
  *)
    echo "[错误] 暂不支持的架构: $ARCH" >&2
    exit 1
    ;;
esac

if [[ -z "$FRP_VERSION" ]]; then
  echo "[信息] 正在获取 frp 最新版本..."
  RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/fatedier/frp/releases/latest")
  if [[ -z "$RELEASE_JSON" ]]; then
    echo "[错误] 无法从 GitHub 获取 frp 最新版本，请检查网络连接或使用 --version 手动指定。" >&2
    exit 1
  fi
  FRP_VERSION=$(grep -m1 '"tag_name"' <<<"$RELEASE_JSON" | sed -E 's/.*"tag_name": "v?([0-9.]+)".*/\1/')
  if [[ -z "$FRP_VERSION" ]]; then
    echo "[错误] 未能解析 frp 最新版本号，请使用 --version 手动指定。" >&2
    exit 1
  fi
fi

DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[信息] 下载 frp v${FRP_VERSION} (${ARCH})..."
if ! curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/frp.tar.gz"; then
  echo "[错误] 下载失败，请检查版本号是否正确。" >&2
  exit 1
fi

tar -xzf "$TMP_DIR/frp.tar.gz" -C "$TMP_DIR"
INSTALL_DIR="${TMP_DIR}/frp_${FRP_VERSION}_linux_${ARCH}"
install -m 0755 "$INSTALL_DIR/frpc" /usr/local/bin/frpc
install -m 0644 -D "$INSTALL_DIR/frpc.toml" /etc/frp/frpc.toml.default

mkdir -p /etc/frp
CONFIG_FILE=/etc/frp/frpc.toml
if [[ ! -f "$CONFIG_FILE" ]]; then
  SERVER_ADDR=${FRPC_SERVER_ADDR:-example.com}
  SERVER_PORT=${FRPC_SERVER_PORT:-7000}
  AUTH_METHOD=${FRPC_AUTH_METHOD:-token}
  AUTH_TOKEN=${FRPC_TOKEN:-changeme}
  TUNNEL_NAME=${FRPC_TUNNEL_NAME:-web}
  LOCAL_PORT=${FRPC_LOCAL_PORT:-80}
  REMOTE_PORT=${FRPC_REMOTE_PORT:-6000}

  cat > "$CONFIG_FILE" <<CONF
# frpc 配置文件
# 在运行脚本前设置 FRPC_* 环境变量可以覆盖默认值，或直接编辑此文件。
serverAddr = "${SERVER_ADDR}"
serverPort = ${SERVER_PORT}

auth.method = "${AUTH_METHOD}"
auth.token = "${AUTH_TOKEN}"

[[proxies]]
name = "${TUNNEL_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
remotePort = ${REMOTE_PORT}
CONF
  chmod 600 "$CONFIG_FILE"
  echo "[信息] 已生成默认配置文件: $CONFIG_FILE"
  if [[ "$SERVER_ADDR" == "example.com" ]]; then
    echo "[警告] 当前 serverAddr 仍为示例值 example.com，请修改为实际的 frps 公网地址。"
  fi
  if [[ "$AUTH_TOKEN" == "changeme" ]]; then
    echo "[警告] 当前认证 token 为默认值 changeme，请尽快修改以确保安全。"
  fi
else
  echo "[信息] 已检测到现有配置，跳过覆盖: $CONFIG_FILE"
fi

cat > /etc/systemd/system/frpc.service <<'SERVICE'
[Unit]
Description=FRP Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now frpc.service

echo "[完成] frpc 已安装并启动。请根据需要修改 /etc/frp/frpc.toml 并重启服务。"
