#!/usr/bin/env bash
# ============================================================
# WireGuard 引导安装脚本（Agent 模式）
# 只做两件事：
#   1. 安装 WireGuard + 基础内核 / 防火墙（Debian / Ubuntu）
#   2. 生成 Python Agent + wg-admin 命令
#
# 真正的管理逻辑（多客户端 / 监控 / 状态引擎 / 多语言）
# 全部由 /opt/wg-agent/wg_agent.py 提供。
#
# 版本: v1.40-pro-bootstrap
# 作者: 胡博涵 实践版（2025）
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

WG_IF="wg0"
WG_NET="10.10.10.0/24"
WG_SERVER_IP="10.10.10.1"
WG_DIR="/etc/wireguard"
WG_CLIENT_DIR="${WG_DIR}/clients"
WG_PORT_FILE="${WG_DIR}/listen_port"
LOG_FILE="/var/log/wireguard_server_install.log"

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

detect_wan_if() {
  ip route get 8.8.8.8 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
    | head -n1
}

detect_public_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
  if [[ -n "$ip" ]] && ! [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    echo "$ip"
    return
  fi
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

get_or_create_port() {
  if [[ -f "$WG_PORT_FILE" ]]; then
    local p
    p=$(cat "$WG_PORT_FILE" 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      echo "$p"
      return
    fi
  fi
  local port
  port=$(shuf -i 20000-60000 -n 1)
  while ss -lun | awk 'NR>1 {print $5}' | grep -q ":${port}$"; do
    port=$(shuf -i 20000-60000 -n 1)
  done
  echo "$port" > "$WG_PORT_FILE"
  echo "$port"
}

apply_sysctl() {
  info "应用内核转发与 BBR..."
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

configure_nftables() {
  info "配置 nftables 基础 NAT 规则..."
  local WAN_IF WG_PORT
  WAN_IF=$(detect_wan_if)
  [[ -z "$WAN_IF" ]] && WAN_IF="eth0"
  WG_PORT=$(cat "$WG_PORT_FILE")

  # 备份旧配置
  if [[ -f /etc/nftables.conf ]]; then
    cp /etc/nftables.conf "/etc/nftables.conf.bak-$(date +%F-%H%M%S)"
  fi

  cat > /etc/nftables.conf <<EOF
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept

    # WireGuard 端口
    udp dport ${WG_PORT} accept

    # 允许来自 WireGuard 接口的流量
    iif "${WG_IF}" accept

    # SSH
    tcp dport 22 accept

    # 已建立连接
    ct state established,related accept
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
    ip saddr ${WG_NET} oif "${WAN_IF}" masquerade
  }
}
EOF

  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl restart nftables
  success "nftables 已配置。"
}

install_packages() {
  info "检测系统并安装依赖..."
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    info "系统: ${NAME} (${ID})"
  fi

  apt update -y
  apt install -y wireguard qrencode python3 python3-venv python3-pip nftables resolvconf curl
}

setup_wireguard() {
  mkdir -p "$WG_DIR" "$WG_CLIENT_DIR"

  if [[ ! -f "${WG_DIR}/server_private.key" ]] || [[ ! -f "${WG_DIR}/server_public.key" ]]; then
    info "生成服务端密钥..."
    umask 077
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
  fi

  local SERVER_PRIV SERVER_PUB WG_PORT
  SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")
  WG_PORT=$(get_or_create_port)

  info "写入 ${WG_DIR}/${WG_IF}.conf ..."
  cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = 1280
SaveConfig = true
EOF

  chmod 600 "${WG_DIR}/${WG_IF}.conf"

  info "清理残留接口 ${WG_IF} ..."
  ip link del "${WG_IF}" 2>/dev/null || true

  info "启用并启动 WireGuard 服务..."
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IF}"

  apply_sysctl
  configure_nftables

  local PUB_IP
  PUB_IP=$(detect_public_ip || true)
  [[ -z "$PUB_IP" ]] && PUB_IP="0.0.0.0"

  success "WireGuard 基础环境初始化完成："
  echo "-----------------------------------------"
  echo " 公网 IP    : ${PUB_IP}"
  echo " 内网 IP    : ${WG_SERVER_IP}"
  echo " UDP 端口   : ${WG_PORT}"
  echo " 配置文件   : ${WG_DIR}/${WG_IF}.conf"
  echo " 客户端目录 : ${WG_CLIENT_DIR}"
  echo "-----------------------------------------"
}

