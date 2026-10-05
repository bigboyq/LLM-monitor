# Menu & Provider Cards — UI Spec

This file is one of the three UI specs split out of `spec/ui-design.md` (now the
index). It documents the menu bar item, the menu window structure and the shared
`ProviderCardView` that both the edge-dock popover and the menu hover strip render.

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
center sector — go through the time-aware `ModelQuota.colorLevel` thresholds (`< 15` red;
`< 30` for short windows / `< min(time%, 50)` for long windows yellow; otherwise green),
the same rule the provider cards use, replacing the retired fixed `HealthLevel.standard`
thresholds. Composite elements (the bottom dots and the center sector) read the
"actual available" caliber — per model `min(5h, weekly × N)` via
`ModelQuota.aggregateActualAvailable` / `aggregateHealthLevel` — while the left/right
arcs keep their raw per-window averages (the weekly arc uses the widest remaining-time
fraction across models for its dynamic yellow threshold). During GLM peak hours a peak
floor raises a provider's composite status to at least `.warning` (red wins); the floor
only applies to the iconDuo bottom dots and the card header dots — arcs and the center
sector are exempt.

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

`MenuContentView` layout:

```text
width: 360pt
height: content-driven, fixedSize(vertical: true)

+------------------------------------------------+
| chart.bar.xaxis  LLM Monitor              ↻    |
+------------------------------------------------+
| 今日合计 1.2M   60%  ¥18.40（含$2.5）    21:09 |   global today summary + bare refresh time
|  ████████████████  input / cache / output      |
+------------------------------------------------+
| ▸ OpenCode                      820K    10.5   |   section: client + subtotal + value
|   gpt-5.5    ███░░░  620K  62%  $11.30         |   model row
|   GLM-5.3    ██░░░░  200K  40%   ¥33.00        |
| ▸ Codex                         380K   $7.10   |
|   gpt-5.5    ██░░░░  380K  58%   $7.10         |
| ⚠ 会话文件超出单轮扫描预算，已按最新优先截断…   |   truncation notice (that section only)
| ...                                            |
+------------------------------------------------+
| ◉10:23 ◉需重试 ◉未配置 ◉10:31 ◉10:05           |   provider fallback strip (no label)
+------------------------------------------------+
| 更新于 HH:mm / 下次 HH:mm / 就绪  自启 ✓|✗  设置 节能 日志 退出 |
+------------------------------------------------+
```

The menu is the **Harness (client) view**, not the Provider view. The header and
footer are unchanged, but the content area answers "which clients burned how many
tokens today" instead of "how much quota is left per provider". The menu no longer
renders provider cards; the per-provider quota reading lives in the edge status
dock, the hover panels, Settings — and in the **one-line provider fallback strip at
the bottom of the content area**, so that users without the edge dock still get a
quota read in the menu.

**Content structure** (`HarnessUsageMenuView`, driven by the pure
`HarnessTodaySummary.summarize(statuses:now:calendar:)`):

- **Global today summary** — total tokens, total cache-hit rate, total value, plus
  one `TokenBucketBar` for the three-bucket composition. The value is a
  `MixedCurrencyEstimate`: mixed-currency totals render as `10.5（含$1)` (CNY
  equivalent total, USD original in parentheses).
- **Per-client sections**, ordered by today-token descending. A client with no
  today activity is dropped entirely rather than shown as an empty section. Each
  section header carries the client name (`ClientDescriptor`), the section token
  subtotal and the section value — again a `MixedCurrencyEstimate`, because one
  client may span several provider slices (OpenCode / DSH / ZCode) and therefore
  several currencies.
- **Per-model rows inside a section**, keyed by
  `(clientID, quotaProviderID, modelName)`; samples with no usable model name
  collapse into a single 「模型名缺失」 row. Each row is: model name (tail-truncated,
  100pt) + `TokenBucketBar` (fills the remainder, ≥72pt) + tokens (40pt) + hit rate
  (36pt) + value (56pt). The row value is the **single-provider, single-currency**
  original amount (`ModelCostEstimate.displayText`: `¥3.21` / `$9.80` / `未定价`) —
  cross currency folding happens only at section and global level, never per row.

Row column budget: 100 + 72 + 40 + 36 + 56 = 304pt plus 4×6pt spacing = 328pt,
inside the 336pt content area (360pt panel − 2×12pt padding). Numeric columns are
fixed-width, right-aligned and `monospacedDigit`, so a refresh never shifts the row.
The model-name column is **fixed-width**, not `maxWidth`: `TokenBucketBar` wraps a
`GeometryReader` (greedy), and a flexible name column loses the whole row to it.
`HarnessUsageMenuViewTests` pins both the column budget and the row's natural width
(328pt) so that regression cannot come back silently.

