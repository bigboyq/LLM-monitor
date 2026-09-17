import SwiftUI

private struct MenuDisplayDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    /// A value environment (rather than an EnvironmentObject) keeps small
    /// display components safe when rendered in isolation, such as previews
    /// and focused tests. MenuContentView supplies the live shared value.
    var menuDisplayDate: Date {
        get { self[MenuDisplayDateKey.self] }
        set { self[MenuDisplayDateKey.self] = newValue }
    }
}

/// 菜单打开期间的单一展示时钟。只让实际需要倒计时/新鲜度的消费者订阅，
/// 避免每张卡片各自创建 TimelineView。
@MainActor
final class MenuDisplayClock: ObservableObject {
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

/// MenuBarExtra 点开后看到的主面板 — **纯展示**，无 sheet 无交互弹窗
struct MenuContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var loginItemService: LoginItemService
    @Environment(\.openSettings) private var openSettings
    @StateObject private var displayClock = MenuDisplayClock()
    /// 强制本地 UI 重渲染计数（用于同步响应 sleepHealth 状态变更）
    @State private var energyUpdateTick = 0
    /// 动态测量卡片列表的自然排版高度
    @State private var measuredCardsHeight: CGFloat = 0
    /// 菜单所在屏幕的可用高度（从顶部菜单栏到屏幕底部的实际空间）
    @State private var screenAvailableHeight: CGFloat = 0
    /// 菜单所在屏幕的可见高度（扣除 Dock 等后的可见区域，用于 70% 封顶）
    @State private var screenVisibleHeight: CGFloat = 0

    /// “如果屏幕能展示就展示，不能展示按屏幕大小 70% 做”
    private var maxScrollViewHeight: CGFloat? {
        guard screenAvailableHeight > 0, measuredCardsHeight > 0 else { return nil }
        let totalNaturalHeight = measuredCardsHeight + MenuPanelHeightBridge.chromeHeight
        if totalNaturalHeight <= screenAvailableHeight {
            return nil // 能展示就展示：无高度上限，全部自然展开
        }
        // 不能展示，按屏幕大小 70% 做：
        let budget = MenuPanelHeightBridge.cappedHeight(screenVisibleHeight) - MenuPanelHeightBridge.chromeHeight
        return max(budget, 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
            footerBar
        }
        .frame(width: MenuPanelHeightBridge.width)
        .background {
            MenuPanelSurface()
        }
        .background(MenuWindowAutoCloseBridge())
        // F4: 窗口高度与位置由 MenuWindowAlignment 基于卡片真实内容高度与
        // 屏幕可用高度及 70% 封顶动态驱动：能展示就自然展开，超标则封顶 70% 并在内部滚动。
        .background(MenuPanelHeightBridge(measuredCardsHeight: measuredCardsHeight) { availH, visH in
            if abs(screenAvailableHeight - availH) > 0.5 || abs(screenVisibleHeight - visH) > 0.5 {
                DispatchQueue.main.async {
                    screenAvailableHeight = availH
                    screenVisibleHeight = visH
                }
            }
        })
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(CardsContentHeightKey.self) { h in
            if h > 0 && abs(measuredCardsHeight - h) > 0.5 {
                measuredCardsHeight = h
            }
        }
        .environmentObject(displayClock)
        .environment(\.menuDisplayDate, displayClock.date)
        .onAppear {
            displayClock.start()
            let needsFetch = state.statuses.contains { s in
                if case .ready = s.state { return true }
                return false
            }
            if needsFetch {
                Task { await state.refreshAll() }
            }
            loginItemService.refreshStatus()
        }
        .onDisappear { displayClock.stop() }
        // 显式 .onReceive 强制 SwiftUI 订阅 publisher，绕开 MenuBarExtra 的 view 缓存
        // （@ObservedObject 在 MenuBarExtra 上有时不触发 body 重 eval）。
        // AppState 的所有 status 变更入口（mutateStatus / rebuildStatuses / setScanningState /
        // apply*LocalUsage）都 fire `statusDidChange`，view 端挂这一个就够了。
        .onReceive(state.statusDidChange) { _ in }
        // 「节能」健康灯的数据在 SleepHealthService（AppState 之外的嵌套
        // ObservableObject）上；通过改变 @State 强制触发 body 重 eval，
        // 保证圆点颜色即时更新。
        .onReceive(state.sleepHealth.objectWillChange) { _ in
            energyUpdateTick &+= 1
        }
    }

