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

The `iconDuo` dashboard (`IconDuoSVGBuilder`) uses a left 5h arc and right weekly arc, both being concentric
circular arcs growing from the bottom with dark gray background tracks and health-colored
available segments (a missing window keeps only its gray track). The center uses the minimum
actual available ratio across active models — per model, `min(5h remaining, weekly remaining × N)`
with the provider-specific weekly equivalent multiplier N (`ModelQuota.weeklyEquivalentMultiplier`,
the same caliber as the card's segmented progress bar); a model with only one window contributes
just that window (weekly-only models contribute weekly × N, clamped to 1.0), and the center stays
nil when no model has any window. It is a symmetrical circular sector anchored at the top (12 o'clock)
that opens left and right from the bottom (6 o'clock) as quota depletes (full 360° circle at 100%,
180° dome semicircle at 50%, empty red ring at 0%; there is no numeric label). Three bottom dots (enlarged to r=36) follow
the circle's arc to show active-model health prioritized strictly as red > yellow > green (if 3 reds,
yellow and green are omitted); the top dot (enlarged to r=48) mirrors the Energy module's sleep-health state (green / yellow / red, gray while unknown).
The popover window top edge is snapped to `screen.visibleFrame.maxY + 10` on every presentation, absorbing popover margins to stay flush
with the bottom edge of the macOS menu bar.
All `iconDuo` red/yellow/green decisions — the three bottom dots, both arcs, and the
center sector — go through the time-aware `ModelQuota.colorLevel` thresholds (`< 20% * t` red;
`< 50% * t` yellow; otherwise green, with dynamic denominator `100% * t`),
the same rule the provider cards use, replacing the retired fixed `HealthLevel.standard`
thresholds. Composite elements (the bottom dots and the center sector) read the
"actual available" caliber — per model `min(5h, weekly × N)` via
`ModelQuota.aggregateActualAvailable` / `aggregateHealthLevel` — while the left/right
arcs keep their raw per-window averages (both short and weekly arcs use the widest remaining-time
fraction across models for their dynamic thresholds). During GLM peak hours a peak
floor raises a provider's composite status to at least `.warning` (red wins); the floor
only applies to the iconDuo bottom dots and the card header dots — arcs and the center
sector are exempt.

**聚合 model 集合排除独立小池（2026-10 用户裁定）。** iconDuo 的四个读数（左右弧、
中心扇形、底部三点）与 SF Symbol 状态点 / 边缘窗圆环 / provider 综合健康度读的都是
`QuotaInfo.aggregateQuotaModels(providerKind:)` —— `activeModels` 再滤掉
`ModelQuota.isExcludedFromQuotaAggregation(providerKind:)` 命中的家族：minimax 的
`video`（视频生成）与 antigravity 的 `claude_and_gpt_models`（Claude and GPT models）、
`gemini_argon`（Gemini 4 Argon）。
它们都是与主力模型无关的独立配额池，计入最差值聚合只会让无关池子的余量稀释（或拖垮）
一个用户无从 action 的读数。滤后为空时回退 `activeModels`（排除只允许「少算」，不允许
把有数据的 provider 聚合成「无读数」或保守误红）。卡片逐 model 行与通知管线
（`QuotaEventDetector` 逐 model 窗口事件）不受影响。

**Center sector relay semantics.** The center sector takes the *lowest* "actually
available" ratio across plans, but a plan whose value is exactly 0 is excluded from that
comparison. This models plan hand-off: once a plan is spent, it would otherwise pin the
ring to 0 and hide the plan now serving you, so the ring follows the one still in
service (its `timeFraction` follows with it, keeping the yellow line consistent with the
displayed plan). Boundaries are distinguished deliberately: readings exist but every
plan is exhausted → `0` (red empty ring, `timeFraction` nil since `colorLevel` treats 0%
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
|   今日 Token: 820K  价值: ¥10  命中率: 62%  速度: P50 205 tok/s |
|   gpt-5.5                         620K tokens   |   expanded model details use compact rows
|     min ───── ● ─── max   P50 … 最近 … tok/s     |
| ⚠ 会话文件超出单轮扫描预算，已按最新优先截断…   |   truncation notice (that section only)
| ...                                            |
+------------------------------------------------+
| 更新于 HH:mm / 下次 HH:mm / 就绪   ⏻ 自启 | 设置 | 节能 | ⋯ |
+------------------------------------------------+
```

额度页按启用 provider 顺序呈现与用量相同的紧凑卡片外壳，支持单 Provider 刷新、未配置项定位到
对应设置，以及可展开的 Plan 详情；折叠行目标为两行：首行左侧 Provider 名称与临期/高峰事件，
右侧额度更新时间贴近刷新按钮；次行是额度摘要、展开/收起按钮与独立窗口入口。正常状态不再另占更新时间行或详情页脚；
更新时间仅显示 `HH:mm`，help 说明它代表 provider 额度读取时间，刷新动作只刷新该 Provider。
窗口摘要在 5h 与周余量后分别显示对应瓶颈模型的重置倒计时（未知显示「重置时间未知」，已到期显示「待更新」）；详情保留完整重置时间。
重置卡在现有 48h / 24h 紧迫度分档下进入摘要首行（橙 / 红）；GLM 与 DeepSeek 仅在既有高峰规则判断为临近或正在高峰时显示事件。
loading、failed、notConfigured 可按需增加状态行，错误始终可见。DeepSeek 即使没有窗口额度也显示余额。
额度始终使用本机优先、必要时 elected 的全局有效值。菜单顶部 scope 仅切换用量；
多节点额度页会标明当前用量范围与额度仍为全局有效值。内容高度由当前页实测，
超过屏幕预算时内容区滚动，标题和 footer 保持固定。

（footer 右侧功能组竖线分隔，自启为状态化图标按钮；日志与退出收进「更多操作」。）

The menu offers two complementary views: **用量** answers which clients burned how
many tokens today, and **额度** answers how much remains per enabled Provider. The
quota page is available when the edge dock is hidden. Expanding 套餐详情 embeds the
same `ProviderCardView.planModules` composition as the edge-dock popover and standalone
detail window: provider progress and specific modules, quota-window analysis/usage
switcher, and reset-card details. It deliberately omits Account Info and the seven-day
local usage card. The collapsed row keeps a separate “独立窗口” action for the complete
provider view. Fleet effective quota remains independent from scope; quota-window usage
modules continue to follow the selected fleet scope. Loading and failure states preserve
last-success Plan data and retain visible status feedback.

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

**Header right group** (scope switcher + usage freshness + refresh): the scope
dropdown sits next to the refresh button, both right-aligned as one group; 本地用量
的裸刷新时间（`LocalUsageFreshnessText`，见下文 Global freshness）在两者之间——
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
  （`FleetClientSectionView`）；节点 scope 的段头**没有**右键刷新。
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
  - 核心数值区下方是**客户端占比条**（`HarnessClientProportionBar`，2026-10 起，取代原全局 input / cacheRead / output 三段条；模型行现以 Prompt 速度范围线呈现分布）+ 一行图例（`HarnessClientLegend`）：
    - 占比条**一段一个今天有 token 活动的 harness**（`HarnessTodaySummary.clientSegments(from:)` 按 `sections` 既有的 token 降序输出、零段过滤），段宽 = 该客户端今日 token 占全部客户端的比例；
    - **段色 = 主力 provider 的卡 accent 色**：客户端横跨多个 provider 分片时（ZCode / DSH / OpenCode）取今日 token 最大的一路，并列取 quotaProviderID 字典序小者（`HarnessClientSegment.dominantQuotaProviderID`）。色值经 `AccentColor.cardAccentColor`（`Color+Theme.swift`，与 provider 卡描边 / 进度条健康态同源；minimax 亮紫 `#A855F7` / chatgpt 绿 / antigravity 蓝 / glm 靛蓝 / deepseek 青），未知 / 缺失的 providerID 回退灰；
    - 归一化口径与 `TokenBucketBar` 一致：负值按 0、Double 累加分母、总量 ≤ 0 全 0（纯灰底），不产生 NaN；条高沿用 `TokenBucketBar.standardHeight`（7pt）；每段挂 `.help`：「MiniMax Code 355M（77%）」；
    - **图例**把颜色翻译回客户端并直观标注量级：`<着色图标> MiniMax Code 355M  <着色图标> Codex 120M …`。图标取 `ClientDescriptor.iconSystemName(forClientID:)`，着色即段色，紧随其后展示该客户端紧凑 Token 读数；hover 上仍挂「MiniMax Code 355M（77%）」完整 tooltip。chip 超出行宽**换行**（`WrapLayout`）而不是截断；段列表为空（今日无活动）时条只剩灰底、图例整行不画。
- **Per-client sections**, ordered by today-token descending and collapsed by
  default; the disclosure header follows the quota-card two-line shape: client name,
  latest local usage scan time (`HH:mm`), and disclosure control on line one; line two shows
  `今日 Token`、`价值`、`命中率` and prompt-speed P50. `思考` is inserted between hit
  rate and speed only when `ViewThatFits` confirms the complete summary fits; reasoning
  is a share of `output + reasoning`, never added to output a second time. A client with no
  today activity is dropped entirely rather than shown as an empty section. Each
  section subtotal and value. The value is a `MixedCurrencyEstimate`, because one
  client may span several provider slices (OpenCode / DSH / ZCode) and currencies.
  The scan time is the latest local usage scan time for the summary; Fleet client
  sections have no local scan time and do not fabricate one.
- **Per-model rows inside an expanded section**, keyed by
  `(clientID, quotaProviderID, modelName)`; samples with no usable model name
  collapse into a single 「模型名缺失」 row. Each row is a compact block:
  model name + token total; prompt-speed range line (min/max endpoints, P50 marker,
  recent prompt marker) with min/P50/max/recent values and valid/total prompt count;
  then labeled cache-hit percentage and value. Every local model range uses the same
  menu-wide speed scale. Single-value and zero-value markers have vertical offsets so
  coincident readings remain distinguishable; missing or non-finite readings show `—`.
  Fleet client sections use the same compact card summary and disclosure interaction;
  without local call durations they display speed `—`, including expanded Fleet model
  rows, and never draw a fabricated range. The row value is the **single-provider,
  single-currency** original amount (`ModelCostEstimate.displayText`: `¥3.21` /
  `$9.80` / `未定价`) — cross currency folding happens only at section and global
  level, never per row. Prompt speed is `Σ(Output+Reason) ÷ Σ call duration` over
  all calls in one prompt. A prompt joins the distribution only when all call
  durations are valid; `latest` is the newest prompt and is `—` when that newest
  prompt is incomplete (never an older fallback). Rows include valid/total prompt
  counts so exclusions remain visible. The client summary P50 is calculated from
  all of that client's daily prompts, not by averaging model-row percentiles. The
  global summary row carries no speed — the rate is a per-client/per-model metric.

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

**Global freshness (bare time)** — 本地用量的新鲜度时间（`LocalUsageFreshnessText`，
裸文本：任一启用数据源在扫时「计算中…」带 mini spinner（卡级
`effectiveLocalUsageFreshness`，"扫描 > 失败 > 脏 > 干净"取最差），否则各卡最新
`scannedAt` 的裸时钟 `HH:mm`（跨天退化 `MM-dd HH:mm`））**渲染在标题栏右组、
刷新按钮左边**（`MenuContentView.headerBar`，2026-10 从「今日合计」数字行尾部
挪来）。它是**全局**读数、与 scope 无关，放标题栏后三个 scope 的总览数字行不再
各自带时间；数字行收在混币价值上，宽度预算测试相应去掉了时间格。两个值都在
`HarnessTodaySummary.summarize` 里算一次（`localUsageScannedAt` /
`isScanningLocalUsage`），headerBar 与总览卡读同一份缓存，视图不自己走 `statuses`。
它是 `LocalUsageFreshnessBadge` 的**裸文本变体**（同一状态机、同样 `.secondary`
灰、无胶囊底——2026-10-13 起徽章也去掉了「更新于」前缀，两种皮肤渲染同一个裸
时钟）：两种皮肤共享同一个 `LocalUsageFreshnessState`（internal，状态级测试可直接
钉裸时钟），状态判定与时钟文案（含跨天退化）只写一份、仅包装不同。从未扫描过时
裸时间整体不渲染（无占位、无幻影空格）。胶囊变体的宿主只剩 dock 浮层 7 天卡
标题（菜单 strip hover 宿主已随兜底行移除）。

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
live here too; it moved to the menu-bar icon's right-click menu, whose entries distinguish
「打开设置…」 from 「打开配置文件」. The Settings entry uses a hosted public SwiftUI `SettingsLink`.
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
(`Views/MenuContentView.swift:540-570`，`HeightProbeView` 定义在同文件 `:515`). `cappedHeight(_:)` and `heightCapFraction`
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

The menu footer contains:
- the autostart state icon (with help text)
- refresh status (`更新于 HH:mm` / `下次 HH:mm` / `就绪`)
- `设置` (opens native Settings window)
- `节能` (1-click keep-awake in-memory toggle; the icon flips `powersleep` →
  `cup.and.saucer.fill` and the label to `防休眠` while it is on, and the overlay dot
  reflects tri-color sleep health — immediately red when keep-awake is on)
- `更多操作` menu containing `日志` (reveals `log.txt` in Finder) and `退出`
  (`NSApp.terminate`)

### Full Provider Detail Window

The quota page exposes “独立窗口” for each enabled provider. It opens the same
`ProviderCardView` in one public SwiftUI `Window`, so all provider-specific sections
remain reachable even when the edge dock is hidden. The window width follows
`EdgeDockTheme.popoverWidth` (468pt at the current 420pt chart width, including card
and host padding). Routes keep an optional notification model name as context only;
the card is not filtered or scrolled to that model. A disabled provider gets an
explanation and its settings entry; an unknown provider falls back to Notifications
settings. The pending route is in-memory only.

## Provider Card

`ProviderCardView` 完整卡片的渲染宿主是边缘状态窗的 provider 详情浮层（固定
`.alwaysVisible`）及独立详情窗口；菜单额度行只启用 Plan-only 模式，复用同一
`planModules`，不复制额度模块实现，也不承载完整 provider 卡。旧「菜单底部
provider 兜底行 hover 卡」宿主已随兜底行移除（8e7278a，见上文删除记录）。

**卡上两处时间戳统一为裸 "hh:mm"，点击按位置刷各自的数据（2026-10-13 引入，2026-10-18
拆分语义）**：headerContent 右侧的 `ProviderStateLabel` 与段3 标题行的
`LocalUsageFreshnessBadge` 都是裸 `HH:mm`（徽章去掉「更新于 」前缀，
`LocalUsageFreshnessState.content()` 随之删除前缀参数）。两个时间戳本来就是两种数据的
新鲜度，点击各刷各的，不再共用全量刷新：

- **额度时间戳**（标题行胶囊，VoiceOver/help 明示「额度更新时间；点击立即刷新该 Provider」）→ 环境键
  `\.cardQuotaRefreshAction`（`((String) -> Void)?`，参数 `status.id`）→
  `AppState.refreshOne(providerID:)`：只重抓这张卡的额度并只重锚它自己的排期；
- **用量时间戳**（段3 标题行，VoiceOver/help 明示「本地用量更新时间；点击重新扫描本地用量」）→ 环境键
  `\.cardUsageRefreshAction`（`(() -> Void)?`）→ `AppState.triggerLocalUsageRescan()`：
  只补拍一次本地用量 reconcile，不发额度请求、不动任何 provider 的排期；
- **状态栏锚定小眼睛**（窗口型 Provider 标题行刷新胶囊左侧，`eye.fill` / `eye.slash`）：经环境键
  `\.cardPinStatusBarAction`（`((String) -> Void)?`，参数 `status.id`）→
  `AppState.toggleStatusBarPinnedProvider(_:)`：单选勾选将该服务商写入 `config.statusBarPinnedProvider`
  （状态栏双环与健康点独占展示该服务商指标），再点同一卡片取消锚定（置 `nil` 回退全 Provider 聚合）。

在飞事务由 `beginExternalJob` 闸门合并，反馈交给既有状态胶囊自然变化。动作经环境键
传递（默认 `nil` = 无操作，只读渲染免注入）——`ProviderCardView` 是 `Equatable`
值语义视图，不能携带闭包存储属性。注入链路：唯一宿主 dock 浮层由
`EdgeDockController+Popover` 的 `popoverContent` 用 controller 经 `attach(state:)`
持有的 `AppState` 注入（浮层宿主是 `HoverPanelController` 自己的 NSHostingView，外层
环境进不来，只有随视图显式注入的键值能跨宿主存活，与 `\.hoverRevealMode` 同因）。
旧菜单 strip 的用量重扫与 hover 注入链路随 strip 移除而消失；当前额度页的单 Provider
刷新走 `MenuContentView.refreshProviderFromMenu`，仅刷新目标 Provider。卡片手势不进入
`ProviderStateLabel` 内部，dock 卡时间戳仍由宿主注入动作。

`ProviderCardView` 是 thin coordinator，额度行、浮层、图表和账号详情按职责分文件维护；body 的派生值（投影 / 额度窗口快照 / 「今」行 / 「闲」行 / 「免 / 速 / 它」今日动态行）收在 `Views/ProviderCardDerived.swift` 的值键 memo 里（`Models/DerivedValueMemo.swift`），只有输入真的变了才重算：
- `QuotaViews.swift` — 所有 quota 行 / 进度条 / 重置卡 / `EquivalentQuotaAllocation`
- `QuotaWindowUsageViews.swift` — 「额度窗口用量」区块（包含「额度窗口」分析/用量可切换模块与「重置卡详情」模块，详见 `spec/ui/edge-dock.md` §Quota window usage block）
- `LocalUsageHoverViews.swift` — 7 天本地用量卡与 `LocalUsageFreshnessBadge` / `LocalUsageFreshnessText`
- `HoverPanel.swift` (386 行) — `HoverInfoRow` / `HoverPanelController` / 浮层管理
- `TokenChart.swift` (40 行) — 7-day 柱图基础组件
- `QuotaHoverViews.swift` — 已空，只留删除记录注释：`UsageMetricHoverSummaryView` 随其唯一宿主 GLM 闲时脚注一并删除（脚注内容并入「额度窗口」表格「闲」行），额度窗口 hover 明细族则早已随 `menuLayout` 删除

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
|  最近7天token用量            <freshness pill>  |
|  <chart + table>                               |
+-----------------------------------------------+
```

(The two `最近7天token用量` rows are the two card titles, each drawn **outside and
above** its own card plate — see `spec/ui/edge-dock.md` §Two cards, titles outside.)

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
| State tag | compact `未配置` / `待更新` / `已更新` / `需重试` label; a spinner replaces it while loading. `未配置` (not `未启用`): `.notConfigured` covers a missing API key, missing external auth and missing login as well as a disabled provider, and `未启用` made an enabled-but-keyless provider read as switched off |
| Account block hover | **已删除**。邮箱 / 数据来源原本按 provider 分三路包在标题行的 `HoverInfoRow` 里，只为菜单那张卡服务；菜单不再渲染 provider 卡，浮层又不吃鼠标事件，这个折叠区展不开，直接不画 |
| Seven-day local statistics | 不在标题行，在**本地用量那一段**（`LocalUsageFooterView` → `SevenDayTokenUsageHoverView`）：`.alwaysVisible` 下就地展开成第二张卡的内容，`.onHover` 下才是悬停弹层。逐日表末列在 provider 卡路径**跟随「额度窗口」的 分析/用量 segment**（`lastColumnFollowsSegment: true` + `@AppStorage(quotaWindowUsageSegment)`）：分析态显示 价值（现状渲染），用量态显示 速度（`LocalUsageSpeedByDay` 按 `startOfDay(completedAt)` 分组逐日 `windowTokenRate`，文案 `speedText`，单日无有效时长 `—`，无样本不画列；两列同宽 62pt 切换零回流）。Settings 客户端页与 fleet 路径保持默认参数：永远价值列，不受 segment 影响 |

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
准备就绪…
```

This is a transient state. Opening the menu triggers `refreshAll()` if any provider is ready.

### Loading

If `state.lastSuccess` exists, the card shows the cached form of the same three
sections the `.ok` path renders — account row, `QuotaSummary` at 50% opacity, the
resident usage block, the 7-day chart — so the brief mid-refresh flash does not
re-layout the popover.

If not, it shows:

```text
正在获取…
```

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
- **`video` 不参与聚合读数**：状态栏 iconDuo（左右弧 / 中心扇形 / 底部三点）、边缘窗圆环与 provider 综合健康度走 `QuotaInfo.aggregateQuotaModels(providerKind:)`，`video` 被 `ModelQuota.isExcludedFromQuotaAggregation` 排除（与 antigravity 的 Claude and GPT / Gemini 4 Argon 组同规则）——独立小配额池的余量不代表主力模型水位；卡片 video 行照常展示，通知检测仍逐 model 覆盖。

### ChatGPT Plan

- 同时有 5h 和周额度时合并为一条，周进度条按 6 个等价额度分段（`weeklyEquivalentMultiplier` = 6）；接口只返回一个窗口时走单窗口路径，不虚构第二窗口。
- 账号行（第一段 Account Info）= 邮箱（`~/.codex/auth.json`）+ 套餐 pill（如 `Team`）；重置卡逐张清单常驻在「额度窗口用量」区块的重置卡模块里，不再挂 hover。
- `Last Prompt` 摘要随菜单的 provider 卡一起删除，卡片里不再有这个入口；本地用量改由「额度窗口」模块（分析/用量可切换）与 7 天卡承担。

### Antigravity

- 卡片标题 = `Google Antigravity`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 登录邮箱（来自 `GetUserStatus`）+ 套餐 pill（`planLabel` 去掉 `Google ` / `Antigravity ` 前缀，让 `Google AI Pro` → `AI Pro`）。两者皆缺时整行不画。这是一行**常驻**内容：菜单的 provider 卡删除前，邮箱与套餐曾按 provider 分三路包在标题行的 `HoverInfoRow` 浮层里；那些折叠区挂在随行 hover 显隐的弹层里，弹层不在场时无从展开，所以直接画成常驻行——provider 卡退出菜单后也没有「重新进入 hover 浮层」这条路径了。
- `Gemini Models`、`Gemini 4 Argon` and `Claude and GPT models` are shown as separate model groups inside one provider card (display names align with the API-returned `displayName`).
- 双窗口组把 5h / 周收为一条：Gemini 按 6 个等价额度分段，Claude and GPT models 按 2 个（`weeklyEquivalentMultiplier` = 6 / 2，周窗口即 2 × 5h 额度；2026-10-13 从 1 调回 2，2026-10 初曾从 3 下调到 1）；`Gemini 4 Argon` 在 Pro 套餐下仅返回周窗口，走单窗口路径。
- **`Claude and GPT models`（`claude_and_gpt_models`）与 `Gemini 4 Argon`（`gemini_argon`）不参与聚合读数**：状态栏 iconDuo、边缘窗圆环与 provider 综合健康度经 `QuotaInfo.aggregateQuotaModels(providerKind:)` 过滤，`ModelQuota.isExcludedFromQuotaAggregation` 把这两组排除（与 minimax `video` 同规则），只以主力 `Gemini Models` 代表聚合水位；卡片三组行照常展示，通知检测不受影响。
- The countdown suffix uses `Formatters.formatResetSuffix`'s compact ladder (e.g. `3h41m`), the same reset-suffix formatter every provider row shares.
- The countdown follows the model tint unless quota is low enough to trigger warning or critical colors.

### GLM Coding Plan

- 卡片标题 = `GLM Coding Plan`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 仅套餐档位 pill（`data.level` 首字母大写：`lite` → `Lite` / `Pro` / `Max`）。GLM 走 API Key 登录、拿不到邮箱，但**仅等级也显示账号行**；拿不到等级时整行不画。
- 单条 `GLM Coding Plan` 模型行（`QuotaInfo.displayName`，不再硬编码具体模型名）：智谱 Coding Plan 的 5h + 周积分是套餐共享池，合成一条展示，周进度条按 5 个等价额度分段（`weeklyEquivalentMultiplier` = 5；周积分 = 5 × 5h 积分：Lite 2000/10000、Pro 12000/60000、Max 28000/140000）。
- 数据来源：远程 `GET open.bigmodel.cn/api/monitor/usage/quota/limit`，Coding Plan Key 作裸 token 放 `Authorization`。鉴权失败（HTTP 200 + `code:1000`）在 parse 阶段捕获并映射成 401 语义。
- **高峰期提示**：额度行下方一行（`PeakIndicatorView` 外壳 + `GlmPeakIndicatorView` 的文案），纯本地计算（北京时间，与 API 无关）。颜色分 3 档：高峰期 🔥 红色 `高峰期 · 还剩 X`；非高峰期距高峰 < 1 小时 ❄️ 橙色、≥ 1 小时 ❄️ 绿色 `距高峰期 X · 非高峰 5 折`。Mon–Fri 14–18（官方规则：高峰全价、非高峰 50% 折），窗口固定不可调（北京时间、法定节假日除外，设置页只读展示，见 `spec/ui/settings.md`）。倒计时读环境里的 `\.displayDate`——共享展示时钟 `DisplayClock`（每个宿主各持一个实例），由卡片实际所在的宿主各自注入并随面板显隐 start/stop：菜单内容（`MenuContentView` 内联）、菜单兜底行 hover 浮层（`HoverPanelController`）与 dock 浮层（`EdgeDockController`）都持有时钟、经 `DisplayClockScope` 注入环境；不需要自己挂 `TimelineView`。
- **闲时用量**：不再独立成块——原额度条下方的闲时脚注已删除，用量并入「额度窗口」表格的「闲」行；同表还有「免 / 速 / 它」三条今日动态行（Start Plan / 加速卡 / 其他智谱任务的今日切片，与「闲」行同一构造模式，GLM-only，行序 5h → 周 → 今 → 闲 → 免 → 速 → 它，重置日期格恒 `—`，口径说明句挂在「闲」字类型格的 tooltip 上；详见 `spec/ui/edge-dock.md` §Quota window usage block）。
- **活动套餐余额**（`GlmActivityPlanBalancesView`，仅在开启 `parseZcodeBalanceLog` 且有未过期 entitlement 或生效前预告时出现）：余额行每条一行 `🎁 套餐名 · 模型名 94% (283M/300M) 08-31 09:00`（模型名与套餐名忽略大小写同名 / 为空 / 实为 entitlementID 回退值时省略）；预告行（套餐已发放但 `effective_at` 未到、balances 无对应桶）排在余额行之后：`🎁 套餐名 · 模型名 生效时间：MM-dd HH:mm（300M）`——无百分比、无已用/剩余，整行 `.tertiary` 弱化。两种行都空则整块不渲染，排在额度段之后、余额之前。
- **OpenCode 数据合并**：`zhipuai-coding-plan` 绑定默认开启（`clientBindings[]`）。卡片底部展示 native ZCode 与 OpenCode 合并后的今日与最近 7 天 Input / Cache / Output / Reason 以及 R/T；绑定关闭后只显示 native ZCode local Scanner 数据。设置页没有该开关，调整方式见下节。

### OpenCode client bindings（无设置页开关）

The settings panes intentionally expose **no** per-provider OpenCode toggle. Whether
an OpenCode provider slice is merged into a card is owned by `clientBindings[]` in
`config.json` (see `spec/config.md` §Config Schema); GLM defaults to enabled, all other
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

ChatGPT's 5h / weekly summaries retain the preaggregated native Codex totals and
add only the enabled OpenCode contribution. The native samples already represented
by those totals are not added a second time; when native details are unavailable,
the row falls back to aggregating the available combined samples.

### Failed

Layout (off the cached `lastSuccess`, when one exists):

```text
<account row>                     # only if the cached QuotaInfo has one
exclamationmark.triangle.fill  <error message>
上次成功：<clock>
<previous quota bars>             # 55% opacity
<quota-window usage block>        # resident, same as .ok
<7-day chart>
```

The error message is red, 11pt, and limited to 2 lines. The fallback path runs through
the same constructors as the `.ok` branch (`accountInfoRow` / `quotaWindowUsage` /
`peakIndicator`), so a failure can no longer silently drop a section — the historic bug
this structure exists to prevent was exactly that, a missed `between` parameter.

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
| Progress bar | **整行宽**（跟随卡片内容宽度，即两个宿主共同的 **420pt**；不是旧主菜单的 312pt），8pt height，上下各留 3pt。The first segment is `min(5h remaining, weekly remaining × N)`；若周额度尚有余量，下一格先显示 `(weekly remaining × N - 5h remaining) mod 1`，再显示整格周额度 |
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
| 判定谓词 | **复用** `EquivalentQuotaAllocation.bindingWindow(...) == .weekly`（`SegmentedQuotaProgressBar.swift:163`）：周 × N **严格**小于 5h 才算周瓶颈，并列按同一约定落到 5h、不显示括号。这样括号出现与否与本行的分段条永远同源，不会条缩了文字没缩 |
| 括号值 | `EquivalentQuotaAllocation.effectivePrimaryFraction(...) × 100`（`SegmentedQuotaProgressBar.swift:149`），经 `Formatters.formatQuotaPercent` 格式化（至多一位小数、整数不带 `.0`，如 `30%` / `91.9%`） |
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
- **微栅格分段渲染（Hybrid Micro-Ticks）**：条体划分为 `N = max(segments, 1)` 个大段，段间保留 `4pt` 宏观间隙；当 `N > 1` 时，在第 0 段与第 1 段间隙正中绘制 `1.5pt` 宽、`10pt` 高的分界锚线（`Color.primary.opacity(0.28)`），直观区分当前 5h 窗口与未来周配额；
- **自适应微栅格与点亮保证**：每段内含自适应垂直圆角栅格（`ticksPerSegment(for:)`，整条维持 35~42 格，圆角 `1.5pt`，格间距 `1.5pt`）；填充算法 `activeTickCount(fill:totalTicks:)` 对 `fill > 0` 向上取整且保底点亮至少 1 格，杜绝“显示 >0% 但格子全空”；首段点亮栅格用 `intervalSegmentColor`（100% 不透明度），后续周段点亮栅格用 `weeklySegmentColor.opacity(0.68)`，底槽栅格用 `Color.primary.opacity(0.10)`。
- **时间感知与三角标记解耦**：首格颜色由 `primaryTimeRemainingFraction`（即 5h 短窗口/滚动窗口的剩余时间比例）参与统一 pacing 计算（分母 = `100% * t`，`< 20%` 红色，`< 50%` 黄色，`>= 50%` 绿色）；而顶部时间锚点三角 ▼ 仅在长周期窗口（`>= 86400` 秒，如周配额）呈现，短窗口（`< 86400` 秒）不显示三角，避免短频跳动引起视觉干扰。

Progress bar fill (`SegmentedQuotaProgressBar.intervalSegmentColor` /
`weeklySegmentColor` and `ModelQuota.colorLevel`):

| Remaining percent vs Pacing (分母 = 100% * t) | Health Level | Color |
|---|---|---|
| `< 20% * t` (或 percent <= 0，缺失 t 时 `< 20%`) | critical | `Color.criticalTint` |
| `< 50% * t` (缺失 t 时 `< 50%`) | warning | `Color.warningTint` |
| otherwise (包括 `t <= 0` 且 `percent > 0`) | healthy | provider/model tint |

Reset time color (`summaryColor(for:timeFraction:)`):

| Remaining percent vs Pacing (分母 = 100% * t) | Color |
|---|---|
| `< 20% * t` (或 percent <= 0，缺失 t 时 `< 20%`) | `Color.criticalTint` |
| `< 50% * t` (缺失 t 时 `< 50%`) | `Color.warningTint` |
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
| Error message | 11pt |
| Footer text/buttons (`MenuTypography.footer`) | 9pt medium |

The card's failure row is the one place in this table that is a **literal** 11pt rather
than a `MenuTypography` role: the `errorMessage` role had no call site and was deleted
rather than left as an unused role. The rendered size is unchanged.

> 核对基线：2026-10-29 · 代码 d1912e6
> 统一验证通过，详细结果见 `spec/sync.md`。
