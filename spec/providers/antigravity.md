# Antigravity — Provider Spec

Provider id: `antigravity`

Implementation: `Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift` + `Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift`

This provider does not call Google quota APIs with a saved OAuth access token. Instead, it reuses the locally authenticated Antigravity backend — the IDE's `language_server` or the `agy` CLI — discovers its local HTTPS port, and reads quota + account info + per-session token usage from local RPC endpoints.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | Running Antigravity IDE **or** agy CLI; their local authenticated language_server |
| Direct OAuth token use | Avoided; stale `state.vscdb` tokens may return `401` |
| Process discovery | `pgrep -fal language_server` (IDE) + `pgrep -fal agy` / `antigravity-cli` (CLI), command-line keyword filter |
| CSRF | IDE requires `--csrf_token`; CLI does not require any |
| Main local RPCs | `GetUserStatus` (account + tier), `GetLoadCodeAssist` (tier fallback), `RetrieveUserQuotaSummary` (quota), `GetCascadeTrajectoryGeneratorMetadata` (per-event token usage) |
| Account fields | `userStatus.email`, `userStatus.userTier.name`, `userStatus.planStatus.planInfo.{planDisplayName,displayName,productName,planName,planShortName}` |
| Model groups | `Gemini Models`, `Claude and GPT models` |
| Window types | `5h`, `weekly` |
| Reset credits | Not used |
| **Local token usage history** | ✅ Pure RPC architecture: per-event input / output / cacheRead / cacheWrite / reasoning, aggregated to last 7 local days, persisted to `~/.gemini/antigravity/.token-monitor/` |
| Configurable install path | Removed — fully auto-discovered via process scan |

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "antigravity": {
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

`authPath`, `apiKey`, and `serverPath` are not used.

> **Note**: `serverPath` was removed in v1.2.0. Old config files that still carry the field decode fine — the JSON key is silently ignored.

## Local Requirements

For this provider to work:

1. Antigravity IDE **or** agy CLI must already be running.
2. The user must already be logged in.
3. The local language server (embedded in either backend) must be healthy and listening on localhost.
4. The conversation directory is optional: without local session files, quota/account data still works and local-history totals remain empty.

If any of those conditions fail, `AppState` surfaces:

```text
未发现 Antigravity IDE 或 agy CLI 进程，请先启动 Antigravity 并完成登录
```

or, if a process is found but no port:

```text
发现 Antigravity 进程但未监听本地端口，请确认 IDE 或 CLI 已完成登录
```

or, if process + port are healthy but `~/.gemini/antigravity-ide/conversations/` is empty (CLI-only user with no IDE activity):

```text
今日用量：扫描中…   (in the footer line — hovering the title shows scan state)
```

## Discovery Flow

The fetcher scans for **two** kinds of Antigravity backends and picks the best one (IDE first, then CLI):

### 1. `pgrep -fal language_server` (IDE candidates)

For each match, run `classify(command:)`:

- Must contain a known Antigravity IDE `language_server` binary as a basename (path-anchored, followed by whitespace or end-of-string). Known binaries (see `AntigravityFetcher.knownLanguageServerBinaries`):
  - `language_server` — `Antigravity.app`（无空格，独立应用），路径示例 `/Applications/Antigravity.app/Contents/Resources/bin/language_server`
  - `language_server_macos_arm` — `Antigravity IDE.app`（带空格，独立应用），路径示例 `/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm`
  - 兜底：仍允许 `language[-_]server<._多段后缀>` 的任意后缀匹配（向后兼容未来新增的架构/平台后缀，如 `language_server_macos_x64` / `language_server_linux_arm64`）
- The lowercased command must also contain `antigravity` (typically via `--app_data_dir <antigravity path>` or the install path `/Applications/Antigravity.app/...` / `/Applications/Antigravity IDE.app/...`)
- IDE processes must additionally have `--csrf_token` in their command line; otherwise the candidate is rejected (tokenless matches are not used — a later valid one is preferred)

### 2. `pgrep -fal agy` / `antigravity-cli` (CLI candidates)

For each match, run `isAntigravityCliBinary(lowerCommand)`:

- Matches `agy`, `agy.exe`, `antigravity-cli`, `antigravity_cli`
- Path-anchored: must appear at start of command or after `/` or `\` (so `stragy` / `imagery` never match)
- CLI does **not** require `--csrf_token`

### 3. Sort + port discovery

Candidates are sorted:

1. `ide` before `cli` (IDE typically has the full quota)
2. Within a kind, by `processRank()`: `workspace + lsp + csrf` > `lsp + csrf` > `csrf` > other
3. Within a rank, by PID (lower first)

For each candidate, `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` finds the first `127.0.0.1:<port>` listening socket. The first candidate that exposes such a port wins.

The chosen `ServerInfo` carries the CSRF token (if any) and the discovered `kind` for diagnostics.

## Local RPCs

All quota / account calls run in parallel via `async let`. The non-quota calls use `postOptional` — they return `nil` on failure (legacy servers may not support `GetUserStatus` or `GetLoadCodeAssist`) and the quota call is the only fatal one.

```text
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/GetUserStatus
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/GetCascadeTrajectoryGeneratorMetadata
```

Required request headers:

```http
Content-Type: application/json
x-codeium-csrf-token: <csrf_token>   # only set when server has one
```

Bodies:

- `GetUserStatus`: `{ "metadata": { "ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en" } }`
- `GetLoadCodeAssist`, `RetrieveUserQuotaSummary`, `GetCascadeTrajectoryGeneratorMetadata`: `{}` / `{ cascadeId: "<sessionId>" }`

The session trusts localhost TLS for `127.0.0.1` and `localhost`.

## Local RPC Response Shapes

### GetUserStatus

Used for account metadata.

Observed response shape:

```json
{
  "userStatus": {
    "email": "alice@example.com",
    "userTier": { "name": "Free" },
    "planStatus": {
      "planInfo": {
        "planDisplayName": "Pro Max",
        "displayName": "Pro Plan",
        "productName": "Antigravity Pro",
        "planName": "pro-monthly",
        "planShortName": "Pro"
      }
    }
  }
}
```

Tier name resolution (first non-empty wins):

1. `userStatus.userTier.name` (trimmed)
2. `userStatus.planStatus.planInfo.planDisplayName` (trimmed)
3. `userStatus.planStatus.planInfo.displayName`
4. `userStatus.planStatus.planInfo.productName`
5. `userStatus.planStatus.planInfo.planName`
6. `userStatus.planStatus.planInfo.planShortName`
7. `GetLoadCodeAssist.currentTier.name` (fallback for older servers)

Empty / whitespace-only strings are treated as missing at every step.

Email is `userStatus.email` trimmed; treated as missing if empty/whitespace.

| Response field | Model field |
|---|---|
| `userStatus.email` | `QuotaInfo.accountEmail` |
| `userStatus.userTier.name` (or fallbacks above) | `QuotaInfo.planLabel` |

### GetLoadCodeAssist

Used for tier name fallback when `GetUserStatus` is missing or incomplete.

Observed response shape:

```json
{
  "response": {
    "currentTier": {
      "id": "free-tier",
      "name": "Free"
    }
  }
}
```

| Response field | Model field |
|---|---|
| `response.currentTier.name` | `QuotaInfo.planLabel` (only if no value from `GetUserStatus`) |

### RetrieveUserQuotaSummary

Observed response shape:

```json
{
  "response": {
    "groups": [
      {
        "displayName": "Gemini Models",
        "buckets": [
          {
            "bucketId": "gemini-weekly",
            "window": "weekly",
            "remainingFraction": 0.846885,
            "resetTime": "2026-07-11T16:50:25Z"
          },
          {
            "bucketId": "gemini-5h",
            "window": "5h",
            "remainingFraction": 1,
            "resetTime": "2026-07-08T13:09:12Z"
          }
        ]
      },
      {
        "displayName": "Claude and GPT models",
        "buckets": [
          {
            "bucketId": "3p-weekly",
            "window": "weekly",
            "remainingFraction": 1,
            "resetTime": "2026-07-15T08:09:12Z"
          },
          {
            "bucketId": "3p-5h",
            "window": "5h",
            "remainingFraction": 1,
            "resetTime": "2026-07-08T13:09:12Z"
          }
        ]
      }
    ]
  }
}
```

Current parser behavior:

| Response field | Model field |
|---|---|
| `groups[].displayName` | normalized synthetic model id, then mapped back to display names |
| `buckets[].remainingFraction` | percent = `fraction * 100` |
| `buckets[].resetTime` | `intervalResetsAt` or `weeklyResetsAt` |
| `window == "5h"` | interval window |
| `window == "weekly"` | weekly window |

Window status is normalized from bucket presence: an existing bucket maps to
`QuotaWindowStatus.present`, including `remainingFraction = 0`; a missing bucket maps to
`.absent`. The shared UI and health logic never interprets provider-specific raw status values.

Current normalized internal names:

| Group | Internal `modelName` | Display name |
|---|---|---|
| `Gemini Models` | `gemini_models` | `Gemini Models` |
| `Claude and GPT models` | `claude_and_gpt_models` | `Claude and GPT models` |

Returned `ModelQuota` values keep count fields at `0`, because the current local RPC only exposes fractions and reset times.

### GetCascadeTrajectoryGeneratorMetadata

Used by `AntigravityLocalUsageScanner` to extract per-event token usage for a single session (cascade).

Request body:

```json
{ "cascadeId": "<sessionId>" }
```

Response shape (field names may vary between Antigravity versions; parser walks the tree recursively and matches key names against regex patterns):

```json
{
  "generatorMetadata": [
    {
      "timestamp": "2026-07-15T10:30:00Z",
      "model": "gemini-2.5-pro",
      "inputTokens": 100,
      "outputTokens": 50,
      "cacheReadTokens": 20,
      "cacheWriteTokens": 5,
      "reasoningTokens": 10,
      "totalTokens": 185,
      "stepIndices": [58, 59]
    },
    {
      "timestamp": "2026-07-15T10:31:12Z",
      "model": "claude-sonnet-4.5",
      "inputTokens": 200,
      "outputTokens": 80,
      "cacheReadTokens": 30,
      "cacheWriteTokens": 0,
      "reasoningTokens": 0,
      "totalTokens": 310,
      "stepIndices": [60, 61]
    }
  ]
}
```

Field name resolution (case-insensitive, snake_case or camelCase both accepted):

| Detected name pattern | Mapped to |
|---|---|
| `^(input\|prompt).*token$` or `input_tokens` | `inputTokens` |
| `^(output\|completion).*token$` or `output_tokens` | `outputTokens` |
| `cache.*read.*token` or `cache_read_tokens` | `cacheReadTokens` |
| `cache.*write.*token` or `cache_write_tokens` | `cacheWriteTokens` |
| `(reasoning\|thinking).*token` or `reasoning_tokens` | `reasoningTokens` |
| `totalTokens` or `total_tokens` | `totalTokens` (fallback: sum of the above) |
| `stepIndices` or `step_indices` | `stepIndices` (used for best-effort turn inference) |
| `apiProvider` or `api_provider` | model fallback when no higher-priority model field is present |

Model field is selected from explicit `model`-named keys first, with `apiProvider` as a lower-priority fallback (so unrelated strings such as timestamps are not misread as the model name). Values prefixed with `MODEL_PLACEHOLDER_` are dropped.

Events with no token fields at all (just a timestamp + model) are skipped — they don't contribute to the aggregate.

## Local Token Usage Scanner

`AntigravityLocalUsageScanner` runs in the background after every successful quota refresh. It scans both supported conversation directories, accepts `.db` and `.pb` session files, reads only file metadata (mtime/size plus WAL mtime/size for `.db`) against a cached index, and re-fetches only dirty sessions via `GetCascadeTrajectoryGeneratorMetadata`. It never opens the session file contents.

### Storage layout

```
~/.gemini/antigravity/
├── conversations/                         ← Antigravity IDE native (read-only input)
│   ├── {sessionId}.db                      ← discovered and fingerprinted, not opened
│   └── {sessionId}.pb                      ← discovered and fingerprinted, not decoded
└── .token-monitor/                        ← scanner's own cache
    └── index.json                         ← top-level state and per-session cache (fast load)
```

`index.json` schema:

```json
{
  "version": 6,
  "lastScannedAt": "2026-07-15T02:00:00Z",
  "sessions": {
    "41272769-fe7d-4802-a174-b5b28b526ade": {
      "mtimeMs": 1752542400000.0,
      "sizeBytes": 8421376,
      "fetchedAt": "2026-07-15T02:00:00Z",
      "eventCount": 50
    }
  },
  "dailyBySession": {
    "41272769-fe7d-4802-a174-b5b28b526ade": {
      "2026-07-15": { "dayStart": "...", "inputTokens": 1000, "totalTokens": 1800 }
    }
  },
  "samplesBySession": {
    "41272769-fe7d-4802-a174-b5b28b526ade": [
      { "completedAt": "...", "promptID": "...", "inputTokens": 1000, "outputTokens": 800 }
    ]
  }
}
```

`dailyBySession` keeps each session's per-day token breakdown, while `samplesBySession` keeps recent per-event samples. A changed session replaces only its own entries; unchanged sessions remain cached. The source events are not persisted as JSONL — they are fetched again from RPC whenever the file fingerprint is dirty.

### Optimizations

The scanner does heavy work in the background and is built for low-cost re-runs:

1. **File + WAL fingerprint diff**: each scan starts with directory/resource metadata only. A `.db` session is re-fetched when its file mtime/size or WAL mtime/size changes; a `.pb` session uses its file mtime/size.
2. **Per-session incremental aggregation**: `index.dailyBySession` stores each session's day-keyed breakdown. When a session changes, only that session's cached entry is replaced — other sessions' entries are untouched.
3. **In-flight dedup**: if `scan()` is called while a previous scan is still running, the new call is a no-op (the previous one will publish its result via `@Published`).
4. **Off-main-thread I/O**: the scanner class is `@MainActor` for state mutation, while the heavy pipeline lives in `nonisolated static performScanPure(...)` and runs through the non-actor-isolated `LocalUsageScanRunner`. It inherits caller cancellation and only assigns the result back on MainActor.
5. **Serial RPC for dirty sessions**: dirty sessions are fetched one at a time via `nonisolated static func fetchAll(fetcher:dirty:)` (a plain `for` loop, not `withTaskGroup`). This bounds local RPC load and keeps cache updates deterministic.
6. **Failure is non-fatal**: RPC failures don't update `index.sessions[id].mtimeMs` — the next scan naturally retries. `failedSessionCount` is surfaced in the result so the UI can show a warning.
7. **In-flight / offline tolerance**: if every entry in `defaultConversationsDirs` doesn't exist (CLI-only or no IDE activity), `listDBFiles()` returns `[]` and the scan completes cleanly with `sessionCount: 0` — no exception.
8. **Index parse failure recovery**: a corrupted `index.json` is logged + reset to `.empty` rather than failing the whole scan.
9. **Pipeline serialization via `AsyncMutex` + `lastCommittedGeneration`**: 整个 `performScanPure` 包在 `try await pipelineMutex.withLock { ... }` 里, 旧 worker 跑完整个 pipeline 才让新 worker 开始. 配合 `lastCommittedGeneration` 守门, cancel+rescan 期间旧 worker 即使晚到 mutex, `startedGeneration < lastCommittedGeneration` 时也跳过 saveIndex, 杜绝 cache revert. **P1 invariant**: read + write-to-disk + update 全在 mutex 内 atomic (跨 @MainActor hop `await scanner.read.../write...` 持锁执行), 不能拆到 mutex 外. 详见 `spec/overview.md` "Scanner Concurrency" 段.
10. **Generation 守门防 UI flicker**: `runScan` 用 `startedGeneration` 跟 `latestGeneration` 比对, 不一致就丢弃 in-memory result, defer 状态清理也按 generation 守门（`if startedGeneration == self.latestGeneration` 才清 isScanning / inFlightTask）. 防止 cancel+rescan 期间旧任务的 defer 把 UI 的"扫描中"状态清掉.
11. **取消不污染 lastError**: `performScanPure` 的 catch 用 `CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled)` 过滤, 取消错误（`Task.isCancelled` / `CancellationError` / `URLError.cancelled`）直接 return, 不写 `self.lastError`. 跟 AppState 的 refresh catch 同语义.

### Per-event field count (5 + total)

Every `UsageEvent` carries 5 token categories (input / output / cacheRead / cacheWrite / reasoning). Its consumption `totalTokens` is derived from `input + cacheRead + output + reasoning`; server totals and cache-write bookkeeping are not allowed to inflate it.

In the daily aggregate (`AntigravityDailyUsage`), the 5 categories are summed per day; `totalTokens` is the day sum. `cacheWriteTokens` is intentionally **excluded from `totalTokens`** because it's bookkeeping (writes to a future read cache) rather than actual quota consumption — but it's still tracked separately for visibility.

## Session file formats (`.db` vs `.pb`)

Antigravity IDE has used two on-disk formats for per-cascade session files. The scanner accepts both via `SessionStoreFormat` and the file extension, but treats them as **discovery/fingerprint inputs only**: it does not open SQLite or decode protobuf content. Token data and Turn/Round inference come from the local `GetCascadeTrajectoryGeneratorMetadata` RPC for both formats.

| Extension | Format | Runtime use | R/T computation | Token computation |
|---|---|---|---|---|
| `.db` | SQLite | 文件路径、扩展名、mtime/size 及 WAL 指纹 | RPC `stepIndices` 间隙推断（best-effort） | RPC（与文件格式无关）|
| `.pb` | Protobuf (wrapper, not raw) | 文件路径、扩展名、mtime/size 指纹 | RPC `stepIndices` 间隙推断（best-effort） | RPC（与文件格式无关）|

`protoc --decode_raw` on observed `.pb` files fails with "Failed to parse input" — the wrapper is not standard raw protobuf (likely a length-prefixed stream or a custom envelope around a proto message). The bytes do not look compressed (zstd / lz4 / gzip all reject) or encrypted.

For `.pb` sessions, the scanner fetches the same per-event token numbers and `stepIndices` via `GetCascadeTrajectoryGeneratorMetadata` as it does for `.db` sessions. `turns` and `rounds` are therefore populated for both formats, with the caveat that turns are inferred from step-index gaps and are not guaranteed to equal the semantic user-prompt count.

### Directories scanned (`defaultConversationsDirs`)

The scanner walks both:

1. `~/.gemini/antigravity-ide/conversations/` — Antigravity IDE.app (`--app_data_dir antigravity-ide`)
2. `~/.gemini/antigravity/conversations/` — Antigravity.app (`--app_data_dir antigravity`)

Same `sessionId` (UUID) in both directories is deduped to the **first** entry (Antigravity IDE.app wins). This lets a user with both applications installed see fresh data from the active workspace without being shadowed by stale data.

## Historical `.db` Schema Insights — Rounds / Turns / Tool calls

The following is historical reverse-engineering material, retained to explain the origin of the current RPC heuristic. It is not a runtime dependency: the scanner no longer opens these SQLite files or uses `step_type` values. Antigravity's `~/.gemini/<antigravity-ide|antigravity>/conversations/{cascadeId}.db` is a SQLite file with an undocumented schema. All `step_type` numbers come from Google's internal `cascade` framework and were verified by reading 21 `.db` files (June–July 2026) and matching against RPC-returned token data.

### One `.db` = one cascade (one Antigravity session)

A cascade ID is a UUID (`{cascadeId}.db`) shared with the RPC `cascadeId` parameter. Each session can span multiple hours (longest observed: 12h40m, 850 LLM calls). The scanner's session set comes from `ls` over `defaultConversationsDirs` (`.db` + `.pb`).

### `steps` table — what each `step_type` means

| `step_type` | Count per session (observed) | Meaning | Used for |
|---|---|---|---|
| **14** | 5–50+ | **USER PROMPT (turn boundary)** | turns |
| **15** | 10–850 | **LLM API call (round)** | rounds |
| 5 | 0–50+ | LLM tool: `replace_file_content` (JSON: Description + Instruction + ReplacementContent) | tool call distribution |
| 7 | 0–50+ | LLM tool: `grep` / `read_file` | tool call distribution |
| 8 | 0–150+ | Tool result (file content) | diagnostic only |
| 21 | 0–50+ | LLM tool: `run_command` (JSON: CommandLine + Cwd + toolAction) | tool call distribution |
| 9, 23, 33, 98, 101 | rare | Other (rare step types, not yet classified) | unused |

> [!NOTE]
> **Pure RPC 架构升级（v1.4+）**：Antigravity 监控已升级为纯基于本地 RPC (`GetCascadeTrajectoryGeneratorMetadata`) 提取 Turns、Rounds 和 5 类 Token 数据。不再调用 `AntigravityDBReader` 或连接 SQLite `.db` 文件。保留以下历史 Insights 供架构参考。

**历史 `.db` 节点说明**（仅供分析参考）：

**Key trap to avoid**: `step_type=5` and `step_type=21` payloads contain fields named `Description`, `Instruction`, and `ReplacementContent`. These look like user prompts at a glance but they are the **LLM's tool-call instructions to the IDE**, not user input. The actual user prompt is `step_type=14` — its payload embeds the user's literal text (extractable with `[\x20-\x7e\u4e00-\u9fff]{15,}`).

### `step_type=14` payload structure — user prompt

The top-level `step_payload` is a protobuf message. The user prompt content lives at a known fixed path:

```
step_payload
└── field 19 (LEN, 1000-4000 bytes)  ← UserPrompt message
    ├── field 2  (LEN)  ← user's literal text (the actual prompt)
    ├── field 3  (LEN)  ← other metadata (e.g. sentence annotations)
    ├── field 7  (LEN)  ← attached file URI (e.g. `file:///...implementation_plan.md`)
    └── field 12 (LEN)  ← available tool list (read_file / command(*)/mcp(...) / etc.)
