# Edge Status Dock — UI Spec

This file is one of the three UI specs split out of `spec/ui-design.md` (now the
index). It documents the screen-edge panel: circle anatomy, anchor geometry,
hover popover, dock modes, dragging and the 2 Hz mouse-poll budget — the parts of
`Sources/LLM-monitor/Views/` that render outside both the menu and the Settings
window.

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
| **Outer ring** | Effective 5h quota = per-model `min(5h remaining, weekly remaining × N)` via `aggregateActualAvailable` — the same caliber as the iconDuo centre fan / `aggregateHealthLevel` | **worst** model by that effective quota |
| **Inner ring** | Weekly window remaining | `weeklyRemainingPercent`, **worst** model, **raw** (not multiplied by `weeklyEquivalentMultiplier` — the inner ring answers "how much weekly quota is left", and multiplying by the equivalence factor N would stop being that) |
| **Centre** | Which Provider | `BrandLogoView(kind:size:)` at a fixed 14pt (`EdgeDockGeometry.iconSize`) — the same real brand asset the menu cards use, sized to stay inside the inner ring's inner edge (inner ring is `0.72 × 38 = 27.4pt`, so its inner edge sits at a 12.2pt radius against the icon's 7pt half-width). The size is **passed into the view**, never framed from outside: see *Logo sizing is the view's job* below |

Each ring's length is the **minimum** across the provider's models that have that
window — and the outer ring reads the **effective 5h quota** above, not the raw 5h
percentage: a weekly budget that is tighter than the 5h window once the equivalent
multiplier is applied shrinks the outer ring with it (antigravity's Claude/GPT group
at N = 1 is the typical case). The inner ring keeps the **raw** weekly remaining.
This deliberately diverges from the iconDuo arcs, which use the mean: the
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
on by default). On: the outer ring takes the colour of the **effective 5h quota** —
the same bottleneck model its arc length comes from — and the inner ring the colour
of the **weekly window alone**, each through
`ModelQuota.colorLevel(percent:timeFraction:)` — the same thresholds the segmented
bar uses. The weekly ring therefore passes `weeklyTimeRemainingFraction(at:)` and
gets the *time-aware* yellow line (`min(time%, 50)`): a weekly budget that is
half spent with a day left is a warning, with six days left it is not. The outer
ring's time fraction **follows the binding window**: when the 5h window is the
bottleneck it passes `timeFraction: nil` and gets the fixed 30% line — the dynamic
line is a long-window rule, and a window that resets every five hours has no
meaningful "fraction of the window remaining" to tighten it — but when the weekly
window binds (weekly × N tighter than 5h remaining) it passes the weekly time
fraction and gets the same dynamic line, matching `aggregateHealthLevel`. Both take
the **worst** model — for the outer ring the one with the lowest effective quota —
matching how their lengths are computed, so length and colour never
point at different bottlenecks. Off: both rings take the provider's aggregate
`health` instead. The centre logo and the quota number stay neutral in both modes —
they identify, they do not report.

The compact single ring is coloured by the effective 5h quota too, with the same
weekly fallback its *arc length* uses, so a weekly-only provider never shows a
weekly arc in the 5h ring's colour.

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

Each row is **ring + persistent quota number** (effective 5h first, weekly as
fallback, `—` when neither exists). The number is the only readable information
without hovering, so it is the 5h quota (effective: the same number the outer ring
draws): that is what changes fastest and answers "can I
still work right now". It stays a single value — the raw-vs-effective contrast
lives only in the hover tooltip.（额度剩余百分比统一经 `Formatters.formatQuotaPercent` 格式化：至多一位小数，计算结果为整数则显示整数且绝不带 `.0`，如 `91.9%` / `92%` / `100%`。）

There the 5h segment is dual-valued exactly when the weekly conversion binds
(effective < raw 5h): `5h <raw>%(<effective>%有效)` (e.g. `5h 90%(30%有效)` 或 `5h 100%(91.9%有效)`, via
`EdgeDockProjection.intervalCaption`，同样至多一位小数、整数不带 `.0`） — the gap reads as a weekly bottleneck
rather than the 5h window itself running dry; when effective == raw it stays a
plain `5h 60%`（或 `5h 91.9%`）.

That bracket is the **tooltip's**, produced by the dock projection, and it is a
*separate* implementation from the identically-shaped `(N%有效)` on the popover
card's per-model metadata line (`QuotaBarWithMetadata.weeklyBindingEffectivePercent`,
see *Collapsed sections are open in the popover*). The two answer the same question at
two zoom levels — provider-wide worst model here, per model there — and they are not
expected to print the same number.

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
  number, so they differ by `(labelSpacing + labelHeight) / 2` = **8pt** (row height 54
  vs. diameter 38). The popover aligns to the row.

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

