#!/bin/sh
# corp_dns_gateway_posix.sh (v1.1, 2025-08-18)
# 企业 DNS 网关一键部署（POSIX /bin/sh）
# 组件：Unbound(127.0.0.1:5335) + Pi-hole(:53) + Lighttpd(:80)
# 策略：仅国内上游；国外域名不做特殊处理（默认失败，合规）；黑/白名单 + 定时同步
# 兼容：systemd / 非 systemd

set -eu

# ---------------- 可调参数（可 export 覆盖） ----------------
BLOCK_IP="${BLOCK_IP-}"                   # 阻止页/对内 IP（默认自动探测）
PIHOLE_PASS="${PIHOLE_PASS-}"             # Pi-hole 控制台密码；空则自动生成到 /root/pihole_adminpw
CACHE_MIN_TTL="${CACHE_MIN_TTL-3600}"     # Unbound 最小缓存 1h
CACHE_MAX_TTL="${CACHE_MAX_TTL-604800}"   # Unbound 最大缓存 7d

CN_DNS="223.5.5.5 223.6.6.6 119.29.29.29" # 国内公共 DNS
ADLISTS="https://anti-ad.net/easylist.txt https://oisd.nl/basic/"

CUSTOM_BLACKLIST="/etc/pihole/blacklist_custom.txt"
CUSTOM_WHITELIST="/etc/pihole/whitelist_custom.txt"

# 保留系统里已有的 APT 代理配置（不清理）：export KEEP_APT_PROXY=1
KEEP_APT_PROXY="${KEEP_APT_PROXY-0}"
# ----------------------------------------------------------

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }
err(){  printf "[ERR ] %s\n" "$*"  >&2; }
die(){  err "$*"; exit 1; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo sh $0"; }

detect_distro(){
  if [ -r /etc/os-release ]; then . /etc/os-release; info "系统识别：${PRETTY_NAME:-$ID $VERSION_ID}"; fi
}

has(){ command -v "$1" >/dev/null 2>&1; }

is_systemd(){
  command -v systemctl >/dev/null 2>&1 \
  && [ -d /run/systemd/system ] \
  && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ]
}

svc_enable_now(){
  if is_systemd; then
    systemctl enable "$1" >/dev/null 2>&1
    systemctl restart "$1" >/dev/null 2>&1 || systemctl start "$1"
  else
    command -v service >/dev/null 2>&1 && { service "$1" restart >/dev/null 2>&1 || service "$1" start >/dev/null 2>&1 || true; }
  fi
}

start_unbound_nonsd(){
  ss -lntup 2>/dev/null | grep -q ':5335 ' || {
    if command -v start-stop-daemon >/dev/null 2>&1; then
      start-stop-daemon --start --make-pidfile --pidfile /run/unbound.pid --exec /usr/sbin/unbound -- -c /etc/unbound/unbound.conf
    else
      nohup /usr/sbin/unbound -c /etc/unbound/unbound.conf >/var/log/unbound-standalone.log 2>&1 & echo $! >/run/unbound.pid
    fi
  }
}

start_lighttpd_nonsd(){
  ss -lntup 2>/dev/null | grep -q ':80 ' || {
    if command -v start-stop-daemon >/dev/null 2>&1; then
      start-stop-daemon --start --make-pidfile --pidfile /run/lighttpd.pid --exec /usr/sbin/lighttpd -- -f /etc/lighttpd/lighttpd.conf
    else
      nohup /usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf >/var/log/lighttpd-standalone.log 2>&1 & echo $! >/run/lighttpd.pid
    fi
  }
}

backup_file(){ f="$1"; [ -f "$f" ] || return 0; cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true; }

