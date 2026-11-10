# Menu & Provider Cards — UI Spec

This file is one of the three UI specs split out of `spec/ui-design.md` (now the
index). It documents the menu bar item, the menu window structure and the shared
`ProviderCardView`, hosted by the edge-dock popover and the single-instance provider-detail window. The menu has
separate compact usage and quota pages; quota rows reuse the same effective-quota
and fleet context pipeline; each provider also has a route to the full shared card.

## Menu Bar Item

Current implementation:

`MenuBarLabel` (defined in `Sources/LLM-monitor/Views/MenuBarLabel.swift`) renders a fixed `22x22pt` canvas. SF Symbol styles and Icon Duo are drawn into a `20x20pt` box (canvas − 2pt); the `quotaLogo` design asset is drawn at `appIconDesignDrawSide` = **18pt**, centered. The symbol dynamically reflects overall provider health and background refreshing status.
`AppState` publishes a stable clock value (`healthEvaluationDate`), advanced by the
provider deadline driver at GLM/DeepSeek peak/off-peak boundaries plus a ≤5min
sleep-health re-check (no dedicated resident timer), so peak-window boundaries update
even when no provider publishes a fresh network result. The clock is
kept outside the `MenuBarExtra` label because embedding `TimelineView` there can trigger
a status-item redraw loop on some macOS versions.

Icon Styles (`statusBarIconStyle`):
- `chartBar` (`chart.bar.fill` - default)
- `sparkles` (`sparkles`)
- `brain` (`brain.head.profile`)
- `cpu` (`cpu.fill`)
- `quotaLogo` (`App 图标` - the app icon design asset, no longer drawn at runtime)
- `iconDuo` (`Icon Duo` - live quota dashboard)

`quotaLogo` is a **static image**: the settings picker and the menu bar use the same
`llm-quota-730-2-dark.svg` design asset, and nothing about health, quota levels or
custom colors changes it. The asset's canvas is not its artwork — the drawing occupies
only ~59% of it, so drawing it canvas-true would put a ~12pt icon in the menu bar.
`MenuBarLabel.appIconDesignImage` rasterizes it once at 256px, scans the alpha
channel for the tight bounding box and crops to it **at load time** (aspect preserved),
so both consumers — the menu bar and the settings picker — get the artwork rather than
the canvas. `MenuBarLabel.baseDrawRect` then centers it in an
`appIconDesignDrawSide` (**18pt**) box; the SF Symbol and Icon Duo styles use a 20pt
box (canvas − 2pt). The scan must call `CGContext.makeImage()` *after* drawing — it
snapshots the context's current contents, so the reverse order yields a blank image, "no
opaque pixels", and a silent fallback to the uncropped canvas. It used to be drawn at runtime by `QuotaLogoSVGBuilder` — an
outer weekly ring plus an inner 5h ring growing counter-clockwise from 12 o'clock, with
a water cup in the center whose height mapped the 5h minimum remaining and whose color
followed `waterHealth`. At 20pt in the menu bar that drawing did not look like the
icon the picker showed, which is the wrong answer to "I picked this icon": the two
renderings drifted apart, and `waterHealth` existed only to feed it. Deleting the
builder therefore also deleted `StatusBarQuotaMetrics.waterHealth` and
`QuotaRingMetrics.colorHex` (the ring palette, read by nothing else) — the Icon Duo
gauge resolves every color from `healthColors` through its own `colorLevel` rule, so
neither was needed.

The `iconDuo` dashboard (`IconDuoSVGBuilder`) has two presentations. The global aggregate and a selected
provider's paired 5h / weekly source use the dual-window dashboard: a left 5h arc and right weekly arc, both being concentric
circular arcs growing from the bottom with dark gray background tracks and health-colored
available segments (a missing window keeps only its gray track). The center uses the minimum
actual available ratio across active models — per model, `min(5h remaining, weekly remaining × N)`
with the provider-specific weekly equivalent multiplier N (`ModelQuota.weeklyEquivalentMultiplier`,
the same caliber as the card's segmented progress bar); a model with only one window contributes
just that window's raw remainder (without weekly × N for weekly-only models), and the center stays
nil when no model has any window. The center displays this effective 5h percentage as centered digits:
0–99 use their ordinary digits and 100 displays as `00`; unknown data displays `—`. SVG metadata keeps
the real integer percentage in `data-value` and `aria-label`, while `data-display` contains the compact
glyph string. Known values use a 280-unit font and unknown uses 190; the CoreText outline's actual path
bounds are centered at (352, 352), independent of digit widths. The value color follows its effective
5h reading and associated time fraction. Three bottom dots (enlarged to r=36) follow
the circle's arc to show active-model health prioritized strictly as red > yellow > green (if 3 reds,
yellow and green are omitted); the top dot (enlarged to r=48) mirrors the Energy module's sleep-health state (green / yellow / red, gray while unknown).
Both quota arcs leave a net clearance of 0.75 lamp diameters to this dot on each side,
including their round caps. `energyHalfGapDegrees(lampRadius:)` derives the end angles
from the chord distance (lamp radius + half stroke width + clearance).
The popover window top edge is snapped to `screen.visibleFrame.maxY + 10` on every presentation, absorbing popover margins to stay flush
with the bottom edge of the macOS menu bar.
All `iconDuo` red/yellow/green decisions — the three bottom dots, both arcs, and the
center percentage — go through the time-aware `ModelQuota.colorLevel` thresholds (`< 30% * t` red;
`< 60% * t` yellow; otherwise green, with dynamic denominator `100% * t`, configurable via `AlertThresholdConfig`),
the same rule the provider cards use, replacing the retired fixed `HealthLevel.standard`
thresholds. Composite elements (the bottom dots and the center percentage) read the
effective 5h reading — per dual-window model `min(5h, weekly × N)` paired with 5h time via
`ModelQuota.aggregateActualAvailable`; weekly-only models use raw weekly percent and weekly time.
The bottom dots and aggregate health evaluate effective 5h and raw weekly readings separately
and take the worse tier via `aggregateHealthLevel`, while the left/right
arcs keep their raw per-window averages (both short and weekly arcs use the widest remaining-time
fraction across models for their dynamic thresholds). DeepSeek balance health is determined
by balance thresholds (`< 3` red, `< 10` yellow; default `deepseekBalanceCritical = 3.0`,
`deepseekBalanceWarning = 10.0`). During GLM peak hours a peak
floor raises a provider's composite status to at least `.warning` (red wins); the floor
only applies to the dual-window bottom dots and the card header dots — quota arcs,
the center percentage and the single-window percentage gauge are exempt.

When a single-window quota source is selected (for example a weekly-only ChatGPT plan, one API
credit key, or one GLM Start Plan entitlement), `StatusBarQuotaMetrics.singleQuota` selects
the one-source gauge. It draws one circular track and remaining arc with a **12 o'clock notch**, a centered
numeric remaining value (`—` while the chosen source has no current data), and only the Energy
sleep-health indicator at 12 o'clock. Only this menu-bar label omits the `%` symbol:
rounded 0–99 appear as their ordinary digits, and 100% appears as `00` (distinct from
empty `0`). The SVG group exposes the real integer percentage through `data-value` and
`aria-label`, and the compact glyph through `data-display`; known values use a 280-unit font,
unknown uses 190. The CoreText outline's actual bounding box centers the glyph both horizontally
and vertically at (352, 352), independent of whether the value has one or two digits. Arc length,
color, accessibility and card percentages retain the real value. The single gauge uses the
selected source's value with the same centered glyph renderer; split 5h / weekly arcs and
three quota-health dots are omitted. Zero is shown as a critical-colored `0` with an empty
track; absent data is gray. The gauge arc follows the same time-aware `AlertThresholdConfig`
color rule as the other quota elements. The sleep indicator sits **on the ring's circumference**,
inside the top notch, with a net gap of 0.75 lamp diameters to each round cap. Ring and lamp form one circular
silhouette, matching the dual-window dashboard's radius (270 on the 704-unit canvas).
The lamp diameter equals the 56-unit ring width; each clearance is 42 units. The arc runs
from approximately −69.09° to 249.09° (318.18°), derived from the same chord rule as the
dual-window gauge. The remaining angle accommodates the lamp, the rounded ends and the two clearances rather
than forcing a literal 350° arc and moving the lamp above the circle. The value is centered
at the ring's center (352, 352).
The global aggregate also uses this gauge when only one window category is present,
retaining its nonzero-minimum effective percentage.

**聚合 model 集合排除独立小池（2026-10 用户裁定）。** iconDuo 的四个读数（左右弧、
中心百分比、底部三点）与 SF Symbol 状态点 / 边缘窗圆环 / provider 综合健康度读的都是
`QuotaInfo.aggregateQuotaModels(providerKind:)` —— `activeModels` 再滤掉
`ModelQuota.isExcludedFromQuotaAggregation(providerKind:)` 命中的家族：minimax 的
`video`（视频生成）与 antigravity 的 `claude_and_gpt_models`（Claude and GPT models）、
`gemini_argon`（Gemini 4 Argon）。
它们都是与主力模型无关的独立配额池，计入最差值聚合只会让无关池子的余量稀释（或拖垮）
一个用户无从 action 的读数。滤后为空时回退 `activeModels`（排除只允许「少算」，不允许
把有数据的 provider 聚合成「无读数」或保守误红）。卡片逐 model 行与通知管线
（`QuotaEventDetector` 逐 model 窗口事件）不受影响。

**Center percentage relay semantics.** The center percentage takes the *lowest* "actually
available" ratio across plans, but a plan whose value is exactly 0 is excluded from that
comparison. This models plan hand-off: once a plan is spent, it would otherwise pin the
value to 0 and hide the plan now serving you, so the center follows the one still in
service (its `timeFraction` follows with it: 5h time for effective 5h, weekly time for a
weekly-only plan). Boundaries are distinguished deliberately: readings exist but every
plan is exhausted → `0%` (critical-colored `0`, `timeFraction` nil since `colorLevel` treats 0%
as critical regardless); no plan has any window at all → `nil` (gray, "not configured"
is not "exhausted"). Ties keep the first plan encountered. The bottom dots and the card
header dots are unaffected — they still cover every plan, so a spent plan stays red
there. The notification pipeline is a separate concept: it keys off per-window remaining
crossing below **0.01%**, so "plan A's 5-hour window ran out" and "the ring now shows plan
B" are complementary rather than contradictory.

The base icon keeps the standard macOS foreground appearance. For standard SF Symbol
styles, a 6 pt status dot is drawn at the lower-right when `statusBarHealthDotEnabled`
is enabled (the default): green for healthy, orange for warning, and red for critical.
Both `quotaLogo` and `iconDuo` dashboard styles are self-contained (rings/water and
quota/health dots respectively) and do not add this legacy lower-right dot. The retired
`statusBarIndicatorMode` key is ignored when
encountered in an old hand-edited config; it is not part of the current schema.
Unknown or type-mismatched icon values in a hand-edited config fall back to the default
without discarding the provider configuration.

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
- menu window also closes after **30 seconds of no interaction** — the timer starts on
  every `become key` and any mouse move / mouse down / scroll / key down inside the
  window resets it (`MenuInactivityTimer`, the state machine is unit-tested with an
  injected scheduler rather than a real 30s wait)
- hover details are shown in a separate floating `NSPanel`
- Antigravity process availability is discovered asynchronously and cached, so opening the menu does not synchronously run process inspection.

`MenuContentView` layout: usage and quota both use a fixed 484pt width. The usage width
fits the compact four-metric client summary; quota width fits the shared Plan chart at
420pt. Page switching keeps one width, including collapsed, expanded, and empty states.

