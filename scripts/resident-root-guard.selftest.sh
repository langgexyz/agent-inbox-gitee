#!/usr/bin/env bash
# resident-root-guard.selftest —— 断言「安装源必须是仓的常驻位置」这条守卫对**两个入口**
# 都生效（IK5Q3Z）。
#
# 为什么值钱：install.sh 把 `$SKILL_DIR/claude-hooks/SessionStart` 写进
# `~/.claude/settings.json`，那是全机每个会话都读的配置。从 worktree 里跑一次，注册就指
# 过去；worktree 一删（`wt rm` 是日常动作）就成死指针。失败现象是每次会话启动打一条
# 「文件不存在」——不是当场崩，所以没人会立刻发现（IK5Q60 攒出过三条这样的死指针）。
# uninstall.sh 的失败方向反过来：按完整路径匹配删除，前缀对不上就一条也删不掉，却照打
# `ok: uninstalled`。
#
# 两条负向各配一条正向对照（同一目录 + 显式 AGENT_INBOX_GITEE_ROOT -> 该装上 / 该卸掉）。
# 没有正向对照的话，守卫写成「永远拒装」也能全绿。
#
# 结构性判据的夹具是一个路径**完全正常**的 linked worktree（不含 worktrees / .cache /
# tmp 任何字样），黑名单一条都不匹配 —— 拦住它只能靠 --git-dir != --git-common-dir。
#
# 安全：全程假 HOME，**绝不碰真实的 ~/.claude/settings.json**；末尾拿前后 md5 对一遍。
#
# 用法: bash scripts/resident-root-guard.selftest.sh
# exit: 0=全绿 1=有失败

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(dirname "$HERE")"
FAILS=0

check_true() {  # check_true <name> <0=pass>
  if [ "$2" = "0" ]; then echo "ok: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi
}

md5_of() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo '<none>'; }
REAL_SETTINGS="$HOME/.claude/settings.json"
REAL_SETTINGS_BEFORE="$(md5_of "$REAL_SETTINGS")"

command -v jq >/dev/null 2>&1 || { echo "FAIL: 需要 jq（install.sh 用它改 settings.json）"; exit 1; }

# 夹具落点：**故意不放 .cache/ 下**。守卫的路径黑名单认 .cache/，夹具落在那里就分不清
# 是「linked worktree 的结构性判据」生效还是「路径长得像临时目录」生效。判据直接借守卫
# 自己的函数，不在这里抄一份黑名单 —— 抄了就会漂（开发期本仓自己就在 worktree 里，
# 路径含 /worktrees/，$REPO 那个默认落点会被判为临时目录，于是退到 $HOME 下）。
# shellcheck source=scripts/resident-root-guard.sh
. "$REPO/scripts/resident-root-guard.sh"
GUARD="$REPO/.selftest-guard-root"
if _resident_root_is_temp "$GUARD"; then
  GUARD="$HOME/.claude/.selftest-guard-tracker-inbox-$$"
fi
rm -rf "$GUARD"
trap 'rm -rf "$GUARD"' EXIT
mkdir -p "$GUARD"
echo "info: 守卫夹具落点 = ${GUARD}"

# 建夹具仓时要躲开本机的 core.hooksPath / commit 规范 hook，否则 commit 会被 commit-msg
# 的 Why:/Test: 校验拦下，夹具建不出来。
git_clean() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"; }

copy_repo_to() {  # copy_repo_to <dst> —— 把仓内受版本控制的文件按原路径铺进 dst
  local dst="$1" f
  mkdir -p "$dst"
  (cd "$REPO" && git ls-files --cached --others --exclude-standard) | while IFS= read -r f; do
    mkdir -p "$dst/$(dirname "$f")"
    cp -p "$REPO/$f" "$dst/$f"
  done
  # config.json 是 gitignored 的真凭据文件，不复制；夹具用一份假的（token 走 env）。
  printf '%s\n' '{"gitee":{"token":"$GITEE_TOKEN","self_user_id":"selftest"}}' > "$dst/config.json"
}

# 每个场景一个**独立的**假 HOME：断言「一个字都没写」才有意义。
fresh_home() {  # fresh_home <name> -> stdout 假 HOME 路径
  local h="$GUARD/home-$1"
  rm -rf "$h"
  mkdir -p "$h/.local/bin"
  printf '%s' "$h"
}

run_installer() {  # run_installer <源目录> <脚本> <假HOME> <日志>
  env -u AGENT_INBOX_GITEE_ROOT HOME="$3" GITEE_TOKEN=selftest-fake-token \
    bash "$1/scripts/$2" > "$4" 2>&1
}

# ---- 1. 夹具：一个 linked worktree，路径完全正常（黑名单一条都不匹配）----
WT_ORIGIN="$GUARD/inbox-origin"
mkdir -p "$WT_ORIGIN"
git_clean -C "$WT_ORIGIN" init -q
git_clean -C "$WT_ORIGIN" -c user.email=selftest@local -c user.name=selftest \
  commit -q --allow-empty -m init
git_clean -C "$WT_ORIGIN" worktree add -q "$GUARD/inbox-copy" -b guardtest
copy_repo_to "$GUARD/inbox-copy"

! _resident_root_is_temp "$GUARD/inbox-copy"
check_true "前提: 夹具路径不匹配任何黑名单（$GUARD/inbox-copy）—— 拦住它只能靠结构性判据" $?

# ---- 2. 负向：从 linked worktree 跑 install.sh ----
H_WT="$(fresh_home wt-install)"
run_installer "$GUARD/inbox-copy" install.sh "$H_WT" "$GUARD/wt-install.log"
[ $? -ne 0 ]
check_true "负向: 从 linked worktree 跑 install.sh -> 拒装" $?

