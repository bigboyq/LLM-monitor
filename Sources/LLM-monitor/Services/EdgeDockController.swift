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
/// 2. **悬停与接管**：`ignoresMouseEvents = true` 的窗口**收不到** tracking area 事件，
///    hover 只能由控制器自己问"鼠标在哪"——现在是 2Hz 轮询（见 `hoverPollInterval`
///    与 §Per-event budget 的那笔账），不是逐条 `mouseMoved`。`hoveredIndex`
///    （命中哪个圆）是唯一真值：dock 接管状态、圆的 hover 高亮、以及详情 popover
///    挂哪个圆全部由它驱动（`selectedIndex` 滞后于它一个 `hoverOpenDelay`，见
///    `scheduleSelection`）。拖拽仍然逐事件驱动，事件掩码只留它需要的那三个。
/// 3. **位置存比例**：见 `EdgeDockConfig.offset`。
///
/// 本文件只留状态、配置与接线；实现按职责拆在同名 extension 里：
/// `+Window`（窗口工程）、`+Mouse`（穿透与悬停接管）、`+HitTesting`（命中判定纯函数）、
/// `+Popover`（卡片浮层）、`+Drag`（沿边拖拽）、`+Fullscreen`（全屏门控）。
@MainActor
final class EdgeDockController: ObservableObject {
    static let shared = EdgeDockController()

    /// 鼠标进入窗口外扩这么多 pt 以内即接管（兼作离开容差）。
    ///
    /// 必须大于 popoverGap（10pt）的一半以上，dock 与卡片各自的容差区才能在
    /// 两者之间的缝隙里重叠，鼠标横向穿行时接管不中断；12pt 另外给"离开"留出
    /// 一点视觉余量——恰好擦着黑条边缘走时不会一跳一跳地收起。
    static let hoverPadding: CGFloat = 12
    /// 接管后的巡检间隔，兼作拖拽期间的松手检测。
    static let capturePollInterval: TimeInterval = 0.2

    /// 未接管时的 hover 轮询间隔（**2Hz**）。
    ///
    /// 指针在系统上动一下就把本进程唤醒一次，是这套交互里唯一压不掉的固定开销
    ///（100~1000Hz，而唤醒才是大头，不是探测本身）。hover 要回答的问题变化极慢——
    /// 只有指针位置变了才需要重判——所以它不必跟着事件频率走：2Hz 把唤醒次数压到
    /// 每秒 2 次，代价是 hover 最多晚 0.5s 生效（圆环高亮、详情卡片、靠近展开都以
    /// 0.5s 为上限到达）。
    ///
    /// 鼠标一旦进到 dock 附近，`captureMouse()` 会起 `capturePollInterval`（0.2s）
    /// 的巡检定时器，hover 延迟随之降到 0.2s——真正看得见的 0.5s 只发生在"指针
    /// 正在过来的那半秒"上。
    static let hoverPollInterval: TimeInterval = 0.5
    /// 按下后位移超过这么多 pt 才算拖动；以内松手视为"没拖动"，不做任何事
    /// （详情跟随 hover，按钮本身没有点击语义）。
    static let dragThreshold: CGFloat = 4
    /// 悬停某一行后延迟这么久才展开详情。dock 是**常驻**在屏幕边缘的，鼠标
    /// 朝边缘扫过去（拖东西到边上、翻页）会频繁路过它，即时展开就是一路闪卡片。
    /// 这一小段延迟把"路过"和"停下来看"分开。
    static let hoverOpenDelay: TimeInterval = 0.15
    /// 鼠标离开 provider 圆环后延迟这么久才收起详情；期间鼠标移入卡片或其它圆环则取消。
    static let hoverCloseDelay: TimeInterval = 0.20
    /// 鼠标离开保持区后延迟这么久才收起；期间鼠标回来则取消。误划过边缘
    /// （一次性往返）不该把 dock 收掉再长出来闪一遍。
    static let collapseDelay: TimeInterval = 0.5

