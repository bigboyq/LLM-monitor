# Codex Harness — Local Client Spec

Client: Codex (`ClientID.codex`)

Codex is the local CLI/Desktop session source for token usage. The remote ChatGPT Plan provider consumes the same local authentication file for its quota requests; its API contract, quota mapping, reset credits, pricing, and provider UI are documented in the [ChatGPT Plan provider spec](../providers/chatgpt.md).

## Codex auth file

Default location:

```text
~/.codex/auth.json
```

If `CODEX_HOME` is set and `authPath` is omitted, the code reads:

```text
$CODEX_HOME/auth.json
```

Expected shape:

```json
{
  "auth_mode": "chatgpt",
  "tokens": {
    "id_token": "eyJ...",
    "access_token": "eyJ...",
    "refresh_token": "rt...",
    "account_id": "9d6e7f7f-4bf2-46a2-ad19-e9b7248cbc99"
  },
  "last_refresh": "2026-06-30T04:27:48.073782Z"
}
```

Fields used by this app:

| Field | Use |
|---|---|
| `tokens.access_token` | Bearer token for API requests |
| `tokens.account_id` | Optional `ChatGPT-Account-ID` header |
| `tokens.id_token` | Optional JWT source for `chatgpt_plan_type` and `email` |
| `email`（顶层）/ `tokens.email` | `accountEmail`（优先于 JWT 里的邮箱） |

`refresh_token` is not used.

The file is read through `FileHandle` in 64 KiB chunks with a hard cap of
`CodexFetcher.maxAuthFileBytes` (1 MiB); over the cap the provider fails with
`网络错误：Codex 认证文件过大` and logs neither the path nor the content. Read/parse
errors never embed the full path or the underlying system error — they surface as
`网络错误：无法读取 Codex 认证文件（auth.json）`, which keeps the username and any
custom `authPath` directory out of the UI and the log.


The ChatGPT Plan provider consumes this file's access token, account ID, and optional ID-token claims for remote quota requests; its authentication headers and API contract are documented in the [provider spec](../providers/chatgpt.md#auth-consumption).

## Local Usage Aggregation

### Official daily date, reporting window, and freshness

The following date semantics were confirmed by aligning the official day-level API responses
with the local Codex session JSONL data (August 2026, when Pacific Time is PDT):

| Item | Confirmed behavior |
|---|---|
| Official daily boundary | `01:00 UTC`, which is `18:00 PT` on the previous calendar day and `09:00` in China (`Asia/Shanghai`) |
| Official daily window | `[01:00 UTC, next-day 01:00 UTC)`, equivalently `[09:00 China time, next-day 09:00 China time)` |
| Local alignment boundary | Use an explicit `Asia/Shanghai` 09:00 boundary when reproducing the official date labels; do not use the local calendar midnight boundary |
| Typical freshness lag | About 3 hours between the official `data_freshness_ts` snapshot and the time the response is retrieved |

Observed freshness examples:

- A response retrieved at China time 10:00 reported `data_freshness_ts = 23:00 UTC`,
  which is China time 07:00: approximately 3 hours of freshness lag.
- A response retrieved at China time 11:00 reported `data_freshness_ts = 00:00 UTC`,
  which is China time 08:00: again approximately 3 hours of freshness lag.

`data_freshness_ts` describes the latest official aggregation snapshot available to the
endpoint. It establishes an observed reporting/freshness delay, but should not be interpreted
as proof of a specific database-ingestion delay. A date whose official snapshot has not reached
the next `01:00 UTC` boundary is incomplete and must not be compared with a complete local day.

The official API is account-wide and may include work surfaces, other devices, and other clients.
Local JSONL aggregation is client-local; if multiple Codex accounts share the scanned session
roots, their usage must be separated before comparing it with one official account.

### Provider-batch reconciliation (2026-09-14)

