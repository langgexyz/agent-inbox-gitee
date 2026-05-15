#!/usr/bin/env bash
# agent-inbox-gitee install.sh

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_PATH="$SKILL_DIR/claude-hooks/SessionStart"

info() { echo "info: $*"; }
ok()   { echo "ok: $*"; }
warn() { echo "warning: $*"; }
fail() { echo "error: $*" >&2; exit 1; }

# 1. deps
command -v python3 >/dev/null || fail "python3 not in PATH"
command -v jq      >/dev/null || fail "jq required for settings.json patching"
ok "deps verified"

# 2. config
if [[ ! -f "$SKILL_DIR/config.json" ]]; then
  fail "config.json not found. Run: cp $SKILL_DIR/config.example.json $SKILL_DIR/config.json + fill in"
fi

# 3. verify token (env expansion)
TOKEN_RAW="$(python3 -c "
import json, os
with open('$SKILL_DIR/config.json') as f:
    c = json.load(f)
t = c.get('gitee', {}).get('token', '')
if t.startswith('\$'):
    t = os.environ.get(t[1:], '')
print(t)
")"
[[ -n "$TOKEN_RAW" ]] || fail "gitee.token empty (set in config.json or export \$GITEE_TOKEN)"
ok "config + token verified"

# 4. patch settings.json
mkdir -p "$HOME/.claude"
[[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"

tmp="$SETTINGS_FILE.tmp"
jq --arg cmd "$HOOK_PATH" '
  .hooks //= {} |
  .hooks.SessionStart //= [] |
  .hooks.SessionStart |= (
    if any(.[]?; .hooks[]?.command == $cmd) then .
    else . + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
    end
  )
' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
ok "registered SessionStart hook in $SETTINGS_FILE"

# 5. dry-run verify
info "test dry-run"
GITEE_TOKEN="$TOKEN_RAW" "$SKILL_DIR/bin/pull-comments.py" --dry-run --cwd "$PWD" 2>&1 | head -15

cat <<EOF

== installed ==
  hook:    $HOOK_PATH
  config:  $SKILL_DIR/config.json
  test:    $SKILL_DIR/bin/pull-comments.py --dry-run

new windows 启动后 .claude/MainAgentContext.md 会自动含 "最近 Gitee 评论" 节

EOF
