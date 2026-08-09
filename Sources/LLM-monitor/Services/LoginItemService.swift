import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastErrorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refreshStatus()
    }

    var isEnabled: Bool {
        state == .enabled
    }

    var statusText: String {
        switch state {
        case .enabled:
            return "已开启开机自启动"
        case .disabled:
            return isRecommendedInstallLocation ? "可开启开机自启动" : "建议放到 Applications 后再开启"
        case .requiresApproval:
            return "需要在系统设置中批准登录项"
        case .unavailable:
            return "当前环境暂不支持开机自启动"
        }
    }

    var isRecommendedInstallLocation: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            state = .enabled
        case .notRegistered:
            state = .disabled
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async {
        lastErrorMessage = nil

        do {
            if enabled {
                try await Self.registerOnUtilityQueue()
                logInfo("[login-item] register succeeded")
            } else {
                try await service.unregister()
                logInfo("[login-item] unregister succeeded")
            }
            refreshStatus()
        } catch {
            refreshStatus()
            let nsError = error as NSError
            let detail = friendlyMessage(for: nsError, enabling: enabled)
            lastErrorMessage = detail
            logError("[login-item] \(enabled ? "register" : "unregister") failed: \(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)")
        }
    }

    /// ServiceManagement 只提供同步 register API；把这次可能触发系统服务写入的
    /// 调用移到 utility queue，避免设置窗口被同步系统调用阻塞。
    private nonisolated static func registerOnUtilityQueue() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try SMAppService.mainApp.register()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func friendlyMessage(for error: NSError, enabling: Bool) -> String {
        if error.localizedDescription.contains("Operation not permitted") {
            return enabling ? "系统拒绝了登录项注册，请检查系统设置中的登录项权限" : "系统拒绝了登录项移除请求"
        }

        if !isRecommendedInstallLocation && enabling {
            return "建议先把 app 放到 /Applications，再开启开机自启动"
        }

        switch state {
        case .requiresApproval:
            return "已提交登录项请求，请到系统设置 > 通用 > 登录项里批准"
        case .unavailable:
            return "当前 app 包无法注册登录项；通常需要从打包后的 .app 中运行"
        case .enabled, .disabled:
            return error.localizedDescription
        }
    }
}
