# DeepSeek — Provider Spec

Provider id: `deepseek`

Implementation:
- API fetcher: `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift`
- Peak window: `Sources/LLM-monitor/Models/PeakWindow.swift` (`DeepseekPeakWindow` is a compatibility typealias)
- Tests: `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`, `Tests/LLMMonitorTests/PeakWindowTests.swift`

DeepSeek 余额来自官方开放接口，展示为"账户剩余余额"（货币金额），不是 5h / 周积分窗口。
本地 token 用量没有 native scanner（DeepSeek 官方无本地 CLI 账本），来自三路共享账本分片：
ZCode `deepseek` provider slice（默认开启）、DSH `deepseek` provider（默认开启）与可选的
OpenCode `deepseek` provider slice（默认关闭）合并。

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
| Remaining percent | `100` if `is_available` 且 `total_balance > 0`，否则 `0` |
| Windows | interval `.present`（余额即 interval 口径）；weekly `.absent` |
| Peak hours | 北京时间工作日 9:00–12:00 & 14:00–18:00（`DeepseekPeakWindow.defaultWindow`）；时段固定不可调，高峰永不含周末（周六、周日全天平价），法定节假日的周一–周五同样不算高峰（Rule A） |
| Local token source | 无 native scanner；ZCode `deepseek` 分片（默认开启）+ DSH `deepseek` provider（默认开启）+ 可选 OpenCode `deepseek` 分片（默认关闭）合并 |
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
| `clientBindings[]` | The canonical client-to-quota binding controls whether client `deepseek` samples are projected into the card. `zcode` 与 `dsh` 两条绑定**默认开启**、OpenCode `deepseek` 绑定**默认关闭**（事实源是 `Sources/LLM-monitor/Models/ClientIdentity.swift` 的 `ClientProviderBinding.defaultBindings`；`Sources/LLM-monitor/Services/ConfigStore.swift` 的 `defaultClientBindings` 是它的兼容再导出别名）。The legacy provider-level field is migration compatibility only. |

> **Note**: `deepseekPeakWeekdaysOnly` was removed together with the settings toggle
> (peak never includes weekends is now fixed official policy). Old config files that
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

### Aggregation & notification semantics（纯余额口径）

DeepSeek 为纯余额语义（无配额窗口）：quotaLogo 仪表盘聚合与通知管道均已排除
DeepSeek——`AppState.statusBarQuotaMetrics` 的循环以 `where status.kind != .deepseek`
过滤，通知侧由 `ProviderKind.windowedKinds` 门控（余额 0/100 二值化不具备窗口语义，
余额触发器暂不接入）。但传统 SF Symbol 图标样式的健康圆点（`AppState.systemHealthLevel`）
当前仍**有意**计入 DeepSeek 余额健康度（余额为 0 → critical）。此口径差异为保留
设计，未来改进可能统一（见 `AppState.swift` 中 `statusBarQuotaMetrics` 处的代码注释）。

## Peak hours (北京时间)

DeepSeek 官方定价规则：**北京时间周一至周五 9:00–12:00 与 14:00–18:00** 为高峰，高峰
价格为平价（1×）的 2 倍。判定全程基于 `Asia/Shanghai` 时区 Calendar
（`DeepseekPeakWindow.beijingCalendar`），与用户本机时区无关。

**工作日口径（Rule A，与 GLM 统一形状）**：工作日 = 周一–周五 ∧ 当天不是法定节假日。
法定节假日（含调休换来的放假日，常落在周一–周五）不算高峰、高峰 ×2 倍率不加倍
（数据源为打包快照 `Resources/ChinaHolidays.json`，加载与退化行为见
`Models/HolidayCalendar.swift`）；调休上班的周六/周日**有意不建模**——它们本来就不是
周一–周五，天然不算高峰。

**周末平价（官方口径）**：经确认 DeepSeek 周六、周日不执行高峰定价，高峰永不含周末。
`DeepseekPeakWindow.defaultWindow` 固定为 `slots [9–12, 14–18]` + `weekdaysOnly: true`：

