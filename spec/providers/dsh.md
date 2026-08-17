# DSH Local Usage — Provider Merge Spec

DSH (`dsh`) is DeepSeek Harness, a local agent harness that persists every session as
an append-only JSONL log. It is not a menu-bar provider. It is a shared local token
ledger that can be merged into the MiniMax, GLM, and DeepSeek cards, and is also shown
in its own Settings diagnostic tab.

## Data source

| Item | Value |
|---|---|
| Session root | `$DSH_HOME/sessions` (default `~/.dsh/sessions`) |
| Artifact | `<project-dir>/<session-id>/session.jsonl.zstd` (or `session.jsonl` when compression is disabled) |
| Format | Append-only JSONL; first line is a session header; later lines are session events or packed chunk rows |
| Decoder | Prefer `zstd` CLI; fall back to Node 22+ `node:zlib.zstdDecompressSync` |
| Cache | `~/.dsh/.token-monitor/` (fingerprint + versioned `index.json`) |
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
有效的原生 `reasoningTokens`（> 0），优先使用原生值；针对 `minimax` + `MiniMax-M3`，
当原生字段缺失或值不可用/为零时（nil 与显式 0 同等对待，以避免上游把缺失值写成 0
时漏掉估算），
scanner 在 DSH 内部读取同一 `assistant/message` 的 `reasoning`、`text`、`tool-call`
内容块，按字符比例估算 Reason，并保持 `Output + Reason = raw outputTokens`。其他模型、
其他 provider，或没有可用内容块时不猜比例：raw output 全放 `Output`，`Reason = 0`。
`cacheWrite` 只保留在 DSH 原始 daily 诊断字段，不进入统一 total、图表或金额。

The UI splits dsh's inclusive `outputTokens` into visible output and reasoning so the
existing four-category chart stays consistent:

```text
visibleOutput = outputTokens - reasoningTokens
reasoning     = reasoningTokens
output + reasoning == raw dsh outputTokens
```

## Provider mapping

Each dsh session records its provider/model in `request/context` events. The scanner
keeps the raw provider string and the Settings DSH tab shows every provider found.
Card merging uses these aliases:

| Card | dsh provider aliases |
|---|---|
| MiniMax Token Plan | `minimax`, `minimax-cn`, `minimax-cn-coding-plan` |
| GLM Coding Plan | `glm`, `zhipu`, `zhipuai`, `bigmodel`, `builtin:bigmodel-coding-plan` |
| DeepSeek | `deepseek`, `deepseek-official`, `deepseek-cn`, `deepseek-v4` |

Unlike OpenCode, DSH data is merged automatically when present. It is a native harness
ledger, not an optional external account ledger. The existing `mergeOpencodeUsage`
switch still controls whether OpenCode data is added on top.

## Rounds and turns

- `rounds`: one `assistant/message` with non-null usage.
- `turns`: distinct `data.turn` values per provider/day; dsh turns are the harness turn
  IDs, so one user prompt with many tool/LLM continuations counts as one turn.

The scanner deduplicates on `(sessionID, provider, turn, step)`; `provider` is an
explicit isolation dimension because one session can fan out to several providers,
while `seq` is deliberately not part of the key — a retried/replayed logical event
with a fresh `seq` must still count once. When `turn` or `step` is missing the event
has no stable harness identity, so `seq` (or the raw timestamp when `seq` is also
missing) becomes the fallback identity: distinct malformed events stay distinct
instead of collapsing into one bucket, and replays that keep the same `seq` still
deduplicate. Recent samples are namespaced as `dsh:<provider>:...` before merging.
Deduping skips only aggregation of the duplicated line; the parser always advances
to the next line, so a replayed event can never stall the scan.

## Scanner behavior

- Scans at app startup, and after MiniMax / GLM / DeepSeek quota refresh success.
- Uses file mtime + size fingerprints; if nothing changed it only rebases the cached
  seven-day window after midnight.
- Limits: 1,024 session files, 256 MiB of compressed input, 8 MiB per JSONL line, and
  at most 65,536 recent samples per provider within the last 8 calendar days (today
  plus the previous 7). Full scans and cached midnight rebases apply the same
  window/cap contract, so a fingerprint hit and a fresh scan produce equivalent
  recent samples. When the directory exceeds a file/byte cap, snapshots are
  ordered newest-first (mtime descending, path ascending as a stable tie-breaker)
  *before* the caps are applied, so the most recent sessions are always preferred; the
  scan logs a warning with selected/available counts whenever truncation happens.
- A corrupt or unreadable log does not abort the whole scan; it is skipped with a
  warning (path + error summary) and the next scan retries it. Failed files are
  excluded from the success fingerprint in `index.json`, so a lingering bad file
  never satisfies the cache and is re-attempted on every scan until it is fixed
  or removed.

## Implementation map

| Responsibility | Source |
|---|---|
| Data model and provider slices | `Sources/LLM-monitor/Models/DshLocalUsage.swift` |
| Field-level merge and format conversion | `Sources/LLM-monitor/Models/DshUsageMerger.swift` |
| JSONL/zstd scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/DshLocalUsageScanner.swift` |
| File discovery | `Sources/LLM-monitor/Services/FileManagerBox.swift` |
| Settings diagnostic tab | `Sources/LLM-monitor/Views/SettingsView.swift` |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` |
| Regression tests | `Tests/LLMMonitorTests/DshUsageTests.swift` |