```

**For "prompt" extraction**: use `field 19 > field 2`. Field 12 is the catalog of tools the IDE exposed to the LLM for this turn (the `command(./scripts/build_app.sh)` / `read_file(*)` / `mcp(chrome_devtools/...)` strings come from here — not the user's prompt).

**Empty / automated prompts**: a `step_type=14` with no `field 2` text is a **continuation prompt** — the IDE injects it when the user clicks "Continue" with no text. The attached file URI in `field 7` (typically `file:///Users/.../antigravity/brain/<cascadeId>/implementation_plan.md`) is the only payload. Observed ~3% of turns in long sessions.

### `step_type=15` payload structure — LLM round (Type A vs Type B)

The `step_payload` wraps one LLM call. Field 20 is the LLM round message; inside it, the LLM text vs tool call lives at distinct field numbers, and **the protobuf structure tells you whether this round is a working round (Type A) or a final response (Type B)**:

```
step_payload
└── field 20 (LEN, 100-20000 bytes)  ← LlmRound message
    ├── field 1  (LEN)  ← **final user-facing response** (Type B only)
    ├── field 3  (LEN)  ← **LLM thinking out loud** (Type A only)
    ├── field 6  (LEN)  ← tool call ID (UUID with `bot-` prefix)
    ├── field 7  (LEN)  ← tool call JSON data (CommandLine / AbsolutePath / etc.)
    ├── field 8  (LEN)  ← duplicate of field 1 (Type B only)
    ├── field 11 (LEN)  ← timestamp (varint, seconds since epoch)
    ├── field 12 (varint)← always 1 (round index in cascade?)
    └── field 14 (LEN)  ← metadata blob (Type B only)
```

