import SwiftUI

/// 跨宿主共享的展示时钟（`DisplayClock` + `DisplayClockScope` + `\.displayDate`
/// 环境键）。卡内的倒计时 / 新鲜度等"现在"取值必须随宿主显隐起停，而不是渲染
/// 时现取墙钟。菜单内容（`MenuContentView`）、菜单兜底行 hover 浮层
/// （`HoverPanelController`）与 dock 浮层（`EdgeDockController`）各自持有一个
/// `DisplayClock` 实例、随宿主显隐 start/stop，并在自己的根视图上注入环境——
/// 不是菜单专属。

private struct DisplayDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    /// A value environment (rather than an EnvironmentObject) keeps small
    /// display components safe when rendered in isolation, such as previews
    /// and focused tests. Each host supplies the live shared value.
    var displayDate: Date {
        get { self[DisplayDateKey.self] }
        set { self[DisplayDateKey.self] = newValue }
    }
}

/// 展示时钟：只让实际需要倒计时/新鲜度的消费者订阅，避免每张卡片各自创建
/// TimelineView。
@MainActor
final class DisplayClock: ObservableObject {
    @Published private(set) var date = Date()
    private var task: Task<Void, Never>?
    private let tickIntervalNanoseconds: UInt64
    private(set) var startCount = 0
    private(set) var tickCount = 0

    init(tickIntervalNanoseconds: UInt64 = 1_000_000_000) {
        self.tickIntervalNanoseconds = tickIntervalNanoseconds
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        startCount += 1
        date = Date()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.tickIntervalNanoseconds ?? 1_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.tickCount += 1
                self.date = Date()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// 把展示时钟铺进独立宿主（`NSPanel` + `NSHostingView`）的根视图。
///
/// 浮层宿主不在菜单内容的环境里，卡片读 `\.displayDate` 会落到
/// `DisplayDateKey` 的静态兜底值——`static let` 进程内只求值一次，
/// 于是高峰倒计时 / 新鲜度胶囊会永远冻结在第一次渲染的时刻。时钟由宿主
/// 持有并随面板显隐 start/stop（`HoverPanelController` / `EdgeDockController`
/// 的浮层各持一个），这里只负责订阅 tick 并把新值注入环境。
struct DisplayClockScope<Content: View>: View {
    @ObservedObject var clock: DisplayClock
    private let content: Content

    init(clock: DisplayClock, @ViewBuilder content: () -> Content) {
        self.clock = clock
        self.content = content()
    }

    var body: some View {
        content.environment(\.displayDate, clock.date)
    }
}
