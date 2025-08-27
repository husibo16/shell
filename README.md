#!/usr/bin/env bash
# ===================================================================
# 名称: xxxx
# 用途: 完整智能版 Bash 标准模板（生产可用，可扩展子命令）
# 版本: xxxxxx
# 作者: 胡博涵
# 更新: xxxxxx
# 许可: xxx
# ===================================================================

# ---------------------- 严格模式与兼容性 ----------------------
set -Eeuo pipefail
set -o errtrace
shopt -s extglob
IFS=$'\n\t'

# ---------------------- 常量与默认值 -------------------------
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

# ---------------------- 颜色与时间戳 -------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_supports_color() { [[ -t 1 ]] && [[ "${NO_COLOR}" == "false" ]]; }
if _supports_color; then
  _c_reset=$'\033[0m'; _c_info=$'\033[1;34m'; _c_warn=$'\033[1;33m'
  _c_err=$'\033[1;31m'; _c_ok=$'\033[1;32m'; _c_dbg=$'\033[2m'
else
  _c_reset=""; _c_info=""; _c_warn=""; _c_err=""; _c_ok=""; _c_dbg=""
fi

rainbow_text() {
  local text="$1"
  if ! _supports_color; then
    echo "$text"
    return
  fi
  local colors=($'\033[31m' $'\033[33m' $'\033[32m' $'\033[36m' $'\033[34m' $'\033[35m')
  local reset=$'\033[0m'
  local out="" c
  for ((i=0; i<${#text}; i++)); do
    c=${colors[$((i % ${#colors[@]}))]}
    out+="${c}${text:i:1}${reset}"
  done
  echo -e "$out"
}

log__() {
  local level="$1"; shift
  local msg="$*"
  local line="[$(_ts)] $msg"
  local no_color
  no_color=$(echo -e "$line" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
  if [[ "$QUIET" == "true" && "$level" != "ERROR" && "$level" != "WARN" ]]; then
    :
  else
    echo -e "$line"
  fi
  echo "$no_color" >>"$LOG_FILE"
}
log_info()    { log__ INFO    "${_c_info}[INFO]${_c_reset}  $*"; }
log_warn()    { log__ WARN    "${_c_warn}[WARN]${_c_reset}  $*"; }
log_error()   { log__ ERROR   "${_c_err}[ERROR]${_c_reset} $*"; }
log_success() { log__ OK      "${_c_ok}[ OK ]${_c_reset}  $*"; }
log_debug()   { [[ "$DEBUG" == true ]] || return 0; log__ DEBUG "${_c_dbg}[DEBUG] $*${_c_reset}"; }
die() { log_error "$*"; exit 1; }

# ---------------------- 输出重定向（可选） -------------------
_enable_tee_log() {
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_debug "启用 TEE 日志重定向: $LOG_FILE"
}

# ---------------------- 帮助与版本 ---------------------------
print_version() {
  cat <<EOF_VER
$SCRIPT_NAME 3.0.1
Bash >= ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}，跨平台（Linux/macOS）友好
EOF_VER
}
print_usage() {
  cat <<'EOF_USAGE'
用法:
  smart_template.sh <子命令> [选项] [--] [子命令参数...]

子命令:
  greet        打印问候（示例业务）
  status       展示运行环境状态（示例业务）
  help         显示帮助
  version      显示版本

通用选项（放在子命令前后皆可）:
  -n, --name <NAME>        指定名字（greet 子命令可用）
  -d, --debug              调试模式（打印 DEBUG 日志）
  -q, --quiet              静默模式（仅 WARN/ERROR 终端输出）
  -L, --log-file <FILE>    指定日志文件（默认 /tmp/<name>.<pid>.log）
      --tee-log            将所有输出 tee 到日志（慎用）
      --no-color           关闭彩色输出
  -c, --config <FILE>      指定 .env 配置文件（KEY=VALUE）
  -h, --help               显示帮助
  -V, --version            显示版本

示例:
  ./smart_template.sh greet -n Alice --debug
  ./smart_template.sh status --log-file /tmp/app.log --no-color
  ./smart_template.sh greet --config .env
EOF_USAGE
}

# ---------------------- 依赖与环境检查 ----------------------
require_bash() {
  local major=${BASH_VERSINFO[0]} minor=${BASH_VERSINFO[1]}
  if (( major < MIN_BASH_MAJOR || (major == MIN_BASH_MAJOR && minor < MIN_BASH_MINOR) )); then
    die "需要 Bash >= ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}，当前: ${BASH_VERSION}"
  fi
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限"; }

# ---------------------- .env / 配置加载 ----------------------
load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || die "配置文件不存在: $f"
  log_info "加载配置: $f"
  while IFS='=' read -r k v; do
    k="${k%%[[:space:]]*}"; v="${v%%[[:space:]]*}"
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    export "$k=$v"
    log_debug "env: $k=$v"
  done < <(sed -e 's/[[:space:]]*[#].*$//' -e '/^[[:space:]]*$/d' "$f")
}

# ---------------------- 并发锁与临时目录 --------------------
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
      die "检测到并发执行（锁被占用）: $LOCK_FILE"
    fi
    log_debug "已获取锁: $LOCK_FILE"
  else
    log_warn "未找到 flock，跳过加锁（可能出现并发冲突）。建议安装 util-linux（Linux）或相应包。"
  fi
}
TMP_DIR=""
mk_tmpdir() {
  TMP_DIR="$(mktemp -d -t "${SCRIPT_NAME%.sh}.XXXXXX")"
  log_debug "TMP_DIR=$TMP_DIR"
}

# ---------------------- 网络信息（本机 IP 获取） ------------------
#
# get_local_ip: 尝试通过 hostname、ip 或 ifconfig 获取本机 IPv4 地址；
# 若全部不可用则返回 <unknown>
get_local_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$ip" ]]; then
    if command -v ip >/dev/null 2>&1; then
      ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    elif command -v ifconfig >/dev/null 2>&1; then
      ip=$(ifconfig 2>/dev/null | awk '/inet / {print $2}' | grep -v '127.0.0.1' | head -n1)
    fi
  fi
  echo "${ip:-<unknown>}"
}

# ---------------------- 重试/超时/确认 ----------------------
retry() {
  local max="$1"; shift
  local sleep_s="$1"; shift
  local n=1
  until "$@"; do
    local code=$?
    if (( n >= max )); then
      log_error "命令重试 ${n}/${max} 次后仍失败(code=$code): $*"
      return "$code"
    fi
    log_warn "命令失败(code=$code)，${n}/${max} 次重试，等待 ${sleep_s}s: $*"
    sleep "$sleep_s"
    ((n++))
  done
}
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    log_warn "未找到 timeout，直接执行（无超时保护）: $*"
    "$@"
  fi
}
confirm() {
  local prompt="${1:-Are you sure?} [y/N] "
  read -r -p "$prompt" ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------------------- 错误与清理 trap --------------------
error_handler() {
  local exit_code=$?
  local cmd=${BASH_COMMAND:-unknown}
  local line_no=${BASH_LINENO[0]:-unknown}
  log_error "出错: exit=${exit_code}, line=${line_no}, cmd=${cmd}"
  for i in "${!FUNCNAME[@]}"; do
    [[ $i -eq 0 ]] && continue
    log_debug "stack[$i]: func=${FUNCNAME[$i]} line=${BASH_LINENO[$((i-1))]} file=${BASH_SOURCE[$i]}"
  done
  exit "$exit_code"
}
cleanup() {
  { flock -u 200; } 2>/dev/null || true
  rm -f "$LOCK_FILE"
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  log_info "已清理资源"
}
trap error_handler ERR
trap cleanup EXIT INT TERM HUP

# ---------------------- 参数解析（GNU/BSD 兼容） -----------
parse_args() {
  local gnu_getopt_ok=false
  # 正确识别 GNU getopt：退出码为 4 视为 GNU
  if getopt --test >/dev/null 2>&1; then
    : # 某些实现返回 0（极少见）
  else
    [[ $? -eq 4 ]] && gnu_getopt_ok=true
  fi

  if [[ "$gnu_getopt_ok" == "true" ]]; then
    local short="n:dqL:c:hV"
    local long="name:,debug,quiet,log-file:,tee-log,no-color,config:,help,version"

    # 先解析所有选项；`--` 后面的第一个参数才是子命令
    local parsed
    parsed=$(getopt -o "$short" -l "$long" -n "$SCRIPT_NAME" -- "$@") || {
      print_usage; exit 1;
    }
    eval set -- "$parsed"
    while true; do
      case "$1" in
        -n|--name) NAME="$2"; shift 2 ;;
        -d|--debug) DEBUG=true; shift ;;
        -q|--quiet) QUIET=true; shift ;;
        -L|--log-file) LOG_FILE="$2"; shift 2 ;;
        --tee-log) TEE_LOG=true; shift ;;
        --no-color) NO_COLOR=true; shift ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
        -V|--version) print_version; exit 0 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    SUBCOMMAND="${1:-}"; [[ $# -gt 0 ]] && shift || true
    ARGS_REST=("$@")
  else
    # 回退：仅短选项；解析完成后第一个剩余参数为子命令
    while getopts ":n:dqL:c:hV" opt; do
      case $opt in
        n) NAME="$OPTARG" ;;
        d) DEBUG=true ;;
        q) QUIET=true ;;
        L) LOG_FILE="$OPTARG" ;;
        c) CONFIG_FILE="$OPTARG" ;;
        h) print_usage; exit 0 ;;
        V) print_version; exit 0 ;;
        \?) die "无效选项: -$OPTARG" ;;
        :)  die "选项 -$OPTARG 需要参数" ;;
      esac
    done
    shift $((OPTIND - 1))
    SUBCOMMAND="${1:-}"; [[ $# -gt 0 ]] && shift || true
    ARGS_REST=("$@")
  fi
}

# ---------------------- 交互式选择子命令 -------------------
interactive_select() {
  PS3="请选择子命令: "
  local opts=(greet status help version quit)
  select opt in "${opts[@]}"; do
    case "$opt" in
      greet|status|help|version)
        SUBCOMMAND="$opt"
        break
        ;;
      quit)
        exit 0
        ;;
      *)
        echo "无效选项"
        ;;
    esac
  done
}

