# DSH Local Usage — Provider Merge Spec

DSH (`dsh`) is DeepSeek Harness, a local agent harness that persists every session as
an append-only JSONL log. It is not a menu-bar provider. It is a shared local token
ledger that can be merged into the MiniMax, GLM, and DeepSeek cards. Its diagnostics
are shown under Settings → Clients alongside the other local clients.

## Data source

| Item | Value |
|---|---|
| Session root | `$DSH_HOME/sessions` (default `~/.dsh/sessions`) |
| Artifact | `<project-dir>/<session-id>/session.jsonl.zstd`（`*.jsonl.zst` 同等识别；关闭压缩时为 `session.jsonl`） |
| Format | Append-only JSONL; first line is a session header; later lines are session events or packed chunk rows |
| Decoder | Prefer `zstd -q -d -c` CLI (`/opt/homebrew/bin`, `/usr/local/bin`); fall back to Node's `zlib.createZstdDecompress()` streaming, then throw `unavailable` |
| Cache | `~/Library/Application Support/LLM-monitor/token-monitor/dsh.json`（`DshCacheIndex`，当前 `version = 5`：文件指纹数组 + last-good snapshot + calendar signature） |
| Daily window | Seven local calendar days, including today |

The scanner reads provider-billed usage from every `assistant/message` event:

```text
data.usage.inputTokens
data.usage.cacheReadTokens
data.usage.cacheWriteTokens   // optional, default 0
data.usage.outputTokens       // includes reasoning
data.usage.reasoningTokens    // subdivision of outputTokens
```

`inputTokens` is the uncached prompt input. `cacheReadTokens` is a separate cache
bucket. `cacheWriteTokens` is reported separately and is not included in the displayed
consumption total. dsh's own `tokenUsage` projection uses the same buckets.

统一估算契约见 [`spec/accounting.md`](../accounting.md)。DSH raw input 是 uncached input；
scanner 将 `outputTokens`（含 reasoning）拆成互斥的 `Output` 和 `Reason`。如果日志有
有效的原生 `reasoningTokens`（> 0），优先使用原生值（并按 `min(nativeReasoning, output)`
钳位，保证 `Reason ≤ raw outputTokens`，避免异常账单值把守恒关系撑破）；针对 `minimax` +
`MiniMax-M3`（provider 精确匹配 `minimax` / `minimax-cn` / `minimax-cn-coding-plan`，model
叶子名匹配 `m3` / `minimax-m3` / `minimax-m3-*`），
当原生字段缺失或值不可用/为零时（nil 与显式 0 同等对待，以避免上游把缺失值写成 0
时漏掉估算），
scanner 在 DSH 内部读取同一 `assistant/message` 的 `reasoning`、`text`、`tool-call`
内容块（block type 小写化并把 `_` 归一为 `-`；`tool-call` 累加的是 `arguments` 的字符数，
对应 MiniMax Code 的 `tool_call_args` 桶），按字符比例估算 Reason，并保持
`Output + Reason = raw outputTokens`。比例公式本身
已收敛到共享工具 `Sources/LLM-monitor/Models/ReasoningCharSplit.swift` 的
`split(outputTokens:reasoningChars:visibleChars:)`（字符累加用 `SaturatingArithmetic`，
`isMiniMaxM3` 门控不变），
与 MiniMax Code runtime、ZCode 非智谱 provider 分片、OpenCode `minimax` 分片、Agy 同一实现，
因此也顺带获得 `Int.max` 饱和保护；估算行为本身不变。其他模型、
其他 provider，或没有可用内容块时不猜比例：raw output 全放 `Output`，`Reason = 0`。
`cacheWrite` 只保留在 DSH 原始 daily 诊断字段，不进入统一 total、图表或金额。

拆分是**事件级**的（usage 与内容块同属一个 `assistant/message` 事件），这正是 DSH 相对
MiniMax Code 的优势——后者必须在自己的两张表之间按天对齐（见
[`minimax.md`](./minimax.md) 的 "P1-1 v2 字符聚合风险"）。

The UI splits dsh's inclusive `outputTokens` into visible output and reasoning so the
existing four-category chart stays consistent:

