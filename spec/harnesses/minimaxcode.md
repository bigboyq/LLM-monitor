# MiniMax Code — Harness Spec

Harness/client: MiniMax Code (`ClientID.minimaxCode`), contributing local usage to
`QuotaProviderID.minimax`.

Implementation:
- Local `.db` scanner: `Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift` + `MinimaxDBReader.swift` + `MinimaxLocalUsageAggregation.swift`
- Session-directory model resolver: `Sources/LLM-monitor/Services/MinimaxSessionModelResolver.swift`
- Local usage model: `Sources/LLM-monitor/Models/ProviderLocalUsage.swift` (`MinimaxLocalUsage` is a compatibility typealias)
- Shared SQLite read/fallback: `Sources/LLM-monitor/Services/Infra/SQLiteConnection.swift` + `SQLiteTempCopy.swift`
- Shared 7-day hover view: `Sources/LLM-monitor/Views/LocalUsageHoverViews.swift`

This document covers the MiniMax Code runtime's local ledger and the MiniMax-specific local usage
path. The destination provider card, remote quota API, card metadata, pricing, and server-side
limit observations are specified in [`providers/minimax.md`](../providers/minimax.md).


## Current Status

| Item | Current implementation |
|---|---|
| Local token source | `~/.minimax/v2/sqlite/runtime-state.sqlite` (**v2-only**) |
| Local table | `local_runtime_token_usage` |
| Local scanner | `MinimaxLocalUsageScanner` — mtime/size + WAL mtime/size diff + single-source scan + 7-day display window (8-day retention on disk) |
| Local R/T | `COUNT(*)` rounds + `COUNT(DISTINCT turn_id)` turns, computed in SQL (no cross-source join) |
| Local duration | Sample `durationSeconds` comes from `local_runtime_message_rows.data_json.$.usage.request_duration_ms` (FIFO pair + input/output verification), not a `created_at_ms − ts` difference; see §SQL aggregation strategy. |
| Local reasoning | Character-proportion split of `output_tokens` based on `thinking_content` and visible text/tool args. `reason + realOutput == output`; see §Reasoning split. |
| SQLite read strategy | Direct `SQLITE_OPEN_READONLY` (immutable URI only when no `-shm` and no non-empty `-wal`) + `busy_timeout(300)` + extended result codes; file-level errors fall back to a `/tmp/{uuid}.db` copy opened read-write for WAL recovery. |

## Accounting contract

MiniMax v2 的 raw `input` 与 `cacheRead` 是分开的；sample 为兼容历史结构会保存
`inputTokens = input + cacheRead`。账单 output 与 reasoning 在 scanner 中保持守恒：有
原生 reasoning 或可安全使用 thinking 字符比例时拆成 `Output` / `Reason`；没有可靠拆分
依据时 raw output 全放 `Output`、`Reason = 0`。`cacheWrite` 保留用于原始诊断，但不进入
统一 total、图表或金额估算。见 [`spec/accounting.md`](../accounting.md)。

## Local Token Usage Scanner

`MinimaxLocalUsageScanner` runs after a settled Provider batch. It scans the **v2 runtime** `.db` file
as its only supported source,
compares mtime + size against a cached index, and re-aggregates only the
dirty source via direct SQLite queries on the `local_runtime_token_usage` table.

### Why this scanner is simpler than Antigravity's

| Concern | Antigravity | minimax |
|---|---|---|
| Token data source | RPC `GetCascadeTrajectoryGeneratorMetadata` (protobuf decode only for the `.db` timestamp fallback) | **Direct SQL on `local_runtime_token_usage` table** (no RPC, no protobuf) |
| R/T computation | Pure RPC: rounds = timestamped events, turns inferred from `stepIndices` gaps (best-effort) | **Pure SQL**: `COUNT(*)` + `COUNT(DISTINCT turn_id)` (zero cross-source join) |
| Number of `.db` files | One per Antigravity session (up to 22+) | **Just 1 active** (v2 runtime-state) |
| mtime cadence | Once a session is active (frequent) | v2: ~2 min (continuous) |
| R/T drift | Possible (turn inference from step-index gaps can overcount) | **Impossible** (single SQL query) |

`AntigravityLocalUsageScanner` is ~1200 lines because of RPC + bounded-convergence bookkeeping. `MinimaxLocalUsageScanner` is ~720 lines because everything is local SQL.

### Storage layout

```
~/.minimax/
├── v2/
│   ├── sqlite/
│   │   ├── runtime-state.sqlite   ← v2 db (hot path, ~2 min mtime, **唯一主动扫描**)
│   │   ├── runtime-state.sqlite-wal
│   │   └── runtime-state.sqlite-shm
│   └── observability/logs/...
└── ...                        ← scanner 不在客户端目录写缓存

~/Library/Application Support/LLM-monitor/token-monitor/
└── minimax.json               ← top-level state (runtime mtime + per-day aggregate)
```

`index.json` schema (per-source version, NOT per-session like Antigravity — runtime is the only source):

```json
{
  "version": 16,
  "lastScannedAt": "2026-07-16T00:00:00Z",
  "sources": {
    "runtime": {
      "mtimeMs": 1784134792810.0, "sizeBytes": 167297024,
      "walMtimeMs": 1784134792900.0, "walSizeBytes": 5417832,
      "scannedAt": "...", "eventCount": 5058, "sessionCount": 10,
      "charSplitDegraded": null
    }
    // Only the "runtime" entry is supported.
  },
  "dailyBySource": {
    "runtime": { "2026-07-11": { "dayStart": "...", "inputTokens": 924299, "totalTokens": 13123302, "turns": 5, "rounds": 404 }, ... }
  },
  "samplesBySource": { "runtime": [ ... ] },
  "calendarSignature": "<tz/locale/calendar fingerprint>"
}
```

`samplesBySource` holds the per-round samples (recent samples 展示用，键参与指纹) under
the same per-source partition, filtered to the 8-day retention window on read. It is
optional in the decoder so older snapshots still load, but a source with no
`samplesBySource` entry is treated as dirty and re-scanned.

`calendarSignature` records the calendar/tz context the day buckets were built under.
A mismatch forces a re-aggregation (day buckets computed under a different timezone are
not valid), and a cold start whose signature does not match shows no stale usage until
the first scan rebuilds it.

`dailyBySource` keeps the runtime source's per-day breakdown so the next scan can replace
only the changed source's contribution without rebuilding unrelated cache state.

### Optimizations

