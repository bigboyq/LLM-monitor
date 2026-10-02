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
- `quotaLogo` (`App 图标` - the app icon design asset, no longer drawn at runtime)
- `iconDuo` (`Icon Duo` - live quota dashboard)

`quotaLogo` is a **static image**: the settings picker and the menu bar use the same
`llm-quota-730-2-dark.svg` design asset, and nothing about health, quota levels or
custom colors changes it. The asset's canvas is not its artwork — the drawing occupies
only ~59% of it, so drawing it canvas-true would put a ~12pt icon in the menu bar.
`MenuBarLabel.appIconDesignContentRect` rasterizes it once at 256px, scans the alpha
channel for the tight bounding box, and `fittedContentRect` maps that box into the same
20pt frame the SF Symbol styles use (aspect preserved, centered). The scan must call
`CGContext.makeImage()` *after* drawing — it snapshots the context's current contents,
so the reverse order yields a blank image, "no opaque pixels", and a silent fallback to
the uncropped canvas. It used to be drawn at runtime by `QuotaLogoSVGBuilder` — an
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
crossing a 1% threshold, so "plan A's 5-hour window ran out" and "the ring now shows plan
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
| 今天合计 1.2M        命中 60%     $18.40       |   global today summary
|  ████████░░░░░░░░  input / cache / output      |
+------------------------------------------------+
| ▸ OpenCode                      820K    10.5   |   section: client + subtotal + value
|   gpt-5.5    ███░░░  620K  62%  $11.30         |   model row
|   GLM-5.3    ██░░░░  200K  40%   ¥33.00        |
| ▸ Codex                         380K   $7.10   |
|   gpt-5.5    ██░░░░  380K  58%   $7.10         |
| ⚠ 会话文件超出单轮扫描预算，已按最新优先截断…   |   truncation notice (that section only)
| ...                                            |
+------------------------------------------------+
| Provider 状态  ◉10:23 ◉需重试 ◉未配置      +1  |   provider fallback strip
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

**Global freshness capsule** — the top summary block's second row ends with
`LocalUsageFreshnessBadge`: 「计算中…」 while *any* enabled data source is scanning
(per-card `effectiveLocalUsageFreshness`, which already resolves "scanning wins over
failed over dirty"), otherwise 「更新于 HH:mm」 from the latest `scannedAt` across
those cards. Both values are computed once in `HarnessTodaySummary.summarize`, so the
view never walks `statuses` itself. The capsule sits at the end of the bucket-bar row
rather than the number row: the number row's four segments are all fixed-width or
greedy, and a capsule there would push the mixed-currency total into a second line;
`TokenBucketBar` wraps a `GeometryReader`, so giving up ~70pt only narrows the three
buckets. With no scan ever recorded the badge renders nothing at all (no empty
capsule, no phantom space).

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
area) — a 「Provider 状态」 label followed by one minimal element per enabled
provider: brand logo (11pt) + `ProviderStateLabel` capsule (`10:23` / `需重试` /
`未配置` …, already tri-colour by refresh freshness). Its data comes from the pure
projection `ProviderStatusStrip.snapshot(statuses:limit:)`:

- only **enabled** providers are shown — the filter lives in the projection, not in
  the call site, so a forgotten filter cannot surface a card the user switched off;
- providers **without** quota data (not configured / failed / pending) are shown too:
  that is the whole point of the row, since "not displayed" and "no data" must not
  look the same;
- at most `maximumVisibleCount` (4) elements fit: the widest shape (5 enabled
  providers, all `.ok` with timestamps, plus a 「+N」 chip) measures **326pt** inside
  the 336pt content area, leaving 10pt for font-metric drift — the same order of
  margin as the model row's 328pt budget. Whatever does not fit is folded into the
  count reported by `hiddenCount` and rendered as 「+N」, so "three shown" is never
  read as "three registered";
- when truncation happens, the **worst** entries are the ones kept
  (`ProviderStatusStrip.priority`: state first — failed > not configured/ready >
  loading > ok — then quota health), because a failed card has no trustworthy
  `aggregateHealthLevel()` (`nil`) and would sort last if health were ranked alone.
  The kept entries stay in the user's configured order (`providerCardOrder`); only
  *which* ones survive changes, never their order.

Hovering one element opens the **full `ProviderCardView(status:)`** in the existing
hover `NSPanel` (`HoverInfoRow` → `HoverPanelController`, the same mechanism as every
other menu hover detail; 0.22s delay, 0.08s re-arm when switching, 6pt cursor gap,
right edge flips to the cursor's left, bottom edge flips above the cursor). The card
is pinned to `hoverRevealMode = .alwaysVisible` (`ProviderStatusStripView.cardRevealMode`)
and to the dock popover's card width (`EdgeDockTheme.popoverWidth` minus its backdrop
padding — writing the menu's 360pt there would cut 24pt off the 7-day chart) and is
laid out exactly like the dock's card: two cards, titles outside. `.alwaysVisible` is
not a style choice: the hover panel is `ignoresMouseEvents = true`, so every
hover-collapsed section inside the card (account block, local-usage footer) could
never open, and the quota rows would fall back to their compact layout — the same
argument as `EdgeDockController+Popover`. `HoverPanelController.maximumPanelWidth`
was raised to `EdgeDockTheme.popoverWidth` for the same reason it used to be sized
for the 7-day chart: the panel must fit the widest detail. Vertical fit usually needs
no scroll — the card is ~745pt tall (measured on the fullest form: reset credits +
priced windows) and `frameForPanel` clamps to the screen's visible
frame; on a short display the clamp wins and the dock popover's `ScrollView` fallback
(see *Hover behaviour → Size*) keeps the overflow reachable.

Right-clicking one element offers 「刷新 <provider>」 — the per-provider refresh
entry point the menu lost when the provider cards were replaced by the client view.
It routes to `AppState.refreshOne(providerID:)` (the same call the old cards' single
「立即刷新」 item used), so only that provider is fetched and only that provider's
schedule is re-anchored; the other providers' next tick is untouched
(`AppStateTests.testRefreshOneReanchorsOnlyRefreshedProvider`). The item exists for
**every** entry in the strip, including `.notConfigured` / `.failed` ones — retrying
is exactly the action those need. While a refresh transaction is running the item is
disabled; that signal is `AppState.isRefreshJobActive`, the same global flag the
header's spinner uses (there is no per-provider in-flight flag to key on, and none
was invented for this).

The content area scrolls when needed. `MenuPanelHeightBridge` caps the menu window at
70% of the screen's visible height; when the cap is reached, only the content list
scrolls while the header and footer remain fixed. The cap is applied at the native
window layer and the list uses the remaining content height. The measured height is
reported through `CardsContentHeightKey`, which the harness content reuses unchanged.

The menu footer contains:
- `自启 ✓` / `自启 ✗` login item status indicator
- refresh status (`更新于 HH:mm` / `下次 HH:mm` / `就绪`)
- `设置` (opens native Settings window)
- `节能` (1-click keep-awake in-memory toggle; overlay dot reflects tri-color sleep health)
- `日志` (reveals `log.txt` in Finder)
- `退出` (`NSApp.terminate`)

## Edge Status Dock (Screen Edge Panel)

A third window pinned to a screen edge: one circle per enabled Provider, visible
without opening the menu. Configured under Settings → General → 边缘状态窗, persisted
at `config.json` → `edgeDock` (`mode` / `edge` / `offset` / `hideInFullscreen`).

**Default: 状态窗（自动隐藏）** — full feature on, but the screen shows only a 7pt ring
column until the cursor comes near. Defaulting to "nothing appears" instead (the
earlier behaviour, a disabled switch) buried the feature behind a toggle nobody
flips; a column of small dots is the one shape that is present, useful and unobtrusive
without being asked for. 「无」 is the first option in the picker for users who want it
gone — an explicit pick rather than a default that hides the feature.

Granularity is **one circle per Provider**, 1:1 with the menu cards
(`ProviderStatus` granularity). Per-*model* circles were considered and rejected:
they would need a new model-level colour caliber on top of the existing
provider-level one, and would push the window past a glanceable length.

### Circle anatomy

Outside-in, three layers at a 38pt diameter:

| Layer | Meaning | Source |
|---|---|---|
| **Outer ring** | 5-hour (interval) window remaining | `intervalRemainingPercent`, **worst** model |
| **Inner ring** | Weekly window remaining | `weeklyRemainingPercent`, **worst** model, **raw** (not multiplied by `weeklyEquivalentMultiplier` — the inner ring answers "how much weekly quota is left", and multiplying by the equivalence factor N would stop being that) |
| **Centre** | Which Provider | `BrandLogoView(kind:size:)` at a fixed 12pt — the same real brand asset the menu cards use, sized to stay inside the inner ring's inner edge (inner ring is `0.72 × 38 = 27.4pt`, so its inner edge sits at a 12.2pt radius against the icon's 7pt half-width). The size is **passed into the view**, never framed from outside: see *Logo sizing is the view's job* below |

