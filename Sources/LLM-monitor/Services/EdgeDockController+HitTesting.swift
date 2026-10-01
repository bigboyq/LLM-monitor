import CoreGraphics
import Foundation

/// 边缘状态窗的命中判定：从 `EdgeDockController` 拆出来的纯函数。
///
/// 三段都是 `nonisolated static`，只依赖 `EdgeDockGeometry` / `EdgeDockProjection`
/// 与入参，不读任何实例状态。控制器那边是有序状态机（hover、鼠标接管、四个互相
/// 取消的挂起任务），这里只回答两个问题：指针指中了哪个圆、命中该用实测矩形还是
/// 几何兜底。放在一起还有个实际好处：两个 `resolve*` 的判定步骤完全相同，只有
/// 兜底矩形取行还是取圆不同，合进一个私有实现后改一处不会再漏另一处。
extension EdgeDockController {
    /// 圆形命中测试：仅在命中 provider 外圈及其内部区域时返回对应 index。
    ///
    /// 严谨限制在圆内（半径 + 0.5pt 容差），排除了圆下方的数值百分比标签以及行间空隙。
    /// 当某项处于 hover 状态时，圆环尺寸会放大 `EdgeDockGeometry.hoverScale`（1.10x），
    /// 这里相应扩大判定半径，防止指针在边界处由于动画放大缩减产生抖动。
    ///
    /// `minimumRadius`：判定半径的下限。「小圆环」形态的圆只有 7pt（半径 3.5），
    /// 照圆判定等于要指中一个 7px 的点，抖动到相邻行就换了一张卡；那里传**半个
    /// 行距**，相邻两个小环的判定区正好在中点接上——仍然是"离得近的那个"，
    /// 但不再要求指针精确。完整形态传 0，行为与从前逐字相同。
    nonisolated static func circleIndex(
        at point: CGPoint,
        circles: [CGRect],
        currentHovered: Int? = nil,
        minimumRadius: CGFloat = 0
    ) -> Int? {
        for (index, rect) in circles.enumerated() {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let baseRadius = rect.width / 2
            let isCurrent = (index == currentHovered)
            let radius = isCurrent ? (baseRadius * EdgeDockGeometry.hoverScale) : baseRadius
            if hypot(point.x - center.x, point.y - center.y) <= (max(radius, minimumRadius) + 0.5) {
                return index
            }
        }
        return nil
    }

    /// 命中矩形选取（纯函数）：实测优先，三种情况退回几何推算。
    ///
    /// 退回条件 —— 还没量到（视图未上报）、量得不完整（有条目没有矩形）、
    /// 换算后整列落在窗口外（坐标系换算错了；与其错命中不如用兜底）。
    ///
    /// **保证永远返回可命中的矩形**：命中失败会连带 `captureMouse()` 不执行，
    /// `ignoresMouseEvents` 一直是 true，于是 hover 和拖拽**同时**失能。
    /// 宁可位置有偏差，也不能没有命中。
    nonisolated static func resolveRowRects(
        entries: [EdgeDockEntry],
        measured: [String: CGRect],
        panelFrame: CGRect,
        edge: DockEdge,
        slack: CGFloat,
        appearance: EdgeDockGeometry.DockAppearance = .full
    ) -> (rows: [CGRect], usedMeasured: Bool) {
        let resolved = resolveRects(
            fallback: EdgeDockGeometry.rowRects(
                dockFrame: panelFrame, edge: edge, entryCount: entries.count, appearance: appearance
            ),
            entries: entries,
            measured: measured,
            panelFrame: panelFrame,
            slack: slack
        )
        return (rows: resolved.rects, usedMeasured: resolved.usedMeasured)
    }

    /// 圆矩形的命中矩形选取。与 `resolveRowRects` 只差兜底矩形取圆而非取行，
    /// 判定步骤共用 `resolveRects`。
    nonisolated static func resolveCircleRects(
        entries: [EdgeDockEntry],
        measured: [String: CGRect],
        panelFrame: CGRect,
        edge: DockEdge,
        slack: CGFloat,
        appearance: EdgeDockGeometry.DockAppearance = .full
    ) -> (circles: [CGRect], usedMeasured: Bool) {
        let resolved = resolveRects(
            fallback: EdgeDockGeometry.circleRects(
                dockFrame: panelFrame, edge: edge, entryCount: entries.count, appearance: appearance
            ),
            entries: entries,
            measured: measured,
            panelFrame: panelFrame,
            slack: slack
        )
        return (circles: resolved.rects, usedMeasured: resolved.usedMeasured)
    }

    /// 两个 `resolve*` 唯一的差别是兜底矩形，故只由调用方算出传进来。
    nonisolated private static func resolveRects(
        fallback: [CGRect],
        entries: [EdgeDockEntry],
        measured: [String: CGRect],
        panelFrame: CGRect,
        slack: CGFloat
    ) -> (rects: [CGRect], usedMeasured: Bool) {
        guard !entries.isEmpty, !measured.isEmpty else { return (fallback, false) }

        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: measured)
        guard ordered.allSatisfy({ $0 != EdgeDockProjection.unmeasuredRow }) else {
            return (fallback, false)
        }
        // 视图坐标系 → 屏幕坐标系的换算在此之前已完成（调用方传进来的已是屏幕坐标）；
        // 这里只做一次自检：整列必须落在 dock 附近，否则说明换算错了。
        let dockArea = panelFrame.insetBy(dx: -slack, dy: -slack)
        guard ordered.allSatisfy({ dockArea.intersects($0) }) else { return (fallback, false) }
        return (ordered, true)
    }
}