    /// 完整↔简版的**形态过渡**时长。窗口 frame 的 AppKit 动画与内容的 SwiftUI
    /// 变形共用这个常量——两层必须同曲线同时长**同步**播放：窗口负责黑条与
    /// 位置（中心沿边连续移动），内容负责行 / 环的插值。任一层单独先行都会
    /// 露出破绽：只动画窗口 = 收起时缩掉的全是透明区域（瞬间跳变）；只动画
    /// 内容 = 窗口尺寸不变，结束后必须瞬移重定位（跳闪一下）。
    /// `nonisolated`：这个值被 SwiftUI/AppKit 的非隔离动画上下文读取（见
    /// `DockTransition.duration`），它本身是 Sendable 的纯常量，没有理由要求
    /// main actor。Swift 6 语言模式下少了它就是一个编译错误（audit 门禁会跑）。
    nonisolated static let contentMorphDuration: TimeInterval = 0.25

    /// 形态过渡的缓动控制点。**窗口与内容必须共用这一条曲线**（见 `DockTransition`
    /// 与 `EdgeDockContentView` 里的同名注释）。
    ///
    /// (0, 0, 0.58, 1) —— 也就是两个框架各自的 `easeOut`：
    /// `Animation.easeOut` 与 `CAMediaTimingFunction(name: .easeOut)` **本来就是同一条
    /// 曲线**（两边四个具名预设一一对应：linear 0/0/1/1、easeIn 0.42/0/1/1、
    /// easeOut 0/0/0.58/1、easeInEaseOut 0.42/0/0.58/1）。
    ///
    /// 那为什么还要抽成常量？因为"同曲线"此前只是**两个不同框架的同名预设碰巧一致**
    /// 这一个隐含事实：谁把其中一侧换成 `easeInOut`、或者哪个框架将来调整了预设
    /// 取值，代码里没有任何东西会反对，两层就静默错开。写成共用常量之后，"同一条
    /// 曲线"变成编译器能钉住的事实而不是默契。
    ///
    /// 顺带提醒：别把它写成 (0.42, 0, 0.58, 1)。那是 `easeInEaseOut`——起步慢得多
    /// （phase 0.15 处两条曲线差 0.25），会明显改变收起/展开的手感。
    nonisolated static let formMorphControlPoints = (x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    /// dock 窗口 frame 过渡的种类：决定动画时长与互斥规则。
    enum DockTransition {
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

    // ↓ 下面三个是 hover 发布的状态：读方是视图，写方是 `EdgeDockController+Mouse`
    //   的 hover 逻辑——它现住在兄弟 extension 文件里，setter 因此不能在模块外可见。
    //   逐字段再包一层 mutator 只会把同一件事写三遍。
    //   `config` 不在此列：它有写入纪律（变了才发布 / 运行时 vs 设置页），走
    //   `applyRuntimeConfig`。
    /// 当前 hover 到的圆下标；nil = 没有 hover 任何圆。
    ///
    /// 单一真值：视图里圆的 hover 高亮、鼠标是否保持接管、详情挂哪个圆，
    /// 读的都是这一个值。
    @Published var hoveredIndex: Int?

    /// 已展开详情的圆下标；nil = 没有展开的详情卡片。
    ///
    /// 悬停某个圆 = 展开它的卡片，移开鼠标 = 收起。**不再由点击驱动**：点击留着
    /// 只做拖动，按下即起候选、松手时位移不过阈值就当无事发生。
    ///
    /// 相比 `hoveredIndex` 滞后 `hoverOpenDelay`（竖着扫过一列圆时，每个圆都
    /// 重新计时，扫过去就不会依次展开又收起每张卡）；鼠标压在卡片上时维持原值
    /// 不变，那是同一张卡的延续。真正的清理由 `releaseMouseCapture` 在离开整个
    /// 保持区后统一做。
    @Published var selectedIndex: Int?

    /// 「状态窗（自动隐藏）」形态下是否处于**展开**形态。其余形态恒为 false 且
    /// 无意义（外观由 `isCompactAppearance` 统一推导）。
    ///
    /// true = 完整 dock（数值 + 品牌图标 + 双环，可逐行 hover）；
    /// false = 简版（只有 5h 单环小圆）。鼠标靠近展开、离开收起。
    @Published var isExpanded = false

    /// 窗口当前该用哪种外观：四种形态里只有一种会随鼠标变形。
    ///
    /// 唯一判定入口，`reconcile`（窗口尺寸）与视图（排版）都读它——两处若各写
    /// 各的判定，窗口尺寸和内容排版一旦不一致，圆环会被裁或留白。
    var isCompactAppearance: Bool {
        // 「状态窗」静置即完整；「状态窗（自动隐藏）」跟随展开态；其余两种恒为
        // 简版——`isExpanded` 对它们没有意义，不该读。
        if config.mode.staysFullWhenIdle { return false }
        if config.mode.expandsOnProximity { return !isExpanded }
        return true
    }

    weak var state: AppState?
    /// ConfigStore 由 App 的 `@StateObject` 持有到进程结束，这里强引用不会成环
    /// （ConfigStore 不反向引用本控制器）。
    var configStore: ConfigStore?

    var panel: NSPanel?
    var hostingView: NSHostingView<AnyView>?
    /// 悬停某个圆时在旁边展示的 provider 卡片 popover。与 dock 是**两个独立窗口**，
    /// dock 尺寸不因它改变。
    var popoverPanel: NSPanel?
    var popoverHostingView: NSHostingView<AnyView>?
    private var statusCancellable: AnyCancellable?
    private var evaluationCancellable: AnyCancellable?
    private var configCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    var globalMouseMonitor: Any?
    var localMouseMonitor: Any?
    var captureTimer: Timer?

    /// 实际生效配置。`@Published`：外观（完整/简版）由它派生，设置页换形态时
    /// 视图必须立即跟随，否则窗口缩了、内容排版还停在旧形态。
    @Published private(set) var config: EdgeDockConfig = .default
    var isFullscreenSpace = false
    var isDragging = false
    /// 拖拽开始时取一次的条目数，供逐事件的 `applyDrag` 复用。
    var dragEntryCount = 0
    /// 按下时的屏幕坐标与"是否已越过拖动阈值"。位移在阈值内松手 = 原地松开
    /// （保持当前悬停状态），越过阈值 = 真拖动（收起详情、移动窗口）。避免微小手抖
    /// 把 dock 拖走几像素。
    var pressScreenLocation: CGPoint?
    var pressBecameDrag = false
    /// 挂起中的延时收起任务。鼠标离开保持区时排入，0.5s 后触发；期间鼠标回来
    /// 或状态变化（拖动 / 隐藏 / 释放接管）则取消。是**固定 deadline** 而不是
    /// 防抖：巡检定时器每 0.2s 会重复走"还在外面"的分支，防抖式重排会让
    /// deadline 永远被推后、收起永不发生。
    /// Space 切换后阶梯式补测全屏的挂起任务。见 `scheduleFullscreenRechecks`。
    var fullscreenRetryWorkItems: [DispatchWorkItem] = []
    var collapseWorkItem: DispatchWorkItem?
    /// 挂起的「展开某行详情」任务，见 `scheduleSelection`。
    var pendingSelectionWorkItem: DispatchWorkItem?
    /// 挂起的「收起详情」任务，见 `scheduleDeselection`。
    var pendingDeselectionWorkItem: DispatchWorkItem?
    /// 形态过渡进行中标记 + 到期解除任务：期间标准过渡（刷新广播等）不得碰
    /// 窗口 frame——按动画中间态帧重算并 setFrame 会打断正在播放的窗口动画，
    /// 表现为半途抽一下。
    var formMorphGuardWorkItem: DispatchWorkItem?
    var isFormMorphInFlight = false
    /// dock 是否已接管鼠标（`ignoresMouseEvents == false`）。与 `hoveredIndex` 分开：
    /// 鼠标停在 popover 上时不需要再 hover 某个圆，但接管状态必须继续保持。
    var isMouseCaptured = false

    /// hover 探测的**轮询定时器**：只在 dock 可见期间存在（见 `startHoverPoll`）。
    var hoverPollTimer: Timer?


    /// 各 provider 外圈在**视图坐标系**（= NSHostingView）下的真实矩形，由 `EdgeDockContentView`
    /// 用 GeometryReader 逐项直报，键是 provider id。
    var measuredCircleRectsByID: [String: CGRect] = [:]
    /// 每一行在**视图坐标系**（= NSHostingView）下的真实矩形，由 `EdgeDockContentView`
    /// 用 GeometryReader **逐行直报**，键是 provider id。
    var measuredRowRectsByID: [String: CGRect] = [:]
    /// 本帧命中实际采用的来源，切换时写日志。
    var rowRectsSource: RowRectsSource = .geometry
    var circleRectsSource: RowRectsSource = .geometry

    enum RowRectsSource: String {
        case measured = "实测"
        case geometry = "几何兜底"
    }
    /// 上一次的显隐判定签名，用于只在"为什么没出现 / 出现在哪"变化时写日志。
    var lastVisibilitySignature = ""

    /// 进程级事实：`applicationDidFinishLaunching` 是否已经发过。`teardown()` 不复位
    /// ——它是**进程**的事实，不是本控制器的接线状态；重新 `attach` 时若 launch 早已
    /// 发生，直接进入可用态而不是再等一个永不到来的通知。
    private static var appDidFinishLaunching = false
    /// 实例侧的镜像，供 `reconcile` 的门禁读。
    var hasFinishedLaunching = false
    /// 拖拽过程中的临时位置。**不进 `config`**（理由见 `applyDrag`）。
    var dragOffset: Double?

    private init() {}

    /// 运行时改配置的**唯一**入口。`config` 的 setter 保持 `private`：换边、换屏、
    /// 记住位置都是用户刚刚拖出来的结果，语义上与设置页改配置不是一回事，不该由
    /// 模块里任意调用方随手写。调用点在 `EdgeDockController+Drag` / `+Mouse`。
    ///
    /// 「变了才发布」的守卫刻意留在调用侧而不是塞进这里：`edge` 必须逐事件跟进，
    /// 而 `@Published` 无条件赋值等于每帧让整个 dock 视图重算一遍——那是各调用点
    /// 自己的时序决策，不该由一个通用 mutator 替所有人做主。
    func applyRuntimeConfig(_ mutate: (inout EdgeDockConfig) -> Void) {
        mutate(&config)
    }

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
                let modeChanged = next.mode != self.config.mode
                let fullscreenPolicyChanged = next.hideInFullscreen != self.config.hideInFullscreen
                let wasCompact = self.isCompactAppearance
                self.config = next
                // 形态翻转时清掉缓存的全屏判定：重新显示要从"当前不在全屏"开始，
                // 否则会拿退出全屏时的旧状态直接判隐藏。
                if modeChanged { self.isFullscreenSpace = false }
                // 形态翻转时回到收起形态（「状态窗」则恢复常驻完整 dock）。
                // 只在翻转时复位：拖拽落点也会走一次持久化广播，鼠标正悬停时
                // 不该因此闪一次收起。
                if modeChanged { self.isExpanded = false }
                // 形态变了就是一次**形态过渡**：窗口 frame 与内容变形必须同曲线同时长
                // （`.standard` 的 0.18s 对不上内容的 0.25s 变形，中间会出现"圆已经
                // 缩成小环、窗口还在缩"的错位帧）。方向按新形态判定；形态没变
                // （例如只翻了全屏隐藏、或只拖了位置）走标准过渡。
                let formTransition: DockTransition = (wasCompact == self.isCompactAppearance)
                    ? .standard
                    : (self.isCompactAppearance ? .collapse : .expand)
                self.reconcile(animated: true, transition: formTransition)
                // 全屏隐藏开关翻转也必须重新探测：用户很可能**正在全屏里**改这个
                // 设置。少了这次探测就会拿一个可能已经过期的 `isFullscreenSpace`
                // 去套新策略——表现是"开关拨了没反应，要退出全屏再来一次"。
                if modeChanged || fullscreenPolicyChanged {
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
                // 拔屏要先清记忆：否则缓存里留着已经不存在的 display id，
                // `targetScreen` 拿它去匹配会一直失败（虽然结果碰巧也是"找不到"，
                // 但留着就是随时会骗人的状态）。
                EdgeDockDisplay.pruneCache(to: NSScreen.screens)
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

        // **窗口不能在 `applicationDidFinishLaunching` 之前建**：`attach` 跑在
        // `LLMMonitorApp.init()` 里，那早于 launch，此时 window server 还不接受本
        // 进程的窗口，位置与 Space 归属都不可靠。
        //
        // 注意真正拦住建窗的门禁在 `reconcile`（`hasFinishedLaunching`），不只是这里：
        // 状态广播、配置保存、屏幕参数变化在 launch 之前同样可能各触发一次 reconcile，
        // 只把这一次推迟并不够。
        //
        // 上面那些订阅照常接线——它们只是登记，`reconcile` 是幂等的，首次真正执行时
        // 会读到那一刻的最新状态。
        hasFinishedLaunching = Self.appDidFinishLaunching
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Self.appDidFinishLaunching = true
                self.hasFinishedLaunching = true
                // 先判一次全屏再 reconcile：判定为全屏时它自己会走一次
                // `reconcile(animated: false)`，窗口直接以隐藏状态创建；反过来先
                // reconcile 就会先显示、再隐藏，闪一下。attach 之前用户可能就已经待在
                // 全屏 Space 里，而那条路径上不会有任何 Space 切换 / App 激活通知。
                self.evaluateFullscreen()
                self.reconcile(animated: false)
            }
        }
        if hasFinishedLaunching {
            // 重新接线且 launch 早已发生：通知不会再补发，直接补上首次执行。
            evaluateFullscreen()
            reconcile(animated: false)
        }
    }