Tokens are always counted from the same-day subset of each provider contribution's
`recentSamples` (through `UnifiedTokenUsageAggregator.day`), so the extra day that
scanners keep for quota-window math never leaks into "today".

The two-level empty states (no provider registered / no provider enabled) and the
first-run setup guide are unchanged. A third, narrower state — clients present but
no activity today — renders a single 「今日暂无本地 Token 用量」 line inside the
content area.

**Global freshness (bare time)** — the top summary block's **number row ends** with
`LocalUsageFreshnessText`: 「计算中…」 (with a mini spinner) while *any* enabled data
source is scanning (per-card `effectiveLocalUsageFreshness`, which already resolves
"scanning wins over failed over dirty"), otherwise the bare clock (`HH:mm`, falling
back to `MM-dd HH:mm` across midnight) from the latest `scannedAt` across those cards.
Both values are computed once in `HarnessTodaySummary.summarize`, so the view never
walks `statuses` itself. It is the **bare-text variant** of `LocalUsageFreshnessBadge`
(same state machine, same `.secondary` grey, no 「更新于」 prefix, no capsule
background) — the number row has no width budget for a capsule: its segments are all
fixed-width or greedy, and a capsule there would push the mixed-currency total into a
second line. The two skins are now literally one decision: both read a shared private
`LocalUsageFreshnessState`, so the state judgement and the clock text (including the
`MM-dd HH:mm` midnight degradation) are written once and only the wrapping differs. Both
public types and their interfaces are unchanged. The bucket bar below it therefore owns
its **whole row** (no badge at its tail), which also widens the three buckets' read. With
no scan ever recorded the bare time renders nothing at all (no placeholder, no phantom
space). The capsule variant keeps its other hosts (the 7-day card title in the dock
popover / strip hover card).

**Truncation notice** — a section whose sources were truncated (DSH file/byte budget
dropping the oldest sessions) shows a **one-line** short notice (`部分较早会话未计入`,
`HarnessSectionView.truncationShortText`) in orange on the header's second line; the
full `ClientUsageTruncationNotice.text` stays in its `.help` tooltip. The long sentence
wrapped onto two lines under a 336pt content area and pushed the section's rows down. Section-level aggregation, same "any source
truncated ⇒ truncated" rule as `ProviderUsageProjection.isTruncated`. Sections
without truncation show nothing — the numbers are right either way, they are just not
complete, and staying silent would let a partial total read as a complete one.

**Section header context menu** — right-click a section header for 「立即刷新全部」
(`AppState.refreshAll`, the same entry point as the header refresh button) and
「打开配置文件」(`state.openConfigFile`). These are the two actions the per-provider
cards carried before the menu switched to the client view; they are attached to the
header rather than the whole section so that the right-click target reads as "these
numbers".

**Provider fallback strip** (`ProviderStatusStripView`, the last row of the content
area) — one minimal element per enabled provider, **no leading label**: brand logo
(11pt) + `ProviderStateLabel` capsule (`10:23` / `需重试` / `未配置` …, already
tri-colour by refresh freshness). The label was removed in the 2026-10 first-round UI
pass — the icon+capsule sequence is self-explanatory, and the ~74pt it freed is what
raises visible capacity. It is separated from the sections above by a
`MenuHairline.horizontal`, and its data comes from the pure projection
`ProviderStatusStrip.snapshot(statuses:limit:)`:

- only **enabled** providers are shown — the filter lives in the projection, not in
  the call site, so a forgotten filter cannot surface a card the user switched off;
- providers **without** quota data (not configured / failed / pending) are shown too:
  that is the whole point of the row, since "not displayed" and "no data" must not
  look the same;
- at most `maximumVisibleCount` (**5**) elements fit: the widest element (logo + an
  `.ok` `HH:mm` capsule) measures 54pt, so five elements + 4×4pt spacing = **286pt**
  inside the 336pt content area (50pt of drift margin); a sixth (344pt) would clip, so
  it is not squeezed in. Whatever does not fit is folded into the count reported by
  `hiddenCount` and rendered as 「+N」, so "five shown" is never read as "five
  registered";