- 周一–周五执行 9–12 / 14–18 高峰（法定节假日除外）；周六、周日全天平价（1×），
  倒计时直接指向下一个工作日 9:00。`nextPeakStart` 逐日扫描跳过非高峰日
  （15 天预算：春节 8 天法定假 + 紧邻周末最长空档 ~11 天）。
- 高峰窗口整体固定，无任何 config 字段或设置开关可调（「仅工作日」开关与
  `deepseekPeakWeekdaysOnly` 配置键已移除；旧配置文件中的残留键会被静默忽略）。

UI 上 `DeepseekPeakIndicatorView` 嵌在余额行右侧：
- 高峰期 🔥：`高峰 2× · 还剩 X`（红色 pill）
- 非高峰期，距高峰 < 1 小时 ❄️：`距高峰 X`（橙色 pill，临近）
- 非高峰期，距高峰 ≥ 1 小时 ❄️：`距高峰 X`（绿色 pill）

倒计时纯本地计算，不依赖 API 响应，刷新失败也能显示。两个卡片宿主（菜单兜底行
hover 浮层 / dock 浮层）均经 `DisplayClockScope` 注入随面板显隐 start/stop 的
共享展示时钟，倒计时每秒推进（机制与 GLM 同源，见 `spec/providers/glm.md`
§Live countdown 行）。

## OpenCode merge

OpenCode 的 `deepseek` provider 分片作为可选叠加源，由 `config.json` 的
`clientBindings[]` 控制（DeepSeek 缺省关闭），按字段逐项相加到卡片本地数据。DeepSeek
没有 native 本地账本，因此三路分片全部关闭时卡片只显示远程余额。设置页不提供独立
Toggle，merge 状态随 `configStore.config` 原样透传，修改 binding 后会热加载。

## ZCode merge

ZCode 的 `deepseek` provider 分片（`model_usage` 表中 `provider_id` 前缀为 `deepseek`
的行，经 `ZcodeProviderSlice` 切出）**默认并入**本卡，由 `clientBindings[]` 的
`zcode → deepseek` 绑定控制。与 DSH / OpenCode 分片按字段逐项相加；`input` 按
cache-inclusive 上报拆成 uncached / cache-read 两个不相交桶（见 Accounting contract）。
ZCode 分片样本由帧抽取时施加 `zcode:deepseek:` 命名空间（`UsageSampleNamespace.zcodeSlice`），
不会与其它来源互相去重。

## DSH merge

DSH（DeepSeek Harness）的多 provider session 账本同样并入本卡，**默认开启**。
DSH 帧不声明归属，由 `UsageProjectionKernel` 按 `clientBindings[]` 的
`dsh → deepseek` 绑定解析，别名表（大小写不敏感的 `==` / `contains` 匹配）为
`deepseek`、`deepseek-official`、`deepseek-cn`、`deepseek-v4`。没有任何启用的 dsh
绑定认领的 provider key 会被丢弃，并在 `AppState.applyDshUsage` 记一条列出未认领 id 与
已注册别名的告警（手改别名打错字不会静默失败）。DSH 的 `cacheWriteTokens` 只保留在
raw daily 诊断字段，不进入统一 total / 图表 / 金额。详见 [`dsh.md`](./dsh.md)。

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
| Balance row + peak indicator | `Sources/LLM-monitor/Views/QuotaViews.swift`（`DeepseekBalanceRow`）、`Views/DeepseekPeakIndicatorView.swift` |
| Settings pane | `Sources/LLM-monitor/Views/SettingsView.swift`（`deepseekPane`） |
| Card integration | `Sources/LLM-monitor/Views/ProviderCardView.swift` |
| Brand logo | `Sources/LLM-monitor/Resources/BrandLogos/deepseek.svg`、`Views/BrandLogoView.swift` |
| Regression tests | `Tests/LLMMonitorTests/DeepseekFetcherTests.swift`、`PeakWindowTests.swift` |

> 核对基线：2026-10-05 · 代码 6128ab5