```text
width: 484pt (usage and quota)
height: content-driven, fixedSize(vertical: true)

+------------------------------------------------+
| chart.bar.xaxis  LLM Monitor      21:09  ↻   |
+------------------------------------------------+
| [ 用量 ] [ 额度 ]                             |   persisted local page choice
| 今日合计 1.2M   60%  ¥18.40（含$2.5）          |   usage page; freshness is in the header
|  █████▓▓▓▓░░░  客户端占比条（色=主力provider）  |
|  ⌘ MiniMax Code  ⌘ Codex …                     |   legend: 着色客户端图标 + 名字，放不下换行
+------------------------------------------------+
| ▸ OpenCode                         21:09       |   collapsed client section
|   今日 Token: 820K  价值: ¥10  命中率: 62%  速度: 205 tok/s |
|   gpt-5.5                         620K tokens   |   expanded model details use compact rows
|       ├────────◆────────┤                       |
|     min 28            max 163          最近 137   |
| ⚠ 会话文件超出单轮扫描预算，已按最新优先截断…   |   truncation notice (that section only)
| ...                                            |
+------------------------------------------------+
|                   ⏻ 自启 | 设置 | 节能 | 日志 | 退出 |
+------------------------------------------------+
```

额度页按启用 provider 顺序呈现与用量相同的紧凑卡片外壳，支持单 Provider 刷新、未配置项定位到
对应设置，以及可分别展开的「套餐详情」和「用量历史」；两个折叠区初始均关闭，可同时打开。
操作行始终保留「套餐详情」「用量历史」「独立窗口」三个入口。额度摘要与三个操作优先同行；
实际宽度不足时摘要移到独立一行，三个操作仍保持同行。首行左侧 Provider 名称与临期/高峰事件，
右侧放置 Provider 级状态栏来源小眼睛（`eye.fill` / `eye.slash`，单击选该 Provider 主套餐、再次点击取消；右键仍可选具体来源）与额度更新时间，贴近刷新按钮。主套餐额度组在额度行上方显示套餐名（无套餐名时显示「主套餐」），眼睛紧随其后；每条可独立选择的 API Key / 活动套餐标题旁也有单击即选的小眼睛。已选来源显示实心眼睛，并写入同一个 `config.statusBarQuotaSelection`。正常状态不再另占更新时间行或详情页脚；
更新时间仅显示 `HH:mm`，help 说明它代表 provider 额度读取时间，刷新动作只刷新该 Provider。
窗口摘要在 5h 与周余量后分别显示对应瓶颈模型的重置倒计时（未知显示「重置时间未知」，已到期显示「待更新」）；详情保留完整重置时间。
重置卡在现有 48h / 24h 紧迫度分档下进入摘要首行（橙 / 红）；GLM 与 DeepSeek 仅在既有高峰规则判断为临近或正在高峰时显示事件。
loading、failed、notConfigured 可按需增加状态行，错误始终可见。DeepSeek 即使没有窗口额度也显示余额。
额度始终使用本机优先、必要时 elected 的全局有效值。菜单顶部 scope 仅切换用量；
多节点额度页会标明当前用量范围与额度仍为全局有效值。内容高度由当前页实测，
超过屏幕预算时内容区滚动，标题和 footer 保持固定。

在**用量页**中，段总 Token、4 桶、命中率与客户端占比条权威地从各客户端的 `dailyTokenUsage` 计算。
模型明细、折算金额与速度继续从 `recentSamples` 推导。当样本因容量截断或早期样本滚动淘汰导致样本合计小于日桶总额时，
段头与展开列表下方展示完整性说明（`sampleIntegrityNotice`：「部分早期样本已被清理，模型明细仅覆盖留存样本」）；
若客户端今日有日桶总额但单次调用样本为 0（如早期会话全部归档），客户端依然正常保留展示，价值显示为 `—`，
展开区域提示「仅保留日汇总数据，暂无单次调用模型明细」，严禁把未对齐差额随意分摊给模型或伪装成 0 元。

（footer 右侧功能组整体向右对齐，竖线分隔，自启为状态化图标按钮，日志与退出为直属常驻操作。）

The menu offers two complementary views: **用量** answers which clients burned how
many tokens today, and **额度** answers how much remains per enabled Provider. The
quota page is available when the edge dock is hidden. 「套餐详情」 and 「用量历史」 are
independent disclosure actions and may be open together. Plan uses the same
`QuotaWindowAccountInfoRow` + `ProviderCardView.planModules` composition as the edge-dock
popover and complete detail window. History uses the shared `SevenDayUsageHistoryView`;
it remains available without quota data and shows an explicit empty state when history
is unavailable. Opening both sections presents the same Plan and history content as the
standalone window. 「独立窗口」 opens that complete view directly. Fleet effective quota
remains independent from scope; history and quota-window usage continue to follow the
selected fleet scope. Loading and failure states preserve last-success Plan data and
retain visible status feedback.

The quota summary row uses `ViewThatFits`: if the complete summary plus all three actions
fit, they share one line. Otherwise the summary wraps onto its own line while the three
actions stay together, so reset countdowns and 「独立窗口」 remain visible.

**Scope switcher** (`FleetScopeSwitcher`): one shared control, used by the menu
header (right group, next to the refresh button) **and** by the provider-card
header in the dock detail popover. It has two forms, split by the **option count**
(全局 + 本机 + remote nodes):

In the menu, this control applies to the **用量** page only. The quota page always
uses the sync layer's effective global quota (local first, elected fallback), and
when multiple nodes are present it names the selected usage scope so the two data
axes cannot be confused.

- **≤ 4 options → segmented control** — a `Picker` with `.pickerStyle(.segmented)`
  (mini size): 全局 / 本机 / each remote node. One click to switch, everything
  visible at once. Node names go in verbatim (no "（离线）" suffix — a segmented
  control has no width budget and would truncate them).
- **> 4 options → dropdown** — the range text plus the `ellipsis` marker as an
  **inline image attachment** (`Text("\(truncated) \(Image(systemName: "ellipsis"))")`).
  On macOS, SwiftUI maps a `Menu` label onto an AppKit `NSButton` (image + title): a
  standalone `Image` placed in the label is hoisted to the **leading** edge (the text
  ends up to its right) and width limits applied inside the label are ignored. The
  inline attachment is part of the title string, so the marker always stays after the
  text and the button hugs the label.

Both hosts use the same option-count split (`FleetScopeControlStyle.preferred`),
but the two hosts **place the forms differently**:

- **Dock card** — segmented form (≤ 4) below the card header row, except when the
  dock is attached to the bottom edge: then it moves to the end of the detail
  content, nearest the dock; dropdown (> 4) stays in the card header.
- **Menu panel** — the header only ever carries the **dropdown** form (> 4,
  next to the refresh button). At ≤ 4 options the header shows **no scope control
  at all**; the segmented form renders in the content area, above the 今日 card
  (`HarnessUsageMenuView.scopeRow`).

**Position** — the control's place depends on the host **and** on the form:

- **Segmented form (≤ 4 options)** — a dedicated row of its own, spanning the
  full card width:
  - **Dock detail popover**: directly **below the card header row** by default
    (`ProviderCardView.scopeRow`), inset by `LayoutMetrics.cardContentPadding`
    so it lines up with the card blocks underneath. When the dock is on the
    **bottom edge**, the popover opens above it, so the segmented row moves to
    the **end of the detail content** to stay nearest the dock.
  - **Menu panel**: **above the 今日 card** (`HarnessUsageMenuView.scopeRow`),
    at the **same full width as that card's background** — the card's 8pt padding
    sits *inside* its background (`HarnessUsageMenuView.swift` 的注释明确此点), so the
    row must **not** add its own 8pt inset or it ends up narrower than the card.

  The row has to be full width and on its own: a segmented control has no width
  budget, so sharing the header row pushed the provider name down to
  "minimax To…".
- **Dropdown form (> 4 options)** — compact, in the header:
  - **Menu panel**: the header's right group, immediately left of the refresh
    button.
  - **Dock detail popover**: the card header's right side, left of the freshness
    pill.

  The option-count split is unchanged: the segmented row appears only while the
  option count is ≤ 4, and the compact dropdown takes over once there are more.
  Only the dock segmented row changes position for a bottom-edge dock.

  For a left/right dock, the detail popover initially aligns to the hovered row.
  Once open, scope changes preserve its top edge while the content height changes;
  screen bounds still clamp the panel.

