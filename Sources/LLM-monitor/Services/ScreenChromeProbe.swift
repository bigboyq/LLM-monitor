import AppKit

/// 当前 Space 上**真实可视区**的统筹计算与四边避让模型。
///
/// ## 核心模型：四边独立解耦（Per-Edge Clearance Model）
///
/// 屏幕四条边缘上的系统组件（Chrome）相互独立，不能用粗暴的"全屏即全贴物理边 / 非全屏即全缩 visibleFrame"
/// 二值矩阵替代：
/// - **上边缘（Top）**：只由**状态栏（Menu Bar）**决定。
///   - 状态栏出现（普通桌面且菜单栏常驻）：顶边避让状态栏高度；
///   - 状态栏不出现（App 全屏、系统设置自动隐藏菜单栏、或副屏在无独立 Spaces 时）：顶边**直接吸附到物理屏幕边缘**，
///     不再悬在半空中。
/// - **下/左/右边缘（Bottom / Left / Right）**：由**系统 Dock** 决定。
///   - Dock 可能停靠在底部、左侧或右侧；
///   - 只要某条边上有 Dock 占位，悬浮窗在该边缘停靠时必须**保持安全避让，绝对不能与 Dock 重叠**；
///   - 无 Dock 占位的边缘直接吸附到物理屏幕边缘。
/// - **主屏与副屏（Multi-Display）**：
///   - 主屏通常拥有菜单栏与默认 Dock；
///   - 副屏在 `NSScreen.screensHaveSeparateSpaces == false` 时**完全没有状态栏**，顶边直接吸附；
///   - 副屏的全屏状态独立判定，不与主屏互相影响。
enum ScreenChromeProbe {
    /// 状态栏的显隐状态与高度。
    struct MenuBarState: Equatable {
        var isVisible: Bool
        var height: CGFloat
    }

    /// 屏幕四条边缘各自的安全避让（Insets，AppKit 坐标系）。
    struct Insets: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var left: CGFloat
        var right: CGFloat

