#!/usr/bin/env bash
# =============================================================================
# verify.sh — Hermes + XMPP 健康检查（一眼看出各项状态）
#
# 用法：
#   bash verify.sh                  # 检查当前 ~/.hermes
#   HERMES_HOME=/path bash verify.sh  # 检查指定 HERMES_HOME（测试用）
#
# 输出五组状态：Hermes 核心 / XMPP 源码补丁 / XMPP 插件 / 依赖 / 配置 / Gateway
# 退出码：0 = 无缺失项；1 = 存在缺失项（待办项不影响退出码）
# =============================================================================
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SRC_DIR="$HERMES_HOME/hermes-agent"
VENV_DIR="$SRC_DIR/venv"
PIN="45af7a71fcd420b4422d2c074b1ce58b9ce0d048"

OK=0; TODO=0; MISS=0
ok()   { printf '  \033[1;32m[OK]  \033[0m %s\n' "$1"; OK=$((OK+1)); }
todo() { printf '  \033[1;33m[待办] \033[0m %s\n' "$1"; TODO=$((TODO+1)); }
miss() { printf '  \033[1;31m[缺失] \033[0m %s\n' "$1"; MISS=$((MISS+1)); }

# 选择可用的 hermes 可执行文件（优先 venv 内 entry point，其次 PATH）
if [ -x "$VENV_DIR/bin/hermes" ]; then HERMES_BIN="$VENV_DIR/bin/hermes";
elif command -v hermes >/dev/null 2>&1; then HERMES_BIN="$(command -v hermes)";
else HERMES_BIN=""; fi

echo "════════════════ Hermes + XMPP 健康检查 ════════════════"
echo "  HERMES_HOME : $HERMES_HOME"
echo "  锁定提交     : $PIN"
echo

# ---------------------------------------------------------------- 1. Hermes 核心
echo "── 1. Hermes 核心 ──"
PYVER=""
if [ -x "$VENV_DIR/bin/python" ]; then
  PYVER="$("$VENV_DIR/bin/python" -c 'import sys;print(sys.version.split()[0])' 2>/dev/null)"
  if "$VENV_DIR/bin/python" -c 'import hermes_cli' >/dev/null 2>&1; then
    ok "hermes_cli 可导入（Python $PYVER）"
  else
    miss "hermes_cli 不可导入（venv 存在但未安装 Hermes）"
  fi
else
  miss "venv 缺失: $VENV_DIR"
fi
if [ -d "$SRC_DIR/.git" ]; then
  CUR="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ "$CUR" = "$PIN" ]; then
    ok "源码锁定提交 $PIN"
  elif [ -f "$HERMES_HOME/.hermes-source-meta" ] \
       && grep -q "^commit=$PIN$" "$HERMES_HOME/.hermes-source-meta" 2>/dev/null \
       && grep -q "^tree=" "$HERMES_HOME/.hermes-source-meta" 2>/dev/null; then
    ok "源码来自官方归档（标记 commit=$PIN，获取时已通过 tree 内容级校验）"
  else
    todo "源码提交 ${CUR:0:12} ≠ 锁定提交 ${PIN:0:12}（补丁前提可能不成立）"
  fi
else
  miss "源码目录缺失: $SRC_DIR"
fi
[ -n "$HERMES_BIN" ] && ok "hermes 可执行文件: $HERMES_BIN" || todo "hermes 命令不在 PATH（装好 venv 后自动生成）"

# ---------------------------------------------------------------- 2. XMPP 源码补丁
echo "── 2. XMPP 源码补丁 ──"
grep -q 'XMPP = "xmpp"' "$SRC_DIR/gateway/config.py" 2>/dev/null \
  && ok "gateway/config.py: Platform.XMPP 枚举" || miss "gateway/config.py: Platform.XMPP 缺失（补丁未应用）"
grep -q 'XMPP_PASSWORD' "$SRC_DIR/gateway/config.py" 2>/dev/null \
  && ok "gateway/config.py: XMPP 环境变量配置解析" || miss "gateway/config.py: XMPP env 解析缺失"
