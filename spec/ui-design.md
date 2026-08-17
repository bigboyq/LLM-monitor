# UI Design Spec

This spec documents the UI that is currently implemented in `Sources/LLM-monitor/Views/`.

## Principles

- **Display-first** — the compact menu focuses on status; configuration lives in a separate native Settings window.
- **Locally controlled changes** — Settings edits supported fields, while users can still edit `config.json` directly.
- **Fast scanning** — each provider card emphasizes reset time, remaining percent, and failure state.
- **Progressive detail** — default rows stay compact; hover reveals more detail in floating panels.
- **Provider isolation** — every provider is shown as a separate card, even when disabled or unconfigured.
- **System-native** — SwiftUI controls, SF Symbols, system colors, and system light/dark mode.

## Menu Bar Item

Current implementation:

`MenuBarLabel` (defined in `Sources/LLM-monitor/Views/MenuBarLabel.swift`) renders a fixed `22x22pt` canvas. The configured symbol is drawn in a `20x20pt` area and dynamically reflects overall provider health and background refreshing status.
`AppState` publishes a stable one-minute clock value, so GLM/DeepSeek peak-window
boundaries update even when no provider publishes a fresh network result. The clock is
kept outside the `MenuBarExtra` label because embedding `TimelineView` there can trigger
a status-item redraw loop on some macOS versions.

Icon Styles (`statusBarIconStyle`):
- `chartBar` (`chart.bar.fill` - default)
- `sparkles` (`sparkles`)
- `brain` (`brain.head.profile`)
- `cpu` (`cpu.fill`)

The base icon keeps the standard macOS foreground appearance. A 6 pt status dot is
drawn at the lower-right when `statusBarHealthDotEnabled` is enabled (the default): green
for healthy, orange for warning, and red for critical. The legacy
`statusBarIndicatorMode` configuration field is still decoded for compatibility but no
longer changes rendering. Unknown or type-mismatched icon values in a hand-edited config
fall back to the default without discarding the provider configuration.

Health State Mapping:

| Health / State | Main Icon | Status Dot |
|---|---|---|
| Refreshing | `arrow.triangle.2.circlepath` | None |
| Healthy (`.healthy`) | Configured theme icon | Green, 6 pt |
| Warning (`.warning`) | Configured theme icon | Orange, 6 pt |
| Critical (`.critical`) | Configured theme icon | Red, 6 pt |
| Unconfigured (`nil`) | Configured theme icon | None |

## Window Structure

`LLMMonitorApp` uses `MenuBarExtra` with `.menuBarExtraStyle(.window)`.

Runtime behavior:

- menu window closes when it loses focus
- menu window also closes 30 seconds after the mouse leaves it
- hover details are shown in a separate floating `NSPanel`
- Antigravity process availability is discovered asynchronously and cached, so opening the menu does not synchronously run process inspection.

`MenuContentView` layout:

```text
width: 360pt
height: content-driven, fixedSize(vertical: true)

+------------------------------------------------+
| chart.bar.xaxis  LLM Monitor              ↻    |
+------------------------------------------------+
|                                                |
| provider card                                  |
| provider card                                  |
| ...                                            |
|                                                |
+------------------------------------------------+
| 自启 ✓|✗   更新于 HH:mm / 就绪  设置 日志 退出 |
+------------------------------------------------+
```

The provider area scrolls when needed. There is currently no `ScrollView.maxHeight`
cap, so a very long provider list could push the menu off-screen; this is documented
in `spec/overview.md` under "Current Design Boundaries".

The 开机自启动 toggle was moved into the Settings panel in Round 5; the menu footer
shows its status only (`自启 ✓` / `自启 ✗`).

## Settings Window

The native Settings window has a 220pt sidebar and a scrollable detail pane. Its minimum
size is `720x480pt`, with an ideal size of `760x520pt`. General, provider, and OpenCode
pages share the same visual hierarchy and reusable section components.

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

## Header

Implemented in `MenuContentView.headerBar`.