- when truncation happens, the **worst** entries are the ones kept
  (`ProviderStatusStrip.priority`: state first — failed > not configured/ready >
  loading > ok — then quota health), because a failed card has no trustworthy
  `aggregateHealthLevel()` (`nil`) and would sort last if health were ranked alone.
  The kept entries stay in the user's configured order (`providerCardOrder`); only
  *which* ones survive changes, never their order.

Hovering one element opens the **full `ProviderCardView(status:)`** in the existing
hover `NSPanel` (`HoverInfoRow` → `HoverPanelController`, the same mechanism as every
other menu hover detail; 0.22s delay, 0.08s re-arm when switching, 6pt cursor gap,
right edge flips to the cursor's left, bottom edge flips above the cursor). The panel
host owns a shared display clock (`HoverPanelController.displayClock`) that starts/stops
with the panel's show/hide and is injected through `DisplayClockScope` — without it
the in-card peak countdown / freshness capsule would read the environment key's static
fallback value (`DisplayDateKey.defaultValue` is a `static let`, evaluated once per
process, permanently frozen). The card
is pinned to `hoverRevealMode = .alwaysVisible` (`ProviderStatusStripView.cardRevealMode`)
and to the dock popover's card width (`EdgeDockTheme.popoverWidth` minus its backdrop
padding — writing the menu's 360pt there would cut 24pt off the 7-day chart) and is
laid out exactly like the dock's card: the same three sections (Account Info row →
Plan Info's four resident modules → the 7-day card), see `spec/ui/edge-dock.md`
§Two cards, titles outside and §Quota window usage block. `.alwaysVisible` keeps one real job for the 7-day
chart: in that mode the chart does not draw its own title row (the card title row
outside carries it), so a wrong mode shows the title twice or not at all — the hover
panel is `ignoresMouseEvents = true`, and every formerly hover-collapsed section has
been **resident** since the 2026-10 second-round pass (the quota-window usage table,
the per-card reset-credit list and the account row render in both modes). `HoverPanelController.maximumPanelWidth`
was raised to `EdgeDockTheme.popoverWidth` for the same reason it used to be sized
for the 7-day chart: the panel must fit the widest detail. Vertical fit is handled by
`frameForPanel` clamping to the screen's visible frame (the resident form grew the
fullest card; `LayoutMetricsTests` keeps it under an 800pt ceiling) — on a short
display the clamp wins and the dock popover's `ScrollView` fallback
(see `spec/ui/edge-dock.md` §Hover behaviour → Size) keeps the overflow reachable.

**Three interactions share one element**, and the split between them is the point:

| Input | Action | Why it is this one |
|---|---|---|
| **Left click** | Refresh this provider immediately | The element is the only thing in the panel you can left-click onto a *specific* provider with — the hover panel is `ignoresMouseEvents = true` and cannot be clicked, and the header's 「立即刷新全部」 is scoped to everything. No explicit menu, no discovery cost |
| **Right click** | `刷新 <provider>` menu item | The same action as an explicit, named entry point, for the "I know which one I want" case. It carries the provider name because one row shows several same-shaped items |
| **Hover** | Pop the full `ProviderCardView` | Read-only. It issues **no** network request — a pointer merely crossing the row must not spend a provider's fetch budget |

Left and right share **one** action, not two copies: both go through
`ProviderStatusStripView.RefreshMenuItem` (a plain value type carrying `providerID` +
`displayName`, with the `刷新 <name>` title and the `perform` routing), and the host is
still `MenuContentView.refreshProviderFromMenu` → `AppState.refreshOne`. `onTapGesture`
has no addressable seam in SwiftUI, so both the item and the tap closure
(`tapHandler(for:onRefresh:)`) are `static` and pinned by tests instead.

The single-provider refresh is the per-provider entry point the menu lost when the
provider cards were replaced by the client view. It routes to
`AppState.refreshOne(providerID:)` (the same call the old cards' single 「立即刷新」
item used), so only that provider is fetched and only that provider's schedule is
re-anchored; the other providers' next tick is untouched
(`AppStateTests.testRefreshOneReanchorsOnlyRefreshedProvider`). It exists for **every**
entry in the strip, including `.notConfigured` / `.failed` ones — retrying is exactly
the action those need.

