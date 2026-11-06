# ChatGPT Plan — Provider Spec

Provider id: `codex_chatgpt`

Implementation: `Sources/LLM-monitor/Fetchers/CodexFetcher.swift`

This provider consumes the access token and account metadata supplied by the local Codex authentication file, then calls ChatGPT backend quota endpoints. The local auth file and session usage source are documented in the [Codex harness spec](../harnesses/codex.md). Tokens are not stored in `LLM-monitor`'s own config file.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | Local Codex `auth.json`; see the [harness spec](../harnesses/codex.md#codex-auth-file) for path resolution and file structure. |
| Token refresh | Not implemented; assumes Codex CLI/Desktop has already refreshed auth |
| Main endpoint | `GET https://chatgpt.com/backend-api/wham/usage` |
| Reset credits endpoint | `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` |
| Timeout | 15 s (`HTTPTimeouts.overseas`)；响应体上限 8 MiB (`ResponseByteLimits.standardQuota`) |
| Model rows | One synthetic model: `chatgpt_plan` |
| Reset credits | Parsed and displayed when entries exist |
| Plan label | Parsed from `id_token` JWT when available |
| Account email | 解析自 `auth.json` 顶层 / `tokens.email`，缺失时回退 `id_token` JWT 的 `email` 或 `https://api.openai.com/profile.email`；与 `planLabel` 一起进卡内 Account Info 行 |
| Local usage details | Attached by the Codex harness after the provider batch settles; see the [harness spec](../harnesses/codex.md#local-usage-aggregation). |
| Local pricing models | GPT-5.5, GPT-5.6 Sol, GPT-5.6 Terra, GPT-5.6 Luna, GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-6 Astra |

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
| `authPath` | Optional custom auth location. Accepts either an `auth.json` file path or its parent directory; see the [harness spec](../harnesses/codex.md#codex-auth-file) for default path resolution. |
| `adminApiCreditsEnabled` | 是否启用 OpenAI API 赠金监测。缺省为 false。开启后在卡内追加「API赠金」进度条。 |
| `adminApiKeys` | 多 Admin API Key 配置数组（`[CodexAdminKeyConfig]`），支持多组织/多工作区独立追踪。每个元素包含 `id`、`label`、`apiKey`、`monthlyQuotaLimit`、`billingDay`、`billingTime`。优先于标量 Key。 |
| `adminApiKey` | OpenAI Admin API Key (`sk-admin-..`)，历史单 Key 兼容字段。未配置 `adminApiKeys` 时透明回退。 |
| `adminBillingDay` | 每月账单日（1-31，缺省 11）。单 Key 兼容模式使用。 |
| `adminBillingTime` | 账单重置时间（`HH:mm`，如 `00:00` 或 `08:00`，缺省 `00:00`）。单 Key 兼容模式使用。 |
| `adminMonthlyQuotaLimit` | 每月赠金额度上限（美元，缺省 40.0）。单 Key 兼容模式使用。 |
| `notifyIntervalRestored` etc. (4 fields) | Optional per-event notification channels (5h/weekly × restored/exhausted): `none` / `system` / `barkAndSystem`. Defaults: restored → `system`, exhausted → `none`. See `spec/notifications.md`. |


## Auth Consumption

`CodexFetcher` reads `auth.json` via its configured `authPath` (or the Codex home default) and consumes the access token, optional account ID, email, and ID-token claims. File location, schema, and client-side behavior belong to the [Codex harness spec](../harnesses/codex.md#codex-auth-file).

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

Per-window validation in `parseWindow` (a window failing any of these is treated as
absent, not as a healthy window):

- `used_percent` must be a real JSON number (booleans rejected via
  `DateParser.isBoolean`), finite, and within `0...100`.
- The window length comes from `limit_window_seconds`; when that key is absent the
  parser falls back to `window_minutes` and converts (`× 60`, overflow-checked). Either
  way the value must be a positive integer not exceeding
  `CodexFetcher.maxUsageWindowSeconds` (366 days) — a 5 h window is `18000`, a weekly
  window is `604800`. No length key at all leaves the length `nil`; consumers then
  degrade safely (5 h / 7 d fallbacks) instead of synthesizing a boundary.

`reset_at` is parsed by the shared `DateParser.parse`, so it can be:

- ISO-8601 string, with or without fractional seconds
- numeric string (`"1783234800"` / `"1783234800000"`)
- Unix timestamp number — treated as seconds, except that `|value| > 1_000_000_000_000`
  is treated as milliseconds

Values outside `0001-01-01 … 9999-12-31` (or non-finite) return `nil`; the fetcher then
passes `resetsAt = nil` through rather than fabricating a boundary.

If `rate_limit` or its primary window is missing/invalid, parsing fails instead of fabricating a
healthy quota. A missing or invalid secondary window maps to `weeklyStatus = .absent`; a valid
secondary window remains `.present` even when its remaining percentage is `0%`.

## OpenAI API 赠金（API 赠金）

ChatGPT 用户每月可享受官方免费 API 额度福利（API 赠金）。本模块通过 OpenAI 官方 Admin 接口监测组织用量，支持多 Key 并发抓取与独立配额追踪，并按滑动账单周期计算当前周期的额度消耗与剩余有效期。

### 多 Key 配置与兼容回退

通过 `providers.codex_chatgpt.adminApiKeys` 配置多 Key 列表（`[CodexAdminKeyConfig]`），支持多组织 / 多 Workspace 并行追踪。每个条目包含独立的 `id`、`label`、`apiKey`、`monthlyQuotaLimit`、`billingDay`、`billingTime`。未配置 `adminApiKeys` 时由 `effectiveAdminKeys` 透明回退到历史标量字段（`adminApiKey`、`adminBillingDay`、`adminBillingTime`、`adminMonthlyQuotaLimit`）。

### 端点、并发抓取与鉴权

```http
GET https://api.openai.com/v1/organization/costs?start_time=<cycle_start_epoch>&bucket_width=1d&limit=35
Authorization: Bearer <admin_api_key>
```

- **并发多 Key 抓取（`withTaskGroup`）**：
  当 `adminApiCreditsEnabled` 开启且 `effectiveAdminKeys` 非空时，`CodexFetcher` 在 `fetch(mode:)` 中通过 `withTaskGroup(of: (Int, Result<OpenAIApiCreditDetails, Error>).self)` 并发执行所有 Key 的 `fetchAdminCosts(keyConfig:mode:)`。抓取结果带原始索引以严格保序返回。
- **数据解析**：按日 bucket 聚合所有 `results` 下 `amount.value`，累加得到当前账单周期内的已消耗金额 `usedAmount`。
- **空间名称获取**：优先从 costs 响应 results 的 `organization_name` 获取；缺失时若备注 `label` 非空且不为 `"Default"`，优先作为空间名称；若仍无且处于 `.full` 模式，按次要信息频率调用 `GET https://api.openai.com/v1/me` 读取 `orgs.data[0].title`。`.background` 不调用 `/v1/me`，新赠金结果缺组织名时 merger 继承旧组织名，金额/账期/抓取时间使用新值；`.full` 采用本次查询结果（包括 nil）。普通请求或解析失败按可选元数据处理，显示「未知组织」。取消 `/v1/me` 请求会传播取消，不会把被取消的赠金查询记成成功。

### 隔离容错与快照合并（Fault Isolation & Merging）

- **Key 间错误隔离**：
  在 `withTaskGroup` 中，每个 Key 的网络异常、HTTP 401 Unauthorized、HTTP 429 Too Many Requests 或 HTTP 500 均被独立捕获（`.failure(error)`）。**任一 Key 的异常绝不中断兄弟 Key 的并发执行，亦不导致整体抓取批次终止**。
  - 对于失败的 Key，`CodexFetcher` 构造该 Key 独立的 `OpenAIApiCreditDetails`（保留配置的账单周期与配额上限，附带 `lastAttemptFailed = true` 与 `errorMessage = err.localizedDescription`）。
- **与 ChatGPT Plan 主配额完全隔离**：
  - Admin API 全部或部分 Key 失败均不会导致 ChatGPT Plan 5h/周配额刷新失败；
  - 当本地 Plan auth (`auth.json`) 缺失或损坏、但 Admin API Key 可用时，仍可独立成功拉取各 Admin Key 赠金；此时 `QuotaInfo` 将本次结果作为主 quota 失败记录 `mainQuotaError = "Codex Plan auth 缺失"`，但保留成功的 `openAIApiCreditsList`。
- **多 Key 快照合并（`CodexFillingMissingMerger`）**：
  在 `RefreshResultMergers.swift` 中，merger 将 `new.allOpenAIApiCredits` 与 `previous.allOpenAIApiCredits` 逐 Key 比对合并：
  - **键匹配策略**：优先按 `keyId` 精确匹配；其次按非通用的 `organizationName`（`!= "未知组织"`）匹配；最后按数组索引对齐。
  - **失败 Key 保留旧值**：若新快照中某 Key `lastAttemptFailed == true`，且上一轮快照中存在对应 Key，merger 调用 `prev.markingStale(errorMessage: newKey.errorMessage)` 保留上次成功的消耗金额与周期，仅更新陈旧标记与错误说明；若为首刷失败无旧值，则直接采用新失败明细。
  - **后台组织名继承**：若某 Key 在 `.background` 抓取成功但未包含组织名，自动继承上一轮成功的 `organizationName`。
  - 若所有 Key 均失败且无成功 Key，`new.openAIApiCreditsError` 统一标记为 `"API赠金抓取失败"`。

### 数据模型（Data Model）

- `QuotaInfo` 维护统一多 Key 状态：
  - `openAIApiCreditsList: [OpenAIApiCreditDetails]?`: 完整的多 Key 额度明细数组；
  - `openAIApiCredits: OpenAIApiCreditDetails?`: 指向主 Key / 首个 Key，保证向后兼容；
  - `allOpenAIApiCredits: [OpenAIApiCreditDetails]`: 计算属性，优先返回 `openAIApiCreditsList`，若无则返回 `[openAIApiCredits]`，保证 UI 迭代干净统一。
- `OpenAIApiCreditDetails` 契约（符合 `Identifiable`）：
  - 属性：`keyId: String?`、`keyLabel: String?`、`organizationName: String?`、`totalQuota: Double`、`usedAmount: Double`、`cycleStart: Date`、`cycleEnd: Date`、`fetchedAt: Date?`、`lastAttemptFailed: Bool?`、`errorMessage: String?`；
  - 稳定标识符：`id` 单源派生自 `keyId ?? organizationName ?? UUID().uuidString`；
  - 派生算法：
    - `remainingAmount = max(0, totalQuota - usedAmount)`；
    - `remainingPercent`: `(remainingAmount / totalQuota) * 100`，`totalQuota <= 0` 时保护为 0%，防除以零；
    - `timeRemainingFraction(at:)`: 周期时间进度，钳位于 `[0.0, 1.0]`，供进度条红色倒三角 `▼` 指示。

### 账单周期算法

- 由 `OpenAIApiCreditDetails.currentBillingCycle(day:hour:minute:now:)` 计算：
  - 账单日：`1...31`（自动夹取至当月实际最大天数，如 2 月 28/29 日）；
  - 重置时刻：`HH:mm`（时分级切换精度，如 `08:00`）；
  - 滑动周期判定：若 `now >= 当月重置锚点`，周期为 `[当月锚点, 次月锚点)`；若 `now < 当月重置锚点`，周期为 `[上月锚点, 当月锚点)`。跨年时 12 月与 1 月正确滚转。

### UI 呈现（`ChatGPTApiCreditsRow`）

在 ChatGPT Provider 卡片内为每个已配置并启用的 Admin API Key 独立渲染一行 `ChatGPTApiCreditsRow`：
- **标题行**：左侧显示 `API赠金 · <Key 名称>`，名称使用设置中配置的 `label`（对应 `keyLabel`，去除首尾空白）；未命名时按列表顺序显示 `API赠金 · API Key #N`，不再用币种 USD 区分 Key。长标题单行居中截断，tooltip 显示完整名称。右侧独立显示组织/工作区名称（缺省「未知组织」）。
- **独立进度条**：每个 Key 拥有专属的单段 `SegmentedQuotaProgressBar`（高 8pt，自适应绿/黄/红分级着色，带有表示周期时间进度的红色倒三角 `▼`），独占整行通栏显示。
- **独立明细行**：单行整合呈现「已用 <used> 剩余：<remaining>/<total>」与该 Key 专属的「周期至 MM-dd HH:mm（剩余xx）」。
- **局部错误与警告指示**：若某单个 Key 抓取失败或处于陈旧状态，仅在该 Key 的明细行周期信息前显示警告图标（带详细 tooltip 与 accessibility label），展示上次成功的数据及独立错误提示，兄弟 Key 进度条和明细正常展示不受干扰。

## Local Pricing Snapshot

`ModelPricingCatalog` 对 OpenAI/Codex 建立的本地价目快照（USD per 1M tokens）。价格
数据已迁移到随 app 打包的
[`Sources/LLM-monitor/Resources/ModelPricing.json`](../../Sources/LLM-monitor/Resources/ModelPricing.json)（`ModelPricingCatalog` 启动时加载；快照更新时间以 JSON 顶层 `lastUpdated` 字段为准，即 `ModelPricingCatalog.lastUpdated`）。调价 / 增删模型需改 JSON，并同步 `ModelPricingJSONTests` / `ProviderModelTests` 的价格断言与本 spec 的价格表。下表仍然有效：

| Model | Input | Cache read | Output |
|---|---|---|---|
| gpt-5.5 | 5.00 | 0.50 | 30.00 |
| gpt-5.6-sol | 4.00 | 0.40 | 20.00 |
| gpt-5.6-terra | 2.00 | 0.20 | 12.00 |
| gpt-5.6-luna | 0.20 | 0.02 | 1.20 |
| gpt-6.1-sol | 2.00 | 0.10 | 10.00 |
| gpt-6.1-terra | 1.00 | 0.05 | 5.00 |
| gpt-6-sol | 2.00 | 0.20 | 10.00 |
| gpt-6-luna | 0.10 | 0.01 | 0.50 |
| gpt-6-astra | 10.00 | 1.00 | 50.00 |

两条约束：

1. 匹配规则是精确相等（model 小写后 `==`），不是 `contains`；未来带变体后缀的 slug 需要显式加入目录后才会被计价。
2. Cached Write 官方虽有定价，但 Codex 不上报 cache write 字段，目录不建模。

### August 2026 Team weekly value estimate

For the August 2026 Team plan, the observed value of one weekly quota window is approximately
**$58** under the following comparison convention:

| Model family | Valuation convention |
|---|---|
| Terra / Luna | Use the normal model prices in [`ModelPricing.json`](../../Sources/LLM-monitor/Resources/ModelPricing.json) |
| SOL | Apply an effective value discount coefficient of `0.7` to the normal price-equivalent value |

`0.7` is effective from 2026-09-01; before that date the coefficient was `0.56`. The August 2026
calibration below still uses the old `0.56` coefficient.

This is an inferred usage-value estimate, not an official invoice amount. In the 2026-08-15 to
2026-08-19 sample, assuming the reported usage represented approximately 20% of the weekly
window, the adjusted value is:

```text
(SOL value × 0.56 + Luna value + Terra value) ÷ 0.20 ≈ $58
```

The estimate is valid only when the same model mix and pricing assumptions are used. The sample's
2026-08-19 snapshot was incomplete, so this should be treated as an approximate calibration
target rather than a hard quota or billing limit.

### September 2026 valuation convention & empirical calibration (2026-09-09)

#### Historical evolution
- **2026-09-06 (Initial hypothesis)**: GPT-6 Astra was tentatively modeled with a discount coefficient of `0.7` alongside SOL `0.7`, with nominal window anchors of 5h `$10` / weekly `$60`.
- **2026-09-09 (Empirical calibration)**: Two complete 100% depletion cycles on the same day (afternoon 441 turns, evening 148 turns) provided hard server telemetry that refuted the initial `0.7` guess for Astra and established the canonical parameters.

#### Canonical valuation model ($Q = \$10.00$)

| Model family | Valuation coefficient | Rationale |
|---|---|---|
| **GPT-6 Astra** | **`1.00`** (100%) | Flagship model, billed at full price (no platform subsidy). |
| **GPT-5.6 Sol** | **`0.70`** (70%) | Platform workhorse model, 30% subsidy (consistent with the 2026-09-01 update). |
| **GPT-5.6 Luna** | **`1.00`** (100%) | Ultra-cheap tier ($0.02/1M cached), billed at full price. |
| **GPT-5.6 Terra** | **`1.00`** (100%) | Normal price in `ModelPricing.json`. |
| **5h Window Anchor** | **`$10.00`** | Base quota capacity, strictly aligning with the weekly anchor ($6 \times \$10 = \$60$). |
| **Weekly Window Anchor**| **`$60.00`** | Six 5h windows per weekly quota. |

#### Empirical dual-cycle validation (2026-09-09)

Two complete 100% depletion cycles were monitored and logged in session JSONL files on 2026-09-09:

1. **Cycle 1 (Afternoon, 441 turns, Sol-dominated)**:
   - Window: 09:10 to 11:17 UTC (17:10 to 19:17 Beijing).
   - Raw total: `$12.1553` (Sol raw `$9.39`, Astra raw `$1.87`, Luna raw `$0.90`).
   - Adjusted total under canonical model: `$9.32` pre-cutoff, overshooting to `$10.28` after a heavy final turn.

2. **Cycle 2 (Evening, 148 turns, Astra/Sol mixed, 100% pure closed test)**:
   - Window: 13:43 to 15:42 UTC (21:43 to 23:42 Beijing). Total duration 1h59m (< 5h rolling window, zero token expiration).
   - Raw total: `$12.2287` (Sol raw `$7.5515`, Astra raw `$4.6135`, Luna raw `$0.0638`).
   - **Adjusted total under canonical model**: **`$9.9633`** out of `$10.00` (**99.63%** precision, only $0.036 difference).
   - Turn-by-turn MAE across all 148 turns: **1.45%**.
   - **Weekly secondary window increment**: Exactly `+16.0%` (from 30.0% to 46.0%), matching $1/6$ of the weekly window ($\approx 16.67\%$).

#### Empirical quota & rate-limit discoveries

1. **Server `rate_limits` telemetry discovered in session JSONL**:
   Codex session logs (`token_count` events) carry live OpenAI server rate-limit headers:
   ```json
   "rate_limits": {
     "limit_id": "codex",
     "plan_type": "team",
     "primary": {
       "used_percent": 100.0,
       "window_minutes": 300,
       "resets_at": 1788979411
     },
     "secondary": {
       "used_percent": 46.0,
       "window_minutes": 10080,
       "resets_at": 1789436632
     }
   }
   ```
   - Confirms `primary.window_minutes = 300` (exact 5-hour rolling window).
   - Confirms `secondary.window_minutes = 10080` (7-day / weekly rolling window).
   - Confirms `plan_type = "team"`.

2. **Pre-execution admission check & overshoot mechanics (`T-1 < 100%, T >= 100%`)**:
   - The rate-limiting gate verifies quota before a turn starts:
     - **$T-1$**: Server evaluates `floor(used_percent) < 100%` (e.g. 99.0%). Because usage is strictly below 100%, turn $T$ is admitted.
     - **$T$**: Turn $T$ runs to completion regardless of token size (even for large 100k+ token completions costing $0.05 ~ $0.50). This pushes cumulative usage across the $10.00 mark (observable overshoot up to $10.05 ~ $10.70).
     - **$T+1$**: Subsequent request is immediately blocked with `"codex_error_info": "usage_limit_exceeded"` (`Your workspace is out of credits. Add credits to continue.`).
   - **Overshoot clarification**: The apparent cumulative consumption of ~$10.50 ~ $11.00 at hard block is an artifact of the pre-execution admission policy, not an $11 nominal quota. The true rate-limiting anchor is $10.00.

3. **Rounding & UI Quantization**:
   - **Server admission**: Uses `floor()` semantics on usage percentage to protect users from early cutoff (e.g. 99.79% is held at 99.0%).
   - **Client UI**: Formats remaining quota using standard `round()` (e.g. 81.04% used $\implies 81\%$ used, displaying exactly 19% remaining).

### 2026-10 update: load-dependent 5h anchor (2026-10-28)

Official behavior confirmed on 2026-10-28: the 5h window value is **not a fixed \$10.00** —
it floats in the **\$8 ~ \$10** band depending on server load, with \$10 as the upper bound.
The weekly anchor (**\$60**, 6 × upper-bound 5h) is unchanged.

Consequences for the canonical model above:

- The 2026-09-09 dual-cycle calibration (99.63% precision against \$10.00) is reinterpreted as
  an **upper-bound-day sample**; the model coefficients (Astra 1.00 / Sol 0.70 / Luna 1.00 /
  Terra 1.00) remain the working set.
- Deriving "remaining dollars" from the fixed \$10 anchor **overestimates** remaining quota on
  low-load days: if the day's true window is \$8, a displayed 50% remaining is \$4, not \$5.
- The overshoot mechanics (\$10.05 ~ \$10.70 observed at hard block) stay consistent with the
  \$10 upper bound; on low-load days the hard block lands correspondingly earlier in dollars.

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

Date parsing (shared `DateParser.parse`) accepts:

- ISO-8601 with fractional seconds
- ISO-8601 without fractional seconds
- Unix seconds
- Unix milliseconds
- numeric strings in either unit

Bounds enforced by `CodexFetcher.maxResetCreditEntries` (1,000): `available_count` must be
a strict non-negative integer in `0...1000`, `total_earned_count` a strict non-negative
integer, and a `credits` array longer than 1,000 fails the sub-request. `available_count`
absent → `serverAvailableCount = nil` and the UI counts `status == "available"` entries
itself (`ResetCreditsInfo.availableCount`).

If `credits` is missing, the provider returns an empty entries array. If `credits` is
empty — or simply carries fewer `available` entries than the server-reported
`available_count` — the parser appends synthetic `available` entries (`id = synthetic-<i>`,
no expiry/granted date) so the UI can still show a remaining count. A response that would
push the entry list past 1,000 after that top-up is rejected instead of truncated.

Reset-credit fetch failure does not fail the provider refresh. The fetcher logs a warning
and returns the quota model with `resetCredits = nil`; `CodexFillingMissingMerger` then
distinguishes "failed" (marks the row 可能过期) from "skipped by design" (keeps the
previous value and its freshness untouched) based on the refresh mode.

`fetchResetCredits` does not log raw response bodies (`includeBodyInError: false`); only summary count info is logged.

### Refresh cadence & freshness (reset credits)

`fetchResetCredits` only runs on `.full` refresh — i.e. app startup, manual refresh
(header button / card context menu / menu-bar right-click), menu open when a `.ready`
provider exists, and the scheduler's periodic refresh of secondary information. The setting
is shown as 「次要信息频率」, with a UI range of 1...30 and default 20; the persisted
`periodicFullEveryN` key remains for compatibility. Each provider runs one `.full` refresh
per N regular ticks: N−1 `.background` ticks followed by one `.full` tick. N=1 therefore
makes every regular tick `.full`. At the default 300 s provider interval, N=20 refreshes
reset credits about every `20 × 300 s = 100 min`; with a 180 s provider interval and N=2,
the interval is 6 minutes.
Existing configured values are retained, while values above 30 normalize to 30.
`.background` ticks intentionally skip the reset-credits request.

The setting controls independent secondary-information requests: Codex reset credits and
the optional `/v1/me` organization lookup, GLM reset cards and marketing polling, and
Antigravity account/tier RPCs. OpenAI API credits are fetched on every Codex
provider refresh, and `codexUsageDetails` are attached by local-usage reconciliation after
each settled provider batch; neither uses this secondary-information cadence.

Reset credits carries its own freshness metadata (`fetchedAt` / `lastAttemptFailed`), separate
from the main `QuotaInfo.fetchedAt`:

- `.background` skip keeps the previous value and its original `fetchedAt` / failure flag — it
  is **not** treated as a failure and never advances the main provider `failureCount`.
- A `.full` whose reset-credits sub-request fails keeps the previous value and marks
  `lastAttemptFailed`, so the row shows "可能过期" immediately.
- Recovery on the next successful `.full` clears the flag and updates `fetchedAt`.
- As a safety net, the row also shows "可能过期" when the data age exceeds
  `max(3 × (N × providerRefreshInterval), 15 min)`, where N is the effective
  `periodicFullEveryN` value (default ≈ 5 h at N=20 and 300 s). The provider-specific
  interval is used when configured; otherwise the global interval applies. This allows
  several secondary-information cycles to be missed before age alone marks the value
  stale. A value with no `fetchedAt` (pre-R3 cached data) is not age-judged.

## QuotaInfo Mapping

Successful fetch returns (the fetcher itself always writes `codexUsageDetails: nil` —
local usage details are attached later by the reconcile pass, see *Provider-batch
reconciliation*):

```swift
QuotaInfo(
    models: [ModelQuota(modelName: "chatgpt_plan", ...)],
    resetCredits: resetCredits,
    planLabel: planLabel,
    accountEmail: auth.accountEmail,
    codexUsageDetails: nil,
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

Quota rows (`ChatGPTPlanModelRow`, dock-only render path):

```text
ChatGPT Plan   5小时 54%   周 36%   <binding reset time>
[ 6-segment bar: cell 1 = 5h remaining, cells 2…6 = weekly remaining ]
```

- The two window labels come from `Formatters.codexWindowLabel(seconds:)` applied to the
  parsed window length, not from hard-coded strings: `18000` renders as `5小时`, `604800`
  as `周`, and a missing length falls back to `主额度`. Only the **bar** is segmented, into
  `6` segments (`ChatGPTPlanModelRow.weeklyEquivalentMultiplier`, the same constant as
  `ModelQuota.weeklyEquivalentMultiplier(.codexChatGpt)`); the multiplier is **not**
  rendered as text anywhere — no `周倍率：N` label exists in `QuotaViews.swift` any more.
  It only drives the segment count here and the status-bar
  `min(5h, 周 × N)` aggregation (`ModelQuota.aggregateActualAvailable`).
- The hover tooltip on the bar is `QuotaBarTooltip.text(segments:hasTriangle:)`:
  `分段额度：\n第 1 格为当前窗口余量；后续 5 格为等价周额度余量。` plus the ▼ marker legend
  (`\n顶部 ▼ 标记周重置时间进度（左侧即将重置，右侧刚重置）`) when the weekly reset time is known.

Window usage details: the local per-window metrics live in the card's 「额度窗口用量」
section (`QuotaWindowUsageSection`), which for ChatGPT is fed by
`ChatGPTPlanModelRow.windowUsages` — `codexUsageDetails.primary` / `.secondary` when
present (already pre-aggregated from the same session samples, so they must **not** be
re-added), with enabled OpenCode `openai` samples appended on top. The
三列明细（Last Prompt / 5h / 周）row that used to sit under the bar was removed together
with the menu-layout hover family, and the `lastPrompt` data chain (`LastPromptUsage` +
scanner tracking) was removed with it.

If `secondary_window` is absent (for example, a promotion temporarily removes the 5-hour
limit), the app displays the single `primary_window` using its actual `limit_window_seconds`
label and only aggregates local usage for that window. It does not synthesize a second
window, and the bar degrades to the single-window path (`SingleQuotaMetadataLine` +
`SingleQuotaBar`, 1 segment).

Reset credits, when present, render as a collapsed row inside the card's
「额度窗口用量」section (`CompactResetCreditsRow`, module 4 — it used to sit directly
under the quota bar):

```text
重置卡数量：<availableCount>          可能过期 · 上次更新 HH:mm   <earliest expiry>
```

`planLabel` and `accountEmail` render as the card's Account Info row
(`QuotaWindowAccountInfoRow`), not as a card-title pill: for `.codexChatGpt` either one
alone is enough for the row to appear, and both empty hides the row entirely
(`QuotaWindowAccountInfo.make`).

## Errors

The current fetcher uses shared `QuotaError` messages rather than provider-specific user copy.

| Situation | Current error |
|---|---|
| `auth.json` unreadable | `网络错误：无法读取 Codex 认证文件（auth.json）`（只带文件名，不带完整路径 / 底层错误） |
| `auth.json` > 1 MiB | `网络错误：Codex 认证文件过大` |
| `auth.json` invalid JSON | `解析失败：auth.json 不是合法 JSON` |
| `auth.json` 顶层不是对象 | `解析失败：auth.json 顶层不是对象` |
| missing `tokens` | `解析失败：auth.json 缺 tokens` |
| missing `tokens.access_token` | `未配置 API Key` |
| non-HTTP response | `响应格式无效` |
| response body > 8 MiB | `响应过大（上限 … bytes）：<脱敏 endpoint>` |
| HTTP non-2xx | `HTTP <status>，响应 <N> bytes`（`includeBodyInError: false`，不回显 body） |
| HTTP 401 | `Codex 登录已失效，请运行 codex login 后重试`（`QuotaError.userFacingDescription`） |
| usage top level not an object | `解析失败：usage 顶层不是对象` |
| `rate_limit` missing | `解析失败：usage 响应缺少 rate_limit` |
| primary window missing/invalid | `解析失败：usage.rate_limit 缺少合法 primary_window` |
| malformed usage JSON | `解析失败：usage 不是合法 JSON` |
| malformed / out-of-range reset-credit JSON | warning only, quota still succeeds |

Remaining known gap: 429 rate limiting still surfaces the generic `HTTP 429，响应 … bytes`
line rather than a "try again in N minutes" hint.


## Codex Local Usage

The Codex harness scans local session JSONL and contributes `codexUsageDetails` after the provider batch settles. Source paths, aggregation, raw token semantics, and scanner caching are documented in the [Codex harness spec](../harnesses/codex.md#local-usage-aggregation).

> 拆分来源：由原 `spec/providers/codex.md` 按 ChatGPT quota provider 职责拆分；本文件主要沿用其对应章节。
> 核对基线：2026-11-06 · 代码 240b306