Codex local usage details are produced by `LocalUsageOrchestration.reconcile()` after a
Provider batch settles and no longer wait for a successful quota fetch:

- The session scan runs whenever the codex home directory exists — resolved via config
  `authPath` → `CODEX_HOME` → `~/.codex`, the same chain `CodexFetcher` uses
  (`CodexFetcher.codexHomeDirectory` / `checkClientReadiness("codex")`). Readiness is
  diagnostics-only; when a source disappears, one transition reconcile lets the scanner
  publish an empty snapshot and clear stale UI.
- The scan is **not** gated on FSEvents dirtiness. Every reconcile pass runs it and lets the
  window + source fingerprints decide whether anything was actually re-read; the
  source-owned watcher (`LocalUsageSourceLifecycle` over `sessions` + `archived_sessions`)
  only drives UI freshness (`.dirty` / `.clean`). This mirrors the other scanners: an
  always-open session file can change mtime/size before any FSEvents event arrives, so a
  dirty-gated scan would miss it.
- Mode mapping: `.full` and `.dirty` may reuse the cache (`.full` even reuses the
  per-file event cache), only `.hardFull` sets `forceFull` and re-parses every selected
  file. Code equivalence: `forceFull: mode.bypassesProviderCache`.
- Scan results produced before the first quota success can still be collected; the normal
  post-Provider reconcile enriches them when a quota window is available.
- Window summaries (`primary` / `secondary`) are derived from the reset times stored in the
  shared data layer (the most recent successful quota fetch). Before the first quota success
  they are `nil`, and the scan still produces `dailyTokenUsage` (7 days) and the recent samples.
- `applyCodexUsageDetails` enriches whatever quota info the data layer currently holds; the
  strict `fetchedAt` match is gone. After a quota refresh, the next loop-B tick re-derives the
  windows from the new reset times.

### Accounting contract

Codex 的 raw `inputTokens` 是包含 cache-read 的完整输入，`cachedInputTokens` 是其子集；
它们的原始字段语义保持不变。`LocalUsageDaily` adapter 只在统一层计算
`Input = inputTokens - cachedInputTokens`，并单独保留 `Cache read`。Codex 的 output 和
reasoning 是独立字段，直接映射为 `Output` / `Reason`。统一 total 与价格不包含
`cacheWrite`（Codex 本身也不提供该字段）。Codex 侧 scanner 走
`TokenAccountingCatalog.codex`（`input: .cacheInclusive` / `output: .independent`）把 raw
计数归一化成四桶，再还原成 cache-inclusive 的 sample 落盘。完整矩阵见
[`spec/accounting.md`](../accounting.md)。

### Architecture note

Codex local usage intentionally does not use the Minimax/Antigravity three-layer scanner model.
It parses the CLI's append-only JSONL sessions on demand and keeps parsed events in an in-memory
cache keyed by file path; there is no provider-owned incremental SQLite index whose writes
could race during cancel-and-rescan. Cancellation checks at scan boundaries plus the shared local
usage lifecycle/generation guard are therefore sufficient, and a separate `lastCommittedGeneration`
layer or dedicated cancel-and-rescan persistence test would not describe the Codex data path.

It does share the **downstream** half of the model: `QuotaInfo.codexUsageDetails` is turned
into a `HarnessUsageFrame` by `UsageFrameExtractors.codexFrames`
(`clientID = codex`, `quotaProviderID = openAI`, `namespace = .codex` — a passthrough
namespace because the scanner already stamped `codex:` onto every promptID) and then goes
through the same `UsageProjectionKernel` as the other clients. What Codex opts out of is
only the generic `LocalUsageScannerBase` coordinator/cache layer.