1. **mtime + size + WAL mtime/size diff (v12+, 四维)**: each scan `stat`s the v2 `.db` file **+ its `.db-wal`** via `FileManagerBox.attributesOfItem` (fast, no DB open). The source is re-scanned when **any** of `mtimeMs` / `sizeBytes` / `walMtimeMs` / `walSizeBytes` changes — WAL mtime is a separate dimension from WAL size so a same-size WAL whose content was replaced still triggers a scan. Older cache versions are reset so no legacy source data can survive the v2-only migration.

   ### Cache index 版本

   | 版本 | 内容 |
   |---|---|
   | v12 | 加 WAL mtime+size diff,避免 WAL 长 checkpoint 期间漏数据 |
   | v13 | `MinimaxDBReader` 增加 model 回退链：row-level `model` → session-level `record_json.effectiveModel` → ledger 唯一模型（仅当 ledger 只有一个 distinct model；多模型时不猜）；旧 samples 全量重建以应用新模型解析 |
   | v14 | 重新规范化样本 `inputTokens` 为 `uncached + cache_read`（cache-inclusive），与 Codex/DSH 的 sample 字段语义对齐；`tokenComponents` 统一假设 cache-inclusive 输入后，无需再为 Minimax 走特殊分支。旧 snapshots 全量重建 |
   | v15 | 模型名改从 session 目录的 `llm-call.json` 取**真实模型**（见 §Model resolution for samples），账本/投影里的 `minimax/MiniMax-M3` 泛化标签不再当模型名用。旧 samples 带的是错标模型名，必须全量重建才能改对 |
   | v16 | 样本 `durationSeconds` 改由 `local_runtime_message_rows.$.usage.request_duration_ms` FIFO 回填（单次 LLM 请求完整耗时，供窗口 tok/s 分母，见 §SQL aggregation strategy 的 "request_duration_ms 回填"）。旧 samples 没有时长值，必须全量重建才能补上 |

   当前 scanner 的 `currentVersion` 是 16（`CacheIndex.empty.version` 与
   `loadIndex(currentVersion: 16)` 两处一致）。v16 的 bump 理由见
   `CacheIndex.empty` 的行内注释（`MinimaxLocalUsageScanner.swift`），
   v12 / v13 / v14 / v15 见上表。

   **Why WAL dimension was added**: minimax v2 runtime uses SQLite WAL mode and may go **36+ hours without checkpointing** — new writes accumulate in `runtime-state.sqlite-wal` (observed up to 5.4MB before flush) while `.db`'s mtime/size stay frozen. The old two-dimension diff (`mtime || size`) could not detect this, leaving the UI without 7/25-7/26 data until the runtime finally flushed. The WAL size is a direct signal: `walSize` increasing = new data waiting. WAL truncation on checkpoint is captured by `.db`'s mtime jump (runtime `fsync` after WAL write), so the old dimension still catches that case. WAL **mtime** was added alongside size because a checkpoint can rewrite a WAL back to a similar size, and size alone would miss a content-only update.
2. **Per-source incremental aggregation**: `index.dailyBySource["runtime"]` stores the day-keyed breakdown. When runtime changes, only its daily map is replaced.
3. **In-flight dedup**: `LocalUsageScannerBase.scan(mode:)` never runs two scans at once — a request arriving while a previous scan is in flight is merged into the pending slot (stronger mode wins), and the in-flight scan's completion immediately runs one more round with the merged mode.
4. **Serial scan**: the dirty source loop in `performScanPureImpl` is a plain `for` over `dirty` (single source, no parallelism).
5. **Failure is non-fatal**: SQLite aggregate failures don't update `index.sources[source]` fingerprint — the next scan naturally retries. A `stat` failure (permission, transient I/O) is treated separately from a *confirmed* missing file: the source is counted as degraded and its last-good `sources` / `dailyBySource` are preserved, so a permission blip never wipes the card. Only an explicit ENOENT clears the cache entry.
6. **Failure doesn't lose data**: even when a source's `aggregate` throws, the existing `index.dailyBySource[source]` is preserved (no overwrite), so historical data is never lost on transient failures.
7. **Pipeline serialization via `AsyncMutex` + `lastCommittedGeneration`**: 整个 `performScanPure` 包在 `try await pipelineMutex.withLock { ... }` 里, 旧 worker 跑完整个 pipeline 才让新 worker 开始. 配合 `lastCommittedGeneration` 守门, cancel+rescan 期间旧 worker 即使晚到 mutex, `startedGeneration < lastCommittedGeneration` 时也跳过 saveIndex, 杜绝 cache revert. **P1 invariant**: read + write-to-disk + update 全在 mutex 内 atomic (跨 @MainActor hop `await scanner.read.../write...` 持锁执行), 不能拆到 mutex 外. 详见 `spec/local-usage-reconcile.md` "Scanner Concurrency (本地用量 scanner 的并发模型)" 段.
8. **Generation 守门防 UI flicker**: `runScan` 用 `startedGeneration` 跟 `latestGeneration` 比对, 不一致就丢弃 in-memory result, defer 状态清理也按 generation 守门. 防止 cancel+rescan 期间旧任务的 defer 把 UI 的"扫描中"状态清掉.
9. **取消不污染 lastError**: `performScanPure` 的 catch 用 `CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled)` 过滤, 取消错误直接 return, 不写 `self.lastError`.
10. **启动 `.full` 是 cache-assisted**: 只有 `.hardFull`（用户显式强制重扫 / 系统时钟平移）才 `bypassesProviderCache`，允许绕过指纹决策重建账本；冷启动 `.full` 仍然走 mtime/WAL diff.
11. **日桶 8 天裁剪**: 落盘前 `pruneStaleDailyBuckets` 裁掉严格早于 `LocalUsageRetentionWindow`（8 天）的 `dayStart` 桶，全部被裁空的 source 一并移除。`eventCount` / `sessionCount` 独立存在 `sources` 条目里，不受裁剪影响。口径由 `ScannerRetentionContractTests` 锁定。

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
  turn_id             TEXT,                   -- v2: UUID format (NOT msg_xxx); null for sub-agent LLM calls
  model               TEXT,                   -- "minimax/MiniMax-M3" (99.97%); often NULL after the 2026-08-15 runtime schema migration
  ts                  INTEGER NOT NULL,       -- milliseconds since Unix epoch
  input_tokens        INTEGER NOT NULL DEFAULT 0,
  output_tokens       INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens    INTEGER NOT NULL DEFAULT 0,   -- always 0 for M3 / M2.7 (non-thinking models)
  cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
  cost_usd            REAL,                   -- real USD cost from minimax API (100% rows have a value); never read by the scanner
  raw                 TEXT                   -- API raw response JSON
);
CREATE INDEX idx_local_runtime_token_usage_session_ts ON local_runtime_token_usage(session_id, ts);
CREATE INDEX idx_local_runtime_token_usage_agent_ts   ON local_runtime_token_usage(agent_name, ts);
CREATE INDEX idx_local_runtime_token_usage_ts         ON local_runtime_token_usage(ts);
```

### Model resolution for samples (`model` is often NULL)

The MiniMax runtime dropped the `model` column value for many token-ledger rows in its
2026-08-15 schema migration, while the session projection kept the model. `MinimaxDBReader`
therefore resolves each sample's `modelName` in two stages.

**Stage 1 — the real model, from the session directory.** The ledger column and the session
projection both store the **generic label** `minimax/MiniMax-M3`, not the model that actually
ran. The real model lives only in the session directory's `llm-call.json` (`model` +
`provider`), at `~/.minimax/v2/sessions/<history_relative_dir>/llm-call.json`.
`MinimaxSessionModelResolver` reads it (one read per session, cached; the file is
~150 KB because it embeds the system prompt, so it must **not** be re-parsed per row).

When the resolver returns a model, that model **wins over everything below**. Without this
stage every recent usage row is mislabeled: measured on the real ledger, **all 2754 sample
rows inside the 8-day window** fell through to the generic label, i.e. every M3.1 Flash call
was attributed to M3 — wrong model name *and* wrong price (M3 ¥2.1/¥0.42/¥8.4 vs M3.1 Flash
¥1/¥0.1/¥4, which over-estimated the same 8-day usage by **¥253.76 vs ¥69.70**).

**Stage 2 — the fallback chain**, all in one SQL `COALESCE`, used only when the session
directory yields nothing (directory cleaned up, file missing, unreadable JSON):

1. row-level `NULLIF(TRIM(t.model), '')` — the ledger's own value when present
2. session-level `local_runtime_sessions.record_json.effectiveModel` (via a `LEFT JOIN`,
   only when that table has both `session_id` and `record_json`) — survives the migration
3. the ledger's single distinct model — used **only** when `SELECT DISTINCT TRIM(model)`
   returns exactly one row, so a genuinely multi-model ledger never gets collapsed into
   one wrong name (it falls through to `nil` and shows as unpriced)

Both `model` and the session projection are probed with `PRAGMA table_info` first: older
schemas or test fixtures without the column degrade to `NULL` for that step rather than
failing the whole source. `history_relative_dir` is probed the same way — a fixture without
that column simply loses stage 1 and keeps the old behaviour. Sample `promptID` is
`"\(session_id):\(turn_id ?? "event-\(ts)")"`.

### Field semantics

| Field | Meaning | Notes |
|---|---|---|
| `session_id` | minimax session id (UUID-like) | active v2 sessions |
| `agent_name` | which agent ran the LLM call | Main-agent and sub-agent labels are both retained for diagnostics. |
| `turn_id` | turn boundary marker | **v2 是 UUID 格式**（不是 `msg_xxx`）——这正是它无法与 `local_runtime_message_rows.msg_id` per-turn join 的原因，字符聚合因此只能按天对齐。`NULL` 与空串都会被 `COUNT(DISTINCT)` 跳过；实测 v2 数据里 `turn_id` 全部非 NULL 非空 |
| `ts` | LLM call timestamp in ms | Sorted ascending in `idx_local_runtime_token_usage_ts`; `NULL` rows are excluded from every aggregate |
| `input_tokens` | uncached input | 直接进 `MinimaxDailyUsage.inputTokens`（不与 cacheRead 合并） |
| `output_tokens` | generated output (no reasoning) | 账单 output；scanner 在其上做 reasoning 分摊 |
| `reasoning_tokens` | reasoning tokens | 当前 M3 / M2.7 账单里**永远 = 0**;`applyReasoningSplit` 用 `local_runtime_message_rows` 的 `thinking_content` 字符数按比例分摊 `output_tokens` 出来,让 `reasoning` 字段在 UI 上有真实数字显示(实测全期合计 **37.2%** output 实际是 thinking，v6 修后) |
| `cache_read_tokens` | prompt cache hit | **cache dominance**: M3 sessions are 97% cache reads |
| `cache_write_tokens` | prompt cache write | small (50K typical) |
| `cost_usd` | real USD cost from API | 100% non-null; total $144.89 over 21 days for the active user. **Reader 不读这一列**（金额估算走 `ModelPricing.json`） |
| `raw` | original API response JSON | `{"total":24970,"input":0,"output":252,"reasoning":0,"cache":{"write":24718,"read":0}}` — `raw.reasoning` 字段也始终 = 0,未来 minimax 切到 thinking model 时这里会 > 0。Reader 用 `CASE WHEN json_valid(raw) THEN raw ELSE '{}' END` 包裹，`raw` 非法 JSON 不会让聚合失败 |

### Cache dominance

The `cache_read_tokens` column is the dominant cost — for a typical M3 session:

| Day | input | output | reasoning | cache_read | cache_write |
|---|---|---|---|---|---|
| 7/11 | 8,843,144 | 664,272 | 0 | 289,652,202 | 50,158 |
| 7/12 | 26,733,604 | 944,000 | 0 | 401,000,000+ | ... |

Cache reads are 30-40× uncached input — M3's prompt cache is heavily hit. This is **the** reason a per-day breakdown matters: showing only "remaining quota" (the API) hides the fact that you're actually using far more tokens than the API's "remaining %" implies.

**5h-window cache_read distribution** (August 2026, M3 only, post-Token-Plan): a steady-state 5h window accumulates **~50M cache_read tokens** (median 49.2M, max 65.6M) which is ~97% of the window's 51M total tokens and ~91% of the window's ¥24 cost. This 5h cache_read volume is the **primary signal** for "are you approaching the 5h rate-limit waterline" — see the provider spec rate-limits section for the cost-side analysis.

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
WHERE t.ts IS NOT NULL AND (? IS NULL OR t.ts >= ?)   -- cutoff = now - LocalUsageRetentionWindow.seconds
GROUP BY day_key
ORDER BY day_key;

-- global totals (全历史口径，不受 cutoff 影响)
SELECT
  COUNT(DISTINCT session_id) AS session_count,
  COUNT(*)                   AS event_count
FROM local_runtime_token_usage
WHERE ts IS NOT NULL;
```

