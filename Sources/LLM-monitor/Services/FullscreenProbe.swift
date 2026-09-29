import AppKit
import CoreGraphics
import Foundation

/// 判断**当前 Space** 上是否有 macOS 原生全屏窗口。
///
/// 不用辅助功能权限（`AXIsProcessTrusted`）——那会弹权限窗，对一个状态栏小工具
/// 来说代价过高。这里走 `CGWindowListCopyWindowInfo`：只读取窗口**边框**，
/// 不读标题 / 图像，因此不需要「屏幕录制」权限。
///
/// 辅助功能那条路也不成立：`kAXFullScreenAttribute` **不在公开 SDK 里**
/// （公开头文件只有 `kAXFullScreenButtonAttribute`，那是全屏按钮元素、不是状态），
/// 实际要传未文档化的 `"AXFullScreen"` 字符串；而且 AX 回答的是"这个窗口是不是
/// 全屏"，**不回答它在哪个 Space**——别的 Space 上的全屏窗口照样返回 true，
/// 反而会把普通桌面上的 dock 也藏掉。
///
/// ## 问的是"当前 Space"而不是"前台 App"
///
/// 全屏本质上是 **Space** 的属性：进全屏会新建一个 Space。而
/// `NSWorkspace.frontmostApplication` 跟随的是 **App 激活**，滑动 Space 并不
/// 触发任何激活。两者可以完全对不上——滑到一个**非前台 App** 的全屏 Space 时，
/// 前台 App 那个 PID 压根不在这块屏幕上，按前台过滤就会漏判，dock 留在全屏里。
///
/// `.optionOnScreenOnly` 已经把窗口列表限制在当前 Space，所以只要**不**再按
/// 进程过滤，判定天然就是 Space 局部的。
///
/// ## 不会把"最大化窗口"误判成全屏
///
/// 判据是「有普通层窗口盖满 `screen.frame`」**且**「这块屏幕上没有桌面装饰」。
/// 后半条是后加的，因为单靠覆盖面积不够：
///
/// - 菜单栏可见时 `visibleFrame` 比 `frame` 矮一条菜单栏，最大化 / 缩放出来的
///   窗口撑破天也盖不满 `frame`，覆盖判据本来就够用；
/// - **菜单栏和 Dock 都设成自动隐藏时 `visibleFrame == frame`**，缩放出来的窗口
///   恰好盖满 `frame`，覆盖判据分不出来——这才是误判的真实来源。
///
/// 而桌面装饰（壁纸 / 桌面图标 / 菜单栏，见 `desktopChromeLayer`）在两种情况下
/// 都稳定：自动隐藏菜单栏不会藏掉桌面图标，而任何原生全屏 Space 上桌面装饰都
/// 不在。于是「盖满 + 桌面装饰不在」= 真全屏，「盖满 + 桌面装饰还在」= 普通
/// Space 上的大窗口。
///
/// 误报防护来自这两条判据，**不是**来自进程过滤——所以去掉进程过滤并不会
/// 换来"窗口铺满就藏 dock"。真正需要排除的是**自己**的窗口：边缘窗、详情浮层、
/// 设置窗口都是本进程 layer-0 窗口，其中任意一个被铺满都会让自己把自己藏掉。
///
/// **fail-open 是硬要求**：探测失败一律返回 `false`（窗口照常显示）。
/// 一个"探测失败就永久隐身、再也回不来"的窗口，比短暂遮挡一个全屏 App 糟糕得多。
enum FullscreenProbe {
    /// 判定窗口是否铺满整块屏幕。留 2pt 容差吸收 macOS 自己那一点点边框内缩。
    static let coverageTolerance: CGFloat = 2

