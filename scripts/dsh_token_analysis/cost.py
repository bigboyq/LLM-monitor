#!/usr/bin/env python3
"""Fixed daily window cost in CNY, with observed rate-limit events."""
from __future__ import annotations
import json
import os
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

PLAIN_DIR = Path(os.environ.get("DSH_PLAIN_DIR", "/tmp/dsh_plain"))
TZ = timezone(timedelta(hours=8))
RATE_INPUT, RATE_CACHE, RATE_OUTPUT = 2.10, 0.42, 8.40


def parse_ts(ms):
    return datetime.fromtimestamp(ms / 1000.0, tz=TZ)


def window_start(ts):
    base = ts.replace(hour=0, minute=0, second=0, microsecond=0)
    return base + timedelta(hours=max(w for w in (0, 5, 10, 15, 20) if w <= ts.hour))


def cost(i, c, o):
    return (i * RATE_INPUT + c * RATE_CACHE + o * RATE_OUTPUT) / 1_000_000.0


call_totals = {}
rl_events = []
seen = set()
for path in sorted(p for p in PLAIN_DIR.glob("*") if p.suffix in {".zstd", ".zst", ".jsonl"}):
    sid = path.stem
    with path.open() as fh:
        for line in fh:
            try:
                ev = json.loads(line) if line.strip() else None
            except json.JSONDecodeError:
                continue
            if not ev:
                continue
            t, data, ts = ev.get("type"), ev.get("data") or {}, ev.get("time")
            if t == "assistant/message":
                src = (data.get("message") or {}).get("source") or {}
                if src.get("provider") != "minimax-cn" or src.get("model") != "MiniMax-M3":
                    continue
                u = data.get("usage") or {}
                k = (sid, data.get("turn"), data.get("step"))
                r = call_totals.setdefault(k, {"i": 0, "c": 0, "o": 0, "ts": ts, "sid": sid})
                r["i"] += u.get("inputTokens") or 0
                r["c"] += u.get("cacheReadTokens") or 0
                r["o"] += u.get("outputTokens") or 0
                r["ts"] = min(r["ts"], ts)
            elif t == "llm/retry":
                rid = data.get("retryId")
                if rid in seen:
                    continue
                f = data.get("failure") or {}
                if f.get("code") == "RATE_LIMIT" and data.get("provider") == "minimax-cn":
                    seen.add(rid)
                    rl_events.append((ts, sid, data.get("turn"), data.get("step")))

calls = sorted(call_totals.values(), key=lambda r: r["ts"])
rl_events.sort()

# Aggregate per (day, window)
agg = defaultdict(lambda: {"i": 0, "c": 0, "o": 0, "n": 0, "rl": 0, "first": None, "last": None})
for r in calls:
    dt = parse_ts(r["ts"])
    k = (dt.strftime("%Y-%m-%d"), window_start(dt).hour)
    a = agg[k]
    a["i"] += r["i"]; a["c"] += r["c"]; a["o"] += r["o"]; a["n"] += 1
    a["first"] = min(a["first"] or r["ts"], r["ts"])
    a["last"] = max(a["last"] or r["ts"], r["ts"])
for ts, sid, tn, st in rl_events:
    dt = parse_ts(ts)
    k = (dt.strftime("%Y-%m-%d"), window_start(dt).hour)
    agg[k]["rl"] += 1


def fmt_m(n):
    return f"{n/1_000_000:.1f}M"


rows = sorted(agg.items())
hit_costs = [cost(r["i"], r["c"], r["o"]) for _, r in rows if r["rl"] > 0]
miss_costs = [cost(r["i"], r["c"], r["o"]) for _, r in rows if r["rl"] == 0]

print("## 固定时段窗口成本（按脚本固定 M3 价格估算 ¥）")
print()
print(f"  报价：input ¥{RATE_INPUT}/M  cache-read ¥{RATE_CACHE}/M  output ¥{RATE_OUTPUT}/M")
print(f"  （output 已含 reasoning；DSH M3 的 reasoning 字段实测恒为 0，参见 TokenAccountingCatalog.dsh）")
print()
print("```")
print(f"{'日期':<12}  {'窗口':<22}  {'cache-read':>11}  {'input':>9}  {'output':>7}  "
      f"{'total':>9}  {'成本':>8}  {'calls':>5}  {'RL':>3}  bar")
print("-" * 110)
max_cost = max((cost(r["i"], r["c"], r["o"]) for _, r in rows), default=0)
for (day, hour), r in rows:
    c = cost(r["i"], r["c"], r["o"])
    total = r["i"] + r["c"] + r["o"]
    bar_len = int(round(c / max_cost * 30)) if max_cost > 0 else 0
    bar = "█" * bar_len + "·" * (30 - bar_len)
    flag = "🔥" if r["rl"] > 0 else "  "
    first = parse_ts(r["first"]).strftime("%H:%M") if r["first"] is not None else "--:--"
    last = parse_ts(r["last"]).strftime("%H:%M") if r["last"] is not None else "--:--"
    print(f"{day:<12}  {hour:02d}:00+{min(5, 24 - hour)}h ({first}-{last})  "
          f"{fmt_m(r['c']):>11}  {fmt_m(r['i']):>9}  {fmt_m(r['o']):>7}  "
          f"{fmt_m(total):>9}  ¥{c:>6.2f}  {r['n']:>5}  {r['rl']:>3}  {flag} {bar}")
print("```")
print()
print(f"### 触发 rate_limit 的窗口（共 {len(hit_costs)} 个）")
if hit_costs:
    print(f"- 成本范围：¥{min(hit_costs):.2f} – ¥{max(hit_costs):.2f}，平均 **¥{sum(hit_costs)/len(hit_costs):.2f}**")
else:
    print("- 暂无窗口数据")
print()
print(f"### 未触发 rate_limit 的窗口（共 {len(miss_costs)} 个）")
if miss_costs:
    print(f"- 成本范围：¥{min(miss_costs):.2f} – ¥{max(miss_costs):.2f}，平均 **¥{sum(miss_costs)/len(miss_costs):.2f}**")
else:
    print("- 暂无窗口数据")
print()
print("### 总计")
total_cost = sum(cost(r["i"], r["c"], r["o"]) for _, r in rows)
total_tok = sum(r["i"] + r["c"] + r["o"] for _, r in rows)
print(f"- 全部窗口合计：**¥{total_cost:.2f}**  / {total_tok/1_000_000:.1f}M tokens  / {len(rows)} 个 固定时段窗口")
print()
print("注：以上是当前输入的观察统计，不能据此确定服务端限流阈值；价格为脚本固定估值。")
