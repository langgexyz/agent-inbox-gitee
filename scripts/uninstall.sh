#!/usr/bin/env bash
# agent-inbox-gitee uninstall.sh
# Remove SessionStart hook from ~/.claude/settings.json. Keeps config.json.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_PATH="$SKILL_DIR/claude-hooks/SessionStart"

ok()   { echo "ok: $*"; }
info() { echo "info: $*"; }

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
