import CoreGraphics
import Foundation
import SwiftUI

/// 边缘状态窗的纯几何计算。
///
/// 全部是无 AppKit 窗口状态的纯函数：坐标系的翻转、贴边吸附、归一化位置换算
/// 都是最容易出"看起来对但实际差 1px / 掉到屏幕外"的地方，所以全部独立出来测。
enum EdgeDockGeometry {
    /// dock 的两种外观尺寸。「小圆环」与「状态窗（自动隐藏）」的收起形态用
    /// `.compact`，其余一律 `.full`。
    enum DockAppearance {
        /// 完整版：双环 + 品牌图标 + 常驻数值。
        case full
        /// 简版：只有 5h 单环小圆，无数字无图标，紧贴边缘。
        case compact
    }

    /// 单个圆的直径（pt）。双环 + 中心图标，38pt 是三者都不挤的下限。
    static let diameter: CGFloat = 38
    /// 相邻两行/两列的间距（pt）。竖排是行间距，横排是列间距，两者同值。
    static let spacing: CGFloat = 16
    /// 圆环下方常驻数值文字的高度（pt）。
    static let labelHeight: CGFloat = 10
    /// 圆环与数值文字之间的间距（pt）。
    ///
    /// 同样属于"挤"：2pt 时数字几乎贴着环线的描边。4pt 仍明显小于行间距，
    /// 读起来是"数字属于这个圆"，而不是"另一个独立元素"。
    static let labelSpacing: CGFloat = 4
    /// 一行（圆环 + 数值）的高度（pt）。
    static var rowHeight: CGFloat { diameter + labelSpacing + labelHeight }
    /// 相邻两行的步进（行高 + 行间距）。**仅竖排可用**。
    static var rowStep: CGFloat { rowHeight + spacing }
    /// 相邻两列的步进（列宽 + 列间距）。**仅横排可用**。
    ///
    /// 必须和 `rowStep` 分开：数值文字在圆的**下方**，所以一列的宽度是圆宽而不是行高。
    /// 横排若沿用 `rowStep`，窗口会比内容宽出一截，末尾还会空一大块。
    static var columnStep: CGFloat { diameter + spacing }
    /// 圆环列表的内边距（pt）。
    static let padding: CGFloat = 16

    /// 外环（5 小时窗口）直径。
    static let outerRingDiameter = diameter
    /// 内环（周窗口）直径。
    static let innerRingDiameter = diameter * 0.72
    /// 中心品牌图标边长（pt）。
    ///
    /// 上限受内环内沿约束（当前内环内沿半径 ≈ 8.9pt，即图标最大约 17pt），
    /// 再大就会盖住环线；6pt 为当前观感取值。
    static let iconSize: CGFloat = 14
    /// 环线宽（pt）。
    static let ringLineWidth: CGFloat = 3.5

    /// hover 高亮的轻微放大倍数。
    ///
    /// `scaleEffect` 是纯视觉变换、不参与排版：行框、窗口尺寸、命中矩形都不变，
    /// 放大出的 1~2pt 落在四周 8pt 内边距里。只作用在圆环上、不缩放数值文字——
    /// 缩放整行会以行中心为锚把圆往数值一侧顶，hover 时整个 dock 看起来在跳。
    static let hoverScale: CGFloat = 1.10

    // MARK: 简版（自动隐藏模式的收起形态）常量
    //
    // 简版的目标是"常驻也不显眼"：没有数字、没有图标，只剩一枚小环，
    // 所以各项都明显小于完整版；贴边方向总厚度 = 14 + 3×2 = 20pt。

    /// 简版单环直径（pt）。
    static let compactDiameter: CGFloat = 7
    /// 简版相邻两环的间距（pt）。
    static let compactSpacing: CGFloat = 8
    /// 简版的内边距（pt）。
    static let compactPadding: CGFloat = 7
    /// 简版环线宽（pt）。
    static let compactRingLineWidth: CGFloat = 2.5

    /// 简版相邻两个圆心之间的距离（行距，pt）。
    ///
    /// 「小圆环」形态逐行 hover 时用它的一半做判定半径下限（见
    /// `EdgeDockController.circleIndex`）：7pt 的圆按圆判定要指中一个 7px 的点，
    /// 半个行距则刚好让相邻两环的判定区在中点接上。
    static let compactRowStep: CGFloat = compactDiameter + compactSpacing

