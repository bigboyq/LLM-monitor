# Codex / ChatGPT Plan — Provider Spec

Provider id: `codex_chatgpt`

Implementation: `Sources/LLM-monitor/Fetchers/CodexFetcher.swift`

This provider reads the local Codex authentication file and calls ChatGPT backend quota endpoints. It does not store OpenAI or ChatGPT tokens in `LLM-monitor`'s own config file.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `~/.codex/auth.json` by default, or `CODEX_HOME/auth.json` |
| Token refresh | Not implemented; assumes Codex CLI/Desktop has already refreshed auth |
| Main endpoint | `GET https://chatgpt.com/backend-api/wham/usage` |
| Reset credits endpoint | `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` |
| Model rows | One synthetic model: `chatgpt_plan` |
| Reset credits | Parsed and displayed when entries exist |
| Plan label | Parsed from `id_token` JWT when available |
| Local usage details | Aggregated from local Codex session logs |

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "codex_chatgpt": {
      "enabled": true,
      "refreshIntervalSeconds": 60
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `refreshIntervalSeconds` | Optional independent refresh interval. |
| `displayName` | Optional card title override. |
| `authPath` | Optional custom auth location. Accepts either an `auth.json` file path or its parent directory. |

## Auth File

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
| `tokens.id_token` | Optional JWT source for `chatgpt_plan_type` |

`refresh_token` is not used.

## Request Headers

Both endpoints use the same auth headers:

```http
Authorization: Bearer <access_token>
OpenAI-Beta: codex-1
originator: Codex Desktop
ChatGPT-Account-ID: <account_id>
```

`ChatGPT-Account-ID` is only sent when `account_id` is present and non-empty.

## Usage Endpoint

```http
GET https://chatgpt.com/backend-api/wham/usage
```

Expected response shape:

```json
{
  "rate_limit": {
    "primary_window": {
      "used_percent": 46,
      "limit_window_seconds": 18000,
      "reset_at": "2026-07-05T17:00:00Z"
    },
    "secondary_window": {
      "used_percent": 64,
      "limit_window_seconds": 604800,
      "reset_at": "2026-07-08T17:00:00Z"
    }
  }
}
```

Current parser behavior:

| Response field | Model field |
|---|---|
| `primary_window.used_percent` | `intervalRemainingPercent = clamp(100 - used, 0...100)` |
| `primary_window.reset_at` | `intervalResetsAt` |
| `primary_window.limit_window_seconds` | local 5-hour usage window start = `reset_at - seconds` |
| `secondary_window.used_percent` | `weeklyRemainingPercent = clamp(100 - used, 0...100)` |
| `secondary_window.reset_at` | `weeklyResetsAt` |
| `secondary_window.limit_window_seconds` | local weekly usage window start = `reset_at - seconds` |

`reset_at` can be:

- ISO-8601 string
- Unix timestamp number, treated as seconds

If `rate_limit` or its primary window is missing/invalid, parsing fails instead of fabricating a
healthy quota. A missing or invalid secondary window maps to `weeklyStatus = .absent`; a valid
secondary window remains `.present` even when its remaining percentage is `0%`.

## Local Usage Aggregation

### Accounting contract

Codex 的 raw `inputTokens` 是包含 cache-read 的完整输入，`cachedInputTokens` 是其子集；
它们的原始字段语义保持不变。`LocalUsageDaily` adapter 只在统一层计算
`Input = inputTokens - cachedInputTokens`，并单独保留 `Cache read`。Codex 的 output 和
reasoning 是独立字段，直接映射为 `Output` / `Reason`。统一 total 与价格不包含
`cacheWrite`（Codex 本身也不提供该字段）。完整矩阵见 [`spec/accounting.md`](../accounting.md)。

### Architecture note

Codex local usage intentionally does not use the Minimax/Antigravity three-layer scanner model.
It parses the CLI's append-only JSONL sessions on demand and keeps parsed events in an in-memory
cache keyed by file fingerprint; there is no provider-owned incremental SQLite index whose writes
could race during cancel-and-rescan. Cancellation checks at scan boundaries plus the shared local
usage lifecycle/generation guard are therefore sufficient, and a separate `lastCommittedGeneration`
layer or dedicated cancel-and-rescan persistence test would not describe the Codex data path.

The provider also computes local usage summaries from:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`

The application uses the same local aggregation rules directly in
`CodexLocalUsageScanner`:

| UI hover | Time window | Aggregation |
|---|---|---|
| `5h` | `intervalResetsAt - 5h` to `intervalResetsAt` | prompts, rounds, input, cached, output, reasoning output |
| `周` | `weeklyResetsAt - 7d` to `weeklyResetsAt` | same fields over the weekly window |
| `ChatGPT Plan` row | latest completed prompt only | `Last Prompt` summary |

Rules:

- `prompts` counts unique `task_started.turn_id` values inside the window
- `rounds` counts matching `token_count` events
- token totals sum `last_token_usage.*`
- `Last Prompt` is the most recent `task_complete` turn plus all `token_count` events between its `task_started` and `task_complete`

## Reset Credits Endpoint

```http
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

Expected response shape:

```json
{
  "available_count": 2,
  "total_earned_count": 3,
  "credits": [
    {
      "id": "RateLimitResetCredit_...",
      "status": "available",
      "expires_at": "2026-07-18T00:47:58.918242Z",
      "granted_at": "2026-07-08T00:47:58.918242Z",
      "reset_type": "codex_rate_limits",
      "title": "Full reset (Weekly + 5 hr)",
      "description": "..."
    }
  ]
}
```

Current parser behavior:

| Response field | Model field |
|---|---|
| `available_count` | `ResetCreditsInfo.serverAvailableCount` |
| `total_earned_count` | `ResetCreditsInfo.totalEarnedCount` |
| `credits[]` | `ResetCreditEntry[]` |
| `credits[].expires_at` | `ResetCreditEntry.expiresAt` |
| `credits[].granted_at` | `ResetCreditEntry.grantedAt` |
| `credits[].reset_type` | `ResetCreditEntry.resetType` |

Date parsing accepts:

- ISO-8601 with fractional seconds
- ISO-8601 without fractional seconds
- Unix seconds
- Unix milliseconds

If `credits` is missing, the provider returns an empty entries array. If `credits` is empty but `available_count > 0`, the parser synthesizes `available` entries so the UI can still show a remaining count.

Reset-credit fetch failure does not fail the provider refresh. The fetcher logs a warning and returns the quota model with `resetCredits = nil`.

`fetchResetCredits` does not log raw response bodies (`includeBodyInError: false`); only summary count info is logged.

### Refresh cadence & freshness (reset credits)

`fetchResetCredits` only runs on `.full` refresh — i.e. app startup, manual refresh
(header button / card context menu / menu-bar right-click), menu open when a `.ready`
provider exists, and the scheduler's **periodic full**. The scheduler inserts one `.full`
every `periodicFullEveryN` (default 20) `.background` cycles, so at the default 300 s interval
reset credits auto-refreshes roughly every `20 × 300 s ≈ 100 min` without any manual action.
`.background` cycles intentionally skip the reset-credits request.
**Why N=20 (not a separate timer)**: Codex reset credits are day-level events — they
don't change every refresh, so a dedicated full-fetch timer that fires on its own schedule
would be wasted work. Instead, the scheduler piggybacks on the existing background
cycle and counts up; every Nth iteration is upgraded to `.full`. N=1 would mean "every
cycle is full" (heavy given how rarely reset credits change). N=60/100 would push the
full gap to hours-to-half-a-day — by the time the user notices a stale reset credit
and clicks refresh, several background cycles have already been wasted on fetches that
never bothered to look. N=20 at the default 300 s interval lands at ~100 min, which is
"often enough to feel live, rarely enough to stay cheap".

Reset credits carries its own freshness metadata (`fetchedAt` / `lastAttemptFailed`), separate
from the main `QuotaInfo.fetchedAt`:

- `.background` skip keeps the previous value and its original `fetchedAt` / failure flag — it
  is **not** treated as a failure and never advances the main provider `failureCount`.
- A `.full` whose reset-credits sub-request fails keeps the previous value and marks
  `lastAttemptFailed`, so the row shows "可能过期" immediately.
- Recovery on the next successful `.full` clears the flag and updates `fetchedAt`.
- As a safety net, the row also shows "可能过期" when the data age exceeds
  `3 × (periodicFullEveryN × refreshInterval)` (default ≈ 5 h), meaning several periodic-full
  cycles were missed. Normal operation never reaches this (data refreshes every ~100 min).

## QuotaInfo Mapping

Successful fetch returns:

```swift
QuotaInfo(
    models: [ModelQuota(modelName: "chatgpt_plan", ...)],
    resetCredits: resetCredits,
    planLabel: planLabel,
    codexUsageDetails: localUsageDetails,
    fetchedAt: Date()
)
```

`ModelQuota` values:

| Field | Value |
|---|---|
| `modelName` | `chatgpt_plan` |
| `displayName` | `ChatGPT Plan` via `ModelQuota.displayName` |
| `intervalTotalCount` / `intervalUsageCount` | `0` |
| `weeklyTotalCount` / `weeklyUsageCount` | `0` |
| `intervalStatus` / `weeklyStatus` | `.present` for each parsed window; `.absent` when the window is missing |
| remaining percents | `100 - used_percent`, clamped to `0...100` |

An exhausted window (`used_percent = 100`) remains `.present` and is rendered as `0%`.

`planLabel` is parsed from this JWT payload object when present:

```json
{
  "https://api.openai.com/auth": {
    "chatgpt_plan_type": "team"
  }
}
```

The value is capitalized before display/storage, for example `team` becomes `Team`.

## Ready-State Logic

`ProviderKind.codexChatGpt.usesExternalAuth == true`.

Current `AppState` logic:

1. During `rebuildStatuses()`, external-auth providers are probed with `hasLocalAuth()`.
2. Codex fetch runs with `CodexFetcher(authPath: pc.authPath)`.
3. `authPath` now supports either `~/.codex/auth.json` or `~/.codex`.
4. If auth is missing, state becomes `.notConfigured("外部 auth 缺失：~/.codex/auth.json")`.

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `ChatGPT Plan` unless overridden |
| `iconSystemName` | `sparkles` |
| `accentColor` | `chatgpt` mapped to green |

Quota rows:

```text
ChatGPT Plan                              5h × 6 = 周
5h <remaining>%  周 <remaining>%  [weekly bar in 6 segments]  <weekly reset time>
```

Hover details:

- Hover `ChatGPT Plan` row: `Last Prompt`
- Hover the combined quota line: local short-window usage first, then a divider, then local weekly usage

If `secondary_window` is absent (for example, a promotion temporarily removes the 5-hour
limit), the app displays the single `primary_window` using its actual `limit_window_seconds` label
and only aggregates local usage for that window. It does not synthesize a second window or apply
the `5h × 6` presentation.

Reset credits, when present:

```text
重置卡数量：<availableCount>
最早过期：yyyy-MM-dd HH:mm
```

The UI still does not currently display `planLabel`.

## Errors

The current fetcher uses shared `QuotaError` messages rather than provider-specific user copy.

| Situation | Current error |
|---|---|
| `auth.json` unreadable | `网络错误：无法读取 <path>: <system error>` |
| `auth.json` invalid JSON | `解析失败：auth.json 不是合法 JSON` |
| missing `tokens` | `解析失败：auth.json 缺 tokens` |
| missing `tokens.access_token` | `未配置 API Key` |
| non-HTTP response | `响应格式无效` |
| HTTP non-2xx | `HTTP <status>: <body preview>` |
| malformed usage JSON | `解析失败：usage 不是合法 JSON` |
| malformed reset-credit JSON | warning only, quota still succeeds |

Potential improvement: map common HTTP codes to clearer actions, especially 401 requiring Codex re-login and 429 rate limiting.

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

- **UI stacked bars render differently.** Codex has 4 segments (`uncached = input - cached`, `cached`, `output`, `reasoning`); Antigravity has 5. Drawing them with the same `totalSegments` assumption misaligns colors and widths.
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

---

## Open Questions

- Should missing `rate_limit` produce an empty model list, a not-configured state, or the current `100%` fallback?
- Should the UI show `planLabel` near the card title?