```text
visibleOutput = outputTokens - reasoningTokens
reasoning     = reasoningTokens
output + reasoning == raw dsh outputTokens
```

## Provider mapping

Each dsh session records its provider/model in `request/context` events. The scanner
keeps the raw provider string (trimmed; empty → `unknown`) and the Settings → Clients
view shows every provider found.

`DshHarnessFrames.frames(from:)` emits one frame per provider key with an **empty**
`quotaProviderID` — card attribution is not decided here. It is resolved uniformly in
`UsageProjectionKernel.project` against the `clientBindings[]` registry, so any dsh
provider key (including ones a future harness adds) routes through the same alias
table rather than a dsh-local special case. A key no enabled dsh binding claims
resolves to the empty group and is dropped from the cards; `AppState.applyDshUsage`
logs a warning listing the unclaimed provider IDs and the registered aliases so a
hand-edited `sourceProviderAliases` typo does not fail silently.

The alias table below is the shipped default (all three bindings `enabled: true`) from
`ClientProviderBinding.defaultBindings` — the array literals there are the single
source of truth, and a binding the user sets to `enabled: false` is treated as
deliberately unclaimed (no warning):

| Card | dsh provider aliases |
|---|---|
| MiniMax Token Plan | `minimax`, `minimax-cn`, `minimax-cn-coding-plan` |
| GLM Coding Plan | `glm`, `zhipu`, `zhipuai`, `bigmodel`, `builtin:bigmodel-coding-plan`, `account:bigmodel-individual-coding-plan` |
| DeepSeek | `deepseek`, `deepseek-official`, `deepseek-cn`, `deepseek-v4` |

Alias matching is case-insensitive and substring-based (`==` or `contains`), not exact.

Unlike OpenCode, DSH data is merged automatically when present. It is a native harness
ledger, not an optional external account ledger — the three dsh bindings ship enabled,
whereas several OpenCode bindings ship `enabled: false` because an OpenCode install is
an optional third-party account. Disabling a dsh binding is still possible through
`clientBindings[]`; OpenCode is independently controlled the same way.

## Rounds and turns

- `rounds`: one `assistant/message` event with non-null `usage` **and** a non-null
  `time`; without a timestamp the line cannot be bucketed into a local day and is
  dropped before aggregation.
- `turns`: distinct `(sessionID, data.turn)` pairs per provider/day; dsh turns are the
  harness turn IDs, so one user prompt with many tool/LLM continuations counts as one
  turn. Events with no `turn` fall back to an `event:<sessionID>:<seq>` key, which is
  unique per event and therefore counts as one turn each.

The scanner deduplicates on `(sessionID, provider, turn, step)`; `provider` is an
explicit isolation dimension because one session can fan out to several providers,
while `seq` is deliberately not part of the key — a retried/replayed logical event
with a fresh `seq` must still count once. When `turn` or `step` is missing the event
has no stable harness identity, so `seq` (or the raw timestamp when `seq` is also
missing) becomes the fallback identity: distinct malformed events stay distinct
instead of collapsing into one bucket, and replays that keep the same `seq` still
deduplicate. Each retained sample carries `sourceProviderID = "dsh:<provider>"` (the
provenance marker) and a `dsh:<sessionID>:turn:<turn>` / `dsh:<sessionID>:event:<seq>:<ts>`
`promptID`, so dsh rows stay in a single `dsh:` namespace before card merging.
Deduping skips only aggregation of the duplicated line; the parser always advances
to the next line, so a replayed event can never stall the scan.

## Scanner behavior

- Reconciled after each settled Provider batch; the first reconcile and each natural-day
  rollover run a Full Scan, while later reconciles only run when the DSH scanner's
  source-owned FSEvents watcher marks the sessions root dirty. The watcher is stopped
  during scanning and independently rebuilt after the scan settles. `.hardFull`
  (explicit user retry / system clock change) is the only mode allowed to bypass the
  provider's own fingerprint cache.
- Uses file mtime + size fingerprints (version 5 of `DshCacheIndex`); if nothing
  changed it only rebases the cached seven-day window after midnight. A calendar
  signature change forces a re-parse so day buckets are rebuilt under the current
  timezone.