**Two round types, two field shapes** (verified on 98 turns of one production session):

| Type | Has field 1 | Has field 3 | Has field 7 (tool) | Meaning | Typical count per turn |
|---|---|---|---|---|---|
| **A (working)** | ❌ | ✅ (English, "I'm now focused on…") | ✅ (JSON params) | LLM thinks out loud, then calls a tool | 0-20+ |
| **B (final)** | ✅ (Chinese, structured with emoji/headers) | ❌ | ❌ | LLM delivers the user-facing answer | exactly 1 (the last) |

**Why this matters for the OUTPUT**: a `step_type=15` round's "text content" is **either** `field 1` **or** `field 3` — never both, and the wrong one is a totally different content type:

- **`field 1`**: structured Chinese summary, often with `### 🛠️ 1. 双向边界渗透自愈实现` headers, code blocks, Git commit hashes, TP/FP counts. This is the response the user reads in the IDE chat.
- **`field 3`**: terse English commentary like `**Initiating Task Update**\n\nI've established the task list, and now I'm updating task.md, marking the first task as "in progress."` — the LLM's "thinking aloud" before invoking a tool. Shown in IDE debug panels but NOT in the user-facing chat.

**The trap**: extracting `field 3` (or "any LEN text in field 20") gives you the LLM's internal monologue, not the final answer. Extraction code that doesn't know about Type A vs Type B will output working-round noise and miss the final response entirely.

