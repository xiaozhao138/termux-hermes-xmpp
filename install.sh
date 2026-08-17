#!/usr/bin/env bash
# =============================================================================
# install.sh — Termux Hermes + XMPP 一键安装
#
# 目标：新 Termux（已装好基础环境）只需:
#   git clone <你的仓库> && cd <仓库> && ./install.sh
# 脚本自动完成：系统依赖 → 源码获取与锁定 → venv → 官方依赖 → XMPP 依赖
#   → 补丁 → 插件 → skills → 配置模板 → 健康检查
# 只在你缺失密钥时交互提示（XMPP_PASSWORD / API Key / Nous OAuth）
#
# 重复执行安全：内部调用 restore.sh（幂等），已有配置与密钥不会被覆盖
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ENV_FILE="$HERMES_HOME/.env"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install][错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境检查
if [ -z "${PREFIX:-}" ] || ! command -v pkg >/dev/null 2>&1; then
  die "本脚本只能在 Termux 中运行（检测不到 pkg/PREFIX）。请退出当前环境，在 Termux 终端里执行"
fi

# ---------------------------------------------------------------- 1. 系统依赖（幂等）
log "安装 Termux 系统依赖（已装则跳过）..."
pkg install -y python git openssl clang binutils make pkg-config

# ---------------------------------------------------------------- 2. 核心恢复（幂等）
bash "$REPO_DIR/restore.sh"

# ---------------------------------------------------------------- 3. 密钥提示（仅缺失时）
PYBIN="${HERMES_HOME}/hermes-agent/venv/bin/python"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3 || command -v python)"

# 用 python 安全地写入/替换 .env 中的某个键（避免 sed 转义问题）
env_set() { # $1=key  $2=value
  "$PYBIN" - "$ENV_FILE" "$1" "$2" <<'PYEOF'
import os, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, done = [], False
for ln in lines:
    if ln.startswith(key + "="):
        out.append(f"{key}={value}"); done = True
    else:
        out.append(ln)
if not done:
    out.append(f"{key}={value}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYEOF
}

env_has_value() { # $1=key  有值返回 0
  grep -q "^$1=." "$ENV_FILE" 2>/dev/null && return 0
  return 1
}

if [ ! -f "$ENV_FILE" ]; then
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  log "已生成 .env 模板"
fi

if ! env_has_value XMPP_PASSWORD; then
  JID_VAL="$(sed -n 's/^XMPP_JID=//p' "$ENV_FILE" 2>/dev/null | head -1)"
  [ -z "$JID_VAL" ] && JID_VAL="(未设置)"
  log "需要填写 XMPP_PASSWORD（机器人账号 $JID_VAL 的密码）"
  read -rsp "  XMPP_PASSWORD: " XMPP_PW; echo
  [ -n "$XMPP_PW" ] && env_set XMPP_PASSWORD "$XMPP_PW" || warn "未填写，之后可手动编辑 ~/.hermes/.env"
fi

if ! env_has_value DEEPSEEK_API_KEY && [ ! -f "$HERMES_HOME/auth.json" ]; then
  log "模型 API 凭据缺失，二选一："
  log "  a) 填 DEEPSEEK_API_KEY"
  log "  b) 留空，之后执行 hermes auth login nous（OAuth 登录 Nous Portal）"
  read -rsp "  DEEPSEEK_API_KEY（直接回车则留空）: " DKEY; echo
  [ -n "$DKEY" ] && env_set DEEPSEEK_API_KEY "$DKEY"
fi

# ---------------------------------------------------------------- 4. 健康检查
log "运行健康检查 ..."
bash "$REPO_DIR/verify.sh" || warn "健康检查有未通过项，请按上面提示处理"

# ---------------------------------------------------------------- 5. 收尾提示
log "安装完成 ✔"
log "启动 Hermes CLI :  hermes"
log "启动 XMPP Gateway: hermes gateway run   （日志出现 XMPP: connected as ... 即成功）"
log "OAuth 登录 Nous  :  hermes auth login nous"
if [ ! -f "$HERMES_HOME/auth.json" ] && ! env_has_value DEEPSEEK_API_KEY; then
  warn "注意：还没有任何模型凭据，请先 hermes auth login nous 或填写 DEEPSEEK_API_KEY"
fi
