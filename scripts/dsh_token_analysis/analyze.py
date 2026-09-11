#!/usr/bin/env python3
"""
Analyze DSH session.jsonl data for M3 (MiniMax-M3 / minimax-cn) usage:
  1) Token count at each RATE_LIMIT trigger
  2) Token usage per 5-hour quota window (0, 5, 10, 15, 20)

We use the cached Mavis scanner-equivalent token accounting (uncached input +
cache-read, output, reasoning).
"""
from __future__ import annotations
import json
import os
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

PLAIN_DIR = Path("/tmp/dsh_plain")
TZ = timezone(timedelta(hours=8))  # Asia/Shanghai — DSH sessions are CN users
WINDOW_HOURS = (0, 5, 10, 15, 20)


def parse_ts(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000.0, tz=TZ)


def format_num(n: int) -> str:
    return f"{n:,}"


def window_start(ts: datetime) -> datetime:
    """Snap a timestamp to one of 0/5/10/15/20 local-hour starts of the day."""
    h = ts.hour
    base = ts.replace(hour=0, minute=0, second=0, microsecond=0)
    # Largest window start <= ts.hour
    chosen = max(w for w in WINDOW_HOURS if w <= h)
    return base + timedelta(hours=chosen)


def window_label(start: datetime) -> str:
    return f"{start.strftime('%Y-%m-%d %H:00')}+5h"


# ---------------------------------------------------------------------------
# Pass 1: collect M3 (provider=minimax-cn, model=MiniMax-M3) usage samples
#          and RATE_LIMIT triggers (deduped by retryId -> first occurrence)
# ---------------------------------------------------------------------------
usage_samples = []  # list of (ts_ms, prompt_id, input, cache_read, output, reasoning)
rate_limit_events = []  # list of (ts_ms, retry_id, turn, step, code, message)
retry_seen = set()
file_stats = []

for path in sorted(PLAIN_DIR.glob("*.zstd")):
    size = path.stat().st_size
    with path.open("r", encoding="utf-8") as fh:
        line_count = 0
        for line in fh:
            line = line.strip()
            if not line:
                continue
            line_count += 1
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            # DSH session_id is in the line's first "session" event (most files
            # have one) or in the parent directory name. Fall back to filename.
            sid = (ev.get("data") or {}).get("sessionID") if ev.get("type") == "session" else None
            if not sid:
                # Use the directory name from the path as a stable per-file key
                sid = path.stem
            _current_sid = sid  # used by the assistant/message branch below
            t = ev.get("type")
            data = ev.get("data") or {}
            ts = ev.get("time")
            if t == "assistant/message" and isinstance(data, dict):
                message = data.get("message") or {}
                src = message.get("source") if isinstance(message, dict) else None
                if not isinstance(src, dict):
                    src = {}
                provider = src.get("provider") or data.get("provider")
                model = src.get("model") or data.get("model")
                usage = data.get("usage") or {}
                if provider == "minimax-cn" and model == "MiniMax-M3":
                    turn = data.get("turn")
                    step = data.get("step")
                    seq = ev.get("seq")
                    in_t = usage.get("inputTokens") or 0
                    cr_t = usage.get("cacheReadTokens") or 0
                    out_t = usage.get("outputTokens") or 0
                    reas_t = usage.get("reasoningTokens") or 0
                    sample_key = (sid, turn, step)
                    usage_samples.append(
                        (ts, sample_key, in_t, cr_t, out_t, reas_t, sid)
                    )
            elif t == "llm/retry" and isinstance(data, dict):
                rid = data.get("retryId")
                provider = data.get("provider")
                failure = data.get("failure") or {}
                code = failure.get("code")
                if code == "RATE_LIMIT" and provider == "minimax-cn" and rid not in retry_seen:
                    retry_seen.add(rid)
                    msg = failure.get("message", "")
                    rate_limit_events.append(
                        (ts, rid, _current_sid, data.get("turn"), data.get("step"), code, msg)
                    )
        file_stats.append((path.name, size, line_count))

print(f"Parsed {len(file_stats)} files, {sum(s[1] for s in file_stats):,} bytes plaintext")
print(f"  M3 usage samples: {len(usage_samples):,}")
print(f"  RATE_LIMIT triggers (deduped by retryId): {len(rate_limit_events):,}")
print()

# Sort usage by timestamp
usage_samples.sort(key=lambda r: r[0])
rate_limit_events.sort(key=lambda r: r[0])


# ---------------------------------------------------------------------------
# Section 1: token count at each RATE_LIMIT trigger
# ---------------------------------------------------------------------------
# A "call" is one unique (session, turn, step) tuple. DSH may emit multiple
# assistant/message events for the same (turn, step) when retries happen; we
# treat the first non-zero sample for that tuple as the canonical usage and
# sum the rest as additional rounds.

call_totals: dict[tuple, dict] = {}
for ts, sample_key, in_t, cr_t, out_t, reas_t, sid in usage_samples:
    rec = call_totals.setdefault(
        sample_key, {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "ts": ts, "sid": sid}
    )
    rec["input"] += in_t
    rec["cache"] += cr_t
    rec["output"] += out_t
    rec["reasoning"] += reas_t
    # Keep the earliest timestamp as the call start
    if ts < rec["ts"]:
        rec["ts"] = ts

call_list = sorted(call_totals.values(), key=lambda r: r["ts"])
call_timestamps = [r["ts"] for r in call_list]


