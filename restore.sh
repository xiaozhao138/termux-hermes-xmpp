#!/usr/bin/env bash
# =============================================================================
# restore.sh — Termux Hermes + XMPP 恢复脚本（幂等 + 源码获取多级回退）
#
# 源码获取策略（硬约束：最终源码必须精确对应锁定提交 $PIN，绝不接受其他 commit）：
#   阶段1  浅克隆 + fetch 锁定 SHA（2 次克隆尝试 × 3 次 fetch 尝试，
#          自动升级 HTTP/1.1、protocol v1，规避 GitHub HTTP 429 与
#          HTTP/2 RPC 异常如 "expected 'acknowledgments'"）
#   阶段2  全新完整克隆（临时目录，完整历史，checkout $PIN，零额外网络请求）
#   阶段3  官方源码归档 codeload tar.gz + 内容级校验（根树哈希 == $TREE_PIN，
#          树哈希是内容寻址的：任何内容差异都会导致拒绝）
#   全部失败 → 停止并给出明确诊断（绝不把错误版本当成功恢复）
#
# 幂等：已恢复（HEAD==$PIN 或源码标记有效）→ 跳过；不同状态 → 备份或停止；
#       绝不覆盖现有 config.yaml / .env / auth.json / 已有插件
#
# 内部/测试开关（不影响正常使用）：
#   HERMES_UPSTREAM_URL / HERMES_ARCHIVE_URL  覆盖上游地址（镜像/离线测试）
#   RESTORE_SKIP_PIP=1                        跳过 venv/pip 步骤（快速验证源码链路）
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SRC_DIR="$HERMES_HOME/hermes-agent"
VENV_DIR="$SRC_DIR/venv"
PIN="45af7a71fcd420b4422d2c074b1ce58b9ce0d048"
# 45af7a71 的根树哈希（内容级校验锚点；由 git rev-parse <sha>^{tree} 得出）
TREE_PIN="b16536d3492a888ca3458392eedde38da2db6345"
PATCH_FILE="$REPO_DIR/patches/hermes-45af7a7-xmpp-custom.patch"
META_FILE="$HERMES_HOME/.hermes-source-meta"
UPSTREAM_URL="${HERMES_UPSTREAM_URL:-https://github.com/NousResearch/hermes-agent.git}"
ARCHIVE_BASE="${HERMES_ARCHIVE_URL:-https://codeload.github.com/NousResearch/hermes-agent}"

ACQ_TMP=""

log()  { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[restore]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[restore][错误]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_acq() { [ -n "$ACQ_TMP" ] && rm -rf "$ACQ_TMP"; }
trap cleanup_acq EXIT

repo_head() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }

write_meta() { # $1 = via (git|archive)
  mkdir -p "$HERMES_HOME"
  printf 'commit=%s\ntree=%s\nvia=%s\ndate=%s\n' "$PIN" "$TREE_PIN" "$1" "$(date -u +%Y%m%dT%H%M%SZ)" > "$META_FILE"
  log "已写入源码标记: $META_FILE (commit=$PIN via=$1)"
}

meta_valid() {
  [ -f "$META_FILE" ] || return 1
  grep -q "^commit=$PIN$" "$META_FILE" || return 1
  grep -q "^tree=$TREE_PIN$" "$META_FILE" || return 1
  return 0
}

patch_applied() {
  grep -q 'XMPP = "xmpp"' "$SRC_DIR/gateway/config.py" 2>/dev/null
}

# ---------------------------------------------------------------- 0. 预检
command -v git >/dev/null 2>&1 || die "缺少 git，请先: pkg install git"
mkdir -p "$HERMES_HOME"
[ -f "$PATCH_FILE" ]        || die "补丁文件缺失: $PATCH_FILE"
[ -d "$REPO_DIR/plugins/xmpp" ] || die "插件目录缺失: $REPO_DIR/plugins/xmpp"
[ -f "$REPO_DIR/config.yaml.template" ] || die "config.yaml.template 缺失"
[ -f "$REPO_DIR/.env.example" ]        || die ".env.example 缺失"

