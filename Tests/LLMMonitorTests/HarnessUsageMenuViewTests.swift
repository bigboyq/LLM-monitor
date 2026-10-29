import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 菜单 Harness 视图的排版预算与客户端/fleet 范围选择测试。
final class HarnessUsageMenuViewTests: XCTestCase {

    /// 菜单内容区宽度：360pt 面板减去 `LayoutMetrics.cardColumnHorizontalPadding`
    /// 两侧内边距。改菜单宽度时这里必须跟着动。
    private var contentWidth: CGFloat {
        MenuPanelHeightBridge.width - LayoutMetrics.cardColumnHorizontalPadding * 2
    }

    func testRowUsesCompactTwoLineLayoutWithinMenuWidth() {
        XCTAssertEqual(MenuContentMode.usage.rawValue, "usage")
        XCTAssertEqual(MenuContentMode.quota.rawValue, "quota")
        XCTAssertEqual(HarnessModelRowView.columnSpacing, 4)
    }

    /// 菜单额度行在展开时切换到 Plan-only 渲染；该模式参与 ProviderCardView 的值相等判断，
    /// 以免 `.equatable()` 把完整卡片缓存为旧形态（或反过来）。
    func testPlanOnlyModeParticipatesInProviderCardEquatableIdentity() {
        let status = Self.codexFixture()
        let fullCard = ProviderCardView(status: status)
        let planOnly = ProviderCardView(status: status, showsPlanDetailsOnly: true)
        XCTAssertNotEqual(fullCard, planOnly)
        XCTAssertEqual(planOnly, ProviderCardView(status: status, showsPlanDetailsOnly: true))
    }

    func testQuotaPresentationSummarizesWindowsAndDeepSeekBalanceWithoutWindows() {
        let windows = [
            quotaModel(name: "first", interval: 64, weekly: 48),
            quotaModel(name: "second", interval: 32, weekly: 72)
        ]
        XCTAssertEqual(
            MenuQuotaPresentation.summary(providerKind: .codexChatGpt, models: windows, balance: nil),
            "5h 32% · 周 48%"
        )

        let balance = DeepseekBalanceDetail(currency: "CNY", total: 12.3, toppedUp: 10, granted: 2.3)
        XCTAssertEqual(
            MenuQuotaPresentation.summary(providerKind: .deepseek, models: [], balance: balance),
            "余额 ¥12.30"
        )
        XCTAssertEqual(
            MenuQuotaPresentation.summary(providerKind: .codexChatGpt, models: [], balance: balance),
            "暂无窗口额度"
        )
    }

    func testQuotaEmptyStateDistinguishesNoProvidersFromAllDisabled() {
        XCTAssertEqual(MenuQuotaPresentation.emptyState(for: []), .noProviders)
        var disabled = Self.codexFixture()
        disabled.isEnabled = false
        XCTAssertEqual(MenuQuotaPresentation.emptyState(for: [disabled]), .noEnabledProviders)
    }