- **Width cap** — `FleetScopeMenu.maxLabelWidth` = **120pt** for the whole
  group (range text + marker). The text itself is cut by
  `FleetScopeMenu.truncated(_:maxWidth:)`, a pure function that
  measures the string in the 11pt medium font and trims the tail with `…`; the
  marker is always kept (`FleetScopeMenu.glyphReserve` = 16pt is reserved at the
  text's trailing edge so truncated text never collides with it). The cut is done on
  the string rather than with SwiftUI layout because a `Menu` label ignores inner
  width limits (AppKit `NSButton` mapping) and a `maxWidth` frame on the `Menu` is
  treated as flexible by the header `HStack` — it would eat the leftover space and
  open a gap between the text and the marker.
- **Fixed button width** — the `Menu` keeps `.fixedSize()`. Without it SwiftUI
  sizes the button to the **widest item of its own menu** (a node name plus
  "（离线）", measured 109pt), so the scope group's width would drift with the node
  name and the whitespace next to the refresh glyph would change with it.
- **Menu items** — 全局 / 本机, then a 节点 section with the remote nodes
  (`FleetNodeChoice`; stale ones carry "（离线）"). The current scope's text comes
  from `FleetScopeMenu.labelText(_:choices:)`.

**Fleet usage semantics.** A Provider card's selected Fleet or node scope selects
the source bucket, not a provider-filtered daily total. The seven-day chart, the
「今」 row, and daily amount use the selected scope's complete daily bucket across
all providers. `quotaProviderID` filters only quota-window rows. This preserves
the authoritative day total even when the selected quota owner has only part of
that bucket's activity. Window rows select one history per `(modelID, windowKind)`:
prefer the range whose `endAt` matches the effective quota reset boundary at wire
whole-second precision; otherwise use the latest `endAt`. Partial pricing and
incomplete coverage remain visible beside any available amount as 「部分计价」. A
bucket with no priced sample continues to show 「未定价」 rather than suggesting a
partial amount. A stale node's nonzero usage or amount in a displayed daily bucket
also triggers the card's 「部分节点缺该范围或已离线」 notice, even when no current
window row exists for that provider; stale nodes with no daily contribution do not.
Fleet amount text survives both UI adapters: `QuotaWindowUsageSnapshot.Window.costText`
retains the window text, and `QuotaWindowUsageSection.visibleRows` preserves it for
5h / weekly / today / off-peak rows. This keeps partial-pricing markers and mixed-currency
totals visible instead of reducing them to a complete single-currency amount or `—`.

Fleet snapshot and scope changes travel on `fleetDidChange`, separate from
`statusDidChange`, so refreshing the visible Fleet snapshot does not recursively
rebuild a hub report. Closing Fleet Sync or changing upstream clears the prior
snapshot and returns unavailable Fleet/node scope to local.

**Header right group** (scope switcher + page freshness + refresh): the scope
dropdown sits next to the refresh button, both right-aligned as one group; 当前页
数据源的裸刷新时间（见下文 Global freshness）在两者之间——
**scope 下拉（若有）→ 时间 → 刷新**。**The scope dropdown only exists
when there is something to switch** — it renders only when fleet sync
is enabled, node choices are non-empty and the option count is > 4
(`FleetScopeControlStyle.preferred == .dropdown`); without a scope group
(联动未启用 / 选项 ≤ 4) the usage time + refresh button sit alone, flush right
(`MenuContentView.swift` 的 header right group 分支). 时间是全局读数，无论有无
scope 下拉都在刷新按钮左边。

- **Even spacing** — the group's inner spacing is `headerGroupSpacing` = **8pt**.
  The refresh glyph sits centered in its own 26pt hit slot; the equality
  derivation below was measured between the scope button and the refresh glyph
  （时间文本 2026-10 插入后，刷新图标左侧可见留白 = 本间距——时间文本无尾部
  内边距——不再与右侧 12pt 严格相等，读数优先于节奏）. The scope button's own trailing
  padding (AppKit borderless button, measured 4.25pt) participates in the
  scope-side whitespace, while the whitespace on the refresh glyph's
  right is the header's trailing padding (`headerTrailingPadding` = 12pt). Equal
  whitespace therefore needs 12 − 4.25 ≈ 7.75pt, rounded to 8pt (measured at
  2× pixels: 21pt on the left, 20.5pt on the right — a 0.5pt difference, within
  the antialiasing error). The in-flight spinner takes the same slot so starting
  a refresh does not shift the row.
- **One horizontal line** — the marker's dots and the refresh glyph are both
  centered in the header row, so the two marks share one baseline of their own.
- The header title no longer wraps to two lines (`lineLimit(1)` + `fixedSize`):
  a long sleep notice must not reflow the row. The sleep-blockers notice itself
  degrades instead of being cut into an unreadable stub: a `ViewThatFits` falls
  back from "N 个应用正在阻止休眠" to "N 个应用" when the 120pt scope cap leaves
  no room for the full sentence.
- Both glyphs use the `MenuTypography.headerAction` role (11pt medium).

**Content structure** (`HarnessUsageMenuView`, driven by the pure
`HarnessTodaySummary.summarize(statuses:now:calendar:)`). 下述「Global today summary →
per-client sections」描述的是**本机 scope** 的内容区；多机联动启用且 multiNode 时，
内容区按所选 scope 统一为「一行『今日』总览 + 平铺段」结构，见本节开头的
**Fleet scope 内容区**：

**Fleet scope 内容区**（三 scope 统一规则，302b8b3 定稿；细则的单一事实源是
`spec/sync.md` §10.2，此处只放 UI 侧口径）：

- 三个 scope（全局 / 本机 / 各远端节点）各渲染**一行同名「今日」总览** + 客户端
  占比条 + 图例（`scopeOverview(label:…)`，与本机 scope 的总览卡同一实现，
  见上文 Global today summary）——标签统一「今日」，不再「今日全部 / 今日本机」；
  范围语义由顶部 scope 控制表达，总览行不重复。fleet 路径的段来自
  `FleetMenuSummary.sections`（主 provider 由 `ClientSection.dominantQuotaProviderID`
  带过来）。
- **无设备子层**：全局 = 跨节点合并段、本机 = 本地段、节点 = 该节点平铺段
  （`FleetClientSectionView`）；节点 scope 的段头**没有**右键刷新。原带折叠的 `FleetNodeGroupView`（曾为全宽节点行折叠组）已在 M1 彻底删除，节点统一平铺展开模型行。
- 全局 / 节点段内的模型行与金额直接使用 fleet **已合并**条目（hub 已做同币相加、
  混币冲突置空并给出 `costText`），视图不再自行折算。
- 模型行展示名与本机同口径，一律 `compactDisplayName`。
- **零数据不占位**：节点行 / 模型行 / 整段按非零过滤（5400d11）；整 scope 无段
  才出「今日暂无 Token 用量」。缺今日桶显示“尚未同步”及 `—`，不回落本机；
  来源部分不可用时显示已知合计并提示原因及可能包含上次数据。卡片保留历史日图。
- 右键刷新仅全局 / 本机形态的段头提供，文案「刷新本机 <客户端名>」——见下文
  §Section header context menu。

本机 scope 的结构：

- **Global today summary** — 双焦点 Hero 大字卡布局（2026-10 升级）：
  - **顶栏（Header）**：左侧为范围与日期标题（单机为 `今日 MM-dd`，多机 Fleet 为 `全局 · 今日` / `本机 · 今日` / `<节点名> · 今日`），右侧为胶囊徽标 `命中 97%`（无缓存读数显示 `命中 —`）；
  - **核心数值区（Hero Row）**：左侧大号等宽粗体总 Token（如 `132M`）+ 下方副标签 `今日总 Token`；右侧大号等宽粗体总价值（单一币种直接展示如 `¥385.0` / `$47.60`，混合币种折合总额如 `¥385.0`）+ 下方副标签（单一币种 `今日花费`，混合币种展示明细 `折合总额（含$47.6）`）；
  - 核心数值区下方是**客户端占比条**（`HarnessClientProportionBar`，2026-10 起，取代原全局 input / cacheRead / output 三段条；原模型行 Prompt 速度范围线已于 2026-11-07 移除）+ 一行图例（`HarnessClientLegend`）：
    - 占比条**一段一个今天有 token 活动的 harness**（`HarnessTodaySummary.clientSegments(from:)` 按 `sections` 既有的 token 降序输出、零段过滤），段宽 = 该客户端今日 token 占全部客户端的比例；
    - **段色 = 主力 provider 的卡 accent 色**：客户端横跨多个 provider 分片时（ZCode / DSH / OpenCode）取今日 token 最大的一路，并列取 quotaProviderID 字典序小者（`HarnessClientSegment.dominantQuotaProviderID`）。色值经 `AccentColor.cardAccentColor`（`Color+Theme.swift`，与 provider 卡描边 / 进度条健康态同源；minimax 亮紫 `#A855F7` / chatgpt 绿 / antigravity 蓝 / glm 靛蓝 / deepseek 青），未知 / 缺失的 providerID 回退灰；
    - 归一化口径与 `TokenBucketBar` 一致：负值按 0、Double 累加分母、总量 ≤ 0 全 0（纯灰底），不产生 NaN；条高沿用 `TokenBucketBar.standardHeight`（7pt）；每段挂 `.help`：「MiniMax Code 355M（77%）」；
    - **图例**把颜色翻译回客户端并直观标注量级：`<着色图标> MiniMax Code 355M  <着色图标> Codex 120M …`。图标取 `ClientDescriptor.iconSystemName(forClientID:)`，着色即段色，紧随其后展示该客户端紧凑 Token 读数；hover 上仍挂「MiniMax Code 355M（77%）」完整 tooltip。chip 超出行宽**换行**（`WrapLayout`）而不是截断；段列表为空（今日无活动）时条只剩灰底、图例整行不画。
- **Per-client sections（树形层级，2026-11-07 起取代方块卡片）**, ordered by
  today-token descending and collapsed by default. 第一级 = harness 行：
  `▸/▾` 展开三角 + 客户端图标 + 名称 + **同行汇总簇**……右侧扫描时间（`HH:mm`）；
  折叠即一行，右键「刷新 <客户端名>」仍只挂这一行。截断提示独占缩进行；
  展开后第二级 = 模型行，每行带 ├─ 式短横刻线；引导线底部截短约半行近似 └ 形收尾。
  同一模型落在多个 harness 时仍按段嵌套各自展开。树形几何常量
  `guideX = 4` / `treeIndent = 14` / `tickWidth = 7` / `guideOpacity = 0.14` /
  `guideTailTrim = 7` 定义在 `HarnessSectionView`（测试锚点见 `HarnessUsageMenuViewTests`
  `testTreeSectionGeometryAnchors`）；圆角卡片底与段头下划线已随树形化移除。
- **字段级对齐指标簇（`HarnessMetricColumns`，2026-11-07 用户裁定）**：harness 汇总行
  与模型行共用同一组**定宽右对齐列**，纵向跨行对齐；列序与英文标题
  **Turns · Token · Hit · Think · TTFT · Speed · Value · Update**（2026-11-07 裁定：Pmt 更名
  Turns，Value 移到 Speed 后，扫描时间以 Update 加入标题行；2026-11-08 TTFT 插入
  指标簇（初版在 Speed 与 Value 之间，同日晚间按用户裁定改到 Speed 之前），34pt 定宽
  `HarnessMetricColumns.ttft`，`clusterWidth` 的间距系数随之 5→6）。宽度预算按「够并集取
  并集、不够取交集」实测裁定——内容区 460pt（484 面板 − 2×12 内边距）装得下并集，
  故取**并集**（量测锚 `testMetricClusterUsesUnionWithinBudget`，若面板收窄装不下
  则反转回交集并同步本节）。harness 行的 Turns/Token/Value/Hit/Think/TTFT/Speed = 段级
  聚合（Turns 用段 `promptSpeedStatistics.totalPromptCount`、Think 用段 buckets），
  模型行用行级值；速度均为完整 Prompt P50，TTFT 为**调用级 P50**
  （`LocalUsageSummaryBuilder.callTTFTStatistics`，样本批与速度同源）。**Speed 格的
  tooltip（2026-11-08 起）从静态口径说明改为该行实际分布**：
  `Min: x · P50: x · P95: x · Max: x tok/s`（`Formatters.formatSpeed`，P95 就近秩法
  第 ⌈0.95n⌉ 个观测值，`PromptSpeedStatistics.p95`），无有效样本时回退原口径文案，
  有效数 < 总数时尾注 `（v/m Prompt 有有效时长）`；段头用段级分布、模型行用行级分布。
  数值自带量纲（数量级后缀 / 货币符号 /
  % / tok/s / 秒），不带字段标签，口径解释挂每格 `.help` 与表头。Update 占固定尾槽
  （`timeSlot = 38`，以放下标题「Update」为准），模型行留空同宽保证簇列对齐；
  扫描时间为 summary 级最新本地扫描时刻，Fleet 段不伪造。汇总行的价值是
  `MixedCurrencyEstimate`（客户端可横跨多 provider 分片多币种），模型行价值是
  单 provider 单币种原额。
- **指标列标题（`HarnessMetricColumns.columnHeader`，2026-11-07 补）**：客户端段列表
  上方整表一次渲染一行列标题 `Turns · Token · Hit · Think · TTFT · Speed · Value · Update`
  ——列宽与 `cluster` 共用同一组常量、右对齐同位，去标签数值行由此可按表读列；
  标题行带**弹性名称占位**（与数据行同构）撑满行宽，把标题簇推到与数据相同的列位
  （缺占位时标题挤行首、数据贴右缘，2.3.10 修复）；名称列留空占位，整行弱化
  （secondary 72%），口径说明挂表头 `.help`。
- **Per-model rows inside an expanded section**, keyed by
  `(clientID, quotaProviderID, modelName)`; samples with no usable model name
  collapse into a single 「模型名缺失」 row. Each row is a single baseline line:
  模型名（弹性列，最小 80pt 后尾部截断，`.help` 挂全名）+ 上一条描述的
  `HarnessMetricColumns` 并集簇 + 空时间槽——与 harness 行字段级对齐。
  **Prompt 速度范围图与「共享刻度」图例已于 2026-11-07 移除**（用户裁定：图占位大；
  面板宽度本为固定 484pt 常量，移除不改变宽度、只省每行高度与图例行）。速度分布统计
  （`min / max / P50 / latest`）仍按 `spec/accounting.md` §Prompt 速度分布计算，
  UI 只消费 P50 文本。`Pmt` counts all recorded promptIDs, including prompts excluded
  from speed statistics；无有效时长的 Prompt 计入 Pmt、速度格按 `—` 处理。
  Fleet client sections use the same compact card summary and disclosure interaction;
  without local call durations they display speed `—`, including expanded Fleet model
  rows. Fleet model rows use the same single-baseline format and omit the unknown Pmt
  count; help explains that duration data is not synchronized. The row value is the **single-provider,
  single-currency** original amount (`ModelCostEstimate.displayText`: `¥3.21` /
  `$9.80` / `未定价`) — cross currency folding happens only at section and global
  level, never per row. Prompt speed is `Σ(Output+Reason) ÷ Σ decode duration`
  over all calls in one prompt（解码时长 = 调用时长 − 首字延迟，无 TTFT 的调用按
  时长全额计入，2026-11-08 起见 `spec/accounting.md` §Token/s 速率口径）. A prompt
  joins the distribution only when all call
  durations are valid（且解码时长为正）; `latest` is the newest prompt and is `—` when that newest
  prompt is incomplete (never an older fallback). Help explains excluded samples.
  The client summary `速度` is calculated from
  all of that client's daily prompts, not by averaging model-row percentiles. The
  global summary row carries no speed — the rate is a per-client/per-model metric.

Visible speed readings share `Formatters.formatSpeed`: at most three numeric characters
including the decimal point (`8.6` / `50` / `246`); larger magnitudes use a suffix such as
`1.0K`. This changes display precision only; P50, range markers, and shared scales retain
their original numerical values. TTFT readings share `Formatters.formatTTFT`（裸数字秒，
`0.86` / `12.5` / `124`，恒 ≤ 4 字符；nil → `—`）——Speed 列与 TTFT 列同批样本、
不同聚合（速度 = Prompt 级 P50，TTFT = 调用级 P50，见 `spec/accounting.md` §TTFT 口径）。
Fleet 段 / 模型行无本地样本，TTFT 恒 `—`（wire 协议不携带）。

The 484pt menu gives the compact client summary room for four core metrics and adds
the thinking share only when `ViewThatFits` confirms the full row fits. A narrower
host wraps the four core values rather than truncating an essential metric. Expanded
model rows use flexible names and natural labels instead of reserving the old six
columns. Layout is covered by `HarnessUsageMenuViewTests`.

**Model name display** (`HarnessModelRow.compactDisplayName`, model layer): the
column shows a *compacted* name, so that what fits in the 92pt budget is the
**model** rather than the vendor. Two rules, applied in order:

1. **Vendor namespace** — everything up to and including the first `/` is dropped
   (`minimax/MiniMax-M3` → `MiniMax-M3`). The namespace is already stated by the
   section header and the hover card, so repeating it in the name column only
   steals width from the model.
2. **Brand prefix** — known long brand prefixes are stripped case-insensitively
   (`gemini-`, `claude-`): `gemini-3.8-flash-n` → `3.8-flash-n`,
   `claude-opus-4-6-thinking` → `opus-4-6-thinking`. Short prefixes (`gpt-`) are
   **not** stripped: the saving is small, and a bare `flash` is harder to
   attribute inside a multi-provider section.

The **MiniMax family** gets its own normalization instead of rule 2, because the
same model is spelled differently by every harness and the variant suffix is
noise there: the vendor path is dropped, the `-Flash` / `-Flash-Preview` variant
suffix is stripped, and the brand casing is unified to `MiniMax-`.

| Raw model id | Displayed as | Source |
|---|---|---|
| `minimax/MiniMax-M3` | `MiniMax-M3` | MiniMax Code legacy label |
| `MiniMax-M3` | `MiniMax-M3` | DSH / OpenCode |
| `MiniMax-M3.1-Flash` | `MiniMax-M3.1` | MiniMax Code session dir |
| `MiniMax-M3.1-Flash-Preview` | `MiniMax-M3.1` | ZCode |
| `Minimax-M3.1-flash-preview` | `MiniMax-M3.1` | DSH |

The variant suffix is stripped **only inside the MiniMax family**: `gemini-3.8-flash`'s
`-flash` identifies the variant (`3.8-flash-n` vs `3.8-flash-tiered` must stay
distinguishable), so stripping it globally would reintroduce the ambiguity rule 2
exists to remove.

Before this compaction the MiniMax Code row read `minimax/MiniMa…` — the vendor
namespace filled the column and the model name was truncated away; the ZCode row
read `MiniMax-M3.1-F…` for the same reason. Names still wider than 100pt stay
tail-truncated (`opus-4-6-thinki…`) — the column budget is unchanged, only the
vendor prefix no longer eats it.

Compaction is **display-only**: the grouping key (`id`), pricing and statistics all
keep the raw `modelName`, and the row's hover tip still shows the full original ID.

Tokens are always counted from the same-day subset of each provider contribution's
`recentSamples` (through `UnifiedTokenUsageAggregator.day`), so the extra day that
scanners keep for quota-window math never leaks into "today".

The two-level empty states (no provider registered / no provider enabled) and the
first-run setup guide are unchanged. A third, narrower state — clients present but
no activity today — renders a single 「今日暂无 Token 用量」 line inside the
content area. Fleet scope 另有**不可用总览态**：全局 / 所选节点缺少今日权威日桶时，
总览行显示「尚未同步」占位（零值不得显示为已完成合计），数据侧规则见
`spec/sync.md` §10.2 日桶可用性。

**Global freshness (bare time)** — 页面级刷新与时间只保留标题栏右上角一处，
footer 不再显示另一套请求完成/下次刷新时间。用量页取缓存摘要的
`localUsageScannedAt`，点击只调用 `AppState.triggerLocalUsageRescan`；scope 为全局或
节点时 help 明示仍是本机扫描时间，不冒充远端采集时间。额度页通过
`MenuContentView.providerQuotaUpdatedAt` 取启用 Provider 有效额度的最近成功读取时间
（含 elected，优先 quota.fetchedAt，再回退持久的 lastRefreshedAt），不是会在失败时也
更新的 `AppState.lastRefreshAt`。这是最近一张卡的成功时间，不表示所有 Provider 同时更新；
每张卡仍显示自己的额度时间与单卡刷新。额度页主刷新沿用 `AppState.refreshAll` 的完整
路径。两页时间显示 HH:mm，无记录显示「待更新」，进行中以刷新槽 spinner 反馈。

**Truncation notice** — a section whose sources were truncated (DSH file/byte budget
dropping the oldest sessions) shows a **one-line** short notice (`部分较早会话未计入`,
`HarnessSectionView.truncationShortText`) in orange on the header's second line; the
full `ClientUsageTruncationNotice.text` stays in its `.help` tooltip. The long sentence
wrapped onto two lines under a 460pt content area and pushed the section's rows down. Section-level aggregation, same "any source
truncated ⇒ truncated" rule as `ProviderUsageProjection.isTruncated`. Sections
without truncation show nothing — the numbers are right either way, they are just not
complete, and staying silent would let a partial total read as a complete one.

**Section header context menu** — right-click a section header for 「刷新本机 <客户端名>」
（本机 scope 的 `HarnessSectionView` 与 fleet 全局 / 本机形态的
`FleetClientSectionView.refreshMenuTitle` 同文案）:
`HarnessSection.refreshProviderStatusIDs(in:)` resolves the provider cards this
section's today contributions came from (a ZCode section spanning GLM / minimax /
deepseek shard rows refreshes all of them), and `MenuContentView.refreshSectionFromMenu`
then runs `AppState.refreshOne` over those cards sequentially. 「打开配置文件」 used to
live here too; it later moved to the menu-bar icon's right-click menu and was removed
outright in 2.5.1（旧「用默认编辑器打开 config.json」能力整体删除，无替代入口）.
That menu now reads 「刷新 / 设置 / 退出」; the Settings entry is a plain
`NSMenuItem` invoking the SwiftUI `OpenSettingsAction`（`\.openSettings`，经
`SettingsOpenerBridge` 注入 `MenuBarRightClickHandler`；2.5.1 起文案为「设置」，
2.5.2 起弃用 view 宿主 `SettingsLink`——`NSHostingView` 在 popUp 出来的 NSMenu
里不渲染，该条目曾因此长期隐形）.
The menu is attached to the header rather than the whole section so that the right-click
target reads as "these numbers". **节点 scope 的段头没有右键**——刷新只对本机数据有意义，
节点数据由同步链路维护（`spec/sync.md` §10.2）。