    /// 按条目数量算出贴边状态下窗口的尺寸。
    ///
    /// 尺寸必须和 `EdgeDockContentView` 的实际排版一致：竖排是 `VStack`（沿 y 堆叠，
    /// 每项占 `rowHeight`），横排是 `HStack`（沿 x 堆叠，每项占 `diameter`）。
    /// 厚度那一轴在竖排时是圆宽、在横排时是行高——因为数值文字在圆的**下方**，
    /// 两种朝向下列高都是 `rowHeight`。简版没有数值文字，厚度轴退化为
    /// `compactDiameter + compactPadding`。
    static func dockSize(entryCount: Int, edge: DockEdge, appearance: DockAppearance = .full) -> CGSize {
        let n = CGFloat(max(entryCount, 0))
        switch appearance {
        case .full:
            let gaps = CGFloat(max(entryCount - 1, 0)) * spacing
            let along = edge.isVertical
                ? n * rowHeight + gaps + padding * 2
                : n * diameter + gaps + padding * 2
            let across = edge.isVertical
                ? diameter + padding * 2
                : rowHeight + padding * 2
            return edge.isVertical
                ? CGSize(width: across, height: along)
                : CGSize(width: along, height: across)
        case .compact:
            let gaps = CGFloat(max(entryCount - 1, 0)) * compactSpacing
            let along = n * compactDiameter + gaps + compactPadding * 2
            let across = compactDiameter + compactPadding * 2
            return edge.isVertical
                ? CGSize(width: across, height: along)
                : CGSize(width: along, height: across)
        }
    }