**The right-click item is disabled while a refresh transaction is running; the left
click deliberately is not.** The disable signal is `AppState.isRefreshJobActive`, the
same global flag the header's spinner uses (there is no per-provider in-flight flag to
key on, and none was invented for this). The tap path keeps no second copy of that
state: `refreshOne` opens with the same global in-flight gate
(`refreshScheduler.beginExternalJob()`), so a repeat tap is a silent no-op that only
re-anchors the same provider, and a UI-side busy state would only drift from the global
verdict. Feedback comes from the capsule the element already carries (it moves to a
refreshing state and then back to `HH:mm`) — a dead-looking button during a rapid
re-click reads worse than one that just does nothing twice.

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
- `自启 ✓` / `自启 ✗` login item status indicator
- refresh status (`更新于 HH:mm` / `下次 HH:mm` / `就绪`)
- `设置` (opens native Settings window)
- `节能` (1-click keep-awake in-memory toggle; the icon flips `powersleep` →
  `cup.and.saucer.fill` and the label to `防休眠` while it is on, and the overlay dot
  reflects tri-color sleep health — immediately red when keep-awake is on)
- `日志` (reveals `log.txt` in Finder)
- `退出` (`NSApp.terminate`)

## Provider Card

`ProviderCardView` 现在只有**一个**渲染宿主形态：边缘状态窗的 provider 详情浮层，
以及菜单底部 provider 兜底行 hover 出来的那张卡（两者都固定 `.alwaysVisible`）。
菜单内容区是客户端视角，不再渲染 provider 卡，因此这张卡没有"菜单形态"了。

`ProviderCardView` 是 thin coordinator，额度行、浮层、图表和账号详情按职责分文件维护；body 的派生值（投影 / 额度窗口快照 / 「今」行）收在 `Views/ProviderCardDerived.swift` 的值键 memo 里（`Models/DerivedValueMemo.swift`），只有输入真的变了才重算：
- `QuotaViews.swift` — 所有 quota 行 / 进度条 / 重置卡 / `EquivalentQuotaAllocation`
- `QuotaWindowUsageViews.swift` — 「额度窗口用量」区块（包含「额度窗口」分析/用量可切换模块与「重置卡详情」模块，详见 `spec/ui/edge-dock.md` §Quota window usage block）
- `LocalUsageHoverViews.swift` — 7 天本地用量卡与 `LocalUsageFreshnessBadge` / `LocalUsageFreshnessText`
- `HoverPanel.swift` (386 行) — `HoverInfoRow` / `HoverPanelController` / 浮层管理
- `TokenChart.swift` (40 行) — 7-day 柱图基础组件
- `QuotaHoverViews.swift` — 只剩 `UsageMetricHoverSummaryView`（额度窗口 hover 明细族已随 `menuLayout` 删除）

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
- Antigravity uses blue for `Gemini Models`
- Antigravity uses orange for `Claude and GPT models`

## Card Header

| Element | Current behavior |
|---|---|
| Status dot | **不再画**。它紧挨着品牌图标，两个小圆读起来像"图标带了个绿点"，而同一行右侧的 `ProviderStateLabel` 已经把状态说清楚了。承载它的 `StatusIndicator` 视图已随之删除（那两处以它为参照的注释也改成了不依赖类型名的说法） |
| Provider icon | `BrandLogoView(kind:)` at its `defaultSize` (18pt); ChatGPT and GLM assets render as **templates** (they follow `Color.primaryLabel`, so both appearances stay readable), the rest keep their own colours, and a missing asset falls back to a per-brand SF Symbol at 0.72 × size |
| Display name | `MenuTypography.cardTitle` — **13pt bold**, `Color.primaryLabel`, single line, tail-truncated with a `.help` of the full name |
| Plan tag | **已从标题行移除**（2026-10 第二轮改版）。套餐 pill 挪进卡片第一段「Account Info」行（`QuotaWindowAccountInfoRow`），与账号名同一行——账号是谁、什么级别是同一个问题的两半 |
| State tag | compact `未配置` / `待更新` / `已更新` / `需重试` label; a spinner replaces it while loading. `未配置` (not `未启用`): `.notConfigured` covers a missing API key, missing external auth and missing login as well as a disabled provider, and `未启用` made an enabled-but-keyless provider read as switched off |
| Account block hover | **已删除**。邮箱 / 数据来源原本按 provider 分三路包在标题行的 `HoverInfoRow` 里，只为菜单那张卡服务；菜单不再渲染 provider 卡，浮层又不吃鼠标事件，这个折叠区展不开，直接不画 |
| Seven-day local statistics | 不在标题行，在**本地用量那一段**（`LocalUsageFooterView` → `SevenDayTokenUsageHoverView`）：`.alwaysVisible` 下就地展开成第二张卡的内容，`.onHover` 下才是悬停弹层 |

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

