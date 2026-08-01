#!/usr/bin/env bash
# agent-inbox-gitee uninstall.sh
# Remove SessionStart hook from ~/.claude/settings.json. Keeps config.json.

set -uo pipefail

SKILL_DIR="${AGENT_INBOX_GITEE_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_PATH="$SKILL_DIR/claude-hooks/SessionStart"

ok()   { echo "ok: $*"; }
info() { echo "info: $*"; }

# 0.5 预检：SKILL_DIR 必须是仓的常驻位置（IK5Q3Z）
#
# 卸载侧的失败方向跟安装侧反过来，同样隐蔽：下面按 $HOOK_PATH 这个**完整路径**去
# settings.json 里匹配删除。从副本跑时前缀对不上，一条也匹配不到，真正注册着的那条
# 纹丝不动，脚本却照打 `ok: uninstalled` 并 exit 0。用户以为卸干净了，实际还在。
# 判据与逃生口跟 install.sh 共用同一份，见 scripts/resident-root-guard.sh。
# shellcheck source=scripts/resident-root-guard.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/resident-root-guard.sh"
require_resident_root "$SKILL_DIR" "uninstall.sh" "~/.claude/settings.json 的 SessionStart hook 注册"

if command -v jq >/dev/null && [[ -f "$SETTINGS_FILE" ]]; then
  tmp="$SETTINGS_FILE.tmp"
  jq --arg cmd "$HOOK_PATH" '
    if .hooks.SessionStart then
      .hooks.SessionStart |= map(
        .hooks |= map(select(.command != $cmd))
      ) |
      .hooks.SessionStart |= map(select(.hooks | length > 0))
    else . end
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  ok "removed SessionStart hook from $SETTINGS_FILE"
fi

info "config.json preserved at $SKILL_DIR/config.json"
ok "uninstalled"
