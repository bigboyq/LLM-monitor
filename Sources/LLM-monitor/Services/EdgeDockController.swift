import AppKit
import Combine
import QuartzCore
import SwiftUI

/// 屏幕边缘的小尺寸状态窗：一个 provider 一个圆环，贴边常驻。
///
/// 窗口工程上的三个关键约束（都是"能写出来但实际不生效"的高发地带）：
///
/// 1. **状态驱动**：窗口不自己轮询。只订阅 `AppState.statusDidChange`（官方广播
///    通道 —— 直接观察 `@Published statuses` 在本项目已被实测为失效）和
///    `healthEvaluationDate`（高峰边界时钟）。少接一个就是一片永远不变的假窗口。
/// 2. **鼠标接管**：`ignoresMouseEvents = true` 的窗口**收不到** tracking area 事件，
///    所以悬停探测必须走系统级 `addGlobalMonitorForEvents`。`hoveredIndex`（命中哪个圆）
///    是唯一真值，dock 接管状态、圆的 hover 高亮、以及详情 popover 挂哪个圆
///    全部由它驱动（`selectedIndex` 滞后于它一个 `hoverOpenDelay`，见
///    `scheduleSelection`）。
/// 3. **位置存比例**：见 `EdgeDockConfig.offset`。
@MainActor
final class EdgeDockController: ObservableObject {
    static let shared = EdgeDockController()

    /// 鼠标进入窗口外扩这么多 pt 以内即接管（兼作离开容差）。
    ///
    /// 必须大于 popoverGap（10pt）的一半以上，dock 与卡片各自的容差区才能在
    /// 两者之间的缝隙里重叠，鼠标横向穿行时接管不中断；12pt 另外给"离开"留出
    /// 一点视觉余量——恰好擦着黑条边缘走时不会一跳一跳地收起。
    private static let hoverPadding: CGFloat = 12
    /// 接管后的巡检间隔，兼作拖拽期间的松手检测。
    private static let capturePollInterval: TimeInterval = 0.2
    /// 按下后位移超过这么多 pt 才算拖动；以内松手视为"没拖动"，不做任何事
    /// （详情跟随 hover，按钮本身没有点击语义）。
    private static let dragThreshold: CGFloat = 4
    /// 悬停某一行后延迟这么久才展开详情。dock 是**常驻**在屏幕边缘的，鼠标
    /// 朝边缘扫过去（拖东西到边上、翻页）会频繁路过它，即时展开就是一路闪卡片。
    /// 这一小段延迟把"路过"和"停下来看"分开。
    private static let hoverOpenDelay: TimeInterval = 0.15
    /// 鼠标离开保持区后延迟这么久才收起；期间鼠标回来则取消。误划过边缘
    /// （一次性往返）不该把 dock 收掉再长出来闪一遍。
    private static let collapseDelay: TimeInterval = 0.5

    /// 完整↔简版的**形态过渡**时长。窗口 frame 的 AppKit 动画与内容的 SwiftUI
    /// 变形共用这个常量——两层必须同曲线同时长**同步**播放：窗口负责黑条与
    /// 位置（中心沿边连续移动），内容负责行 / 环的插值。任一层单独先行都会
    /// 露出破绽：只动画窗口 = 收起时缩掉的全是透明区域（瞬间跳变）；只动画
    /// 内容 = 窗口尺寸不变，结束后必须瞬移重定位（跳闪一下）。
    /// `nonisolated`：这个值被 SwiftUI/AppKit 的非隔离动画上下文读取（见
    /// `DockTransition.duration`），它本身是 Sendable 的纯常量，没有理由要求
    /// main actor。Swift 6 语言模式下少了它就是一个编译错误（audit 门禁会跑）。
    nonisolated static let contentMorphDuration: TimeInterval = 0.25

    /// dock 窗口 frame 过渡的种类：决定动画时长与互斥规则。
    private enum DockTransition {
        case expand
        case collapse
        /// 拖拽落点吸附、配置变更等位置微调。
        case standard

        var isFormChange: Bool { self != .standard }

        var duration: TimeInterval {
            switch self {
            case .expand, .collapse: return contentMorphDuration
            case .standard: return 0.18
            }
        }
    }

    /// 当前 hover 到的圆下标；nil = 没有 hover 任何圆。
    ///
    /// 单一真值：视图里圆的 hover 高亮、鼠标是否保持接管、详情挂哪个圆，
    /// 读的都是这一个值。
    @Published private(set) var hoveredIndex: Int?

    /// 已展开详情的圆下标；nil = 没有展开的详情卡片。
    ///
    /// 悬停某个圆 = 展开它的卡片，移开鼠标 = 收起。**不再由点击驱动**：点击留着
    /// 只做拖动，按下即起候选、松手时位移不过阈值就当无事发生。
    ///
    /// 相比 `hoveredIndex` 滞后 `hoverOpenDelay`（竖着扫过一列圆时，每个圆都
    /// 重新计时，扫过去就不会依次展开又收起每张卡）；鼠标压在卡片上时维持原值
    /// 不变，那是同一张卡的延续。真正的清理由 `releaseMouseCapture` 在离开整个
    /// 保持区后统一做。
    @Published private(set) var selectedIndex: Int?

    /// 自动隐藏模式下是否处于**展开**形态。非自动隐藏模式下恒为 false 且无意义
    /// （外观由 `isCompactAppearance` 统一推导）。
    ///
    /// true = 完整 dock（数值 + 品牌图标 + 双环，可逐行 hover）；
    /// false = 简版（只有 5h 单环小圆）。鼠标靠近展开、离开收起。
    @Published private(set) var isExpanded = false

    /// 窗口当前该用哪种外观：自动隐藏开启且未展开时才是简版。
    ///
    /// 唯一判定入口，`reconcile`（窗口尺寸）与视图（排版）都读它——两处若各写
    /// 各的判定，窗口尺寸和内容排版一旦不一致，圆环会被裁或留白。
    var isCompactAppearance: Bool {
        config.autoHideMode && !isExpanded
    }

    private weak var state: AppState?
    /// ConfigStore 由 App 的 `@StateObject` 持有到进程结束，这里强引用不会成环
    /// （ConfigStore 不反向引用本控制器）。
    private var configStore: ConfigStore?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    /// 悬停某个圆时在旁边展示的 provider 卡片 popover。与 dock 是**两个独立窗口**，
    /// dock 尺寸不因它改变。
    private var popoverPanel: NSPanel?
    private var popoverHostingView: NSHostingView<AnyView>?
    private var statusCancellable: AnyCancellable?
    private var evaluationCancellable: AnyCancellable?
    private var configCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var captureTimer: Timer?

