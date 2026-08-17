# GLM Coding Plan — Provider Spec

Provider id: `glm_coding_plan`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift`
- Tests: `Tests/LLMMonitorTests/GlmTests.swift`

The quota portion queries 智谱 (Zhipu / BigModel) GLM Coding Plan's internal monitor
endpoint — the same one used by the official `zai-coding-plugins` — for the 5-hour and
weekly credit windows plus the subscribed tier (Lite / Pro / Max). Token detail is supplied
by the native ZCode local scanner, with the shared OpenCode scanner optionally merged when
the provider's merge switch is enabled.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.glm_coding_plan.apiKey` |
| Required key type | GLM Coding Plan Key, format `<id>.<secret>` (the same key used for Anthropic / OpenAI protocol access) |
| Quota endpoint | `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit` |
| Quota timeout | 15 seconds (`HTTPTimeouts.request`) |
| Quota unit | Remaining credit percent, derived from `remaining / usage` (NOT the response `percentage` field, which is *used* percent) |
| Windows | 5h (interval) + weekly — classified by window metadata, with reset-time fallback |
| Plan tier | `data.level` → capitalized pill (`lite` → `Lite`) |
| Local token source | native ZCode `~/.zcode/cli/db/db.sqlite` (`model_usage`, `provider_id='builtin:bigmodel-coding-plan'`); optional OpenCode `zhipuai-coding-plan` slice merged on top |

## Accounting contract

