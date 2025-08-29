#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2015,SC1111
# ===================================================================
# 名称: snipeit_installer.sh
# 用途: 在 Ubuntu Server 上完整部署 Snipe-IT（含 Node.js、Git、Redis、Supervisor、LDAP、SMTP邮箱配置）
# 版本: 3.1.1
# 作者: 胡博涵
# 更新: 2025-08-27
# 许可: MIT
# ===================================================================

# ---------------------- 严格模式与兼容性 ----------------------
set -Eeuo pipefail
set -o errtrace
shopt -s extglob
IFS=$'\n\t'

# ---------------------- 常量与默认值（严格对齐你的 .env 字段） -------------------------
# 注: 脚本内置的固定参数与默认设置, 如无特殊需求可保持不变
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PID="$$"
readonly DEFAULT_LOG_FILE="/tmp/${SCRIPT_NAME%.sh}.${PID}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.sh}.lock"
readonly MIN_BASH_MAJOR=4
readonly MIN_BASH_MINOR=2

DEBUG=false
QUIET=false
NO_COLOR=false
TEE_LOG=false
LOG_FILE="$DEFAULT_LOG_FILE"
CONFIG_FILE=""
NAME=""
SUBCOMMAND=""
ARGS_REST=()

# ============ 部署参数（可通过 -c 配置文件覆盖，KEY=VALUE） ============
# 注: 在外部配置文件中以 KEY=VALUE 形式声明, 再通过 -c <文件> 引入即可覆盖
# App 基础
APP_DIR="${APP_DIR:-/var/www/snipe-it}"
APP_URL="${APP_URL:-http://$(hostname -I 2>/dev/null | awk '{print $1}')}"
APP_TIMEZONE="${APP_TIMEZONE:-Asia/Shanghai}"
APP_LOCALE="${APP_LOCALE:-zh-CN}"
SERVER_NAME="${SERVER_NAME:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

# 数据库
DB_CONNECTION="${DB_CONNECTION:-mysql}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_SOCKET="${DB_SOCKET:-null}"
DB_DATABASE="${DB_DATABASE:-snipeit}"
DB_USERNAME="${DB_USERNAME:-snipeit}"
DB_PASSWORD="${DB_PASSWORD:-StrongPassword1166!}"
DB_PREFIX="${DB_PREFIX:-null}"
DB_DUMP_PATH="${DB_DUMP_PATH:-/usr/bin}"
DB_DUMP_SKIP_SSL="${DB_DUMP_SKIP_SSL:-false}"
DB_CHARSET="${DB_CHARSET:-utf8mb4}"
DB_COLLATION="${DB_COLLATION:-utf8mb4_unicode_ci}"
DB_SANITIZE_BY_DEFAULT="${DB_SANITIZE_BY_DEFAULT:-false}"

# 邮件（严格按你贴出的字段）
MAIL_MAILER="${MAIL_MAILER:-smtp}"
MAIL_HOST="${MAIL_HOST:-180.168.100.46}"
MAIL_PORT="${MAIL_PORT:-25}"
MAIL_USERNAME="${MAIL_USERNAME:-hudajun}"
MAIL_PASSWORD="${MAIL_PASSWORD:-sz1234}"
MAIL_FROM_ADDR="${MAIL_FROM_ADDR:-hudajun@strongcasa.com}"
MAIL_FROM_NAME="${MAIL_FROM_NAME:-Snipe-IT}"
MAIL_REPLYTO_ADDR="${MAIL_REPLYTO_ADDR:-hudajun@strongcasa.com}"
MAIL_REPLYTO_NAME="${MAIL_REPLYTO_NAME:-Snipe-IT}"
MAIL_AUTO_EMBED_METHOD="${MAIL_AUTO_EMBED_METHOD:-attachment}"
MAIL_TLS_VERIFY_PEER="${MAIL_TLS_VERIFY_PEER:-false}"

# 会话/队列/缓存（与你模板一致）
SESSION_DRIVER="${SESSION_DRIVER:-file}"
QUEUE_DRIVER="${QUEUE_DRIVER:-sync}"
CACHE_DRIVER="${CACHE_DRIVER:-file}"
CACHE_PREFIX="${CACHE_PREFIX:-snipeit}"

