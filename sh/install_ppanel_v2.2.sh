#!/bin/bash
# ============================================================================
# PPanel 一键部署脚本 v2.2
# ============================================================================
# 支持系统：
#   - CentOS 7/8/Stream
#   - RHEL 7/8/9
#   - AlmaLinux 8/9
#   - Rocky Linux 8/9
#   - Ubuntu 18.04/20.04/22.04/24.04
#   - Debian 10/11/12
#
# 功能：
#   - 自动检测操作系统类型和版本
#   - 自动识别宝塔面板安装的 Node.js
#   - 创建 node/npm/pm2 全局软链接
#   - 自动生成 ecosystem.config.js
#   - 修复目录和文件权限
#   - PM2 启动 + 开机自启
#   - 日志统一管理 + 自动轮转
#   - 健康检查
#   - SELinux 兼容处理
#   - 防火墙端口提示
#   - 🆕 增强守护自愈（无限重启 + 指数退避 + 健康检查 + 看门狗）
#
# 高并发方案说明：
#   Next.js 官方不建议使用 PM2 cluster 模式，本脚本采用 fork 单实例。
#   如需更高并发，推荐方案：
#     1. 启动多个 Next.js 实例，监听不同端口（如 3002, 3003, 3004）
#     2. 使用 Nginx 反向代理 + upstream 负载均衡
#   示例 Nginx 配置：
#     upstream ppanel_user {
#         server 127.0.0.1:3002;
#         server 127.0.0.1:3003;
#         server 127.0.0.1:3004;
#     }
#     server {
#         listen 80;
#         location / {
#             proxy_pass http://ppanel_user;
#         }
#     }
# ============================================================================

set -euo pipefail

# 脚本版本
SCRIPT_VERSION="2.2.1"

########################################
#           可调配置区 START           #
########################################

# 后端服务目录（ppanel-server 编译好的二进制所在目录）
PANEL_SERVER_DIR="/www/wwwroot/ppanel-server"

# 管理端 Next.js 目录（apps/admin）
ADMIN_WEB_DIR="/www/wwwroot/ppanel-admin-web/apps/admin"

# 用户端 Next.js 目录（apps/user）
USER_WEB_DIR="/www/wwwroot/ppanel-user-web/apps/user"

# 日志目录
LOG_DIR="/www/wwwlogs/ppanel"

# 管理端监听端口
ADMIN_PORT=3001

# 用户端监听端口
USER_PORT=3002

# 是否配置 PM2 开机自启（1=是，0=否）
ENABLE_PM2_STARTUP=1

# 是否安装日志轮转（1=是，0=否）
ENABLE_LOG_ROTATE=1

# 健康检查超时时间（秒）
HEALTH_CHECK_TIMEOUT=30

# 是否跳过健康检查（1=跳过，0=执行）
SKIP_HEALTH_CHECK=0

# 是否跳过系统兼容性检查（1=跳过，0=执行）- 谨慎使用
SKIP_OS_CHECK=0

# 是否启用增强守护（systemd 监控 PM2 + 健康检查定时任务）
ENABLE_ENHANCED_GUARD=1

# 健康检查间隔（分钟）- 用于 cron 定时任务
HEALTH_CHECK_INTERVAL=5

########################################
#           可调配置区 END             #
########################################

# 颜色定义
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# 系统信息变量（稍后填充）
OS_TYPE=""
OS_ID=""
OS_VERSION=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""
INIT_SYSTEM=""
PKG_MANAGER=""
FIREWALL_TYPE=""
SELINUX_STATUS=""

# 日志输出函数
log_info()  { echo -e "${COLOR_BLUE}👉${COLOR_RESET} $1"; }
log_ok()    { echo -e "${COLOR_GREEN}✔${COLOR_RESET} $1"; }
log_warn()  { echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}❌${COLOR_RESET} $1"; }
log_debug() { echo -e "${COLOR_CYAN}🔍${COLOR_RESET} $1"; }

# 错误退出
die() {
  log_error "$1"
  exit 1
}

# 打印分隔标题
print_section() {
  echo ""
  echo -e "${COLOR_BLUE}══════════════════════════════════════${COLOR_RESET}"
  echo -e "${COLOR_BLUE}  $1${COLOR_RESET}"
  echo -e "${COLOR_BLUE}══════════════════════════════════════${COLOR_RESET}"
}