# ===== APT 预处理：清理错误的 Proxy(Auto)Detect 变体 =====
apt_preflight(){
  [ "$KEEP_APT_PROXY" = "1" ] && { info "保留系统现有 APT 代理配置（KEEP_APT_PROXY=1）"; return; }
  info "APT 预检查：清理可能的 Proxy(Auto)Detect 残留..."
  for f in /etc/apt/apt.conf /etc/apt/apt.conf.d/*; do
    [ -f "$f" ] || continue
    if grep -Eq 'Acquire::(http|https)::ProxyAutoDetect|Acquire::ProxyAutoDetect|Acquire::(http|https)::Proxy-Auto-Detect|Acquire::Proxy-Auto-Detect' "$f"; then
      backup_file "$f"
      sed -i -E \
        -e '/Acquire::(http|https)::ProxyAutoDetect/d' \
        -e '/Acquire::ProxyAutoDetect/d' \
        -e '/Acquire::(http|https)::Proxy-Auto-Detect/d' \
        -e '/Acquire::Proxy-Auto-Detect/d' "$f"
    fi
  done
}

# ===== 统一的 apt 执行器：本脚本内强制 DIRECT/禁用自动探测 =====
apt_exec(){
  # 用法：apt_exec update -y  |  apt_exec install -y pkg1 pkg2 ...
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    apt-get \
      -o Acquire::http::Proxy="DIRECT" \
      -o Acquire::https::Proxy="DIRECT" \
      -o Acquire::http::Proxy-Auto-Detect=false \
      -o Acquire::https::Proxy-Auto-Detect=false \
      "$@"
}

ensure_pkgs(){
  info "刷新软件索引..."
  apt_exec update -y
  info "安装依赖：$*"
  DEBIAN_FRONTEND=noninteractive apt_exec install -y --no-install-recommends "$@"
}

get_first_lan_ip(){
  ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 \
  | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1
}

prepare_block_ip(){
  [ -n "${BLOCK_IP-}" ] || BLOCK_IP="$(get_first_lan_ip || true)"
  [ -n "${BLOCK_IP}" ] || die "无法自动探测内网 IPv4，请 export BLOCK_IP=10.x.x.x 后重试"
  info "阻止页/对内服务 IPv4：$BLOCK_IP"
}

temp_set_resolver_for_install(){ backup_file /etc/resolv.conf; printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" >/etc/resolv.conf; }
restore_resolver_note(){ info "保留当前 resolv.conf；部署完成后如需切到 127.0.0.1 再手动调整"; }

fix_systemd_resolved_conflict(){
  if is_systemd && systemctl is-active --quiet systemd-resolved; then
    info "关闭 DNSStubListener 以释放 :53"
    mkdir -p /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/pihole.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved || true
  fi
  if ss -lntup 2>/dev/null | grep -q ':53 '; then
    warn ":53 仍被占用，尝试停用 systemd-resolved（若存在）"
    is_systemd && { systemctl stop systemd-resolved || true; systemctl disable systemd-resolved || true; }
  fi
}

ensure_unbound_main_conf(){
  if [ ! -s /etc/unbound/unbound.conf ]; then
    cat >/etc/unbound/unbound.conf <<'CONF'
server:
  verbosity: 1
include: "/etc/unbound/unbound.conf.d/*.conf"
CONF
  elif ! grep -q 'include: *"/etc/unbound/unbound.conf.d/\*\.conf"' /etc/unbound/unbound.conf 2>/dev/null; then
    echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' >>/etc/unbound/unbound.conf
  fi
}

install_unbound(){
  ensure_pkgs unbound dnsutils
  ensure_unbound_main_conf
  mkdir -p /etc/unbound/unbound.conf.d
  f=/etc/unbound/unbound.conf.d/corp.conf
  info "写入 Unbound 配置：$f"; backup_file "$f"
  {
    cat <<EOF
server:
  interface: 127.0.0.1
  port: 5335
  do-ip4: yes
  do-udp: yes
  do-tcp: yes

  prefetch: yes
  prefetch-key: yes
  cache-min-ttl: ${CACHE_MIN_TTL}
  cache-max-ttl: ${CACHE_MAX_TTL}

  harden-referral-path: yes
  msg-cache-size: 64m
  rrset-cache-size: 128m
  num-threads: 1

forward-zone:
  name: "."
EOF
    for ip in $CN_DNS; do printf "  forward-addr: %s\n" "$ip"; done
  } >"$f"

  if is_systemd; then
    svc_enable_now unbound || { warn "systemctl 操作失败，回退为非 systemd 启动方式"; start_unbound_nonsd; }
    sleep 1
  else
    start_unbound_nonsd; sleep 1
  fi

  ss -lntup 2>/dev/null | grep -q ':5335 ' || die "Unbound 未监听 127.0.0.1:5335，请查 /var/log/unbound-standalone.log 或 journalctl -u unbound"
  info "Unbound 已就绪：127.0.0.1:5335"
}

install_lighthttpd_blockpage(){
  ensure_pkgs lighttpd
  conf=/etc/lighttpd/conf-available/15-blockpage.conf
  info "配置 Lighttpd 阻止页与根跳转"
  cat >"$conf" <<'CONF'
server.modules += ( "mod_redirect" )
url.redirect += ( "^/$" => "/blocked.html" )
CONF
  docroot=/var/www/html; mkdir -p "$docroot"
  if [ ! -f "${docroot}/blocked.html" ]; then
    info "写入默认阻止页：$docroot/blocked.html"
    cat >"${docroot}/blocked.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>访问被阻止</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,Arial;background:#fafafa;color:#222;margin:0}
.wrap{max-width:640px;margin:12vh auto;background:#fff;padding:32px;border-radius:16px;box-shadow:0 6px 24px rgba(0,0,0,.08)}
h1{margin:0 0 12px;font-size:28px;color:#c62828}p{margin:8px 0;line-height:1.8}code{background:#f0f0f0;padding:2px 6px;border-radius:6px}</style>
</head><body><div class="wrap"><h1>⚠️ 访问被阻止</h1><p>该网站域名已被公司 DNS 策略屏蔽。</p><p>若确因工作需要访问，请联系 IT 管理员申请白名单。</p><p style="opacity:.7">This access is blocked by corporate DNS policy. Please contact IT for allowlist if it is for work.</p></div></body></html>
HTML
  fi
  command -v lighty-enable-mod >/dev/null 2>&1 && lighty-enable-mod 15-blockpage >/dev/null 2>&1 || true
  if is_systemd; then
    svc_enable_now lighttpd || { warn "systemctl 操作失败，回退为非 systemd 启动方式"; start_lighttpd_nonsd; }
  else
    start_lighttpd_nonsd
  fi
}

install_pihole_unattended(){
  ensure_pkgs curl ca-certificates git
  IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"; [ -n "$IFACE" ] || IFACE="eth0"

  if [ -z "$PIHOLE_PASS" ]; then
    PIHOLE_PASS="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-14)"
    printf "%s\n" "$PIHOLE_PASS" >/root/pihole_adminpw; chmod 600 /root/pihole_adminpw
    info "随机生成 Pi-hole 控制台密码：保存在 /root/pihole_adminpw"
  fi

  mkdir -p /etc/pihole
  cat >/etc/pihole/setupVars.conf <<EOF
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
WEBPASSWORD=${PIHOLE_PASS}
PIHOLE_INTERFACE=${IFACE}
IPV4_ADDRESS=${BLOCK_IP}/24
IPV6_ADDRESS=
QUERY_LOGGING=true
BLOCKING_ENABLED=true
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
EOF

  if [ ! -d /etc/.pihole ]; then
    info "获取 Pi-hole 安装器..."; git clone --depth=1 https://github.com/pi-hole/pi-hole.git /etc/.pihole
  else
    info "更新 Pi-hole 安装器..."; ( cd /etc/.pihole || exit 0; git pull --ff-only || true )
  fi

  info "无人值守安装 Pi-hole..."; sh "/etc/.pihole/automated install/basic-install.sh" --unattended

  ftl=/etc/pihole/pihole-FTL.conf; touch "$ftl"
  if grep -q '^BLOCKINGMODE=' "$ftl"; then sed -i 's/^BLOCKINGMODE=.*/BLOCKINGMODE=IP/' "$ftl"; else echo "BLOCKINGMODE=IP" >>"$ftl"; fi

  pihole restartdns >/dev/null 2>&1 || true

  info "写入推荐广告源..."
  for u in $ADLISTS; do pihole -a adlist add "$u" >/dev/null 2>&1 || true; done
  pihole -g >/dev/null 2>&1 || true

  info "Pi-hole 控制台：http://${BLOCK_IP}/admin"
  info "管理员密码：${PIHOLE_PASS}"
}

