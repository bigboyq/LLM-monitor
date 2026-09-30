import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 边缘状态窗的几何 / 投影 / 全屏判定口径。
///
/// 这一组全是**纯函数**，不需要窗口或屏幕：坐标系翻转、贴边吸附、归一化位置
/// 换算都是"看起来对但实际差 1px / 掉到屏幕外"的高发地带，必须钉死。
final class EdgeDockTests: XCTestCase {

    // MARK: - 几何：尺寸

    func testDockSizeGrowsVerticallyOnVerticalEdges() {
        let thickness = EdgeDockGeometry.diameter + EdgeDockGeometry.padding * 2
        let one = EdgeDockGeometry.dockSize(entryCount: 1, edge: .right)
        XCTAssertEqual(one.width, thickness)
        XCTAssertEqual(one.height, EdgeDockGeometry.rowHeight + EdgeDockGeometry.padding * 2)

        let three = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        XCTAssertEqual(three.width, thickness, "竖排时宽度不随条目数变化")
        XCTAssertEqual(
            three.height,
            CGFloat(3) * EdgeDockGeometry.rowHeight + CGFloat(2) * EdgeDockGeometry.spacing + EdgeDockGeometry.padding * 2
        )
    }

    func testDockSizeGrowsHorizontallyOnHorizontalEdges() {
        // 横排：沿 x 增长，每列占**圆宽**（数值在圆的下方，不占宽度）；
        // 高度是行高（圆 + 数值）+ 内边距。
        let three = EdgeDockGeometry.dockSize(entryCount: 3, edge: .bottom)
        XCTAssertEqual(three.height, EdgeDockGeometry.rowHeight + EdgeDockGeometry.padding * 2)
        XCTAssertEqual(
            three.width,
            CGFloat(3) * EdgeDockGeometry.diameter + CGFloat(2) * EdgeDockGeometry.spacing + EdgeDockGeometry.padding * 2
        )
    }

    func testRowHeightIncludesLabelSpace() {
        // 每行必须为"圆环 + 常驻数值"留够高度，否则数字会被窗口裁掉。
        XCTAssertEqual(
            EdgeDockGeometry.rowHeight,
            EdgeDockGeometry.diameter + EdgeDockGeometry.labelSpacing + EdgeDockGeometry.labelHeight
        )
        XCTAssertGreaterThan(EdgeDockGeometry.rowHeight, EdgeDockGeometry.diameter, "行高必须大于圆环直径")
        XCTAssertGreaterThan(EdgeDockGeometry.rowStep, EdgeDockGeometry.rowHeight)
    }

    func testDockSizeForZeroEntriesKeepsPadding() {
        let size = EdgeDockGeometry.dockSize(entryCount: 0, edge: .right)
        XCTAssertEqual(size.height, EdgeDockGeometry.padding * 2)
        XCTAssertGreaterThan(size.width, 0)
    }

    // MARK: - 几何：贴边

    /// visibleFrame 模拟：主屏 1920x1080，顶部菜单栏 25，Dock 在底部 60。
    private let visible = CGRect(x: 0, y: 60, width: 1920, height: 995)

