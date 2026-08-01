#!/usr/bin/env bash
# merge-gate-run.sh —— 本仓的测试面聚合入口（IK5R86）。
#
# 为什么要有这一层：`.project-profile.yml` 的 gates.merge.test_command 原来直接指
# scripts/resident-root-guard.selftest.sh 这一个文件。单文件当入口有两个问题——
# 加第二个 selftest 时得改 profile（而 profile 是给别的仓也看的元信息，不该跟着测试
# 数量变），且没有地方挂「装机面被改动时跑全栈端到端」那种条件触发。
#
# 收哪些：仓里真有的、快且零准备的自测（无需装依赖、无需起服务）。
#   1. scripts/*.selftest.sh —— 常驻位置守卫等
#   2. 装机面被改动时的全栈端到端（见下）
#
# usage: bash tools/merge-gate-run.sh
# exit: 0 全绿；1 有红项

set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAIL=0

step() {  # step <名字> <命令...>
  local name="$1"; shift
  echo ""
  echo "info: === $name ==="
  if "$@"; then
    echo "ok: $name"
  else
    echo "error: $name 红 —— 重跑看详情: $*"
    FAIL=1
  fi
}

# 1. 仓内 selftest（glob 收，加一个新的不用改这里也不用改 profile）
shopt -s nullglob
for t in scripts/*.selftest.sh; do
  step "$t" bash "$t"
done
shopt -u nullglob

# 2. 装机面被改动时，跑全栈端到端（IK5R86）。
#
# 改安装器是最容易引入「新机器上装不上」的操作，而那类问题在本机永远看不见：隔壁仓的
# selftest 硬用 ~/.claude/.tmp 却不建它，本机碰巧有所以永远绿、新机器上该仓根本装不上，
# 是全量装才发现的，不是任何 gate 拦下来的。
#
# 脚本住在 ~/.claude/bootstrap/（要装全套才有意义，不属于任何单个仓）。这里是**调用**
# 不是 source —— 跨仓 source 违反依赖方向，而且只 clone 本仓的机器上根本没有那个文件。
# 两种「跑不成」分开：找不到脚本 = 只 clone 了本仓的环境，预期内，跳过并说明；
# 找到但跑红 = 真失败，拦。
E2E_VERIFY="${CLAUDE_HOME:-$HOME/.claude}/bootstrap/e2e-verify.sh"
# selftest 也算装机面（IK5T07）：本仓的 install.sh / setup.sh 会跑自己的 selftest，红了就
# exit 1，于是改 selftest 一样能让仓装不上。IK5SWN 那次退化改的正是某个 selftest，而当时
# 六处触发面都不含它，merge-gate 没跑 e2e，退化一路合进 main。
E2E_TRIGGER='(^|/)install\.sh$|(^|/)uninstall\.sh$|(^|/)setup\.sh$|(^|/)resident-root-guard\.sh$|selftest'
CHANGED="$(git diff --name-only origin/main...HEAD 2>/dev/null || true)"
if [ "${E2E_VERIFY_FORCE:-0}" = "1" ] || echo "$CHANGED" | grep -qE "$E2E_TRIGGER"; then
  if [ -x "$E2E_VERIFY" ]; then
    step "e2e-verify（装机面被改动，跑全栈端到端）" bash "$E2E_VERIFY"
  else
    echo ""
    echo "info: === e2e-verify ==="
    echo "info: 装机面被改动，但找不到 ${E2E_VERIFY} —— 只 clone 了本仓的环境是正常的，跳过"
    echo "info: 装了全套的机器上这一步会跑（它验的是「这些仓凑在一起能不能干活」）"
  fi
else
  echo ""
  echo "info: === e2e-verify ==="
  echo "info: 本次 diff 没碰装机面，跳过（改 install/uninstall/setup 时会跑）"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "ok: merge-gate-run 全绿"
else
  echo "error: merge-gate-run 有红项（见上）"
fi
exit "$FAIL"