**How to find a turn's final OUTPUT** (the user-facing answer):

1. Walk all `step_type=15` rows with `idx` between this turn's user prompt (`step_type=14`) and the next turn's user prompt
2. The **last** one is the final round
3. If `field 1` is present → that's the final OUTPUT (Type B)
4. Else, the last round with any text is the last working round (Type A only) — the turn has no final summary in the .db (the LLM ended with a tool call and the next user prompt interrupted)

**Sample Python walker** (works on the {cascadeId}.db after copy-isolation; the `field 20 > field 1/3` schema has been stable across 21 .db files observed since June 2026):

```python
def parse_unknown_fields(data): ...   # standard varint walker
def get_user_prompt(payload):
    # top-level field 19 > field 2
    ...
def get_round_text(payload):
    # field 20 > field 1 (final) and field 20 > field 3 (thinking)
    final = thinking = None
    for f20 in parse_unknown_fields(payload):
        if f20.field_num == 20 and f20.wire_type == 2:
            for sub in parse_unknown_fields(f20.value):
                if sub.wire_type == 2 and len(sub.value) > 20:
                    try:
                        text = sub.value.decode('utf-8')
                        if '\x00' in text: continue
                        if sub.field_num == 1 and not final:   final = text
                        elif sub.field_num == 3 and not thinking: thinking = text
                    except: pass
    return final, thinking
```

