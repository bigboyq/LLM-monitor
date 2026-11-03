# Config Schema 与构建打包

`config.json` 的字段契约、运行时落盘文件、构建与打包脚本。改配置字段从本文件 §Config Schema 入手；改 UI 侧字段的展示语义另见 `ui-design.md`（及其拆分出的 `ui/*.md`）。

## Config Schema

The app reads and writes this shape:

```json
{
  "schemaVersion": 3,
  "refreshIntervalSeconds": 300,
  "providers": {
    "minimax_token_plan": {
      "enabled": false,
      "apiKey": "sk-cp-REPLACE-WITH-YOUR-KEY"
    },
    "codex_chatgpt": {
      "enabled": false,
      "authPath": "~/.codex/auth.json"
    },
    "antigravity": {
      "enabled": false
    },
    "glm_coding_plan": {
      "enabled": false,
      "apiKey": "REPLACE-WITH-YOUR-CODING-PLAN-KEY"
    },
    "deepseek": {
      "enabled": false,
      "apiKey": "sk-REPLACE-WITH-YOUR-KEY"
    }
  }
}
```

首次启动模板默认关闭所有 provider，避免占位 Key 被误认为已配置。菜单中会显示“打开设置”引导；配置真实凭据后再启用对应 provider。上表是 `ConfigStore.writeTemplate` 实际生成的模板默认值（见 `ConfigStore.templateProviders()`）；两点需要说明：

- Harness 用量自动按账本 provider 归因，不提供归因开关。路由别名事实源是内置 `ClientProviderBinding.defaultBindings`（10 条共享账本路由全部有效）；native 帧直接使用其 `quotaProviderID`。模板不写 `clientBindings`，旧键与 provider 级 `mergeOpencodeUsage` 解码时忽略，保存时清理。
- 模板**不写** `providerCardOrder`（nil 被 `encode(to:)` 省略），首屏按 Provider 显示名字母序；用户第一次在设置页调序后才出现该键。`statusBarIconStyle` / `statusBarHealthDotEnabled` / `statusBarHealthColors` / `bark` / `edgeDock` 同理，模板一律不写，缺省值见下表。

`refreshIntervalSeconds` 除了顶层全局默认，还可以在每个 provider 下**可选覆盖**。模板默认不写该字段，下面是一个让 Codex 每 60 秒刷新一次的自定义示例（并非模板默认值）：

```json
"codex_chatgpt": {
  "enabled": true,
  "authPath": "~/.codex/auth.json",
  "refreshIntervalSeconds": 60
}
```