# ============================================================================
# 系统检测函数
# ============================================================================

# 检测操作系统类型和版本
detect_os() {
  if [ -f /etc/os-release ]; then
    # 现代 Linux 发行版
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
    
    case "$OS_ID" in
      centos)
        OS_TYPE="rhel"
        OS_VERSION="CentOS $OS_VERSION_ID"
        ;;
      rhel|redhat)
        OS_TYPE="rhel"
        OS_VERSION="RHEL $OS_VERSION_ID"
        ;;
      almalinux)
        OS_TYPE="rhel"
        OS_VERSION="AlmaLinux $OS_VERSION_ID"
        ;;
      rocky)
        OS_TYPE="rhel"
        OS_VERSION="Rocky Linux $OS_VERSION_ID"
        ;;
      ubuntu)
        OS_TYPE="debian"
        OS_VERSION="Ubuntu $OS_VERSION_ID"
        ;;
      debian)
        OS_TYPE="debian"
        OS_VERSION="Debian $OS_VERSION_ID"
        ;;
      fedora)
        OS_TYPE="rhel"
        OS_VERSION="Fedora $OS_VERSION_ID"
        ;;
      openeuler)
        OS_TYPE="rhel"
        OS_VERSION="openEuler $OS_VERSION_ID"
        ;;
      *)
        OS_TYPE="unknown"
        OS_VERSION="$OS_PRETTY_NAME"
        ;;
    esac
  elif [ -f /etc/redhat-release ]; then
    # 旧版 CentOS/RHEL
    OS_TYPE="rhel"
    OS_VERSION=$(cat /etc/redhat-release)
    OS_ID="centos"
    OS_VERSION_ID=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
  elif [ -f /etc/debian_version ]; then
    # 旧版 Debian
    OS_TYPE="debian"
    OS_VERSION="Debian $(cat /etc/debian_version)"
    OS_ID="debian"
    OS_VERSION_ID=$(cat /etc/debian_version)
  else
    OS_TYPE="unknown"
    OS_VERSION="Unknown"
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
  fi
}

# 检测初始化系统
detect_init_system() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif [ -f /sbin/init ] && /sbin/init --version 2>&1 | grep -q upstart; then
    INIT_SYSTEM="upstart"
  elif [ -f /etc/init.d/cron ] && [ ! -h /etc/init.d/cron ]; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
}

# 检测包管理器
detect_pkg_manager() {
  if command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    PKG_MANAGER="unknown"
  fi
}

# 检测防火墙类型
detect_firewall() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    FIREWALL_TYPE="firewalld"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    FIREWALL_TYPE="ufw"
  elif command -v iptables >/dev/null 2>&1; then
    FIREWALL_TYPE="iptables"
  else
    FIREWALL_TYPE="none"
  fi
}

# 检测 SELinux 状态
detect_selinux() {
  if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
  else
    SELINUX_STATUS="Not Installed"
  fi
}

# 检查系统兼容性
check_os_compatibility() {
  local supported=0
  local major_version
  
  # 提取主版本号
  major_version=$(echo "$OS_VERSION_ID" | cut -d. -f1)
  
  case "$OS_ID" in
    centos)
      if [ "$major_version" -ge 7 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    rhel|redhat)
      if [ "$major_version" -ge 7 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    almalinux)
      if [ "$major_version" -ge 8 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    rocky)
      if [ "$major_version" -ge 8 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    ubuntu)
      if [ "$major_version" -ge 18 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    debian)
      if [ "$major_version" -ge 10 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    fedora)
      if [ "$major_version" -ge 35 ] 2>/dev/null; then
        supported=1
      fi
      ;;
    openeuler)
      supported=1
      ;;
  esac
  
  return $((1 - supported))
}

# 检查必要命令
check_required_commands() {
  local missing_cmds=()
  local required_cmds=(bash grep sed awk cat mkdir chmod chown ln rm mv cp ls sort tail head date id)
  
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done
  
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    die "缺少必要命令: ${missing_cmds[*]}"
  fi
}

# ============================================================================
# 工具函数
# ============================================================================

# 检查并创建软链接
check_and_link() {
  local src="$1"
  local dst="$2"
  
  # 如果目标是普通文件（非软链接），先备份
  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    log_warn "$dst 是一个文件，将备份为 ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi
  
  ln -sf "$src" "$dst"
}