Since 2026-09-06 the in-memory cache also carries a per-file resume offset: while the app is
running, a grown session file is re-parsed only from its last complete line (append-only
incremental parsing, ms-level per tick). The session event cache is persisted across app
restarts to `token-monitor/codex.json` (via `ScannerIndexIO`), allowing cold starts to reuse
the warm cache without full re-parsing; a truncated or same-size-but-modified file falls back
to a full re-parse of that file. The byte-level line prefilter
(`event_msg` / `turn_context` markers matched via memmem before any String decoding) keeps
parsing an order of magnitude cheaper than a naive `String.contains` pass.

The scan selects at most 1,024 recent files and retains event caches for the newest 256;
older selected files are still scanned within the I/O budget but cannot evict that hot set.
The 1 GiB per-scan budget counts only bytes actually read, not cache hits. Cached events
remain available after the read budget is exhausted. Budget-truncated incremental tails
and files skipped for lack of budget remain pending, so the aggregate summary is not cached
until those reads finish on a later refresh. Cold scans still use the existing bounded tail
window (discarding older content is intentional). A natural EOF with an incomplete JSON line
is stable while the file is unchanged; its resume offset stays at the line start so an append
can complete that line without duplicating events.

`CodexLocalScanLimits.production` (single source of the numbers above):

| Limit | Value |
|---|---|
| `maxSessionFiles` | 1,024 |
| `maxEventsPerFile` | 10,000 |
| `maxTotalParsedBytes` | 1 GiB (1,073,741,824) |
| `maxJSONLLineBytes` | 8 MiB |
| `readChunkBytes` | 1 MiB |
| `maxEventCacheEntries` | 256 |
| `maxRecentSamples` | 65,536 |

