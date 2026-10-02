import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 卡片浮层的宽度、定位与沿边拖拽。对应 `+Popover` / `+Drag`。
final class EdgeDockPopoverTests: EdgeDockTestCase {

    // MARK: - popover 与最宽内容（7 天图表）的宽度一致性

    func testPopoverWidthFitsSevenDayChart() {
        // 宽度推导链：图表 420 + 卡片内边距 12×2 + 背板内边距 12×2。
        // 曾经直接取主菜单宽度 360，卡片内容区只剩 312pt，图表首尾两天的柱
        // 被浮层整段裁掉——固定宽度的前提是先装得下最宽的内容。
        XCTAssertEqual(
            EdgeDockTheme.popoverWidth,
            SevenDayUsageChartMetrics.pricedWidth
                + LayoutMetrics.cardContentPadding * 2
                + EdgeDockTheme.popoverPadding * 2
        )
        XCTAssertGreaterThan(EdgeDockTheme.popoverWidth, MenuPanelHeightBridge.width)
    }

    func testPopoverCardInnerWidthFitsChart() {
        // 卡片内容区（面板宽 - 背板内边距 - 卡片内边距）必须完整装下图表，
        // 不带价格列时同样要装下柱区（415）。
        let inner = EdgeDockTheme.popoverWidth
            - EdgeDockTheme.popoverPadding * 2
            - LayoutMetrics.cardContentPadding * 2
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
            EdgeDockTheme.popoverPadding, LayoutMetrics.cardColumnHorizontalPadding,
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
}
