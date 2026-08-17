# minimax — Provider Spec

Provider id: `minimax_token_plan`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift`
- Local `.db` scanner: `Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift` + `MinimaxDBReader.swift`
- Local usage model: `Sources/LLM-monitor/Models/MinimaxLocalUsage.swift`
- Shared 7-day hover view: `Sources/LLM-monitor/Views/LocalUsageHoverViews.swift`

This provider covers two distinct data sources:

1. **Remote quota API** — `GET https://www.minimaxi.com/v1/token_plan/remains` — for
   the per-model "remaining percent" displayed in the main card.
2. **Local `.db` token usage** — v2-only: `~/.minimax/v2/sqlite/runtime-state.sqlite`
   (hot, mtime ~2 min) is the only supported and scanned source. The legacy
   The legacy database is not read. Per-day 7-day hover chart shows actual rounds /
   input / output / cache / cost.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.minimax_token_plan.apiKey` |
| Required key type | Token Plan key, usually `sk-cp-...` |
| Quota endpoint | `GET https://www.minimaxi.com/v1/token_plan/remains` |
| Quota timeout | 15 seconds |
| Quota unit | Remaining percent, not token count |
| Local token source | `~/.minimax/v2/sqlite/runtime-state.sqlite` (**v2-only**) |
| Local table | `local_runtime_token_usage` |
| Local scanner | `MinimaxLocalUsageScanner` — mtime diff + WAL-aware cache + single-source scan + 7-day padding |
| Local R/T | `COUNT(*)` rounds + `COUNT(DISTINCT turn_id)` turns, computed in SQL (no cross-source join) |
| Local reasoning | 字符比例分摊 `output_tokens` — 从 `session_messages.thinking_content` + `msg_content` 字符数按 `R/(R+C)` 比例分摊账单 output。守恒 `reason + realOutput == output`。 |
| SQLite read strategy | `SQLITE_OPEN_READWRITE` + `busy_timeout(300)` + `extended_result_codes(1)`, fallback to `/tmp/{uuid}.db` copy on CANTOPEN(14) / BUSY(5) |
| Models | M3 (`minimax/MiniMax-M3`, 99.97% of data) + occasional M2.7 |
| Reasoning tokens | **来源**: M3 / M2.7 当前按 `session_messages.thinking_content` 字符数比例分摊 `output_tokens` 出来(账单层 `reasoning_tokens` 永远是 0)。未来切到 thinking model 时,scanner 自动切到 `raw.reasoning` 字段直接用。 |
| Cross-provider hover | Shared `SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>` + `LocalUsageFooterView<Daily>` — Antigravity / Codex / Minimax / OpenCode all use the same SwiftUI view with field-level adapters |

## Accounting contract

