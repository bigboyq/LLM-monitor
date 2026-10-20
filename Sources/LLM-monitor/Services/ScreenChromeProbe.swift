import AppKit
import CoreGraphics

/// 当前 Space 上**真实可视区**的探测：菜单栏与系统程序坞（macOS Dock）此刻
/// **实际显示中**的占用，从 `screen.frame` 里扣除。
///
/// 背景：`NSScreen.visibleFrame` 是**静态**的——按「菜单栏常驻 + 系统 Dock 常驻」
/// 预留，不看它们此刻是否真的在屏上。原生全屏 Space 里两者都隐藏，visibleFrame
/// 却照样预留 → 贴上/下边的窗口悬空一条菜单栏/Dock 的高度；系统 Dock 停在左/右
/// 侧的机器上，贴那条边的窗口同样落在错误的基准上。这里回答的是"**现在**这块
/// 屏上真实挡着什么"。
///
/// 探测走 CGWindowList 的**窗口层级**，不读任何私有状态：
/// - 菜单栏在 `kCGMainMenuWindowLevel`，系统 Dock 在 `kCGDockWindowLevel`；
/// - 自动隐藏（收起）与原生全屏 Space 上它们不在屏上（`optionOnScreenOnly`
///   查不到，或 bounds 已滑出屏外被相交判定滤掉）→ 占用为空 → 贴物理边缘，
///   全屏不需要任何特判分支。
///
/// fail-open 是硬要求（与 `FullscreenProbe` 同纪律）：窗口列表读不到、占用把
/// 可视区收缩成非法形状，一律回退 `screen.visibleFrame`——退回旧行为，绝不把
/// 窗口算到屏外去。
enum ScreenChromeProbe {
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

    /// 与屏幕边的贴合/相交判定容差，吸收窗口边框的亚像素内缩。
    static let edgeTolerance: CGFloat = 0.5

    /// 一条系统装饰窗口的判定所需信息。抽成 struct 是为了让收缩逻辑能脱离
    /// `CGWindowListCopyWindowInfo` 单测（与 `FullscreenProbe.WindowEntry` 同模式）。
    struct ChromeWindow {
        let layer: Int
        /// CG 坐标系（主屏左上原点、y 向下）下的边框。
        let bounds: CGRect
    }

    /// 纯核心：从窗口列表算目标屏的真实可视区。
    ///
    /// 从 `screenFrame` 出发，对每条与它相交的菜单栏/Dock 占用带收缩对应的边；
    /// 结果非法（塌掉/越界）或列表不可用都返回 `fallback`。
    static func effectiveVisibleFrame(
        among windows: [ChromeWindow],
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat,
        fallback: CGRect
    ) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return fallback }
        var effective = screenFrame
        for window in windows {
            guard window.layer == mainMenuLayer || window.layer == dockLayer else { continue }
            // AppKit（左下原点）↔ CG（左上原点）的翻转是同一个式子——自逆，
            // 所以入参叫 fromAppKitRect 的变换对 CG 矩形同样适用。
            let occupied = FullscreenProbe.cgRect(
                fromAppKitRect: window.bounds,
                primaryScreenHeight: primaryScreenHeight
            )
            let band = occupied.intersection(screenFrame)
            guard band.width > edgeTolerance, band.height > edgeTolerance else { continue }

            let pinsTop = band.maxY >= screenFrame.maxY - edgeTolerance
            let pinsBottom = band.minY <= screenFrame.minY + edgeTolerance
            let pinsLeft = band.minX <= screenFrame.minX + edgeTolerance
            let pinsRight = band.maxX >= screenFrame.maxX - edgeTolerance
            // 判据是**形状**（细长条的方向），不是贴边数：横条（菜单栏 / 底部
            // Dock）天然贴左又贴右，侧边 Dock 天然贴顶又贴底——按贴边数会把
            // 正常装饰误杀成"横跨异常"。方块（两轴都厚，如全屏窗口）两条判据
            // 都不满足，自动跳过。
            let isHorizontalBand = band.height <= band.width / 2
            let isVerticalBand = band.width <= band.height / 2
            guard isHorizontalBand || isVerticalBand else { continue }

            // 横条必须贴顶或底、竖条必须贴左或右，否则它漂浮在屏中间，挡不住
            // 任何一条边，收缩无从谈起。
            var newMinY = effective.minY
            var newMaxY = effective.maxY
            var newMinX = effective.minX
            var newMaxX = effective.maxX
            if isHorizontalBand {
                if pinsTop {
                    newMaxY = min(newMaxY, band.minY)
                } else if pinsBottom {
                    newMinY = max(newMinY, band.maxY)
                } else {
                    continue
                }
            } else {
                if pinsLeft {
                    newMinX = max(newMinX, band.maxX)
                } else if pinsRight {
                    newMaxX = min(newMaxX, band.minX)
                } else {
                    continue
                }
            }
            let shrunk = CGRect(
                x: newMinX,
                y: newMinY,
                width: newMaxX - newMinX,
                height: newMaxY - newMinY
            )
            guard shrunk.width >= edgeTolerance, shrunk.height >= edgeTolerance,
                  screenFrame.contains(shrunk)
            else { continue }
            effective = shrunk
        }
        guard effective.width > 0, effective.height > 0, screenFrame.contains(effective) else {
            return fallback
        }
        return effective
    }

    /// 薄 IO：目标屏此刻的真实可视区。只负责取窗口列表，判定全在纯核心。
    static func effectiveVisibleFrame(on screen: NSScreen) -> CGRect {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return screen.visibleFrame }
        let windows = raw.compactMap { item -> ChromeWindow? in
            guard let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return ChromeWindow(layer: layer, bounds: rect)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return effectiveVisibleFrame(
            among: windows,
            screenFrame: screen.frame,
            primaryScreenHeight: primaryHeight,
            fallback: screen.visibleFrame
        )
    }
}
