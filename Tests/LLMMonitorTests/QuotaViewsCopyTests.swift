import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 单窗口额度行的标签 / 标记文案，以及用量浮层的拆行规则。对应
/// `QuotaViews` 的 `QuotaBarWithMetadata` 与 `QuotaHoverViews` 的
/// `UsageMetricHoverSummaryView`。
final class QuotaViewsCopyTests: XCTestCase {

    // MARK: - 单窗口标签与用量浮层拆行

    /// 单窗口元信息行**必须**用调用方给的那个标签。
    ///
    /// 约定是"只有一个窗口时它一律进 `primaryLabel`、`secondaryLabel` 留空"
    /// （两个 dock 调用点都这么传）。曾经「只有周窗口」那一支去读 `secondaryLabel`，
    /// 于是读到那个刻意留空的串，dock 里这行的窗口标签**整个消失**——只剩一个无名
    /// 百分比框，读者不知道那个数字是 5h 还是周。「只有 5h」那一支读的是
    /// `primaryLabel`，所以是对的：同一视图对对称的两种情况用了两套读法。
    ///
    /// 这类 bug 靠渲染截图才看得出来，纯断言返回值才钉得住。
    func testSingleWindowMetadataLineUsesTheLabelTheCallerSupplied() {
        let now = Date()
        func model(interval: Bool, weekly: Bool, remaining: Double) -> ModelQuota {
            ModelQuota(
                modelName: "general",
                intervalTotalCount: 100,
                intervalUsageCount: Int(100 - remaining),
                intervalRemainingPercent: remaining,
                intervalStatus: interval ? .present : .absent,
                intervalResetsAt: interval ? now.addingTimeInterval(3600) : nil,
                intervalWindowSeconds: interval ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: Int(100 - remaining),
                weeklyRemainingPercent: weekly ? remaining : 0,
                weeklyStatus: weekly ? .present : .absent,
                weeklyResetsAt: weekly ? now.addingTimeInterval(7 * 24 * 3600) : nil,
                weeklyWindowSeconds: weekly ? 7 * 24 * 3600 : nil
            )
        }

        // 两个调用点都是"仅存的那个标签放 primary、secondary 留空"。
        let weeklyOnly = QuotaBarWithMetadata.singleWindow(
            model: model(interval: false, weekly: true, remaining: 42),
            primaryLabel: "周",
            secondaryLabel: ""
        )
        XCTAssertEqual(weeklyOnly?.label, "周",
                       "只有周窗口时标签必须来自 primaryLabel；读 secondaryLabel 会得到空串")
        XCTAssertEqual(weeklyOnly?.percent, 42)

        let intervalOnly = QuotaBarWithMetadata.singleWindow(
            model: model(interval: true, weekly: false, remaining: 77),
            primaryLabel: "5h",
            secondaryLabel: ""
        )
        XCTAssertEqual(intervalOnly?.label, "5h")
        XCTAssertEqual(intervalOnly?.percent, 77)

        // 一个窗口都没有 → nil，调用方自己出占位文案。
        XCTAssertNil(
            QuotaBarWithMetadata.singleWindow(
                model: model(interval: false, weekly: false, remaining: 0),
                primaryLabel: "5h", secondaryLabel: "周"
            ),
            "没有窗口时不该凭空造出一行"
        )
    }