- When files change, an in-memory cache retains parsed results for the newest 256
  selected files. Older selected files are still parsed and included, but cannot
  evict that hot set. Adding a new session first removes entries outside the new
  hot set, so it does not cause a chain of cache misses across unchanged history.
- Limits: 1,024 session files, 1 GiB of input, 8 MiB per JSONL line, and
  at most 65,536 recent samples per provider within the last 8 calendar days (today
  plus the previous 7). Full scans and cached midnight rebases apply the same
  window/cap contract, so a fingerprint hit and a fresh scan produce equivalent
  recent samples. When the directory exceeds a file/byte cap, snapshots are
  ordered newest-first (mtime descending, path ascending as a stable tie-breaker)
  *before* the caps are applied, so the most recent sessions are always preferred; the
  scan logs a warning with selected/available counts whenever truncation happens.
  A budget-truncated scan is a complete scan of a deliberately reduced file set, so it
  publishes normally and sets `DshLocalUsage.isTruncated` — the 7-day hover view and
  Settings → Clients then label the numbers as a newest-first subset.
- Parsing streams from disk with a line buffer bounded by the 8 MiB line cap — plain
  JSONL and streamed archive decompression alike never load a whole file into memory;
  a single session's decompressed archive output is capped at 1 GiB.
- A corrupt or unreadable log does not abort the whole scan: `aggregateFiles` isolates
  the bad file, logs a warning (path + error summary), and keeps aggregating the rest.
  But a round that saw **any** failed file never becomes the new last-good: the scanner
  returns the previous cached snapshot re-based to today and marked
  `isPartial = true`, and leaves `index.json` (fingerprints *and* snapshot) completely
  untouched. Advancing only the successful fingerprints would let a later deletion
  falsely hit an aggregate that was missing the failed file, so the whole round is
  treated as not-yet-done. `partial` is never persisted (`saveIndex` asserts it), and
  `scanResultIsComplete` routes it through the freshness channel instead, so the next
  reconcile retries the file until it is fixed or removed.
- A file that cannot even be `stat`ed is handled one level earlier, before any parsing:
  the round returns the re-based last-good snapshot as partial without touching the
  index, because "cannot stat" is not evidence of deletion. The escape hatch is an
  explicit `.hardFull` rescan, which ignores the stat-failure memory and rebuilds from
  whatever is currently stat-able.

## Implementation map

| Responsibility | Source |
|---|---|
| Data model and provider slices | `Sources/LLM-monitor/Models/DshLocalUsage.swift`（`DshDailyUsage` 是 `Models/LocalDailyTokenUsage.swift` 里 `LocalDailyTokenUsage` 的 typealias） |
| Field-level merge and format conversion | `Sources/LLM-monitor/Models/UsageProjectionKernel.swift`（DSH 帧适配 `DshHarnessFrames` + `UsageProjectionKernel.project`，旧 `DshUsageMerger` 已吸收删除；`dsh:dsh:` 双层 promptID 前缀随之清理为单层） |
| Provider alias bindings | `Sources/LLM-monitor/Models/ClientIdentity.swift`（`ClientProviderBinding.defaultBindings` 里 `clientID == ClientID.dsh` 的三条，别名字面量是归属解析的唯一事实源） |
| JSONL/zstd scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/DshLocalUsageScanner.swift` |
| File discovery | `Sources/LLM-monitor/Services/Infra/FileManagerBox.swift`（目录遍历是通用的；`session.jsonl` / `*.jsonl.zstd` / `*.jsonl.zst` 的筛选规则留在 DSH scanner 里） |
| Retention window constant | `Sources/LLM-monitor/Models/LocalUsageRetentionWindow.swift`（`days = 8`，落盘口径；展示面仍是 7 天） |
| Client diagnostics | `Sources/LLM-monitor/Views/SettingsClientsPane.swift` |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` |
| Regression tests | `Tests/LLMMonitorTests/DshLocalUsageScannerTests.swift`, `DshHarnessFramesTests.swift`, `ScannerRetentionContractTests.swift` |

> 核对基线：2026-10-04 · 代码 d6396fd