| Element | Current behavior |
|---|---|
| Leading icon | `chart.bar.xaxis`, 13pt semibold, secondary |
| Title | `LLM Monitor`, 13pt semibold |
| Refresh control | Plain button with `arrow.clockwise`, tooltip `立即刷新全部` |
| Spinner | Shows while at least one provider request is in flight; the refresh button is replaced to prevent accidental duplicate requests |

Clicking refresh runs:

```swift
Task { await state.refreshAll() }
```

## Content

If `state.statuses` is empty:

- text: `没有注册 provider`
- link-style button: `打开配置文件`

Otherwise:

- `LazyVStack(spacing: 14)`
- horizontal padding 12pt
- vertical padding 8pt
- one `ProviderCardView` per status

Each card has a context menu:

| Menu item | Action |
|---|---|
| `立即刷新` | `state.refreshOne(providerID:)` |
| `打开配置文件…` | `state.openConfigFile()` |

When the menu appears, `MenuContentView.onAppear` logs all statuses. If any provider is `.ready`, it triggers `state.refreshAll()`.

`MenuWindowAutoCloseBridge` attaches native tracking and notification observers so the menu can auto-close on focus loss or delayed mouse exit.

## Launch At Login (Settings Window)

The launch-at-login control lives in the Settings window. The menu footer only
shows the current status and does not contain the toggle.

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
- if macOS requires approval, finish it in System Settings

## Footer

Implemented in `MenuContentView.footerBar`.

Left status text:

| State | Text |
|---|---|
| `lastRefreshAt != nil` | `更新于 <HH:mm or MM-dd HH:mm>` |
| `nextRefreshAt != nil` | `下次 <HH:mm or MM-dd HH:mm>` |
| otherwise | `就绪` |

`nextRefreshAt` is the earliest next time among enabled providers' independent timers. After
the first request completes, the footer therefore shows a useful next-refresh time even when
providers use different intervals.

Right actions:

| Button | Icon | Action |
|---|---|---|
| `设置` | `gearshape` | open the graphical Settings window |
| `日志` | `doc.text.magnifyingglass` | reveal `log.txt` in Finder |
| `退出` | `xmark.circle` | `NSApp.terminate(nil)` |

Current styling:

- footer status uses 9pt medium text with reduced secondary opacity
- footer actions use lightweight, keyboard-accessible plain buttons instead of gesture-only labels
- separators are 1pt low-contrast vertical rules

## Provider Card

`ProviderCardView` 是 thin coordinator，额度行、浮层、图表和账号详情按职责分文件维护：
- `QuotaViews.swift` — 所有 quota 行 / 进度条 / `EquivalentQuotaAllocation`
- `HoverPanel.swift` (306 行) — `HoverInfoRow` / `HoverPanelController` / 浮层管理
- `TokenChart.swift` (40 行) — 7-day 柱图基础组件
- `AntigravityAccountView.swift` (52 行) — Antigravity 账号 hover 详情

具体视觉结构由 `QuotaViews.swift` 定义。

Visual structure:

```text
+-----------------------------------------------+
| accent stripe | status dot  icon  display name |
|               |                                |
|               | state-specific content         |
+-----------------------------------------------+
```

Card styling:

| Property | Value |
|---|---|
| Background | `Color.primary.opacity(0.04)` |
| Border | accent color at 25% opacity, 1pt |
| Corner radius | 10pt continuous |
| Left stripe | 3pt wide rounded rectangle |
| Inner padding | 12pt |

Accent color mapping:

| Accent | Color |
|---|---|
| `minimax` | purple |
| `chatgpt` | green |
| `antigravity` | blue |
| `glm` | blue |
| `custom` | gray |
| `deepseek` | cyan |

Row-level tint rules:

- minimax rows use a magenta brand tint
- ChatGPT rows use a green brand tint
- Antigravity uses blue for `Gemini Models`
- Antigravity uses orange for `Claude and GPT models`

## Card Header