| Field | Scope | Meaning |
|---|---|---|
| `schemaVersion` | global | Configuration schema version. Missing legacy values decode as version 0 and are normalized to the current version; unsupported future versions are rejected rather than silently defaulted. Schema 3 adds the `sync` block (multi-machine fleet sync, see `spec/sync.md`). |
| `sync` | global | 多机联动配置（`SyncConfig`）。缺省或不写 = `enabled: false`，完全不参与（现有用户零影响）；坏值按未配置处理（逐字段容错，只回退该字段）。字段：`enabled`（缺省 false）、`hubURL`（空 = 本机为主节点 hub；非空 = 副节点 node，且不监听端口——角色由 `SyncRole.derive` 单源派生）、`pushIntervalSeconds`（默认 `0`，缺失、类型错误或越界值也回退 `0`；`0` 跟随 `effectiveGlobalRefreshInterval`，即“跟随常规”；显式正数保持原值；config 允许 `1...86400` 秒，设置页输入范围仍为 `0...3600` 秒，即跟随全局或 1 秒至 1 小时）、`hubBindHost`（默认 `0.0.0.0`；`127.0.0.1`/`localhost` 时只绑回环）、`hubPort`（默认 8787）、`nodeName`（空 = hostname）、`staleAfterSeconds`（默认 900）、`quotaMaxAgeSeconds`（默认 1800）、`retainDays`（默认 7）。旧文件中的 `sync.nodeID` 不再是身份来源，也不会迁移到设备身份文件。启用联动时的本机 UUID 独立存放在 config 同目录的 `.deviceId`；复制 config 无需改旧 UUID，但不得复制 `.deviceId`。配置变化会热更新角色、监听端口、上游与推送周期。协议与运行时见 `spec/sync.md`。 |
| `refreshIntervalSeconds` | global | Default refresh interval in seconds. Current default is `300`; effective values are clamped to 10 seconds...30 days. |
| `statusBarIconStyle` | global | Selected menu-bar icon theme. Missing or invalid values use `chartBar`. |
| `statusBarHealthDotEnabled` | global | Shows the 6 pt health dot on the menu-bar icon. Missing or invalid values default to `true`. |
| `statusBarHealthColors` | global | `healthyHex` / `warningHex` / `criticalHex` overrides for the health dot and Icon Duo arcs. Missing or malformed falls back to `StatusBarHealthColors.default` (`#34C759` / `#FFD60A` / `#FF453A`). |
| `edgeDock` | global | 屏幕边缘状态窗配置（`EdgeDockConfig`）。缺省等价于 `EdgeDockConfig.default`：`mode = .autoHideWindow`（默认开启、平时收起为小圆环）、`edge = .right`、`offset = 0.5`、`hideInFullscreen = true`、`compactSize = .small`、`independentRingColors = true`。`screenUUID` 为 nil 时跟随当前所在屏。**逐字段容错**：手改坏值只回退该字段，不整块报废（外层用 `try?` 解码，整块失败会连用户拖好的位置一起静默重置）。详见 `spec/ui/edge-dock.md`。 |
| `bark` | global | Bark 推送渠道（`BarkConfig`：`enabled` / `serverURL` / `deviceKey` / `sound` / `skipWhenAwakeAndUnlocked` / `ttl` / `group`）。字段缺失或 `enabled == false` 都表示不推送。详见 `spec/notifications.md`。 |
| `systemNotificationSoundEnabled` | global | 系统通知声音开关（optional Bool，缺省 true；非法类型回退默认）。通知页随普通草稿保存，开启写 nil、关闭写 false；系统通知内容与前台呈现共同遵循，Bark 铃声独立。 |
| `holidaySource` | global | 法定节假日数据源（URL 或本地文件路径），供 `HolidayCalendar` 解析链取数。缺省（不写键）= 上游 chinese-days CDN JSON（`HolidayCalendar.defaultSourceURL`，与 `scripts/sync-holiday-data.sh` 的 `UPSTREAM_URL` 同值）；**显式空串** = 只用随 App 打包的内置快照、不联网；其余值按 http(s) URL 或本地文件路径解析。类型写错按缺失处理（回退缺省语义）。缓存文件、取数触发与设置页展示见 `spec/ui/settings.md` 的「节假日数据源」。 |
| `appearance` | global | 应用外观（`AppAppearance`：`light` / `dark` / 缺省=自动跟随系统）。`AppState.applyAppearance` 写 `NSApp.appearance`，start 与每次配置变更时应用；设置页界面 pane「外观」节随普通表单草稿保存，选「自动」时字段不落盘。 |
| `providerCardOrder` | global | Optional ordered list of stable canonical Quota Provider IDs (for example `deepseek` or `minimax`) for the main menu cards. Missing, empty, unknown, or duplicate IDs are normalized; omitted items are appended by Provider display name. |
| `statusBarPinnedProvider` | global | 状态栏小眼睛锚定的 Provider ID（规范化 ID，如 `minimax`、`antigravity` 等）。缺省或 nil 表示全 Provider 聚合（取已启用且有有效配额的各 Provider 5h/周非零最小值）；非空且对应的 Provider 已启用且有有效配额时，状态栏双环（Icon Duo）与健康度圆点仅展示该服务商指标。卡片小眼睛点击单选/再点取消即时写穿。类型错误按缺失（nil）容错处理。 |
| `providers.<id>.enabled` | provider | Disabled providers stay visible but are not fetched. Missing `enabled` decodes as `true`. |
| `providers.<id>.apiKey` | provider | API key for providers that do not manage external auth. Used by minimax. |
| `providers.<id>.displayName` | provider | Optional UI label override. |
| `providers.<id>.refreshIntervalSeconds` | provider | Optional provider-specific timer interval, with the same 10-second...30-day clamp. |
| `providers.<id>.glmAuthMode` | provider | GLM 认证方式（`apiKey` / `credential`，缺省 `apiKey`）。选 `apiKey` 仅填写 API Key 并监控标准 5h 与周额度套餐；选 `credential` 自动读取本地 ZCode 凭据（免填 Key），支持标准套餐、活动套餐、额度重置卡与运营活动推送。 |
| `providers.<id>.authPath` | provider | 自管认证文件或所在目录路径。Codex 为 `auth.json` 路径（缺省 `~/.codex/auth.json`）；GLM 为 ZCode 凭证目录或 `credentials.json` 路径（缺省 `~/.zcode/v2`）。 |
| `providers.<id>.notifyCampaign` | provider | 运营活动通知渠道（`QuotaNotifyChannel`：`none` / `system` / `barkAndSystem`），用于 GLM 营销活动触达推送。默认关闭（`none`），仅在 `credential` 模式下生效且选定渠道时才发起轮询；按次要信息频率轮询（仅 `.full` 模式），发现活动 1h 内不重复推送，防抖不限制接口请求。 |
| `providers.<id>.parseZcodeCredential` / `parseZcodePlan` / `parseZcodeBalanceLog` | legacy | 兼容历史配置字段。解码时若为 true 自动迁移至 `glmAuthMode = .credential`，保存时不落盘。 |
| `providers.<id>.adminApiCreditsEnabled` | provider | 是否启用 OpenAI API 赠金监测（ChatGPT 专用）。缺省或 false 表示关闭；开启时在 ChatGPT 卡渲染「API赠金」进度条。 |
| `providers.<id>.adminApiKey` | provider | OpenAI Admin API Key（`sk-admin-...`），用于查询组织消耗 `v1/organization/costs`。 |
| `providers.<id>.adminBillingDay` | provider | 每月账单日（1-31，缺省 11）。 |
| `providers.<id>.adminBillingTime` | provider | 账单重置时间（`HH:mm`，如 `00:00` 或 `08:00`，缺省 `00:00`）。 |
| `providers.<id>.adminMonthlyQuotaLimit` | provider | 每月 API 赠金额度上限（美元，缺省 40.0）。 |
| `providers.<id>.notifyIntervalRestored` / `notifyIntervalExhausted` / `notifyWeeklyRestored` / `notifyWeeklyExhausted` | provider | 四类额度事件各自的推送渠道（`QuotaNotifyChannel`：`none` / `system` / `barkAndSystem`）。字段不存在 = 默认渠道（恢复 → 系统通知，耗尽 → 不通知），与引入通知配置前的行为一致。 |
| `clientBindings[]` | removed | 历史 Harness 归因开关与别名配置；解码忽略、不再编码。全部已支持来源按内置 provider 路由自动归因，旧 `enabled: false` 不再屏蔽真实用量；无法识别的 provider 不猜测归属。`AppConfig.clientBindings` 仅为只读内置路由的运行时兼容出口。 |
| `alerts` | global | 集中告警阈值配置（`AlertThresholdConfig`）。缺省或 nil 使用默认值（API 配额余量警告 60%、危险 30%；DeepSeek 余额警告 10、危险 3）。字段：`apiQuotaWarningPercent` (1...100, 默认 60)、`apiQuotaCriticalPercent` (1...100, 默认 30)、`deepseekBalanceWarning` (0..., 默认 10)、`deepseekBalanceCritical` (0..., 默认 3)。始终自动约束 `critical <= warning`。控制状态栏健康圆点、双环色段、卡片头部及 Edge Dock 呼吸环的红黄告警分档。 |
| `periodicFullEveryN` | global | 次要信息频率相对 Provider 刷新间隔的倍率（Int，范围 1...30，默认 20）。沿用历史配置键；每 N 拍常规刷新有一次全量（`.full`），1 倍时每拍都抓取次要信息。设置页「常规」Tab 通过倍数下拉框配置，预计周期见各 Provider 设置。受影响范围详见下文。 |
| `providers.<id>.mergeOpencodeUsage` | removed | 历史 OpenCode 合并开关；解码忽略、保存清理，不再影响用量归因。 |

