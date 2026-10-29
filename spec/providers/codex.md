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
| Timeout | 15 s (`HTTPTimeouts.overseas`)；响应体上限 8 MiB (`ResponseByteLimits.standardQuota`) |
| Model rows | One synthetic model: `chatgpt_plan` |
| Reset credits | Parsed and displayed when entries exist |
| Plan label | Parsed from `id_token` JWT when available |
| Account email | 解析自 `auth.json` 顶层 / `tokens.email`，缺失时回退 `id_token` JWT 的 `email` 或 `https://api.openai.com/profile.email`；与 `planLabel` 一起进卡内 Account Info 行 |
| Local usage details | Aggregated from local Codex session logs |
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
| `authPath` | Optional custom auth location. Accepts either an `auth.json` file path or its parent directory. |
| `adminApiCreditsEnabled` | 是否启用 OpenAI API 赠金监测。缺省为 false。开启后在卡内追加「API赠金」进度条。 |
| `adminApiKey` | OpenAI Admin API Key (`sk-admin-..`)，用于调用官方组织成本接口。 |
| `adminBillingDay` | 每月账单日（1-31，缺省 11）。 |
| `adminBillingTime` | 账单重置时间（`HH:mm`，如 `00:00` 或 `08:00`，缺省 `00:00`）。 |
| `adminMonthlyQuotaLimit` | 每月赠金额度上限（美元，缺省 40.0）。 |
| `notifyIntervalRestored` etc. (4 fields) | Optional per-event notification channels (5h/weekly × restored/exhausted): `none` / `system` / `barkAndSystem`. Defaults: restored → `system`, exhausted → `none`. See `spec/notifications.md`. |

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
| `tokens.id_token` | Optional JWT source for `chatgpt_plan_type` and `email` |
| `email`（顶层）/ `tokens.email` | `accountEmail`（优先于 JWT 里的邮箱） |

`refresh_token` is not used.

The file is read through `FileHandle` in 64 KiB chunks with a hard cap of
`CodexFetcher.maxAuthFileBytes` (1 MiB); over the cap the provider fails with
`网络错误：Codex 认证文件过大` and logs neither the path nor the content. Read/parse
errors never embed the full path or the underlying system error — they surface as
`网络错误：无法读取 Codex 认证文件（auth.json）`, which keeps the username and any
custom `authPath` directory out of the UI and the log.

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

ChatGPT 用户每月可享受官方免费 API 额度福利（API 赠金）。本模块通过 OpenAI 官方 Admin 接口监测组织用量，并按滑动账单周期计算当前周期的额度消耗与剩余有效期。

### 端点与鉴权

```http
GET https://api.openai.com/v1/organization/costs?start_time=<cycle_start_epoch>&bucket_width=1d&limit=35
Authorization: Bearer <admin_api_key>
```

- **数据解析**：按日 bucket 聚合所有 `results` 下 `amount.value`，累加得到当前账单周期内的已消耗金额 `usedAmount`。
- **空间名称获取**：优先从 costs 响应 results 的 `organization_name` 获取；若当周期刚开始尚无用量消费导致 results 为空，则回退调用 `GET https://api.openai.com/v1/me` 读取 `orgs.data[0].title`；都取不到时显示「未知组织」。
- **容错设计**：`adminCosts` 抓取异常不会导致 ChatGPT Plan 5h/周配额刷新失败；保留上一轮赠金值，并在赠金行标记「更新失败 · 上次 HH:mm」。赠金明细独立记录 `fetchedAt` 与 `lastAttemptFailed`。
- **主 quota 失败**：当本地 Plan auth 缺失、但 Admin API Key 可用时，仍可独立更新赠金；Codex merger 保留上次 Plan model/账号/套餐和主 quota 时间，并将本次结果作为主 quota 失败写入 `ProviderStatus.failed`。主 quota HTTP/解析失败时，并行成功的 Admin 结果只更新赠金明细及其独立时间，不更新 Plan、provider 成功时间或 quota 通知基线；赠金失败则保留旧值并标记。没有旧赠金时也展示赠金抓取错误。

### 账单周期算法

- 由 `OpenAIApiCreditDetails.currentBillingCycle(day:hour:minute:now:)` 计算：
  - 账单日：`1...31`（自动夹取至当月实际最大天数，如 2 月 28/29 日）；
  - 重置时刻：`HH:mm`（时分级切换精度，如 `08:00`）；
  - 滑动周期判定：若 `now >= 当月重置锚点`，周期为 `[当月锚点, 次月锚点)`；若 `now < 当月重置锚点`，周期为 `[上月锚点, 当月锚点)`。跨年时 12 月与 1 月正确滚转。

### UI 呈现（`ChatGPTApiCreditsRow`）

在 ChatGPT Provider 卡片内紧凑自适应展示：
- **标题行**：`API赠金`（11pt semibold）与空间/组织名称（次要色靠右）；组织名取不到时显示「未知组织」。
- **进度条**：单段 `SegmentedQuotaProgressBar`（高 8pt，健康度绿/黄/红自适应着色，带有表示周期时间进度的红色倒三角 `▼`），独占整行通栏显示，条两侧不放标签。
- **金额行**：`剩余 $x / 总$x · 已用 $xx.xx`。
- **状态行**：账单周期结束时间与倒计时，以及 `更新 HH:mm`；最近一次赠金请求失败时显示 `更新失败 · 上次 HH:mm`。首次失败且无旧明细时展示错误状态。

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
  post-Provider reconcile enriches them when the 5h window is available.
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
incremental parsing, ms-level per tick). The incremental state lives purely in the process —
an app restart starts from an empty cache and performs a full cold scan (~1.3s after the
byte-level line prefilter), and a truncated or same-size-but-modified file falls back to a full
re-parse of that file. No disk index is written; the byte-level line prefilter
(`event_msg` / `turn_context` markers matched via memmem before any String decoding) keeps the
cold scan itself an order of magnitude cheaper than a naive `String.contains` pass.

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
  `max(3 × (periodicFullEveryN × refreshInterval), 15 min)` (default ≈ 5 h), meaning
  several periodic-full cycles were missed. Normal operation never reaches this
  (data refreshes every ~100 min). A value with no `fetchedAt` (pre-R3 cached data) is
  not age-judged.

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

> 核对基线：2026-10-29 · 代码 013a82e