**Provider fallback strip — removed from the menu** (用户裁定 2026-10-24, 8e7278a):
the old last-row provider strip and its hover card remain removed. Phase 2 adds a
separate quota page to the existing menu, so quota is directly available without
the edge dock. The old strip projection, view, and strip-specific tests were deleted
because no production host remained. The Settings provider refresh action is now
independent of that removed menu feature.

The content area scrolls when needed. `MenuPanelHeightBridge` caps the menu window at
70% of the screen's visible height; when the cap is reached, only the content list
scrolls while the header and footer remain fixed. The cap is applied at the native
window layer and the list uses the remaining content height. The measured height is
reported through `CardsContentHeightKey`, which the harness content reuses unchanged.

**The cap lives in the `NSWindow`, not in SwiftUI frames.** The menu sizes to its
content (`fixedSize(vertical: true)`) so a short client list gets a short window; the
ceiling is `window.contentMaxSize` = `floor(visibleFrame.height × 0.70)`, set by
`MenuPanelHeightBridge.HeightProbeView.applyMaxSize()`
(`Views/MenuContentView.swift:727-757`，`HeightProbeView` 定义在同文件 `:716`). `cappedHeight(_:)` and `heightCapFraction`
(0.70) are exposed as `static` precisely so `MenuPanelHeightBridgeTests` can pin the
arithmetic without standing up an `NSWindow` / `NSScreen`. The cap is conditional:
`windowMaxHeight` is `maxHeight` only when the natural height (measured cards +
`chromeHeight` 65pt) exceeds `availableHeight`, otherwise the window is free to grow
to `availableHeight` = `max(visibleFrame.height, frame.height − 35)`. A menu that fits
is never artificially shortened to 70%.

**Which screen is read, and when it is re-read.** The height is taken from
`MenuWindowAlignment.effectiveScreen(for: window)` — the window's own screen first,
then a geometric intersection with the menu frame, then the screen under the cursor,
and only last `NSScreen.main`. `NSScreen.main` alone is unusable here: it follows
keyboard focus, so the cap would follow whichever window the user just clicked.
Re-application is likewise event-driven rather than observer-driven:
`viewDidMoveToWindow` recomputes on **every** menu appearance (the `MenuBarExtra`
popover reattaches the view each time the user opens the menu, and the bridge also
defers one `applyMaxSize()` to the next main-queue turn) and `updateTrackingAreas`
re-checks after a resolution or Dock change moves `visibleFrame`. No
`NSScreenDidChangeScreenParameters` observer is registered — it was removed in 8c6a97f
to avoid Swift 6 deinit-access-of-non-`Sendable`-token warnings, and it is not needed
because the popover reattaches on every screen change anyway. (The dock *does* observe
`NSApplication.didChangeScreenParametersNotification`; the menu does not.)

**Why 70%:** a full-screen (100%) menu looks crowded and, once scrollable, gets its
bottom rows covered by the Dock / status-bar icons. 70% leaves a 30% buffer so internal
scrolling never pushes content under the Dock, while the menu still reads as
"floating" rather than wall-to-wall — 0.85+ feels wall-to-wall, 0.5- trips the
`ScrollView` far too often.

The menu footer contains (right-aligned, separated by vertical hairlines):
- the autostart state icon (with help text)
- `设置` (opens native Settings window)
- `节能` (1-click keep-awake in-memory toggle; the icon flips `powersleep` →
  `cup.and.saucer.fill` and the label to `防休眠` while it is on, and the overlay dot
  reflects tri-color sleep health — immediately red when keep-awake is on)
- `日志` (reveals `log.txt` in Finder)
- `退出` (`NSApp.terminate`)

### Full Provider Detail Window

The quota page exposes “独立窗口” for each enabled provider. It opens the complete
`ProviderCardView` in one public SwiftUI `Window`, showing Account Info + Plan and the
seven-day history by default. The window's minimum width is derived from the
`.expanded` seven-day history table instead of the edge popover width:
`ProviderDetailWindowView.minimumWindowWidth` =
`SevenDayUsageChartMetrics.expandedTableWidth` (466pt) + `cardColumnHorizontalPadding`
× 2 + `cardContentPadding` × 2 = **514pt** (two padding layers: outer VStack + card
content). The previous 468pt (`EdgeDockTheme.popoverWidth`) left only 420pt of card
content and clipped the table's last column. `defaultSize` in `LLMMonitorApp` starts
the window at the same minimum width and **880pt** tall so both cards fit without
scrolling (the former 700pt default could not). The root frame is
`.frame(minWidth: minHeight: 420)` only — the `idealWidth`/`idealHeight` pair was
removed because macOS SwiftUI ideal sizing fights manual resizes, and `defaultSize`
already owns the initial size. Content stretches with the window: the `.expanded`
history table cells use `minWidth` floor + `maxWidth: .infinity` (column floors live
in `SevenDayUsageChartMetrics.expanded*`), and the quota-window table does the same
for its numeric/value/speed columns via the `quotaTableFillsWidth` environment key
(injected only here). Routes keep an optional notification model name as context only;
the card is not filtered or scrolled to that model. A disabled provider gets an
explanation and its settings entry; an unknown provider falls back to Notifications
settings. The pending route is in-memory only.

## Provider Card