# 端口健康检查
check_port() {
  local port=$1
  local name=$2
  local timeout=$3
  local elapsed=0
  
  log_info "检查 $name (端口 $port)..."
  
  while [ $elapsed -lt $timeout ]; do
    # 优先使用 curl
    if command -v curl >/dev/null 2>&1; then
      if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port" 2>/dev/null | grep -qE "^[23]"; then
        log_ok "$name 已就绪 (端口 $port)"
        return 0
      fi
    # 其次使用 nc
    elif command -v nc >/dev/null 2>&1; then
      if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        log_ok "$name 端口已开放 ($port)"
        return 0
      fi
    # 再次使用 ss
    elif command -v ss >/dev/null 2>&1; then
      if ss -tuln 2>/dev/null | grep -q ":$port "; then
        log_ok "$name 端口已开放 ($port)"
        return 0
      fi
    else
      log_warn "未安装 curl/nc/ss，跳过端口检查"
      return 0
    fi
    
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  log_warn "$name 未能在 ${timeout}s 内响应，请手动检查"
  return 1
}

# 显示防火墙配置提示
show_firewall_hints() {
  echo ""
  log_info "防火墙配置提示 (类型: $FIREWALL_TYPE):"
  echo ""
  
  case "$FIREWALL_TYPE" in
    firewalld)
      echo "    # 开放管理端端口"
      echo "    firewall-cmd --permanent --add-port=$ADMIN_PORT/tcp"
      echo "    # 开放用户端端口"
      echo "    firewall-cmd --permanent --add-port=$USER_PORT/tcp"
      echo "    # 重载防火墙"
      echo "    firewall-cmd --reload"
      ;;
    ufw)
      echo "    # 开放管理端端口"
      echo "    ufw allow $ADMIN_PORT/tcp"
      echo "    # 开放用户端端口"
      echo "    ufw allow $USER_PORT/tcp"
      ;;
    iptables)
      echo "    # 开放管理端端口"
      echo "    iptables -A INPUT -p tcp --dport $ADMIN_PORT -j ACCEPT"
      echo "    # 开放用户端端口"
      echo "    iptables -A INPUT -p tcp --dport $USER_PORT -j ACCEPT"
      echo "    # 保存规则 (CentOS/RHEL)"
      echo "    service iptables save"
      ;;
    none)
      echo "    未检测到活动的防火墙"
      ;;
  esac
  echo ""
}

# 处理 SELinux
handle_selinux() {
  if [ "$SELINUX_STATUS" = "Enforcing" ]; then
    log_warn "检测到 SELinux 为 Enforcing 模式"
    log_info "为 PM2 和应用端口配置 SELinux..."
    
    # 允许 Node.js 绑定端口
    if command -v semanage >/dev/null 2>&1; then
      semanage port -a -t http_port_t -p tcp "$ADMIN_PORT" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$ADMIN_PORT" 2>/dev/null || true
      semanage port -a -t http_port_t -p tcp "$USER_PORT" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$USER_PORT" 2>/dev/null || true
      log_ok "SELinux 端口规则已添加"
    else
      log_warn "未安装 semanage，请手动配置 SELinux 或设置为 Permissive 模式"
      echo "    临时设置: setenforce 0"
      echo "    永久设置: 编辑 /etc/selinux/config 将 SELINUX=enforcing 改为 SELINUX=permissive"
    fi
  fi
}

########################################
#             主逻辑开始               #
########################################

print_section "PPanel 一键部署 v$SCRIPT_VERSION"

# ========== Step 0: 系统检测 ==========
print_section "Step 0: 系统环境检测"

log_info "检测操作系统..."
detect_os
detect_init_system
detect_pkg_manager
detect_firewall
detect_selinux

echo ""
echo -e "  ${COLOR_CYAN}操作系统:${COLOR_RESET}    $OS_VERSION ($OS_PRETTY_NAME)"
echo -e "  ${COLOR_CYAN}系统类型:${COLOR_RESET}    $OS_TYPE"
echo -e "  ${COLOR_CYAN}初始化系统:${COLOR_RESET}  $INIT_SYSTEM"
echo -e "  ${COLOR_CYAN}包管理器:${COLOR_RESET}    $PKG_MANAGER"
echo -e "  ${COLOR_CYAN}防火墙:${COLOR_RESET}      $FIREWALL_TYPE"
echo -e "  ${COLOR_CYAN}SELinux:${COLOR_RESET}     $SELINUX_STATUS"
echo ""