# ---------------------------------------------------------------- 1. 检测现有安装
SKIP_SOURCE=0
if [ -e "$SRC_DIR" ]; then
  if [ ! -d "$SRC_DIR/.git" ]; then
    if [ ! -f "$HERMES_HOME/config.yaml" ] && [ ! -f "$HERMES_HOME/.env" ]; then
      warn "检测到不完整的恢复残留（$SRC_DIR 非 git 仓库且无配置）—— 备份后重建"
      mv "$SRC_DIR" "$SRC_DIR.bak.$(date +%Y%m%d%H%M%S)"
    else
      die "检测到 $SRC_DIR 已存在但不是 git 仓库，且存在配置 —— 为安全起见不触碰，请手动检查"
    fi
  else
    CUR="$(repo_head "$SRC_DIR")"
    if [ "$CUR" = "$PIN" ]; then
      if patch_applied; then
        log "检测到已有 Hermes 源码: 已锁定 $PIN 且补丁已应用 —— 跳过源码步骤"
        SKIP_SOURCE=1
      else
        die "源码在锁定提交但缺少 XMPP 补丁（异常状态）。已停止；可备份后删除 $SRC_DIR 再重跑"
      fi
    elif meta_valid; then
      log "检测到归档源恢复（$META_FILE 标记有效，commit=$PIN）—— 跳过源码步骤"
      SKIP_SOURCE=1
    elif [ ! -f "$HERMES_HOME/config.yaml" ] && [ ! -f "$HERMES_HOME/.env" ]; then
      warn "检测到未完成的恢复残留（提交 ${CUR:0:12} ≠ $PIN 且无配置）—— 备份后重新获取"
      mv "$SRC_DIR" "$SRC_DIR.bak.$(date +%Y%m%d%H%M%S)"
    else
      warn "现有源码提交 (${CUR:0:12}) 与锁定提交 (${PIN:0:12}) 不一致"
      if [ "${FORCE:-0}" = "1" ]; then
        BAK="$SRC_DIR.bak.$(date +%Y%m%d%H%M%S)"
        warn "FORCE=1：将旧目录备份为 $BAK 后重建"
        mv "$SRC_DIR" "$BAK"
      else
        die "为避免破坏现有 Hermes，已停止。确认要重建请设 FORCE=1 重跑（旧目录会备份为 .bak）"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- 2. 源码获取（多级回退）
STAGE1_FAILED="" STAGE2_FAILED="" STAGE3_FAILED=""

