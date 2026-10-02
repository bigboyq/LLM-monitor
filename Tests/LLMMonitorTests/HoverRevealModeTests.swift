import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 折叠区（`HoverInfoRow`）的展开方式，以及由它决定的两套卡片排版。
///
/// 主菜单依赖"hover 才展开"来控制信息密度，所以**默认值必须永远是 `.onHover`**。
/// 改默认值不会报错、不会崩，只会让菜单忽然变成一堵没人能看完的墙 —— 这类回归
/// 只能靠一条断言挡住。
final class HoverRevealModeTests: XCTestCase {

    func testDefaultIsOnHoverSoTheMenuKeepsCollapsing() {
        // 不设任何环境值时（主菜单的所有卡片都是这种情况）必须走 hover 浮层。
        XCTAssertEqual(
            EnvironmentValues().hoverRevealMode, .onHover,
            "默认展开方式必须是 .onHover，否则主菜单的信息密度失控"
        )
    }

    /// 「注入点只有一处」这条约定本身**没有**被自动守住。
    ///
    /// 这条测试曾经只写了 `XCTAssertEqual(HoverRevealMode.onHover, EnvironmentValues().hoverRevealMode)`
    /// ——和上面 `testDefaultIsOnHoverSoTheMenuKeepsCollapsing` 是同一个表达式，
    /// 什么都没多证明：它从不碰 `MenuContentView`，把边缘窗整个删掉照样绿，
    /// 明天往主菜单里加一处 `.environment(\.hoverRevealMode, .alwaysVisible)` 也照样绿。
    /// 那正是它自称要守的东西。
    ///
    /// 真正能守住它的形式是**数注入点**（全仓 grep `.environment(\.hoverRevealMode`，
    /// 应当只有 `EdgeDockController.popoverContent` 一处）。本文件拿不到源码路径，
    /// 所以这里只把"默认值必须仍是 onHover"重复钉一次并说明差距，**不要**再把它
    /// 当成注入点的闸门。注入点那条留给 review / 静态检查。
    func testMenuPanelContentDoesNotForceAlwaysVisible() {
        // 覆盖范围仅限默认值本身，**不含**"主菜单没有注入 alwaysVisible"。
        XCTAssertEqual(HoverRevealMode.onHover, EnvironmentValues().hoverRevealMode)
    }

    func testEnvironmentOverrideIsReadable() {
        // 设置 → 读取这条链路本身要通，否则 popover 侧的常展开关会静默失效，
        // 表现是"浮层里那些折叠区怎么悬停都展不开"。
        var values = EnvironmentValues()
        XCTAssertEqual(values.hoverRevealMode, .onHover)
        values.hoverRevealMode = .alwaysVisible
        XCTAssertEqual(values.hoverRevealMode, .alwaysVisible)
    }

    // MARK: - 两套排版规则