MiniMax v2 的 raw `input` 与 `cacheRead` 是分开的；sample 为兼容历史结构会保存
`inputTokens = input + cacheRead`。账单 output 与 reasoning 在 scanner 中保持守恒：有
原生 reasoning 或可安全使用 thinking 字符比例时拆成 `Output` / `Reason`；没有可靠拆分
依据时 raw output 全放 `Output`、`Reason = 0`。`cacheWrite` 保留用于原始诊断，但不进入
统一 total、图表或金额估算。见 [`spec/accounting.md`](../accounting.md)。

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "minimax_token_plan": {
      "enabled": false,
      "apiKey": "sk-cp-REPLACE-WITH-YOUR-KEY"
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `apiKey` | Token Plan API key. Empty values and `sk-cp-REPLACE...` placeholders are treated as missing. |
| `refreshIntervalSeconds` | Optional independent refresh interval (overrides global default of 300s). |
| `displayName` | Optional card title override. |

`MinimaxTokenPlanFetcher.hasLocalAuth()` always returns `true`; `AppState` validates the config `apiKey`. After every successful quota refresh, `AppState` triggers `triggerMinimaxLocalUsageScan()` (mtime diff + per-source cache).

## API Request

```http
GET https://www.minimaxi.com/v1/token_plan/remains
Authorization: Bearer <Token Plan API Key>
Content-Type: application/json
```

The app sends the full API key in the request. Logs only include the key length (e.g. `key length=125`); the key and any prefix are never logged.

**Important**: this endpoint is server-side validated and only accepts `sk-cp-...` API Keys issued by minimax's open platform console. The local runtime's `~/.minimax/local-runtime.auth.json` JWT accessToken (used by the minimax IDE / CLI) is **not** accepted — verified by direct curl test returning `{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key in the 'Authorization' field of the request header"}}`.

## API Response Schema

Observed successful response:

```json
{
  "model_remains": [
    {
      "start_time": 1783234800000,
      "end_time":   1783252800000,
      "remains_time": 10629565,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "model_name": "general",
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "weekly_start_time": 1782662400000,
      "weekly_end_time":   1783267200000,
      "weekly_remains_time": 25029565,
      "current_interval_status": 1,
      "current_interval_remaining_percent": 54,
      "current_weekly_status": 1,
      "current_weekly_remaining_percent": 64
    },
    {
      "model_name": "video",
      "current_interval_remaining_percent": 100,
      "current_weekly_remaining_percent": 100
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
```

Important fields:

| Field | Meaning |
|---|---|
| `model_remains[]` | One entry per minimax quota family |
| `model_name` | Provider model/family id, for example `general`, `video`, `image`, `speech`, `music` |
| `current_interval_*` | 5-hour rolling window data |
| `current_weekly_*` | Weekly window data |
| `*_remaining_percent` | Core display value, `0...100` |
| `*_total_count` / `*_usage_count` | Preserved in `ModelQuota`; often `0` for percent-only plans |
| `points` / account credits | Not present in the current `token_plan/remains` response; no separate Minimax points balance is currently exposed by this fetcher |
| `*_status` | `1` = active; `2` = active but exhausted (0% remaining); `3` = not subscribed. The parser normalizes `2` to the internal active-window status so an exhausted window remains visible. |
| `end_time` / `weekly_end_time` | Millisecond timestamps used as reset times |
| `base_resp.status_code` | `0` means success |
| `base_resp.status_msg` | Server message for non-zero status |

Historical note: older guesses assumed OpenAI-style token counts and second timestamps. Current code uses percent fields and millisecond timestamps.

## API Parser Behavior

`MinimaxTokenPlanFetcher.parse(data:)` uses strict `JSONDecoder` models, with a
`JSONSerialization` preflight for the four quota count fields. Missing optional fields remain
compatible with older response variants, while present count fields must be non-negative JSON
integers and percentage fields must be finite values in `0...100`.

Mapping per `model_remains[]` item:

| Response field | Model field |
|---|---|
| `model_name` | `modelName` |
| `current_interval_total_count` | `intervalTotalCount` |
| `current_interval_usage_count` | `intervalUsageCount` |
| `current_interval_remaining_percent` | `intervalRemainingPercent` |
| `current_interval_status` | `intervalStatus` (`1/2` → `.present`, other raw codes → `.absent`) |
| `end_time` | `intervalResetsAt` |
| `current_weekly_total_count` | `weeklyTotalCount` |
| `current_weekly_usage_count` | `weeklyUsageCount` |
| `current_weekly_remaining_percent` | `weeklyRemainingPercent` |
| `current_weekly_status` | `weeklyStatus` (`1/2` → `.present`, other raw codes → `.absent`) |
| `weekly_end_time` | `weeklyResetsAt` |

`parseMsTimestamp(_:)` treats numbers and numeric strings as milliseconds since Unix epoch.

The current successful response contains only model/window quota data and `base_resp`;
there is no points, credits, or account-balance field to display. The strict response
model intentionally ignores unknown JSON keys for forward compatibility, so a future
Minimax points field must be added explicitly to a provider-neutral credit/balance model
before it can appear in the UI; it must not be folded into `ModelQuota` percentages.

The API can return placeholder model records for capabilities that are not available to the
current subscription. A model is displayed only when at least one quota window is present. Raw
status `2` means the window is active but exhausted, so it is normalized to `.present` and
rendered as `0%` with its reset time. Raw status `3` and other non-active codes normalize to
`.absent`; the record remains available for diagnostics in `QuotaInfo.models`, but is excluded
from `QuotaInfo.activeModels`, card rendering, dividers, and provider health. If a later refresh
changes either status to `1` or `2`, the model reappears automatically.

Successful parse returns:

```swift
QuotaInfo(
    models: models,
    resetCredits: nil,
    planLabel: nil,
    fetchedAt: Date()
)
```

## Local Token Usage Scanner

`MinimaxLocalUsageScanner` runs in the background after every successful quota
refresh (same cadence, typically 5 min). It scans the **v2 runtime** `.db` file
as its only supported source,
compares mtime + size against a cached index, and re-aggregates only the
dirty source via direct SQLite queries on the `local_runtime_token_usage` table.

### Why this scanner is simpler than Antigravity's

| Concern | Antigravity | minimax |
|---|---|---|
| Token data source | RPC `GetCascadeTrajectoryGeneratorMetadata` + protobuf decode | **Direct SQL on `local_runtime_token_usage` table** (no RPC, no protobuf) |
| R/T computation | Cross-source join: `.db` `step_type=14/15` idx → RPC events (order not stable) | **Pure SQL**: `COUNT(*)` + `COUNT(DISTINCT turn_id)` (zero cross-source join) |
| Number of `.db` files | One per Antigravity session (up to 22+) | **Just 1 active** (v2 runtime-state) |
| mtime cadence | Once a session is active (frequent) | v2: ~2 min (continuous) |
| R/T drift | Possible (RPC order drift → had to sort by timestamp) | **Impossible** (single SQL query) |

`AntigravityLocalUsageScanner` is ~700 lines because of RPC + protobuf + cross-source join logic. `MinimaxLocalUsageScanner` is ~470 lines because everything is local SQL.

### Storage layout

```
~/.minimax/
├── v2/
│   ├── sqlite/
│   │   ├── runtime-state.sqlite   ← v2 db (hot path, ~2 min mtime, **唯一主动扫描**)
│   │   ├── runtime-state.sqlite-wal
│   │   └── runtime-state.sqlite-shm
│   └── observability/logs/...
└── .token-monitor/            ← scanner's own cache
    └── index.json             ← top-level state (runtime mtime + per-day aggregate)
```

`index.json` schema (per-source version, NOT per-session like Antigravity — runtime is the only source):

```json
{
  "version": 12,
  "lastScannedAt": "2026-07-16T00:00:00Z",
  "sources": {
    "runtime": { "mtimeMs": 1784134792810.0, "sizeBytes": 167297024, "walSizeBytes": 5417832, "scannedAt": "...", "eventCount": 5058, "sessionCount": 10 }
    // Only the "runtime" entry is supported.
  },
  "dailyBySource": {
    "runtime": { "2026-07-11": { "dayStart": "...", "inputTokens": 924299, "totalTokens": 13123302, "turns": 5, "rounds": 404 }, ... }
  }
}
```

`dailyBySource` keeps the runtime source's per-day breakdown so the next scan can replace
only the changed source's contribution without rebuilding unrelated cache state.

### Optimizations

1. **mtime + size + WAL-size diff (v12)**: each scan `stat`s the v2 `.db` file **+ its `.db-wal`** via `URL.resourceValues` (fast, no DB open). The source is re-scanned when **any** of `mtimeMs` / `sizeBytes` / `walSizeBytes` changes. Older cache versions are reset so no legacy source data can survive the v2-only migration.

   ### Cache index 版本

   | 版本 | 内容 |
   |---|---|
   | v12 | 加 WAL-size diff,避免 WAL 长 checkpoint 期间漏数据 |
   | v13 | `MinimaxDBReader` 增加 model 回退链：row-level `model` → session-level `record_json.effectiveModel` → ledger 唯一模型；旧 samples 全量重建以应用新模型解析 |
   | v14 | 重新规范化样本 `inputTokens` 为 `uncached + cache_read`（cache-inclusive），与 Codex/DSH 的 sample 字段语义对齐；`tokenComponents` 统一假设 cache-inclusive 输入后，无需再为 Minimax 走特殊分支。旧 snapshots 全量重建 |

   当前 scanner 的 `currentVersion` 是 14。`MinimaxLocalUsageScanner.CacheIndex` 注释中标明每次 bump 的理由。

   **Why WAL dimension was added**: minimax v2 runtime uses SQLite WAL mode and may go **36+ hours without checkpointing** — new writes accumulate in `runtime-state.sqlite-wal` (observed up to 5.4MB before flush) while `.db`'s mtime/size stay frozen. The old two-dimension diff (`mtime || size`) could not detect this, leaving the UI without 7/25-7/26 data until the runtime finally flushed. The WAL size is a direct signal: `walSize` increasing = new data waiting. WAL truncation on checkpoint is captured by `.db`'s mtime jump (runtime `fsync` after WAL write), so the old dimension still catches that case.
2. **Per-source incremental aggregation**: `index.dailyBySource["runtime"]` stores the day-keyed breakdown. When runtime changes, only its daily map is replaced.
3. **In-flight dedup**: if `scan()` is called while a previous scan is still running, the new call is a no-op.
4. **Serial scan** (`maxConcurrentReads = 1`): single source scanned, no parallelism needed.
5. **Failure is non-fatal**: SQLite aggregate failures don't update `index.sources[source].mtimeMs` — the next scan naturally retries.
6. **Failure doesn't lose data**: even when a source's `aggregate` throws, the existing `index.dailyBySource[source]` is preserved (no overwrite), so historical data is never lost on transient failures.
7. **Pipeline serialization via `AsyncMutex` + `lastCommittedGeneration`**: 整个 `performScanPure` 包在 `try await pipelineMutex.withLock { ... }` 里, 旧 worker 跑完整个 pipeline 才让新 worker 开始. 配合 `lastCommittedGeneration` 守门, cancel+rescan 期间旧 worker 即使晚到 mutex, `startedGeneration < lastCommittedGeneration` 时也跳过 saveIndex, 杜绝 cache revert. **P1 invariant**: read + write-to-disk + update 全在 mutex 内 atomic (跨 @MainActor hop `await scanner.read.../write...` 持锁执行), 不能拆到 mutex 外. 详见 `spec/overview.md` "Scanner Concurrency" 段.
8. **Generation 守门防 UI flicker**: `runScan` 用 `startedGeneration` 跟 `latestGeneration` 比对, 不一致就丢弃 in-memory result, defer 状态清理也按 generation 守门. 防止 cancel+rescan 期间旧任务的 defer 把 UI 的"扫描中"状态清掉.
9. **取消不污染 lastError**: `performScanPure` 的 catch 用 `CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled)` 过滤, 取消错误直接 return, 不写 `self.lastError`.

### v2 table name

The supported v2 database uses one fixed table name:

| Source | Path | Table name | Role |
|---|---|---|---|
| `runtime` | `~/.minimax/v2/sqlite/runtime-state.sqlite` | `local_runtime_token_usage` | **唯一支持、唯一扫描** |

`MinimaxDBReader.aggregate()` always reads `local_runtime_token_usage`; the reader does not
accept a legacy table name or database source parameter.

**Bug history**: an earlier version hardcoded `FROM token_usage` in the SQL, which caused v2 source to fail with `SQLITE_ERROR (1)`. The reader now uses the v2 table directly, so this legacy table-name mismatch cannot recur through the scanner API.

## `.db` Schema Insights

minimax's runtime stores all LLM call token usage in the v2 SQLite file
(`~/.minimax/v2/sqlite/runtime-state.sqlite`). The schema is undocumented but
trivially readable (no protobuf). All fields are stored as plain SQLite types
(INTEGER / REAL / TEXT).

### `local_runtime_token_usage` table — full schema

```sql
CREATE TABLE local_runtime_token_usage (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id          TEXT NOT NULL,           -- mvs_xxx format (shared with minimax runtime)
  agent_name          TEXT NOT NULL,           -- "mavis" / "coder" / "verifier" / "general" / "unknown"
  framework_type      TEXT NOT NULL,           -- "opencode" (minimax local runtime)
  turn_id             TEXT,                   -- msg_xxx format; non-null for actual turns, null for sub-agent LLM calls
  model               TEXT,                   -- "minimax/MiniMax-M3" (99.97%) or "MiniMax-M2.7" (rare)
  ts                  INTEGER NOT NULL,       -- milliseconds since Unix epoch
  input_tokens        INTEGER NOT NULL DEFAULT 0,
  output_tokens       INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens    INTEGER NOT NULL DEFAULT 0,   -- always 0 for M3 / M2.7 (non-thinking models)
  cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
  cost_usd            REAL,                   -- real USD cost from minimax API (100% rows have a value)
  raw                 TEXT                   -- API raw response JSON
);
CREATE INDEX idx_local_runtime_token_usage_session_ts ON local_runtime_token_usage(session_id, ts);
CREATE INDEX idx_local_runtime_token_usage_agent_ts   ON local_runtime_token_usage(agent_name, ts);
CREATE INDEX idx_local_runtime_token_usage_ts         ON local_runtime_token_usage(ts);
```

### Field semantics

| Field | Meaning | Notes |
|---|---|---|
| `session_id` | minimax session id (UUID-like) | active v2 sessions |
| `agent_name` | which agent ran the LLM call | Main-agent and sub-agent labels are both retained for diagnostics. |
| `turn_id` | turn boundary marker (`msg_xxx` format) | 1 turn = 1 round in current M3 data (1:1 mapping) |
| `ts` | LLM call timestamp in ms | Sorted ascending in `idx_local_runtime_token_usage_ts` |
| `input_tokens` | uncached input | directly used as `MinimaxDailyUsage.input` |
| `output_tokens` | generated output (no reasoning) | directly used as `MinimaxDailyUsage.output` |
| `reasoning_tokens` | reasoning tokens | 当前 M3 / M2.7 账单里**永远 = 0**;`MinimaxLocalUsageScanner` 用 `session_messages.thinking_content` 字符数按比例分摊 `output_tokens` 出来,让 `reasoning` 字段在 UI 上有真实数字显示(实测全期合计 **83.3%** output 实际是 thinking) |
| `cache_read_tokens` | prompt cache hit | **cache dominance**: M3 sessions are 97% cache reads |
| `cache_write_tokens` | prompt cache write | small (50K typical) |
| `cost_usd` | real USD cost from API | 100% non-null; total $144.89 over 21 days for the active user |
| `raw` | original API response JSON | `{"total":24970,"input":0,"output":252,"reasoning":0,"cache":{"write":24718,"read":0}}` — `raw.reasoning` 字段也始终 = 0,未来 minimax 切到 thinking model 时这里会 > 0 |

### Cache dominance

The `cache_read_tokens` column is the dominant cost — for a typical M3 session:

| Day | input | output | reasoning | cache_read | cache_write |
|---|---|---|---|---|---|
| 7/11 | 8,843,144 | 664,272 | 0 | 289,652,202 | 50,158 |
| 7/12 | 26,733,604 | 944,000 | 0 | 401,000,000+ | ... |

Cache reads are 30-40× uncached input — M3's prompt cache is heavily hit. This is **the** reason a per-day breakdown matters: showing only "remaining quota" (the API) hides the fact that you're actually using far more tokens than the API's "remaining %" implies.

### Lazy .db write — sessions don't flush while open

The v2 `.db` is written by the `MiniMax` process (PID visible via `lsof`). While the runtime is alive:

- `~/.minimax/v2/sqlite/runtime-state.sqlite` — **scanner 唯一读取的源**；mtime only updates when the runtime flushes

This is the same "lazy write" pattern Antigravity has. The scanner handles the **read-side** via `busy_timeout(300)` and the copy-isolation strategy (below).

**Lazy write observed in production (2026-07-24 → 2026-07-26)**:

The v2 runtime went **36+ hours** without a single `.db` checkpoint:

| Time | `.db` mtime | `.db` size | `.db-wal` size | Rounds in `.db` |
|---|---|---|---|---|
| 2026-07-24 22:50 (last flush before gap) | 22:50:15 | 314613760 | (empty) | 9915 |
| 2026-07-26 11:08 (first flush after gap) | 11:08:20 | 360120320 | 5417832 (~5.4MB) | 12200 |
| 2026-07-26 11:14 (next flush) | 11:13:12 | 360730624 | (smaller, after checkpoint) | (growing) |

During the gap, new sessions / rounds went **only** to `.db-wal`; the WAL-dimension diff is what now catches this — without it, 7/25-7/26 data was invisible to the UI for the entire gap.

### SQL aggregation strategy

`MinimaxDBReader.aggregate(calendar:)` runs the token aggregation queries in a single connection:

```sql
-- per-day aggregation from the v2 runtime table
SELECT
  strftime('%Y-%m-%d', t.ts/1000, 'unixepoch', 'localtime') AS day_key,  -- local timezone day
  COUNT(*)                                    AS rounds,
  COUNT(DISTINCT t.turn_id)                   AS turns,
  TOTAL(MAX(CAST(COALESCE(t.input_tokens, 0) AS REAL), 0.0)) AS input,
  TOTAL(MAX(CAST(COALESCE(t.output_tokens, 0) AS REAL), 0.0)) AS output,
  TOTAL(MAX(
    MAX(CAST(COALESCE(t.reasoning_tokens, 0) AS REAL), 0.0),
    MAX(CAST(COALESCE(json_extract(
      CASE WHEN json_valid(t.raw) THEN t.raw ELSE '{}' END,
      '$.reasoning'
    ), 0) AS REAL), 0.0)
  )) AS reasoning,
  TOTAL(MAX(CAST(COALESCE(t.cache_read_tokens, 0) AS REAL), 0.0)) AS cache_read,
  TOTAL(MAX(CAST(COALESCE(t.cache_write_tokens, 0) AS REAL), 0.0)) AS cache_write
FROM local_runtime_token_usage t
WHERE t.ts IS NOT NULL
GROUP BY day_key
ORDER BY day_key;

-- global totals
SELECT
  COUNT(DISTINCT session_id) AS session_count,
  COUNT(*)                   AS event_count
FROM local_runtime_token_usage
WHERE ts IS NOT NULL;
```

**Timezone**: `strftime + 'localtime'` uses the process's local timezone (matches Swift's `Calendar.current`). This is critical for cross-day transitions — verified by test (cross-midnight timestamps are correctly bucketed to the local date).