Each ring's length is the **minimum** across the provider's models that have that
window. This deliberately diverges from the iconDuo arcs, which use the mean: the
iconDuo is a single icon aggregating *all* providers and has no per-provider
option, whereas an edge dock circle *is* one provider and must answer "is this one
about to run out". Length and colour therefore agree — both worst-case — instead of
ring saying "plenty" while the colour says "danger".

**Thickness is also a hierarchy: thick outside, thin inside.** The outer ring is
3.5pt, the inner 2.5pt. Two rings of equal weight read as the same arc drawn twice;
the step in weight makes the outer ring the subject and the inner an annotation. It
stops short of being thinner because the inner ring's diameter is only `0.72 ×` the
outer one, and a much thinner stroke turns its 1.8pt-radius band into a grey smear.

**The two rings may be coloured independently** (`config.independentRingColors`,
on by default). On: the outer ring takes the colour of the **5-hour window alone**
and the inner ring the colour of the **weekly window alone**, each through
`ModelQuota.colorLevel(percent:timeFraction:)` — the same thresholds the segmented
bar uses. The weekly ring therefore passes `weeklyTimeRemainingFraction(at:)` and
gets the *time-aware* yellow line (`min(time%, 50)`): a weekly budget that is
half spent with a day left is a warning, with six days left it is not. The 5-hour
ring passes `timeFraction: nil` and gets the fixed 30% line — the dynamic line is
a long-window rule, and a window that resets every five hours has no meaningful
"fraction of the window remaining" to tighten it. Both take the **worst** model in
that window, matching how their lengths are computed, so length and colour never
point at different bottlenecks. Off: both rings take the provider's aggregate
`health` instead. The centre logo and the quota number stay neutral in both modes —
they identify, they do not report.

The compact single ring is coloured by the 5-hour window too, with the same weekly
fallback its *arc length* uses, so a weekly-only provider never shows a weekly arc
in the 5-hour window's colour.

A provider with only one of the two windows draws just that ring; a provider with
neither (balance-only DeepSeek, or no successful fetch yet) draws a dimmed full ring
on both, reading as "health is known, remaining quantity is not". A grey ring would
be indistinguishable from "no data" — which is also why a *missing* window gets a
`nil` health level (neutral) rather than some guessed colour.

The dock background uses `EdgeDockTab`: an **asymmetric tab** — the side facing
the screen is **square and flush**, the inward-facing end is a large convex corner
(`0.37 ×` the short side).

The flush screen side is deliberate. The window already sits flush against the
screen edge; a rounded corner there opens a sliver of desktop between screen and
window and the backplate starts to read as a capsule floating above the screen.
Square corners let it join the screen edge into one continuous line.

Each row is **ring + persistent quota number** (5h first, weekly as fallback, `—`
when neither exists). The number is the only readable information without
hovering, so it is the 5h window: that is what changes fastest and answers "can I
still work right now".

### Row order is the configured provider order

The dock lists providers in **`config.providerCardOrder`** — the same list the
settings page drags and the menu panel renders, keyed by
`ProviderKind.quotaProviderID`. With no configured order it falls back to
display-name ascending. Combined with the anchor table above, the reading order
is: `left`/`right` → **top to bottom**; `top`/`bottom` → **left to right**.

Ordering is not presentational. A hit-test index is resolved back to a provider
through `entries[index].id`, so the view's order and the controller's order must
be the *same* order or hover highlights one circle and pops another provider's
card. Both sides therefore go through `EdgeDockProjection.entries(from:preferredIDs:)`
against the same config; `EdgeDockController.orderedEntries()` is the controller's
single entry point.

Two consequences worth keeping in mind:

- **Selection is anchored by id, not by index.** Reordering while a card is open
  would otherwise silently swap the open card to a different provider, so
  `reconcile` re-derives `selectedIndex` from the provider id it was showing.
- **Duplicate config keys must not trap.** `DisplayOrder.ordered` builds its
  lookup with an explicit loop rather than `Dictionary(uniqueKeysWithValues:)`,
  which would crash on two statuses sharing one `quotaProviderID` — and the dock
  re-projects on every mouse move, so that is an app-wide crash, not a glitch.

### Logo sizing is the view's job

`BrandLogoView` takes a `size` and frames **itself** with it. Wrapping it in
`.frame(width:height:)` from the call site does not shrink it: SwiftUI's `frame`
is a size *proposal*, and a child carrying its own fixed frame returns that size
regardless — the outer frame only centres the larger content, without scaling or
clipping. The dock icon was declared 6pt this way and rendered at the default
18pt, filling the inner ring's hole and riding onto its stroke.

### Anchor convention (geometry must match layout, literally)

Every `EdgeDockGeometry` function that positions a row has to agree with what
`EdgeDockContentView` actually lays out. Getting this wrong flips the whole column
and produces the worst-looking failure mode there is: the popover shows the **right
provider** in the **wrong place**.

| Edge | Stack | Index 0 renders at | Step along the edge |
|---|---|---|---|
| `left` / `right` | `VStack` | **top** = `dockFrame.maxY` (AppKit y points up) | `rowStep` = `rowHeight + spacing` |
| `top` / `bottom` | `HStack` | **left** = `dockFrame.minX` (x matches SwiftUI) | `columnStep` = `diameter + spacing` |

Three consequences that are easy to get wrong:

- **`rowStep` is vertical-only.** The number sits *below* the ring, so a row is
  `rowHeight` tall but only `diameter` wide. A horizontal dock stacks `diameter`
  per column; reusing `rowStep` there leaves the window wider than its content and
  the last column stranded.
- **A row's hit rect spans the whole dock** on the axis perpendicular to the edge,
  while the laid-out row is only `diameter` wide. Those are different purposes
  (hit target vs. content), so the test compares the stacking axis only.
- **`rowCenter` returns the row centre, not the ring centre** — the row includes the
  number, so they differ by 7pt. The popover aligns to the row.

**Padding is orientation-independent.** The dock's backplate is a hard-edged shape, so a
missing inset is immediately visible and never produces an error. `dockSize` adds
`padding * 2` on the stacking axis (`rowHeight` per row vertically, `diameter` per
column horizontally) and on the perpendicular axis (`diameter` vertically,
`rowHeight` horizontally — the number still hangs below the ring either way).
`testContentInsetEqualsPaddingOnAllFourSidesOfEveryEdge` pins the result: the laid-out
content sits exactly `padding` from all four window edges, for every edge and every
row count. Changing `rowHeight`, `spacing` or `diameter` moves the window size and the
layout together, or this fails.

Rhythm is deliberate, not uniform: `labelSpacing` (4pt) is *smaller* than `spacing`
(16pt), so a number reads as belonging to the ring above it rather than as the first
element of the next row. `testLabelStaysVisuallyAttachedToItsOwnRing` guards that
relationship, and that `spacing` stays wider than the ring's stroke — otherwise two
rows' rings visually merge into one blob.

### The quota ring

Two rings per row, each a **track** plus an **arc**:

| Part | Rule |
|---|---|
| Track | `EdgeDockTheme.ringTrack`, drawn **unconditionally**. It is the only cue that "there is a ring here, the number just isn't readable yet" while loading, on first fetch, or for providers with no quota window. Never skip it because `fraction == nil` — the track and the arc are two separate draws |
| Track colour | `Color.primary` @ 18%, **not** a fixed white and not `Color.secondary`. The dock is force-rendered in `\.colorScheme = .dark`, so `primary` is reliably light against the dark glass; the point of the semantic colour is only that the old "dock never changes appearance, so hardcode white" special case no longer has to be maintained |
| Arc | `EdgeDockGeometry.arcTrimRange(fraction:)`, which returns `nil` for `nil` and `0` (a zero-length round-capped stroke would leave a dot on an empty ring) and `[1 - fraction, 1]` otherwise |
| Direction | **Depletes clockwise.** The clockwise end is pinned at 12 o'clock and the free end sweeps clockwise toward it, so the gap opens at 12 o'clock and grows clockwise. The common `[0, fraction]` fills clockwise from 12 and retracts *counter*-clockwise on the way down — that reads as "progress", not "remaining" |

`arcTrimRange` is a pure function precisely so the direction is testable: written
backwards it still renders, still animates, and still throws no error — it just makes
the ring appear to turn the wrong way, which nothing in the UI reports.

### Popover width