# 检查系统兼容性
if [ "$SKIP_OS_CHECK" -eq 0 ]; then
  if ! check_os_compatibility; then
    echo ""
    log_error "不支持的操作系统: $OS_VERSION"
    echo ""
    echo "支持的系统："
    echo "  - CentOS 7/8/Stream"
    echo "  - RHEL 7/8/9"
    echo "  - AlmaLinux 8/9"
    echo "  - Rocky Linux 8/9"
    echo "  - Ubuntu 18.04/20.04/22.04/24.04"
    echo "  - Debian 10/11/12"
    echo "  - Fedora 35+"
    echo "  - openEuler"
    echo ""
    echo "如需强制运行，请设置 SKIP_OS_CHECK=1"
    exit 1
  fi
  log_ok "系统兼容性检查通过"
else
  log_warn "跳过系统兼容性检查 (SKIP_OS_CHECK=1)"
fi

# 检查初始化系统
if [ "$INIT_SYSTEM" != "systemd" ]; then
  log_warn "检测到非 systemd 系统 ($INIT_SYSTEM)"
  log_warn "PM2 开机自启可能需要手动配置"
fi

# 检查必要命令
check_required_commands
log_ok "必要命令检查通过"

# ========== Step 1: 检查 root 权限 ==========
print_section "Step 1: 检查运行权限"

if [ "$(id -u)" -ne 0 ]; then
  die "请使用 root 用户运行此脚本！使用: sudo $0"
fi
log_ok "已确认 root 权限"

# ========== Step 2: 识别 Node.js ==========
print_section "Step 2: 识别 Node.js"

NODE_BASE_DIR="/www/server/nodejs"

if [ ! -d "$NODE_BASE_DIR" ]; then
  die "未找到 $NODE_BASE_DIR 目录，请先在宝塔面板安装 Node.js 管理器"
fi

# 找到最新版本的 Node 目录（只匹配 v 开头的版本目录，如 v20.10.0）
NODE_PATH=$(ls -d "$NODE_BASE_DIR"/v[0-9]* 2>/dev/null | sort -V | tail -n 1)
[ -z "$NODE_PATH" ] && die "未在 $NODE_BASE_DIR 找到 Node 版本目录（应为 v20.x.x 格式）"

NODE_BIN="$NODE_PATH/bin/node"
NPM_BIN="$NODE_PATH/bin/npm"

[ ! -f "$NODE_BIN" ] && die "未找到 Node 可执行文件：$NODE_BIN"
[ ! -f "$NPM_BIN" ] && die "未找到 npm 可执行文件：$NPM_BIN"

NODE_VERSION=$("$NODE_BIN" --version 2>/dev/null || echo "unknown")
NPM_VERSION=$("$NPM_BIN" --version 2>/dev/null || echo "unknown")

log_ok "Node 路径: $NODE_PATH"
log_ok "Node 版本: $NODE_VERSION"
log_ok "npm 版本: $NPM_VERSION"

# ========== Step 3: 创建软链接 ==========
print_section "Step 3: 创建软链接"

check_and_link "$NODE_BIN" "/usr/bin/node"
check_and_link "$NODE_BIN" "/usr/local/bin/node"
check_and_link "$NPM_BIN" "/usr/bin/npm"
check_and_link "$NPM_BIN" "/usr/local/bin/npm"

log_ok "node / npm 已链接到 /usr/bin 和 /usr/local/bin"

# ========== Step 4: 检查 PM2 ==========
print_section "Step 4: 检查 PM2"

# 按优先级查找 PM2
PM2_BIN=""
POSSIBLE_PATHS=(
  "$NODE_PATH/lib/node_modules/pm2/bin/pm2"
  "$NODE_PATH/bin/pm2"
)

for path in "${POSSIBLE_PATHS[@]}"; do
  if [ -f "$path" ]; then
    PM2_BIN="$path"
    break
  fi
done

# 最后尝试系统 PATH
if [ -z "$PM2_BIN" ]; then
  if command -v pm2 >/dev/null 2>&1; then
    PM2_BIN="$(command -v pm2)"
  else
    die "未检测到 PM2，请在宝塔 Node.js 管理器中安装 PM2"
  fi
fi

