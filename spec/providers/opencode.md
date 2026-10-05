# OpenCode Local Usage — Provider Merge Spec

OpenCode is not a menu-bar provider. It is a shared local token ledger that can be
optionally merged into the Minimax, ChatGPT, Antigravity, GLM, and DeepSeek cards.

## Data source

| Item | Value |
|---|---|
| Database | `~/.local/share/opencode/opencode.db` |
| Table | `message` |
| Part table | `part` — optional, joined via `message.id`; only used by the minimax reasoning char split (very old databases have no such table, see below) |
| Included rows | `role = assistant`, non-null `providerID`, non-null `tokens`, positive token total |
| Cache | `~/Library/Application Support/LLM-monitor/token-monitor/opencode.json` |
| Daily window | Seven local calendar days, including today |

The scanner reads the following fields from each assistant message:

```text
data.providerID
data.modelID
data.parentID
data.tokens.input
data.tokens.output
data.tokens.reasoning
data.tokens.cache.read
data.tokens.cache.write
```

`tokens.input` is the uncached input amount. `cache.read` is kept as a separate
cache bucket. The displayed total is `input + cache.read + output + reasoning`;
`cache.write` is reported separately and is not included in the consumption total.

这也是统一 accounting contract：daily 的 `input` 已是 uncached input，sample 只为兼容
历史结构保存 cache-inclusive input；进入价格估算时再拆成 `Input` 与 `Cache read`。
`cacheWrite` 继续保留在 raw 诊断，但不进入统一图表、total 或价值。详见
[`spec/accounting.md`](../accounting.md)。

## Provider mapping and bindings

OpenCode merge is controlled by the schema-v2 `clientBindings[]` array in `config.json`.
The settings UI intentionally has no per-provider OpenCode toggles: the client binding is
the canonical source of truth, while `providers.<id>.mergeOpencodeUsage` is retained only
as a legacy compatibility field for older builds and migration. GLM defaults to enabled;
the other supported bindings default to disabled. Users who need a non-default value edit
`config.json` and save it; the directory watcher hot-reloads the binding.

| Card | OpenCode providerID | Missing-field default |
|---|---|---|
| Minimax Token Plan | `minimax-cn-coding-plan` | `false` |
| ChatGPT Plan | `openai` | `false` |
| Antigravity | `antigravity`, `google-antigravity`, `google-vertex`, or `google` (多个 alias 逐项相加合并成一帧) | `false` |
| GLM Coding Plan | `zhipuai-coding-plan` | `true` |
| DeepSeek | `deepseek` | `false` |

别名的事实源是 `ClientProviderBinding.defaultBindings` 的
`clientID: openCode` 条目（`Models/ClientIdentity.swift`），
`OpencodeLocalUsage.<x>ProviderID` 常量从那里导出。DeepSeek 行只有 `deepseek`
一个别名——`deepseek-official` / `deepseek-cn` / `deepseek-v4` 是 **DSH** 的路由
别名（`ClientID.dsh` 条目），不参与 OpenCode 分片归因。

The `minimax` providerID is intentionally excluded from the Minimax card; it is the
redundant OpenCode local-capability ledger and never contributes to that quota card. Its
rows are still read (and still get the reasoning char split below) — the exclusion only
keeps them out of the card merge.

When the matching `clientBindings[]` entry is disabled, the card receives only its existing
native/local data. When it is enabled, OpenCode values are added to the native values:

