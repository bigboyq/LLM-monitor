import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 菜单 Harness 视图的**排版预算**守门：列宽定死在一屏内，数字列定宽右对齐。
///
/// 这些常量改起来没有编译错误、也没有运行时错误——超宽只会让模型名被挤没或
/// 占比条塌成一条线，肉眼要在一台真机菜单里才看得出来。所以这里量一次
/// `NSHostingView` 的自然宽：溢出 336pt（菜单 360 − 两侧 12pt 内边距）即红。
final class HarnessUsageMenuViewTests: XCTestCase {

    /// 菜单内容区宽度：360pt 面板减去 `LayoutMetrics.cardColumnHorizontalPadding`
    /// 两侧内边距。改菜单宽度时这里必须跟着动。
    private var contentWidth: CGFloat {
        MenuPanelHeightBridge.width - LayoutMetrics.cardColumnHorizontalPadding * 2
    }

    /// 五列定宽 + 四段间距不得超出内容区。少一个 term 就说明新增/加宽了某一列。
    func testRowColumnBudgetFitsTheMenuContentWidth() {
        let columns = [
            HarnessModelRowView.modelNameWidth,
            HarnessModelRowView.bucketBarMinWidth,
            HarnessModelRowView.tokenWidth,
            HarnessModelRowView.hitRateWidth,
            HarnessModelRowView.valueWidth
        ]
        let budget = columns.reduce(0, +) + CGFloat(columns.count - 1) * 6
        XCTAssertLessThanOrEqual(
            budget, contentWidth,
            "模型行五列（\(budget)pt）超出内容区 \(contentWidth)pt，模型名或占比条会被压没"
        )
        XCTAssertGreaterThanOrEqual(
            HarnessModelRowView.bucketBarMinWidth, 72,
            "占比条低于 72pt 就看不出三段比例了"
        )
    }

    /// 今日合计**数字行**的宽度预算：标签 + 总 token 列 + 裸命中率列 + 最宽常见
    /// 混币价值 + 裸刷新时间 + 各段间距，不得超出卡片内宽（内容区 − 卡片自带的
    /// 两侧 8pt padding）。超出时先被 tail 截断的是混币价值——这条钉住的是
    /// "常见最坏形态不必动用截断"；跨天时间（`MM-dd HH:mm`，实测 59pt）与扫描
    /// 态（「计算中…」+ 进度圈，实测 52pt）共用这条余量，真同时发生时由价值
    /// 截断兜底，与改造前同一口径。
    @MainActor
    func testTodayOverviewRowFitsItsInnerWidth() {
        let innerWidth = contentWidth - 16
        let label = self.width(of: Text("今日合计").font(MenuTypography.metricLabel))
        let hitRate = self.width(
            of: Text(HarnessUsageMenuView.hitRateText(1.0)).font(MenuTypography.metricValue)
        )
        // 混币价值最宽的常见形态：跨币种 + 两位小数（`MixedCurrencyEstimate` 的
        // 呈现口径，trim 后无分组分隔符）。
        let value = MixedCurrencyEstimate(usd: 7610.55, cny: 45659.85)
        let valueText = self.width(of: Text(value.displayText).font(MenuTypography.metricValue))
        let refreshTime = self.width(of: Text("21:09").font(MenuTypography.badge))

        let row = label
            + HarnessUsageMenuView.totalWidth
            + HarnessUsageMenuView.hitRateWidth
            + valueText
            + refreshTime
            + 4 * 6   // HStack 四段固定间距
            + 4       // Spacer 最小宽
        XCTAssertLessThanOrEqual(
            row, innerWidth,
            "今日合计行最坏 \(row)pt 超出卡片内宽 \(innerWidth)pt，混币价值会被截断"
        )
    }

    /// 真的布局一次：最宽形态（长模型名 + 9 字符 token + 部分计价）下自然宽不得
    /// 超过内容区。定宽常量是这条的**前提**——任何一个数字列去掉 `.frame(width:)`
    /// 都会让自然宽按文案涨上去。
    @MainActor
    func testRenderedViewNeverExceedsTheContentWidth() {
        let summary = HarnessTodaySummary.summarize(
            statuses: Self.widestFixture(),
            now: Date(),
            calendar: .current
        )
        XCTAssertFalse(summary.isEmpty, "fixture 必须真的有内容，否则量的是空视图")

        let hosting = NSHostingView(
            rootView: AnyView(HarnessUsageMenuView(summary: summary).frame(width: contentWidth))
        )
        hosting.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()

        let size = hosting.fittingSize
        XCTAssertLessThanOrEqual(
            size.width, contentWidth + 0.5,
            "菜单内容自然宽 \(size.width)pt 溢出内容区 \(contentWidth)pt"
        )
        XCTAssertGreaterThan(size.height, 0)
    }

