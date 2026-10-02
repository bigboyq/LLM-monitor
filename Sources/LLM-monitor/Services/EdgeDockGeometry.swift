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
    /// 圆环下方常驻数值文字的**字号**（pt）。`labelHeight` 由它推导，两者不许各写一个。
    static let labelFontSize: CGFloat = 10
    /// 圆环下方常驻数值文字占用的高度（pt）。
    ///
    /// 略大于字号：10pt 系统字体的实际行高约 12pt，按字号取值会让字形在固定行框里
    /// 上下各溢出约 1pt（简版↔完整形态的行高动画会把它放大成可见的抖动）。
    /// 取 `字号 + 2` 是把这 2pt 余量显式算进行高，而不是指望 SwiftUI 居中后看不出来。
    static var labelHeight: CGFloat { labelFontSize + 2 }
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
    /// 内环（周窗口）线宽（pt）。
    ///
    /// 比外环细是**刻意的**：两环画一样粗时，内环像外环的复制品，"两个窗口"
    /// 读起来像同一条弧画了两遍。粗外 / 细内给出明确的层级——外环是主体、内环是
    /// 附注。取值 2.5（外环 3.5 的 ~0.71）而不是更细：内环直径只有外环的 0.72，
    /// 线宽再细就会在内环已经只有 2px 直径的环心上糊成灰点。
    static let innerRingLineWidth: CGFloat = 2.5

    /// hover 高亮的轻微放大倍数。
    ///
    /// `scaleEffect` 是纯视觉变换、不参与排版：行框、窗口尺寸、命中矩形都不变，
    /// 放大出的 1~2pt 落在四周 8pt 内边距里。只作用在圆环上、不缩放数值文字——
    /// 缩放整行会以行中心为锚把圆往数值一侧顶，hover 时整个 dock 看起来在跳。
    static let hoverScale: CGFloat = 1.10

    // MARK: 简版（自动隐藏模式的收起形态）常量
    //
    // 简版的目标是"常驻也不显眼"：没有数字、没有图标，只剩一枚小环，
    // 所以各项都明显小于完整版。三档之间是**整套**换掉的（环径、线宽、间距、
    // 内边距同步放大），只放大其中一两项会立刻看出"环变大了但排布没跟上"。

    /// 一档简版尺寸的全部度量。抽成值类型而不是四个平行函数：环径、线宽、间距、
    /// 内边距是**同一个决定**的四面，分成四处查表迟早只改其中一面。
    struct CompactMetrics {
        let diameter: CGFloat
        let spacing: CGFloat
        let padding: CGFloat
        let ringLineWidth: CGFloat

        /// 相邻两个圆心之间的距离（行距）= 环径 + 间距。
        var rowStep: CGFloat { diameter + spacing }

        /// 贴边方向的窗口总厚度 = 环径 + 内边距 ×2。
        var thickness: CGFloat { diameter + padding * 2 }
    }

    /// 查某一档简版的尺寸。
    ///
    /// 三档的取值都是算出来的，不是"看着差不多"：线宽不能细到在浅色玻璃上消失
    /// （≥1.5），也不能粗到吃掉环心（×2 < 环径）；贴边厚度必须严格小于完整版的
    /// 70pt，否则"收起"反而比展开更占地方；行距的一半是逐行 hover 的判定半径
    /// 下限，必须 ≥7.5pt 才够手指指。这些不等式由 `EdgeDockGeometryTests` 钉住。
    static func compactMetrics(for size: EdgeDockCompactSize) -> CompactMetrics {
        switch size {
        case .small:  return CompactMetrics(diameter: 7, spacing: 8, padding: 7, ringLineWidth: 2.5)
        case .medium: return CompactMetrics(diameter: 11, spacing: 10, padding: 10, ringLineWidth: 3.5)
        case .large:  return CompactMetrics(diameter: 14, spacing: 12, padding: 12, ringLineWidth: 4)
        }
    }

    /// 简版相邻两个圆心之间的距离（行距，pt）。
    ///
    /// 「小圆环」形态逐行 hover 时用它的一半做判定半径下限（见
    /// `EdgeDockController.circleIndex`）：小档 7pt 的圆按圆判定要指中一个 7px 的点，
    /// 半个行距则刚好让相邻两环的判定区在中点接上。
    static func compactRowStep(for size: EdgeDockCompactSize) -> CGFloat {
        compactMetrics(for: size).rowStep
    }

    // 无参版本 = 默认档的转发。给"确实不关心档位"的读者（绝大多数完整形态的
    // 调用点、以及只关心默认行为的老测试）留一个短写法；**任何简版路径都必须
    // 显式传档位**——下面的兜底推算漏传档位的后果是整列圆按小档尺寸算，
    // 命中与卡片定位会逐行错开。

    /// 简版单环直径（pt），默认档。
    static var compactDiameter: CGFloat { compactMetrics(for: .default).diameter }
    /// 简版相邻两环的间距（pt），默认档。
    static var compactSpacing: CGFloat { compactMetrics(for: .default).spacing }
    /// 简版的内边距（pt），默认档。
    static var compactPadding: CGFloat { compactMetrics(for: .default).padding }
    /// 简版环线宽（pt），默认档。
    static var compactRingLineWidth: CGFloat { compactMetrics(for: .default).ringLineWidth }
    /// 简版行距（pt），默认档。
    static var compactRowStep: CGFloat { compactRowStep(for: .default) }

    /// 按条目数量算出贴边状态下窗口的尺寸。
    ///
    /// 尺寸必须和 `EdgeDockContentView` 的实际排版一致：竖排是 `VStack`（沿 y 堆叠，
    /// 每项占 `rowHeight`），横排是 `HStack`（沿 x 堆叠，每项占 `diameter`）。
    /// 厚度那一轴在竖排时是圆宽、在横排时是行高——因为数值文字在圆的**下方**，
    /// 两种朝向下列高都是 `rowHeight`。简版没有数值文字，厚度轴退化为
    /// `compactDiameter + compactPadding`。
    static func dockSize(
        entryCount: Int,
        edge: DockEdge,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> CGSize {
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
            let m = compactMetrics(for: compactSize)
            let gaps = CGFloat(max(entryCount - 1, 0)) * m.spacing
            let along = n * m.diameter + gaps + m.padding * 2
            return edge.isVertical
                ? CGSize(width: m.thickness, height: along)
                : CGSize(width: along, height: m.thickness)
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
        // 窗口两个轴都要各自钳到可用区——不按朝向分叉，竖排横排用的是同一句。
        let clamped = CGSize(
            width: min(dockSize.width, visibleFrame.width),
            height: min(dockSize.height, visibleFrame.height)
        )
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
    /// 这里返回的是行中心而不是圆心：一行是"圆 + 下方数值"，竖排时行中心比圆心
    /// 低 `(labelSpacing + labelHeight) / 2` = 8pt（当前行高 54 vs 圆径 38）。
    /// popover 纵向对齐到行中心比对齐圆心更稳，也不会因为数值文字的存在而看着偏上。
    ///
    /// **锚点约定必须和 `EdgeDockContentView` 的排版一致**，否则整列会上下翻转：
    /// - 竖排用 `VStack`，第 0 行渲染在**上方**（= `maxY`），所以从 `maxY` 往回减。
    /// - 横排用 `HStack`，第 0 列渲染在**左侧**（= `minX`），x 与 SwiftUI 同向，所以从
    ///   `minX` 往加。
    static func rowCenter(
        dockFrame: CGRect,
        edge: DockEdge,
        index: Int,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> CGPoint {
        // 竖排用**行高**做锚：完整形态行高 = 圆 38 + 间距 4 + 数值 12 = 54，
        // 行中心因此比圆心低 (54 − 38)/2 = 8pt；简版没有数值文字，行高退化成
        // 圆径，行中心就是圆心。
        // 横排用**圆径**做锚、按**列距**步进：数值在圆的下方，不吃横排的列宽。
        // 三套量都随形态与简版档位切换，不能拿完整形态的常数去推 15pt 行距的简版。
        let lead: CGFloat
        let rowH: CGFloat
        let dia: CGFloat
        switch appearance {
        case .full:    (lead, rowH, dia) = (padding, rowHeight, diameter)
        case .compact:
            let m = compactMetrics(for: compactSize)
            (lead, rowH, dia) = (m.padding, m.diameter, m.diameter)
        }
        let along = CGFloat(index) * step(for: appearance, edge: edge, compactSize: compactSize)
        if edge.isVertical {
            return CGPoint(x: dockFrame.midX, y: dockFrame.maxY - (lead + rowH / 2) - along)
        }
        return CGPoint(x: dockFrame.minX + (lead + dia / 2) + along, y: dockFrame.midY)
    }

    /// 相邻两个条目在**堆叠轴**上的步进，按朝向与形态取值。
    ///
    /// 完整形态下竖排（`rowStep` 70）与横排（`columnStep` 54）**差 16pt**：数值
    /// 文字挂在圆的下方，所以横排一列的宽度是圆宽而不是行高。简版没有数值文字，
    /// 两者都退化成 `compactRowStep`。
    ///
    /// 单独抽出来是因为"竖排用行距、横排用列距"这条规则在 `circleCenter` 与
    /// `rowCenter` 两处都要用，写成 `edge.isVertical ? a : b` 各写一遍最容易在
    /// 改其中一处时漏掉另一处——那正是本函数被抽出来的原因。
    private static func step(
        for appearance: DockAppearance,
        edge: DockEdge,
        compactSize: EdgeDockCompactSize = .default
    ) -> CGFloat {
        switch appearance {
        case .full:    return edge.isVertical ? rowStep : columnStep
        case .compact: return compactRowStep(for: compactSize)
        }
    }

    /// 按常量推算的行矩形（**兜底**），屏幕坐标系，与 `dockFrame` 同一空间。
    ///
    /// 只在视图实测矩形不可用时用（见 `EdgeDockController.resolveRowRects`）。它会
    /// 因为猜错 SwiftUI 的文字行高而产生逐行累积的偏差，所以**只是兜底**：宁可偏差，
    /// 也不能让 hover 彻底失能——hover 失能会连带鼠标接管一起失效，拖拽也跟着死。
    ///
    /// `appearance` 与 `circleRects` 同理：简版没有数值文字，行高退化成
    /// `compactDiameter`，行距是 `compactRowStep`。不带上它就会按 70pt 的行距去推
    /// 15pt 行距的简版，从第 2 行起逐行错开，详情卡片会挂在一个看起来不属于它的环上。
    static func rowRects(
        dockFrame: CGRect,
        edge: DockEdge,
        entryCount: Int,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> [CGRect] {
        let compact = compactMetrics(for: compactSize)
        let across = appearance == .full ? diameter : compact.diameter
        let rowH = appearance == .full ? rowHeight : compact.diameter
        return (0..<max(entryCount, 0)).map { index in
            let center = rowCenter(
                dockFrame: dockFrame, edge: edge, index: index,
                appearance: appearance, compactSize: compactSize
            )
            if edge.isVertical {
                // 竖排：行在堆叠轴上占**行高**，在另一轴上铺满窗口厚度。
                return CGRect(
                    x: dockFrame.minX, y: center.y - rowH / 2,
                    width: dockFrame.width, height: rowH
                )
            }
            // 横排：行在堆叠轴上占**圆径**——数值文字在圆的下方，不吃列宽。
            return CGRect(
                x: center.x - across / 2, y: dockFrame.minY,
                width: across, height: dockFrame.height
            )
        }
    }

    /// 第 `index` 个圆的**圆心**（dock frame 坐标系，AppKit 屏幕坐标，y 轴朝上）。
    ///
    /// 必须与 `EdgeDockContentView` 的排版一致：
    /// - 竖排用 `VStack`，第 0 行渲染在上方（= `maxY`），从 `maxY` 减去 padding 与半个圆径。
    /// - 横排用 `HStack`，第 0 列渲染在左侧（= `minX`），x 从 `minX` 加上 padding 与半个圆径，y 位于顶部圆环中心。
    ///
    /// `appearance` 决定用哪一套尺寸常量：简版的圆径、行距、内边距按**档位**取
    /// （7~14pt / 15~26pt / 7~12pt），与完整形态（38 / 70 / 16）毫无关系。
    /// **兜底路径必须显式带上它**——按完整形态的常数去推算简版，第 0 行会偏出
    /// 约 24pt，命中到隔壁那个 provider。
    ///
    /// 步进**分朝向**：竖排是 `rowStep`（行高 + 行间距），横排是 `columnStep`
    /// （圆宽 + 列间距）——两者在完整形态下差 16pt（数值文字在圆的**下方**，横排
    /// 的列宽不吃行高）。简版没有数值文字，两者都等于 `compactRowStep`。
    static func circleCenter(
        dockFrame: CGRect,
        edge: DockEdge,
        index: Int,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> CGPoint {
        let inset: CGFloat
        switch appearance {
        case .full:      inset = padding + diameter / 2
        case .compact:
            let m = compactMetrics(for: compactSize)
            inset = m.padding + m.diameter / 2
        }
        let along = CGFloat(index) * step(for: appearance, edge: edge, compactSize: compactSize)
        if edge.isVertical {
            return CGPoint(x: dockFrame.midX, y: dockFrame.maxY - inset - along)
        }
        return CGPoint(x: dockFrame.minX + inset + along, y: dockFrame.maxY - inset)
    }

    /// 各圆的外接矩形（屏幕坐标系，与 `dockFrame` 同一空间）。
    static func circleRects(
        dockFrame: CGRect,
        edge: DockEdge,
        entryCount: Int,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> [CGRect] {
        let dia = appearance == .full ? diameter : compactMetrics(for: compactSize).diameter
        return (0..<max(entryCount, 0)).map { index in
            let center = circleCenter(
                dockFrame: dockFrame, edge: edge, index: index,
                appearance: appearance, compactSize: compactSize
            )
            return CGRect(
                x: center.x - dia / 2,
                y: center.y - dia / 2,
                width: dia,
                height: dia
            )
        }
    }

    /// popover 贴近 dock 摆放：紧贴被 hover 的圆，沿垂直于贴靠边的方向朝屏幕内侧展开。
    ///
    /// 展开方向与 dock 的贴靠方向相反（贴右边 → popover 往左长），保证内容朝屏幕内，
    /// 不会被推出可视区域；纵向以圆心对齐并钳在 visibleFrame 内。
    ///
    /// `measuredRowCenter`：**实测**行中心（屏幕坐标），有值时用它当纵向锚点。
    /// 实测矩形两种形态都上报（见 `EdgeDockContentView`），所以它实际上总有值。
    ///
    /// `appearance` 只服务于下面那个 `rowCenter` 兜底：完整形态的行距是 70（行高
    /// 54 + 间距 16），简版是 15。按完整形态的常数去推简版，从第 2 行起就逐行错开，
    /// 卡片会挂在一个看起来不属于它的环上——与 `circleRects` / `rowRects` 同一个坑，
    /// 三个兜底必须一起修。
    static func popoverFrame(
        size: CGSize,
        dockFrame: CGRect,
        rowIndex: Int,
        edge: DockEdge,
        visibleFrame: CGRect,
        measuredRowCenter: CGPoint? = nil,
        appearance: DockAppearance = .full,
        compactSize: EdgeDockCompactSize = .default
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }
        let w = min(size.width, visibleFrame.width)
        let h = min(size.height, visibleFrame.height)
        let center = measuredRowCenter
            ?? rowCenter(
                dockFrame: dockFrame, edge: edge, index: rowIndex,
                appearance: appearance, compactSize: compactSize
            )

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

/// 边缘窗背板形状：**贴屏幕那一侧走直边，朝屏幕内侧两端是圆角**。
///
/// 直边与屏幕边缘连成一条线，看起来是"从屏幕里长出来的一截"；那边若也圆，会在
/// 屏幕与窗口之间露出一条缝，黑块反而像浮在屏幕上方的一颗胶囊。
///
/// 几种替代形态（都踩过）：
/// - 贴边侧挖成凹角（iPhone 那种刘海缺口）：语义上更"贴边"，但窗口本就与屏幕
///   齐平，挖角只会在贴边侧的两端多出两小块悬空——在 20pt 厚的简版里几乎看不见，
///   却让背板轮廓在角落处变得难以辨认。
/// - 半圆帽：像浮在屏幕上的一颗珠子，不贴边。
/// - 四角常规圆角：柔和，但贴边侧没有直边，贴边感消失。
/// - **本形态**：内侧圆润 + 贴边侧直边。
///
/// 两端圆角与贴边直边**不是镜像推导出来的**：只手写"贴屏侧在右边"这一种形状，
/// 其余三条边用仿射变换（`CGAffineTransform`）旋转/镜像得到——手写四组弧的镜像
/// 版本几乎必错，而写反之后 boundingBox 仍然正确、只有角落包含性会变，
/// 属于最难查的一类 bug，所以 `path(in:)` 的镜像结果由测试钉住。
///
/// `cornerRadiusFactor` 取 0.37 而非 0.5：0.5 会退化成半圆帽；0.37 × 短边
/// 必然小于短边的一半（0.37 < 0.5），所以内侧第一个圆永远不会被圆角切到。
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