**R/T**: computed in the same SQL query as the per-day tokens. **No cross-source join**, so there's no "RPC order drift" pitfall (which antigravity had to handle — see its spec's `sort by timestamp` rule).

**Character aggregation**: per-day `reason_chars` + `output_chars` 来自
`local_runtime_message_rows.data_json` 的 `thinking_content` + `msg_content` 字段,
由 runtime helper 按本地自然日聚合后供 scanner 字符分摊 `outputTokens` 使用。
这是独立的 per-day 查询，不 join token rows，因为 v2 的 `turn_id` 与 `msg_id`
不匹配；它是当前 v2 reasoning split 的输入。

字符聚合 SQL 失败时**不静默降级**：主 token 账本（input / cacheRead / output）照常
返回，Reason 按 0 处理，`MinimaxDBAggregate.charAggregationDegraded` 置位；scanner
把 `charSplitDegraded` 写进 source 的 fingerprint entry（optional 字段，旧 cache 解码
为 nil，无需 bump 版本），下一轮扫描即使 db 指纹未变也强制重扫重试，直到字符聚合
恢复成功并清除标记。warning 日志只含 source 路径与错误摘要，不落消息正文。

### Reasoning split (output → realOutput + reason)

`MinimaxLocalUsageScanner.applyReasoningSplit(perDay:perDayChars:)` 在 SQL 聚合之上把账单的 `outputTokens` 拆成 (realOutput, reason),per-day 决策:

```swift
if usage.reasoningTokens > 0 {
    // 未来路径:账单/聚合层面已经分了 reasoning,直接用
    realOutput = max(0, outputTokens - reasoningTokens)
    reason     = reasoningTokens
} else if let chars = perDayChars[day], chars.total > 0 {
    // 当前 M3 / M2.7 路径:按 thinking_content 字符比例分摊
    reason     = outputTokens * chars.reason / (chars.reason + chars.output)
    realOutput = outputTokens - reason
} else {
    // 没字符数据(v2 / 字符聚合失败)→ 保持原样
    realOutput = outputTokens
    reason     = 0
}
```

**守恒**: `reason + realOutput == outputTokens` 永远成立(整数四舍五入最多 ±1 token)。

**P2-2 边界校验**: 当 `usage.reasoningTokens > usage.outputTokens`(异常,可能账单字段解释变了,或 raw 路径重复算),scanner 截断 `reasoning = min(reasoning, output)`,保证 `reasoning + realOutput == output` 守恒。log warn 让 user 知道有异常。

**字符分摊的分母(关键)**: `chars.reason + chars.output` 包含三类 LLM 生成的 token:

| 类别 | 来源字段 | 算 reason? | 算 output? | 算分母? | 算 token? |
|---|---|---|---|---|---|
| `thinking_content` | LLM 思考文本 | ✓ | | ✓ | ✓ (账单计入 output) |
| `msg_content` | LLM 给用户的回复 | | ✓ | ✓ | ✓ (账单计入 output) |
| `tool_call_args` | LLM 调工具的 JSON 指令 | | ✓ | ✓ | ✓ (账单计入 output) |
| `tool_call_result_data` | 工具返回的结果 | | | **✗** | **✗ (不算当前 output,会作为下轮 input)** |

