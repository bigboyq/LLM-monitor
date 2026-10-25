import XCTest
@testable import LLM_monitor

/// The settings toggle is a draft of ServiceManagement's actual state. These tests
/// exercise the value model directly; they do not register a real login item or
/// rely on an unmounted SwiftUI @State setter.
final class SettingsLoginItemDraftTests: XCTestCase {

    func testMenuChangesInEitherDirectionSynchronizeOpenSettingsDraft() {
        var draft = SettingsLoginItemDraft(baseline: false, draft: false)

        draft.sync(actual: true)
        XCTAssertTrue(draft.baseline)
        XCTAssertTrue(draft.draft)

        draft.sync(actual: false)
        XCTAssertFalse(draft.baseline)
        XCTAssertFalse(draft.draft)
    }

    func testRepeatedActualStatusPreservesUnsavedLocalEdit() {
        var draft = SettingsLoginItemDraft(baseline: false, draft: false)
        draft.draft = true

        draft.sync(actual: false)
        draft.sync(actual: false)

        XCTAssertFalse(draft.baseline)
        XCTAssertTrue(draft.draft)
        XCTAssertTrue(draft.requestedValue(actual: false))
    }

    func testMenuStateWinsOverStaleUnmodifiedDraftBeforePublisherArrives() {
        let draft = SettingsLoginItemDraft(baseline: false, draft: false)

        XCTAssertTrue(
            draft.requestedValue(actual: true),
            "保存时应以当前Service状态为准，不能用未dirty的旧draft反向覆盖菜单操作"
        )
    }

    func testChangedActualStatusRebasesDraftEvenWhenItHadLocalEdit() {
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)

        draft.sync(actual: true)

        XCTAssertTrue(draft.baseline)
        XCTAssertTrue(draft.draft)
        XCTAssertTrue(draft.requestedValue(actual: true))
    }

    func testSyncToActualResetsBothDraftAndBaselineAfterTransaction() {
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)

        draft.syncToActual(actual: false)

        XCTAssertFalse(draft.baseline)
        XCTAssertFalse(draft.draft)
    }
}
