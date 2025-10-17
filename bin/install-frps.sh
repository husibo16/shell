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
用法: install-frps.sh [--version <FRP版本>]

该脚本会在当前服务器上安装并配置 frp 服务端 (frps)。
- 默认会自动获取 GitHub 上最新的稳定版本。
- 通过 FRPS_* 环境变量可以覆盖配置项。
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
install -m 0755 "$INSTALL_DIR/frps" /usr/local/bin/frps
install -m 0644 -D "$INSTALL_DIR/frps.toml" /etc/frp/frps.toml.default

mkdir -p /etc/frp
CONFIG_FILE=/etc/frp/frps.toml
if [[ ! -f "$CONFIG_FILE" ]]; then
  BIND_PORT=${FRPS_BIND_PORT:-7000}
  WEB_ADDR=${FRPS_WEB_ADDR:-${FRPS_DASHBOARD_ADDR:-"0.0.0.0"}}
  WEB_PORT=${FRPS_WEB_PORT:-${FRPS_DASHBOARD_PORT:-7500}}
  WEB_USER=${FRPS_WEB_USER:-${FRPS_DASHBOARD_USER:-admin}}
  WEB_PASS=${FRPS_WEB_PASS:-${FRPS_DASHBOARD_PASS:-changeme}}
  AUTH_METHOD=${FRPS_AUTH_METHOD:-token}
  AUTH_TOKEN=${FRPS_TOKEN:-changeme}
  LOG_PATH=${FRPS_LOG_PATH:-${FRPS_LOG_TO:-/var/log/frps.log}}
  LOG_LEVEL=${FRPS_LOG_LEVEL:-info}
  ENABLE_PROMETHEUS=${FRPS_ENABLE_PROMETHEUS:-true}

  if [[ ! "$ENABLE_PROMETHEUS" =~ ^(true|false)$ ]]; then
    echo "[警告] FRPS_ENABLE_PROMETHEUS 仅支持 true/false，当前值 '$ENABLE_PROMETHEUS' 已被忽略，默认使用 true。"
    ENABLE_PROMETHEUS=true
  fi

  cat > "$CONFIG_FILE" <<CONF
# frps 配置文件
# 如需调整端口、认证等参数，可在运行脚本前设置 FRPS_* 环境变量，或直接编辑此文件。
bindPort = ${BIND_PORT}

webServer.addr = "${WEB_ADDR}"
webServer.port = ${WEB_PORT}
webServer.user = "${WEB_USER}"
webServer.password = "${WEB_PASS}"

auth.method = "${AUTH_METHOD}"
auth.token = "${AUTH_TOKEN}"

enablePrometheus = ${ENABLE_PROMETHEUS}

log.to = "${LOG_PATH}"
log.level = "${LOG_LEVEL}"
CONF
  chmod 600 "$CONFIG_FILE"
  echo "[信息] 已生成默认配置文件: $CONFIG_FILE"
  if [[ "$AUTH_TOKEN" == "changeme" ]]; then
    echo "[警告] 当前认证 token 为默认值 changeme，请尽快修改以确保安全。"
  fi
else
  echo "[信息] 已检测到现有配置，跳过覆盖: $CONFIG_FILE"
fi

cat > /etc/systemd/system/frps.service <<'SERVICE'
[Unit]
Description=FRP Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now frps.service

echo "[完成] frps 已安装并启动。请根据需要修改 /etc/frp/frps.toml 并重启服务。"