install_agent() {
  info "安装 Python Agent 到 /opt/wg-agent ..."
  mkdir -p /opt/wg-agent
  cat > /opt/wg-agent/wg_agent.py << 'EOF'
#!/usr/bin/env python3
# ============================================================
# WireGuard Python Agent (CLI 管理面板)
# 架构: UI → Facade → Controller → StateEngine → WGAdapter → WireGuard
# 版本: v1.40-pro-agent
# 默认语言: 中文，可在菜单中切换到 English
# 状态引擎采样周期: 建议 2 秒（实时监控时）
# ============================================================

import os
import sys
import time
import json
import subprocess
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Tuple

WG_IF = "wg0"
WG_DIR = "/etc/wireguard"
CLIENT_DIR = os.path.join(WG_DIR, "clients")
STATE_FILE = "/opt/wg-agent/state.json"
EVENT_LOG = "/var/log/wireguard-clients.log"
AGENT_LOG = "/var/log/wg-agent.log"
INSTALL_LOG = "/var/log/wireguard_server_install.log"

# -------------------- 简单日志 --------------------
def log(msg: str):
    ts = time.strftime("%F %T")
    line = f"[{ts}] {msg}"
    try:
        with open(AGENT_LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass

# -------------------- 多语言支持 --------------------
LANG = "zh"  # 默认中文

TEXT = {
    "zh": {
        "title": "================== WireGuard 管理面板 ==================",
        "version": "版本: {version} | 快捷命令: wg-admin | 当前语言: 中文 (按 8 切换)",
        "menu_main": [
            "1) 客户端管理",
            "2) 服务管理",
            "3) 监控中心",
            "4) 日志中心",
            "5) 安全中心（预留）",
            "8) 切换语言：English",
            "9) 卸载提示",
            "0) 退出",
        ],
        "prompt_choice": "请选择操作: ",
        "back": "0) 返回上级",
        "invalid": "无效选项，请重试。",
        "press_enter": "按回车键返回...",
        "not_root": "必须在 root 权限下运行（或通过 sudo）。",
        "wg_not_ready": "检测不到 {iface}，请先确保 wg-quick@{iface} 已启动。",
        "no_clients": "当前没有任何客户端。",
        "client_add_name": "请输入客户端名称（字母数字下划线）: ",
        "client_name_empty": "客户端名称不能为空。",
        "client_name_invalid": "客户端名称只能包含字母、数字、下划线、连字符。",
        "client_exists": "客户端 {name} 已存在。",
        "ip_exhausted": "IP 已用尽（10.10.10.2-254）。",
        "client_created": "客户端 {name} 创建完成。",
        "client_deleted": "客户端 {name} 已删除。",
        "input_client_delete": "请输入要删除的客户端名称: ",
        "client_not_found": "客户端 {name} 不存在。",
        "server_info_title": "服务端信息：",
        "dashboard_title": "=============== WireGuard 状态总览 ===============",
        "dashboard_service_running": "WireGuard 服务状态: 运行中",
        "dashboard_service_stopped": "WireGuard 服务状态: 未运行",
        "dashboard_wg_ip": "wg0 IP        : {ip}",
        "dashboard_pub_ip": "公网 IP       : {ip}",
        "dashboard_port": "UDP 端口      : {port}",
        "dashboard_online": "在线客户端数 : {count}",
        "dashboard_rate": "汇总速率     : 下行 {rx:.2f} KiB/s, 上行 {tx:.2f} KiB/s",
        "logs_title": "========= 日志中心 =========",
        "logs_install": "1) 安装日志",
        "logs_agent": "2) Agent 日志",
        "logs_clients": "3) 客户端事件日志",
        "logs_tail": "显示 {path} 的最近 {n} 行：",
        "lang_switched_en": "已切换为 English。",
        "lang_switched_zh": "已切换为 中文。",
        "uninstall_tip": "卸载提示：请使用 apt purge wireguard wireguard-tools，并手动删除 /etc/wireguard 与 /opt/wg-agent。",
    },
    "en": {
        "title": "================== WireGuard Control Panel ==================",
        "version": "Version: {version} | Shortcut: wg-admin | Lang: English (press 8 to switch)",
        "menu_main": [
            "1) Client Management",
            "2) Service Management",
            "3) Monitoring Center",
            "4) Log Center",
            "5) Security (Reserved)",
            "8) Switch Language: 中文",
            "9) Uninstall hint",
            "0) Exit",
        ],
        "prompt_choice": "Select an option: ",
        "back": "0) Back",
        "invalid": "Invalid option, please retry.",
        "press_enter": "Press Enter to return...",
        "not_root": "Must run as root (or via sudo).",
        "wg_not_ready": "Interface {iface} not found. Please ensure wg-quick@{iface} is running.",
        "no_clients": "No clients found.",
        "client_add_name": "Enter client name (letters/digits/_/-): ",
        "client_name_empty": "Client name must not be empty.",
        "client_name_invalid": "Client name may only contain letters, digits, '_' or '-'.",
        "client_exists": "Client {name} already exists.",
        "ip_exhausted": "IP pool exhausted (10.10.10.2-254).",
        "client_created": "Client {name} created.",
        "client_deleted": "Client {name} deleted.",
        "input_client_delete": "Enter client name to delete: ",
        "client_not_found": "Client {name} not found.",
        "server_info_title": "Server Info:",
        "dashboard_title": "=============== WireGuard Dashboard ===============",
        "dashboard_service_running": "WireGuard service: running",
        "dashboard_service_stopped": "WireGuard service: stopped",
        "dashboard_wg_ip": "wg0 IP      : {ip}",
        "dashboard_pub_ip": "Public IP   : {ip}",
        "dashboard_port": "UDP Port    : {port}",
        "dashboard_online": "Online peers: {count}",
        "dashboard_rate": "Total rate  : RX {rx:.2f} KiB/s, TX {tx:.2f} KiB/s",
        "logs_title": "========= Log Center =========",
        "logs_install": "1) Install log",
        "logs_agent": "2) Agent log",
        "logs_clients": "3) Client events",
        "logs_tail": "Tail {n} lines of {path}:",
        "lang_switched_en": "Switched to English.",
        "lang_switched_zh": "已切换为 中文。",
        "uninstall_tip": "Uninstall hint: apt purge wireguard wireguard-tools, then remove /etc/wireguard and /opt/wg-agent.",
    },
}

def T(key: str, **kwargs) -> str:
  """国际化文本获取"""
  text = TEXT.get(LANG, TEXT["zh"]).get(key, key)
  try:
    return text.format(**kwargs)
  except Exception:
    return text

# -------------------- 数据模型 --------------------
@dataclass
class PeerRuntime:
    public_key: str
    endpoint: str
    latest_handshake: int
    rx_bytes: int
    tx_bytes: int
    keepalive: int

@dataclass
class PeerState:
    name: str
    ip: str
    public_key: str
    endpoint: str
    online: bool
    seconds_since_handshake: Optional[int]
    rx_rate: float  # bytes/s
    tx_rate: float  # bytes/s
    rx_total: int
    tx_total: int

# -------------------- WireGuard 适配层 --------------------
class WGAdapter:
    @staticmethod
    def _run(cmd: List[str]) -> str:
        log(f"run: {' '.join(cmd)}")
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)

    @staticmethod
    def interface_exists() -> bool:
        try:
            WGAdapter._run(["wg", "show", WG_IF])
            return True
        except Exception:
            return False

    @staticmethod
    def get_server_public_key() -> Optional[str]:
        try:
            out = WGAdapter._run(["wg", "show", WG_IF, "public-key"])
            return out.strip()
        except Exception:
            return None

    @staticmethod
    def get_server_listen_port() -> Optional[int]:
        try:
            out = WGAdapter._run(["wg", "show", WG_IF, "listen-port"])
            return int(out.strip())
        except Exception:
            return None

    @staticmethod
    def get_wg_ip() -> str:
        try:
            out = WGAdapter._run(["ip", "-4", "addr", "show", WG_IF])
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("inet "):
                    return line.split()[1]
        except Exception:
            pass
        return "N/A"

    @staticmethod
    def get_public_ip() -> str:
        try:
            r = WGAdapter._run(["bash", "-c", "ip route get 1.1.1.1 | awk '/src/ {print $7; exit}'"])
            ip = r.strip()
            if ip:
                return ip
        except Exception:
            pass
        return "N/A"

    @staticmethod
    def get_runtime_peers() -> Dict[str, PeerRuntime]:
        """解析 wg show wg0 dump，返回 public_key -> PeerRuntime"""
        peers: Dict[str, PeerRuntime] = {}
        try:
            out = WGAdapter._run(["wg", "show", WG_IF, "dump"])
        except Exception:
            return peers
        lines = out.strip().splitlines()
        # 第一行是 interface 行
        for line in lines[1:]:
            parts = line.strip().split("\t")
            if len(parts) < 8:
                continue
            pub = parts[0]
            endpoint = parts[2]
            try:
                hs = int(parts[4])
                rx = int(parts[5])
                tx = int(parts[6])
                ka = int(parts[7])
            except ValueError:
                continue
            peers[pub] = PeerRuntime(
                public_key=pub,
                endpoint=endpoint,
                latest_handshake=hs,
                rx_bytes=rx,
                tx_bytes=tx,
                keepalive=ka,
            )
        return peers

    @staticmethod
    def ensure_dirs():
        os.makedirs(CLIENT_DIR, exist_ok=True)

    @staticmethod
    def list_client_configs() -> Dict[str, Tuple[str, str]]:
        """
        返回 name -> (ip, public_key)
        """
        WGAdapter.ensure_dirs()
        result: Dict[str, Tuple[str, str]] = {}
        for name in os.listdir(CLIENT_DIR):
            path = os.path.join(CLIENT_DIR, name)
            if not os.path.isdir(path):
                continue
            conf_path = os.path.join(path, "client.conf")
            key_path = os.path.join(path, "client_public.key")
            ip = "N/A"
            pub = ""
            try:
                with open(conf_path) as f:
                    for line in f:
                        if line.strip().startswith("Address"):
                            ip = line.split("=", 1)[1].strip()
                            break
            except Exception:
                pass
            try:
                with open(key_path) as f:
                    pub = f.read().strip()
            except Exception:
                pass
            result[name] = (ip, pub)
        return result

    @staticmethod
    def next_client_ip() -> Optional[str]:
        used: List[str] = []
        for _, (ip, _) in WGAdapter.list_client_configs().items():
            if ip != "N/A":
                used.append(ip.split("/")[0])
        for last in range(2, 255):
            candidate = f"10.10.10.{last}"
            if candidate not in used:
                return candidate
        return None

    @staticmethod
    def add_client(name: str) -> PeerState:
        WGAdapter.ensure_dirs()
        clients = WGAdapter.list_client_configs()
        if name in clients:
            raise RuntimeError(T("client_exists", name=name))

        ip = WGAdapter.next_client_ip()
        if ip is None:
            raise RuntimeError(T("ip_exhausted"))

        client_dir = os.path.join(CLIENT_DIR, name)
        os.makedirs(client_dir, exist_ok=True)
        priv_path = os.path.join(client_dir, "client_private.key")
        pub_path = os.path.join(client_dir, "client_public.key")

        # 生成密钥
        priv = WGAdapter._run(["wg", "genkey"]).strip()
        pub = subprocess.check_output(["bash", "-lc", f"echo '{priv}' | wg pubkey"], text=True).strip()

        with open(priv_path, "w") as f:
            f.write(priv + "\n")
        with open(pub_path, "w") as f:
            f.write(pub + "\n")
        os.chmod(priv_path, 0o600)
        os.chmod(pub_path, 0o600)

        server_pub = WGAdapter.get_server_public_key() or ""
        port = WGAdapter.get_server_listen_port() or 0
        endpoint = f"{WGAdapter.get_public_ip()}:{port}"

        client_conf = os.path.join(client_dir, "client.conf")
        with open(client_conf, "w") as f:
            f.write(f"""[Interface]
Address = {ip}/24
PrivateKey = {priv}
DNS = 1.1.1.1, 1.0.0.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = {server_pub}
Endpoint = {endpoint}
AllowedIPs = 0.0.0.0/0, 10.10.10.0/24
PersistentKeepalive = 25
""")
        os.chmod(client_conf, 0o600)

        # 加入 wg 配置
        WGAdapter._run(["wg", "set", WG_IF, "peer", pub, "allowed-ips", f"{ip}/32"])
        WGAdapter._run(["wg-quick", "save", WG_IF])

        # 返回初始状态（在线信息稍后由 StateEngine 计算）
        return PeerState(
            name=name,
            ip=f"{ip}/24",
            public_key=pub,
            endpoint="",
            online=False,
            seconds_since_handshake=None,
            rx_rate=0.0,
            tx_rate=0.0,
            rx_total=0,
            tx_total=0,
        )

    @staticmethod
    def delete_client(name: str) -> None:
        clients = WGAdapter.list_client_configs()
        if name not in clients:
            raise RuntimeError(T("client_not_found", name=name))
        _, pub = clients[name]
        if pub:
            try:
                WGAdapter._run(["wg", "set", WG_IF, "peer", pub, "remove"])
                WGAdapter._run(["wg-quick", "save", WG_IF])
            except Exception:
                pass
        client_dir = os.path.join(CLIENT_DIR, name)
        for root, dirs, files in os.walk(client_dir, topdown=False):
            for fn in files:
                try:
                    os.remove(os.path.join(root, fn))
                except Exception:
                    pass
            for d in dirs:
                try:
                    os.rmdir(os.path.join(root, d))
                except Exception:
                    pass
        try:
            os.rmdir(client_dir)
        except Exception:
            pass

# -------------------- 状态引擎 --------------------
class StateEngine:
    def __init__(self) -> None:
        self.prev_snapshot: Dict[str, Dict] = {}
        self.prev_time: Optional[float] = None

    def load_state(self):
        try:
            with open(STATE_FILE) as f:
                data = json.load(f)
            self.prev_snapshot = data.get("peers", {})
            self.prev_time = data.get("timestamp", None)
        except Exception:
            self.prev_snapshot = {}
            self.prev_time = None

    def save_state(self, peers: Dict[str, Dict], ts: float):
        try:
            tmp = {"timestamp": ts, "peers": peers}
            os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
            with open(STATE_FILE, "w") as f:
                json.dump(tmp, f)
        except Exception:
            pass

    def tick(self) -> Dict[str, PeerState]:
        """
        采样一次，返回当前所有客户端的状态（带速率）。
        """
        if not WGAdapter.interface_exists():
            return {}

        self.load_state()
        now = time.time()
        runtime_peers = WGAdapter.get_runtime_peers()
        client_conf = WGAdapter.list_client_configs()

        result: Dict[str, PeerState] = {}
        new_snapshot: Dict[str, Dict] = {}

        for name, (ip, pub) in client_conf.items():
            rt = runtime_peers.get(pub)
            if rt is None:
                # 还没连上
                state = PeerState(
                    name=name,
                    ip=ip,
                    public_key=pub,
                    endpoint="",
                    online=False,
                    seconds_since_handshake=None,
                    rx_rate=0.0,
                    tx_rate=0.0,
                    rx_total=0,
                    tx_total=0,
                )
                result[name] = state
                new_snapshot[pub] = {
                    "rx": 0,
                    "tx": 0,
                    "ts": now,
                }
                continue

            # 在线判定
            if rt.latest_handshake == 0:
                online = False
                diff_s = None
            else:
                diff = int(now - rt.latest_handshake)
                online = diff <= 180
                diff_s = diff

            # 速率计算（差分）
            prev = self.prev_snapshot.get(rt.public_key)
            rx_rate = tx_rate = 0.0
            if prev and self.prev_time and now > self.prev_time:
                dt = now - self.prev_time
                drx = rt.rx_bytes - int(prev.get("rx", 0))
                dtx = rt.tx_bytes - int(prev.get("tx", 0))
                if drx < 0 or dtx < 0 or dt <= 0:
                    rx_rate = tx_rate = 0.0
                else:
                    rx_rate = drx / dt
                    tx_rate = dtx / dt

            state = PeerState(
                name=name,
                ip=ip,
                public_key=pub,
                endpoint=rt.endpoint,
                online=online,
                seconds_since_handshake=diff_s,
                rx_rate=rx_rate,
                tx_rate=tx_rate,
                rx_total=rt.rx_bytes,
                tx_total=rt.tx_bytes,
            )
            result[name] = state
            new_snapshot[rt.public_key] = {
                "rx": rt.rx_bytes,
                "tx": rt.tx_bytes,
                "ts": now,
            }

        self.save_state(new_snapshot, now)
        self._emit_events(result)
        return result

    def _emit_events(self, peers: Dict[str, PeerState]):
        """
        简单事件：在线 / 离线切换 + endpoint 变化
        """
        try:
            os.makedirs(os.path.dirname(EVENT_LOG), exist_ok=True)
        except Exception:
            pass
        now = time.strftime("%F %T")
        lines: List[str] = []
        for name, st in peers.items():
            key = st.public_key
            prev = self.prev_snapshot.get(key, {})
            prev_online = prev.get("online")
            prev_ep = prev.get("endpoint", "")
            cur_online = st.online
            cur_ep = st.endpoint or ""

            if prev_online is None:
                # 首次，不记事件
                pass
            elif prev_online != cur_online:
                status = "ONLINE" if cur_online else "OFFLINE"
                lines.append(f"[{now}] client={name} pub={key[:16]} status={status} endpoint={cur_ep}")
            elif cur_ep and prev_ep != cur_ep:
                lines.append(f"[{now}] client={name} pub={key[:16]} endpoint_change={prev_ep}->{cur_ep}")

            # 把在线状态与 endpoint 放回 snapshot（方便下次比较）
            self.prev_snapshot[key] = {
                "rx": st.rx_total,
                "tx": st.tx_total,
                "ts": time.time(),
                "online": cur_online,
                "endpoint": cur_ep,
            }

        if lines:
            try:
                with open(EVENT_LOG, "a") as f:
                    f.write("\n".join(lines) + "\n")
            except Exception:
                pass

# -------------------- 控制器 & UI --------------------
class Controller:
    def __init__(self):
        self.engine = StateEngine()

    # ---- 客户端管理 ----
    def client_add(self):
        name = input(T("client_add_name")).strip()
        if not name:
            print(T("client_name_empty"))
            return
        import re
        if not re.match(r"^[A-Za-z0-9_-]+$", name):
            print(T("client_name_invalid"))
            return
        try:
            st = WGAdapter.add_client(name)
            print(T("client_created", name=name))
            print(f"  IP: {st.ip}")
            client_conf = os.path.join(CLIENT_DIR, name, "client.conf")
            print(f"  配置文件: {client_conf}")
            print("  建议将该文件复制到客户端 /etc/wireguard/wg0.conf")
        except Exception as e:
            print(f"[错误] {e}")

    def client_delete(self):
        name = input(T("input_client_delete")).strip()
        if not name:
            return
        try:
            WGAdapter.delete_client(name)
            print(T("client_deleted", name=name))
        except Exception as e:
            print(f"[错误] {e}")

    def client_list_detailed(self):
        peers = self.engine.tick()
        if not peers:
            print(T("no_clients"))
            return
        print("名称              IP                 在线   最近握手(s)   下行KiB/s   上行KiB/s")
        print("--------------------------------------------------------------------------")
        for name, st in sorted(peers.items(), key=lambda x: x[0]):
            online = "ON" if st.online else "OFF"
            hs = st.seconds_since_handshake if st.seconds_since_handshake is not None else "-"
            rx = st.rx_rate / 1024
            tx = st.tx_rate / 1024
            print(f"{name:<16}{st.ip:<18}{online:<6}{str(hs):<14}{rx:>10.2f}{tx:>11.2f}")

    def client_show_events(self):
        path = EVENT_LOG
        print(T("logs_tail", path=path, n=50))
        print("--------------------------------------------------")
        try:
            if os.path.exists(path):
                os.system(f"tail -n 50 {path}")
            else:
                print(T("no_clients"))
        except Exception:
            print("(无法读取事件日志)")
        print("--------------------------------------------------")

    # ---- 服务管理 ----
    def show_server_info(self):
        if not WGAdapter.interface_exists():
            print(T("wg_not_ready", iface=WG_IF))
            return
        print(T("server_info_title"))
        print("-----------------------------------------")
        print(f" Interface   : {WG_IF}")
        print(f" Public Key  : {WGAdapter.get_server_public_key()}")
        print(f" Listen Port : {WGAdapter.get_server_listen_port()}")
        print(f" wg0 IP      : {WGAdapter.get_wg_ip()}")
        print(f" Public IP   : {WGAdapter.get_public_ip()}")
        print(f" Conf file   : {os.path.join(WG_DIR, WG_IF + '.conf')}")
        print(f" Clients dir : {CLIENT_DIR}")
        print("-----------------------------------------")
        try:
            os.system(f"wg show {WG_IF}")
        except Exception:
            pass

    def restart_wg(self):
        os.system(f"systemctl restart wg-quick@{WG_IF}")
        print("wg-quick 重启完成。")

    def stop_wg(self):
        os.system(f"systemctl stop wg-quick@{WG_IF}")
        print("wg-quick 已停止。")

    # ---- 监控中心 ----
    def dashboard_once(self):
        peers = self.engine.tick()
        print(T("dashboard_title"))
        print("")
        active = os.system(f"systemctl is-active --quiet wg-quick@{WG_IF}") == 0
        print(" " + (T("dashboard_service_running") if active else T("dashboard_service_stopped")))
        print("")
        wg_ip = WGAdapter.get_wg_ip()
        pub_ip = WGAdapter.get_public_ip()
        port = WGAdapter.get_server_listen_port() or 0
        print(" " + T("dashboard_wg_ip", ip=wg_ip))
        print(" " + T("dashboard_pub_ip", ip=pub_ip))
        print(" " + T("dashboard_port", port=port))
        online_count = sum(1 for st in peers.values() if st.online)
        total_rx = sum(st.rx_rate for st in peers.values()) / 1024
        total_tx = sum(st.tx_rate for st in peers.values()) / 1024
        print(" " + T("dashboard_online", count=online_count))
        print(" " + T("dashboard_rate", rx=total_rx, tx=total_tx))
        print("==================================================")

    def live_monitor(self, interval: float = 2.0):
        """
        简单实时监控：每 interval 秒刷新一次状态。
        Ctrl+C 退出。
        """
        print("Ctrl+C 退出实时监控。")
        try:
            while True:
                os.system("clear")
                self.dashboard_once()
                print("")
                self.client_list_detailed()
                time.sleep(interval)
        except KeyboardInterrupt:
            print("\n已退出实时监控。")

    # ---- 日志中心 ----
    def show_log_tail(self, path: str, n: int = 50):
        print(T("logs_tail", path=path, n=n))
        print("--------------------------------------------------")
        try:
            if os.path.exists(path):
                os.system(f"tail -n {n} {path}")
            else:
                print("(文件不存在)")
        except Exception:
            print("(无法读取日志)")
        print("--------------------------------------------------")

# -------------------- 菜单 --------------------
VERSION = "v1.40-pro"

def ensure_root():
    if os.geteuid() != 0:
        print(T("not_root"))
        sys.exit(1)

def switch_lang():
    global LANG
    if LANG == "zh":
        LANG = "en"
        print(T("lang_switched_en"))
    else:
        LANG = "zh"
        print(T("lang_switched_zh"))

def main_menu(ctrl: Controller):
    while True:
        print("")
        print(T("title"))
        print(T("version", version=VERSION))
        print("")
        for line in TEXT[LANG]["menu_main"]:
            print(" " + line)
        print("============================================================")
        choice = input(T("prompt_choice")).strip()
        if choice == "1":
            client_menu(ctrl)
        elif choice == "2":
            service_menu(ctrl)
        elif choice == "3":
            monitor_menu(ctrl)
        elif choice == "4":
            logs_menu(ctrl)
        elif choice == "5":
            security_menu(ctrl)
        elif choice == "8":
            switch_lang()
        elif choice == "9":
            print(T("uninstall_tip"))
            input(T("press_enter"))
        elif choice == "0":
            print("Bye.")
            break
        else:
            print(T("invalid"))

def client_menu(ctrl: Controller):
    while True:
        print("")
        print("========= 客户端管理 / Client Management =========")
        print(" 1) 新增客户端 / Add client")
        print(" 2) 删除客户端 / Delete client")
        print(" 3) 客户端列表（状态 / 流量）/ List clients")
        print(" 4) 客户端事件日志 / Client events")
        print(" 0) 返回 / Back")
        print("==================================================")
        c = input(T("prompt_choice")).strip()
        if c == "1":
            ctrl.client_add()
        elif c == "2":
            ctrl.client_delete()
        elif c == "3":
            ctrl.client_list_detailed()
        elif c == "4":
            ctrl.client_show_events()
        elif c == "0":
            break
        else:
            print(T("invalid"))
        input(T("press_enter"))

def service_menu(ctrl: Controller):
    while True:
        print("")
        print("========= 服务管理 / Service Management =========")
        print(" 1) 查看服务端信息 / Show server info")
        print(" 2) 重启 WireGuard / Restart WireGuard")
        print(" 3) 停止 WireGuard / Stop WireGuard")
        print(" 0) 返回 / Back")
        print("=================================================")
        c = input(T("prompt_choice")).strip()
        if c == "1":
            ctrl.show_server_info()
        elif c == "2":
            ctrl.restart_wg()
        elif c == "3":
            ctrl.stop_wg()
        elif c == "0":
            break
        else:
            print(T("invalid"))
        input(T("press_enter"))

def monitor_menu(ctrl: Controller):
    while True:
        print("")
        print("========= 监控中心 / Monitoring =========")
        print(" 1) 状态总览（单次）/ Dashboard (once)")
        print(" 2) 实时监控（2 秒刷新）/ Live monitor (2s)")
        print(" 0) 返回 / Back")
        print("=========================================")
        c = input(T("prompt_choice")).strip()
        if c == "1":
            ctrl.dashboard_once()
            input(T("press_enter"))
        elif c == "2":
            ctrl.live_monitor(interval=2.0)
        elif c == "0":
            break
        else:
            print(T("invalid"))

def logs_menu(ctrl: Controller):
    while True:
        print("")
        print(T("logs_title"))
        print(" " + T("logs_install"))
        print(" " + T("logs_agent"))
        print(" " + T("logs_clients"))
        print(" " + T("back"))
        print("=========================================")
        c = input(T("prompt_choice")).strip()
        if c == "1":
            ctrl.show_log_tail(INSTALL_LOG, 80)
        elif c == "2":
            ctrl.show_log_tail(AGENT_LOG, 80)
        elif c == "3":
            ctrl.show_log_tail(EVENT_LOG, 80)
        elif c == "0":
            break
        else:
            print(T("invalid"))
        input(T("press_enter"))

def security_menu(ctrl: Controller):
    print("")
    print("========= 安全中心（预留） / Security (reserved) =========")
    print(" 此版本仅提供占位，未来支持黑名单、自动封禁等高级策略。")
    print("=========================================================")
    input(T("press_enter"))

def main():
    ensure_root()
    ctrl = Controller()
    main_menu(ctrl)

if __name__ == "__main__":
    main()
EOF

  chmod +x /opt/wg-agent/wg_agent.py

  info "创建 wg-admin 命令..."
  cat > /usr/local/bin/wg-admin << 'EOF'
#!/usr/bin/env bash
exec python3 /opt/wg-agent/wg_agent.py "$@"
EOF
  chmod +x /usr/local/bin/wg-admin

  success "Python Agent 已安装完成。使用命令 wg-admin 进入管理面板。"
}

# -------------------- 主流程 --------------------
main() {
  info "开始执行 WireGuard 引导安装（Agent 模式）..."
  install_packages

  if [[ ! -f "${WG_DIR}/${WG_IF}.conf" ]]; then
    setup_wireguard
  else
    warn "检测到已有 ${WG_DIR}/${WG_IF}.conf，跳过 WireGuard 初始化。"
  fi

  install_agent

  success "全部完成！之后可直接运行：wg-admin"
}

main "$@"