acquire_source() {
  local attempt f
  # ---- 阶段 1：浅克隆 + fetch 锁定 SHA（克隆2次 × 抓取3次，逐级升级 HTTP 方式）----
  for attempt in 1 2; do
    for f in 1 2 3; do
      local HTTPC=() PROTC=()
      [ "$attempt" -ge 2 ] && HTTPC=(-c http.version=HTTP/1.1)
      [ "$f" -ge 3 ] && PROTC=(-c protocol.version=1)
      [ "$f" -ge 2 ] && sleep 5
      ACQ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-acq.XXXXXX")"
      log "阶段1 尝试（克隆#$attempt / 抓取#$f${HTTPC[*]:+ / HTTP/1.1}${PROTC[*]:+ / proto-v1}）..."
      if git "${HTTPC[@]}" "${PROTC[@]}" clone --depth 1 --no-tags "$UPSTREAM_URL" "$ACQ_TMP/src" >/dev/null 2>&1 \
         && git "${HTTPC[@]}" "${PROTC[@]}" -C "$ACQ_TMP/src" fetch --depth 1 --no-tags origin "$PIN" >/dev/null 2>&1 \
         && git -C "$ACQ_TMP/src" checkout -q "$PIN" >/dev/null 2>&1 \
         && [ "$(repo_head "$ACQ_TMP/src")" = "$PIN" ]; then
        log "阶段1 成功（克隆#$attempt 抓取#$f）—— HEAD 校验 = $PIN"
        rm -rf "$SRC_DIR" 2>/dev/null || true
        mv "$ACQ_TMP/src" "$SRC_DIR" || die "阶段1: 移动源码到 $SRC_DIR 失败"
        write_meta git
        return 0
      fi
      rm -rf "$ACQ_TMP"; ACQ_TMP=""
    done
  done
  STAGE1_FAILED="浅克隆 + 锁定SHA 抓取失败（可能 429 限流 / HTTP RPC 异常 / 网络不可达）"
  log "阶段1 失败，进入阶段2（完整克隆）"

  # ---- 阶段 2：全新完整克隆（完整历史，checkout 无需额外请求）----
  for attempt in 1 2; do
    local HTTPC=()
    [ "$attempt" -ge 2 ] && HTTPC=(-c http.version=HTTP/1.1)
    [ "$attempt" -ge 2 ] && sleep 10
    ACQ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-acq.XXXXXX")"
    log "阶段2 尝试 $attempt：完整克隆（含全部历史）..."
    if git "${HTTPC[@]}" clone --single-branch --branch main --no-tags "$UPSTREAM_URL" "$ACQ_TMP/src" >/dev/null 2>&1 \
       && git -C "$ACQ_TMP/src" checkout -q "$PIN" >/dev/null 2>&1 \
       && [ "$(repo_head "$ACQ_TMP/src")" = "$PIN" ]; then
      log "阶段2 成功 —— HEAD 校验 = $PIN"
      rm -rf "$SRC_DIR" 2>/dev/null || true
      mv "$ACQ_TMP/src" "$SRC_DIR" || die "阶段2: 移动源码到 $SRC_DIR 失败"
      write_meta git
      return 0
    fi
    rm -rf "$ACQ_TMP"; ACQ_TMP=""
  done
  STAGE2_FAILED="完整克隆或 checkout $PIN 失败"
  log "阶段2 失败，进入阶段3（官方源码归档）"

  # ---- 阶段 3：官方源码归档（codeload）+ 内容级 tree 校验 ----
  command -v curl >/dev/null 2>&1 || { STAGE3_FAILED="缺少 curl（请 pkg install curl）"; return 1; }
  command -v tar  >/dev/null 2>&1 || { STAGE3_FAILED="缺少 tar"; return 1; }
  ACQ_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-acq.XXXXXX")"
  log "阶段3：下载官方源码归档 $ARCHIVE_BASE/tar.gz/$PIN ..."
  if curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 \
       -o "$ACQ_TMP/hermes-$PIN.tar.gz" "$ARCHIVE_BASE/tar.gz/$PIN" 2>/dev/null; then
    mkdir -p "$ACQ_TMP/src"
    if tar -xzf "$ACQ_TMP/hermes-$PIN.tar.gz" -C "$ACQ_TMP/src" --strip-components=1 2>/dev/null; then
      TREE="$( (cd "$ACQ_TMP/src" && git init -q && git add -Af && git write-tree) 2>/dev/null )" \
        || { STAGE3_FAILED="tree 计算失败"; return 1; }
      if [ "$TREE" = "$TREE_PIN" ]; then
        log "阶段3 归档内容校验通过（tree = $TREE_PIN）—— 尝试物化真实 commit $PIN ..."
        # 3a. 物化真实 commit 对象：上游可能已从临时 429 / HTTP RPC 异常恢复。
        #     成功 → HEAD 就是真实的 $PIN（最强状态）；失败不影响内容保证（tree 已锁定）。
        #     --depth 1：只需该 commit 与其 tree 的对象，不拉全历史（父链非必需）。
        REAL=0
        for f in 1 2 3; do
          local HTTPC=() PROTC=()
          [ "$f" -ge 2 ] && HTTPC=(-c http.version=HTTP/1.1)
          [ "$f" -ge 3 ] && PROTC=(-c protocol.version=1)
          [ "$f" -ge 2 ] && sleep 5
          if git "${HTTPC[@]}" "${PROTC[@]}" -C "$ACQ_TMP/src" fetch --depth 1 --no-tags "$UPSTREAM_URL" "$PIN" >/dev/null 2>&1 \
             && git -C "$ACQ_TMP/src" reset -q --hard "$PIN" >/dev/null 2>&1 \
             && [ "$(repo_head "$ACQ_TMP/src")" = "$PIN" ]; then
            REAL=1
            break
          fi
        done
        if [ "$REAL" = "1" ]; then
          log "阶段3 成功 —— 已物化真实 commit，HEAD 校验 = $PIN"
          rm -rf "$SRC_DIR" 2>/dev/null || true
          mv "$ACQ_TMP/src" "$SRC_DIR" || { STAGE3_FAILED="移动源码到 $SRC_DIR 失败"; return 1; }
          write_meta git
          return 0
        fi
        # 3b. 上游仍无法提供 commit 对象：采用内容级校验通过的合成提交（tree 已锁定 == TREE_PIN）
        log "阶段3 上游仍无法提供 commit 对象 —— 采用 tree 校验通过的合成提交（内容 = $TREE_PIN）"
        git -C "$ACQ_TMP/src" -c user.name="Hermes Restore" -c user.email="restore@localhost" \
            commit -qm "hermes-agent @ $PIN (official archive)" 2>/dev/null \
          || { STAGE3_FAILED="归档源提交失败"; return 1; }
        log "阶段3 成功 —— 内容级校验通过（tree = $TREE_PIN）"
        rm -rf "$SRC_DIR" 2>/dev/null || true
        mv "$ACQ_TMP/src" "$SRC_DIR" || { STAGE3_FAILED="移动源码到 $SRC_DIR 失败"; return 1; }
        write_meta archive
        return 0
      else
        STAGE3_FAILED="tree 校验失败：得到 $TREE，期望 $TREE_PIN —— 内容与锁定提交不符，已拒绝"
        return 1
      fi
    else
      STAGE3_FAILED="归档解压失败"
      return 1
    fi
  else
    STAGE3_FAILED="归档下载失败（curl 退出码 $?）"
    return 1
  fi
}

