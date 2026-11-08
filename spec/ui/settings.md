# Settings Window — UI Spec

This file is one of the three UI specs split out of `spec/ui-design.md` (now the
index). It documents the native Settings window, the menu chrome around it (header,
content, launch-at-login, footer) and how the quota notifications surface in the UI.

## Settings Window

The native Settings window has a 220pt sidebar and a scrollable detail pane. Its minimum
size is `720x480pt`, with an ideal size of `760x520pt`. General, Interface, Notifications,
Energy, Sync, provider, and client pages share the same visual hierarchy and reusable
section components. The sidebar is structured into three native macOS sections:
- **通用** (`generalTabs`): 常规、界面、通知、节能、多机联动；
- **额度** (`providerTabs`): ChatGPT、Antigravity、GLM、MiniMax、DeepSeek 等注册的 Provider 配额设置页；
- **用量** (`clientTabs`): Codex、Antigravity、Agy、ZCode、OpenCode、DSH、MiniMax Code 等本地客户端（`ClientDescriptor.all`），直接点击展示该客户端已识别的 Provider token 明细、7 天用量历史与估算价值，无需经由二级横向分段控件反复切换。同名条目（如 Antigravity 额度 vs 用量）通过前缀 `client.<id>` 隔离 ID。

General contains refresh, launch-at-login, holiday source, config-directory and About;
Interface contains appearance, status-bar icon, edge dock preview/configuration and menu
Provider order; Notifications contains system authorization, Bark and all windowed-provider
event channels. Provider panes place notification links after authentication/refresh settings;
each link opens Notifications and scrolls to that Provider's channel rules.

Settings layout rules:

- pane headers vertically center a `34x34pt` icon container with the two-line title and subtitle
- settings rows use a left-aligned label and a right-aligned control or value
- boolean settings use native SwiftUI switch toggles with `.controlSize(.small)`
- controls within a section use 16pt vertical spacing; the section card uses 14pt padding
- explanatory copy belongs below the section card as caption-sized footer text
- menu pickers use a fixed trailing-aligned frame where necessary to keep controls in one column

Typography is semantic rather than chosen independently by each pane: 20pt bold for pane
titles, `subheadline` for subtitles and supporting text, `caption` for section titles,
footers, and metadata, `body` for row labels, and `footnote` for inline status messages.

Sync writes through immediately and has its own per-field drafts and save errors
(see [`spec/sync.md`](../sync.md) §10). `SettingsView` owns that controller so switching
tabs preserves failed edits. Outside Sync, the bottom bar shows 「多机联动配置未保存」
and a 「查看」 action that returns to the Sync pane; unrelated general-form save errors
remain visible independently.
Sync-only config changes do not reload the General/provider form or discard its
unsaved edits. Relevant external form changes reload a clean form from the configuration
published by `ConfigStore`, without reading the previous value during `willSet`. If ordinary
form edits are dirty, the window asks whether to reload (discarding those edits) or keep them;
keeping the current form means its values for ordinary settings take precedence at save time;
Sync and dock-position writes remain independent. This is intentionally a whole-form choice,
not a per-field merge. Ordinary settings form state is consolidated into a value-type
`SettingsFormDraft: Equatable`, enabling unified dirty checking via
`draft != baselineDraft || launchAtLoginDraft.hasLocalEdit` (eliminating manual string
fingerprint concatenation). Dirty state covers persisted
ordinary form fields plus a locally changed launch-item draft, while service-driven launch-item
changes rebase the launch-item draft instead of marking the form dirty. Password visibility,
test status, and dock position are presentation/live state and do not count as form edits.
Cancel with dirty ordinary edits confirms discard; immediately saved Sync changes and dock
drag position are not undone by Cancel.
Dock position-only writes compare normalized effective values, so a first write
from an absent dock config to an explicit default payload also preserves form drafts.
The Interface pane's 「恢复默认位置」 action writes the default edge/offset and clears the
screen UUID immediately, using the latest config snapshot while preserving dock mode,
fullscreen behavior, compact size, independent ring colors, and unrelated form drafts.

### Per-provider 「立即刷新」 (single-provider refresh)

Every provider pane (five: minimax, chatgpt, antigravity, glm, deepseek) carries one
small 「立即刷新」 row inside its
「认证与刷新」 section（Antigravity 的认证内容自 2.5.0 起是两枚**真实可交互**的
凭据策略开关——「钥匙串额度兜底」（`accessTokenFallback`，缺省开）与「允许监控
刷新 Token」（`allowTokenRefresh`，2.5.0 语义翻正、缺省开），细节见下节
「Antigravity pane 的凭据策略开关」；独立刷新频率未显式配置时显示专属默认 300s
而非继承全局）. It is a `SettingsControlRow` with a
borderless `arrow.clockwise` button and the tooltip 「立即刷新该 Provider」, built by the
shared `providerRefreshButton(for:)` so the five panes are one line each. The button is
rendered only for a provider that has a registered descriptor — an unregistered kind
has no id to refresh, so there is nothing to route to. The pane's enabled/disabled
toggle does **not** gate it: a disabled provider is exactly the one a user wants to
retry.