`tool_call_result_data` **不**算当前 output 字符分摊——它是工具返回的结果,出现在**下一轮** user message 的 input 里(账单算下一轮的 input tokens,不是当前轮的 output tokens)。漏算或错算都会让 reason 比例失真。

**修法历史(踩坑记录)**:

1. **v4 (84% 高估)**: 字符分摊只用了 `thinking_content` + `msg_content`,**漏算** `tool_call_args`(占 82% total chars)。thinking 比例被虚高到 84%。

2. **v5 (15% 低估)**: 用整个 `tool_calls` 数组的 LENGTH,`tool_call_result_data` 占 67% 字符被错算进 total 分母,稀释了 thinking 比例到 15%。

3. **v6 (37% 正确)**: 用 `json_each` 展开 `tool_calls` 数组,只 sum 每个元素的 `tool_call_args` 字符。**排除** `tool_call_result_data`(它算 input,不算 current output)。SQL:

   ```sql
   -- output_chars = msg_content + tool_call_args (排除 result_data)
   SUM(LENGTH(json_extract(data_json, '$.msg_content')))
   + SUM((
       SELECT COALESCE(SUM(LENGTH(json_extract(j.value, '$.tool_call_args'))), 0)
       FROM json_each(IFNULL(json_extract(data_json, '$.tool_calls'), '[]')) j
     ))
   ```

**精度**: 字符比例分摊在 `msg_content` 含代码块 / Markdown 缩进时偏差 ±5-15%(代码字符密度比自然语言低)。thinking_content 是纯自然语言(LLM 思考过程),比例稳定 ~4 chars/token。tool_call_args 是 JSON 指令,字符/token 比例跟自然语言接近。

**实测**(全期 21 天合计,v6 修后):
- 账单 output: 3,512,604 tokens
- 字符分摊 reason: 1,305,303 tokens (**37.2%**)
- realOutput: 2,207,301 tokens (62.8%)
- 守恒: ✓

**Future-proof**: 当 minimax 切到 thinking model 时,`raw.reasoning` 或 `reasoning_tokens` 列会出现非零值。**P2-1 + P1/P2-1 修复**后:reader SQL `r.reasoning = SUM(MAX(reasoning_tokens, json_extract(t.raw, '$.reasoning')))` — **per-row 取最大再 sum**(不是 `MAX(SUM, SUM)` 那种 group 后取 max,后者混合数据会算错,见 P1/P2-1 修复)。scanner 看到 `usage.reasoningTokens > 0` 走未来路径直接用账单,字符分摊路径变成 fallback。

