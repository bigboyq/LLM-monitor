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

The scanner deduplicates on `(sessionID, turn, step)` so a retried/replayed event does
not double count. Recent samples are namespaced as `dsh:<provider>:...` before merging.

## Scanner behavior

- Scans at app startup, and after MiniMax / GLM / DeepSeek quota refresh success.
- Uses file mtime + size fingerprints; if nothing changed it only rebases the cached
  seven-day window after midnight.
- Limits: 256 session files, 256 MiB of compressed input, 8 MiB per JSONL line, and
  4,096 recent samples per provider.
- A corrupt or unreadable log does not abort the whole scan; it is skipped and the next
  scan retries it.

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
