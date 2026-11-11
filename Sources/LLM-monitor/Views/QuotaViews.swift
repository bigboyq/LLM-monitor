import SwiftUI
import AppKit




/// ChatGPT 重置卡：只显示数量和最早过期时间。
///
/// 逐张明细**不再挂 hover**（第七轮）：`QuotaWindowUsageSection` 的重置卡模块
/// 已经把清单常驻在折叠行下面（同一个 `ResetCreditsDetailList`、同一份排序），
/// 原来的 `revealsDetail: true` 展开分支只剩默认参数在走，生产路径不可达，
/// hover 展开那条还会让鼠标可达的宿主（主菜单 hover 卡）看到重复的清单。
struct CompactResetCreditsRow: View {
    let resets: ResetCreditsInfo
    /// provider 的 background 刷新间隔（秒）。
    var refreshIntervalSeconds: Int = 300
    var periodicFullEveryN: Int = AppConfig.defaultPeriodicFullEveryN

    /// R3: reset credits 的实际刷新周期。reset credits 只在 .full 抓取，而 scheduler
    /// 每 N 拍抓取一次次要信息，所以真实周期 = N × Provider 刷新间隔。
    /// 过期判定基于这个周期（3×），否则会在两次 full 之间持续误报。
    private var resetCreditsRefreshPeriod: TimeInterval {
        TimeInterval(refreshIntervalSeconds) * TimeInterval(periodicFullEveryN)
    }

    /// 过期判定用宿主注入的展示时钟，不取渲染时的墙钟（与卡内其它倒计时同一个 now）。
    @Environment(\.displayDate) private var displayDate

    private var isStale: Bool {
        resets.isStale(now: displayDate, refreshIntervalSeconds: resetCreditsRefreshPeriod)
    }

    var body: some View {
        summary
    }

    /// 折叠态：总数 + 最近一张的到期时间（外加过期提示）。
    private var summary: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(summaryColor)

                Text("重置卡数量：\(resets.availableCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(summaryColor)
            }

            Spacer(minLength: 8)

            if isStale {
                // R3: reset credits 子接口失败或数据过旧，显示过期提示（不只靠透明度/颜色）。
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(staleText)
                        .font(MenuTypography.resetDate)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .help(staleHelp)
            }

            let expColor = Self.expiryColor(for: resets.nearestExpiry, now: displayDate)
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(expColor)
                Text(expiryText)
                    .font(MenuTypography.resetDate)
                    .foregroundStyle(expColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// 最近重置卡过期时间颜色：<=24h 红色、<=48h 黄色、>48h 次要灰
    static func expiryColor(for nearestExpiry: Date?, now: Date) -> Color {
        guard let nearestExpiry else { return .secondary }
        let remaining = nearestExpiry.timeIntervalSince(now)
        if remaining <= 24 * 3600 {
            return .criticalTint
        } else if remaining <= 48 * 3600 {
            return .warningTint
        } else {
            return .secondary
        }
    }

    private var expiryText: String {
        guard let nearestExpiry = resets.nearestExpiry else { return "—" }
        return Formatters.formatMonthDayMinute(nearestExpiry)
    }

    /// R3: 过期文案——"可能过期 · 上次更新 HH:mm"；无 fetchedAt 时不带时间。
    private var staleText: String {
        if let fetchedAt = resets.fetchedAt {
            return "可能过期 · 上次更新 \(Formatters.formatClock(fetchedAt))"
        }
        return "可能过期"
    }

    private var staleHelp: String {
        if resets.lastAttemptFailed {
            return "最近一次抓取 reset credits 失败，显示的是上次成功的数据"
        }
        return "reset credits 数据已较久未更新，可能已过期"
    }

    private var summaryColor: Color {
        if resets.availableCount == 0 { return .criticalTint }
        if resets.availableCount == 1 { return .warningTint }
        return .healthyTint
    }
}

/// 一条可用 reset credit：过期时间 + 剩余时间
struct CreditEntryRow: View {
    let entry: ResetCreditEntry
    /// 剩余时间取宿主注入的展示时钟，不取渲染时的墙钟。
    @Environment(\.displayDate) private var displayDate

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.dotColor(for: entry.expiresAt, now: displayDate))
                .frame(width: 5, height: 5)

