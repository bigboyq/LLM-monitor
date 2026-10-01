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

    /// dock 形态下，**重置卡与高峰期倒计时由卡片层提供**，而卡片层只在
    /// `dockBody` 的非 `.ok` 回退路径上需要显式把它们交下去（`QuotaSummary` 自己
    /// 因为 `hoistsResetCredits` 为 true 不再画）。
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

    /// 菜单侧不受上面那条影响：重置卡一直由 `QuotaSummary` 自己画，高度差应当**同样**
    /// 存在。这里确认交接链的改动没有顺手把菜单也改了。
    @MainActor
    func testMenuCardResetCreditsBehaviourIsUnchanged() {
        let withCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: true)
        let withoutCredits = Self.makeChatGPTStatus(state: .failed, resetCredits: false)
        let tall = measuredHeight(mode: .onHover, status: withCredits)
        let short = measuredHeight(mode: .onHover, status: withoutCredits)
        XCTAssertGreaterThan(tall, short, "菜单侧重置卡一直是自己画的，不该被这次改动影响")
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
    func testQuotaWindowsHoverLaysTwoColumnsSideBySide() {
        let now = Date()
        let primaryResets = now.addingTimeInterval(3600)
        let weeklyResets = now.addingTimeInterval(7 * 24 * 3600)

        let viewWidth = naturalWidth(of: QuotaWindowsHoverView(
            title: "chatgpt_plan",
            weeklyEquivalentMultiplier: 6,
            primaryLabel: "5h",
            primaryPercent: 62,
            primaryResetsAt: primaryResets,
            weeklyPercent: 80,
            weeklyResetsAt: weeklyResets,
            secondaryLabel: "周"
        ))
        let oneColumnWidth = naturalWidth(of: HoverMetricLine(
            label: "5h", percent: 62, resetsAt: primaryResets
        ))
        let twoColumnWidth = naturalWidth(of: HStack(alignment: .top, spacing: 16) {
            HoverMetricLine(label: "5h", percent: 62, resetsAt: primaryResets)
            HoverMetricLine(label: "周", percent: 80, resetsAt: weeklyResets)
        })

        // 前提：参照物本身是"两列宽"，否则下面的比较毫无意义。
        XCTAssertGreaterThan(
            twoColumnWidth, oneColumnWidth * 1.9,
            "前提不成立：两列 HStack 应当约为单列的两倍（实际 \(twoColumnWidth) vs \(oneColumnWidth)）"
        )
        XCTAssertGreaterThanOrEqual(
            viewWidth, twoColumnWidth,
            "两个窗口的明细必须并排：视图自然宽 \(viewWidth) 达不到两列的 \(twoColumnWidth)，说明它们被堆叠了"
        )
    }

    /// 菜单侧七条规则**全部**关闭。任一条被顺手改成 true，主菜单卡片就会变形
    /// （条跑到头部、5h/周并排、账号就地展开、倒计时跳到头部、input 里的
    /// cached 被拆出来、prompts 里的 rounds 被拆出来）——而菜单是默认宿主，
    /// 这条断言就是"改默认形态前先看这里"的闸门。
    /// 刻意**不含**并排那条：它曾经以 `laysWindowDetailsSideBySide(mode:)` 的形式
    /// 出现在这里，但它没有可达的消费方（唯一的读者在 `QuotaHoverViews` 的两个
    /// hover 视图里，而那两个视图只从 model 行的 `menuLayout` 构造），断言它对
    /// `.alwaysVisible` 返回 true 只是在给"规则已实现"制造错觉。现在那个谓词连同
    /// 堆叠分支一起删了，改为无条件并排，由
    /// `testQuotaWindowsHoverLaysTwoColumnsSideBySide` 单独盯着。
    func testMenuLayoutStaysUnchanged() {
        for rule in [
            ProviderCardLayout.liftsProgressBar,
            ProviderCardLayout.hoistsResetCredits,
            ProviderCardLayout.hoistsPeakIndicator,
            ProviderCardLayout.hidesHeaderStatusDot,
            ProviderCardLayout.splitsCachedInputRow,
            ProviderCardLayout.splitsRoundsRow,
            ProviderCardLayout.splitsIntoTwoCards,
        ] {
            XCTAssertFalse(rule(.onHover), "主菜单不该套用 dock 的重排规则")
            XCTAssertTrue(rule(.alwaysVisible), "dock 详情浮层才套用重排规则")
        }
    }

    // MARK: - 真的量一次高度

    /// 钉住"重排后不能再长回去"。
    ///
    /// 量的是 dock 详情浮层**自己**的高度（`.alwaysVisible`），把同一张卡片
    /// 真正布局一遍取 `fittingSize`。2026-09-29 实测（ChatGPT 双窗口 +
    /// 满 7 天本地用量，444pt 内容宽）**1188pt**（全展开的原始形态）→
    /// **915pt**（第一轮重排）→ **611pt**（第二轮：元信息行去重 + 三列布局）
    /// → **648pt**（第三轮：重置卡提到头部 + input/cached、prompts/rounds 拆行）
    /// → **628pt**（第四轮：去掉进度条前导 label 和模型名那一行）
    /// → **650pt**（第五轮：拆「额度 / 最近7天token用量」两个 section，各加一个标题行）
    /// → **635pt**（第六轮：去掉两组之间的横线，并让第二组不再画自己那行
    ///   12pt「最近 7 天 Token 用量」）。
    /// → **617pt**（第七轮：改成一屏**两张卡片**，标题提到卡外——头部那行当第一张
    ///   卡的标题、新增「最近7天token用量」当第二张的标题，图表自己那行标题连同
    ///   分隔线一起撤掉）。
    /// → **679pt**（第八轮：两行标题统一成 13pt、卡片内字号收到 10/11、
    ///   描述行移到进度条上方并给条留出上下间距、重置/高峰期移到条与统计表之间
    ///   并补一条分隔线。这一轮是**涨**的，涨在字号与呼吸感上）。
    /// → **505pt**（第九轮：撤掉三列明细 **Last Prompt | 5h | 周**。它们讲的是
    ///   本地扫描的 token 用量，和下一张卡「最近7天token用量」是同一件事，
    ///   一屏摆两份既重复又把"还剩多少"这条主线压住。条与元信息行之间的分隔线
    ///   留着，现在分隔的是"额度"与"用量"）。
    ///
    /// 第三轮涨 37pt 是**故意的**：拆行换来每个数字都有完整一行。第四轮把
    /// 头部那张"条 + 名称 label"总表撤回、条各归各的分块，顺带省掉模型名那一行，
    /// 又落回 628pt。第五轮加两个 section 标题后回到 650pt——那 22pt 是**故意**
    /// 花的：额度和本地用量是两套独立数据源（provider 接口 vs 本机会话扫描），
    /// 混在一列里读者分不清归属，本地用量为空时"扫描尚未完成"尤其会被当成
    /// 额度的脚注。第七轮把两组做成两张有边界的卡、标题提到卡外，反而又降了
    /// 18pt：多出来的卡间距与标题行，少于撤掉的图表标题行 + 分隔线 + 内层标题。
    /// 第八轮把 8/9pt 的字号统一到 10pt，图表与用量表跟着变高——那是拿高度换
    /// 可读性，不是排版失控。第九轮一次性降 174pt：三列明细整块撤掉，用量明细
    /// 只留在「最近7天token用量」那张卡里，浮层不必再滚动。
    ///
    /// **不要改成"和菜单形态比"**：菜单那张卡片是**折叠**的（同一张卡只有
    /// 120pt），拿它当基准会把"折叠区就地展开"这件事本身判成回归——而就地
    /// 展开正是 dock 侧必须的行为（浮层不接受鼠标事件，折叠区展不开）。
    ///
    /// 上限取 550pt：给字体度量随 macOS 版本漂移留出余量，又足够紧——任何
    /// "再加回一个常展区块"都会顶破它（上一轮的三列明细就有 174pt）。
    /// 改动这套排版时要重新量。
    ///
    /// 注意这个上限和 popover 的高度上限（`popoverHeightFraction`）是两回事：
    /// 那条管的是"面板不许高过屏幕"，超了套 ScrollView；这条管的是"排版别再变高"，
    /// 顶破了说明有人加回了常展区块。两个数字不要互相抄。
    @MainActor
    func testDockDetailStaysUnderTheRearrangedCeiling() {
        let height = measuredHeight(mode: .alwaysVisible, status: Self.makeChatGPTStatus())
        XCTAssertGreaterThan(height, 0, "必须能布局出高度，否则这条断言没有意义")
        XCTAssertLessThan(
            height, 550,
            "dock 详情浮层比重排前更高了（现在 \(height)pt，全展开时是 1188pt）"
        )
    }



    /// `.ok` / `.failed(带 lastSuccess)` 两种状态的选择器。
    fileprivate enum CardState {
        case ok
        case failed

        func makeState(from info: QuotaInfo) -> ProviderStatus.State {
            switch self {
            case .ok:      return .ok(info)
            case .failed:  return .failed(message: "网络不可用", lastSuccess: info)
            }
        }
    }

    // MARK: - helpers

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
    fileprivate static func makeChatGPTStatus() -> ProviderStatus {
        makeChatGPTStatus(state: CardState.ok, resetCredits: false)
    }

    /// 同上，但状态与「有没有重置额度数据」可切换。
    ///
    /// 这两个开关是配对用的：`.failed` + 有/无重置数据，四个组合里只有
    /// 「dock + 失败 + 有数据」这一格能区分"重置卡被画出来了"和"没画"——
    /// 其余三格要么本来就画（菜单由 `QuotaSummary` 自己画），要么本来就该没有。
    fileprivate static func makeChatGPTStatus(
        state: CardState,
        resetCredits: Bool
    ) -> ProviderStatus {
        let now = Date()
        let model = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 38,
            intervalRemainingPercent: 62,
            intervalStatus: .present,
            intervalResetsAt: now.addingTimeInterval(2 * 3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: 70,
            weeklyRemainingPercent: 30,
            weeklyStatus: .present,
            weeklyResetsAt: now.addingTimeInterval(3 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
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
                recentSamples: [],
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
    fileprivate static func makeSevenDays(now: Date) -> [DailyTokenUsage] {
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
