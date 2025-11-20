#!/usr/bin/env bash
# ============================================================
# WireGuard 一键服务端（多客户端 + 自动守护 + 加速 + 监控 + 导出 + 密钥重置 + 卸载）
# 模式: 超级节点（客户端全流量走服务器 + 客户端互通）
# 适配系统: Debian / Ubuntu
# 作者: 胡博涵 实践版（2025）
# 版本: v1.5-intelligent（MTU 实测 + 分流 + 智能 DNS）
# ============================================================

# ---- Bash 强制守护（使用 POSIX 语法确保在 dash/busybox 下也能复用）----
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v /bin/bash >/dev/null 2>&1; then
    exec /bin/bash "$0" "$@"
  elif command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    printf "[错误] 当前 shell (%s) 不支持脚本所需的 bash 语法，请安装 bash 后以 'bash %s' 运行。\n" "${SHELL:-unknown}" "$0" >&2
    exit 1
  fi
fi

set -euo pipefail
LOG_FILE="/var/log/wireguard_server_install.log"
export DEBIAN_FRONTEND=noninteractive

WG_IF="wg0"
WG_NET="10.10.10.0/24"
WG_SERVER_IP="10.10.10.1"
WG_DIR="/etc/wireguard"
WG_CLIENT_DIR="${WG_DIR}/clients"
WG_PORT_FILE="${WG_DIR}/listen_port"
WG_MANAGER_CONF="${WG_DIR}/wg-manager.conf"   # 预留给以后集成 Telegram 等配置
WG_MTU_FILE="${WG_DIR}/mtu"
WG_DNS_FILE="${WG_DIR}/dns_best"              # 智能 DNS 缓存

# -------------------- 彩色输出 & 日志 --------------------
info()    { echo -e "\033[1;34m[信息]\033[0m $1"; }
success() { echo -e "\033[1;32m[成功]\033[0m $1"; }
warn()    { echo -e "\033[1;33m[警告]\033[0m $1"; }
error()   { echo -e "\033[1;31m[错误]\033[0m $1"; }

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'error "脚本执行出错，请查看日志：${LOG_FILE}"' ERR

if [[ $EUID -ne 0 ]]; then
  error "必须以 root 身份运行。"
  exit 1
fi

# -------------------- 基础工具函数 --------------------
ensure_cmd() {
  # 确保命令存在，否则安装
  local cmd="$1"
  local pkg="${2:-$1}"
  if ! command -v "$cmd" &>/dev/null; then
    info "安装依赖：$pkg ..."
    apt update -y
    apt install -y "$pkg"
  fi
}

detect_wan_if() {
  ip route get 8.8.8.8 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
    | head -n1
}

