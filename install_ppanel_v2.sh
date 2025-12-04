#!/bin/bash
# ============================================================================
# PPanel 一键部署脚本 v2.0
# ============================================================================
# 功能：
#   - 自动识别宝塔面板安装的 Node.js
#   - 创建 node/npm/pm2 全局软链接
#   - 自动生成 ecosystem.config.js
#   - 修复目录和文件权限
#   - PM2 启动 + 开机自启
#   - 日志统一管理 + 自动轮转
#   - 健康检查
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

########################################
#           可调配置区 END             #
########################################

# 颜色定义
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# 日志输出函数
log_info()  { echo -e "${COLOR_BLUE}👉${COLOR_RESET} $1"; }
log_ok()    { echo -e "${COLOR_GREEN}✔${COLOR_RESET} $1"; }
log_warn()  { echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}❌${COLOR_RESET} $1"; }

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
    else
      log_warn "未安装 curl 或 nc，跳过端口检查"
      return 0
    fi
    
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  log_warn "$name 未能在 ${timeout}s 内响应，请手动检查"
  return 1
}

########################################
#             主逻辑开始               #
########################################

print_section "PPanel 一键部署 v2.0"

# ========== Step 0: 检查 root 权限 ==========
log_info "检查运行权限..."
if [ "$(id -u)" -ne 0 ]; then
  die "请使用 root 用户运行此脚本！使用: sudo $0"
fi
log_ok "已确认 root 权限"

# ========== Step 1: 识别 Node.js ==========
print_section "Step 1: 识别 Node.js"

NODE_BASE_DIR="/www/server/nodejs"

if [ ! -d "$NODE_BASE_DIR" ]; then
  die "未找到 $NODE_BASE_DIR 目录，请先在宝塔面板安装 Node.js 管理器"
fi

# 找到最新版本的 Node 目录
NODE_PATH=$(find "$NODE_BASE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -n 1)
[ -z "$NODE_PATH" ] && die "未在 $NODE_BASE_DIR 找到 Node 版本目录"

NODE_BIN="$NODE_PATH/bin/node"
NPM_BIN="$NODE_PATH/bin/npm"

[ ! -f "$NODE_BIN" ] && die "未找到 Node 可执行文件：$NODE_BIN"
[ ! -f "$NPM_BIN" ] && die "未找到 npm 可执行文件：$NPM_BIN"

NODE_VERSION=$("$NODE_BIN" --version 2>/dev/null || echo "unknown")
NPM_VERSION=$("$NPM_BIN" --version 2>/dev/null || echo "unknown")

log_ok "Node 路径: $NODE_PATH"
log_ok "Node 版本: $NODE_VERSION"
log_ok "npm 版本: $NPM_VERSION"

# ========== Step 2: 创建软链接 ==========
print_section "Step 2: 创建软链接"

check_and_link "$NODE_BIN" "/usr/bin/node"
check_and_link "$NODE_BIN" "/usr/local/bin/node"
check_and_link "$NPM_BIN" "/usr/bin/npm"
check_and_link "$NPM_BIN" "/usr/local/bin/npm"

log_ok "node / npm 已链接到 /usr/bin 和 /usr/local/bin"

# ========== Step 3: 检查 PM2 ==========
print_section "Step 3: 检查 PM2"

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

# ========== Step 4: 检查目录和文件 ==========
print_section "Step 4: 检查目录结构"

[ ! -d "$PANEL_SERVER_DIR" ] && die "后端目录不存在：$PANEL_SERVER_DIR"
[ ! -d "$ADMIN_WEB_DIR" ]    && die "管理端目录不存在：$ADMIN_WEB_DIR"
[ ! -d "$USER_WEB_DIR" ]     && die "用户端目录不存在：$USER_WEB_DIR"

PANEL_SERVER_BIN="$PANEL_SERVER_DIR/ppanel-server"
[ ! -f "$PANEL_SERVER_BIN" ]          && die "未找到后端二进制：$PANEL_SERVER_BIN"
[ ! -f "$ADMIN_WEB_DIR/server.js" ]   && die "未找到管理端入口：$ADMIN_WEB_DIR/server.js"
[ ! -f "$USER_WEB_DIR/server.js" ]    && die "未找到用户端入口：$USER_WEB_DIR/server.js"

log_ok "目录和文件检查通过"

# ========== Step 5: 创建日志目录 ==========
print_section "Step 5: 准备日志目录"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

log_ok "日志目录: $LOG_DIR"

# ========== Step 6: 设置权限 ==========
print_section "Step 6: 设置权限"

chmod +x "$PANEL_SERVER_BIN"
chmod -R 755 "$ADMIN_WEB_DIR"
chmod -R 755 "$USER_WEB_DIR"

log_ok "权限设置完成"

# ========== Step 7: 生成 PM2 配置 ==========
print_section "Step 7: 生成 PM2 配置"

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
      max_memory_restart: "1G",
      min_uptime: "10s",
      max_restarts: 10,
      restart_delay: 4000,
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
      max_restarts: 10,
      restart_delay: 4000,
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
      max_memory_restart: "2G",
      min_uptime: "10s",
      max_restarts: 10,
      restart_delay: 4000,
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

# ========== Step 8: 启动 PM2 ==========
print_section "Step 8: 启动 PM2 应用"

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

# ========== Step 9: 健康检查 ==========
if [ "$SKIP_HEALTH_CHECK" -eq 0 ]; then
  print_section "Step 9: 健康检查"
  
  check_port "$ADMIN_PORT" "管理端" "$HEALTH_CHECK_TIMEOUT" || true
  check_port "$USER_PORT" "用户端" "$HEALTH_CHECK_TIMEOUT" || true
else
  log_info "跳过健康检查 (SKIP_HEALTH_CHECK=1)"
fi

# ========== Step 10: 开机自启 ==========
if [ "$ENABLE_PM2_STARTUP" -eq 1 ]; then
  print_section "Step 10: 配置开机自启"
  
  pm2 save --force
  pm2 startup systemd -u root --hp /root 2>/dev/null || true
  pm2 save --force
  
  log_ok "PM2 开机自启已配置"
else
  log_info "跳过开机自启配置 (ENABLE_PM2_STARTUP=0)"
fi

# ========== Step 11: 日志轮转 ==========
if [ "$ENABLE_LOG_ROTATE" -eq 1 ]; then
  print_section "Step 11: 配置日志轮转"
  
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

# ========== Step 12: 记录部署信息 ==========
print_section "Step 12: 记录部署信息"

DEPLOY_LOG="$LOG_DIR/deploy.log"
cat >> "$DEPLOY_LOG" << EOF

========================================
部署时间: $(date '+%Y-%m-%d %H:%M:%S')
----------------------------------------
Node 版本: $NODE_VERSION
npm 版本: $NPM_VERSION
PM2 版本: $PM2_VERSION
Node 路径: $NODE_PATH
----------------------------------------
管理端端口: $ADMIN_PORT
用户端端口: $USER_PORT
----------------------------------------
配置文件: $ECOSYSTEM_FILE
日志目录: $LOG_DIR
========================================
EOF

log_ok "部署日志: $DEPLOY_LOG"

# ========== 完成 ==========
print_section "🎉 部署完成"

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
echo -e "${COLOR_GREEN}访问地址:${COLOR_RESET}"
echo "  管理端: http://<服务器IP>:$ADMIN_PORT"
echo "  用户端: http://<服务器IP>:$USER_PORT"
echo ""
echo -e "${COLOR_GREEN}日志目录:${COLOR_RESET} $LOG_DIR"
echo ""