# Redis（默认 null，启用后写入 127.0.0.1:6379）
REDIS_HOST="${REDIS_HOST:-null}"
REDIS_PASSWORD="${REDIS_PASSWORD:-null}"
REDIS_PORT="${REDIS_PORT:-null}"

# Nginx 是否自动装 HTTPS（此脚本只配 80；HTTPS 可后续扩展子命令）
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

# ---------------------- 彩色与装饰 -------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_supports_color() { [[ -t 1 ]] && [[ ${NO_COLOR} == "false" ]]; }
if _supports_color; then
  _c_reset=$'\033[0m'
  _c_info=$'\033[1;34m'
  _c_warn=$'\033[1;33m'
  _c_err=$'\033[1;31m'
  _c_ok=$'\033[1;32m'
  _c_title=$'\033[1;35m'
  _c_dbg=$'\033[2m'
else
  _c_reset=""
  _c_info=""
  _c_warn=""
  _c_err=""
  _c_ok=""
  _c_title=""
  _c_dbg=""
fi

banner() {
  local text="$1" line
  line=$(printf '%*s' "${#text}" '' | tr ' ' '-')
  echo -e "${_c_title}${line}${_c_reset}"
  echo -e "${_c_title}${text}${_c_reset}"
  echo -e "${_c_title}${line}${_c_reset}"
}

log__() {
  local level="$1"
  shift
  local msg="$*"
  local line="[$(_ts)] $msg"
  local no_color
  no_color=$(echo -e "$line" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
  if [[ $QUIET == "true" && $level != "ERROR" && $level != "WARN" ]]; then :; else echo -e "$line"; fi
  echo "$no_color" >>"$LOG_FILE"
}
log_info() { log__ INFO "${_c_info}[信息]${_c_reset}  $*"; }
log_warn() { log__ WARN "${_c_warn}[警告]${_c_reset}  $*"; }
log_error() { log__ ERROR "${_c_err}[错误]${_c_reset}  $*"; }
log_success() { log__ OK "${_c_ok}[成功]${_c_reset}  $*"; }
log_debug() {
  [[ $DEBUG == true ]] || return 0
  log__ DEBUG "${_c_dbg}[调试] $*${_c_reset}"
}
die() {
  log_error "$*"
  exit 1
}

_enable_tee_log() {
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_debug "TEE 日志: $LOG_FILE"
}

# ---------------------- 帮助与版本 ---------------------------
print_version() {
  cat <<EOF_VER
$SCRIPT_NAME 3.1.1
Bash >= ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}，Snipe-IT 全量安装器（中文交互/彩色输出）
EOF_VER
}
print_usage() {
  cat <<'EOF_USAGE'
用法:
  snipeit_installer.sh <子命令> [选项] [--] [参数...]

子命令（中文交互友好）:
  体检_precheck          环境体检/基础工具安装（含 Git）
  安装_db_mariadb        安装并初始化 MariaDB，创建库和账户
  安装_php               安装 PHP(自动识别次版本) 及扩展 + PHP-FPM
  安装_composer          安装 Composer
  安装_node              安装 Node.js & npm
  安装_redis             安装并启用 Redis
  安装_supervisor        安装并配置 Supervisor（Laravel 队列）
  拉取_配置_snipeit      克隆 Snipe-IT 并生成/校正 .env（SMTP/Redis/APP_URL）
  配置_nginx             安装并配置 Nginx（指向 public/）
  初始化_依赖_数据库     composer 依赖 + APP_KEY + migrate（可选演示数据）
  配置_防火墙            UFW 放行 OpenSSH & Nginx Full
  测试_smtp              测试到 SMTP 主机:端口的连通性（不发信）
  一键全装               按最佳顺序执行全部步骤
  状态_status            展示环境信息（IP/PHP/FPM 等）
  帮助_help              显示帮助
  版本_version           显示版本
EOF_USAGE
}