**Since the 2026-10 second-round pass the provider card has no hover-collapsed
sections left.** The account row, the quota-window usage block (`QuotaWindowUsageSection`),
the per-card reset-credit list and the 7-day footer are all **resident** — formerly the
two card hosts sat in `ignoresMouseEvents = true` panels (the menu strip hover still does,
while the dock popover panel has since flipped `ignoresMouseEvents = false` so its
controls and tooltips are interactive), but residency remains the only form that works
across both hosts without an unreachable "hover of a hover". What still branches on
`hoverRevealMode` inside the card is one detail: the 7-day chart's own title row
(`.alwaysVisible` hoists it into the card title outside; other modes draw it inside).
Everything below still describes the `HoverInfoRow` mechanism, which the **main menu's
own hover rows** continue to use:

| Host | `hoverRevealMode` | Behaviour |
|---|---|---|
| Main menu — the header's sleep-blockers notice (`SleepOffendersHoverView`) | `.onHover` (the default) | Independent `NSPanel` after a delay |
| Provider card in the edge dock popover | `.alwaysVisible` | Resident layout; the quota / 7-day groups are split into two cards, see *Two cards, titles outside*. The popover panel receives mouse events (`ignoresMouseEvents = false`), enabling segment switching, `.help` tooltips, and `ScrollView` scrolling |
| Provider card in the menu's provider strip hover | `.alwaysVisible` (pinned) | identical layout to the dock card, but the panel ignores mouse events (`ignoresMouseEvents = true`); segment control is not rendered (`quotaWindowSegmentEditable = false`), table renders the persisted segment state |

The switch is an `Environment` value rather than a parameter threaded through each
call site: even with only two live `HoverInfoRow` call sites left (the header notice and
the provider strip — the card's own hover rows were deleted with the menu's provider
cards), a parameter would mean remembering to update every one of them, and a missed
site silently keeps the old behaviour with no error anywhere.

The default is `.onHover` **on purpose**: it is the side that protects the main menu.
Changing it would not crash or warn, it would just quietly turn the menu into a wall of
text, so `HoverRevealModeTests` asserts the default rather than trusting it.

`.alwaysVisible` is the only workable choice for this window. The popover is already
one-hover deep, so a nested "hover to expand" would be a hover of a hover. Even with
the dock popover now receiving mouse events (`ignoresMouseEvents = false`), keeping
sections resident preserves unified card sizing across both hosts and prevents
jarring height jumps.

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
consumer, and the whole `QuotaWindowsHoverView` family
(`QuotaWindowsHoverView` / `QuotaUsageWindowsHoverView` / `QuotaUsageWindowColumn` /
`SingleQuotaWindowHoverView` / `HoverMetricLine` / `QuotaWindowsHoverPresentation`) was
**deleted** along with the only path that constructed it — the model rows' `menuLayout`,
which is itself gone. `QuotaHoverViews.swift` now holds only
`UsageMetricHoverSummaryView`, whose one live in-card host is GLM's off-peak footnote.

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
inlined as `mode == .alwaysVisible` at the call site. `testStripHoverCardMustUseTheAlwaysVisibleRevealMode`
pins the mode the menu's own provider card is rendered with, and (since the
second-round pass) asserts the reset-credit height delta in **both** modes — residency
must not silently get re-attached to the expand state.

The popover's header is therefore not just "provider name + state" — it keeps
only what answers *how much is left* at a glance, and everything about *how was it
spent* sits below. The provider-level row that used to travel with the peak countdown
(the collapsed reset-credit row) moved into the usage block's fourth module in the
2026-10 second-round pass, so the card-level rows above the divider now carry exactly
one thing:

- **Peak indicator** (GLM / DeepSeek only), below the first model's bar via
  `betweenBarAndColumns`.