    /// 实际生效配置。`@Published`：外观（完整/简版）由它派生，设置页翻转
    /// 自动隐藏开关时视图必须立即跟随，否则窗口缩了、内容排版还停在旧形态。
    @Published private(set) var config: EdgeDockConfig = .default
    private var isFullscreenSpace = false
    private var isDragging = false
    /// 拖拽开始时取一次的条目数，供逐事件的 `applyDrag` 复用。
    private var dragEntryCount = 0
    /// 按下时的屏幕坐标与"是否已越过拖动阈值"。位移在阈值内松手 = 点击（切换
    /// 详情卡片），越过阈值 = 真拖动（收起详情、移动窗口）。没有这对状态就无法
    /// 区分两种意图——点一下圆环会先把 dock 拖走几像素，或反过来拖动被当成点击。
    private var pressScreenLocation: CGPoint?
    private var pressBecameDrag = false
    /// 挂起中的延时收起任务。鼠标离开保持区时排入，0.5s 后触发；期间鼠标回来
    /// 或状态变化（拖动 / 隐藏 / 释放接管）则取消。是**固定 deadline** 而不是
    /// 防抖：巡检定时器每 0.2s 会重复走"还在外面"的分支，防抖式重排会让
    /// deadline 永远被推后、收起永不发生。
    /// Space 切换后阶梯式补测全屏的挂起任务。见 `scheduleFullscreenRechecks`。
    private var fullscreenRetryWorkItems: [DispatchWorkItem] = []
    private var collapseWorkItem: DispatchWorkItem?
    /// 挂起的「展开某行详情」任务，见 `scheduleSelection`。
    private var pendingSelectionWorkItem: DispatchWorkItem?
    /// 形态过渡进行中标记 + 到期解除任务：期间标准过渡（刷新广播等）不得碰
    /// 窗口 frame——按动画中间态帧重算并 setFrame 会打断正在播放的窗口动画，
    /// 表现为半途抽一下。
    private var formMorphGuardWorkItem: DispatchWorkItem?
    private var isFormMorphInFlight = false
    /// dock 是否已接管鼠标（`ignoresMouseEvents == false`）。与 `hoveredIndex` 分开：
    /// 鼠标停在 popover 上时不需要再 hover 某个圆，但接管状态必须继续保持。
    private var isMouseCaptured = false

    /// 每一行在**视图坐标系**（= NSHostingView）下的真实矩形，由 `EdgeDockContentView`
    /// 用 GeometryReader **逐行直报**，键是 provider id。
    ///
    /// 存视图坐标而不是屏幕坐标：拖拽 / 换屏 / 移动窗口时这些矩形不变，屏幕坐标却在变。
    /// 每帧按当前窗口位置换算一次，4 个矩形的开销可以忽略，却避免了"拖到一半命中
    /// 判定还停在旧位置"这种陈旧数据。
    ///
    /// 坐标系换算由控制器统一做，视图只报自己的矩形 —— 视图不该知道屏幕的存在。
    private var measuredRowRectsByID: [String: CGRect] = [:]
    /// 本帧命中实际采用的来源，切换时写日志。
    ///
    /// 这一行日志是有意加的：实测路径一旦失效（例如坐标系换算错了），界面表现为
    /// "hover 正常但位置微妙地偏"，没有任何报错。把它显式打出来，silent failure
    /// 才有可能被看见。
    private var rowRectsSource: RowRectsSource = .geometry

    private enum RowRectsSource: String {
        case measured = "实测"
        case geometry = "几何兜底"
    }
    /// 上一次的显隐判定签名，用于只在"为什么没出现 / 出现在哪"变化时写日志。
    private var lastVisibilitySignature = ""

    private init() {}

    // MARK: - 接线

    func attach(state: AppState, configStore: ConfigStore) {
        self.state = state
        self.configStore = configStore
        config = configStore.config.effectiveEdgeDockConfig

        // 条目数 / 健康色变化 → 重算窗口尺寸
        statusCancellable = state.statusDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile(animated: true) }

