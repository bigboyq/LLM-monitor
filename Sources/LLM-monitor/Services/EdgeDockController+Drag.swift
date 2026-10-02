import AppKit

/// 边缘状态窗的拖拽（沿贴靠边滑动）：从 `EdgeDockController` 拆出。
///
/// 按下即起候选，位移越过阈值才算真拖动；拖拽中的临时位置不进 `config`
/// （理由见 `applyDrag`），落点才写回比例。
extension EdgeDockController {
    // MARK: - 拖拽：沿贴靠边滑动

    /// 拖拽中直接按鼠标位置驱动窗口 frame —— 不依赖 `isMovableByWindowBackground` 的
    /// 自由移动。自由移动会让窗口脱离屏幕边缘悬在半空，而用户想表达的只是
    /// "沿着边缘上下挪一挪"，所以垂直于边的方向一律钉死在边缘。
    ///
    /// 由 `.leftMouseDragged` 逐事件调用（见 `handleMouseEvent`），不是定时轮询。
    func applyDrag(at mouse: CGPoint) {
        guard let panel else { return }
        let visibleFrame = dragVisibleFrame(for: mouse)

        // 鼠标明显更靠近另一条边时才换边（带 margin，避免角落来回闪）。
        let edge = EdgeDockGeometry.edgeAfterDrag(
            mouse: mouse, currentEdge: config.edge, visibleFrame: visibleFrame
        )
        // `edge` **必须**逐事件跟进：内容靠它决定 VStack/HStack、背板形状与贴边
        // 对齐，换边的那一刻就得换排布。但 `edgeAfterDrag` 带 40pt 优势判定，一次
        // 拖拽通常一次都不会换边，所以只在真的变了时赋值——`config` 是 @Published，
        // 无条件赋值等于每帧让整个 dock 视图重算一遍。
        if edge != config.edge { applyRuntimeConfig { $0.edge = edge } }

        let size = EdgeDockGeometry.dockSize(
            entryCount: dragEntryCount,
            edge: edge,
            appearance: isCompactAppearance ? .compact : .full,
            compactSize: config.compactSize
        )
        // `offset` 相反：它只决定**窗口**位置，视图一次也没读过它
        // （`EdgeDockContentView` 只消费 `config.edge`）。拖拽期间留在非发布的
        // `dragOffset` 上，松手时由 `finishPressOrDrag` 一次性写回——60~120Hz 的
        // 发布会把整棵内容树连同每行两次 GeometryReader 测量全部重跑一遍，
        // 换来的却是一个渲染不出来的数字。
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: mouse, dockSize: size, visibleFrame: visibleFrame, edge: edge
        )
        dragOffset = offset

        // `display: false`：不在每个事件里强制同步重绘。拖动由窗口服务器合成，
        // 同步重绘只会把主线程打满，反而更卡。
        panel.setFrame(
            EdgeDockGeometry.frame(
                visibleFrame: visibleFrame, edge: edge, size: size, offset: offset
            ),
            display: false
        )
    }

    /// 本次拖拽按**哪块屏**的可用区算：鼠标越过屏幕边界就换屏。
    ///
    /// 换屏写进 `config.screenUUID` 而不是记一个临时变量——`targetScreen` 下一帧
    /// 就能确定性地解析到新屏（不依赖焦点，也不依赖窗口碰巧已经搬过去）。写完
    /// 立刻按新屏重算，窗口当个事件就落位；松手时随整份配置一起持久化。
    ///
    /// 判定用"鼠标落在**别的**屏的可用区里"，而不是比较几何距离：相邻两屏拼接时
    /// 边界只有一条，鼠标越过它时它在两块屏里都算落在边界附近，用距离会来回抖。
    private func dragVisibleFrame(for mouse: CGPoint) -> CGRect {
        let current = Self.targetScreen
        let screens = NSScreen.screens
        let index = EdgeDockDisplay.crossedIndex(
            currentDisplayID: EdgeDockDisplay.displayID(of: current),
            mouse: mouse,
            candidates: screens.map { (EdgeDockDisplay.displayID(of: $0), $0.visibleFrame) }
        )
        guard let index, let uuid = EdgeDockDisplay.uuid(of: screens[index]) else {
            return current.visibleFrame
        }
        applyRuntimeConfig { $0.screenUUID = uuid }
        logInfo("EdgeDock: 拖拽跨屏 → uuid=\(uuid) frame=\(Self.describe(screens[index].visibleFrame))")
        return screens[index].visibleFrame
    }

    /// 配置里指定的屏在当前系统上找不到时，把它清掉并落盘。
    ///
    /// 落盘而不是只改内存：不落盘的话，用户每次启动都要重新走一遍"找不到 → 猜主屏"，
    /// 而且 config.json 里那个永远解析不到的 UUID 会一直误导人。删掉之后 dock
    /// 回到"跟随所在屏 / 主屏"的老行为——那是唯一在屏不见了还能站得住的语义。
    func dropScreenUUIDIfVanished() {
        guard let uuid = config.screenUUID else { return }
        guard NSScreen.screens.allSatisfy({ EdgeDockDisplay.uuid(of: $0) != uuid }) else { return }
        logInfo("EdgeDock: 配置指定的屏已不在（uuid=\(uuid)），回落到主屏")
        applyRuntimeConfig { $0.screenUUID = nil }
        persistConfig()
    }

    /// 整份 `EdgeDockConfig` 写盘（拖拽松手、配置指定的屏消失后的回落都走这里）。
    func persistConfig() {
        guard let configStore else { return }
        let current = configStore.config
        // 与默认完全一致时写 nil，保持 config.json 干净（与 statusBar* 字段同一约定）。
        guard current.edgeDock != config else { return }
        var updated = current
        updated.edgeDock = config
        do {
            try configStore.applyAndSave(updated)
        } catch {
            logError("EdgeDock: 保存边缘窗配置失败 \(error.localizedDescription)")
        }
    }
}
