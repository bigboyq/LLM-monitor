import AppKit
import Combine
import SwiftUI

/// 边缘状态窗的窗口工程：从 `EdgeDockController` 拆出。
///
/// 建/拆 `NSPanel`、按条目数与形态算窗口尺寸、把 dock 贴到目标屏那一侧，以及
/// "为什么没出现 / 出现在哪"的日志签名。只碰窗口，不碰输入。
extension EdgeDockController {
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
    func orderedEntries() -> [EdgeDockEntry] {
        guard let state else { return [] }
        return EdgeDockProjection.entries(
            from: state.statuses,
            preferredIDs: configStore?.config.providerCardOrder
        )
    }

    /// 唯一的布局/显隐收口：算条目 → 决定显隐 → 定尺寸 → 贴边 → 排序。
    func reconcile(animated: Bool, transition: DockTransition = .standard) {
        // launch 之前一律不建窗（见 `attach` 里的说明）：`ensurePanel` 会把一个
        // NSPanel 交给 window server，那在 `applicationDidFinishLaunching` 之前
        // 位置与 Space 归属都不可靠。
        guard hasFinishedLaunching, state != nil else { return }

        // 配置指定的屏已经不在了（拔线 / 换机器）→ 先把配置改写成"没指定"，
        // 否则它会一直指向一块不存在的屏，每次启动都算错一次、dock 落在没人
        // 看得到的地方。必须在取 `targetScreen` **之前**：本次 reconcile 就要
        // 用回落后的屏定位。
        dropScreenUUIDIfVanished()

        let entries = orderedEntries()
        let entryCount = entries.count
        // 选中项按 **id** 跟着 provider 走，而不是钉在下标上：用户在设置页改了顺序，
        // 下标会指向另一个 provider，已经展开的卡片就会无声地换成别人的。
        //
        // `resolvedIndex` 把"下标还在范围内吗"和"取它"合成一次判断：写成两个独立
        // 表达式就必须靠 `!` 去断言前面那个 guard，拆开时编译器帮不上忙。
        let resolvedIndex = selectedIndex.flatMap { entries.indices.contains($0) ? $0 : nil }
        let selectedID = resolvedIndex.map { entries[$0].id }
        // 只在真的变了才写回——`@Published` 每次赋值都会广播，而 reconcile 每次
        // 状态广播都跑，无条件赋值等于每 provider 一次无谓的视图刷新。
        //
        // 下面两个"钉住的对象没了"的分支**清完下标必须让浮层真正消失**：
        // `selectedIndex` 只是"该显示谁的卡"这一个真值，清它并不会让 popover 面板
        // 收起来——`orderOut` 只在 `updatePopover()` / `hidePopover()` 里发生。而
        // 这两条分支后面走的是 `entryCount > 0` 的**可见**路径，既不会经过隐藏分支
        // 里的 `releaseMouseCapture()`，也不会走到快路径的 `if selectedIndex != nil`
        // （刚清完，已经是 nil）。只清下标的结果是：面板留在屏幕上显示一个已经不
        // 在 `entries` 里的 provider，而且**不会自愈**——`probeMouse` 只在
        // `selectedIndex != nil` 时才排收起任务，nil 之后谁也不再碰它。
        if let selectedID {
            let reanchored = entries.firstIndex(where: { $0.id == selectedID })
            if selectedIndex != reanchored { selectedIndex = reanchored }
        } else if selectedIndex != nil, entryCount == 0 {
            // 条目全没了（provider 停用/删除）→ 钉住的卡片没有对象，直接收起。
            selectedIndex = nil
            updatePopover()
        } else if let stale = selectedIndex, stale >= entryCount {
            // 条目**变少**了（下标还指向已被停用的 provider）：按 id 已经救不回来——
            // 那个 provider 根本不在 `entries` 里。留着这个越界下标会让
            // `updatePopover` 每次都白跑一遍 `orderedEntries()` 才在边界判断里退出。
            selectedIndex = nil
            // 顺带把悬停高亮也放掉：它同样按 id 锚定，provider 一走就无处可指。
            if hoveredIndex == stale { hoveredIndex = nil }
            updatePopover()
        }

        // 形态选了「无」、前台 App 全屏、或一个 provider 都没开监控 → 不出现。
        // 挂一个空壳在屏幕边缘只会让人以为程序坏了。
        guard config.mode.isVisible, !isHiddenByFullscreen, entryCount > 0 else {
            logVisibilityChange(
                mode: config.mode,
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
            // 用可选链而不是 ensurePanel()：形态为「无」时**完全不创建窗口**。
            // attach 跑在 LLMMonitorApp.init() 里，那早于 applicationDidFinishLaunching，
            // 不该在那之前就往 window server 塞一个窗口。
            panel?.orderOut(nil)
            // 不显示就不必再问"鼠标在哪"：轮询是这条链路上唯一的常驻开销。
            stopHoverPoll()
            return
        }

        // 到这里才真的需要窗口了。
        ensurePanel()
        guard let panel else { return }

        // dock 尺寸只跟条目数和外观有关 —— hover 弹出的是旁边那个独立 popover，
        // dock 本体不参与展开（「状态窗（自动隐藏）」的收起/展开除外，那是窗口自身的形态）。
        // 拖拽中不跟几何计算抢控制权，否则窗口会跟手抽搐。
        //
        // 放在算 `target` **之前**还有第二个理由：拖拽期间 `config.offset` 还没写回
        // （那要等松手，见 `finishPressOrDrag`），此刻拿它算出来的 `target` 是拖拽
        // **之前**的位置——即使后面不再用它，也不该让一个明知是错的帧存在于这条路径上。
        guard !isDragging else { return }

        let edge = config.edge
        let size = EdgeDockGeometry.dockSize(
            entryCount: entryCount,
            edge: edge,
            appearance: isCompactAppearance ? .compact : .full,
            compactSize: config.compactSize
        )

        let target = EdgeDockGeometry.frame(
            visibleFrame: Self.targetScreen.visibleFrame,
            edge: edge,
            size: size,
            offset: config.offset
        )

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
            // 曲线取 `formMorphControlPoints`——与内容侧那层同一个常量，不是
            // 各写各的"easeOut"（那两条贝塞尔并不相同）。
            let cp = Self.formMorphControlPoints
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = transition.duration
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints: Float(cp.x1), Float(cp.y1), Float(cp.x2), Float(cp.y2)
                )
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
        startHoverPoll()

        logVisibilityChange(
            mode: config.mode,
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
        mode: EdgeDockMode,
        entryCount: Int,
        fullscreen: Bool,
        shown: Bool,
        frame: CGRect
    ) {
        let signature = "\(mode.rawValue)|\(entryCount)|\(fullscreen)|\(shown)|\(frame.origin.x.rounded())|\(frame.origin.y.rounded())"
        guard signature != lastVisibilitySignature else { return }
        lastVisibilitySignature = signature

        if shown {
            logInfo("EdgeDock: 显示 \(entryCount) 个圆 形态=\(mode.rawValue) edge=\(config.edge.rawValue) frame=\(Self.describe(frame))")
        } else {
            let reason = !mode.isVisible ? "形态为「无」" : (entryCount == 0 ? "没有已启用的 Provider" : "前台 App 全屏")
            logInfo("EdgeDock: 隐藏（\(reason)）形态=\(mode.rawValue) entries=\(entryCount) fullscreen=\(fullscreen)")
        }
    }

    static func describe(_ index: Int?) -> String {
        index.map { "第\($0 + 1)行" } ?? "无"
    }

    static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    /// dock 的"主场"屏，按三层解析，顺序即优先级（见 `spec/ui-design.md`）。
    ///
    /// 1. **`config.screenUUID`** —— 用户把 dock 停靠的那块屏。**这是上副屏的唯一
    ///    路径**：不加这一层，拖到副屏的位置虽然会被存进 `config.screenUUID`，却
    ///    永远没有人读它，下次启动照样落回主屏（`EdgeDockDisplay.matchingScreen`
    ///    就是为这一层写的，之前只有测试在调）。
    /// 2. **窗口当前所在屏** —— 换屏 / 改分辨率 / 改排列之后 AppKit 会换掉
    ///    `NSScreen` 对象，拿着一个已经不属于任何显示器的对象算 `visibleFrame`，
    ///    dock 会停到看不见的地方，所以这里按 **display id** 复核它是否仍在线。
    ///    不能无条件用 `NSScreen.main`：它跟随键盘焦点，多显示器下用户在另一块屏
    ///    上点一下任何窗口，dock 就会整个跳过去，看起来就是位置随机漂移。
    /// 3. **主屏 → 第一块屏** —— 启动、还没有任何窗口时的兜底。
    ///
    /// **一块屏都没有时**（无头 / 显示器被全部拔出这类瞬态）**不再对空数组取
    /// `[0]`**——旧写法在"空数组"分支里对同一份空数组下标，必然越界。改为回落到
    /// 上一次成功解析到的屏：dock 会停在拔屏前的那块屏的几何上而不是跳到
    /// 屏幕原点；进程启动以来一块屏都没见过时才退到一个零尺寸的 `NSScreen()`
    /// 兜底（与 `MenuWindowAlignment.effectiveScreen` 的末位兜底同一形状，不引入
    /// 新的强制解包）。
    static var targetScreen: NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return lastKnownScreen ?? NSScreen.main ?? NSScreen()
        }

        let resolved: NSScreen
        if let uuid = shared.config.screenUUID,
           let configured = EdgeDockDisplay.matchingScreen(preferred: uuid, screens: screens) {
            resolved = configured
        } else if let current = shared.panel?.screen ?? shared.popoverPanel?.screen,
                  isStillAttached(current, among: screens) {
            resolved = current
        } else {
            resolved = NSScreen.main ?? screens.first ?? screens[0]
        }
        lastKnownScreen = resolved
        return resolved
    }

    /// 最近一次成功解析到的屏。仅在"系统当前一块屏都没有"时作为兜底被读到，
    /// 写入点只有 `targetScreen` 本身。
    private static var lastKnownScreen: NSScreen?

    /// 这块屏是否还挂在当前系统上（按 display id 比，不用对象相等）。
    private static func isStillAttached(_ screen: NSScreen, among screens: [NSScreen]) -> Bool {
        guard let id = EdgeDockDisplay.displayID(of: screen) else { return false }
        return screens.contains { EdgeDockDisplay.displayID(of: $0) == id }
    }
}
