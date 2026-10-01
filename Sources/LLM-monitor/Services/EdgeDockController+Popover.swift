import AppKit
import SwiftUI

/// 边缘状态窗的 Provider 卡片浮层：从 `EdgeDockController` 拆出。
///
/// 浮层与 dock 是两个独立窗口，dock 尺寸不因它改变；这里只管浮层的定位、显隐，
/// 以及鼠标停在浮层上时怎么维持接管。
extension EdgeDockController {
    // MARK: - Provider 卡片 popover

    /// 展示 / 收起**当前悬停**的 provider 卡片。
    ///
    /// 直接复用菜单里的 `ProviderCardView(status:)`，与主菜单那一屏**逐字同源**，
    /// 不另写一套轻量版 —— 两份"看起来一样的卡片"必然漂移。
    func updatePopover() {
        guard let panel,
              let state,
              let index = selectedIndex,
              config.mode.isVisible, !isHiddenByFullscreen
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

        // 纵向锚点用**实测行中心**。`popoverFrame` 自己那个 `rowCenter` 兜底现在也
        // 接了 `appearance`（与 `circleRects` / `rowRects` 同一批修的），所以它已经
        // 不再"写死完整形态的行距"；但实测仍然优先——它顺带覆盖了简版↔完整形态
        // 变形动画的中间帧，那几帧里两种常数都不对。
        let rows = resolvedRowRects(entries: entries, panelFrame: panel.frame)
        let anchorCenter = index < rows.count ? CGPoint(x: rows[index].midX, y: rows[index].midY) : nil
        let targetFrame = EdgeDockGeometry.popoverFrame(
            size: CGSize(width: width, height: height),
            dockFrame: panel.frame,
            rowIndex: index,
            edge: config.edge,
            visibleFrame: visibleFrame,
            measuredRowCenter: anchorCenter,
            appearance: isCompactAppearance ? .compact : .full
        )

        popover.setFrame(targetFrame, display: true)
        hosting.layoutSubtreeIfNeeded()
        popover.orderFrontRegardless()
    }

    /// 收起详情窗。
    func hidePopover() {
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
    func startCaptureTimer() {
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
}