    // MARK: - header（紧凑 padding）

    private var headerBar: some View {
        HStack(spacing: 4) {
            // 主面板左上角使用 App 图标设计稿；加载失败兜底回原系统符号。
            if let appIcon = MenuBarLabel.appIconDesignImage {
                Image(nsImage: appIcon)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(MenuTypography.headerTitle)
                    .foregroundStyle(.secondary)
            }
            Text("LLM Monitor")
                .font(MenuTypography.headerTitle)
                .foregroundStyle(Color.primaryLabel)
            if let report = state.sleepHealth.report, !report.offenders.isEmpty {
                headerSleepBlockersNotice(offenders: report.offenders)
            }
            Spacer()
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 24, alignment: .trailing)
                    .help("正在刷新")
            } else {
                Button(action: { Task { await state.refreshAll() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        // 点击区域保留 26pt，但图标本身右对齐到卡片外边缘。
                        .frame(width: 26, height: 24, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("立即刷新全部")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
    }

    /// 标题旁的睡眠锁提示：有第三方应用阻止休眠时显示数量，悬浮展开
    /// 应用清单（与设置页节能 Tab 检查项一同源）；无应用时整体隐藏。
    /// 仅 hover 展示、不可点击，与主面板其他 hover 区域行为一致。
    private func headerSleepBlockersNotice(offenders: [SleepAssertionOffender]) -> some View {
        HoverInfoRow {
            Text("\(offenders.count) 个应用正在阻止休眠")
                .font(MenuTypography.metricLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } detail: {
            SleepOffendersHoverView(offenders: offenders)
        }
    }

    // MARK: - content（卡片过多时滚动，避免菜单超出屏幕）

    @ViewBuilder
    private var content: some View {
        let cards = DisplayOrder.ordered(
            state.statuses.filter { $0.isEnabled },
            preferredIDs: state.configStore.config.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: Self.providerStatusDisplayNameAscending
        )

        if cards.isEmpty {
            VStack(spacing: 8) {
                if state.statuses.isEmpty {
                    Text("没有注册 provider")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("打开配置文件") { state.openConfigFile() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                } else {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("暂无启用的 Provider 监控")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primaryLabel)
                    Text("可在设置中勾选需要监控的 Provider")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("打开设置") {
                        openSettingsWindow()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: CardsContentHeightKey.self, value: geo.size.height)
                }
            )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    if Self.shouldShowSetupGuide(for: cards) {
                        setupGuide
                    }
                    ForEach(cards) { status in
                        ProviderCardView(status: status)
                            .equatable()
                            .contextMenu {
                                Button("立即刷新") {
                                    Task { await state.refreshOne(providerID: status.id) }
                                }
                                Button("打开配置文件…") {
                                    state.openConfigFile()
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: CardsContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(maxHeight: maxScrollViewHeight)
        }
    }

    private static func providerStatusDisplayNameAscending(
        _ lhs: ProviderStatus,
        _ rhs: ProviderStatus
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Four registered cards can all be `.notConfigured` on first launch because
    /// the template intentionally contains no usable credentials. Keep the
    /// existing passive card layout, but add one actionable route to Settings.
    static func shouldShowSetupGuide(for statuses: [ProviderStatus]) -> Bool {
        !statuses.isEmpty && statuses.allSatisfy {
            if case .notConfigured = $0.state { return true }
            return false
        }
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("开始配置 provider", systemImage: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
            Text("打开设置，启用 provider 并填写 API Key，或完成本地登录。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("打开设置") {
                openSettingsWindow()
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openSettingsWindow() {
        MenuBarAppActivation.activateForWindowPresentation()
        openSettings()
    }

    // MARK: - footer（紧凑 padding）



    private var footerBar: some View {
        HStack(spacing: 8) {
            footerStatus
            FooterActionButton(icon: "gearshape", title: "设置") {
                    openSettingsWindow()
                }
                .help("打开设置面板")
            footerSeparator
            FooterActionButton(
                icon: state.sleepHealth.isKeepAwakeOn ? "cup.and.saucer.fill" : "powersleep",
                title: state.sleepHealth.isKeepAwakeOn ? "防休眠" : "节能",
                dotColor: energyDotColor
            ) {
                state.sleepHealth.setKeepAwake(!state.sleepHealth.isKeepAwakeOn)
                energyUpdateTick &+= 1
            }
                .help(energyActionTooltip)
            footerSeparator
            FooterActionButton(icon: "doc.text.magnifyingglass", title: "日志") {
                state.revealLogFile()
            }
                .help("在 Finder 中显示 log.txt")
            footerSeparator
            FooterActionButton(icon: "xmark.circle", title: "退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// 「节能」入口的三色健康灯：颜色 = 睡眠健康度经菜单栏同款配色实例换算；
    /// 防休眠开启时立即返回 critical（红色）；report 尚未生成时不画点。
    private var energyDotColor: NSColor? {
        let level: HealthLevel?
        if state.sleepHealth.isKeepAwakeOn {
            level = .critical
        } else {
            level = state.sleepHealth.report?.status.healthLevel
        }
        return state.configStore.config.effectiveStatusBarHealthColors.color(for: level)
    }

    /// 「节能」按钮提示语：单击直接就地切换防休眠模式；排障可从旁边的「设置」进入。
    private var energyActionTooltip: String {
        if state.sleepHealth.isKeepAwakeOn {
            return "当前已开启防休眠模式；单击恢复系统自动睡眠"
        }
        switch state.sleepHealth.report?.status {
        case .blockedByAssertions:
            return "单击开启防休眠（当前有应用阻止休眠，详情见设置）"
        case .acSleepDisabled:
            return "单击开启防休眠（当前 AC 休眠已关闭，详情见设置）"
        case .healthy:
            return "单击开启防休眠模式（防止电脑休眠）"
        default:
            return "单击切换防休眠模式"
        }
    }

    private var footerStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(MenuTypography.footer)
            if let last = state.lastRefreshAt {
                Text("更新于 \(Formatters.formatClock(last))")
                    .font(MenuTypography.footerNumber)
            } else if let next = state.nextRefreshAt {
                Text("下次 \(Formatters.formatClock(next))")
                    .font(MenuTypography.footerNumber)
            } else {
                Text("就绪")
                    .font(MenuTypography.footer)
            }

            footerSeparator

            Text("自启 \(loginItemService.isEnabled ? "✓" : "✗")")
                .font(MenuTypography.footer)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .foregroundStyle(Color.secondary.opacity(0.75))
    }

    private var footerSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 10)
    }
}

/// 菜单整体背景：macOS 26 交给 MenuBarExtra 的系统 popover 提供 Liquid Glass，
/// 避免在系统玻璃上再叠一层自定义 glassEffect；旧系统回退到标准材质。
/// Header / content / footer 共用这一层，避免被 Divider 切成三个视觉区域。
private struct MenuPanelSurface: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            // MenuBarExtra(.window) 已经拥有系统 Liquid Glass 背景。
            // 这里保持透明，让 header / content / footer 共享同一层系统材质。
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

/// F4: 附着到实际 menu window，直接设置 `window.contentMaxSize` =
/// `floor(visibleFrame.height × 0.70)`。高度上限放在 NSWindow 层，不靠 SwiftUI
/// frame 拼凑：`fixedSize` 让窗口按内容自然决定高度，`contentMaxSize` 只负责
/// "别超过屏幕可见高度的 70%"。卡片少→窗口矮、全显示；卡片多→窗口封顶、内部
/// ScrollView 滚动。读取 `window.screen`（菜单所在屏），不用 `NSScreen.main`。
///
/// Testability note: `heightCapFraction` / `cappedHeight(_:)` / `width` 暴露为
/// `static`，让 `MenuPanelHeightBridgeTests` 不需要构造 `NSWindow` / `NSScreen`
/// 就能验证 70% 算式。`HeightProbeView.applyMaxSize()` 是带 NSWindow 副作用的
/// side-effect-only path，集成测试留给 UI 验证。
struct MenuPanelHeightBridge: NSViewRepresentable {
    /// F4: 70% 高度上限。设计判断：菜单贴顶/贴 Dock 时仍保留 30% 余量，
    /// 比 0.85+ 体感更"飘"、比 0.5- 触发 ScrollView 太频繁。具体取值见
    /// 7859f2d 的 commit body（"screen-relative height cap"）的视觉评估。
    static let heightCapFraction: CGFloat = 0.70
    /// F4: 菜单固定宽度。改这里会改所有 menu 卡片列宽。
    static let width: CGFloat = 360
    /// header (~38pt) + footer (~27pt) 的总固定高度。
    /// 所有需要将"卡片列表高度"换算为"窗口总高度"的位置统一引用此常量，
    /// 避免多处硬编码导致改一漏一。
    static let chromeHeight: CGFloat = 65

    /// F4: 给定 `screen.visibleFrame.height`，算 floor 后的 max content height。
    /// 抽成 pure function 让单测不需要 fake NSWindow/NSScreen。
    static func cappedHeight(_ visibleFrameHeight: CGFloat) -> CGFloat {
        floor(visibleFrameHeight * heightCapFraction)
    }

    var measuredCardsHeight: CGFloat = 0
    var onScreenDimensions: ((CGFloat, CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> HeightProbeView {
        let view = HeightProbeView()
        view.measuredCardsHeight = measuredCardsHeight
        view.onScreenDimensions = onScreenDimensions
        return view
    }

    func updateNSView(_ nsView: HeightProbeView, context: Context) {
        nsView.measuredCardsHeight = measuredCardsHeight
        nsView.onScreenDimensions = onScreenDimensions
        nsView.applyMaxSize()
    }

    final class HeightProbeView: NSView {
        var measuredCardsHeight: CGFloat = 0
        var onScreenDimensions: ((CGFloat, CGFloat) -> Void)? = nil
        private var lastMaxHeight: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 每次菜单窗口出现（viewDidMoveToWindow）都按当前所在屏重算 contentMaxSize。
            applyMaxSize()
            DispatchQueue.main.async { [weak self] in
                self?.applyMaxSize()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // 屏幕分辨率/Dock 变化后 visibleFrame 会变，借 updateTrackingAreas 重新核对。
            applyMaxSize()
        }

        func applyMaxSize() {
            guard let window else { return }
            let screen = MenuWindowAlignment.effectiveScreen(for: window)
            let visibleHeight = screen.visibleFrame.height
            // 真实可用高度：从顶部菜单栏到屏幕底部的实际空间
            let availableHeight = max(visibleHeight, screen.frame.height - 35)
            onScreenDimensions?(availableHeight, visibleHeight)

            let maxHeight = MenuPanelHeightBridge.cappedHeight(visibleHeight)
            let totalNaturalHeight = measuredCardsHeight > 0 ? (measuredCardsHeight + MenuPanelHeightBridge.chromeHeight) : 0
            // 能放下时允许自然撑开至 availableHeight；超标放不下时才封顶 maxHeight (70%)
            let windowMaxHeight = totalNaturalHeight > availableHeight ? maxHeight : availableHeight

            if windowMaxHeight != lastMaxHeight {
                lastMaxHeight = windowMaxHeight
                window.contentMaxSize = NSSize(width: MenuPanelHeightBridge.width, height: windowMaxHeight)
            }

            // 确保下拉窗口上边缘紧贴菜单栏底边并吸收系统 popover 顶部留白（+10pt），彻底消除空白空间缝隙
            MenuWindowAlignment.align(window: window, cardsHeight: measuredCardsHeight)
        }
    }
}

private struct FooterActionButton: View {
    let icon: String
    let title: String
    /// 可选状态圆点（如「节能」的三色健康灯）：非 nil 时叠在图标右上角；
    /// 默认 nil 不画，原有按钮（设置 / 日志 / 退出）不受影响。
    var dotColor: NSColor? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(MenuTypography.footer)
                    .overlay(alignment: .topTrailing) {
                        if let dotColor {
                            Circle()
                                .fill(Color(nsColor: dotColor))
                                .frame(width: 6.5, height: 6.5)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                                .offset(x: 3, y: -2)
                        }
                    }
                Text(title)
                    .font(MenuTypography.footer)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.secondary.opacity(0.82))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CardsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