    /// 把窗口贴到 `edge`，沿边方向按 `offset` 定位。
    ///
    /// `offset` 是**中心**在可用区域内的归一化位置（0 = 该边起点，1 = 该边终点），
    /// 这样拖到边缘时圆环不会被裁掉一半。
    /// 尺寸超过可用区域时按可用区域钳位，保证窗口永远完整可见。
    static func frame(visibleFrame: CGRect, edge: DockEdge, size: CGSize, offset: Double) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }

        let t = offset.isFinite ? min(max(offset, 0), 1) : 0.5

        if edge.isVertical {
            let width = min(size.width, visibleFrame.width)
            let height = min(size.height, visibleFrame.height)
            let y = visibleFrame.midY - height / 2 + (visibleFrame.height - height) * (t - 0.5)
            let x = (edge == .right) ? visibleFrame.maxX - width : visibleFrame.minX
            return CGRect(x: x, y: y, width: width, height: height)
        } else {
            let width = min(size.width, visibleFrame.width)
            let height = min(size.height, visibleFrame.height)
            let x = visibleFrame.midX - width / 2 + (visibleFrame.width - width) * (t - 0.5)
            let y = (edge == .top) ? visibleFrame.maxY - height : visibleFrame.minY
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// 窗口 frame → 归一化 offset（`frame` 的逆运算，用于拖动后回写配置）。
    ///
    /// 必须和 `frame` 用**同一套锚点约定**：offset 描述的是窗口中心在
    /// 「可用范围减去窗口自身尺寸」这段行程里的归一化位置。两者约定不一致时
    /// 往返一次位置就漂一截，表现为"每次开设置窗口都自己挪一点"。
    static func normalizedOffset(frame: CGRect, visibleFrame: CGRect, edge: DockEdge) -> Double {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return 0.5 }
        let travel: CGFloat = edge.isVertical
            ? visibleFrame.height - frame.height
            : visibleFrame.width - frame.width
        // 窗口和可用区域一样大（或更大）时没有行程可言，只能是居中。
        guard travel > 0 else { return 0.5 }
        let delta = edge.isVertical
            ? frame.midY - visibleFrame.midY
            : frame.midX - visibleFrame.midX
        let t = 0.5 + delta / travel
        guard t.isFinite else { return 0.5 }
        return min(max(t, 0), 1)
    }

    /// 拖动落点离哪条边最近 —— 决定吸附到哪一边。
    ///
    /// 距离相同时按 `edgePriority` 决定，保证同样的落点永远得到同样的结果
    /// （否则用户在两条边正中间松手时窗口会随机跳边）。
    static func nearestEdge(
        to point: CGPoint,
        in visibleFrame: CGRect,
        edgePriority: [DockEdge] = DockEdge.allCases
    ) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = edgePriority.map { edge in
            switch edge {
            case .left:   return (edge, point.x - visibleFrame.minX)
            case .right:  return (edge, visibleFrame.maxX - point.x)
            case .top:    return (edge, visibleFrame.maxY - point.y)
            case .bottom: return (edge, point.y - visibleFrame.minY)
            }
        }
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
    }

    /// 悬停时 popover 与圆环之间的间距（pt）。
    static let popoverGap: CGFloat = 10
    /// popover 高度占屏幕可见区的上限，超出部分滚动。
    ///
    /// **这个上限不截断内容**：超过它就套 `ScrollView`（见 `EdgeDockController`
    /// 里 `natural.height > heightCap` 那个分支），卡片该多高还是多高，只是
    /// 变成可滚动的。
    ///
    /// 那为什么还要有它？因为 `popoverFrame` 会把面板高度压到
    /// `visibleFrame.height`，而 `NSPanel` 自己不会滚动——超出屏幕的那一段
    /// 永远够不着。所以真正的硬界只有**屏幕**；`heightCap` 的作用是保证
    /// "一旦帧被压到屏幕高度，内容一定已经是可滚动的"，也就是
    /// `heightCap ≤ visibleFrame.height` 必须成立。
    ///
    /// 取 0.95 而不是 1.0：留一线可见的边缘，让它还看得出是"从 dock 弹出来的
    /// 一块浮层"，而不是铺满整屏。1080p 下约 918pt，ChatGPT 最重形态（648pt）
    /// 完全放得下。
    static let popoverHeightFraction: CGFloat = 0.95

    /// 剩余额度弧的 trim 区间（`0...1`，0 = 3 点方向，顺时针增长）。无弧返回 nil。
    ///
    /// **顺时针收缩** = 把弧的顺时针末端钉在 12 点：区间取 `[1 - fraction, 1]`，
    /// 缺口便从 12 点开始顺时针张开。用 `[0, fraction]` 是"进度条"读法——弧顺时针
    /// 生长、缩短时逆时针回抽，表达的是"已用"而不是"剩余"。
    ///
    /// 抽成纯函数是为了能钉住这个方向：方向写反在界面上表现为"环在往回转"，
    /// 不看代码根本发现不了。
    static func arcTrimRange(fraction: Double?) -> ClosedRange<Double>? {
        guard let fraction, fraction > 0 else { return nil }
        let f = min(fraction, 1)
        return (1 - f)...1
    }

    /// 拖拽时"换边"需要的距离优势：鼠标必须比当前边明显更近才切换贴靠方向，
    /// 否则在角落附近来回横跳会疯狂闪边。
    static let edgeSwitchMargin: CGFloat = 40

    /// 拖拽 → 沿贴靠边的归一化位置。
    ///
    /// 只取**沿边方向**的鼠标坐标：竖排边只看 y，横排边只看 x。垂直于边的方向由
    /// `frame` 钉死在屏幕边缘，所以拖动天然就是"沿着边缘滑动"，不会把窗口拖到
    /// 屏幕中间去。
    static func offsetAlongEdge(
        forMouse mouse: CGPoint,
        dockSize: CGSize,
        visibleFrame: CGRect,
        edge: DockEdge
    ) -> Double {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return 0.5 }
        let clamped = edge.isVertical
            ? CGSize(width: min(dockSize.width, visibleFrame.width), height: min(dockSize.height, visibleFrame.height))
            : CGSize(width: min(dockSize.width, visibleFrame.width), height: min(dockSize.height, visibleFrame.height))
        let travel = edge.isVertical
            ? visibleFrame.height - clamped.height
            : visibleFrame.width - clamped.width
        // 窗口和可用区域一样大时没有行程可言。
        guard travel > 0 else { return 0.5 }
        let along = edge.isVertical ? mouse.y : mouse.x
        let center = edge.isVertical ? visibleFrame.midY : visibleFrame.midX
        let t = 0.5 + (along - center) / travel
        guard t.isFinite else { return 0.5 }
        return min(max(t, 0), 1)
    }

    /// 拖拽过程中决定要不要换边：鼠标明显更靠近另一条边才切。
    /// 距离相同时保持当前边，避免抖动。
    static func edgeAfterDrag(
        mouse: CGPoint,
        currentEdge: DockEdge,
        visibleFrame: CGRect
    ) -> DockEdge {
        func distance(_ edge: DockEdge) -> CGFloat {
            switch edge {
            case .left:   return mouse.x - visibleFrame.minX
            case .right:  return visibleFrame.maxX - mouse.x
            case .top:    return visibleFrame.maxY - mouse.y
            case .bottom: return mouse.y - visibleFrame.minY
            }
        }
        let nearest = EdgeDockGeometry.nearestEdge(to: mouse, in: visibleFrame)
        guard nearest != currentEdge else { return currentEdge }
        guard distance(nearest) + edgeSwitchMargin < distance(currentEdge) else { return currentEdge }
        return nearest
    }

    /// 第 `index` 行的**行中心**（dock frame 坐标系，AppKit 屏幕坐标，y 轴朝上）。
    ///
    /// 这里返回的是行中心而不是圆心：一行是"圆 + 下方数值"，行中心比圆心低 7pt。
    /// popover 纵向对齐到行中心比对齐圆心更稳，也不会因为数值文字的存在而看着偏上。
    ///
    /// **锚点约定必须和 `EdgeDockContentView` 的排版一致**，否则整列会上下翻转：
    /// - 竖排用 `VStack`，第 0 行渲染在**上方**（= `maxY`），所以从 `maxY` 往回减。
    /// - 横排用 `HStack`，第 0 列渲染在**左侧**（= `minX`），x 与 SwiftUI 同向，所以从
    ///   `minX` 往加。
    static func rowCenter(dockFrame: CGRect, edge: DockEdge, index: Int) -> CGPoint {
        if edge.isVertical {
            return CGPoint(
                x: dockFrame.midX,
                y: dockFrame.maxY - (padding + rowHeight / 2) - CGFloat(index) * rowStep
            )
        }
        return CGPoint(
            x: dockFrame.minX + (padding + diameter / 2) + CGFloat(index) * columnStep,
            y: dockFrame.midY
        )
    }

    /// 按常量推算的行矩形（**兜底**），屏幕坐标系，与 `dockFrame` 同一空间。
    ///
    /// 只在视图实测矩形不可用时用（见 `EdgeDockController.resolveRowRects`）。它会
    /// 因为猜错 SwiftUI 的文字行高而产生逐行累积的偏差，所以**只是兜底**：宁可偏差，
    /// 也不能让 hover 彻底失能——hover 失能会连带鼠标接管一起失效，拖拽也跟着死。
    static func rowRects(dockFrame: CGRect, edge: DockEdge, entryCount: Int) -> [CGRect] {
        (0..<max(entryCount, 0)).map { index in
            let center = rowCenter(dockFrame: dockFrame, edge: edge, index: index)
            // 行在堆叠轴上占 rowHeight，在另一轴上占 diameter（横排时交换）。
            // 行与行之间留出 spacing 的缝，由 `rowIndex` 的"最近中心"容差兜住。
            if edge.isVertical {
                return CGRect(
                    x: dockFrame.minX, y: center.y - rowHeight / 2,
                    width: dockFrame.width, height: rowHeight
                )
            }
            return CGRect(
                x: center.x - diameter / 2, y: dockFrame.minY,
                width: diameter, height: dockFrame.height
            )
        }
    }

    /// 第 `index` 个圆的**圆心**（dock frame 坐标系，AppKit 屏幕坐标，y 轴朝上）。
    ///
    /// 必须与 `EdgeDockContentView` 的排版一致：
    /// - 竖排用 `VStack`，第 0 行渲染在上方（= `maxY`），从 `maxY` 减去 padding 与半个圆径。
    /// - 横排用 `HStack`，第 0 列渲染在左侧（= `minX`），x 从 `minX` 加上 padding 与半个圆径，y 位于顶部圆环中心。
    static func circleCenter(dockFrame: CGRect, edge: DockEdge, index: Int) -> CGPoint {
        if edge.isVertical {
            return CGPoint(
                x: dockFrame.midX,
                y: dockFrame.maxY - (padding + diameter / 2) - CGFloat(index) * rowStep
            )
        }
        return CGPoint(
            x: dockFrame.minX + (padding + diameter / 2) + CGFloat(index) * columnStep,
            y: dockFrame.maxY - padding - diameter / 2
        )
    }

    /// 各圆的外接矩形（屏幕坐标系，与 `dockFrame` 同一空间）。
    static func circleRects(dockFrame: CGRect, edge: DockEdge, entryCount: Int) -> [CGRect] {
        (0..<max(entryCount, 0)).map { index in
            let center = circleCenter(dockFrame: dockFrame, edge: edge, index: index)
            return CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
    }

    /// popover 贴近 dock 摆放：紧贴被 hover 的圆，沿垂直于贴靠边的方向朝屏幕内侧展开。
    ///
    /// 展开方向与 dock 的贴靠方向相反（贴右边 → popover 往左长），保证内容朝屏幕内，
    /// 不会被推出可视区域；纵向以圆心对齐并钳在 visibleFrame 内。
    ///
    /// `measuredRowCenter`：**实测**行中心（屏幕坐标），有值时用它当纵向锚点。
    /// 必须传：下面的 `rowCenter` 兜底写死的是完整形态的常数（行距 38 + 16pt），
    /// 在简版 15pt 的行距下从第 2 行起就逐行错开，卡片会挂在一个看起来不属于它
    /// 的环上。实测矩形两种形态都上报（见 `EdgeDockContentView`），推算只留作
    /// "这一帧还没量到"时的兜底。
    static func popoverFrame(
        size: CGSize,
        dockFrame: CGRect,
        rowIndex: Int,
        edge: DockEdge,
        visibleFrame: CGRect,
        measuredRowCenter: CGPoint? = nil
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }
        let w = min(size.width, visibleFrame.width)
        let h = min(size.height, visibleFrame.height)
        let center = measuredRowCenter ?? rowCenter(dockFrame: dockFrame, edge: edge, index: rowIndex)

        let x: CGFloat
        let y: CGFloat
        if edge.isVertical {
            x = edge == .right ? dockFrame.minX - popoverGap - w : dockFrame.maxX + popoverGap
            y = center.y - h / 2
        } else {
            y = edge == .top ? dockFrame.minY - popoverGap - h : dockFrame.maxY + popoverGap
            x = center.x - w / 2
        }

        return CGRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - w),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - h),
            width: w,
            height: h
        )
    }
}