`ProviderCardView` 的共享呈现入口按宿主选择：边缘状态窗 popover 使用 `edgePlan`
（Provider 标题 + scope + Account Info + Plan，不含 history）；独立详情窗口使用
`complete`（Account Info + Plan + history）；菜单分别使用 `plan` 与 `history`，两个
折叠区可同时展开。Plan 共用 `QuotaWindowAccountInfoRow` 与 `planModules`，history
共用 `SevenDayUsageHistoryView`，不复制业务模块。旧「菜单底部
provider 兜底行 hover 卡」宿主已随兜底行移除（8e7278a，见上文删除记录）。

**卡上两处时间戳统一为裸 "hh:mm"，点击按位置刷各自的数据（2026-10-13 引入，2026-10-18
拆分语义）**：headerContent 右侧的 `ProviderStateLabel` 与段3 标题行的
`LocalUsageFreshnessBadge` 都是裸 `HH:mm`（徽章去掉「更新于 」前缀，
`LocalUsageFreshnessState.content()` 随之删除前缀参数）。两个时间戳本来就是两种数据的
新鲜度，点击各刷各的，不再共用全量刷新：

- **额度时间戳与显式刷新按钮**（标题行，VoiceOver/help 明示「额度更新时间；点击立即刷新该 Provider」与「刷新 <Provider> 额度；仅重新读取此 provider」）：标题行右侧并排呈现 `ProviderStateLabel` 状态/时间戳胶囊与显式 `Image(systemName: "arrow.clockwise")` 刷新按钮（14×14pt 占位，`font(.system(size: 11, weight: .regular))`）。非 loading 态下点击时间胶囊或刷新按钮均经由环境键 `\.cardQuotaRefreshAction`（`((String) -> Void)?`，参数 `status.id`）触发 `AppState.refreshOne(providerID:)`，只重抓该 Provider 额度并重锚其排期；当处于抓取中（`status.isLoading == true`）时，刷新按钮自动切换为微型 `ProgressView()`（`.scaleEffect(0.55)`，14×14pt 占位），状态胶囊同步呈现相应加载态，防止重复触发；
- **用量时间戳**（段3 标题行，VoiceOver/help 明示「本地用量更新时间；点击重新扫描本地用量」）→ 环境键
  `\.cardUsageRefreshAction`（`(() -> Void)?`）→ `AppState.triggerLocalUsageRescan()`：
  只补拍一次本地用量 reconcile，不发额度请求、不动任何 provider 的排期；
- **状态栏锚定小眼睛**（窗口型 Provider 标题行刷新胶囊左侧，`eye.fill` / `eye.slash`）：经环境键
  `\.cardPinStatusBarAction`（`((String) -> Void)?`，参数 `status.id`）→
  `AppState.toggleStatusBarPinnedProvider(_:)`：单击选择该 Provider 的主套餐，再点同一卡片取消选择（置 `nil` 回到全 Provider 聚合）。
  `StatusBarQuotaSelector` 为菜单额度行与详情卡片共用控件；右键列出 `statusBarQuotaOptions`。
  主套餐额度组标题旁的 `StatusBarQuotaSourcePinButton` 一击选择 Provider 主套餐；重复点击保持所选，取消锚定仍由 Provider 行眼睛完成。ChatGPT 每个 API Key、
  GLM 每个生效中或待生效活动套餐的标题旁同一按钮一击选择对应独立额度池，已选项以实心眼睛标记。
  用 `setStatusBarQuotaSelection` 选择独立来源。详情卡经 `\.cardStatusBarQuotaOptions` /
  `\.cardSelectStatusBarQuota` 注入选项和动作。`selectedStatusBarSource` 参与卡片 Equatable，
  同 Provider 切换 Key / 权益时也会更新，菜单勾选与 help 指向具体来源。

在飞事务由 `beginExternalJob` 闸门合并，反馈交给既有状态胶囊自然变化。动作经环境键
传递（默认 `nil` = 无操作，只读渲染免注入）——`ProviderCardView` 是 `Equatable`
值语义视图，不能携带闭包存储属性。注入链路：唯一宿主 dock 浮层由
`EdgeDockController+Popover` 的 `popoverContent` 用 controller 经 `attach(state:)`
持有的 `AppState` 注入（浮层宿主是 `HoverPanelController` 自己的 NSHostingView，外层
环境进不来，只有随视图显式注入的键值能跨宿主存活，与 `\.hoverRevealMode` 同因）。
旧菜单 strip 的用量重扫与 hover 注入链路随 strip 移除而消失；当前额度页的单 Provider
刷新走 `MenuContentView.refreshProviderFromMenu`，仅刷新目标 Provider。卡片手势不进入
`ProviderStateLabel` 内部，dock 卡时间戳仍由宿主注入动作。

EnvironmentKey 的动作闭包采用 `@MainActor @Sendable` 类型：它们只由 UI 点击回调调用，
实际状态读写仍留在 MainActor；只读预览可继续使用 `nil` 缺省值。

`ProviderCardView` 是 thin coordinator，额度行、浮层、图表和账号详情按职责分文件维护；body 的派生值（投影 / 额度窗口快照 / 「今」行 / 「闲」行 / 「免 / 速 / 它」今日动态行）收在 `Views/ProviderCardDerived.swift` 的值键 memo 里（`Models/DerivedValueMemo.swift`），只有输入真的变了才重算：
- `QuotaViews.swift` — 所有 quota 行 / 进度条 / 重置卡 / `EquivalentQuotaAllocation`
- `QuotaWindowUsageViews.swift` — 「额度窗口用量」区块（包含「额度窗口」分析/用量可切换模块与「重置卡详情」模块，详见 `spec/ui/edge-dock.md` §Quota window usage block）
- `LocalUsageHoverViews.swift` — 本地历史数据新鲜度状态机与胶囊（`LocalUsageFreshnessState` / `LocalUsageFreshnessBadge`）；原 `LocalUsageChartDayMetrics`、`SevenDayTokenUsageHoverView`、`LocalUsageDayBar`、`LocalUsageLegendDot`、`LocalUsageFreshnessText` 与 `LocalUsageFooterView` 等 ~450 行死代码已在 M1 彻底清理
- `SevenDayUsageHistoryChart.swift` — 菜单、Provider 卡与 Settings 共用的 7 天多指标折线图
- `HoverPanel.swift` (386 行) — `HoverInfoRow` / `HoverPanelController` / 浮层管理
- 废弃图表与死代码清理：原 `QuotaHoverViews.swift`（曾保留注释的废弃明细浮层骨架）、`TokenChart.swift`（过时的 `StackedTokenBar` / `TokenBarSegment` / `TokenChartScale` 堆叠柱图原语）已在 M1 彻底删除；`HarnessUsageMenuView.swift` 中的 `FleetNodeGroupView`（曾为全宽节点行折叠组）亦随节点平铺展示设计彻底移除；`ProviderCardView.swift` 中的空 `ProviderCardLayout` 枚举一并清理

Visual structure:

```text
+-----------------------------------------------+
|  icon  display name              state capsule |
|  [account row]                                 |
|  Plan详情                                       |
|    <model metadata line>                       |
|    <progress bar>                              |
|  额度窗口（分析/用量 segment 切换）/ 重置卡详情   |
|  -------------------------------------------  |
|  最近7天使用历史             <freshness pill>  |
|  <chart + table>                               |
+-----------------------------------------------+
```

(In the complete detail window these are the two card titles, each drawn **outside and
above** its own card plate. The edge popover intentionally shows only the Plan card.)

Card styling:

| Property | Value |
|---|---|
| Background | `Color(NSColor.controlBackgroundColor).opacity(0.60)` — a system control底色, not a hand-picked translucent grey; the card is content, so it should not refract the host glass under it |
| Border | accent color at 25% opacity, 1pt (`strokeBorder`) |
| Corner radius | 12pt continuous |
| Left stripe | **不存在** — 曾是 3pt 圆角竖条，随宿主材质方案一起撤掉了 |
| Inner padding | `LayoutMetrics.cardContentPadding` (12pt) |

Accent color mapping:

| Accent | Color |
|---|---|
| `minimax` | purple |
| `chatgpt` | green |
| `antigravity` | blue |
| `glm` | `Color.glmBrand`（靛蓝，刻意区别于 Antigravity 的宝石蓝） |
| `custom` | gray |
| `deepseek` | cyan |

Row-level tint rules:

- minimax rows use a magenta brand tint
- ChatGPT rows use a green brand tint
- Antigravity uses blue for `Gemini Models` / `Gemini 4 Argon`
- Antigravity uses orange for `Claude and GPT models`（raw id `claude_and_gpt_models`）

## Card Header

| Element | Current behavior |
|---|---|
| Status dot | **不再画**。它紧挨着品牌图标，两个小圆读起来像"图标带了个绿点"，而同一行右侧的 `ProviderStateLabel` 已经把状态说清楚了。承载它的 `StatusIndicator` 视图已随之删除（那两处以它为参照的注释也改成了不依赖类型名的说法） |
| Provider icon | `BrandLogoView(kind:)` at its `defaultSize` (18pt); ChatGPT and GLM assets render as **templates** (they follow `Color.primaryLabel`, so both appearances stay readable), the rest keep their own colours, and a missing asset falls back to a per-brand SF Symbol at 0.72 × size |
| Display name | `MenuTypography.cardTitle` — **13pt bold**, `Color.primaryLabel`, single line, tail-truncated with a `.help` of the full name |
| Plan tag | **已从标题行移除**（2026-10 第二轮改版）。套餐 pill 挪进卡片第一段「Account Info」行（`QuotaWindowAccountInfoRow`），与账号名同一行——账号是谁、什么级别是同一个问题的两半 |
| State tag & Refresh button | compact `未配置` / `待更新` / `已更新` / `需重试` label (`ProviderStateLabel`)；紧邻其右侧为显式单 Provider 刷新按钮 `Image(systemName: "arrow.clockwise")`，在 `status.isLoading` 时切换为小型 `ProgressView()`（`.scaleEffect(0.55)`，14×14pt）旋转动画。时间戳胶囊本身亦保留点击刷新手势，形成双入口。`未配置` (not `未启用`): `.notConfigured` covers a missing API key, missing external auth and missing login as well as a disabled provider, and `未启用` made an enabled-but-keyless provider read as switched off |
| Account block hover | **已删除**。邮箱 / 数据来源原本按 provider 分三路包在标题行的 `HoverInfoRow` 里，只为菜单那张卡服务；菜单不再渲染 provider 卡，浮层又不吃鼠标事件，这个折叠区展不开，直接不画 |
| Seven-day usage history | 外层标题为「最近7天使用历史」，右侧新鲜度时间只在本机 scope 显示并可重扫。共享 `SevenDayUsageHistoryView` 用 7 个自然日槽位展示单指标折线；缺失日断线，今天标注未完结。8 个可选指标为总量、Rounds、价值、思考、产出、命中、TTFT、速度（2026-11-08 TTFT 插在命中与速度之间），默认总量；选择写入独立的 `@AppStorage("usageHistoryMetric")`，不随「额度窗口」分析/用量切换。速度按 Prompt 汇总为每日 P50；TTFT 按调用汇总为每日 P50（`LocalUsageTTFTByDay`，数值单位秒，Y 轴标签走 `Formatters.formatTTFT`）；比率指标 Y 轴按当前有效样本 min/max 自适应伸缩，刻度精度随跨度调整（如 49.8%–50.2% 不折叠为同一个 50%）；命中率和思考占比上限为 100%，产出比允许超过 100%。Fleet 使用当前 scope 的权威 `snapshot.daily`，无 Prompt 时长时速度显示 `—`，无本地样本时 TTFT 显示 `—`。 |