**P1-2 算法本质 — 估算,不是精确 token 统计 (v8 修)**: 字符数 ≠ token 数(中文 / 英文 / 代码 / JSON 密度不同,4-1 chars/token 范围)。算法用字符比例分摊 output_tokens:

- 按天字符比例: 约 27.95% (per-day 字符聚合 / 全日字符总和)
- 按 turn 分别计算再加权: 约 29.53% (每个 turn 单独算 chars 比例再 sum)
- 单条消息比例分布 0-100% (有些 turn 100% thinking,有些 100% content)

per-day 聚合跟 per-turn 加权有 ~1.5% 差异(per-day 把所有 turn 平均了)。**结论**: 算法是 UI 展示用的**估算值**,不是精确账单。UI / 文档应明确标注 "估算"。

**P1-2 totalTokens 守恒 (v8 修)**: 修前 reader 算 `totalTokens = input + cacheRead + output + reasoning`,scanner 拆出 `realOutput = output - reason` 后字段总和 = input + realOutput + reason < totalTokens(差额 = reasoning 被算两次)。修后 scanner **重新算** `totalTokens = input + cacheRead + realOutput + reasoning = input + cacheRead + output`(跟账单总和一致),所有路径(未来 / 字符 / 无字符)统一公式,字段总和永远 == totalTokens。

**P1-1 v2 字符聚合风险 (v8 修)**: v2 path 字符聚合是 per-day 聚合(不 join `token_usage`),**v2 `local_runtime_message_rows.turn_id` 100% NULL**,无法 per-turn 精确配对 token 行。后果:

- v2 字符聚合跟 token 行只能按天对齐(`created_at_ms` vs `ts`),天粒度
- v2 早期 token 写入不完整时(7/11 实测 message 1280 vs token 404 = 3.17x),字符聚合会偏(分母过大,reason 比例被稀释)
- v2 近期(7/15+)实测对齐 1.0x,正常

**scanner `filterUnsafeV2CharCounts` (v8 修)**: 比较**真实 message 行数 vs token 行数**(reader 通过 `MinimaxCharCounts.messageCount` 暴露,v2 路径 SQL 顺带 `COUNT(*)`)。`messageCount / rounds > 2.0` 时**移除该 day 的字符聚合**(不是 warn-only),scanner `applyReasoningSplit` 看到无字符数据走"reason = 0"路径,**真正修复数据偏差**,不是只 log。

## SQLite reader — 跟 antigravity 一样的踩坑

`MinimaxDBReader` is a near-mirror of `AntigravityDBReader`. Same dual strategy: **fast path direct read + `/tmp` copy fallback on CANTOPEN/BUSY**.

### Why this is needed (same root cause as Antigravity)

macOS system `libsqlite3.dylib` and CLI `sqlite3` are both SQLite 3.51.0 source builds, but the dylib is stricter about `-shm` shared memory file format. When the runtime is actively writing:

- `sqlite3_open_v2` returns OK (opens `.db`)
- `sqlite3_prepare_v2` returns `SQLITE_CANTOPEN (14)` "unable to open database file" during the mmap `-shm` phase