check_and_link "$PM2_BIN" "/usr/bin/pm2"
check_and_link "$PM2_BIN" "/usr/local/bin/pm2"

PM2_VERSION=$(pm2 --version 2>/dev/null || echo "unknown")
log_ok "PM2 路径: $PM2_BIN"
log_ok "PM2 版本: $PM2_VERSION"

# ========== Step 5: 检查目录和文件 ==========
print_section "Step 5: 检查目录结构"

[ ! -d "$PANEL_SERVER_DIR" ] && die "后端目录不存在：$PANEL_SERVER_DIR"
[ ! -d "$ADMIN_WEB_DIR" ]    && die "管理端目录不存在：$ADMIN_WEB_DIR"
[ ! -d "$USER_WEB_DIR" ]     && die "用户端目录不存在：$USER_WEB_DIR"

PANEL_SERVER_BIN="$PANEL_SERVER_DIR/ppanel-server"
[ ! -f "$PANEL_SERVER_BIN" ]          && die "未找到后端二进制：$PANEL_SERVER_BIN"
[ ! -f "$ADMIN_WEB_DIR/server.js" ]   && die "未找到管理端入口：$ADMIN_WEB_DIR/server.js"
[ ! -f "$USER_WEB_DIR/server.js" ]    && die "未找到用户端入口：$USER_WEB_DIR/server.js"

log_ok "目录和文件检查通过"

# ========== Step 6: 创建日志目录 ==========
print_section "Step 6: 准备日志目录"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

log_ok "日志目录: $LOG_DIR"

# ========== Step 7: 设置权限 ==========
print_section "Step 7: 设置权限"

chmod +x "$PANEL_SERVER_BIN"
chmod -R 755 "$ADMIN_WEB_DIR"
chmod -R 755 "$USER_WEB_DIR"

log_ok "权限设置完成"

# ========== Step 8: 处理 SELinux ==========
if [ "$OS_TYPE" = "rhel" ] && [ "$SELINUX_STATUS" = "Enforcing" ]; then
  print_section "Step 8: 处理 SELinux"
  handle_selinux
fi

# ========== Step 9: 生成 PM2 配置 ==========
print_section "Step 9: 生成 PM2 配置"

ECOSYSTEM_FILE="/www/ecosystem.config.js"

# 备份旧配置
if [ -f "$ECOSYSTEM_FILE" ]; then
  BACKUP_FILE="${ECOSYSTEM_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$ECOSYSTEM_FILE" "$BACKUP_FILE"
  log_warn "已备份旧配置: $BACKUP_FILE"
fi

cat > "$ECOSYSTEM_FILE" << EOF
/**
 * PPanel PM2 配置文件
 * 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
 * 脚本版本: $SCRIPT_VERSION
 * 操作系统: $OS_VERSION
 * Node 版本: $NODE_VERSION
 * PM2 版本: $PM2_VERSION
 *
 * 注意：Next.js 官方不建议使用 PM2 cluster 模式
 * 如需更高并发，请使用 Nginx 反代 + 多端口多实例方案
 */

module.exports = {
  apps: [
    // 后端服务 (Go 二进制)
    {
      name: "ppanel-server",
      cwd: "$PANEL_SERVER_DIR",
      script: "./ppanel-server",
      args: ["run", "--config", "$PANEL_SERVER_DIR/etc/ppanel.yaml"],
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: "500M",
      min_uptime: "10s",
      max_restarts: 999999,       // 极大值，等效于无限重启
      restart_delay: 4000,
      exp_backoff_restart_delay: 1000, // 指数退避，避免疯狂重启
      out_file: "$LOG_DIR/ppanel-server.out.log",
      error_file: "$LOG_DIR/ppanel-server.err.log",
      merge_logs: true,
      time: true,
      env: {
        NODE_ENV: "production"
      }
    },

    // 管理端 Next.js (fork 单实例)
    {
      name: "ppanel-admin",
      cwd: "$ADMIN_WEB_DIR",
      script: "server.js",
      interpreter: "node",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: "1G",
      min_uptime: "10s",
      max_restarts: 999999,       // 极大值，等效于无限重启
      restart_delay: 4000,
      exp_backoff_restart_delay: 1000, // 指数退避
      out_file: "$LOG_DIR/ppanel-admin.out.log",
      error_file: "$LOG_DIR/ppanel-admin.err.log",
      merge_logs: true,
      time: true,
      env: {
        NODE_ENV: "production",
        PORT: $ADMIN_PORT
      }
    },

    // 用户端 Next.js (fork 单实例)
    {
      name: "ppanel-user",
      cwd: "$USER_WEB_DIR",
      script: "server.js",
      interpreter: "node",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: "1G",
      min_uptime: "10s",
      max_restarts: 999999,       // 极大值，等效于无限重启
      restart_delay: 4000,
      exp_backoff_restart_delay: 1000, // 指数退避
      out_file: "$LOG_DIR/ppanel-user.out.log",
      error_file: "$LOG_DIR/ppanel-user.err.log",
      merge_logs: true,
      time: true,
      env: {
        NODE_ENV: "production",
        PORT: $USER_PORT
      }
    }
  ]
};
EOF