Each model block is then `QuotaBarWithMetadata` (its `name · 5h 100%[(30%有效)] weekly …`
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
  can give way. The metadata line keeps a `name` defaulting to `""` so a host that
  already labels the row elsewhere can omit it; today every call site passes
  `model.displayName` (the menu host that used to pass the empty string is gone).

**The metadata line carries the weekly-bottleneck suffix `(30%有效)`.** The popover's
per-model detail row is the *same* `QuotaBarWithMetadata` the menu's provider-strip
hover card renders — one `private struct CombinedQuotaMetadataLine`, so the two hosts
cannot drift. Since 2026-10-04 that line shows, next to the raw 5h reading, the 5h
**effective** budget whenever the weekly conversion is the binding constraint:
`ChatGPT Plan 5h 100%(30%有效) weekly 5%`. It exists because the segmented bar right
below it draws `min(5h, weekly × N)` while the number is the raw 5h — without the
suffix a 30%-long bar next to "5h 100%" reads as a bug (the user reported exactly
that). The predicate is `QuotaBarWithMetadata.weeklyBindingEffectivePercent`
(`QuotaViews.swift:643`), which reuses `EquivalentQuotaAllocation.bindingWindow`:
weekly × N must be *strictly* tighter, ties fall to 5h, and single-window models
never get a suffix. The value is `effectivePrimaryFraction × 100`, printed in
`Color.criticalTint`. The row's data column switches from 152pt to 208pt
(`quotaCombinedEffectiveSuffixWidth` = 56) when the suffix is present, so rows in the
same card still align and the reset time does not jump. Full rules, including the
colour rationale, are in `spec/ui/menu-and-cards.md` §Combined Quota Row →
*Weekly-bottleneck suffix*.

**No `QuotaDetailColumns`.** The popover used to show *Last Prompt | 5h | weekly*
as three equal columns under each bar. They are gone: all three report local token
usage from the same local session scan, which card 2 already shows in full
(`最近7天token用量` + its usage table), so the popover was saying the same thing
twice and burying the one thing that answers "how much is left" under three blocks
of numbers. Their hover carriers (`LastPromptHoverSummaryView`,
`QuotaUsageWindowColumn`, `QuotaWindowsHoverView`) were deleted with the menu's
provider cards, so the detail is not one hover away anywhere — card 2's 7-day table
is now its only home. `ModelQuotaDockBlock` therefore has no `columns` parameter at
all: the omission is structural, not a flag someone can flip.

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
onto their own lines really does cost ~37pt; that is the trade. There is no shorter
"menu card" to compare it against any more — the menu's collapsed provider card is
gone, and both live hosts render this same resident layout. The **800pt** ceiling here is also a different number from
`popoverHeightFraction` (0.95) — that one bounds the panel against the screen, this one
catches someone re-adding an always-expanded block. Do not copy one into the other.
There is a second, looser ceiling: the "fullest quota window section" fixture (reset
credits + priced windows) is capped at **900pt** by
`testDockDetailWithTheFullestQuotaWindowSectionStaysUnderTheSameCeiling`, which first
asserts that the fixture really is taller than the light one.

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
| Popover | Second `NSPanel`, `ignoresMouseEvents = false` (`.nonactivatingPanel`, receives clicks/hovers without stealing focus), level `.popUpMenu` so it sits above the dock. Renders the same `ProviderCardView(status:)` the menu's provider strip hovers — so the dock's popover and the menu's hover card are the same object at the same width and the same layout, not two near-identical ones. In the dock it lays out as **two cards with their titles outside**, see *Two cards, titles outside* below. An open card is re-rendered on every status broadcast (`reconcile`'s no-op-frame branch refreshes it), so it never shows numbers frozen at the moment it opened |
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
menu's provider strip hover shows the very same layout. Since the 2026-10 second-round
pass card 1 opens with the **Account Info row**, giving the whole thing three reading
sections: *who is this* → *what does this round of quota look like* → *what did the
last 7 days look like*.