/// 边缘窗背景形状：**贴屏幕那一侧是反向（凹）圆角，朝屏幕内侧是常规圆角**。
///
/// 这才是"刘海"的形状：窗口齐边贴住屏幕，贴边侧的两个角被**挖掉**而不是补圆，
/// 于是屏幕边缘在上下两处向 dock 内凹进一块，像 iPhone 顶部那个缺口。
///
/// 四种形态的取舍（都踩过）：
/// - 半圆帽：像浮在屏幕上的一颗珠子，不贴边。
/// - 四角常规圆角：柔和，但贴边侧没有"缺口"，刘海感消失。
/// - 直角：太生硬。
/// - **本形态**：内侧圆润 + 贴边侧内凹。
///
/// 几何上凹角与凸角的圆心相同（都在 `w/2, h/2` 一带），区别只在走哪一段弧：
/// 凸角走"远离顶点"的长弧补满角落，凹角走"贴近顶点"的短弧把角落挖空。
/// 下面每条边都显式写全 4 段弧——这种镜像推导很容易写反，而写反后
/// boundingBox 仍然正确，只有角落包含性会变，必须靠测试钉住。
///
/// `cornerRadiusFactor` 取 0.4 而非 0.5：0.5 会退化成半圆帽，
/// 且 0.4 × 短边必然小于短边的一半，第一个圆永远不会被圆角切到。
struct EdgeDockTab: Shape {
    /// 决定哪一侧齐平。必须与 `EdgeDockGeometry.frame` 使用的贴靠边一致。
    let edge: DockEdge

