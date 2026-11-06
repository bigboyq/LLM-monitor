# GLM Coding Plan — Provider Spec

Provider id: `glm_coding_plan`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift`
- Tests: `Tests/LLMMonitorTests/GlmCodingPlanFetcherTests.swift / GlmZcodeDBReaderTests.swift / GlmOffPeakTests.swift / GlmUsageCategoryTests.swift（按 MARK 段拆分）`

The quota portion queries 智谱 (Zhipu / BigModel) GLM Coding Plan's internal monitor
endpoint — the same one used by the official `zai-coding-plugins` — for the 5-hour and
weekly credit windows plus the subscribed tier (Lite / Pro / Max). Token detail is supplied
by the native ZCode local scanner; supported OpenCode and DSH provider IDs are also
automatically attributed through the built-in routing registry. See [ZCode harness](../harnesses/zcode.md)
for local usage accounting, credential storage, and official-client behavior.

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.glm_coding_plan.apiKey` 与 `providers.glm_coding_plan.authPath` / 默认 `~/.zcode/v2/credentials.json` 可同时配置 |
| Quota auth | 必填 GLM Coding Plan API Key（格式 `<id>.<secret>`）；OAuth 不用于标准额度请求 |
| ZCode extensions | Optional `zcodeJWTEnabled` switch (default `false`); when enabled, read `zcodejwttoken` and use the configured API Key with it for supported ZCode API requests |
| Quota endpoint | `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit` |
| Quota timeout | 10 seconds (`HTTPTimeouts.domestic`) |
| Quota unit | Remaining credit percent, derived from `remaining / usage` (NOT the response `percentage` field, which is *used* percent) |
| Windows | 5h (interval) + weekly — classified by window metadata, with reset-time fallback |
| Plan tier | `data.level` → capitalized pill (`lite` → `Lite`) |
| Local token source | Native ZCode SQLite reader and supported DSH / OpenCode GLM attribution; see [ZCode harness](../harnesses/zcode.md) |

## Local token detail

SQLite schema, accounting rules, scan/cache behavior, and category attribution are documented
in the [ZCode harness spec](../harnesses/zcode.md). Shared accounting definitions remain in
[`spec/accounting.md`](../accounting.md).

## Model Pricing Catalog

设置面板“客户端”Tab 中的名义价值估算基于随 app 打包的价格目录 [`ModelPricing.json`](../../Sources/LLM-monitor/Resources/ModelPricing.json)（`ModelPricingCatalog` 启动时加载，`QuotaProviderID.zhipu` 条目）。调价 / 增删模型需改 JSON，并同步 `ModelPricingJSONTests` / `ProviderModelTests` 的价格断言与本 spec 的价格表。价格目录使用智谱官方人民币公开价（CNY 直接计价）：

| 模型匹配模式 | 归一化标签 (`modelLabel`) | 未缓存输入 (Input / 1M) | 缓存读取 (CacheRead / 1M) | 输出/思考 (Output / 1M) | 币种 |
|---|---|---|---|---|---|
| `glm-5.3-flash` / `glm-5.3flash` | `GLM-5.3-Flash` | **¥0.80** | **¥0.23** | **¥2.80** | CNY (¥) |
| `glm-5.3` | `GLM-5.3` | **¥8.00** | **¥2.00** | **¥28.00** | CNY (¥) |
| 兜底：其余一切模型（含缺失模型名） | 原始模型名，缺失时 `GLM-5.3-Flash(兜底)` | **¥0.80** | **¥0.23** | **¥2.80** | CNY (¥) |

- **GLM-5.2 及以下已退休**：`glm-5.2` / `glm-4.5` / `glm-4.7` 不再单独定价，出现即按
  GLM-5.3-Flash 兜底计价（估计值，不对应真实账单）。兜底使 zhipu 分支永远有价。
