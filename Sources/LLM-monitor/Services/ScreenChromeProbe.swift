import AppKit

/// 当前 Space 上**真实可视区**的选边：全屏 Space 贴物理屏幕边缘，非全屏用
/// `NSScreen.visibleFrame` 的预留。
///
/// `NSScreen.visibleFrame` 是**静态**的——按「菜单栏常驻 + 系统 Dock 常驻」预留，
/// 不看它们此刻是否真的在屏上。原生全屏 Space 里两者都被系统强制隐藏，
/// visibleFrame 却照样预留 → 贴上/下边的窗口悬空一条预留高度；而非全屏时这份
/// 预留**恰好就是真实占用**（菜单栏/Dock 在屏，AppKit 也为侧边 Dock 的机器算好
/// 了水平预留）。所以可靠信号不是"去窗口列表里找装饰"，而是**Space 形态**：
///
/// - 全屏 Space：菜单栏与系统 Dock 被系统保证隐藏 → 贴 `screen.frame`；
/// - 非全屏：`visibleFrame` 的预留此刻真实 → 照用（含系统 Dock 在左/右/底的全部
///   避让，AppKit 已经算好）。
///
/// ## CGWindowList 路线为什么被否决（2026-10 实测，macOS 26）
///
/// 曾尝试按 `kCGMainMenuWindowLevel` / `kCGDockWindowLevel` 从窗口列表提取装饰
/// 条带再从 `screen.frame` 收缩。实测两处硬伤：菜单栏**不作为独立窗口暴露**
/// （level-24 列表为空）；系统 Dock 的主窗口 bounds 是**整块屏幕的方块**
/// （`owner=程序坞 cg=(0,0,1512,982)`），图标条只是它的视觉部分——按形状判据
/// 只能当异常跳过，等于什么都没探测到。Space 形态（`FullscreenProbe`，同样走
/// 窗口列表但有"盖满 + 无桌面装饰"这对实战判据）才是"装饰此刻在不在屏"的
/// 可靠回答。
///
/// fail-open：选中的矩形退化（零尺寸瞬态）时回退另一个来源；两者皆退化才放行
/// `.zero`（下游 `EdgeDockGeometry.frame` 对零矩形有自己的 `.zero` 保护）。
enum ScreenChromeProbe {
    /// 纯核心：按 Space 形态在两个基准里选边。
    static func effectiveVisibleFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        isFullscreenSpace: Bool
    ) -> CGRect {
        let chosen = isFullscreenSpace ? screenFrame : visibleFrame
        let alternate = isFullscreenSpace ? visibleFrame : screenFrame
        guard chosen.width <= 0 || chosen.height <= 0 else { return chosen }
        return alternate
    }

    /// 薄包装：目标屏 + 控制器持有的全屏判定（`EdgeDockController.isFullscreenSpace`，
    /// 由 `FullscreenProbe` 按目标屏当前 Space 探测）。
    static func effectiveVisibleFrame(on screen: NSScreen, isFullscreenSpace: Bool) -> CGRect {
        effectiveVisibleFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isFullscreenSpace: isFullscreenSpace
        )
    }
}