    /// 模型名那一列**必须真的占宽度**。
    ///
    /// 曾经的写法是 `Text(...).frame(maxWidth:)` + 给占比条 `.layoutPriority(1)`：
    /// `TokenBucketBar` 内部是 `GeometryReader`（贪婪），优先级一高就把整行吃光，
    /// 模型名列被压成 0pt——**自然宽**因此只剩三个定宽数字列（约 150pt），
    /// 而定宽写法下自然宽正好是五列之和 328pt。这条断言就是那次 bug 的守门。
    @MainActor
    func testModelRowNaturalWidthCoversAllFiveColumns() {
        let row = HarnessModelRow(
            dayStart: Calendar.current.startOfDay(for: Date()),
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.5",
            samples: [Self.sample(at: Date())],
            calendar: .current
        )
        let hosting = NSHostingView(rootView: AnyView(HarnessModelRowView(row: row)))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        hosting.layoutSubtreeIfNeeded()

        let expected = HarnessModelRowView.modelNameWidth
            + HarnessModelRowView.bucketBarMinWidth
            + HarnessModelRowView.tokenWidth
            + HarnessModelRowView.hitRateWidth
            + HarnessModelRowView.valueWidth
            + 4 * 6
        XCTAssertEqual(
            hosting.fittingSize.width, expected, accuracy: 0.5,
            "模型行自然宽应等于五列定宽之和（模型名列塌成 0pt 时会明显更小）"
        )
    }

    /// 段数 / 行数增加时高度增长（有内容可滚），但单段视图本身必须矮——
    /// `MenuPanelHeightBridge` 用它换算窗口高度，一个段撑到半屏就说明排版跑偏了。
    @MainActor
    func testSectionsStayCompactEnoughForTheMenuHeightBudget() {
        let oneRow = HarnessSectionView(section: Self.sectionFixture(rowCount: 1))
        let fiveRows = HarnessSectionView(section: Self.sectionFixture(rowCount: 5))
        let single = self.height(of: oneRow)
        let five = self.height(of: fiveRows)
        XCTAssertGreaterThan(five, single, "5 行必然比 1 行高，否则行没被渲染")
        XCTAssertLessThan(
            five, 120,
            "5 行的一段已经 \(five)pt（单行段 \(single)pt），菜单会被单个客户端吃满"
        )
    }

    /// 截断提示**只在该段的数据源真被截断时出现**。
    ///
    /// 高度差就是那行在不在线的直接证据（只差 `isTruncated` 一个字段）。提示用
    /// 的是 `ClientUsageTruncationNotice.text`（与设置页展开行、7 天柱图脚注同一
    /// 常量），所以它固定占两行上下；哪天改成一行，这条的高度上限要跟着改。
    @MainActor
    func testTruncationNoticeOnlyShowsForTruncatedSections() {
        let truncated = self.height(of: HarnessSectionView(
            section: Self.sectionFixture(rowCount: 2, isTruncated: true)
        ))
        let complete = self.height(of: HarnessSectionView(
            section: Self.sectionFixture(rowCount: 2, isTruncated: false)
        ))
        XCTAssertGreaterThan(
            truncated, complete,
            "被截断的段必须多出橙色截断提示行（否则一份残缺统计被当完整统计读）"
        )
    }

    // MARK: - helpers

    @MainActor
    private func height<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: contentWidth)))
        hosting.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// 宽画布量单段文案 / 视图的**自然宽**：定宽列常量必须装得下各自的文案。
    @MainActor
    private func width<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    /// 一个客户端 + 一个极长模型名的行：模型名列尾截断，右侧四列仍定宽。
    private static func sectionFixture(rowCount: Int, isTruncated: Bool = false) -> HarnessSection {
        let rows = (0..<rowCount).map { index in
            HarnessModelRow(
                dayStart: Calendar.current.startOfDay(for: Date()),
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.openAI,
                modelName: index == 0
                    ? "claude-sonnet-4-6-thinking-extended-preview-20260101"
                    : "model-\(index)",
                samples: [Self.sample(at: Date())],
                calendar: .current
            )
        }
        return HarnessSection(
            clientID: ClientID.openCode,
            displayName: "OpenCode",
            iconSystemName: "terminal",
            buckets: TokenUsageBuckets(input: 400_000, cacheRead: 600_000, output: 200_000, reasoning: 100_000),
            value: MixedCurrencyEstimate(usd: 11.3, cny: 0),
            rows: rows,
            isTruncated: isTruncated
        )
    }

    private static func widestFixture() -> [ProviderStatus] {
        [codexFixture(), deepseekFixture()]
    }

    private static func sample(at date: Date) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: "gpt-5.5",
            promptID: "p1",
            inputTokens: 1_000_000,
            cachedInputTokens: 600_000,
            outputTokens: 200_000,
            reasoningOutputTokens: 100_000
        )
    }

    private static func codexFixture() -> ProviderStatus {
        let samples = [sample(at: Date())]
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                lastPrompt: nil,
                dailyTokenUsage: [],
                recentSamples: samples,
                scannedAt: Date()
            ),
            fetchedAt: Date()
        )
        return ProviderStatus(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .ok(info)
        )
    }

    private static func deepseekFixture() -> ProviderStatus {
        let samples = [
            LocalTokenUsageSample(
                completedAt: Date(),
                modelName: "deepseek-chat",
                promptID: "d1",
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        ]
        return ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: DshLocalUsage(
                byProvider: ["deepseek": DshProviderUsage(
                    today: nil,
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: samples.count,
                    recentSamples: samples
                )],
                modelsByProvider: [:],
                sessionsRoot: nil,
                sessionCount: 1,
                eventCount: samples.count,
                scannedAt: Date()
            )
        )
    }
}