| Element | Current behavior |
|---|---|
| Status dot | `StatusIndicator(level: status.healthLevel)` |
| Provider icon | bundled brand asset in an `18x18pt` frame; OpenAI follows the system foreground color and missing assets use a recognizable SF Symbol fallback |
| Display name | 14pt bold |
| Plan tag | shown when a fetched provider supplies a plan label (for example, ChatGPT plan type) |
| State tag | compact `未启用` / `待更新` / `已更新` / `需重试` label; a spinner replaces it while loading |
| ChatGPT title hover | When seven-day local statistics are available, hovering the header displays seven calendar-day groups. Each group contains Input/Cached and Output/Reason stacked bars plus the exact compact values. |

`StatusIndicator` uses:

| Health | Dot color |
|---|---|
| healthy | green |
| warning | orange |
| critical | red |

`.notConfigured`、`.ready`、首次 `.loading` 和没有成功数据的 `.failed` 都返回 `nil` 健康度，因此显示灰点。

Bundled brand assets are used consistently in provider card headers and Settings navigation.
They cover Minimax, OpenAI, Antigravity, GLM, and DeepSeek; OpenCode has separate light
and dark assets because it is a shared local data source rather than a provider card.

## Card States

### Not Configured

Shown for missing config blocks, disabled providers, missing API keys, or missing external auth.

```text
doc.badge.gearshape
<reason>
编辑 config.json 启用
```

Reasons currently produced by `AppState`:

| Reason | Cause |
|---|---|
| `未在 config.json 中配置` | provider block missing |
| `已在 config.json 中禁用` | `enabled == false` |
| `API Key 未填写` | API-key provider has empty/template key |
| `外部 auth 缺失：~/.codex/auth.json` | external-auth provider probe failed |
| `请先启动 Antigravity 并完成登录` | Antigravity IDE / agy CLI 进程未发现或未监听本地端口 |

### Ready

Text:

```text
准备就绪…
```

This is a transient state. Opening the menu triggers `refreshAll()` if any provider is ready.

### Loading

If `state.lastSuccess` exists, the card shows the previous `QuotaSummary` at 50% opacity.

If not, it shows:

```text
正在获取…
```

### OK

Shows `QuotaSummary(info:)`.

## Hover Panels

Hover details are implemented as a separate floating `NSPanel`, not a SwiftUI overlay clipped by the menu window.

Current behavior:

- show after 150ms hover delay
- anchor to mouse position
- keep a 6px cursor gap
- prefer mouse as top-left
- if the right side does not fit, flip to mouse-as-top-right
- if the bottom does not fit, clamp to the screen visible frame
- attach to the menu window via parent-child relationship

This is currently used for:

- ChatGPT Plan `Last Prompt`
- ChatGPT Plan 合并的 `5h / 周` 本地用量
- reset credits detail

## Provider-Specific Card Details

### minimax

- 大部分模型（`general` / `image` / `speech` / `music` / `tts` 等）把 5h 和周额度合成一条。标题右侧显示 `5h × 10 = 周`，周进度条按 10 个等价额度分段；hover 展开两个窗口的百分比与 reset 时间。
- **`video` 模型走日窗口**：标题右侧显示 `日 × 7 = 周`，周进度条按 7 个等价额度分段（1 天 ≈ 1/7 周）。原因：minimax video 实际是日配额而不是 5h 配额，按 5h × 10 分段会误导。label 由 `QuotaSummary.primaryWindowLabel` 按 model 名判断。

### ChatGPT Plan

- The `ChatGPT Plan` row hovers to a `Last Prompt` summary.
- 同时有 5h 和周额度时合并为一条，标题右侧显示 `5h × 6 = 周`；hover 先显示短周期的本地 usage，横线分隔后显示周 usage。接口只返回一个窗口时不显示倍率或虚构的第二窗口。
- The reset-credit row is separated by a divider and hovers to per-credit expiry details.

### Antigravity

