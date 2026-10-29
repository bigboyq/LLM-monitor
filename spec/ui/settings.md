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

General contains refresh, launch-at-login, holiday source and About;
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
not a per-field merge. Dirty state covers persisted
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
「认证与刷新」 section (Antigravity is the exception on placement: it has no auth
block, so the row sits in 「刷新频率」 instead). It is a `SettingsControlRow` with a
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

### ChatGPT Provider Pane 与「API 赠金」设置

ChatGPT 设置 pane（`SettingsProviderPanes.swift:chatgptPane`）在基础的 `auth.json 路径` 与刷新频率之外，提供「API 赠金」专用配置节：
- **开关**：「启用 API 赠金监测」（`chatgptAdminCreditsEnabled`）。默认关闭；开启后向下展开选项，关闭时全部选项隐藏。
- **Admin API Key**：`secretField` 掩码输入框（带明文/掩码切换眼标图标），支持 `sk-admin-...` 前缀的官方管理员 Key。
- **赠金额度 ($)**：每月额度上限输入框（`chatgptMonthlyQuotaLimit`，默认 40）。
- 启用赠金监测时，该输入必须为大于 0 的有限数字；空值、非数字、非正数或非有限数值显示行内错误并阻止保存，保留输入草稿。关闭赠金监测时该项隐藏，输入校验不阻止保存。默认 40 仅用于未配置时的初始值。
- **账单日**：`Picker` 下拉框（每月 1 日至 31 日，默认 11 日）。
- **重置时间**：`DatePicker`（时分输入组件，精确至分钟粒度，如 `00:00` 或 `08:00`）。
- API 赠金节 footer 说明首月统计可能存在偏差，后续按完整账期计算；保留现有赠金命名与算法，不做首月校准。
- **草稿与保存**：所有字段绑定 `SettingsView` 草稿状态并参与 `draftFingerprint` 脏检查；保存时写回 `config.providers["codex_chatgpt"]`。

### 客户端 (Clients) 与用量 pane

侧栏的「用量」分节将每个本地客户端（`ClientDescriptor.all`）提升为第一级设置 Tab，
点击后直接由 `clientPane(for:)` 呈现该客户端的详细诊断，包括「已识别的 Provider」
（按公开 API 单价估算的价值、7 天折线柱图与 Token 指标）；同名客户端与 Provider
（如 Antigravity）通过带 `client.` 命名空间前缀的 ID 隔离。

对于向后兼容的聚合入口 `SettingsView.clientsPane` (`SettingsClientsPane.swift`)，
仍保留两层结构：

- A **client switch bar** — `ClientSegmentedControl`，由 `NSSegmentedControl` 构成的水平
  分段切换条，支持横向滚动与 Provider 数量角标。
- A **「已识别的 Provider」 section** — one `DisclosureGroup` per provider that actually
  produced local token activity for the selected client, showing total tokens, cache hit
  rate and the API-price estimate. The list is keyed by `.id(client.id)` so switching
  clients rebuilds the column and the expansion state falls back to the computed default
  (expanded only when the client has exactly one provider) instead of SwiftUI reusing
  the previous client's expansion by position. ZCode 的 GLM 贡献在此按
  `GlmUsageCategory` 拆成多行展示（Coding Plan → Start Plan → 加速卡 → 闲时任务 →
  其他任务，行序 = `allCases` 声明序，空分类不出行；判定与口径见
  `spec/providers/glm.md` §Provider 分类）。

Each expanded provider also uses the shared `SevenDayUsageHistoryView` shown by provider
cards. It plots one selected metric across seven daily slots: total, Rounds, value,
thinking share, output-to-input ratio, hit rate, or speed; total is the default. Missing dates appear as
gaps and today is marked incomplete. Speed is calculated as daily Prompt P50. The selected
metric is persisted independently under `usageHistoryMetric` and is not coupled to the
quota-window Analysis/Usage switch.

The per-provider OpenCode merge switch is **not** in this pane (nor in the provider
panes) — `clientBindings[]` in `config.json` is its only source of truth, so saving the
form never rolls a hand-edited value back. See `spec/ui/menu-and-cards.md`
§Provider-Specific Card Details → *OpenCode client bindings*.

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

### GLM 高峰期提示（只读）与「节假日数据源」

GLM provider pane 的「高峰期提示」段是**只读展示**（与 DeepSeek 同款
`SettingsControlRow` 写法）：值行为 `工作日 14:00–18:00（北京时间 · 法定节假日除外）`，
footer 注明按北京时间计算、官方口径、不可调。曾经的开始/结束小时 Stepper 与
「仅工作日」开关已随 GLM 去配置化删除（`peakStartHour` / `peakEndHour` /
`peakWeekdaysOnly` 键移除，残留键由 `JSONDecoder` 静默忽略，见 `spec/config.md`
§Config Schema）；DeepSeek pane 的 footer 同步补了「法定节假日除外」口径。

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

- text: `没有注册 provider`
- link-style button: `打开配置文件`

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
| Menu-bar icon（右键菜单栏图标） | 刷新 / 打开配置文件 / 退出 | `refreshAll` / `openConfigFile` / terminate——「打开配置文件」已从段头右键移到这里 |

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
- 系统通知声音绑定 `systemNotificationSoundEnabledDraft`，随普通表单保存；缺省保持出声。系统测试使用当前草稿开关，正式通知使用已保存值；Bark 铃声单独配置。
- 字段默认值与逐字段容错见 `spec/notifications.md` §5；JSON 契约见 `spec/config.md` §Config Schema 的 `notify*` 与 `bark` 字段。

> 核对基线：2026-10-29 · 代码 013a82e
> Sync 草稿跨 tab 保留、表单隔离与保存失败提示验证结果见 `spec/sync.md`。
> 2026-10-25 菜单 / 设置自启同步已随 6f11831 入库：相关定向测试 27 例、完整测试 1422 例均 0 失败；测试使用模拟登录项操作，不执行真实注册 / 注销。
