#!/bin/bash

set -e

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== 帮助信息 =====
show_help() {
  echo "用法: $0 [选项]"
  echo ""
  echo "选项:"
  echo "  -k, --key \"公钥字符串\"    直接指定 SSH 公钥"
  echo "  -f, --file 文件路径        从文件读取公钥 (如 ~/.ssh/id_ed25519.pub)"
  echo "  -i, --interactive          交互式输入公钥"
  echo "  -p, --port 端口号          指定 SSH 端口 (默认交互询问)"
  echo "  -h, --help                 显示帮助信息"
  echo ""
  echo "示例:"
  echo "  $0 -k \"ssh-ed25519 AAAA... user@host\""
  echo "  $0 -f /tmp/my_key.pub"
  echo "  $0 -f /tmp/my_key.pub -p 2222"
  echo "  $0 -i"
  exit 0
}

# ===== 参数解析 =====
USER_PUBLIC_KEY=""
KEY_FILE=""
INTERACTIVE=false
NEW_PORT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -k|--key)
      USER_PUBLIC_KEY="$2"
      shift 2
      ;;
    -f|--file)
      KEY_FILE="$2"
      shift 2
      ;;
    -i|--interactive)
      INTERACTIVE=true
      shift
      ;;
    -p|--port)
      NEW_PORT="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo -e "${RED}❌ 未知参数: $1${NC}"
      show_help
      ;;
  esac
done

# ===== 获取公钥 =====
get_public_key() {
  # 方式1: 命令行直接指定
  if [ -n "$USER_PUBLIC_KEY" ]; then
    echo -e "${GREEN}✅ 使用命令行指定的公钥${NC}"
    return 0
  fi

  # 方式2: 从文件读取
  if [ -n "$KEY_FILE" ]; then
    if [ ! -f "$KEY_FILE" ]; then
      echo -e "${RED}❌ 公钥文件不存在: $KEY_FILE${NC}"
      exit 1
    fi
    USER_PUBLIC_KEY=$(cat "$KEY_FILE" | head -n 1 | tr -d '\n')
    echo -e "${GREEN}✅ 已从文件读取公钥: $KEY_FILE${NC}"
    return 0
  fi

  # 方式3: 交互式输入
  if [ "$INTERACTIVE" = true ]; then
    echo -e "${BLUE}请输入您的 SSH 公钥 (以 ssh-ed25519 或 ssh-rsa 开头):${NC}"
    read -r USER_PUBLIC_KEY
    if [ -z "$USER_PUBLIC_KEY" ]; then
      echo -e "${RED}❌ 公钥不能为空${NC}"
      exit 1
    fi
    return 0
  fi

  # 方式4: 尝试自动检测本地公钥文件
  echo -e "${YELLOW}▶ 未指定公钥，尝试自动检测...${NC}"
  
  local KEY_FILES=(
    "/root/.ssh/id_ed25519.pub"
    "/root/.ssh/id_rsa.pub"
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_rsa.pub"
  )

  for kf in "${KEY_FILES[@]}"; do
    if [ -f "$kf" ]; then
      echo -e "${YELLOW}发现本地公钥: $kf${NC}"
      read -p "是否使用此公钥? [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        USER_PUBLIC_KEY=$(cat "$kf" | head -n 1 | tr -d '\n')
        echo -e "${GREEN}✅ 已加载公钥: $kf${NC}"
        return 0
      fi
    fi
  done

  # 都没有，提示用户输入
  echo -e "${YELLOW}未找到本地公钥文件，请手动输入:${NC}"
  read -r USER_PUBLIC_KEY
  if [ -z "$USER_PUBLIC_KEY" ]; then
    echo -e "${RED}❌ 公钥不能为空！${NC}"
    echo "用法: $0 -k \"ssh-ed25519 AAAA... user@host\""
    echo "或者: $0 -f /path/to/key.pub"
    exit 1
  fi
}