log_ok "配置文件已生成: $ECOSYSTEM_FILE"
echo "    管理端端口: $ADMIN_PORT"
echo "    用户端端口: $USER_PORT"

# ========== Step 10: 启动 PM2 ==========
print_section "Step 10: 启动 PM2 应用"

log_info "清理旧进程..."
pm2 delete ppanel-server ppanel-admin ppanel-user 2>/dev/null || true
# 兼容旧脚本的进程名
pm2 delete ppaneladmin ppaneluser 2>/dev/null || true

log_info "启动应用..."
if ! pm2 start "$ECOSYSTEM_FILE"; then
  die "PM2 启动失败，请检查配置"
fi

log_info "等待进程稳定 (5秒)..."
sleep 5

pm2 ls

# ========== Step 11: 健康检查 ==========
if [ "$SKIP_HEALTH_CHECK" -eq 0 ]; then
  print_section "Step 11: 健康检查"
  
  check_port "$ADMIN_PORT" "管理端" "$HEALTH_CHECK_TIMEOUT" || true
  check_port "$USER_PORT" "用户端" "$HEALTH_CHECK_TIMEOUT" || true
else
  log_info "跳过健康检查 (SKIP_HEALTH_CHECK=1)"
fi

# ========== Step 12: 开机自启 ==========
if [ "$ENABLE_PM2_STARTUP" -eq 1 ]; then
  print_section "Step 12: 配置开机自启"
  
  pm2 save --force
  
  # 根据初始化系统选择正确的参数
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    pm2 startup systemd -u root --hp /root 2>/dev/null || log_warn "PM2 startup 配置失败，请手动执行: pm2 startup"
  elif [ "$INIT_SYSTEM" = "upstart" ]; then
    pm2 startup upstart -u root --hp /root 2>/dev/null || log_warn "PM2 startup 配置失败，请手动执行: pm2 startup"
  else
    pm2 startup 2>/dev/null || log_warn "PM2 startup 配置失败，请手动执行: pm2 startup"
  fi
  
  pm2 save --force
  
  log_ok "PM2 开机自启已配置"
else
  log_info "跳过开机自启配置 (ENABLE_PM2_STARTUP=0)"
fi

# ========== Step 13: 日志轮转 ==========
if [ "$ENABLE_LOG_ROTATE" -eq 1 ]; then
  print_section "Step 13: 配置日志轮转"
  
  # 检查是否已安装
  if pm2 list 2>/dev/null | grep -q "pm2-logrotate"; then
    log_ok "pm2-logrotate 已安装"
  else
    log_info "安装 pm2-logrotate..."
    pm2 install pm2-logrotate 2>/dev/null || log_warn "安装失败，请手动执行: pm2 install pm2-logrotate"
  fi
  
  # 配置轮转参数
  pm2 set pm2-logrotate:max_size 50M 2>/dev/null || true
  pm2 set pm2-logrotate:retain 7 2>/dev/null || true
  pm2 set pm2-logrotate:compress true 2>/dev/null || true
  pm2 set pm2-logrotate:dateFormat YYYY-MM-DD_HH-mm-ss 2>/dev/null || true
  
  log_ok "日志轮转: 50M/文件, 保留7份, 启用压缩"
else
  log_info "跳过日志轮转配置 (ENABLE_LOG_ROTATE=0)"
fi