    /// 单 5h 窗口（长周期）时那条 ▼ 重置进度标记要透传，不能被写死成 nil。
    ///
    /// `intervalTimeRemainingFraction` 本来就只在**长**周期窗口下非 nil，正是需要
    /// 标记的那一类；曾经 dock 侧把它写死成 nil，于是同一份数据在菜单里有 ▼、在
    /// dock 里没有——同一件事两种画法。
    func testSingleWindowKeepsTheIntervalResetMarker() {
        let now = Date()
        func model(windowSeconds: Int?) -> ModelQuota {
            ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100, intervalUsageCount: 20,
                intervalRemainingPercent: 80, intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3600),
                intervalWindowSeconds: windowSeconds,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )
        }
        let short = QuotaBarWithMetadata.singleWindow(
            model: model(windowSeconds: 5 * 3600), primaryLabel: "5h", secondaryLabel: ""
        )
        let long = QuotaBarWithMetadata.singleWindow(
            model: model(windowSeconds: 7 * 24 * 3600), primaryLabel: "5h", secondaryLabel: ""
        )
        XCTAssertNil(short?.timeRemainingFraction, "短周期窗口本来就没有重置进度标记")
        XCTAssertNotNil(long?.timeRemainingFraction, "长周期窗口的 ▼ 标记不能被吞掉")
    }

    // MARK: - 周瓶颈括号（5h 有效额度）

    /// 双窗口行的括号判定：周 × N **严格**小于 5h 剩余才显示，值 = min(5h, 周×N)。
    /// 判定与该行分段条共用 `EquivalentQuotaAllocation.bindingWindow`（含并列取 5h
    /// 的约定）——条缩到 30% 的同一行文字必须给出 "(30%有效)"，两者永远同源。
    func testWeeklyBindingEffectivePercentMirrorsTheBarBindingDecision() {
        let now = Date()
        func model(interval: Double?, weekly: Double?) -> ModelQuota {
            ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100, intervalUsageCount: 0,
                intervalRemainingPercent: interval ?? 0,
                intervalStatus: interval == nil ? .absent : .present,
                intervalResetsAt: interval == nil ? nil : now.addingTimeInterval(3600),
                intervalWindowSeconds: interval == nil ? nil : 5 * 3600,
                weeklyTotalCount: 100, weeklyUsageCount: 0,
                weeklyRemainingPercent: weekly ?? 0,
                weeklyStatus: weekly == nil ? .absent : .present,
                weeklyResetsAt: weekly == nil ? nil : now.addingTimeInterval(7 * 24 * 3600),
                weeklyWindowSeconds: weekly == nil ? nil : 7 * 24 * 3600
            )
        }

        // 用户实测场景：5h 100%、周 5%、N=6 → 条 30%，括号 "(30%有效)"。
        XCTAssertEqual(
            QuotaBarWithMetadata.weeklyBindingEffectivePercent(
                model: model(interval: 100, weekly: 5), multiplier: 6
            ) ?? -1, 30, accuracy: 0.0001
        )
        // 周充裕（85 × 6 封顶 100 ≥ 40）→ 5h 是瓶颈，维持单数值。
        XCTAssertNil(
            QuotaBarWithMetadata.weeklyBindingEffectivePercent(
                model: model(interval: 40, weekly: 85), multiplier: 6
            )
        )
        // 并列（60 == 10 × 6）→ 约定落到 5h，不显示括号（与 bindingWindow 一致）。
        XCTAssertNil(
            QuotaBarWithMetadata.weeklyBindingEffectivePercent(
                model: model(interval: 60, weekly: 10), multiplier: 6
            )
        )
        // 单窗口：不存在跨窗口瓶颈，永远不显示括号。
        XCTAssertNil(
            QuotaBarWithMetadata.weeklyBindingEffectivePercent(
                model: model(interval: 40, weekly: nil), multiplier: 6
            )
        )
        XCTAssertNil(
            QuotaBarWithMetadata.weeklyBindingEffectivePercent(
                model: model(interval: nil, weekly: 40), multiplier: 6
            )
        )
    }

    /// 两个窗口的明细**并排**而不是堆叠。
    ///
    /// 判据是**宽度**，不是高度——这个选择是被量出来的：视图里除两列外还有标题行和
    /// "周倍率"脚注，所以整个视图的堆叠/并排高度差被别的行淹没了（实测并排 98pt，
    /// 而手搭的"两行+分隔线"参照只有 69pt，两者压根不是同一段内容，比高度不成立）。
    ///
    /// 宽度很干净：`HoverMetricLine` 是固定构造（标签 18pt + 百分比 40pt + 两个可压缩
    /// 文本），单列自然宽 225pt，两列 `HStack(spacing: 16)` 自然宽 **466pt**
    /// = 225 × 2 + 16。实测并排状态下整个视图的自然宽正好也是 466——说明这条 `HStack`
    /// 就是驱动宽度的那一行。改回堆叠后视图宽度会塌到其它行（标题/脚注/单列）的最大
    /// 宽度，达不到 466，断言即红。
    ///
    /// ⚠️ 这条是**间接**判据：它证明的是"有 466pt 的一行"，不是"那两个 `usageSection`
    /// 在里面"。`QuotaUsageWindowsHoverView` 那处（列是 token 用量块）没有单独覆盖——
    /// 两处是同构改动，要给第二处也加一条得先量出它的单列宽度当参照。
    @MainActor
    func testUsageMetricHoverAlwaysSplitsPromptsRoundsAndInputCached() {
        let usage = UsageMetricSummary(
            prompts: 42,
            rounds: 128,
            inputTokens: 1_240_000,
            cachedInputTokens: 860_000,
            outputTokens: 320_000,
            reasoningOutputTokens: 96_000
        )
        let split = self.measuredHeight(
            of: UsageMetricHoverSummaryView(title: "", usage: usage, showPromptCount: true),
            minWidth: 1_000
        )
        let merged = self.measuredHeight(of: Self.mergedMetricSummary(usage: usage), minWidth: 1_000)

        XCTAssertGreaterThan(split, 0, "前提不成立：这一组必须真的排得出来")
        XCTAssertGreaterThan(
            split, merged * 1.5,
            "prompts/rounds 与 input/cached 必须各占一行（拆行 \(split)pt vs 合并 \(merged)pt）"
        )
    }

    // MARK: - helpers

    /// 测任意视图在 `minWidth` 下的自然高度。
    ///
    /// 宽度不设死：hover 浮层本身按内容自适应（见 `HoverPanelController`），
    /// 这里只是给个下限让 layout 跑起来。
    @MainActor
    private func measuredHeight<V: View>(of view: V, minWidth: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view).frame(width: minWidth))
        hosting.frame = CGRect(x: 0, y: 0, width: minWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// 收敛**之前**的合并写法当参照物：`prompts: 42 (128 rounds)` 与
    /// `input: 380K (+860K cached)` 各占一行（4 行），拆行写法是 8 行。
    ///
    /// 字体与 `UsageMetricHoverSummaryView.metricLine` 保持一致，否则量到的高度
    /// 比的不是"行数"而是"字号"。
    @MainActor
    private static func mergedMetricSummary(usage: UsageMetricSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("prompts: ")
                    .foregroundStyle(.secondary)
                Text("\(Formatters.formatGroupedInt(usage.prompts))")
                    .foregroundStyle(.primary)
                Text(" (\(Formatters.formatGroupedInt(usage.rounds)) rounds)")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Text("input: ")
                    .foregroundStyle(.secondary)
                Text("\(Formatters.formatTokenCountCompact(usage.uncachedInputTokens)) "
                     + "(+\(Formatters.formatTokenCountCompact(usage.cachedInputTokens)) cached)")
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 0) {
                Text("output: ")
                    .foregroundStyle(.secondary)
                Text(Formatters.formatTokenCountCompact(usage.outputTokens))
                    .foregroundStyle(.primary)
            }
        }
        .font(MenuTypography.hoverBodyMonospaced)
    }
}