# 智能获取服务器公网 IP（自动识别 NAT + 多网卡）
detect_public_ip() {
  local ip
  # 方法 1：出口路由
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
  # 过滤内网 + CGNAT
  if [[ -n "$ip" ]] && \
     ! [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
    echo "$ip"
    return
  fi

  # 方法 2：外网探测（如果 curl 存在）
  if command -v curl &>/dev/null; then
    for api in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
      ip=$(curl -4s --max-time 3 "$api" || true)
      if [[ -n "$ip" ]]; then
        echo "$ip"
        return
      fi
    done
  fi

  echo ""
}

# 动态检测 WireGuard 监听端口
detect_wg_port() {
  local port=""
  if [[ -f "${WG_DIR}/${WG_IF}.conf" ]]; then
    port=$(awk '/ListenPort/ {print $3}' "${WG_DIR}/${WG_IF}.conf" | head -n1 || true)
  fi
  if [[ -z "$port" && -f "$WG_PORT_FILE" ]]; then
    port=$(cat "$WG_PORT_FILE" 2>/dev/null || true)
  fi
  echo "$port"
}

# 智能探测 MTU（按服务器出口估算 + ping 探测，客户端可覆盖）
detect_optimal_mtu() {
  local existing mtu_candidate wan_if base_mtu wg_overhead=80

  # 如果已有缓存则直接使用，避免每次重复探测
  if [[ -f "$WG_MTU_FILE" ]]; then
    existing=$(cat "$WG_MTU_FILE" 2>/dev/null || true)
  fi
  if [[ -n "${existing:-}" ]]; then
    echo "$existing"
    return
  fi

  wan_if=$(detect_wan_if)
  if [[ -z "$wan_if" ]]; then
    wan_if=$(ip route | awk '/default/ {print $5; exit}')
  fi

  base_mtu=$(ip -o link show "$wan_if" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
  [[ -z "$base_mtu" ]] && base_mtu=1500

  mtu_candidate=$((base_mtu - wg_overhead))
  [[ $mtu_candidate -lt 1280 ]] && mtu_candidate=1280

  # 使用 ping + DF 做路径 MTU 探测，失败则返回估算值
  if command -v ping &>/dev/null; then
    local test_ips=("1.1.1.1" "8.8.8.8")
    local ip size
    for ip in "${test_ips[@]}"; do
      if ping -4 -c1 -W1 "$ip" >/dev/null 2>&1; then
        size=$mtu_candidate
        while [[ $size -ge 1280 ]]; do
          # ICMP 头部 28 字节
          if ping -4 -c1 -W1 -M do -s $((size-28)) "$ip" >/dev/null 2>&1; then
            echo "$size"
            return
          fi
          size=$((size-10))
        done
      fi
    done
  fi

  echo "$mtu_candidate"
}

get_or_detect_mtu() {
  local mtu
  mtu=$(detect_optimal_mtu)
  echo "$mtu" > "$WG_MTU_FILE"
  echo "$mtu"
}

# 智能 DNS：测试一批常见 DNS，选延迟最低的两台
detect_best_dns() {
  local existing
  if [[ -f "$WG_DNS_FILE" ]]; then
    existing=$(cat "$WG_DNS_FILE" 2>/dev/null || true)
  fi
  if [[ -n "${existing:-}" ]]; then
    echo "$existing"
    return
  fi

  local candidates=(
    "1.1.1.1"
    "1.0.0.1"
    "8.8.8.8"
    "8.8.4.4"
    "9.9.9.9"
    "114.114.114.114"
    "223.5.5.5"
    "223.6.6.6"
  )
  local results=()
  local ip rtt line

  if ! command -v ping >/dev/null 2>&1; then
    echo "1.1.1.1, 8.8.8.8"
    return
  fi

  for ip in "${candidates[@]}"; do
    line=$(ping -c1 -W1 "$ip" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
    if [[ -n "$line" ]]; then
      results+=("$line $ip")
    fi
  done

  if ((${#results[@]} == 0)); then
    echo "1.1.1.1, 8.8.8.8"
    return
  fi

  local sorted first second
  sorted=$(printf '%s\n' "${results[@]}" | sort -n)
  first=$(awk 'NR==1{print $2}' <<<"$sorted")
  second=$(awk 'NR==2{print $2}' <<<"$sorted")

  if [[ -n "$second" ]]; then
    echo "${first}, ${second}"
  else
    echo "${first}"
  fi
}

get_or_detect_dns() {
  local dns
  dns=$(detect_best_dns)
  echo "$dns" > "$WG_DNS_FILE"
  echo "$dns"
}

SERVER_PUBLIC_IP=$(detect_public_ip)
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  warn "无法自动识别公网 IP，后续客户端配置中的 Endpoint 可能需要手动修正。"
  SERVER_PUBLIC_IP="0.0.0.0"
else
  success "自动识别公网 IP：${SERVER_PUBLIC_IP}"
fi

# -------------------- 端口 / IP 分配 --------------------
get_or_create_port() {
  local port
  port=$(detect_wg_port)

  if [[ -z "${port:-}" ]]; then
    port=$(shuf -i 20000-60000 -n 1)
  fi

  # 检测端口冲突（UDP）
  while ss -lun | awk 'NR>1 {print $5}' | grep -q ":${port}$"; do
    warn "UDP 端口 ${port} 已被占用，重新随机一个..."
    port=$(shuf -i 20000-60000 -n 1)
  done

  echo "$port" > "$WG_PORT_FILE"
  echo "$port"
}

next_client_ip() {
  mkdir -p "$WG_CLIENT_DIR"
  local used_ips base_prefix="10.10.10"
  used_ips=$(grep -R "^Address" "$WG_CLIENT_DIR" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)
  local i candidate
  for i in $(seq 2 254); do
    candidate="${base_prefix}.${i}"
    if ! grep -q "$candidate" <<< "$used_ips"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# -------------------- 内核与系统优化 --------------------
ensure_kernel_modules() {
  info "检测 WireGuard 内核模块..."
  if ! lsmod | grep -q wireguard; then
    warn "未检测到 wireguard 内核模块，尝试加载..."
    modprobe wireguard 2>/dev/null || true
  fi

  if ! lsmod | grep -q wireguard; then
    warn "仍未加载 wireguard 模块，将尝试安装 DKMS 版本（旧内核可能需要）..."
    apt update -y || true
    apt install -y wireguard-dkms "linux-headers-$(uname -r)" || true
    modprobe wireguard 2>/dev/null || true
  fi
}

apply_sysctl_optimizations() {
  info "应用内核网络优化（转发 + BBR）..."
  cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.netfilter.nf_conntrack_max=262144
net.ipv4.tcp_mtu_probing=1
EOF
  sysctl --system >/dev/null 2>&1 || true
}

# -------------------- nftables 配置（动态端口 + 动态网卡） --------------------
configure_nftables() {
  info "配置 nftables 防火墙..."

  # 备份原有配置，避免覆盖生产环境已有的防火墙规则
  if [[ -f /etc/nftables.conf ]]; then
    local backup="/etc/nftables.conf.bak-$(date +%F-%H%M%S)"
    cp /etc/nftables.conf "$backup"
    info "已备份现有 nftables 配置到：${backup}"
  fi

  local WAN_IF WG_PORT
  WAN_IF=$(detect_wan_if)
  if [[ -z "$WAN_IF" ]]; then
    warn "未能检测到默认出口网卡，使用 eth0 作为默认出口。"
    WAN_IF="eth0"
  fi
  WG_PORT=$(detect_wg_port)
  if [[ -z "$WG_PORT" ]]; then
    WG_PORT=$(get_or_create_port)
  fi

  cat > /etc/nftables.conf <<EOF
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept

    # WireGuard UDP 端口（动态自动识别）
    udp dport ${WG_PORT} accept

    # 允许来自 WireGuard 隧道的流量
    iif "${WG_IF}" accept

    # 允许 Ping
    icmp type echo-request accept
    icmp type echo-reply accept

    # 已建立连接
    ct state established,related accept

    # 允许 SSH
    tcp dport 22 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy accept;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    # 动态适配出口网卡
    ip saddr ${WG_NET} oif "${WAN_IF}" masquerade
  }
}
EOF

  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl restart nftables
  success "nftables 防火墙规则已动态适配并应用。"
}

# -------------------- 自动守护 --------------------
setup_wg_monitor() {
  info "配置 WireGuard 自动守护..."
  cat > /usr/local/bin/wg-monitor.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WG_IF="wg0"
LOG_FILE="/var/log/wg-monitor.log"
umask 077
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

if ! wg show "${WG_IF}" >/dev/null 2>&1; then
  log "检测到 ${WG_IF} 未运行，尝试启动..."
  if output=$(wg-quick up "${WG_IF}" 2>&1); then
    log "wg-quick up 成功。"
    log "$output"
  else
    log "wg-quick up 失败：${output}"
    exit 1
  fi
else
  handshake=$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk 'NR>1 {print $2}' | sort -nr | head -n1)
  if [[ -z "${handshake:-}" || "${handshake}" -eq 0 ]]; then
    log "${WG_IF} 目前没有活跃握手，可能所有客户端均离线。"
  fi
fi

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  log "警告：systemd 单元 wg-quick@${WG_IF} 未处于 active 状态。"
fi
EOF
  chmod +x /usr/local/bin/wg-monitor.sh

  cat > /etc/systemd/system/wg-monitor.service <<EOF
[Unit]
Description=WireGuard Monitor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-monitor.sh
EOF

  cat > /etc/systemd/system/wg-monitor.timer <<EOF
[Unit]
Description=Run WireGuard Monitor every minute

[Timer]
OnBootSec=15
OnUnitActiveSec=60
Unit=wg-monitor.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now wg-monitor.timer >/dev/null 2>&1 || true
  success "WireGuard 自动守护已启用。"
}

# -------------------- 初始化 WireGuard 服务端 --------------------
init_server() {
  info "检测系统环境..."
  ensure_cmd lsb_release lsb-release
  local DISTRO CODENAME
  DISTRO=$(lsb_release -is)
  CODENAME=$(lsb_release -cs)
  success "系统识别为：${DISTRO} (${CODENAME})"

  info "安装核心依赖..."
  apt update -y
  apt install -y wireguard resolvconf nftables curl qrencode zip netcat-traditional

  ensure_kernel_modules
  apply_sysctl_optimizations

  mkdir -p "$WG_DIR" "$WG_CLIENT_DIR"

  info "生成服务端密钥..."
  if [[ ! -f "${WG_DIR}/server_private.key" ]] || [[ ! -f "${WG_DIR}/server_public.key" ]]; then
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
  fi
  local SERVER_PRIV SERVER_PUB
  SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")
  success "服务端公钥：${SERVER_PUB}"

  local WG_PORT WG_MTU
  WG_PORT=$(get_or_create_port)
  WG_MTU=1280
  success "WireGuard 监听端口：${WG_PORT}/udp"
  success "服务端 MTU 固定为：${WG_MTU}"

  info "写入 ${WG_DIR}/${WG_IF}.conf ..."
  cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = ${WG_MTU}
SaveConfig = true
EOF

  chmod 600 "${WG_DIR}/${WG_IF}.conf"

  info "清理可能残留的接口 ${WG_IF} ..."
  ip link del "${WG_IF}" 2>/dev/null || true

  info "启用并启动 WireGuard 服务..."
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IF}"

  configure_nftables
  setup_wg_monitor

  # 创建全局 wg-admin 命令
  local SCRIPT_REAL
  SCRIPT_REAL=$(realpath "$0")
  cat > /usr/local/bin/wg-admin <<EOF
#!/usr/bin/env bash
bash "${SCRIPT_REAL}"
EOF
  chmod +x /usr/local/bin/wg-admin
  success "已创建全局管理命令：wg-admin（在任意目录运行即可进入菜单）"

  success "WireGuard 服务端初始化完成！"
  echo "-----------------------------------------"
  echo " 服务端公网 IP : ${SERVER_PUBLIC_IP}"
  echo " 服务端内网 IP : ${WG_SERVER_IP}"
  echo " 监听端口      : ${WG_PORT}/udp"
  echo " 公钥          : ${SERVER_PUB}"
  echo " 配置文件      : ${WG_DIR}/${WG_IF}.conf"
  echo " 客户端目录    : ${WG_CLIENT_DIR}/<client_name>/client.conf"
  echo "-----------------------------------------"
}

# -------------------- 新增客户端 --------------------
add_client() {
  if [[ ! -f "${WG_DIR}/${WG_IF}.conf" ]]; then
    error "尚未初始化服务端，请先执行初始化。"
    return
  fi

  read -rp "请输入客户端名称（字母数字下划线）: " NAME
  if [[ -z "$NAME" ]]; then
    error "客户端名称不能为空。"
    return
  fi
  if [[ "$NAME" =~ [^a-zA-Z0-9_-] ]]; then
    error "客户端名称包含非法字符。"
    return
  fi

  local CLIENT_PATH="${WG_CLIENT_DIR}/${NAME}"
  if [[ -d "$CLIENT_PATH" ]]; then
    error "客户端 ${NAME} 已存在。"
    return
  fi

  local CLIENT_IP WG_MTU_RECOMMEND WG_MTU ALLOWED_IPS DNS_SERVERS
  CLIENT_IP=$(next_client_ip) || { error "客户端 IP 已用尽（10.10.10.2-254）。"; return; }

  # 推荐 MTU（根据服务器出口估算）
  WG_MTU_RECOMMEND=$(get_or_detect_mtu)
  echo "推荐 MTU（基于服务器出口估算）: ${WG_MTU_RECOMMEND}"
  echo "如已在客户端实测 MTU，可在此输入实测值；否则按回车使用推荐值。"
  read -rp "请输入客户端 MTU（1200–1500，默认 ${WG_MTU_RECOMMEND}）: " REPLY_MTU

  if [[ -n "${REPLY_MTU:-}" && "${REPLY_MTU}" =~ ^[0-9]+$ ]] && \
     [[ "${REPLY_MTU}" -ge 1200 && "${REPLY_MTU}" -le 1500 ]]; then
    WG_MTU="${REPLY_MTU}"
  else
    WG_MTU="${WG_MTU_RECOMMEND}"
  fi

  # 路由模式选择：全局 / 仅内网 / 自定义
  echo "选择路由模式:"
  echo " 1) 全局代理（所有流量走服务器，附带内网互通）"
  echo " 2) 仅内网（只访问 ${WG_NET}，不代理公网）"
  echo " 3) 自定义 AllowedIPs"
  read -rp "请输入选项 [1-3]（默认 1）: " ROUTE_MODE

  case "${ROUTE_MODE:-1}" in
    2)
      ALLOWED_IPS="${WG_NET}"
      ;;
    3)
      read -rp "请输入 AllowedIPs（例如 0.0.0.0/0, ${WG_NET}）: " CUSTOM_ALLOWED
      if [[ -n "${CUSTOM_ALLOWED:-}" ]]; then
        ALLOWED_IPS="${CUSTOM_ALLOWED}"
      else
        ALLOWED_IPS="0.0.0.0/0, ${WG_NET}"
      fi
      ;;
    *)
      ALLOWED_IPS="0.0.0.0/0, ${WG_NET}"
      ;;
  esac

  # 智能 DNS
  DNS_SERVERS=$(get_or_detect_dns)
  echo "智能 DNS 选择结果：${DNS_SERVERS}"

  mkdir -p "$CLIENT_PATH"

  info "生成客户端密钥..."
  wg genkey | tee "${CLIENT_PATH}/client_private.key" | wg pubkey > "${CLIENT_PATH}/client_public.key"
  local CLIENT_PRIV CLIENT_PUB
  CLIENT_PRIV=$(cat "${CLIENT_PATH}/client_private.key")
  CLIENT_PUB=$(cat "${CLIENT_PATH}/client_public.key")

  local SERVER_PUB WG_PORT
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")
  WG_PORT=$(detect_wg_port)
  [[ -z "$WG_PORT" ]] && WG_PORT=$(get_or_create_port)

  info "写入客户端配置文件 ${CLIENT_PATH}/client.conf ..."
  cat > "${CLIENT_PATH}/client.conf" <<EOF
[Interface]
Address = ${CLIENT_IP}/24
PrivateKey = ${CLIENT_PRIV}
DNS = ${DNS_SERVERS}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
# 路由模式：${ALLOWED_IPS}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 25
EOF

  chmod 600 "${CLIENT_PATH}/client.conf"

  info "将客户端加入服务端 peer 列表..."
  wg set "${WG_IF}" peer "${CLIENT_PUB}" allowed-ips "${CLIENT_IP}/32"
  wg-quick save "${WG_IF}"

  success "客户端 ${NAME} 创建完成！"
  echo "-----------------------------------------"
  echo " 客户端名称 : ${NAME}"
  echo " 客户端 IP  : ${CLIENT_IP}"
  echo " 配置文件   : ${CLIENT_PATH}/client.conf"
  echo " 公钥       : ${CLIENT_PUB}"
  echo " MTU        : ${WG_MTU}"
  echo " AllowedIPs : ${ALLOWED_IPS}"
  echo " DNS        : ${DNS_SERVERS}"
  echo "-----------------------------------------"
  echo ">> 在客户端：将 client.conf 复制到 /etc/wireguard/wg0.conf 即可使用"
  echo ">> 建议在客户端实际用 ping 再测一遍 MTU，如有更优值可回到此菜单重新建一个客户端。"

  # 终端二维码
  info "生成配置二维码（终端扫码导入）..."
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${CLIENT_PATH}/client.conf" || warn "二维码生成失败（qrencode 异常）。"
  else
    warn "未安装 qrencode，跳过二维码生成。"
  fi
}

