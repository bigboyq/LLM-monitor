import XCTest
import AppKit
@testable import LLM_monitor

/// F4：MenuInactivityTimer 计时状态机的 start/reset/cancel 自动化测试。
/// 真实的 30 秒关闭、持续滚动不关闭、失焦立即关闭需在 Release app 上手工 QA。
@MainActor
final class MenuAutoCloseTests: XCTestCase {

    /// 记录式 fake 调度器：捕获安排的延时闭包，测试可手动触发或取消。
    private final class FakeScheduler: InactivityScheduler {
        private(set) var scheduledDelays: [TimeInterval] = []
        private(set) var handles: [FakeHandle] = []

        func schedule(
            after delay: TimeInterval,
            _ block: @escaping @MainActor @Sendable () -> Void
        ) -> any InactivityHandle {
            let handle = FakeHandle(block: block)
            scheduledDelays.append(delay)
            handles.append(handle)
            return handle
        }
    }

    private final class FakeHandle: InactivityHandle {
        let block: @MainActor @Sendable () -> Void
        private(set) var isCancelled = false

        init(block: @escaping @MainActor @Sendable () -> Void) {
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }

        @MainActor
        func fire() {
            block()
        }
    }

    func testInactivityTimerFiresAfterInterval() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()

        XCTAssertEqual(scheduler.scheduledDelays, [30], "startOrReset 应安排一次 interval 后触发")
        XCTAssertEqual(scheduler.handles.count, 1)

        // 触发安排的闭包 → close 被调用一次
        scheduler.handles[0].fire()
        XCTAssertEqual(timer.fireCount, 1)
        XCTAssertEqual(closeCallCount, 1)
    }

    func testInactivityTimerResetCancelsOldFire() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()
        // 交互事件触发 reset：旧 handle 被取消并替换为新 handle
        timer.startOrReset()

        XCTAssertEqual(scheduler.handles.count, 2)
        XCTAssertTrue(scheduler.handles[0].isCancelled, "reset 应取消旧 handle")

        // 旧的 handle 即使 fire 也不应触发 close（token 已失效）
        scheduler.handles[0].fire()
        XCTAssertEqual(closeCallCount, 0, "被 reset 替换的旧计时不应触发 close")
        XCTAssertEqual(timer.fireCount, 0)

        // 最新的 handle fire 才触发
        scheduler.handles[1].fire()
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(timer.fireCount, 1)
    }

    func testInactivityTimerCancelPreventsFire() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()
        timer.cancel()

        XCTAssertTrue(scheduler.handles[0].isCancelled, "cancel 应取消当前 handle")
        // cancel 后即便 fire 也不触发 close（token 已轮换）
        scheduler.handles[0].fire()
        XCTAssertEqual(closeCallCount, 0)
        XCTAssertEqual(timer.fireCount, 0)
    }

    func testInactivityTimerStartOrResetReplacesPrevious() {
        let scheduler = FakeScheduler()
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: {}
        )
        timer.startOrReset()
        timer.startOrReset()
        timer.startOrReset()
        // 三次 startOrReset 安排三次，前两次被取消
        XCTAssertEqual(scheduler.handles.count, 3)
        XCTAssertTrue(scheduler.handles[0].isCancelled)
        XCTAssertTrue(scheduler.handles[1].isCancelled)
        XCTAssertFalse(scheduler.handles[2].isCancelled, "最新 handle 不应被取消")
    }

    // MARK: - 关闭回调（onPanelClose）

    /// 菜单关掉时视图**不销毁**（只是 `orderOut`），所以展示时钟的停表不能挂在
    /// `onDisappear` 上，必须挂在关闭路径上。本条钉住 30s 无交互关闭会发
    /// `onPanelClose`（`displayClock.stop()` 的唯一来源）。
    func testPanelCloseCallbackFiresOnInactivityClose() {
        let fakeScheduler = FakeScheduler()
        var closeCallCount = 0
        let coordinator = MenuWindowAutoCloseBridge.Coordinator(
            inactivityInterval: 30,
            scheduler: fakeScheduler
        )
        coordinator.onPanelClose = { closeCallCount += 1 }
        coordinator.attach(window: Self.makeMenuWindow())
        XCTAssertEqual(fakeScheduler.scheduledDelays, [30], "attach 应启动 30s 无交互计时")

        fakeScheduler.handles[0].fire()
        XCTAssertEqual(closeCallCount, 1, "30s 无交互关闭必须发出 onPanelClose（停表靠它）")
    }

    /// 失焦关闭（`didResignKey`）是生产里最常见的关闭路径，走的是同一个
    /// `closeMenu` 出口，因此必须同样发出 `onPanelClose`。
    func testPanelCloseCallbackFiresOnWindowResignKey() async {
        let window = Self.makeMenuWindow()
        var closeCallCount = 0
        var openCallCount = 0
        let coordinator = MenuWindowAutoCloseBridge.Coordinator(
            inactivityInterval: 30,
            scheduler: FakeScheduler()
        )
        coordinator.onPanelOpen = { openCallCount += 1 }
        coordinator.onPanelClose = { closeCallCount += 1 }
        coordinator.attach(window: window)

        // 对称性：become key → onPanelOpen；resign key → onPanelClose。
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(openCallCount, 1, "become key 必须发出 onPanelOpen")
        XCTAssertEqual(closeCallCount, 1, "失焦关闭必须发出 onPanelClose")
    }

    /// `onPanelOpen` / `onPanelClose` 必须成对转发到 Coordinator：bridge 的闭包
    /// 存在 `TrackingNSView` 上，`updateNSView` 每次刷新都要透传，否则 SwiftUI
    /// 重算后闭包会丢。
    func testTrackingViewForwardsBothCallbacksToCoordinator() {
        let coordinator = MenuWindowAutoCloseBridge.Coordinator(scheduler: FakeScheduler())
        let view = MenuWindowAutoCloseBridge.TrackingNSView()
        view.coordinator = coordinator

        var openCallCount = 0
        var closeCallCount = 0
        view.onPanelOpen = { openCallCount += 1 }
        view.onPanelClose = { closeCallCount += 1 }

        coordinator.onPanelOpen?()
        coordinator.onPanelClose?()
        XCTAssertEqual(openCallCount, 1)
        XCTAssertEqual(closeCallCount, 1)
    }

    /// 一个从未显示过的 borderless 窗口：bridge 只用它的对象身份投递通知，
    /// 不需要 window-server 真的把它显示出来。
    private static func makeMenuWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }
}
