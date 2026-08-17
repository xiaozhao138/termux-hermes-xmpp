#!/usr/bin/env bash
# =============================================================================
# backup.sh — 导出"安全可备份内容"（脱敏导出）
#
# 只导出可安全公开/留存的内容：补丁、XMPP 插件源码、自定义 skills、配置模板。
# 绝不包含：.env、auth.json、OAuth token、state.db、历史记录、sessions、
#           memories、venv 等敏感或机器相关数据（见 .gitignore）。
# 导出前会做脱敏校验（scrub_check.py），任何真实密钥值出现在导出内容中都会中止。
#
# 用法：
#   bash backup.sh                    # 导出到 ./backups/
#   bash backup.sh /自定义/输出目录    # 指定输出目录
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$REPO_DIR/backups}"
TS="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

log() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 1. 汇总安全内容
log "汇总安全内容 ..."
mkdir -p "$STAGE/patches" "$STAGE/plugins/xmpp" "$STAGE/skills" "$STAGE/optional-scripts"
cp "$REPO_DIR"/patches/*.patch "$STAGE/patches/" 2>/dev/null || true
cp "$REPO_DIR/plugins/xmpp/"*.py "$REPO_DIR/plugins/xmpp/"*.yaml "$STAGE/plugins/xmpp/" 2>/dev/null || true
cp -r "$REPO_DIR/skills/." "$STAGE/skills/" 2>/dev/null || true
cp "$REPO_DIR/config.yaml.template" "$STAGE/" 2>/dev/null || true
cp "$REPO_DIR/.env.example" "$STAGE/" 2>/dev/null || true
cp "$REPO_DIR/optional-scripts/"* "$STAGE/optional-scripts/" 2>/dev/null || true

# ---------------------------------------------------------------- 2. 脱敏校验（硬性）
log "脱敏校验（扫描真实密钥值是否泄漏进导出内容）..."
python3 "$REPO_DIR/scripts/scrub_check.py" "$STAGE"

# ---------------------------------------------------------------- 3. 打包
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/termux-hermes-safe-export-$TS.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" .
log "完成 ✔"
echo
echo "  安全备份: $TARBALL"
echo "  内容    : 补丁 / XMPP 插件 / 自定义 skills / 配置模板（全部脱敏）"
echo "  不含    : .env、auth.json、OAuth、state.db、历史、会话、memory、venv"
echo "  （backups/ 已在 .gitignore 中，不会误传 GitHub）"