    func testProviderDetailRouteKeepsModelContextAndFallsBackForDisabledOrMissingTargets() {
        let descriptor = FetcherDescriptor(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "codex_chatgpt", displayName: "ChatGPT Plan", kind: .codexChatGpt) }
        )
        let route = ProviderDetailRoute(providerID: "codex_chatgpt", modelName: "gpt-5")
        XCTAssertEqual(route.modelName, "gpt-5")
        XCTAssertEqual(
            ProviderDetailRouting.target(route: route, statuses: [], descriptors: [descriptor]),
            .disabled(.codexChatGpt)
        )
        XCTAssertEqual(
            ProviderDetailRouting.target(route: route, statuses: [], descriptors: []),
            .missing
        )
    }

    func testSystemNotificationSoundDefaultsOnAndRoundTripsOff() throws {
        XCTAssertTrue(AppConfig.default.effectiveSystemNotificationSoundEnabled)
        var config = AppConfig.default
        config.systemNotificationSoundEnabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertFalse(decoded.effectiveSystemNotificationSoundEnabled)
    }

    /// 今日汇总**双焦点 Hero 卡片**的宽度预算：
    /// 1. 顶栏：标签 + 命中率胶囊，两端对齐且留有 Spacer。
    /// 2. 核心大字行：大号 Token + 最宽混币大号主金额，两端对齐且留有 Spacer。
    /// 不得超出卡片内宽（内容区 − 卡片两侧 8pt padding）。
    @MainActor
    func testTodayOverviewRowFitsItsInnerWidth() {
        let innerWidth = contentWidth - 16
        // 1. 顶栏：标签 + 命中率胶囊
        let label = self.width(of: Text("今日 10-27").font(MenuTypography.metricLabel))
        let hitBadge = self.width(
            of: HStack(spacing: 3) {
                Text("命中").font(.system(size: 9, weight: .medium))
                Text(HarnessUsageMenuView.hitRateText(1.0)).font(.system(size: 9, weight: .bold))
            }
        ) + 12 // capsule horizontal padding 6 * 2
        let topRow = label + hitBadge + 12 // min spacer
        XCTAssertLessThanOrEqual(
            topRow, innerWidth,
            "今日汇总顶栏超出卡片内宽 \(innerWidth)pt"
        )

        // 2. 核心大字行：大号 Token + 大号金额（跨币种最宽形态）
        let tokensWidth = self.width(of: Text("1,041M").font(MenuTypography.todayHeroValue))
        let value = MixedCurrencyEstimate(usd: 7610.55, cny: 45659.85)
        let costParts = HarnessUsageMenuView.heroCostParts(from: value.displayText)
        XCTAssertEqual(costParts.primary, "¥98933.7")
        XCTAssertEqual(costParts.subtitle, "折合总额（含$7610.55）")

        let costPrimaryWidth = self.width(of: Text(costParts.primary).font(MenuTypography.todayHeroValue))
        let heroRow = tokensWidth + costPrimaryWidth + 12 // min spacer
        XCTAssertLessThanOrEqual(
            heroRow, innerWidth,
            "今日汇总核心 Hero 行最坏 \(heroRow)pt 超出卡片内宽 \(innerWidth)pt"
        )
    }

    func testHeroCostPartsFormatting() {
        let singleCNY = HarnessUsageMenuView.heroCostParts(from: "¥385.00")
        XCTAssertEqual(singleCNY.primary, "¥385.00")
        XCTAssertEqual(singleCNY.subtitle, "今日花费")

        let singleUSD = HarnessUsageMenuView.heroCostParts(from: "$47.60")
        XCTAssertEqual(singleUSD.primary, "$47.60")
        XCTAssertEqual(singleUSD.subtitle, "今日花费")

        let mixed = HarnessUsageMenuView.heroCostParts(from: "385.0（含$47.6）")
        XCTAssertEqual(mixed.primary, "¥385.0")
        XCTAssertEqual(mixed.subtitle, "折合总额（含$47.6）")

        let missing = HarnessUsageMenuView.heroCostParts(from: "—")
        XCTAssertEqual(missing.primary, "—")
        XCTAssertEqual(missing.subtitle, "今日花费")
    }

    /// 联动未启用时，传统菜单仍要在客户端段之前显示今日总览。
    @MainActor
    func testLegacyMenuIncludesTodayOverviewBeforeClientSections() {
        let summary = HarnessTodaySummary.summarize(
            statuses: [Self.codexFixture()],
            now: Date(),
            calendar: .current
        )
        guard let section = summary.sections.first else {
            XCTFail("fixture 必须产生一个客户端段")
            return
        }
        let viewHeight = height(of: HarnessUsageMenuView(summary: summary))
        let sectionHeight = height(of: HarnessSectionView(section: section))
        XCTAssertGreaterThan(
            viewHeight, sectionHeight + 30,
            "单机菜单须包含顶部今日总览，不能只剩客户端段"
        )
    }

    func testMissingSelectedNodeDoesNotResolveToLocalContent() {
        XCTAssertTrue(HarnessUsageMenuView.isMissingNodeSelection(
            scope: .node(UUID()), nodeSummary: nil
        ))
        XCTAssertFalse(HarnessUsageMenuView.isMissingNodeSelection(
            scope: .local, nodeSummary: nil
        ))
    }

    @MainActor
    func testMissingGlobalDailyDataKeepsGlobalUnavailableRendering() {
        let summary = FleetMenuSummary(
            multiNode: true,
            hasDailyData: false,
            dailyNotice: "全局今日用量尚未同步",
            fleetTotals: FleetMenuSummary.TotalsRow(
                tokens: 0, hitRate: nil, valueText: "—", buckets: .zero
            ),
            sections: []
        )
        XCTAssertTrue(HarnessUsageMenuView.isUnavailableFleetSelection(
            scope: .fleet, summary: summary
        ))
        XCTAssertFalse(HarnessUsageMenuView.isUnavailableFleetSelection(
            scope: .local, summary: summary
        ), "切回本机后仍使用本机菜单内容")

        let view = HarnessUsageMenuView(
            summary: HarnessTodaySummary.summarize(statuses: [Self.codexFixture()], now: Date()),
            fleetSummary: summary,
            activeScope: .fleet,
            scopeChoices: [FleetNodeChoice(id: UUID(), name: "远端", stale: false)]
        )
        XCTAssertGreaterThan(height(of: view), 0, "未同步状态必须实际布局出来")
    }

    /// 真的布局一次：长模型名与部分计价必须在内容区内折行/截断。
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

    /// 两行排版在指定菜单宽度下可布局，不再要求六列都挤进同一行。
    @MainActor
    func testModelRowNaturalWidthFitsCompactContent() {
        let row = HarnessModelRow(
            dayStart: Calendar.current.startOfDay(for: Date()),
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.5",
            samples: [Self.sample(at: Date())],
            calendar: .current
        )
        let hosting = NSHostingView(rootView: AnyView(HarnessModelRowView(row: row)))
        hosting.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hosting.fittingSize.width, contentWidth + 0.5)
        XCTAssertGreaterThan(hosting.fittingSize.height, 20, "模型行应分成至少两层信息")
    }

    /// 段头与模型行同构（Token 小计 / 命中占位 / 速度汇总 / 价值四格定宽）后，
    /// 段头的自然宽仍不得超出内容区：最长的注册客户端名 + 图标 + Spacer 最小宽
    /// + 四格定宽 + 列间距要装进 336pt。名称列是行里唯一的弹性部分——数值格组
    /// 再多占一点宽度，最先被挤没的就是段名。
    @MainActor
    func testSectionHeaderFitsTheMenuContentWidth() {
        let section = Self.sectionFixture(rowCount: 1, displayName: "MiniMax Code")
        let width = self.width(of: HarnessSectionView(section: section))
        XCTAssertLessThanOrEqual(
            width, contentWidth,
            "段头自然宽 \(width)pt 超出内容区 \(contentWidth)pt——段头数值格组挤掉了段名"
        )
        XCTAssertGreaterThan(width, 0)
    }

    /// 段数 / 行数增加时高度增长（有内容可滚），但单段视图本身必须矮——
    /// `MenuPanelHeightBridge` 用它换算窗口高度，一个段撑到半屏就说明排版跑偏了。
    @MainActor
    func testSectionsStayCompactEnoughForTheMenuHeightBudget() {
        let oneRow = HarnessSectionView(section: Self.sectionFixture(rowCount: 1))
        let fiveRows = HarnessSectionView(section: Self.sectionFixture(rowCount: 5))
        let single = self.height(of: oneRow)
        let five = self.height(of: fiveRows)
        XCTAssertGreaterThanOrEqual(five, single, "折叠状态允许不同模型数拥有相同高度")
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

    // MARK: - fleet 段头右键刷新（§10.2）

    /// fleet 段头右键「刷新 <客户端名>」刷的是**本机**这一段：交出去的是
    /// clientID 对应的那一段，不是别的段、也不是全部段。
    ///
    /// 这条钉的是"点 A 刷 A"：fleet 段头给的是 clientID，路由取错段的话，用户
    /// 点一个客户端的右键却刷了另一个客户端的卡（而且毫无反馈）。
    @MainActor
    func testFleetSectionRefreshRoutesToTheMatchingLocalSection() {
        let sections = [
            Self.sectionFixture(rowCount: 1, clientID: ClientID.openCode),
            Self.sectionFixture(rowCount: 1, clientID: ClientID.dsh)
        ]
        var refreshed: [String] = []
        HarnessUsageMenuView.refreshLocalSection(
            clientID: ClientID.dsh,
            sections: sections
        ) { refreshed.append($0.clientID) }
        XCTAssertEqual(refreshed, [ClientID.dsh], "只刷命中的那一段")
    }

    /// 本机没有这一段（该客户端今天只有远端数据）→ 什么都不做：不改刷别的段，
    /// 不崩。
    @MainActor
    func testFleetSectionRefreshDoesNothingWithoutAMatchingLocalSection() {
        let sections = [Self.sectionFixture(rowCount: 1, clientID: ClientID.openCode)]
        var refreshed: [String] = []
        HarnessUsageMenuView.refreshLocalSection(
            clientID: ClientID.zcode,
            sections: sections
        ) { refreshed.append($0.clientID) }
        XCTAssertTrue(refreshed.isEmpty, "本机没有这一段时不该刷任何段")
    }

    /// fleet 段头右键项的文案钉死：「刷新本机 <客户端名>」——「本机」二字是
    /// 语义的一部分（刷的是本机数据，不是 fleet 合计）。
    @MainActor
    func testFleetSectionRefreshMenuTitleKeepsTheLocalWording() {
        XCTAssertEqual(
            FleetClientSectionView.refreshMenuTitle(displayName: "OpenCode"),
            "刷新本机 OpenCode"
        )
    }

    /// 节点形态的段头**没有**右键刷新：刷的是本机数据，对单节点视图无意义。
    /// 全局形态才有（节点分支不传 `onRefreshClient`）。
    @MainActor
    func testNodeScopedFleetSectionHasNoRefreshMenu() {
        let section = Self.fleetClientSectionFixture()
        XCTAssertFalse(
            FleetClientSectionView(section: section).hasRefreshMenu,
            "节点形态不该出现段头右键刷新"
        )
        XCTAssertTrue(
            FleetClientSectionView(section: section, onRefreshClient: { _ in }).hasRefreshMenu,
            "全局形态必须保留段头右键刷新"
        )
    }

    /// 菜单分隔线与 footer 竖线共用同一份规格常量。
    /// 数值被钉死是"观感不变"的直接证据：收敛到 `MenuHairline` 是**提纯**，不是改设计。
    func testHairlineKeepsTheOriginalOnePointEightPercentSpec() {
        XCTAssertEqual(MenuHairline.thickness, 1, "发丝线一直是 1pt")
        XCTAssertEqual(MenuHairline.opacity, 0.08, accuracy: 1e-9, "发丝线一直是前景色 8%")
        XCTAssertEqual(MenuHairline.verticalLength, 10, "footer 分隔竖线一直是 10pt")
    }

    // MARK: - 今日占比条（客户端占比）

    /// 占比条段 = 有今日活动的客户端段：顺序跟随 sections（调用方已按 token 降序），
    /// 零活动段整段过滤，主 provider 是段内今日 token 最大的那一路。
    func testClientSegmentsFollowSectionsAndCarryDominantProvider() {
        let minimaxSection = Self.segmentFixture(
            clientID: ClientID.minimaxCode, displayName: "MiniMax Code",
            rows: [(QuotaProviderID.minimax, 355_000_000)]
        )
        let codexSection = Self.segmentFixture(
            clientID: ClientID.codex, displayName: "Codex",
            rows: [(QuotaProviderID.openAI, 107_000_000)]
        )
        let emptySection = Self.segmentFixture(
            clientID: ClientID.dsh, displayName: "DSH", rows: []
        )
        let segments = HarnessTodaySummary.clientSegments(
            from: [minimaxSection, codexSection, emptySection]
        )
        XCTAssertEqual(
            segments.map(\.clientID), [ClientID.minimaxCode, ClientID.codex],
            "顺序跟随 sections，零活动段不占位"
        )
        XCTAssertEqual(segments.map(\.totalTokens), [355_000_000, 107_000_000])
        XCTAssertEqual(
            segments.map(\.dominantQuotaProviderID),
            [QuotaProviderID.minimax, QuotaProviderID.openAI]
        )
    }

    /// 多 provider 分片客户端（ZCode 型）的主 provider 取今日 token 最大的一路；
    /// 并列时取 quotaProviderID 字典序小者，结果与行序无关（字典遍历无序）。
    func testDominantProviderPicksLargestShareAndTieBreaksLexicographically() {
        let mixed = Self.segmentFixture(
            clientID: ClientID.zcode, displayName: "ZCode",
            rows: [
                (QuotaProviderID.zhipu, 100),
                (QuotaProviderID.minimax, 300),
                (QuotaProviderID.deepseek, 200)
            ]
        )
        XCTAssertEqual(
            HarnessTodaySummary.clientSegments(from: [mixed]).first?.dominantQuotaProviderID,
            QuotaProviderID.minimax
        )
        XCTAssertEqual(
            HarnessClientSegment.dominantQuotaProviderID([
                ("zhipu", 100), ("deepseek", 100)
            ]),
            QuotaProviderID.deepseek,
            "并列取字典序小者（deepseek < zhipu）"
        )
        XCTAssertEqual(
            HarnessClientSegment.dominantQuotaProviderID([
                ("deepseek", 100), ("zhipu", 100)
            ]),
            QuotaProviderID.deepseek,
            "同一批行换行序仍算出同一个归属"
        )
    }

    /// 占比条数学：段宽 = 段 token / 全部段 token；空段与全零总量都退回全 0
    /// （纯灰底），任何输入不产生 NaN。
    func testProportionBarFractionsMatchTokenShares() {
        let fractions = HarnessClientProportionBar.fractions(for: [
            HarnessClientSegment(
                clientID: "a", displayName: "A", totalTokens: 355_000_000,
                dominantQuotaProviderID: QuotaProviderID.minimax),
            HarnessClientSegment(
                clientID: "b", displayName: "B", totalTokens: 107_000_000,
                dominantQuotaProviderID: QuotaProviderID.openAI),
        ])
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(fractions[0], 355.0 / 462.0, accuracy: 1e-12)
        XCTAssertEqual(fractions[1], 107.0 / 462.0, accuracy: 1e-12)
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: 1e-12)

        XCTAssertTrue(HarnessClientProportionBar.fractions(for: []).isEmpty)
        let zero = HarnessClientProportionBar.fractions(for: [
            HarnessClientSegment(
                clientID: "a", displayName: "A", totalTokens: 0, dominantQuotaProviderID: nil)
        ])
        XCTAssertEqual(zero, [0.0], "全零总量退回纯灰底")
    }

    /// 段色映射覆盖五个 quota provider；nil / 未知 ID 回退 nil → 灰（与 .custom
    /// 同款，「不知道是谁」不读成某个品牌）。
    func testProportionBarAccentCoversEveryQuotaProvider() {
        XCTAssertEqual(
            HarnessClientProportionBar.accent(forQuotaProviderID: QuotaProviderID.minimax),
            .minimax
        )
        XCTAssertEqual(
            HarnessClientProportionBar.accent(forQuotaProviderID: QuotaProviderID.openAI),
            .chatgpt
        )
        XCTAssertEqual(
            HarnessClientProportionBar.accent(forQuotaProviderID: QuotaProviderID.antigravity),
            .antigravity
        )
        XCTAssertEqual(
            HarnessClientProportionBar.accent(forQuotaProviderID: QuotaProviderID.zhipu),
            .glm
        )
        XCTAssertEqual(
            HarnessClientProportionBar.accent(forQuotaProviderID: QuotaProviderID.deepseek),
            .deepseek
        )
        XCTAssertNil(HarnessClientProportionBar.accent(forQuotaProviderID: nil))
        XCTAssertNil(HarnessClientProportionBar.accent(forQuotaProviderID: "unknown"))
    }

    /// tooltip 文案：「名 token（占比%）」；总量为 0 时退回只有 token 数——0 做
    /// 分母的占比没有意义。
    func testProportionBarTooltipTextStatesShareOfTotal() {
        let segment = HarnessClientSegment(
            clientID: ClientID.minimaxCode, displayName: "MiniMax Code",
            totalTokens: 355_000_000, dominantQuotaProviderID: QuotaProviderID.minimax
        )
        XCTAssertEqual(
            HarnessClientProportionBar.tooltipText(for: segment, totalTokens: 462_000_000),
            "MiniMax Code 355M（77%）"
        )
        XCTAssertEqual(
            HarnessClientProportionBar.tooltipText(for: segment, totalTokens: 0),
            "MiniMax Code 355M"
        )
    }

    /// 占比条 + 图例真的布局出来：条高 = 标准槽高；7 个客户端的图例超出一行宽
    /// 时必须换行（高度涨上去），而不是把占比最小的那批客户端截没。
    @MainActor
    func testClientProportionBarAndLegendRenderAndWrap() {
        let segments = (0..<7).map { index in
            HarnessClientSegment(
                clientID: "c\(index)", displayName: "Client \(index)",
                totalTokens: 100 + index, dominantQuotaProviderID: QuotaProviderID.zhipu
            )
        }
        let barHeight = self.height(of: HarnessClientProportionBar(segments: segments))
        XCTAssertEqual(
            barHeight, HarnessClientProportionBar.standardHeight, accuracy: 0.5,
            "占比条与模型行的三段条同高（同一张卡里条高不齐很难看）"
        )
        let legendHeight = self.height(of: HarnessClientLegend(
            segments: segments, totalTokens: segments.reduce(0) { $0 + $1.totalTokens }
        ))
        XCTAssertGreaterThan(
            legendHeight, 16,
            "7 个 chip 一行放不下，图例必须换行（不换行时高度只有单行 ~13pt）"
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

    /// 一个客户端 + 一个极长模型名的行：模型名列尾截断，右侧五列仍定宽。
    /// `clientID` 可切换测试数据段；`displayName` 可覆盖段头的展示名。
    private static func sectionFixture(
        rowCount: Int,
        isTruncated: Bool = false,
        clientID: String = ClientID.openCode,
        displayName: String? = nil
    ) -> HarnessSection {
        let rows = (0..<rowCount).map { index in
            HarnessModelRow(
                dayStart: Calendar.current.startOfDay(for: Date()),
                clientID: clientID,
                quotaProviderID: QuotaProviderID.openAI,
                modelName: index == 0
                    ? "claude-sonnet-4-6-thinking-extended-preview-20260101"
                    : "model-\(index)",
                samples: [Self.sample(at: Date())],
                calendar: .current
            )
        }
        return HarnessSection(
            clientID: clientID,
            displayName: displayName ?? clientID,
            iconSystemName: "terminal",
            buckets: TokenUsageBuckets(input: 400_000, cacheRead: 600_000, output: 200_000, reasoning: 100_000),
            tokensPerSecond: nil,
            value: MixedCurrencyEstimate(usd: 11.3, cny: 0),
            rows: rows,
            isTruncated: isTruncated
        )
    }

    /// fleet 形态的一个客户端段（段头 + 节点/模型行）。右键刷新的门控只关心
    /// 段本身，节点行与模型行留空即可。
    private static func fleetClientSectionFixture(
        clientID: String = ClientID.openCode
    ) -> FleetMenuSummary.ClientSection {
        FleetMenuSummary.ClientSection(
            clientID: clientID,
            displayName: "OpenCode",
            iconSystemName: "terminal",
            buckets: TokenUsageBuckets(input: 1_000, cacheRead: 0, output: 0, reasoning: 0),
            costText: "¥1.00",
            isTruncated: false,
            nodes: [],
            models: [],
            mergedModels: []
        )
    }

    /// 占比条测试用的一个客户端段：`rows` 是 (quotaProviderID, 今日 token) 对，
    /// 每行一个模型样本（cached 为 0，行 token = 输入 token）。空 `rows` 造出
    /// 零活动段（`clientSegments(from:)` 必须把它滤掉）。
    private static func segmentFixture(
        clientID: String,
        displayName: String,
        rows: [(quotaProviderID: String, tokens: Int)]
    ) -> HarnessSection {
        let modelRows = rows.map { row in
            HarnessModelRow(
                dayStart: Calendar.current.startOfDay(for: Date()),
                clientID: clientID,
                quotaProviderID: row.quotaProviderID,
                modelName: "model-\(row.quotaProviderID)",
                samples: [LocalTokenUsageSample(
                    completedAt: Date(),
                    modelName: "model-\(row.quotaProviderID)",
                    promptID: "p-\(row.quotaProviderID)",
                    inputTokens: row.tokens,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0
                )],
                calendar: .current
            )
        }
        let buckets = modelRows.reduce(TokenUsageBuckets.zero) { acc, row in
            TokenUsageBuckets(
                input: acc.input + row.buckets.input,
                cacheRead: acc.cacheRead + row.buckets.cacheRead,
                output: acc.output + row.buckets.output,
                reasoning: acc.reasoning + row.buckets.reasoning
            )
        }
        return HarnessSection(
            clientID: clientID,
            displayName: displayName,
            iconSystemName: "terminal",
            buckets: buckets,
            tokensPerSecond: nil,
            value: MixedCurrencyEstimate(estimates: modelRows.map(\.costEstimate)),
            rows: modelRows,
            isTruncated: false
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

    private func quotaModel(name: String, interval: Double, weekly: Double) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: Int(100 - interval),
            intervalRemainingPercent: interval,
            intervalStatus: .present,
            intervalResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 100,
            weeklyUsageCount: Int(100 - weekly),
            weeklyRemainingPercent: weekly,
            weeklyStatus: .present,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_900_000_000),
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
    }
}
