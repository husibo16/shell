# Shell 脚本模板仓库

[![Shell Quality](https://github.com/husibo16/shell/actions/workflows/shell-pr-diff.yml/badge.svg)](../../actions)

一个 **生产可用的 Bash 脚本标准模板**，包含以下特性：

- 严格模式（`set -Eeuo pipefail` / `IFS` / `extglob`）
- 错误栈追踪与自动清理（`trap ERR/EXIT`）
- 日志函数（INFO/WARN/ERROR/DEBUG，支持颜色和时间戳）
- 临时目录与并发锁（防止脚本重复运行）
- 重试 / 超时 / .env 配置加载
- 支持 **子命令模式**（示例：`hello` / `http-get` / `lock-demo`）
- 已集成 [ShellCheck](https://www.shellcheck.net/) 与 [shfmt](https://github.com/mvdan/sh) 的 CI/预提交检查

---

## 🚀 快速开始

```bash
# 克隆仓库
git clone https://github.com/husibo16/shell.git
cd shell

# 给脚本执行权限
chmod +x bin/smart.sh

# 查看帮助
./bin/smart.sh -h

# 执行子命令
./bin/smart.sh hello --name "胡博涵"
./bin/smart.sh http-get https://example.com --retry 3 --timeout 5