# ===== 验证公钥格式 =====
validate_public_key() {
  if [[ ! "$USER_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa|dss)[[:space:]] ]]; then
    echo -e "${RED}❌ 公钥格式无效！公钥应以 ssh-ed25519, ssh-rsa, ssh-ecdsa 或 ssh-dss 开头${NC}"
    echo "您输入的内容: $USER_PUBLIC_KEY"
    exit 1
  fi
  echo -e "${GREEN}✅ 公钥格式验证通过${NC}"
}

echo -e "${BLUE}🔧 开始执行 SSH 安全加固脚本 v2.0...${NC}"
echo ""

# ===== Check root =====
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 必须使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# ===== 获取并验证公钥 =====
get_public_key
validate_public_key

echo ""
echo -e "${BLUE}将使用以下公钥:${NC}"
echo "$USER_PUBLIC_KEY" | cut -c1-80
echo "..."
echo ""

# ===== Detect sshd config path =====
SSH_CONFIG="/etc/ssh/sshd_config"
if [ ! -f "$SSH_CONFIG" ]; then
  echo -e "${RED}❌ 未找到 SSH 配置文件：$SSH_CONFIG${NC}"
  exit 1
fi

# ===== Step 1: Setup SSH key login =====
echo -e "${BLUE}▶ 步骤 1：配置 SSH 公钥登录...${NC}"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if grep -qF "$USER_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
  echo -e "${YELLOW}ℹ 公钥已存在于 /root/.ssh/authorized_keys 中，跳过追加。${NC}"
else
  echo "$USER_PUBLIC_KEY" >> /root/.ssh/authorized_keys
  echo -e "${GREEN}✅ 已将公钥写入 /root/.ssh/authorized_keys${NC}"
fi

chmod 600 /root/.ssh/authorized_keys
echo -e "${GREEN}✅ SSH 公钥登录配置完成（root 用户）。${NC}"

# ===== Step 2: Ask for new SSH port =====
echo ""
echo -e "${BLUE}▶ 步骤 2：设置 SSH 端口（可提高安全性）${NC}"

if [ -z "$NEW_PORT" ]; then
  read -p "请输入新的 SSH 端口（直接回车保持 22，建议 2222-60000）: " NEW_PORT
fi

if [ -z "$NEW_PORT" ]; then
  NEW_PORT=22
fi

if ! echo "$NEW_PORT" | grep -Eq '^[0-9]+$'; then
  echo -e "${YELLOW}⚠ 输入的端口无效，使用默认端口 22。${NC}"
  NEW_PORT=22
fi

if [ "$NEW_PORT" -le 0 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo -e "${YELLOW}⚠ 端口范围无效，使用默认端口 22。${NC}"
  NEW_PORT=22
fi

echo -e "${GREEN}🔢 将使用 SSH 端口：$NEW_PORT${NC}"

# ===== Step 3: Backup sshd_config =====
echo ""
echo -e "${BLUE}▶ 步骤 3：备份 SSH 配置...${NC}"

BACKUP_FILE="${SSH_CONFIG}.bak-$(date +%F-%H%M%S)"
cp "$SSH_CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}🗂 已备份 SSH 配置到: $BACKUP_FILE${NC}"

# ===== Step 4: Update sshd_config =====
echo ""
echo -e "${BLUE}▶ 步骤 4：修改 SSH 配置（端口 + 禁用密码登录 + 仅密钥）...${NC}"

# Port
if grep -qE '^[#[:space:]]*Port ' "$SSH_CONFIG"; then
  sed -i "s/^[#[:space:]]*Port .*/Port $NEW_PORT/" "$SSH_CONFIG"
else
  echo "Port $NEW_PORT" >> "$SSH_CONFIG"
fi

# PasswordAuthentication no
if grep -qE '^[#[:space:]]*PasswordAuthentication ' "$SSH_CONFIG"; then
  sed -i "s/^[#[:space:]]*PasswordAuthentication .*/PasswordAuthentication no/" "$SSH_CONFIG"
else
  echo "PasswordAuthentication no" >> "$SSH_CONFIG"
fi

# PermitRootLogin prohibit-password (root 仅允许密钥)
if grep -qE '^[#[:space:]]*PermitRootLogin ' "$SSH_CONFIG"; then
  sed -i "s/^[#[:space:]]*PermitRootLogin .*/PermitRootLogin prohibit-password/" "$SSH_CONFIG"
else
  echo "PermitRootLogin prohibit-password" >> "$SSH_CONFIG"
fi

# Ensure PubkeyAuthentication yes
if grep -qE '^[#[:space:]]*PubkeyAuthentication ' "$SSH_CONFIG"; then
  sed -i "s/^[#[:space:]]*PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSH_CONFIG"
else
  echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"
fi

echo -e "${GREEN}✅ SSH 配置已更新：${NC}"
echo "   - 端口: $NEW_PORT"
echo "   - 禁用密码登录"
echo "   - 仅允许密钥登录（root）"

# ===== Step 5: Install Fail2ban + Firewall =====
echo ""
echo -e "${BLUE}▶ 步骤 5：安装 Fail2ban 与防火墙...${NC}"

PKG_TOOL=""

if command -v apt-get >/dev/null 2>&1; then
  PKG_TOOL="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_TOOL="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_TOOL="yum"
else
  echo -e "${YELLOW}⚠ 未检测到支持的包管理器(apt/dnf/yum)，跳过自动安装。${NC}"
fi

if [ "$PKG_TOOL" = "apt" ]; then
  echo "🔁 正在通过 apt 安装 fail2ban 和 ufw..."
  apt-get update -y
  apt-get install -y fail2ban ufw
elif [ "$PKG_TOOL" = "dnf" ] || [ "$PKG_TOOL" = "yum" ]; then
  echo "🔁 正在通过 $PKG_TOOL 安装 fail2ban..."
  $PKG_TOOL install -y epel-release || true
  $PKG_TOOL install -y fail2ban
fi

echo -e "${GREEN}✅ Fail2ban 安装步骤完成${NC}"

# ===== Step 6: Configure Fail2ban for SSH =====
echo ""
echo -e "${BLUE}▶ 步骤 6：配置 Fail2ban 保护 SSH...${NC}"

# 自动检测日志路径
if [ -f /var/log/auth.log ]; then
  LOGPATH="/var/log/auth.log"
elif [ -f /var/log/secure ]; then
  LOGPATH="/var/log/secure"
else
  LOGPATH="%(sshd_log)s"
fi

if [ -d /etc/fail2ban ]; then
  JAIL_LOCAL="/etc/fail2ban/jail.local"
  cat > "$JAIL_LOCAL" <<EOF
[sshd]
enabled  = true
port     = $NEW_PORT
filter   = sshd
logpath  = $LOGPATH
maxretry = 5
findtime = 600
bantime  = 3600
EOF

  echo -e "${GREEN}✅ 已写入 Fail2ban 配置：$JAIL_LOCAL${NC}"
  echo "   - 日志路径: $LOGPATH"
else
  echo -e "${YELLOW}⚠ 未找到 /etc/fail2ban 目录，请手动检查。${NC}"
fi

# ===== Step 7: Handle SELinux (CentOS/RHEL) =====
echo ""
echo -e "${BLUE}▶ 步骤 7：处理 SELinux 端口策略...${NC}"

if command -v semanage >/dev/null 2>&1 && [ "$NEW_PORT" != "22" ]; then
  echo "🔐 添加 SELinux SSH 端口策略..."
  semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || \
  semanage port -m -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || true
  echo -e "${GREEN}✅ SELinux 端口策略已添加${NC}"
else
  echo -e "${YELLOW}ℹ 未检测到 semanage 或使用默认端口，跳过 SELinux 配置${NC}"
fi

# ===== Step 8: Configure Firewall (UFW or firewalld) =====
echo ""
echo -e "${BLUE}▶ 步骤 8：配置防火墙...${NC}"

if command -v ufw >/dev/null 2>&1; then
  echo "🔐 配置 UFW 规则..."
  ufw allow "$NEW_PORT"/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp

  if [ "$NEW_PORT" != "22" ]; then
    ufw delete allow 22/tcp 2>/dev/null || true
  fi

  ufw --force enable
  echo -e "${GREEN}✅ UFW 已启用并开放端口：$NEW_PORT, 80, 443${NC}"

elif command -v firewall-cmd >/dev/null 2>&1; then
  echo "🔐 配置 firewalld 规则..."
  firewall-cmd --permanent --add-port="$NEW_PORT"/tcp
  firewall-cmd --permanent --add-port=80/tcp
  firewall-cmd --permanent --add-port=443/tcp
  
  if [ "$NEW_PORT" != "22" ]; then
    firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
  fi
  
  firewall-cmd --reload
  echo -e "${GREEN}✅ firewalld 已配置并开放端口：$NEW_PORT, 80, 443${NC}"
else
  echo -e "${YELLOW}⚠ 未检测到 ufw 或 firewalld，跳过防火墙配置。${NC}"
fi

# ===== Step 9: Restart SSH + Fail2ban =====
echo ""
echo -e "${BLUE}▶ 步骤 9：重启 SSH 与 Fail2ban 服务...${NC}"

SSH_SERVICE="ssh"
if systemctl restart ssh 2>/dev/null; then
  SSH_SERVICE="ssh"
elif systemctl restart sshd 2>/dev/null; then
  SSH_SERVICE="sshd"
else
  echo -e "${RED}❌ 无法重启 ssh/sshd 服务，请检查 systemctl 状态！${NC}"
  exit 1
fi

systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

echo -e "${GREEN}✅ SSH 服务已重启（服务名：$SSH_SERVICE）。${NC}"

# ===== Step 10: Local check SSH port =====
echo ""
echo -e "${BLUE}▶ 步骤 10：检测 SSH 是否在新端口监听...${NC}"

sleep 3

if command -v ss >/dev/null 2>&1; then
  if ss -tln | grep -q ":$NEW_PORT "; then
    echo -e "${GREEN}✅ 检测到 SSH 正在端口 $NEW_PORT 上监听。${NC}"
  else
    echo -e "${YELLOW}⚠ 未检测到 SSH 在端口 $NEW_PORT 监听，开始恢复备份配置...${NC}"
    cp "$BACKUP_FILE" "$SSH_CONFIG"
    systemctl restart "$SSH_SERVICE"
    echo -e "${RED}❌ 已恢复原 SSH 配置，请手动检查 /etc/ssh/sshd_config。${NC}"
    exit 1
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -tln | grep -q ":$NEW_PORT "; then
    echo -e "${GREEN}✅ 检测到 SSH 正在端口 $NEW_PORT 上监听。${NC}"
  else
    echo -e "${YELLOW}⚠ 端口检测失败，请手动确认。${NC}"
  fi
else
  echo -e "${YELLOW}ℹ 未找到 ss/netstat 命令，跳过本地端口检测。${NC}"
fi

echo ""
echo -e "${GREEN}🎉 所有步骤执行完成！当前已启用配置：${NC}"
echo "   - SSH 端口: $NEW_PORT"
echo "   - 禁用密码登录，仅允许密钥登录"
echo "   - Fail2ban 已保护 SSH 登录"
echo "   - 防火墙已开放端口: $NEW_PORT, 80, 443"
echo ""
echo -e "${YELLOW}🧪 请立刻在 *新的终端窗口* 测试：${NC}"
echo "   ssh -p $NEW_PORT root@你的服务器IP"
echo -e "${GREEN}✅ 确认新端口可以正常登录后，再关闭当前老的 SSH 会话。${NC}"