### Token data is NOT in `.db` — confirmed by Rosetta-stone search

`GetCascadeTrajectoryGeneratorMetadata` returns per-LLM-call token numbers. The scanner can reproduce these numbers as ground truth and search the .db for them. The result: **none of the token numbers (input / output / cacheRead / cacheWrite / reasoning / total) exist as protobuf fields in any .db table** (`steps`, `gen_metadata`, `executor_metadata`, `trajectory_metadata_blob`, `parent_references`, `battle_mode_infos`). All searches return:

- false positives in protobuf noise (e.g. `cache_read=0` matches every blob because the single-byte varint `0x00` is everywhere)
- matches in `step_payload` are text that the LLM happened to write containing the same number (e.g. the LLM writing "Output: 3182 tokens" in its response)

**Token data lives only in the `language_server` process memory** and is exposed via the RPC. Restarting Antigravity IDE clears all per-round token history; only the conversation flow (steps) and structure (metadata blobs) survive in `.db`.

### Lazy .db write — sessions don't flush while open

`language_server` (PID discoverable via `ps aux | grep language_server`) holds `.db` file handles while a session is active. Until the session closes, the conversation switch happens, or the IDE exits, **the `.db` mtime does not update** and the scanner cannot see new steps. Implication for users: counts in the app lag the real-time activity by 0 to N hours, where N depends on when Antigravity last flushed. Use `lsof +D ~/.gemini/antigravity/conversations/` to check who holds the file handle.

### Round ↔ step index mapping

For historical sessions whose `.db` steps and RPC response events were in sync:

- `gen_metadata.idx` (table of LLM-call trajectories) is 1:1 with the `events` array index returned by the RPC
- `steps.idx` of `step_type=15` rows in ascending order is 1:1 with the same RPC events array
- Both orderings are by occurrence, not by `idx` value (idx values have gaps for non-LLM-call steps)

This means: a `step_type=15` row at `.db idx = N` is the LLM call that produced `events[N]` in the RPC response. `step_type=14` (user prompt) `idx` values sit *before* the `step_type=15` `idx` for the LLM calls they triggered — using `step_type=14` boundaries to slice events[] gives per-turn token totals.

## Current scanner pipeline (pure RPC)

1. **File fingerprint diff** — enumerate `.db` and `.pb` filenames and compare mtime/size; for `.db`, the adjacent WAL mtime/size is also part of the fingerprint. File contents are not opened.
2. **RPC fetch** — for each dirty session, call `GetCascadeTrajectoryGeneratorMetadata` and parse timestamp, model, token fields, and `stepIndices` from each event.
3. **Round aggregation** — count timestamped RPC events as rounds and bucket token totals by the local calendar day.
4. **Turn inference** — sort events by timestamp and start a new inferred turn when the next event's minimum `stepIndices` value has a gap after the previous maximum. This is best-effort and can overcount when tool-call steps create gaps.
5. **Cache update** — only a non-empty RPC result advances the file fingerprint and replaces the session's daily/sample cache. Failed or empty RPC responses retain last-good data and remain dirty for a later scan.

## Historical SQLite reader investigation

The following SQLite investigation describes the removed implementation and is retained only as background. It must not be read as the current scanner pipeline.

**根因（确认）**：macOS 系统 `libsqlite3.dylib` 跟 CLI `sqlite3` 是**同一 SQLite 源版本（3.51.0）**。但 IDE 写出来的 `-shm` 共享内存文件，**dylib 拒绝 open，CLI 接受**。`sqlite3_open_v2` 成功（打开 .db 文件），但 `sqlite3_prepare_v2` 在 mmap `-shm` 阶段返回 `SQLITE_CANTOPEN (14)` "unable to open database file"。

**实测 21/21**：
- 全 fresh 状态（没 -shm）：dylib 21/21 SUCCESS（自己建 -shm）
- IDE 写完一轮后（每个 .db 都有 32KB -shm）：dylib **5/21 SUCCESS，16/21 CANTOPEN**
- 同 .db 用 CLI 测：21/21 SUCCESS

**为什么 dylib 严格、CLI 宽松**：
- dylib 跟系统 SQLite 一起 backport，对损坏/不规范的 -shm 状态直接 fail
- CLI 走自己的代码路径，对异常 -shm 更鲁棒
- 具体差异点没深挖（可能是 -shm header magic / version / size mismatch），但行为可观察

**为什么最终不采纳"删 -shm 修法"**（2026-07-15 18:30 用户判断）：
- 删 -shm 后 dylib 100% 能 read（实测 5/21 → 20/21）
- 但 IDE 侧需要重建 -shm → 引发额外 I/O + 短暂 WAL 写入抖动
- **不值的为 1/21 收益去打扰 IDE**——主动写 session 的 1/21 删了也立刻被 IDE 重建，救不回来
- 选了"copy 隔离"，稳态 ~21/21 + IDE 完全不被干扰

**历史实现的最终修法**（`SQLiteTempCopy` 公共 helper + `AntigravityDBReader` + `AntigravityLocalUsageScanner.performScanPure`）：

