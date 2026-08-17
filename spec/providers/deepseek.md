# DeepSeek — Provider Spec

Provider id: `deepseek`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift`
- Peak window: `Sources/LLM-monitor/Models/DeepseekPeakWindow.swift`
- Tests: `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`, `Tests/LLMMonitorTests/DeepseekPeakWindowTests.swift`

DeepSeek 余额来自官方开放接口，展示为"账户剩余余额"（货币金额），不是 5h / 周积分窗口。
本地 token 用量没有 native scanner（DeepSeek 官方无本地 CLI 账本），只有可选的 OpenCode
`deepseek` provider slice 合并。

## Accounting contract

DeepSeek 官方余额接口没有本地 token harness，因此 DeepSeek 卡片本身没有 native
sample/daily accounting。若合并 OpenCode，使用 OpenCode 的统一四桶口径；余额金额和
本地 API 名义价值是两条独立信息。统一规则（包括 `cacheWrite` 不计入估算）见
[`spec/accounting.md`](../accounting.md)。

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.deepseek.apiKey` |
| Required key type | DeepSeek 开放平台 (platform.deepseek.com) API Key，格式 `sk-...` |
| Balance endpoint | `GET https://api.deepseek.com/user/balance` |
| Quota timeout | 15 seconds (`HTTPTimeouts.request`) |
| Balance unit | `is_available` + `balance_infos[]`（`currency` / `total_balance` / `granted_balance` / `topped_up_balance`） |
| Display | 总余额 → `planLabel`（`¥100.50`）；充值 / 赠金明细 → hover（`充值: ¥90.50 | 赠金: ¥10.00`） |
| Remaining percent | `100` if `is_available` 且 `total_balance > 0`，否则 `0` |
| Windows | interval `.present`（余额即 interval 口径）；weekly `.absent` |
| Peak hours | 北京时间工作日 9:00–12:00 & 14:00–18:00（`DeepseekPeakWindow.defaultWindow`）；时段固定不可调，周末平价开关可配置 |
| Local token source | 无 native scanner；可选 OpenCode `deepseek` provider slice 合并 |

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "deepseek": {
      "enabled": true,
      "apiKey": "sk-xxxxxxxxxxxxxxxx",
      "mergeOpencodeUsage": false,
      "deepseekPeakWeekdaysOnly": true
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `apiKey` | DeepSeek API Key. Empty values and `REPLACE...` placeholders are treated as missing (`ProviderConfig.usableAPIKey`). |
| `refreshIntervalSeconds` | Optional independent refresh interval (overrides global default of 300s). |
| `displayName` | Optional card title override. |
| `mergeOpencodeUsage` | Adds OpenCode `deepseek` model token data on top of the balance display. Missing defaults to `false` (no native local ledger to preserve). |
| `deepseekPeakWeekdaysOnly` | 高峰期是否仅工作日（周一–周五），周末全天平价。缺省 = `true`（默认周末平价）。设为 `false` 时每天（含周末）都执行高峰时段。 |

`DeepseekFetcher.hasLocalAuth()` always returns `true`; `AppState` validates the config `apiKey`.

## Balance semantics

The DeepSeek balance endpoint returns per-currency entries. The fetcher uses the first
`balance_infos` entry:

- `total_balance` → card balance `planLabel`（`$`/`¥` 按 `currency == "USD"` 选择符号）。
- `topped_up_balance` / `granted_balance` → hover 明细（充值 / 赠金）。
- `is_available == false` 或 `total_balance <= 0` → remaining percent 归 0（红色 critical 语义）。
- 三个余额字符串若存在但无法解析，或解析为 `NaN` / infinity，则按 `decodingError` 拒绝，
  防止非有限数进入百分比格式化和整数转换。

`healthLevel` 走 interval 分支：余额可用 → 100% → healthy，不可用 → 0% → critical。
0/100% 的"百分比"不会被当作进度条展示：`ProviderCardView.shouldUseDeepseekBalanceRow`
对 `.deepseek` 直接路由到 `DeepseekBalanceRow`（余额金额行），绕过百分比进度条。

## Peak hours (北京时间)

DeepSeek 官方定价规则：**北京时间工作日 9:00–12:00 与 14:00–18:00** 为高峰，高峰期价格
为平时 2 倍。判定全程基于 `Asia/Shanghai` 时区 Calendar（`DeepseekPeakWindow.beijingCalendar`），
与用户本机时区无关。

**周末平价**：经确认 DeepSeek 周六、周日不执行高峰定价，与 GLM 的「仅工作日」语义对齐。
`DeepseekPeakWindow` 提供 `weekdaysOnly` 字段（默认 `true`，即默认周末全天平价）：

- `weekdaysOnly = true`（默认）：周一–周五执行 9–12 / 14–18 高峰；周六、周日全天平价，
  倒计时直接指向下周一 9:00。`nextPeakStart` 逐日扫描跳过非高峰日（最多 8 天，覆盖周末）。
- `weekdaysOnly = false`：每天（含周末）都执行 9–12 / 14–18 高峰。

高峰时段本身（9–12 / 14–18）为官方固定政策，时段不可调；只有周末平价开关可配置
（设置页「高峰期提示」段的「仅工作日（周一–周五）」Toggle，对应 `providers.deepseek.deepseekPeakWeekdaysOnly`）。
UI 上 `DeepseekPeakIndicatorView` 嵌在余额行右侧：
- 高峰期 🔥：`高峰 2× · 还剩 X`（红色 pill）
- 非高峰期，距高峰 < 1 小时 ❄️：`距高峰 X`（橙色 pill，临近）
- 非高峰期，距高峰 ≥ 1 小时 ❄️：`距高峰 X`（绿色 pill）

倒计时纯本地计算，不依赖 API 响应，刷新失败也能显示。

## OpenCode merge

OpenCode 的 `deepseek` provider 分片作为可选叠加源（`mergeOpencodeUsage` 开关，DeepSeek
缺省关闭），按字段逐项相加到卡片本地数据。DeepSeek 没有 native 本地账本，因此开启后
柱图 / 今日汇总完全来自 OpenCode 数据；关闭时卡片只显示远程余额。

## Error mapping

| Response | QuotaError | User-facing |
|---|---|---|
| 空 / 空白 API Key | `missingAPIKey` | `未配置 API Key` |
| 非 2xx（401 / 5xx） | `httpError(status, body)` | 401 → `DeepSeek API Key 无效或已过期`；其他 → `HTTP <status>: ...` |
| `balance_infos` 缺失或为空 | `decodingError` | `解析失败：DeepSeek 未返回任何余额条目` |
| 余额字段非数字、`NaN` 或 infinity | `decodingError` | `解析失败：DeepSeek 返回了无效的余额字段` |
| JSON 无法解析 | `decodingError` | `解析失败：DeepSeek 返回的 JSON 无法解析` |
| 取消 | 透传 `CancellationError` / `URLError.cancelled` | 上层走 `.deferred`，不计 failure |

## Implementation map

| Responsibility | Source |
|---|---|
| Balance fetcher + parse | `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift` |
| Peak window (Beijing time) | `Sources/LLM-monitor/Models/DeepseekPeakWindow.swift` |
| Balance row + peak indicator | `Sources/LLM-monitor/Views/QuotaViews.swift`、`Views/DeepseekPeakIndicatorView.swift` |
| Account hover | `Sources/LLM-monitor/Views/DeepseekAccountView.swift` |
| Settings pane | `Sources/LLM-monitor/Views/SettingsView.swift`（`deepseekPane`） |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` |
| Brand logo | `Sources/LLM-monitor/Resources/BrandLogos/deepseek.svg`、`Views/BrandLogoView.swift` |
| Regression tests | `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`、`DeepseekPeakWindowTests.swift` |