if [ "$SKIP_SOURCE" = "0" ]; then
  if ! acquire_source; then
    die "源码获取全部失败，已停止（未修改任何源码）。诊断：
  阶段1: ${STAGE1_FAILED:-无}
  阶段2: ${STAGE2_FAILED:-无}
  阶段3: ${STAGE3_FAILED:-无}
可能原因与处理：
  - HTTP 429 = GitHub 临时限流：等待 30-60 分钟后重试，或切换网络（Wi-Fi/流量）
  - 'expected acknowledgments' = HTTP/2 RPC 异常：脚本已自动改用 HTTP/1.1 重试
  - 网络不可达：先验证 curl -I https://github.com 是否 200
手动恢复方式（然后重新执行 bash restore.sh）：
  git clone https://github.com/NousResearch/hermes-agent.git $SRC_DIR
  cd $SRC_DIR && git checkout $PIN"
  fi
fi

# ---------------------------------------------------------------- 3. 应用补丁（严格模式）
if ! patch_applied; then
  log "应用 XMPP 补丁 ..."
  if ! git -C "$SRC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    die "补丁无法干净应用（上游代码已变化？）。已停止，未修改任何源码。如需适配请重新生成补丁"
  fi
  git -C "$SRC_DIR" apply "$PATCH_FILE" || die "补丁应用失败。已停止"
  grep -q 'XMPP = "xmpp"'     "$SRC_DIR/gateway/config.py"    || die "补丁校验失败: config.py"
  grep -q 'XMPP_ALLOWED_JIDS' "$SRC_DIR/gateway/authz_mixin.py" || die "补丁校验失败: authz_mixin.py"
  log "补丁应用并校验通过"
else
  log "补丁已应用 —— 跳过"
fi

# ---------------------------------------------------------------- 4. venv + 依赖（RESTORE_SKIP_PIP=1 时跳过，供快速验证）
if [ "${RESTORE_SKIP_PIP:-0}" != "1" ]; then
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    command -v python >/dev/null 2>&1 || die "缺少 python，请先: pkg install python"
    log "创建 venv ..."
    python -m venv "$VENV_DIR"
  fi
  PY="$VENV_DIR/bin/python"
  "$PY" -c 'import sys; assert (3,11) <= sys.version_info < (3,14), "需要 Python 3.11~3.13"' \
    || die "Python 版本不受支持（$( "$PY" -V 2>&1 )），Termux 请用: pkg install python"
  if ! "$PY" -c 'import hermes_cli' >/dev/null 2>&1; then
    log "安装 Hermes（官方 Termux 路径: pip install -e '.[termux]' -c constraints-termux.txt）..."
    ( cd "$SRC_DIR" && "$VENV_DIR/bin/pip" install -e ".[termux]" -c constraints-termux.txt ) \
      || die "Hermes 安装失败。已停止"
  else
    log "hermes_cli 已安装 —— 跳过"
  fi
  if ! "$PY" -c 'import slixmpp' >/dev/null 2>&1; then
    log "安装 XMPP 依赖 slixmpp aiodns（自动带 pycares）..."
    "$VENV_DIR/bin/pip" install slixmpp aiodns || die "XMPP 依赖安装失败。已停止"
  else
    log "slixmpp 已安装 —— 跳过"
  fi
else
  log "RESTORE_SKIP_PIP=1：跳过 venv/pip 安装（测试模式）"
fi

# ---------------------------------------------------------------- 5. XMPP 插件
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

# ---------------------------------------------------------------- 6. 自定义 skills（不覆盖已有）
log "同步自定义 skills（已存在的不覆盖）..."
mkdir -p "$HERMES_HOME/skills"
cp -rn "$REPO_DIR/skills/." "$HERMES_HOME/skills/" 2>/dev/null || true

# ---------------------------------------------------------------- 7. 配置模板（绝不覆盖现有）
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