- 卡片标题 = `Google Antigravity`（provider 名），右边的 pill = 套餐名（`planLabel` 去掉 `Google ` / `Antigravity ` 前缀，让 `Google AI Pro` → `AI Pro` 跟 `Team` 一样短）。
  这与 `ChatGPT Plan + Team` 的视觉节奏完全一致：provider 名 + 套餐 pill，互补不重叠。
  没有套餐时 pill 自动隐藏。
- 卡片标题整行 hover 展开账号详情：登录邮箱（来自 `GetUserStatus`，可复制）+ 套餐名 + 数据来源说明。
  邮箱缺失时显示"未拿到账号邮箱（首次刷新后会显示）"提示，不留空 cell。
- `Gemini Models` and `Claude and GPT models` are shown as separate model groups inside one provider card.
- 两组都把 5h / 周收为一条：Gemini 使用 `5h × 6 = 周` 分段，Claude and GPT 使用 `5h × 3 = 周` 分段。
- The countdown text uses compact formatting such as `3小时41分后`.
- The countdown follows the model tint unless quota is low enough to trigger warning or critical colors.

### GLM Coding Plan

- 卡片标题 = `GLM Coding Plan`（provider 名），右边的 pill = 套餐档位（`data.level` 首字母大写：`lite` → `Lite` / `Pro` / `Max`），跟 ChatGPT 的 `Team` / Antigravity 的 `AI Pro` 完全对称。
- 单条 `GLM-5.2` 模型行：智谱 Coding Plan 的 5h + 周积分是套餐共享池，合成一条展示，标题右侧显示 `5h × 5 = 周`（周积分 = 5 × 5h 积分：Lite 2000/10000、Pro 12000/60000、Max 28000/140000）。
- 数据来源：远程 `GET open.bigmodel.cn/api/monitor/usage/quota/limit`，Coding Plan Key 作裸 token 放 `Authorization`。鉴权失败（HTTP 200 + `code:1000`）在 parse 阶段捕获并映射成 401 语义。
- **高峰期提示**：额度行下方一行，纯本地时区计算（与 API 无关）。颜色分 3 档：高峰期 🔥 红色 `高峰期 · 还剩 X`；非高峰期距高峰 < 1 小时 ❄️ 橙色、≥ 1 小时 ❄️ 绿色 `距高峰期 X · 非高峰 5 折`。默认 Mon–Fri 14–18（官方规则：高峰全价、非高峰 50% 折），窗口可在设置面板自定义。`TimelineView(.periodic(by: 60))` 让倒计时在菜单打开时每分钟刷新。
- **OpenCode 数据合并**：`zhipuai-coding-plan` 绑定默认开启（`clientBindings[]`）。卡片底部展示 native ZCode 与 OpenCode 合并后的今日与最近 7 天 Input / Cache / Output / Reason 以及 R/T；绑定关闭后只显示 native ZCode local Scanner 数据。设置页没有该开关，调整方式见下节。

### OpenCode client bindings（无设置页开关）

The settings panes intentionally expose **no** per-provider OpenCode toggle. Whether
an OpenCode provider slice is merged into a card is owned by `clientBindings[]` in
`config.json` (see the Config Schema section); GLM defaults to enabled, all other
providers to disabled. To change it, edit `config.json` and save — the directory
watcher hot-reloads the config and rebuilds the cards, no app restart needed.

| Binding (`opencode` → quota) | Off | On |
|---|---|---|
| Minimax | native Minimax Scanner only | add `minimax-cn-coding-plan` OpenCode data |
| ChatGPT | native Codex session data only | add OpenCode `openai` data to 5h / weekly summaries and daily chart |
| Antigravity | native conversation Scanner only | add matching OpenCode Antigravity provider data |
| GLM | native ZCode scanner only | add `zhipuai-coding-plan` OpenCode data on top of native ZCode |

The merge itself is provider-neutral: `ProviderStatus.usageProjection` folds every
client contribution into the card; the switch only controls whether the OpenCode
contribution appears. OpenCode rounds are tokenized assistant messages. Turns are
distinct user-prompt parents. The 7-day chart shows R/T alongside Input, Cache,
Output, and Reason.

