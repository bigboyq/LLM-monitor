import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 独立宿主（`NSPanel` + `NSHostingView`）的展示时钟注入。
///
/// `ProviderCardView` 实际可见的宿主只有两个：菜单兜底行 hover 浮层
/// （`HoverPanelController`）与 dock 浮层（`EdgeDockController` 的 popover），
/// 都不在 `MenuContentView` 的环境里。没有宿主级注入时，卡内读
/// `\.displayDate` 的组件（GLM / DeepSeek 高峰倒计时、`ProviderStateLabel`
/// 新鲜度胶囊）会落到 `DisplayDateKey` 的 `static let` 兜底值——进程内只
/// 求值一次，永远冻结（用户实测 DeepSeek 卡一直显示「距高峰 1分」）。
///
/// 这组测试钉住两件事：`DisplayClockScope` 确实把**活动**时钟送进环境且
/// 随 tick 推进；两个宿主的时钟默认停表、隐藏即停。
@MainActor
final class DisplayClockScopeTests: XCTestCase {

    // MARK: - 机制：活动时钟随 tick 推进（关键回归门禁）

    /// scope 必须把**每 tick 新取的 `Date()`**送进环境，而不是
    /// `DisplayDateKey.defaultValue` 那个冻结值。
    ///
    /// 探针视图在 body 里记录每次读到的环境值；时钟以 1ms tick 泵动后，
    /// 记录序列必须攒出 ≥3 个值且末值 > 首值——冻结值做不到这一点。
    /// 等待有 2s 上限：超时即失败并说明原因，不允许无上限 sleep 或依赖
    /// 墙钟巧合，保证 CI / 本机稳定。
    func testScopeInjectsAdvancingClockDatesIntoTheEnvironment() async {
        let recorder = DateRecorder()
        let clock = DisplayClock(tickIntervalNanoseconds: 1_000_000)
        // 强引用 hosting：视图树必须在断言期间持续活着并接收更新。
        let hosting = NSHostingView(
            rootView: DisplayClockScope(clock: clock) {
                DisplayDateProbeView(recorder: recorder)
            }
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        hosting.layoutSubtreeIfNeeded()

        clock.start()
        defer { clock.stop() }

        // 有上限地泵 runloop：SwiftUI 的环境值传播随主 runloop 上的渲染事务
        // 提交，这里让出主 actor（给 1ms 的 tick task）再泵一小段 runloop，
        // 直到探针攒够 3 个值。
        let deadline = Date().addingTimeInterval(2)
        while recorder.dates.count < 3 && Date() < deadline {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertGreaterThanOrEqual(
            recorder.dates.count, 3,
            "2s 内探针只记录到 \(recorder.dates.count) 个环境值：时钟没 tick，"
                + "或环境值没有随 tick 传播到读 `\\.displayDate` 的视图"
        )
        XCTAssertGreaterThan(
            recorder.dates.last!, recorder.dates.first!,
            "环境里的展示日期必须随 tick 推进；首尾相同说明注入的是冻结值"
                + "（DisplayDateKey.defaultValue 的老毛病）"
        )
    }

    // MARK: - 机制：卡内重置倒计时取注入的展示时钟，不是渲染时墙钟

    /// 「额度窗口」区块的重置日期格 `MM-dd HH:mm (倒计时)` 必须由**注入的**
    /// `\.displayDate` 决定（`QuotaWindowUsageSection.resetDateCell` 读环境值），
    /// 而不是渲染时现取的墙钟——否则卡片浮层只要一直开着，倒计时就冻结在
    /// 打开那一刻（与 `DisplayDateKey.defaultValue` 冻结是同一类毛病）。
    ///
    /// 怎么钉：同一份快照（`resetsAt` 固定），两次 `NSHostingView` 渲染只差注入的
    /// 展示时刻——`resetsAt − 1h` 出剩余时间后缀，`resetsAt + 1h` 必须出「已过期」，
    /// 两次渲染位图必须不同。同一次注入渲染两遍必须逐位一致，是位图法的
    /// 确定性对照：连它都不等说明位图路径不可靠，先红在这里。
    @MainActor
    func testCardResetCountdownFollowsTheInjectedDisplayDateNotTheWallClock() throws {
        let resetsAt = Date(timeIntervalSince1970: 1_790_000_000)
        // 前提：两个注入时刻落在纯函数阶梯的两端（剩余 vs 已过期）。
        XCTAssertEqual(
            Formatters.formatResetSuffix(from: resetsAt, now: resetsAt.addingTimeInterval(-3600)),
            "1h00m"
        )
        XCTAssertEqual(
            Formatters.formatResetSuffix(from: resetsAt, now: resetsAt.addingTimeInterval(3600)),
            "已过期"
        )

        let snapshot = QuotaWindowUsageSnapshot(
            interval: .init(
                label: "5h",
                usage: UsageMetricSummary(
                    prompts: 1, rounds: 1,
                    inputTokens: 1_000, cachedInputTokens: 0,
                    outputTokens: 1_000, reasoningOutputTokens: 0
                ),
                resetsAt: resetsAt,
                cost: nil
            ),
            weekly: nil,
            poolCount: 1
        )
        // 卡内容宽（两个浮层宿主一致），区块必须真的排得出来。
        let width = EdgeDockTheme.popoverWidth
            - EdgeDockTheme.popoverPadding * 2
            - LayoutMetrics.cardContentPadding * 2

        func section(displayDate: Date) -> some View {
            QuotaWindowUsageSection(snapshot: snapshot, segmentOverride: .analysis)
                .environment(\.displayDate, displayDate)
                .frame(width: width)
        }

        func renderedData(displayDate: Date) -> Data? {
            let hosting = NSHostingView(rootView: AnyView(section(displayDate: displayDate)))
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10_000)
            hosting.layoutSubtreeIfNeeded()
            let height = max(1, hosting.fittingSize.height.rounded(.up))
            guard height > 1 else { return nil }
            let sized = NSHostingView(rootView: AnyView(section(displayDate: displayDate)))
            sized.frame = CGRect(x: 0, y: 0, width: width, height: height)
            sized.layoutSubtreeIfNeeded()
            guard let rep = sized.bitmapImageRepForCachingDisplay(in: sized.bounds) else { return nil }
            sized.cacheDisplay(in: sized.bounds, to: rep)
            // 比像素字节而不是 tiffRepresentation：后者带 TIFF 元数据，
            // 与"内容是否相同"不是一回事；像素缓冲是内容的直接证据。
            guard let pixels = rep.bitmapData else { return nil }
            return Data(bytes: pixels, count: rep.bytesPerRow * rep.pixelsHigh)
        }

        let fresh = try XCTUnwrap(
            renderedData(displayDate: resetsAt.addingTimeInterval(-3600)),
            "resetsAt − 1h 的渲染必须产出位图"
        )
        let expired = try XCTUnwrap(
            renderedData(displayDate: resetsAt.addingTimeInterval(3600)),
            "resetsAt + 1h 的渲染必须产出位图"
        )
        let freshAgain = try XCTUnwrap(
            renderedData(displayDate: resetsAt.addingTimeInterval(-3600)),
            "确定性对照渲染必须产出位图"
        )

        XCTAssertEqual(
            fresh, freshAgain,
            "同一次注入渲染两遍必须逐位一致；不等说明位图路径有抖动，下面的不等判定不可信"
        )
        XCTAssertNotEqual(
            fresh, expired,
            "只差注入的展示时刻（剩余 vs 已过期），位图必须不同——相同说明重置倒计时"
                + "没有读注入的 \\(\\.displayDate)，而是在渲染时现取了墙钟"
        )
    }

    // MARK: - 宿主缝：默认停表、隐藏即停

    /// hover 浮层宿主：隐藏后不得让时钟空转。
    ///
    /// `HoverPanelController` 是 `private init` 单例，用 `.shared`；`hide()` 在
    /// 无面板时是安全 no-op（`panel?.orderOut`），这条测试不构造任何 `NSPanel`。
    /// 不在这里测 `present` 的 start 路径——那需要真实面板与完整卡片。
    func testHoverPanelClockIsStoppedAfterHide() {
        HoverPanelController.shared.hide()
        XCTAssertFalse(
            HoverPanelController.shared.displayClock.isRunning,
            "hover 浮层隐藏后展示时钟必须停表；空转的时钟是每秒一次的无谓唤醒"
        )
    }

    /// dock 浮层宿主：同上。
    ///
    /// `EdgeDockController.init()` 是空实现，`.shared` 构造代价可忽略。刻意不用
    /// `updatePopover()` 测 start 路径——那需要真实面板与 AppState，重。
    func testEdgeDockPopoverClockIsStoppedAfterHidePopover() {
        EdgeDockController.shared.hidePopover()
        XCTAssertFalse(
            EdgeDockController.shared.popoverDisplayClock.isRunning,
            "dock 浮层隐藏后展示时钟必须停表"
        )
    }

    /// `updatePopover()` 的 guard 早退路径（`.shared` 未接线时 `panel` 为 nil，
    /// 第一个 guard 就触发）必须同样走 `hidePopover()` —— 时钟保持停表。
    /// 这条钉的是"早退路径不重复开表"的那道缝。
    func testUpdatePopoverEarlyExitKeepsTheClockStopped() {
        EdgeDockController.shared.updatePopover()
        XCTAssertFalse(
            EdgeDockController.shared.popoverDisplayClock.isRunning,
            "updatePopover 早退路径必须收敛到 hidePopover()，时钟不得残留运行态"
        )
    }
}

/// 探针每次 body 重 eval 记录一次读到的环境值。只在主线程存活（测试类与
/// SwiftUI body 都在主线程），不需要同步。
private final class DateRecorder {
    private(set) var dates: [Date] = []

    func record(_ date: Date) {
        dates.append(date)
    }
}

/// 读 `\.displayDate` 的最小探针：环境值变化会触发 body 重 eval，
/// `let _ =` 在 ViewBuilder 里是合法语句，每次重 eval 都记录一次。
private struct DisplayDateProbeView: View {
    @Environment(\.displayDate) private var date
    let recorder: DateRecorder

    var body: some View {
        let _ = recorder.record(date)
        Color.clear
    }
}
