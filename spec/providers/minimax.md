# minimax — Provider Spec

Provider id: `minimax_token_plan`

Implementation:
- Remote quota fetcher: `Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift`
- Pricing data: `Sources/LLM-monitor/Resources/ModelPricing.json` (matched by `Models/ModelPricingCatalog.swift`)

This provider covers the remote Token Plan API and its quota card. Its main quota card also
merges local usage from the MiniMax Code harness, DSH, the ZCode `minimax` slice, and supported
OpenCode provider IDs. MiniMax Code's local runtime database, scanner, and sample accounting are
specified in [`harnesses/minimaxcode.md`](../harnesses/minimaxcode.md); the other contributors are
documented in their own files.


## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.minimax_token_plan.apiKey` |
| Required key type | Token Plan key, usually `sk-cp-...` |
| Quota endpoint | `GET https://www.minimaxi.com/v1/token_plan/remains` |
| Quota timeout | 10 seconds (`HTTPTimeouts.domestic`) |
| Quota unit | Remaining percent, not token count |
| Models and pricing | M3 and above are in `ModelPricing.json`; M2.7 / M2.5 / M2.1 are retired and historical usage remains unpriced. M3.1 Flash has a separate earlier-match entry (**¥1 / ¥0.1 / ¥4**) vs M3 (**¥2.1 / ¥0.42 / ¥8.4**). The generic runtime label `minimax/MiniMax-M3` is not a real model name; MiniMax Code samples resolve the real model as described in the [harness spec](../harnesses/minimaxcode.md#model-resolution-for-samples-model-is-often-null). |
| Cross-provider hover | The card displays automatically attributed local usage alongside quota; MiniMax Code scanner details are in the [harness spec](../harnesses/minimaxcode.md). |

## Accounting contract

The MiniMax Code ledger keeps uncached input, cache reads, and output as separate buckets. Sample
normalization and reasoning allocation are described in the
[MiniMax Code harness spec](../harnesses/minimaxcode.md#accounting-contract); the project-wide
accounting contract is in [`spec/accounting.md`](../accounting.md).


## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "minimax_token_plan": {
      "enabled": false,
      "apiKey": "sk-cp-REPLACE-WITH-YOUR-KEY"
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `apiKey` | Token Plan API key. Empty values and `sk-cp-REPLACE...` placeholders are treated as missing. |
| `refreshIntervalSeconds` | Optional independent refresh interval (overrides global default of 300s). |
| `displayName` | Optional card title override. |
| `notifyIntervalRestored` etc. (4 fields) | Optional per-event notification channels (5h/weekly × restored/exhausted): `none` / `system` / `barkAndSystem`. Defaults: restored → `system`, exhausted → `none`. See `spec/notifications.md`. |

`MinimaxTokenPlanFetcher.hasLocalAuth()` always returns `true`; `AppState` validates the config `apiKey`.
MiniMax Code scanner scheduling and cache invalidation are documented in the
[harness spec](../harnesses/minimaxcode.md#local-token-usage-scanner).

## API Request

```http
GET https://www.minimaxi.com/v1/token_plan/remains
Authorization: Bearer <Token Plan API Key>
Content-Type: application/json
```

The app sends the full API key in the request. Logs only include the key length (e.g. `key length=125`); the key and any prefix are never logged.

**Important**: this endpoint is server-side validated and only accepts `sk-cp-...` API Keys issued by minimax's open platform console. The local runtime's `~/.minimax/local-runtime.auth.json` JWT accessToken (used by the minimax IDE / CLI) is **not** accepted — verified by direct curl test returning `{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key in the 'Authorization' field of the request header"}}`.

## API Response Schema

Observed successful response:

```json
{
  "model_remains": [
    {
      "start_time": 1783234800000,
      "end_time":   1783252800000,
      "remains_time": 10629565,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "model_name": "general",
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "weekly_start_time": 1782662400000,
      "weekly_end_time":   1783267200000,
      "weekly_remains_time": 25029565,
      "current_interval_status": 1,
      "current_interval_remaining_percent": 54,
      "current_weekly_status": 1,
      "current_weekly_remaining_percent": 64
    },
    {
      "model_name": "video",
      "current_interval_remaining_percent": 100,
      "current_weekly_remaining_percent": 100
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
```

Important fields:

| Field | Meaning |
|---|---|
| `model_remains[]` | One entry per minimax quota family |
| `model_name` | Provider model/family id, for example `general`, `video`, `image`, `speech`, `music` |
| `current_interval_*` | 5-hour rolling window data |
| `current_weekly_*` | Weekly window data |
| `*_remaining_percent` | Core display value, `0...100` |
| `*_total_count` / `*_usage_count` | Preserved in `ModelQuota`; often `0` for percent-only plans |
| `points` / account credits | Not present in the current `token_plan/remains` response; no separate Minimax points balance is currently exposed by this fetcher |
| `*_status` | `1` = active; `2` = active but exhausted (0% remaining); `3` = not subscribed. The parser normalizes `2` to the internal active-window status so an exhausted window remains visible. |
| `end_time` / `weekly_end_time` | Millisecond timestamps used as reset times. `end_time` 还派生 `intervalWindowSeconds`（end 落 0 点 → 14400，其余边界 → 18000；video 恒 nil），见 [Rate Limits](#rate-limits) |
| `base_resp.status_code` | `0` means success |
| `base_resp.status_msg` | Server message for non-zero status |

Historical note: older guesses assumed OpenAI-style token counts and second timestamps. Current code uses percent fields and millisecond timestamps.

## API Parser Behavior

`MinimaxTokenPlanFetcher.parse(data:)` uses strict `JSONDecoder` models — there is no
`JSONSerialization` preflight. The count-field validation lives inside
`MinimaxModelRemain.init(from:)` as `strictNonnegativeCount`, so the payload is walked
exactly once: each of the four `*_count` fields may be absent (treated as 0) but, when
present, must be a finite non-negative integer exactly representable as `Int` (rejecting
decimals, negatives, overflow, booleans and strings). Percentage fields must be finite
values in `0...100` when present.

One deliberate asymmetry: a record with a missing or blank `model_name` short-circuits to
all-`nil` fields and is skipped by the caller, so one malformed record cannot drag down
the models that *are* displayable. Type drift on any *other* field of a named record is
a hard decode failure instead — silently degrading a present-but-typed-wrong field to
`nil` would render as a real 0% quota.

`validatedCounts` additionally rejects `usage > total` when `total != 0`; `total == 0`
means pay-as-you-go with no fixed allowance, so `usage` is left uncapped.

Mapping per `model_remains[]` item:

| Response field | Model field |
|---|---|
| `model_name` | `modelName` (trimmed; blank → record skipped) |
| `current_interval_total_count` | `intervalTotalCount` |
| `current_interval_usage_count` | `intervalUsageCount` |
| `current_interval_remaining_percent` | `intervalRemainingPercent` |
| `current_interval_status` | `intervalStatus` (`1/2` → `.present`, other raw codes → `.absent`, absent → percent-based default) |
| `end_time` | `intervalResetsAt` |
| `current_weekly_total_count` | `weeklyTotalCount` |
| `current_weekly_usage_count` | `weeklyUsageCount` |
| `current_weekly_remaining_percent` | `weeklyRemainingPercent` |
| `current_weekly_status` | `weeklyStatus` (same normalization as the interval window) |
| `weekly_end_time` | `weeklyResetsAt` |

`DateParser.parseMsTimestamp` treats numbers and numeric strings as milliseconds since
Unix epoch — it is a dedicated entry point precisely because the unit is fixed here
(the auto-unit `DateParser.parse` would misread small millisecond values as seconds).

When a raw status is absent, the default is derived from the percent: no percent →
`.absent`, percent present → `.present`. This is what lets a partial record (e.g. one
that carries only a weekly window) succeed instead of failing the whole provider
refresh. Declaring a window `.present` (raw status 1/2, or a percent-only default)
while its percent is missing is still rejected. A missing `weekly_end_time` passes
`weeklyResetsAt = nil` through unchanged — the consumer degrades safely (time-aware
coloring falls back to the baseline 100% denominator: `< 20%` red / `< 50%` yellow /
otherwise green, since `timeFraction` is nil; local window bucketing skipped) rather
than fabricating a reset time by synthesizing a 7-day boundary.

`intervalWindowSeconds` 是**派生值**而非透传。minimax 的 5h 窗口贴固定日边界
00:00 / 05:00 / 10:00 / 15:00 / 20:00（本地时区），最后一段 20:00→24:00 只有 4 小时，
响应本身不携带窗口长度，fetcher 按 `end_time` 反推：end 落在 0 点 → 14400，其余边界
→ 18000（`MinimaxTokenPlanFetcher.intervalWindowLength`）；video 记录保持 nil——其
日窗口的 24h 兜底长度在 end 已知时本就落在 0 点边界，且 video 作为独立模型已被排除在聚合之外。
消费方 `windowBounds` 用 `end − 长度` 反推窗口起点：20~23:59 区间若仍走 5h 兜底，
起点会退到 19:00，把上一窗口最后 1 小时的样本多算进「额度窗口」5h 行（token 与
金额双双虚高）——这就是派生该字段的理由。`end_time` 缺失时长度为 nil，按原 5h 兜底降级。

The current successful response contains only model/window quota data and `base_resp`;
there is no points, credits, or account-balance field to display. The strict response
model intentionally ignores unknown JSON keys for forward compatibility, so a future
Minimax points field must be added explicitly to a provider-neutral credit/balance model
before it can appear in the UI; it must not be folded into `ModelQuota` percentages.

The API can return placeholder model records for capabilities that are not available to the
current subscription. A model is displayed only when at least one quota window is present. Raw
status `2` means the window is active but exhausted, so it is normalized to `.present` and
rendered as `0%` with its reset time. Raw status `3` and other non-active codes normalize to
`.absent`; the record remains available for diagnostics in `QuotaInfo.models`, but is excluded
from `QuotaInfo.activeModels`, card rendering, dividers, and provider health. If a later refresh
changes either status to `1` or `2`, the model reappears automatically.

Successful parse returns:

```swift
QuotaInfo(
    models: models,
    resetCredits: nil,
    planLabel: nil,
    accountEmail: nil,        // minimax 走 API Key，无登录账号
    codexUsageDetails: nil,
    fetchedAt: Date()
)
```

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `minimax Token Plan` unless overridden |
| `iconSystemName` | `bubble.left.and.text.bubble.right.fill` |
| `accentColor` | `minimax` mapped to purple |

**Per-model window / multiplier**（`ModelQuota.weeklyEquivalentMultiplier` + `primaryWindowLabel` 按 model 名分）：

| Model name | 主窗口 label | 周倍率 N | 等价比例 |
|---|---|---|---|
| `general` / `image` / `speech` / `music` / `tts` | `5h` | 10 | 1 段 = 5h，10 段 = 周 |
| `video` | `日` | 7 | 1 段 = 1 天，7 段 = 周（minimax 实际是日配额） |

**聚合排除（2026-10 用户裁定）**：`video` 不参与跨 model 聚合读数——状态栏 iconDuo、
边缘窗圆环与 provider 综合健康度经 `QuotaInfo.aggregateQuotaModels(providerKind:)` 取
聚合 model 集合，`ModelQuota.isExcludedFromQuotaAggregation` 把 `video` 排除（与
antigravity 的 Claude and GPT 组同规则）。独立小配额池的余量不代表主力模型水位；卡片
video 行、通知检测（`QuotaEventDetector` 走 `current.models` 全量）不受影响。
### 7-day local usage chart

The main card renders a shared 7-day chart from automatically attributed local client usage. Its
MiniMax Code source, sample semantics, chart categories, and view wiring are documented in the
[MiniMax Code harness spec](../harnesses/minimaxcode.md#local-usage-ui).


## API Error Handling

Current fetch path:

| Situation | Current error |
|---|---|
| Empty API key passed to fetcher | `未配置 API Key` |
| URLSession error | `网络错误：<system message>` |
| Non-HTTP response | `响应格式无效` |
| HTTP non-2xx | `HTTP <status>，响应 <N> bytes`（`HTTPClient` 的脱敏摘要已含状态码，`QuotaError` 检测到前缀重复时原样显示、不二次拼 `HTTP <status>:`） |
| Response body over the 8 MiB cap | `响应过大（上限 <N> bytes）：<endpoint path>` |
| Any JSON decode failure (malformed JSON, wrong type, non-negative-count violation, `usage > total`, out-of-range percent) | `解析失败：minimax 返回的 JSON 无法解析` |
| Missing `base_resp` | `解析失败：响应缺少 base_resp` |
| Missing `base_resp.status_code` | `解析失败：base_resp 缺少 status_code` |
| `base_resp.status_code = 1004` | `QuotaError.httpError(401)` → 展示为 `minimax API Key 无效或已过期`（`QuotaError.userFacingDescription` 剥掉 body 里的 `<msg>`） |
| Other non-zero `base_resp.status_code` | `解析失败：minimax 返回错误 [<code>]: <msg>` |
| Missing `model_remains` array | `解析失败：minimax 返回的 JSON 无法解析`（顶层 `modelRemains` 是 required decode，缺失即解码失败） |
| Declared-present window with no percent | `解析失败：model_remains[<name>] 声明 5h 窗口有效，但缺少合法 current_interval_remaining_percent`（周窗口同理） |
| Every record skipped or `model_remains` empty | `解析失败：model_remains 数组为空` |

The API's business-level auth failure `status_code=1004` is normalized to the same `HTTP 401`
semantic used by GLM; other non-zero business codes remain decoding errors.

**Token Plan auth verification**: confirmed that `~/.minimax/local-runtime.auth.json`'s `accessToken` (JWT) is **not** accepted by `token_plan/remains` — see "API Request" above. Only `sk-cp-...` API keys from minimax's open platform work.

## Rate Limits

### Client-side backoff

The provider has no client-side backoff beyond the configured refresh interval. If minimax returns rate-limit or service errors, `AppState` moves the provider to `.failed` and shows the previous `QuotaInfo` from `state.lastSuccess` if available.

Default global refresh interval is 300 seconds. A provider-specific interval can be set:

```json
{
  "providers": {
    "minimax_token_plan": {
      "enabled": true,
      "apiKey": "sk-cp-...",
      "refreshIntervalSeconds": 300
    }
  }
}
```

### Server-side 5h rolling window — the limit is **cost**, not tokens

The M3 Token Plan enforces a **quota window** (API 语义上叫 5h 窗口) that snaps to the day boundaries 00:00 / 05:00 / 10:00 / 15:00 / 20:00 local time. This produces four 5h slots plus a final **4h slot (20:00→24:00)** per day (the API field is `current_interval_*` per [`model_remains[]`](#api-response-schema)). The window resets at the next boundary, not at "now − 5h". 窗口长度由 fetcher 按 `end_time` 反推填进 `intervalWindowSeconds`（见 §API Parser Behavior），「额度窗口」5h 行的起点反推因此总是落在真实边界上。

**The hard constraint is cost, not token count.** Two independent clients (Mavis and DSH) both converge on a **5h cost ceiling of ~¥24** when measuring 5h windows that hit the natural throttle. The equivalent token count is a **secondary effect** of the cache_read / input / output mix in the workload:

| Workload | cache_read share | Tokens that fit in ¥24 | Notes |
|---|---:|---:|---|
| Mavis (Aug 1–14, M3) | ~97% | **~50M** (49.2–52.7M) | long-running task loops |
| DSH (Aug 16–27, M3) | ~98% | **~50M** (49.6–55.0M stable) | the windows that triggered RATE_LIMIT |
| DSH 2026-08-17 10:00+5h | ~99% | 68.2M → **¥30.02** | single long session over-shooting the ceiling — see credit rail below |

The window cost formula uses the M3 prices from `ModelPricing.json`:

```
cost(¥) = input * 2.10 + cacheRead * 0.42 + (output + reasoning) * 8.40  (per 1M tokens)
```

M3.1 Flash has its own, cheaper entry (also from `ModelPricing.json`):

```
cost(¥) = input * 1.00 + cacheRead * 0.10 + (output + reasoning) * 4.00  (per 1M tokens)
```

The M3 prices above remain the right ones for the M3-era evidence quoted in this section
(Mavis 2026-08-01 ~ 08-14, DSH 2026-08-16 ~ 08-27 — all M3). But a **current** ledger
whose rows resolve to M3.1 Flash must be costed with the M3.1 Flash prices; mixing the two
inflates the estimate (measured on a real 8-day window: ¥253.76 with M3 prices vs ¥69.70
with M3.1 Flash prices for the same tokens).

#### Evidence the ceiling is cost, not tokens

1. **Mavis local `.db` M3 usage, 2026-08-01 ~ 2026-08-14, 24 windows (post-Token-Plan tier change)**: 10 of the 24 windows sit in the **¥23.49 – ¥25.38** band with token totals 49.2M–52.7M and rounds 254–570. Mavis' long-running task loops naturally cap at this level even when the underlying M3 quota API has remaining capacity.
2. **DSH 13 windows, 2026-08-16 ~ 2026-08-27**: the 5 stable RATE_LIMIT-triggering windows all sit at **¥23.80 – ¥30.02** / tokens 49.6M–68.2M. The un-triggered window max is ¥29.37 / 66.2M / 422 calls.
3. **DSH 2026-08-23 00:00+5h** is the disambiguating case: 8 subagent sessions fire 4-second-spaced turn-1 calls in parallel; window cost is only **¥9.50 / 17.9M / 128 calls**, but 8 RATE_LIMIT events fire. If the limit were tokens, a 17.9M-token window (one third of the steady-state) would never trip; the fact that it does shows the throttle is on a **rate dimension** independent of the cumulative cost ceiling.
4. **DSH 2026-08-17 10:00+5h** is the over-shoot case: a single long session (`session-b00aa5`, 1078 calls over 44h) consumes 68.2M tokens / ¥30.02 in 54 minutes. This is **¥24 plan + ¥6 credits**, not a misclassification — the user burned through the in-plan allowance and kept going on the credit rail.

#### What this means for the data

The "5h cost ceiling ¥24" should be treated as the **primary** limit signal in the UI and the spec. The "5h token total ~50M" is a **secondary** indicator that depends on the cache_read / input / output mix and should not be quoted as the limit. If a future workload drops the cache_read share (e.g. more cold-context tasks), the same ¥24 ceiling will correspond to far fewer tokens (~12M for a 100% input workload at ¥2.10/M), not more.

#### Out-of-plan rail (credit / pay-as-you-go)

When `current_interval_remaining_percent` hits `0` and a request still goes through, the consumed tokens are on the **credit rail** (additional cost beyond the monthly Token Plan fee). The cleanest split is:

```
cost_in_plan     = sum( tokens consumed while current_interval_remaining_percent > 0 )
cost_out_of_plan = sum( tokens consumed while current_interval_remaining_percent == 0 )
total_5h_cost    = cost_in_plan + cost_out_of_plan
```

A working hypothesis (DSH 2026-08-17 10:00+5h): `cost_in_plan ≈ ¥24`, `cost_out_of_plan ≈ ¥6`, `total ≈ ¥30`. To realize this split empirically, see Open Questions § 5h-quota cross-window attribution — it requires persisting every quota snapshot.

## 额度重置卡（调研记录，未接入）

> 2026-10-28 调研结论。桌面端私有接口，LLM-monitor **有意不接入**；本节只记录发现，
> 供未来官方开放 API 或桌面端行为变化时参考。背景：据公开资料 Token Plan 已于
> 2026-10-01 停售、被 M Plan（全模态统一额度）取代，重置卡语义可能随套餐迁移继续变化。

**接口来源**：MiniMax Agent 桌面端 3.1.6 的 IPC Proxy 日志（`~/Library/Logs/MiniMax/api-*.log`
逐条记录请求头——Authorization 脱敏——与响应状态）+ `/Applications/MiniMax Code.app` 内
`app.asar` 字符串逆向。host 与 open platform 同为 `www.minimaxi.com`，但走
`/backend/account/` 路由前缀；裸 `/backend/account/reset_card` 是 404——它是**路由前缀**，
子路径才是端点：

| 端点 | 方法 | 说明 |
|---|---|---|
| `/backend/account/reset_card/list` | GET | 可用重置卡列表（asar 逆向所得，日志未观测到调用） |
| `/backend/account/reset_card/flows` | GET | 近 30 天获得/使用记录；query：`create_time`（记录窗口起点 ms，观测值早于请求 ~11 天，精确语义未确认）/ `page` / `size` / `business=Agent` / `device_platform=desktop`。桌面端日志实测 HTTP 200 + `baseRespStatusCode: 0`（面板打开时触发） |
| `/backend/account/reset_card/use` | POST | 用卡（asar 逆向所得，日志未观测到调用） |

响应走与 `/v1/token_plan/remains` 相同的 `base_resp` envelope（`status_code=1004` = 未登录）。
同鉴权域的兄弟端点：`/backend/account/token_plan/remains_percent`（桌面端版余额百分比，
桌面端约每 10s 轮询）、`/backend/account/token_plan_credit`（积分；asar 内另有
`credit_spending` / `my_credit_usage` / `fallback` 子路径）。

**鉴权**（桌面端登录会话域；桌面端请求全部携带，`Authorization` 实测必要）：

```
Authorization: Bearer <MiniMax Agent 桌面端登录 JWT>   # sharedAuth；日志字段 accessTokenGeneration 代际轮换
X-Group-Id: <op_group_id>                             # 工作区/群组 id（观测值为纯数字）
Origin / Referer: https://www.minimaxi.com
User-Agent: MiniMaxAgent Mozilla/5.0 (...) MiniMax/3.1.6 Chrome/... Safari/537.36
```

**不可获取的原因**（2026-10-28 实测）：LLM-monitor 手里两把钥匙都被
`1004 not login` 拒绝——① config 的 `sk-cp-...` Token Plan API key（open platform 鉴权域，
即 `/v1/token_plan/remains` 同一把）；② `~/.minimax/local-runtime.auth.json` 的 CLI
runtime JWT（明文可读，但它是 Code CLI 会话，不是桌面 Agent 会话）。桌面端现行 JWT
无明文落盘：`~/Library/Application Support/MiniMax/Local Storage/leveldb` 只有陈旧过期
残片，现行 token 由主进程持有（safeStorage/Keychain 域）——ZCode 余额日志那条
「解析客户端落盘数据」的旁路对 MiniMax 不可行。

## Known Limitations

The limitations of MiniMax Code's local ledger and chart are listed in the
[MiniMax Code harness spec](../harnesses/minimaxcode.md#known-limitations).


## Test Coverage

Minimax provider parser tests are in `Tests/LLMMonitorTests/MinimaxResponseParsingTests.swift`:

- **Fetcher parser (`MinimaxResponseParsingTests.swift`)**:
  - `testMinimaxParse`: happy-path `model_remains` → `ModelQuota` mapping.
  - `testMinimaxParseBaseRespError` / `testMinimaxParseEmptyModelRemains`: `base_resp` failures and the empty-array guard.
  - `testMinimaxParseRecordMissingModelNameSkipped`: blank `model_name` records are skipped, not fatal.
  - `testMinimaxParseStrictCountValidation`: `strictNonnegativeCount` / `validatedCounts` rejection paths.
  - `testMinimaxParseWeeklyWindowMissingEndTimePassesThroughNil` / `testMinimaxParseIntervalWindowMissingPercentToleratedAsAbsent` / `testMinimaxParseDeclaredPresentWindowWithoutPercentStillThrows`: window-status tolerance and rejection boundaries.
  - `testMinimaxParseIntervalWindowSecondsFromMidnightEndTime` / `testMinimaxParseIntervalWindowSecondsFromEveningBoundaryEndTime` / `testIntervalWindowLengthHelperWithFixedCalendar`: `intervalWindowSeconds` 反推（end 落 0 点 → 14400，其余边界 → 18000；helper 直测注入固定 Asia/Shanghai 日历）。
  - `testMinimaxParseVideoRecordKeepsIntervalWindowSecondsNil` / `testMinimaxParseRecordWithoutEndTimeKeepsIntervalWindowSecondsNil`: video 与缺 `end_time` 的记录长度保持 nil。

## Open Questions

- Should HTTP 401/403/429 from the API receive provider-specific user messages?
- Should `current_interval_status` and `current_weekly_status` influence health beyond remaining percent?

The quota-window cross-source attribution question combines remote quota snapshots and local usage; it is retained here. MiniMax Code's source and accounting constraints are documented in the [harness spec](../harnesses/minimaxcode.md).

- **5h-quota cross-window attribution** — the DSH 2026-08-17 10:00+5h window hit ¥30.02 in 54 minutes from a single long session; in the local `.db` the 5h window cost of a busy Mavis day (e.g. 2026-08-02) sits at ¥23.88 / 50.4M tokens. Two competing explanations, neither currently verifiable from the data we can read:
  1. **Cross-window session attribution** — the 5h wall-clock windows 00/05/10/15/20 don't match the `interval_start_time` / `interval_end_time` returned by `minimax /v1/token_plan/remains`, so a session straddling a boundary may be double-counted or split. The fetcher does not record these boundaries historically; only the most recent fetch is kept in `ModelQuota`.
  2. **Point credits / quota top-up** — `minimax` may allow top-up credits that augment the 5h quota, or roll unused quota into the next window, or have a per-request cache-read ceiling independent of the 5h percent. The `token_plan/remains` response exposes `current_interval_total_count` / `current_interval_usage_count` but historically these are `0` for percent-only plans (see [API Response Schema](#api-response-schema) row "`*_total_count` / `*_usage_count`"). No `points` or `credits` field is currently exposed by the fetcher; the local `.db` records `cost_usd` only (and is `0` for Mavis post-2026-07-11 because the user is on Token Plan).
  - **What we need to disambiguate**: log the raw `model_remains[].start_time` / `end_time` / `*_total_count` / `*_usage_count` alongside the `Quotinferred` 5h window assignments for ~30 days, then re-derive the 5h cost from the `*_usage_count` delta. If the deltas correlate with the `.db` 5h cost, the window boundary hypothesis is wrong; if they don't, point credits are augmenting the quota. This requires schema work in `local_runtime_token_usage` (a `quota_snapshot_id` column) and a new `local_runtime_quota_snapshots` table.

  - **Cleanest split using `current_interval_remaining_percent`**: when the API field is `> 0`, every token consumed is **inside the Token Plan** (no extra cost beyond the monthly fee). When the field hits `0`, the 5h window is **exhausted** and any further token usage is **on the credit / pay-as-you-go rail**. So the 5h window's total cost decomposes as:

    ```
    cost_in_plan     = sum( tokens consumed while current_interval_remaining_percent > 0 )
    cost_out_of_plan = sum( tokens consumed while current_interval_remaining_percent == 0 )
    total_5h_cost    = cost_in_plan + cost_out_of_plan
    ```

    This is more informative than the current 5h cost number because it separates "the plan's natural ceiling" from "any overflow that the user paid for via credits". A working hypothesis: the 5h plan ceiling sits at **¥24 / ~50M tokens** (the steady-state value across Mavis + DSH), and any window above that (e.g. DSH 2026-08-17 10:00+5h at ¥30.02) is **¥24 plan + ¥6 credits**, not a misclassification.

    To realize this split, the fetcher must persist every `current_interval_remaining_percent` sample with a timestamp. Currently it only stores the most recent value in `ModelQuota`; a `local_runtime_quota_snapshots(model_name, ts, interval_remaining_percent, weekly_remaining_percent, interval_total_count, interval_usage_count, weekly_total_count, weekly_usage_count)` table is needed, and `local_runtime_token_usage` should gain a `quota_snapshot_id` so each row can be tagged "inside plan" vs "credits".

> 核对基线：2026-11-03 · 代码 d07fa47