- **日志匹配规则**：匹配不区分大小写。ZCode 日志中的 `GLM-5.3`、OpenCode 中的 `glm-5.3`、DSH 中的 `GLM-5.3-Flash` 均可直接命中。
- **目录更新时间**：记录于 `ModelPricingCatalog.lastUpdated`（即 JSON 顶层 `lastUpdated`，当前为 `2026-10-01`）。
- **未定价模型**：zhipu 分支因兜底永远全覆盖，"未定价 / 部分计价"提示对该 provider 不再出现；其他 provider 维持明确列出未收录模型的既有口径。

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "glm_coding_plan": {
      "enabled": true,
      "zcodeJWTEnabled": true,
      "authPath": "~/.zcode/v2",
      "apiKey": "coding-plan-key",
      "notifyCampaign": "barkAndSystem"
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `zcodeJWTEnabled` | Optional Bool; enables ZCode JWT extensions. Missing defaults to `false` for new configurations. Explicit true/false takes precedence; otherwise `effectiveGlmAuthMode` preserves the legacy setting (`glmAuthMode` first, then `parseZcodeCredential` → `parseZcodePlan` → `parseZcodeBalanceLog`, using the first non-nil value). |
| `authPath` | ZCode 凭证文件或目录路径；仅在 `zcodeJWTEnabled` 为 true 时读取（缺省 `~/.zcode/v2`，支持 `~/.zcode/v2/credentials.json` 或自定义路径）。读取时将路径首字符 `～`（U+FF5E）或 `˜`（U+02DC）归一为 ASCII `~` 后展开主目录；路径中段字符保持原样。 |
| `apiKey` | Required Coding Plan Key. The quota fetcher is not ready without a nonblank key. When ZCode JWT extensions are enabled, this same configured key is sent as the BigModel authorization header; OAuth is never used as fallback. |
| `glmAuthMode` | Legacy compatibility field (`apiKey` / `credential`); when `zcodeJWTEnabled` is absent, `credential` migrates to enabled. Settings save clears this key. |
| `refreshIntervalSeconds` | Optional independent refresh interval (overrides global default of 300s). |
| `displayName` | Optional card title override. |
| `notifyCampaign` | Optional notification channel for new ZCode marketing campaigns (`none` / `system` / `barkAndSystem`). 默认关闭；JWT 扩展开启、读取到 JWT 且通知渠道开启后，仅 `.full` 刷新轮询。 |
| `parseZcodeCredential` / `parseZcodePlan` / `parseZcodeBalanceLog` | Legacy compatibility fields; used in the above precedence order when both `zcodeJWTEnabled` and `glmAuthMode` are absent. Settings save clears these keys. |
| `notifyIntervalRestored` etc. (4 fields) | Optional per-event notification channels (5h/weekly × restored/exhausted): `none` / `system` / `barkAndSystem`. Defaults: restored → `system`, exhausted → `none`. See `spec/notifications.md`. |

The peak window defaults to Mon–Fri 14:00–18:00（北京时间，法定节假日除外），相对平时的积分倍率默认 2×。Provider 的 `peakWindow` JSON 可覆盖时段、`weekdaysOnly` 与 `multiplier`；设置页只读展示当前值（见 `spec/config.md` §Config Schema、`spec/ui/settings.md`）。旧版本平铺的 `peakStartHour` / `peakEndHour` / `peakWeekdaysOnly` 键仍静默忽略，不参与判定、保存时清理。

`GlmCodingPlanFetcher.hasLocalAuth()` 要求存在非空 API Key 才报告 ready；即使 ZCode JWT 扩展开启且本地 JWT 存在，也不能替代主额度 API Key。JWT 有效性由 ZCode 接口验证。

## API Request

```http
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
Authorization: <Coding Plan Key>
Content-Type: application/json
```

**Important — auth header**: the configured Coding Plan Key is sent as a **raw token** in
`Authorization` (no `Bearer` prefix), matching the official plugin and the Anthropic
protocol base URL (`https://open.bigmodel.cn/api/anthropic`). The key format is `<id>.<secret>`.
The API Key is required. OAuth access tokens are not used for this endpoint.

**认证凭证分工**（2026-11-05 实测与当前实现）：

| 信息 | 当前请求使用的凭证 | 认证头 |
|---|---|---|
| 标准 5 小时 / 周额度 | API Key 即可，不需要 ZCode JWT | `Authorization: <API Key>` |
| 重置卡 | ZCode JWT + API Key | `Authorization: Bearer <JWT>` + `X-Bigmodel-Authorization: <API Key>` |
| 活动套餐余额 | ZCode JWT + API Key（当前实现） | `Authorization: Bearer <JWT>` + `X-Bigmodel-Authorization: <API Key>` |
| 营销活动 | ZCode JWT，不携带 API Key | `Authorization: Bearer <JWT>` |

API Key 可以替代双凭证接口中的 **BigModel OAuth access token**，不能替代 **ZCode JWT**。
重置卡的成功实测保留了 ZCode JWT，只将 `X-Bigmodel-Authorization` 从 OAuth token 换成 API Key；
不能据此推断 API Key 单独即可查询重置卡。活动套餐余额也已实测 JWT + API Key 成功，
并未验证省略 API Key 是否仍可用；表中记录当前发送方式。

应用统一要求先配置 API Key；三类 ZCode 扩展查询还须开启 `zcodeJWTEnabled` 并读取到 JWT。
营销接口本身不发送 API Key，仍受此应用级开关与营销通知配置控制。设备、语言、版本等附加请求头见下文直连 API 小节。

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
| `code` | Business code; `200` = success. Invalid API keys can come back as HTTP 200 with `code: 1000` — check the body, not only HTTP status. |
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
   (interval) window and `unit == 6, number == 1` is the weekly window. The metadata
   is only trusted when **both** windows are identified **and** their
   `nextResetTime` differ; otherwise (metadata missing / unknown, or the two
   reset times collapse to the same value) the parser falls back to
   `nextResetTime` ascending — first = 5h, last = weekly — for compatibility with
   older responses. This avoids misclassifying windows when a weekly reset happens
   before the 5h reset.
5. Per window: validate `total > 0`, `used >= 0`, `remaining >= 0`. `used > total` is
   allowed because a single Coding Plan task can exceed the nominal window total; that
   window is treated as exhausted (`remainingPercent = 0`) instead of failing the whole
   provider refresh. Otherwise `remaining <= total` is required, and the parser computes
   `remainingPercent = remaining / total * 100` (clamped to [0, 100]).
6. Build a single `ModelQuota` (modelName `glm_coding_plan`, displayName `GLM Coding Plan`) with
   interval (5h) + weekly windows; present limits map to `QuotaWindowStatus.present`,
   missing weekly limits map to `.absent`, and `intervalWindowSeconds = 18000`,
   `weeklyWindowSeconds = 604800`. 写死 18000 是**对的**：GLM 的 5h 窗口是真实滚动
   5 小时（用户裁定 2026-10-09），不像 minimax 贴固定日边界、末段只有 4h——不要给
   GLM 引入任何按 `end_time` 反推边界的逻辑。Codex（API 返回真实窗口长度）与
   Antigravity（rolling 5h，5h 兜底仅在 reset 时间缺失的降级路径生效）同理无整点切换。

Mapping:

| Response field | Model field |
|---|---|
| `limits[*].usage` | `intervalTotalCount` / `weeklyTotalCount` |
| `limits[*].currentValue` | `intervalUsageCount` / `weeklyUsageCount` |
| `remaining / usage * 100` | `intervalRemainingPercent` / `weeklyRemainingPercent` |
| `limits[*].nextResetTime` (ms) | `intervalResetsAt` / `weeklyResetsAt`; missing 5h value falls back to `now + 5h`，missing weekly value passes `nil` through（消费面按「present 但 reset 时间未知」降级，不伪造 7 天边界） |
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
| `iconSystemName` | `chevron.left.forwardslash.chevron.right` (`</>`) — 仅是 bundled 资源缺失时的防御性兜底符号；`Resources/BrandLogos/glm.svg` 已内置（1.4.2 起），卡片正常渲染品牌 logo，实际无 SF Symbol 回退 |
| `accentColor` | `glm` mapped to `.glmBrand` (indigo) |

Window multiplier (`ModelQuota.weeklyEquivalentMultiplier`): **5** — 不再有一行
「周倍率：N」文本（旧的 `QuotaWindowTitle` 已随三列布局下线删除）：倍率以
`CombinedQuotaWindowRow(weeklyEquivalentMultiplier:)` 传给分段进度条
（`SegmentedQuotaProgressBar`，5 段），段数语义写在 hover 提示
`QuotaBarTooltip.text(segments:)`（「第 1 格为当前窗口余量；后续 4 格为等价周额度
余量」），matching the tier credit ratio (weekly = 5× the 5h credits)。

The card shows the standard two-window layout (5h + weekly remaining %, reset countdown)
and a tier pill (`Lite` / `Pro` / `Max`). The footer renders the shared seven-day
Input/Cache/Output/Reason local-usage chart, fed by the native ZCode scanner and all
supported OpenCode / DSH GLM sources. Supported provider IDs are automatically attributed;
unknown IDs are not guessed into a card and there is no user-facing attribution switch.
The merged samples also feed the 「额度窗口」 usage table and its 「闲 / 免 / 速 / 它」
today rows.

## Peak Hours Indicator

智谱默认规则：**每周一至周五 14:00–18:00**（北京时间，与 DeepSeek 统一判定形状）
为高峰时段，**法定节假日除外**（工作日 = 周一–周五 ∧ 当天不是法定节假日，
见 `Models/HolidayCalendar.swift`）。高峰期模型调用按基础积分扣费，**非高峰期按
50% 抵扣**（省一半），即高峰相对平时为 **2×**。`peakWindow` 可覆盖时段与相对倍率，GLM 名义价值估算不因此乘倍率。卡片在额度行下方显示一条倒计时提示，颜色分 3 档反映紧迫度（文案倍率取当前配置）：

- **高峰期** 🔥（**红色**）：`高峰期 2× · 还剩 1小时30分`
- **非高峰期，距高峰 < 1 小时** ❄️（**橙色**，临近）：`距高峰期 45分 · 平时 1×`
- **非高峰期，距高峰 ≥ 1 小时** ❄️（**绿色**，余量充足）：`距高峰期 2小时13分 · 平时 1×`

实现细节：

| Aspect | Behavior |
|---|---|
| Model | `Models/PeakWindow.swift`（`GlmPeakWindow` 为兼容 typealias）— `status(at:calendar:holidays:)` 返回 `.peak(until:)` / `.offPeak(until:)` |
| Time basis | `PeakWindow.beijingCalendar`（Asia/Shanghai，与 DeepSeek 统一；调用点显式传入），与 GLM API 无关 —— refresh 失败也能显示 |
| Live countdown | `Views/GlmPeakIndicatorView.swift` 只注入 GLM 文案 / 图标 / 配色，倒计时读环境值 `\.displayDate`（**宿主各自注入的活动时钟**：`MenuContentView` 内联 / hover 浮层 `HoverPanelController` / dock 浮层 `EdgeDockController`，各自持有一个 `DisplayClock` 实例并经 `DisplayClockScope` 注入，随宿主显隐 start/stop）；宿主不可见即停、零开销。公共外壳与 `formatPeakDuration` 在 `Views/PeakIndicatorView.swift`，不再自挂 `TimelineView` |
| Window source | `ProviderConfig.effectivePeakWindow(for:)`（`rebuildStatuses` 时挂在 `ProviderStatus.glmPeakWindow`，未配置 `peakWindow` 时回退 `.zhipuDefault`；其他 kind 为 nil） |
| Defaults | `GlmPeakWindow.zhipuDefault` = Mon–Fri 14:00–18:00 |
| Day classification | Rule A：`Calendar.weekday` Mon–Fri = 2…6 ∧ 非法定节假日（`HolidayCalendar.shared`，打包快照 `Resources/ChinaHolidays.json`）；周末与调休上班的周六/周日永远非高峰（`weekdaysOnly`） |
| Boundary | 半开区间 `[startHour:00, endHour:00)`：14:00:00 算高峰，18:00:00 算非高峰 |
| Next peak | 今日 `startHour:00` 未到则取今日，否则逐日扫描跳过非高峰日（15 天预算：春节 8 天法定假 + 紧邻周末最长空档 ~11 天） |

时区固定为北京时间，默认按 Rule A 工作日（周一–周五 ∧ 非法定节假日）判定；JSON 中 `weekdaysOnly: false` 改为每天执行。设置面板「高峰期提示」只读展示当前时段与积分倍率。

### ZCode 扩展 API 集成（Activity Plan、重置卡与营销活动）

zcode SaaS 活动套餐（如周末体验套餐 `ZCode Weekend Build`）、额度重置卡与营销活动触达通过 `GlmZcodeAPIClient` 直调 `zcode.z.ai` 接口获取：
- 必须手动填写 Coding Plan API Key 才能启动 GLM fetcher。ZCode JWT 扩展由独立配置 `zcodeJWTEnabled` 控制（缺省关闭）；关闭时不读取凭证文件、不调用三路 ZCode 接口，也不展示上一次缓存的 package。打开后才从 `authPath` 读取 JWT 与设备标识；找到 JWT 时启用套餐余额、重置卡与营销活动接口；没有 JWT 时只跳过扩展请求，主额度仍正常请求；
- 抓取随 `GlmCodingPlanFetcher` 并在后台静默聚合至 `GlmZcodePackageSnapshot`，由 `GlmFillingMissingMerger` 处理跨模式合并；三路接口经 `ZcodePackageProviding` 协议注入（默认实现 `GlmZcodeAPIPackageProvider` 转发 `GlmZcodeAPIClient` static 方法），编排逻辑（部分失败降级、凭证缺失跳过、background 门控）可注入 stub 单测；
- **主频与次要信息频率**：
  - **活动套餐余额**：与 GLM Provider 生效刷新间隔保持一致（独立间隔优先，否则继承默认），每次刷新（`.full` 与 `.background`）均查询；
  - **额度重置卡**：按「次要信息频率」轮询，仅在 `.full` 模式下查询，`.background` 模式按设计跳过并从上次成功快照继承；
  - **营销活动触达**：仅在选定通知渠道（`notifyCampaign != .none`）且在 `.full` 模式下发起轮询，未选通知完全不发请求；发现活动通知一次，1 小时内不重复通知；
- **次要信息频率语义**：设置 UI 范围为 1...30，默认 20；内部 JSON 键仍为 `periodicFullEveryN`。每 N 个常规 provider 刷新拍中，N−1 拍为 `.background`，第 N 拍为 `.full`；N=1 时每拍均为 `.full`。默认 300 秒间隔下，重置卡约每 100 分钟刷新；180 秒间隔、N=2 时约每 6 分钟刷新。旧配置值保持原数值，超过 30 的值归一到 30。GLM 主 quota 与活动套餐余额仍按 provider 主刷新间隔每拍查询，不受此频率控制；
- 直连失败静默回退，不影响 GLM 主卡额度抓取。

| 项 | 值 |
|---|---|
| 数据源 | 直连 API：`GlmZcodeAPIClient.fetchBalance()` / `fetchResetCards()` / `fetchMarketingTouch()`（经 `ZcodePackageProviding` 协议注入，默认 `GlmZcodeAPIPackageProvider` 转发） |
| 接口 1：套餐余额 | `GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=...`（与 GLM Provider 生效刷新间隔一致；`app_version` query 与两条请求的 `X-ZCode-App-Version` header 由 `ZcodeAppVersionResolver` 运行时从本机 ZCode.app 的 Info.plist（`CFBundleShortVersionString`）动态读取，读取失败回退 `3.17.1`，进程内缓存一次） |
| 接口 2：重置卡 | `GET https://zcode.z.ai/api/v1/coding-plan/reset/status`（按次要信息频率轮询，仅 `.full` 模式查询） |
| 接口 3：营销活动 | `GET https://zcode.z.ai/api/v1/marketing/touch?seq=1`（仅在通知开启且 `.full` 模式轮询，通知按 delivery 做 1h 防抖） |
| 过期口径 | `expires_at <= now` 的套餐条目直接剔除；重置卡按 `expireAt` 展示 |
| 认证方式 | `apiKey` 必填，标准额度只使用此 key。`zcodeJWTEnabled` 独立控制扩展；开启后双头 ZCode 接口发送 `Authorization: Bearer <JWT>` 与 `X-Bigmodel-Authorization: <配置的 API Key>`，不使用 OAuth |
| 营销活动通知 | `providers.glm_coding_plan.notifyCampaign`（`QuotaNotifyChannel`：`none` / `system` / `barkAndSystem`；缺省关闭；JWT 扩展开启、JWT 可读且通知渠道开启后，仅 `.full` 模式轮询） |
| 套餐展示 | `GlmActivityPlanBalancesView`：排在标准额度之后，渲染生效中活动套餐进度条与失效倒计时，以及生效前预告置灰条 |
| 重置卡展示 | `QuotaWindowUsageSection.glmResetCardsModule`（`GlmResetCardsBlock`）：排在「额度窗口」之后，带有标题「重置卡详情」（`QuotaModuleTitle`），双列布局，左侧 5 小时卡 `5小时重置卡 (N)`、右侧周卡 `周重置卡 (N)`；每列最多展示前 3 张（`prefix(3)`），显示彩色紧迫度圆点、`MM-dd HH:mm` 与相对倒计时；无可用卡时不占卡片高度 |

**营销活动响应解析**（`GlmZcodeAPIClient.parseMarketingTouchResponse`）：接受 `data.deliveries` 或顶层 `deliveries`。活动 ID 按非空的 `id` → `delivery_id` → `campaign_id` → 套餐 ID → 标题 → 正文回退；字符串先去首尾空白。旧格式的顶层 `title`、`body` / `content` 与 `plan_id` / `planID` 优先。banner 格式的套餐 ID 从 `banner.buttons[].action` 中 `type == "claim_zcode_plan"` 的 `args.plan_id` 获取，缺失时取 `banner.background.args.zcode_plan.plan_id`；标题回退该套餐的 `name`，正文回退其 `entitlements` 中有效的 `show_name` 与正数 `grant_units`，格式为 `GLM-5.3-Flash 300000000 tokens 待领取`（多项以 `；` 分隔）。不使用 `success_popup` 的领取成功文案。仅有 `campaign_id` 的其他营销活动也保留，通知沿用默认文案。

### 额度重置卡接口与展示

LLM-monitor 仅读取 `GET https://zcode.z.ai/api/v1/coding-plan/reset/status`，按已配置的
「次要信息频率」在 `.full` 模式刷新。状态解析、失败降级与展示由本 Provider 实现；
客户端自己的发卡、用卡行为见 [ZCode harness spec](../harnesses/zcode.md#official-client-reset-card-behavior)。

`GET /status` 响应（envelope `{code, msg, data}`，时间戳为 unix **毫秒**）：

```json
{
  "code": 0,
  "msg": "success",
  "data": {
    "available_five_hour_resets": [],
    "available_week_resets": [
      { "expire_at": 1797955199000 }
    ],
    "latest_five_hour_reset_history": { "used_at": 1793167845000 },
    "latest_week_reset_history": { "used_at": 1793170881000 },
    "has_unread_history": false
  }
}
```

鉴权为**双头**（缺一不可）：

```
Authorization: Bearer <zcodejwttoken>            # ZCode 活跃 JWT（由 GlmZcodeCredentialReader 从 credentials.json 解密）
X-Bigmodel-Authorization: <Coding Plan API Key>       # 与标准额度 API 相同的必填配置 key
Bigmodel-Target-Type: PERSONAL                    # 个人账号固定为 PERSONAL；团队套餐为 TEAM
```

### ZCode 直连接口验证记录

2026-10-30 的历史响应记录如下；凭证文件与解密方式见
[ZCode harness spec](../harnesses/zcode.md#local-credentials)。这些旧请求的 token 写法记录当时实测，
当前 API Key / JWT 分工以本文件「认证凭证分工」为准。

**三大直连接口实测全部 HTTP 200 验证通过**：
   - **重置卡状态**：`GET https://zcode.z.ai/api/v1/coding-plan/reset/status`
     - 需 `Authorization: Bearer <jwt>` + `X-Bigmodel-Authorization: <token>` + `Bigmodel-Target-Type: PERSONAL`。
     - 实测返回可用周卡 3 张（`expire_at: 1797955199000`），5 小时卡 0 张。
   - **Start Plan 余额**：`GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=3.17.1`（实测时的版本；现已改为运行时从本机 ZCode.app 动态读取，见上表「接口 1」）
     - 需 `Authorization: Bearer <jwt>` + `X-Device-Mid` + `X-Client-Language: zh-CN` + `X-ZCode-App-Version` + `X-Bigmodel-Authorization` + `Bigmodel-Target-Type: PERSONAL`。
     - 实测返回 `ZCODE WEEKEND BUILD` 套餐，总量 500,000,000 tokens，剩余 500,000,000 tokens，生效时间 `effective_at: 1793372400`，到期时间 `ends_at: 1793581200`（注意：此接口时间戳为**秒**，与重置卡的**毫秒**不同，客户端均自适应转换）。
   - **营销活动触达（领鸡蛋）**：`GET https://zcode.z.ai/api/v1/marketing/touch?seq=1`
     - 需 `Authorization: Bearer <jwt>` + `X-Device-Mid` + `X-Client-Language: zh-CN`。
     - 实测返回 HTTP 200，`deliveries: []`（活动领取后为空；有活动未领取时返回活动 delivery 字典供触发推送）。
     - 2026-11-03 实测未领活动 `ZCODE GLOBAL BUILD`：delivery 使用 `campaign_id`，`banner.background.args.zcode_plan` 提供套餐名称与 GLM-5.3-Flash 300,000,000 tokens 权益，`banner.buttons[].action.type == "claim_zcode_plan"` 提供领取动作。已领取套餐余额接口此时仍可返回空列表，未领提醒必须读取 marketing 接口；解析回归见 `GlmZcodeAPIClientTests.testParseMarketingTouchResponseRecognizesClaimablePlanBanner`。

### 直连接口 vs 日志解析 架构对比

| 维度 | 直连 API 路线 | 历史本地轮询日志解析路线 |
|---|---|---|
| **重置卡获取** | **支持**（5h / 周卡数量及过期时间） | **不支持**（日志完全不记录重置卡请求与响应） |
| **未领运营活动（领鸡蛋）** | **支持**（可提前检测到未领弹窗，触发 Bark 推送提醒） | **不支持**（日志仅在用户手动点击领取后记录一条 success，无法做未领提醒） |
| **实时性** | **高**（LLM-monitor 后台周期性静默请求，无需打开 ZCode 客户端） | **低**（依赖 ZCode 桌面端必须保持运行并持续轮询写入） |
| **离线可用性** | 依赖网络 | **完全离线可用**（纯读本地 log 文件） |
| **鉴权失效风险** | 若用户退登或 Token 过期且久未启动 ZCode，可能返回 401 | 无（日志已落盘，不存在实时鉴权问题） |

**最终架构决策**：**Direct API Only（纯直连接口解析，解耦日志）**。
- 去除 `GlmZcodeLocalUsageScanner` 与 `LocalUsageOrchestration` 中的日志解析调用与目录监听；
- 统一由 `GlmCodingPlanFetcher` 在 JWT 扩展开启且本地读到 ZCode JWT 后，通过 `GlmZcodeAPIClient` 直连接口获取活动套餐、重置卡与营销触达；
- 当直连 API 失败或本地凭证缺失时静默降级（保留原有配额刷新，不阻断主流程），旧版轮询日志解析器已被彻底移除。

**可观测副作用**：用卡成功后 monitor 接口对应窗口的 `remaining` 立即回满、
`nextResetTime` 重新滚动——LLM-monitor 不做「疑似用卡」推断展示，卡片只反映
接口原始值。

### Implementation map

| Responsibility | Source |
|---|---|
| Data model | `Sources/LLM-monitor/Models/GlmLocalUsage.swift`（`GlmActivityPlanBalance` / `GlmActivityPlanPreview` 同文件） |
| ZCode 直连 API 客户端（套餐余额、重置卡、营销活动；`ZcodePackageProviding` 协议与默认实现 `GlmZcodeAPIPackageProvider` 同文件） | `Sources/LLM-monitor/Services/GlmZcodeAPIClient.swift` |
| ZCode app 版本解析（`app_version` / `X-ZCode-App-Version` 动态来源，读本机 ZCode.app Info.plist，失败回退 `3.17.1`） | `Sources/LLM-monitor/Services/ZcodeAppVersionResolver.swift` |
| Provider-neutral projection with OpenCode | `Sources/LLM-monitor/Models/ProviderClientModel.swift` (`ProviderStatus.usageProjection`，帧抽取表 `usageFrameExtractors`) + `UsageProjectionKernel` |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` + `QuotaViews.swift`；「额度窗口」表格「闲」行的构造在 `Sources/LLM-monitor/Views/ProviderCardDerived.swift`（`ProviderCardDerivedValues.offPeakUsageRow`），「免 / 速 / 它」三行在 `ProviderCardDerivedValues.glmCategoryUsageRows` |


See [ZCode harness implementation map](../harnesses/zcode.md#implementation-map) for the local SQLite scanner and credential reader.

## API Error Handling

| Situation | Current error |
|---|---|
| API Key missing or blank | `未配置 API Key` (`QuotaError.missingAPIKey`); local OAuth does not replace the key |
| URLSession error | `网络错误：<system message>` |
| Non-HTTP response | `响应格式无效` |
| HTTP non-2xx | `HTTP <status>: <body preview>` (rare — monitor API returns 200 even for errors) |
| `code == 1000` (auth failed) | `HTTP 401: Coding Plan Key 无效或已过期（身份验证失败。）` |
| `code` other non-200 | `解析失败：GLM Coding Plan 返回错误 [<code>]: <msg>` |
| Missing `data` | `解析失败：响应缺少 data` |
| No `CREDIT_LIMIT` entries | `解析失败：GLM Coding Plan 未返回任何有效积分额度` |
| Counts invalid (e.g. `remaining > total`) | `解析失败：GLM Coding Plan 积分额度字段非法: ...` |
| JWT extension disabled or JWT missing | 主额度仍可请求；关闭时不读取本地凭证，开启但缺少 JWT 时跳过 ZCode 套餐、重置卡和营销接口 |

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
- ZCode 侧的 zcode-plan / coding-plan-reset 接口（`zcode.z.ai`）：JWT 扩展开启且本地读到 JWT 后通过 `GlmZcodeAPIClient` 获取活动套餐余额与额度重置卡；双头接口的 BigModel 凭证只使用配置的 API Key（旧日志解析器已废弃删除）。

## Test Coverage

Provider quota and ZCode extension API coverage is in
`Tests/LLMMonitorTests/GlmCodingPlanFetcherTests.swift`,
`GlmZcodeAPIClientTests.swift`, `GlmZcodePackageOrchestrationTests.swift`, and
`ZcodeAppVersionResolverTests.swift`. Peak-window boundaries and holiday behavior are covered
by shared `PeakWindowTests.swift` and `HolidayCalendarTests.swift`.

| Test | What it verifies |
|---|---|
| `testMissingAPIKeyDoesNotFallBackToOAuthCredential` | Missing or blank API Key prevents fetching even when local OAuth and JWT are present |
| `testJWTFlagOffSkipsPackageDespiteLegacyCredentialMode` | Explicitly disabled JWT extension keeps standard quota and skips all ZCode requests |
| `testJWTAndAPIKeyFetchDetailsWithoutOAuth` | Enabled JWT extension fetches details using JWT plus API Key without OAuth |
| `testAPIKeyWithoutJWTStillFetchesStandardQuota` | Missing JWT skips extension requests while standard quota succeeds |
| `testGlmCodingPlanFetcherParsingAndWindows` | Successful response, both windows, plan label, and display name |
| `testGlmFetcherErrorHandling` | Business failure and empty-limit error paths |
| `testGlmCodingPlanFetcherErrorPaths` | Invalid remaining/total boundary |
| `testGlmPeakWindowStatusRules` | Peak-window status and config mapping |
| `testGlmPeakWindowBoundaryAndWeekdaysOnly` | Half-open boundary and weekday filtering |

ZCode SQLite reader, scanner, accounting, and category tests are listed in the
[ZCode harness spec](../harnesses/zcode.md#test-coverage).

> 核对基线：2026-11-06 · 代码 240b306