It routes to `AppState.refreshOne(providerID:)`, the **same chain** as the menu's
client section header right-click item（「刷新本机 <客户端名>」，见
`spec/ui/menu-and-cards.md` §Section header context menu）: one provider's request,
one provider's schedule re-anchored, every other provider's next tick untouched. On
Antigravity it sits **beside** the local-usage hard rebuild, not instead of it — one
re-fetches quota and re-anchors the schedule, the other force-rescans every local
session; they answer different questions and neither replaces the other.

**The in-flight signal is global, on purpose.** While `AppState.isRefreshJobActive` is
true every pane's button is disabled and swaps its icon for a small `ProgressView`.
There is no per-provider in-flight signal to read, and guessing one would mean
maintaining a second verdict next to the global one; the same flag already gates the
menu's header refresh button and Antigravity's rebuild button, so all three agree.
`SettingsProviderRefreshAction` (a value type mirroring the menu's `RefreshMenuItem`)
holds the routing and the disable decision, because a SwiftUI `Button` has no
addressable seam — the tests pin the action, the view only draws it. The greyed-out
first layer is UX, not correctness: repeated clicks are absorbed by `refreshOne`'s
transaction gate.

### Antigravity pane 的凭据策略开关（2.5.0）

Antigravity 设置 pane（`SettingsProviderPanes.swift:antigravityPane`）的「认证与刷新」
节自 2.5.0 起放两枚**真实可交互**的开关（`SettingsToggleRow` 标准行，绑定
`draft.antigravityAccessTokenFallback` / `draft.antigravityAllowTokenRefresh`；保存时
开启写 nil=缺省、关闭写显式 false，均缺省 **true**）：

- **「钥匙串额度兜底」**（`providers.antigravity.accessTokenFallback`）：控制本地
  language_server 不可用时的 keychain → 远端 Cloud Code 兜底路径。
- **「允许监控刷新 Token」**（`providers.antigravity.allowTokenRefresh`）：控制 token
  过期时是否运行 agy CLI（`agy models`）代理刷新钥匙串凭据（2.4.0–2.4.3 曾恒为关
  且 disabled，2.5.0 语义翻正）。

**启动预检自动 disable（运行时生效，不改用户 json）**：monitor 启动与 config 热重载
各执行一次预检（`AppState.runAntigravityCredentialPreflight`，结果发布在
`state.antigravityCredentialPreflight`），被自动 disable 的开关显示
**off + disabled + 原因文案**（`SettingsControlRow` 内 `Toggle(.constant(false))`
disabled + `SettingsTypography.metadata` secondary 说明文字，沿用 2.4.x 恒为关行的
布局）：

| 预检结论 | UI 表现 | 恢复方式 |
|---|---|---|
| 钥匙串授权被拒（系统授权弹窗被拒/不可读） | ①「钥匙串额度兜底」off + disabled + 「钥匙串访问被拒」 | 授权后手动重开开关或重启 monitor（触发重新预检） |
| agy CLI 未找到（PATH + `~/.local/bin/agy`） | ②「允许监控刷新 Token」off + disabled + 「未找到 agy CLI」 | 安装后手动重开开关或重启 monitor |
| 钥匙串条目不存在（未登录） | **软不可用不 disable**：开关保持可交互，行下追加「未登录 Antigravity（登录后自动恢复兜底路径）」提示 | 登录后自动恢复 |

不做后台自动复活；预检详情与退避契约见
`spec/providers/antigravity.md` § Credential Preflight & Backoff。

### Antigravity pane 的「额度来源」行

Antigravity 设置 pane（`SettingsProviderPanes.swift:antigravityPane`）在「认证与刷新」
节内、两枚凭据策略开关行下方有一条**只读**的「额度来源」行
（`SettingsControlRow` 标准行布局，值文本用 `SettingsTypography.metadata` +
secondary，与开关行的说明文字同款；无任何交互）。2.5.0 起额度有两条路径（本地
language_server 主路径——ls 可用即走、不读钥匙串；本地不可用时钥匙串凭据 → 远端
Cloud Code API，含 agy 刷新后的远端重试），本行回答「当前走的是哪条路」：

- **数据源**：本机 status 最近一次成功刷新打上的
  `QuotaInfo.antigravityQuotaSource`（`AntigravityQuotaSource`，打标与合并语义见
  `spec/providers/antigravity.md` § Remote Quota Path 的「来源标记 + UI 展示」）。
  视图经 `providerID(for: .antigravity)` 查 `state.statuses` 读
  `status.lastSuccess` 的标记（`antigravityQuotaSourceDescription`），不解析状态机。
- **文案**（2.5.0 更新）：`.remoteCloudCode` → 「远端 Cloud Code（钥匙串凭据兜底）」；
  `.localLanguageServer` → 「本地 language_server（本地服务优先）」；标记缺失
  （尚无成功刷新 / `lastSuccess` 为 nil）→ 中性占位「—」。来源标记不跨
  启动持久化（AppState 只持久化刷新时间戳），重启后首拍刷新前显示「—」。
- **刷新时机**：`AntigravityFillingMissingMerger` 在 background 拍保留上次来源
  （与账号/套餐同生命周期）、full 拍采纳本次值，因此本行在 full 周期粒度上稳定；
  设置页「立即刷新」（`.full`）完成后立即反映当次实际路径。

### 常规 pane「刷新频率」节与次要信息频率

常规设置 pane（`SettingsGeneralPane.swift`）在「刷新频率」节提供默认刷新与次要信息周期的集中控制：
- **默认刷新频率**（`refreshIntervalSeconds`）：`Slider` 滑块在 10...3600s（10 秒至 1 小时）连续调节，默认 5 分钟（300s）。各 Provider 未单独指定频率时均沿用此全局间隔。
- **次要信息频率**（`periodicFullEveryN`）：与默认刷新频率使用相同宽度和行距的 `Slider`，范围 1...30、步长 1，左右端标注「1 倍」和「30 倍」，默认 20 倍。下方胶囊显示当前倍数及按默认间隔 × 倍率估算的预计周期；ChatGPT、Antigravity 与启用 GLM ZCode JWT 扩展时的 Provider 设置另显示各自预计周期，优先按独立刷新间隔折算、未设置则继承默认间隔，间隔与运行时一致归一化为 10s...30d。ChatGPT 标注重置卡 / 组织信息，Antigravity 标注账号 / 套餐信息，GLM 标注重置卡 / 活动。
  - 控制 Provider 调度器每 N 拍抓取一次次要信息：N-1 拍后台模式（`.background`）后一次全量模式（`.full`），1 倍时每拍都抓取；
  - 受影响范围包括：Codex 重置次数抓取与陈旧度判定（`max(3 × (N × interval), 15 min)`）、GLM ZCode 额度重置卡抓取、GLM ZCode 运营活动轮询、Antigravity 账号/套餐与 Codex Admin API 组织标题独立查询；
  - 绑定 `draft.periodicFullEveryN`，为默认值 20 时写回 nil，非默认值落盘，配置热重载时调度器动态更新生效。

### ChatGPT Provider Pane 与「API 赠金」设置

ChatGPT 设置 pane（`SettingsProviderPanes.swift:chatgptPane`）在基础的 `auth.json 路径` 与刷新频率之外，提供「API 赠金」专用配置节：
- **开关**：「启用 API 赠金监测」（`chatgptAdminCreditsEnabled`）。默认关闭；开启后向下展开多 Key 管理卡片列表与添加按钮，关闭时全部隐藏。
- **多 Key 管理卡片列表 (`CodexAdminKeyCardView`)**：每个 Key 呈现为一个独立卡片（圆角 8pt，填充背景与边框）：
  - **卡头与删除操作**：卡头左侧显示自定义备注名称（未输入时显示默认占位 `API Key #N`，`SettingsTypography.rowEmphasis`）；右侧在卡片数量大于 1 时显示删除按钮（`canDelete = draft.chatgptAdminKeys.count > 1`，带 `trash` 图标与「删除此 API Key」提示；单 Key 时隐藏删除按钮以防止清空配置）；
  - **Key 名称**：输入框绑定 `keyDraft.label`，占位符为「例如：个人账号、团队项目」；帮助文字说明名称用于区分额度卡片中的各个 API Key，留空时显示 `API Key #N`。沿用 JSON 的 `label` 字段；
  - **Admin API Key**：`keyDraft.apiKey` 输入框，支持明文/密文切换（`isKeyVisible` 切换 `TextField` 与 `SecureField`，带眼睛图标按钮），占位符为 `sk-admin-...`；
  - **赠金额度 ($)**：每月额度上限输入框（`keyDraft.monthlyQuotaLimit`，默认 40）。行内实时校验：当 Key 非空且额度非大于 0 的有限数字时，输入框下方即时呈现红色错误文案「请输入大于 0 的有限数字。」。在表单保存时（`SettingsView.saveAndApply()`）执行强校验拦截，非法时抛出错误阻止保存；
  - **账单日**：`Picker` 下拉框（每月 1 日至 31 日，默认 11 日，绑定 `keyDraft.billingDay`）；
  - **重置时间**：`DatePicker` 时分输入组件（精确至分钟粒度，默认 `08:00`，绑定 `keyDraft.billingTime`）。
- **添加 Key 按钮**：卡片列表下方提供「添加 API Key」操作（`plus.circle.fill` 图标），点击向 `draft.chatgptAdminKeys` 追加新的 `CodexAdminKeyConfigDraft`（新生成 UUID，默认额度 40，账单日 11 日，重置时间 08:00）。
- **双向兼容与数据持久化**：
  - `SettingsFormDraft` 提供 `chatgptAdminApiKey`、`chatgptBillingDay`、`chatgptBillingTime`、`chatgptMonthlyQuotaLimit` 计算属性，双向代理映射至首个 Key（`chatgptAdminKeys.first`）；
  - 保存时，有效非空 Key 列表（`compactMap { $0.toConfig() }`）写入 `ProviderConfig.adminApiKeys` 数组；同时将首个有效 Key 镜像同步至传统标量字段（`chatgpt.adminApiKey` 等），确保旧版本客户端与单 Key 接口完全兼容；
  - 所有卡片字段通过 `CodexAdminKeyConfigDraft: Equatable` 参与 `SettingsFormDraft: Equatable` 统一脏检查与保存流。
- API 赠金节 footer 说明首月统计可能存在偏差，后续按完整账期计算；保留现有赠金命名与算法，不做首月校准。

### 客户端 (Clients) 与用量 pane

侧栏的「用量」分节将每个本地客户端（`ClientDescriptor.all`）提升为第一级设置 Tab，
点击后直接由 `clientPane(for:)` 呈现该客户端的详细诊断，包括「额度池分组」
（按公开 API 单价估算的价值、7 天折线柱图与 Token 指标）；同名客户端与 Provider
（如 Antigravity）通过带 `client.` 命名空间前缀的 ID 隔离。

对于向后兼容的聚合入口 `SettingsView.clientsPane` (`SettingsClientsPane.swift`)，
仍保留两层结构：

- A **client switch bar** — `ClientSegmentedControl`，由 `NSSegmentedControl` 构成的水平
  分段切换条，支持横向滚动与额度池分组数量角标。
- A **「额度池分组」 section** — one `DisclosureGroup` per observed provider/pool
  with local token activity for the selected client, showing total tokens, cache hit
  rate and the API-price estimate. The list is keyed by `.id(client.id)` so switching
  clients rebuilds the column and the expansion state falls back to the computed default
  (expanded only when the client has exactly one provider) instead of SwiftUI reusing
  the previous client's expansion by position. ZCode 的 GLM 贡献在此按
  `GlmUsageCategory` 拆成多行展示（Coding Plan → Start Plan → 加速卡 → 闲时任务 →
  其他任务，行序 = `allCases` 声明序，空分类不出行；判定与口径见
  `spec/harnesses/zcode.md` §Provider 分类）。

Antigravity Provider 的所有 Harness 贡献（Antigravity、Agy、OpenCode）共用额度侧模型池标识，按 Gemini Models → Gemini 4 Argon → Claude and GPT models 拆组；未知模型与日桶中无法由留存样本解释的差额归入「未归属额度池」。同池的 5h / 周窗口只产生一组，按原始模型样本计价后归组，不把池名作为模型定价。日桶四桶合计保持权威值，留存样本不足不把差额分给已知模型。

Each expanded provider also uses the shared `SevenDayUsageHistoryView` shown by provider
cards. It plots one selected metric across seven daily slots: total, Rounds, value,
thinking share, output-to-input ratio, hit rate, or speed; total is the default. Missing dates appear as
gaps and today is marked incomplete. Speed is calculated as daily Prompt P50. The selected
metric is persisted independently under `usageHistoryMetric` and is not coupled to the
quota-window Analysis/Usage switch.

Harness usage attribution is automatic. This pane has no attribution toggles, no binding
draft, and no binding save action. Every supported ledger provider contributes to its mapped
provider card and client diagnostics through the same projection; historical disabled
bindings do not hide real usage. Native frames carry a provider ID, while shared ledgers
use the built-in alias registry. Unknown providers are not guessed from model names.
Disabled providers are still excluded from client diagnostics (`guard status.isEnabled`).
显示条件在 `ClientUsageAggregation.clientProviderUsageByClient(for:)` 分组及窗口裁剪后统一判断：展示日桶中 Token、Rounds、Turns 全为 0 的行不显示，也不计入分组数量；窗口外的历史样本、扫描时间或已登记路由不构成显示依据。今天为 0 但七天内其他日期有用量的分组仍保留；仅有调用次数的记录也保留。

### 界面 pane「外观」节

Interface pane 的「外观」节（`SettingsGeneralPane.swift`）行标签「界面外观」，
**分段 Picker**（`.pickerStyle(.segmented)`），选项即 `AppAppearance.allCases` 的
浅色 / 深色 / 自动（`displayName`），宽度 `SettingsLayout.standardControlWidth`。

语义：

- selection 绑定 `appearanceDraft`，加载自 `config.effectiveAppearance`（缺省 nil → `.auto`）。
- 通过普通表单 `saveAndApply` 保存（「自动」落 nil），取消不保存外观；失败保留草稿并展示错误。
- 应用点在 `AppState.applyAppearance`：写 `NSApp.appearance`。`start()` 在应用入口
  早期执行时 `NSApplication` 可能尚未创建，此时**下一个主循环重试一次**（`NSApp`
  非 nil 守卫，测试进程 NSApp 恒 nil 不会自旋）；`start()` 与每次配置变更都会调用。
- 边界：`MenuBarExtra` 原生呈现（菜单栏图标本身）仍随系统外观，不受此设置控制。

### 界面 pane「状态栏图标」节与指标来源

Interface pane「状态栏图标」节（`SettingsGeneralPane.swift`）提供图标样式与监控目标配置：
- **图标主题 Picker**（`StatusBarIconStyle`）：App 图标、Icon Duo 双环仪表盘、系统符号等样式及实时烘焙预览；
- **指标来源 Picker**（`statusBarPinnedProvider`）：
  - 「全部聚合（非零最小值）」（缺省 / tag `""` / 落盘 `nil`）：综合所有已启用 Provider 计算非零最小值；
  - 窗口 Provider（MiniMax、ChatGPT、Antigravity、GLM 等）：将状态栏 Icon Duo 双环及健康度圆点单选锚定至该 Provider；
  - 与 Provider 卡片标题栏的「小眼睛」按钮双向联动，保存时写回 `config.json` 的 `statusBarPinnedProvider` 字段；
- **状态圆点与三色拾色器**（`statusBarHealthDotEnabled`、`statusBarHealthColors`）。

### GLM API Key、ZCode JWT 扩展与高峰期提示

GLM provider pane（`SettingsProviderPanes.swift:glmPane`）包含必填 API Key 与独立 ZCode 扩展开关：
- **API Key**（`apiKey`，`glmApiKeyField`）：必填 Coding Plan Key（`id.secret`），用于标准 5h/周额度。没有有效非空 Key 时 Provider 未就绪；OAuth 不作为回退。
- **启用 ZCode JWT 扩展**（`zcodeJWTEnabled`，缺省关闭）：开启后显示「ZCode 凭证路径」与营销通知配置，并读取 ZCode JWT。关闭时不读取本地凭证、不请求扩展 API，也不展示既有 package 数据。
- **ZCode 凭证路径**（`authPath`）：扩展开启时可填写目录或 `credentials.json` 文件路径，带「选择…」文件选择按钮和 `~` 路径解析；留空默认读 `~/.zcode/v2`。JWT 存在时查询活动套餐和重置卡；重置卡跟随次要信息频率。JWT 缺失时只跳过扩展，主额度仍可正常刷新。
- **运营活动推送通知**（`notifyCampaign`）：仅扩展开启、读到 JWT、通知渠道开启且为 `.full` 刷新时轮询活动。
- **重置卡 / 活动预计周期**：只显示预计周期胶囊，认证说明和周期行不再重复提示开启通知，通知渠道由相邻配置项选择。
- 新开关显式 true/false 优先；缺失时沿用旧 `effectiveGlmAuthMode` 设置（先取 `glmAuthMode`，再依次取 `parseZcodeCredential` / `parseZcodePlan` / `parseZcodeBalanceLog` 的首个非 nil 值）。设置保存写入新开关并清除历史键。
- **高峰期提示**：GLM 与 DeepSeek 共用 `SettingsView.peakPricingSection(for:)`，只读展示当前 `peakWindow` 的时段定义与高峰倍率；GLM 行标题为「高峰期积分」，DeepSeek 为「高峰期价格」，默认均显示 `2×`（只显示偏离平时的倍率，不再附「平时 1×」后缀，2026-11-07 用户裁定）。时段来自 `PeakWindow.scheduleLabel`，按 `weekdaysOnly` 显示「工作日」或「每天」，工作日附「法定节假日除外」。在 JSON 中修改时段或倍率后展示随配置更新，设置页无编辑控件；GLM footer 明确积分倍率不参与本地名义价值估算。字段契约见 `spec/config.md` §Config Schema。

General pane 的「关于」之前有
「节假日数据源」节（`HolidaySourceSection`，单独 View 以 `@ObservedObject` 观察
`AppState.holidayCalendarService` 的刷新状态与结果文案）：

- **源输入行**：可编辑文本（支持 URL / 本地文件路径），缺省（config 不写
  `holidaySource` 键）展示为上游 chinese-days CDN URL
  （`HolidayCalendar.defaultSourceURL`）。保存走既有 draft/save 事务：与默认 URL
  一致写回 nil（不落键，保持 config.json 干净）、显式空串原样写 `""`
  （= 只用内置快照、不联网）、其余值原样保存。
- **状态行**：`2025–2026 · 抓取于 2026-10-05 · 来源：缓存/内置`
  （`HolidayCalendarService.statusLine` 纯函数）。当前年份未被快照覆盖时另有一行
  **橙色**提示：`节假日表未覆盖 <year>，<year> 年按纯周一–周五判定`
  （`coverageWarning` 纯函数）。
- **「立即更新」按钮** + 进行中（转圈 + 正在更新…）/ 最近一次结果文案：强制取数
  一次，不受新鲜度窗口限制；失败文案橙色，既有数据原样保留。

取数与缓存编排（`Services/HolidayCalendarService.swift`，解析纯函数在
`Models/HolidayCalendar.swift`）：

- 解析链：① 本地缓存 `~/Library/Application Support/LLM-monitor/holidays-cache.json`
  （与打包资源同 schema：source / fetchedAt / holidays）→ ② 内置 bundle 快照
  （缺失/损坏内部退化空表）→ ③ `.empty`。`holidaySource` 为显式空串时跳过缓存
  与取数，直接用内置快照。
- 触发：启动后（App 入口调 `start(source:)`；缓存缺失 / `fetchedAt` 早于 7 天 /
  源变更才真取数）+ config 中 `holidaySource` 变更（`AppState` config 订阅 →
  `handleConfigChange`，源未变 no-op）+ 设置页「立即更新」。取数异步 best-effort，
  不阻塞启动、不崩、失败不清空既有数据。
- 成功后：写缓存（best-effort）→ `HolidayCalendar.applyResolved` 替换 `shared`
  （`status(at:)` 等默认参数在调用时求值，各判定点自然读到新表）→ 经
  `statusDidChange.send()` + 健康边界重排触发一次 UI 刷新（卡片高峰 pill / 额度行
  随之重算）。
- 源格式：仅支持本项目 JSON 快照格式；默认源的上游 chinese-days 格式由 App 内置
  与 `sync-holiday-data.sh` 同款转换（`holidays` ∪ `inLieuDays`、workdays 有意
  丢弃、年份过滤 [当前年-1, …]）。其余格式（如 ICS）给明确失败文案
  「仅支持本项目 JSON 快照格式，可用 scripts/sync-holiday-data.sh 生成」，不猜测
  解析。取数走 `Services/Infra/HTTPClient`（overseas 超时档），本地路径直接读文件。

### 常规 pane「配置文件」节与「打开设置目录」按钮（2.5.1）

常规 pane「关于」之前有「配置文件」节：`SettingsControlRow("设置目录")` 行内一枚
「打开设置目录」按钮（hover 文案「在 Finder 中打开配置目录并选中 config.json」，
行布局沿用「恢复默认位置」式按钮行惯例）。点击经
`SettingsView.openSettingsDirectory()` 把 `ConfigStore.configURL`
（`~/Library/Application Support/LLM-monitor/config.json`，URL 事实源唯一）交给
注入的 reveal 出口 `SettingsView.revealConfigDirectory`——生产默认
`NSWorkspace.activateFileViewerSelecting([url])`（Finder 打开配置目录并选中
config.json），测试注入记录闭包断言参数（`Tests/LLMMonitorTests/SettingsGeneralPaneTests.swift`；
SwiftUI `Button` 无可寻址测试缝，UI 测试基建也没有 NSWorkspace 替身，故执行出口包成闭包）。

同版本（2.5.1）删除旧「用系统默认应用打开 config.json」入口
（`ConfigStore.openInDefaultEditor` / `AppState.openConfigFile`）：右键菜单
「打开配置文件」条目与菜单空态「打开配置文件」按钮一并移除，不做替代入口。

## Header

Implemented in `MenuContentView.headerBar`.

| Element | Current behavior |
|---|---|
| Leading icon | Full app icon (`icon-master.png`, 24×24, original colors; falls back to `chart.bar.xaxis` 13pt semibold secondary if the asset fails to load) |
| Title | `LLM Monitor`, 13pt semibold |
| Sleep-blocker notice | `N 个应用正在阻止休眠`, 10pt medium `Color.secondaryLabel` (fixed NSColor — the glass panel's vibrancy washes out hierarchical `.secondary`, especially in light mode), after the title, rendered only when `sleepHealth.report.offenders` is non-empty; hovering opens the offender list (`SleepOffendersHoverView`, same rows as Settings → Energy check 1), hidden otherwise, hover-only with no click action |
| Scope switcher (conditional) | > 4 options（多机联动启用、节点 choices 非空）时，刷新按钮左侧出现「范围文字 + `ellipsis`」下拉（`FleetScopeSwitcher`，系统 `Menu`：全局 / 本机 / 「节点」分组）；≤ 4 项或未启用联动时标题栏没有 scope 控件——分段形态渲染在内容区「今日」卡上方。几何、截断与菜单项规则见 `spec/ui/menu-and-cards.md` §Scope switcher |
| Refresh control | 页面级唯一刷新按钮；用量重扫本机 LocalUsage，额度刷新 Provider；对应数据时间在按钮左侧。图标在 26pt 点击槽内居中，与 scope 组间距 8pt |
| Spinner | Replaces refresh during a full job, LocalUsage scanning on 用量, or Provider fetching on 额度; retains the last known data timestamp |

Clicking refresh runs:

```swift
// MenuContentView.refreshDisplayedPage：按当前页面选择数据源。
// 用量：await state.triggerLocalUsageRescan()
// 额度：await state.refreshAll()
```

## Content

If `state.statuses` is empty:

- text: `没有注册 provider`（2.5.1 起不再附「打开配置文件」按钮——用系统默认应用打开 config.json 的入口已整体删除，见下文「配置文件」节）

Otherwise:

- `ScrollView(.vertical, showsIndicators: false)` wrapping a **non-lazy** `VStack`
  (`HarnessUsageMenuView.sectionSpacing` = 10pt). Non-lazy on purpose: the content
  height feeds `MenuPanelHeightBridge` to decide the window height, and a lazy
  container only lays out its visible region and would under-report it
- horizontal padding `LayoutMetrics.cardColumnHorizontalPadding` (12pt)
- vertical padding 8pt
- optionally the first-run setup guide (`MenuContentView.shouldShowSetupGuide`: every
  enabled provider is `.notConfigured`)
- `HarnessUsageMenuView`（scope 总览 + client sections）。多机联动启用且 multiNode 时
  内容区顶部还有 scope 控件（≤ 4 项的分段形态在「今日」卡上方）与三 scope 统一总览，
  规则见 `spec/ui/menu-and-cards.md` §Scope switcher 与 §Content structure。
  菜单提供「用量 / 额度」切换；额度页使用 `MenuQuotaOverviewView`，独立于 edge dock。
  旧 provider 兜底条的无宿主实现及专属测试已清理。

The context menus that used to hang off each provider card now hang off narrower
targets:

| Target | Menu item | Action |
|---|---|---|
| Client section header（本机 scope 的 `HarnessSectionView`，及 fleet 全局 / 本机形态的 `FleetClientSectionView`） | `刷新本机 <客户端名>` | `AppState.refreshOne` over the section's provider cards |
| Menu-bar icon（右键菜单栏图标） | 刷新 / 设置 / 退出 | `refreshAll` / 普通 `NSMenuItem` 经注入的 `\.openSettings` 动作（`SettingsOpenerBridge`）打开设置窗口 / terminate——2.5.1 起旧「打开配置文件」条目删除；2.5.2 起弃用 view 宿主 `SettingsLink`（弹出菜单中不渲染） |

When the menu appears, `MenuContentView.onAppear` refreshes the login-item status and
forces a sleep-health probe, and — if **any** provider is `.ready` — triggers
`state.refreshAll()`.

`MenuWindowAutoCloseBridge` attaches native tracking and notification observers so the menu can auto-close on focus loss or 30s of inactivity; it also snaps the window's top edge to `screen.visibleFrame.maxY + 10` (`MenuWindowAlignment.topOffset`), absorbing the system popover's top margin so the panel sits flush with the menu bar.

## Launch At Login (Settings Window)

The Settings window and menu footer share `LoginItemService`. The menu toggle applies
immediately; the Settings toggle remains a draft until 「保存并应用」. Both read the
system login-item state rather than a `config.json` field.

`SettingsLoginItemDraft` tracks the last actual state and the local edit. A real
menu/system state change synchronizes the open Settings toggle; repeated same-state
refreshes preserve an unsaved local edit. Saving unrelated settings uses the live
service value when the toggle has not been edited, even before a pending status
notification arrives. After save, registration failure or rollback, the draft adopts
the final actual state. Pending system approval remains distinct from enabled.

| Element | Current behavior |
|---|---|
| Toggle label | `开机自启动` |
| Backing service | `SMAppService.mainApp` |
| Status hint | Shows whether launch-at-login is enabled, needs approval, or should be enabled only after moving the app to `/Applications` |
| Error display | Inline orange text below the toggle when register/unregister fails |

Expected user flow:

- copy the packaged `.app` to `/Applications`
- open Settings from the menu footer
- enable `开机自启动`
- click 「保存并应用」
- if macOS requires approval, finish it in System Settings

## Footer

Implemented in `MenuContentView.footerBar`.

Page refresh and freshness now appear only in the header: LocalUsage scan time on
用量, Provider successful quota time on 额度. The footer does not repeat request or
next-refresh timestamps; provider scheduling itself remains unchanged.

Right actions:

| Button | Icon | Action |
|---|---|---|
| `自启` | `power` / `power.dotted` | toggle the shared `LoginItemService` immediately; synchronize the open Settings draft to the resulting actual state |
| `设置` | `gearshape` | open the graphical Settings window |
| `节能` / `防休眠` | `powersleep` / `cup.and.saucer.fill` | `state.sleepHealth.setKeepAwake(_:)` — one click, in memory, no `IOPMAssertion` written to disk; the tri-colour health dot turns red while keep-awake is on |
| `日志` | `doc.text.magnifyingglass` | reveal `log.txt` in Finder |
| `退出` | `xmark.circle` | `NSApp.terminate(nil)` |

Current styling:

- footer status uses 9pt medium text with reduced secondary opacity
- footer actions use lightweight, keyboard-accessible plain buttons instead of gesture-only labels
- separators are 1pt low-contrast vertical rules

**All menu hairlines are one component** (`MenuHairline`). Three call sites — the
section header's lower edge, the provider strip's upper edge, and the footer's vertical
separators — used to spell the same line out by hand
(`Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)` /
`frame(width: 1, height: 10)`). They are the same line in two orientations: one 1pt
stroke, one 8% foreground colour, on the same glass. Converged into one view so a
change to weight or colour moves all three at once — leaving one behind puts two
different lines on one panel. The horizontal form sets **no width**: all its call sites
hang it off an `.overlay`, so the width has to come from the container, and hardcoding
it here would decouple the rule from what it is ruling. Spec: thickness 1pt, opacity
0.08, vertical length 10pt; the numbers are pinned by a test so the refactor stays
appearance-neutral.

## Quota Notifications (system + Bark)

本节只管设置页的呈现与入口位置；通知的触发逻辑、事件边沿阈值、渠道行为与防抖的**单一事实源**在 `spec/notifications.md`（§3 事件模型与触发语义 / §4 渠道层 / §5 配置 Schema），本节不复述其规则。

- Notifications pane 集中四个窗口类 provider 的四类事件渠道选择（`不通知` / `系统通知` / `Bark + 系统通知`）。Provider pane 保留跳转入口，不维护第二份通知草稿。
- 同页提供系统权限查询/申请/拒绝后的设置引导/测试，以及 Bark 全局配置：`enabled` / `serverURL` / `deviceKey` / `sound` / `skipWhenAwakeAndUnlocked` / `ttl` / `group`。主动 Bark 测试使用当前草稿且明确绕过正式屏幕跳过策略。
- **告警阈值配置**（`alertThresholdsSection`）：提供 API 配额与 DeepSeek 余额的告警阈值调节控件（余量警告 %、余量危险 %、DeepSeek 余额警告、DeepSeek 余额危险）。各输入项直接绑定 `$draft.alertThresholds`，由 `SettingsFormDraft: Equatable` 统一进行脏检查并保存。
- 系统通知声音绑定 `draft.systemNotificationSoundEnabled`，随普通表单保存；缺省保持出声。系统测试使用当前草稿开关，正式通知使用已保存值；Bark 铃声单独配置。
- 字段默认值与逐字段容错见 `spec/notifications.md` §5；JSON 契约见 `spec/config.md` §Config Schema 的 `notify*` 与 `bark` 字段。

### 设置页滚动位置与排版规范

- **切页滚动复位**：`SettingsView` 的 `detailContent` 在 `SettingsPaneHeader` 挂载 `.id("settings-top")`。普通 Tab 切换统一通过 `proxy.scrollTo("settings-top", anchor: .top)` 归位到顶部，避免继承上一页的滚动偏移；从 Provider 页点击「编辑此 Provider 的通知规则」时保留定向平滑滚动至目标项。
- **历史图表空间适配**：`SevenDayUsageHistoryView` 增加紧凑（`.compact`）与宽松（`.expanded`）两种模式。设置页与独立详情窗口使用 `.expanded`，宽度撑满可用区域（`.frame(maxWidth: .infinity)`），表格字号适度提至 11–11.5pt、列宽与间距自适应拉开；菜单与浮层维持 `.compact`（420pt）。坐标轴与日期标签字体提至 10–11pt、配色提至 `.secondary`。expanded 表格（b9e1000 起）的 R/T 与四个分桶加动态列在 expanded 下改为「`minWidth` 列宽下限 + `maxWidth: .infinity`」弹性填满（下限常量住在 `SevenDayUsageChartMetrics.expanded*`，日期列恒为固定 42pt），compact 仍为 `.frame(width:)` 固定列宽；详情窗口因此能在放大时让表格随窗口一起拉伸。
- **说明文字与行距紧凑化**：边缘状态窗 footer 收敛为 2 句核心操作指引，双环机制与多屏行为放入「了解更多…」popover；ChatGPT API 赠金设置采用独立 `CodexAdminKeyCardView` 模块化卡片（12pt 内边距、低透明度底色与边框描边），对齐常规表单行距。

> 核对基线：2026-11-08 · 代码 4941430
> Sync 草稿跨 tab 保留、表单隔离与保存失败提示验证结果见 `spec/sync.md`。
> 2026-10-25 菜单 / 设置自启同步已随 6f11831 入库：相关定向测试 27 例、完整测试 1422 例均 0 失败；测试使用模拟登录项操作，不执行真实注册 / 注销。
