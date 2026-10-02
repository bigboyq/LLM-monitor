import AppKit

/// 边缘状态窗的鼠标穿透与悬停接管：从 `EdgeDockController` 拆出。
///
/// `ignoresMouseEvents = true` 的窗口收不到 tracking area 事件，hover 只能由控制器
/// 自己问"鼠标在哪"（2Hz 轮询）；"指中了哪个圆"在 `EdgeDockController+HitTesting`。
/// 这里管的是：装卸全局与本地 monitor、轮询节拍、命中后的接管与释放，以及
/// hover / 展开 / 收起这几个互相取消的挂起任务。
extension EdgeDockController {
    // MARK: - 鼠标穿透 / 悬停接管

    func installMouseMonitors() {
        guard globalMouseMonitor == nil else { return }

        // **只监听拖拽的三个事件，不监听 `.mouseMoved`**：全局 mouseMoved 钩子真正
        // 的代价不是探测本身，而是"指针在系统上动一下，本进程就被唤醒一次"——移动
        // 时 100~1000Hz，唤醒才是大头。hover / 靠近展开 / 收起现在一律由 2Hz 的
        // `hoverPollTimer` 读 `NSEvent.mouseLocation` 回答；事件通知只留拖拽真正需要
        // 的部分（逐事件驱动，延迟必须是 0，不能进轮询）。
        //
        // ignoresMouseEvents = true 的窗口收不到 tracking area 事件，所以"按下/拖动
        // 落在 dock 上"这一路只能靠系统级监听。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseEvent(event.type) }
        }