    /// 桌面装饰（Finder 桌面图标窗）所在的 CGWindow 层，即
    /// `kCGDesktopIconWindowLevel`。
    ///
    /// 这块屏幕上还有没有这一层的窗口，就是「真全屏」与「普通 Space 上的大窗口」
    /// 的分界线（见类型注释）。用**公开常量**而不是硬编码数字：这个值随系统版本
    /// 会变，写死一个数字会在别的系统上静默把判定反过来。
    ///
    /// 判据必须**精确等于**这一层，不能放宽成"桌面那一带的层"：同一带上还有
    /// 窗口服务器与 WindowManager 的常驻窗口（壁纸后板、Space 切换层等），
    /// 全屏时它们**照样在**，放宽就会把真全屏判成普通 Space。
    static let desktopChromeLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// AppKit（左下原点、y 向上）→ CGWindowList（主屏左上原点、y 向下）。
    ///
    /// 两套坐标系只差一次 y 翻转，翻错会让全屏判定在多屏下彻底失准，
    /// 所以单独抽成纯函数测试。翻转后**负 y 是正常的**——主屏上方的副屏本来就落在
    /// CG 全局坐标的负 y 区，别把它当成 bug 去加绝对值 / 改偏移
    /// （见 `testCgRectFlipIsCorrectForScreensAboveAndBelowThePrimary`）。
    static func cgRect(fromAppKitRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 一条窗口的判定所需信息。抽成 struct 是为了让判定逻辑能脱离
    /// `CGWindowListCopyWindowInfo` 单测。
    struct WindowEntry {
        let ownerPID: pid_t
        /// CoreGraphics 窗口层（0 = 普通层）。
        let layer: Int
        /// **CG 坐标系**（左上原点、y 向下）下的边框。
        let bounds: CGRect
    }

    /// 纯判定：这些窗口里有没有一个铺满整块屏幕的普通层窗口，且这块屏幕正处于
    /// 全屏 Space（没有桌面装饰）。
    ///
    /// - Parameter ownProcessIdentifier: 本进程 PID，本进程的所有窗口一律跳过
    ///   （边缘窗 / 详情浮层 / 设置窗口都是本进程的 layer-0 窗口）。
    static func containsFullscreenWindow(
        among entries: [WindowEntry],
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        let screenRect = cgRect(fromAppKitRect: screenFrame, primaryScreenHeight: primaryScreenHeight)
        // 桌面装饰还在 = 普通 Space，铺满的窗口只是被缩放到 visibleFrame 的大窗口。
        guard !hasDesktopChrome(among: entries, screenRect: screenRect) else { return false }
        return entries.contains { entry in
            guard entry.ownerPID != ownProcessIdentifier else { return false }
            // 只看普通层级窗口：菜单 / tooltip / 阴影层铺满屏幕不代表全屏。
            guard entry.layer == 0 else { return false }
            return covers(entry.bounds, screenRect)
        }
    }

    /// 这块屏幕上是否还画着桌面装饰。
    ///
    /// 判据方向是**保守**的：它只把覆盖判据的 `true` 改判成 `false`，不会凭空
    /// 造出 `true`。桌面装饰读不到时（比如桌面图标被关掉）最多退回旧行为，
    /// 不会因此多藏一次 dock。
    private static func hasDesktopChrome(among entries: [WindowEntry], screenRect: CGRect) -> Bool {
        entries.contains { entry in
            entry.layer == desktopChromeLayer && covers(entry.bounds, screenRect)
        }
    }

    /// 当前 Space 上是否有原生全屏窗口。
    ///
    /// - Parameter ownProcessIdentifier: 本进程 PID，用于排除自身窗口。
    static func isAnyFullscreenWindow(
        on screen: NSScreen,
        excludingProcessIdentifier ownProcessIdentifier: pid_t
    ) -> Bool {
        // **不能带 `.excludeDesktopElements`**：它过滤掉的正是桌面装饰（壁纸 /
        // 桌面图标 / 菜单栏），而"桌面装饰在不在"就是本探测的另一半判据。多出来的
        // 都是负层级窗口，`layer == 0` 的候选过滤本来就会把它们挡掉。
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let entries = raw.compactMap { item -> WindowEntry? in
            guard let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return WindowEntry(ownerPID: ownerPID, layer: layer, bounds: rect)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return containsFullscreenWindow(
            among: entries,
            screenFrame: screen.frame,
            primaryScreenHeight: primaryHeight,
            ownProcessIdentifier: ownProcessIdentifier
        )
    }

    private static func covers(_ rect: CGRect, _ screenRect: CGRect) -> Bool {
        rect.insetBy(dx: -coverageTolerance, dy: -coverageTolerance).contains(screenRect)
    }
}
