# agent-inbox-gitee

SessionStart hook 拉 Gitee 最近 6h 评论，写到当前项目 `.claude/MainAgentContext.md`。Agent 启动就看到 user 在 飞书 / Gitee 留的话，主动响应。

完整说明见 [SKILL.md](./SKILL.md)。

## 快速安装

```bash
git clone https://github.com/langgexyz/agent-inbox-gitee.git ~/.claude/skills/agent-inbox-gitee
cd ~/.claude/skills/agent-inbox-gitee
cp config.example.json config.json
vim config.json   # 填 GITEE_TOKEN + self_user_id + enterprise_id
./scripts/install.sh
```

## 卸载

```bash
~/.claude/skills/agent-inbox-gitee/scripts/uninstall.sh
```

## License

MIT