    func teardown() {
        stopHoverPoll()
        cancelPendingCollapse()
        cancelPendingSelection()
        cancelPendingDeselection()
        cancelFullscreenRechecks()
        cancelFormMorphGuard()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        captureTimer?.invalidate()
        captureTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil
        launchObserver = nil
        activationObserver = nil
        spaceObserver = nil
        statusCancellable?.cancel()
        evaluationCancellable?.cancel()
        // 三个订阅缺一不可：漏掉 `configCancellable` 会让"卸载后 config 又变了"
        // 继续驱动一次 reconcile，而此时订阅者本该已经没了。
        configCancellable?.cancel()
        statusCancellable = nil
        evaluationCancellable = nil
        configCancellable = nil
        hidePopover()
        panel?.orderOut(nil)
        // 断开 `controller → hostingView → rootView → controller` 这个环。单例进程
        // 生命周期下它无害，但 teardown 的语义是"回到没接线的状态"，留着引用就不是。
        popoverPanel?.orderOut(nil)
        popoverPanel = nil
        popoverHostingView = nil
        panel = nil
        hostingView = nil
        // 接管标记也必须复位：`captureMouse()` 的入口是 `!isMouseCaptured`，
        // 留着 true 的话，之后重建出来的面板（`ensurePanel` 一律以
        // `ignoresMouseEvents = true` 新建）**永远接管不了鼠标**——hover 退化成
        // 0.5s 轮询能看，但 0.2s 的接管巡检与拖拽判定都不会再启动。
        isMouseCaptured = false
        // 拖拽/悬停状态同理，全部复位：`reconcile` 在 `guard !isDragging` 处就返回，
        // 一次"拖到一半 teardown"会让 dock 从此再也无法布局，而它是 `teardown`
        // 声称要做到的事（回到没接线的状态）之一。`pressScreenLocation` /
        // `pressBecameDrag` / `dragEntryCount` 一并清掉，免得下一次按下沿用半途的值。
        isDragging = false
        pressScreenLocation = nil
        pressBecameDrag = false
        dragEntryCount = 0
        dragOffset = nil
        isExpanded = false
        hoveredIndex = nil
        selectedIndex = nil
        // 实测矩形同样作废：它们描述的是**旧**那个 hosting view 的布局，
        // 换宿主后坐标系不再成立。留着会被 `resolveRowRects` 的"整列落在窗口内吗"
        // 自检挡掉、退回几何兜底，但那是靠一次错误命中才纠正，不如直接清掉。
        measuredRowRectsByID.removeAll()
        measuredCircleRectsByID.removeAll()
    }

}