# ---------------------- 依赖与环境检查 ----------------------
require_bash() {
  local major=${BASH_VERSINFO[0]} minor=${BASH_VERSINFO[1]}
  ((major > MIN_BASH_MAJOR || (major == MIN_BASH_MAJOR && minor >= MIN_BASH_MINOR))) || die "需要 Bash >= ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}，当前: ${BASH_VERSION}"
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限"; }

# ---------------------- .env / 配置加载 ----------------------
load_env_file() {
  local f="$1"
  [[ -f $f ]] || die "配置文件不存在: $f"
  log_info "加载配置文件: $f"
  while IFS='=' read -r k v; do
    k="${k%%[[:space:]]*}"
    v="${v%%[[:space:]]*}"
    [[ -z $k || $k =~ ^# ]] && continue
    v="${v%\"}"
    v="${v#\"}"
    v="${v%'}"
      v="${v#'}"
    export "$k=$v"
    log_debug "ENV: $k=$v"
  done < <(sed -e 's/[[:space:]]*[#].*$//' -e '/^[[:space:]]*$/d' "$f")
}

# ---------------------- 并发锁与临时目录 --------------------
acquire_lock() {
  command -v flock >/dev/null 2>&1 && {
    exec 200>"$LOCK_FILE"
    flock -n 200 || die "并发执行检测到，锁被占用: $LOCK_FILE"
    log_debug "已获取锁"
  } || log_warn "系统无 flock，跳过加锁"
}
TMP_DIR=""
mk_tmpdir() {
  TMP_DIR="$(mktemp -d -t "${SCRIPT_NAME%.sh}.XXXXXX")"
  log_debug "TMP_DIR=$TMP_DIR"
}

# ---------------------- 网络信息 ----------------------
get_local_ip() {
  local ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n $ip ]] || ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-<unknown>}"
}

# ---------------------- 重试/超时/确认 ----------------------
retry() {
  local max="$1" sleep_s="$2"
  shift 2
  local n=1
  until "$@"; do
    local code=$?
    ((n >= max)) && {
      log_error "重试${n}/${max}失败: $*"
      return "$code"
    }
    log_warn "失败(code=$code)，${n}/${max}，${sleep_s}s后重试: $*"
    sleep "$sleep_s"
    ((n++))
  done
}
with_timeout() {
  local secs="$1"
  shift
  command -v timeout >/dev/null 2>&1 && timeout "$secs" "$@" || {
    log_warn "无 timeout：$*"
    "$@"
  }
}
confirm() {
  local p="${1:-确认执行吗?} [y/N] "
  read -r -p "$p" a || true
  [[ ${a,,} =~ ^(y|yes)$ ]]
}

# ---------------------- 错误与清理 trap --------------------
error_handler() {
  local exit_code=$? cmd=${BASH_COMMAND:-unknown} line_no=${BASH_LINENO[0]:-unknown}
  log_error "出错: exit=${exit_code}, line=${line_no}, cmd=${cmd}"
  for i in "${!FUNCNAME[@]}"; do
    [[ $i -eq 0 ]] && continue
    log_debug "stack[$i]: func=${FUNCNAME[$i]} line=${BASH_LINENO[$((i - 1))]} file=${BASH_SOURCE[$i]}"
  done
  exit "$exit_code"
}
cleanup() {
  { flock -u 200; } 2>/dev/null || true
  rm -f "$LOCK_FILE"
  [[ -n ${TMP_DIR:-} && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
  log_info "已清理临时资源"
}
trap error_handler ERR
trap cleanup EXIT INT TERM HUP

# ---------------------- 参数解析 ---------------------------
parse_args() {
  local gnu=false
  getopt --test >/dev/null 2>&1 || [[ $? -eq 4 ]] && gnu=true
  if $gnu; then
    local short="dqL:c:hV"
    local long="debug,quiet,log-file:,tee-log,no-color,config:,help,version"
    local parsed
    parsed=$(getopt -o "$short" -l "$long" -n "$SCRIPT_NAME" -- "$@") || {
      print_usage
      exit 1
    }
    eval set -- "$parsed"
    while true; do
      case "$1" in
        -d | --debug)
          DEBUG=true
          shift
          ;;
        -q | --quiet)
          QUIET=true
          shift
          ;;
        -L | --log-file)
          LOG_FILE="$2"
          shift 2
          ;;
        --tee-log)
          TEE_LOG=true
          shift
          ;;
        --no-color)
          NO_COLOR=true
          shift
          ;;
        -c | --config)
          CONFIG_FILE="$2"
          shift 2
          ;;
        -h | --help)
          print_usage
          exit 0
          ;;
        -V | --version)
          print_version
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *) break ;;
      esac
    done
    SUBCOMMAND="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    ARGS_REST=("$@")
  else
    while getopts ":dqL:c:hV" opt; do
      case $opt in
        d) DEBUG=true ;; q) QUIET=true ;; L) LOG_FILE="$OPTARG" ;;
        c) CONFIG_FILE="$OPTARG" ;; h)
          print_usage
          exit 0
          ;;
        V)
          print_version
          exit 0
          ;;
        \?) die "无效选项: -$OPTARG" ;; :) die "选项 -$OPTARG 需要参数" ;;
      esac
    done
    shift $((OPTIND - 1))
    SUBCOMMAND="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    ARGS_REST=("$@")
  fi
}