setup_custom_lists_and_cron(){
  : >"$CUSTOM_BLACKLIST" 2>/dev/null || true
  : >"$CUSTOM_WHITELIST" 2>/dev/null || true
  chmod 644 "$CUSTOM_BLACKLIST" "$CUSTOM_WHITELIST" 2>/dev/null || true

  sync=/usr/local/sbin/pihole_sync_lists.sh
  cat >"$sync" <<'SH'
#!/bin/sh
set -eu
BL="/etc/pihole/blacklist_custom.txt"
WL="/etc/pihole/whitelist_custom.txt"

add_lines(){
  file="$1"; cmd="$2"
  [ -f "$file" ] || return 0
  grep -v '^[[:space:]]*$' "$file" | grep -v '^[[:space:]]*#' | while IFS= read -r d; do
    if ! pihole -q -exact "$d" >/dev/null 2>&1; then pihole $cmd "$d" >/dev/null 2>&1 || true; fi
  done
}
add_lines "$BL" "-b"
add_lines "$WL" "-w"
pihole -g >/dev/null 2>&1 || true
pihole restartdns >/dev/null 2>&1 || true
SH
  chmod +x "$sync"

  jitter_cmd='$(awk '"'"'BEGIN{srand();print int(rand()*300)}'"'"')'
  cron=/etc/cron.d/pihole_custom_sync
  {
    echo "SHELL=/bin/sh"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "# 每日 02:30 同步黑白名单并更新规则（带随机抖动）"
    echo "30 2 * * * root sleep ${jitter_cmd}; /usr/local/sbin/pihole_sync_lists.sh"
  } >"$cron"
}