        static let zero = Insets(top: 0, bottom: 0, left: 0, right: 0)
    }

    /// 系统 Dock 的浮动毛玻璃外壳与通知未读红点（Badge）视觉高度通常超出 visibleFrame 扣除量，
    /// 增加 8pt 的安全吸附呼吸区，确保在窗口模式停靠在 Dock 上方时紧密贴合且不与 Dock 背景/角标穿模重叠。
    static let dockClearancePadding: CGFloat = 8

    /// 计算给定屏幕条件下的四边有效避让。
    /// - Parameters:
    ///   - screenFrame: 物理屏幕区域（AppKit 坐标系）
    ///   - visibleFrame: 系统静态安全区（AppKit 坐标系）
    ///   - isMenuBarVisible: 状态栏是否在此屏幕上出现
    ///   - menuBarHeight: 状态栏实测高度（若有实测则优先使用，例如副屏动态唤出时的 30pt）
    ///   - keepDockClearance: 是否保持对 Dock 的避让（默认为 true，左右下绝不与 Dock 重叠）
    static func effectiveInsets(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        isMenuBarVisible: Bool,
        menuBarHeight: CGFloat? = nil,
        keepDockClearance: Bool = true
    ) -> Insets {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return .zero
        }

        // 顶边：状态栏
        let staticTop = max(screenFrame.maxY - visibleFrame.maxY, 0)
        let top: CGFloat
        if isMenuBarVisible {
            if let customHeight = menuBarHeight, customHeight > 0 {
                top = customHeight
            } else if staticTop > 0 {
                top = staticTop
            } else {
                top = 30
            }
        } else {
            top = 0
        }

        // 底边与侧边：Dock（左、右、下均有可能）
        let staticBottom = max(visibleFrame.minY - screenFrame.minY, 0)
        let staticLeft = max(visibleFrame.minX - screenFrame.minX, 0)
        let staticRight = max(screenFrame.maxX - visibleFrame.maxX, 0)

        let bottom = (keepDockClearance && staticBottom > 0) ? (staticBottom + dockClearancePadding) : 0
        let left = (keepDockClearance && staticLeft > 0) ? (staticLeft + dockClearancePadding) : 0
        let right = (keepDockClearance && staticRight > 0) ? (staticRight + dockClearancePadding) : 0

        return Insets(top: top, bottom: bottom, left: left, right: right)
    }

    /// 纯核心：按状态栏是否出现与 Dock 位置，计算真实有效可视区。
    ///
    /// - 状态栏未出现（App 全屏 / 自动隐藏状态栏 / 副屏无状态栏）：顶边吸附屏幕物理边缘；
    /// - 状态栏出现：顶边避让状态栏；
    /// - Dock 存在（左、右、下）：严格避让 Dock，绝不重叠。
    static func effectiveVisibleFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        isMenuBarVisible: Bool,
        menuBarHeight: CGFloat? = nil,
        keepDockClearance: Bool = true
    ) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return visibleFrame.width > 0 && visibleFrame.height > 0 ? visibleFrame : .zero
        }

        let insets = effectiveInsets(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            isMenuBarVisible: isMenuBarVisible,
            menuBarHeight: menuBarHeight,
            keepDockClearance: keepDockClearance
        )

        let x = screenFrame.minX + insets.left
        let y = screenFrame.minY + insets.bottom
        let width = screenFrame.width - (insets.left + insets.right)
        let height = screenFrame.height - (insets.top + insets.bottom)

        guard width > 0, height > 0 else {
            return visibleFrame.width > 0 && visibleFrame.height > 0 ? visibleFrame : screenFrame
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 针对 `isFullscreenSpace: Bool` 的二元接口（与原有调用点对齐）。
    ///
    /// - `isFullscreenSpace == true`（全屏模式）：状态栏未出现（顶边吸附物理上沿），且全屏下无常驻 Dock（底/左/右吸附物理屏幕边缘）；
    /// - `isFullscreenSpace == false`（非全屏窗口模式）：按系统静态预留避让状态栏，且保持对 Dock 的避让，吸附在 Dock 上。
    static func effectiveVisibleFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        isFullscreenSpace: Bool
    ) -> CGRect {
        effectiveVisibleFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            isMenuBarVisible: !isFullscreenSpace,
            keepDockClearance: !isFullscreenSpace
        )
    }

    /// 薄包装：按目标屏幕对象及其全屏判定，计算真实有效可视区。
    /// 自动处理主屏副屏、单独 Spaces 拓扑、全屏状态、状态栏实测显隐/高度与 Dock 避让。
    static func effectiveVisibleFrame(on screen: NSScreen, isFullscreenSpace: Bool) -> CGRect {
        let state = menuBarState(on: screen, isFullscreenSpace: isFullscreenSpace)
        return effectiveVisibleFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isMenuBarVisible: state.isVisible,
            menuBarHeight: state.height,
            keepDockClearance: !isFullscreenSpace
        )
    }

    /// 状态栏是否在当前屏幕上真实出现及其高度。
    static func menuBarState(
        on screen: NSScreen,
        isFullscreenSpace: Bool,
        windowEntries: [FullscreenProbe.WindowEntry]? = nil
    ) -> MenuBarState {
        // 1. 实时窗口检测：检查 CoreGraphics 窗口列表中属于该屏幕且处于 onScreen 状态的 Menubar 窗口
        if let info = menuBarWindowInfo(on: screen, customEntries: windowEntries) {
            return info
        }

        // 2. 窗口列表读取失败时的保守几何兜底：
        if isFullscreenSpace {
            return MenuBarState(isVisible: false, height: 0)
        }
        if !NSScreen.screensHaveSeparateSpaces && !isPrimaryScreen(screen) {
            return MenuBarState(isVisible: false, height: 0)
        }
        let staticTop = screen.frame.maxY - screen.visibleFrame.maxY
        return MenuBarState(isVisible: staticTop > 1, height: max(staticTop, 0))
    }

    /// 状态栏是否在当前屏幕上真实出现（向后兼容）。
    static func isMenuBarVisible(
        on screen: NSScreen,
        isFullscreenSpace: Bool,
        windowEntries: [FullscreenProbe.WindowEntry]? = nil
    ) -> Bool {
        menuBarState(on: screen, isFullscreenSpace: isFullscreenSpace, windowEntries: windowEntries).isVisible
    }

    /// 检查 CoreGraphics 窗口列表中属于该屏幕且可见的菜单栏窗口信息。
    static func menuBarWindowInfo(
        on screen: NSScreen,
        customEntries: [FullscreenProbe.WindowEntry]? = nil
    ) -> MenuBarState? {
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let screenMinX = screen.frame.minX
        let screenMaxX = screen.frame.maxX

        // 转换当前屏幕上沿至 CoreGraphics 坐标系（主屏原点在左上角，AppKit 原点在左下角）
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        let screenTopCG = primaryHeight - screen.frame.maxY

        if let entries = customEntries {
            for entry in entries {
                guard entry.layer == mainMenuLayer else { continue }
                let overlapMinX = max(entry.bounds.minX, screenMinX)
                let overlapMaxX = min(entry.bounds.maxX, screenMaxX)
                guard (overlapMaxX - overlapMinX) > 100 else { continue }

                let entersTop = entry.bounds.maxY > screenTopCG + 1 && entry.bounds.minY <= screenTopCG + 5
                let validHeight = entry.bounds.height >= 15
                if entersTop && validHeight {
                    return MenuBarState(isVisible: true, height: entry.bounds.height)
                }
            }
            return MenuBarState(isVisible: false, height: 0)
        }

        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for item in raw {
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == mainMenuLayer else { continue }
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let overlapMinX = max(rect.minX, screenMinX)
            let overlapMaxX = min(rect.maxX, screenMaxX)
            guard (overlapMaxX - overlapMinX) > 100 else { continue }

            let entersTop = rect.maxY > screenTopCG + 1 && rect.minY <= screenTopCG + 5
            let validHeight = rect.height >= 15
            if entersTop && validHeight {
                return MenuBarState(isVisible: true, height: rect.height)
            }
        }
        return MenuBarState(isVisible: false, height: 0)
    }

    /// 保留原 `hasMenuBarWindow` 供已有调用点使用。
    static func hasMenuBarWindow(
        on screen: NSScreen,
        customEntries: [FullscreenProbe.WindowEntry]? = nil
    ) -> Bool? {
        menuBarWindowInfo(on: screen, customEntries: customEntries)?.isVisible
    }

    /// 是否为主屏（在 AppKit 坐标系中，主屏的原点必然为 (0,0)）。
    static func isPrimaryScreen(_ screen: NSScreen) -> Bool {
        screen.frame.origin == .zero || screen == NSScreen.screens.first
    }
}