    /// 朝屏幕内侧那一端的圆角半径 = 短边 × 该系数。
    static let cornerRadiusFactor: CGFloat = 0.37

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        // 只手写"贴屏侧在右边"这一种形状，其余三条边用仿射变换镜像/旋转得到。
        // 手写 4 组弧的镜像版本必错：起点对但方向搞反之后 boundingBox 依然正确，
        // 只有轮廓朝向会悄悄反过来——最难查的一类 bug。
        switch edge {
        case .right:
            return canonicalPath(width: rect.width, height: rect.height)
        case .left:
            let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0)
            return canonicalPath(width: rect.width, height: rect.height).applying(mirror)
        case .bottom:
            // 旋转 +90°（屏幕坐标 y 向下）：x' = -y + width，y' = x。
            let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.width, ty: 0)
            return canonicalPath(width: rect.height, height: rect.width).applying(rotate)
        case .top:
            // 旋转 -90°：x' = y，y' = -x + height。
            let rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)
            return canonicalPath(width: rect.height, height: rect.width).applying(rotate)
        }
    }

    /// 规范形状：**贴屏侧（右边）是直角，朝屏幕内侧（左边）是圆角**。
    ///
    /// 贴屏侧留直角是刻意的：窗口本就齐边贴住屏幕，直边与屏幕边缘连成一条线，
    /// 看起来是"从屏幕里长出来的一截"；如果那边也圆，会在屏幕与窗口之间露出
    /// 一条缝，黑块反而像浮在屏幕上方的一颗胶囊。
    private func canonicalPath(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        let r = min(width, height) * Self.cornerRadiusFactor

        // 遍历方向：顶边右→左，左边向下，底边左→右，最后沿贴屏侧直边闭合。
        // 两段弧的起止点必须与相邻直线的端点严格重合——角度写错时 Path 不会报错，
        // 只会在两个点之间连一条斜线，把整个角切掉，而且 boundingBox 仍然正确。
        path.move(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: r, y: 0))
        // 内侧上角：从 (r, 0) 到 (0, r)，角度递减
        path.addArc(
            center: CGPoint(x: r, y: r),
            radius: r,
            startAngle: .radians(Double.pi * 1.5),
            endAngle: .radians(Double.pi),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 0, y: height - r))
        // 内侧下角：从 (0, height - r) 到 (r, height)，角度递减
        path.addArc(
            center: CGPoint(x: r, y: height - r),
            radius: r,
            startAngle: .radians(Double.pi),
            endAngle: .radians(Double.pi / 2),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }
}