**Empirically** (against the live `MiniMax` process holding the .db fd):
- 5/21 SUCCESS on direct read when runtime is mid-write
- 21/21 SUCCESS on `/tmp` copy read (copy is fully isolated from runtime's `-shm`)

### Open flags (defaults to READWRITE)

```swift
let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
let code = sqlite3_open_v2(self.path, &db, flags, nil)
```

**READWRITE (not READONLY)** because:
- The `/tmp` copy starts as a dirty WAL state
- SQLite needs to perform WAL recovery (write `-wal` pages back to `.db`) on first read
- READONLY on a dirty WAL → CANTOPEN(14) in the prepare step
- READWRITE allows the recovery to happen transparently

### busy_timeout + extended_result_codes

```swift
sqlite3_extended_result_codes(db, 1)  // before busy_timeout
sqlite3_busy_timeout(db, 300)        // 300ms wait on BUSY/CANTOPEN
```

`extended_result_codes(1)` lets us distinguish `SQLITE_CANTOPEN_*` subtypes for diagnostics. `busy_timeout(300)` handles brief runtime write-lock contention.

### Error → fallback decision tree

```
SQLiteConnectionError.openFailed(path, code, extCode, msg) caught in SQLiteTempCopy.read
├── code == 14 (SQLITE_CANTOPEN)  → fallback to /tmp copy
├── code == 5  (SQLITE_BUSY)      → fallback to /tmp copy
└── other code (e.g. 1 SQLITE_ERROR, 26 NOTADB) → propagate (copy won't help)
```

`SQLITE_ERROR(1)` is a SQL logic error — that's exactly what the v2 table name bug produced. The copy fallback doesn't trigger, and the error propagates so the scanner can log it and move on.

### Copy fallback (`SQLiteTempCopy.read` 公共 helper)

`SQLiteTempCopy` 是 antigravity / minimax scanner 共用的 SQLite 读策略：

```swift
try SQLiteTempCopy.read(dbPath: dbPath, logTag: "[minimax-scan]") { url in
    let reader = try MinimaxDBReader(path: url)
    return try reader.aggregate(calendar: calendar)
}
```

- 快路径：直接 read 原 .db，无 copy I/O
- 兜底：`SQLiteTempCopy.withTempCopy` 把 `.db + .db-wal + .db-shm` 三件套 copy 到 `/tmp` 副本
  - `defer` 在第一次文件创建之前就注册，覆盖"复制 .db 成功 → 复制 -wal 失败"这种半完成场景
  - READWRITE 让 SQLite 在副本上完成 WAL recovery（把 -wal pages 写回 .db）
  - `busy_timeout(300)` 应对偶尔的副本竞争
  - 副本不保留，read 完 `defer` 删 .db / .db-wal / .db-shm
- 错误码过滤：只对 file-level 错误（CANTOPEN 14 / BUSY 5）走 copy，其他错误直接 propagate

历史背景：`.db → /tmp 副本 + read` 的逻辑最初是 `MinimaxLocalUsageScanner.aggregateFromDB`
内联的私有方法；后来抽到 `Services/SQLiteTempCopy.read` 公共 helper（跟 antigravity
scanner 共享）。SQLiteTempCopy 的 `withTempCopy` defer 注册位置修复了一个老 bug：
旧代码先 copy .db 再注册 defer，".db 复制成功但 -wal 复制失败" 时副本残留在 /tmp。
新代码在第一次文件创建之前就注册 defer, 覆盖半完成场景。

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `minimax Token Plan` unless overridden |
| `iconSystemName` | `bubble.left.and.text.bubble.right.fill` |
| `accentColor` | `minimax` mapped to purple |

**Per-model window / multiplier**（`QuotaSummary.weeklyEquivalentMultiplier` + `primaryWindowLabel` 按 model 名分）：

| Model name | 主窗口 label | 周倍率 N | 等价比例 |
|---|---|---|---|
| `general` / `image` / `speech` / `music` / `tts` | `5h` | 10 | 1 段 = 5h，10 段 = 周 |
| `video` | `日` | 7 | 1 段 = 1 天，7 段 = 周（minimax 实际是日配额） |

### 7-day hover chart (shared with antigravity + codex)

`LocalUsageFooterView<MinimaxDailyUsage>` is dispatched from `ProviderCardView.localUsageFooter(for:)` with these arguments:

```swift
LocalUsageFooterView<MinimaxDailyUsage>(
    dailyTokenUsage: usage?.dailyTokenUsage ?? [],
    scannedAt: usage?.scannedAt,
    isScanning: status.isScanningLocalUsage,
    isReady: !days.isEmpty,
    emptyHint: "本机无 minimax v2 会话数据（runtime 不可读或尚未产生记录）"
)
```

`isReady` for minimax is `!days.isEmpty` (any day having data is enough — unlike codex which requires 7 full days).

The 7-day hover displays 4 stacked categories (input / cache / output / reason) per day, identical visually to antigravity's chart. See `LocalUsageHoverViews.swift` for the generic implementation.

### Why 4 categories when reasoning is always 0?

历史问题。Reasoning 不再总是 0——`MinimaxLocalUsageScanner.applyReasoningSplit` 已经从 `session_messages.thinking_content` 字符数按比例分摊出 reasoning(实测全期 37.2% output 实际是 thinking,v6 修后;v4 84% / v5 15% 都是修 bug 过程中的中间值,详见 "Reasoning split" 段踩坑记录)。Reason 栏现在有真实数字显示。

The hover chart is **shared** with antigravity + codex via `SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>`. 4th column 保持兼容(antigravity / codex 已经在用),minimax 之前 placeholder 现在有数据。

**未来工作**: 7-day chart 加第 5 个柱子 "Tool"(只算 tool_call_args),跟 reason / output 区分,让用户看到"工具调用"是 output 的主要部分(全期 30%+)。涉及 antigravity / codex 共享的 `LocalUsageHoverViews`,scope 大,留作后续。

## Cross-Provider Cache Semantics

`MinimaxDailyUsage` uses the same cache model as `AntigravityDailyUsage`:

| Provider | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` |
|---|---|---|---|
| Antigravity | uncached input | cache read | cache write (separate) |
| minimax | uncached input | cache read | cache write (separate) |
| Codex | **uncached + cached combined** (subset model) | `cachedInputTokens` (= read) | not stored (always 0) |

**Adapter** (`Models/LocalUsageDaily.swift`):

| Provider | `input` adapter | `cacheRead` adapter | `cacheWrite` adapter |
|---|---|---|---|
| `AntigravityDailyUsage` | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` |
| `MinimaxDailyUsage` | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` |
| `DailyTokenUsage` (codex) | `uncachedInputTokens` (= inputTokens - cachedInputTokens) | `cachedInputTokens` | `0` (fixed) |

The `LocalUsageDaily` protocol uses short field names (`input` / `cacheRead` / `cacheWrite` / `output` / `reasoning`) to **avoid collisions with existing stored property names** on the provider-specific daily types (e.g. `inputTokens`, `outputTokens`, `reasoningTokens` — all already exist on at least one type).

**Why minimax + antigravity use independent `input` / `cacheRead` / `cacheWrite`**: the API returns them as three separate quantities, and subtracting them would lose precision. `totalTokens` is `input + cacheRead + output + reasoning` — `cacheWrite` is intentionally excluded (it's bookkeeping, not consumption).

**Why codex uses subset model**: the ChatGPT `/backend-api/wham/usage` API returns `input_tokens` and `cached_input_tokens` as overlapping counts, not separate. Different API design choice.

## API Error Handling

Current fetch path:

| Situation | Current error |
|---|---|
| Empty API key passed to fetcher | `未配置 API Key` |
| URLSession error | `网络错误：<system message>` |
| Non-HTTP response | `响应格式无效` |
| HTTP non-2xx | `HTTP <status>: <body preview>` |
| Invalid JSON | `解析失败：invalid JSON: <message>` |
| Top-level JSON not object | `解析失败：top-level not an object` |
| `base_resp.status_code = 1004` | `HTTP 401: minimax API Key 无效或已过期（<msg>）` |
| Other non-zero `base_resp.status_code` | `解析失败：minimax 返回错误 [<code>]: <msg>` |
| Missing `model_remains` array | `解析失败：missing model_remains array, top-level keys=...` |
| Empty parsed models | `解析失败：model_remains 数组为空` |

The API's business-level auth failure `status_code=1004` is normalized to the same `HTTP 401`
semantic used by GLM; other non-zero business codes remain decoding errors.

**Token Plan auth verification**: confirmed that `~/.minimax/local-runtime.auth.json`'s `accessToken` (JWT) is **not** accepted by `token_plan/remains` — see "API Request" above. Only `sk-cp-...` API keys from minimax's open platform work.

## Local Scanner Error Handling

| Situation | Current behavior |
|---|---|
| `.db` file missing | `logInfo` + skip source (no exception) |
| `aggregateFromDB` throws file-level error (CANTOPEN/BUSY) | `aggregateFromDB` itself retries via `/tmp` copy |
| `aggregateFromDB` throws SQL error (e.g. wrong table name) | `logInfo` + skip; `index.dailyBySource[source]` preserved (no overwrite) |
| `aggregateFromDB` throws any other error | `logInfo` + skip; existing data preserved |
| All 2 sources fail | `lastResult` retains previous result; UI shows placeholder with `sessionCount == 0` |
| `index.json` version mismatch | Reset to `.empty`, full re-scan next time |
| `index.json` parse error | Reset to `.empty`, full re-scan next time |

## Rate Limits

The provider has no client-side backoff beyond the configured refresh interval. If minimax returns rate-limit or service errors, `AppState` moves the provider to `.failed` and shows the previous `QuotaInfo` from `state.lastSuccess` if available.

Default global refresh interval is 300 seconds. A provider-specific interval can be set:

```json
{
  "providers": {
    "minimax_token_plan": {
      "enabled": true,
      "apiKey": "sk-cp-...",
      "refreshIntervalSeconds": 300
    }
  }
}
```

## Known Limitations

- `cost_usd` is read from `token_usage` but **not yet exposed to UI** — the 7-day chart and the inline "今天 X in · Y out" footer don't include today's cost. Future work: add a "今天 $0.42" suffix to the footer.
- Per-model breakdown is not exposed. The hover chart shows **aggregate** per day, not "today's M3 vs M2.7 vs coder vs verifier". The `model` and `agent_name` columns are queryable from `.db`; UI is the only blocker.
- 7-day window is hardcoded. The data is in cache, so extending to 14/30 days is a single SQL change.
- `cost_usd` is only meaningful for direct API calls; sub-agent runs (`coder`, `verifier`, etc.) may have different cost semantics that aren't surfaced.
- v2's `local_runtime_sessions.record_json` is **not** read (would provide `parentSessionId` / `errorMessage` / `title` for richer UI). Schema is 100% available, scanner just doesn't query it yet.

## Legacy database policy

The legacy database is out of scope. It is not probed, opened, aggregated, or used
as a cache fallback. Minimax local usage requires the
v2 runtime database at `~/.minimax/v2/sqlite/runtime-state.sqlite`.

This intentionally avoids mixing two schemas and prevents stale legacy history from
being presented as current v2 usage. Users without the v2 database receive the empty
local-usage state until Minimax creates it.

## Test Coverage

Minimax tests are located in `Tests/LLMMonitorTests/MinimaxV2UsageTests.swift` and `Tests/LLMMonitorTests/ScannerAndLoggingTests.swift`:

- **Reader & v2 Scanner (`MinimaxV2UsageTests.swift`)**:
  - `testV2ReaderAggregatesRowsSessionsTurnsAndSamples`: aggregates v2 rows, sessions, turns, and samples.
  - `testV2ReaderClampsNegativeValuesAndUsesPerRowReasoningMaximum`: clamps invalid values and applies per-row reasoning maximum.
  - `testV2CharacterAggregationUsesToolArgsExcludesResultsAndPreservesOutput`: verifies v2 character aggregation filters and output conservation.
  - `testV2UnsafeCharacterRatioDropsOnlyMisalignedDay`: filters abnormal character-count days.
  - `testV2CacheMigrationResetsLegacySourceData`: resets incompatible cached source data for the v2-only policy.
  - `testScannerReadsOnlyRuntimeDatabaseEvenWhenSiblingLegacyDatabaseExists`: ignores a sibling legacy database.
  - `testPerRowReasoningExprTakesMaxOfNativeAndRaw`: verifies single-row dual-source `MAX` selection between native `reasoning_tokens` and `raw.reasoning`.
Test pattern: build a real SQLite database with the v2 tables, insert test rows with
`Date` / `DateComponents` (not hardcoded millisecond timestamps), open via
`MinimaxDBReader`, and assert on the aggregate. The reader tests cover the complete
reasoning split input contract, including non-negative totals, per-row native/raw
reasoning maximum, character aggregation, and output conservation.

## Open Questions

- Should HTTP 401/403/429 from the API receive provider-specific user messages?
- Should `current_interval_status` and `current_weekly_status` influence health beyond remaining percent?
- Should the 7-day hover expose `cost_usd` as a secondary number under the I/O bar (e.g. "今天 $0.42")?
- Should the hover show per-model breakdown (M3 vs M2.7) as a second bar group?
- Should v2's `local_runtime_sessions.record_json.title` / `errorMessage` be surfaced for "failing sessions" highlight?
- Should scanner cache `cost_usd` (currently discarded — only `input/output/cache/rounds/turns` are kept)?
- Should 7-day window become configurable (`recentDays: 7 | 14 | 30`)?
- Should the scanner use `local_runtime_ledger_watermarks.last_seq` for incremental v2 sync instead of mtime + full re-aggregate?