open_firewall_hint(){
  if has nft; then
    info "nftables 存在。以下为建议规则片段（请按你们的策略集整合）："
    cat <<'EOF'

table inet filter {
  chain input {
    type filter hook input priority 0;
    ip saddr {10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16} tcp dport {53,80} accept
    ip saddr {10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16} udp dport 53 accept
  }
}
EOF
  fi
}

post_checks(){
  info "运行健康检查..."
  is_systemd && systemctl is-active --quiet unbound || warn "systemd 显示 Unbound 未运行（可能已回退为非 systemd 启动）"
  ss -lntu | grep -q ':53 ' || die "端口 53 未监听，Pi-hole 可能未成功绑定（journalctl -u pihole-FTL）"
  ss -lntu | grep -q ':80 ' || die "端口 80 未监听，Lighttpd 可能未成功启动"
  has dig && { info "dig @127.0.0.1 taobao.com 测试..."; dig @127.0.0.1 taobao.com +time=2 +tries=1 >/dev/null 2>&1 || warn "dig 测试失败，稍后再试或检查网络"; }
}

print_summary(){
  echo; bold "================ 部署完成（摘要） ================"
  echo "对内 DNS：           ${BLOCK_IP}:53   （Pi-hole）"
  echo "上游解析：           127.0.0.1#5335  （Unbound，仅国内公共 DNS）"
  echo "阻止页：             http://${BLOCK_IP}/  （根路径自动跳转 /blocked.html）"
  echo "Pi-hole 控制台：     http://${BLOCK_IP}/admin"
  [ -n "${PIHOLE_PASS-}" ] && echo "管理员密码：         ${PIHOLE_PASS}" || echo "管理员密码：         <保存在 /root/pihole_adminpw>"
  echo; echo "广告规则源："; for u in $ADLISTS; do echo "  - $u"; done
  echo; echo "自定义黑名单文件：   $CUSTOM_BLACKLIST"
  echo "自定义白名单文件：   $CUSTOM_WHITELIST"
  echo "定时同步任务：       /etc/cron.d/pihole_custom_sync （每日 02:30）"
  echo; bold "常用命令："
  echo "  pihole -b example.com              # 加入公司黑名单"
  echo "  pihole -w example.com              # 加入白名单"
  echo "  pihole --regex '.*ads.*'           # 正则拦截一类域名"
  echo "  pihole -g                          # 手动刷新规则（gravity）"
  echo "  pihole restartdns                  # 重启 DNS 服务"
  echo; bold "注意事项 / 易踩坑："
  echo "1) 国外域名不做特殊处理（解析/访问失败属正常）；请勿尝试公司侧'翻墙'。"
  echo "2) 若 :53 被占，本脚本已尝试处理 systemd-resolved；若仍冲突请排查其他服务。"
  echo "3) 客户端缓存滞后可清空其 DNS 缓存（Windows: ipconfig /flushdns）。"
  echo "4) 规则过多会增负载，建议 anti-AD + oisd basic 起步后按需增减。"
  echo "=================================================="
}

main(){
  need_root
  detect_distro
  apt_preflight              # <== 关键：先清理 AutoDetect 变体
  prepare_block_ip
  temp_set_resolver_for_install
  fix_systemd_resolved_conflict
  install_unbound
  install_lighthttpd_blockpage
  install_pihole_unattended
  setup_custom_lists_and_cron
  open_firewall_hint
  restore_resolver_note
  post_checks
  print_summary
}

main "$@"