The metric picker renders a single-row capsule list: **总量 / Rounds / 价值 / 思考 / 产出 / 命中 / 速度**。
Total is Input + Cache + Output + Reason; cache-write tokens are excluded.
Rounds count tokenized API calls; Turns count distinct user prompts. The three rate metrics are:
- **思考** (thinking share): `reasoning / (output + reasoning)`
- **产出** (output-to-input ratio): `(output + reasoning) / (input + cacheRead)`
- **命中** (hit rate): `cacheRead / (input + cacheRead)`
The daily table consists of 6 base columns plus 1 selected dynamic column (always 7 columns):
- **Base columns**: `日期` (34pt), `R/T` (54pt, Rounds / Turns), `Input` (46pt), `Cache` (46pt), `Reason` (46pt), `Output` (46pt).
- **Dynamic column** (7th column, 58pt): mirrors whichever metric is currently selected in the chart (总量, Rounds, 价值, 思考, 产出, 命中, TTFT, 速度). Single-currency value keeps its currency, mixed currencies are converted to CNY using the existing mixed-currency rate, and incomplete pricing is marked partial. Speed is Prompt-level P50 per day; TTFT is call-level P50 per day via `Formatters.formatTTFT` (seconds); unavailable durations / samples remain `—`. Fleet uses its current-scope authoritative daily snapshot and has no prompt-duration data, so Fleet speed and TTFT stay `—`.

scope 切换**不在标题行**：选项 ≤4 时默认在标题行**下方**独占一行
（`ProviderCardView.scopeRow`，宽度与卡片一致）；dock 贴底边时该行移到详情内容末尾、靠近
dock。选项 >4 时才使用标题行里的紧凑下拉控件（状态胶囊左边）。分段控件单独占行，避免
把 provider 名挤成「minimax To…」。

状态点的配色（已连同视图删除）原为：healthy 绿 / warning 橙 / critical 红，
`nil` 健康度显示灰点；三档语义色本身由 `healthyTint` / `warningTint` /
`criticalTint` 提供（见 *Progress And Health Colors*）。

Bundled brand assets are used consistently in provider card headers and Settings navigation.
They cover Minimax, OpenAI, Antigravity, GLM, and DeepSeek; OpenCode has separate light
and dark assets because it is a shared local data source rather than a provider card.

## Card States

### Not Configured

Shown for missing config blocks, disabled providers, missing API keys, or missing external auth.

```text
doc.badge.gearshape
<reason>
前往设置启用并配置
```

Reasons currently produced by `AppState`:

| Reason | Cause |
|---|---|
| `未在 config.json 中配置` | provider block missing |
| `已在 config.json 中禁用` | `enabled == false` |
| `API Key 未填写` | API-key provider has empty/template key |
| `外部 auth 缺失：~/.codex/auth.json` | external-auth provider probe failed |
| `请先启动 Antigravity 并完成登录` | Antigravity / agy CLI 进程未发现或未监听本地端口 |

### Ready

Text:

```text
等待首次额度数据
```

This is a transient state. Opening the menu triggers `refreshAll()` if any provider is ready.

### Loading

If `state.lastSuccess` exists, the shared Plan presentation keeps the cached account and
quota modules visible, with the same full presentation used by the menu Plan disclosure.
The shared seven-day history remains in its own card for every state, so loading does not
switch back to a legacy chart or re-layout the history section.

If not, the shared Plan placeholder shows:

```text
正在获取套餐额度
```

The complete detail history remains independently visible; loading does not switch its
chart implementation or hide its empty/scanning state.

### OK

Shows `QuotaSummary(info:)`.

## Hover Panels

Hover details are implemented as a separate floating `NSPanel`, not a SwiftUI overlay clipped by the menu window.

Current behavior:

- show after 0.22s hover delay
- when the panel is already visible, switching to a neighboring row re-shows after a 0.08s debounce (`HoverPanel.swift` 的 `effectiveDelay`)
- anchor to mouse position
- keep a 6px cursor gap
- prefer mouse as top-left
- if the right side does not fit, flip to mouse-as-top-right
- if the bottom does not fit, clamp to the screen visible frame
- attach to the menu window via parent-child relationship

This is currently used for exactly one thing:

- the header's **sleep-blockers notice** (`SleepOffendersHoverView`, the same rows as
  Settings → Energy check 1) — hover-only, no click action

Everything else that used to hang off a hover panel is gone: the ChatGPT `Last Prompt`
summary, the merged `5h / 周` local-usage column, the quota-window detail views and the
per-card reset-credit list were all deleted with the menu's provider cards (reset credits
first became resident in the second-round pass, the rest lost their only host). Do not
look for a hover route to this data — the card carries it inline.

## Provider-Specific Card Details

### minimax

- 大部分模型（`general` / `image` / `speech` / `music` / `tts` 等）把 5h 和周额度合成一条，周进度条按 10 个等价额度分段（`ModelQuota.weeklyEquivalentMultiplier` = 10）。
- **`video` 模型走日窗口**：周进度条按 7 个等价额度分段（1 天 ≈ 1/7 周）。原因：minimax video 实际是日配额而不是 5h 配额，按 5h × 10 分段会误导。label 由 `QuotaSummary.primaryWindowLabel` 按 model 名判断。
- **`video` 不参与聚合读数**：状态栏 iconDuo（左右弧 / 中心百分比 / 底部三点）、边缘窗圆环与 provider 综合健康度走 `QuotaInfo.aggregateQuotaModels(providerKind:)`，`video` 被 `ModelQuota.isExcludedFromQuotaAggregation` 排除（与 antigravity 的 Claude and GPT / Gemini 4 Argon 组同规则）——独立小配额池的余量不代表主力模型水位；卡片 video 行照常展示，通知检测仍逐 model 覆盖。

### ChatGPT Plan

- 同时有 5h 和周额度时合并为一条，周进度条按 6 个等价额度分段（`weeklyEquivalentMultiplier` = 6）；接口只返回一个窗口时走单窗口路径，不虚构第二窗口。
- 账号行（第一段 Account Info）= 邮箱（`~/.codex/auth.json`）+ 套餐 pill（如 `Team`）；重置卡逐张清单常驻在「额度窗口用量」区块的重置卡模块里，不再挂 hover。清单（`ResetCreditsDetailList`）按到期日升序最多展示 4 张（`prefix(4)`），以两列等宽 × 至多两行的 `LazyVGrid` 行优先填充（左上 → 右上 → 左下 → 右下），对齐 GLM 重置卡块的半宽密度；每行日期格式 `MM-dd HH:mm`（与 GLM 对齐，不显示年份）+ 紧迫度圆点 + 相对倒计时。
- **多 Key API 赠金渲染（`ChatGPTApiCreditsRow`）**：支持配置多个 Codex / ChatGPT API Key，数据源自 `info.allOpenAIApiCredits`（`[OpenAIApiCreditDetails]`）。每个有效 Key 均在 Plan 模型行下方渲染为独立的赠金配额卡片行（多 Key 间以 `Divider().opacity(0.2)` 分隔）：
  - **首行标题与组织**：左侧展示 `API赠金 · <备注名称>`（未命名时显示 `API赠金 · USD`，`MenuTypography.hoverRowEmphasis`）；右侧居右展示所属组织名（未返回时显示 `未知组织`，`MenuTypography.dataLabel`，中间截断）；
  - **独立进度条**：使用 `SegmentedQuotaProgressBar` 单段展示（`segments: 1`，高度 8pt，色调 `.chatgptBrand`），根据剩余比例（`remainingPercent / 100.0`）及账单日剩余时间比例（`timeRemainingFraction(at: displayDate)`）动态呈现时间感知进度；
  - **已用/余量与重置倒计时**：次行左侧显示 `已用 <usedAmount> 剩余：<remainingAmount>/<totalQuota>`（金额为整数时隐藏小数位，如 `40`、`18.50`）；右侧显示周期重置时间 `周期至 MM-dd HH:mm（剩余 Xd / Xh / 已到期）`（倒计时由 `Formatters.formatRelativeCountdown` 格式化）；
  - **错误隔离与容错**：单 Key 抓取失败或降级显示上次成功数据时，倒计时左侧展示橙色警告图标 `Image(systemName: "exclamationmark.triangle")`，tooltip 悬停提示具体错误信息。多 Key 间并发请求且错误隔离，单 Key 失败不影响其他 Key 或主套餐的正常渲染与刷新；
  - 当无任何成功数据且存在全局错误时，退化展示单行错误提示文案。
- `Last Prompt` 摘要随菜单的 provider 卡一起删除，卡片里不再有这个入口；本地用量改由「额度窗口」模块（分析/用量可切换）与 7 天卡承担。

### Antigravity

- 卡片标题 = `Google Antigravity`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 登录邮箱（来自 `GetUserStatus`）+ 套餐 pill（`planLabel` 去掉 `Google ` / `Antigravity ` 前缀，让 `Google AI Pro` → `AI Pro`）。两者皆缺时整行不画。这是一行**常驻**内容：菜单的 provider 卡删除前，邮箱与套餐曾按 provider 分三路包在标题行的 `HoverInfoRow` 浮层里；那些折叠区挂在随行 hover 显隐的弹层里，弹层不在场时无从展开，所以直接画成常驻行——provider 卡退出菜单后也没有「重新进入 hover 浮层」这条路径了。
- `Gemini Models`、`Gemini 4 Argon` and `Claude and GPT models` are shown as separate model groups inside one provider card (display names align with the API-returned `displayName`).
- 双窗口组把 5h / 周收为一条：Gemini 周等效倍率为 4.0（2026-11-06 用户再次实测确认周额度 $120、5h $30，周容量精确为 5h 的 4 倍；按 4 个等容量整段展示，每段 25 点），Claude and GPT models 按 2 个（`weeklyEquivalentMultiplier` = 2，周窗口即 2 × 5h 额度，每段 50 点；2026-10-13 从 1 调回 2，2026-10 初曾从 3 下调到 1）；`Gemini 4 Argon` 在 Pro 套餐下仅返回周窗口，走单窗口路径。
- **`Claude and GPT models`（`claude_and_gpt_models`）与 `Gemini 4 Argon`（`gemini_argon`）不参与聚合读数**：状态栏 iconDuo、边缘窗圆环与 provider 综合健康度经 `QuotaInfo.aggregateQuotaModels(providerKind:)` 过滤，`ModelQuota.isExcludedFromQuotaAggregation` 把这两组排除（与 minimax `video` 同规则），只以主力 `Gemini Models` 代表聚合水位；卡片三组行照常展示，通知检测不受影响。
- The countdown suffix uses `Formatters.formatResetSuffix`'s compact ladder (e.g. `3h41m`), the same reset-suffix formatter every provider row shares.
- The countdown follows the model tint unless quota is low enough to trigger warning or critical colors.

### GLM Coding Plan

