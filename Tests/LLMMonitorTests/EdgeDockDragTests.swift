import AppKit
import XCTest
@testable import LLM_monitor

final class EdgeDockDragGeometryTests: EdgeDockTestCase {
    func testNearestEdgeUsesFiniteSegmentDistancesOutsideTheFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // x 仍在屏内，y 超过顶边：到上边线段 40pt，到右边线段约 64pt。
        XCTAssertEqual(
            EdgeDockGeometry.nearestEdge(to: CGPoint(x: 950, y: 840), in: frame),
            .top
        )
    }

    func testCurrentEdgeWinsOutsideCornerTieAndSwitchMarginStillApplies() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // 右上角外侧，两条有限边线段到同一个角点，距离相等；当前边保持。
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(
                mouse: CGPoint(x: 1100, y: 900), currentEdge: .top, visibleFrame: frame
            ),
            .top
        )
        // top 比 right 只近 24pt，小于 40pt 阈值，继续保持当前边。
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(
                mouse: CGPoint(x: 950, y: 840), currentEdge: .right, visibleFrame: frame
            ),
            .right
        )
        // top 比 right 明显更近，优势超过 40pt 时换边。
        XCTAssertEqual(
            EdgeDockGeometry.edgeAfterDrag(
                mouse: CGPoint(x: 800, y: 840), currentEdge: .right, visibleFrame: frame
            ),
            .top
        )
    }

    func testGrabFractionKeepsPointerAtSameRelativePositionWhenWindowSizeChanges() {
        let original = CGRect(x: 0, y: 0, width: 46, height: 240)
        let pointer = CGPoint(x: original.midX, y: original.maxY - original.height * 0.2)
        let fraction = EdgeDockGeometry.grabFraction(forMouse: pointer, in: original, edge: .right)
        XCTAssertEqual(fraction, 0.2, accuracy: 0.0001)

        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let newSize = CGSize(width: 46, height: 300)
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 1150, y: 500),
            dockSize: newSize,
            visibleFrame: visibleFrame,
            edge: .right,
            grabFraction: fraction
        )
        let placed = EdgeDockGeometry.frame(
            visibleFrame: visibleFrame, edge: .right, size: newSize, offset: offset
        )
        XCTAssertEqual(placed.maxY - placed.height * fraction, 500, accuracy: 0.001)
    }

    func testFirstFourPointDragKeepsGrabbedPointAttachedToDock() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let initial = EdgeDockGeometry.frame(
            visibleFrame: visibleFrame, edge: .right, size: size, offset: 0.5
        )
        let fraction = 0.8
        let start = CGPoint(x: initial.midX, y: initial.maxY - initial.height * fraction)
        let release = CGPoint(x: start.x, y: start.y + 4)
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: release,
            dockSize: size,
            visibleFrame: visibleFrame,
            edge: .right,
            grabFraction: fraction
        )
        let moved = EdgeDockGeometry.frame(
            visibleFrame: visibleFrame, edge: .right, size: size, offset: offset
        )
        XCTAssertEqual(moved.maxY - moved.height * fraction, release.y, accuracy: 0.001)
        XCTAssertEqual(moved.minX, initial.minX, accuracy: 0.001)
    }

    func testFirstProviderGrabbedOnVerticalEdgeStaysAtLeftOfHorizontalEdge() {
        let vertical = CGRect(x: 0, y: 0, width: 46, height: 240)
        let firstProviderPoint = CGPoint(x: vertical.midX, y: vertical.maxY - 12)
        let fraction = EdgeDockGeometry.grabFraction(
            forMouse: firstProviderPoint, in: vertical, edge: .right
        )
        XCTAssertEqual(fraction, 0.05, accuracy: 0.0001)

        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let horizontalSize = CGSize(width: 300, height: 54)
        let offset = EdgeDockGeometry.offsetAlongEdge(
            forMouse: CGPoint(x: 500, y: 100),
            dockSize: horizontalSize,
            visibleFrame: visibleFrame,
            edge: .bottom,
            grabFraction: fraction
        )
        let placed = EdgeDockGeometry.frame(
            visibleFrame: visibleFrame, edge: .bottom, size: horizontalSize, offset: offset
        )
        XCTAssertEqual(placed.minX + placed.width * fraction, 500, accuracy: 0.001)
    }
}

final class EdgeDockDragReleaseTests: StateTestCase {
    @MainActor
    func testMouseUpWithoutFinalDraggedEventUsesReleaseCoordinate() throws {
        guard let screen = NSScreen.screens.first,
              let displayID = EdgeDockDisplay.displayID(of: screen),
              let uuid = EdgeDockDisplay.uuid(of: screen)
        else {
            throw XCTSkip("A connected display with a stable display UUID is required")
        }
        let controller = EdgeDockController.shared
        let store = makeIsolatedConfigStore()
        let size = EdgeDockGeometry.dockSize(
            entryCount: 1, edge: .right, appearance: .compact, compactSize: .default
        )
        let visibleFrame = ScreenChromeProbe.effectiveVisibleFrame(on: screen, isFullscreenSpace: false)
        let initial = EdgeDockGeometry.frame(
            visibleFrame: visibleFrame, edge: .right, size: size, offset: 0.5
        )
        let panel = NSPanel(contentRect: initial, styleMask: [.borderless], backing: .buffered, defer: true)

        let previous = (
            config: controller.config,
            store: controller.configStore,
            panel: controller.panel,
            isDragging: controller.isDragging,
            pressLocation: controller.pressScreenLocation,
            becameDrag: controller.pressBecameDrag,
            grabFraction: controller.dragGrabFraction,
            lastMouse: controller.lastDragMouseLocation,
            dragOffset: controller.dragOffset,
            entryCount: controller.dragEntryCount,
            frames: controller.dragFrameByDisplayID
        )
        defer {
            controller.applyRuntimeConfig { $0 = previous.config }
            controller.configStore = previous.store
            controller.panel = previous.panel
            controller.isDragging = previous.isDragging
            controller.pressScreenLocation = previous.pressLocation
            controller.pressBecameDrag = previous.becameDrag
            controller.dragGrabFraction = previous.grabFraction
            controller.lastDragMouseLocation = previous.lastMouse
            controller.dragOffset = previous.dragOffset
            controller.dragEntryCount = previous.entryCount
            controller.dragFrameByDisplayID = previous.frames
        }

        controller.configStore = store
        controller.applyRuntimeConfig {
            $0.mode = .hidden
            $0.edge = .right
            $0.offset = 0.5
            $0.screenUUID = uuid
            $0.compactSize = .default
        }
        controller.panel = panel
        controller.dragEntryCount = 1
        controller.dragFrameByDisplayID = [displayID: visibleFrame]
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let release = CGPoint(x: start.x, y: start.y + 80)
        controller.isDragging = true
        controller.pressScreenLocation = start
        controller.pressBecameDrag = false
        controller.dragGrabFraction = EdgeDockGeometry.grabFraction(
            forMouse: start, in: panel.frame, edge: .right
        )
        controller.lastDragMouseLocation = nil
        controller.dragOffset = nil

        controller.finishPressOrDrag(at: release)

        let expected = EdgeDockGeometry.offsetAlongEdge(
            forMouse: release,
            dockSize: size,
            visibleFrame: visibleFrame,
            edge: .right,
            grabFraction: 0.5
        )
        XCTAssertTrue(controller.pressBecameDrag, "Mouse-up beyond threshold must be recognized as a drag")
        XCTAssertEqual(controller.config.offset, expected, accuracy: 0.0001)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)
    }
}