This is currently used for exactly two things:

- the header's **sleep-blockers notice** (`SleepOffendersHoverView`, the same rows as
  Settings → Energy check 1) — hover-only, no click action
- **the menu's provider fallback strip**: hovering one provider element shows the full
  `ProviderCardView(status:)` for that provider, at the dock popover's card width
  (`EdgeDockTheme.popoverWidth` − backdrop padding) and in its `.alwaysVisible` layout
  — the same card the dock shows, reached from the menu. Vertical fit is handled by
  `frameForPanel` clamping to the screen's visible frame; `LayoutMetricsTests` keeps
  the resident card under an 800pt ceiling (900pt for the fullest fixture).

Everything else that used to hang off a hover panel is gone: the ChatGPT `Last Prompt`
summary, the merged `5h / 周` local-usage column, the quota-window detail views and the
per-card reset-credit list were all deleted with the menu's provider cards (reset credits
first became resident in the second-round pass, the rest lost their only host). Do not
look for a hover route to this data — the card carries it inline.

## Provider-Specific Card Details

### minimax

- 大部分模型（`general` / `image` / `speech` / `music` / `tts` 等）把 5h 和周额度合成一条，周进度条按 10 个等价额度分段（`ModelQuota.weeklyEquivalentMultiplier` = 10）。
- **`video` 模型走日窗口**：周进度条按 7 个等价额度分段（1 天 ≈ 1/7 周）。原因：minimax video 实际是日配额而不是 5h 配额，按 5h × 10 分段会误导。label 由 `QuotaSummary.primaryWindowLabel` 按 model 名判断。

### ChatGPT Plan

- 同时有 5h 和周额度时合并为一条，周进度条按 6 个等价额度分段（`weeklyEquivalentMultiplier` = 6）；接口只返回一个窗口时走单窗口路径，不虚构第二窗口。
- 账号行（第一段 Account Info）= 邮箱（`~/.codex/auth.json`）+ 套餐 pill（如 `Team`）；重置卡逐张清单常驻在「额度窗口用量」区块的重置卡模块里，不再挂 hover。
- `Last Prompt` 摘要随菜单的 provider 卡一起删除，卡片里不再有这个入口；本地用量改由「额度窗口」模块（分析/用量可切换）与 7 天卡承担。

### Antigravity

- 卡片标题 = `Google Antigravity`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 登录邮箱（来自 `GetUserStatus`）+ 套餐 pill（`planLabel` 去掉 `Google ` / `Antigravity ` 前缀，让 `Google AI Pro` → `AI Pro`）。两者皆缺时整行不画。这是一行**常驻**内容：菜单的 provider 卡删除前，邮箱与套餐曾按 provider 分三路包在标题行的 `HoverInfoRow` 浮层里；现在浮层 `ignoresMouseEvents = true`，那个折叠区展不开，所以直接画成常驻行——没有「重新进入 hover 浮层」这条路径了。
- `Gemini Models` and `Claude and GPT models` are shown as separate model groups inside one provider card.
- 两组都把 5h / 周收为一条：Gemini 按 6 个等价额度分段，Claude and GPT 按 1 个（`weeklyEquivalentMultiplier` = 6 / 1，周窗口即 1 × 5h 额度）。
- The countdown text uses compact formatting such as `3小时41分后`.
- The countdown follows the model tint unless quota is low enough to trigger warning or critical colors.

### GLM Coding Plan