grep -q 'XMPP_ALLOWED_JIDS' "$SRC_DIR/gateway/authz_mixin.py" 2>/dev/null \
  && ok "gateway/authz_mixin.py: JID 白名单授权" || miss "gateway/authz_mixin.py: JID 白名单缺失"

# ---------------------------------------------------------------- 3. XMPP 插件
echo "── 3. XMPP 插件 ──"
[ -f "$HERMES_HOME/plugins/xmpp/adapter.py" ]  && ok "插件 adapter.py 存在"   || miss "插件 adapter.py 缺失"
[ -f "$HERMES_HOME/plugins/xmpp/plugin.yaml" ] && ok "插件 plugin.yaml 存在"  || miss "插件 plugin.yaml 缺失"
[ -f "$HERMES_HOME/plugins/xmpp/__init__.py" ] && ok "插件 __init__.py 存在"  || miss "插件 __init__.py 缺失"
if grep -q 'xmpp-platform' "$HERMES_HOME/config.yaml" 2>/dev/null; then
  ok "config.yaml 已启用 xmpp-platform"
else
  todo "config.yaml 未启用 xmpp-platform（运行: hermes plugins enable xmpp-platform）"
fi

# ---------------------------------------------------------------- 4. 依赖
echo "── 4. 依赖 ──"
if [ -x "$VENV_DIR/bin/python" ]; then
  if "$VENV_DIR/bin/python" -c 'import slixmpp' >/dev/null 2>&1; then
    ok "slixmpp $("$VENV_DIR/bin/python" -c 'import slixmpp;print(slixmpp.__version__)' 2>/dev/null)"
  else miss "slixmpp 未安装"; fi
  "$VENV_DIR/bin/python" -c 'import aiodns'  >/dev/null 2>&1 && ok "aiodns"  || miss "aiodns 未安装"
  "$VENV_DIR/bin/python" -c 'import pycares' >/dev/null 2>&1 && ok "pycares" || miss "pycares 未安装"
else
  miss "无法检查依赖（venv 缺失）"
fi

# ---------------------------------------------------------------- 5. 配置
echo "── 5. 配置 ──"
[ -f "$HERMES_HOME/.env" ] && ok ".env 存在" || miss ".env 缺失（cp .env.example ~/.hermes/.env）"
[ -f "$HERMES_HOME/config.yaml" ] && ok "config.yaml 存在" || miss "config.yaml 缺失"
grep -q '^XMPP_JID=.' "$HERMES_HOME/.env" 2>/dev/null && ok "XMPP_JID 已设置" || todo "XMPP_JID 未设置"
grep -q '^XMPP_PASSWORD=.' "$HERMES_HOME/.env" 2>/dev/null && ok "XMPP_PASSWORD 已设置" || todo "XMPP_PASSWORD 未设置（待填写）"
if grep -q '^DEEPSEEK_API_KEY=.' "$HERMES_HOME/.env" 2>/dev/null || [ -f "$HERMES_HOME/auth.json" ]; then
  ok "模型 API 凭据就绪"
else
  todo "无 API Key 且无 auth.json（需要: hermes auth login nous 或填写 DEEPSEEK_API_KEY）"
fi

# ---------------------------------------------------------------- 6. Gateway
echo "── 6. Gateway ──"
if [ -n "$HERMES_BIN" ]; then
  GSTATUS="$("$HERMES_BIN" gateway status 2>&1 | head -1)"
  case "$GSTATUS" in
    *"is not running"*|*"not running"*|*未运行*)
      todo "Gateway 未运行（可启动: hermes gateway run）";;
    *running*|*运行*)
      ok "Gateway 运行中";;
    *)
      todo "Gateway 状态未知: $GSTATUS";;
  esac
else
  todo "hermes 命令不可用，无法查询 Gateway 状态"
fi

echo
echo "════════════════ 结果: $OK 项正常 / $TODO 项待办 / $MISS 项缺失 ════════════════"
echo "  待办 = 需要你操作（填密钥/OAuth/启用插件/启动 gateway）"
echo "  缺失 = 安装不完整（请重跑 restore.sh）"
[ "$MISS" -eq 0 ]