grep -q "是 linked worktree" "$GUARD/wt-install.log"
check_true "负向: 拒装理由是「linked worktree」（结构性判据触发，不是路径长得像临时目录）" $?

grep -qF "bash $WT_ORIGIN/scripts/install.sh" "$GUARD/wt-install.log"
check_true "负向: 文案给出常驻位置的完整路径（顺 --git-common-dir 反推出主 checkout）" $?

grep -q "AGENT_INBOX_GITEE_ROOT=" "$GUARD/wt-install.log"
check_true "负向: 文案给出逃生口写法（确实要指到这里怎么办）" $?

[ ! -e "$H_WT/.claude" ]
check_true "负向: 拒装时假 HOME 的 ~/.claude 一个字都没写（连目录都没建）" $?

# ---- 3. 负向：从临时目录副本（.cache/，自成一个 git 仓，不是 worktree）----
TMP_COPY="$GUARD/.cache/plain-copy"
copy_repo_to "$TMP_COPY"
git_clean -C "$TMP_COPY" init -q

H_TMP="$(fresh_home tmp-install)"
run_installer "$TMP_COPY" install.sh "$H_TMP" "$GUARD/tmp-install.log"
[ $? -ne 0 ]
check_true "负向: 从临时目录副本（.cache/，非 worktree）跑 install.sh -> 拒装" $?

grep -q "落在临时目录里" "$GUARD/tmp-install.log"
check_true "负向: 拒装理由是「临时目录」（路径黑名单分支，兜住非 worktree 的副本）" $?

[ ! -e "$H_TMP/.claude" ]
check_true "负向: 临时副本拒装时假 HOME 的 ~/.claude 一个字都没写" $?

# ---- 4. 负向：卸载器同守卫（这一侧的失败方向是「假成功」）----
H_UN="$(fresh_home wt-uninstall)"
mkdir -p "$H_UN/.claude"; echo '{}' > "$H_UN/.claude/settings.json"
UN_BEFORE="$(md5_of "$H_UN/.claude/settings.json")"
run_installer "$GUARD/inbox-copy" uninstall.sh "$H_UN" "$GUARD/wt-uninstall.log"
[ $? -ne 0 ]
check_true "负向: 从 linked worktree 跑 uninstall.sh -> 拒卸（否则一条没摘却照打 ok）" $?

! grep -q "^ok: uninstalled" "$GUARD/wt-uninstall.log"
check_true "负向: 拒卸时没有打出 'ok: uninstalled' 那句假成功" $?

[ "$UN_BEFORE" = "$(md5_of "$H_UN/.claude/settings.json")" ]
check_true "负向: 拒卸时假 HOME 的 settings.json 一个字没动" $?

# ---- 5. 正向对照：同一个 worktree 目录 + 显式逃生口 -> 该装上 ----
#     没有这一条，守卫写成「永远拒装」也能全绿。
#
#     只断言到「hook 注册进 settings.json」为止，不断言 install.sh 的退出码：它最后一段
#     会拿 token 真调 Gitee API 做 dry-run，那是网络依赖，跟本文件要测的守卫无关，
#     把它绑进断言只会让这条测试随网络飘。守卫放行与全局写入落到该目录 —— 正是要证的两件事。
H_POS="$(fresh_home positive)"
env HOME="$H_POS" GITEE_TOKEN=selftest-fake-token \
  AGENT_INBOX_GITEE_ROOT="$GUARD/inbox-copy" \
  bash "$GUARD/inbox-copy/scripts/install.sh" > "$GUARD/positive.log" 2>&1

#     判「放行了」看的是 install.sh 走到了守卫**下游**的那一步（注册 hook），不是守卫
#     自己打的 ok —— 逃生口那条分支是直接 return，本来就不打任何东西。
grep -q "^ok: registered SessionStart hook" "$GUARD/positive.log"
check_true "正向: 同一 worktree + 显式 AGENT_INBOX_GITEE_ROOT -> 守卫放行、走到注册那一步（拦的是「没明说」不是这个路径）" $?

grep -qF "$GUARD/inbox-copy/claude-hooks/SessionStart" "$H_POS/.claude/settings.json" 2>/dev/null
check_true "正向: 逃生口生效后 hook 确实注册到了该目录" $?

# ---- 6. 正向对照：卸载器带逃生口 -> 该卸掉 ----
env HOME="$H_POS" AGENT_INBOX_GITEE_ROOT="$GUARD/inbox-copy" \
  bash "$GUARD/inbox-copy/scripts/uninstall.sh" > "$GUARD/positive-uninstall.log" 2>&1
check_true "正向: 同一 worktree + 显式 AGENT_INBOX_GITEE_ROOT -> 卸载器跑通" $?

! grep -qF "$GUARD/inbox-copy/claude-hooks/SessionStart" "$H_POS/.claude/settings.json" 2>/dev/null
check_true "正向: 卸载后那条注册确实从 settings.json 里摘掉了" $?

# ---- 7. 真实 settings.json 全程没被动过 ----
[ "$REAL_SETTINGS_BEFORE" = "$(md5_of "$REAL_SETTINGS")" ]
check_true "隔离: 真实 ~/.claude/settings.json 前后一字不差（md5 ${REAL_SETTINGS_BEFORE}）" $?

echo "--- $([ $FAILS -eq 0 ] && echo PASS || echo FAIL): $FAILS 项失败 ---"
exit $([ $FAILS -eq 0 ] && echo 0 || echo 1)