| | Title row (outside, above the card) | Card |
|---|---|---|
| 1 | brand logo + provider name, with the refresh time / state label on the right — **no status dot** (the `ProviderStateLabel` capsule on the same row already states the status) and **no plan capsule** (it moved into the Account Info row) | **Section 1 — Account Info**: one resident row, account name + plan pill (see below), no section title. **Section 2 — Plan Info**: the in-card section title 「Plan详情」 first, then three resident modules: per model `<name> 5h 62%[(30%有效)] weekly 30% <reset time>` + the progress bar (the peak-window countdown still rides *below* the first bar; the parenthesised suffix appears only when the weekly conversion binds — see *Collapsed sections are open in the popover*); a divider; then the **quota-window usage block** — unified 「额度窗口」 Grid (with 「分析」/「用量」 segment switch) and the reset-credit module (see below) |
| 2 | `最近7天token用量`, with the local-usage freshness as a **capsule** (`更新于 HH:mm` / `计算中…`) on the right — same font, weight and colour as title 1, because the two rows are the same kind of thing: the name of their card | the 7-day chart, its usage table and the footnote |

**Section 1 — Account Info** is `QuotaWindowAccountInfoRow`, one row, no section
title: account name (email, monospaced, tail-truncated) + the plan pill (the very
pill the card header used to wear — same `MenuTypography.pill` capsule). Visibility
is decided **only** by `QuotaWindowAccountInfo.make`: a provider shows the row when it
has *either* a real account name or a real plan level, and hides the whole row when it
has neither — codexChatGPT / antigravity show email + pill (antigravity keeps the
`Google AI Pro` → `AI Pro` prefix stripping), glmCodingPlan shows only the level
(API-key login, no email), **deepseek shows nothing** (its `planLabel` is the balance
string `¥xx.xx`, not a level — the balance stays in `DeepseekBalanceRow`), and
minimaxTokenPlan has neither field. An empty/blank string counts as missing, so a
first-refresh gap never lights the row up. A thin separator follows the row only when
it renders.

**Section 2 — Plan Info reads as three modules.** Since the third-round pass it
opens with its own section title 「Plan详情」 (`ProviderCardView.planSectionTitle`,
11pt semibold — the account row deliberately has none; the `.loading` / `.failed`
fallback paths draw the same title so a mid-refresh flash cannot blink it). The
metadata line moved *above* the bar (read the description, then the graphic), the bar keeps vertical
breathing room, and the peak countdown sits *below* the bar — it is context for the
quota, provider-level, so it travels through `QuotaSummary.betweenBarAndColumns` → the
model row → `ModelQuotaDockBlock.between` (type-erased as `AnyView`, only the first
model row receives a non-empty value). The reset-credit row that used to sit next to
the countdown now lives in the usage block's second module. The divider between the
quota bars and the usage block is drawn once by the card
(`ProviderCardView.quotaUsageDivider`), not per model block, so it spans the whole
quota group; both sides come from different data sources — provider API above, local
session scan below — and without the line the usage reads as a continuation of the
quota.

**Type scale inside the two cards: 13 / 11 / 10.** Card titles are
`MenuTypography.cardTitle`; values and body text are 11 (`hoverBodyMonospaced` /
`hoverRowEmphasis`, and `hoverTitle` was pulled down to 11 so a sub-title is no longer
bigger than the values under it);
labels, captions, footnotes, day labels, chart annotations and table cells are 10 —
the 8pt and 9pt sizes that used to live in the chart and the table are gone
(`timeSuffix` and `hoverFootnote` moved from 9 to 10). Capsules keep `badge` at 9pt,
since a pill is a different kind of mark, not body copy. The scale is a **role
vocabulary, not a fixed list**: unreferenced roles are deleted rather than parked, so
`MenuTypography` holds no multiplier / `hoverBody` / `hoverCaptionEmphasis` /
`errorMessage` token waiting for a caller that never arrives.

