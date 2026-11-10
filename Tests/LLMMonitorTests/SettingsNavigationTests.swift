import Combine
import XCTest
@testable import LLM_monitor

@MainActor
final class SettingsNavigationTests: StateTestCase {
    func testMountedSettingsConsumesPublishedDestinationsAndClearsRequests() async {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()
        defer { state.stop() }
        var destinations: [String] = []
        var currentTab = SettingsTab.general
        let received = expectation(description: "消费已打开设置窗的三个跳转请求")
        received.expectedFulfillmentCount = 3

        // 与 SettingsView 的窗口订阅及实际消费出口相同；验证目的地与请求清理，
        // 而不是把 @Published 的 willSet 时序当成需要修复的行为。
        let subscription = state.$pendingSettingsTab
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { pending in
                SettingsView.consumeSettingsTabRequest(pending, state: state) { tab in
                    currentTab = tab
                    destinations.append(tab.id)
                    received.fulfill()
                }
            }

        state.pendingSettingsTab = .energy
        state.pendingSettingsTab = .notifications
        state.pendingSettingsTab = .sync
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(destinations, [SettingsTab.energy.id, SettingsTab.notifications.id, SettingsTab.sync.id])
        XCTAssertEqual(currentTab.id, SettingsTab.sync.id)
        XCTAssertNil(state.pendingSettingsTab, "消费后不能被 publisher 外层赋值重新留下旧请求")
        withExtendedLifetime(subscription) {}
    }

    func testSettingsFirstAppearanceConsumesRequestMadeBeforeSubscription() {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()
        defer { state.stop() }
        state.pendingSettingsTab = .energy
        var currentTab = SettingsTab.general
        SettingsView.consumeSettingsTabRequest(state.pendingSettingsTab, state: state) {
            currentTab = $0
        }
        XCTAssertEqual(currentTab.id, SettingsTab.energy.id)
        XCTAssertNil(state.pendingSettingsTab)
        SettingsView.consumeSettingsTabRequest(nil, state: state) { _ in
            XCTFail("清空广播不能重复导航")
        }
    }
}