### Failed

Layout:

```text
exclamationmark.triangle.fill  <error message>
上次成功：<clock>                # only if lastSuccess exists
<previous quota summary>          # 55% opacity
```

The error message is red, 11pt, and limited to 2 lines.

## Quota Summary

`QuotaSummary` contains:

1. One `ModelRow` per `info.models`.
2. A divider between model rows.
3. Optional reset-credit section.

The current UI does not show a large primary remaining-number block. It prioritizes per-window reset timing.

## Combined Quota Row

Implemented in `ModelRow`.

```text
<model display name>                         5h × <N> = 周
5h <NN>%   周 <NN>%   [weekly progress, divided into N equivalent segments]  <weekly reset time>
```

Model name:

- 11pt semibold
- brand tint for the current provider/model group

Quota summary line:

布局从「横向三段」改成「上下两行」：
- **Line 1**：进度条（**占满整行**）
- **Line 2**：`5h X%  周 Y%`（左） + `clock reset-date (suffix)`（右）

| Part | Style |
|---|---|
| Progress bar | **整行宽**（约 312pt，跟随卡片内容宽度），8pt height。The first segment is `min(5h remaining, weekly remaining × N)`；若周额度尚有余量，下一格先显示 `(weekly remaining × N - 5h remaining) mod 1`，再显示整格周额度 |
| Data column | `5h X%  周 Y%` 固定 **160pt** 宽，左对齐（用 `quotaDataColumnWidth` 常量）。固定宽度让后面的 reset time 从同一 x 位置开始，跨行对齐。32pt 的内部 per-percent 框保持 "5h" 和 "周" 列对齐。160pt 来自 Antigravity 行的实际占用测试：reset time 文字 + 紧凑后缀最长约 110pt，加 50pt 留白 |
| Labels (`5h`, `周`) | 10pt semibold, secondary |
| Percent | 10pt semibold monospaced digit，每个用 32pt 固定右对齐宽 |
| Clock icon | `clock.arrow.circlepath`, 10pt semibold |
| Reset time | **从 data column 末尾紧跟其后**（不再用 Spacer 推右），跨行起始 x 一致。取 binding constraint 那一边的 reset：min(5h remaining, weekly remaining × N) 中较小那一边。如果 5h 较小，显示 5h reset；如果 wk × N 较小（5h 还有余量但 wk 撑死了），显示 wk reset——这种场景下 wk reset 才是用户真正等的时间。两边都缺数据时显示 `—`；hover 永远展示两个窗口的完整 reset |
| Reset 剩余时间 | reset date 之后括号内挂一个紧凑倒计时，由 `Formatters.formatResetSuffix` 输出。阶梯压缩：3d+ → `Xd`；1d+ → `XdXh`；5h+ → `Xh`；1h+ → `XhXXm`；否则 `Xm`。边界 inclusive（>=），避免 1d → "24h"、5h → "5h00m" 这种单位丢失 |

**字体统一规则**：
- 标题行（model name / 重置卡数量）：11pt semibold，brand 颜色
- 周倍率 caption：10pt medium monospaced，secondary（之前是 8pt tertiary 太小）
- 数据行（percent / reset time）：10pt semibold

按这样分级，避免字号跳跃（之前 8pt / 10pt / 11pt 混着用）。

The `5h × N = 周` label expresses a provider-specific equivalent quota ratio, not a conversion of elapsed time. If reset time is missing, the line shows `—`.

**Hover tooltip 文案（解释视觉元素）**：

- **周倍率 N 文字**（标题右侧）:
  - `周倍率：5（分段条按 1 段当前 5h + 4 段等价的周额度渲染）` — 让用户理解 N 段不是 5 段 / 6 段 / 10 段的随机数,而是"1 段当前窗口 + (N-1) 段周窗口"的几何关系