    /// 卡片层**无条件**提供重置卡与高峰期倒计时，而它只在 `dockBody` 的非 `.ok`
    /// 回退路径上需要显式把它们交下去（`QuotaSummary` 自己不再画）。
    ///
    /// 这个测试盯的是那条"交接链有没有断"：`.failed` 分支曾经漏传
    /// `betweenBarAndColumns`，于是失败态的 provider 在 dock 浮层里既没有重置卡
    /// 也没有倒计时——恰恰是最该看"上次还剩多少、什么时候回补"的时候。
    ///
    /// 怎么钉：`resetCredits` 有值时卡片会多出一整行；两种状态只差这一个字段，
    /// 所以**高度差**就是那行在不在线的直接证据。不靠截图、不靠访问私有方法。
    @MainActor
    func testDockCardStillShowsResetCreditsWhenTheFetchFailed() {
        let withCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: true)
        let withoutCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: false)
        let tall = measuredHeight(mode: .alwaysVisible, status: withCredits)
        let short = measuredHeight(mode: .alwaysVisible, status: withoutCredits)
        XCTAssertGreaterThan(
            tall, short,
            "dock 浮层里 `.failed` 状态必须仍画出重置卡（应比没有重置数据时高出约一行）"
        )
    }

    /// `.ok` 状态下，额度窗口区块**必须真的画出来**。
    ///
    /// `QuotaWindowUsageTests.testBalanceOnlyProviderRendersNoBlockAtAll` 只钉了
    /// 反向的那一半："没有窗口时整块零高度"。反向断言有个盲区——如果卡片层
    /// 根本没把窗口数据传下去，那条测试照样绿（因为它量的正是"没画"），
    /// 而用户看到的是一张只剩百分比、连 5h / 周都分不清的卡。
    ///
    /// 怎么钉：同一个 provider、同一状态、同一个 reveal mode，两份数据只差
    /// "模型有没有额度窗口"这一个字段，高度差就是那两条窗口行在不在线的直接证据。
    @MainActor
    func testOkStateCardIsTallerWhenTheModelHasQuotaWindows() {
        let withWindows = Self.makeChatGPTStatus(state: .ok, resetCredits: false, withQuotaWindows: true)
        let withoutWindows = Self.makeChatGPTStatus(state: .ok, resetCredits: false, withQuotaWindows: false)
        let tall = measuredHeight(mode: .alwaysVisible, status: withWindows)
        let short = measuredHeight(mode: .alwaysVisible, status: withoutWindows)
        XCTAssertGreaterThan(
            tall, short,
            "`.ok` 卡片里有额度窗口的模型必须比没有窗口的更高（窗口区块必须真的渲染）"
        )
    }

    /// 菜单底部兜底行 hover 出来的那张卡，**必须**以 `.alwaysVisible` 渲染。
    ///
    /// 浮层 `ignoresMouseEvents = true`，收不到鼠标事件：不钉这个 mode，卡里那些
    /// 「悬停才展开」的部分永远展不开——`HoverInfoRow` 折叠起来的东西（四桶绝对值、
    /// 逐张重置卡清单、账号段）一份也看不到。
    ///
    /// ⚠️ 这里的"为什么"在 `ProviderCardLayout` 那轮收敛之后**变过一次**：额度行
    /// 内部那三条排版规则（消费方在 `QuotaViews` / `QuotaHoverViews`）已随判据删除
    /// 固定成 dock 形态，所以 `.onHover` 不再是"另一套简版排版"，它少掉的只是折叠
    /// 起来的那几段。原来那条"`onHover` 下没有重置卡"的等值断言因此失效——重置卡
    /// 摘要现在由卡片层无条件画，两个 mode 下都在场。
    ///
    /// 菜单形态那张完整卡（单卡 + 卡内标题 + 账号折叠区 + 自己画重置额度）曾经由
    /// `testMenuCardResetCreditsBehaviourIsUnchanged` 守着，它随 `menuBody` 一起
    /// 删除。生产路径上**没有任何宿主**再用 `.onHover` 渲染 provider 卡（dock 浮层与
    /// 菜单兜底行都固定 `.alwaysVisible`），于是这几条断言是一件事：兜底行用的就是
    /// 那个 mode，在它之下折叠段的内容在场、在默认 mode 之下不在场——把"为什么必须
    /// 钉死"写进测试，比只钉结果更耐改。
    @MainActor
    func testStripHoverCardMustUseTheAlwaysVisibleRevealMode() {
        XCTAssertEqual(
            ProviderStatusStripView.cardRevealMode, .alwaysVisible,
            "兜底行的 hover 卡必须钉死 .alwaysVisible（浮层不吃鼠标事件）"
        )
        XCTAssertEqual(
            ProviderStatusStripView.cardWidth,
            EdgeDockTheme.popoverWidth - EdgeDockTheme.popoverPadding * 2,
            "hover 卡必须与 dock 浮层那张卡同宽（7 天图表那 420pt 不能被压掉）"
        )

        let withCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: true)
        let withoutCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: false)
        XCTAssertGreaterThan(
            measuredHeight(mode: ProviderStatusStripView.cardRevealMode, status: withCredits),
            measuredHeight(mode: ProviderStatusStripView.cardRevealMode, status: withoutCredits),
            "兜底行的 hover 卡必须画出重置卡"
        )
        XCTAssertGreaterThan(
            measuredHeight(mode: ProviderStatusStripView.cardRevealMode, status: withCredits),
            measuredHeight(mode: .onHover, status: withCredits),
            "`.alwaysVisible` 下「额度窗口用量」浮层里那些折叠段（四桶 / 逐张重置卡 / 账号）"
                + "必须就地展开——浮层不吃鼠标事件，它们是唯一的呈现路径"
        )
    }

    // MARK: - 卡片 fixture（ChatGPT 卡，LayoutMetricsTests 也复用这一份）

    /// `.ok` / `.failed(带 lastSuccess)` 两种状态的选择器。
    enum CardState {
        case ok
        case failed

        func makeState(from info: QuotaInfo) -> ProviderStatus.State {
            switch self {
            case .ok:      return .ok(info)
            case .failed:  return .failed(message: "网络不可用", lastSuccess: info)
            }
        }
    }

    // MARK: - 排版测量 helpers

    /// dock 浮层里卡片内容区的宽度（`EdgeDockTheme.popoverWidth` 减去两侧背板内边距）。
    private var cardContentWidth: CGFloat {
        EdgeDockTheme.popoverWidth - EdgeDockTheme.popoverPadding * 2
    }

    /// 视图的自然宽度（不限宽、不受 frame 影响）。
    @MainActor
    private func naturalWidth<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

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

    @MainActor
    private func measuredHeight(mode: HoverRevealMode, status: ProviderStatus) -> CGFloat {
        let root = ProviderCardView(status: status)
            .environment(\.hoverRevealMode, mode)
            .frame(width: cardContentWidth)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: cardContentWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// ChatGPT 卡：双窗口 model + 本地用量明细（走 `ChatGPTPlanModelRow`，
    /// 也就是 dock 详情浮层里最"重"的一种形态）。
    static func makeChatGPTStatus() -> ProviderStatus {
        makeChatGPTStatus(state: CardState.ok, resetCredits: false)
    }

    /// 同上，但状态与「有没有重置额度数据」可切换。
    ///
    /// 这两个开关是配对用的：`.failed` + 有/无重置数据，四个组合里只有
    /// 「dock + 失败 + 有数据」这一格能区分"重置卡被画出来了"和"没画"——
    /// 其余三格要么本来就画（菜单由 `QuotaSummary` 自己画），要么本来就该没有。
    static func makeChatGPTStatus(
        state: CardState,
        resetCredits: Bool,
        recentSamples: [LocalTokenUsageSample] = [],
        withQuotaWindows: Bool = true
    ) -> ProviderStatus {
        let now = Date()
        let model = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 38,
            intervalRemainingPercent: 62,
            intervalStatus: withQuotaWindows ? .present : .absent,
            intervalResetsAt: withQuotaWindows ? now.addingTimeInterval(2 * 3600) : nil,
            intervalWindowSeconds: withQuotaWindows ? 5 * 3600 : nil,
            weeklyTotalCount: 100,
            weeklyUsageCount: 70,
            weeklyRemainingPercent: 30,
            weeklyStatus: withQuotaWindows ? .present : .absent,
            weeklyResetsAt: withQuotaWindows ? now.addingTimeInterval(3 * 24 * 3600) : nil,
            weeklyWindowSeconds: withQuotaWindows ? 7 * 24 * 3600 : nil
        )
        let usage = UsageMetricSummary(
            prompts: 42,
            rounds: 128,
            inputTokens: 1_240_000,
            cachedInputTokens: 860_000,
            outputTokens: 320_000,
            reasoningOutputTokens: 96_000
        )
        let credits: ResetCreditsInfo? = resetCredits
            ? ResetCreditsInfo(
                entries: [
                    ResetCreditEntry(
                        id: "credit-1",
                        status: "available",
                        expiresAt: now.addingTimeInterval(14 * 24 * 3600),
                        grantedAt: now,
                        resetType: "codex_rate_limits",
                        title: nil,
                        description: nil
                    )
                ],
                serverAvailableCount: 1,
                totalEarnedCount: 1,
                fetchedAt: now
            )
            : nil
        let info = QuotaInfo(
            models: [model],
            resetCredits: credits,
            planLabel: "Team",
            accountEmail: "someone@example.com",
            codexUsageDetails: CodexUsageDetails(
                primary: usage,
                secondary: usage,
                lastPrompt: LastPromptUsage(
                    completedAt: now.addingTimeInterval(-1800),
                    usage: usage
                ),
                dailyTokenUsage: makeSevenDays(now: now),
                recentSamples: recentSamples,
                scannedAt: now
            ),
            fetchedAt: now
        )
        return ProviderStatus(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: state.makeState(from: info)
        )
    }

    /// 含今天在内的七个自然日。ChatGPT 的页脚要**满 7 天**才进图表形态
    /// （不足时是一行"积累中"占位），少一天这条测试量的就不是最重的那个形态。
    static func makeSevenDays(now: Date) -> [DailyTokenUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { offset in
            let scale = 1 + offset
            return DailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                inputTokens: 120_000 * scale,
                cachedInputTokens: 240_000 * scale,
                outputTokens: 48_000 * scale,
                reasoningOutputTokens: 12_000 * scale,
                rounds: 30 * scale,
                turns: 90 * scale
            )
        }
    }
}