- daily `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `rounds`, and `turns`;
- quota-window token summaries (`prompts`, `rounds`, and token categories);
- ChatGPT's 5-hour / weekly daily token data.

ChatGPT 没有 per-source 的手工换算：合并发生在 `UsageProjectionKernel`，所有来源的 daily
都先归一成 `UnifiedDailyTokenUsage`（`input` = uncached，`cacheRead` / `cacheWrite`
独立成桶）再逐桶相加。Codex native 的 `DailyTokenUsage` 也通过 `LocalUsageDaily`
conformance 落进同一模型（`input = uncachedInputTokens`、`cacheRead = cachedInputTokens`），
所以「cached 是完整 input 的子集」这条不变量在求和后仍然成立。

## MiniMax reasoning fallback

`message.data.$.tokens.reasoning` is a real, independent bucket for most providers —
`deepseek` / `openai` / `zhipuai` all report values, and those rows are passed through
untouched. The minimax rows are the exception: measured `minimax` (7904 messages) and
`minimax-cn-coding-plan` (36 messages) both report `tokens.reasoning` as **always 0**,
while the `part` table holds the real thinking text (3860 reasoning parts, 3.18M chars).
For them the thinking is folded into the output bucket.

`OpencodeDBReader` therefore applies a three-stage decision whose formula is the shared
`Models/ReasoningCharSplit.swift` (`split(outputTokens:reasoningChars:visibleChars:)`),
identical to the ZCode provider slices, the MiniMax Code runtime, and DSH M3:

| Priority | Condition | Result |
|---|---|---|
| ① native | `tokens.reasoning > 0` | passed through unchanged (two independent columns, no reclassification) |
| ② char split | providerID lowercased prefix is `minimax` **and** the day / row carries reasoning text in `part` | `round(output × rchars / (rchars + vchars))` split into `reasoning` + `output`, conserving `reasoning + output == raw output` |
| ③ fallback | neither of the above | `reasoning = 0`, `output` unchanged |

The minimax gate is deliberate and not a generic rule: for every other provider a split
would overwrite a genuine native value. The SQL side narrows with `LIKE 'minimax%'` and
the Swift side re-checks the lowercased prefix (`needsCharSplit`) so both sides state the
same rule explicitly (SQLite `LIKE` is case-insensitive for ASCII by default).

Character buckets are identical to the ZCode slices — measured in `opencode.db`, a tool
part stores its arguments at the same path as ZCode:

| Bucket | Condition | Characters |
|---|---|---|
| reasoning | `$.type = 'reasoning'` | `$.text` |
| visible | `$.type = 'text'` | `$.text` |
| visible | `$.type = 'tool'` | `$.state.input` (tool arguments are model-generated output, equivalent to MiniMax Code's `tool_call_args`) |

Granularity: daily aggregation (`queryPerDay` + `queryMinimaxReasoningChars`) is a
**day-level** split — characters are grouped by provider × local calendar day; recent
samples (`querySamples`) are a **row-level** split — two correlated subqueries fetch the
part characters of that one message. The split conserves the bucket, so recomputing
`totalTokens` still yields the original `in + out + rsn + cacheRead`.

Very old `opencode.db` files have no `part` table at all (this reader never depended on it
before). `partTableExists()` checks `sqlite_master` before any character query, so the
char aggregation returns empty and the sample SQL degrades those two columns to constant
`0` — reasoning stays `0` and aggregation still succeeds, instead of failing at
`sqlite3_prepare` time on the missing table.

## Rounds and turns

- `rounds`: one assistant message with positive token usage, equivalent to one
  tokenized LLM call.
- `turns`: distinct `COALESCE(parentID, message.id)` values per local day. In normal
  OpenCode sessions, `parentID` identifies the user prompt, so multiple tool/LLM
  continuations under one prompt count as one turn.

The recent sample prompt IDs are namespaced before cross-source merging. This prevents
a native Scanner prompt ID and an OpenCode prompt ID with the same textual value from
being incorrectly deduplicated.

The scanner uses a two-layer concurrency model: `inFlightTask`/generation guards prevent
stale results from updating UI state, while the shared `AsyncMutex` serializes the complete
snapshot cache read/aggregate/write pipeline. It intentionally does not use
`lastCommittedGeneration`: OpenCode is one database producing one full snapshot, so it has no
per-source cache view whose late write could roll back another source. `AsyncMutex` is
cancellation-aware, and its non-reentrant behavior is documented in the shared concurrency spec.

## 7-day behavior

The scanner keeps seven local calendar days and rebases cached snapshots after midnight,
even when the database fingerprint has not changed. Missing days are zero-filled. The
shared chart displays four categories—Input, Cache, Output, Reason—and an R/T column
where R is rounds and T is turns.

## Refresh timing

OpenCode 不挂自己的独立 timer，也没有 quota 依赖：由 `ProviderRefreshScheduler` 每批
Provider 请求结算后的 `LocalUsageOrchestration.reconcile()` 驱动。启动首拍执行 Full Scan；
日历 / 时区失效走 hardFull；其余批次（自然日切换、手工 `refreshAll`、唤醒、定时）一律
是 dirty 模式的普通 reconcile——只有 OpenCode scanner 自己的 FSEvents watcher 或显式
失效把 source 标为 dirty 时才会重聚合，否则仅在指纹未变的情况下 rebase 7 天窗口。

> 决策依据：OpenCode 是“跨 provider 共享账本”。FSEvents 只负责把它标记为 dirty，
> 实际扫描仍挂在 Provider batch 之后；因此不需要也不存在 OpenCode 自己的独立触发配置。
> 模式语义见 [`spec/local-usage-reconcile.md`](../local-usage-reconcile.md)。

## Implementation map

| Responsibility | Source |
|---|---|
| Data model and provider slices | `Sources/LLM-monitor/Models/OpencodeLocalUsage.swift` |
| OpenCode sample promptID 命名空间 | `Sources/LLM-monitor/Models/UsageProjectionKernel.swift` 的 `UsageSampleNamespace.opencode`（旧 `OpencodeUsageMerger` 已吸收删除；卡片合并入口仍是 `ProviderStatus.usageProjection`） |
| SQLite reader | `Sources/LLM-monitor/Services/OpencodeDBReader.swift` |
| Scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/OpencodeUsageScanner.swift` |
| Merge 控制（无设置页开关） | `config.json` 的 `clientBindings[]`（唯一事实源；legacy config 由 `legacyClientBindings` 从 `ProviderConfig.mergeOpencodeUsage` 迁移） |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` and `QuotaViews.swift` |
| Regression tests | `Tests/LLMMonitorTests/OpencodeUsageTests.swift`（usageProjection 多 client 投影、命名空间与 reader 回归） |

> 核对基线：2026-10-05 · 代码 79dee29
