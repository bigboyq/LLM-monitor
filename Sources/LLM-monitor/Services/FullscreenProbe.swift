import AppKit
import CoreGraphics
import Foundation

/// 判断前台 App 是否处于 macOS 原生全屏。
///
/// 不用辅助功能权限（`AXIsProcessTrusted`）——那会弹权限窗，对一个状态栏小工具
/// 来说代价过高。这里走 `CGWindowListCopyWindowInfo`：只读取窗口**边框**，
/// 不读标题 / 图像，因此不需要「屏幕录制」权限。
///
/// **fail-open 是硬要求**：探测失败一律返回 `false`（窗口照常显示）。
/// 一个"探测失败就永久隐身、再也回不来"的窗口，比短暂遮挡一个全屏 App 糟糕得多。
enum FullscreenProbe {
    /// 判定窗口是否铺满整块屏幕。留 2pt 容差吸收 macOS 自己那一点点边框内缩。
    static let coverageTolerance: CGFloat = 2

    /// AppKit（左下原点、y 向上）→ CGWindowList（主屏左上原点、y 向下）。
    ///
    /// 两套坐标系只差一次 y 翻转，翻错会让全屏判定在多屏下彻底失准，
    /// 所以单独抽成纯函数测试。
    static func cgRect(fromAppKitRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 前台 App 是否有普通层级窗口铺满 `screen`。
    ///
    /// - Parameter ownWindowNumber: 需要排除的自身窗口号（边缘窗自己），
    ///   否则它会把自己判成"前台 App 全屏"从而自己把自己藏掉。
    static func isFrontmostAppFullscreen(on screen: NSScreen, excludingWindowNumber ownWindowNumber: Int? = nil) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenRect = cgRect(fromAppKitRect: screen.frame, primaryScreenHeight: primaryHeight)

        for entry in raw {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int, ownerPID == pid else { continue }
            // 只看普通层级窗口：菜单 / tooltip / 阴影层铺满屏幕不代表全屏。
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let ownWindowNumber,
               let number = entry[kCGWindowNumber as String] as? Int,
               number == ownWindowNumber {
                continue
            }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }

            if covers(rect, screenRect) { return true }
        }
        return false
    }

    private static func covers(_ rect: CGRect, _ screenRect: CGRect) -> Bool {
        rect.insetBy(dx: -coverageTolerance, dy: -coverageTolerance).contains(screenRect)
    }
}