        // 本 app 在前台或命中本应用面板时的事件监听。
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
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
                // 按下即作废挂起的收起与选择：拖拽期间收起毫无意义，且释放接管会打断
                // 正在进行的事件序列。形态过渡守卫一并解除，拖拽自己接管 frame。
                cancelPendingCollapse()
                cancelPendingSelection()
                cancelPendingDeselection()
                cancelFormMorphGuard()
                // 条目数在拖拽开始时取一次：拖动事件是 60~120Hz，而重新投影要走一遍
                // 全部 provider 的额度聚合，没必要每帧重来。
                dragEntryCount = orderedEntries().count
                pressScreenLocation = NSEvent.mouseLocation
                pressBecameDrag = false
                // 上一段拖拽的临时位置不能带进这一次：没越过阈值就松手时
                // `finishPressOrDrag` 会直接返回，留着就会写回一个陈旧的 offset。
                dragOffset = nil
            }
        case .leftMouseUp:
            finishPressOrDrag(at: NSEvent.mouseLocation)
        case .leftMouseDragged:
            dragMoved(at: NSEvent.mouseLocation)
        default:
            // `.mouseMoved` 已不在监听掩码里（见 `installMouseMonitors`）：hover 走
            // 轮询。这里留一个空分支而不是删掉 `default`，是为了将来若恢复事件驱动，
            // 落到明确的 no-op，而不是一个"看起来在处理、其实没人发"的分支。
            break
        }
    }

    /// hover 探测的轮询：**dock 可见期间**每 `hoverPollInterval` 问一次
    /// 「鼠标在哪、命中哪个圆、要不要接管」。
    ///
    /// 幂等启动：显示分支每次 `reconcile` 都会调它，而定时器只需要一份。
    func startHoverPoll() {
        guard hoverPollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.hoverPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.probeMouse(at: NSEvent.mouseLocation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
        // 立刻探一次：刚显示出来的窗口不该再等半秒才认人。
        probeMouse(at: NSEvent.mouseLocation)
    }

    func stopHoverPoll() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    /// 拖动事件 / 巡检定时器共用的移动入口：先过"点击 vs 拖动"阈值。
    ///
    /// 阈值之内的抖动既不移动窗口也不收详情——否则每次点击 dock 都会先被拖歪
    /// 1~2pt 再弹回。越过阈值那一刻判定为真拖动：详情卡片没有跟着 dock 跑的
    /// 意义，立即收起。
    ///
    /// 只跟从「在 dock 上按下」的那次拖动（`guard isDragging`）。global monitor
    /// 会收到所有其他 App 的拖动事件——在别的应用里拖窗口、划选文本、拖滑杆，
    /// 无条件跟随时任何一次拖动都会把 dock 瞬移到鼠标处，松手再 persistConfig
    /// 把漂移位置写进 config。mouseDown 落在 dock 上时 local / global 两个
    /// monitor 必有一个先见到（接管中走 local，穿透时走 global）。
    func dragMoved(at mouse: CGPoint) {
        guard isDragging else { return }
        if !pressBecameDrag, let start = pressScreenLocation {
            guard hypot(mouse.x - start.x, mouse.y - start.y) >= Self.dragThreshold else { return }
            pressBecameDrag = true
            cancelPendingSelection()
            cancelPendingDeselection()
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
        cancelPendingDeselection()
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

    func cancelPendingSelection() {
        pendingSelectionWorkItem?.cancel()
        pendingSelectionWorkItem = nil
    }

    /// 鼠标离开 provider 圆环后延迟收起详情（经 `hoverCloseDelay`）。
    /// 如果鼠标是在移向卡片，期间进入卡片区域即取消该任务；如果停在留白处，到点收起。
    private func scheduleDeselection() {
        guard pendingDeselectionWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.selectedIndex != nil, self.hoveredIndex == nil else { return }
                self.selectedIndex = nil
                self.updatePopover()
            }
        }
        pendingDeselectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCloseDelay, execute: work)
    }

    func cancelPendingDeselection() {
        pendingDeselectionWorkItem?.cancel()
        pendingDeselectionWorkItem = nil
    }

    /// 松手的统一收尾：有位移 = 拖动（吸附 + 记住位置），无位移 = 保持现状（悬停模式由鼠标位置驱动）。
    private func finishPressOrDrag(at mouse: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        // 无论是否越过阈值都要清干净：阈值内松手时不该把上一次拖拽留下的偏移
        // 写进 `config`。
        guard pressBecameDrag, let offset = dragOffset else {
            dragOffset = nil
            return
        }
        dragOffset = nil
        applyRuntimeConfig { $0.offset = offset }
        reconcile(animated: true)
        persistConfig()
    }

    /// 每帧巡检鼠标：决定命中哪个圆、要不要接管、popover 挂在哪。
    func probeMouse(at mouse: CGPoint) {
        guard let panel = self.panel,
              config.mode.isVisible, !isHiddenByFullscreen, !isDragging else { return }

        let inDock = panel.frame.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding).contains(mouse)
        // 卡片**不可见时不参与判定**：`orderOut` 只把窗口藏起来，frame 还留在
        // 上次出现的位置——不过滤 `isVisible` 的话，卡片曾经占据（现在已消失）
        // 的那块屏幕会一直算作"保持接管区"：鼠标路过就莫名保活，自动隐藏的
        // 收起判定跟着失真，看起来像给一张看不见的卡片预留了空间。
        let inPopover = popoverPanel.map {
            $0.isVisible
                && $0.frame.insetBy(dx: -Self.hoverPadding, dy: -Self.hoverPadding).contains(mouse)
        } ?? false

        // 「状态窗（自动隐藏）」的收起形态：靠近即整体展开，不做逐行 hover——
        // 简版的圆只有 7pt，逐行命中在这个尺寸下只会抖；"dock 长出来"本身就是
        // 对这个靠近动作的回应。逐行 hover（高亮 + 详情）都只在展开形态里发生。
        //
        // 「小圆环」形态**不**走这条：它常驻简版、永远不展开，但仍然逐行 hover
        // 弹详情（落下去共用下面的通用命中路径即可）——展开与否是形态的差别，
        // 能不能看某个 provider 的详情不是。
        if isCompactAppearance, config.mode.expandsOnProximity {
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

        // 仅在 hover provider 外圈及内部区域时才命中（其他空白、数值标签等区域不命中）。
        //
        // 圆矩形**只在进到 dock 附近时**才算，`orderedEntries()` 也一起挪进来：它要
        // 把全部 provider 重新投影一遍（每个 provider 两次额度聚合 + 一次健康度判定，
        // 实测 ≈37µs），而指针九成时间都在屏幕别处——这一轮探测里它同样会被原样丢掉。
        let circles: [CGRect]? = inDock
            ? resolvedCircleRects(entries: orderedEntries(), panelFrame: panel.frame)
            : nil
        // 简版的圆半径只有 3.5pt（小档），直接按圆判定等于要指到 7px 大的东西上；
        // 「小圆环」形态逐行 hover 要能用，判定半径取**半个行距**（刚好让相邻两个
        // 小环的判定区接上、在中点分界），命中哪个圆不再取决于手指有多稳。
        // 行距随档位变，所以下限也必须按当前档位取。
        let newIndex = circles.flatMap {
            Self.circleIndex(
                at: mouse,
                circles: $0,
                currentHovered: hoveredIndex,
                minimumRadius: isCompactAppearance
                    ? EdgeDockGeometry.compactRowStep(for: config.compactSize) / 2
                    : 0
            )
        }

        if newIndex != hoveredIndex {
            hoveredIndex = newIndex
            // `circles` 只在进 dock 时才算，"来源"（实测／几何兜底）也就只在那时
            // 有意义；离开的那次没有几何可报，只记命中变化。
            let source = circles.map { " circles=\($0.count) 来源=\(circleRectsSource.rawValue)" } ?? ""
            logInfo("EdgeDock: hover -> \(Self.describe(newIndex))" + source)
        }

        // 仅在 hover provider 外圈以及内部区域时才触发详情展示：
        // - 鼠标停留在卡片上（inPopover == true）：保持当前卡片展示不抽走；
        // - 命中 provider 圆（newIndex != nil）：展开该 provider 详情（延迟 0.15s 防掠过闪烁）；
        // - 鼠标在 dock 内但未命中任何 provider 圆（如落在数值标签或留白处）：延时 0.20s 收起详情卡片。
        if inPopover {
            cancelPendingSelection()
            cancelPendingDeselection()
        } else if let newIndex {
            cancelPendingDeselection()
            if newIndex != selectedIndex {
                scheduleSelection(newIndex)
            }
        } else {
            cancelPendingSelection()
            if selectedIndex != nil {
                scheduleDeselection()
            }
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

    func cancelPendingCollapse() {
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

    /// 鼠标离开 dock 与 popover 之后，把「状态窗（自动隐藏）」收起回简版。
    ///
    /// 窗口与内容**同步**收回（同曲线同时长）：中心沿边连续移回简版位置、黑条
    /// 连续缩回边缘，结束后无需任何补摆。
    ///
    /// 不放进 `releaseMouseCapture`：那里还被 reconcile 的隐藏分支调用，若它再触发
    /// reconcile 会形成一次无意义的重入（隐藏条件不会变，但白跑一遍）。
    private func collapseExpandedDockIfNeeded() {
        guard isExpanded, config.mode.isVisible, !isHiddenByFullscreen, !isDragging else { return }
        isExpanded = false
        reconcile(animated: true, transition: .collapse)
    }

    /// 形态过渡期间拒绝标准过渡抢窗口 frame；动画结束后自动解除。
    func beginFormMorphGuard() {
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

    func cancelFormMorphGuard() {
        formMorphGuardWorkItem?.cancel()
        formMorphGuardWorkItem = nil
        isFormMorphInFlight = false
    }

    func updateMeasuredRowRect(id: String, rect: CGRect) {
        guard measuredRowRectsByID[id] != rect else { return }
        measuredRowRectsByID[id] = rect
    }

    func updateMeasuredCircleRect(id: String, rect: CGRect) {
        guard measuredCircleRectsByID[id] != rect else { return }
        measuredCircleRectsByID[id] = rect
    }

    /// 本帧用于命中的行矩形（屏幕坐标）：实测优先，不可用时退回几何推算。
    func resolvedRowRects(entries: [EdgeDockEntry], panelFrame: CGRect) -> [CGRect] {
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
            slack: Self.hoverPadding,
            appearance: isCompactAppearance ? .compact : .full,
            compactSize: config.compactSize
        )
        setRowRectsSource(resolved.usedMeasured ? .measured : .geometry)
        return resolved.rows
    }

    /// 本帧用于命中的 provider 圆矩形（屏幕坐标）：实测优先，不可用时退回几何推算。
    private func resolvedCircleRects(entries: [EdgeDockEntry], panelFrame: CGRect) -> [CGRect] {
        let onScreen: [String: CGRect]
        if let hostingView {
            onScreen = measuredCircleRectsByID.mapValues { convertToScreen($0, in: hostingView) }
        } else {
            onScreen = [:]
        }
        let resolved = Self.resolveCircleRects(
            entries: entries,
            measured: onScreen,
            panelFrame: panelFrame,
            edge: config.edge,
            slack: Self.hoverPadding,
            appearance: isCompactAppearance ? .compact : .full,
            compactSize: config.compactSize
        )
        setCircleRectsSource(resolved.usedMeasured ? .measured : .geometry)
        return resolved.circles
    }

    private func setRowRectsSource(_ source: RowRectsSource) {
        guard source != rowRectsSource else { return }
        rowRectsSource = source
        logInfo("EdgeDock: 命中来源 -> \(source.rawValue) measured=\(measuredRowRectsByID.count)")
    }

    private func setCircleRectsSource(_ source: RowRectsSource) {
        guard source != circleRectsSource else { return }
        circleRectsSource = source
        logInfo("EdgeDock: 圆形命中来源 -> \(source.rawValue) measured=\(measuredCircleRectsByID.count)")
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

    func releaseMouseCapture() {
        // 释放已由其它路径发生（隐藏 / 拆卸 / 本任务的触发点），挂起的延时收起
        // 一律作废，避免它在稍后凭空再跑一遍释放。
        cancelPendingCollapse()
        // 挂起的展开同样作废：鼠标已经离开保持区，0.15s 后再凭空展开一张卡
        // 读起来是"鼠标不在、卡片在"。
        cancelPendingSelection()
        cancelPendingDeselection()
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
}
