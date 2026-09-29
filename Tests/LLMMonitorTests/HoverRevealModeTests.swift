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

    func testMenuPanelContentDoesNotForceAlwaysVisible() {
        // 主菜单不该注入 alwaysVisible：边缘窗的策略不能漏回主菜单。
        // 这里只固定"注入点只有 popoverContent 一处"这个约定。
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

    /// 菜单侧六条规则**全部**关闭。任一条被顺手改成 true，主菜单卡片就会变形
    /// （条跑到头部、5h/周并排、账号就地展开、倒计时跳到头部、input 里的
    /// cached 被拆出来、prompts 里的 rounds 被拆出来）——而菜单是默认宿主，
    /// 这条断言就是"改默认形态前先看这里"的闸门。
    func testMenuLayoutStaysUnchanged() {
        for rule in [
            ProviderCardLayout.liftsProgressBar,
            ProviderCardLayout.laysWindowDetailsSideBySide,
            ProviderCardLayout.expandsAccountSection,
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
    ///
    /// 第三轮涨 37pt 是**故意的**：拆行换来每个数字都有完整一行。第四轮把
    /// 头部那张"条 + 名称 label"总表撤回、条各归各的分块，顺带省掉模型名那一行，
    /// 又落回 628pt。第五轮加两个 section 标题后回到 650pt——那 22pt 是**故意**
    /// 花的：额度和本地用量是两套独立数据源（provider 接口 vs 本机会话扫描），
    /// 混在一列里读者分不清归属，本地用量为空时"扫描尚未完成"尤其会被当成
    /// 额度的脚注。第七轮把两组做成两张有边界的卡、标题提到卡外，反而又降了
    /// 18pt：多出来的卡间距与标题行，少于撤掉的图表标题行 + 分隔线 + 内层标题。
    /// 第八轮把 8/9pt 的字号统一到 10pt，图表与用量表跟着变高——那是拿高度换
    /// 可读性，不是排版失控。
    ///
    /// **不要改成"和菜单形态比"**：菜单那张卡片是**折叠**的（同一张卡只有
    /// 120pt），拿它当基准会把"折叠区就地展开"这件事本身判成回归——而就地
    /// 展开正是 dock 侧必须的行为（浮层不接受鼠标事件，折叠区展不开）。
    ///
    /// 上限取 720pt：给字体度量随 macOS 版本漂移留出余量，又足够紧——任何
    /// "再加回一个常展区块"（那至少是 30pt）都会顶破它。改动这套排版时要重新量。
    ///
    /// 注意这个上限和 popover 的高度上限（`popoverHeightFraction`）是两回事：
    /// 那条管的是"面板不许高过屏幕"，超了套 ScrollView；这条管的是"排版别再变高"，
    /// 顶破了说明有人加回了常展区块。两个数字不要互相抄。
    @MainActor
    func testDockDetailStaysUnderTheRearrangedCeiling() {
        let height = measuredHeight(mode: .alwaysVisible, status: Self.makeChatGPTStatus())
        XCTAssertGreaterThan(height, 0, "必须能布局出高度，否则这条断言没有意义")
        XCTAssertLessThan(
            height, 720,
            "dock 详情浮层比重排前更高了（现在 \(height)pt，全展开时是 1188pt）"
        )
    }

    // MARK: - helpers

    /// dock 浮层里卡片内容区的宽度（`EdgeDockTheme.popoverWidth` 减去两侧背板内边距）。
    private var cardContentWidth: CGFloat {
        EdgeDockTheme.popoverWidth - EdgeDockTheme.popoverPadding * 2
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
        let info = QuotaInfo(
            models: [model],
            resetCredits: nil,
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
            state: .ok(info)
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
