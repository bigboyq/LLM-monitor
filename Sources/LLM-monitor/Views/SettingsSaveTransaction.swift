import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum SettingsSaveTransactionError: LocalizedError, Equatable {
    case loginItemUpdateFailed(String)
    case configSaveFailed(String)
    case configSaveFailedAndLoginItemRolledBack(String)
    case configSaveFailedAndLoginItemRollbackFailed(
        configError: String,
        rollbackError: String
    )

    var errorDescription: String? {
        switch self {
        case .loginItemUpdateFailed(let message):
            return "配置尚未应用；无法更新开机自启动设置：\(message)"
        case .configSaveFailed(let message):
            return "配置保存失败；开机自启动设置未变更：\(message)"
        case .configSaveFailedAndLoginItemRolledBack(let message):
            return "配置保存失败，开机自启动设置已恢复：\(message)"
        case .configSaveFailedAndLoginItemRollbackFailed(
            let configError,
            let rollbackError
        ):
            return """
            配置保存失败（\(configError)），且无法恢复开机自启动设置（\(rollbackError)）。\
            请检查系统设置中的登录项状态。
            """
        }
    }
}

struct LoginItemUpdateOutcome: Equatable {
    let isEnabled: Bool
    let errorMessage: String?
    /// 注册已被系统接受，但仍需用户在系统设置中批准。
    let requiresApproval: Bool
}

/// 设置保存的事务边界：登录项先变更，配置随后落盘；配置失败时回滚登录项。
///
/// 依赖通过 closure 注入，视图只负责构造 AppConfig 草稿和展示最终错误。
@MainActor
enum SettingsSaveTransaction {
    static func execute(
        previousLaunchAtLogin: Bool,
        requestedLaunchAtLogin: Bool,
        updateLoginItem: (Bool) async -> LoginItemUpdateOutcome,
        saveConfig: () throws -> Void
    ) async throws {
        let shouldUpdateLoginItem = requestedLaunchAtLogin != previousLaunchAtLogin
        if shouldUpdateLoginItem {
            let update = await updateLoginItem(requestedLaunchAtLogin)
            let acceptedPendingApproval = requestedLaunchAtLogin && update.requiresApproval
            guard update.isEnabled == requestedLaunchAtLogin || acceptedPendingApproval else {
                throw SettingsSaveTransactionError.loginItemUpdateFailed(
                    update.errorMessage ?? "系统未接受状态变更"
                )
            }
        }

        do {
            try saveConfig()
        } catch {
            let configError = error.localizedDescription

            guard shouldUpdateLoginItem else {
                throw SettingsSaveTransactionError.configSaveFailed(configError)
            }

            let rollback = await updateLoginItem(previousLaunchAtLogin)
            guard rollback.isEnabled == previousLaunchAtLogin else {
                throw SettingsSaveTransactionError.configSaveFailedAndLoginItemRollbackFailed(
                    configError: configError,
                    rollbackError: rollback.errorMessage ?? "系统未恢复到保存前状态"
                )
            }

            throw SettingsSaveTransactionError.configSaveFailedAndLoginItemRolledBack(configError)
        }
    }
}