# ========== Step 14: 增强守护 ==========
if [ "$ENABLE_ENHANCED_GUARD" -eq 1 ]; then
  print_section "Step 14: 配置增强守护"
  
  # ---------- 14.1 创建健康检查脚本 ----------
  log_info "创建健康检查脚本..."
  
  HEALTH_SCRIPT="/www/scripts/ppanel-health-check.sh"
  mkdir -p /www/scripts
  
  cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# ============================================================================
# PPanel 健康检查与自愈脚本
# 由 install_ppanel_v2.1.sh 自动生成
# ============================================================================

LOG_FILE="/www/wwwlogs/ppanel/health-check.log"
MAX_LOG_SIZE=10485760  # 10MB

# 日志函数
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 轮转日志
rotate_log() {
  if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
    log "日志已轮转"
  fi
}

# 检查 PM2 daemon 是否运行
check_pm2_daemon() {
  if ! pgrep -x "PM2" >/dev/null 2>&1 && ! pgrep -f "pm2" >/dev/null 2>&1; then
    log "⚠️ PM2 daemon 未运行，尝试恢复..."
    pm2 resurrect 2>/dev/null || pm2 start /www/ecosystem.config.js 2>/dev/null
    if pgrep -f "pm2" >/dev/null 2>&1; then
      log "✅ PM2 daemon 已恢复"
    else
      log "❌ PM2 daemon 恢复失败"
    fi
  fi
}