The provider also computes local usage summaries from:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`

The application uses the same local aggregation rules directly in
`CodexLocalUsageScanner`:

| Consumer | Time window | Aggregation |
|---|---|---|
| 5 h window (`primary`) | `intervalResetsAt - windowSeconds` to `intervalResetsAt` | prompts, rounds, input, cached, output, reasoning output |
| weekly window (`secondary`) | `weeklyResetsAt - windowSeconds` to `weeklyResetsAt` | same fields over the weekly window |
| 7-day chart (`dailyTokenUsage`) | local calendar days, today and the previous 6 | daily `turns` / `rounds` / token totals |
| recent samples | whole scan | per-`token_count` `LocalTokenUsageSample` (cache-inclusive input, `codex:` promptID, `sourceProviderID = openai`), newest 65,536 kept; `durationSeconds` from the `token_usage_record` pairing rule below (nil without a valid anchor) |

Window lengths are the parser's `limitWindowSeconds` (falling back to 5 h / 7 d when the
API omits them), not the literal 5 h / 7 d.

The local `primary` / `secondary` summary keys refer to normalized interval / weekly
fields, not raw API positions. A Pro response with only a 604800-second `primary_window`
therefore creates only a local `secondary` window and a 周 usage row; 5h remains absent.

Rules:

- `prompts` counts unique `task_started.turn_id` values inside the window
- `rounds` counts matching `token_count` events
- token totals sum `last_token_usage.*`
- `durationSeconds` (token/s denominator, mixed differencing validated on real rollouts):
  each rollout also carries top-level `token_usage_record` events (one per model response,
  `timestamp` ms + `payload.turn_id`), parsed **for timing only** — token accounting stays
  single-sourced on `token_count` (the two event kinds are ~1:1, double-counting risk).
  Start anchor for a record = max(last `token_count` timestamp, last record timestamp) of
  that turn, falling back to `task_started`; the derived duration rides the **next**
  `token_count` sample of the same turn (consumed once, stale/invalid anchors discarded,
  (0, 3600] s valid, state scoped per session file — turn IDs are global UUIDs).

### 跨进程缓存持久化（`ScannerIndexIO`）

Codex 本地会话扫描索引经 `CodexScannerIndex: Codable, Sendable` 序列化并落盘：
- **存储路径**：`~/Library/Application Support/LLM-monitor/token-monitor/codex.json`（由 `TokenMonitorProvider.codex` 定义）；
- **生命周期**：扫描器首次或冷启动扫描前执行 `loadIfNeeded()` 读取暖索引，跳过未修改会话文件的重新解析；扫描完成时通过 `persistToDisk()` 原子写盘；
- **增量判据**：保持基于文件 `mtime` 和 `size` 的指纹缓存，在不改动 session 内部状态的前提下杜绝冷启动全量 I/O。


## Context compaction（上下文压缩，调研记录）

> 2026-10-28/29 观测（窗口 10-21~10-28：83 个 rollout 文件、8,312 条 token_count 事件、
> **56 次真实压缩**）。非官方契约，随版本可能变化；本节只记录发现，不进任何代码路径。

**设计模式：按 context window 的百分比触发（p50 = 80%，硬阈值簇 ≈ 94.5%），压到 ~44K
起步**。与 antigravity 的绝对水位（~300K）不同，Codex 的触发跟随模型窗口缩放。

| 观测量 | 值 |
|---|---|
| 触发水位（pre，压缩前最后一次非零 input） | 156.8K ~ 449.3K，p50 = 224.2K；**按 window 百分比**：p50 = 80%，双峰——17 次聚在 94.0%~94.8% 的硬阈值簇（auto-compact 触发线 ≈ 0.945 × window），39 次散布 60%~87% 的早压缩（其中 19 次前 120s 有 task_started，疑为新用户消息投影检查触发；未找到 `/compact` 明文命令，手动/自动无法区分） |
| 模型窗口 | `model_context_window` 逐响应变化：gpt-6.1-sol = 475,000 / gpt-6-luna = 258,400（session 内可切模型）；luna 组 pre p50 = 206K（80%）、sol 组 p50 = 374.7K（79%） |
| 压缩完成水位（post，压缩后第一条非零 input） | 30.5K ~ 62.7K，**p50 = 43.9K**（≈ window 的 16%） |
| 底座（新会话首事件 input，含首条消息） | 30.2K ~ 42.0K，**p50 ≈ 35.0K**（比 antigravity 的 ~10.7K 大一个量级） |
| 压缩比 | 表观（post/pre）p50 = 18%；**扣除底座后对话内容的真实压缩比 ≈ 4.7%**——压缩后上下文里 ~80% 是固定底座 |
| 摘要形态 | `compacted` 事件的 `replacement_history` 含 `{type:"compaction", encrypted_content:...}`——**服务端加密摘要**（base64 p50 34,744 字符 ≈ 26KB ≈ 6~7K token，固定形状，与 post−底座差值吻合），本地读不到明文；另有若干 retained 原始 user 消息（带 `retained_source` 指回原 id） |
| 增长斜率（相邻两次模型调用的 input 增量，n=7,895） | 轮内（工具循环）p50 +909、p90 +5,795、max +20.5K；跨轮（新用户消息）p50 +725、p90 +3,220、max +32.8K |

**数据在哪看（复现路径）**：

1. `~/.codex/sessions/YYYY/MM/DD/rollout-<UTC时间>-<thread_id>.jsonl`，每行
   `{ordinal, timestamp, type, payload}`。**水位字段**：`type=="event_msg"` 且
   `payload.type=="token_count"` → `payload.info.last_token_usage.input_tokens`
   （cache-inclusive，`cached_input_tokens` 是其子集；同轮内严格单调递增，除压缩点外
   零例外）。时间戳用顶层 `.timestamp`（ISO-8601 UTC ms）。
2. **压缩点双标记**：(a) 顶层 `type=="compacted"`；(b) 同秒一条 `input=0` 的
   token_count。两标记 56/56 双向 ±5s 匹配，零漏检零误检；跳过零事件后套用
   「prev ≥ 120K 且 next < prev × 0.55」骤降规则得到完全相同的 56 个点。
3. **组键必须用文件**，不能用 `session_meta.payload.id`：resume/子代理文件会继承父 id
   （文件名 `parent_child` 双 id 或开头拷贝父 meta）。

**数据质量陷阱**：

- 71/83 文件是 `luna_worker` 子代理线程（`source.subagent.thread_spawn`，depth=1）：
  spawn 文件首调用**继承父会话全部上下文**（最高 310K），其首事件 input 不是底座；
  其中 4 次压缩是「spawn 继承超限 → 立即压缩」。
- resume 文件开头会重放一条 compacted 事件（12 条，无零标记、无 pre/post），不计入
  压缩次数。
- 一次压缩连发两条 `input=0` 的 token_count（相隔 1~3s），按「连续零折叠」去重，
  否则 56 会虚增为 60。
- `input=0` 的事件里 `total_token_usage` 仍是累计值（13.6M 级），做日用量统计时勿把
  `last` 与 `total` 混用（与 §Local session aggregation 的 DailyTokenUsage 口径一致）。


## TTFT / 首字时延上游字段（调研记录，2026-11-08）

> 只读调研（本机 `~/.codex/sessions/2026/11/08/rollout-*.jsonl` 实测）。非官方契约，
> 随版本可能变化；本节只记录发现，不进任何代码路径。

每个 task/turn 结束时 JSONL 落一条 `type=="event_msg"` 且 `payload.type=="task_complete"`
的事件，payload **原生携带 turn 级时延字段**：

| payload 字段 | 含义 |
|---|---|
| `started_at` / `completed_at` | epoch 秒，turn 起止 |
| `duration_ms` | turn 总时长 |
| `time_to_first_token_ms` | 本 turn 首次响应的首字延迟（TTFT） |
| `turn_id` / `root_turn_id` / `last_agent_message` | 归属键与终答文本 |

监控现状（2026-11-08 更新）：scanner 已解析 `task_complete`，`durationSeconds` 仍走
§Local session aggregation Rules 的 `token_usage_record` 锚点差分；TTFT 接入为
`.taskCompleted` 事件携带 payload 原生 `time_to_first_token_ms`（负 / NaN 拒绝，
ms ÷ 1000），**turn 级 → 回填该 turn 第一条 `token_usage_record` 样本**（文件内收集
`taskCompleteTTFT[turnID]` 后统一回填，无对应 record 丢弃）；缓存 v2 重建。
`payload.duration_ms` 仍未读取（时长口径维持 token_count 锚点差分单源，见 Rules）。

## Cross-Provider Cache Semantics (Codex vs Antigravity)

> Companion section: see `antigravity.md` § Cross-Provider Cache Semantics for the Antigravity side of this comparison, including the recommended `NormalizedDailyUsage` abstraction.

Codex and Antigravity report cache reads using **incompatible semantic models**. Any code that aggregates token usage across both providers must be aware of these differences, or it will double-count or mis-attribute.

### Codex model: `cachedInputTokens` is a SUBSET of `inputTokens`

`inputTokens` is the **full** input that the API charged for. `cachedInputTokens` is the subset of those tokens that were served from cache. Adding them together double-counts:

```swift
// QuotaInfo.swift — DailyTokenUsage
inputTokens             // 完整输入总量（已含 cached）
cachedInputTokens       // input 里面命中缓存的子集