The popover is **fixed width**, not content-sized, and the width is derived from the
widest thing the card can contain — the 7-day token usage chart
(`SevenDayUsageChartMetrics.pricedWidth` = 420): chart + the card's own 12pt padding
(`LayoutMetrics.cardContentPadding`) + the popover's 12pt backdrop padding
(`LayoutMetrics.cardColumnHorizontalPadding`) = `EdgeDockTheme.popoverWidth` (468).
It used to equal the main-menu width (360), which left the card only 312pt of content
width and clipped the first/last day of the chart — exactly the layout damage a fixed
width was supposed to prevent, just caused by the width being too small in the first
place. The menu keeps its own 360; only the popover widens. Clamped only when the
screen is narrower than the popover. The same derivation now also sets
`HoverPanelController.maximumPanelWidth` (it used to be chart + 2×10pt = 440, sized
only for the chart): the menu's provider strip hovers a whole `ProviderCardView`,
whose widest content is that chart **plus the card's own 12pt padding on each side**,
so the cap is `EdgeDockTheme.popoverWidth` (468). Left at 440 the card's right edge
was cut; the panel is still clamped to the screen's visible frame, as before.

### Collapsed sections are open in the popover

The provider card hides several sections behind hover — the account block in the
header, the quota data rows, the reset-credit row, the local-usage footer. All of them
go through the single `HoverInfoRow` wrapper, which is where the behaviour branches:

| Host | `hoverRevealMode` | Behaviour |
|---|---|---|
| Main menu (its own hover rows) | `.onHover` (the default) | Independent `NSPanel` after a delay |
| Provider card in the edge dock popover | `.alwaysVisible` | Each section expands **in place**; the two groups (quota / 7-day usage) are additionally split into two cards, see *Two cards, titles outside* |
| Provider card in the menu's provider strip hover | `.alwaysVisible` (pinned) | identical to the dock card — same `NSPanel` mechanism, but a panel that ignores mouse events, so "hover to expand" could never open |

The switch is an `Environment` value rather than a parameter threaded through each
call site: there are a dozen `HoverInfoRow` uses across `ProviderCardView`,
`QuotaViews` and `LocalUsageHoverViews`, and a parameter would mean remembering to
update every one of them — a missed site silently keeps the old behaviour with no
error anywhere.

The default is `.onHover` **on purpose**: it is the side that protects the main menu.
Changing it would not crash or warn, it would just quietly turn the menu into a wall of
text, so `HoverRevealModeTests` asserts the default rather than trusting it.

`.alwaysVisible` is the only workable choice for this window. The popover panel sets
`ignoresMouseEvents = true` — it can never receive hover — and it is already a
one-hover deep, so a nested "hover to expand" is a hover of a hover, and those
sections would never open at all.

Opening everything is not free, though: one provider card is a lot of content at
once, and the popover is capped at `0.95 ×` the visible height. That cap does
**not** truncate anything: over it, the content is wrapped in a `ScrollView`, so
the card is exactly as tall as it wants to be. The cap exists for one reason —
`popoverFrame` clamps the panel to `visibleFrame.height`, and an `NSPanel` does
not scroll itself, so anything past the screen edge would be unreachable. The
hard limit is the screen; the cap only guarantees the invariant
`heightCap ≤ visibleFrame.height`, which is what makes "if the frame ever got
clamped, the content is already scrollable" true. So
the popover is **not** simply the old menu card un-collapsed. Three layout rules
(`ProviderCardLayout`) still diverge, all keyed on the same mode, and all three are
read outside `ProviderCardView` (in `QuotaViews` / `QuotaHoverViews`):

| Rule | Other mode | Popover / strip hover | Why |
|---|---|---|---|
| `liftsProgressBar` | title, then bar | **bar first, no title row** | "how much is left" before the detail; the model name is not a row of its own but the leading token of the bar's metadata line (`Gemini Models 5h 62% weekly 59%`) |
| `splitsCachedInputRow` | `input: 1.2M (+860K cached)` | **`input:` and `cached:` on separate lines** | cached hides in parentheses, so a quick read only catches input — and cache hit rate is the number that says whether the call was expensive |
| `splitsRoundsRow` | `prompts: 42 (128 rounds)` | **`prompts:` with `rounds:` on the next line** | the three-column layout that forced it is gone; the row that still renders it in the popover is full width, where one number per line still reads better than a merged one |