# 检查单个应用状态
check_app() {
  local app_name=$1
  local app_port=$2
  
  # 检查 PM2 中的状态
  local status=$(pm2 jlist 2>/dev/null | grep -o "\"name\":\"$app_name\"[^}]*\"status\":\"[^\"]*\"" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
  
  if [ "$status" != "online" ]; then
    log "⚠️ $app_name 状态异常: $status，尝试重启..."
    pm2 restart "$app_name" 2>/dev/null
    sleep 3
    
    local new_status=$(pm2 jlist 2>/dev/null | grep -o "\"name\":\"$app_name\"[^}]*\"status\":\"[^\"]*\"" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [ "$new_status" = "online" ]; then
      log "✅ $app_name 已恢复"
    else
      log "❌ $app_name 恢复失败，状态: $new_status"
    fi
    return
  fi
  
  # 如果有端口，检查端口响应
  if [ -n "$app_port" ] && [ "$app_port" != "0" ]; then
    if command -v curl >/dev/null 2>&1; then
      local http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:$app_port" 2>/dev/null)
      if ! echo "$http_code" | grep -qE "^[23]"; then
        log "⚠️ $app_name 端口 $app_port 无响应 (HTTP $http_code)，尝试重启..."
        pm2 restart "$app_name" 2>/dev/null
        sleep 5
        log "✅ $app_name 已重启"
      fi
    fi
  fi
}

# 主逻辑
main() {
  rotate_log
  
  # 检查 PM2 daemon
  check_pm2_daemon
  
  # 检查各应用
  check_app "ppanel-server" "0"
HEALTHEOF

  # 动态添加端口检查（使用实际配置的端口）
  cat >> "$HEALTH_SCRIPT" << EOF
  check_app "ppanel-admin" "$ADMIN_PORT"
  check_app "ppanel-user" "$USER_PORT"
}

main
EOF

  chmod +x "$HEALTH_SCRIPT"
  log_ok "健康检查脚本: $HEALTH_SCRIPT"
  
  # ---------- 14.2 创建 systemd 服务（监控 PM2） ----------
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    log_info "创建 PM2 守护服务..."
    
    cat > /etc/systemd/system/ppanel-guard.service << EOF
[Unit]
Description=PPanel PM2 Guardian Service
After=network.target

[Service]
Type=forking
User=root
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$NODE_PATH/bin
ExecStart=/usr/bin/pm2 start /www/ecosystem.config.js --no-daemon
ExecReload=/usr/bin/pm2 reload all
ExecStop=/usr/bin/pm2 stop all
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 创建 PM2 看门狗服务
    cat > /etc/systemd/system/ppanel-watchdog.service << EOF
[Unit]
Description=PPanel Watchdog - Health Check Service
After=ppanel-guard.service

[Service]
Type=oneshot
ExecStart=$HEALTH_SCRIPT
EOF

    cat > /etc/systemd/system/ppanel-watchdog.timer << EOF
[Unit]
Description=PPanel Watchdog Timer
After=ppanel-guard.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=${HEALTH_CHECK_INTERVAL}min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable ppanel-watchdog.timer 2>/dev/null || true
    systemctl start ppanel-watchdog.timer 2>/dev/null || true
    
    log_ok "systemd 守护服务已配置"
    log_ok "健康检查间隔: 每 ${HEALTH_CHECK_INTERVAL} 分钟"
  else
    # ---------- 14.3 非 systemd 系统使用 cron ----------
    log_info "配置 cron 定时健康检查..."
    
    # 移除旧的 cron 任务
    crontab -l 2>/dev/null | grep -v "ppanel-health-check" | crontab - 2>/dev/null || true
    
    # 添加新的 cron 任务
    (crontab -l 2>/dev/null; echo "*/${HEALTH_CHECK_INTERVAL} * * * * $HEALTH_SCRIPT >/dev/null 2>&1") | crontab -
    
    log_ok "cron 健康检查已配置 (每 ${HEALTH_CHECK_INTERVAL} 分钟)"
  fi
  
  log_ok "增强守护配置完成"
else
  log_info "跳过增强守护配置 (ENABLE_ENHANCED_GUARD=0)"
fi

# ========== Step 15: 记录部署信息 ==========
print_section "Step 15: 记录部署信息"

DEPLOY_LOG="$LOG_DIR/deploy.log"
cat >> "$DEPLOY_LOG" << EOF

========================================
部署时间: $(date '+%Y-%m-%d %H:%M:%S')
脚本版本: $SCRIPT_VERSION
----------------------------------------
操作系统: $OS_VERSION
系统类型: $OS_TYPE
内核版本: $(uname -r)
初始化系统: $INIT_SYSTEM
包管理器: $PKG_MANAGER
防火墙: $FIREWALL_TYPE
SELinux: $SELINUX_STATUS
----------------------------------------
Node 版本: $NODE_VERSION
npm 版本: $NPM_VERSION
PM2 版本: $PM2_VERSION
Node 路径: $NODE_PATH
----------------------------------------
管理端端口: $ADMIN_PORT
用户端端口: $USER_PORT
----------------------------------------
增强守护: $([ "$ENABLE_ENHANCED_GUARD" -eq 1 ] && echo "已启用" || echo "未启用")
健康检查间隔: ${HEALTH_CHECK_INTERVAL} 分钟
健康检查脚本: /www/scripts/ppanel-health-check.sh
----------------------------------------
配置文件: $ECOSYSTEM_FILE
日志目录: $LOG_DIR
========================================
EOF

log_ok "部署日志: $DEPLOY_LOG"

# ========== 完成 ==========
print_section "🎉 部署完成"

echo ""
echo -e "${COLOR_GREEN}系统信息:${COLOR_RESET}"
echo "  操作系统: $OS_VERSION"
echo "  SELinux:  $SELINUX_STATUS"
echo "  防火墙:   $FIREWALL_TYPE"
echo ""
echo -e "${COLOR_GREEN}服务状态:${COLOR_RESET}"
pm2 ls
echo ""
echo -e "${COLOR_GREEN}常用命令:${COLOR_RESET}"
echo "  查看状态:       pm2 ls"
echo "  查看所有日志:   pm2 logs"
echo "  查看后端日志:   pm2 logs ppanel-server"
echo "  查看管理端日志: pm2 logs ppanel-admin"
echo "  查看用户端日志: pm2 logs ppanel-user"
echo "  重启所有服务:   pm2 restart all"
echo ""
if [ "$ENABLE_ENHANCED_GUARD" -eq 1 ]; then
  echo -e "${COLOR_GREEN}守护命令:${COLOR_RESET}"
  echo "  手动健康检查:   /www/scripts/ppanel-health-check.sh"
  echo "  查看健康日志:   tail -f $LOG_DIR/health-check.log"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "  看门狗状态:     systemctl status ppanel-watchdog.timer"
    echo "  看门狗日志:     journalctl -u ppanel-watchdog"
  fi
  echo ""
fi
echo -e "${COLOR_GREEN}访问地址:${COLOR_RESET}"
echo "  管理端: http://<服务器IP>:$ADMIN_PORT"
echo "  用户端: http://<服务器IP>:$USER_PORT"
echo ""
echo -e "${COLOR_GREEN}日志目录:${COLOR_RESET} $LOG_DIR"

# 显示防火墙提示
if [ "$FIREWALL_TYPE" != "none" ]; then
  show_firewall_hints
fi

echo ""