`ProviderConfig.encode(to:)` omits nil optional fields, so saved config only includes relevant keys. `ConfigStore.applyAndSave()` writes pretty-printed, sorted-key JSON and reapplies `0600`.
旧版本残留的 provider 级键（如 GLM 曾有的 `peakStartHour` / `peakEndHour` / `peakWeekdaysOnly`——GLM 高峰窗口已固定为官方口径，DeepSeek 峰谷键当年同理）由 `JSONDecoder` **静默忽略**：解码端只认上表列出的键，残留既不报错、也不参与任何判定，下次在设置页保存时自然消失。
Unknown or incorrectly typed `statusBarIconStyle` /
`statusBarHealthDotEnabled` values fall back
to their defaults; cosmetic config errors do not trigger recovery of the provider settings.

### 次要信息频率（`periodicFullEveryN`）及其影响范围

全局配置 `periodicFullEveryN`（默认 20，范围 1...30，在设置页「常规」Tab 的「默认刷新频率」下方配置）控制次要信息刷新周期。主额度与余额使用 `effectiveRefreshInterval(for:)`：有 Provider 独立间隔时使用该值，否则继承默认刷新频率。次要信息周期为该有效间隔的 N 倍，预计值不含网络请求与本地 reconcile 耗时。历史数值保留并归一化至 1...30，但周期含义从 N 次后台后再全量（N+1 拍）改为 N 拍；例如主频率 180s、配置 2，预计周期由 9 分钟改为 6 分钟。

