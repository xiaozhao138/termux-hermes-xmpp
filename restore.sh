#!/usr/bin/env bash
# =============================================================================
# restore.sh — Termux Hermes + XMPP 恢复脚本（幂等）
#
# 设计目标：
#   - 可重复执行：重复运行不会破坏已经正常工作的 Hermes
#   - 检测已有安装：锁定提交 + 补丁标记齐全 => 跳过；不同状态 => 停止并报告
#   - 绝不覆盖现有 config.yaml / .env / auth.json / 已有插件
#   - 补丁严格绑定上游提交 $PIN：无法干净应用 => 立即停止，不强行修改源码
#
# 用法：
#   bash restore.sh            # 常规恢复
#   FORCE=1 bash restore.sh    # 已有不同状态的 Hermes 时，备份旧目录后重建
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SRC_DIR="$HERMES_HOME/hermes-agent"
VENV_DIR="$SRC_DIR/venv"
PIN="45af7a71fcd420b4422d2c074b1ce58b9ce0d048"
PATCH_FILE="$REPO_DIR/patches/hermes-45af7a7-xmpp-custom.patch"

log()  { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[restore]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[restore][错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 预检
command -v git >/dev/null 2>&1 || die "缺少 git，请先: pkg install git"
[ -d "$REPO_DIR/patches" ]  || die "补丁目录缺失: $REPO_DIR/patches"
[ -f "$PATCH_FILE" ]        || die "补丁文件缺失: $PATCH_FILE"
[ -d "$REPO_DIR/plugins/xmpp" ] || die "插件目录缺失: $REPO_DIR/plugins/xmpp"
[ -f "$REPO_DIR/config.yaml.template" ] || die "config.yaml.template 缺失"
[ -f "$REPO_DIR/.env.example" ]        || die ".env.example 缺失"

# ---------------------------------------------------------------- 1. 检测现有安装
if [ -e "$SRC_DIR" ]; then
  if [ ! -d "$SRC_DIR/.git" ]; then
    die "检测到 $SRC_DIR 已存在但不是 git 仓库 —— 为安全起见不触碰，请手动检查"
  fi
  CUR="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  log "检测到已有 Hermes 源码: $SRC_DIR @ ${CUR:0:12}"
  if [ "$CUR" = "$PIN" ]; then
    if grep -q 'XMPP = "xmpp"' "$SRC_DIR/gateway/config.py" 2>/dev/null; then
      log "源码已锁定且 XMPP 补丁已应用 —— 跳过源码步骤"
    else
      die "源码在锁定提交但缺少 XMPP 补丁（异常状态）。已停止；可备份后删除 $SRC_DIR 再重跑"
    fi
  else
    warn "现有源码提交 (${CUR:0:12}) 与锁定提交 (${PIN:0:12}) 不一致"
    if [ "${FORCE:-0}" = "1" ]; then
      BAK="${SRC_DIR}.bak.$(date +%Y%m%d%H%M%S)"
      warn "FORCE=1：将旧目录备份为 $BAK 后重建"
      mv "$SRC_DIR" "$BAK"
    else
      die "为避免破坏现有 Hermes，已停止。确认要重建请设 FORCE=1 重跑（旧目录会备份为 .bak）"
    fi
  fi
fi

# ---------------------------------------------------------------- 2. 获取并锁定源码
if [ ! -d "$SRC_DIR/.git" ]; then
  mkdir -p "$HERMES_HOME"
  log "克隆 hermes-agent ..."
  git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$SRC_DIR"
  log "抓取并锁定提交 $PIN ..."
  git -C "$SRC_DIR" fetch --depth 1 origin "$PIN" \
    || die "无法抓取锁定提交 $PIN（网络问题或上游已不可达）。已停止"
  git -C "$SRC_DIR" checkout "$PIN" || die "checkout $PIN 失败。已停止"
  log "源码已锁定: $PIN"
fi

# ---------------------------------------------------------------- 3. 应用补丁（严格模式）
if ! grep -q 'XMPP = "xmpp"' "$SRC_DIR/gateway/config.py" 2>/dev/null; then
  log "应用 XMPP 补丁 ..."
  if ! git -C "$SRC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    die "补丁无法干净应用（上游代码已变化？）。已停止，未修改任何源码。如需适配请重新生成补丁"
  fi
  git -C "$SRC_DIR" apply "$PATCH_FILE" || die "补丁应用失败。已停止"
  # 应用后二次校验
  grep -q 'XMPP = "xmpp"'     "$SRC_DIR/gateway/config.py"    || die "补丁校验失败: config.py"
  grep -q 'XMPP_ALLOWED_JIDS' "$SRC_DIR/gateway/authz_mixin.py" || die "补丁校验失败: authz_mixin.py"
  log "补丁应用并校验通过"
else
  log "补丁已应用 —— 跳过"
fi

# ---------------------------------------------------------------- 4. venv
if [ ! -x "$VENV_DIR/bin/python" ]; then
  command -v python >/dev/null 2>&1 || die "缺少 python，请先: pkg install python"
  log "创建 venv ..."
  python -m venv "$VENV_DIR"
fi
PY="$VENV_DIR/bin/python"
"$PY" -c 'import sys; assert (3,11) <= sys.version_info < (3,14), "需要 Python 3.11~3.13"' \
  || die "Python 版本不受支持（$( "$PY" -V 2>&1 )），Termux 请用: pkg install python"

# ---------------------------------------------------------------- 5. Hermes 本体（官方 Termux 路径）
if ! "$PY" -c 'import hermes_cli' >/dev/null 2>&1; then
  log "安装 Hermes（官方 Termux 路径: pip install -e '.[termux]' -c constraints-termux.txt）..."
  ( cd "$SRC_DIR" && "$VENV_DIR/bin/pip" install -e ".[termux]" -c constraints-termux.txt ) \
    || die "Hermes 安装失败。已停止"
else
  log "hermes_cli 已安装 —— 跳过"
fi

# ---------------------------------------------------------------- 6. XMPP Python 依赖
if ! "$PY" -c 'import slixmpp' >/dev/null 2>&1; then
  log "安装 XMPP 依赖 slixmpp aiodns（自动带 pycares）..."
  "$VENV_DIR/bin/pip" install slixmpp aiodns || die "XMPP 依赖安装失败。已停止"
else
  log "slixmpp 已安装 —— 跳过"
fi

# ---------------------------------------------------------------- 7. XMPP 插件
PLUGIN_DIR="$HERMES_HOME/plugins/xmpp"
if [ ! -f "$PLUGIN_DIR/adapter.py" ]; then
  mkdir -p "$HERMES_HOME/plugins"
  cp -r "$REPO_DIR/plugins/xmpp" "$HERMES_HOME/plugins/"
  log "XMPP 插件已安装 -> $PLUGIN_DIR"
else
  if diff -q "$REPO_DIR/plugins/xmpp/adapter.py" "$PLUGIN_DIR/adapter.py" >/dev/null 2>&1; then
    log "插件已存在且与项目一致 —— 跳过"
  else
    warn "插件已存在但内容与项目不同 —— 未覆盖（如需更新请手动比较）"
  fi
fi

# ---------------------------------------------------------------- 8. 自定义 skills（不覆盖已有）
log "同步自定义 skills（已存在的不覆盖）..."
mkdir -p "$HERMES_HOME/skills"
cp -rn "$REPO_DIR/skills/." "$HERMES_HOME/skills/" 2>/dev/null || true

# ---------------------------------------------------------------- 9. 配置模板（绝不覆盖现有）
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
  cp "$REPO_DIR/config.yaml.template" "$HERMES_HOME/config.yaml"
  log "已生成 config.yaml（模板）"
else
  log "config.yaml 已存在 —— 不覆盖"
  if ! grep -q "xmpp-platform" "$HERMES_HOME/config.yaml" 2>/dev/null; then
    warn "config.yaml 未启用 xmpp-platform 插件，请执行: hermes plugins enable xmpp-platform"
  fi
fi
if [ ! -f "$HERMES_HOME/.env" ]; then
  cp "$REPO_DIR/.env.example" "$HERMES_HOME/.env"
  log "已生成 .env（模板，含占位符）—— 需要填写密钥（install.sh 或手动）"
else
  log ".env 已存在 —— 不覆盖"
fi

log "restore.sh 完成 ✔"
log "下一步: 填写密钥（bash install.sh 可自动提示）→ bash verify.sh 健康检查 → hermes gateway run 启动"