        // 高峰窗口跨越边界时也要跟着变色（此时可能没有任何抓取发生）
        evaluationCancellable = state.$healthEvaluationDate
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile(animated: true) }

        // config.json 被手改 / 设置页保存 → 跟随
        configCancellable = configStore.$config
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newConfig in
                guard let self else { return }
                let next = newConfig.effectiveEdgeDockConfig
                let visibilityChanged = next.enabled != self.config.enabled
                let autoHideChanged = next.autoHideMode != self.config.autoHideMode
                let fullscreenPolicyChanged = next.hideInFullscreen != self.config.hideInFullscreen
                self.config = next
                // 开关翻转时清掉缓存的全屏判定：重新开启要从"当前不在全屏"开始，
                // 否则会拿退出全屏时的旧状态直接判隐藏。
                if visibilityChanged { self.isFullscreenSpace = false }
                // 自动隐藏开关翻转时回到收起形态（关掉自动隐藏则恢复常驻完整 dock）。
                // 只在翻转时复位：拖拽落点也会走一次持久化广播，鼠标正悬停时
                // 不该因此闪一次收起。
                if visibilityChanged || autoHideChanged { self.isExpanded = false }
                self.reconcile(animated: true)
                // 全屏隐藏开关翻转也必须重新探测：用户很可能**正在全屏里**改这个
                // 设置。少了这次探测就会拿一个可能已经过期的 `isFullscreenSpace`
                // 去套新策略——表现是"开关拨了没反应，要退出全屏再来一次"。
                if visibilityChanged || fullscreenPolicyChanged {
                    self.evaluateFullscreen()
                }
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile(animated: false)
                self.evaluateFullscreen()
            }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateFullscreen() }
        }

        // 进/出全屏的**本体**信号：全屏会切到一个新的 Space，所以真正对应这件事的
        // 通知是 `activeSpaceDidChange`，而不是上面那两个。
        //
        // 之前只靠 `didActivateApplication`，等于在赌"进全屏时系统会顺带发一次
        // App 激活"——而用户点全屏时那个 App 本来就已经是前台的，根本不会重新
        // 激活。结果是 `isFullscreenSpace` 停在旧值：默认配置下 dock 该藏
        // 没藏（既有 bug），关掉"全屏隐藏"时则是因为状态压根没更新才碰巧对。
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateFullscreen()
                self?.scheduleFullscreenRechecks()
            }
        }

        installMouseMonitors()
        // 启动时先判一次全屏，再 reconcile：attach 之前用户可能就已经待在全屏 Space 里，
        // 而那条路径上不会有任何 Space 切换 / App 激活通知（`activeSpaceDidChange` 只在
        // 切换时发）。少了这一次，dock 会在启动的头一瞬间挂在全屏窗口上，一直等到用户
        // 切走再切回来才消失。
        //
        // 放在 reconcile 之前：判定为全屏时它自己会走一次 `reconcile(animated: false)`，
        // 窗口直接以隐藏状态创建；反过来先 reconcile 就会先显示、再隐藏，闪一下。
        evaluateFullscreen()
        reconcile(animated: false)
    }

    func teardown() {
        cancelPendingCollapse()
        cancelFullscreenRechecks()
        cancelFormMorphGuard()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        captureTimer?.invalidate()
        captureTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil
        activationObserver = nil
        spaceObserver = nil
        statusCancellable?.cancel()
        evaluationCancellable?.cancel()
        hidePopover()
        panel?.orderOut(nil)
    }

    // MARK: - 窗口

    private func ensurePanel() {
        guard panel == nil, let state, let configStore else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // .floating：盖在普通窗口之上，但低于菜单栏 / 系统弹窗层级。
        panel.level = .floating
        // canJoinAllSpaces + fullScreenAuxiliary：切 Space 时跟着走。
        // 全屏态的显隐由 evaluateFullscreen 显式控制。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        // 底色保持透明、背板由 SwiftUI 的液态玻璃填：玻璃要采样背后的桌面壁纸，
        // 设成不透明底色会让整个窗口矩形变成一块死板的实色，`EdgeDockTab` 的
        // 直角与圆角轮廓也看不见。
        panel.hasShadow = false
        panel.backgroundColor = .clear
        // **钉死暗色**，不跟系统外观走：dock 和菜单栏图标、菜单面板一起常驻在
        // 桌面上，跟着系统在白天/晚上翻转会让它一天变两次观感。
        //
        // 这里和内容侧的 `.environment(\.colorScheme, .dark)` 是**两件必须同时
        // 做的事**，缺一不可：面板外观决定材质（`glassEffect` /
        // `ultraThinMaterial`）按暗色还是浅色解析，SwiftUI 的环境决定
        // `Color.primary` 这类语义色翻成浅色还是深色。只做前者会得到"深底深字"，
        // 只做后者会得到"浅底浅字"，两种都看不见。
        panel.appearance = NSAppearance(named: .vibrantDark)
        // 拖动不走系统的自由移动：窗口位置由 `applyDrag` 按鼠标直接驱动，
        // 始终钉在贴靠边上（见该方法说明）。
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        // 默认完全穿透：常驻在屏幕边缘也绝不挡用户点下面的东西。
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(
            rootView: AnyView(
                EdgeDockContentView(controller: self, state: state, configStore: configStore)
                    // 与 `panel.appearance` 配对，理由见上。
                    .environment(\.colorScheme, .dark)
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    /// 当前应该展示的条目，顺序 = 配置里的 provider 顺序（与菜单卡片一致）。
    ///
    /// **控制器侧的唯一定义**：窗口尺寸、命中下标、popover 取 status 全走这里。
    /// 视图（`EdgeDockContentView`）用同一个 `EdgeDockProjection.entries` 和同一份
    /// 配置算出同样的顺序——两边只要有一处自己排，就会出现"高亮的是 A、弹出的是 B"。
    private func orderedEntries() -> [EdgeDockEntry] {
        guard let state else { return [] }
        return EdgeDockProjection.entries(
            from: state.statuses,
            preferredIDs: configStore?.config.providerCardOrder
        )
    }

    /// 唯一的布局/显隐收口：算条目 → 决定显隐 → 定尺寸 → 贴边 → 排序。
    private func reconcile(animated: Bool, transition: DockTransition = .standard) {
        // 只做"接没接线"的存在性检查，不绑定 `state` 本身：下面一律经
        // `orderedEntries()` 取数据（它自己也读 `state`），接出一个用不上的局部量
        // 只会招来 unused 警告。
        guard state != nil else { return }

        let entries = orderedEntries()
        let entryCount = entries.count
        // 选中项按 **id** 跟着 provider 走，而不是钉在下标上：用户在设置页改了顺序，
        // 下标会指向另一个 provider，已经展开的卡片就会无声地换成别人的。
        let selectedID = (selectedIndex.map { entries.indices.contains($0) } ?? false)
            ? entries[selectedIndex!].id
            : nil
        // 只在真的变了才写回——`@Published` 每次赋值都会广播，而 reconcile 每次
        // 状态广播都跑，无条件赋值等于每 provider 一次无谓的视图刷新。
        if let selectedID {
            let reanchored = entries.firstIndex(where: { $0.id == selectedID })
            if selectedIndex != reanchored { selectedIndex = reanchored }
        } else if selectedIndex != nil, entryCount == 0 {
            // 条目全没了（provider 停用/删除）→ 钉住的卡片没有对象，直接收起。
            selectedIndex = nil
        }

        // 开关关闭、前台 App 全屏、或一个 provider 都没开监控 → 不出现。
        // 挂一个空壳在屏幕边缘只会让人以为程序坏了。
        guard config.enabled, !isHiddenByFullscreen, entryCount > 0 else {
            logVisibilityChange(
                enabled: config.enabled,
                entryCount: entryCount,
                fullscreen: isFullscreenSpace,
                shown: false,
                frame: .zero
            )
            // 隐藏路径**永远**清：不是"鼠标离开"，是"没有 dock 了"。
            releaseMouseCapture()
            // 隐藏即解除形态过渡守卫，窗口不再有动画需要保护。
            cancelFormMorphGuard()
            // 重新出现时从收起形态开始：展开态是"鼠标还在上面"的瞬时状态，
            // 隐藏过一轮就不该带着它回来。
            isExpanded = false
            // 用可选链而不是 ensurePanel()：开关关闭时**完全不创建窗口**。
            // attach 跑在 LLMMonitorApp.init() 里，那早于 applicationDidFinishLaunching，
            // 不该在那之前就往 window server 塞一个窗口。
            panel?.orderOut(nil)
            return
        }

        // 到这里才真的需要窗口了。
        ensurePanel()
        guard let panel else { return }

        // dock 尺寸只跟条目数和外观有关 —— hover 弹出的是旁边那个独立 popover，
        // dock 本体不参与展开（自动隐藏模式的收起/展开除外，那是窗口自身的形态）。
        let edge = config.edge
        let size = EdgeDockGeometry.dockSize(
            entryCount: entryCount,
            edge: edge,
            appearance: isCompactAppearance ? .compact : .full
        )

        let target = EdgeDockGeometry.frame(
            visibleFrame: Self.targetScreen.visibleFrame,
            edge: edge,
            size: size,
            offset: config.offset
        )

        // 拖拽中不跟几何计算抢控制权，否则窗口会跟手抽搐。
        guard !isDragging else { return }

        // 形态过渡动画进行中：帧由该动画驱动到位，标准过渡此刻按中间态帧重算
        // 并 setFrame 只会打断它。形态过渡自身不受此限——快速反向切换时直接
        // 重定目标即可。
        if transition == .standard, isFormMorphInFlight { return }

        // 帧没有变化时完全不碰窗口。refresh 期间 `statusDidChange` 每个 provider
        // 都触发一次；反复 `setFrame`（哪怕目标帧相同）也会打断窗口服务器的合成、
        // 重启隐式动画，dock 会跟着每一次广播轻微抽动。显隐与位置都由 frame 决定，
        // 帧相同且已可见 = 一切照旧。
        if panel.isVisible, panel.frame == target {
            // 例外：展开着的详情卡片内容是创建那一刻的快照，数据刷新后必须重摆
            // 一次，否则读到的永远是旧值。
            if selectedIndex != nil { updatePopover() }
            return
        }

        if animated, panel.isVisible {
            if transition.isFormChange { beginFormMorphGuard() }
            // 形态过渡（expand/collapse）与内容的 SwiftUI 变形同曲线同时长，
            // 窗口中心沿边连续移到目标位置；standard 只做位置微调。
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = transition.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()

        logVisibilityChange(
            enabled: config.enabled,
            entryCount: entryCount,
            fullscreen: isFullscreenSpace,
            shown: true,
            frame: target
        )
    }

    /// 只在"为什么没出现 / 出现在哪"发生变化时打一行。
    ///
    /// 这个窗口最容易变成一片**完全静默的缺席**——没开、被全屏挡住、一个 provider
    /// 都没启用，三种情况屏幕上长得一模一样。没有任何日志时用户无从判断是哪一种，
    /// 只能靠猜。这里把判定输入和最终 frame 一起落盘，让"没出现"变成可诊断的。
    private func logVisibilityChange(
        enabled: Bool,
        entryCount: Int,
        fullscreen: Bool,
        shown: Bool,
        frame: CGRect
    ) {
        let signature = "\(enabled)|\(entryCount)|\(fullscreen)|\(shown)|\(frame.origin.x.rounded())|\(frame.origin.y.rounded())"
        guard signature != lastVisibilitySignature else { return }
        lastVisibilitySignature = signature

        if shown {
            logInfo("EdgeDock: 显示 \(entryCount) 个圆 edge=\(config.edge.rawValue) frame=\(Self.describe(frame))")
        } else {
            let reason = !enabled ? "开关关闭" : (entryCount == 0 ? "没有已启用的 Provider" : "前台 App 全屏")
            logInfo("EdgeDock: 隐藏（\(reason)）enabled=\(enabled) entries=\(entryCount) fullscreen=\(fullscreen)")
        }
    }

    private static func describe(_ index: Int?) -> String {
        index.map { "第\($0 + 1)行" } ?? "无"
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    /// dock 的"主场"屏：已显示时锚定**当前所在屏**，未显示时才用主屏。
    ///
    /// 不能无条件用 `NSScreen.main`：它跟随键盘焦点——多显示器下用户在另一块屏
    /// 上点一下任何窗口，dock 就会整个跳到那块屏上，看起来就是位置随机漂移。
    /// 锚定所在屏后位置只由配置驱动；代价是 dock 暂时不能被拖到别的屏
    /// （拖拽时 visibleFrame 始终取本屏，窗口钉在本屏边缘），这是有意的取舍。
    private static var targetScreen: NSScreen {
        if let current = shared.panel?.screen ?? shared.popoverPanel?.screen {
            return current
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    // MARK: - 鼠标穿透 / 悬停接管

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil else { return }

        // ignoresMouseEvents = true 的窗口收不到 tracking area 事件，必须走系统级监听。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event.type) }
        }

        // 本 app 在前台或命中本应用面板时的事件监听。
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event.type) }
            return event
        }
    }

    /// 鼠标事件的唯一处理入口（global / local 两个 monitor 共用）。
    private func handleMouseEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            // 只有按在 dock 本身上才起拖；按在 popover 上不应该把圆环拖走。
            // isVisible：隐藏路径只 orderOut，frame 还留着旧位置——全屏 / 关开关
            // 期间点到那个位置，不该把看不见的 dock 拖走再把新位置写进配置。
            if let panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) {
                isDragging = true
                // 按下即作废挂起的收起：拖拽期间收起毫无意义，且释放接管会打断
                // 正在进行的事件序列。形态过渡守卫一并解除，拖拽自己接管 frame。
                cancelPendingCollapse()
                cancelFormMorphGuard()
                // 条目数在拖拽开始时取一次：拖动事件是 60~120Hz，而重新投影要走一遍
                // 全部 provider 的额度聚合，没必要每帧重来。
                dragEntryCount = orderedEntries().count
                pressScreenLocation = NSEvent.mouseLocation
                pressBecameDrag = false
            }
        case .leftMouseUp:
            finishPressOrDrag(at: NSEvent.mouseLocation)
        case .leftMouseDragged:
            dragMoved(at: NSEvent.mouseLocation)
        default:
            probeMouse(at: NSEvent.mouseLocation)
        }
    }

    /// 拖动事件 / 巡检定时器共用的移动入口：先过"点击 vs 拖动"阈值。
    ///
    /// 阈值之内的抖动既不移动窗口也不收详情——否则每次点击 dock 都会先被拖歪
    /// 1~2pt 再弹回。越过阈值那一刻判定为真拖动：详情卡片没有跟着 dock 跑的
    /// 意义，立即收起。
    ///
    /// 只跟从「在 dock 上按下」的那次拖动（`guard isDragging`）。global monitor
    /// 会收到所有其他 App 的拖动事件——在别的应用里拖窗口、划选文本、拖滑杆，
    /// 无条件跟随时任何一次拖动都会把 dock 瞬移到鼠标处，松手再 persistPosition
    /// 把漂移位置写进 config。mouseDown 落在 dock 上时 local / global 两个
    /// monitor 必有一个先见到（接管中走 local，穿透时走 global）。
    private func dragMoved(at mouse: CGPoint) {
        guard isDragging else { return }
        if !pressBecameDrag, let start = pressScreenLocation {
            guard hypot(mouse.x - start.x, mouse.y - start.y) >= Self.dragThreshold else { return }
            pressBecameDrag = true
            if selectedIndex != nil {
                selectedIndex = nil
                updatePopover()
            }
        }
        applyDrag(at: mouse)
    }

    /// 展开某行的详情，经 `hoverOpenDelay` 延迟。
    ///
    /// 换行就换任务：鼠标竖着扫过一列圆时，每个圆都重新计时，于是"扫过去"不会
    /// 依次展开又收起每张卡；停在哪，哪张才展开。任务到点时再复核一次
    /// `hoveredIndex`——延迟期间鼠标可能已经移走或移到了别的圆上。
    private func scheduleSelection(_ index: Int) {
        cancelPendingSelection()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoveredIndex == index, self.selectedIndex != index else { return }
                self.selectedIndex = index
                self.updatePopover()
            }
        }
        pendingSelectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: work)
    }

    private func cancelPendingSelection() {
        pendingSelectionWorkItem?.cancel()
        pendingSelectionWorkItem = nil
    }

    /// 松手的统一收尾：有位移 = 拖动（吸附 + 记住位置），无位移 = 保持现状（悬停模式由鼠标位置驱动）。
    private func finishPressOrDrag(at mouse: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        guard pressBecameDrag else { return }
        reconcile(animated: true)
        persistPosition()
    }

    /// 每帧巡检鼠标：决定命中哪个圆、要不要接管、popover 挂在哪。
    private func probeMouse(at mouse: CGPoint) {
        guard let panel = self.panel,
              config.enabled, !isHiddenByFullscreen, !isDragging else { return }

        let inDock = panel.frame.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding).contains(mouse)
        // 卡片**不可见时不参与判定**：`orderOut` 只把窗口藏起来，frame 还留在
        // 上次出现的位置——不过滤 `isVisible` 的话，卡片曾经占据（现在已消失）
        // 的那块屏幕会一直算作"保持接管区"：鼠标路过就莫名保活，自动隐藏的
        // 收起判定跟着失真，看起来像给一张看不见的卡片预留了空间。
        let inPopover = popoverPanel.map {
            $0.isVisible
                && $0.frame.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding).contains(mouse)
        } ?? false

        // 简版（自动隐藏的收起形态）：靠近即整体展开，不做逐行 hover——
        // 简版的圆只有 14pt，逐行命中在这个尺寸下只会抖；"dock 长出来"
        // 本身就是对这个靠近动作的回应。逐行 hover（高亮 + 详情）都只在
        // 展开形态里发生。
        if isCompactAppearance {
            if inDock {
                isExpanded = true
                captureMouse()
                // 窗口与内容**同步**动画（同曲线同时长）：中心沿边连续移到完整形态
                // 的位置、黑条连续长出。窗口瞬时先行 / 事后补缩都会在两种帧的
                // 中心差上跳一下（同一 offset 下完整帧与简版帧中心不重合）。
                reconcile(animated: true, transition: .expand)
                // 展开完成后接管巡检接管鼠标，`probeMouse` 会按新的行矩形补上
                // 悬停命中，详情跟着一起出来；这里不需要为动画中间态做任何补摆。
            }
            return
        }

        // 实测矩形优先；不可用时才退回按常量推算（宁可位置有偏差，也不能没有命中——
        // 命中失败会连带鼠标接管一起失效，hover 和拖拽会同时失能）。
        let entries = orderedEntries()
        let rows = resolvedRowRects(entries: entries, panelFrame: panel.frame)
        let newIndex = inDock ? Self.rowIndex(at: mouse, measured: rows) : nil

        if newIndex != hoveredIndex {
            hoveredIndex = newIndex
            logInfo(
                "EdgeDock: hover -> \(Self.describe(newIndex)) "
                + "rows=\(rows.count) 来源=\(rowRectsSource.rawValue)"
            )
        }

        // 详情**跟随 hover**。两个方向要区别对待：
        //
        // - 压在卡片上（`inPopover`）时不改选中：鼠标从环移到卡片上的那一段
        //   `newIndex` 必然变成 nil，跟着它清就把正在读的卡片抽走了。
        //   dock 与卡片的容差区在缝隙里重叠（2×12 > popoverGap 10），所以这里
        //   出现的是"仍在接管区、但不在环上"，由下面 0.5s 的收起宽限兜底。
        // - `newIndex == nil` 时**不**主动清空：鼠标滑到黑条内边距、或从环移向
        //   卡片时都会经过这种状态，立刻收卡等于不给反应。真正的清理由
        //   `releaseMouseCapture` 在离开整个保持区后统一做。
        if !inPopover, let newIndex, newIndex != selectedIndex {
            scheduleSelection(newIndex)
        }

        // 鼠标在任一窗口的**视觉范围**（窗口 frame + 容差）内都保持接管。
        //
        // 判定必须用整窗 frame（inDock），不能要求命中某一行（newIndex != nil）：
        // 行的命中区是"精确包含 + 距行中心 34pt 以内"的圆，而 dock 黑条两侧各有
        // 8pt 内边距、行与行之间还有 16pt 间隙——鼠标走在内边距条带的对角区域时
        // 到最近行中心可到 41pt，命中失败 → 收起，但视觉上明明还压在黑条上，
        // 表现就是"还没离开就收起了"。行命中（hoveredIndex）只负责高亮。
        //
        // 离开不立即收起：排一个 0.5s 的延时任务，期间回来就取消——一来一回的
        // 短暂划过不该让 dock 收掉再长出来闪一遍。
        if inDock || inPopover {
            cancelPendingCollapse()
            captureMouse()
        } else {
            scheduleCollapse()
        }
    }

    /// 鼠标离开保持区后的延时收起：到点复核（静止回来的极端情形没有新鼠标事件，
    /// 必须在触发时再核一次），仍在外面才真正释放与收拢。
    private func scheduleCollapse() {
        guard collapseWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            guard !self.cursorInsideKeepAliveRegion(NSEvent.mouseLocation) else { return }
            self.releaseMouseCapture()
            self.collapseExpandedDockIfNeeded()
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: item)
    }

    private func cancelPendingCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// 鼠标是否还在"保持接管"区：dock frame，或**可见的**详情卡片 frame，
    /// 各外扩一个 hoverPadding。
    private func cursorInsideKeepAliveRegion(_ mouse: CGPoint) -> Bool {
        guard let panel else { return false }
        if panel.frame.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding).contains(mouse) {
            return true
        }
        guard let popover = popoverPanel, popover.isVisible else { return false }
        return popover.frame
            .insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding)
            .contains(mouse)
    }

    /// 鼠标离开 dock 与 popover 之后，把自动隐藏模式收起回简版。
    ///
    /// 窗口与内容**同步**收回（同曲线同时长）：中心沿边连续移回简版位置、黑条
    /// 连续缩回边缘，结束后无需任何补摆。
    ///
    /// 不放进 `releaseMouseCapture`：那里还被 reconcile 的隐藏分支调用，若它再触发
    /// reconcile 会形成一次无意义的重入（隐藏条件不会变，但白跑一遍）。
    private func collapseExpandedDockIfNeeded() {
        guard isExpanded, config.enabled, !isHiddenByFullscreen, !isDragging else { return }
        isExpanded = false
        reconcile(animated: true, transition: .collapse)
    }

    /// 形态过渡期间拒绝标准过渡抢窗口 frame；动画结束后自动解除。
    private func beginFormMorphGuard() {
        cancelFormMorphGuard()
        isFormMorphInFlight = true
        let item = DispatchWorkItem { [weak self] in
            self?.formMorphGuardWorkItem = nil
            self?.isFormMorphInFlight = false
        }
        formMorphGuardWorkItem = item
        // +0.05s 余量：SwiftUI 动画的实际结束略晚于名义 duration。
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.contentMorphDuration + 0.05,
            execute: item
        )
    }

    private func cancelFormMorphGuard() {
        formMorphGuardWorkItem?.cancel()
        formMorphGuardWorkItem = nil
        isFormMorphInFlight = false
    }

    /// 命中测试：优先用视图实测的行矩形。
    ///
    /// `nonisolated`：纯函数，不碰任何 actor 状态。标出来是为了能在同步测试里直接
    /// 断言几何行为——否则每个调用点都得被拖进主线程，白白让纯几何多一层跳板。
    nonisolated static func rowIndex(at point: CGPoint, measured: [CGRect]) -> Int? {
        for (index, rect) in measured.enumerated() where rect.contains(point) {
            return index
        }
        // 实测矩形可能有 1~2pt 的取整差，取"最近中心"兜底，避免边界抖动。
        var best: (index: Int, distance: CGFloat)?
        for (index, rect) in measured.enumerated() {
            let d = hypot(rect.midX - point.x, rect.midY - point.y)
            if best == nil || d < best!.distance { best = (index, d) }
        }
        guard let best, best.distance <= EdgeDockGeometry.diameter else { return nil }
        return best.index
    }

    func updateMeasuredRowRect(id: String, rect: CGRect) {
        guard measuredRowRectsByID[id] != rect else { return }
        measuredRowRectsByID[id] = rect
    }

    /// 本帧用于命中的行矩形（屏幕坐标）：实测优先，不可用时退回几何推算。
    private func resolvedRowRects(entries: [EdgeDockEntry], panelFrame: CGRect) -> [CGRect] {
        // 视图只报视图坐标；换算在这里做，拖拽 / 换屏时每帧按当前窗口位置重算，
        // 不会像"上报时就换算"那样留下陈旧数据。
        let onScreen: [String: CGRect]
        if let hostingView {
            onScreen = measuredRowRectsByID.mapValues { convertToScreen($0, in: hostingView) }
        } else {
            onScreen = [:]
        }
        let resolved = Self.resolveRowRects(
            entries: entries,
            measured: onScreen,
            panelFrame: panelFrame,
            edge: config.edge,
            slack: Self.hoverPadding
        )
        setRowRectsSource(resolved.usedMeasured ? .measured : .geometry)
        return resolved.rows
    }

    /// 命中矩形选取（纯函数）：实测优先，三种情况退回几何推算。
    ///
    /// 退回条件 —— 还没量到（视图未上报）、量得不完整（有条目没有矩形）、
    /// 换算后整列落在窗口外（坐标系换算错了；与其错命中不如用兜底）。
    ///
    /// **保证永远返回可命中的行**：命中失败会连带 `captureMouse()` 不执行，
    /// `ignoresMouseEvents` 一直是 true，于是 hover 和拖拽**同时**失能。
    /// 宁可位置有偏差，也不能没有命中。
    nonisolated static func resolveRowRects(
        entries: [EdgeDockEntry],
        measured: [String: CGRect],
        panelFrame: CGRect,
        edge: DockEdge,
        slack: CGFloat
    ) -> (rows: [CGRect], usedMeasured: Bool) {
        let fallback = EdgeDockGeometry.rowRects(
            dockFrame: panelFrame, edge: edge, entryCount: entries.count
        )
        guard !entries.isEmpty, !measured.isEmpty else { return (fallback, false) }

        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: measured)
        guard ordered.allSatisfy({ $0 != EdgeDockProjection.unmeasuredRow }) else {
            return (fallback, false)
        }
        // 视图坐标系 → 屏幕坐标系的换算在此之前已完成（调用方传进来的已是屏幕坐标）；
        // 这里只做一次自检：整列必须落在 dock 附近，否则说明换算错了。
        let dockArea = panelFrame.insetBy(dx: -slack, dy: -slack)
        guard ordered.allSatisfy({ dockArea.intersects($0) }) else { return (fallback, false) }
        return (ordered, true)
    }

    private func setRowRectsSource(_ source: RowRectsSource) {
        guard source != rowRectsSource else { return }
        rowRectsSource = source
        logInfo("EdgeDock: 命中来源 -> \(source.rawValue) measured=\(measuredRowRectsByID.count)")
    }

    /// 视图坐标（y 向下，原点左上，来自 SwiftUI geo.frame(in: .global)）→ 屏幕坐标（y 向上，原点屏幕左下）。
    private func convertToScreen(_ rect: CGRect, in view: NSView) -> CGRect {
        guard let window = view.window else { return rect }
        return CGRect(
            x: window.frame.minX + rect.minX,
            y: window.frame.maxY - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
    private func captureMouse() {
        guard let panel, !isMouseCaptured else { return }
        isMouseCaptured = true
        panel.ignoresMouseEvents = false
        startCaptureTimer()
    }

    private func releaseMouseCapture() {
        // 释放已由其它路径发生（隐藏 / 拆卸 / 本任务的触发点），挂起的延时收起
        // 一律作废，避免它在稍后凭空再跑一遍释放。
        cancelPendingCollapse()
        // 挂起的展开同样作废：鼠标已经离开保持区，0.15s 后再凭空展开一张卡
        // 读起来是"鼠标不在、卡片在"。
        cancelPendingSelection()
        guard isMouseCaptured || hoveredIndex != nil || selectedIndex != nil else { return }
        isMouseCaptured = false
        captureTimer?.invalidate()
        captureTimer = nil
        panel?.ignoresMouseEvents = true
        if hoveredIndex != nil {
            hoveredIndex = nil
        }
        if selectedIndex != nil {
            selectedIndex = nil
            updatePopover()
        }
    }

    // MARK: - Provider 卡片 popover

    /// 展示 / 收起**当前悬停**的 provider 卡片。
    ///
    /// 直接复用菜单里的 `ProviderCardView(status:)`，与主菜单那一屏**逐字同源**，
    /// 不另写一套轻量版 —— 两份"看起来一样的卡片"必然漂移。
    private func updatePopover() {
        guard let panel,
              let state,
              let index = selectedIndex,
              config.enabled, !isHiddenByFullscreen
        else {
            hidePopover()
            return
        }

        let statuses = state.statuses
        // 投影过滤掉 disabled 的 provider，条数和 statuses 的下标可能对不齐，
        // 所以这里按 id 取原始 status，而不是直接用 index 下标。
        let entries = orderedEntries()
        guard index >= 0, index < entries.count,
              let status = statuses.first(where: { $0.id == entries[index].id })
        else {
            hidePopover()
            return
        }

        let visibleFrame = Self.targetScreen.visibleFrame
        let (popover, hosting) = ensurePopoverPanel()
        let backdrop = EdgeDockTheme.popoverPadding
        // 固定宽度 = 主菜单宽度；屏幕装不下才钳位。卡片内容宽 = 面板宽 - 两侧内边距，
        // 与主菜单里卡片拿到的是同一个数。
        let width = min(EdgeDockTheme.popoverWidth, max(visibleFrame.width - 80, 240))
        let cardContentWidth = max(width - backdrop * 2, 120)

        /// 系统材质背板 + 和菜单那一屏**同一张卡片**浮在上面。
        ///
        /// 卡片曾经被去掉（`surface: .transparent`，内容直接坐在材质上），理由是
        /// "材质本身已经是系统材质，再夹一层半透明底色会把它压灰"。结果是 dock
        /// 的浮层和菜单弹出长得不一样：同一张 `ProviderCardView` 在两个宿主里
        /// 一个没有边界、一个有。现在按"和菜单弹出的一样"来——卡片回来，材质只
        /// 负责垫底。
        ///
        /// 宽度**固定**并与主菜单同源，不再按内容自然尺寸伸缩：自然尺寸下每张
        /// 卡片宽度都不一样，同一张 `ProviderCardView` 在不同 provider 之间换行
        /// 位置会跳。固定宽度才和菜单那一屏看起来是同一个东西。
        @ViewBuilder
        func card() -> some View {
            ProviderCardView(status: status)
                .frame(width: cardContentWidth)
                .padding(backdrop)
                .edgeDockPopoverSystemMaterialBackground()
        }

        hosting.rootView = AnyView(popoverContent(card()))
        hosting.layoutSubtreeIfNeeded()

        let natural = hosting.fittingSize
        let heightCap = max(visibleFrame.height * EdgeDockGeometry.popoverHeightFraction, 160)
        let height = min(max(natural.height, 120), heightCap)

        // 装不下才套 ScrollView：卡片比屏幕还高时滚动，否则内容会被直接截断。
        if natural.height > heightCap {
            hosting.rootView = AnyView(
                popoverContent(
                    ScrollView {
                        card()
                    }
                    .frame(width: width, height: height)
                )
            )
        }

        let targetFrame = EdgeDockGeometry.popoverFrame(
            size: CGSize(width: width, height: height),
            dockFrame: panel.frame,
            rowIndex: index,
            edge: config.edge,
            visibleFrame: visibleFrame
        )

        popover.setFrame(targetFrame, display: true)
        hosting.layoutSubtreeIfNeeded()
        popover.orderFrontRegardless()
    }

    /// 收起详情窗。
    private func hidePopover() {
        popoverPanel?.orderOut(nil)
    }

    /// popover 内容**跟随系统外观** + 折叠区常展。
    ///
    /// 和 dock 的**固定暗色**是刻意的对照，不是漏配：dock 常驻屏幕边缘，跟菜单栏
    /// 一起长在桌面上；popover 是用户点出来的临时浮层，按"和菜单弹出的一样"来做，
    /// 所以它跟随系统，和菜单那一屏同进同出。
    ///
    /// 面板侧不设 `appearance`、这里也不覆盖 `colorScheme`：两者必须一致，只改
    /// SwiftUI 的 `colorScheme` 不会让**材质本身**跟着变（`ultraThinMaterial` /
    /// `glassEffect` 按面板外观解析），结果是"内容按浅色画、底板按深色画"——
    /// 比不改更糟。
    ///
    /// `hoverRevealMode = .alwaysVisible`：这个浮层本身就是"鼠标悬停在某个圆上"
    /// 才出现的详情，**靠鼠标移开来收起**而不是靠移出某个区域。里面再藏一层
    /// "悬停才展开"等于要求一个正在被移开的窗口被悬停 —— 那些 section 永远
    /// 展不开，等于整段信息静默丢失。
    private func popoverContent<C: View>(_ content: C) -> some View {
        content
            .environment(\.hoverRevealMode, .alwaysVisible)
    }

    private func ensurePopoverPanel() -> (NSPanel, NSHostingView<AnyView>) {
        if let popoverPanel, let popoverHostingView {
            return (popoverPanel, popoverHostingView)
        }

        let popover = NSPanel(
            contentRect: .init(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        popover.isFloatingPanel = true
        // 比 dock 再高一级，popover 才不会被 dock 自己压住。
        popover.level = .popUpMenu
        popover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        popover.hidesOnDeactivate = false
        popover.isOpaque = false
        // 同 dock：背板来自 SwiftUI，窗口保持透明。玻璃要采样窗口背后的桌面，
        // 这里一旦改成不透明，磨砂会直接退化成一块死板的灰。
        popover.hasShadow = false
        popover.backgroundColor = .clear
        // **不设** appearance：材质按系统外观解析，和菜单弹出保持一致。dock 那边
        // 是相反的（钉 vibrantDark + 强制 dark colorScheme），两者刻意不同——dock
        // 常驻，popover 跟菜单走。
        popover.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        popover.contentView = hosting

        popoverPanel = popover
        popoverHostingView = hosting
        return (popover, hosting)
    }

    /// 接管后持续巡检：鼠标移出就交还。
    ///
    /// 这里只负责 **hover 巡检**。拖动**不走**这个定时器——它是 0.2s 的轮询周期，
    /// 拿它驱动拖动会让窗口每 200ms 才挪一次（5fps），必须逐 `.leftMouseDragged`
    /// 事件驱动。保留拖拽调用只是兜底（正常情况下事件已经驱动过了）。
    private func startCaptureTimer() {
        captureTimer?.invalidate()
        let timer = Timer(timeInterval: Self.capturePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMouseCaptured else { return }
                self.probeMouse(at: NSEvent.mouseLocation)
                // 拖动兜底也必须过阈值门：直接 applyDrag 会把"按住没动"的点击
                // 每隔 0.2s 向鼠标位置吸附一次，点击手感就没了。
                if self.isDragging { self.dragMoved(at: NSEvent.mouseLocation) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    // MARK: - 拖拽：沿贴靠边滑动

    /// 拖拽中直接按鼠标位置驱动窗口 frame —— 不依赖 `isMovableByWindowBackground` 的
    /// 自由移动。自由移动会让窗口脱离屏幕边缘悬在半空，而用户想表达的只是
    /// "沿着边缘上下挪一挪"，所以垂直于边的方向一律钉死在边缘。
    ///
    /// 由 `.leftMouseDragged` 逐事件调用（见 `handleMouseEvent`），不是定时轮询。
    private func applyDrag(at mouse: CGPoint) {
        guard let panel else { return }
        let visibleFrame = Self.targetScreen.visibleFrame

        // 鼠标明显更靠近另一条边时才换边（带 margin，避免角落来回闪）。
        let edge = EdgeDockGeometry.edgeAfterDrag(
            mouse: mouse, currentEdge: config.edge, visibleFrame: visibleFrame
        )
        config.edge = edge

        let size = EdgeDockGeometry.dockSize(
            entryCount: dragEntryCount,
            edge: edge,
            appearance: isCompactAppearance ? .compact : .full
        )
        config.offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: mouse, dockSize: size, visibleFrame: visibleFrame, edge: edge
        )
        // `display: false`：不在每个事件里强制同步重绘。拖动由窗口服务器合成，
        // 同步重绘只会把主线程打满，反而更卡。
        panel.setFrame(
            EdgeDockGeometry.frame(
                visibleFrame: visibleFrame, edge: edge, size: size, offset: config.offset
            ),
            display: false
        )
    }

    private func persistPosition() {
        guard let configStore else { return }
        let current = configStore.config
        // 与默认完全一致时写 nil，保持 config.json 干净（与 statusBar* 字段同一约定）。
        guard current.edgeDock != config else { return }
        var updated = current
        updated.edgeDock = config
        do {
            try configStore.applyAndSave(updated)
        } catch {
            logError("EdgeDock: 保存位置失败 \(error.localizedDescription)")
        }
    }

    // MARK: - 全屏门控

    /// 全屏是否**应该**让 dock 消失。探测结果（`isFullscreenSpace`）是事实，
    /// 策略本身在 `EdgeDockConfig.hidesInFullscreen` 上（可单测）。
    ///
    /// 单独拎出来而不是在四个 guard 里各写一次：多写一次不会编译报错，只会让
    /// 某一处（比如 popover 的显示判断）漏掉这个开关，表现是"dock 在全屏里还
    /// 开着、点开详情却什么都没有"。
    private var isHiddenByFullscreen: Bool {
        config.hidesInFullscreen(isFullscreenSpace: isFullscreenSpace)
    }

    /// Space 切换后**阶梯式**补测全屏，各档延迟。
    ///
    /// 单次补测不够，因为"进/出全屏"和"滑动 Space"是两种时长完全不同的过渡：
    ///
    /// - 滑动 Space：瞬时，0.25s 后就稳定了
    /// - 进/出全屏：约 1s 的窗口动画。0.25s 时窗口还在**长大**，`covers()`
    ///   读到的中间态盖不满整屏 → 判成"没全屏"
    ///
    /// 而 `evaluateFullscreen` 对"值没变"是直接 return 的，也就是**一次读错就被
    /// 永久缓存**，直到下一次无关事件才可能纠正。这正是实测症状的成因：
    /// 浏览器刚进全屏时 dock 留着（0.25s 读到动画中间态），等关掉另一个全屏
    /// 窗口再滑回来反而正常（滑动没有动画，0.25s 足够）。
    ///
    /// 阶梯覆盖到 2.8s，够任何真实过渡走完。重复执行无害——判定本身幂等，
    /// 只有真正翻转时才 reconcile。成本是每次 Space 切换多 5 次窗口列表读取。
    private static let fullscreenRetryLadder: [TimeInterval] = [0.25, 0.6, 1.1, 1.8, 2.8]

    private func scheduleFullscreenRechecks() {
        cancelFullscreenRechecks()
        fullscreenRetryWorkItems = Self.fullscreenRetryLadder.map { delay in
            let work = DispatchWorkItem { [weak self] in
                self?.evaluateFullscreen()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func cancelFullscreenRechecks() {
        fullscreenRetryWorkItems.forEach { $0.cancel() }
        fullscreenRetryWorkItems.removeAll()
    }

    private func evaluateFullscreen() {
        guard config.enabled else {
            isFullscreenSpace = false
            reconcile(animated: false)
            return
        }
        // fail-open：探测失败返回 false，窗口照常显示。
        //
        // 判据问的是"当前 Space 上有没有铺满整屏的窗口"，不是"前台 App 有没有"——
        // 滑动 Space 不触发 App 激活，按前台过滤会漏判出非前台 App 的全屏 Space。
        let fullscreen = FullscreenProbe.isAnyFullscreenWindow(
            on: Self.targetScreen,
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        guard fullscreen != isFullscreenSpace else { return }
        isFullscreenSpace = fullscreen
        logInfo(fullscreen
            ? (config.hideInFullscreen
                ? "EdgeDock: 检测到全屏，隐藏"
                : "EdgeDock: 检测到全屏（已关闭全屏隐藏，继续显示）")
            : "EdgeDock: 退出全屏，恢复显示")
        reconcile(animated: false)
    }
}