# ---------------------- 中文交互菜单 ---------------------------
interactive_menu() {
  while true; do
    echo
    banner "★ Snipe-IT 全量安装器（中文交互）★"
    cat <<'EOF_MENU'
  1) 体检_precheck          - 环境体检/基础工具安装（含 Git）
  2) 安装_db_mariadb        - 安装并初始化 MariaDB，创建库和账户
  3) 安装_php               - 安装 PHP(自动识别次版本) 及扩展 + PHP-FPM
  4) 安装_composer          - 安装 Composer
  5) 安装_node              - 安装 Node.js & npm
  6) 安装_redis             - 安装并启用 Redis
  7) 安装_supervisor        - 安装并配置 Supervisor（Laravel 队列）
  8) 拉取_配置_snipeit      - 克隆 Snipe-IT 并生成/校正 .env
  9) 配置_nginx             - 安装并配置 Nginx（指向 public/）
 10) 初始化_依赖_数据库     - composer 依赖 + APP_KEY + migrate
 11) 配置_防火墙            - UFW 放行 OpenSSH & Nginx Full
 12) 测试_smtp              - 测试到 SMTP 主机:端口的连通性（不发信）
 13) 一键全装               - 按最佳顺序执行全部步骤
 14) 状态_status            - 展示环境信息（IP/PHP/FPM 等）
  q) 退出
EOF_MENU
    read -r -p "👉 你的选择: " choice
    case "$choice" in
      1) SUBCOMMAND="体检_precheck" ;;
      2) SUBCOMMAND="安装_db_mariadb" ;;
      3) SUBCOMMAND="安装_php" ;;
      4) SUBCOMMAND="安装_composer" ;;
      5) SUBCOMMAND="安装_node" ;;
      6) SUBCOMMAND="安装_redis" ;;
      7) SUBCOMMAND="安装_supervisor" ;;
      8) SUBCOMMAND="拉取_配置_snipeit" ;;
      9) SUBCOMMAND="配置_nginx" ;;
      10) SUBCOMMAND="初始化_依赖_数据库" ;;
      11) SUBCOMMAND="配置_防火墙" ;;
      12) SUBCOMMAND="测试_smtp" ;;
      13) SUBCOMMAND="一键全装" ;;
      14) SUBCOMMAND="状态_status" ;;
      q | Q) SUBCOMMAND="退出_quit" ;;
      *)
        echo -e "${_c_err}无效选项${_c_reset}"
        continue
        ;;
    esac
    break
  done
}