/// 边缘窗视觉常量。
///
/// 集中在这里而不是散在各个 View 里：换主题时只改这一处，dock 与 popover 会一起变。
enum EdgeDockTheme {
    /// popover 背板的圆角。
    static let popoverCornerRadius: CGFloat = 12

    /// popover **固定宽度**，由卡片里最宽的内容——7 天 token 图表——推导。
    ///
    /// 链路：图表 420pt → `ProviderCardView` 自身内边距 12×2 → popover 背板内边距
    /// 12×2 → 468。曾经直接取主菜单宽度 360：卡片内容区只剩 312pt，图表首尾两天的
    /// 柱被浮层整段裁掉——「宽度固定」防的是内容把窗口挤变形，前提是宽度一开始
    /// 就装得下最宽的内容。屏幕比它还窄时才钳位。
    static var popoverWidth: CGFloat {
        SevenDayUsageChartMetrics.pricedWidth
            + ProviderCardView.contentPadding * 2
            + popoverPadding * 2
    }

    /// popover 背板内边距。水平方向与主菜单卡片列的内边距同源，
    /// 这样 popover 里的卡片宽度与菜单里的卡片**逐像素相同**。
    static var popoverPadding: CGFloat { MenuPanelHeightBridge.cardHorizontalPadding }

    /// dock 液态玻璃的暗色压深。
    ///
    /// dock **钉死暗色**，不跟系统外观走：它和菜单栏图标、菜单面板一起常驻在
    /// 桌面上，跟着系统在白天/晚上翻转会让同一块边缘窗一天变两次观感，而环与
    /// 数值的对比度本来就应该只由一种底色决定。
    ///
    /// 0.34 是把"亮壁纸"和"暗壁纸"两种最坏情况都算过之后定的：更浅会在亮壁纸上
    /// 糊成一块灰、环的可读性随壁纸漂移；更深会把折射和描边细节整个盖掉，等于
    /// 又退回一块纯色板。
    static let dockGlassTint = Color.black.opacity(0.34)

