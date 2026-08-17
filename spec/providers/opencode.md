# OpenCode Local Usage — Provider Merge Spec

OpenCode is not a menu-bar provider. It is a shared local token ledger that can be
optionally merged into the Minimax, ChatGPT, Antigravity, GLM, and DeepSeek cards.

## Data source

| Item | Value |
|---|---|
| Database | `~/.local/share/opencode/opencode.db` |
| Table | `message` |
| Included rows | `role = assistant`, non-null `providerID`, non-null `tokens`, positive token total |
| Cache | `~/.local/share/opencode/.token-monitor/` |
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

## Provider mapping and switches

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
| Antigravity | `antigravity`, `google-antigravity`, `google-vertex`, or `google` | `false` |
| GLM Coding Plan | `zhipuai-coding-plan` | `true` |
| DeepSeek | `deepseek`, `deepseek-official`, `deepseek-cn`, or `deepseek-v4` | `false` |

The `minimax` providerID is intentionally excluded from the Minimax card; it is the
redundant OpenCode local-capability ledger and never contributes to that quota card.

When the matching `clientBindings[]` entry is disabled, the card receives only its existing
native/local data. When it is enabled, OpenCode values are added to the native values:

- daily `input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`, `rounds`, and `turns`;
- quota-window token summaries (`prompts`, `rounds`, and token categories);
- ChatGPT's 5-hour / weekly daily token data.

For ChatGPT, OpenCode's uncached `input` is converted to the Codex daily model as
`inputTokens = input + cacheRead` and `cachedInputTokens = cacheRead` before addition.
This preserves the Codex model's invariant that cached input is a subset of complete
input.

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

OpenCode **不挂自己的独立 timer**,扫描由 consumer provider 的 quota 刷新触发:
- 应用启动时主动扫一次(让设置页诊断和已有 GLM/minimax/DeepSeek 卡片尽早拿到本地历史)
- minimax 主 quota 刷新成功时(`refreshProviderDirectly` 在成功路径触发 `triggerOpencodeUsageScan`)
- GLM 主 quota 刷新成功时(同上,加 native ZCode + opencode 双扫描)
- Codex / Antigravity 主 quota 刷新成功时(同上路径)

**实际刷新频率 ≈ min(各 consumer provider 的 refreshIntervalSeconds)**。OpenCode 设置页
"刷新时机" 一行明确展示这个触发逻辑。如需更密集的 OpenCode 扫描,加快任一 consumer
provider 的刷新间隔即可——不需要也不存在 OpenCode 自己的独立配置项。

> 决策依据:OpenCode 是"跨 provider 共享账本",不是用户主动查询的服务。给它一个独立
> timer 会导致 consumer 还在静默时 OpenCode 已经扫了,反而造成"看 OpenCode 卡片
> 的 prompt 时间"和"看各 quota 卡片的 prompt 时间"对不上的诡异感。
> piggyback consumer provider 是最自然的同步点。

## Implementation map

| Responsibility | Source |
|---|---|
| Data model and provider slices | `Sources/LLM-monitor/Models/OpencodeLocalUsage.swift` |
| OpenCode sample promptID 命名空间 | `Sources/LLM-monitor/Models/OpencodeUsageMerger.swift`（卡片合并入口是 `ProviderStatus.usageProjection`，历史 `merge*` 函数已删除） |
| SQLite reader | `Sources/LLM-monitor/Services/OpencodeDBReader.swift` |
| Scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/OpencodeUsageScanner.swift` |
| Merge 控制（无设置页开关） | `config.json` 的 `clientBindings[]`（唯一事实源；legacy config 由 `legacyClientBindings` 从 `ProviderConfig.mergeOpencodeUsage` 迁移） |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` and `QuotaViews.swift` |
| Regression tests | `Tests/LLMMonitorTests/OpencodeUsageTests.swift`（usageProjection 多 client 投影、命名空间与 reader 回归） |