1. **快路径：直接 read 原 .db**（`SQLiteTempCopy.read` 第一次尝试）
   - 默认尝试，0 copy I/O。无 -shm 冲突时省掉 ~16MB/session 的文件复制
   - 实测：IDE 暂停写时 21/21 session 都能走快路径，scan 1455ms vs copy 策略 10059ms
   - **省 6.9x 时间**

2. **兜底：copy .db + .db-wal + .db-shm 到 /tmp 副本上 read**（`SQLiteTempCopy.withTempCopy`）
   - 快路径 open 失败且错误码是 CANTOPEN(14) / BUSY(5) 时自动触发
   - 副本上 SQLite 自由 mmap，不受 IDE 实时 -shm 状态干扰
   - READWRITE 让 SQLite 在副本上完成 WAL recovery（把 -wal pages 写回 .db）
   - `sqlite3_busy_timeout(db, 300)` 应对偶尔的副本竞争
   - 副本不保留，read 完 `defer` 删 .db / .db-wal / .db-shm

3. **错误码过滤：只对 file-level 错误走 copy**（`SQLiteTempCopy.read`）
   - CANTOPEN(14) / BUSY(5) → 走 copy（IDE -shm 状态/锁问题，copy 能解）
   - NOTADB(26) / SQL 错误 → 直接 propagate（copy 也救不了，省 I/O）

4. **单次尝试，失败丢给下次 scan**
   - 不在 scanner 内维护 5s retry timer（额外状态机 + 抢 IDE 资源的本质没变）
   - 失败就 `logInfo` + 保留旧 R/T 数据；下次外部 `triggerAntigravityLocalUsageScan`（来自
     antigravity 主 quota refresh timer，默认 60s）会再扫一次
   - IDE 通常那时已暂停写 → .db 副本 copy 成功率高

5. **Off-main-thread**：所有 SQLite 读 + RPC 都在 `nonisolated static performScanPure`
   里通过 `LocalUsageScanRunner` 执行，继承 caller 取消且不阻塞菜单栏 MainActor。
   RPC 是串行的（`fetchAll` 内部 `for` 循环），不是因为怕 IDE 锁竞争，
   而是因为串行 fetchAll 简化了 R/T 配对的 idx 语义；copy 隔离后
   IDE 完全不知道我们在 read。

6. **R/T 数据不能覆盖**（**重要 bug 修复**）
   - 旧代码：scan 失败时 `index.dailyBySession[sessionId] = newDaily` 仍执行
   - newDaily（无 R/T）覆盖了之前成功的 R/T 数据
   - 现象：20/21 → 反复 scan → 10/21（数据被蚕食）
   - 修：`if rtSucceeded || index.dailyBySession[sessionId] == nil` 才更新 index
   - 即 R/T 失败也保留旧 index 的 R/T（merge 而不是 overwrite）
   - **任何"先建 newDict 再覆盖旧 index"模式都要警惕**——read-modify-write 不能用 replace

**实测**（force full scan by touch 所有 .db）：
- 21/21 SUCCESS, 0 failed
- **快路径全命中（0 fallback）**：21 个 session 全部直接 read 成功
- full scan 时间：**1455ms**（vs 之前 always-copy 策略 10059ms，**6.9x 加速**）
- 即使 IDE 当前正在写，快路径失败自动触发 copy 兜底，**21/21 仍能成功**
- 偶尔 IDE 切换 session 时 .db 短暂不可读 → 单次失败 → 下次 scan（60s 内）自然 backfill
- total turns/rounds 持续累积（实测 118/1305+），不停涨

**为什么不采纳的修法**：
- ❌ **删 -shm**（5/21 → 20/21）：让 IDE 重建 -shm I/O 抖动 + WAL 短暂性能抖动，为 1/21 收益打扰 IDE 不值得
- ❌ **bundle 新版 libsqlite3.dylib**：code signing 拒收风险
- ❌ **fallback 到 `Process` 跑 `sqlite3` CLI**：subprocess 启动开销 ~50ms × 21 = 1s，实施成本不匹配
- ❌ **自己 parse .shm/.db 格式**：~500 行新代码，bug 风险高

**未来可选优化**（如确实需要 100% 实时覆盖率）：
- IDE 提供 IPC 接口直接给 R/T 数据（不依赖 .db 文件）——最干净，但等 IDE 团队
- 把 -shm "问题 dylib 版本" 标记为已知限制，靠 IDE 写完一段后自然 backfill

### Historical R/T round-event 配对：按时间排序

旧版 `performScanPure` 曾把 RPC events 跟 `.db` `step_type=15` idx 列表配对时：

| 来源 | 内容 | 顺序保证 |
|---|---|---|
| `.db` `step_type=15` idx | LLM call 序号 | `ORDER BY idx` **严格升序**——稳定 |
| RPC `generatorMetadata` events | 每次 LLM call 的 token + timestamp | **RPC 返回顺序不保证**——会话变长后 payload 排列会漂移 |

如果直接 `events[i]` ↔ `roundIdxs[i]` 按位置配对，RPC 顺序变化时配对错位，部分 round 找不到 timestamp，R/T 当天显示为 "—"。**间歇性失败，看似随机**。

**历史修法**：events 先按 `timestamp` 升序排，再按位置配对 roundIdxs。当前纯 RPC 实现不再进行这类 `.db` 配对，而是直接使用 RPC 事件自身的 `stepIndices` 做 best-effort turn 推断。

```swift
let sortedEvents = events
    .filter { $0.timestamp != nil }
    .sorted { $0.timestamp! < $1.timestamp! }
let n = min(roundIdxs.count, sortedEvents.count)
for i in 0..<n {
    roundIdxToTs[roundIdxs[i]] = sortedEvents[i].timestamp!
}
```

**配套优化**：
- turn 找"idx 之后第一个 round idx"用 O(log n) binary search（手写 `lo/hi`），不要 `firstIndex(where:)` O(n) 线性扫
- `roundIdxs` 由调用方查询后传入 `perDayTurnsAndRounds(roundIdxs:...)`，避免在两个函数里重复 `SELECT ... WHERE step_type=15`（两次独立读事务，busy_timeout 也只盖单次）

### Historical R/T ratio as a complexity signal

Rounds-per-turn is a strong signal of task complexity. Observed ratios (21 sessions, 6 active days):