- **分段条 hover**（系统 .help()）:
  - `分段条: 第 1 格 = 当前 5h 剩余;后续 N-1 格 = 等价的周额度剩余。顶部 ▼ = 周 reset 进度（0 = 即将过期, 1 = 刚重置）`
  - 5h-only 单窗口不画三角,tooltip 省略三角说明
- **数据行 hover popover**（自定义 HoverInfoRow）:
  - `主行 reset time 取 5h（5h 是 binding constraint,比周额度先耗尽）。顶部红三角 ▼ = 周 reset 进度,仅作时间标记`
  - 跟分段条 tooltip 区分:这里明确说"红三角 = 周 reset 标记,主行 = 当前 binding constraint 的 reset"
  - 周是 binding constraint 时: `主行 reset time 取周额度（5h 还有余量但周额度已先耗尽）。顶部红三角 ▼ = 周 reset 进度,与主行 reset 含义不同`

> 设计原则:把"几何关系"（N 段 = 1 + N-1）、"时间标记 vs binding reset"（红三角 vs 主行）、
> "两个窗口哪个先耗尽"（binding constraint）三类容易混淆的视觉/语义用 tooltip 说清。
> 不增加新 UI 元素,只让用户能 hover 看到文字解释。

## Progress And Health Colors

Progress bar fill (`SegmentedQuotaProgressBar.barColor` and `ModelQuota.colorLevel`):

| Remaining percent | Health Level | Color |
|---|---|---|
| `< 15` | critical | red |
| `< 30` (5h) / `< min(time%, 50)` (weekly) | warning | yellow |
| otherwise | healthy | provider/model tint |

Reset time color (`summaryColor(for:)`):

| Remaining percent | Color |
|---|---|
| `< 15` | red |
| `< 30` (5h) / `< min(time%, 50)` (weekly) | yellow |
| `> 80` | green |
| otherwise | primary |

## Quota Update Notifications

After each successful remote quota request, the app compares the result with that provider's
previous successful snapshot. A macOS notification is sent when an existing model and window
has increased by at least 0.01 percentage points. The first snapshot, a newly appearing model
or window, decreases, and smaller floating-point noise do not notify. Multiple model changes
from one provider refresh are combined into one notification.

At application launch, notification authorization is requested only when the system status is
`.notDetermined`; an existing allow or deny choice is not prompted again. Notifications remain
visible as a banner with sound while the menu app is in the foreground. UserNotifications is
available only from a packaged `.app` with a Bundle Identifier, so raw `swift run` / SwiftPM
executables disable this feature safely.

## Reset Credits

Shown when `info.resetCredits?.shouldDisplay == true`.

Header:

```text
arrow.counterclockwise.circle.fill  <availableCount> 次剩余  / 共 <entries.count> 张
```

Header color:

| Available count | Color |
|---|---|
| `0` | red |
| `1` | orange |
| `>= 2` | green |

Rows are only shown for entries with `expiresAt != nil`.

```text
status dot  MM-dd HH:mm  约 <duration> 后
```

Entry status colors:

| Status | Dot color |
|---|---|
| `available` | green |
| `used` | secondary |
| `expired` | red |
| other | secondary |

The UI intentionally hides reset-credit id, title, description, and grant time.

## Typography

| Element | Font |
|---|---|
| Header title | 13pt semibold |
| Provider title | 14pt bold |
| Provider icon | 14pt semibold |
| Model name | 11pt semibold |
| Reset label | 11pt semibold |
| Reset percent | 11pt medium monospaced digit |
| Reset relative time | 11pt semibold |
| Error message | 11pt |
| Footer text/buttons | 9pt medium |

## Non-Goals

- No additional settings sheet inside the menu panel; provider toggles and API
  key fields belong to the dedicated Settings window.
- No custom visual theme beyond the menu bar icon theme selector.
- No custom font.
- No in-app provider deletion.

## UI Follow-Ups

These are useful future changes if the app grows:

- Add a scrollable max-height content area for many providers.