            if let expiresAt = entry.expiresAt {
                Text(Formatters.formatMonthDayMinute(expiresAt))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)

                Text(Formatters.formatRelativeShort(from: expiresAt, now: displayDate))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.relativeTextColor(for: expiresAt, now: displayDate))
            } else {
                Text("过期时间未知")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    /// 到期紧迫度颜色辅助函数：<=24h 红色、<=48h 黄色、>48h 绿色（用于指示圆点）
    static func dotColor(for expiresAt: Date?, now: Date) -> Color {
        guard let expiresAt else { return .secondary }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 24 * 3600 {
            return .criticalTint
        } else if remaining <= 48 * 3600 {
            return .warningTint
        } else {
            return .healthyTint
        }
    }

    /// 剩余时间相对文案颜色：<=24h 红色、<=48h 黄色、>48h 次要灰
    static func relativeTextColor(for expiresAt: Date?, now: Date) -> Color {
        guard let expiresAt else { return .secondary }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 24 * 3600 {
            return .criticalTint
        } else if remaining <= 48 * 3600 {
            return .warningTint
        } else {
            return .secondary
        }
    }
}

// MARK: - 通用 quota 行

/// 将短周期与周额度收进同一条：分段只表达等价配额比例，不把两种窗口的百分比相加。
struct CombinedQuotaWindowRow: View {
    let model: ModelQuota
    let primaryLabel: String
    let tint: Color
    let weeklyEquivalentMultiplier: Double
    /// 夹在进度条块与下方**本地用量**之间的卡片级信息（重置卡、高峰期），见
    /// `ModelQuotaDockBlock.between`。只有第一个 model 行会拿到非空值。
    var between: AnyView = AnyView(EmptyView())
    var isSelectedQuotaSource: Bool = false
    var onSelectQuotaSource: (() -> Void)? = nil

    /// 直接渲染 dock 形态。此前是 `if isDockLayout { dockBlock } else { menuLayout }`：
    /// 判据 `ProviderCardLayout.liftsProgressBar(mode:)` 恒为真（生产路径上唯一的宿主
    /// 就是 `ProviderCardView`，`EdgeDockController.popoverContent` 注入 `.alwaysVisible`；
    /// 旧菜单 provider-card 宿主已删除，因此菜单那一支跑不到，连同它的独占子视图一并删除。
    /// 新的渲染宿主若要换形态，届时是**恢复分支**而不是从死代码里挑。
    var body: some View {
        dockBlock
    }

    // MARK: dock：条 + 元信息行