- 卡片标题 = `GLM Coding Plan`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 仅套餐档位 pill（`data.level` 首字母大写：`lite` → `Lite` / `Pro` / `Max`）。GLM 走 API Key 登录、拿不到邮箱，但**仅等级也显示账号行**；拿不到等级时整行不画。
- 单条 `GLM Coding Plan` 模型行（`QuotaInfo.displayName`，不再硬编码具体模型名）：智谱 Coding Plan 的 5h + 周积分是套餐共享池，合成一条展示，周进度条按 5 个等价额度分段（`weeklyEquivalentMultiplier` = 5；周积分 = 5 × 5h 积分：Lite 2000/10000、Pro 12000/60000、Max 28000/140000）。
- 数据来源：远程 `GET open.bigmodel.cn/api/monitor/usage/quota/limit`，Coding Plan Key 作裸 token 放 `Authorization`。鉴权失败（HTTP 200 + `code:1000`）在 parse 阶段捕获并映射成 401 语义。
- **高峰期提示**：额度行下方一行（`PeakIndicatorView` 外壳 + `GlmPeakIndicatorView` 的文案），纯本地计算（北京时间，与 API 无关）。颜色分 3 档：高峰期 🔥 红色 `高峰期 2× · 还剩 X`；非高峰期距高峰 < 1 小时 ❄️ 橙色、≥ 1 小时 ❄️ 绿色 `距高峰期 X`。**倍率只在偏离平时 1× 时标注**（2026-11-07 用户裁定）：高峰行显示当前 `peakWindow.multiplier`（未来可配置 5×），非高峰默认价不标注；未来若引入闲时折扣（免费 / 0.5×）才在闲时行标注。默认 Mon–Fri 14–18、倍率 2×（高峰全价、非高峰 50% 抵扣）；与 DeepSeek 统一支持 JSON 配置时段、工作日限制和倍率，设置页只读展示（见 `spec/ui/settings.md`）。倒计时读环境里的 `\.displayDate`——共享展示时钟 `DisplayClock`（每个宿主各持一个实例），由卡片实际所在的宿主各自注入并随面板显隐 start/stop：菜单内容（`MenuContentView` 内联，由 `MenuWindowAutoCloseBridge.onPanelOpen` 启动并同步当前墙钟、`onPanelClose` 停表）、菜单兜底行 hover 浮层（`HoverPanelController`）与 dock 浮层（`EdgeDockController`）都持有时钟、经 `DisplayClockScope` 注入环境；不需要自己挂 `TimelineView`。
- **卡片段落布局（与 ChatGPT 对齐四段式流式结构）**：
  1. **标准套餐额度**（`QuotaSummary`）：Coding Plan 5h & 周进度条与额度读数，卡片级高峰期倒计时夹在进度条下方；
  2. **活动套餐额度**（`GlmActivityPlanBalancesView`，仅在存在活动套餐余额或预告时渲染）：紧跟标准套餐之后，`Divider().opacity(0.3)` 分隔。生效中套餐渲染独立进度条（8pt 单段）、`已用 X · 剩余：Y/Z (pct%)` 与 `失效时间：MM-dd HH:mm（剩余X小时）`，失效倒计时紧迫度分级（`<=1h` 红色、`<=2h` 黄色、`>2h` 正常）；生效前预告行整体置灰弱化，进度条置灰底 0%，渲染 `额度：Z` 与 `生效时间：MM-dd HH:mm（X小时后生效）`；
  3. **额度窗口**（`QuotaWindowUsageSection.windowUsageModule`）：`quotaUsageDivider` 分隔，统一带有模块标题 `QuotaModuleTitle(text: "额度窗口")`、分析/用量分段切换器及两态共享骨架的网格（「分析」态 7 列、「用量」态 8 列，见 `spec/ui/edge-dock.md` §Detail Window Modules；行集 5h、周、今、闲、免、速、它）；
  4. **重置卡详情**（`QuotaWindowUsageSection.glmResetCardsModule`，在存在可用重置卡时渲染）：`moduleSeparator` 分隔，对齐 ChatGPT 标题规范带有 `QuotaModuleTitle(text: "重置卡详情")`；内容区双列展示 5 小时卡与周卡（`GlmResetCardsBlock`），左侧 `5小时重置卡 (N)`、右侧 `周重置卡 (N)`；每列最多展示前 3 张（`prefix(3)`），显示到期紧迫度彩色圆点（`CreditEntryRow.dotColor`：<=24h 红色、<=48h 黄色、>48h 绿色）、`MM-dd HH:mm` 及相对到期倒计时；若某列卡片为 0 张则显示 `暂无可用卡`；无任何可用重置卡时整块不渲染且不占卡片高度。

### Automatic local usage attribution

Supported local usage is attributed automatically through the built-in
client/provider routing registry. Native scanners stay with their provider; OpenCode,
ZCode, and DSH ledger slices are routed by registered provider IDs or aliases. This
mapping is not exposed as a user setting and is not read from or written to `config.json`.
Unknown provider IDs are left unattributed rather than guessed. Provider enable/disable
settings continue to govern provider activity independently of local usage routing.

| OpenCode provider ID | Quota card |
|---|---|
| `minimax-cn-coding-plan` | Minimax |
| `openai` | ChatGPT |
| `antigravity`, `google-antigravity`, `google-vertex`, `google` | Antigravity |
| `zhipuai-coding-plan` | GLM |
| `deepseek` | DeepSeek |

The aliases are kept in the built-in registry (`ClientProviderBinding.defaultBindings`);
the `UsageProjectionKernel` and `ProviderStatus.usageProjection` apply the mapping and
fold every matched contribution into its card. OpenCode rounds are tokenized assistant
messages. Turns are distinct user-prompt parents. The shared seven-day history chart
shows selectable Rounds, total, value, speed, hit rate, thinking share, and
output-to-input ratio trends.

ChatGPT's 5h / weekly summaries retain the preaggregated native Codex totals and add the
automatically attributed OpenCode contribution. The native samples already represented
by those totals are not added a second time; when native details are unavailable, the row
falls back to aggregating the available combined samples.

### Failed

The failed state uses the shared Plan presentation. When a cached `lastSuccess` exists,
its Account Info and Plan modules remain visible with the error; otherwise the shared
error placeholder is shown. The history card remains independent:

```text
<shared Account Info + Plan modules, if cached lastSuccess exists>
exclamationmark.triangle.fill  <error message>
<shared seven-day usage history>
```

The error message uses the critical tint, 10pt `MenuTypography.hint`, and is limited to 2 lines. Loading, failed, ready and
not-configured states use the same shared Plan rendering as the menu disclosure; the
history card stays mounted separately in all of them.

## Quota Summary

`QuotaSummary` contains:

1. One model block per `info.activeModels`, picked by three pure predicates:
   `shouldUseChatGPTPlanRow` (ChatGPT + `chatgpt_plan`) → `ChatGPTPlanModelRow`,
   `shouldUseDeepseekBalanceRow` (any DeepSeek model) → `DeepseekBalanceRow`, otherwise
   `CombinedQuotaWindowRow`. Each wraps its bar in a `ModelQuotaDockBlock`.
2. A `Divider().opacity(0.3)` between model blocks, none after the last one.
3. The card-level `betweenBarAndColumns` on the **first** model only — and if the model
   list is empty, it is drawn on its own, so the peak countdown can never vanish with
   the `ForEach`.

The current UI does not show a large primary remaining-number block. It prioritizes per-window reset timing. **Reset credits are no longer part of `QuotaSummary`** — since the 2026-10 second-round pass the collapsed row moved out of the progress bar's `between` slot (which now carries only the peak countdown) into the quota-window usage block's reset-credit module.

## Combined Quota Row

Implemented in `QuotaBarWithMetadata` (both the dual-window `CombinedQuotaMetadataLine` +
`CombinedQuotaBar` path and the single-window `SingleQuotaMetadataLine` + `SingleQuotaBar` path).

```text
<model display name>  5h <NN>%[(<NN>%有效)]  周 <NN>%        🕓 <reset date> (<countdown>)
[weekly progress bar, divided into N equivalent segments]
```

(the parenthesised suffix is drawn only when the weekly conversion binds — see
*Weekly-bottleneck suffix* below.)

**The multiplier N is not written anywhere on screen.** It used to be a `5h × N = 周`
caption in the title row (and a `周倍率：N` label); both are gone. N now only drives
(a) the number of segments in the progress bar and (b) the `min(5h, weekly × N)`
"actual available" caliber shared by the card's bar, the Icon Duo centre sector and the
menu bar aggregation. The reader infers it from the bar's segmentation and from the
tooltip below. The weekly-bottleneck suffix added in the 2026-10-04 pass does **not**
reintroduce N either: it prints the *effective percentage* (`(30%有效)`), a value the
reader can compare against the bar without knowing the conversion factor.

Model name:

- 11pt semibold (`MenuTypography.modelTitle`)
- `Color.primaryLabel`, tail-truncated; **not** the brand tint — see *字体统一规则* below

Quota summary line:

布局从「横向三段」改成「上下两行」：
- **Line 1**：元信息行（`model · 5h X%[(Y%有效)] 周 Y%` + 右侧 `clock reset-date (suffix)`，
  括号只在周瓶颈时出现，见 *Weekly-bottleneck suffix*）——
  先读说明再读图形，model 名就住在这行里（见 `spec/ui/edge-dock.md` §Two cards, titles outside）
- **Line 2**：进度条（**占满整行**）

| Part | Style |
|---|---|
| Progress bar | **整行宽**（跟随卡片内容宽度，即两个宿主共同的 **420pt**；不是旧主菜单的 312pt），8pt height，上下各留 3pt。首格为 `min(5h remaining, weekly remaining × N)`；若周额度更高，优先填满后续的整格单位，余数格跟随其后（容量为余数） |
| Data column | 双窗口 `5h X%  周 Y%` 使用 `quotaCombinedDataColumnWidth` 固定 **152pt** 宽，**显示周瓶颈括号时再加 `quotaCombinedEffectiveSuffixWidth`（56pt）= 208pt 档**；单窗口使用 `quotaSingleDataColumnWidth` 固定 **80pt** 宽。均右对齐，让 reset time 从一致的 x 位置开始。内部 per-percent 框保持 "5h" 和 "周" 列对齐。宽度是**定宽档**而不是自适应：同一张卡里显示括号的行共用 208pt、不显示的共用 152pt，各自成列，重置时间不会因为某一行的括号有无而左右乱跳 |
| Labels (`5h`, `周`) | 10pt semibold, secondary |
| Percent | 10pt semibold monospaced digit，每个用 40pt 固定右对齐宽（统一经 `Formatters.formatQuotaPercent` 格式化：至多一位小数，计算结果为整数则显示整数且绝不带 `.0`，如 `91.9%` / `92%` / `100%`） |
| Clock icon | `clock.arrow.circlepath`, 10pt semibold |
| Reset time | 紧跟在 data column 之后（不再用 Spacer 推右），跨行起始 x 一致。取 binding constraint 那一边的 reset：min(5h remaining, weekly remaining × N) 中较小那一边。如果 5h 较小，显示 5h reset；如果 wk × N 较小（5h 还有余量但 wk 撑死了），显示 wk reset——这种场景下 wk reset 才是用户真正等的时间（`EquivalentQuotaAllocation.bindingResetDate`）。两边都缺数据时显示 `—` |
| Reset 剩余时间 | reset date 之后括号内挂一个紧凑倒计时，由 `Formatters.formatResetSuffix` 输出。阶梯压缩：3d+ → `Xd`；1d+ → `XdXh`；5h+ → `Xh`；1h+ → `XhXXm`；否则 `Xm`。边界 inclusive（>=），避免 1d → "24h"、5h → "5h00m" 这种单位丢失。取值来源是宿主注入的展示时钟（`\.displayDate`，随浮层显隐起停）——`now` 为必填参数，不再是渲染时现取的墙钟 |
| Weekly-bottleneck suffix | 周折算构成瓶颈时，5h 数值之后并列一个 `(<N>%有效)`，见下节 |

**Weekly-bottleneck suffix（`(30%有效)`，2026-10-04 起）** —
`CombinedQuotaMetadataLine.quotaValue(…effectivePercent:)` 在 5h 数值右侧多挂一段括号
文字，标出这一行**实际还能用多少**。它解决的是同一行里条与字打架：分段条首格画的是
`min(5h, 周×N)`，而 `primaryPercent` 始终是**原始** 5h，所以周更紧时读者会看到
"条已经缩到 30%、文字还写着 `5h 100%`"（典型：ChatGPT 周只剩 5%、N=6；antigravity
Claude and GPT models 组 N=2）。括号把差额摆到明面上。

| Rule | Value |
|---|---|
| 显示条件 | `QuotaBarWithMetadata.weeklyBindingEffectivePercent(model:multiplier:)` 返回非 nil（`QuotaViews.swift:477`）——纯函数，双窗口以外一律 nil |
| 判定谓词 | **复用** `EquivalentQuotaAllocation.bindingWindow(...) == .weekly`（`SegmentedQuotaProgressBar.swift:316`）：周 × N **严格**小于 5h 才算周瓶颈，并列按同一约定落到 5h、不显示括号。这样括号出现与否与本行的分段条永远同源，不会条缩了文字没缩 |
| 括号值 | `EquivalentQuotaAllocation.effectivePrimaryFraction(...) × 100`（`SegmentedQuotaProgressBar.swift:292`），经 `Formatters.formatQuotaPercent` 格式化（至多一位小数、整数不带 `.0`，如 `30%` / `91.9%`） |
| 渲染 | `Text("(\(Formatters.formatQuotaPercent(effectivePercent))有效)")`，`MenuTypography.dataValue`（10pt semibold monospacedDigit），`Color.criticalTint`，`.fixedSize()`（`QuotaViews.swift:598-602`） |
| 颜色 | **告急同款红 `Color.criticalTint`**，不是 `.secondary` 灰：括号值是"周瓶颈下实际还能用多少"的告警数字，要在原始 5h 的绿色系旁边跳出来 |
| 宽度 | 数据列按上表走 152 → 152+56 两档，括号本身 `fixedSize` 不参与压缩 |
| 作用域 | 只对 5h（primary）那一格传非 nil；周数值（secondary）没有对应括号——它就是周窗口自己的原始剩余，没有被折算过 |

