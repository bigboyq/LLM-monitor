import XCTest
@testable import LLM_monitor

/// 设置页保存事务（`SettingsSaveTransaction`）的执行顺序约定：登录项更新即使
/// 需要用户授权，也必须继续落盘配置。对应 `SettingsSaveTransaction`。
final class SettingsSaveTransactionTests: XCTestCase {

    // MARK: - SettingsSaveTransaction

    func testSettingsSaveTransactionAllowsPendingLoginItemApproval() async throws {
        var didSave = false

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: false,
            requestedLaunchAtLogin: true,
            updateLoginItem: { _ in
                LoginItemUpdateOutcome(
                    isEnabled: false,
                    errorMessage: nil,
                    requiresApproval: true
                )
            },
            saveConfig: {
                didSave = true
            }
        )

        XCTAssertTrue(didSave)
    }

    @MainActor
    func testMenuToggleIsNotUndoneWhenSettingsSavesOtherConfigWithStaleCleanDraft() async throws {
        let draft = SettingsLoginItemDraft(baseline: false, draft: false)
        let actualAfterMenuToggle = true
        var updateCalls = 0
        var didSaveConfig = false

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: actualAfterMenuToggle,
            requestedLaunchAtLogin: draft.requestedValue(actual: actualAfterMenuToggle),
            updateLoginItem: { requested in
                updateCalls += 1
                return LoginItemUpdateOutcome(
                    isEnabled: requested,
                    errorMessage: nil,
                    requiresApproval: false
                )
            },
            saveConfig: { didSaveConfig = true }
        )

        XCTAssertTrue(didSaveConfig)
        XCTAssertEqual(updateCalls, 0, "saving another field must not reverse a menu toggle")
    }

    @MainActor
    func testLocalDraftChangeIsAppliedAndRebasedToActualState() async throws {
        var actual = false
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)
        let requested = draft.requestedValue(actual: actual)

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: actual,
            requestedLaunchAtLogin: requested,
            updateLoginItem: { enabled in
                actual = enabled
                return LoginItemUpdateOutcome(
                    isEnabled: actual,
                    errorMessage: nil,
                    requiresApproval: false
                )
            },
            saveConfig: {}
        )
        draft.syncToActual(actual: actual)

        XCTAssertTrue(actual)
        XCTAssertTrue(draft.baseline)
        XCTAssertTrue(draft.draft)
    }

    @MainActor
    func testRegistrationFailureRebasesDisplayToActualDisabledState() async throws {
        let actual = false
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)
        var didSaveConfig = false

        do {
            try await SettingsSaveTransaction.execute(
                previousLaunchAtLogin: actual,
                requestedLaunchAtLogin: draft.requestedValue(actual: actual),
                updateLoginItem: { _ in
                    LoginItemUpdateOutcome(
                        isEnabled: actual,
                        errorMessage: "registration denied",
                        requiresApproval: false
                    )
                },
                saveConfig: { didSaveConfig = true }
            )
            XCTFail("registration failure should reject the save")
        } catch let error as SettingsSaveTransactionError {
            guard case .loginItemUpdateFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        draft.syncToActual(actual: actual)

        XCTAssertFalse(didSaveConfig)
        XCTAssertFalse(draft.baseline)
        XCTAssertFalse(draft.draft)
    }

    @MainActor
    func testConfigWriteFailureRollsBackLoginItemAndResetsDisplay() async throws {
        var actual = false
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)
        var requestedTransitions: [Bool] = []

        do {
            try await SettingsSaveTransaction.execute(
                previousLaunchAtLogin: actual,
                requestedLaunchAtLogin: draft.requestedValue(actual: actual),
                updateLoginItem: { requested in
                    requestedTransitions.append(requested)
                    actual = requested
                    return LoginItemUpdateOutcome(
                        isEnabled: actual,
                        errorMessage: nil,
                        requiresApproval: false
                    )
                },
                saveConfig: {
                    throw NSError(
                        domain: "ConfigWriteFailure",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "disk is read-only"]
                    )
                }
            )
            XCTFail("config write failure should fail the transaction")
        } catch let error as SettingsSaveTransactionError {
            guard case .configSaveFailedAndLoginItemRolledBack = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        draft.syncToActual(actual: actual)

        XCTAssertEqual(requestedTransitions, [true, false])
        XCTAssertFalse(actual)
        XCTAssertFalse(draft.baseline)
        XCTAssertFalse(draft.draft)
    }

    @MainActor
    func testPendingApprovalSavesConfigWithoutShowingLoginItemAsEnabled() async throws {
        let actual = false
        var draft = SettingsLoginItemDraft(baseline: false, draft: true)
        var didSaveConfig = false

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: actual,
            requestedLaunchAtLogin: draft.requestedValue(actual: actual),
            updateLoginItem: { _ in
                LoginItemUpdateOutcome(
                    isEnabled: false,
                    errorMessage: nil,
                    requiresApproval: true
                )
            },
            saveConfig: { didSaveConfig = true }
        )
        draft.syncToActual(actual: actual)

        XCTAssertTrue(didSaveConfig, "approval pending still permits config save")
        XCTAssertFalse(draft.baseline)
        XCTAssertFalse(draft.draft, "requiresApproval is not a confirmed enabled state")
    }
}