**Cutoff**: per-day 聚合与字符聚合都带 `LocalUsageRetentionWindow`（8 天）时间下界，
UI 只消费最近 7 天，dirty 重扫时无下界的全表 `GROUP BY` 是纯浪费。session / event
总数仍是全历史口径，不受 cutoff 影响。

**Timezone**: `strftime + 'localtime'` uses the process's local timezone (matches Swift's `Calendar.current`). This is critical for cross-day transitions — verified by test (cross-midnight timestamps are correctly bucketed to the local date).

**R/T**: computed in the same SQL query as the per-day tokens. **No cross-source join**, so there's no "RPC order drift" pitfall (which antigravity's removed SQLite reader once had to handle — see its spec's historical R/T pairing section).

**Character aggregation**: per-day `reason_chars` + `output_chars` 来自
`local_runtime_message_rows.data_json`（生产表是 `local_runtime_message_rows`，
`session_messages` 只是历史测试夹具名）的 `thinking_content` + `msg_content` +
`tool_calls[].tool_call_args` 字段，按 `role = 'assistant'` 过滤后由独立 per-day 查询
聚合，供 scanner 字符分摊 `outputTokens` 使用。
这是独立的 per-day 查询，不 join token rows，因为 v2 的 `turn_id` 与 `msg_id`
不匹配；它是当前 v2 reasoning split 的输入。查询同一次 `COUNT(*)` 出
`message_count`，供 `filterUnsafeV2CharCounts` 的对齐检查使用。
表不存在（更老 schema）时直接返回空字典，**不算 degraded**——没有可分摊的字符数据
与"聚合失败"是两种不同的降级，前者是正常路径。

字符聚合 SQL 失败时**不静默降级**：主 token 账本（input / cacheRead / output）照常
返回，Reason 按 0 处理，`MinimaxDBAggregate.charAggregationDegraded` 置位；scanner
把 `charSplitDegraded` 写进 source 的 fingerprint entry（optional 字段，旧 cache 解码
为 nil，无需 bump 版本），下一轮扫描即使 db 指纹未变也强制重扫重试，直到字符聚合
恢复成功并清除标记。warning 日志只含 source 路径与错误摘要，不落消息正文。