    /// dock 侧只剩**额度本身**：条 + 元信息行。
    ///
    /// 三列明细（Last Prompt | 5h | 周）已经撤掉——它们和下面那张「最近7天token
    /// 用量」卡讲的是同一件事（本地扫描的 token 用量），在一屏里摆两份既重复，
    /// 又让"还剩多少"这条主线被三块数字压住。想知道这次 prompt 花了多少，走
    /// 菜单侧的 hover 浮层。
    ///
    /// 元信息行（`5h 100% 周 …`）也只出现一次：它此前在额度行本身和
    /// `QuotaWindowsHoverView` 展开后的窗口指标行各一份，dock 侧两处都在屏上。
    @ViewBuilder
    private var dockBlock: some View {
        if model.hasIntervalWindow, model.hasWeeklyWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: QuotaSummary.weeklyWindowLabel(),
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint,
                    isSelectedQuotaSource: isSelectedQuotaSource,
                    onSelectQuotaSource: onSelectQuotaSource
                ),
                between: between
            )
        } else if model.hasIntervalWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint,
                    isSelectedQuotaSource: isSelectedQuotaSource,
                    onSelectQuotaSource: onSelectQuotaSource
                ),
                between: between
            )
        } else if model.hasWeeklyWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: QuotaSummary.weeklyWindowLabel(),
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint,
                    isSelectedQuotaSource: isSelectedQuotaSource,
                    onSelectQuotaSource: onSelectQuotaSource
                ),
                between: between
            )
        } else {
            Text("额度窗口不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// 短周期窗口缺 `windowSeconds` 时的兜底长度（`windowBounds` 用）。
    ///
    /// 提成 `static` 是因为卡片级「额度窗口用量」区块（`ProviderCardView`）要为同
    /// 一个 model 推窗口边界，它必须拿到**同一个**兜底长度——minimax video 是日窗口
    /// （24h），其余是 5h，两处各写一份迟早改漏一处，而漏了不会崩，只会让 video
    /// 的"日窗口"按 5h 截断、条与数字各说各话。
    nonisolated static func primaryFallbackSeconds(
        providerKind: ProviderKind,
        model: ModelQuota
    ) -> TimeInterval {
        providerKind == .minimaxTokenPlan && MinimaxModelKind.isVideo(model.modelName)
            ? 24 * 60 * 60
            : 5 * 60 * 60
    }
}

/// Hover 详情里的单行窗口信息
// MARK: - 进度条（裸视图）与它的 hover 明细

/// 双窗口 model 的分段进度条本体。
///
/// 与 hover 明细拆开是因为**排版权在父级**：dock 详情浮层里这条要排在
/// model 标题**之上**，且旁边没有自己的 hover 明细——菜单那条"条 + hover 弹明细"
/// 的结构整块搬不过去（浮层不接受鼠标事件），明细要看菜单。
struct CombinedQuotaBar: View {
    let model: ModelQuota
    let tint: Color
    let weeklyEquivalentMultiplier: Double

    var body: some View {
        SegmentedQuotaProgressBar(
            primaryFraction: model.intervalRemainingPercent / 100.0,
            weeklyFraction: model.weeklyRemainingPercent / 100.0,
            tint: tint,
            multiplier: weeklyEquivalentMultiplier,
            height: 8,
            timeRemainingFraction: model.weeklyTimeRemainingFraction,
            primaryTimeRemainingFraction: model.intervalTimeRemainingFraction
        )
        .frame(maxWidth: .infinity)
        .help(QuotaBarTooltip.text(
            multiplier: weeklyEquivalentMultiplier,
            hasTriangle: model.weeklyTimeRemainingFraction != nil
        ))
    }
}

/// 单窗口 model 的进度条本体。
struct SingleQuotaBar: View {
    let percent: Double
    let tint: Color
    /// 顶部红三角位置 (0=即将过期, 1=刚重置)。nil = 不画。
    let timeRemainingFraction: Double?
    /// 用于配额标色的时间比例（如 5h 剩余时间）。未传则降级到 timeRemainingFraction。
    var colorTimeRemainingFraction: Double? = nil

    var body: some View {
        SegmentedQuotaProgressBar(
            primaryFraction: percent / 100.0,
            weeklyFraction: percent / 100.0,
            tint: tint,
            segments: 1,
            height: 8,
            timeRemainingFraction: timeRemainingFraction,
            primaryTimeRemainingFraction: colorTimeRemainingFraction ?? timeRemainingFraction
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - dock 详情浮层的 model 块

/// dock 详情浮层里一个 model 的整块：元信息行 + 进度条（+ 卡片级信息）。
///
/// 菜单形态不走这里：那边是 `HoverInfoRow` 逐块折叠的原有结构（条在标题下、
/// 每块各自 hover）。这里把"全部就地展开"**收敛到一个视图**——条的次序、
/// 元信息行只留一份，这些规则不该在两个 model 行里各写一遍，否则改一处漏一处，
/// 而漏了既不崩也不报错，只是浮层悄悄变高一截。
///
/// 块里**没有**分隔线：三列明细撤掉后块内只剩额度本身，而"额度 / 本地用量"
/// 之间的那条线要横跨所有 model，只能由卡片层画一次（`ProviderCardView.dockBody`）——
/// 每个块各画一条会在两个 model 之间叠成两条挨着的线。
struct ModelQuotaDockBlock<Bar: View>: View {
    let bar: Bar
    /// 夹在「进度条块」与下方**本地用量**之间的**卡片级**信息（重置卡、高峰期倒计时）。
    ///
    /// 用 `AnyView` 而不是再一个泛型参数：它的来源在卡片层（`ProviderCardView`），
    /// 要一路穿过 `QuotaSummary` → 各个 model 行视图才到得了这里，多一个泛型参数的
    /// 传递会把整条链都染上类型参数，而这里只需要"一段不透明的内容"。
    /// 有默认值，所以三处 menu 调用点不用改。
    var between: AnyView = AnyView(EmptyView())
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            between
        }
    }
}

/// 一个 model 的「元信息行 + 进度条」。两者是同一份数字的两种画法（行是文字、
/// 条是图形），所以合成一个视图，必须贴在一起。
///
/// **行在条的上方**：那行写的是"这条条代表哪个 model、哪两个窗口、各剩多少、
/// 什么时候重置"，先读说明再读图形；反过来读者得先猜这根条是什么、再回头找它
/// 的注解。条本身上下各留一点间距，不贴着相邻内容。
///
/// **model 名写在这行里，不另起一行、也不提到卡片头部**：三列明细撤掉后，块里
/// 只剩这一行和条，Antigravity 那样的多 model provider 就有两条一模一样的条，
/// 谁是谁全靠猜。名字必须和它描述的数字挨着——提到头部就得给每个 model 各搬一份，
/// 另起一行则是把同一行字拆成两半。
///
/// ## `primaryLabel` / `secondaryLabel` 的约定
///
/// **调用方已经决定了这个 model 有哪几个窗口**，这里的三个分支只负责把决定渲染
/// 出来。约定：
/// - 两个窗口都有 → `primaryLabel` 是短周期窗口标签，`secondaryLabel` 是周窗口标签。
/// - 只有一个窗口 → **它一律进 `primaryLabel`**，`secondaryLabel` 传空串。
///
/// 「一律进 primary」是关键：两个调用点（`ChatGPTPlanModelRow.dockBlock` 的
/// `dockWindowLabels` 与 `CombinedQuotaWindowRow.dockBlock`）都是这么传的。曾经
/// 「只有周窗口」的分支去读 `secondaryLabel`——也就是那个被刻意留空的字符串——于是
/// dock 里这一行的窗口标签**整个消失**，只剩一个无名百分比框；而同样情况的
/// 「只有 5h」分支读 `primaryLabel`，是对的。同一份契约在一个视图里对两种情况
/// 用了两套读法，属于最难发现的一类漂移。
struct QuotaBarWithMetadata: View {
    let model: ModelQuota
    let primaryLabel: String
    let secondaryLabel: String
    let weeklyEquivalentMultiplier: Double
    let tint: Color
    var isSelectedQuotaSource: Bool = false
    var onSelectQuotaSource: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasIntervalWindow, model.hasWeeklyWindow {
                CombinedQuotaMetadataLine(
                    name: model.displayName,
                    primaryLabel: primaryLabel,
                    primaryPercent: model.intervalRemainingPercent,
                    primaryEffectivePercent: Self.weeklyBindingEffectivePercent(
                        model: model, multiplier: weeklyEquivalentMultiplier
                    ),
                    primaryTimeFraction: model.intervalTimeRemainingFraction,
                    secondaryLabel: secondaryLabel,
                    secondaryPercent: model.weeklyRemainingPercent,
                    secondaryTimeFraction: model.weeklyTimeRemainingFraction,
                    resetsAt: EquivalentQuotaAllocation.bindingResetDate(
                        primaryFraction: model.intervalRemainingPercent / 100.0,
                        weeklyFraction: model.weeklyRemainingPercent / 100.0,
                        primaryResetsAt: model.intervalResetsAt,
                        weeklyResetsAt: model.weeklyResetsAt,
                        multiplier: weeklyEquivalentMultiplier
                    ),
                    isSelectedQuotaSource: isSelectedQuotaSource,
                    onSelectQuotaSource: onSelectQuotaSource
                )
                CombinedQuotaBar(
                    model: model,
                    tint: tint,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier
                )
                .padding(.vertical, 3)
            } else {
                // 单窗口 / 无窗口共用一条路径：窗口选择交给 `singleWindow` 这个
                // **纯函数**算，而不是在这里再写一遍三分支。
                if let single = Self.singleWindow(
                    model: model, primaryLabel: primaryLabel, secondaryLabel: secondaryLabel
                ) {
                    let colorFraction = model.hasIntervalWindow
                        ? model.intervalTimeRemainingFraction
                        : model.weeklyTimeRemainingFraction
                    SingleQuotaMetadataLine(
                        name: model.displayName,
                        label: single.label,
                        percent: single.percent,
                        resetsAt: single.resetsAt,
                        timeFraction: colorFraction,
                        isSelectedQuotaSource: isSelectedQuotaSource,
                        onSelectQuotaSource: onSelectQuotaSource
                    )
                    SingleQuotaBar(
                        percent: single.percent,
                        tint: tint,
                        timeRemainingFraction: single.timeRemainingFraction,
                        colorTimeRemainingFraction: colorFraction
                    )
                    .padding(.vertical, 3)
                }
            }
        }
    }

    /// 只有一个额度窗口时，这一条元信息行该画什么。`nil` = 一个窗口都没有
    /// （调用方自己出占位文案）。
    ///
    /// 抽成纯函数有两个理由，第二个是它被修出来的那次 bug：
    /// 1. 三分支的 `if/else` 里读的是**同一批**字段，抽出来后 `body` 只剩一次
    ///    形状判断，标签/百分比/重置时间不可能在某一支里漏改。
    /// 2. 「只有周窗口」那一支曾经去读 `secondaryLabel`——而按约定调用方把仅存的
    ///    那个标签放在了 `primaryLabel`、`secondaryLabel` 刻意留空——于是 dock 里
    ///    这行的窗口标签整个消失，只剩一个无名百分比框；同一视图的「只有 5h」
    ///    分支读 `primaryLabel`，是对的。同一个视图对对称的两种情况用了两套读法，
    ///    而两套读法都"看起来合理"，只能靠一条直接断言返回值的测试钉住。
    static func singleWindow(
        model: ModelQuota,
        primaryLabel: String,
        secondaryLabel: String
    ) -> (label: String, percent: Double, resetsAt: Date?, timeRemainingFraction: Double?)? {
        if model.hasIntervalWindow {
            // 短周期窗口（<24h，如 5h）不画顶部 ▼ 时间标记三角（与产品偏好一致）；
            // 长周期窗口（>=24h，如 ChatGPT Plan）保留 ▼ 标记。
            let isLongWindow = (model.intervalWindowSeconds ?? (5 * 3600)) >= 86400
            let marker = isLongWindow ? model.intervalTimeRemainingFraction : nil
            return (primaryLabel, model.intervalRemainingPercent, model.intervalResetsAt, marker)
        }
        if model.hasWeeklyWindow {
            // 单窗口时标签一律在 `primaryLabel`：`secondaryLabel` 此时是空串。
            return (primaryLabel, model.weeklyRemainingPercent, model.weeklyResetsAt,
                    model.weeklyTimeRemainingFraction)
        }
        return nil
    }

    /// 「周折算构成瓶颈」时括号里要亮出来的 5h **有效额度**（min(5h 剩余, 周剩余 × N)）；
    /// nil = 5h 是瓶颈（或并列），元信息行维持单数值。
    ///
    /// 分段条画的是 min(5h, 周×N)、`primaryPercent` 却是原始 5h——周更紧时
    /// （典型：ChatGPT 周只剩 5%、antigravity Claude/GPT 组 N=1）会出现
    /// "条已缩到 30%、文字还写着 5h 100%"的表观矛盾，括号值就是把这笔账补上。
    /// 判定与并列约定**复用** `EquivalentQuotaAllocation.bindingWindow`
    /// （weekly 严格小于 primary 才算周瓶颈），保证括号出现与否与这行自己的
    /// 分段条永远同源，不会条缩了文字没缩（或反过来）。
    static func weeklyBindingEffectivePercent(model: ModelQuota, multiplier: Double) -> Double? {
        guard model.hasIntervalWindow, model.hasWeeklyWindow else { return nil }
        let primary = model.intervalRemainingPercent / 100.0
        let weekly = model.weeklyRemainingPercent / 100.0
        guard EquivalentQuotaAllocation.bindingWindow(
            primaryFraction: primary, weeklyFraction: weekly, multiplier: multiplier
        ) == .weekly else { return nil }
        return EquivalentQuotaAllocation.effectivePrimaryFraction(
            primaryFraction: primary, weeklyFraction: weekly, multiplier: multiplier
        ) * 100
    }

    static func weeklyBindingEffectivePercent(model: ModelQuota, multiplier: Int) -> Double? {
        weeklyBindingEffectivePercent(model: model, multiplier: Double(multiplier))
    }
}