    /// 圆环底槽（进度弧画在它上面）。
    ///
    /// 用 `Color.primary` 而不是写死白色：dock 的内容被强制在 `colorScheme = .dark`
    /// 下渲染（见 `ensurePanel`），`primary` 因此恒解析成浅色，和旧的写死白色等价，
    /// 但不再需要维护一个"因为 dock 不随外观变化所以写死"的特例。空槽消失之后，
    /// 50% 会被读成"环画断了"而不是"还剩一半"——用户读到的是**错的**数据，
    /// 而不只是难看的界面，所以底槽必须始终看得见。
    ///
    /// 不透明度 0.18（原来 0.16）：0.16 在亮壁纸透上来的玻璃上偏淡。
    static let ringTrack = Color.primary.opacity(0.18)

}

extension View {
    /// dock 背板：**常驻暗色液态玻璃**，不跟随系统外观。
    ///
    /// 与 popover 的区别是刻意的，不是没对齐：dock 常驻屏幕边缘，popover 是用户
    /// 点出来的临时浮层。前者固定暗色、后者跟随系统（见
    /// `edgeDockPopoverSystemMaterialBackground`）。
    ///
    /// macOS 26 及以上走 `glassEffect`——真正的液态玻璃，含折射与系统描边；
    /// 更早的系统没有这个 API，用 `ultraThinMaterial` 磨砂 + 一层暗色压深近似：
    /// 材质在下负责模糊，压深在上负责变暗，两层叠在同一个 ZStack 里。
    ///
    /// 玻璃要采样窗口**背后**的内容，所以前提是窗口透明（`isOpaque = false` +
    /// clear 背景）：不透明底色会让玻璃退化成一块死板的实色，`EdgeDockTab` 的
    /// 直角与圆角轮廓也看不见。
    ///
    /// 光这一层还不够：面板必须同时钉 `NSAppearance.vibrantDark`，内容必须同时
    /// 强制 `colorScheme = .dark`。只改 SwiftUI 环境不会让材质本身按暗色解析；
    /// 只改面板外观则 `Color.primary` 仍按系统浅色翻成深色——深底深字直接看不见。
    ///
    /// `@ViewBuilder`：两个分支（`glassEffect` / `background`）返回的是两个不同的
    /// 具体类型，只有 ViewBuilder 才能把它们合成 `_ConditionalContent`。
    @ViewBuilder
    func edgeDockDarkGlassBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(EdgeDockTheme.dockGlassTint), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(EdgeDockTheme.dockGlassTint)
                }
            }
        }
    }

    /// popover 背板：**系统材质**，跟随系统外观，圆角用 `popoverCornerRadius`。
    ///
    /// 目标是"和菜单弹出的一模一样"——菜单那层是 `MenuBarExtra(.window)` 窗口自带
    /// 的系统玻璃（`MenuPanelSurface` 因此只写 `Color.clear`）。但那个玻璃是 AppKit
    /// 给**那个特定窗口**的，自建的 borderless `NSPanel` 不会自动获得：写
    /// `Color.clear` 只会得到完全透明，背后直接是壁纸，没有模糊、没有玻璃。
    /// 所以这里显式挂 `.regularMaterial`——由系统决定深浅，跟着 `colorScheme`
    /// 自动变，**不需要任何手调浓度**。
    ///
    /// 卡片（`ProviderCardView`）画在它上面，和菜单那一屏共用同一套卡片表面，
    /// 所以这里只管材质，不再画自己的边界。
    func edgeDockPopoverSystemMaterialBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: EdgeDockTheme.popoverCornerRadius, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}