# -------------------- 删除客户端 --------------------
del_client() {
  if [[ ! -d "$WG_CLIENT_DIR" ]]; then
    warn "当前没有任何客户端。"
    return
  fi

  read -rp "请输入要删除的客户端名称: " NAME
  local CLIENT_PATH="${WG_CLIENT_DIR}/${NAME}"
  if [[ ! -d "$CLIENT_PATH" ]]; then
    error "客户端 ${NAME} 不存在。"
    return
  fi

  local CLIENT_PUB
  CLIENT_PUB=$(cat "${CLIENT_PATH}/client_public.key")

  info "从 WireGuard 中移除客户端 peer..."
  wg set "${WG_IF}" peer "${CLIENT_PUB}" remove || true
  wg-quick save "${WG_IF}"

  info "删除客户端文件..."
  rm -rf "${CLIENT_PATH}"

  success "客户端 ${NAME} 已删除。"
}

# -------------------- 列出客户端 --------------------
list_clients() {
  if [[ ! -d "$WG_CLIENT_DIR" ]]; then
    warn "当前没有任何客户端。"
    return
  fi

  echo "当前已配置客户端："
  echo "-----------------------------------------"
  local d NAME IP
  for d in "${WG_CLIENT_DIR}"/*; do
    [[ -d "$d" ]] || continue
    NAME=$(basename "$d")
    IP=$(grep -m1 "^Address" "$d/client.conf" 2>/dev/null | awk '{print $3}')
    echo " - ${NAME} : ${IP}"
  done
  echo "-----------------------------------------"
}

# -------------------- 显示服务端信息 --------------------
show_server_info() {
  if [[ ! -f "${WG_DIR}/${WG_IF}.conf" ]]; then
    error "服务端尚未初始化。"
    return
  fi
  local SERVER_PUB WG_PORT DNS_BEST
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")
  WG_PORT=$(detect_wg_port)
  [[ -z "$WG_PORT" ]] && WG_PORT="未知"

  if [[ -f "$WG_DNS_FILE" ]]; then
    DNS_BEST=$(cat "$WG_DNS_FILE" 2>/dev/null || true)
  else
    DNS_BEST="未缓存（创建客户端时自动探测）"
  fi

  echo "-----------------------------------------"
  echo " 服务端公网 IP : ${SERVER_PUBLIC_IP}"
  echo " 服务端内网 IP : ${WG_SERVER_IP}"
  echo " 监听端口      : ${WG_PORT}/udp"
  echo " 公钥          : ${SERVER_PUB}"
  echo " 配置文件      : ${WG_DIR}/${WG_IF}.conf"
  echo " 客户端目录    : ${WG_CLIENT_DIR}"
  echo " 智能 DNS 缓存 : ${DNS_BEST}"
  echo "-----------------------------------------"
  wg show "${WG_IF}" || true
}

# -------------------- 导出所有客户端配置 --------------------
export_clients() {
  if [[ ! -d "$WG_CLIENT_DIR" ]]; then
    warn "当前没有任何客户端。"
    return
  fi
  local backup="/etc/wireguard/clients_backup_$(date +%F_%H%M%S).zip"
  info "打包客户端配置到：${backup}"
  if zip -r "$backup" "$WG_CLIENT_DIR" >/dev/null 2>&1; then
    success "导出成功：${backup}"
  else
    error "打包失败。"
  fi
}

# -------------------- 重置服务端密钥（保留客户端） --------------------
reset_server_keys() {
  if [[ ! -f "${WG_DIR}/${WG_IF}.conf" ]]; then
    error "服务端尚未初始化。"
    return
  fi

  warn "此操作将重置服务端密钥，但保留所有客户端配置。"
  read -rp "确认继续？(yes/no): " ans
  [[ "$ans" != "yes" ]] && info "已取消。" && return

  info "生成新的服务端密钥..."
  wg genkey | tee "${WG_DIR}/server_private.key.new" | wg pubkey > "${WG_DIR}/server_public.key.new"
  local NEW_PRIV NEW_PUB
  NEW_PRIV=$(cat "${WG_DIR}/server_private.key.new")
  NEW_PUB=$(cat "${WG_DIR}/server_public.key.new")

  info "更新 wg0.conf 中的私钥..."
  sed -i "s|^PrivateKey *=.*|PrivateKey = ${NEW_PRIV}|" "${WG_DIR}/${WG_IF}.conf"

  info "让运行中的 WireGuard 使用新私钥..."
  wg set "${WG_IF}" private-key <(echo "${NEW_PRIV}") || true

  mv "${WG_DIR}/server_private.key.new" "${WG_DIR}/server_private.key"
  mv "${WG_DIR}/server_public.key.new" "${WG_DIR}/server_public.key"

  info "更新所有客户端配置中的服务端公钥..."
  local d
  for d in "${WG_CLIENT_DIR}"/*; do
    [[ -d "$d" ]] || continue
    sed -i "s|^PublicKey *=.*|PublicKey = ${NEW_PUB}|" "$d/client.conf"
  done

  wg-quick save "${WG_IF}"
  success "服务端密钥已重置，并同步到所有客户端配置文件。"
}

# -------------------- 状态总览面板 --------------------
status_panel() {
  clear
  echo "=============== WireGuard 状态面板 ==============="
  echo ""

  echo "[服务状态]"
  if systemctl is-active "wg-quick@${WG_IF}" >/dev/null 2>&1; then
    echo "  WireGuard: 运行中"
  else
    echo "  WireGuard: 未运行"
  fi

  echo ""
  echo "[网络信息]"
  echo "  公网 IP : ${SERVER_PUBLIC_IP}"
  echo "  出口网卡: $(detect_wan_if)"
  echo "  ${WG_IF} IP  : $(ip -4 addr show ${WG_IF} 2>/dev/null | awk '/inet/ {print $2}' || echo '未分配')"
  echo "  UDP 端口: $(detect_wg_port || echo '未知')"

  echo ""
  echo "[转发与加速]"
  local fwd ipv6 bbr
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  ipv6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  echo "  IPv4 转发: $([[ "$fwd" == "1" ]] && echo 开启 || echo 关闭)"
  echo "  IPv6 转发: $([[ "$ipv6" == "1" ]] && echo 开启 || echo 关闭)"
  echo "  拥塞控制: ${bbr}"

  echo ""
  echo "[客户端状态]"
  wg show "${WG_IF}" || echo "  无数据（可能未运行）"

  echo ""
  echo "[系统资源]"
  echo "  CPU : $(top -bn1 | awk '/Cpu\(s\)/ {print $2"%"}')"
  echo "  内存: $(free -h | awk '/Mem/ {print $3 "/" $2}')"
  echo "  负载: $(uptime | awk -F'load average:' '{print $2}')"
  echo "  磁盘: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (已用 " $5 ")"}')"

  echo ""
  echo "=================================================="
}

# -------------------- 重启 / 停止 WireGuard --------------------
restart_wg() {
  systemctl restart "wg-quick@${WG_IF}"
  success "WireGuard 已重启。"
}

stop_wg() {
  systemctl stop "wg-quick@${WG_IF}"
  success "WireGuard 已停止。"
}

# -------------------- 卸载 WireGuard（保留备份） --------------------
uninstall_wireguard() {
  warn "此操作将卸载 WireGuard 并删除 /etc/wireguard（会生成备份）。"
  read -rp "确认卸载？(yes/no): " ans
  [[ "$ans" != "yes" ]] && info "已取消卸载。" && return

  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl disable --now wg-monitor.timer >/dev/null 2>&1 || true
  systemctl disable --now wg-monitor.service >/dev/null 2>&1 || true

  local backup="/root/wireguard_backup_$(date +%F_%H%M%S).tar.gz"
  if [[ -d "$WG_DIR" ]]; then
    info "备份 /etc/wireguard 到：${backup}"
    tar czf "$backup" "$WG_DIR"
  fi

  info "卸载相关软件包（保留 nftables，可按需手动卸载）..."
  apt purge -y wireguard wireguard-tools resolvconf || true
  apt autoremove -y || true

  rm -rf "$WG_DIR"
  rm -f /usr/local/bin/wg-admin
  rm -f /usr/local/bin/wg-monitor.sh
  rm -f /etc/systemd/system/wg-monitor.service
  rm -f /etc/systemd/system/wg-monitor.timer

  systemctl daemon-reload

  success "WireGuard 已卸载。备份文件：${backup}"
}

# -------------------- 主逻辑 --------------------
if [[ ! -f "${WG_DIR}/${WG_IF}.conf" ]]; then
  info "检测到尚未初始化 WireGuard 服务端，开始初始化..."
  init_server
else
  success "检测到已有 WireGuard 配置，跳过初始化。"
fi

while true; do
  echo ""
  echo "=============== WireGuard 管理菜单 ==============="
  echo " wg-admin  管理菜单（任意目录执行 wg-admin 即可调用）"
  echo " 1) 新增客户端"
  echo " 2) 删除客户端"
  echo " 3) 列出客户端"
  echo " 4) 显示服务端信息"
  echo " 5) 导出所有客户端配置"
  echo " 6) 重置服务端密钥（保留客户端）"
  echo " 7) 查看系统与 VPN 状态面板"
  echo " 8) 卸载 WireGuard（保留备份）"
  echo " 9) 重启 WireGuard"
  echo "10) 停止 WireGuard"
  echo " 0) 退出"
  echo "=================================================="
  read -rp "请选择操作: " choice

  case "$choice" in
    1) add_client ;;
    2) del_client ;;
    3) list_clients ;;
    4) show_server_info ;;
    5) export_clients ;;
    6) reset_server_keys ;;
    7) status_panel ;;
    8) uninstall_wireguard ;;
    9) restart_wg ;;
    10) stop_wg ;;
    0) echo "退出。"; exit 0 ;;
    *) warn "无效选项，请重新输入。" ;;
  esac
done