def total_for_range(start_ms: int, end_ms: int | None) -> dict:
    """Sum usage tokens whose timestamp is in [start, end). end=None = +inf."""
    s = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0}
    for r in call_list:
        ts = r["ts"]
        if ts < start_ms:
            continue
        if end_ms is not None and ts >= end_ms:
            break
        s["input"] += r["input"]
        s["cache"] += r["cache"]
        s["output"] += r["output"]
        s["reasoning"] += r["reasoning"]
        s["count"] += 1
    return s


print("=" * 110)
print("Section 1 — M3 token usage at each RATE_LIMIT trigger")
print("=" * 110)
print(f"{'#':>3}  {'timestamp':<20}  {'turn/step':>9}  {'sid':<14}  "
      f"{'this call (in+cache+out+reas)':<35}  {'window total so far':<26}  {'day total so far':<26}")
print("-" * 110)

last_day_total: dict = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0}
last_window_total: dict = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0}
current_day = None
current_window_start = None

for i, (ts, rid, sid, turn, step, code, msg) in enumerate(rate_limit_events, 1):
    ts_dt = parse_ts(ts)
    day_str = ts_dt.strftime("%Y-%m-%d")
    win_start_dt = window_start(ts_dt)
    # Reset running totals if day changed
    if day_str != current_day:
        current_day = day_str
        last_day_total = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0}
    if win_start_dt != current_window_start:
        current_window_start = win_start_dt
        last_window_total = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0}

    # Find the matching call: same (sid, turn, step) — when missing (e.g. the
    # assistant/message wasn't logged because the request was throttled before
    # any tokens came back), fall back to the latest call with the same sid
    # whose ts is <= the rate-limit time.
    target_key = (sid, turn, step)
    call = call_totals.get(target_key)
    if call is None:
        # Latest call in the same session at-or-before the rate limit
        for r in reversed(call_list):
            if r["sid"] == sid and r["ts"] <= ts:
                call = r
                break
    if call is None:
        call = {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "ts": ts, "sid": sid}

    # Add this call's tokens to running totals
    for k in ("input", "cache", "output", "reasoning"):
        last_day_total[k] += call[k]
        last_window_total[k] += call[k]
    last_day_total["count"] += 1
    last_window_total["count"] += 1

    call_str = (
        f"in={format_num(call['input'])} "
        f"+cache={format_num(call['cache'])} "
        f"out={format_num(call['output'])} "
        f"reas={format_num(call['reasoning'])}"
    )
    day_str_total = (
        f"in={format_num(last_day_total['input'])} "
        f"+cache={format_num(last_day_total['cache'])} "
        f"out={format_num(last_day_total['output'])} "
        f"reas={format_num(last_day_total['reasoning'])} "
        f"(n={last_day_total['count']})"
    )
    win_str_total = (
        f"in={format_num(last_window_total['input'])} "
        f"+cache={format_num(last_window_total['cache'])} "
        f"out={format_num(last_window_total['output'])} "
        f"reas={format_num(last_window_total['reasoning'])} "
        f"(n={last_window_total['count']})"
    )

    short_sid = sid[:12] if sid else "?"
    print(f"{i:>3}  {ts_dt.strftime('%Y-%m-%d %H:%M:%S'):<20}  "
          f"{str(turn)+'/'+str(step):>9}  {short_sid:<14}  {call_str:<35}  "
          f"{win_str_total:<26}  {day_str_total:<26}")

print()
print("=" * 110)
print("Section 2 — M3 token usage per 5-hour quota window (0/5/10/15/20)")
print("=" * 110)

# Group by (day, window_start_hour) using call timestamps
window_records: dict[tuple, dict] = defaultdict(
    lambda: {"input": 0, "cache": 0, "output": 0, "reasoning": 0, "count": 0,
             "first_ts": None, "last_ts": None, "rate_limits": 0}
)
# Also bucket rate limits into windows
for ts, rid, sid, turn, step, code, msg in rate_limit_events:
    ts_dt = parse_ts(ts)
    key = (ts_dt.strftime("%Y-%m-%d"), window_start(ts_dt).hour)
    window_records[key]["rate_limits"] += 1

for r in call_list:
    ts_dt = parse_ts(r["ts"])
    key = (ts_dt.strftime("%Y-%m-%d"), window_start(ts_dt).hour)
    rec = window_records[key]
    for k in ("input", "cache", "output", "reasoning"):
        rec[k] += r[k]
    rec["count"] += 1
    if rec["first_ts"] is None or r["ts"] < rec["first_ts"]:
        rec["first_ts"] = r["ts"]
    if rec["last_ts"] is None or r["ts"] > rec["last_ts"]:
        rec["last_ts"] = r["ts"]

# Pretty print
keys = sorted(window_records.keys())
print(f"{'date':<12}  {'window':<22}  {'in':>11}  {'cache':>14}  {'out':>10}  "
      f"{'reas':>6}  {'total':>14}  {'calls':>6}  {'rate_limits':>12}")
print("-" * 110)
for (day, hour) in keys:
    r = window_records[(day, hour)]
    total = r["input"] + r["cache"] + r["output"] + r["reasoning"]
    first = parse_ts(r["first_ts"]).strftime("%H:%M:%S") if r["first_ts"] else "-"
    last = parse_ts(r["last_ts"]).strftime("%H:%M:%S") if r["last_ts"] else "-"
    print(f"{day:<12}  {hour:02d}:00+5h ({first}-{last:<8})  "
          f"{format_num(r['input']):>11}  {format_num(r['cache']):>14}  "
          f"{format_num(r['output']):>10}  {format_num(r['reasoning']):>6}  "
          f"{format_num(total):>14}  {r['count']:>6}  {r['rate_limits']:>12}")