**request_duration_ms 回填（样本 durationSeconds，cache v16）**: 样本的
`LocalTokenUsageSample.durationSeconds`（单次 LLM 请求完整耗时，窗口 tok/s 分母
`LocalUsageSummaryBuilder.windowTokenRate` 只认 0.2–3600 秒）来自同一张
`local_runtime_message_rows`（role='assistant'）的
`data_json.$.usage.request_duration_ms`（毫秒；含 TTFT + decode，严格不含工具执行）。
reader 在 `runtimeAssistantDurationQueues` 里把窗口内 assistant 行按
`(session_id, turn_id)` 分组成 FIFO 队列（`ORDER BY id` 行写入序，同 turn 内与账本行
`ts` 序实测一致），再在样本 map 闭包里经
`MinimaxDBReader.verifiedDuration(from:ledgerInputTokens:ledgerOutputTokens:)` 逐样本
弹出：条目的 `$.usage.input_tokens` / `$.usage.output_tokens` 与账本行原始值
**双核对通过**才采纳——实测两者与账本对应列逐行相等（全历史 11838/11838 对；
`$.usage.input_tokens` 是未缓存口径，不是 cache-inclusive），对不上的条目按序丢弃
（空行 / 窗口边缘不对齐的行不阻塞后续配对），队列耗尽仍无匹配则 `durationSeconds`
保持 nil——宁可缺时长，也不把时长安到错误的调用上。`request_duration_ms` 缺失 /
0 / 负值同样写 nil。`turn_id` 为 NULL / 空串的 message 行（SQL 侧过滤）与 `turnID`
为 nil 的样本（promptID 落 `event-<ts>`，子代理旧数据）都不参与配对。

**为何不能用 created_at 差分**：`created_at_ms − token 行 ts` 对
`finish_reason="toolUse"`（占 95.8%）的 assistant 行算出的是**工具执行完成时刻**与
请求发起时刻的差——这类行要把 `tool_call_result_data` 内嵌进同一条 assistant 行才
落盘，差分会把工具耗时（P90 +30.1s）算进"模型耗时"。`request_duration_ms` 是
runtime 原生记录的单次请求耗时，无此污染。实测保留窗口 3054/3054（100%）精确配对。

**独立守门**：时长查询与字符聚合同表同过滤风格，但 do/catch 各自独立——查询失败
（坏表 / 缺列 / 锁）只让全部样本 `durationSeconds` 保持 nil，主 token 账本、字符聚合
与 `charAggregationDegraded` 均不受影响，也**不**置 degraded 强制重扫：时长是纯增强
数据，缺了不改任何 token 数字，只影响 tok/s 分母覆盖面，活跃 runtime 的指纹 diff
（~2 min）很快自然重试。`applyReasoningSplit(samples:)` 重建样本时原样保留
`durationSeconds`（有单测锁定）。

### TTFT / 首字时延字段（调研记录，2026-11-08；同日二次复核修订）

> 只读调研（v4 会话 `mvs_1354…` 全链路解剖 + 全库四重验证）。非官方契约，随版本可能
> 变化。**本节初版结论有误、已于同日复核修订**：初版断言 `usage` 全键清单里
> 「除 `request_duration_ms` 外无任何时延键」，实际漏了 `decode_duration_ms`。

**修订后结论：MiniMax Code 的逐调用 TTFT 可由总时长与解码时长差分推导**：

- `data_json.$.usage` 实际同时携带 `request_duration_ms`（发起→完成总时长，
  含 TTFT + decode）与 **`decode_duration_ms`（纯 token 解码耗时）**；
  thinking 模型还附带 `thinking_duration_ms`（解码前期的思考耗时，监控不消费）。
- **推导公式：`TTFT(ms) = request_duration_ms − decode_duration_ms`**。
  2026-11-08 全库实测（14,665 条带 request 的 assistant 行）：decode 覆盖
  94.5%；有 decode 的行里 99.1% 满足 `request ≥ decode`（其余为取消 / 时钟
  抖动 → nil）；P25/P50/P75 = 1.28s / 1.75s / 2.59s，量级合理。会话
  `mvs_1354…` 逐调用验证 7/7（大 Prompt 首调 14.8s、cache 命中次调 1.2s）。
- 初版其余观察不变：会话目录三个文件（`messages.jsonl` / `llm-call.json` /
  `manifest.json`）无 chunk 流、无首字时刻；`timing` 键只出现在 toolResult
  命令计时器，与 LLM 时延无关。

监控现状（2026-11-08 二次修订）：reader 的时长守门窗口查询**同一查询补取
`decode_duration_ms`**，走同一 `(session, turn)` FIFO 配对与 token 核对机制，
sample `ttftSeconds = (request − decode) / 1000`（decode 缺失或差值 < 0 → nil，
有效性域 [0, 3600] 过滤在聚合层）；字符分摊重建路径原样保留 `ttftSeconds`（与
`durationSeconds` 同模式），**移除 2.5.3 的显式写 0**；缓存 v18 重建。
聚合口径见 [`accounting.md`](../accounting.md) §TTFT 口径。

**附带发现（待观察）**：会话目录为
`~/.minimax/v2/sessions/<日期>/<时间>-session_<base64(sessionId)>/`；样本会话是
`sessionType=branch`、`archived/hidden`（从既有对话分支），其 db 的
`local_runtime_message_rows` / `token_usage` 行数为 0——branch 会话的用量是否最终落
columnar 表待更多样本确认；若不落，只读 db 的 scanner 会漏 branch 会话用量。

### Reasoning split (output → realOutput + reason)

**2026-11-08 起拆分粒度：日级大锅饭 → 调用级**（缓存 v19）。2.5.4 的 FIFO 时长配对
（`(session, turn)` FIFO + input/output tokens 双核对）已把 `local_runtime_message_rows`
的 assistant 行与 token 行 100% 配对，同一查询顺带取出该行 `$.thinking_content` /
`$.msg_content`（msg 侧含 tool_call_args，与日级字符聚合同口径）字符，配对成功的调用
**逐调用**执行 `ReasoningCharSplit.split`（`MinimaxLocalUsageAggregation.callLevelSplit`）；
按日 Σ 出配对产物（`MinimaxPairedSplitDay`）。

`applyReasoningSplit` 现为三条路径：

```swift
if usage.reasoningTokens > 0 {
    // 未来路径:账单/聚合层面已经分了 reasoning,直接用
    // P2-2 钳位: reasoning 超过 output 时截到 output,保证守恒
    reason     = min(usage.reasoningTokens, outputTokens)
    realOutput = outputTokens - reason
} else if 当天有配对调用 {
    // 调用级（2026-11-08 起）: reason = Σ配对调用拆分 + 未配对残余按日级比例
    // （残余 raw = 当天 raw output − 配对覆盖账面 output；残余字符 = 日级字符 − 配对字符，
    //  差减钳 0，无字符数据/无残余 → 残余分量 0 不猜）
} else if let chars = perDayChars[day],
          let split = ReasoningCharSplit.split(
            outputTokens: outputTokens,
            reasoningChars: chars.reason,
            visibleChars: chars.output
          ) {
    // 整天无配对的回退路径:原日级字符比例（向后兼容，v2 异常 day 等）
} else {
    // 没字符数据(v2 异常 day / 字符聚合失败 / 表不存在)或字符里没有思考文本
    // → 整个 usage 原样返回(不做 totalTokens 重算)
```

samples 侧同理：配对下标直接用调用级结果（`perSampleCallSplits` 与 samples 同下标
对齐），未配对样本维持日级比例路径；重建构造点 `rebuiltSample` 对
`sourceProviderID` / `durationSeconds` / `ttftSeconds` 原样透传。
`outputTokens` itself is clamped with `max(usage.outputTokens, 0)` before the branch, so a
negative ledger value cannot produce a negative split on any path.

**升级动机**：日级平均抹平同一天内重度推演（思考占比可到 95%+）与轻量确认（≈0）的
个体差异，调用级配对后每次调用用自己的思考/正文字符比拆分。P1-1 的 v2 字符聚合安全
守门（`filterUnsafeV2CharCounts`）行为不变——被过滤的字符只约束「未配对残余」的日级
比例，配对调用逐条 token 双核对、不受分母稀释影响。

