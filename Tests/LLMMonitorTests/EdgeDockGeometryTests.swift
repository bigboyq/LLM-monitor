import XCTest
import CoreGraphics
import SwiftUI
@testable import LLM_monitor

/// 窗口尺寸、贴边 frame、offset 往返与最近边吸附，以及圆环外观常量。对应 `EdgeDockGeometry` / `+Window`。
final class EdgeDockGeometryTests: EdgeDockTestCase {

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

    // MARK: - 简版 dock（自动隐藏模式的收起形态）

    func testCompactDockSizeGrowsVerticallyOnVerticalEdges() {
        // 简版没有数值文字：厚度轴 = 单环直径 + 内边距，两个方向同值。
        // 三档都要过：档位换的是**整套**尺寸，只验默认档等于没验。
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            let one = EdgeDockGeometry.dockSize(
                entryCount: 1, edge: .right, appearance: .compact, compactSize: size
            )
            XCTAssertEqual(one.width, m.thickness, "\(size) 单条厚度")
            XCTAssertEqual(one.height, m.thickness, "\(size) 单条厚度")

            let three = EdgeDockGeometry.dockSize(
                entryCount: 3, edge: .right, appearance: .compact, compactSize: size
            )
            XCTAssertEqual(three.width, m.thickness, "\(size) 竖排时厚度不随条目数变化")
            XCTAssertEqual(
                three.height,
                CGFloat(3) * m.diameter + CGFloat(2) * m.spacing + m.padding * 2,
                "\(size) 沿边方向 = 环径 ×n + 间距 ×(n-1) + 内边距 ×2"
            )
        }
    }

    func testCompactDockSizeGrowsHorizontallyOnHorizontalEdges() {
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            let three = EdgeDockGeometry.dockSize(
                entryCount: 3, edge: .bottom, appearance: .compact, compactSize: size
            )
            XCTAssertEqual(three.height, m.thickness, "\(size) 横排厚度轴")
            XCTAssertEqual(
                three.width,
                CGFloat(3) * m.diameter + CGFloat(2) * m.spacing + m.padding * 2,
                "\(size) 横排沿边方向"
            )
        }
    }

    func testCompactDockIsSmallerThanFullDock() {
        // 简版的存在意义就是"收起后不显眼"：任何朝向、任何条目数都必须比完整版小。
        // **三档都要满足**：大档的贴边厚度 38 已经逼近完整版的 70，再加一档就会
        // 出现"收起比展开还占地方"——这条不等式是档位表能加到几档的上界。
        for size in EdgeDockCompactSize.allCases {
            for edge in DockEdge.allCases {
                for count in [1, 3, 5] {
                    let full = EdgeDockGeometry.dockSize(entryCount: count, edge: edge, appearance: .full)
                    let compact = EdgeDockGeometry.dockSize(
                        entryCount: count, edge: edge, appearance: .compact, compactSize: size
                    )
                    XCTAssertLessThan(
                        compact.width, full.width, "edge=\(edge) count=\(count) \(size) 必须更窄"
                    )
                    XCTAssertLessThan(
                        compact.height, full.height, "edge=\(edge) count=\(count) \(size) 必须更矮"
                    )
                }
            }
        }
    }

    func testCompactFrameStaysFullyOnScreen() {
        // 简版与完整版共用 frame()：贴边、钳位、offset 0/1 不被裁，缺一不可。
        for size in EdgeDockCompactSize.allCases {
            for edge in DockEdge.allCases {
                let dockSize = EdgeDockGeometry.dockSize(
                    entryCount: 4, edge: edge, appearance: .compact, compactSize: size
                )
                for offset in [0.0, 0.5, 1.0] {
                    let frame = EdgeDockGeometry.frame(
                        visibleFrame: visible, edge: edge, size: dockSize, offset: offset
                    )
                    XCTAssertTrue(
                        visible.contains(frame),
                        "edge=\(edge) offset=\(offset) 简版窗口必须完整可见"
                    )
                }
            }
        }
    }

    /// **档位必须传遍每一条简版几何路径**：行中心、圆心、行矩形、圆矩形都各自
    /// 内部算了一遍锚点与步进，其中任何一处漏传 `compactSize`，症状都是"窗口按
    /// 大档变大、兜底命中仍按小档算"，hover 从第 2 行起逐行错开。
    /// `rowCenter` 曾经就是这样漏的（`step(...)` 忘了带档位），而当时所有尺寸测试
    /// 都只查 `dockSize`，全绿——所以这条按"窗口尺寸 + 四个兜底"整体钉。
    func testCompactTierReachesEveryGeometryPath() {
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            let step = m.rowStep
            let count = 3
            let size2D = EdgeDockGeometry.dockSize(
                entryCount: count, edge: .right, appearance: .compact, compactSize: size
            )
            let dock = makeDockFrame(edge: .right, entryCount: count, size: size2D)

            // 圆心：第 0 行贴 padding，之后按该档行距步进。
            for index in 0..<count {
                let center = EdgeDockGeometry.circleCenter(
                    dockFrame: dock, edge: .right, index: index,
                    appearance: .compact, compactSize: size
                )
                XCTAssertEqual(center.x, dock.midX, accuracy: 0.001, "\(size) 圆心在厚度轴居中")
                XCTAssertEqual(
                    center.y, dock.maxY - m.padding - m.diameter / 2 - CGFloat(index) * step,
                    accuracy: 0.001, "\(size) 第 \(index) 个圆的纵向位置/步进"
                )
            }
            // 行中心：行高退化成环径（简版没有数值文字），但**行距同样按档位**。
            for index in 0..<count {
                let center = EdgeDockGeometry.rowCenter(
                    dockFrame: dock, edge: .right, index: index,
                    appearance: .compact, compactSize: size
                )
                XCTAssertEqual(
                    center.y, dock.maxY - m.padding - m.diameter / 2 - CGFloat(index) * step,
                    accuracy: 0.001, "\(size) 第 \(index) 行的行距必须按档位"
                )
            }
            // 兜底矩形：圆矩形边长 = 环径，行矩形在竖排时铺满窗口厚度。
            let circles = EdgeDockGeometry.circleRects(
                dockFrame: dock, edge: .right, entryCount: count,
                appearance: .compact, compactSize: size
            )
            XCTAssertTrue(
                circles.allSatisfy { abs($0.width - m.diameter) < 0.001 },
                "\(size) 兜底圆边长必须等于该档环径"
            )
            XCTAssertTrue(
                circles.allSatisfy { $0.height < EdgeDockGeometry.diameter },
                "\(size) 兜底圆必须比完整版小"
            )
            let rows = EdgeDockGeometry.rowRects(
                dockFrame: dock, edge: .right, entryCount: count,
                appearance: .compact, compactSize: size
            )
            XCTAssertTrue(
                rows.allSatisfy { abs($0.height - m.diameter) < 0.001 },
                "\(size) 简版行高退化成环径"
            )
            XCTAssertTrue(
                rows.allSatisfy { abs($0.width - dock.width) < 0.001 },
                "\(size) 竖排行在另一轴上铺满窗口厚度"
            )
        }
    }

    func testCompactRingIsReadableAtItsSize() {
        // 每一档的线宽都要同时满足两条：细到极限时在浅色玻璃上会消失（≥1.5），
        // 粗到极限时环心被吃光（×2 < 环径）。这两条是档位表的取值边界。
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            XCTAssertGreaterThanOrEqual(
                m.ringLineWidth, 1.5, "\(size) 环线过细在浅色壁纸上会消失"
            )
            XCTAssertLessThan(
                m.ringLineWidth * 2, m.diameter, "\(size) 环线过粗会吃掉整个环心"
            )
        }
    }

    /// 档位表的可用性下限：逐行 hover 的判定半径是**半个行距**
    /// （见 `EdgeDockController.circleIndex` 的 `minimumRadius`）。它必须够手指指，
    /// 否则"简版逐行 hover 出对应 provider 的详情"这个能力在某一档上直接失能，
    /// 而症状是"有时候点得中有时候点不中"。
    func testCompactHitRadiusStaysAboveUsabilityFloor() {
        for size in EdgeDockCompactSize.allCases {
            let step = EdgeDockGeometry.compactRowStep(for: size)
            XCTAssertGreaterThanOrEqual(
                step / 2, 7.5,
                "\(size) 半个行距 \(step / 2)pt 低于 7.5pt 的可用性下限，逐行 hover 会难按"
            )
        }
    }

    /// 三档必须**真的**是三档：环径与行距都不同。写成三档而取值相同的话，
    /// 整个功能等于只有一个尺寸换了三次名字。
    func testCompactTiersAreActuallyDistinct() {
        let diameters = EdgeDockCompactSize.allCases.map {
            EdgeDockGeometry.compactMetrics(for: $0).diameter
        }
        XCTAssertEqual(Set(diameters).count, EdgeDockCompactSize.allCases.count, "环径必须逐档不同")
        let steps = EdgeDockCompactSize.allCases.map { EdgeDockGeometry.compactRowStep(for: $0) }
        XCTAssertEqual(Set(steps).count, EdgeDockCompactSize.allCases.count, "行距必须逐档不同")
        // 档位从小到大必须真的变大：picker 里的顺序与屏幕上的大小必须同向。
        for (a, b) in zip(diameters, diameters.dropFirst()) {
            XCTAssertLessThan(a, b, "档位顺序必须与尺寸顺序同向")
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

    // MARK: - 常驻数值标签宽度护栏

    /// 圆环下方常驻数值文字（如 "91.9%", "100%"）在最长形态下的自然测量宽度
    /// 必须 ≤ 行宽/圆环直径（`EdgeDockGeometry.diameter` = 38pt），
    /// 保证一位小数改版后常驻数字不撑破 dock 标签。
    @MainActor
    func testDockQuotaLabelWidthFitsWithinRowDiameter() {
        let longestForms = ["100%", "99.9%", "91.9%", "0%"]
        for text in longestForms {
            let label = Text(text)
                .font(.system(size: EdgeDockGeometry.labelFontSize, weight: .medium, design: .rounded))
                .monospacedDigit()
            let hosting = NSHostingView(rootView: label)
            hosting.layoutSubtreeIfNeeded()
            let width = hosting.fittingSize.width
            XCTAssertLessThanOrEqual(
                width,
                EdgeDockGeometry.diameter,
                "额度百分比标签 \"\(text)\" 测量宽度（\(width)pt）不能超过 dock 圆环直径（\(EdgeDockGeometry.diameter)pt）"
            )
        }
    }
}
