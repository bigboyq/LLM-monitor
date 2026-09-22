#!/usr/bin/env python3
"""
Antigravity Opus 5h window cost aggregation.

Source: ~/Library/Application Support/LLM-monitor/token-monitor/antigravity.json
  (LLM-monitor-maintained cache; reads per-session samples from Antigravity RPC)

Opus model: claude-opus-4-6-thinking (169 samples)
Sonnet model: claude-sonnet-4-6 (97 samples)

Pricing reference (Anthropic public list):
  Opus 4.6:   input $15 / 1M, cache_read $1.50 / 1M, output $75 / 1M
  Sonnet 4.6: input $3  / 1M, cache_read $0.30 / 1M, output $15 / 1M
  (These are list prices; Antigravity subscription may negotiate different rates.)
"""
import json
from pathlib import Path
from collections import defaultdict
from datetime import datetime, timedelta, timezone

INDEX = (
    Path.home()
    / "Library"
    / "Application Support"
    / "LLM-monitor"
    / "token-monitor"
    / "antigravity.json"
)
TZ = timezone(timedelta(hours=8))
WINDOWS = (0, 5, 10, 15, 20)

# Public list prices (USD per 1M tokens)
PRICES = {
    "claude-opus-4-6-thinking": {
        "input": 15.0, "cache": 1.50, "output": 75.0,
    },
    "claude-sonnet-4-6": {
        "input": 3.0, "cache": 0.30, "output": 15.0,
    },
    "Claude Sonnet 4.6 (Thinking)": {  # fallback
        "input": 3.0, "cache": 0.30, "output": 15.0,
    },
}
USD_CNY = 7.20  # approximate


def parse_ts(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(TZ)


def window_start(ts):
    base = ts.replace(hour=0, minute=0, second=0, microsecond=0)
    return base + timedelta(hours=max(w for w in WINDOWS if w <= ts.hour))


def cost_usd(model, in_t, cache_t, out_t, reason_t=0):
    p = PRICES.get(model, PRICES["claude-opus-4-6-thinking"])
    return (
        in_t * p["input"]
        + cache_t * p["cache"]
        + (out_t + reason_t) * p["output"]
    ) / 1_000_000.0


# Load
with open(INDEX) as fh:
    data = json.load(fh)

# Filter & group by (model, day, window)
per_window = defaultdict(lambda: {
    "i": 0, "c": 0, "o": 0, "r": 0, "n": 0,
    "first": None, "last": None,
})

opuses_total = {"i": 0, "c": 0, "o": 0, "r": 0, "n": 0}

for sid, samples in data["samplesBySession"].items():
    if not isinstance(samples, list):
        continue
    for s in samples:
        m = s.get("modelName", "")
        if "opus" not in m.lower() and "claude" not in m.lower():
            continue
        ts = parse_ts(s["completedAt"])
        win = window_start(ts)
        k = (m, ts.strftime("%Y-%m-%d"), win)
        in_t = s.get("inputTokens") or 0
        cache_t = s.get("cachedInputTokens") or 0
        out_t = s.get("outputTokens") or 0
        reason_t = s.get("reasoningOutputTokens") or 0
        rec = per_window[k]
        rec["i"] += in_t; rec["c"] += cache_t
        rec["o"] += out_t; rec["r"] += reason_t; rec["n"] += 1
        if rec["first"] is None or ts < rec["first"]:
            rec["first"] = ts
        if rec["last"] is None or ts > rec["last"]:
            rec["last"] = ts
        if "opus" in m.lower():
            opuses_total["i"] += in_t
            opuses_total["c"] += cache_t
            opuses_total["o"] += out_t
            opuses_total["r"] += reason_t
            opuses_total["n"] += 1

# Total Opus
opus_total_cost_usd = cost_usd(
    "claude-opus-4-6-thinking",
    opuses_total["i"], opuses_total["c"], opuses_total["o"], opuses_total["r"]
)
opus_total_cost_cny = opus_total_cost_usd * USD_CNY
print(f"## Antigravity Opus 总消耗（2026-07-29 ~ 09-14）")
print()
print(f"- rounds: **{opuses_total['n']}**")
print(f"- input (uncached): {opuses_total['i']:,}")
print(f"- cache-read: {opuses_total['c']:,}")
print(f"- output: {opuses_total['o']:,}")
print(f"- reasoning: {opuses_total['r']:,}")
total_tokens = opuses_total['i']+opuses_total['c']+opuses_total['o']+opuses_total['r']
print(f"- **total tokens**: {total_tokens:,} ({total_tokens/1e6:.1f}M)")
print(f"- cost @ list price: **${opus_total_cost_usd:,.2f}**  ≈ **¥{opus_total_cost_cny:,.2f}**")
print()

# 5h windows for Opus only
print("## Opus 每 5h 窗口累计（按 Opus 官方 list price 折算）")
print()
print(f"Opus list price: input ${PRICES['claude-opus-4-6-thinking']['input']}/M · cache_read ${PRICES['claude-opus-4-6-thinking']['cache']}/M · output ${PRICES['claude-opus-4-6-thinking']['output']}/M")
print()
print("```")
print(f"{'日期':<12}  {'窗口':<22}  {'cache-read':>11}  {'input':>9}  {'output':>9}  "
      f"{'total':>9}  {'USD':>7}  {'CNY':>8}  {'calls':>5}  bar")
print("-" * 120)

opus_windows = [(k, r) for k, r in per_window.items() if "opus" in k[0].lower()]
opus_windows.sort(key=lambda x: (x[0][1], x[0][2]))
max_cost = max(
    (cost_usd(k[0], r["i"], r["c"], r["o"], r["r"]) for k, r in opus_windows),
    default=1,
)
for (model, day, win), r in opus_windows:
    c_usd = cost_usd(model, r["i"], r["c"], r["o"], r["r"])
    c_cny = c_usd * USD_CNY
    total = r["i"] + r["c"] + r["o"] + r["r"]
    bar_len = int(round(c_usd / max_cost * 30))
    bar = "█" * bar_len + "·" * (30 - bar_len)
    first = r["first"].strftime("%m-%d %H:%M") if r["first"] else "-"
    last = r["last"].strftime("%m-%d %H:%M") if r["last"] else "-"
    print(f"{day:<12}  {win.strftime('%m-%d %H:%M')}+5h   "
          f"{r['c']/1e6:>9.2f}M  {r['i']/1e6:>7.2f}M  {(r['o']+r['r'])/1e6:>7.2f}M  "
          f"{total/1e6:>7.2f}M  ${c_usd:>5.2f}  ¥{c_cny:>6.2f}  {r['n']:>5}  {bar}")
print("```")

# Per-day total
print()
print("## Opus 每日累计")
print()
print("| 日期 | rounds | tokens | USD | CNY |")
print("|------|-------:|-------:|----:|----:|")
per_day = defaultdict(lambda: {"i":0,"c":0,"o":0,"r":0,"n":0})
for (model, day, win), r in opus_windows:
    per_day[day]["i"] += r["i"]; per_day[day]["c"] += r["c"]
    per_day[day]["o"] += r["o"]; per_day[day]["r"] += r["r"]; per_day[day]["n"] += r["n"]
for day in sorted(per_day):
    r = per_day[day]
    total = r["i"]+r["c"]+r["o"]+r["r"]
    usd = cost_usd("claude-opus-4-6-thinking", r["i"], r["c"], r["o"], r["r"])
    print(f"| {day} | {r['n']:>4} | {total/1e6:>6.2f}M | ${usd:>6.2f} | ¥{usd*USD_CNY:>6.2f} |")