// `OffPeakUsageFootnote`（GLM 今日闲时用量脚注，连同它的取数 `todayOffPeakUsage`
// 与 `offPeakFootnote`）已删除：闲时用量并入「额度窗口」表格的「闲」行
// （`QuotaWindowUsageSection.offPeak`，数据由 `ProviderCardDerivedValues.offPeakUsageRow`
// 产出，与被删脚注同源同口径）。说明句「ZCode 闲时任务真实消耗；不影响 5h / 周
// 积分余额」逐字保留在 `QuotaWindowUsageSection.offPeakRowHelp`，挂在「闲」行
// 类型格的 `.help` 上。

// 原先这里还有一族「菜单形态的额度行」视图：`QuotaCombinedUsageRow`（条 + 元信息行
// 各自 hover）与 `QuotaSingleUsageRow`（单窗口对应物），以及它们专用的
// `QuotaWindowTitle`（那行 model 的名字 + 周倍率）。三者只从两个 model 行的
// `menuLayout` 构造，而那一支随 `isDockLayout` 恒真一起变成不可达，于是连同
// `LastPromptHoverSummaryView` 一并删除。
//
// `QuotaHoverViews.swift` 里的 `QuotaWindowsHoverView` / `SingleQuotaWindowHoverView`
// / `QuotaUsageWindowsHoverView` / `QuotaUsageWindowColumn` 原本也只从这两个视图
// 构造——该族（含 HoverMetricLine 与 Presentation，连同量宽测试）已随后续清理
// 一并删除，`QuotaHoverViews.swift` 里留下删除说明。