- 卡片标题 = `GLM Coding Plan`（provider 名），无 pill。
- 账号行（第一段 Account Info）= 仅套餐档位 pill（`data.level` 首字母大写：`lite` → `Lite` / `Pro` / `Max`）。GLM 走 API Key 登录、拿不到邮箱，但**仅等级也显示账号行**；拿不到等级时整行不画。
- 单条 `GLM Coding Plan` 模型行（`QuotaInfo.displayName`，不再硬编码具体模型名）：智谱 Coding Plan 的 5h + 周积分是套餐共享池，合成一条展示，周进度条按 5 个等价额度分段（`weeklyEquivalentMultiplier` = 5；周积分 = 5 × 5h 积分：Lite 2000/10000、Pro 12000/60000、Max 28000/140000）。
- 数据来源：远程 `GET open.bigmodel.cn/api/monitor/usage/quota/limit`，Coding Plan Key 作裸 token 放 `Authorization`。鉴权失败（HTTP 200 + `code:1000`）在 parse 阶段捕获并映射成 401 语义。
- **高峰期提示**：额度行下方一行（`PeakIndicatorView` 外壳 + `GlmPeakIndicatorView` 的文案），纯本地计算（北京时间，与 API 无关）。颜色分 3 档：高峰期 🔥 红色 `高峰期 · 还剩 X`；非高峰期距高峰 < 1 小时 ❄️ 橙色、≥ 1 小时 ❄️ 绿色 `距高峰期 X · 非高峰 5 折`。Mon–Fri 14–18（官方规则：高峰全价、非高峰 50% 折），窗口固定不可调（北京时间、法定节假日除外，设置页只读展示，见 `spec/ui/settings.md`）。倒计时读环境里的 `\.displayDate`——共享展示时钟 `DisplayClock`（每个宿主各持一个实例），由卡片实际所在的宿主各自注入并随面板显隐 start/stop：菜单内容（`MenuContentView` 内联）、菜单兜底行 hover 浮层（`HoverPanelController`）与 dock 浮层（`EdgeDockController`）都持有时钟、经 `DisplayClockScope` 注入环境；不需要自己挂 `TimelineView`。
- **活动套餐余额**（`GlmActivityPlanBalancesView`，仅在开启 `parseZcodeBalanceLog` 且有未过期 entitlement 时出现）：每条一行 `🎁 套餐名 94% (283M/300M) 08-31 09:00`，排在额度段之后、余额之前。
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
Claude/GPT 组 N=1）。括号把差额摆到明面上。

| Rule | Value |
|---|---|
| 显示条件 | `QuotaBarWithMetadata.weeklyBindingEffectivePercent(model:multiplier:)` 返回非 nil（`QuotaViews.swift:648`）——纯函数，双窗口以外一律 nil |
| 判定谓词 | **复用** `EquivalentQuotaAllocation.bindingWindow(...) == .weekly`（`SegmentedQuotaProgressBar.swift:163`）：周 × N **严格**小于 5h 才算周瓶颈，并列按同一约定落到 5h、不显示括号。这样括号出现与否与本行的分段条永远同源，不会条缩了文字没缩 |
| 括号值 | `EquivalentQuotaAllocation.effectivePrimaryFraction(...) × 100`（`SegmentedQuotaProgressBar.swift:149`），经 `Formatters.formatQuotaPercent` 格式化（至多一位小数、整数不带 `.0`，如 `30%` / `91.9%`） |
| 渲染 | `Text("(\(Formatters.formatQuotaPercent(effectivePercent))有效)")`，`MenuTypography.dataValue`（10pt semibold monospacedDigit），`Color.criticalTint`，`.fixedSize()`（`QuotaViews.swift:780-786`） |
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
`healthyTint` already had. Custom `statusBarHealthColors` are **not** wired into these
tokens yet — that config still feeds only the menu-bar icon dot and the dock circle,
and making it reach the card means plumbing a dynamic colour through `AppState`; it is
deliberately future work rather than a silent half-wiring.

Progress bar fill (`SegmentedQuotaProgressBar.intervalSegmentColor` /
`weeklySegmentColor` and `ModelQuota.colorLevel`):

| Remaining percent | Health Level | Color |
|---|---|---|
| `< 15` | critical | `Color.criticalTint` |
| `< 30` (5h) / `< min(time%, 50)` (weekly) | warning | `Color.warningTint` |
| otherwise | healthy | provider/model tint |

Reset time color (`summaryColor(for:)`):

| Remaining percent | Color |
|---|---|
| `< 15` | `Color.criticalTint` |
| `< 30` (5h) / `< min(time%, 50)` (weekly) | `Color.warningTint` |
| `> 80` | `Color.healthyTint` |
| otherwise | primary |

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

The per-card list (`ResetCreditsDetailList`) filters to `status == "available"` and sorts
by expiry ascending (entries with no expiry last, then by id for stability), so the
status-based dot colours the list used to switch on are **no longer needed**: every
row that survives the filter is available, and its 5pt dot is unconditionally
`Color.healthyTint`. An entry with no expiry is still listed, as 「过期时间未知」.

```text
●  2026-10-30 09:00  约 3 天 4 小时 后
●  过期时间未知
```

The UI intentionally hides reset-credit id, title, description, and grant time.

## Typography

| Element | Font |
|---|---|
| Header title (`MenuTypography.headerTitle`) | 13pt semibold |
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

> 核对基线：2026-10-05 · 代码 79dee29
