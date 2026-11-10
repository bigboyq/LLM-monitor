import AppKit
import XCTest
@testable import LLM_monitor

@MainActor
final class EdgeDockSelectionTests: StateTestCase {
    private func entry(_ id: String) -> EdgeDockEntry {
        EdgeDockEntry(
            id: id, displayName: id, kind: .codexChatGpt, balanceAvailable: nil,
            intervalFraction: nil, rawIntervalFraction: nil, weeklyFraction: nil,
            health: nil, intervalHealth: nil, weeklyHealth: nil
        )
    }

    private func withController(_ body: (EdgeDockController) -> Void) {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()
        let controller = EdgeDockController.shared
        controller.teardown()
        defer { controller.teardown(); state.stop() }
        controller.state = state
        controller.hasFinishedLaunching = true
        controller.applyRuntimeConfig { $0.mode = .statusWindow; $0.screenUUID = nil }
        // 不显示任何真实窗口；拖拽门禁只跳过 frame/show，保留 reconcile 的身份处理。
        controller.panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        controller.isDragging = true
        controller.cachedOrderedEntries = [entry("A"), entry("B"), entry("C")]
        controller.selectedIndex = 1
        body(controller)
    }

    func testSelectionFollowsStableProviderThroughReorderAndEarlierRemoval() {
        withController { controller in
            XCTAssertEqual(controller.selectedProviderID, "B")
            controller.cachedOrderedEntries = [entry("C"), entry("A"), entry("B")]
            controller.reconcile(animated: false)
            XCTAssertEqual(controller.selectedProviderID, "B")
            XCTAssertEqual(controller.selectedIndex, 2)
            controller.cachedOrderedEntries = [entry("B"), entry("C")]
            controller.reconcile(animated: false)
            XCTAssertEqual(controller.selectedProviderID, "B")
            XCTAssertEqual(controller.selectedIndex, 0)
        }
    }

    func testRemovingSelectedProviderClosesPopoverEvenWhenOldIndexIsValid() {
        withController { controller in
            _ = controller.ensurePopoverPanel()
            controller.cachedOrderedEntries = [entry("A"), entry("C")]
            controller.reconcile(animated: false)
            XCTAssertNil(controller.selectedProviderID)
            XCTAssertNil(controller.selectedIndex)
            XCTAssertNil(controller.popoverPanel)
        }
    }

    func testReleaseHideDragAndTeardownClearProviderIdentity() {
        withController { controller in
            controller.releaseMouseCapture()
            XCTAssertNil(controller.selectedProviderID)
            controller.selectedIndex = 1
            controller.applyRuntimeConfig { $0.mode = .hidden }
            controller.reconcile(animated: false)
            XCTAssertNil(controller.selectedProviderID)
            controller.applyRuntimeConfig { $0.mode = .statusWindow }
            controller.selectedIndex = 1
            controller.isDragging = true
            controller.pressScreenLocation = .zero
            controller.dragEntryCount = 3
            controller.dragMoved(at: CGPoint(x: 8, y: 0))
            XCTAssertNil(controller.selectedProviderID)
            controller.selectedIndex = 1
            controller.teardown()
            XCTAssertNil(controller.selectedProviderID)
        }
    }
}