**受其影响的完整范围包括**：
1. **调度器全量刷新循环**（`ProviderRefreshScheduler`）：
   每个已启用的 Provider 首拍 `.full`，随后 N-1 拍 `.background` 再一次 `.full`；N=1 时每拍都是 `.full`。若 Provider 有效间隔为 `interval`，则全量模式触发周期约为 `N × interval`（例如默认 300s × 20 ≈ 100 分钟）。配置变更时调度器动态更新生效。调度器直接注入的 0 仅供内部兼容（禁用周期 full），不属于用户配置范围。
2. **Codex / ChatGPT 重置次数（Rate-limit Reset Credits）抓取与过期判定**：
   - 抓取时机：Codex 仅在 `.full` 模式下向 `chatgpt.com/backend-api/wham/rate-limit-reset-credits` 请求重置次数，`.background` 模式跳过并保持原值；
   - 陈旧度判定：reset-credits 在卡片上标记为「可能过期」的时间阈值是 `max(3 × (periodicFullEveryN × refreshInterval), 15 min)`（默认约 5 小时），`periodicFullEveryN` 决定了该数据容许未更新的有效新鲜度窗口。
3. **GLM Coding Plan 额度重置卡（Reset Cards）查询**：
   - ZCode `coding-plan/reset/status` 按次要信息频率，仅在 `.full` 模式下发起网络查询，`.background` 模式跳过并由 `GlmFillingMissingMerger` 从上一次成功快照继承；因此重置卡的实际抓取周期直接由 `periodicFullEveryN` 决定。
4. **GLM Coding Plan 运营活动（Marketing Touch）轮询**：
   - 营销触达接口（`marketing/touch`）仅在开启通知且模式为 `.full` 时发起轮询，未配置通知时完全不发起请求；其实际轮询频率同样由 `periodicFullEveryN` 约束。1 小时防抖只限制通知发送，不限制接口请求。
5. **独立账号、套餐与组织信息查询**：
   - Antigravity 的 `GetUserStatus`（账号 / 套餐）与 `GetLoadCodeAssist`（套餐兜底）仅在 `.full` 模式请求；`.background` 只请求 `RetrieveUserQuotaSummary`，保留上次账号与套餐显示。
   - Codex Admin API 的 `/v1/organization/costs` 金额查询仍每拍执行；仅在 `.full` 且 costs 缺少组织名称时请求 `/v1/me`。后台新金额缺组织名时仅继承旧组织名，金额、账期与新鲜度均采用新结果。