**共享公式**: 比例分摊本身收敛到 `Sources/LLM-monitor/Models/ReasoningCharSplit.swift`
的 `split(outputTokens:reasoningChars:visibleChars:)`，行为与本节早前的 `R/(R+C)` 公式一致
（并顺带获得 `Int.max` 饱和保护：字符累加用 `SaturatingArithmetic`，估算值饱和到
`Int.max` 后再 clamp 回 `[0, output]`，两端都溢出也不会 trap）。另外四处字符分摊入口复用它：
ZCode 的非智谱 provider 分片（`GlmZcodeDBReader`，day 级 / 行级）、OpenCode 的 `minimax`
分片（`OpencodeDBReader`，day 级 / 行级）、Dsh M3（`DshLocalUsageScanner.estimateM3ReasoningTokens`，
事件级）、Agy（`AgyLocalUsageAggregation`，逐行 + 日聚合两级）。`split`
返回 `nil` 表示无法估算（raw output ≤ 0 或思考字符 ≤ 0，或饱和分母为 0），调用方保持原样。

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

3. **v6 (37% 正确)**: 用 `json_each` 展开 `tool_calls` 数组,只 sum 每个元素的 `tool_call_args` 字符。**排除** `tool_call_result_data`(它算 input,不算 current output)。生产 SQL（`safe_data` 是 `CASE WHEN json_valid(data_json) THEN data_json ELSE '{}' END` 的别名，保证脏 JSON 不让整条查询失败）:

   ```sql
   -- output_chars = msg_content + tool_call_args (排除 result_data)
   TOTAL(LENGTH(json_extract(safe_data, '$.msg_content')))
   + TOTAL((
       SELECT TOTAL(LENGTH(json_extract(
         CASE WHEN json_valid(j.value) THEN j.value ELSE '{}' END,
         '$.tool_call_args'
       )))
       FROM json_each(
         CASE
           WHEN json_type(safe_data, '$.tool_calls') = 'array'
           THEN json_extract(safe_data, '$.tool_calls')
           ELSE '[]'
         END
       ) j
     ))
   ```

   `json_type(...) = 'array'` 是刻意的: v6 早期版本用 `IFNULL(json_extract(...), '[]')`,
   当 `tool_calls` 存在但不是数组（对象/字符串）时 `json_each` 会直接报错,整个字符聚合
   降级。`reason_chars` / `output_chars` 两侧都先经 `safe_data`,`TOTAL()` 的 NaN /
   负值由 `nonNegativeInt` 统一归零、`+∞` 饱和到 `Int.max`。只有 `reason_chars > 0 ||
   output_chars > 0` 的 day 才进入 `perDayChars`,全零 day 不建条目。

**精度**: 字符比例分摊在 `msg_content` 含代码块 / Markdown 缩进时偏差 ±5-15%(代码字符密度比自然语言低)。thinking_content 是纯自然语言(LLM 思考过程),比例稳定 ~4 chars/token。tool_call_args 是 JSON 指令,字符/token 比例跟自然语言接近。

**实测**(全期 21 天合计,v6 修后):
- 账单 output: 3,512,604 tokens
- 字符分摊 reason: 1,305,303 tokens (**37.2%**)
- realOutput: 2,207,301 tokens (62.8%)
- 守恒: ✓

**Future-proof**: 当 minimax 切到 thinking model 时,`raw.reasoning` 或 `reasoning_tokens` 列会出现非零值。**P2-1 + P1/P2-1 修复**后,reader 的 per-day reasoning 表达式是 `TOTAL(MAX(MAX(COALESCE(reasoning_tokens,0),0.0), MAX(COALESCE(json_extract(safe_raw,'$.reasoning'),0),0.0)))` —— **per-row 取最大再 sum**(不是 `MAX(SUM, SUM)` 那种 group 后取 max,后者混合数据会算错,见 P1/P2-1 修复)。`safe_raw` 是 `CASE WHEN json_valid(t.raw) THEN t.raw ELSE '{}' END`,所以 `raw` 是非法 JSON 时该行按 0 参与而不是让整条查询失败。scanner 看到 `usage.reasoningTokens > 0` 走未来路径直接用账单,字符分摊路径变成 fallback。

**P1-2 算法本质 — 估算,不是精确 token 统计 (v8 修)**: 字符数 ≠ token 数(中文 / 英文 / 代码 / JSON 密度不同,4-1 chars/token 范围)。算法用字符比例分摊 output_tokens:

- 按天字符比例: 约 27.95% (per-day 字符聚合 / 全日字符总和)
- 按 turn 分别计算再加权: 约 29.53% (每个 turn 单独算 chars 比例再 sum)
- 单条消息比例分布 0-100% (有些 turn 100% thinking,有些 100% content)

per-day 聚合跟 per-turn 加权有 ~1.5% 差异(per-day 把所有 turn 平均了)。**结论**: 算法是 UI 展示用的**估算值**,不是精确账单。UI / 文档应明确标注 "估算"。

**P1-2 totalTokens 守恒 (v8 修)**: 修前 reader 算 `totalTokens = input + cacheRead + output + reasoning`,scanner 拆出 `realOutput = output - reason` 后字段总和 = input + realOutput + reason < totalTokens(差额 = reasoning 被算两次)。修后 scanner 在**未来路径和字符路径**上**重新算** `totalTokens = input + cacheRead + realOutput + reasoning = input + cacheRead + output`(跟账单总和一致),字段总和 == totalTokens。**无字符路径**直接原样返回 reader 算出的 usage 并 `continue`,不做重算——那条路径上 `reasoning == 0`,reader 的 `input + cacheRead + output + reasoning` 本来就等于 `input + cacheRead + output`,重算是恒等操作。

**P1-1 v2 字符聚合风险 (v8 修)**: v2 path 字符聚合是 per-day 聚合(不 join `local_runtime_token_usage`),**v2 `local_runtime_message_rows.turn_id` 100% NULL**,无法 per-turn 精确配对 token 行。后果:

- v2 字符聚合跟 token 行只能按天对齐(`created_at_ms` vs `ts`),天粒度
- v2 早期 token 写入不完整时(7/11 实测 message 1280 vs token 404 = 3.17x),字符聚合会偏(分母过大,reason 比例被稀释)
- v2 近期(7/15+)实测对齐 1.0x,正常

**scanner `filterUnsafeV2CharCounts` (v8 修)**: 比较**真实 message 行数 vs token 行数**(reader 通过 `MinimaxCharCounts.messageCount` 暴露,v2 路径 SQL 顺带 `COUNT(*)`)。`messageCount / rounds > 2.0`（`ratioThreshold` 默认值）时**移除该 day 的字符聚合**(不是 warn-only),scanner `applyReasoningSplit` 看到无字符数据走"reason = 0"路径,**真正修复数据偏差**,不是只 log。另有两条过滤：字符聚合里没有对应 token 行的 day（`rounds == 0` 或 `perDay` 无该日）同样跳过——空 day 的字符数没有分摊对象。

## SQLite reader — 跟 antigravity 一样的踩坑

`MinimaxDBReader` is a near-mirror of `AntigravityDBReader`. Same dual strategy: **fast path direct read + `/tmp` copy fallback on file-level SQLite errors**. The open/read/fallback plumbing is no longer in the reader at all — it lives in `Services/Infra/SQLiteConnection.swift` and `Services/Infra/SQLiteTempCopy.swift`; `MinimaxDBReader` keeps only minimax-domain SQL.