| Date | turns | rounds | rounds/turn | What was happening |
|---|---:|---:|---:|---|
| 2026-06-10 | 7 | 24 | 3.4 | First-time setup, mostly trivial turns |
| 2026-06-22 | 11 | 48 | 4.4 | Routine edits |
| 2026-07-09 | 48 | 308 | 6.4 | Mixed work day |
| 2026-07-10 | 7 | 102 | 14.6 | Debug-heavy session |
| 2026-07-14 | 29 | 221 | 7.6 | Normal workday |
| 2026-07-15 | 12 | 388 | 32.3 | First 2 turns dominated, rest were 1-round follow-ups |

Distribution per turn within a single session is highly uneven — first few turns after a context reset often burn 25+ rounds (tool-use loops), then a tail of 1-round confirmations. The 7-day chart should show both totals, not the ratio (it's not meaningful when averaged across heterogeneous turns).

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `Google Antigravity` (provider name, with brand prefix) |
| `iconSystemName` | `paperplane.circle.fill` |
| `accentColor` | `antigravity` |

**Card title = `displayName`** ("Google Antigravity") with the tier shown as a small pill on the right, mirroring the `ChatGPT Plan` + `Team` pattern. The pill strips the `Google ` / `Antigravity ` prefix from `planLabel`, so `Google AI Pro` becomes `AI Pro`, `Antigravity Pro` becomes `Pro`, and bare names like `Free` pass through unchanged. When no tier is known the pill is suppressed (e.g. the user has just logged out and the next refresh hasn't run yet).

The two text dimensions carry non-overlapping information:

- **Title** = provider brand (always present)
- **Pill** = tier / plan identifier (when known, kept short)

### Hover details (card title)

A `HoverInfoRow` wraps the entire header. The detail panel shows:

- Login email (from `GetUserStatus.userStatus.email`)
- Plan name (tier, repeated for clarity when different from the card pill)
- Source note: "数据来源：本机 Antigravity IDE / agy CLI 的 language_server"

Panel header is `Google Antigravity 账号` for consistency with the card title.

If email is missing, the panel shows a non-fatal "未拿到账号邮箱（首次刷新后会显示）" hint instead of an empty cell. Email text is `.textSelection(.enabled)` so users can copy it.

### Footer line: today's token usage

Below the two model quota rows, a small line shows today's usage:

```text
📈 今天 5.2K in · 1.3K out · 800 cache · 200 reason
```

Source: `AntigravityLocalUsage.today` (sum of all sessions' events whose timestamp is in today's local day).

When the scanner hasn't completed yet (first scan in progress, or RPC failure), the footer shows a placeholder `今日用量：扫描中…` so the user knows data is coming.

### Hover details (footer)

A second `HoverInfoRow` wraps the footer line. The detail panel shows:

- 7 stacked bar chart, one per local day for the last 7 days
- Each bar stacked: input (blue) / cache (cyan) / output (green) / reason (orange)
- Numeric table below: date / input / cache / output / reason
- Footer: "更新于 HH:MM" (from `scannedAt`)

```text
最近 7 天 Token 用量                            更新于 02:00
[Input] [Cache] [Output] [Reason]

[bar chart, 7 columns]

日期      Input   Cache   Output  Reason
07-09     1.2K    300     500     100
07-10     2.1K    500     800     150
...
07-15     5.2K    800     1.3K    200
```

### Quota rows

Current row tints:

| Group | Tint |
|---|---|
| `Gemini Models` | blue |
| `Claude and GPT models` | orange |

Both groups use a combined quota row:

```text
Google Antigravity              [AI Pro]                   01:44
Gemini Models                                          5h × 6 = 周
5h 100%  周 85%   [weekly bar in 6 segments]  <weekly reset time>

Claude and GPT models                                  5h × 3 = 周
5h 100%  周 100%  [weekly bar in 3 segments]  <weekly reset time>

📈 今天 5.2K in · 1.3K out · 800 cache · 200 reason
```

## Error Handling

| Situation | Current behavior |
|---|---|
| `pgrep` finds no IDE `language_server` and no agy CLI | `网络错误：未发现 Antigravity IDE 或 agy CLI 进程...` |
| Processes found but none listen on localhost | `网络错误：发现 Antigravity 进程但未监听本地端口...` |
| IDE candidate without `--csrf_token` | Silently rejected; later valid candidates still considered |
| `lsof` fails | Wrapped in `网络错误：无法启动 lsof: <msg>` |
| `RetrieveUserQuotaSummary` returns non-2xx | `HTTP <status>: <body preview>` |
| `GetUserStatus` or `GetLoadCodeAssist` fail | Logged at warn level; tier / email degrade gracefully (fallback chain + nil email) |
| `RetrieveUserQuotaSummary` JSON decode fails | `解析失败：Antigravity 响应解析失败: ...` |
| No quota groups survive parsing | `解析失败：Antigravity quota 响应里没有可用 bucket` |
| Scanner: every entry in `defaultConversationsDirs` missing | Scan completes with `sessionCount: 0`; footer shows placeholder "今日用量：扫描中…" |
| Scanner: `GetCascadeTrajectoryGeneratorMetadata` fails for one session | `failedSessionCount` increments; the session is retried next scan (mtime preserved) |
| Scanner: `index.json` corrupted | Logged at warn level + reset to `.empty`; next scan rebuilds from scratch |

## Cross-Provider Cache Semantics (Antigravity vs Codex)

> Companion section: see `codex.md` § Cross-Provider Cache Semantics for the Codex side of this comparison.

Antigravity and Codex report cache reads using **incompatible semantic models**. Any code that aggregates token usage across both providers must be aware of these differences, or it will double-count or mis-attribute.

### Antigravity model: `inputTokens` and `cacheReadTokens` are MUTUALLY EXCLUSIVE

`inputTokens` is **only the uncached input**. Tokens that were served from the cache are reported as `cacheReadTokens`, not as part of `inputTokens`. The two are separate buckets; their sum is the total input that the model "saw":

```swift
// AntigravityLocalUsage.swift
totalInput = inputTokens + cacheReadTokens
cacheHitRate = cacheReadTokens / (inputTokens + cacheReadTokens)
totalTokens = inputTokens + cacheReadTokens + outputTokens + reasoningTokens
//                                     ^ cacheWriteTokens intentionally excluded
```

`cacheWriteTokens` is bookkeeping (writes to a future read cache) and is **never** part of `totalTokens`. Reasoning tokens may overlap with output tokens; both are reported independently.

### Codex model: `cachedInputTokens` is a SUBSET of `inputTokens`

`inputTokens` is the **full** input that the API charged for, and `cachedInputTokens` is the subset of those tokens that were served from cache. Adding them together double-counts. See `codex.md` for the full breakdown.

### Comparison table

| Dimension | Antigravity | Codex |
|---|---|---|
| Cache bucket | Independent, parallel to `inputTokens` | Subset of `inputTokens` |
| Total input = | `inputTokens + cacheReadTokens` | `inputTokens` (already includes cached) |
| `cacheWrite` | Yes, separate field, not in `totalTokens` | **Not reported** |
| Cache hit rate | `cacheRead / (cacheRead + input)` | `cached / input` (mathematically equivalent) |
| Per-round data | All 5 fields per LLM call | 4 fields per `token_count` event (`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`) |
| Data source | RPC `GetCascadeTrajectoryGeneratorMetadata` (live) | Local JSONL `~/.codex/sessions/**/*.jsonl` (near-realtime) |
| Data lag when source idle | None while IDE is running; data lost on IDE exit if session never flushes | None — CLI flushes JSONL continuously |
| Reasoning vs output | Independently reported (may overlap) | Summed into `outputTotal = output + reasoning` |
| Total tokens formula | `input + cacheRead + output + reasoning` (excludes `cacheWrite`) | `input + output + reasoning` (already includes cached) |

### Why this matters in practice

- **UI stacked bars render differently.** Antigravity has 5 segments (`input`, `cacheRead`, `cacheWrite`, `output`, `reasoning`); Codex has 4 (`uncached = input - cached`, `cached`, `output`, `reasoning`). Drawing them with the same `totalSegments` assumption misaligns colors and widths.
- **Total computation differs.** A naive `total = input + cached + output + reasoning` over-counts Codex by `cached`.
- **cacheWrite asymmetry.** Antigravity's "future cache" segment is just absent on the Codex side; the UI either hides the segment or shows 0 for Codex.
- **Cross-provider sum**: only `input (uncached)`, `cacheRead/cached`, `output`, `reasoning` are comparable. `cacheWrite` is Antigravity-only.

### Recommended normalized abstraction (cross-provider view)

To compare or sum daily usage across both providers, normalize both into a single shape at the provider boundary. The model below is what `CodexFetcher` and `AntigravityLocalUsageScanner` should produce (or what a view-layer adapter should derive) before any aggregation:

```swift
/// Provider-agnostic daily token usage.
/// All four `input`/`cacheRead`/`output`/`reasoning` categories are
/// MUTUALLY EXCLUSIVE (parallel buckets) regardless of source.
struct NormalizedDailyUsage: Equatable, Sendable, Identifiable {
    let dayStart: Date
    let uncachedInput: Int   // Antigravity: inputTokens;            Codex: inputTokens - cachedInputTokens
    let cacheRead: Int       // Antigravity: cacheReadTokens;        Codex: cachedInputTokens
    let cacheWrite: Int      // Antigravity: cacheWriteTokens;       Codex: 0
    let output: Int          // Antigravity: outputTokens;           Codex: outputTokens
    let reasoning: Int       // Antigravity: reasoningTokens;        Codex: reasoningOutputTokens
    let turns: Int           // Antigravity: inferred turn count; Codex: user prompt count
    let rounds: Int          // Both: LLM call count

    var id: Date { dayStart }
    var totalInput: Int { uncachedInput + cacheRead }
    var totalOutput: Int { output + reasoning }
    var totalTokens: Int { uncachedInput + cacheRead + output + reasoning }
    var cacheHitRate: Double? {
        let denom = totalInput
        guard denom > 0 else { return nil }
        return Double(cacheRead) / Double(denom)
    }
}
```

**Mapping rules** (apply at the provider boundary, before persistence):

| From provider | → `uncachedInput` | → `cacheRead` | → `cacheWrite` | → `output` | → `reasoning` |
|---|---|---|---|---|---|
| Antigravity `AntigravityDailyUsage` | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` | `outputTokens` | `reasoningTokens` |
| Codex `DailyTokenUsage` | `max(inputTokens - cachedInputTokens, 0)` | `cachedInputTokens` | `0` | `outputTokens` | `reasoningOutputTokens` |

After normalization, cross-provider sum, average, and chart rendering can treat the two providers as a single data source.

## Recent Issues & Fixes (July 2026)

### 1. Multi-Workspace & Multi-Instance Port Discovery
- **Issue**: When running multiple workspaces in `Antigravity IDE.app`, each workspace spawns its own isolated `language_server_macos_arm` process listening on a random port. Token usage metadata is kept in the memory of the specific process running that workspace. The previous implementation only queried the first process returned by `discoverServer()`, resulting in missing stats for other workspaces (returning 0 events).
- **Fix**: Updated `AntigravityFetcher` to expose `discoverServers()` which lists all active local servers. `getTrajectoryMetadata` now tries querying all servers sequentially and returns the first non-empty events list. Added `silenceError: true` to `postOptional` to prevent mismatching servers from flooding log files with `trajectory not found` HTTP 500 warnings.

### 2. Empty-RPC retention and cache migration
- **Issue**: A session queried against the wrong workspace server, or a server that is not ready yet, can return an empty event list. Treating that response as a successful empty session would freeze the cache at zero.
- **Fix**: Empty RPC responses are not trustworthy success: the scanner retains last-good daily/samples data, does not advance the file fingerprint, and retries on a later scan. Cache indexes from v5 and earlier are migrated to v6, their old per-event samples are cleared, and existing sessions are forced through the pure-RPC path once.

### 3. Pure-RPC Turn/Round approximation
- **Issue**: The removed SQLite implementation could count `step_type=14/15` directly, but it did not work uniformly across `.db` and `.pb` formats and required reading the IDE's database files.
- **Fix**: The current scanner reads only file metadata and obtains token events plus `stepIndices` through `GetCascadeTrajectoryGeneratorMetadata` for both formats. Rounds count timestamped RPC events; turns are inferred from step-index gaps and are explicitly best-effort.

---

## Helper Script

For raw quota export outside the menu app:

```bash
./scripts/export-antigravity-quota.sh /tmp/antigravity-quota.json
```

This script:

1. discovers the running Antigravity `language_server` (IDE only; CLI not yet supported in the script)
2. extracts its CSRF token
3. calls `RetrieveUserQuotaSummary`
4. prints or writes the raw JSON