/// 进度条上方那一行的 model 名。
///
/// 它是**这行的主语**（"Gemini Models 5h 62% 周 59%"），所以用 `modelTitle`
/// 而不是同行的 `dataLabel`——数字与窗口标签是宾语，11pt 的名字压得住 10pt 的
/// 数字；两者同字号时一行四个等重的词，谁修饰谁反而看不出来。
///
/// 宽度放不下时截断而不是压缩数字：百分比列是定宽的，重置时间在行尾，名字是
/// 整行里唯一可牺牲的那一段（`layoutPriority(-1)` 让它先让位）。名字缺失时
/// 整个不画——菜单侧那行的名字由标题行写了，这里重复一遍只是多一处噪音。
private struct QuotaRowModelName: View {
    let name: String

    var body: some View {
        if !name.isEmpty {
            Text(name)
                .font(MenuTypography.modelTitle)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }
}

private struct CombinedQuotaMetadataLine: View {
    /// 进度条对应的 model 名，排在所有窗口标签之前。菜单侧传空串（标题行已有）。
    var name: String = ""
    let primaryLabel: String
    let primaryPercent: Double
    /// 周折算构成瓶颈时并列显示的 5h 有效额度（括号值），nil = 周不是瓶颈。
    ///
    /// 分段条按 min(5h, 周×N) 画、`primaryPercent` 是原始 5h，周更紧时两者
    /// 表观矛盾（条 30%、文字 100%）；括号把有效值并排亮出来。判定与条同源，
    /// 见 `QuotaBarWithMetadata.weeklyBindingEffectivePercent`。
    let primaryEffectivePercent: Double?
    let primaryTimeFraction: Double?
    let secondaryLabel: String
    let secondaryPercent: Double
    let secondaryTimeFraction: Double?
    let resetsAt: Date?
    var isSelectedQuotaSource: Bool = false
    var onSelectQuotaSource: (() -> Void)? = nil