接口按数据职责分频：额度、余额、金额查询走 Provider 主频率；其余独立元数据、重置卡和活动查询走次要信息频率。Codex / GLM / MiniMax / Antigravity 主额度、DeepSeek 余额、启用后的 Codex Admin API 赠金以及凭证模式的 GLM 活动套餐余额均每拍获取。GLM `data.level`、costs 附带组织名等同一主响应的元数据随主响应更新；Codex 邮箱与套餐名来自构建鉴权头所需的本地 `auth.json` / JWT，没有独立网络查询。本地用量在 Provider 批次结算后独立 reconcile，高峰提示与倒计时按本地展示时钟计算。启动首刷与手动额度刷新会同时抓取主信息与次要信息。

OpenCode and DSH are shared local Clients rather than menu-bar quota Providers. Their
raw multi-provider slices are surfaced in the new "客户端" tab instead of a dedicated
diagnostic pane; card display uses one provider-neutral aggregate token projection.
Antigravity is a special quota owner: its Gemini / Claude / GPT model usage remains
attached to the Antigravity quota scope.

Display ordering is intentionally scoped. Client tabs, Settings Provider tabs, and
Provider rows inside a Client tab are always sorted by their user-facing display name.
Only the main menu Provider cards are user-configurable through `providerCardOrder`;
the Settings window exposes up/down controls for this list. The ordering helper uses
stable IDs, ignores removed or duplicated entries, and appends newly registered
Providers using the default alphabetical order.

Settings > Clients uses horizontally scrollable client tabs sorted by display name
(Agy, Antigravity, Codex, DSH, MiniMax Code, OpenCode, ZCode). Each tab only renders quota
providers with observed local token activity. Provider rows are collapsed by default;
expanding one opens the shared seven-day token chart. It uses the same seven local
calendar days as the provider chart: the extra retained samples
for quota-window calculations must not add an eighth day or an out-of-window model
group to the client view. Group totals and price estimates use this same window.
The daily table keeps the columns `R/T → Input → Cache → Output → Reason → 价值`; the value column is shown
when the client scanner has per-call model samples. Below the chart, aggregate
tokens, the Input/Cache/Output/Reason breakdown, cache hit rate, and the seven-day
estimated public-API value remain visible. Values are displayed to two decimal
places. If a sample has no model name or no catalog entry, the client page shows
the unpriced model and its token amount instead of hiding the impact.
The estimate uses recognized model names and the published currency for that
provider; unknown models are explicitly marked as unpriced rather than assigned a
fallback price (zhipu/GLM is the one deliberate exception: its catalog always falls
back to GLM-5.3-Flash pricing). The OpenAI/Codex catalog recognizes GPT-5.5, GPT-5.6 Sol/Terra/Luna,
and GPT-6 Astra/Sol/Luna plus GPT-6.1 Sol/Terra by exact (lowercased) name match; legacy GPT-4, o1, o3, and generic
GPT-5 names remain unpriced. Antigravity's
independent GPT pricing rules are not affected. All price data lives in the bundled
`Sources/LLM-monitor/Resources/ModelPricing.json`, which `ModelPricingCatalog` loads
at startup (entries evaluated in array order, first hit wins; parse failures crash
loudly because the file is a developer-controlled, test-guarded resource). The
catalog records its update date in
`ModelPricingCatalog.lastUpdated` (currently `2026-10-27`, read from the JSON). Codex local events keep
the model from `turn_context` so GPT-5.6 / GPT-6 variants can be priced separately.

The main provider card footer also shows today's token total, cache hit rate, and
value when local model samples are available.

### 首份 config.json 模板的语义

`ConfigStore.writeTemplate(to:)` 只写可配置字段，不写 Harness 归因开关。`AppConfig.clientBindings` 始终提供内置自动路由；历史 `clientBindings` 与 `mergeOpencodeUsage` 即使为 false 或类型错误，也不会影响配置加载和真实用量统计，下一次保存自然移除。Provider 自身的 `enabled` 仍决定其额度卡和相应扫描消费者是否启用。

## Runtime Files