**菜单卡与 dock popover 共用同一个行视图**（`CombinedQuotaMetadataLine` 是 private
的，两处宿主渲染的是同一个 `QuotaBarWithMetadata`），所以括号在两处同步生效，不存在
"dock 有、菜单没有"的分叉。`QuotaViewsCopyTests` 钉住四个判定用例：周瓶颈
（5h 100% / 周 5% / N=6 → `30`）、周充裕、并列、单窗口（5h-only 与周-only 均 nil）。

**字体统一规则**：
- 标题行（model name / 重置卡数量）：11pt semibold
- 数据行（percent / reset time）：10pt semibold

model name 与重置卡数量用 `Color.primaryLabel` 而不是品牌色——**品牌色只进进度条**
（`SegmentedQuotaProgressBar.tint`）。一条彩色的文字躺在整行灰度数字中间会抢走整行的
读法。

**Hover tooltip（`QuotaBarTooltip.text(segments:hasTriangle:)`，挂在进度条上，
系统 `.help()`）**：

```
分段额度：
第 1 格为当前窗口余量；后续 <N-1> 格为等价周额度余量。顶部 ▼ 标记周重置时间进度（左侧即将重置，右侧刚重置）
```

单窗口（`N == 1`）换成「单一窗口可用进度」；`hasTriangle` 为 false 时（没有周重置
时间可标）整句省略三角说明。

> 设计原则:把"几何关系"（N 段 = 1 + N-1）和"时间标记 vs binding reset"（顶部 ▼ vs
> 主行）两类容易混淆的视觉/语义用 tooltip 说清。**binding constraint 本身不再解释**
> ——那两句 tooltip 曾挂在数据行的 `HoverInfoRow` 上，随菜单的 provider 卡一起删除，
> 现在读者只能从"主行 reset 落在 5h 还是周"自己读出结论。

## Progress And Health Colors

**The three health colors are tokens, not literals.** `Color.criticalTint`
(systemRed), `Color.warningTint` (systemOrange) and `Color.healthyTint` (systemGreen) in
`Color+Theme.swift` are the single definition, and the bar fill, the summary/reset
color, the `ProviderStateLabel` red capsule, the weekly-bottleneck `(N%有效)` suffix
and the reset-credit row's three tiers all read them. `systemRed` is the reason the critical tier needed a token too: SwiftUI's
`.red` is a **fixed** colour that does not follow the appearance, so on a light card it
stays the same hot red its dark-card contrast was chosen for, exactly the problem
`healthyTint` already had.

Provider 品牌色从 `Color+Theme.swift` 统一派发：MiniMax 品牌色已统一为亮紫 `#A855F7`（`Color(red: 0.66, green: 0.33, blue: 0.97)`），`Color.minimaxBrand` 与 `AccentColor.minimax.cardAccentColor` 保持单源，卡片描边、配额条健康态、窗口 Token 条与今日汇总客户端占比条完全一致。

分段配额进度条（`SegmentedQuotaProgressBar`）：
- **标准槽高**严格锁定为 `13pt`（`8pt` 条高 + `4pt` 顶部时间锚点三角 ▼ + `1pt` 间距），保持所有卡片行高稳定；
- **微栅格分段渲染（Hybrid Micro-Ticks，约 100 槽微栅格体系）**：整条以约 100 槽（96~100 点）为全满基准分辨率，基于「肉眼对色块宽度敏感、对微小间距不敏感」的设计哲学，每组模型按整除需求分配专属段点数（单窗口 100 点、2 段各 50 点、4 段各 25 点、5 段各 20 点、6 段各 16 点、7 段各 14 点、10 段各 10 点），彻底根除同卡片各段间点数不等或锯齿问题；色块宽度（`tickWidth`）固定为全局恒定值 `2.0pt`（Retina 2x 屏幕下物理对应整整 4px，圆角 `1.0pt`，呈饱满垂直胶囊状），绝对不因分段动态拉伸或压缩；扣除所有色块固定宽度与分段大间隙（`macroGap = 8.0pt`，相当于整整 2 根线槽位的清晰视觉分隔，段间:段内比率近 4x）后的全部剩余空白空间平分到段内块与块的微间距（`tickGap` $\approx 2.0\sim 2.2\text{pt}$，与色块宽度形成近乎 1:1 的黄金呼吸节奏）；当 `N > 1` 时，在第 0 段与第 1 段间隙正中绘制 `1.5pt` 宽、`10pt` 高的分界锚线（`Color.primary.opacity(0.28)`），直观区分当前 5h 窗口与未来周配额；
- **自适应栅格分配与点亮规则**：各段自适应栅格数（`ticksPerSegment(for:)`，单段 100、2 段各 50、4 段各 25、5 段各 20、6 段各 16、7 段各 14、10 段各 10；若遇非整数倍率则按容量权重分配并以 100 格为总基准）；点亮算法 `activeTickCount(fill:totalTicks:)` 采用 Half-Down 最近邻吸附（贴近最近刻度，遇到小数部分恰为 0.5 的中点平局时向小取整，保守估计余量，例如 10 格区间中 44.9% 与 45% 亮 4 格、45.1% 亮 5 格；16 格区间 50% 亮 8 格，46.875% 亮 7 格、47.0% 亮 8 格）；首段点亮栅格用 `intervalSegmentColor`（100% 不透明度），后续周段点亮栅格用 `weeklySegmentColor.opacity(0.68)`，底槽栅格用 `Color.primary.opacity(0.10)`。
- **时间感知与三角标记解耦**：双窗首格按有效 5h 余量 `min(primaryFraction, weeklyFraction × N)` 配 `primaryTimeRemainingFraction` 判色，周段按原始周余量配周时间。缺少 5h 重置时间时不借用周时间；单窗按自身余量和时间判色。统一 pacing 分母为 `100% * t`，默认 `< 30%` 红色、`< 60%` 黄色、其余品牌色。顶部时间锚点三角 ▼ 仅在长周期窗口（`>= 86400` 秒，如周配额）呈现，短窗口不显示三角。

Progress bar fill (`SegmentedQuotaProgressBar.intervalSegmentColor` /
`weeklySegmentColor` and `ModelQuota.colorLevel`):

| Remaining percent vs Pacing (分母 = 100% * t) | Health Level | Color |
|---|---|---|
| `< 30% * t` (或 percent <= 0，缺失 t 时 `< 30%`) | critical | `Color.criticalTint` |
| `< 60% * t` (缺失 t 时 `< 60%`) | warning | `Color.warningTint` |
| otherwise (包括 `t <= 0` 且 `percent > 0`) | healthy | provider/model tint |

DeepSeek API 账户余额健康度（`ProviderStatus.aggregateHealthLevel` / `AlertThresholdConfig`）：
- 余额 `< 3` 元（或 `<= 0`）：红色 `.critical`（默认 `deepseekBalanceCritical = 3.0`）
- 余额 `< 10` 元：黄色 `.warning`（默认 `deepseekBalanceWarning = 10.0`）
- 余额 `≥ 10` 元：绿色 `.healthy`

Reset time color (`summaryColor(for:timeFraction:)`):

| Remaining percent vs Pacing (分母 = 100% * t) | Color |
|---|---|
| `< 30% * t` (或 percent <= 0，缺失 t 时 `< 30%`) | `Color.criticalTint` |
| `< 60% * t` (缺失 t 时 `< 60%`) | `Color.warningTint` |
| `> 80%` (在 healthy 档位且绝对百分比高) | `Color.healthyTint` |
| otherwise (healthy 档位基线) | primary |

## Reset Credits

Since the 2026-10 second-round pass, reset credits live in one **resident module** at
the end of the quota-window usage block (see `spec/ui/edge-dock.md`
§Quota window usage block): the collapsed
row (`CompactResetCreditsRow`) followed by the per-card list. The module's single
visibility rule is **available count > 0**; zero available → the whole module is
omitted, not just the list. The old `ResetCreditsInfo.shouldDisplay` predicate that
expressed this was deleted — it was a second answer to a question the count already
answers, and two answers to one question is how they drift apart.

Collapsed row:

```text
arrow.counterclockwise.circle.fill  重置卡数量：N  [可能过期 · 上次更新 HH:mm]  🕓 MM-dd HH:mm
```

Row color (the icon + the count text together) — these are the semantic health
tokens, not literals, so all three tiers hold their contrast in both appearances:

| Available count | Color |
|---|---|
| `0` | `Color.criticalTint` (systemRed) |
| `1` | `Color.warningTint` (systemOrange) |
| `>= 2` | `Color.healthyTint` (systemGreen) |

Trailing reset date color (`CompactResetCreditsRow.expiryColor`，时钟图标与日期文本同步):
- `<= 24h`（或已过期）：`Color.criticalTint`
- `<= 48h`（且 `> 24h`）：`Color.warningTint`
- `> 48h` 或无到期日：`.secondary`

The per-card list (`ResetCreditsDetailList`) filters to `status == "available"` and sorts
by expiry ascending (entries with no expiry last, then by id for stability).
Each row's 5pt dot (`CreditEntryRow.dotColor`) and relative time text (`CreditEntryRow.relativeTextColor`)
dynamically indicate expiry urgency:

| Expiry time remaining | Dot Color (`dotColor`) | Relative Text Color (`relativeTextColor`) |
|---|---|---|
| `<= 24h` (或已过期) | `Color.criticalTint` (systemRed) | `Color.criticalTint` |
| `<= 48h` (且 `> 24h`) | `Color.warningTint` (systemOrange) | `Color.warningTint` |
| `> 48h` | `Color.healthyTint` (systemGreen) | `.secondary` |
| 未知到期日 (`nil`) | `.secondary` | `.secondary`（文案为「过期时间未知」并带 `.tertiary`） |

```text
●  2026-10-30 09:00  约 3 天 4 小时 后
●  过期时间未知
```

The UI intentionally hides reset-credit id, title, description, and grant time.

## Typography

| Element | Font |
|---|---|
| Header title (`MenuTypography.headerTitle`) | 13pt semibold |
| Header action glyphs — scope 切换标记 / 刷新图标 (`MenuTypography.headerAction`) | 11pt medium |
| Card / provider title (`MenuTypography.cardTitle`) | 13pt bold |
| Provider icon | not text — the bundled brand asset at 18pt (`BrandLogoView.defaultSize`) |
| Model name (`MenuTypography.modelTitle`) | 11pt semibold |
| Window label `5h` / `周` (`MenuTypography.dataLabel`) | 10pt semibold |
| Window percent / weekly-bottleneck `(N%有效)` (`MenuTypography.dataValue`) | 10pt semibold monospaced digit |
| Reset time (`MenuTypography.resetDate`) | 10pt semibold monospaced digit |
| Reset countdown suffix (`MenuTypography.timeSuffix`) | 10pt medium monospaced digit |
| Plan pill (`MenuTypography.pill`) / state & count capsules (`MenuTypography.badge`) | 9pt semibold |
| Quota-table body (`MenuTypography.metricValue`) | 10pt medium monospaced digit |
| Table headers / module titles (`MenuTypography.metricLabel` / `QuotaModuleTitle`) | 10pt (semibold for module titles) |
| Error message (`MenuTypography.hint`) | 10pt |
| Footer text/buttons (`MenuTypography.footer`) | 9pt medium |

The shared Plan fallback uses the same 10pt `MenuTypography.hint` role for loading and
failure feedback; there is no separate error-message typography role.

> 核对基线：2026-11-10 · 代码 1d06cb4