# ---------------------- 子命令实现（示例） -------------------
cmd_greet() {
  if [[ -z "$NAME" ]]; then
    read -r -p "请输入名字: " NAME
    [[ -z "$NAME" ]] && die "greet 需要名字"
  fi
  log_info "准备问候..."
  log_debug "NAME=$NAME"
  rainbow_text "Hello, $NAME!"
}
cmd_status() {
  log_info "环境状态："
  local labels=("Script" "Dir" "IP" "PID" "Bash" "LogFile" "Debug" "Quiet" "TmpDir")
  local values=("$SCRIPT_NAME" "$SCRIPT_DIR" "$(get_local_ip)" "$PID" "$BASH_VERSION" "$LOG_FILE" "$DEBUG" "$QUIET" "${TMP_DIR:-<未创建>}")
  local colors=($'\033[31m' $'\033[33m' $'\033[32m' $'\033[36m' $'\033[34m' $'\033[35m')
  for i in "${!labels[@]}"; do
    if _supports_color; then
      local idx=$(( i % ${#colors[@]} ))
      printf "  %b%-8s%b : %s\n" "${colors[$idx]}" "${labels[i]}" "$_c_reset" "${values[i]}"
    else
      printf "  %-8s : %s\n" "${labels[i]}" "${values[i]}"
    fi
  done
}

load_plugins() {
  local d="$SCRIPT_DIR/scripts.d"
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.sh; do
    [[ -e "$f" ]] || continue
    log_info "加载插件: $f"
    # shellcheck source=/dev/null
    source "$f"
  done
}

# ---------------------- 主入口 ------------------------------
main() {
  require_bash
  parse_args "$@"
  if [[ -z "$SUBCOMMAND" ]]; then
    interactive_select
  fi

  : >"$LOG_FILE" || die "无法写日志文件: $LOG_FILE"
  log_info "启动 $SCRIPT_NAME (pid=$PID)"

  [[ "$TEE_LOG" == "true" ]] && _enable_tee_log
  [[ -n "$CONFIG_FILE" ]] && load_env_file "$CONFIG_FILE"

  acquire_lock
  mk_tmpdir
  load_plugins

  require_cmd echo

  case "$SUBCOMMAND" in
    greet)   cmd_greet "${ARGS_REST[@]+"${ARGS_REST[@]}"}" ;;
    status)  cmd_status ;;
    help)    print_usage ;;
    version) print_version ;;
    *)       log_warn "未知子命令: $SUBCOMMAND"; print_usage; exit 1 ;;
  esac

  log_success "执行完成"
}

main "$@"