| File | Purpose |
|---|---|
| `~/Library/Application Support/LLM-monitor/config.json` | User-editable config |
| `~/Library/Application Support/LLM-monitor/.deviceId` | 本机 Fleet Sync UUID 身份文件；首次启用联动且文件不存在时创建。复制 `config.json` 时不要复制此文件。旧 `sync.nodeID` 不迁移。 |
| `~/Library/Application Support/LLM-monitor/holidays-cache.json` | 法定节假日数据源缓存（与打包资源同 schema：source / fetchedAt / holidays）。取数成功后经 `FileManagerBox.writePrivate` 回写（文件 0600 / 目录 0700）；缺失 / 损坏 / bundledOnly 模式时回落内置快照 |
| `~/Library/Application Support/LLM-monitor/notification-state.json` | 通知触发器基线（每次成功刷新回写，供边沿检测跨重启连续） |
| `~/Library/Application Support/LLM-monitor/log.txt` | Rotated runtime log (5 MB 上限 rotate, 保留 active + .1 + .2 共 3 份)；测试进程（XCTest）自动改写到 `NSTemporaryDirectory()/LLM-monitor-tests/log.txt`（裸 `swift test` 不再污染真实日志），`LLM_MONITOR_LOG_PATH` 显式覆盖最优先 |

The footer has buttons to open the config file and reveal the log file in Finder.

## Build And Packaging

Development run:

```bash
swift build
./.build/debug/LLM-monitor
```

Build an app bundle:

```bash
./scripts/build-app.sh [version] [build-number]
```

Package a DMG after building the app:

```bash
./scripts/build-dmg.sh
```