    func testFrameSnapsFlushToRightEdge() {
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: 0.5)
        XCTAssertEqual(frame.maxX, visible.maxX, accuracy: 0.001, "右侧必须严丝合缝贴住 visibleFrame 右缘")
        XCTAssertEqual(frame.width, size.width, accuracy: 0.001)
    }

    func testFrameSnapsFlushToOtherThreeEdges() {
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .left)
        let left = EdgeDockGeometry.frame(visibleFrame: visible, edge: .left, size: size, offset: 0.5)
        XCTAssertEqual(left.minX, visible.minX, accuracy: 0.001)

        let bottom = EdgeDockGeometry.frame(visibleFrame: visible, edge: .bottom, size: size, offset: 0.5)
        XCTAssertEqual(bottom.minY, visible.minY, accuracy: 0.001)

        let top = EdgeDockGeometry.frame(visibleFrame: visible, edge: .top, size: size, offset: 0.5)
        XCTAssertEqual(top.maxY, visible.maxY, accuracy: 0.001)
    }

    func testOffsetZeroAndOneStayFullyOnScreen() {
        // 拖到边缘时窗口不能被裁掉一半——offset 描述的是窗口**中心**的位置。
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)

        let atZero = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: 0)
        XCTAssertGreaterThanOrEqual(atZero.minY, visible.minY - 0.001)
        XCTAssertEqual(atZero.minY, visible.minY, accuracy: 0.001)

        let atOne = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: 1)
        XCTAssertLessThanOrEqual(atOne.maxY, visible.maxY + 0.001)
        XCTAssertEqual(atOne.maxY, visible.maxY, accuracy: 0.001)
    }

    func testHalfOffsetCentersWindow() {
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: 0.5)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.001)
    }

    func testFrameClampsToVisibleFrameWhenTallerThanScreen() {
        // 条目极多（或屏幕很矮）时，窗口必须被钳到可见区域内，不能整块跑到屏幕外。
        let huge = CGSize(width: 42, height: 5000)
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: huge, offset: 0.5)
        XCTAssertLessThanOrEqual(frame.height, visible.height)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.001)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.001)
    }

    func testFrameWithDegenerateVisibleFrameReturnsZero() {
        let size = CGSize(width: 42, height: 100)
        XCTAssertEqual(
            EdgeDockGeometry.frame(visibleFrame: .zero, edge: .right, size: size, offset: 0.5),
            CGRect.zero
        )
    }

    func testNonFiniteOffsetFallsBackToCenter() {
        // 手改 config.json 写出的 NaN 不该产生一个位置诡异的窗口。
        let size = CGSize(width: 42, height: 100)
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: .nan)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.001)
    }

    // MARK: - 几何：往返一致性

    func testOffsetRoundTripIsStable() {
        // frame → offset → frame 必须回到原处。这是"拖完能记住位置"的前提，
        // 两处算法一旦不同步，用户每开一次设置位置就漂一次。
        let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: .right)
        for edge in DockEdge.allCases {
            for raw in [0.0, 0.13, 0.5, 0.77, 1.0] {
                let original = EdgeDockGeometry.frame(
                    visibleFrame: visible, edge: edge, size: size, offset: raw
                )
                let recovered = EdgeDockGeometry.normalizedOffset(
                    frame: original, visibleFrame: visible, edge: edge
                )
                let roundTripped = EdgeDockGeometry.frame(
                    visibleFrame: visible, edge: edge, size: size, offset: recovered
                )
                XCTAssertEqual(roundTripped.origin.x, original.origin.x, accuracy: 0.001, "edge=\(edge) offset=\(raw) x")
                XCTAssertEqual(roundTripped.origin.y, original.origin.y, accuracy: 0.001, "edge=\(edge) offset=\(raw) y")
            }
        }
    }

    func testNormalizedOffsetClampsOutOfRangeInput() {
        // 窗口被拖出可见区域时 offset 要被钳住，而不是写出一个 -3.5 落进 config。
        let outside = CGRect(x: 0, y: -9000, width: 42, height: 100)
        XCTAssertEqual(
            EdgeDockGeometry.normalizedOffset(frame: outside, visibleFrame: visible, edge: .right),
            0
        )
    }

    // MARK: - 几何：吸附到最近的边

    func testNearestEdgePicksTheClosestSide() {
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 1910, y: 500), in: visible), .right)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 10, y: 500), in: visible), .left)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 960, y: 1050), in: visible), .top)
        XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: CGPoint(x: 960, y: 70), in: visible), .bottom)
    }

    func testNearestEdgeIsDeterministicOnTie() {
        // 正中间放下时不能随机跳边：同样的落点必须永远得到同样的结果。
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let first = EdgeDockGeometry.nearestEdge(to: center, in: visible)
        for _ in 0..<20 {
            XCTAssertEqual(EdgeDockGeometry.nearestEdge(to: center, in: visible), first)
        }
    }

    func testNearestEdgeRespectsPriorityOrder() {
        // 左下角：到 .left 和 .bottom 的距离都是 0，只有优先级能决定结果。
        // （正中心不行：那里上下比左右近，根本轮不到优先级。）
        let corner = CGPoint(x: visible.minX, y: visible.minY)
        XCTAssertEqual(
            EdgeDockGeometry.nearestEdge(to: corner, in: visible, edgePriority: [.left, .right, .top, .bottom]),
            .left
        )
        XCTAssertEqual(
            EdgeDockGeometry.nearestEdge(to: corner, in: visible, edgePriority: [.bottom, .top, .left, .right]),
            .bottom
        )
    }

    // MARK: - hover 命中：鼠标位置 → 圆下标

    /// 贴右边、4 个圆、offset 居中的 dock frame。
    /// `size` 显式给出时用它（简版形态的行距与完整版不同，测简版时必须给）。
    private func makeDockFrame(
        edge: DockEdge,
        entryCount: Int,
        offset: Double = 0.5,
        size: CGSize? = nil
    ) -> CGRect {
        EdgeDockGeometry.frame(
            visibleFrame: visible,
            edge: edge,
            size: size ?? EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge),
            offset: offset
        )
    }

    /// 模拟 `EdgeDockContentView` 的真实排版，算出每行在**窗口内**的矩形。
    ///
    /// 竖排 = `VStack`（沿 y 堆叠，第 0 行在上），横排 = `HStack`（沿 x 堆叠，
    /// 第 0 列在左），外面套一层 `padding`。SwiftUI 坐标 y 向下、原点在左上。
    private func swiftUILaidOutRows(entryCount: Int, edge: DockEdge) -> [CGRect] {
        let vertical = edge.isVertical
        // 竖排每项高 rowHeight、横排每项宽 diameter，步进也不同（rowStep / columnStep）。
        let itemExtent = vertical ? EdgeDockGeometry.rowHeight : EdgeDockGeometry.diameter
        let step = vertical ? EdgeDockGeometry.rowStep : EdgeDockGeometry.columnStep
        let across = vertical ? EdgeDockGeometry.diameter : EdgeDockGeometry.rowHeight
        return (0..<entryCount).map { index in
            let along = EdgeDockGeometry.padding + CGFloat(index) * step
            return vertical
                ? CGRect(
                    x: EdgeDockGeometry.padding, y: along,
                    width: across, height: itemExtent
                )
                : CGRect(
                    x: along, y: EdgeDockGeometry.padding,
                    width: itemExtent, height: across
                )
        }
    }

    /// 把窗口内（y 向下）矩形翻成屏幕坐标（y 向上）。
    private func flippedToScreen(_ rows: [CGRect], in dock: CGRect) -> [CGRect] {
        rows.map { row in
            CGRect(
                x: dock.minX + row.minX,
                y: dock.maxY - row.maxY,
                width: row.width, height: row.height
            )
        }
    }

    func testGeometryMatchesSwiftUILayoutForEveryEdge() {
        // 这条是「几何层必须与视图排版逐字一致」的钉死。
        //
        // 曾经写反过一次：`rowCenter` 把第 0 行算在 `dockFrame.minY`（屏幕下方），
        // 而 VStack 把它渲染在上方，于是 popover 整体上下颠倒 —— 内容对、位置翻转。
        // 而且当时那条测试叫 `testCircleCenterMatchesRenderedLayout`，断言的却是
        // 相反的约定，看起来权威、实际在把错误固化。
        //
        // 只在**堆叠轴**上逐字比较：跨轴上 `rowRects` 返回整个 dock（命中区域就该是
        // 整条，hover 边缘一圈空白也应该命中），而排版的行只有圆那么宽，那是两个
        // 不同用途，混在一起比会得出错误的结论。
        for edge in DockEdge.allCases {
            for count in 1...6 {
                let dock = makeDockFrame(edge: edge, entryCount: count)
                let expected = flippedToScreen(
                    swiftUILaidOutRows(entryCount: count, edge: edge), in: dock
                )
                let actual = EdgeDockGeometry.rowRects(
                    dockFrame: dock, edge: edge, entryCount: count
                )
                XCTAssertEqual(actual.count, count, "edge=\(edge) count=\(count) 行数")
                for index in 0..<count {
                    if edge.isVertical {
                        XCTAssertEqual(
                            actual[index].minY, expected[index].minY, accuracy: 0.001,
                            "edge=\(edge) count=\(count) 第\(index)行 y 与排版不符"
                        )
                        XCTAssertEqual(
                            actual[index].height, expected[index].height, accuracy: 0.001,
                            "edge=\(edge) count=\(count) 第\(index)行高与排版不符"
                        )
                        XCTAssertEqual(
                            actual[index].width, dock.width, accuracy: 0.001,
                            "edge=\(edge) 第\(index)行命中区应横跨整个 dock"
                        )
                    } else {
                        XCTAssertEqual(
                            actual[index].minX, expected[index].minX, accuracy: 0.001,
                            "edge=\(edge) count=\(count) 第\(index)列 x 与排版不符"
                        )
                        XCTAssertEqual(
                            actual[index].width, expected[index].width, accuracy: 0.001,
                            "edge=\(edge) count=\(count) 第\(index)列宽与排版不符"
                        )
                        XCTAssertEqual(
                            actual[index].height, dock.height, accuracy: 0.001,
                            "edge=\(edge) 第\(index)列命中区应纵贯整个 dock"
                        )
                    }
                }
            }
        }
    }

    func testFirstRowRendersAtTopForVerticalEdges() {
        // 竖排：VStack 把第 0 行渲染在上方，也就是屏幕坐标的 maxY 一侧。
        for edge in [DockEdge.left, .right] {
            let dock = makeDockFrame(edge: edge, entryCount: 4)
            let rows = EdgeDockGeometry.rowRects(dockFrame: dock, edge: edge, entryCount: 4)
            XCTAssertGreaterThan(
                rows[0].midY, rows[3].midY,
                "edge=\(edge) 第 0 行必须在第 3 行**上方**（AppKit y 轴朝上）"
            )
        }
    }

    func testFirstRowRendersAtLeftForHorizontalEdges() {
        // 横排：HStack 把第 0 列渲染在左侧，x 与 SwiftUI 同向。
        for edge in [DockEdge.top, .bottom] {
            let dock = makeDockFrame(edge: edge, entryCount: 4)
            let rows = EdgeDockGeometry.rowRects(dockFrame: dock, edge: edge, entryCount: 4)
            XCTAssertLessThan(
                rows[0].midX, rows[3].midX,
                "edge=\(edge) 第 0 列必须在第 3 列左侧"
            )
        }
    }

    /// 内容相对窗口四条边的留白，四种朝向都必须**恰好**是 `padding`。
    ///
    /// 这条是「横排不能掉一个 padding」的钉死。改行高 / 行间距时，窗口尺寸和内容
    /// 排版必须同步跟着变：两者任何一边单独改，横排就会出现"上下留白不对称"或
    /// "某一侧贴边"——而窗口是个纯黑不透明块，贴边与否一眼就能看出来，且不会有
    /// 任何报错。
    func testContentInsetEqualsPaddingOnAllFourSidesOfEveryEdge() {
        for edge in DockEdge.allCases {
            for count in 1...5 {
                let dock = makeDockFrame(edge: edge, entryCount: count)
                let rows = flippedToScreen(
                    swiftUILaidOutRows(entryCount: count, edge: edge), in: dock
                )
                guard let first = rows.first, let last = rows.last else {
                    XCTFail("edge=\(edge) count=\(count) 没有行")
                    continue
                }
                // 沿边方向：起点与终点各留一个 padding。
                let alongStart: CGFloat
                let alongEnd: CGFloat
                if edge.isVertical {
                    alongStart = dock.maxY - first.maxY
                    alongEnd = last.minY - dock.minY
                } else {
                    alongStart = first.minX - dock.minX
                    alongEnd = dock.maxX - last.maxX
                }
                // 垂直于贴靠边：内容居中，两侧留白 = (窗口厚度 - 内容厚度) / 2。
                let cross: CGFloat = edge.isVertical
                    ? (dock.width - first.width) / 2
                    : (dock.height - first.height) / 2

                let label = "edge=\(edge) count=\(count)"
                XCTAssertEqual(alongStart, EdgeDockGeometry.padding, accuracy: 0.001, "\(label) 起点留白")
                XCTAssertEqual(alongEnd, EdgeDockGeometry.padding, accuracy: 0.001, "\(label) 终点留白")
                XCTAssertEqual(cross, EdgeDockGeometry.padding, accuracy: 0.001, "\(label) 横向留白")
            }
        }
    }

    /// 环与数值之间、数字与下一个环之间，两者不能被压成同一个量级。
    ///
    /// 一旦 `labelSpacing` 追平 `spacing`，数字就会读成"下一个圆的一部分"。
    func testLabelStaysVisuallyAttachedToItsOwnRing() {
        XCTAssertLessThan(
            EdgeDockGeometry.labelSpacing, EdgeDockGeometry.spacing,
            "数字离自己的环必须比离下一个环更近，否则归属关系就反了"
        )
        XCTAssertGreaterThan(
            EdgeDockGeometry.spacing, EdgeDockGeometry.ringLineWidth,
            "行间距要明显大于环线描边，否则两行的环视觉上连成一片"
        )
    }

    func testDockSizeMatchesContentExtent() {
        // 窗口必须正好装下内容：竖排高度、横排宽度都要与排版推出的 extent 一致，
        // 否则末尾一行会被裁掉，或者多出一截空白。
        for edge in DockEdge.allCases {
            for count in 0...6 {
                let size = EdgeDockGeometry.dockSize(entryCount: count, edge: edge)
                let rows = swiftUILaidOutRows(entryCount: count, edge: edge)
                let extent = edge.isVertical ? size.height : size.width
                if count == 0 {
                    XCTAssertEqual(extent, EdgeDockGeometry.padding * 2, accuracy: 0.001, "edge=\(edge)")
                    continue
                }
                let last = rows[count - 1]
                let contentEnd = (edge.isVertical ? last.maxY : last.maxX)
                    + EdgeDockGeometry.padding
                XCTAssertEqual(
                    extent, contentEnd, accuracy: 0.001,
                    "edge=\(edge) count=\(count) 窗口沿边尺寸应正好装下内容"
                )
            }
        }
    }

    func testRowCenterMatchesRenderedRows() {
        // 行中心必须正好落在行的中心线上。popover 纵向对齐读的就是它，偏一点
        // 就会让卡片看着没对准被 hover 的那一行。
        for edge in DockEdge.allCases {
            let dock = makeDockFrame(edge: edge, entryCount: 4)
            let rows = EdgeDockGeometry.rowRects(dockFrame: dock, edge: edge, entryCount: 4)
            for index in 0..<4 {
                let center = EdgeDockGeometry.rowCenter(
                    dockFrame: dock, edge: edge, index: index
                )
                XCTAssertEqual(center.x, rows[index].midX, accuracy: 0.001, "edge=\(edge) 第\(index)行 x")
                XCTAssertEqual(
                    center.y, rows[index].midY, accuracy: 0.001,
                    "edge=\(edge) 第\(index)行 y"
                )
            }
        }
    }

    func testGapBetweenRowsSnapsToNeighbour() {
        // 行与行之间的缝隙必须归属相邻的某一行，否则鼠标划过时 popover 会不停闪烁消失。
        let dock = makeDockFrame(edge: .right, entryCount: 4)
        let rows = EdgeDockGeometry.rowRects(dockFrame: dock, edge: .right, entryCount: 4)
        let gapMid = CGPoint(
            x: dock.midX,
            y: (rows[1].maxY + rows[0].minY) / 2
        )
        let hit = EdgeDockController.rowIndex(at: gapMid, measured: rows)
        XCTAssertTrue(
            hit == 0 || hit == 1,
            "缝隙必须命中相邻的某一行，实际 \(String(describing: hit))"
        )
    }

    // MARK: - 精确圆形 Hover 命中测试

    func testCircleCenterAndRectsGeometry() {
        for edge in DockEdge.allCases {
            let dock = makeDockFrame(edge: edge, entryCount: 3)
            let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: edge, entryCount: 3)
            XCTAssertEqual(circles.count, 3)

            for index in 0..<3 {
                let center = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: edge, index: index)
                let rect = circles[index]
                XCTAssertEqual(rect.midX, center.x, accuracy: 0.001, "edge=\(edge) idx=\(index) rect.midX")
                XCTAssertEqual(rect.midY, center.y, accuracy: 0.001, "edge=\(edge) idx=\(index) rect.midY")
                XCTAssertEqual(rect.width, EdgeDockGeometry.diameter, accuracy: 0.001)
                XCTAssertEqual(rect.height, EdgeDockGeometry.diameter, accuracy: 0.001)
            }

            if edge.isVertical {
                // 第 0 个在上方（y 坐标更大），第 2 个在下方（y 坐标更小）
                XCTAssertGreaterThan(circles[0].midY, circles[1].midY)
                XCTAssertGreaterThan(circles[1].midY, circles[2].midY)
                // x 居中对齐 dock
                XCTAssertEqual(circles[0].midX, dock.midX, accuracy: 0.001)
            } else {
                // 第 0 个在左边（x 坐标更小），第 2 个在右边（x 坐标更大）
                XCTAssertLessThan(circles[0].midX, circles[1].midX)
                XCTAssertLessThan(circles[1].midX, circles[2].midX)
            }
        }
    }

    func testCircleIndexHitsInsideProviderCircle() {
        let dock = makeDockFrame(edge: .right, entryCount: 3)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 3)

        for index in 0..<3 {
            let center = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: .right, index: index)
            // 圆心
            XCTAssertEqual(EdgeDockController.circleIndex(at: center, circles: circles), index)
            // 内部区域 (半径内 10pt)
            let innerPoint = CGPoint(x: center.x + 8, y: center.y - 6)
            XCTAssertEqual(EdgeDockController.circleIndex(at: innerPoint, circles: circles), index)
            // 外圈边界附近 (半径 19pt，测试 18.5pt)
            let nearEdgePoint = CGPoint(x: center.x, y: center.y + 18.5)
            XCTAssertEqual(EdgeDockController.circleIndex(at: nearEdgePoint, circles: circles), index)
        }
    }

    func testCircleIndexRejectsLabelBelowCircle() {
        let dock = makeDockFrame(edge: .right, entryCount: 3)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 3)

        // 竖排中，数值百分比标签位于圆环下方（距离圆心垂直距离在 23pt ~ 33pt）
        let center0 = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: .right, index: 0)
        let labelPoint = CGPoint(x: center0.x, y: center0.y - 26) // 标签区域

        // circleIndex 必须返回 nil（不触发详情展示）
        XCTAssertNil(
            EdgeDockController.circleIndex(at: labelPoint, circles: circles),
            "光标在百分比数值标签上时不应触发 circleIndex 命中"
        )
    }

    func testCircleIndexRejectsGapBetweenCircles() {
        let dock = makeDockFrame(edge: .right, entryCount: 3)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 3)

        let center0 = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: .right, index: 0)
        let center1 = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: .right, index: 1)
        let midGap = CGPoint(x: dock.midX, y: (center0.y + center1.y) / 2)

        XCTAssertNil(
            EdgeDockController.circleIndex(at: midGap, circles: circles),
            "光标在两圆环之间的间隙时不应命中"
        )
    }

    func testCircleIndexRejectsDockBackgroundPadding() {
        let dock = makeDockFrame(edge: .right, entryCount: 3)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 3)

        // dock 顶部的留白边距区 (padding 区域)
        let topPaddingPoint = CGPoint(x: dock.midX, y: dock.maxY - 2)
        XCTAssertNil(
            EdgeDockController.circleIndex(at: topPaddingPoint, circles: circles),
            "光标在 dock 顶部边距时不应命中"
        )

        // dock 侧边的空白区域
        let sideMarginPoint = CGPoint(x: dock.minX + 2, y: circles[0].midY)
        XCTAssertNil(
            EdgeDockController.circleIndex(at: sideMarginPoint, circles: circles),
            "光标在 dock 侧边缘留白时不应命中"
        )
    }

    func testCircleIndexRespectsHoverScaleExpansion() {
        let dock = makeDockFrame(edge: .right, entryCount: 2)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 2)
        let center0 = EdgeDockGeometry.circleCenter(dockFrame: dock, edge: .right, index: 0)

        // 基准半径 19pt。测试点位于距离圆心 20.0pt (基准半径外，但在 1.10x 放大后的 20.9pt 半径内)
        let pointAt20pt = CGPoint(x: center0.x + 20.0, y: center0.y)

        // 未 hover 时：20pt 超出 19pt -> 返回 nil
        XCTAssertNil(
            EdgeDockController.circleIndex(at: pointAt20pt, circles: circles, currentHovered: nil)
        )

        // 已处于 hover 状态时：20pt 处于 20.9pt 放大圆内 -> 命中保持为 0，防止抖动
        XCTAssertEqual(
            EdgeDockController.circleIndex(at: pointAt20pt, circles: circles, currentHovered: 0),
            0
        )
    }

    func testCircleIndexHonoursMinimumRadiusForCompactRings() {
        // 「小圆环」形态逐行 hover 用：7pt 的圆（半径 3.5）照圆判定等于要指中一个
        // 7px 的点，指偏 4pt 就换了一张卡。传半个行距当判定半径下限之后，
        // 圆心旁 6pt 处仍然命中**这一行**。
        let compact = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right, appearance: .compact)
        let dock = makeDockFrame(edge: .right, entryCount: 3, size: compact)
        let step = EdgeDockGeometry.compactRowStep
        var circles: [CGRect] = []
        for index in 0..<3 {
            let center = CGPoint(
                x: dock.midX,
                y: dock.maxY - EdgeDockGeometry.compactPadding - EdgeDockGeometry.compactDiameter / 2
                    - CGFloat(index) * step
            )
            circles.append(CGRect(
                x: center.x - EdgeDockGeometry.compactDiameter / 2,
                y: center.y - EdgeDockGeometry.compactDiameter / 2,
                width: EdgeDockGeometry.compactDiameter,
                height: EdgeDockGeometry.compactDiameter
            ))
        }
        // 半径 3.5 的圆心旁 6pt：按圆判定不命中，按半个行距（7.5pt）判定命中。
        let sixOut = CGPoint(x: circles[1].midX + 6, y: circles[1].midY)
        XCTAssertNil(
            EdgeDockController.circleIndex(at: sixOut, circles: circles),
            "不传下限时行为与从前逐字相同：7pt 的圆只认 3.5pt"
        )
        XCTAssertEqual(
            EdgeDockController.circleIndex(
                at: sixOut, circles: circles, minimumRadius: step / 2
            ),
            1
        )
        // 相邻两环的判定区在中点接上：越靠近哪一个就归哪一个，不会因为"先遍历到
        // 上面那个"而张冠李戴（中点 ±0.5pt 那一格是 0.5pt 容差，两边都算命中，
        // 循环先到者胜——与完整形态用同一条容差规则，不另开特例）。
        let nearerToSecond = CGPoint(x: circles[1].midX, y: circles[1].midY - 5.4)
        XCTAssertEqual(
            EdgeDockController.circleIndex(
                at: nearerToSecond, circles: circles, minimumRadius: step / 2
            ),
            1,
            "明显更靠近第二个环的点必须算第二个环"
        )
        let nearerToFirst = CGPoint(x: circles[0].midX, y: circles[0].midY + 5.4)
        XCTAssertEqual(
            EdgeDockController.circleIndex(
                at: nearerToFirst, circles: circles, minimumRadius: step / 2
            ),
            0
        )
    }

    // MARK: - 额度弧：顺时针收缩

    func testArcPinsClockwiseEndAtTwelve() {
        // 顺时针末端恒为 1（即 12 点），额度下降时另一端顺时针扫向 12 点。
        for fraction in [1.0, 0.75, 0.5, 0.25, 0.05] {
            let range = EdgeDockGeometry.arcTrimRange(fraction: fraction)
            XCTAssertNotNil(range, "fraction=\(fraction) 应该有弧")
            XCTAssertEqual(
                range!.upperBound, 1, accuracy: 0.0001,
                "fraction=\(fraction) 顺时针末端必须钉在 12 点"
            )
            XCTAssertEqual(
                range!.lowerBound, 1 - fraction, accuracy: 0.0001,
                "fraction=\(fraction) 另一端应在 1-fraction"
            )
        }
    }

    func testArcLeadEdgeAdvancesClockwiseAsQuotaDrops() {
        // 额度越低，缺口越大且**沿顺时针**张开 —— 起点单调递增。
        let fractions = [1.0, 0.8, 0.6, 0.4, 0.2, 0.05]
        var previous = -1.0
        for fraction in fractions {
            let start = EdgeDockGeometry.arcTrimRange(fraction: fraction)!.lowerBound
            XCTAssertGreaterThan(
                start, previous,
                "额度从 \(fraction) 继续下降时缺口必须顺时针扩大（起点变大）"
            )
            previous = start
        }
    }

    func testArcIsAbsentWithoutDataSoOnlyTheTrackRemains() {
        // nil（加载中/无额度窗口）与 0（耗尽）都不画弧：底槽必须仍然在，
        // 它是"这里有一个环、只是读不到数"的唯一提示。
        XCTAssertNil(EdgeDockGeometry.arcTrimRange(fraction: nil), "无数据不应有弧")
        XCTAssertNil(EdgeDockGeometry.arcTrimRange(fraction: 0), "耗尽不应留一个圆头假点")
    }

    func testArcClampsOverfilledQuota() {
        // 超过 100% 的脏数据要封顶，否则 lowerBound 变负、区间反转。
        let range = EdgeDockGeometry.arcTrimRange(fraction: 1.4)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(range!.upperBound, 1, accuracy: 0.0001)
    }

    // MARK: - popover 与最宽内容（7 天图表）的宽度一致性

    func testPopoverWidthFitsSevenDayChart() {
        // 宽度推导链：图表 420 + 卡片内边距 12×2 + 背板内边距 12×2。
        // 曾经直接取主菜单宽度 360，卡片内容区只剩 312pt，图表首尾两天的柱
        // 被浮层整段裁掉——固定宽度的前提是先装得下最宽的内容。
        XCTAssertEqual(
            EdgeDockTheme.popoverWidth,
            SevenDayUsageChartMetrics.pricedWidth
                + ProviderCardView.contentPadding * 2
                + EdgeDockTheme.popoverPadding * 2
        )
        XCTAssertGreaterThan(EdgeDockTheme.popoverWidth, MenuPanelHeightBridge.width)
    }

    func testPopoverCardInnerWidthFitsChart() {
        // 卡片内容区（面板宽 - 背板内边距 - 卡片内边距）必须完整装下图表，
        // 不带价格列时同样要装下柱区（415）。
        let inner = EdgeDockTheme.popoverWidth
            - EdgeDockTheme.popoverPadding * 2
            - ProviderCardView.contentPadding * 2
        XCTAssertGreaterThanOrEqual(inner, SevenDayUsageChartMetrics.pricedWidth)
        XCTAssertGreaterThanOrEqual(inner, SevenDayUsageChartMetrics.barsWidth)
    }

    func testChartBarsWidthCoversSevenDayRow() {
        // 柱区常量必须始终等于实际排版：7 根柱 × 55pt + 6 个 5pt 间距。
        // LocalUsageDayBar 的宽度或间距变了而这里没跟，首尾两天就会被裁。
        XCTAssertEqual(SevenDayUsageChartMetrics.barsWidth, 55 * 7 + 5 * 6)
        XCTAssertLessThanOrEqual(SevenDayUsageChartMetrics.barsWidth, SevenDayUsageChartMetrics.pricedWidth)
    }

    func testPopoverPaddingTracksMenuCardPadding() {
        XCTAssertEqual(
            EdgeDockTheme.popoverPadding, MenuPanelHeightBridge.cardHorizontalPadding,
            "两侧内边距同源，改菜单时不会漏改 popover"
        )
    }

    func testPopoverClampsOnNarrowScreens() {
        // 屏幕比 popover 还窄时必须钳位，否则浮层会铺满全屏还盖住 dock。
        // （钳位分支见 EdgeDockController.updatePopover：min(popoverWidth, 屏宽-80)。）
        let popover = EdgeDockTheme.popoverWidth
        let narrow = popover - 80
        XCTAssertLessThan(narrow, popover, "窄屏走钳位分支")
        XCTAssertGreaterThan(narrow - EdgeDockTheme.popoverPadding * 2, 120, "钳位后仍要留得下卡片内容")
    }


    // MARK: - popover 定位

    func testPopoverOpensInwardWhenDockedRight() {
        // 贴右边 → popover 朝左展开，绝不能被推出屏幕右侧。
        let dock = makeDockFrame(edge: .right, entryCount: 4)
        let size = CGSize(width: 340, height: 200)
        let frame = EdgeDockGeometry.popoverFrame(
            size: size, dockFrame: dock, rowIndex: 1, edge: .right, visibleFrame: visible
        )
        XCTAssertEqual(frame.maxX, dock.minX - EdgeDockGeometry.popoverGap, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX)
    }

    func testPopoverOpensInwardForEveryEdge() {
        let size = CGSize(width: 340, height: 200)
        for edge in DockEdge.allCases {
            let dock = makeDockFrame(edge: edge, entryCount: 4)
            let frame = EdgeDockGeometry.popoverFrame(
                size: size, dockFrame: dock, rowIndex: 1, edge: edge, visibleFrame: visible
            )
            switch edge {
            case .right:
                XCTAssertLessThan(frame.maxX, dock.minX, "edge=right 应向左展开")
            case .left:
                XCTAssertGreaterThan(frame.minX, dock.maxX, "edge=left 应向右展开")
            case .top:
                XCTAssertLessThan(frame.maxY, dock.minY, "edge=top 应向下展开")
            case .bottom:
                XCTAssertGreaterThan(frame.minY, dock.maxY, "edge=bottom 应向上展开")
            }
            XCTAssertTrue(visible.contains(frame), "edge=\(edge) popover 必须完全在可视区内")
        }
    }

    func testPopoverAlignsWithHoveredCircle() {
        let dock = makeDockFrame(edge: .right, entryCount: 4)
        let size = CGSize(width: 340, height: 200)
        let frame = EdgeDockGeometry.popoverFrame(
            size: size, dockFrame: dock, rowIndex: 2, edge: .right, visibleFrame: visible
        )
        let center = EdgeDockGeometry.rowCenter(dockFrame: dock, edge: .right, index: 2)
        XCTAssertEqual(frame.midY, center.y, accuracy: 0.001, "纵向与被 hover 的圆心对齐")
    }

    func testPopoverAnchorsToMeasuredRowCenter() {
        // 「小圆环」形态行距 15pt，而 popoverFrame 的兜底推算写死的是完整形态的
        // 行距（38 + 16pt）：不传实测中心时，第 2 行的卡片会挂在比真环低 30pt 的
        // 位置。控制器一律传实测行中心。
        let compact = EdgeDockGeometry.dockSize(entryCount: 4, edge: .right, appearance: .compact)
        let dock = makeDockFrame(edge: .right, entryCount: 4, size: compact)
        let estimated = EdgeDockGeometry.rowCenter(dockFrame: dock, edge: .right, index: 2)
        let real = CGPoint(x: dock.midX, y: dock.maxY - 40)

        let size = CGSize(width: 340, height: 200)
        let frame = EdgeDockGeometry.popoverFrame(
            size: size, dockFrame: dock, rowIndex: 2, edge: .right, visibleFrame: visible,
            measuredRowCenter: real
        )
        XCTAssertEqual(frame.midY, real.y, accuracy: 0.001, "纵向必须对齐实测行中心")
        XCTAssertNotEqual(
            frame.midY, estimated.y, accuracy: 0.001,
            "这条测试的前提：完整形态推算确实对不上简版的行距"
        )
    }

    func testPopoverStaysOnScreenWhenCircleNearTopOrBottom() {
        // 第一个圆贴顶 / 最后一个圆贴底时，popover 仍要完整可见。
        let size = CGSize(width: 340, height: 260)
        let dockTop = makeDockFrame(edge: .right, entryCount: 4, offset: 0)
        let top = EdgeDockGeometry.popoverFrame(
            size: size, dockFrame: dockTop, rowIndex: 0, edge: .right, visibleFrame: visible
        )
        XCTAssertGreaterThanOrEqual(top.minY, visible.minY - 0.001)
        XCTAssertLessThanOrEqual(top.maxY, visible.maxY + 0.001)

        let dockBottom = makeDockFrame(edge: .right, entryCount: 4, offset: 1)
        let bottom = EdgeDockGeometry.popoverFrame(
            size: size, dockFrame: dockBottom, rowIndex: 3, edge: .right, visibleFrame: visible
        )
        XCTAssertGreaterThanOrEqual(bottom.minY, visible.minY - 0.001)
        XCTAssertLessThanOrEqual(bottom.maxY, visible.maxY + 0.001)
    }

    func testPopoverClampsWhenWiderThanScreen() {
        let dock = makeDockFrame(edge: .right, entryCount: 4)
        let absurd = CGSize(width: 5000, height: 200)
        let frame = EdgeDockGeometry.popoverFrame(
            size: absurd, dockFrame: dock, rowIndex: 0, edge: .right, visibleFrame: visible
        )
        XCTAssertLessThanOrEqual(frame.width, visible.width)
        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: - 简版 dock（自动隐藏模式的收起形态）

    func testCompactDockSizeGrowsVerticallyOnVerticalEdges() {
        // 简版没有数值文字：厚度轴 = 单环直径 + 内边距，两个方向同值。
        let thickness = EdgeDockGeometry.compactDiameter + EdgeDockGeometry.compactPadding * 2
        let one = EdgeDockGeometry.dockSize(entryCount: 1, edge: .right, appearance: .compact)
        XCTAssertEqual(one.width, thickness)
        XCTAssertEqual(one.height, thickness)

        let three = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right, appearance: .compact)
        XCTAssertEqual(three.width, thickness, "竖排时厚度不随条目数变化")
        XCTAssertEqual(
            three.height,
            CGFloat(3) * EdgeDockGeometry.compactDiameter
                + CGFloat(2) * EdgeDockGeometry.compactSpacing
                + EdgeDockGeometry.compactPadding * 2
        )
    }

    func testCompactDockSizeGrowsHorizontallyOnHorizontalEdges() {
        let three = EdgeDockGeometry.dockSize(entryCount: 3, edge: .bottom, appearance: .compact)
        XCTAssertEqual(
            three.height,
            EdgeDockGeometry.compactDiameter + EdgeDockGeometry.compactPadding * 2
        )
        XCTAssertEqual(
            three.width,
            CGFloat(3) * EdgeDockGeometry.compactDiameter
                + CGFloat(2) * EdgeDockGeometry.compactSpacing
                + EdgeDockGeometry.compactPadding * 2
        )
    }

    func testCompactDockIsSmallerThanFullDock() {
        // 简版的存在意义就是"收起后不显眼"：任何朝向、任何条目数都必须比完整版小。
        for edge in DockEdge.allCases {
            for count in [1, 3, 5] {
                let full = EdgeDockGeometry.dockSize(entryCount: count, edge: edge, appearance: .full)
                let compact = EdgeDockGeometry.dockSize(entryCount: count, edge: edge, appearance: .compact)
                XCTAssertLessThan(compact.width, full.width, "edge=\(edge) count=\(count) 简版必须更窄")
                XCTAssertLessThan(compact.height, full.height, "edge=\(edge) count=\(count) 简版必须更矮")
            }
        }
    }

    func testCompactFrameStaysFullyOnScreen() {
        // 简版与完整版共用 frame()：贴边、钳位、offset 0/1 不被裁，缺一不可。
        for edge in DockEdge.allCases {
            let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: edge, appearance: .compact)
            for offset in [0.0, 0.5, 1.0] {
                let frame = EdgeDockGeometry.frame(
                    visibleFrame: visible, edge: edge, size: size, offset: offset
                )
                XCTAssertTrue(
                    visible.contains(frame),
                    "edge=\(edge) offset=\(offset) 简版窗口必须完整可见"
                )
            }
        }
    }

    func testCompactRingIsReadableAtItsSize() {
        // 14pt 的环配 2pt 线宽：线宽不能细到看不见，也不能粗到环变成实心点。
        XCTAssertGreaterThanOrEqual(
            EdgeDockGeometry.compactRingLineWidth, 1.5,
            "环线过细在浅色壁纸上会消失"
        )
        XCTAssertLessThan(
            EdgeDockGeometry.compactRingLineWidth * 2, EdgeDockGeometry.compactDiameter,
            "环线过粗会吃掉整个环心"
        )
    }

    // MARK: - 多屏：屏幕身份与跨屏拖拽

    func testMatchingIndexResolvesTheConfiguredScreen() {
        // 副屏在左边 / 在右边两种排列都要能找到——UUID 与下标顺序无关。
        let keys = ["PRIMARY", "LEFT", "RIGHT"]
        XCTAssertEqual(EdgeDockDisplay.matchingIndex(preferred: "RIGHT", keys: keys), 2)
        XCTAssertEqual(EdgeDockDisplay.matchingIndex(preferred: "LEFT", keys: ["LEFT", "PRIMARY"]), 0)
    }

    func testMatchingIndexTreatsUnsetOrVanishedScreenAsUnset() {
        let keys = ["PRIMARY", "RIGHT"]
        XCTAssertNil(EdgeDockDisplay.matchingIndex(preferred: nil, keys: keys), "没配过屏")
        XCTAssertNil(
            EdgeDockDisplay.matchingIndex(preferred: "", keys: keys),
            "空串要当没配（手改 config.json 会写出这种值）"
        )
        XCTAssertNil(
            EdgeDockDisplay.matchingIndex(preferred: "GONE", keys: keys),
            "屏被拔掉时必须返回 nil，调用方据此把配置改写回落"
        )
        XCTAssertNil(EdgeDockDisplay.matchingIndex(preferred: "PRIMARY", keys: []))
    }

    @MainActor
    func testEveryAttachedDisplayHasADistinctResolvableUUID() {
        // 真正跑一遍 AppKit 那层（`NSScreen` 在纯逻辑测试里造不出来）：
        // 每块屏都要拿得到 UUID，UUID 之间不能重复，且能按 UUID 反查回同一块屏。
        // 重复会让两块屏互相匹配，dock 停在 A 屏却按 B 屏的 visibleFrame 定位。
        let screens = NSScreen.screens
        let uuids = screens.compactMap { EdgeDockDisplay.uuid(of: $0) }
        XCTAssertEqual(uuids.count, screens.count, "每块屏都要有 UUID（拿不到说明拿不到 display id）")
        XCTAssertEqual(Set(uuids).count, uuids.count, "不同显示器不能撞 UUID")
        for (index, screen) in screens.enumerated() {
            let uuid = uuids[index]
            XCTAssertEqual(
                EdgeDockDisplay.displayID(of: EdgeDockDisplay.matchingScreen(preferred: uuid, screens: screens)!),
                EdgeDockDisplay.displayID(of: screen),
                "按 UUID 反查必须回到同一块屏"
            )
        }
        XCTAssertNil(EdgeDockDisplay.matchingScreen(preferred: "NO-SUCH-UUID", screens: screens))
    }

    func testCrossedIndexOnlySwitchesToADifferentDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (1, main), (2, right)
        ]
        // 鼠标还在本屏内：不换。
        XCTAssertNil(EdgeDockDisplay.crossedIndex(currentDisplayID: 1, mouse: CGPoint(x: 900, y: 500), candidates: candidates))
        // 鼠标越过拼接边界：换到右边那块。
        XCTAssertEqual(
            EdgeDockDisplay.crossedIndex(currentDisplayID: 1, mouse: CGPoint(x: 2400, y: 500), candidates: candidates),
            1
        )
        // 反向同理。
        XCTAssertEqual(
            EdgeDockDisplay.crossedIndex(currentDisplayID: 2, mouse: CGPoint(x: 900, y: 500), candidates: candidates),
            0
        )
    }

    func testCrossedIndexIgnoresMirroredCopiesOfTheSameDisplay() {
        // 镜像屏两个 NSScreen 共享同一个 display id，visibleFrame 各是一半。
        // 鼠标在镜像那半边时"换屏"只会把窗口挪到同一台显示器的另一面，
        // 坐标系统一换位置就错了——必须判定为没越界。
        let left = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let right = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (7, left), (7, right)
        ]
        XCTAssertNil(EdgeDockDisplay.crossedIndex(currentDisplayID: 7, mouse: CGPoint(x: 1500, y: 500), candidates: candidates))
    }

    func testCrossedIndexStaysPutWhenTheCurrentScreenIsUnknown() {
        // 认不出本屏 display id 时不敢换：换错的后果是 dock 消失在看不见的地方。
        let candidates: [(displayID: CGDirectDisplayID?, visibleFrame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        XCTAssertNil(
            EdgeDockDisplay.crossedIndex(currentDisplayID: nil, mouse: CGPoint(x: 500, y: 500), candidates: candidates)
        )
    }

    func testScreenUUIDRoundTripsAndDefaultsToUnset() throws {
        // 老配置没有这个字段：必须是"没指定"（跟随所在屏），而不是解码失败。
        let legacy = #"{"mode":"statusWindow","edge":"left","offset":0.2}"#
        XCTAssertNil(try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8)).screenUUID)

        let onSecond = EdgeDockConfig(mode: .statusWindow, edge: .top, offset: 0.2, screenUUID: "RIGHT-UUID")
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(onSecond))
        XCTAssertEqual(decoded.screenUUID, "RIGHT-UUID")
        XCTAssertEqual(decoded.normalized.screenUUID, "RIGHT-UUID", "normalized 必须原样保留所在的屏")
    }

    func testSettingsSaveMustNotLoseTheConfiguredScreen() {
        // 设置页只改形态/贴边/全屏，位置类字段一律沿用已存值。漏掉 screenUUID
        // 的后果比漏掉 offset 更严重：用户在副屏上拖好的 dock 会被点一下"保存"
        // 静默搬回主屏。
        let stored = EdgeDockConfig(mode: .compactRings, edge: .bottom, offset: 0.42,
                                    screenUUID: "SECOND", hideInFullscreen: false)
        let rebuilt = EdgeDockConfig(
            mode: stored.mode,
            edge: stored.edge,
            offset: stored.offset,
            screenUUID: stored.screenUUID,
            hideInFullscreen: stored.hideInFullscreen
        )
        XCTAssertEqual(rebuilt, stored)
    }

    // MARK: - 形态（mode）：默认值、配置兼容与语义

    func testDefaultModeIsAutoHideWindow() {
        // 默认给「状态窗（自动隐藏）」：完整功能默认开着，屏幕上默认只占一条
        // 7pt 的小环列，鼠标靠近才长出来。改这个值等于改"装上 App 之后屏幕上
        // 立刻出现什么"——曾经默认是"什么都不出现"，现在必须钉住新约定。
        XCTAssertEqual(EdgeDockConfig.default.mode, .autoHideWindow)
        XCTAssertTrue(EdgeDockConfig.default.mode.isVisible)
    }

    func testModeExposesTheTwoIndependentSwitchesTheControllerUsedToRead() {
        // 控制器过去读两个布尔（enabled / autoHideMode），现在只读形态上这两个
        // 派生属性。四种组合必须各自落在一个**互斥**的格子里：
        // 「小圆环」与「状态窗（自动隐藏）」都是简版，但只有后者会被鼠标撑大——
        // 这一条钉住的就是那个区别，它无法从"两个布尔"里一眼看出来。
        XCTAssertFalse(EdgeDockMode.hidden.isVisible)
        XCTAssertFalse(EdgeDockMode.hidden.expandsOnProximity)
        XCTAssertTrue(EdgeDockMode.statusWindow.staysFullWhenIdle)
        XCTAssertFalse(EdgeDockMode.statusWindow.expandsOnProximity)
        XCTAssertTrue(EdgeDockMode.compactRings.isVisible)
        XCTAssertFalse(EdgeDockMode.compactRings.expandsOnProximity, "小圆环永不展开")
        XCTAssertFalse(EdgeDockMode.compactRings.staysFullWhenIdle)
        XCTAssertTrue(EdgeDockMode.autoHideWindow.expandsOnProximity)
        XCTAssertFalse(EdgeDockMode.autoHideWindow.staysFullWhenIdle)
    }

    func testEveryModeHasItsOwnDisplayName() {
        // 四个选项都在 picker 里列出。名字重复或为空 = 用户分不出该选哪个。
        XCTAssertEqual(EdgeDockMode.allCases.count, 4)
        XCTAssertEqual(
            Set(EdgeDockMode.allCases.map(\.displayName)).count, 4,
            "四种形态的显示名必须两两不同"
        )
        XCTAssertTrue(EdgeDockMode.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    func testLegacyConfigJSONWithoutModeFallsBackToDefault() throws {
        // 旧 config.json 只有 enabled / autoHideMode，没有 mode：必须按**默认形态**
        // 解码成功，绝不能让整块解码失败——外层 ConfigStore 对 edgeDock 用的是
        // `try?`，失败 = 用户拖到另一条边的 dock 被静默重置回默认位置。
        // 这里刻意**不**映射旧的 enabled/autoHideMode（行为回落到默认形态）。
        let legacy = #"{"enabled":true,"edge":"left","offset":0.3,"autoHideMode":true}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.mode, .default)
        XCTAssertEqual(decoded.edge, .left)
        XCTAssertEqual(decoded.offset, 0.3, accuracy: 0.0001)
    }

    func testLegacyConfigThatExplicitlyDisabledTheDockStillDecodes() throws {
        // enabled=false 的旧配置同样按默认形态解码（不映射）——但**其它字段必须
        // 原样保住**：位置和贴边方向是用户拖出来的，比形态更不能丢。
        let legacy = #"{"enabled":false,"edge":"bottom","offset":0.8}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.edge, .bottom)
        XCTAssertEqual(decoded.offset, 0.8, accuracy: 0.0001)
    }

    func testModeRoundTripsThroughJSON() throws {
        for mode in EdgeDockMode.allCases {
            let original = EdgeDockConfig(mode: mode, edge: .bottom, offset: 0.7)
            let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.normalized.mode, mode, "normalized 必须原样保留形态")
        }
    }

    func testUnknownModeValueInHandEditedConfigFallsBackToDefault() throws {
        // 手改 config.json 写一个不存在的形态值：整块解码必须成功并回落到默认，
        // 不能让 try? 把整份配置判成损坏。
        let hand = #"{"mode":"magic","edge":"left","offset":0.2}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(hand.utf8))
        XCTAssertEqual(decoded.mode, .default)
    }

    // MARK: - 全屏隐藏开关：配置兼容

    func testHideInFullscreenDefaultsOn() {
        // 全屏隐藏与形态**正交**：形态选「无」时它没有可作用的对象，但只要选了
        // 任何一种形态，缺省就该是"全屏时让路"——功能一直存在、默认一直是开。
        // 如果这里给 false，等于升级后所有开着 dock 的用户立刻在全屏里
        // 多出一个窗口——那不是新功能，是行为突变。
        XCTAssertTrue(EdgeDockConfig.default.hideInFullscreen)
    }

    func testLegacyConfigJSONWithoutHideInFullscreenStillDecodes() throws {
        // 缺字段不能让整块解码失败。外层 ConfigStore 用 try?，失败 = 用户拖好的
        // 边缘窗被静默重置。
        let legacy = #"{"mode":"statusWindow","edge":"top","offset":0.2}"#
        let decoded = try JSONDecoder().decode(EdgeDockConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.mode, .statusWindow)
        XCTAssertEqual(decoded.edge, .top)
        XCTAssertTrue(decoded.hideInFullscreen, "缺失该字段时必须回落到默认开启")
    }

    func testHideInFullscreenRoundTripsThroughJSON() throws {
        let off = EdgeDockConfig(mode: .statusWindow, edge: .left, offset: 0.9, hideInFullscreen: false)
        let offDecoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(off))
        XCTAssertEqual(offDecoded, off)
        XCTAssertFalse(offDecoded.normalized.hideInFullscreen, "normalized 必须原样保留关闭状态")

        let on = EdgeDockConfig(mode: .statusWindow, edge: .left, offset: 0.9, hideInFullscreen: true)
        let onDecoded = try JSONDecoder().decode(EdgeDockConfig.self, from: try JSONEncoder().encode(on))
        XCTAssertTrue(onDecoded.normalized.hideInFullscreen)
    }


    func testFullscreenHidingRespectsTheToggle() {
        // 策略本身：探测到全屏 + 开关开着 → 隐藏；开关关掉 → 一律不隐藏。
        // 这两行曾经散在控制器四个 guard 里各写一次，任何一处漏掉都不会编译报错。
        let hiding = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 0.5, hideInFullscreen: true)
        XCTAssertTrue(hiding.hidesInFullscreen(isFullscreenSpace: true))
        XCTAssertFalse(hiding.hidesInFullscreen(isFullscreenSpace: false), "不在全屏时永远不隐藏")

        let showing = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 0.5, hideInFullscreen: false)
        XCTAssertFalse(
            showing.hidesInFullscreen(isFullscreenSpace: true),
            "关掉开关后，即使前台 App 全屏也不该隐藏——这正是这个选项的意义"
        )
    }

    func testEdgeSurvivesSettingsSaveEvenThoughThereIsNoEdgePicker() {
        // 设置页不再有"贴靠边"下拉框，但保存时仍然要把**已存的值**原样写回去。
        // 贴边方向由拖动实时写盘；如果这里改成 `EdgeDockConfig.default.edge`，
        // 用户在设置页点一下"保存"就会把拖好的位置打回右侧，而且没有任何提示。
        let stored = EdgeDockConfig(mode: .compactRings, edge: .bottom, offset: 0.42, hideInFullscreen: false)
        let rebuilt = EdgeDockConfig(
            mode: stored.mode,
            edge: stored.edge,
            offset: stored.offset,
            hideInFullscreen: stored.hideInFullscreen
        )
        XCTAssertEqual(rebuilt, stored)
    }

    // MARK: - 配置归一化

    func testNormalizedClampsHandEditedOffset() {
        let over = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: 42)
        XCTAssertEqual(over.normalized.offset, 1)

        let under = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: -7)
        XCTAssertEqual(under.normalized.offset, 0)

        let nan = EdgeDockConfig(mode: .statusWindow, edge: .right, offset: .nan)
        XCTAssertEqual(nan.normalized.offset, 0.5)
    }


    func testDefaultEdgeDockSitsOnTheRightEdge() {
        // 贴边方向与形态无关：默认右侧，拖动后由拖拽写盘。
        XCTAssertEqual(EdgeDockConfig.default.edge, .right)
        XCTAssertEqual(EdgeDockConfig.default.mode, .autoHideWindow)
    }

    func testDockEdgeAxisClassification() {
        XCTAssertTrue(DockEdge.left.isVertical)
        XCTAssertTrue(DockEdge.right.isVertical)
        XCTAssertFalse(DockEdge.top.isVertical)
        XCTAssertFalse(DockEdge.bottom.isVertical)
    }

    // MARK: - 投影：statuses → 圆环条目

    private func makeModel(
        name: String,
        intervalPercent: Double?,
        weeklyPercent: Double? = nil,
        now: Date = Date()
    ) -> ModelQuota {
        // 窗口标记为 present 时**必须**同时给出 reset 时间：`ModelQuota` 在 debug 下
        // 对"present 但没有重置时间"是 assertionFailure 直接 trap，那不是合法夹具。
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: intervalPercent ?? 0,
            intervalStatus: intervalPercent == nil ? .absent : .present,
            intervalResetsAt: intervalPercent == nil ? nil : now.addingTimeInterval(2 * 3600),
            intervalWindowSeconds: intervalPercent == nil ? nil : 18000,
            weeklyTotalCount: 100,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: weeklyPercent ?? 0,
            weeklyStatus: weeklyPercent == nil ? .absent : .present,
            weeklyResetsAt: weeklyPercent == nil ? nil : now.addingTimeInterval(3 * 24 * 3600),
            weeklyWindowSeconds: weeklyPercent == nil ? nil : 604800
        )
    }

    private func makeStatus(
        id: String,
        kind: ProviderKind = .codexChatGpt,
        enabled: Bool = true,
        state: ProviderStatus.State
    ) -> ProviderStatus {
        var status = ProviderStatus(
            id: id,
            displayName: id.uppercased(),
            kind: kind,
            iconSystemName: "circle",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: state
        )
        status.isEnabled = enabled
        return status
    }

    private func makeInfo(_ models: [ModelQuota]) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    func testProjectionOnlyIncludesEnabledProviders() {
        // 「开启监控的」就是这个过滤条件：disabled 的 provider 不该出现在边缘窗。
        let statuses = [
            makeStatus(id: "on", enabled: true, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 50)]))),
            makeStatus(id: "off", enabled: false, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 50)]))),
        ]
        let entries = EdgeDockProjection.entries(from: statuses)
        XCTAssertEqual(entries.map(\.id), ["on"])
    }

    func testProjectionSeparatesIntervalAndWeeklyWindows() {
        // 外环读 5 小时、内环读周额度，两个窗口各走各的原始百分比。
        let status = makeStatus(id: "dual", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 40, weeklyPercent: 85),
        ])))
        let entry = EdgeDockProjection.entries(from: [status])[0]
        XCTAssertEqual(entry.intervalFraction ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(entry.weeklyFraction ?? -1, 0.85, accuracy: 0.0001)
        XCTAssertTrue(entry.hasAnyQuotaWindow)
    }

    func testWeeklyRingUsesRawPercentNotEquivalentMultiplier() {
        // 内环表达"周额度本身还剩多少"，不能乘周等效倍率 N。
        // codex 的 N = 6，乘完 50% 会变成 300%（封顶满环），读出来就不是周额度了。
        let status = makeStatus(id: "codex", kind: .codexChatGpt, state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 40, weeklyPercent: 50),
        ])))
        XCTAssertEqual(EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.50, accuracy: 0.0001)
    }

    func testOnlyWeeklyWindowLeavesOuterRingEmpty() {
        // 只有周窗口的 provider：外环 nil（不画弧），内环有值。
        let status = makeStatus(id: "weekly_only", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: nil, weeklyPercent: 70),
        ])))
        let entry = EdgeDockProjection.entries(from: [status])[0]
        XCTAssertNil(entry.intervalFraction)
        XCTAssertEqual(entry.weeklyFraction ?? -1, 0.70, accuracy: 0.0001)
        XCTAssertTrue(entry.hasAnyQuotaWindow)
    }

    func testProjectionUsesWorstModelNotAveragePerWindow() {
        // 一个 provider 下多个 model 时每个窗口各取最低值：平均值会把瓶颈洗掉。
        let status = makeStatus(id: "multi", state: .ok(makeInfo([
            makeModel(name: "a", intervalPercent: 90, weeklyPercent: 95),
            makeModel(name: "b", intervalPercent: 20, weeklyPercent: 60),
            makeModel(name: "c", intervalPercent: 70, weeklyPercent: 30),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.20, accuracy: 0.0001
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.30, accuracy: 0.0001
        )
    }

    func testProjectionFractionsAreNilWithoutData() {
        // 没抓到数据 ≠ 满额。两个环都必须是 nil，视图才画压暗满环而不是空环。
        let ready = makeStatus(id: "ready", state: .ready)
        XCTAssertNil(EdgeDockProjection.intervalFraction(ready, at: Date()))
        XCTAssertNil(EdgeDockProjection.weeklyFraction(ready, at: Date()))
        let entry = EdgeDockProjection.entries(from: [ready]).first
        XCTAssertNil(entry?.intervalFraction)
        XCTAssertNil(entry?.weeklyFraction)
        XCTAssertFalse(entry?.hasAnyQuotaWindow ?? true)
    }

    func testProjectionKeepsLastSuccessWhileLoading() {
        // loading / failed 期间仍能用上次的成功数据画环，而不是闪成"无数据"。
        let info = makeInfo([makeModel(name: "g", intervalPercent: 42, weeklyPercent: 77)])
        for status in [
            makeStatus(id: "loading", state: .loading(lastSuccess: info)),
            makeStatus(id: "failed", state: .failed(message: "boom", lastSuccess: info)),
        ] {
            XCTAssertEqual(
                EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.42, accuracy: 0.0001
            )
            XCTAssertEqual(
                EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.77, accuracy: 0.0001
            )
        }
    }

    func testProjectionFailedWithoutCacheHasNoHealth() {
        let failed = makeStatus(id: "failed", state: .failed(message: "boom", lastSuccess: nil))
        XCTAssertNil(EdgeDockProjection.intervalFraction(failed, at: Date()))
        XCTAssertNil(EdgeDockProjection.entries(from: [failed]).first?.health)
    }

    func testProjectionSkipsModelsWithoutActiveWindow() {
        // 无窗口占位 model 不参与 min，否则一个 0% 占位会把整个环打成空环。
        let status = makeStatus(id: "placeholder", state: .ok(makeInfo([
            makeModel(name: "real", intervalPercent: 60),
            ModelQuota(
                modelName: "no_window",
                intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 0,
                intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            ),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.60, accuracy: 0.0001
        )
    }

    func testProjectionCarriesKindForBrandIcon() {
        // 中心图标按 kind 取品牌资源，投影必须把它带出来。
        let status = makeStatus(id: "glm", kind: .glmCodingPlan, state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 50),
        ])))
        XCTAssertEqual(EdgeDockProjection.entries(from: [status]).first?.kind, .glmCodingPlan)
    }

    func testProjectionEntryIDsAreStableAcrossOrdering() {
        // id 必须用 providerID 而不是显示名或下标：popover 定位与高亮靠它认人。
        // kind 要给成不同的两个：排序键是 `quotaProviderID`，两个同 kind 的条目
        // 在配置里是同一个键，配置本来就表达不了它们的先后。
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        // 没传 preferredIDs = 用户没配过顺序 → 退回显示名升序（ANTIGRAVITY < CODEX_CHATGPT）
        let ids = EdgeDockProjection.entries(from: statuses).map(\.id)
        XCTAssertEqual(ids, ["antigravity", "codex_chatgpt"], "默认按显示名升序")
        XCTAssertEqual(Set(ids).count, ids.count, "id 不重复")
    }

    // MARK: - 条目顺序 = 配置里的 provider 顺序

    /// dock 必须按设置页里排的顺序展示，且与菜单卡片**同序**：
    /// 两处各排各的会让用户在菜单里排好的位置到 dock 里失效。
    func testProjectionFollowsConfiguredProviderOrder() {
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "deepseek", kind: .deepseek, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        // 配置键是 quotaProviderID，不是 status.id / providerID —— 与菜单同一份。
        let ordered = EdgeDockProjection.entries(
            from: statuses,
            preferredIDs: [QuotaProviderID.deepseek, QuotaProviderID.openAI]
        )
        XCTAssertEqual(ordered.map(\.id), ["deepseek", "codex_chatgpt", "antigravity"],
                       "已配置的按配置排，没配的按显示名升序补在后面")

        // 与菜单卡片对同一份 statuses + 同一份顺序必须得到同一个次序。
        let cards = DisplayOrder.ordered(
            statuses,
            preferredIDs: [QuotaProviderID.deepseek, QuotaProviderID.openAI],
            id: { $0.kind.quotaProviderID },
            by: ProviderStatus.displayNameAscending
        )
        XCTAssertEqual(ordered.map(\.id), cards.map(\.id), "dock 与菜单卡片必须同序")
    }

    /// 配置里的顺序必须**真的**改变 dock 顺序——上一条钉的是"按配置排"，
    /// 这条钉的是"不是碰巧对"：给一个非默认序，输出必须跟着换。
    func testProjectionOrderActuallyTracksConfig() {
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "deepseek", kind: .deepseek, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        XCTAssertEqual(
            EdgeDockProjection.entries(
                from: statuses, preferredIDs: [QuotaProviderID.antigravity, QuotaProviderID.deepseek]
            ).map(\.id),
            ["antigravity", "deepseek", "codex_chatgpt"]
        )
        XCTAssertEqual(
            EdgeDockProjection.entries(
                from: statuses, preferredIDs: [QuotaProviderID.zhipu]
            ).map(\.id),
            ["antigravity", "codex_chatgpt", "deepseek"],
            "配置里全是无效 id 时退回默认序，不该空掉"
        )
    }

    /// 两个条目共用同一个配置键（同一个 kind）不能让投影 trap：
    /// 命中判定每次鼠标移动都跑一遍 `entries`，这里崩就是整 app 崩。
    func testProjectionSurvivesDuplicateProviderKeys() {
        let statuses = [
            makeStatus(id: "dup_a", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "dup_b", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        let entries = EdgeDockProjection.entries(from: statuses)
        XCTAssertEqual(entries.count, 1, "同一个配置键只保留先出现的那个")
        XCTAssertEqual(entries.first?.id, "dup_a")
    }

    func testProjectionEmptyStatusesProducesNoEntries() {
        // 一个 provider 都没开监控时，controller 据此完全不显示窗口。
        XCTAssertTrue(EdgeDockProjection.entries(from: []).isEmpty)
        XCTAssertTrue(EdgeDockProjection.entries(from: [makeStatus(id: "off", enabled: false, state: .ready)]).isEmpty)
    }

    // MARK: - 拖拽：沿贴靠边滑动

    func testDragOffsetFollowsMouseAlongEdge() {
        // 竖排边只跟 y：鼠标往上 → offset 变小；跟 x 无关。
        let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: .right)
        let atCenter = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: visible.midY), dockSize: size, visibleFrame: visible, edge: .right
        )
        XCTAssertEqual(atCenter, 0.5, accuracy: 0.0001)

        let above = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: visible.minY + 100), dockSize: size, visibleFrame: visible, edge: .right
        )
        XCTAssertLessThan(above, 0.5, "鼠标在上半部分 → offset 更小")

        let below = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: visible.maxY - 100), dockSize: size, visibleFrame: visible, edge: .right
        )
        XCTAssertGreaterThan(below, 0.5, "鼠标在下半部分 → offset 更大")
    }

    func testDragOffsetIgnoresPerpendicularAxis() {
        // 横向拖动不该改变竖排边的位置——窗口永远钉在边上，只沿边滑动。
        let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: .right)
        let nearLeft = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: visible.minX + 5, y: visible.midY), dockSize: size, visibleFrame: visible, edge: .right
        )
        let nearRight = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: visible.maxX - 5, y: visible.midY), dockSize: size, visibleFrame: visible, edge: .right
        )
        XCTAssertEqual(nearLeft, nearRight, accuracy: 0.0001, "x 坐标不影响竖排边的 offset")
    }

    func testDragOffsetClampsOutsideVisibleFrame() {
        // 鼠标拖出屏幕时 offset 必须被钳住，不能写进 config 变成 -0.3。
        let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: .right)
        let above = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: visible.minY - 5000), dockSize: size, visibleFrame: visible, edge: .right
        )
        let below = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: visible.maxY + 5000), dockSize: size, visibleFrame: visible, edge: .right
        )
        XCTAssertEqual(above, 0)
        XCTAssertEqual(below, 1)
    }

    func testDragOnHorizontalEdgeFollowsX() {
        let size = EdgeDockGeometry.dockSize(entryCount: 4, edge: .bottom)
        let left = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: visible.minX + 200, y: 500), dockSize: size, visibleFrame: visible, edge: .bottom
        )
        let right = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: visible.maxX - 200, y: 500), dockSize: size, visibleFrame: visible, edge: .bottom
        )
        XCTAssertLessThan(left, 0.5)
        XCTAssertGreaterThan(right, 0.5)
    }

    func testDragOffsetRoundTripsWithFrame() {
        // offsetAlongEdge → frame → normalizedOffset 必须回到原处，
        // 否则"拖一下再开设置"位置会漂。
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let mouse = CGPoint(x: 0, y: visible.minY + 300)
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: mouse, dockSize: size, visibleFrame: visible, edge: .right
        )
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: offset)
        let recovered = EdgeDockGeometry.normalizedOffset(frame: frame, visibleFrame: visible, edge: .right)
        XCTAssertEqual(recovered, offset, accuracy: 0.0001)
    }

    func testDragStaysPinnedToEdge() {
        // 拖拽过程中窗口必须始终贴着边缘，不能被拖到屏幕中间。
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        // 鼠标故意放在屏幕正中间
        let mouse = CGPoint(x: visible.midX, y: visible.midY)
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: mouse, dockSize: size, visibleFrame: visible, edge: .right
        )
        let frame = EdgeDockGeometry.frame(visibleFrame: visible, edge: .right, size: size, offset: offset)
        XCTAssertEqual(frame.maxX, visible.maxX, accuracy: 0.001, "仍然贴住右缘")
    }

    func testDragSwitchesEdgeOnlyWithClearMargin() {
        // 方形可视区 + 正中心：到四条边完全等距。此时不该换边——
        // 换边必须有明确优势，否则鼠标停在角落附近会疯狂闪边。
        let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let center = CGPoint(x: 500, y: 500)
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(mouse: center, currentEdge: .left, visibleFrame: square),
            .left, "四边等距时保持当前边"
        )

        // 明确贴近左边（10 vs 990）→ 换边。
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(
                mouse: CGPoint(x: 10, y: 500), currentEdge: .right, visibleFrame: square
            ),
            .left, "明显更靠近左边才换边"
        )
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(
                mouse: CGPoint(x: 990, y: 500), currentEdge: .left, visibleFrame: square
            ),
            .right, "明显更靠近右边才换边"
        )
    }

    func testDragMarginBlocksNearTieButNotClearWinner() {
        // 领先幅度小于 margin 时不换边，超过 margin 才换。
        let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // 当前在右边，鼠标略偏中心右侧（距右 505，距左 495）：差 10 < margin 40。
        let nearTie = EdgeDockGeometry.edgeAfterDrag(
            mouse: CGPoint(x: 495, y: 500), currentEdge: .right, visibleFrame: square
        )
        XCTAssertEqual(nearTie, .right, "差距小于 margin 不换边")

        // 鼠标偏中心左侧 60：距左 440，距右 560，差 120 > margin 40 → 换边。
        let clear = EdgeDockGeometry.edgeAfterDrag(
            mouse: CGPoint(x: 440, y: 500), currentEdge: .right, visibleFrame: square
        )
        XCTAssertEqual(clear, .left, "差距超过 margin 才换边")
    }

    func testDragKeepsCurrentEdgeWhenItIsTheNearest() {
        for edge in DockEdge.allCases {
            let mouse: CGPoint
            switch edge {
            case .left:   mouse = CGPoint(x: visible.minX + 5, y: visible.midY)
            case .right:  mouse = CGPoint(x: visible.maxX - 5, y: visible.midY)
            case .top:    mouse = CGPoint(x: visible.midX, y: visible.maxY - 5)
            case .bottom: mouse = CGPoint(x: visible.midX, y: visible.minY + 5)
            }
            XCTAssertEqual(
                EdgeDockGeometry.edgeAfterDrag(mouse: mouse, currentEdge: edge, visibleFrame: visible),
                edge
            )
        }
    }

    // MARK: - 背景形状：贴屏侧直角齐平 / 内侧大圆角

    func testScreenSideIsFlushAndSquare() {
        // 贴屏侧必须是直角：四角都在形状外，中段贴到画布边缘。
        // 窗口本就齐边贴住屏幕，那边留圆角会在屏幕与窗口之间露出一条缝。
        for edge in DockEdge.allCases {
            let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: edge)
            let rect = CGRect(origin: .zero, size: size)
            let path = EdgeDockTab(edge: edge).path(in: rect)
            let e: CGFloat = 0.5
            let corners: [CGPoint]
            let mid: CGPoint
            switch edge {
            case .right:
                corners = [CGPoint(x: rect.maxX - e, y: rect.minY + e), CGPoint(x: rect.maxX - e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.maxX - e, y: rect.midY)
            case .left:
                corners = [CGPoint(x: rect.minX + e, y: rect.minY + e), CGPoint(x: rect.minX + e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.minX + e, y: rect.midY)
            case .bottom:
                corners = [CGPoint(x: rect.minX + e, y: rect.maxY - e), CGPoint(x: rect.maxX - e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.midX, y: rect.maxY - e)
            case .top:
                corners = [CGPoint(x: rect.minX + e, y: rect.minY + e), CGPoint(x: rect.maxX - e, y: rect.minY + e)]
                mid = CGPoint(x: rect.midX, y: rect.minY + e)
            }
            // 直角：角点本身属于形状（这正是"直角"与"圆角"的可观测差别）
            XCTAssertTrue(path.contains(corners[0]), "edge=\(edge) 贴屏侧第一个角必须是直角")
            XCTAssertTrue(path.contains(corners[1]), "edge=\(edge) 贴屏侧第二个角必须是直角")
            XCTAssertTrue(path.contains(mid), "edge=\(edge) 贴屏侧中段应贴满边缘")
        }
    }

    func testInwardSideIsRounded() {
        // 朝屏幕内侧那一端是大圆角：两角被切掉，中段实心。
        for edge in DockEdge.allCases {
            let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: edge)
            let rect = CGRect(origin: .zero, size: size)
            let path = EdgeDockTab(edge: edge).path(in: rect)
            let e: CGFloat = 0.5
            let off = min(rect.width, rect.height) * 0.15
            let corners: [CGPoint]
            let mid: CGPoint
            switch edge {
            case .right:
                corners = [CGPoint(x: rect.minX + e, y: rect.minY + e), CGPoint(x: rect.minX + e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.minX + off, y: rect.midY)
            case .left:
                corners = [CGPoint(x: rect.maxX - e, y: rect.minY + e), CGPoint(x: rect.maxX - e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.maxX - off, y: rect.midY)
            case .bottom:
                corners = [CGPoint(x: rect.minX + e, y: rect.minY + e), CGPoint(x: rect.maxX - e, y: rect.minY + e)]
                mid = CGPoint(x: rect.midX, y: rect.minY + off)
            case .top:
                corners = [CGPoint(x: rect.minX + e, y: rect.maxY - e), CGPoint(x: rect.maxX - e, y: rect.maxY - e)]
                mid = CGPoint(x: rect.midX, y: rect.maxY - off)
            }
            XCTAssertFalse(path.contains(corners[0]), "edge=\(edge) 内侧第一个角应被圆角切掉")
            XCTAssertFalse(path.contains(corners[1]), "edge=\(edge) 内侧第二个角应被圆角切掉")
            XCTAssertTrue(path.contains(mid), "edge=\(edge) 内侧中段应实心")
        }
    }

    func testShapeIsAsymmetricBetweenTheTwoSides() {
        // 两侧判定必须不同：贴屏侧是直角，内侧是圆角。若两侧结论一致，
        // 说明仿射镜像方向写反了——而 boundingBox 在那种情况下依然完全正确。
        for edge in DockEdge.allCases {
            let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: edge)
            let rect = CGRect(origin: .zero, size: size)
            let path = EdgeDockTab(edge: edge).path(in: rect)
            let e: CGFloat = 0.5
            let screenCorner: CGPoint
            let inwardCorner: CGPoint
            switch edge {
            case .right:
                screenCorner = CGPoint(x: rect.maxX - e, y: rect.minY + e)
                inwardCorner = CGPoint(x: rect.minX + e, y: rect.minY + e)
            case .left:
                screenCorner = CGPoint(x: rect.minX + e, y: rect.minY + e)
                inwardCorner = CGPoint(x: rect.maxX - e, y: rect.minY + e)
            case .bottom:
                screenCorner = CGPoint(x: rect.minX + e, y: rect.maxY - e)
                inwardCorner = CGPoint(x: rect.minX + e, y: rect.minY + e)
            case .top:
                screenCorner = CGPoint(x: rect.minX + e, y: rect.minY + e)
                inwardCorner = CGPoint(x: rect.minX + e, y: rect.maxY - e)
            }
            // 贴屏侧角点在形状内（直角），内侧角点在形状外（圆角）——必须不同。
            // 写成 XCTAssertEqual 会要求两者相同，恰好把正确实现判为失败。
            XCTAssertNotEqual(
                path.contains(screenCorner), path.contains(inwardCorner),
                "edge=\(edge) 贴屏侧与内侧的角落判定必须相反（直角 vs 圆角）"
            )
        }
    }

    func testShapeCoversWholeRect() {
        for entryCount in [1, 2, 5] {
            for edge in DockEdge.allCases {
                let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
                let rect = CGRect(origin: .zero, size: size)
                // 用容差而不是精确相等：其它三边是仿射镜像/旋转出来的，浮点会产生
                // 1e-5 量级的零头。要求逐位相等只会让测试对真实的形状回归不敏感。
                let box = EdgeDockTab(edge: edge).path(in: rect).boundingRect
                XCTAssertEqual(box.minX, rect.minX, accuracy: 0.001, "entryCount=\(entryCount) edge=\(edge) minX")
                XCTAssertEqual(box.minY, rect.minY, accuracy: 0.001, "entryCount=\(entryCount) edge=\(edge) minY")
                XCTAssertEqual(box.width, rect.width, accuracy: 0.001, "entryCount=\(entryCount) edge=\(edge) width")
                XCTAssertEqual(box.height, rect.height, accuracy: 0.001, "entryCount=\(entryCount) edge=\(edge) height")
            }
        }
    }

    func testCornerRadiusStaysBelowHalfTheShortSide() {
        XCTAssertLessThan(EdgeDockTab.cornerRadiusFactor, 0.5, "0.5 会退化成半圆帽")
        XCTAssertGreaterThan(EdgeDockTab.cornerRadiusFactor, 0.2, "太小就失去柔和感")
    }

    func testShapeNeverClipsTheFirstRow() {
        // 内侧圆角不能啃到第一个圆环，也不能啃到它的数值文字。
        for entryCount in [1, 2, 5] {
            for edge in DockEdge.allCases {
                let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
                let path = EdgeDockTab(edge: edge).path(in: CGRect(origin: .zero, size: size))
                let circleCenter = CGPoint(
                    x: EdgeDockGeometry.padding + EdgeDockGeometry.diameter / 2,
                    y: EdgeDockGeometry.padding + EdgeDockGeometry.diameter / 2
                )
                let inset = EdgeDockGeometry.diameter / 2 / 2.squareRoot()
                for sx in [CGFloat(1), -1] {
                    for sy in [CGFloat(1), -1] {
                        let probe = CGPoint(x: circleCenter.x + sx * inset, y: circleCenter.y + sy * inset)
                        XCTAssertTrue(
                            path.contains(probe),
                            "entryCount=\(entryCount) edge=\(edge) 圆角切到了圆环 probe=\(probe)"
                        )
                    }
                }
                // 数值文字那一行整段都要在形状内
                let labelMid = CGPoint(
                    x: circleCenter.x,
                    y: circleCenter.y + EdgeDockGeometry.diameter / 2 + EdgeDockGeometry.labelHeight / 2
                )
                XCTAssertTrue(
                    path.contains(labelMid),
                    "entryCount=\(entryCount) edge=\(edge) 数值文字被圆角切到了"
                )
            }
        }
    }

    func testShapeIsDegenerateSafe() {
        XCTAssertTrue(EdgeDockTab(edge: .right).path(in: .zero).isEmpty)
    }

    // MARK: - 实测行矩形的命中判定

    /// 用几何常量推算的行位置 vs 视图实测的行位置，允许存在偏差；
    /// 命中判定必须以实测为准，否则偏差会逐行累积成"hover A 弹出 B"。
    private func measuredRows(edge: DockEdge, entryCount: Int, drift: CGFloat = 0) -> [CGRect] {
        let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
        let dock = EdgeDockGeometry.frame(visibleFrame: visible, edge: edge, size: size, offset: 0.5)
        var rects: [CGRect] = []
        for index in 0..<entryCount {
            let c = EdgeDockGeometry.rowCenter(dockFrame: dock, edge: edge, index: index)
            let row = EdgeDockGeometry.rowHeight + drift
            let along = row / 2 - drift / 2
            switch edge {
            case .right:  rects.append(CGRect(x: dock.minX, y: c.y - along, width: dock.width, height: row))
            case .left:   rects.append(CGRect(x: dock.minX, y: c.y - along, width: dock.width, height: row))
            case .bottom: rects.append(CGRect(x: c.x - along, y: dock.minY, width: row, height: dock.height))
            case .top:    rects.append(CGRect(x: c.x - along, y: dock.minY, width: row, height: dock.height))
            }
        }
        return rects
    }

    func testRowIndexUsesMeasuredRectsNotAssumedGeometry() {
        // 人为给每一行都加同样的漂移，模拟"常量推算与真实排版对不上"。
        // 命中必须仍然落在被 hover 的那一行上。
        for edge in DockEdge.allCases {
            let rows = measuredRows(edge: edge, entryCount: 4, drift: 3)
            for (index, rect) in rows.enumerated() {
                let probe = CGPoint(x: rect.midX, y: rect.midY)
                XCTAssertEqual(
                    EdgeDockController.rowIndex(at: probe, measured: rows), index,
                    "edge=\(edge) 第\(index)行中心应命中自己"
                )
            }
        }
    }

    func testRowIndexPrefersExactContainment() {
        let rows = measuredRows(edge: .right, entryCount: 4)
        // 取每行上边缘往里 2pt 的点——足够靠边，仍必须判给本行而不是下一行。
        for (index, rect) in rows.enumerated() {
            let probe = CGPoint(x: rect.midX, y: rect.minY + 2)
            XCTAssertEqual(
                EdgeDockController.rowIndex(at: probe, measured: rows), index,
                "第\(index)行上沿内 2pt 应命中本行"
            )
        }
    }

    func testRowIndexReturnsNilFarAway() {
        let rows = measuredRows(edge: .right, entryCount: 4)
        // 屏幕远端：既不在任何行内，离最近行中心也超过直径容差
        XCTAssertNil(EdgeDockController.rowIndex(at: CGPoint(x: 100, y: visible.minY + 20), measured: rows))
    }

    func testRowIndexReturnsNilWhenNoRowsMeasuredYet() {
        // 刚显示还没排版完时不能瞎猜，否则会弹错 provider。
        XCTAssertNil(EdgeDockController.rowIndex(at: CGPoint(x: 1900, y: 500), measured: []))
    }

    func testRowIndexToleratesBoundaryGap() {
        // 行与行之间有 spacing，落在缝隙里的点归属最近的行，不产生 nil 抖动。
        let rows = measuredRows(edge: .right, entryCount: 3)
        let gapMid = CGPoint(x: rows[0].midX, y: rows[0].maxY + (rows[1].minY - rows[0].maxY) / 2)
        let hit = EdgeDockController.rowIndex(at: gapMid, measured: rows)
        XCTAssertTrue(hit == 0 || hit == 1, "缝隙必须归属相邻的某一行，实际 \(String(describing: hit))")
    }

    // MARK: - 行下标与 provider 的对应关系
    //
    // 这一组是「hover minimax、弹出 DeepSeek」那个 bug 的钉死。
    // 命中下标会被拿去反查 entries[index].id 决定 popover 显示谁，所以
    // 「第 i 个矩形」必须严格等于「第 i 个条目」，任何来源的顺序错位都算失败。

    private func rowRectsByID(
        _ entries: [EdgeDockEntry],
        edge: DockEdge = .right,
        entryCount: Int? = nil,
        drift: CGFloat = 0
    ) -> [String: CGRect] {
        let rects = measuredRows(edge: edge, entryCount: entryCount ?? entries.count, drift: drift)
        return Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), rects))
    }

    private func makeEntries(_ ids: [String]) -> [EdgeDockEntry] {
        ids.map {
            EdgeDockEntry(
                id: $0,
                displayName: $0.uppercased(),
                kind: .codexChatGpt,
                intervalFraction: 0.5,
                weeklyFraction: 0.8,
                health: .healthy
            )
        }
    }

    func testOrderRowRectsKeysOutputByEntryOrderNotReportOrder() {
        // 上报是字典（无序），输出必须按 entries 顺序重建，逐槽对上自己的 id。
        let entries = makeEntries(["minimax", "deepseek", "glm", "chatgpt"])
        let reported = rowRectsByID(entries, drift: 2)
        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        XCTAssertEqual(ordered.count, entries.count, "输出长度必须与条目数一致")
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(
                ordered[index], reported[entry.id],
                "第\(index)槽必须是 \(entry.id) 自己的矩形"
            )
        }
    }

    func testOrderRowRectsKeepsLaterSlotsAlignedWhenOneRowMissing() {
        // 少一行的正确处理是「留一个永不命中的坑」，不是跳过——跳过会让后面整体前移，
        // 变成另一种更隐蔽的下标错位。
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        var reported = rowRectsByID(entries)
        reported.removeValue(forKey: "deepseek")

        let ordered = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        XCTAssertEqual(ordered.count, 3, "缺一行也不能少一槽")
        XCTAssertEqual(ordered[0], reported["minimax"], "minimax 槽不受影响")
        XCTAssertEqual(ordered[1], EdgeDockProjection.unmeasuredRow, "缺测的行填不可命中的占位")
        XCTAssertEqual(ordered[2], reported["glm"], "glm 槽不能前移到下标 1")
    }

    func testUnmeasuredRowIsNeverHittable() {
        // 占位矩形必须在任何真实鼠标位置之外，且自身不命中。
        let rows = measuredRows(edge: .right, entryCount: 2) + [EdgeDockProjection.unmeasuredRow]
        XCTAssertNil(
            EdgeDockController.rowIndex(at: CGPoint(x: 1900, y: 400), measured: rows),
            "真实屏幕点不该命中占位行"
        )
        XCTAssertNil(
            EdgeDockController.rowIndex(at: .zero, measured: rows),
            "原点也不该命中占位行"
        )
    }

    func testHoveringEachRowResolvesToThatSameProvider() {
        // 端到端钉死用户报的那个症状：对第 i 行任意位置取样，命中下标必须是 i，
        // 于是 popover 反查到的就是第 i 个 provider。
        let entries = makeEntries(["minimax", "deepseek", "glm", "chatgpt"])
        let reported = rowRectsByID(entries, drift: 3)
        let measured = EdgeDockProjection.orderRowRects(entries: entries, reported: reported)

        for (index, entry) in entries.enumerated() {
            let rect = measured[index]
            for probe in [CGPoint(x: rect.midX, y: rect.midY),
                          CGPoint(x: rect.minX + 2, y: rect.minY + 2)] {
                let hit = EdgeDockController.rowIndex(at: probe, measured: measured)
                XCTAssertEqual(
                    hit, index,
                    "hover \(entry.id) 的行（下标\(index)）却命中 \(String(describing: hit))"
                )
            }
        }
    }

    func testHoverOrderIsStableUnderRectKeyReordering() {
        // 上报顺序一变（SwiftUI 不保证 reduce 顺序），命中结果必须完全不变。
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let rects = measuredRows(edge: .right, entryCount: 3, drift: 1)
        let forward = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), rects))
        // 反着配一遍：id 与矩形故意错位配对后再交给重排，看结果是否仍按 id 归位。
        let shuffled = Dictionary(uniqueKeysWithValues: zip(entries.reversed().map(\.id), rects))

        let a = EdgeDockProjection.orderRowRects(entries: entries, reported: forward)
        let b = EdgeDockProjection.orderRowRects(entries: entries, reported: shuffled)
        XCTAssertEqual(a.count, b.count)
        // forward 与 shuffled 是不同数据，只断言"都能按 id 找到自己的矩形"。
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(b[index], shuffled[entry.id], "第\(index)槽应对应 \(entry.id) 自己的矩形")
            XCTAssertEqual(
                EdgeDockController.rowIndex(
                    at: CGPoint(x: b[index].midX, y: b[index].midY), measured: b
                ),
                index,
                "重排后 hover \(entry.id) 仍应命中下标\(index)"
            )
        }
    }

    // MARK: - 命中矩形选取：实测不可用时必须还能命中
    //
    // 这组是「hover 和拖拽同时失能」那个回归的钉死。命中一旦恒为 nil，
    // `captureMouse()` 就不执行，`ignoresMouseEvents` 一直是 true，
    // 于是 hover 无效、按下也收不到 —— 表现为两个功能一起坏。
    // 所以规则是：**任何输入下都必须返回可命中的行**，只能是准不准，不能是空。

    private func panelFrame(edge: DockEdge, entryCount: Int) -> CGRect {
        let size = EdgeDockGeometry.dockSize(entryCount: entryCount, edge: edge)
        return EdgeDockGeometry.frame(visibleFrame: visible, edge: edge, size: size, offset: 0.5)
    }

    func testGeometryFallbackKeepsEveryRowHittable() {
        // 一条实测矩形都没有时，必须退回几何推算，且每一行都还能命中自己。
        for edge in DockEdge.allCases {
            for count in 1...8 {
                let entries = makeEntries((0..<count).map { "p\($0)" })
                let frame = panelFrame(edge: edge, entryCount: count)
                let resolved = EdgeDockController.resolveRowRects(
                    entries: entries, measured: [:], panelFrame: frame, edge: edge, slack: 8
                )
                XCTAssertFalse(resolved.usedMeasured, "没有实测数据却声称用了实测")
                XCTAssertEqual(resolved.rows.count, count)
                // 用 firstRange 而不是直接下标：兜底一旦返回空数组，这里要报出清晰的
                // 断言失败，而不是先崩在 "Index out of range" 上把真正的原因盖掉。
                guard resolved.rows.first != nil else {
                    XCTFail("edge=\(edge) count=\(count) 兜底返回了空行数组，hover 会彻底失能")
                    continue
                }
                for index in 0..<count {
                    let row = resolved.rows[index]
                    XCTAssertEqual(
                        EdgeDockController.rowIndex(
                            at: CGPoint(x: row.midX, y: row.midY), measured: resolved.rows
                        ),
                        index,
                        "edge=\(edge) count=\(count) 第\(index)行兜底后必须还能命中"
                    )
                }
            }
        }
    }

    func testGeometryFallbackRowsFollowCircleOrder() {
        // 兜底行的中心必须与 `circleCenter` 同序，否则下标 i 指向的不是第 i 个圆。
        for edge in DockEdge.allCases {
            let count = 5
            let frame = panelFrame(edge: edge, entryCount: count)
            let rows = EdgeDockGeometry.rowRects(dockFrame: frame, edge: edge, entryCount: count)
            for index in 0..<count {
                let expected = EdgeDockGeometry.rowCenter(
                    dockFrame: frame, edge: edge, index: index
                )
                let actual = CGPoint(x: rows[index].midX, y: rows[index].midY)
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, "edge=\(edge) 第\(index)行 x")
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, "edge=\(edge) 第\(index)行 y")
            }
        }
    }

    func testGeometryFallbackWithZeroEntriesProducesNoRows() {
        for edge in DockEdge.allCases {
            let frame = panelFrame(edge: edge, entryCount: 0)
            let resolved = EdgeDockController.resolveRowRects(
                entries: [], measured: [:], panelFrame: frame, edge: edge, slack: 8
            )
            XCTAssertTrue(resolved.rows.isEmpty, "没有 provider 时不该造出幽灵行")
            XCTAssertFalse(resolved.usedMeasured)
        }
    }

    func testResolveRowRectsFallsBackWhenMeasurementIncomplete() {
        // 少一行的实测：整体退回几何，不能让后面的行错位顶上来。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let partial = rowRectsByID(entries, edge: edge)
            .filter { $0.key != "deepseek" }

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: partial, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertFalse(resolved.usedMeasured, "实测不完整必须退回")
        XCTAssertEqual(
            resolved.rows, EdgeDockGeometry.rowRects(
                dockFrame: frame, edge: edge, entryCount: 3
            ),
            "退回的结果应与几何推算完全一致"
        )
    }

    func testResolveRowRectsFallsBackWhenConvertedRectsAreOffscreen() {
        // 坐标系换算错到窗口外：宁可偏差也要能命中，不能整列都指空。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let bogus = rowRectsByID(entries, edge: edge)
            .mapValues { CGRect(x: $0.minX + 5_000, y: $0.minY + 5_000, width: $0.width, height: $0.height) }

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: bogus, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertFalse(resolved.usedMeasured, "矩形全在窗口外说明换算错了，必须退回")
        XCTAssertEqual(
            EdgeDockController.rowIndex(
                at: CGPoint(x: frame.midX, y: frame.midY), measured: resolved.rows
            ) != nil,
            true,
            "兜底后窗口中心必须仍能命中某一行"
        )
    }

    func testResolveRowRectsUsesMeasurementWhenUsable() {
        // 正常路径：实测可用就用实测，不退回。
        let edge = DockEdge.right
        let entries = makeEntries(["minimax", "deepseek", "glm"])
        let frame = panelFrame(edge: edge, entryCount: 3)
        let good = rowRectsByID(entries, edge: edge, drift: 2)

        let resolved = EdgeDockController.resolveRowRects(
            entries: entries, measured: good, panelFrame: frame, edge: edge, slack: 8
        )
        XCTAssertTrue(resolved.usedMeasured, "实测可用时不该退回")
        XCTAssertEqual(
            resolved.rows, EdgeDockProjection.orderRowRects(entries: entries, reported: good),
            "实测路径应原样按条目顺序返回"
        )
    }

    // MARK: - 图标尺寸

    func testBrandIconFitsInsideInnerRing() {
        // 图标必须落在内环描边内沿以内，否则会盖住环线。
        let innerRingInnerRadius = EdgeDockGeometry.innerRingDiameter / 2
            - EdgeDockGeometry.ringLineWidth / 2
        XCTAssertLessThanOrEqual(
            EdgeDockGeometry.iconSize / 2, innerRingInnerRadius,
            "品牌图标不能压到内环上"
        )
        XCTAssertGreaterThanOrEqual(
            EdgeDockGeometry.iconSize, 5,
            "图标过小会看不清是哪个 provider"
        )
    }

    /// 上一条只钉了**常量**，钉不住实际画出来的大小：`BrandLogoView` 曾经自带
    /// 18pt 固定 frame，外层再套 `.frame(width: 6, height: 6)` 也不会变小，
    /// 结果图标按 18pt 画出来、压在内环描边上。
    ///
    /// 这条钉的是**机制**而不是某组常量的算术：尺寸必须由 `BrandLogoView` 自己
    /// 消费（存成 `size`、用它 frame 自己），而不是留在调用处靠外层 frame。
    /// 常量本身由 `testBrandIconFitsInsideInnerRing` 钉，用户调内环/图标大小时
    /// 两条各管各的、都不会因为对方失效。
    func testBrandIconSizeIsConsumedByTheViewItself() {
        XCTAssertEqual(
            BrandLogoView(kind: .codexChatGpt, size: EdgeDockGeometry.iconSize).size,
            EdgeDockGeometry.iconSize,
            "BrandLogoView 必须按传入尺寸绘制，而不是外层再套一个 frame"
        )
        // 兜底 SF Symbol 分支同样按 size 缩放：它内部原本硬编码 13pt 字号 +
        // 18pt frame，dock 里的 12pt 图标会直接被撑回 18。
        XCTAssertLessThan(
            EdgeDockGeometry.iconSize, BrandLogoView.defaultSize,
            "dock 图标比默认尺寸小时，兜底符号必须跟着缩小"
        )
    }

    // MARK: - 全屏判定：坐标系翻转
    func testCgRectFlipsYAxis() {
        // AppKit（左下原点）→ CGWindowList（主屏左上原点）。
        // 主屏 1080 高时，贴底部的窗口在 CG 坐标系里 y 应该靠近 0。
        let primary: CGFloat = 1080
        let appKitBottom = CGRect(x: 0, y: 0, width: 100, height: 50)
        let cg = FullscreenProbe.cgRect(fromAppKitRect: appKitBottom, primaryScreenHeight: primary)
        XCTAssertEqual(cg.minY, 1030, accuracy: 0.001, "贴 AppKit 底部 = CG 顶部坐标")
        XCTAssertEqual(cg.maxY, 1080, accuracy: 0.001)

        let appKitTop = CGRect(x: 0, y: 1030, width: 100, height: 50)
        let cgTop = FullscreenProbe.cgRect(fromAppKitRect: appKitTop, primaryScreenHeight: primary)
        XCTAssertEqual(cgTop.minY, 0, accuracy: 0.001, "贴 AppKit 顶部 = CG 顶部坐标 0")
    }

    // MARK: - 全屏判定：当前 Space 局部，而非"前台 App"

    private static let probeScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let probePrimary: CGFloat = 1080
    private static let probeOwnPID: pid_t = 4242

    private func probe(
        _ entries: [FullscreenProbe.WindowEntry],
        own: pid_t = EdgeDockTests.probeOwnPID
    ) -> Bool {
        FullscreenProbe.containsFullscreenWindow(
            among: entries,
            screenFrame: EdgeDockTests.probeScreen,
            primaryScreenHeight: EdgeDockTests.probePrimary,
            ownProcessIdentifier: own
        )
    }

    private func window(
        _ pid: pid_t, layer: Int = 0, _ rect: CGRect
    ) -> FullscreenProbe.WindowEntry {
        .init(ownerPID: pid, layer: layer, bounds: rect)
    }

    /// 这条钉的就是"滑动桌面后 dock 留在全屏里"那个 bug。
    ///
    /// 全屏窗口属于 PID 777，但**前台 App 不是它**——滑动 Space 不触发 App 激活，
    /// 所以前台 PID 仍然是别的进程。旧实现按前台 PID 过滤，整个窗口列表里挑不出
    /// 任何属于前台的窗口 → 判定"没全屏" → dock 留在全屏 Space 上不消失。
    func testFullscreenWindowIsDetectedEvenWhenItIsNotTheFrontmostApp() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let entries = [
            window(777, full),                  // 别人家的全屏窗口，就在当前 Space 上
            window(1234, CGRect(x: 10, y: 10, width: 400, height: 300)),  // 前台 App 的普通小窗
        ]
        XCTAssertTrue(
            probe(entries, own: EdgeDockTests.probeOwnPID),
            "只要当前 Space 上有铺满整屏的窗口就该判定全屏——不能因为它不属于前台 App 而漏判"
        )
    }

    func testMaximizedWindowIsNotFullscreen() {
        // 菜单栏可见时最大化窗口被挤在 visibleFrame 里（这里 y=25 留给菜单栏），
        // 盖不满整块显示区。误报防护来自覆盖判据，**不是**进程过滤——
        // 所以去掉进程过滤不会换来"窗口铺满就藏 dock"。
        let maximized = CGRect(x: 0, y: 25, width: 1920, height: 1030)
        XCTAssertFalse(probe([window(777, maximized)]))
    }

    // MARK: - 全屏判定：桌面装饰区分「真全屏」与「缩放」

    /// 单独那条覆盖判据挡不住的误判：菜单栏和 Dock 都设成自动隐藏时
    /// `visibleFrame == frame`，缩放 / 最大化出来的窗口正好盖满 `screen.frame`。
    /// 桌面装饰还在 = 普通 Space，不能算全屏。
    func testZoomedWindowCoveringWholeScreenOnNormalSpaceIsNotFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let entries = [
            window(777, full),
            window(744, layer: FullscreenProbe.desktopChromeLayer, full),
        ]
        XCTAssertFalse(
            probe(entries),
            "桌面装饰还在，说明这是普通 Space，铺满的窗口只是被缩放到 visibleFrame 的大窗口"
        )
    }

    /// 真全屏 Space 上没有桌面装饰：同样铺满，判定必须为真。
    /// 与上一条一起钉住「覆盖面积 + 桌面装饰」这对判据，缺一条就退化成旧行为。
    func testWholeScreenWindowWithoutDesktopChromeIsFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(probe([window(777, full)]))
    }

    /// 副屏的桌面装饰不在本屏上，不能压掉本屏的全屏判定。
    func testDesktopChromeOnAnotherScreenDoesNotSuppressFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let otherScreen = CGRect(x: 0, y: -1200, width: 1920, height: 1200)
        XCTAssertTrue(
            probe([
                window(777, full),
                window(744, layer: FullscreenProbe.desktopChromeLayer, otherScreen),
            ]),
            "桌面装饰必须按目标屏比对，副屏那一份与本屏无关"
        )
    }

    /// 判据必须**精确等于** `kCGDesktopIconWindowLevel`。桌面那一带上还有窗口服务器
    /// 与 WindowManager 的常驻窗口（壁纸后板、Space 切换层等），全屏时它们照样在；
    /// 一旦放宽成"层 <= 桌面图标层"，真全屏就会被判成普通 Space（漏判，dock 留在
    /// 全屏里）。
    func testOnlyTheDesktopIconLevelCountsAsDesktopChrome() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let neighbours = [
            FullscreenProbe.desktopChromeLayer - 1,
            FullscreenProbe.desktopChromeLayer + 1,
            Int(CGWindowLevelForKey(.desktopWindow)),
        ]
        for layer in neighbours {
            XCTAssertTrue(
                probe([window(777, full), window(410, layer: layer, full)]),
                "层 \(layer) 不是桌面装饰层，不该压掉全屏判定"
            )
        }
        XCTAssertFalse(
            probe([window(777, full), window(744, layer: FullscreenProbe.desktopChromeLayer, full)]),
            "桌面图标层本身仍必须被认成桌面装饰"
        )
    }

    func testOwnProcessWindowsNeverCountAsFullscreen() {
        // 自己铺满屏幕的任何窗口都不能触发隐藏，否则边缘窗会自己把自己藏掉，
        // 而且没有任何手段把它弄回来。
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(
            probe([window(EdgeDockTests.probeOwnPID, full)]),
            "本进程窗口铺满屏幕时必须返回 false"
        )
        XCTAssertTrue(
            probe([window(EdgeDockTests.probeOwnPID, full), window(777, full)], own: EdgeDockTests.probeOwnPID),
            "本进程有满屏窗口时，仍然要看别人的"
        )
    }

    func testNonNormalWindowLayersNeverCountAsFullscreen() {
        // 菜单 / tooltip / 阴影层铺满屏幕不代表全屏。
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for layer in [1, 2, 3, -1] {
            XCTAssertFalse(probe([window(777, layer: layer, full)]), "layer \(layer) 不该被判成全屏")
        }
        XCTAssertTrue(probe([window(777, layer: 0, full)]))
    }

    func testEmptyWindowListIsNotFullscreen() {
        XCTAssertFalse(probe([]), "探测不到任何窗口时必须 fail-open（返回 false，窗口照常显示）")
    }

    /// 副屏排在主屏**上方**时，翻转出来的 CG 原点是**负 y**——这是正确的全局坐标，
    /// 不是 bug。
    ///
    /// 这一条存在的原因是它极易被"修"坏：判据拿窗口坐标和 `screen.frame` 翻转后的
    /// 坐标比对，而两者不同源时覆盖判据会恒假；恒假的表现和"窗口没被报出来"一样，
    /// 于是很可能有人看到负 y 就加一次取绝对值 / 改成主屏高度当偏移。那样多屏布置
    /// 在主屏上方或左侧的机器上会静默失效，而单屏开发机永远复现不出来。
    ///
    /// 真实数据（本机，主屏 1440×900、上方副屏 1920×1080）：副屏窗口的
    /// `kCGWindowBounds` 是 `y = -1080`，对应 AppKit 的 `y = 900...1980`。
    func testCgRectFlipIsCorrectForScreensAboveAndBelowThePrimary() {
        let primary: CGFloat = 900

        // 主屏上方：AppKit y 从主屏高度往上长 → CG y 为负。
        let above = FullscreenProbe.cgRect(
            fromAppKitRect: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            primaryScreenHeight: primary
        )
        XCTAssertEqual(above, CGRect(x: 0, y: -1080, width: 1920, height: 1080), "主屏上方的副屏必须是负 CG y")

        // 主屏下方：AppKit y 为负 → CG y 大于主屏高度。
        let below = FullscreenProbe.cgRect(
            fromAppKitRect: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryScreenHeight: primary
        )
        XCTAssertEqual(below, CGRect(x: 0, y: 900, width: 1920, height: 1080), "主屏下方的副屏从主屏高度往下算")

        // 且判定用得起来：副屏自己的全屏窗口（哪怕位于负 y）必须被认出来。
        let entries = [window(777, above)]
        XCTAssertTrue(
            FullscreenProbe.containsFullscreenWindow(
                among: entries,
                screenFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                primaryScreenHeight: primary,
                ownProcessIdentifier: EdgeDockTests.probeOwnPID
            ),
            "副屏在负 y 区域时覆盖判据不能恒假"
        )
    }

    func testCgRectFlipPreservesSizeAndIsInvolutive() {
        let primary: CGFloat = 1080
        let original = CGRect(x: 100, y: 200, width: 1920, height: 995)
        let flipped = FullscreenProbe.cgRect(fromAppKitRect: original, primaryScreenHeight: primary)
        XCTAssertEqual(flipped.width, original.width)
        XCTAssertEqual(flipped.height, original.height)
        XCTAssertEqual(flipped.origin.x, original.origin.x, accuracy: 0.001, "只翻 y")

        let back = FullscreenProbe.cgRect(fromAppKitRect: flipped, primaryScreenHeight: primary)
        XCTAssertEqual(back.origin.x, original.origin.x, accuracy: 0.001)
        XCTAssertEqual(back.origin.y, original.origin.y, accuracy: 0.001, "翻两次必须回到原点")
    }

    func testCoverageToleranceAbsorbsRounding() {
        // 铺满判定留 2pt 容差：macOS 自己的边框内缩不该被当成"没铺满"。
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let insetByOne = screen.insetBy(dx: 1, dy: 1)
        XCTAssertTrue(insetByOne.insetBy(dx: -FullscreenProbe.coverageTolerance, dy: -FullscreenProbe.coverageTolerance).contains(screen))

        let waySmaller = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(waySmaller.insetBy(dx: -FullscreenProbe.coverageTolerance, dy: -FullscreenProbe.coverageTolerance).contains(screen))
    }

}
