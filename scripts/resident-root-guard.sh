#!/usr/bin/env bash
# resident-root-guard —— 安装器 / 卸载器共用的「安装源必须是仓的常驻位置」预检（IK5Q3Z）。
#
# 为什么：install.sh / uninstall.sh 的 SKILL_DIR 按脚本自身位置推导，而它们写的是**全局**
# 落点 —— `~/.claude/settings.json` 里那条 SessionStart hook 注册，值就是
# `$SKILL_DIR/claude-hooks/SessionStart`。从 worktree 或临时副本里跑一次，那条注册就指到
# 那个目录上；worktree 一删（`wt rm` 是日常动作）指针就悬空。
#
# 失败方向是这条守卫存在的全部理由：hook 注册是数组、规范那份还在，所以**功能不丢、
# 只多一条 error** —— 每次会话启动打一次「文件不存在」，不是当场崩，所以没人会立刻发现。
# IK5Q60 就是这么在 settings.json 里攒出三条指向已删 worktree 的注册的。
#
# 卸载侧的失败方向反过来、同样隐蔽：uninstall.sh 按 `$SKILL_DIR/claude-hooks/SessionStart`
# 这个**完整路径**去 settings.json 里匹配删除。从副本跑时前缀对不上，一条也匹配不到，
# 真正注册着的那条纹丝不动，脚本却照打 `ok: uninstalled` 并 exit 0（假成功）。
#
# 为什么抽成共享文件而不是两份各写一段（IK5Q60 的结论）：同仓两个入口抄两份必漂 ——
# 改了 install.sh 的判据、忘了 uninstall.sh，剩下的那半就是没人知道的缺口。
#
# 判据用结构性的，不靠路径长什么样：linked worktree 的 `--git-dir` 与 `--git-common-dir`
# 不同。再补一条路径黑名单，兜住「不是 worktree 但仍是临时副本」（拷进 .cache / tmp 里跑）。
# 逃生口：显式 `AGENT_INBOX_GITEE_ROOT=` 时整条守卫放行 —— 那是调用方明确知道自己在指哪
# （本仓的 resident-root-guard.selftest 的正向对照就靠它证明「拦的是没明说，不是这个路径」）。
#
# usage: source "$(dirname "${BASH_SOURCE[0]}")/resident-root-guard.sh"
#        require_resident_root "$SKILL_ROOT" "<脚本名>" "<这次要写的全局落点，一句话>"

# 临时目录判据。列在这里的路径段一律不是仓的常驻位置。
_RESIDENT_ROOT_TEMP_GLOBS=(
  '*/worktrees/*'
  '*/.cache/*'
  '/tmp/*'
  '/private/tmp/*'
  '/var/folders/*'
)

_resident_root_is_temp() {  # _resident_root_is_temp <path> -> 0=临时 1=不是
  local p="$1" g
  for g in "${_RESIDENT_ROOT_TEMP_GLOBS[@]}"; do
    # shellcheck disable=SC2254  # glob 本来就要按模式匹配，不能加引号
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}

# 常驻位置的三级回退：linked worktree 能顺着 --git-common-dir 反推出主 checkout；
# 反推不出来（临时副本自成一个仓 / 根本不在 git 里）就退到本机文档里的常驻落点。
_resident_root_hint() {  # _resident_root_hint <path> -> stdout 常驻位置绝对路径
  local root="$1" commondir cand
  commondir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$commondir" ]]; then
    cand="$(cd "$(dirname "$commondir")" 2>/dev/null && pwd -P || true)"
    if [[ -n "$cand" ]] && ! _resident_root_is_temp "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/.claude/skills/agent-inbox-gitee"
}

# 主入口。不满足就 `exit 1`（fail-closed）——写歪的全局配置比装不上难发现得多。
require_resident_root() {  # require_resident_root <SKILL_ROOT> <脚本名> <全局落点描述>
  local root="$1" script="$2" what="$3"

  # 逃生口：调用方显式指定过根，就是它明确知道自己在指哪。
  # 写成完整 if 而不是 `[[ ]] && return`：后者整条 list 的退出码是 1，在 `set -e` 下
  # 会把调用方直接带走。
  if [[ -n "${AGENT_INBOX_GITEE_ROOT:-}" ]]; then
    return 0
  fi

  local hint reason=""
  local gitdir commondir
  gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || true)"
  commondir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"

  if [[ -n "$gitdir" && -n "$commondir" && "$gitdir" != "$commondir" ]]; then
    reason="是 linked worktree"
  elif _resident_root_is_temp "$root"; then
    reason="落在临时目录里"
  else
    echo "ok: 安装源是常驻位置: $root"
    return 0
  fi

  # 变量一律 ${var}：`set -u` 下裸 $var 紧跟中文字符会把中文吞进变量名，报成
  # 「unbound variable」——错在报错这一行，跟真正的问题毫无关系。
  hint="$(_resident_root_hint "$root")"
  {
    echo "error: ${root} ${reason}，不是仓的常驻位置，拒绝继续。"
    echo "       ${script} 写的是全局落点（${what}）。指到一个会被删的目录上，"
    echo "       目录一没就成死指针 —— 现象是每次会话启动打一条「文件不存在」，"
    echo "       而不是当场崩，所以没人会立刻发现（IK5Q60 就是这么来的）。"
    echo "       修法：从常驻位置跑 —— bash ${hint}/scripts/${script}"
    echo "       确实要指到这里：显式 AGENT_INBOX_GITEE_ROOT=${root} bash scripts/${script}"
  } >&2
  exit 1
}