The quota windows' side-by-side layout is no longer a rule at all: it had no reachable
consumer (`QuotaWindowsHoverView` / `QuotaUsageWindowsHoverView` are only built from the
model rows' menu layout, which the popover no longer uses), so the predicate was deleted
and the two columns are now unconditional.

Four more rules were deleted together with the menu's provider cards, because **all**
of their consumers lived in `ProviderCardView.swift` and belonged to the deleted menu
branch:

| Deleted rule | What replaced it |
|---|---|
| `splitsIntoTwoCards` | the card is unconditionally two cards with their titles outside |
| `hidesHeaderStatusDot` | the header row no longer draws a status dot at all (the `ProviderStateLabel` capsule on the same row already states the status) |
| `hoistsResetCredits` | the card layer always draws the reset row, below the progress bar |
| `hoistsPeakIndicator` | the card layer always draws the peak countdown, next to the reset row |

Keeping a rule whose only consumer is gone produces exactly the false signal this
table used to produce: a predicate that can only return `true`, a test asserting it
returns `true`, and no rendering anywhere that depends on it.

Because the rules are the *only* thing that differs, each is named rather than
inlined as `mode == .alwaysVisible` at the call site, and
`HoverRevealModeTests.testProviderCardLayoutTableConvergedToTheDockHost` pins what
survived, while `testStripHoverCardMustUseTheAlwaysVisibleRevealMode` pins the mode
the menu's own provider card is rendered with.

The popover's header is therefore not just "provider name + state" — it keeps
only what answers *how much is left* at a glance, and everything about *how was it
spent* sits below:

- **Peak indicator** (GLM / DeepSeek only)
- **Reset credits**, in its collapsed form (count + nearest expiry) via
  `revealsDetail: false`. Same reason as the account section: the panel can't be
  hovered, so per-card detail would be permanently expanded.

Each model block is then `QuotaBarWithMetadata` (its `name · 5h 100% weekly …`
metadata line + the bar), followed by the card-level rows and, for GLM, the
off-peak footnote. The block carries no divider of its own — see below. Two things
are deliberately **absent**:

- **No leading label on the bar.** An earlier pass pooled every model's bar into a
  header table, which forced each row to carry a dot + model name so the reader
  could tell them apart — and that label then duplicated the name on the metadata
  line. Each bar keeps its own block, so the label buys nothing.
- **No model-name row** (`QuotaWindowTitle`, which also carried the weekly
  multiplier). The name is the **leading token of the metadata line** instead —
  `Gemini Models 5h 62% weekly 59%`, `ChatGPT Plan 5h 62% weekly 30%`. It has to
  be *somewhere* now: with the three columns gone the block is a bar and one line
  of text, so Antigravity's two models would be two indistinguishable bars. Inline
  is the only place that works — a separate row splits one sentence in two, and the
  card header cannot carry it because the values are per model, not per provider.
  The name uses `MenuTypography.modelTitle` (11pt semibold) while the window labels
  and percentages stay at 10pt: the name is that line's subject, the rest is its
  predicates, and four equally-weighted words hide that. It truncates
  (`layoutPriority(-1)`, tail) when the line runs out of room — the percentages are
  fixed-width and the reset time is pinned right, so the name is the only thing that
  can give way. The menu passes an empty name: `QuotaWindowTitle` already labels
  that row, and repeating it there would be noise.

**No `QuotaDetailColumns`.** The popover used to show *Last Prompt | 5h | weekly*
as three equal columns under each bar. They are gone: all three report local token
usage from the same local session scan, which card 2 already shows in full
(`最近7天token用量` + its usage table), so the popover was saying the same thing
twice and burying the one thing that answers "how much is left" under three blocks
of numbers. The detail is not lost — it is one hover away in the menu, where
`LastPromptHoverSummaryView` and `QuotaUsageWindowColumn` are still the menu's
hover panels. `ModelQuotaDockBlock` therefore has no `columns` parameter at all:
the omission is structural, not a flag someone can flip.

The divider stays, but it moved **up** to the card layer: it used to sit at the end of
each model block, separating the quota overview from those three columns. It now
separates the quota overview (every model's bar + the reset/peak rows) from the
local-usage row below it, and since it has to span all models it is drawn once in
`ProviderCardView.dockBody` rather than once per block — per-block it would stack
into two adjacent lines between Antigravity's two models. Both sides come from
different data sources — provider API vs local session scan — and without the line
the local usage reads as a continuation of the quota.

`ModelQuotaDockBlock` has a `bar` parameter and no `title` parameter, so the title
omission is structural too.

Height is measured, not assumed. Opening four sections inline is easy to get
subtly taller — no crash, no warning, just a popover that scrolls or clips.
`testDockDetailStaysUnderTheRearrangedCeiling` lays the card out for real and caps
it: **1188pt** fully expanded → **915pt** after the first rework → **611pt** after
the dedupe + three-column pass → **648pt** after the reset-credits hoist and the
line splits → **628pt** after dropping the bar label and the model-name row
(ChatGPT dual-window with a full 7 days of local usage, the heaviest form) →
**650pt / 635pt / 617pt** through the two-section and two-card passes →
**679pt** after the 13pt titles, 10/11pt body type and the reset/peak hoist →
**505pt** after the three-column pass was dropped. Splitting cached and rounds
onto their own lines really does cost ~37pt; that is the trade. Do **not** compare
it against the menu card's height: that card is collapsed, so it measures ~120pt
and "the popover is taller than the menu" is the intended behaviour, not a
regression. The 550pt ceiling here is also a different number from
`popoverHeightFraction` — that one bounds the panel against the screen, this one
catches someone re-adding an always-expanded block. Do not copy one into the
other.

The first version had this inverted (`minY` + step, i.e. index 0 at the bottom) and
the test that "verified" it was named `testCircleCenterMatchesRenderedLayout` while
asserting the exact opposite of what SwiftUI renders. The guard against that class of
error is `testGeometryMatchesSwiftUILayoutForEveryEdge`, which **simulates** the
VStack/HStack layout and compares it against the geometry element by element.

Hover hit-testing therefore **cannot** be derived from `EdgeDockGeometry` constants alone.
Those constants guess SwiftUI's layout — text line height, `spacing`, `padding` — and
once a guess is off by even 1pt the error accumulates row over row until hovering a
circle pops a different provider's card. The rows measure their **real** rectangles
instead, and the row frame itself is pinned to the geometry constants
(`width: diameter, height: rowHeight`), so content size equals window size by
construction; the hover scale lives on the circle inside the row and `scaleEffect`
never participates in layout, so a measurement can no longer feed back into hit
testing at all.

Rows report those rectangles **directly** (`EdgeDockController.updateMeasuredRowRect`),
keyed by provider ID — not through a `PreferenceKey`. `onPreferenceChange` only fires
when the value *changes*, and the first layout pass hands it the `defaultValue` while
the real rectangles only exist once layout has run; without a further layout pass it
never fires again. The symptom is silent and severe: the measured rects stay empty,
every hit test fails, and because mouse capture is driven by a hit, `ignoresMouseEvents`
never turns off — so **hover and dragging die together**. `onAppear` / `onChange` have
no such timing condition.

Rects travel in the **view** coordinate space (`.global` = the `NSHostingView`), and the
controller converts to screen coordinates per frame. Screen-space rects would go stale
the moment the dock is dragged, moved, or moved to another display, because the view
space rects are stable while the screen-space ones are not.

Three rules keep this safe:

- **Rectangles travel keyed by provider ID, never by position.** The hit index is what
  `updatePopover` looks up `entries[index].id` with, so index misalignment is *wrong
  content*, not just a misplaced popover. `EdgeDockProjection.orderRowRects` rebuilds
  the array in `entries` order.
- **A row that has not been measured keeps its slot.** A missing ID becomes
  `EdgeDockProjection.unmeasuredRow` (an unreachable rect), never a skipped element;
  skipping would shift every later row up one index — the same class of bug.
- **There is always something hittable.** `resolveRowRects` falls back to
  `EdgeDockGeometry.rowRects` when nothing was reported, when the report is incomplete,
  or when the converted rects fall outside the dock (a sign the coordinate conversion
  is wrong). The fallback is off by a little; having no hit at all is not an option,
  because a miss also kills mouse capture and therefore dragging. The active source is
  logged (`命中来源 -> 实测 / 几何兜底`) precisely so this stays observable instead of
  degrading quietly.

Only the right-edge variant is authored; the other three come from an affine mirror
/ rotation. Hand-authoring all four means 16 arc segments, and a mismatched arc
start point makes `Path` silently connect the two points with a straight line —
cutting off the entire corner while `boundingRect` stays perfectly correct. The
tests therefore assert per-side corner containment (square ⇒ corner inside, round
⇒ corner outside) rather than only the bounding box.

Rejected alternatives (all tried): semicircular cap, four convex corners, an
outward flare on the screen side, and a concave fillet at the screen-side corners —
the last is not expressible as a fillet at all, since a circle tangent to both
edges of a rectangular corner only has its tangent points inside the rect from the
interior center.

### Background

The two surfaces are deliberately **not** the same, and that difference is the point:

| Surface | Fill | Why |
|---|---|---|
| Dock | **dark liquid glass**, fixed — `glassEffect` on macOS 26+, `ultraThinMaterial` + a black 0.34 layer below that, clipped by `EdgeDockTab` | It is permanently on screen next to the menu bar. Pinning it dark means the panel does not change character twice a day as the user switches the system appearance, and the rings' contrast is decided by one backdrop instead of two |
| Hover popover | `.regularMaterial`, following the system appearance, `popoverCornerRadius` | It is a temporary overlay the user asked for, and it is matched to the menu popup: same system material, same `ProviderCardView(status:)` sitting on top of it |
| Menu panel | AppKit's own glass for the `MenuBarExtra(.window)` window | The reference the popover is matched to |

The dock was once solid opaque black, and both were briefly one shared system material.
Neither is the current design: the dock stays dark on purpose, the popover follows the
system on purpose.

Both windows stay **transparent** at the window level (`isOpaque = false`, clear
background) and paint their fill in SwiftUI. For the dock this is because an opaque
window background would fill the whole window rect and hide the notch's rounded corner
outline, and because glass samples what is behind the window; for the popover it is
because **the material samples what is behind the window** — an opaque panel turns it
into a dead grey slab.

The menu's glass is supplied by AppKit for the `MenuBarExtra(.window)` window
specifically and is not inherited by a self-built borderless `NSPanel`, where
`Color.clear` would be plain transparency with no blur — so both surfaces request their
backdrop explicitly (`edgeDockDarkGlassBackground` / `edgeDockPopoverSystemMaterialBackground`).

**Forcing the dock dark takes two coordinated settings, never one.** The panel pins
`NSAppearance(named: .vibrantDark)` so the *material* resolves dark, and the hosted
content is wrapped in `\.colorScheme = .dark` so semantic colours (`Color.primary` in
the ring track, the number label) resolve light. Doing only the first yields dark text
on a dark slab; only the second yields light text on a light slab. The popover does
neither, and that asymmetry is intentional.

`EdgeDockTheme` remains the single place these values live.

### Hover behaviour

The dock window **never changes size on hover** — with one deliberate exception:
auto-hide mode (below), where proximity is what grows the window. **Hovering** a circle
opens a separate popover window beside the dock, containing the **same
`ProviderCardView(status:)` — the same card the menu's provider strip hovers for that
provider, so there is one card implementation, not a second lightweight variant. Two
"identical looking" cards would inevitably drift apart. Hover alone only highlights
the circle (the 1.10× scale).

| Aspect | Behaviour |
|---|---|
| Dock window | Fixed size while expanded. Only the hovered **circle** scales to `EdgeDockGeometry.hoverScale` (1.10×) inside its fixed row — the row frame, the number label and the window never move |
| Popover trigger | **Hover**, with a **0.15s open delay** (`selectedIndex` trails `hoveredIndex` by it; the click is reserved for dragging). `scheduleSelection` re-checks `hoveredIndex` when the delay elapses, so sweeping the cursor down a column of circles re-arms the timer for each one instead of flashing every card in turn. `scheduleDeselection` collapses the card 0.20s after the cursor leaves the circle, unless it entered the card itself. The delay is not cosmetic: the dock is **permanently** on the screen edge, and a cursor merely passing by (dragging a window to the edge, turning a page) would otherwise make cards strobe. Clicking is a drag candidate only — `dragMoved` gates on a 4pt threshold and a press that never crosses it does nothing at all |
| Popover | Second `NSPanel`, `ignoresMouseEvents = true` (read-only, never steals focus), level `.popUpMenu` so it sits above the dock. Renders the same `ProviderCardView(status:)` the menu's provider strip hovers — so the dock's popover and the menu's hover card are the same object at the same width and the same layout, not two near-identical ones. In the dock it lays out as **two cards with their titles outside**, see *Two cards, titles outside* below. An open card is re-rendered on every status broadcast (`reconcile`'s no-op-frame branch refreshes it), so it never shows numbers frozen at the moment it opened |
| Hit test | `EdgeDockController.circleIndex(at:circles:currentHovered:minimumRadius:)` — the provider's **outer circle only** (radius + 0.5pt), which deliberately excludes the number label below it and the gaps between rows. The hovered circle's disc grows by `hoverScale` to match its on-screen scale animation. `minimumRadius` is a floor, not an override: the compact dock's circles are 7pt (radius 3.5) and it passes **half a row pitch** (7.5pt) so adjacent discs meet at their midpoint — pointing at a 7px target without it snaps to a neighbour. Circles come from `resolveCircleRects` (measured, with an `EdgeDockGeometry` fallback that is **appearance-aware** — the full-approach constants put compact row 0 about 24pt off). Never recomputed from constants alone — see *Edge status dock → Layout* |
| Anchor | Vertically centred on the hovered **row** (measured rect when available; `EdgeDockGeometry.rowCenter` is only the "not measured yet" fallback), opening **inward** (docked right → opens left) |
| Size | **Fixed width** `EdgeDockTheme.popoverWidth` (derived from the 7-day chart, see *Popover width*), height = natural card size clamped to 95% of screen height; a `ScrollView` replaces the plain card only when it exceeds the height cap, so overflow scrolls instead of being clipped |
| Dismiss | Cursor leaving either the dock or the popover **by frame** takes effect after a **0.5s grace delay** (cancelled on return; see *Auto-hide mode → Collapse*). Each window's frame + a 12pt tolerance; `hoverPadding` must stay > half of `popoverGap` so the two tolerance zones overlap in the 10pt gap between the windows and capture never drops while crossing. The popover's zone counts **only while the card is visible** — `orderOut` leaves the frame where the card last was, and an unfiltered read reserves keep-capture space for an invisible card. Capture is deliberately **not** hit-based: the circle hit area is a 38pt disc, which leaves the padding strips and gap diagonals of the black tab uncovered — releasing there collapsed the dock while the cursor was still visibly on it. Release clears `hoveredIndex` / `selectedIndex` and any pending open/close work item |

Because both windows participate in the same capture region, moving the cursor
onto the popover keeps it open — and the popover's host status is looked up by
**provider ID**, not array index, because the projection filters out disabled
providers and the two indices can drift apart.

#### Two cards, titles outside

The dock popover is **two cards**, each with its title drawn *outside and above* it.
This used to be `ProviderCardLayout.splitsIntoTwoCards` on for `.alwaysVisible` only,
with the menu column of short cards keeping one card whose header sat inside it; that
column is gone (the menu is the client view now), so the split is unconditional — the
menu's provider strip hover shows the very same two-card layout.

| | Title row (outside, above the card) | Card |
|---|---|---|
| 1 | brand logo + provider name + plan capsule, with the refresh time / state label on the right — **no status dot**; the dot sits right next to the brand logo and the two small circles read as "the logo with a green pip", while the capsule on the same row already states the status | per model: `<name> 5h 62% weekly 30% <reset time>` and the progress bar; then reset credits, the peak-window countdown, a divider, the **quota-window usage block** (see below), then the local-usage **summary** row (`📈 今天 …`) |
| 2 | `最近7天token用量`, with the local-usage freshness as a **capsule** (`更新于 HH:mm` / `计算中…`) on the right — same font, weight and colour as title 1, because the two rows are the same kind of thing: the name of their card | the 7-day chart, its usage table and the footnote |

**Card 1 reads top-to-bottom as summary → local usage.** The metadata line moved
*above* the bar (read the description, then the graphic), the bar now keeps vertical
breathing room, and the reset/peak rows moved *below* the bar, above a divider that
separates them from the local-usage row — they are context for the quota, and the
row under the line comes from the local session scan, not the quota API. Those
two rows are provider-level but sit in the middle of a per-model block, so they travel
through `QuotaSummary.betweenBarAndColumns` → the model row → `ModelQuotaDockBlock.between`
(type-erased as `AnyView`, only the first model row receives a non-empty value). The
divider is drawn by the card itself (`ProviderCardView.quotaUsageDivider`), not by
each model block, so it spans the whole quota group; it is the same one the chart
uses below itself (`Divider().opacity(0.45)`, full content width, no extra
horizontal inset).

**Type scale inside the two cards: 13 / 11 / 10.** Card titles are
`MenuTypography.cardTitle`; values and body text are 11 (`hoverBody*`, and `hoverTitle`
was pulled down to 11 so a sub-title is no longer bigger than the values under it);
labels, captions, footnotes, day labels, chart annotations and table cells are 10 —
the 8pt and 9pt sizes that used to live in the chart and the table are gone
(`timeSuffix` and `hoverFootnote` moved from 9 to 10). Capsules keep `badge` at 9pt,
since a pill is a different kind of mark, not body copy.

The cut is not arbitrary: the quota group is "now" and the 7-day group is "history", and
`HoverInfoRow` already drew a separator between them. The card boundary replaces that
separator, so the lower half stops reading as a table appended to the upper card. The
split rides on `LocalUsagePart` (`.summary` into card 1, `.detail` into card 2,
`.combined` for the menu), which is also why the chart no longer draws its own title row
in `.alwaysVisible`: the title and the freshness badge moved up into title row 2.

Two knock-on details, both easy to miss:

- The reset-credit row starts with a `Divider` when it sits under the header in the menu.
  Once it moves between the bar and the statistics that divider would hang a line in the
  middle of the summary block, so the row takes `divides:` and the dock passes `false`.
- Both cards use `.frame(maxWidth: .infinity)`. Sized to their content they would have
  different widths (card 2 is only the chart) and the stack would show two misaligned
  plates.

Non-`.ok` states (loading / failed / not configured) fall back to a single card: there
are no two groups to cut, and splitting anyway would leave a second card holding nothing
but a placeholder.

#### Quota window usage block

Inside card 1, **below** the quota/local-usage divider and above the `📈 今天 …` row,
there is one block that answers "how much did *this machine* burn inside the current
quota window?". It is rendered by `QuotaWindowUsageSection`
(`Views/QuotaWindowUsageViews.swift`), in the same `.alwaysVisible` card the dock
popover and the menu's provider strip hover both show.

| Part | Content |
|---|---|
| Bar | **Time composition, not bucket composition**: the full bar is the local token total inside the current **weekly** window; the solid left segment is the part inside the latest **5h** window, the translucent right segment is the rest of the week. Grey trough. 6pt Capsule, provider accent colour. Deliberately *not* `TokenBucketBar` (that one splits input / cache / output) and not `SegmentedQuotaProgressBar` (that one encodes a remaining percentage) |
| One row per window | `5h 173M · 命中 97.8% · 出/入 12% · 思考 41% · ¥12.34` — five short metrics, 10pt `monospacedDigit`, **one line, never wrapped**. When the width is genuinely insufficient, `ViewThatFits` falls back to compressed labels (`出比` / `思`); the numbers themselves are never shortened, because two rows of numbers read as two different subjects |
| Hover detail | per window: the four absolute buckets (`input` / `cached` / `output` / `reason`, `input` being the **uncached** one), that window's nominal value, and that window's reset time. The two windows sit **side by side**, so the same bucket lines up horizontally |
| Hover detail, reset credits | appended below the buckets: the **per-card list** of available reset credits (count + each card's expiry), rendered by `ResetCreditsDetailList` — the same view the reset-credit row's own hover uses |

**Value (the fifth metric)** — `ModelPricingCatalog.estimate` over the window's
**already filtered samples** (the very array the four buckets are summed from, so token
count and money can never describe different sets of samples), in the **original
currency** (`¥` / `$`) with no local-currency conversion, matching the 7-day table and
the client summary. DeepSeek's ×2 peak multiplier is evaluated **per sample timestamp**
(the `deepseekPeakWindow` travels with the status), so a window straddling a peak
boundary is not doubled as a whole. `—` means no local samples in the window; `未定价`
means samples are present but the catalog has no price for them. Summing several model
pools adds their money only while the currencies agree — a mixed-currency sum returns
nil rather than a meaningless total.

Ratio formulas (all three return `nil` — rendered `—` — when their denominator is 0;
`0%` would read as "the ratio really is zero"):

| Ratio | Formula |
|---|---|
| 命中 cache hit | `cached / (input + cached)` |
| 出/入 output to input | `(reason + output) / (input + cached)` |
| 思考 reasoning share | `reason / (reason + output)` |

Data source and calibration:

- Windows are the **same** ones the quota rows use — `LocalUsageSummaryBuilder.windowBounds`
  (`intervalResetsAt` / `weeklyResetsAt` pushed back by the window length) feeding
  `LocalUsageSummaryBuilder.windowSamples`, so the GLM off-peak exclusion
  (`excludeWindows` + `excludeGlmOffPeak`) applies here exactly as it does above. ChatGPT
  keeps its `codexUsageDetails` + OpenCode path via `ChatGPTPlanModelRow.windowUsages`.
- A provider with several model quotas is **summed per window** (`combineWindowUsage`):
  `modelMatches` already partitions the samples per model quota, so the pools do not
  overlap. The reset time shown is the **earliest** one, and the detail says so whenever
  more than one pool contributed.
- **Degenerate cases**: a provider with only one of the two windows shows only that row
  and the bar becomes a single segment; a balance-only provider (DeepSeek API balance,
  no quota window at all) renders **nothing** — not an empty bar; a window with zero local
  usage still shows its row with `0` and `—`.
- Both card hosts live in panels with `ignoresMouseEvents = true`, so the detail is
  rendered **in place** by `HoverInfoRow`'s `.alwaysVisible` branch — it is the only path
  by which the four buckets are ever visible. That is why the card grew (measured 506pt
  → 664pt) and why the ceiling in
  `HoverRevealModeTests.testDockDetailStaysUnderTheRearrangedCeiling` moved 550 → 700.
- **Reset credits reachability.** The reset-credit row in the quota area is
  `revealsDetail: false`, and both hosts swallow mouse events, so a pure hover cannot
  open its per-card list. The per-card list therefore rides this block's detail panel —
  it is the only in-place expansion point the card has, and "how many credits do I have
  and when do they expire" answers the same question as the four buckets ("what did this
  round of quota actually go on"). `QuotaWindowUsageSection` renders whenever
  `resetCredits != nil`, even if the snapshot itself is empty; the bar and the metric
  rows stay hidden in that case.
- **Height ceiling.** `testDockDetailStaysUnderTheRearrangedCeiling` measures the
  *lightest* card (no reset credits, no local samples in the window). The realistic
  case — reset credits present, samples present, hence two more value lines plus the
  per-card credit list — is guarded separately by
  `testDockDetailWithTheFullestQuotaWindowSectionStaysUnderTheSameCeiling`
  (measured 745pt, ceiling 800pt). Both are needed: the light fixture alone would not
  notice the last two additions.

### Dock modes (compact form)

`EdgeDockConfig.mode` (Settings → 常规 → 边缘状态窗 → 形态), a four-way picker:

| Mode | Screen |
|---|---|
| `hidden` 无 | Nothing is drawn |
| `statusWindow` 状态窗 | Always the full appearance |
| `compactRings` 小圆环 | Always the compact form; proximity never expands it |
| `autoHideWindow` 状态窗（自动隐藏） | Compact form, expands on proximity (**default**) |

**One enum, not two switches.** The previous pair (`enabled` + `autoHideMode`) spelled
four combinations, one of which (auto-hide while disabled) is meaningless, and neither
of the two real forms had a name of its own — a switch labelled 「自动隐藏模式（收起为
小圆环）」 only tells you the *other* setting by negation. A four-way picker gives every
form a name that matches what is on screen and removes the intermediate state where two
switches both govern one thing.

`hideInFullscreen` stays a **separate** toggle: it answers "when does it get out of the
way" (an event), not "what does it look like" (a shape); the two are orthogonal, so the
toggle still has a meaning under every mode except `hidden`.

**Legacy configs** (`enabled` / `autoHideMode`, no `mode`) decode as the **default**
mode. Mapping the two old booleans onto the enum was rejected: it would keep a
translation table alive for fields nobody can see in the current UI, and the dock is
still an unreleased feature, so falling back to the default is the cheaper mistake. A
hand-edited *unknown* `mode` string also decodes as the default rather than throwing —
`ConfigStore` uses `try?` on this block, so a throw would drop the user's dragged edge
and offset along with the bad value. The four modes:

- **Compact form** (shared by `compactRings` and collapsed `autoHideWindow`) — flush to
  the edge, one small single ring per enabled provider. Its size is a **user choice**,
  `config.compactSize`, three tiers (`EdgeDockGeometry.compactMetrics(for:)`):

  | Tier | Ring | Stroke | Gap | Padding | Edge thickness | Row step |
  |---|---|---|---|---|---|---|
  | 小 small (**default**) | 7pt | 2.5pt | 8pt | 7pt | 21pt | 15pt |
  | 中 medium | 11pt | 3.5pt | 10pt | 10pt | 31pt | 21pt |
  | 大 large | 14pt | 4pt | 12pt | 12pt | 38pt | 26pt |

  A tier is a **whole** set, not one number: scaling only the ring would leave the
  spacing and padding behind and the column reads as a mistake. Three tiers rather
  than a slider because the four metrics have hard constraints between them
  (stroke must stay visible yet not eat the ring centre, the compact window must
  stay smaller than the full form's 70pt, half a row step must stay a pointable
  target) — a slider can produce most combinations, and all three tiers are checked
  against every one of them. The default is 小 because that is what the screen
  showed before the setting existed. No number label, no brand logo. The ring is the
  **5h interval fraction**, falling back to the weekly fraction for providers with no
  5h window (same precedence as the full dock's number label — a blank ring would
  silently drop information), dim track only when neither exists.
- **Expand** (`autoHideWindow` only) — cursor within the usual 12pt proximity of the
  compact window sets `isExpanded = true`; the window frame and the content **animate together**
  (`contentMorphDuration`, 0.25s easeOut, both started in the same tick): the AppKit
  `setFrame` animation moves the window center along the edge to the full-form
  position while the SwiftUI content morphs from compact to full — one view tree
  whose row frames, spacing, padding and ring diameters interpolate, with the inner
  ring / brand icon / number label fading via opacity transitions. The two layers
  must stay in lockstep: the full frame and the compact frame have **different
  centers** for the same normalized offset (`frame()` anchors by offset × remaining
  travel, which depends on size), so any *instant* window swap — grow-first or
  shrink-after — re-centers the content by up to tens of points and reads as a
  repositioning flicker. A synchronized continuous animation is the only ordering
  reads as a
  repositioning flicker. A synchronized continuous animation is the only ordering
  with no seam at either end. In this mode expansion is the *whole* response: no
  per-row hover while collapsed — once the full layout is up, the usual per-row hover
  takes over (a 7pt target is too small for per-row hit-testing to be anything but jitter,
  but at full size it is not).
- **Collapse** — the cursor leaving both the dock and the popover schedules collapse
  after a **0.5s grace delay**; the deadline is *fixed*, not re-armed (the 0.2s probe
  timer keeps hitting the "still outside" branch and a debounce-style re-arm would
  push the deadline forever). Returning inside the grace window cancels it, so a
  quick sweep across the edge doesn't flash the dock out and back. At the deadline
  the keep-alive region is re-checked, then capture releases and the window and
  content animate back **together** (same synchronized 0.25s, reverse direction) —
  no second-phase snap, nothing to settle afterwards. While the morph is in flight,
  `reconcile` refuses *standard* frame updates (`isFormMorphInFlight`) so a status
  broadcast can't restart the window animation mid-flight, and a form transition
  itself simply retargets (rapid reverse switches stay continuous). This cannot
  oscillate: for the same normalized offset the full frame always *contains* the
  compact frame (`frame()` grows the window outward from the same anchor), so
  leaving the full frame means leaving the compact frame's proximity too.
- **State** — `EdgeDockController.isExpanded` is the single published flag;
  `isCompactAppearance` is the one predicate both `reconcile` (window size) and
  `EdgeDockContentView` (layout) read, so the window and its content can never
  disagree about which form is showing. It derives from the mode
  (`staysFullWhenIdle` → always full; `expandsOnProximity` → `!isExpanded`; otherwise
  always compact) rather than re-deriving the shape from two booleans at each site.
  Switching mode resets to collapsed; a drag-persist write does **not**, so the dock
  doesn't flicker while you're hovering and it saves its position.
- **Geometry** — `dockSize(entryCount:edge:appearance:compactSize:)`; `appearance`
  defaults to `.full` so the full-form call sites are unchanged, and **every compact
  path passes `compactSize`** (window, drag, hit-test fallback, popover, mouse floor).
  The fallback hit-test geometry (`rowRects`, `rowCenter`, `circleRects`,
  `circleCenter`, `popoverFrame`) is **appearance- and tier-aware**, not
  full-appearance-only: the full-form constants put compact row 0 about 24pt off, and
  they do it per tier (小 row 0 is off by 31pt at 大). In `compactRings` the dock *is*
  row-hit-tested, but it uses the **measured** row rects (the view reports them in
  both appearances) and a hit radius floor of half the compact row step
  (`compactRowStep(for:) / 2`, 7.5/10.5/13pt by tier) rather than the ring radius: a
  7pt ring demands pixel-precise pointing, and at half a row step the neighbouring
  hit zones meet at the midpoint. `popoverFrame` likewise takes the measured row
  centre, because its fallback assumes the full form's 54pt row step and would hang
  the card tens of points below the ring it belongs to.
- **Tier changes are a form transition** — changing `compactSize` while the compact
  form is showing routes through `.collapse`/`.expand` (0.25s, same curve) like any
  other form change, and the content's `.animation(_:value:)` is keyed on a
  `formSignature` of *appearance + tier*, not on `isCompactAppearance` alone. Keying
  on appearance alone made the content snap while the window animated: the window
  side alone would then be the layer moving by itself, which is the exact failure the
  shared-curve contract exists to prevent. While the full form is showing the tier
  has no consumer, so a tier change there is an ordinary `.standard` update.

### Dragging

Dragging does **not** use `isMovableByWindowBackground`. Free movement would let
the panel detach from the screen edge and float mid-screen, while the user's
actual intent is "nudge it along the edge". `EdgeDockController.applyDrag`
replaces the window frame directly from the mouse position on every capture tick:

- **Perpendicular axis is pinned to the edge** — vertical edges only track `y`,
  horizontal edges only track `x`, so a drag always slides along the edge.
- **Edge switching needs a clear margin** (`EdgeDockGeometry.edgeSwitchMargin`,
  40pt). Flipping to a new edge requires the mouse to be that much closer to the
  new edge than the current one; otherwise hovering near a corner makes the dock
  flicker between edges.
- Releasing snaps, animates, and persists `{edge, offset}`.

Pressing the mouse **on the dock** starts a drag and dismisses the popover;
pressing on the popover does not move the dock. A hidden dock never starts one:
the hide paths only `orderOut` (the stale frame remains), so the mouse-down guard
also requires `panel.isVisible`.

**Drag follows only drags that started on the dock.** `.leftMouseDragged` guards
on `isDragging` instead of setting it. The global monitor delivers drag events from
**every other app** — dragging a window, selecting text, pulling a slider — and an
unguarded handler used to call `applyDrag` for each of them, teleporting the dock to
the mouse and persisting the drifted position on release. This is safe to gate
because a mouse-down landing on the dock is always observed first by one of the two
monitors: captured dock → the event is delivered to our app → local monitor;
pass-through dock → the event goes to the app below → global monitor.

**The dock's display comes from config, not from focus.** `targetScreen` resolves in
three layers, in this order:

1. **`config.screenUUID`** — the display the user parked the dock on. This is the
   only path onto a secondary display, and it is a *display UUID*
   (`CGDisplayCreateUUIDFromDisplayID`), never a screen index or a coordinate:
   `NSScreen.screens` order follows the "primary display" setting and the
   arrangement, and two same-resolution displays have identical geometry, so both
   would let the dock move by itself. The UUID survives re-plugging, changing ports
   and rearranging displays. (`CGDirectDisplayID` would not — it is re-enumerated
   per boot.)
2. **`panel.screen`** — the fallback when no display is configured, i.e. exactly the
   pre-multi-display behaviour. `NSScreen.main` is *not* usable here: it follows
   keyboard focus, so clicking any window on another screen used to relocate the
   whole dock, reading as random drift.
3. **Main screen, then the first screen** — start-up, before any window exists.

Layer 2 verifies that `panel.screen` is still in `NSScreen.screens` (compared by
display id): reconfiguring or unplugging a display replaces the `NSScreen` object, and
computing a `visibleFrame` from an object that no longer belongs to a display parks
the dock somewhere invisible.

**A vanished display is resolved, not remembered.** `dropScreenUUIDIfVanished` runs
at the top of `reconcile` — before anything reads `targetScreen`, so the same pass
already positions the dock — and clears `screenUUID` when no attached display
carries it. Falling back *in memory* would be worse than not recording it: the UUID
in `config.json` would point at a display that no longer exists forever, and every
launch would redo the "cannot resolve, guess the main screen" dance. Clearing it
restores layer 2, the only semantics that survive the display being gone.

**Dragging across displays.** `dragVisibleFrame` asks which display the *cursor* is
on, not how far it is from an edge: two adjacent displays share a single boundary
and the cursor sitting on it counts as inside both, so a distance comparison
oscillates. Two conditions must both hold, and the mirror-display case is the reason
the first is not optional — mirrored displays share one display id but have
different `visibleFrame` coordinate spaces, so switching "screens" there would place
the dock at a wrong position on the same physical display. When the current display
id cannot be read at all, no switch happens: a wrong switch is invisible to the user,
who then has no idea why their dock left.

`offset` is a ratio along the current screen's edge, so it survives a display
switch as the same *relative* position — dragging a centred dock to the next display
leaves it centred, which is what a drag means here.

**UUID lookups are memoised.** `CGDisplayCreateUUIDFromDisplayID` costs ~15µs (one
WindowServer round trip) and `targetScreen` is consulted on every drag event.
`EdgeDockDisplay` caches by display id for the lifetime of a boot and prunes on
`didChangeScreenParametersNotification`.

**Drag must be event-driven, never timer-driven.** The capture timer runs at
`capturePollInterval` (0.2s) because it exists to answer "is the mouse still over
us?" — that is a 5Hz question. Drag events arrive at 60–120Hz, so moving the window
from the timer makes it jump one step every 200ms, which reads as dropped frames.
`.leftMouseDragged` therefore calls `applyDrag` directly; the timer keeps a
redundant call purely as a safety net (absolute positioning makes it idempotent,
and it is equally gated on `isDragging`).

### Mouse polling budget (2Hz, not per-event)

The dock reacts to hover and to the cursor approaching the screen edge. The obvious
implementation — a system-wide `mouseMoved` monitor — turns out to be the one
expensive thing in the whole feature, and not because of the work it does:

| Cost | Measured |
|---|---|
| The probe body (hit test + geometry + reading the cursor) | **≈3 µs** |
| AppKit **waking the process** for a system-wide mouse move, ×100–1000/s | the actual bill |

A menu-bar app that registers `addGlobalMonitorForEvents(.mouseMoved)` gets scheduled
every time the pointer moves *anywhere on the system* — 100–1000Hz while the user
waves it. The probe body is a rounding error next to that wake, so the fix is not to
make the probe cheaper (it is already cheap) but to **stop being woken**.

Hover therefore runs on a **2Hz poll** (`hoverPollInterval`) instead of an event:

- `.mouseMoved` was **removed from both monitors' masks**. The masks now carry only
  `[.leftMouseDown, .leftMouseDragged, .leftMouseUp]` — exactly the events dragging
  needs, which must stay event-driven because a 0-latency window move is the whole
  point of the drag. Hover, proximity-expand and collapse are answered by reading
  `NSEvent.mouseLocation` from the timer.
- The poll exists only while the dock is **visible** (`startHoverPoll` /
  `stopHoverPoll` in `reconcile`'s show / hide branches), and probes immediately on
  show so a freshly revealed dock does not take half a second to notice the pointer.
- Nothing is lost by polling slower than the pointer: the question hover asks
  ("which circle is under the cursor") only changes when the cursor moves, and
  a *faster sweep* now samples fewer positions — fewer accidental card flashes.
- The projection is still computed **only when the cursor is inside the dock's
  keep-alive region**. Off-dock probes cost two `CGRect.contains` and nothing else.
  A projection cache was tried and removed: at 2Hz the whole-column projection
  (≈37 µs) costs 0.007% of a core, and a TTL'd cache would be pure complexity.

**Latency is the price, and it is bounded where it matters.** Ring highlight, card
open and proximity-expand all land within `hoverPollInterval` (0.5s) of the pointer
arriving. Once the cursor is actually over the dock, `captureMouse()` starts the
0.2s `capturePollInterval` timer, and hover drops to 0.2s — the visible 0.5s is
confined to the half-second *before* arrival. Releasing the capture stays prompt
too: the 0.2s timer is what detects the pointer leaving, followed by the 0.5s
`collapseDelay` grace.

Swapping back is one constant: raising `hoverPollInterval` back to a frame and
restoring `.mouseMoved` to the two masks reinstates event-driven hover, with the
projection computed only inside the keep-alive region as it is today.

Two supporting details for drag, both about the same per-event budget:

- The provider projection is computed **once at mouse-down** (`dragEntryCount`). It
  walks every provider's quota aggregation, which has no business running 120×/second.
- `setFrame(..., display: false)`. Forcing a synchronous redraw per event saturates
  the main thread; the window server composites the move anyway.

Fullscreen handling: `FullscreenProbe` reads window *bounds* only via
`CGWindowListCopyWindowInfo` (no Accessibility or Screen Recording permission prompt) and
hides the dock when the current Space has a normal-layer window covering the whole screen
**and** that display has no desktop chrome. The second half is what separates a real
fullscreen Space from a zoomed window: with both the menu bar and the Dock set to
auto-hide, `visibleFrame == frame`, so a zoomed window covers `screen.frame` exactly and
coverage alone cannot tell the difference. Desktop chrome (the Finder desktop-icon window,
`kCGDesktopIconWindowLevel`) is absent on every fullscreen Space and present on every
normal one, and hiding the menu bar does not remove it. `.excludeDesktopElements` must
therefore stay off, since it filters out exactly that window; the negative-layer windows it
admits are ignored by the `layer == 0` candidate filter. The chrome layer is matched
exactly, never as a band — WindowServer and WindowManager keep persistent windows at
neighbouring levels even while fullscreen, so a band test would turn every fullscreen Space
into a miss. This is **fail-open** and one-directional: the chrome test can only turn a
`true` into a `false`, so when chrome cannot be read at all the probe degrades to the old
coverage-only answer rather than hiding more. Any failure returns `false` and the dock
stays visible, because a panel that hides itself on a probe failure and never returns is
worse than brief overlap. The dock's own windows are excluded from the probe so it cannot
classify itself as fullscreen.

AX (`AXFullScreen`) was evaluated and rejected: it is not in the public SDK (only the
fullscreen *button* element is), it needs an Accessibility grant that ad-hoc builds lose on
every rebuild, and it answers "is this window fullscreen" without saying *which Space* — a
fullscreen window on another Space still reports `true`, which would hide the dock on a
plain desktop.

Dragging moves the panel freely (`isMovableByWindowBackground`); on release it snaps
to the nearest edge and persists `{edge, offset}` through `ConfigStore.applyAndSave`.

| State | Dock |
|---|---|
| `mode == .hidden` | Not created / ordered out |
| No enabled Provider (entry count 0) | Ordered out — no empty shell on the screen edge |
| Fullscreen window on the target screen's current Space, with `hideInFullscreen` on | Ordered out, restored on exit |
| Otherwise | Visible, click-through |

`hideInFullscreen` defaults to **on**: the option was added after the behaviour, so the
default has to preserve it — defaulting to off would put a dock inside every fullscreen
window for every existing user. Because the setting can be flipped while the user is
already fullscreen, a policy change re-probes instead of reusing the cached verdict.

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

`nextRefreshAt` is the earliest next due time across enabled providers, published by the
single `ProviderRefreshScheduler` Task (no per-provider timers). After
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

`ProviderCardView` 现在只有**一个**渲染宿主形态：边缘状态窗的 provider 详情浮层，
以及菜单底部 provider 兜底行 hover 出来的那张卡（两者都固定 `.alwaysVisible`）。
菜单内容区是客户端视角，不再渲染 provider 卡，因此这张卡没有"菜单形态"了。

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
| Status dot | **不再画**。它紧挨着品牌图标，两个小圆读起来像"图标带了个绿点"，而同一行右侧的 `ProviderStateLabel` 已经把状态说清楚了。承载它的 `StatusIndicator` 视图已随之删除（那两处以它为参照的注释也改成了不依赖类型名的说法） |
| Provider icon | bundled brand asset in an `18x18pt` frame; OpenAI follows the system foreground color and missing assets use a recognizable SF Symbol fallback |
| Display name | 14pt bold |
| Plan tag | shown when a fetched provider supplies a plan label (for example, ChatGPT plan type) |
| State tag | compact `未配置` / `待更新` / `已更新` / `需重试` label; a spinner replaces it while loading. `未配置` (not `未启用`): `.notConfigured` covers a missing API key, missing external auth and missing login as well as a disabled provider, and `未启用` made an enabled-but-keyless provider read as switched off |
| Account block hover | **已删除**。邮箱 / 数据来源原本按 provider 分三路包在标题行的 `HoverInfoRow` 里，只为菜单那张卡服务；菜单不再渲染 provider 卡，浮层又不吃鼠标事件，这个折叠区展不开，直接不画 |
| Seven-day local statistics | 不在标题行，在**本地用量那一段**（`LocalUsageFooterView` → `SevenDayTokenUsageHoverView`）：`.alwaysVisible` 下就地展开成第二张卡的内容，`.onHover` 下才是悬停弹层 |

状态点的配色（已连同视图删除）原为：healthy 绿 / warning 橙 / critical 红，
`nil` 健康度显示灰点；语义色本身仍由 `healthyTint` / `warningTint` 提供。

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
| `请先启动 Antigravity 并完成登录` | Antigravity / agy CLI 进程未发现或未监听本地端口 |

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

- show after 0.22s hover delay
- when the panel is already visible, switching to a neighboring row re-shows after a 0.08s debounce (`HoverPanel.swift` 的 `effectiveDelay`)
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
- **the menu's provider fallback strip**: hovering one provider element shows the full
  `ProviderCardView(status:)` for that provider, at the dock popover's card width
  (`EdgeDockTheme.popoverWidth` − backdrop padding) and in its `.alwaysVisible` layout
  — the same card the dock shows, reached from the menu. Vertical fit is handled by
  `frameForPanel` clamping to the screen's visible frame (fullest card ≈ 745pt).

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
- 单条 `GLM Coding Plan` 模型行（`QuotaInfo.displayName`，不再硬编码具体模型名）：智谱 Coding Plan 的 5h + 周积分是套餐共享池，合成一条展示，标题右侧显示 `5h × 5 = 周`（周积分 = 5 × 5h 积分：Lite 2000/10000、Pro 12000/60000、Max 28000/140000）。
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

ChatGPT's 5h / weekly summaries retain the preaggregated native Codex totals and
add only the enabled OpenCode contribution. The native samples already represented
by those totals are not added a second time; when native details are unavailable,
the row falls back to aggregating the available combined samples.

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
| Data column | 双窗口 `5h X%  周 Y%` 使用 `quotaCombinedDataColumnWidth` 固定 **152pt** 宽，单窗口使用 `quotaSingleDataColumnWidth` 固定 **80pt** 宽；两者均左对齐，让 reset time 从一致的 x 位置开始。内部 per-percent 框保持 "5h" 和 "周" 列对齐 |
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

The 周倍率 label（`周倍率：N`，标题右侧）expresses a provider-specific equivalent quota ratio, not a conversion of elapsed time. If reset time is missing, the line shows `—`.

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

Progress bar fill (`SegmentedQuotaProgressBar.intervalSegmentColor` /
`weeklySegmentColor` and `ModelQuota.colorLevel`):

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

## Quota Notifications (system + Bark)

After each successful remote quota request for a windowed provider (`ProviderKind.windowedKinds`:
ChatGPT, GLM, minimax, Antigravity), `QuotaEventDetector` compares the result with that
provider's persisted baseline (`TriggerStateStore`, `notification-state.json` — survives
restarts, so exhaustion/recovery events that happen while the app is down are reported on the
first refresh after relaunch). Four event kinds, each with an independently configurable
channel (`off` / `system` / `bark+system`, defaults: restored → system, exhausted → off):

| Kind | Edge |
|---|---|
| restored (5h / weekly) | rise > 5 pp, or back above 98% with a strict rise (parking at 100% is not a rise) |
| exhausted (5h / weekly) | remaining percent crosses below 0.01% |

The first snapshot, a newly appearing model or window, and decreases do not notify. Per-model
merging applies: one refresh produces at most one system notification and one Bark push per
model, and each channel's body only contains events routed to that channel. System titles
reflect the event kind (「额度已用完 / 已恢复 / 额度提醒」); Bark carries a stable per
provider+model overwrite `id` so new pushes replace old ones on the phone. Both channels
apply a 60-second per-model cooldown. DeepSeek is balance-based (binarized 0/100) and has no
window triggers; a balance threshold trigger is future work (see `spec/notifications.md`).

At application launch, notification authorization is requested only when the system status is
`.notDetermined`; an existing allow or deny choice is not prompted again. Notifications remain
visible as a banner with sound while the menu app is in the foreground. UserNotifications is
available only from a packaged `.app` with a Bundle Identifier, so raw `swift run` / SwiftPM
executables disable the system-notification channel safely (Bark, being plain HTTP, still
works there).

The optional Bark push (Settings > General > Bark 推送) posts JSON to
`POST {server}/{key}` and is skipped when the user is at the Mac: with
`skipWhenAwakeAndUnlocked` enabled, Bark is skipped only when the display is awake **and**
the session is unlocked; display sleep or a locked screen (user away) both deliver.

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