### Why this is needed (same root cause as Antigravity)

macOS system `libsqlite3.dylib` and CLI `sqlite3` are both SQLite 3.51.0 source builds, but the dylib is stricter about `-shm` shared memory file format. When the runtime is actively writing:

- `sqlite3_open_v2` returns OK (opens `.db`)
- `sqlite3_prepare_v2` returns `SQLITE_CANTOPEN (14)` "unable to open database file" during the mmap `-shm` phase

**Empirically** (against the live `MiniMax` process holding the .db fd):
- 5/21 SUCCESS on direct read when runtime is mid-write
- 21/21 SUCCESS on `/tmp` copy read (copy is fully isolated from runtime's `-shm`)

### Open flags

```swift
// SQLiteConnection.init(path:readOnly:)
flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
```

`MinimaxLocalUsageScanner.aggregateFromDB` picks the mode by path: the **direct read of the
real `.db` uses `readOnly: true`**, and only the `/tmp` copy opens `readOnly: false`.

`readOnly: false` → plain `SQLITE_OPEN_READWRITE`, because the copy starts in a dirty WAL
state and SQLite must perform WAL recovery (writing `-wal` pages back into the copy)
on first read. READONLY on a dirty WAL yields CANTOPEN(14) at prepare time.

`readOnly: true` has two sub-paths:
- No `-shm` and no non-empty `-wal` → opened as `file:<path>?immutable=1 | SQLITE_OPEN_URI`,
  bypassing SQLite's WAL shared-memory check entirely. This avoids a spurious CANTOPEN(14)
  and an unnecessary GB-scale `/tmp` copy for a fully quiescent database.
- Otherwise → plain `SQLITE_OPEN_READONLY`, attempting to read the live WAL. Any
  recovery / lock failure here is caught upstream and retried on the `/tmp` copy.

The `immutable=1` decision is re-checked after open and before the first query (TOCTOU
narrowing): if a `-shm` appeared or a non-empty `-wal` showed up in between, the read is
abandoned for a consistent snapshot copy. A 0-byte `-wal` does not demote it — such a
residue carries no frames, so the main DB already is a complete, consistent snapshot.

### busy_timeout + extended_result_codes

```swift
sqlite3_extended_result_codes(db, 1)  // before busy_timeout
sqlite3_busy_timeout(db, 300)        // 300ms wait on BUSY/CANTOPEN
```

`extended_result_codes(1)` lets us distinguish `SQLITE_CANTOPEN_*` subtypes for diagnostics. `busy_timeout(300)` handles brief runtime write-lock contention.

### Error → fallback decision tree

```
SQLiteConnectionError caught in SQLiteTempCopy.read (base code = code & 0xFF)
├── 14 SQLITE_CANTOPEN  → fallback to /tmp copy   (-shm 与本进程 dylib 不兼容等)
├── 5  SQLITE_BUSY      → fallback to /tmp copy   (写锁 300ms 内没等到)
├── 8  SQLITE_READONLY  → fallback to /tmp copy   (只读连接遇脏 WAL：READONLY_RECOVERY(264) 等，副本 READWRITE 才能 recovery)
├── 10 SQLITE_IOERR     → fallback to /tmp copy   (IOERR_SHMOPEN / IOERR_SHMLOCK 等，换干净 I/O 路径)
├── 11 SQLITE_CORRUPT   → fallback to /tmp copy   (并发 auto-checkpoint 撕裂页，重拷一致快照自愈)
└── other code (1 SQLITE_ERROR, 26 NOTADB, ...)   → propagate (copy won't help)
```

`SQLITE_ERROR(1)` is a SQL logic error — that's exactly what the v2 table name bug
produced. The copy fallback doesn't trigger, and the error propagates so the scanner can
log it and move on. `NOTADB(26)` (the file is not a database) likewise.

**CORRUPT has a two-round memory.** If the direct read returns CORRUPT *and* a persistent
corruption memory for this source path is already in effect (last round's copy read also
failed CORRUPT with an unchanged source fingerprint), the copy is skipped entirely and the
error is rethrown — a genuinely corrupt file should fail fast, not pay a full copy every
round. The memory is keyed by source path + fingerprint and lives only in-process, so any
change to the file invalidates it.

### Copy fallback (`SQLiteTempCopy.read` 公共 helper)

`SQLiteTempCopy` 是 antigravity / minimax scanner 共用的 SQLite 读策略：

```swift
try SQLiteTempCopy.read(dbPath: dbPath, logTag: "[minimax-scan]") { url in
    let reader = try MinimaxDBReader(path: url, readOnly: url.path == dbPath.path)
    defer { reader.close() }
    return try reader.aggregate(calendar: calendar, cutoff: cutoff)
}
```

- 快路径：直接 read 原 `.db`，无 copy I/O（可能走 `immutable=1`）
- 兜底：`SQLiteTempCopy.withTempCopy` 把 `.db + .db-wal + .db-shm` 三件套 copy 到 `/tmp` 副本
  - `defer` 在第一次文件创建之前就注册，覆盖"复制 .db 成功 → 复制 -wal 失败"这种半完成场景
  - READWRITE 让 SQLite 在副本上完成 WAL recovery（把 -wal pages 写回 .db）
  - `busy_timeout(300)` 应对偶尔的副本竞争
  - 副本不保留，read 完 `defer` 删 .db / .db-wal / .db-shm
  - 拷贝循环带逐文件指纹校验：`.db`（大文件）拷完立即复验源指纹，失效就放弃本轮
    剩余的 wal/shm 拷贝并重试，最多 3 轮，耗尽后抛 `sourceChangedDuringSnapshot`
- 错误码过滤：只对 file-level 错误（CANTOPEN 14 / BUSY 5 / READONLY 8 / IOERR 10 /
  CORRUPT 11）走 copy，其他错误直接 propagate（详见上面的 decision tree）

历史背景：`.db → /tmp 副本 + read` 的逻辑最初是 `MinimaxLocalUsageScanner.aggregateFromDB`
内联的私有方法；后来抽到 `Services/Infra/SQLiteTempCopy.read` 公共 helper（跟 antigravity
scanner 共享）。SQLiteTempCopy 的 `withTempCopy` defer 注册位置修复了一个老 bug：
旧代码先 copy .db 再注册 defer，".db 复制成功但 -wal 复制失败" 时副本残留在 /tmp。
新代码在第一次文件创建之前就注册 defer, 覆盖半完成场景。

## Local Usage UI

The card no longer renders `MinimaxLocalUsage` directly. `ProviderCardView.localUsage(projection:part:)`
feeds a `ProviderUsageProjection` — the automatically attributed local sources for the
`minimax` quota provider (MiniMax Code runtime, DSH, ZCode `minimax` slice, and supported
OpenCode IDs; each scanner result reaches it as a `ClientUsageContribution`) — into the shared footer:

```swift
// ProviderCardView.localUsage(projection:part:), production path passes part: .detail
makeLocalUsageFooter(
    dailyTokenUsage: projection.dailyTokenUsage,   // [UnifiedDailyTokenUsage], not [MinimaxDailyUsage]
    recentSamples: projection.recentSamples,
    quotaProviderID: status.kind.quotaProviderID,   // QuotaProviderID.minimax
    deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
    scannedAt: projection.scannedAt,
    isReady: projection.hasActivity
        && (status.kind != .codexChatGpt || projection.dailyTokenUsage.count == 7),
    freshness: projection.localUsageFreshness,
    isTruncated: projection.isTruncated,
    emptyHint: "本机未发现 MiniMax Code / DSH 会话数据",
    part: part
)
```

`isReady` for minimax is just `projection.hasActivity` — any day with tokens / turns /
rounds, or any retained sample, is enough. The `dailyTokenUsage.count == 7` conjunct is
a codex-only requirement (its API is naturally sparse and needs a full week to render).
`hasActivity` is deliberately *not* `!days.isEmpty`: `filterLast7Days` zero-fills missing
days, so the array is always 7 long once a scan has run, even with no data at all.

The empty-state hint is per-`ProviderKind` (`emptyUsageHint`); minimax's names both
client families because the card merges them, so the text is "本机未发现 MiniMax Code / DSH 会话数据"
rather than naming the v2 runtime alone.

The 7-day hover displays 4 stacked categories (input / cache / output / reason) per day, identical visually to antigravity's chart. See `LocalUsageHoverViews.swift` for the generic implementation.

### Why the chart has four categories

历史问题。Reasoning 不再总是 0——`applyReasoningSplit(perDay:perDayChars:)`（定义在 `Services/MinimaxLocalUsageAggregation.swift`）已经从 `local_runtime_message_rows.data_json` 的 `thinking_content` 字符数按比例分摊出 reasoning(实测全期 37.2% output 实际是 thinking,v6 修后;v4 84% / v5 15% 都是修 bug 过程中的中间值,详见 "Reasoning split" 段踩坑记录)。Reason 栏现在有真实数字显示。分摊比例同时按 day 级比例回写到每条 sample（`applyReasoningSplit(samples:rawPerDay:adjustedPerDay:calendar:)`），让 recent samples 与 7 天柱图口径一致。

The hover chart is **shared** across every local-usage client via `SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>`. 4th column 保持兼容(其他客户端已经在用),minimax 之前 placeholder 现在有数据。

**未来工作**: 7-day chart 加第 5 个柱子 "Tool"(只算 tool_call_args),跟 reason / output 区分,让用户看到"工具调用"是 output 的主要部分(全期 30%+)。涉及所有客户端共享的 `LocalUsageHoverViews`,scope 大,留作后续。

## Cross-Provider Cache Semantics

`MinimaxDailyUsage` uses the same cache model as `AntigravityDailyUsage` (per-day
aggregates keep the three buckets separate):

| Provider | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` |
|---|---|---|---|
| Antigravity | uncached input | cache read | cache write (separate) |
| minimax | uncached input | cache read | cache write (separate) |
| Codex | **uncached + cached combined** (subset model) | `cachedInputTokens` (= read) | not stored (always 0) |

**Samples follow a different, deliberately unified rule.** Since cache index v14, a
minimax sample's `inputTokens` is **cache-inclusive** (`uncached + cacheRead`), produced by
`TokenAccountingCatalog.minimax.normalizedBuckets(...).cacheInclusiveInput`. The ledger's
own three buckets are never lost — `cachedInputTokens` still carries the cache-read part,
so the two are separable downstream, and `tokenComponents` no longer needs a minimax-only
branch. DSH and Codex already worked this way; v14 aligned minimax with them.
`MinimaxDailyUsage` (the per-day type) keeps `inputTokens` **uncached** — only the sample
type is cache-inclusive.

**Adapter** (`Models/LocalUsageDaily.swift`):

`MinimaxDailyUsage` is a `typealias` for `LocalDailyTokenUsage` (as is
`AntigravityDailyUsage`), so there is no per-provider adapter to maintain for them — the
shared struct carries the conformance directly. Only codex needs an explicit adapter,
because its field names differ and it has no cache-write bucket:

| Provider | `input` adapter | `cacheRead` adapter | `cacheWrite` adapter |
|---|---|---|---|
| `MinimaxDailyUsage` = `AntigravityDailyUsage` = `LocalDailyTokenUsage` | `inputTokens` (uncached) | `cacheReadTokens` | `cacheWriteTokens` |
| `DailyTokenUsage` (codex) | `uncachedInputTokens` (= inputTokens - cachedInputTokens) | `cachedInputTokens` | `0` (fixed) |

The protocol's default implementations (`accountingBuckets`, `totalTokens`, `inputTotal`,
`outputTotal`, `cacheHitRate`, `reasonRate`) clamp every field with `max(_, 0)` and sum via
`SaturatingArithmetic`, so a negative or near-`Int.max` ledger value cannot produce a
negative total or an overflow trap anywhere downstream.

The `LocalUsageDaily` protocol uses short field names (`input` / `cacheRead` / `cacheWrite` / `output` / `reasoning`) to **avoid collisions with existing stored property names** on the provider-specific daily types (e.g. `inputTokens`, `outputTokens`, `reasoningTokens` — all already exist on at least one type).

**Why minimax + antigravity use independent `input` / `cacheRead` / `cacheWrite`**: the API returns them as three separate quantities, and subtracting them would lose precision. `totalTokens` is `input + cacheRead + output + reasoning` — `cacheWrite` is intentionally excluded (it's bookkeeping, not consumption).

**Why codex uses subset model**: the ChatGPT `/backend-api/wham/usage` API returns `input_tokens` and `cached_input_tokens` as overlapping counts, not separate. Different API design choice.

## Local Scanner Error Handling

| Situation | Current behavior |
|---|---|
| `.db` file confirmed missing (ENOENT) | `logInfo` + 清理该 source 的 cache 条目（明确不存在才清） |
| `.db` or `.db-wal` `stat` fails for another reason (permission, transient I/O) | `logWarn` + 计入 degraded，**保留 last-good** `sources` / `dailyBySource`，下一轮继续重试 |
| `aggregateFromDB` throws file-level error | `aggregateFromDB` 自身经 `/tmp` 副本重试；副本也失败才上抛 |
| `aggregateFromDB` throws SQL error (e.g. wrong table name) | `logInfo` + skip；`index.dailyBySource[source]` 与 `samplesBySource[source]` 保留（不覆盖），指纹不推进，下一轮自然重试 |
| `aggregateFromDB` throws any other error | `logInfo` + skip；existing data preserved |
| 唯一的 runtime source 失败 | `failedSessionCount > 0` → `scanResultIsComplete` 为 false，source 保持 dirty / failed 供下一轮 reconcile 重试；已有日桶仍展示 |
| `index.json` version mismatch (≠ 16) | Reset to `.empty`, full re-scan next time |
| `index.json` parse error | Reset to `.empty`, full re-scan next time |
| 冷启动时 `calendarSignature` 不匹配 | 不展示旧快照（返回 nil），等第一次 scan 按当前日历重建 |
| 字符聚合 SQL 失败（token 账本仍成功） | 主账本照常返回，Reason = 0，`charSplitDegraded` 置位并强制下一轮重扫 |

## Known Limitations

- `cost_usd` is present in `local_runtime_token_usage` but is **not read at all** by the reader, let alone shown in the UI — the scanner only keeps `input/output/cache/rounds/turns`. (Pricing for the chart's money column comes from `ModelPricing.json` × tokens, not from the ledger's own `cost_usd`.) Future work: add a "今天 $0.42" suffix to the footer.
- Per-model breakdown is not exposed in the hover chart. It shows **aggregate** per day, not "today's M3 vs M3.1 Flash vs coder vs verifier". The `model` and `agent_name` columns are queryable from `.db`; UI is the only blocker. (`model` *is* resolved per sample for pricing, via the session-directory model → row → session → unique-ledger fallback chain.)
- 7-day window is hardcoded. The data is in cache, so extending to 14/30 days is a single SQL change (and a `LocalUsageRetentionWindow` bump).
- `cost_usd` is only meaningful for direct API calls; sub-agent runs (`coder`, `verifier`, etc.) may have different cost semantics that aren't surfaced.
- v2's `local_runtime_sessions.record_json` is only consulted for `effectiveModel` (the session-level model fallback in the sample query). `parentSessionId` / `errorMessage` / `title` are **not** read. Schema is 100% available, scanner just doesn't query those fields. The **real** model comes from a different file entirely — the session directory's `llm-call.json` (see §Model resolution for samples).

## Legacy database policy

The legacy database is out of scope. It is not probed, opened, aggregated, or used
as a cache fallback. Minimax local usage requires the
v2 runtime database at `~/.minimax/v2/sqlite/runtime-state.sqlite`.

This intentionally avoids mixing two schemas and prevents stale legacy history from
being presented as current v2 usage. Users without the v2 database receive the empty
local-usage state until Minimax creates it.

## Test Coverage

MiniMax local usage tests are in `Tests/LLMMonitorTests/MinimaxDBReaderTests.swift` and `Tests/LLMMonitorTests/MinimaxLocalUsageScannerTests.swift`; shared retention coverage is in `Tests/LLMMonitorTests/ScannerRetentionContractTests.swift`.

- **额度窗口用量回归（`QuotaWindowUsageTests.swift`，跨 provider 文件中的 minimax 区块）**：
  - `testWindowBoundsPinnedToRealStartWhenMinimaxEndsAtMidnight`：end 为次日 0 点、长度 14400 时 `windowBounds` 起点 = 当日 20:00（不回退 5h 兜底错推的 19:00）。
  - `testMinimaxShortWindowUsageExcludesPreviousWindowWhenLengthIsKnown`：20:00–24:00 段内 19:30 样本被真实 4h 长度排除、nil 对照组多算（修复前行为）；在统一节奏算法下，真实 4h/5h 长度准确计算出 `intervalTimeRemainingFraction` 参与时间感知标色。
- **Reader (`MinimaxDBReaderTests.swift`)**:
  - `testV2ReaderAggregatesRowsSessionsTurnsAndSamples`: aggregates v2 rows, sessions, turns, and samples.
  - `testV2ReaderRecoversMissingModelFromSessionAndUniqueLedgerModel`: the row → `record_json.effectiveModel` → unique-ledger-model fallback chain.
  - `testV2ReaderDoesNotGuessWhenLedgerContainsMultipleModels`: with several distinct models in the ledger the last fallback is refused (sample `modelName` is nil rather than a wrong guess).
  - `testV2ReaderPrefersSessionDirectoryModelOverGenericLedgerLabel`: the session directory's `llm-call.json` model wins over the ledger's generic `minimax/MiniMax-M3` label.
  - `testV2ReaderFallsBackWhenSessionDirectoryModelIsUnavailable`: an unreadable session directory falls back to the old chain instead of crashing or guessing.
  - `testV2ReaderClampsNegativeValuesAndUsesPerRowReasoningMaximum`: clamps invalid values and applies per-row reasoning maximum.
  - `testV2CharacterAggregationUsesToolArgsExcludesResultsAndPreservesOutput`: verifies v2 character aggregation filters and output conservation.
  - `testV2CharSQLFailureKeepsTokenLedgerAndMarksDegradedForRetry`: keeps the token ledger and marks character aggregation degraded.
  - `testPerRowReasoningExprTakesMaxOfNativeAndRaw`: verifies single-row dual-source `MAX` selection between native `reasoning_tokens` and `raw.reasoning`.
  - `testV2DurationBackfillPairsFIFOAcrossTurns`: `request_duration_ms` 按 `(session_id, turn_id)` FIFO 1:1 回填 `durationSeconds`，跨 turn 互不串；主账本字段不受影响。
  - `testV2DurationBackfillSkipsMismatchedEntryAndKeepsFIFOOrder`: input/output 核对失败的条目按序丢弃，不阻塞同 turn 后续配对。
  - `testV2DurationBackfillEmptyRowAndMissingOrZeroDurationGivesNil`: `$.usage` 缺失的空行永不匹配；命中条目缺 `request_duration_ms` / 值 0 / 无 message 行 → `durationSeconds` 保持 nil。
  - `testV2DurationSQLFailureKeepsSamplesUnaffected`: 坏表（`breakMessageTableSchema` 缺 `data_json`）时时长查询独立守门——不 throw、样本路径与主账本原样、`charAggregationDegraded` 语义不变。
  - `testVerifiedDurationPopsFIFOUntilTokenMatch`: FIFO 弹出 + 双核对的纯逻辑契约（空行永不匹配 / 命中即停 / 队列耗尽 → nil）。
- **v2 Scanner (`MinimaxLocalUsageScannerTests.swift`)**:
  - `testV2DegradedSourceIsRetriedAndRecovers`: retries a degraded source and clears the flag after recovery.
  - `testV2UnsafeCharacterRatioDropsOnlyMisalignedDay`: filters abnormal character-count days.
  - `testApplyReasoningSplitPreservesDurationSeconds`: 字符分摊重建样本时原样保留 `durationSeconds`（丢了该样本在 tok/s 分子分母里都不计）。
  - `testV2CacheMigrationResetsLegacySourceData`: resets incompatible cached source data for the v2-only policy.
  - `testScannerReadsOnlyRuntimeDatabaseEvenWhenSiblingLegacyDatabaseExists`: ignores a sibling legacy database.
  - `testMinimaxRestoresCachedUsageOnColdStart` / `testPrunesDailyBucketsOlderThanEightDayWindowOnSave`: cached-result restore and 8-day bucket hygiene.
  - `testComputeFailedSessionCountRules`: failed-session count rules.
- **Retention contract (`ScannerRetentionContractTests.swift`)**: locks `pruneStaleDailyBuckets` to the shared `LocalUsageRetentionWindow.days` window so the literal 8 cannot drift away from the other scanners.
Test pattern: build a real SQLite database with the v2 tables, insert test rows with
`Date` / `DateComponents` (not hardcoded millisecond timestamps), open via
`MinimaxDBReader`, and assert on the aggregate. The reader tests cover the complete
reasoning split input contract, including non-negative totals, per-row native/raw
reasoning maximum, character aggregation, and output conservation.

## Open Questions

- Should the 7-day hover expose `cost_usd` as a secondary number under the I/O bar (e.g. "今天 $0.42")?
- Should the hover show per-model breakdown (M3 vs M2.7) as a second bar group?
- Should v2's `local_runtime_sessions.record_json.title` / `errorMessage` be surfaced for "failing sessions" highlight?
- Should scanner cache `cost_usd` (currently discarded — only `input/output/cache/rounds/turns` are kept)?
- Should 7-day window become configurable (`recentDays: 7 | 14 | 30`)?
- Should the scanner use `local_runtime_ledger_watermarks.last_seq` for incremental v2 sync instead of mtime + full re-aggregate?


> 本文由 `spec/providers/minimax.md` 拆分；内容沿用该文件已核对的代码基线，本次未重新逐项核对全部代码。
> 核对基线：2026-11-08 · 代码 ea43cff
