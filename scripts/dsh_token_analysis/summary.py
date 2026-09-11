#!/usr/bin/env python3
"""Compact summary view of the analysis."""
import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

PLAIN_DIR = Path("/tmp/dsh_plain")
TZ = timezone(timedelta(hours=8))


def parse_ts(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000.0, tz=TZ)


def fmt(n: int) -> str:
    return f"{n:,}"


def window_start(ts: datetime) -> datetime:
    h = ts.hour
    base = ts.replace(hour=0, minute=0, second=0, microsecond=0)
    chosen = max(w for w in (0, 5, 10, 15, 20) if w <= h)
    return base + timedelta(hours=chosen)


call_totals = {}      # (sid, turn, step) -> dict
rate_limit_events = []  # (ts, rid, sid, turn, step)
retry_seen = set()

for path in sorted(PLAIN_DIR.glob("*.zstd")):
    sid = path.stem
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get("type")
            data = ev.get("data") or {}
            ts = ev.get("time")
            if t == "assistant/message":
                msg = data.get("message") or {}
                src = msg.get("source") if isinstance(msg, dict) else None
                if not isinstance(src, dict):
                    continue
                if src.get("provider") != "minimax-cn" or src.get("model") != "MiniMax-M3":
                    continue
                usage = data.get("usage") or {}
                key = (sid, data.get("turn"), data.get("step"))
                rec = call_totals.setdefault(
                    key, {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "ts": ts, "sid": sid}
                )
                rec["input"] += usage.get("inputTokens") or 0
                rec["cache"] += usage.get("cacheReadTokens") or 0
                rec["output"] += usage.get("outputTokens") or 0
                rec["reasoning"] += usage.get("reasoningTokens") or 0
                if ts < rec["ts"]:
                    rec["ts"] = ts
            elif t == "llm/retry":
                rid = data.get("retryId")
                if not rid or rid in retry_seen:
                    continue
                failure = data.get("failure") or {}
                if failure.get("code") != "RATE_LIMIT":
                    continue
                if data.get("provider") != "minimax-cn":
                    continue
                retry_seen.add(rid)
                rate_limit_events.append(
                    (ts, rid, sid, data.get("turn"), data.get("step"))
                )

call_list = sorted(call_totals.values(), key=lambda r: r["ts"])
rate_limit_events.sort(key=lambda r: r[0])

# ---------------------------------------------------------------------------
# Per-RATE_LIMIT summary
# ---------------------------------------------------------------------------
print("## 每次 Rate Limit 触发时的 M3 token 使用")
print()
print("按 retryId 去重后共 14 次 RATE_LIMIT。\"本次调用\"指 rate-limit 那个请求的 assistant/message 上报（input = uncached input，cache = cache-read，out = output，reas = reasoning）。\"窗口累计 / 日累计\"是自当天 / 当窗口起点以来的累计 calls。")
print()
print("| # | 时间 | session | turn/step | input | cache-read | output | reasoning | 窗口累计 tokens | 日累计 tokens |")
print("|---|------|---------|-----------|------:|-----------:|-------:|----------:|---------------:|-------------:|")

# Running totals per day / window
day_running = None
win_running = None
cur_day = None
cur_win = None
for i, (ts, rid, sid, turn, step) in enumerate(rate_limit_events, 1):
    ts_dt = parse_ts(ts)
    day = ts_dt.strftime("%Y-%m-%d")
    win = window_start(ts_dt)
    if day != cur_day:
        cur_day = day
        day_running = {"input": 0, "cache": 0, "output": 0, "reasoning": 0}
    if win != cur_win:
        cur_win = win
        win_running = {"input": 0, "cache": 0, "output": 0, "reasoning": 0}
    call = call_totals.get((sid, turn, step))
    if call is None:
        for r in reversed(call_list):
            if r["sid"] == sid and r["ts"] <= ts:
                call = r
                break
    if call is None:
        call = {"input": 0, "cache": 0, "output": 0, "reasoning": 0}
    for k in ("input", "cache", "output", "reasoning"):
        day_running[k] += call[k]
        win_running[k] += call[k]
    win_total = sum(win_running.values())
    day_total = sum(day_running.values())
    short_sid = sid[:14] + ("…" if len(sid) > 14 else "")
    print(f"| {i} | {ts_dt.strftime('%Y-%m-%d %H:%M:%S')} | `{short_sid}` | {turn}/{step} | "
          f"{fmt(call['input'])} | {fmt(call['cache'])} | {fmt(call['output'])} | {fmt(call['reasoning'])} | "
          f"{fmt(win_total)} | {fmt(day_total)} |")

print()
print("## 5h 窗口累计 token 使用")
print()
print("按本地时间 0/5/10/15/20 切分（每个窗口 5 小时）。\"calls\"=该窗口内的 M3 call 次数。")
print()
print("| 日期 | 窗口 | input (uncached) | cache-read | output | reasoning | **total** | calls | rate_limits |")
print("|------|------|-----------------:|-----------:|-------:|----------:|----------:|------:|------------:|")

# Aggregate per (day, window_start)
agg = defaultdict(lambda: {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0, "rate_limits": 0})
for r in call_list:
    ts_dt = parse_ts(r["ts"])
    k = (ts_dt.strftime("%Y-%m-%d"), window_start(ts_dt).hour)
    rec = agg[k]
    for x in ("input", "cache", "output", "reasoning"):
        rec[x] += r[x]
    rec["count"] += 1
for ts, rid, sid, turn, step in rate_limit_events:
    ts_dt = parse_ts(ts)
    k = (ts_dt.strftime("%Y-%m-%d"), window_start(ts_dt).hour)
    agg[k]["rate_limits"] += 1

for (day, hour), r in sorted(agg.items()):
    total = sum((r["input"], r["cache"], r["output"], r["reasoning"]))
    print(f"| {day} | {hour:02d}:00+5h | {fmt(r['input'])} | {fmt(r['cache'])} | "
          f"{fmt(r['output'])} | {fmt(r['reasoning'])} | **{fmt(total)}** | {r['count']} | {r['rate_limits']} |")

# ---------------------------------------------------------------------------
# Aggregate: 5h-window totals where rate_limit fired
# ---------------------------------------------------------------------------
print()
print("## RATE_LIMIT 触发的窗口使用量（聚焦）")
print()
hits = [(k, r) for k, r in agg.items() if r["rate_limits"] > 0]
hits.sort()
print("| 窗口 | input | cache-read | output | reasoning | total | calls | rate_limits |")
print("|------|------:|-----------:|-------:|----------:|------:|------:|------------:|")
for (day, hour), r in hits:
    total = sum((r["input"], r["cache"], r["output"], r["reasoning"]))
    print(f"| {day} {hour:02d}:00+5h | {fmt(r['input'])} | {fmt(r['cache'])} | "
          f"{fmt(r['output'])} | {fmt(r['reasoning'])} | **{fmt(total)}** | {r['count']} | {r['rate_limits']} |")
