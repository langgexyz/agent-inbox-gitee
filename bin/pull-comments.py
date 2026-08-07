#!/usr/bin/env python3
"""pull-comments.py

Fetch Gitee enterprise issue comments where:
  - issue assignee or author matches self_user_id (per config)
  - issue updated within --hours window
  - comment created within --hours window
  - comment author != self (configurable)

Write the formatted summary to <cwd>/.claude/MainAgentContext.md inside
tracker-inbox:start/end marker block（旧名 agent-inbox-gitee 的 marker 兼容读取）. Stdlib only (urllib + json).

Usage:
  pull-comments.py [--cwd PATH] [--hours N] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path


MARKER_START = "<!-- agent-inbox-gitee:start -->"
MARKER_END = "<!-- agent-inbox-gitee:end -->"

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
CONFIG_PATH = SKILL_DIR / "config.json"


def log(level: str, msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} [{level}] {msg}", file=sys.stderr, flush=True)


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        log("error", f"config not found at {CONFIG_PATH}")
        log("error", "cp config.example.json → config.json + fill in values")
        sys.exit(1)
    with open(CONFIG_PATH) as f:
        c = json.load(f)
    gitee = c.get("gitee", {})
    # "$VAR" 形式的值一律从环境读。org 耦合值（token / enterprise_id）不写死在
    # 示例配置里，这样仓可以公开分发。
    for key in ("token", "enterprise_id"):
        v = gitee.get(key)
        if isinstance(v, str) and v.startswith("$"):
            gitee[key] = os.environ.get(v[1:], "")
    for key in ("token", "enterprise_id"):
        if not gitee.get(key):
            log("error", f"gitee.{key} empty after env expand — check config.json")
            sys.exit(1)
    return c


def gitee_get(
    path: str, token: str, params: dict | None = None
) -> list | dict | None:
    if params:
        path += "?" + urllib.parse.urlencode(params)
    url = f"https://gitee.com/api/v5/{path.lstrip('/')}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        excerpt = e.read().decode()[:200]
        log("error", f"GET {path}: {e.code} {excerpt}")
        return None
    except Exception as e:
        log("error", f"GET {path} failed: {e}")
        return None


def parse_ts(iso: str) -> int:
    """ISO 8601 with optional tz → epoch seconds."""
    if not iso:
        return 0
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())
    except Exception:
        return 0


def fmt_rel(ts: int) -> str:
    delta = int(time.time()) - ts
    if delta < 60:
        return f"{delta}s ago"
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    return f"{delta // 86400}d ago"


def collect_issues(cfg: dict, since_ts: int) -> list[dict]:
    ent = cfg["gitee"]["enterprise_id"]
    tok = cfg["gitee"]["token"]
    self_id = cfg["gitee"]["self_user_id"]
    watch = cfg["watch"]
    max_n = cfg["limits"]["max_issues"]

    seen: dict[str, dict] = {}

    if watch.get("assignee"):
        r = gitee_get(
            f"enterprises/{ent}/issues",
            tok,
            {"assignee_id": self_id, "state": "open", "per_page": max_n},
        )
        if isinstance(r, list):
            for i in r:
                ident = i.get("ident") or str(i.get("number") or "")
                if ident:
                    seen[ident] = i

    if watch.get("author"):
        r = gitee_get(
            f"enterprises/{ent}/issues",
            tok,
            {"author_id": self_id, "state": "open", "per_page": max_n},
        )
        if isinstance(r, list):
            for i in r:
                ident = i.get("ident") or str(i.get("number") or "")
                if ident:
                    seen[ident] = i

    filtered = [
        i for i in seen.values()
        if parse_ts(i.get("updated_at", "")) >= since_ts
    ]
    filtered.sort(key=lambda x: parse_ts(x.get("updated_at", "")), reverse=True)
    return filtered[:max_n]


def collect_comments(cfg: dict, issue: dict, since_ts: int) -> list[dict]:
    ent = cfg["gitee"]["enterprise_id"]
    tok = cfg["gitee"]["token"]
    self_id = cfg["gitee"]["self_user_id"]
    max_c = cfg["limits"]["max_comments_per_issue"]
    exclude_self = cfg.get("exclude_self_comments", True)

    ident = issue.get("ident") or str(issue.get("number") or "")
    r = gitee_get(
        f"enterprises/{ent}/issues/{ident}/comments",
        tok,
        {"per_page": 50},
    )
    if not isinstance(r, list):
        return []

    fresh = []
    for c in r:
        cts = parse_ts(c.get("created_at", ""))
        if cts < since_ts:
            continue
        author_id = (c.get("author") or {}).get("id")
        if exclude_self and author_id == self_id:
            continue
        fresh.append(c)
    fresh.sort(key=lambda x: parse_ts(x.get("created_at", "")))
    return fresh[-max_c:]


def render(
    issues_with_comments: list[tuple[dict, list[dict]]],
    window_hours: int,
    now_ts: int,
) -> str:
    ts_str = time.strftime("%Y-%m-%d %H:%M", time.localtime(now_ts))
    lines = [
        f"## 最近 Gitee 评论（截至 {ts_str}，覆盖 {window_hours}h）",
        "",
    ]

    total = 0
    for issue, comments in issues_with_comments:
        title = (issue.get("title") or "").strip()
        if len(title) > 50:
            title = title[:50] + "…"
        for c in comments:
            total += 1
            author_info = c.get("author") or {}
            author = (
                author_info.get("name")
                or author_info.get("login")
                or "?"
            )
            ts = parse_ts(c.get("created_at", ""))
            body = (c.get("body") or "").strip().replace("\n", " ")
            if len(body) > 200:
                body = body[:200] + "…"
            ident = issue.get("ident") or str(issue.get("number") or "")
            lines.append(
                f'- **{ident}** {author} ({fmt_rel(ts)}): "{body}"'
                + (f" — _{title}_" if title else "")
            )

    if total == 0:
        lines.append(f"_近 {window_hours}h 无新评论_")

    lines.append("")
    return "\n".join(lines)


def update_main_agent_context(cwd: str, section_md: str) -> None:
    path = Path(cwd) / ".claude" / "MainAgentContext.md"
    path.parent.mkdir(parents=True, exist_ok=True)

    existing = path.read_text() if path.exists() else ""
    block = f"{MARKER_START}\n{section_md}\n{MARKER_END}\n"

    if MARKER_START in existing and MARKER_END in existing:
        before, _, rest = existing.partition(MARKER_START)
        _, _, after = rest.partition(MARKER_END)
        before = before.rstrip() + "\n\n" if before.strip() else ""
        after = after.lstrip("\n")
        new = before + block + ("\n" + after if after else "")
    elif existing.strip():
        new = block + "\n" + existing
    else:
        new = block

    tmp = path.with_suffix(".tmp")
    tmp.write_text(new)
    tmp.replace(path)
    log("info", f"updated {path}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--hours", type=int, default=None)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    cfg = load_config()
    hours = args.hours or cfg["window"]["hours"]
    now_ts = int(time.time())
    since_ts = now_ts - hours * 3600

    log(
        "info",
        f"pulling Gitee comments since {time.strftime('%H:%M', time.localtime(since_ts))} (window={hours}h, cwd={args.cwd})",
    )

    issues = collect_issues(cfg, since_ts)
    log("info", f"found {len(issues)} relevant issues")

    issues_with_comments = []
    for issue in issues:
        comments = collect_comments(cfg, issue, since_ts)
        if comments:
            issues_with_comments.append((issue, comments))

    section = render(issues_with_comments, hours, now_ts)

    if args.dry_run:
        print(section)
        return

    update_main_agent_context(args.cwd, section)


if __name__ == "__main__":
    main()
