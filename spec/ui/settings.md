# Settings Window — UI Spec

This file is one of the three UI specs split out of `spec/ui-design.md` (now the
index). It documents the native Settings window, the menu chrome around it (header,
content, launch-at-login, footer) and how the quota notifications surface in the UI.

## Settings Window

The native Settings window has a 220pt sidebar and a scrollable detail pane. Its minimum
size is `720x480pt`, with an ideal size of `760x520pt`. General, Energy, provider, and Clients
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
provider-strip right-click item (see `spec/ui/menu-and-cards.md` §Window Structure →
*Provider fallback strip*): one provider's request,
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

### 客户端 (Clients) pane

`SettingsView.clientsPane` (`SettingsClientsPane.swift`) is the only pane that is not a
provider pane. It has two halves:

- A **client switch bar** — `ClientSegmentedControl`, an `NSViewRepresentable` over
  `NSSegmentedControl`, wrapped in a horizontal `ScrollView`. The system control is
  used instead of SwiftUI's segmented `Picker` for two measured reasons: the Picker does
  not scroll and squeezes overflowed segments into ellipses (`MiniMax Code` truncates),
  and it can only render `Text`, so a count badge cannot use a smaller secondary font.
  Each segment is `title (N)` — the count in parentheses, because a bare `DSH 2` reads as
  a version number; the full form goes in the tooltip (`标题 · N 个 Provider · 副标题`).
  The tradeoff is explicit: no icons, since `NSSegmentedControl` cannot show an icon
  beside a text label without giving up template tinting.
- A **「已识别的 Provider」 section** — one `DisclosureGroup` per provider that actually
  produced local token activity for the selected client, showing total tokens, cache hit
  rate and the API-price estimate. The list is keyed by `.id(client.id)` so switching
  clients rebuilds the column and the expansion state falls back to the computed default
  (expanded only when the client has exactly one provider) instead of SwiftUI reusing
  the previous client's expansion by position.

The per-provider OpenCode merge switch is **not** in this pane (nor in the provider
panes) — `clientBindings[]` in `config.json` is its only source of truth, so saving the
form never rolls a hand-edited value back. See `spec/ui/menu-and-cards.md`
§Provider-Specific Card Details → *OpenCode client bindings*.

## Header

Implemented in `MenuContentView.headerBar`.

| Element | Current behavior |
|---|---|
| Leading icon | Full app icon (`icon-master.png`, 24×24, original colors; falls back to `chart.bar.xaxis` 13pt semibold secondary if the asset fails to load) |
| Title | `LLM Monitor`, 13pt semibold |
| Sleep-blocker notice | `N 个应用正在阻止休眠`, 10pt medium `Color.secondaryLabel` (fixed NSColor — the glass panel's vibrancy washes out hierarchical `.secondary`, especially in light mode), after the title, rendered only when `sleepHealth.report.offenders` is non-empty; hovering opens the offender list (`SleepOffendersHoverView`, same rows as Settings → Energy check 1), hidden otherwise, hover-only with no click action |
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

- `ScrollView(.vertical, showsIndicators: false)` wrapping a **non-lazy** `VStack`
  (`HarnessUsageMenuView.sectionSpacing` = 10pt). Non-lazy on purpose: the content
  height feeds `MenuPanelHeightBridge` to decide the window height, and a lazy
  container only lays out its visible region and would under-report it
- horizontal padding `LayoutMetrics.cardColumnHorizontalPadding` (12pt)
- vertical padding 8pt
- optionally the first-run setup guide (`MenuContentView.shouldShowSetupGuide`: every
  enabled provider is `.notConfigured`)
- `HarnessUsageMenuView` (global summary + per-client sections) and, as its last row,
  `ProviderStatusStripView` — **not** a `ProviderCardView` per status

The two context menus that used to hang off each provider card now hang off narrower
targets:

| Target | Menu item | Action |
|---|---|---|
| Client section header (`HarnessSectionView`) | `立即刷新全部` | `AppState.refreshAll` (same entry point as the header refresh button) |
| Client section header | `打开配置文件` | `state.openConfigFile()` |
| Provider strip element | `刷新 <provider>` | `state.refreshOne(providerID:)` |

When the menu appears, `MenuContentView.onAppear` refreshes the login-item status and
forces a sleep-health probe, and — if **any** provider is `.ready` — triggers
`state.refreshAll()`.

`MenuWindowAutoCloseBridge` attaches native tracking and notification observers so the menu can auto-close on focus loss or 30s of inactivity; it also snaps the window's top edge to `screen.visibleFrame.maxY + 10` (`MenuWindowAlignment.topOffset`), absorbing the system popover's top margin so the panel sits flush with the menu bar.

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

`nextRefreshAt` is the earliest next due time across enabled providers, published by the
single `ProviderRefreshScheduler` Task (no per-provider timers). After
the first request completes, the footer therefore shows a useful next-refresh time even when
providers use different intervals.

Right actions:

| Button | Icon | Action |
|---|---|---|
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

- 四个有窗口事件的 provider pane（ChatGPT / GLM / minimax / Antigravity）各有一个「通知配置」节：恢复 / 耗尽两个事件各自的渠道选择（`off` / `system` / `bark+system`）。
- General pane 有一个「Bark 推送」全局节：`enabled` / `serverURL` / `deviceKey` / `sound` / `skipWhenAwakeAndUnlocked` / `ttl` / `group`。
- 字段默认值与逐字段容错见 `spec/notifications.md` §5；JSON 契约见 `spec/config.md` §Config Schema 的 `notify*` 与 `bark` 字段。

> 核对基线：2026-10-04 · 代码 d6396fd