需要 notarization 时，先用 `xcrun notarytool store-credentials` 保存凭据，再显式启用：

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARIZE=1 NOTARY_PROFILE="llm-monitor" ./scripts/build-dmg.sh
```

脚本会签名 DMG，等待 Apple 审核结果、staple ticket 并执行 `stapler validate`；普通本地构建默认不签名 DMG，也不访问 notarization 服务。

`build-app.sh` compiles an arm64-only release binary (`swift build -c release --arch arm64`),
then asks SwiftPM where the products actually landed
(`swift build -c release --arch arm64 --show-bin-path`, e.g. `.build/out/Products/Release`) instead of
guessing a historical product path — the real directory moves with toolchain / build system, and a
guessed path silently repacks a stale binary into a freshly-timestamped `.app`. A `lipo -archs` gate
then rejects anything that is not arm64-only, creates `build/LLM-monitor.app`, writes
`Info.plist`, sets `LSUIElement=true`, and ad-hoc signs the app.

Fleet 局域网访问声明同样由此脚本写入 `Info.plist`：
`NSLocalNetworkUsageDescription` 说明连接局域网主节点以同步用量和额度的用途；
`NSAppTransportSecurity.NSAllowsLocalNetworking=true` 允许局域网 HTTP（IP / 本地名称），
不设置全局 `NSAllowsArbitraryLoads`。这些是应用包配置，修改后须重新打包安装；
`swift test` 的裸可执行文件回环测试不能代替打包应用的 ATS / 本地网络授权验证。

### App icon packaging（双路线设计，已裁定勿再翻转）

`build-app.sh` 按固定优先级选择图标路线（`scripts/build-app.sh` 的 `[3/4]` 之前步骤）：

1. **Icon Composer 路线（主路线）**：仓库存在 `images/LLMMenu.icon` 工程源时，用
   `xcrun actool` 编译出 `Assets.car` + `LLMMenu.icns` 放入 `Contents/Resources/`，
   `Info.plist` 写 `CFBundleIconFile=LLMMenu` 与 `CFBundleIconName=LLMMenu`。
2. **静态回退路线**：没有 `.icon` 目录时，复制 `Sources/LLM-monitor/Resources/AppIcon.icns`，
   `CFBundleIconFile=AppIcon`。

**职责划分（这是设计意图，不是缺陷）**：

- `Assets.car` 是新版系统（支持 Icon Composer layered icon 的 macOS）的**主要图标方案**，
  提供分层/自适应渲染。
- `.icns` **只为兼容旧系统而存在**（旧系统不读 `Assets.car`，经 `CFBundleIconFile` 回退）。
  icns 的存在不代表主方案被降级；同理，不要以"icns 才是官方图标"为由移除 car 路线。
- 静态 `AppIcon.icns` 分辨率覆盖是完整的：经 `iconutil -c iconset` 反推核实，内含
  `icon_256x256@2x.png`（512px）与 `icon_512x512@2x.png`（1024px）表示，旧系统大尺寸
  场景（Dock 放大 / Finder 大图标 / DMG 展示）不会拿到低清位图。

**图标资产同步（单一入口，不再手工 cp / 手工跑 generate-icns.sh）**：源资产为
`Assets/icon-master.png` 与 `images/llm-quota-730-2-dark.svg`；SwiftPM `.copy` 打包
副本（`Sources/LLM-monitor/Resources/IconPreview/` 下两文件，结构性无法消除）与
回退 `AppIcon.icns` 统一由 `scripts/sync-icon-assets.sh` 同步：cp 两份副本、调用
`generate-icns.sh` 重生成 icns、写 sidecar `Assets/AppIcon.icns.source.sha256`
（sha256sum 兼容格式，记录 icns 由哪个版本的 master 生成；sidecar 哈希 == 当前
master 哈希即 icns 新鲜度的确定性判据，不用 mtime）。`build-app.sh` 在版本号解析
后调用 `sync-icon-assets.sh --check` 做构建前置校验（只校验不重生成——release 必
须从已提交状态构建，不能在构建中悄悄改二进制）；副本一致性另由
`Tests/LLMMonitorTests/IconAssetSyncTests.swift` 钉住。脚本覆盖范围之外的手工步骤：
Icon Composer 里更新 `images/LLMMenu.icon` 工程；菜单栏「App 图标」直接用这份
设计稿（`llm-quota-730-2-dark.svg`），改图即改图标，无需再改绘制代码；spec 文档同步。

**历史分歧备注**：1.6.0 前夕 `478f322` 曾以"打包产物异常"为由移除 Icon Composer 路线，
`0f1a7b8` 又将其恢复。本节即为最终裁定：**双路线并存是既定设计**，两条路线的产物各有
职责、互不替代。今后改动图标打包方案前，先修订本节并说明理由，不要再单方面翻转。

### 发布前检查清单

`scripts/build-release.sh` 的门禁只覆盖**版本号一致性**（工作区干净、`VERSION`、
CHANGELOG 最新条目、两份 README 的「当前版本」/DMG 名/build-release 示例、
`docs/releases/<version>.md` 存在）。**它拦不住语义漂移**——文档里某段功能描述与本版
实际行为不符时，版本号照样全绿，构建照发。因此下面几项是**人工检查**，不能指望脚本：

1. **用户文档核对（本清单的必做项）**：逐条核对本版改动涉及的功能描述，在
   `docs/help.zh-CN.md`、`docs/help.en.md`、`README.md`、`README.en.md` 中是否与当前行为一致——
   尤其是被改动过默认值、时区口径、可配置项、路径、权限的那几处。写改动的同一轮就把
   这几份文档一起改掉，不要留到发版前。
2. **spec 同步**：功能、逻辑、字段层面的改动必须在同一次提交里修订对应 spec 小节
   （见仓库 AGENTS.md 的 Spec 优先规则），spec 过期比用户文档过期更难被发现。
3. **发布说明与 CHANGELOG 自洽**：`docs/releases/<version>.md` 与 `CHANGELOG.md` 同版本条目
   的行为描述不得互相矛盾，也不得一边有、一边漏（本仓库出现过 1.23.0 release 文档漏写
   `Changed` 两条、而 1.23.1 又回头链接它的情形）。
4. **spec 基线行**：spec 各文件末尾的「核对基线」行随本次 commit 更新到实际 commit。

反面教材（真实事故）：1.23.2 把 GLM 高峰窗口去配置化、固定为北京时间，设置页与 `docs/help.*`
的旧文案「按本机时区计算、可在设置中调整」直到发版前才发现，只因 `build-release.sh` 的
版本门禁全绿而放行。**功能口径变了，用户文档必须同轮改**。

> 核对基线：2026-11-03 · 代码 d07fa47
