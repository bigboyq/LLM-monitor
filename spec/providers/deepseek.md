# DeepSeek — Provider Spec

Provider id: `deepseek`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift`
- Peak window: `Sources/LLM-monitor/Models/PeakWindow.swift` (`DeepseekPeakWindow` is a compatibility typealias)
- Tests: `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`, `Tests/LLMMonitorTests/PeakWindowTests.swift`

DeepSeek 余额来自官方开放接口，展示为"账户剩余余额"（货币金额），不是 5h / 周积分窗口。
本地 token 用量没有 native scanner（DeepSeek 官方无本地 CLI 账本），来自三路共享账本分片：
ZCode、DSH 与 OpenCode 中可识别为 DeepSeek 的 provider 分片会自动归入本卡。

## Accounting contract

DeepSeek 官方余额接口没有本地 token harness，因此 DeepSeek 卡片本身没有 native
sample/daily accounting。若合并 ZCode / DSH / OpenCode 分片，使用统一的四桶口径（ZCode 的
`input_tokens` 为 cache-inclusive 上报，按 `uncached = max(input − cache_read, 0)` 拆桶；
DSH 与 OpenCode 的 raw input 本就是 uncached）；余额金额和本地 API 名义价值是两条独立信息。
统一规则（包括 `cacheWrite` 不计入估算）见
[`spec/accounting.md`](../accounting.md)。

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | `providers.deepseek.apiKey` |
| Required key type | DeepSeek 开放平台 (platform.deepseek.com) API Key，格式 `sk-...` |
| Balance endpoint | `GET https://api.deepseek.com/user/balance` |
| Quota timeout | 10 seconds (`HTTPTimeouts.domestic`) |
| Balance unit | `is_available` + `balance_infos[]`（`currency` / `total_balance` / `granted_balance` / `topped_up_balance`） |
| Display | 余额行（`DeepseekBalanceRow`）标题 `API 账户余额`，右端 `planLabel` 金额（`¥100.50`）；`充值: ¥90.50` / `赠金: ¥10.00` 与高峰指示器同处该行第二行（单行截断，完整文本走 tooltip） |
| Edge dock | A single full-size status ring; known availability is shown with the existing health tint and the circle-below label `可用` / `不可用`. Unknown availability shows the neutral track and `—`; the dock never maps the compatibility 0/100 health value to a quota arc. |
| Remaining percent | `100` if `is_available` 且 `total_balance > 0`，否则 `0` |
| Windows | interval `.present` 仅保留旧状态/可用性语义，weekly `.absent`；DeepSeek 没有 5h / 周额度池与重置时间 |
| Peak hours | 默认北京时间工作日 9:00–12:00 & 14:00–18:00，默认高峰倍率 2×（`DeepseekPeakWindow.defaultWindow`）；Provider JSON 的 `peakWindow` 可覆盖时段、工作日限制与倍率，设置页只读展示。默认排除周末与法定节假日（Rule A） |
| Local token source | 无 native scanner；自动归入已支持的 ZCode、DSH、OpenCode DeepSeek 分片 |
| Balance model row | 单个合成 model `deepseek_balance`，`ModelQuota.displayName` → `DeepSeek API 余额` |

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "deepseek": {
      "enabled": true,
      "apiKey": "sk-xxxxxxxxxxxxxxxx"
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
| `peakWindow` | Optional slots / weekdaysOnly / multiplier override; defaults to weekday 9–12 & 14–18, multiplier 2. See `spec/config.md` §Config Schema. |

> **Note**: `deepseekPeakWeekdaysOnly` was removed together with the settings toggle
> (the default still excludes weekends). Old config files that
> still carry the key decode fine — the JSON key is silently ignored and is never
> written back.

`DeepseekFetcher.hasLocalAuth()` always returns `true`; `AppState` validates the config `apiKey`.

## Balance semantics

The DeepSeek balance endpoint returns per-currency entries. The fetcher uses the first
`balance_infos` entry:

- `total_balance` → card balance `planLabel`（`$`/`¥` 按 `currency == "USD"` 选择符号）。
- `topped_up_balance` / `granted_balance` → 结构化 `DeepseekBalanceDetail`，由
  `DeepseekBalanceRow` 在余额行内联展示（充值 / 赠金），字段缺失时按 `0` 处理。
- `is_available` 缺失按 `true` 处理；`is_available == false` 或 `total_balance <= 0` →
  remaining percent 归 0（红色 critical 语义）。
- 三个余额字符串若存在但无法解析，或解析为 `NaN` / infinity，则按 `decodingError` 拒绝，
  防止非有限数进入百分比格式化和整数转换。

`healthLevel` 走 interval 分支：余额可用 → 100% → healthy，不可用 → 0% → critical。
0/100% 的"百分比"不会被当作进度条展示：`ProviderCardView.shouldUseDeepseekBalanceRow`
对 `.deepseek` 直接路由到 `DeepseekBalanceRow`（余额金额行），绕过百分比进度条。
该 model 的 interval 字段仍为 `.present` 仅为了既有额度状态与 100/0 可用性语义；不能将它显示为「5h」或展示重置日期。边缘状态窗用单个完整状态环表达可用性健康档（已知时按健康色绘制完整强度的满环，未知时仅显示中性底槽），保留圈下「可用」/「不可用」/「—」标签；不把该字段解释为剩余比例，也不绘制第二个周环。共享 Plan 的余额行是唯一金额明细来源，显示账户总余额以及真实充值 / 赠金；菜单折叠摘要显示总余额与赠金。额度窗口历史分析表对 DeepSeek 隐藏，不重复解释本地 token 消耗为额度窗口，也不另画一份余额表。

### Aggregation & notification semantics（纯余额口径）

DeepSeek 为纯余额语义（无配额窗口）：quotaLogo 仪表盘聚合与通知管道均已排除
DeepSeek——`AppState.statusBarQuotaMetrics` 的循环以 `where status.kind != .deepseek`
过滤，通知侧由 `ProviderKind.windowedKinds` 门控（余额 0/100 二值化不具备窗口语义，
余额触发器暂不接入）。但传统 SF Symbol 图标样式的健康圆点（`AppState.systemHealthLevel`）
当前仍**有意**计入 DeepSeek 余额健康度（余额为 0 → critical）。此口径差异为保留
设计，未来改进可能统一（见 `AppState.swift` 中 `statusBarQuotaMetrics` 处的代码注释）。

## Peak hours (北京时间)

DeepSeek 默认定价规则：**北京时间周一至周五 9:00–12:00 与 14:00–18:00** 为高峰，高峰
价格为平价（1×）的 2 倍。Provider JSON 的 `peakWindow` 可覆盖时段、`weekdaysOnly` 与 `multiplier`（支持 1.5、3 等倍率），提示与本地 / Fleet 金额估算使用同一窗口。判定全程基于 `Asia/Shanghai` 时区 Calendar
（`DeepseekPeakWindow.beijingCalendar`），与用户本机时区无关。

**默认工作日口径（Rule A，与 GLM 统一形状）**：工作日 = 周一–周五 ∧ 当天不是法定节假日。
法定节假日（含调休换来的放假日，常落在周一–周五）不算高峰、高峰 ×2 倍率不加倍
（数据源为打包快照 `Resources/ChinaHolidays.json`，加载与退化行为见
`Models/HolidayCalendar.swift`）；调休上班的周六/周日**有意不建模**——它们本来就不是
周一–周五，天然不算高峰。

**周末平价（默认口径）**：DeepSeek 默认周六、周日不执行高峰定价。
`DeepseekPeakWindow.defaultWindow` 为 `slots [9–12, 14–18]` + `weekdaysOnly: true` + `multiplier: 2`：

- 周一–周五执行 9–12 / 14–18 高峰（法定节假日除外）；周六、周日全天平价（1×），
  倒计时直接指向下一个工作日 9:00。`nextPeakStart` 逐日扫描跳过非高峰日
  （15 天预算：春节 8 天法定假 + 紧邻周末最长空档 ~11 天）。
- 自定义配置使用 `peakWindow`；`weekdaysOnly: false` 时每天执行指定时段。设置页没有编辑开关，只展示当前配置；旧平铺键 `deepseekPeakWeekdaysOnly` 仍忽略。

UI 上 `DeepseekPeakIndicatorView` 嵌在余额行右侧（倍率只在偏离平时 1× 时标注，
非高峰默认价不显示倍率，2026-11-07 用户裁定）：
- 高峰期 🔥：`高峰期 2× · 还剩 X`（红色 pill，倍率取当前 `PeakWindow.multiplier`）
- 非高峰期，距高峰 < 1 小时 ❄️：`距高峰期 X`（橙色 pill，临近）
- 非高峰期，距高峰 ≥ 1 小时 ❄️：`距高峰期 X`（绿色 pill）

倒计时纯本地计算，不依赖 API 响应，刷新失败也能显示。两个卡片宿主（菜单兜底行
hover 浮层 / dock 浮层）均经 `DisplayClockScope` 注入随面板显隐 start/stop 的
共享展示时钟，倒计时每秒推进（机制与 GLM 同源，见 `spec/providers/glm.md`
§Live countdown 行）。

## OpenCode merge

OpenCode 的 `deepseek` provider 分片按内置 provider 路由自动叠加到卡片本地数据，按字段
逐项相加。归因不通过设置或 `config.json` 控制；没有已支持别名的 provider ID 不会被猜测
归入 DeepSeek。

## ZCode merge

ZCode 的 `deepseek` provider 分片（`model_usage` 表中 `provider_id` 前缀为 `deepseek`
的行，经 `ZcodeProviderSlice` 切出）自动并入本卡。与 DSH / OpenCode 分片按字段逐项相加；`input` 按
cache-inclusive 上报拆成 uncached / cache-read 两个不相交桶（见 Accounting contract）。
ZCode 分片样本由帧抽取时施加 `zcode:deepseek:` 命名空间（`UsageSampleNamespace.zcodeSlice`），
不会与其它来源互相去重。

## DSH merge

DSH（DeepSeek Harness）的多 provider session 账本自动并入本卡。DSH 帧不声明归属，由
`UsageProjectionKernel` 按内置 alias registry 的 `dsh → deepseek` 路由解析；别名匹配
大小写不敏感且为 `==` / `contains`：`deepseek`、`deepseek-official`、`deepseek-cn`、
`deepseek-v4`。未知 provider key 不会被猜测归类，会被丢弃并由 `AppState.applyDshUsage`
记录未认领 ID 与已注册别名。DSH 的 `cacheWriteTokens` 只保留在
raw daily 诊断字段，不进入统一 total / 图表 / 金额。详见 [`dsh.md`](../harnesses/dsh.md)。

## Error mapping

| Response | QuotaError | User-facing |
|---|---|---|
| 空 / 空白 API Key | `missingAPIKey` | `未配置 API Key` |
| 非 2xx（401 / 5xx） | `httpError(status, body)` | 401 → `DeepSeek API Key 无效或已过期`（`QuotaError.userFacingDescription`）；其他 → `HTTP <status>，响应 <N> bytes`（`includeBodyInError: false`，不回显 body） |
| 响应体超过 8 MiB | `responseTooLarge` | `响应过大（上限 … bytes）：<脱敏 endpoint>` |
| `balance_infos` 缺失或为空 | `decodingError` | `解析失败：DeepSeek 未返回任何余额条目` |
| 余额字段非数字、`NaN` 或 infinity | `decodingError` | `解析失败：DeepSeek 返回了无效的余额字段` |
| JSON 无法解析 | `decodingError` | `解析失败：DeepSeek 返回的 JSON 无法解析` |
| 取消 | 透传 `CancellationError` / `URLError.cancelled` | 上层走 `.deferred`，不计 failure |

## Implementation map

| Responsibility | Source |
|---|---|
| Balance fetcher + parse | `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift` |
| Peak window (Beijing time) | `Sources/LLM-monitor/Models/PeakWindow.swift` (`DeepseekPeakWindow` is a compatibility typealias) |
| Balance row + peak indicator | `Sources/LLM-monitor/Views/DeepseekBalanceRow.swift`（`DeepseekBalanceRow`）、`Views/DeepseekPeakIndicatorView.swift` |
| Settings pane | `Sources/LLM-monitor/Views/SettingsProviderPanes.swift`（`deepseekPane`，`extension SettingsView`） |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` |
| Brand logo | `Sources/LLM-monitor/Resources/BrandLogos/deepseek.svg`、`Views/BrandLogoView.swift` |
| Regression tests | `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`、`PeakWindowTests.swift` |

> 核对基线：2026-11-10 · 代码 7b50bba