uncachedInputTokens = max(inputTokens - cachedInputTokens, 0)   // 推出来的"非缓存"输入
inputTotal = uncachedInputTokens + cachedInputTokens
           = inputTokens                                         // 跟 input 自己相等
```

This is visible in the JSONL data: every `token_count` event has both fields, and `cached_input_tokens ≤ input_tokens` for every round in practice.

Codex does **not** report a `cache_write_tokens` field. There is no concept of "future cache write" in the Codex schema; once a request is served, only the read-side cache accounting is visible to the client.

Reasoning is reported as `reasoning_output_tokens` separately from `output_tokens`, and the model sums them: `outputTotal = outputTokens + reasoningOutputTokens`.

### Antigravity model: `inputTokens` and `cacheReadTokens` are MUTUALLY EXCLUSIVE

`inputTokens` is **only the uncached input**; cache-served tokens are reported as `cacheReadTokens`. The two are separate buckets, not parent/child. See `antigravity.md` for the full breakdown.

### Comparison table

| Dimension | Codex | Antigravity |
|---|---|---|
| Cache bucket | Subset of `inputTokens` | Independent, parallel to `inputTokens` |
| Total input = | `inputTokens` (already includes cached) | `inputTokens + cacheReadTokens` |
| `cacheWrite` | **Not reported** | Yes, separate field, not in `totalTokens` |
| Cache hit rate | `cachedInputTokens / inputTokens` | `cacheReadTokens / (inputTokens + cacheReadTokens)` (equivalent) |
| Per-round data | 4 fields per `token_count` event | All 5 fields per LLM call |
| Data source | Local JSONL `~/.codex/sessions/**/*.jsonl` | RPC `GetCascadeTrajectoryGeneratorMetadata` |
| Data lag when source idle | None — CLI flushes JSONL continuously | None while IDE runs; data lost on IDE exit if session never flushes |
| Reasoning vs output | `outputTotal = output + reasoning` (summed) | Independently reported (may overlap) |
| Total tokens formula | `input + output + reasoning` | `input + cacheRead + output + reasoning` (excludes `cacheWrite`) |

### Why this matters in practice

- **Data models differ; the shared UI renders them uniformly.** Antigravity's daily type carries a 5th field (`cacheWrite`) that Codex lacks, but the shared chart layer (`LocalUsageChartDayMetrics`) renders the **same 4 segments** (`uncached = input - cached`, `cached`, `output`, `reasoning`) for every provider — `cacheWrite` is excluded from the UI and kept as raw diagnostics. The historical risk was drawing bars from raw per-provider shapes; today only code that bypasses the shared metrics would misalign.
- **Total computation differs.** A naive `total = input + cached + output + reasoning` over-counts Codex by `cached` (because Codex's `input` already includes `cached`).
- **cacheWrite asymmetry.** Codex has no `cacheWrite` segment; the UI either hides the segment for Codex rows or renders 0.
- **Cross-provider sum**: only `input (uncached)`, `cacheRead/cached`, `output`, `reasoning` are comparable. `cacheWrite` is Antigravity-only.

### Recommended normalized abstraction (cross-provider view)

To compare or sum daily usage across both providers, normalize both into a single shape at the provider boundary. The model below is what `CodexFetcher` and `AntigravityLocalUsageScanner` should produce (or what a view-layer adapter should derive) before any aggregation. See `antigravity.md` for the full `NormalizedDailyUsage` definition.

**Codex → NormalizedDailyUsage mapping** (apply at the provider boundary, before persistence):

| From `DailyTokenUsage` | → `NormalizedDailyUsage` field |
|---|---|
| `inputTokens - cachedInputTokens` (floored at 0) | `uncachedInput` |
| `cachedInputTokens` | `cacheRead` |
| `0` | `cacheWrite` |
| `outputTokens` | `output` |
| `reasoningOutputTokens` | `reasoning` |
| `turns` | `turns` |
| `rounds` | `rounds` |

After normalization, cross-provider sum, average, and chart rendering can treat the two providers as a single data source.

> 拆分来源：由原 `spec/providers/codex.md` 按 Codex 本地 harness / client 职责拆分；本文件主要沿用其对应章节。
当前持久化缓存版本 **v3**：`ScannerIndexIO` 使用固定 9 位小数秒 ISO 日期，保留实际 Date 表示；旧秒级缓存一次性失效，从原始来源重建，避免 cold/warm 窗口边缘归属不同。具体契约见 `spec/local-usage-reconcile.md`。

> 核对基线：2026-11-10 · 代码 b89b867