The cut is not arbitrary: the quota group is "now" and the 7-day group is "history", and
`HoverInfoRow` already drew a separator between them. The card boundary replaces that
separator, so the lower half stops reading as a table appended to the upper card. The
split rides on `LocalUsagePart`, which today has exactly **one** case — `.detail`,
i.e. card 2 gets the chart and card 1 gets everything else. The former `.summary` and
`.combined` cases are gone: the summary row stopped rendering anywhere in the card in
the second-round pass (its content moved into the usage block's 今 row) and the combined
form was for the old menu column, which no longer exists, so both were branches that
could only ever be false. This is also why the chart no longer draws its own title row
in `.alwaysVisible`: the title and the freshness badge moved up into title row 2.

Two knock-on details, both easy to miss:

- Both cards use `.frame(maxWidth: .infinity)`. Sized to their content they would have
  different widths (card 2 is only the chart) and the stack would show two misaligned
  plates.
- The non-`.ok` fallback (loading / failed) renders the **same three sections** off the
  cached `lastSuccess` — account row, quota bars (dimmed), usage block, 7-day chart —
  through the same constructors as the `.ok` path, so a `.loading` flash mid-refresh
  cannot drop a section. `.notConfigured` alone stays a bare placeholder.

#### Quota window usage block

Inside card 1, **below** the quota/local-usage divider, there is one block that answers
"how much did *this machine* burn inside the current quota window?". It is rendered by
`QuotaWindowUsageSection` (`Views/QuotaWindowUsageViews.swift`), in the same
`.alwaysVisible` card the dock popover and the menu's provider strip hover both show.
Since the second-round pass the block is **fully resident** — the hover-expanded detail
(`QuotaWindowUsageHoverView`) is deleted — and reads as up to two modules separated
by 1px hairlines (`QuotaModuleSeparator`). Each module is headed by its own title
(「额度窗口」 / 「重置卡详情」, `QuotaModuleTitle`: 10pt secondary
**semibold** since the fourth round, left-aligned) drawn **inside** the module, below the hairline and above the content, so
it hides with its module; each module is hidden when it has no data, the whole block
(and the divider above it) hidden when both are:

**Every width in both tables is budgeted against 420pt, the card content width the two
hosts share** — `EdgeDockTheme.popoverWidth` (468) − 2×12pt backdrop padding − 2×12pt
card padding. That is the number to use, *not* the main menu's 360/312. The grids are
greedy so they always fill whatever they are given, but every number *derived* from the
width — the per-column budget, the "does the three-character header still fit" argument,
where the compact-money threshold is measured — was being computed against a menu that
no longer renders a provider card at all, 108pt narrower than either real host. The
guardrail tests now read the same constant, so the budget and the check cannot drift
apart again.

| Module | Content |
|---|---|
| Quota window (`windowUsageModule`) | Titled 「额度窗口」 (`QuotaWindowUsageSection.windowUsageTitle`). Merges the former 「额度分析」 and 「额度详情」 into a single switchable module with zero-reflow between states. The title row hosts a custom capsule `QuotaWindowUsageSegmentControl` on the right (rendered when `quotaWindowSegmentEditable` is true), offering **「分析」** (default) and **「用量」** (`QuotaWindowUsageSegment`, persisted via `@AppStorage(QuotaWindowUsageSection.segmentStorageKey)` = `"quotaWindowUsageSegment"`). The time-composition bar (`QuotaWindowTimeShareBar`) was completely removed. Below the title row sits **one unified `Grid` of 7 columns** (`horizontalSpacing: 8`, `verticalSpacing: 3`) across all visible rows (5h / 周 / 今). Fixed columns: **类型** (left, natural width ~16pt), **价值** (fixed 58pt, `QuotaWindowUsageSection.valueColumnWidth`, left-aligned cell), and **重置日期** (right, fixed 126pt, `QuotaWindowUsageSection.resetDateColumnWidth`, including 9pt leading gutter `QuotaWindowUsageSection.resetDateColumnLeadingGap`). The middle 4 columns switch by segment: in **「分析」** mode: `类型 | 用量 | 命中 | 产出比 | 思考 | 价值 | 重置日期` (`statsHeaders`); in **「用量」** mode: `类型 | Input | Cached | Output | Reason | 价值 | 重置日期` (`rawTableHeaders`). Middle columns share a fixed width of **42pt** (`middleColumnWidth`) and right-alignment (headers follow cell alignment). The 420pt budget: `natural (~16pt) + 4×42pt + 58pt + 126pt + 6×8pt = 416pt ≤ 420pt` (measured header 「类型」 at 20pt yields `420pt ≤ 420pt`). Both modes share the exact same Grid skeleton and column dimensions, guaranteeing zero reflow (pinned by height-equality test). Reset date is formatted as `MM-dd HH:mm (倒计时)`, 今 row displays `—`; its 126pt width removes the former 1.2× factor, fitting the longest form `09-30 15:07 (23h59m)` (117pt) + 9pt gutter with 0pt surplus, guarded by `testResetDateColumnWidthCoversTheLongestForm`. With multiple pools, a footnote below the Grid explains totals are summed and reset date is the earliest. |
| Reset credits (`resetCreditsModule`) | Titled 「重置卡详情」 (`QuotaWindowUsageSection.resetCreditsTitle`). The collapsed row (**`重置卡数量：N`** + nearest expiry) followed by the **per-card list** (`ResetCreditsDetailList`): N available credits render as N+1 lines. **Zero available → the whole module is omitted** (not a `重置卡数量：0` line) |

**Value (the sixth metric)** — `ModelPricingCatalog.estimate` over the window's
**already filtered samples** (the very array the four buckets are summed from, so token
count and money can never describe different sets of samples), in the **original
currency** (`¥` / `$`) with no local-currency conversion, matching the 7-day table and
the client summary. DeepSeek's ×2 peak multiplier is evaluated **per sample timestamp**
(the `deepseekPeakWindow` travels with the status), so a window straddling a peak
boundary is not doubled as a whole. `—` means no local samples in the window; `未定价`
means samples are present but the catalog has no price for them. Summing several model
pools adds their money only while the currencies agree — a mixed-currency sum returns
nil rather than a meaningless total.

**Amounts ≥ 100,000 switch to compact units** (`¥123.5K`, `¥1.23M` / `$2.50B`; the K
rung uses one decimal); below that the
cell is `ModelCostEstimate.displayText` verbatim, with the partially-priced suffix
carried over. The threshold is measured, not guessed: the 价值 column is fixed at 58pt
(`valueColumnWidth`), and `¥99999.99` — the longest form the plain path can produce —
measures ≈58pt, while `¥999999.99` no longer fits and is what pushed the threshold down.
`¥9.88M` measures ≈40pt, leaving plenty of room in the column.
The ladder is **K / M / B**, the same language the 用量 column already speaks
(`Formatters.formatTokenCountCompact`: `30K` / `3M`), and the B rung exists so the
formatter cannot lose its unit at some magnitude. 「万」 was considered and rejected:
it is a second unit system the reader has to learn, and it only means anything for CNY —
this column is original-currency, so `$123.4万` would simply be wrong.

Ratio formulas (all three return `nil` — rendered `—` — when their denominator is 0;
`0%` would read as "the ratio really is zero"):

| Ratio | Formula | Rendered |
|---|---|---|
| 命中 cache hit | `cached / (input + cached)` | 1 decimal (`97.8%`) |
| 产出比 output to input | `(reason + output) / (input + cached)` | **adaptive percentage (`outputInputRateText`)**: value ≥ 10 → integer (`12%`, `100%`); 1 ≤ value < 10 → 1 decimal (`1.2%`, `9.9%`); value < 1 → 2 decimals (`0.12%`, `0.00%`). Tiered on raw percentage value before formatting (e.g. 9.99% falls in 1-decimal bracket, displays `10.0%`). Designed to reclaim column width for the 420pt budget and zero-reflow layout; users knowingly accepted folding in the 10–100% range (the former "fixed 3 decimals" design decision retired). |
| 思考 reasoning share | `reason / (reason + output)` | 0 decimals (`41%`) |

**The 产出比 cell explains itself on hover.** A cell holds either the percentage text or a bare
`—`, and neither says what the two sides of the fraction are. So the cell carries a
`.help`: with a value, 「产出比 =（思考 + 输出）/（未缓存输入 + 缓存输入）」; without one,
「会话无输入 token 时产出比无法计算，显示为 —」. The second string is the important one —
`—` there is not zero, it is a ratio whose denominator is the entire input side and the
session had none, and a dash in a numeric column is otherwise read as a missing reading
rather than an undefined one. Both are constants on `QuotaWindowUsageSection`
(`outputInputRateHelp` / `outputInputRateHelpUnavailable`) and are pinned by a test.

Data source and calibration:

- Windows are the **same** ones the quota rows use — `LocalUsageSummaryBuilder.windowBounds`
  (`intervalResetsAt` / `weeklyResetsAt` pushed back by the window length) feeding
  `LocalUsageSummaryBuilder.windowSamples`, so the GLM off-peak exclusion
  (`excludeWindows` + `excludeGlmOffPeak`) applies here exactly as it does above. ChatGPT
  keeps its `codexUsageDetails` + OpenCode path via `ChatGPTPlanModelRow.windowUsages`.
- A provider with several model quotas is **summed per window** (`combineWindowUsage`):
  `modelMatches` already partitions the samples per model quota, so the pools do not
  overlap. The reset time shown is the **earliest** one, and the table footnote says so
  whenever more than one pool contributed (`snapshot.poolCount > 1`).
- The **今 row** (label 「今」 since the fifth round) is provider-level today: the same-day
  bucket aggregate from `ProviderUsageProjection.dailyTokenUsage` (the same source the
  removed `📈 今天 …` summary row read), valued from the same-day samples through
  `ModelPricingCatalog` — no window math, no GLM off-peak exclusion. Today has no window
  reset date, so its reset date cell displays `—`.
- **All-zero rules & Degenerate cases**:
  - **All-zero rows skipped**: a row (5h/周/今) whose four buckets sum to 0 is skipped
    entirely via `visibleRows` — appearing in neither mode.
  - **All-zero columns hide module-wide**: evaluated per active segment across visible rows.
    In analysis mode (`statsColumnVisibility`), `命中` disappears when cached tokens sum to 0
    across all visible rows, and `思考` disappears when reasoning tokens sum to 0 across all
    visible rows. In usage mode (`numericColumnVisibility`), each of `Input`, `Cached`,
    `Output`, and `Reason` disappears when its respective bucket sums to 0 across all visible
    rows. Fixed columns (`类型`, `价值`, `重置日期`) are always present and never hide.
  - **Whole module disappearance**: when no row survives the filter, the entire 「额度窗口」
    module — title and segment control included — disappears. If no reset credits are available
    either (`hasVisibleContent` is false), the whole section and the card's `quotaUsageDivider`
    above it disappear. A balance-only provider (DeepSeek API balance, no quota window at all)
    renders **nothing**.
- **Host interactivity & environment**:
  - Dock popover panel: `ensurePopoverPanel` sets `ignoresMouseEvents = false` (`.nonactivatingPanel`,
    does not steal focus), allowing users to click the segment switch, hover over `.help` tooltips,
    and scroll with `ScrollView`. Injects `.environment(\.quotaWindowSegmentEditable, true)`.
  - Menu strip hover panel: `HoverPanel.swift` retains `ignoresMouseEvents = true`, injecting
    `.environment(\.quotaWindowSegmentEditable, false)`. The segment control is not rendered in
    the title row, while the table renders the persisted segment state from `@AppStorage`.
- **Reset credits residency.** The per-card list is the module itself: the collapsed row
  (`CompactResetCreditsRow`) plus `ResetCreditsDetailList`, unconditionally, always on
  screen. There is nothing left to expand — `CompactResetCreditsRow` has no
  `revealsDetail` parameter and no hover branch, and `ResetCreditsDetailList` has no
  `showsHeader` parameter, no 「可用重置卡 N 张」 header and no 「暂无可用重置卡」 empty
  state. The old hover form was deleted rather than left defaulted: the only construction
  site passed `false`, so the expanded branch was unreachable in production, and keeping
  it alive would have shown a **second** copy of the list on the one host that can still
  receive hover (the main menu's own hover rows). Zero available credits is handled by
  the module rule above, so the list never needs an empty state of its own.
- **Height ceiling.** `LayoutMetricsTests` still lays the card out for real — the light
  fixture is capped at **800pt** (`testDockDetailStaysUnderTheRearrangedCeiling`), and
  the reset-credits + priced-windows fixture (the resident form's realistic worst case)
  at **900pt** (`testDockDetailWithTheFullestQuotaWindowSectionStaysUnderTheSameCeiling`).
  Residency is what makes the cap matter: nothing is hidden behind a hover any more, so
  the popover's `ScrollView` fallback is the only overflow valve.

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
  **effective 5h quota** (`min(5h remaining, weekly remaining × N)` via
  `aggregateActualAvailable`, the same caliber as the full dock's outer ring and the
  iconDuo centre fan), falling back to the raw weekly fraction for providers with no
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

> 核对基线：2026-10-04 · 代码 eb28ecf