    /// 恒 `true`：百分比与重置时间**始终**作为一组聚在行尾。
    ///
    /// 两个百分比回答"还剩多少"，重置时间回答"什么时候换一轮"，三者挤在行尾
    /// 一簇；开头的 model 名与它们之间的空档把"这是谁的条"和"还剩多少"分成两半。
    ///
    /// 原先按 `hoverRevealMode` 分叉（菜单那支是"百分比在行首、时间在行尾"）：
    /// 判据 `ProviderCardLayout.liftsProgressBar(mode:)` 在 `.alwaysVisible` 下恒
    /// 为真，而两个渲染宿主都注入 `.alwaysVisible`，另一处宿主
    /// （`QuotaCombinedUsageRow`）只出现在 model 行的 `menuLayout` 里、已随那一支
    /// 删除。判据已删除，对齐固定成行尾（见 `ProviderCardLayout`）。

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                QuotaRowModelName(name: name)
                if let onSelectQuotaSource, !name.isEmpty {
                    StatusBarQuotaSourcePinButton(
                        isSelected: isSelectedQuotaSource,
                        title: name,
                        action: onSelectQuotaSource
                    )
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                quotaValue(
                    label: primaryLabel, percent: primaryPercent,
                    timeFraction: primaryTimeFraction, effectivePercent: primaryEffectivePercent
                )
                quotaValue(label: secondaryLabel, percent: secondaryPercent, timeFraction: secondaryTimeFraction)
            }
            .frame(
                width: quotaCombinedDataColumnWidth
                    + (primaryEffectivePercent == nil ? 0 : quotaCombinedEffectiveSuffixWidth),
                alignment: .trailing
            )
            ResetTimeSummary(resetsAt: resetsAt)
        }
    }

    /// - Parameter effectivePercent: 周瓶颈时并列显示的 5h 有效额度，仅 primary 传非 nil。
    private func quotaValue(
        label: String,
        percent: Double,
        timeFraction: Double?,
        effectivePercent: Double? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(MenuTypography.dataLabel)
                .foregroundStyle(Color.primaryLabel)
            Text(Formatters.formatQuotaPercent(percent))
                .font(MenuTypography.dataValue)
                .foregroundStyle(summaryColor(for: percent, timeFraction: timeFraction))
                .frame(width: 40, alignment: .trailing)
            if let effectivePercent {
                // 红色用告急同款 `criticalTint`：括号值是"周瓶颈下实际还能用多少"的
                // 告警数字，要在原始 5h（绿色系）旁边跳出来，secondary 灰不够响。
                Text("(\(Formatters.formatQuotaPercent(effectivePercent))有效)")
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.criticalTint)
                    .fixedSize()
            }
        }
    }
}

