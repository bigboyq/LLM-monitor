#!/usr/bin/env python3
"""
Analyze minimax code client's local M3 usage from
~/.minimax/v2/sqlite/runtime-state.sqlite, grouped by 5h quota window.

This is the Mavis-internal app's own usage (when the user runs M3 inside
the Mavis desktop client). 5h windows snap to local 0/5/10/15/20.
"""
import sqlite3
from collections import defaultdict
from datetime import datetime, timedelta, timezone

DB = "/Users/zhebinqiu/.minimax/v2/sqlite/runtime-state.sqlite"
TZ = timezone(timedelta(hours=8))
RATE_INPUT, RATE_CACHE, RATE_OUTPUT = 2.10, 0.42, 8.40

conn = sqlite3.connect(DB)
cur = conn.cursor()

# 1. Inspect providers / models
cur.execute("""
  SELECT
    substr(model, 1, instr(model, '/')-1) AS provider,
    substr(model, instr(model, '/')+1)    AS model,
    COUNT(*) AS rows,
    SUM(input_tokens+output_tokens+reasoning_tokens+cache_read_tokens+cache_write_tokens) AS total
  FROM local_runtime_token_usage
  GROUP BY provider, model
  ORDER BY total DESC
""")
print("## minimax code 客户端的本地账本 — 模型分布")
print()
print("| provider | model | rows | total tokens |")
print("|----------|-------|-----:|-------------:|")
for provider, model, rows, total in cur.fetchall():
    print(f"| `{provider or '?'}` | `{model or '?'}` | {rows:,} | {total/1e6:,.1f}M |")

# 2. Windowed aggregation
WINDOWS = (0, 5, 10, 15, 20)


def window_hour(h):
    return max(w for w in WINDOWS if w <= h)


def fmt_yuan(v):
    return f"¥{v:,.2f}"


def fmt_m(n):
    return f"{n/1_000_000:.1f}M"


# 3. Per-5h-window aggregation (M3 only)
cur.execute("""
  SELECT ts, input_tokens, output_tokens, reasoning_tokens,
         cache_read_tokens, cache_write_tokens
  FROM local_runtime_token_usage
  WHERE model = 'minimax/MiniMax-M3'
  ORDER BY ts
""")

agg = defaultdict(lambda: {
    "i": 0, "o": 0, "r": 0, "c": 0, "w": 0, "n": 0,
    "first": None, "last": None,
})

for ts_ms, i, o, r, c, w in cur.fetchall():
    dt = datetime.fromtimestamp(ts_ms / 1000.0, tz=TZ)
    base = dt.replace(hour=0, minute=0, second=0, microsecond=0)
    win_start = base + timedelta(hours=window_hour(dt.hour))
    k = (dt.strftime("%Y-%m-%d"), win_start)
    rec = agg[k]
    rec["i"] += i; rec["o"] += o; rec["r"] += r; rec["c"] += c; rec["w"] += w
    rec["n"] += 1
    if rec["first"] is None or ts_ms < rec["first"]:
        rec["first"] = ts_ms
    if rec["last"] is None or ts_ms > rec["last"]:
        rec["last"] = ts_ms


def cost(r):
    return (r["i"] * RATE_INPUT + r["c"] * RATE_CACHE + (r["o"] + r["r"]) * RATE_OUTPUT) / 1_000_000.0


# Pretty print all windows
print()
print("## minimax code 客户端 — M3 每 5h 窗口累计（按 M3 官方报价折算）")
print()
print("```")
print(f"{'日期':<12}  {'窗口':<22}  {'cache-read':>10}  {'input':>8}  {'output+reas':>10}  "
      f"{'total':>9}  {'成本':>8}  {'calls':>5}  bar")
print("-" * 110)
rows = []
for k, r in agg.items():
    rows.append((cost(r), r, k))
rows.sort(key=lambda x: x[2])
max_cost = max((cost(r) for _, r, _ in rows), default=1)
for c, r, (day, win) in rows:
    total = r["i"] + r["o"] + r["r"] + r["c"]
    bar_len = int(round(c / max_cost * 30))
    bar = "█" * bar_len + "·" * (30 - bar_len)
    first = datetime.fromtimestamp(r["first"] / 1000.0, tz=TZ).strftime("%m-%d %H:%M")
    last = datetime.fromtimestamp(r["last"] / 1000.0, tz=TZ).strftime("%m-%d %H:%M")
    print(f"{day:<12}  {win.strftime('%m-%d %H:%M')}+5h   "
          f"{fmt_m(r['c']):>10}  {fmt_m(r['i']):>8}  {fmt_m(r['o']+r['r']):>10}  "
          f"{fmt_m(total):>9}  {fmt_yuan(c):>8}  {r['n']:>5}  {bar}")
print("```")
print()

# 4. Summary statistics
all_costs = [cost(r) for r in agg.values()]
all_costs.sort()
total_cost = sum(all_costs)
n = len(all_costs)
print("## 汇总")
print()
print(f"- **5h 窗口数**：{n}")
print(f"- **总成本**：{fmt_yuan(total_cost)}")
print(f"- **总 token**（input + cache + output + reasoning）：{sum(r['i']+r['c']+r['o']+r['r'] for r in agg.values())/1e6:,.1f}M")
print(f"- **总 rounds**（LLM 调用数）：{sum(r['n'] for r in agg.values()):,}")
print()
print(f"- **窗口成本中位数**：{fmt_yuan(all_costs[n//2])}")
print(f"- **窗口成本 P75**：{fmt_yuan(all_costs[int(n*0.75)])}")
print(f"- **窗口成本 P90**：{fmt_yuan(all_costs[min(n-1, int(n*0.90))])}")
print(f"- **窗口成本 max**：{fmt_yuan(max(all_costs))}")
print()
print("## 时间分布")
print()
cur.execute("""
  SELECT
    strftime('%Y-%m', ts/1000, 'unixepoch', 'localtime') as ym,
    COUNT(*) as rounds,
    SUM(input_tokens+output_tokens+reasoning_tokens+cache_read_tokens+cache_write_tokens) as total,
    printf('%.2f', SUM(input_tokens)*2.1/1e6 + SUM(cache_read_tokens)*0.42/1e6
                  + (SUM(output_tokens)+SUM(reasoning_tokens))*8.4/1e6) as cost
  FROM local_runtime_token_usage
  WHERE model = 'minimax/MiniMax-M3'
  GROUP BY ym
  ORDER BY ym
""")
print("| 月份 | rounds | tokens | 成本 |")
print("|------|-------:|-------:|-----:|")
for ym, rounds, total, c in cur.fetchall():
    print(f"| {ym} | {rounds:,} | {total/1e6:,.1f}M | ¥{float(c):,.2f} |")
