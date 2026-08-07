---
name: tracker-inbox
description: SessionStart hook 拉 Gitee 最近 6h 新评论 → 写到当前项目 .claude/MainAgentContext.md，agent 启动就看到 user 在 飞书/Gitee 留的话。配 agent-inbound-feishu (Phase 3b) 形成 inbound 闭环。触发：拉 Gitee 评论 / SessionStart inbox / 看新评论 / agent inbox
---

# tracker-inbox

每次 Claude Code 窗口启动时，hook 拉 user 关心的 Gitee issue 最近 6h 新评论，写到 cwd 项目的 `.claude/MainAgentContext.md` 里。Agent 看 MainAgentContext.md 时自然看到，主动响应。

## 流程

```
[Claude Code session 启动]
       ↓ SessionStart hook
[parse stdin JSON 拿 session_id + cwd]
       ↓
[pull-comments.py --cwd <cwd> --hours 6]
       ↓
[Gitee API: list enterprise issues where (assignee=self OR author=self) AND updated_at > 6h ago]
       ↓
[每个 issue: list comments 过滤 6h 内 + 排除 self]
       ↓
[渲染 markdown 段]
       ↓
[原子更新 <cwd>/.claude/MainAgentContext.md 的 tracker-inbox:start/end marker 块]

后续 user 看 MainAgentContext.md 或 agent 启动后 load-status.sh hook 自动 cat 前 40 行，新评论入 context。
```

## 安装

```bash
git clone https://github.com/langgexyz/tracker-inbox.git ~/.claude/skills/tracker-inbox
cd ~/.claude/skills/tracker-inbox
cp config.example.json config.json
vim config.json  # 填 GITEE_TOKEN + self_username + enterprise_id
./scripts/install.sh
```

install.sh 做的事：

1. 检查 deps (python3, jq)
2. 检查 GITEE_TOKEN（config.json 或 env）
3. jq patch `~/.claude/settings.json` 注册 SessionStart hook
4. 自检：跑一次 pull-comments.py --dry-run

## 卸载

```bash
~/.claude/skills/tracker-inbox/scripts/uninstall.sh
```

unregister hook 从 settings.json。config.json 保留。

## MainAgentContext.md 区段

被替换的部分由 marker 包：

```markdown
<!-- tracker-inbox:start -->
## 最近 Gitee 评论（截至 2026-05-15 18:30，覆盖 6h）

- **IJNOWO** 张三 (1h ago): "我要再加一个功能 X..."
- **IJNM9H** 李四 (3h ago): "PR review 完毕，approve"
- **IJNMRR** 王五 (5h ago): "e2e 测了下，飞书消息收到"

无 → "近 6h 无新评论"
<!-- tracker-inbox:end -->
```

agent 看到这段后该主动 say "看了下你最近评论，先处理 IJNOWO 吧"。

## 关注规则（config 决定）

```json
{
  "watch": {
    "assignee": true,  // assignee=self 的 issue 也拉
    "author":   true,  // author=self 的 issue 也拉
    "labels":   []     // 含这些 label 的额外拉（暂未实现）
  }
}
```

assignee + author 两路并集，去重。

## 限制

- 只读 enterprise issue（不读 enterprise PR — PR review 评论格式不同，未来扩）
- 6h 时间窗硬编码（可改 config，TBD）
- 中文 emoji 不过滤（如果你不喜欢直接改 pull-comments.py 渲染逻辑）
- **不调 飞书 API** — 只读 Gitee。Phase 3b 已经把飞书 reply 通过 daemon 落到 Gitee comments，本 skill 站在 Gitee 端读。

## 与其他 skill 关系

| skill | 关系 |
|---|---|
| `agent-inbound-feishu` (Phase 3b) | 飞书 reply 落到 Gitee comment，本 skill 拉 Gitee comment 进 context；闭环 |
| `agent-feishu-notify` (Phase 3a) | 反向：agent 主动发飞书 |
| `agent-eventlog` | 提供 SessionStart hook 注册基础设施（settings.json patch 模式）|

## 后续 phase

- 3c.1（本 phase MVP）：assignee+author 拉，6h 窗口固定
- 3c.2：动态时间窗（自上次 session_end）
- 3c.3：加 PR review 评论
- 3c.4：unread state 跟踪（user 看过的不重复 surface）