# ---------------------- 工具函数 ---------------------------
php_minor() { php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.3"; }
php_fpm_sock() { echo "/var/run/php/php$(php_minor)-fpm.sock"; }
ensure_service() {
  systemctl enable "$1"
  systemctl restart "$1"
  systemctl --no-pager --full status "$1" | sed -n '1,5p' || true
}
set_kv() {
  local file="$1" key="$2" val="$3" esc
  touch "$file"
  esc=$(printf '%s' "$val" | sed -e 's/[\\/\&|]/\\&/g')
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

# ---------------------- 子命令实现 -------------------------
cmd_precheck() {
  require_root
  banner "① 环境体检 / 基础工具"
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  apt install -y curl wget unzip vim htop git ca-certificates lsb-release apt-transport-https gnupg
  log_success "基础工具安装完成（含 Git）"
}

cmd_install_db() {
  require_root
  banner "② 安装 MariaDB"
  apt install -y mariadb-server mariadb-client
  ensure_service mariadb
  mysql -uroot --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_DATABASE}\` CHARACTER SET ${DB_CHARSET} COLLATE ${DB_COLLATION};
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_DATABASE}\`.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
SQL
  log_info "建议执行: mysql_secure_installation 进一步加固 root 账号"
  log_success "数据库就绪：db=${DB_DATABASE} user=${DB_USERNAME}"
}

cmd_install_php() {
  require_root
  local pv="$(php_minor)"
  banner "③ 安装 PHP ${pv} + 扩展 + FPM"
  apt install -y "php${pv}-fpm" "php${pv}-cli" "php${pv}-common" \
    "php${pv}-bcmath" "php${pv}-curl" "php${pv}-gd" "php${pv}-mbstring" \
    "php${pv}-mysql" "php${pv}-xml" "php${pv}-zip" "php${pv}-intl" "php${pv}-readline" \
    "php${pv}-redis" "php${pv}-ldap"
  phpenmod opcache redis ldap || true
  ensure_service "php${pv}-fpm"
  log_success "PHP 安装完成，FPM sock: $(php_fpm_sock)"
}

cmd_install_composer() {
  require_root
  banner "④ 安装 Composer"
  if command -v composer >/dev/null 2>&1; then
    log_info "Composer 已安装：$(composer --version)"
  else
    apt install -y composer
  fi
  log_success "Composer 就绪"
}

cmd_install_node() {
  require_root
  banner "⑤ 安装 Node.js & npm"
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt install -y nodejs
  node -v
  npm -v || true
  log_success "Node.js & npm 就绪"
}

cmd_install_redis() {
  require_root
  banner "⑥ 安装 Redis"
  apt install -y redis-server
  ensure_service redis-server
  log_success "Redis 服务已启用"
}

cmd_install_supervisor() {
  require_root
  banner "⑦ 安装 Supervisor（队列守护）"
  apt install -y supervisor
  cat >/etc/supervisor/conf.d/snipeit-worker.conf <<EOF_SUP
[program:snipeit-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${APP_DIR}/artisan queue:work --sleep=3 --tries=3
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/supervisor/snipeit-worker.log
stopasgroup=true
killasgroup=true
EOF_SUP
  supervisorctl reread || true
  supervisorctl update || true
  log_success "Supervisor 已配置（应用目录就绪后自动生效）"
}

cmd_snipe_download() {
  require_root
  banner "⑧ 拉取 Snipe-IT 代码并准备 .env"
  mkdir -p "$(dirname "$APP_DIR")"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    git clone https://github.com/snipe/snipe-it.git "$APP_DIR"
  else
    git -C "$APP_DIR" pull --ff-only || true
  fi
  cd "$APP_DIR"
  [[ -f .env ]] || cp .env.example .env
  chown -R www-data:www-data "$APP_DIR"
  log_success "源码与初始 .env 就绪"
}

cmd_snipe_config_env() {
  require_root
  banner "⑨ 配置 .env（中文交互 + 智能默认值）"
  cd "$APP_DIR" || die "未找到应用目录: $APP_DIR"
  [[ -f .env ]] || cp .env.example .env

  echo -e "${_c_title}基础设置：${_c_reset}"
  read -r -p "APP_URL [${APP_URL}]: " v || true
  APP_URL="${v:-$APP_URL}"
  read -r -p "SERVER_NAME(Nginx) [${SERVER_NAME}]: " v || true
  SERVER_NAME="${v:-$SERVER_NAME}"
  read -r -p "APP_TIMEZONE [${APP_TIMEZONE}]: " v || true
  APP_TIMEZONE="${v:-$APP_TIMEZONE}"
  read -r -p "APP_LOCALE [${APP_LOCALE}]: " v || true
  APP_LOCALE="${v:-$APP_LOCALE}"

  echo -e "${_c_title}数据库设置：${_c_reset}"
  read -r -p "DB_DATABASE [${DB_DATABASE}]: " v || true
  DB_DATABASE="${v:-$DB_DATABASE}"
  read -r -p "DB_USERNAME [${DB_USERNAME}]: " v || true
  DB_USERNAME="${v:-$DB_USERNAME}"
  read -r -p "DB_PASSWORD [${DB_PASSWORD}]: " v || true
  DB_PASSWORD="${v:-$DB_PASSWORD}"

  echo -e "${_c_title}邮件（SMTP）设置：${_c_reset}"
  read -r -p "MAIL_HOST [${MAIL_HOST}]: " v || true
  MAIL_HOST="${v:-$MAIL_HOST}"
  read -r -p "MAIL_PORT [${MAIL_PORT}]: " v || true
  MAIL_PORT="${v:-$MAIL_PORT}"
  read -r -p "MAIL_USERNAME [${MAIL_USERNAME}]: " v || true
  MAIL_USERNAME="${v:-$MAIL_USERNAME}"
  read -r -p "MAIL_PASSWORD [${MAIL_PASSWORD}]: " v || true
  MAIL_PASSWORD="${v:-$MAIL_PASSWORD}"
  read -r -p "MAIL_FROM_ADDR [${MAIL_FROM_ADDR}]: " v || true
  MAIL_FROM_ADDR="${v:-$MAIL_FROM_ADDR}"
  read -r -p "MAIL_FROM_NAME [${MAIL_FROM_NAME}]: " v || true
  MAIL_FROM_NAME="${v:-$MAIL_FROM_NAME}"
  read -r -p "MAIL_REPLYTO_ADDR [${MAIL_REPLYTO_ADDR}]: " v || true
  MAIL_REPLYTO_ADDR="${v:-$MAIL_REPLYTO_ADDR}"
  read -r -p "MAIL_REPLYTO_NAME [${MAIL_REPLYTO_NAME}]: " v || true
  MAIL_REPLYTO_NAME="${v:-$MAIL_REPLYTO_NAME}"
  read -r -p "MAIL_TLS_VERIFY_PEER (true/false) [${MAIL_TLS_VERIFY_PEER}]: " v || true
  MAIL_TLS_VERIFY_PEER="${v:-$MAIL_TLS_VERIFY_PEER}"

  echo -e "${_c_title}Redis（可选）：${_c_reset}"
  read -r -p "启用 Redis 作为缓存/会话/队列？(y/N): " v || true
  if [[ ${v,,} =~ ^(y|yes)$ ]]; then
    REDIS_HOST="127.0.0.1"
    REDIS_PORT="6379"
    REDIS_PASSWORD=""
    CACHE_DRIVER="redis"
    SESSION_DRIVER="redis"
    QUEUE_DRIVER="redis"
  else
    REDIS_HOST=""
    REDIS_PORT=""
    REDIS_PASSWORD=""
    CACHE_DRIVER="file"
    SESSION_DRIVER="file"
    QUEUE_DRIVER="sync"
  fi

  set_kv ".env" "APP_ENV" "production"
  set_kv ".env" "APP_DEBUG" "false"
  set_kv ".env" "APP_URL" "${APP_URL}"
  set_kv ".env" "APP_TIMEZONE" "'${APP_TIMEZONE}'"
  set_kv ".env" "APP_LOCALE" "'${APP_LOCALE}'"
  set_kv ".env" "MAX_RESULTS" "500"

  set_kv ".env" "DB_CONNECTION" "${DB_CONNECTION}"
  set_kv ".env" "DB_HOST" "${DB_HOST}"
  set_kv ".env" "DB_SOCKET" "${DB_SOCKET}"
  set_kv ".env" "DB_PORT" "${DB_PORT}"
  set_kv ".env" "DB_DATABASE" "${DB_DATABASE}"
  set_kv ".env" "DB_USERNAME" "${DB_USERNAME}"
  set_kv ".env" "DB_PASSWORD" "${DB_PASSWORD}"
  set_kv ".env" "DB_PREFIX" "${DB_PREFIX}"
  set_kv ".env" "DB_DUMP_PATH" "'${DB_DUMP_PATH}'"
  set_kv ".env" "DB_DUMP_SKIP_SSL" "${DB_DUMP_SKIP_SSL}"
  set_kv ".env" "DB_CHARSET" "${DB_CHARSET}"
  set_kv ".env" "DB_COLLATION" "${DB_COLLATION}"
  set_kv ".env" "DB_SANITIZE_BY_DEFAULT" "${DB_SANITIZE_BY_DEFAULT}"

  set_kv ".env" "MAIL_MAILER" "${MAIL_MAILER}"
  set_kv ".env" "MAIL_HOST" "${MAIL_HOST}"
  set_kv ".env" "MAIL_PORT" "${MAIL_PORT}"
  set_kv ".env" "MAIL_USERNAME" "${MAIL_USERNAME}"
  set_kv ".env" "MAIL_PASSWORD" "${MAIL_PASSWORD}"
  set_kv ".env" "MAIL_FROM_ADDR" "${MAIL_FROM_ADDR}"
  set_kv ".env" "MAIL_FROM_NAME" "'${MAIL_FROM_NAME}'"
  set_kv ".env" "MAIL_REPLYTO_ADDR" "${MAIL_REPLYTO_ADDR}"
  set_kv ".env" "MAIL_REPLYTO_NAME" "'${MAIL_REPLYTO_NAME}'"
  set_kv ".env" "MAIL_AUTO_EMBED_METHOD" "'${MAIL_AUTO_EMBED_METHOD}'"
  set_kv ".env" "MAIL_TLS_VERIFY_PEER" "${MAIL_TLS_VERIFY_PEER}"

  set_kv ".env" "IMAGE_LIB" "gd"

  set_kv ".env" "SESSION_DRIVER" "${SESSION_DRIVER}"
  set_kv ".env" "COOKIE_NAME" "snipeit_session"
  set_kv ".env" "PASSPORT_COOKIE_NAME" "'snipeit_passport_token'"
  set_kv ".env" "SECURE_COOKIES" "false"

  set_kv ".env" "CACHE_DRIVER" "${CACHE_DRIVER}"
  set_kv ".env" "QUEUE_DRIVER" "${QUEUE_DRIVER}"
  set_kv ".env" "CACHE_PREFIX" "${CACHE_PREFIX}"

  set_kv ".env" "REDIS_HOST" "${REDIS_HOST}"
  set_kv ".env" "REDIS_PASSWORD" "${REDIS_PASSWORD}"
  set_kv ".env" "REDIS_PORT" "${REDIS_PORT}"

  chown -R www-data:www-data "$APP_DIR"
  log_success ".env 配置完成（严格对齐你的字段名，包括邮箱）"
}

cmd_snipe_dependencies() {
  require_root
  banner "⑪ Composer 依赖 + APP_KEY + 数据库迁移"
  cd "$APP_DIR" || die "未找到应用目录: $APP_DIR"
  require_cmd composer
  composer install --no-dev --prefer-dist --optimize-autoloader
  php artisan key:generate || true
  if confirm "导入演示数据（包含示例资产等）?"; then
    php artisan migrate --seed --force
  else
    php artisan migrate --force
  fi
  chown -R www-data:www-data "$APP_DIR"
  find "$APP_DIR/storage" -type d -exec chmod 775 {} \; || true
  find "$APP_DIR/bootstrap/cache" -type d -exec chmod 775 {} \; || true
  log_success "依赖安装 & 初始化完成"
}

cmd_nginx_config() {
  require_root
  banner "⑩ 配置 Nginx"
  local pv="$(php_minor)"
  command -v nginx >/dev/null 2>&1 || apt install -y nginx
  local conf="/etc/nginx/sites-available/snipeit"
  cat >"$conf" <<NGINX
server {
    listen 80;
    server_name ${SERVER_NAME};

    root ${APP_DIR}/public;
    index index.php index.html;

    access_log /var/log/nginx/snipeit_access.log;
    error_log  /var/log/nginx/snipeit_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${pv}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\. {
        deny all;
    }
}
NGINX
  ln -sf "$conf" /etc/nginx/sites-enabled/snipeit
  [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
  log_success "Nginx 配置完成：server_name=${SERVER_NAME} root=${APP_DIR}/public"
}

cmd_firewall() {
  require_root
  banner "⑫ 配置防火墙 UFW"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH || true
    ufw allow 'Nginx Full' || true
    log_success "已放行 OpenSSH 与 Nginx Full（80/443）"
  else
    log_warn "未检测到 ufw，跳过防火墙设置"
  fi
}

cmd_test_smtp() {
  banner "SMTP 连通性测试（不发送邮件）"
  read -r -p "SMTP 主机 [${MAIL_HOST}]: " v || true
  local host="${v:-$MAIL_HOST}"
  read -r -p "端口 [${MAIL_PORT}]: " v || true
  local port="${v:-$MAIL_PORT}"
  if command -v timeout >/dev/null 2>&1; then
    if timeout 5 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
      log_success "到 ${host}:${port} 可连通"
    else
      log_error "无法连通 ${host}:${port}，检查网络/安全组/白名单/证书策略"
    fi
  else
    log_warn "系统无 timeout，跳过"
  fi
  echo -e "${_c_info}提示：登录 Snipe-IT 后台→设置→邮件，发“测试邮件”验证账号/证书策略。${_c_reset}"
}

cmd_status() {
  banner "环境状态"
  local labels=("脚本" "目录" "IP" "PID" "Bash" "日志" "PHP" "FPM_sock" "AppDir")
  local values=("$SCRIPT_NAME" "$SCRIPT_DIR" "$(get_local_ip)" "$PID" "$BASH_VERSION" "$LOG_FILE" "$(php -v 2>/dev/null | head -n1 || echo N/A)" "$(php_fpm_sock)" "$APP_DIR")
  for i in "${!labels[@]}"; do printf "  %-10s : %s\n" "${labels[i]}" "${values[i]}"; done
}

cmd_install_all() {
  require_root
  banner "🚀 一键全量安装（含 Node.js/Redis/Supervisor/SMTP）"
  cmd_precheck
  cmd_install_db
  cmd_install_php
  cmd_install_composer
  cmd_install_node
  cmd_install_redis
  cmd_install_supervisor
  cmd_snipe_download
  cmd_snipe_config_env
  cmd_nginx_config
  cmd_snipe_dependencies
  cmd_firewall
  log_success "一键安装完成！现在访问：${APP_URL}"
  echo -e "${_c_ok}首次进入初始化向导，创建管理员账户；随后建议开启 HTTPS 与定时备份。${_c_reset}"
}

# ---------------------- 主入口 ------------------------------
main() {
  require_bash
  parse_args "$@"

  : >"$LOG_FILE" || die "无法写日志文件: $LOG_FILE"
  banner "Snipe-IT 安装器启动 (pid=$PID)"
  [[ $TEE_LOG == "true" ]] && _enable_tee_log
  [[ -n $CONFIG_FILE ]] && load_env_file "$CONFIG_FILE"

  acquire_lock
  mk_tmpdir

  run_once=false
  [[ -n $SUBCOMMAND ]] && run_once=true

  while true; do
    if [[ -z $SUBCOMMAND ]]; then
      interactive_menu
      [[ -n $SUBCOMMAND ]] || continue
    fi
    [[ $SUBCOMMAND == "退出_quit" ]] && break

    case "$SUBCOMMAND" in
      体检_precheck) cmd_precheck ;;
      安装_db_mariadb) cmd_install_db ;;
      安装_php) cmd_install_php ;;
      安装_composer) cmd_install_composer ;;
      安装_node) cmd_install_node ;;
      安装_redis) cmd_install_redis ;;
      安装_supervisor) cmd_install_supervisor ;;
      拉取_配置_snipeit)
        cmd_snipe_download
        cmd_snipe_config_env
        ;;
      配置_nginx) cmd_nginx_config ;;
      初始化_依赖_数据库) cmd_snipe_dependencies ;;
      配置_防火墙) cmd_firewall ;;
      测试_smtp) cmd_test_smtp ;;
      一键全装) cmd_install_all ;;
      状态_status) cmd_status ;;
      帮助_help) print_usage ;;
      版本_version) print_version ;;
      *)
        log_warn "未知子命令: $SUBCOMMAND"
        print_usage
        [[ $run_once == true ]] && exit 1
        ;;
    esac

    log_success "执行完成"
    [[ $run_once == true ]] && break
    SUBCOMMAND=""
  done
}

main "$@"