ZCode 的 `model_usage.input_tokens` 是包含 cache-read 的 raw input，
`cache_read_input_tokens` 是子集。reader 的 daily 路径先计算 uncached input；sample
保留完整 input 以兼容 `LocalTokenUsageSample`。Method A 已在 reader 内完成 reasoning
归类：output/reasoning 进入统一层时已经互斥，不再二次相减。`cache_creation_input_tokens`
只保留为 raw 诊断，不进入统一 total、图表或金额估算。见
[`spec/accounting.md`](../accounting.md)。

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "glm_coding_plan": {
      "enabled": true,
      "apiKey": "your-coding-plan-key-id.secret",
      "peakStartHour": 14,
      "peakEndHour": 18,
      "peakWeekdaysOnly": true,
      "mergeOpencodeUsage": true
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `apiKey` | Coding Plan Key. Empty values and `REPLACE...` placeholders are treated as missing (`ProviderConfig.usableAPIKey`). |
| `refreshIntervalSeconds` | Optional independent refresh interval (overrides global default of 300s). |
| `displayName` | Optional card title override. |
| `peakStartHour` | Peak window start hour (24h, local tz). Default `14`. |
| `peakEndHour` | Peak window end hour (24h, half-open, must be > `peakStartHour`). Default `18`. |
| `peakWeekdaysOnly` | `true` = Mon–Fri only; `false` = every day. Default `true`. |
| `mergeOpencodeUsage` | Adds OpenCode `zhipuai-coding-plan` token data on top of the native ZCode scanner. Missing defaults to `true` for backward compatibility; set `false` to show only the native ZCode local Scanner data. |

Peak fields are optional; when omitted (or when `peakEndHour ≤ peakStartHour`) the window
falls back to the official default (Mon–Fri 14:00–18:00). Omitted fields are not written to
`config.json`.

`GlmCodingPlanFetcher.hasLocalAuth()` always returns `true`; `AppState` validates the config `apiKey`.

## API Request

```http
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
Authorization: <Coding Plan Key>
Content-Type: application/json
```

**Important — auth header**: the Coding Plan Key is sent as a **raw token** in
`Authorization` (no `Bearer` prefix), matching the official plugin and the Anthropic
protocol base URL (`https://open.bigmodel.cn/api/anthropic`). The key format is `<id>.<secret>`.

Logs only include the key length (e.g. `key length=48`), never the key itself or a prefix.

Two related endpoints exist on the same monitor API (not used by the fetcher yet):
`/api/monitor/usage/model-usage` and `/api/monitor/usage/tool-usage` — both accept
`startTime` / `endTime` query params (`yyyy-MM-dd HH:mm:ss`, URL-encoded) for hourly
token / MCP-tool usage charts.

## API Response Schema

Observed successful response (Lite tier):

```json
{
  "code": 200,
  "msg": "Operation successful",
  "success": true,
  "data": {
    "level": "lite",
    "limits": [
      {
        "type": "CREDIT_LIMIT",
        "unit": 3,
        "number": 5,
        "usage": 2000,
        "currentValue": 114,
        "remaining": 1885,
        "percentage": 5,
        "nextResetTime": 1785486276273
      },
      {
        "type": "CREDIT_LIMIT",
        "unit": 6,
        "number": 1,
        "usage": 10000,
        "currentValue": 114,
        "remaining": 9885,
        "percentage": 1,
        "nextResetTime": 1786072666998
      }
    ]
  }
}
```

Important fields:

| Field | Meaning |
|---|---|
| `code` | Business code; `200` = success. **Auth failures come back as HTTP 200 with `code: 1000`** — must be checked in the body, not via HTTP status. |
| `success` | `true` / `false` business flag |
| `data.level` | Subscribed tier: `lite` / `pro` / `max` → card pill |
| `data.limits[]` | One entry per credit window |
| `limits[].type` | `CREDIT_LIMIT` = credit window (older schemas also emit `TOKENS_LIMIT` / `TIME_LIMIT`, which are ignored) |
| `limits[].usage` | **Window total credits** (note: field name is `usage` but it is the *total*, e.g. Lite 5h = 2000, weekly = 10000) |
| `limits[].currentValue` | Credits already used |
| `limits[].remaining` | Credits remaining |
| `limits[].percentage` | **Used** percent [0,100] (NOT remaining — the parser recomputes remaining % from `remaining / usage`) |
| `limits[].nextResetTime` | Millisecond timestamp of next window reset |
| `limits[].unit` / `number` | Undocumented window descriptor; not relied on for classification |

**Credit totals by tier** (from the official Coding Plan docs):

| Tier | 5h credits | Weekly credits | Multiplier (weekly / 5h) |
|---|---|---|---|
| Lite | 2,000 | 10,000 | 5× |
| Pro | 12,000 | 60,000 | 5× |
| Max | 28,000 | 140,000 | 5× |

## API Parser Behavior

`GlmCodingPlanFetcher.parse(data:)` uses `JSONDecoder` with `GlmQuotaResponse` (all-optional
fields, so business-error payloads without `data` still decode).

Processing steps:

1. Decode `GlmQuotaResponse`.
2. Business-code check: if `code != 200` → throw. `code == 1000` (auth) maps to
   `QuotaError.httpError(status: 401, ...)` so the UI shows an auth-style message; other
   codes → `QuotaError.decodingError`.
3. Filter `data.limits` to `type == "CREDIT_LIMIT"` with `usage > 0`.
4. **Classify windows** by stable metadata first: `unit == 3, number == 5` is the 5h
   (interval) window and `unit == 6, number == 1` is the weekly window. When the metadata
   is missing or unknown, fall back to `nextResetTime` ascending for compatibility with
   older responses. This avoids misclassifying windows when a weekly reset happens before
   the 5h reset.
5. Per window: validate `total > 0`, `used >= 0`, `remaining >= 0`. `used > total` is
   allowed because a single Coding Plan task can exceed the nominal window total; that
   window is treated as exhausted (`remainingPercent = 0`) instead of failing the whole
   provider refresh. Otherwise `remaining <= total` is required, and the parser computes
   `remainingPercent = remaining / total * 100` (clamped to [0, 100]).
6. Build a single `ModelQuota` (modelName `glm_coding_plan`, displayName `GLM-5.2`) with
   interval (5h) + weekly windows; present limits map to `QuotaWindowStatus.present`,
   missing weekly limits map to `.absent`, and `intervalWindowSeconds = 18000`,
   `weeklyWindowSeconds = 604800`.

Mapping:

| Response field | Model field |
|---|---|
| `limits[*].usage` | `intervalTotalCount` / `weeklyTotalCount` |
| `limits[*].currentValue` | `intervalUsageCount` / `weeklyUsageCount` |
| `remaining / usage * 100` | `intervalRemainingPercent` / `weeklyRemainingPercent` |
| `limits[*].nextResetTime` (ms) | `intervalResetsAt` / `weeklyResetsAt`; missing 5h value falls back to `now + 5h` |
| `data.level` (capitalized) | `QuotaInfo.planLabel` |

Successful parse returns:

```swift
QuotaInfo(
    models: [model],          // single ModelQuota covering the plan's shared credit pool
    resetCredits: nil,
    planLabel: "Lite",        // tier, capitalized
    accountEmail: nil,
    codexUsageDetails: nil,
    fetchedAt: Date()
)
```

Edge cases handled:
- Single limit returned → interval window only, `weeklyStatus = .absent`.
- Non-`CREDIT_LIMIT` entries (legacy `TOKENS_LIMIT` / `TIME_LIMIT`) → ignored.
- `used + remaining != total` (server rounding off-by-one) → tolerated; remaining % is
  always computed from `remaining / usage`.
- `used > usage` (a large task crosses the nominal window total) → tolerated and treated as
  0% remaining; the actual `currentValue` is preserved for diagnostics.

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `GLM Coding Plan` unless overridden |
| `iconSystemName` | `chevron.left.forwardslash.chevron.right` (`</>`) — no bundled brand asset yet, so `BrandLogoView` falls back to this SF Symbol |
| `accentColor` | `glm` mapped to `.glmBrand` (indigo) |

Window multiplier (`QuotaSummary.weeklyEquivalentMultiplier`): **5** — renders as
`5h × 5 = 周`, matching the tier credit ratio (weekly = 5× the 5h credits).

The card shows the standard two-window layout (5h + weekly remaining %, reset countdown)
and a tier pill (`Lite` / `Pro` / `Max`). The footer renders the shared seven-day
Input/Cache/Output/Reason local-usage chart, fed by the native ZCode scanner with OpenCode's
`zhipuai-coding-plan` slice optionally merged on top (`mergeOpencodeUsage`, default on).
The merged samples also feed the quota-window hover summary.

## Peak Hours Indicator

智谱官方规则：**每周一至周五 14:00–18:00**（用户本地时区）为高峰时段，高峰期模型
调用按基础积分扣费，**非高峰期按 50% 抵扣**（省一半）。卡片在额度行下方显示一条
倒计时提示，颜色分 3 档反映紧迫度：

- **高峰期** 🔥（**红色**）：`高峰期 · 还剩 1小时30分`
- **非高峰期，距高峰 < 1 小时** ❄️（**橙色**，临近）：`距高峰期 45分 · 非高峰 5 折`
- **非高峰期，距高峰 ≥ 1 小时** ❄️（**绿色**，余量充足）：`距高峰期 2小时13分 · 非高峰 5 折`

实现细节：

| Aspect | Behavior |
|---|---|
| Model | `Models/GlmPeakWindow.swift` — `status(at:calendar:)` 返回 `.peak(until:)` / `.offPeak(until:)` |
| Time basis | `Calendar.current`（用户本地时区），与 GLM API 无关 —— refresh 失败也能显示 |
| Live countdown | `Views/GlmPeakIndicatorView.swift` 用 `TimelineView(.periodic(by: 60))`，菜单打开时每分钟自动刷新；关闭时零开销 |
| Window source | `ProviderConfig.glmPeakWindow`（config 派生，`rebuildStatuses` 时挂在 `ProviderStatus.glmPeakWindow`） |
| Defaults | `GlmPeakWindow.zhipuDefault` = Mon–Fri 14:00–18:00 |
| Day classification | `Calendar.weekday`: Mon–Fri = 2…6；周末永远非高峰（`weekdaysOnly`） |
| Boundary | 半开区间 `[startHour:00, endHour:00)`：14:00:00 算高峰，18:00:00 算非高峰 |
| Next peak | 今日 `startHour:00` 未到则取今日，否则逐日扫描跳过非高峰日（覆盖周末） |

窗口完全可配置（设置面板「高峰期提示」段：开始/结束小时 Stepper + 仅工作日开关）；
非法配置（`endHour ≤ startHour` 或越界）整体回退默认。

## Local Token Source (ZCode)

GLM Coding Plan's native local token detail comes from the official ZCode CLI's SQLite
database — the same client used to drive GLM. OpenCode's `zhipuai-coding-plan` slice is an
optional overlay on top (controlled by `mergeOpencodeUsage`, default on).

| Item | Value |
|---|---|
| Database | `~/.zcode/cli/db/db.sqlite` (WAL mode, active `-wal`) |
| Tables | `model_usage` (one row per model request) + `part` (looked up via `model_usage.assistant_message_id` for round-level reasoning classification) |
| Included rows | `provider_id IN ('builtin:bigmodel-coding-plan', 'offpeak-idle-plan')` AND `status = 'completed'` AND (`input + output + reasoning + cache_read`) > 0 |
| Cache | `~/.zcode/cli/.token-monitor/index.json` (versioned, db+WAL fingerprint) |
| Daily window | Seven local calendar days, including today |

The scanner reads the following columns from each GLM `model_usage` row:

```text
started_at                     # epoch ms, source of per-day aggregation
turn_id                        # native turn grouping (one user prompt → one turn)
session_id                     # session dedup for sessionCount
model_id                       # diagnosis + Last Prompt model match
assistant_message_id           # FK to message.id; NULL for session_title, otherwise used
                               #   to test whether a reasoning part exists
input_tokens                   # FULL input (cacheRead is a subset, NOT uncached)
output_tokens                  # generation (includes folded reasoning for GLM-5.2)
reasoning_tokens               # native value when supplied; otherwise Method A may classify output by part type
cache_read_input_tokens        # cache hit
cache_creation_input_tokens    # cache write (bookkeeping, not in total)
```

The scanner also checks the `part` table via `assistant_message_id`:

```text
part.data                      # JSON: {"type": "reasoning"|"text", ...}
                               # any type='reasoning' part classifies that round as reasoning
                               # no character/token ratio is calculated
```

**Input 口径（重要）**：ZCode 的 `input_tokens` 列是**完整输入（含 cacheRead）**，不是
纯新输入 —— 证据：`computed_total_tokens = input_tokens + output_tokens` 恒成立，且
`input_tokens - cache_read_input_tokens` 才是真实的纯新输入（avg≈1k，符合"每轮新增几百到
几千"）。因此 `LocalUsageDaily.input`（= uncached）= `max(input - cacheRead, 0)`，饱和减法
保证 db 取整误差（cacheRead 偶尔 > input）下不产生负值。这与 Codex daily model 的口径
（uncached input + cached input 子集）完全对齐。

`cache_read` is kept as a separate cache bucket. The displayed total is
`uncached_input + cache_read + output + reasoning`; `cache_write` is reported separately
and is not included in the consumption total.

**Reasoning 口径（方案 A — 按 Round 整轮归类）**：GLM-5.2 是 reasoning model。ZCode 的账单层
`model_usage.reasoning_tokens` 列恒为 0 且 `raw_usage_json` 不含 reasoning 字段 —— 但 ZCode
**实际把思考文本存到了 `part` 表**（`type='reasoning'` 的 part，`text` 字段是完整思考过程）。

归类规则（**Method A — 100% 基于账单列和 part 表 JSON 直接判断，不做任何字符/token 换算**）：

| 条件 | 该轮 `output_tokens` 归到哪 |
|---|---|
| `mu.reasoning_tokens > 0`（账单层直接给出，priority path） | `reasoning_tokens` 报账单值, `output_tokens` 报账单值（独立两列；不重分类） |
| `assistant_message_id` 存在 + `part` 表有 `type='reasoning'` part | `reasoning_tokens = output_tokens`, `output_tokens = 0`（**整轮归 reasoning**） |
| `assistant_message_id` 存在 + `part` 表无 `type='reasoning'` part（含 text-only / 缺 type 字段 / 合法 JSON 但无 reasoning part） | `reasoning_tokens = 0`, `output_tokens = output_tokens`（保持原样） |
| `assistant_message_id IS NULL`（`session_title` 后台任务 / 早期数据） | `reasoning_tokens = 0`, `output_tokens = output_tokens`（无 part 可关联） |

实现：`GlmZcodeDBReader.queryPerDay` 的 `SUM(CASE ... WHEN EXISTS (... type='reasoning') ...)`
里，per-row 把 `output_tokens` 整轮归到 reasoning 列（或保持 output 列），不走字符比例估算。
**不是 token 级精确拆分**,而是"该 round 是否整轮算 thinking"的硬分类。

> **关于字符分摊**: 早期 (v 之前) 实现曾按 `reasonChars / (reasonChars + textChars)` 比例把
> `output_tokens` 拆成 `(realOutput, reasoningTokens)`,跟 minimax 同构。该路径已弃用:
> - 估算误差大(中英文字符/token 比例不一致,代码块 / Markdown 字符密度差异)
> - 跟当前 Method A 重复(同一份 part 文本既被字符分摊也被 EXISTS 归类)
> - 维护成本高(scanner 还要在 aggregation 末尾按日比例回写 sample)
> 决策:**统一到 Method A**,删掉所有字符分摊代码;spec 也只描述 Method A 行为。
> minimax spec 里的"字符分摊"跟 GLM 的 Method A 是**完全不同的两套实现**,不可混用。

| 边界条件 | 行为 |
|---|---|
| `assistant_message_id IS NULL` | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part` 表无该 `message_id` 对应行 | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part.data` 缺 `type` 字段 / `type='text'` / `type='tool'` | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part.data` 损坏 JSON | reader 先用 `json_valid` 将其替换为 `{}`，再执行 `json_extract`；走 ELSE 分支（output 保持原样、reasoning=0），静默处理 |
| 未来 ZCode 账单层直接写 `reasoning_tokens > 0` | priority path: `output_tokens` 报账单值, `reasoning_tokens` 报账单值（独立加总） |

**实测分布**（189 行 / 单 session, 2026-08-02）: Method A 把 88 / 189 行（47%）的
`output_tokens` 整轮归为 reasoning（part 表里有 `type='reasoning'` part），跟 GLM-5.2
"思考重" 的直觉一致。剩余 101 / 189 行（`session_title` 后台任务 + text-only part）保持
output 不变,`reasoning_tokens = 0`。

OpenCode 的 `zhipuai-coding-plan` 分片本身有原生 reasoning tokens（`mergeGlm` 相加合并），
所以合并后 reason 数据来自两个独立源交叉验证。如果 Method A 估值跟 OpenCode 原生 reason
差异巨大（>20%），说明 ZCode schema 变了（新增 reason 字段 / part 类型变化），
需要重新评估 reader 逻辑。

per-sample 分布：reader 直接输出 `LocalTokenUsageSample.reasoningOutputTokens` 跟 `outputTokens`
(Method A 已经在 SQL CASE 里算好),scanner 不再额外做 sample 回写——比字符分摊时代少一层
"按日比例回写"的复杂度。

### Rounds and turns

- **rounds** = `COUNT(*)` — every `model_usage` row is one tokenized LLM call (including
  main-agent, subagent, retry, and `session_title` background generation).
- **turns** = `COUNT(DISTINCT turn_id)` — ZCode emits a native `turn_id`; all model calls
  triggered by one user prompt share the same `turn_id` and count as one turn.
- The recent sample prompt IDs are `session_id:turn_id` (falling back to
  `session_id:event-<id>` when `turn_id` is null). Before cross-source merging, OpenCode
  sample prompt IDs are namespaced with the `opencode:zhipuai-coding-plan:` prefix so a
  native ZCode prompt ID and an OpenCode prompt ID never collide.

### Input display (chart vs hover)

Both the 7-day stacked bar chart and the quota-window hover show the **uncached** input as
the primary "input" number, so the two views never disagree:

- **7-day chart** (`LocalUsageDaily.input`): `GlmDailyUsage.inputTokens` is already uncached
  (= `max(input_raw - cacheRead, 0)`), computed in the reader.
- **Hover** (`UsageMetricHoverSummaryView`): the shared `input` line renders
  `usage.uncachedInputTokens` (= `max(inputTokens - cachedInputTokens, 0)`) with the cache
  amount shown as a `(+N cached)` suffix. `UsageMetricSummary.inputTokens` keeps its
  project-wide "full input (cache is a subset)" invariant; `cacheHitRate` is still computed
  against full input.

This is a global hover change (applies to all four providers) so the Input number is never
the full input masquerading as new input.

### Off-peak tasks (闲时任务)

ZCode 的闲时任务是系统赠送的、**不消耗 Coding Plan 积分**的后台任务（需提前排队）。
它的 `model_usage` 行写在同一张表，但 **`provider_id` 是独立的 `offpeak-idle-plan`**
（不是 `builtin:bigmodel-coding-plan`）；落在 `off_peak_tasks.[started_at, ended_at]`
时间窗口内的调用不扣积分。

| 位置 | 是否包含闲时任务 token |
|---|---|
| 今日 / 7 天本地 token 柱图（footer） | **包含**（真实 token 消耗，按日聚合不经过窗口过滤） |
| 5h / week 额度窗口 hover（`primaryUsage` / `weeklyUsage`） | **排除**（不消耗积分，计入会高估额度消耗） |

实现：`GlmZcodeDBReader` 同时读 `builtin:bigmodel-coding-plan` 与 `offpeak-idle-plan`
两个 provider 的 `model_usage` 行（`provider_id IN (?, ?)`），让闲时任务的真实消耗进入
今日 / 7 天柱图。scanner 每次扫描额外读 `~/.zcode/v2/tasks-index.sqlite` 的
`off_peak_tasks` 表（`status='completed'` 且 `started_at` / `ended_at` 都非空），产出
`[GlmOffPeakWindow]` 挂在 `GlmLocalUsage.offPeakWindows`。`LocalUsageSummaryBuilder.summary`
的额度窗口路径优先读取 sample 上保存的原始 `provider_id`：只有
`offpeak-idle-plan` 精确归为闲时；同一时间窗口内的正常 Coding Plan 调用不会被误排除。
旧缓存没有来源字段时，才回退到 `completedAt` 是否落入闲时窗口（闭区间 + 2 秒容差）。
OpenCode 合并 sample 带独立命名空间，始终视为正常消耗。

> 缓存版本 8：v7 已覆盖双 provider，但 recent sample 没有 `sourceProviderID`；升级后
> 即使 db 指纹没变也会重扫，确保额度窗口使用精确 provider 归属。

### Implementation map

| Responsibility | Source |
|---|---|
| Data model | `Sources/LLM-monitor/Models/GlmLocalUsage.swift` |
| SQLite reader | `Sources/LLM-monitor/Services/GlmZcodeDBReader.swift` |
| Off-peak window reader | `Sources/LLM-monitor/Services/GlmZcodeOffPeakReader.swift` |
| Scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift` |
| Field-level merge with OpenCode | `Sources/LLM-monitor/Models/OpencodeUsageMerger.swift` (`mergeGlm`) |
| Window summary + off-peak exclusion | `Sources/LLM-monitor/Models/LocalTokenUsageSample.swift` (`summary(excludeGlmOffPeak:)`) |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` + `QuotaViews.swift` |
| Regression tests | `Tests/LLMMonitorTests/GlmTests.swift` |

## API Error Handling

| Situation | Current error |
|---|---|
| Empty API key passed to fetcher | `未配置 API Key` (`QuotaError.missingAPIKey`) |
| URLSession error | `网络错误：<system message>` |
| Non-HTTP response | `响应格式无效` |
| HTTP non-2xx | `HTTP <status>: <body preview>` (rare — monitor API returns 200 even for errors) |
| `code == 1000` (auth failed) | `HTTP 401: Coding Plan Key 无效或已过期（身份验证失败。）` |
| `code` other non-200 | `解析失败：GLM Coding Plan 返回错误 [<code>]: <msg>` |
| Missing `data` | `解析失败：响应缺少 data` |
| No `CREDIT_LIMIT` entries | `解析失败：GLM Coding Plan 未返回任何有效积分额度` |
| Counts invalid (e.g. `remaining > total`) | `解析失败：GLM Coding Plan 积分额度字段非法: ...` |

**Auth failure is HTTP 200**: the 智谱 monitor API validates the key at the business layer,
returning `{ "code": 1000, "msg": "身份验证失败。", "success": false }` with HTTP 200. The
parser therefore checks `code`, not the HTTP status. `code == 1000` is re-mapped to an
HTTP-401-style error so the failed-state UI clearly signals an auth problem.

## Rate Limits

No client-side backoff beyond the configured refresh interval. On business/HTTP errors,
`AppState` moves the provider to `.failed` and shows the previous `QuotaInfo` from
`state.lastSuccess` if available. Default global refresh interval is 300 seconds; a
provider-specific interval can be set via `refreshIntervalSeconds`.

## Known Limitations

- **OpenCode only as the overlay source.** The native local scanner reads ZCode's
  `model_usage` table; OpenCode's `zhipuai-coding-plan` slice is an optional overlay
  (default on). Turning `mergeOpencodeUsage` off leaves only the native ZCode data.
- **OpenCode only for the second token source.** The `/api/monitor/usage/model-usage`
  endpoint exists and returns hourly aggregate tokens (without the Input/Cache/Reason/Output
  split used by the shared chart), so it is not used as a remote second GLM data source.
- **No account email.** The quota/limit response has no email field, so the card has no
  account hover (unlike Antigravity).
- `unit` / `number` window descriptors are used when present; `nextResetTime` remains the
  compatibility fallback for older responses or incomplete metadata.
- `data.limits` schema is empirical (captured from a live Lite-tier account). Pro / Max
  tiers and future API changes are covered by the lenient optional-field decoder, but
  edge cases may surface.
- Only the `open.bigmodel.cn` host is wired. The same monitor API is mirrored at
  `api.z.ai` (Z.ai) per the official plugin; supporting it would be a config-driven
  endpoint change.

## Test Coverage

`Tests/LLMMonitorTests/GlmTests.swift` — the GLM fetcher, peak-window, native scanner,
and OpenCode merge tests are consolidated in one file:

| Test | What it verifies |
|---|---|
| `testGlmCodingPlanFetcherParsingAndWindows` | Successful response, both windows, plan label, and display name |
| `testGlmFetcherErrorHandling` | Business failure and empty-limit error paths |
| `testGlmCodingPlanFetcherErrorPaths` | Invalid remaining/total boundary |
| `testGlmPeakWindowStatusRules` | Peak-window status and config mapping |
| `testGlmPeakWindowBoundaryAndWeekdaysOnly` | Half-open boundary and weekday filtering |
| `testGlmZcodeDBReaderMethodAClassification` | Native/reasoning-part priority, malformed JSON fallback, and conservation |
| `testGlmZcodeDBReaderNativeAndSnapshot` | Native aggregation, samples, snapshot padding, and today selection |
| `testGlmReaderAppliesRecentCutoffToDailyAggregation` | Recent cutoff applies to daily aggregation and samples |
| `testOpencodeUsageMergerMergeGlm` | OpenCode GLM usage merge |

`StateAndSchedulerTests.testLocalUsageScanTriggerTimingPolicy` covers the startup timing
policy.

The native ZCode scanner and OpenCode merge coverage is included above. The scan-trigger timing
is locked by `StateAndSchedulerTests.testLocalUsageScanTriggerTimingPolicy`: Minimax and GLM
scan immediately on app start, while Antigravity waits for main-quota success.

### Independent periodic trigger

All local scanners normally only fire after their provider's quota refresh **succeeds**.
For GLM this creates a blind spot: when the GLM quota keeps failing (expired key, network),
the scanner never runs and new ZCode token consumption never reaches the chart.

To close this gap, GLM has a dedicated periodic trigger (`AppState.glmLocalUsagePeriodicTask`)
that fires `triggerGlmLocalUsageScan()` on the GLM provider's `refreshIntervalSeconds` (same
cadence as quota), **independent of quota success**. The scanner's db+WAL fingerprint check
ensures that when nothing changed only a `stat()` runs (microseconds); SQL (~1.5ms) only runs
when the WAL actually moved. Wired in `AppState.start()` / cancelled in `stop()`; the wiring
is locked by `StateAndSchedulerTests.testGlmLocalUsagePeriodicTriggerWiredInStartAndStop`.
