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
}
