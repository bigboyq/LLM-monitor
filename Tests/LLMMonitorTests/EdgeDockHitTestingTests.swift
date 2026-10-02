import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 「指针指中了哪个圆」——对应 `EdgeDockController.circleIndex`。
final class EdgeDockHitTestingTests: EdgeDockTestCase {

    // MARK: - hover 命中：鼠标位置 → 圆下标

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
        // 「小圆环」形态逐行 hover 用：小档 7pt 的圆（半径 3.5）照圆判定等于要指中
        // 一个 7px 的点，指偏 4pt 就换了一张卡。传半个行距当判定半径下限之后，
        // 圆心旁 6pt 处仍然命中**这一行**。三档的行距不同，判定半径也跟着变。
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            let compact = EdgeDockGeometry.dockSize(
                entryCount: 3, edge: .right, appearance: .compact, compactSize: size
            )
            let dock = makeDockFrame(edge: .right, entryCount: 3, size: compact)
            let step = EdgeDockGeometry.compactRowStep(for: size)
            let circles: [CGRect] = (0..<3).map { index in
                let center = CGPoint(
                    x: dock.midX,
                    y: dock.maxY - m.padding - m.diameter / 2 - CGFloat(index) * step
                )
                return CGRect(
                    x: center.x - m.diameter / 2,
                    y: center.y - m.diameter / 2,
                    width: m.diameter,
                    height: m.diameter
                )
            }
            // 圆外一点（圆半径 +1.5pt）：按圆判定不命中，按半个行距判定命中。
            // 偏移量必须**跟着档位算**——写死 6 在中/大档上会落进圆内，那条
            // "不传下限时按圆判定"的断言会变成在测另一件事。
            let outside = m.diameter / 2 + 1.5
            let sixOut = CGPoint(x: circles[1].midX + outside, y: circles[1].midY)
            XCTAssertNil(
                EdgeDockController.circleIndex(at: sixOut, circles: circles),
                "\(size) 不传下限时行为与从前逐字相同：只认圆半径"
            )
            XCTAssertEqual(
                EdgeDockController.circleIndex(
                    at: sixOut, circles: circles, minimumRadius: step / 2
                ),
                1,
                "\(size) 半个行距 \(step / 2)pt 必须覆盖到圆外 \(outside)pt 处"
            )
            // 相邻两环的判定区在中点接上：越靠近哪一个就归哪一个，不会因为"先遍历到
            // 上面那个"而张冠李戴（中点 ±0.5pt 那一格是 0.5pt 容差，两边都算命中，
            // 循环先到者胜——与完整形态用同一条容差规则，不另开特例）。
            // 取"半个行距往回 2.1pt"：明显偏向本环，又不越中点，三档通用。
            let nearerToSecond = CGPoint(
                x: circles[1].midX, y: circles[1].midY - (step / 2 - 2.1)
            )
            XCTAssertEqual(
                EdgeDockController.circleIndex(
                    at: nearerToSecond, circles: circles, minimumRadius: step / 2
                ),
                1,
                "\(size) 明显更靠近第二个环的点必须算第二个环"
            )
            let nearerToFirst = CGPoint(
                x: circles[0].midX, y: circles[0].midY + (step / 2 - 2.1)
            )
            XCTAssertEqual(
                EdgeDockController.circleIndex(
                    at: nearerToFirst, circles: circles, minimumRadius: step / 2
                ),
                0,
                "\(size) 明显更靠近第一个环的点必须算第一个环"
            )
        }
    }
}