private struct SingleQuotaMetadataLine: View {
    /// 进度条对应的 model 名，排在窗口标签之前。菜单侧传空串（标题行已有）。
    var name: String = ""
    let label: String
    let percent: Double
    let resetsAt: Date?
    var timeFraction: Double? = nil
    var isSelectedQuotaSource: Bool = false
    var onSelectQuotaSource: (() -> Void)? = nil
    /// 同 `CombinedQuotaMetadataLine`：读数一律聚在行尾，对齐不再按环境分叉。

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                QuotaRowModelName(name: name)
                if let onSelectQuotaSource, !name.isEmpty {
                    StatusBarQuotaSourcePinButton(
                        isSelected: isSelectedQuotaSource,
                        title: name,
                        action: onSelectQuotaSource
                    )
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Text(label)
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                Text(Formatters.formatQuotaPercent(percent))
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(summaryColor(for: percent, timeFraction: timeFraction))
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(width: quotaSingleDataColumnWidth, alignment: .trailing)
            ResetTimeSummary(resetsAt: resetsAt)
        }
    }
}

private struct ResetTimeSummary: View {
    let resetsAt: Date?
    /// 倒计时取宿主注入的展示时钟，不取渲染时的墙钟（随浮层显隐起停）。
    @Environment(\.displayDate) private var displayDate

    var body: some View {
        if let resetsAt {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(Formatters.formatMonthDayMinute(resetsAt))
                    .font(MenuTypography.resetDate)
                    .lineLimit(1)
                // 倒计时用次要色而不是 tertiary：tertiary 在浅色材质上已经淡到
                // 接近不可读，而"还剩多久"是这行里读者真正要拿走的第二个信息
                // （第一个是重置时刻），不该比同一行的时钟图标还弱。
                Text("(\(Formatters.formatResetSuffix(from: resetsAt, now: displayDate)))")
                    .font(MenuTypography.timeSuffix)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primaryLabel)
        } else {
            Text("—")
                .font(MenuTypography.hint)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tooltip helpers

/// 进度条 hover 说明。抽成命名空间是因为进度条现在可能被**父级**画
/// （dock 把条提到 model 标题之上），文案不能再是某个 view 里的自由函数。
enum QuotaBarTooltip {
    /// 精炼为清晰的配额与重置时间解释
    static func text(multiplier: Double, hasTriangle: Bool) -> String {
        let isInteger = abs(multiplier - multiplier.rounded()) < 0.001
        let parts: String
        if multiplier <= 1.001 {
            parts = "单一窗口可用进度"
        } else if isInteger {
            let n = Int(multiplier.rounded())
            parts = "第 1 格为当前窗口余量；后续 \(n - 1) 格为等价周额度余量"
        } else {
            let formatted = String(format: "%.2f", multiplier)
            parts = "第 1 格为当前窗口余量；后续各格为等价周额度余量（周额度等价于 \(formatted) 倍窗口额度）"
        }
        let triangle: String
        if hasTriangle {
            triangle = "\n顶部 ▼ 标记周重置时间进度（左侧即将重置，右侧刚重置）"
        } else {
            triangle = ""
        }
        return "分段额度：\n\(parts)。\(triangle)"
    }

    static func text(segments: Int, hasTriangle: Bool) -> String {
        text(multiplier: Double(segments), hasTriangle: hasTriangle)
    }
}



/// 数据列宽度：双窗口数据列定宽 152pt 确保对齐，单窗口紧凑定宽 80pt 避免留白过大
private let quotaCombinedDataColumnWidth: CGFloat = 152
private let quotaSingleDataColumnWidth: CGFloat = 80

/// 周瓶颈括号「(30%有效)」的预留宽度。括号值恒 < 100（周**严格**更紧才显示），
/// 10pt semibold monospacedDigit 下最长约 50pt；定宽让所有显示括号的行共用同一个
/// 列宽（152 + 56），不显示的行维持原 152——同一张卡里两档列宽各自成列，
/// 重置时间不会因为括号的有无而左右乱跳。
private let quotaCombinedEffectiveSuffixWidth: CGFloat = 56
