import Foundation
import UserNotifications

/// 单个模型在一次远程刷新中恢复的额度窗口。
struct QuotaIncrease: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let previousPercent: Double
        let currentPercent: Double
    }

    let modelName: String
    let displayName: String
    let interval: Window?
    let weekly: Window?
}

/// 比较两次成功的远程额度快照。只有两边都存在的窗口才参与比较，避免首次出现
/// model/window 时把“没有基线”误判成恢复。
enum QuotaIncreaseDetector {
    /// 百分比来自不同服务的浮点响应；忽略小于 0.01 个百分点的数值噪声。
    private static let minimumIncrease = 0.01

    nonisolated static func detect(current: QuotaInfo, previous: QuotaInfo?) -> [QuotaIncrease] {
        guard let previous else { return [] }

        let previousByName = Dictionary(
            previous.models.map { ($0.modelName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return current.models.compactMap { model in
            guard let old = previousByName[model.modelName.lowercased()] else { return nil }

            let interval = increase(
                previousPercent: old.intervalRemainingPercent,
                currentPercent: model.intervalRemainingPercent,
                previousPresent: old.hasIntervalWindow,
                currentPresent: model.hasIntervalWindow
            )
            let weekly = increase(
                previousPercent: old.weeklyRemainingPercent,
                currentPercent: model.weeklyRemainingPercent,
                previousPresent: old.hasWeeklyWindow,
                currentPresent: model.hasWeeklyWindow
            )
            guard interval != nil || weekly != nil else { return nil }

            return QuotaIncrease(
                modelName: model.modelName,
                displayName: model.displayName,
                interval: interval,
                weekly: weekly
            )
        }
    }

    private nonisolated static func increase(
        previousPercent: Double,
        currentPercent: Double,
        previousPresent: Bool,
        currentPresent: Bool
    ) -> QuotaIncrease.Window? {
        guard previousPresent,
              currentPresent,
              previousPercent.isFinite,
              currentPercent.isFinite,
              currentPercent - previousPercent >= minimumIncrease else {
            return nil
        }
        return QuotaIncrease.Window(
            previousPercent: previousPercent,
            currentPercent: currentPercent
        )
    }
}

protocol QuotaUpdateNotifying: AnyObject {
    func notify(providerID: String, providerName: String, increases: [QuotaIncrease])
}

/// 测试和不需要系统通知的调用方使用；产品入口显式注入 SystemQuotaUpdateNotifier。
final class NoopQuotaUpdateNotifier: QuotaUpdateNotifying {
    func notify(providerID: String, providerName: String, increases: [QuotaIncrease]) {}
}

/// macOS 本地通知。应用启动时检查授权状态；如果启动检查尚未完成，额度恢复路径
/// 仍会自行申请权限并在授权后继续发送当次通知。
final class SystemQuotaUpdateNotifier: NSObject, QuotaUpdateNotifying,
                                       UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// `LLMMonitorApp.init()` 发生在 NSApplication 完成启动之前。此时直接调用
    /// `UNUserNotificationCenter.current()` 会在部分 macOS 版本中触发运行时异常。
    /// 延迟到 applicationDidFinishLaunching 的权限检查（或更晚的通知发送）再创建。
    private lazy var center: UNUserNotificationCenter? = {
        // `swift run` 产生的是裸可执行文件，没有 Bundle Identifier；
        // UserNotifications 在这种进程中不可用，调用 current() 可能直接异常退出。
        guard Bundle.main.bundleIdentifier != nil else {
            logWarn("[quota-notification] 当前进程不是有效的 .app bundle，禁用系统通知")
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    override init() {
        super.init()
    }

    /// 启动完成后调用。仅 `.notDetermined` 会触发系统授权框；已授权或已拒绝时
    /// 只记录当前状态，不会重复打扰用户。
    func checkAuthorizationAtLaunch() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        logWarn("[quota-notification] 启动时请求通知权限失败: \(error.localizedDescription)")
                    } else {
                        logInfo("[quota-notification] 启动权限检查完成: \(granted ? "已授权" : "未授权")")
                    }
                }
            case .authorized, .provisional, .ephemeral:
                logDebug("[quota-notification] 启动权限检查: 已授权")
            case .denied:
                logDebug("[quota-notification] 启动权限检查: 用户已拒绝")
            @unknown default:
                logWarn("[quota-notification] 启动权限检查遇到未知授权状态")
            }
        }
    }

    func notify(providerID: String, providerName: String, increases: [QuotaIncrease]) {
        guard !increases.isEmpty, let center else { return }

        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.enqueue(providerID: providerID, providerName: providerName, increases: increases)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    if let error {
                        logWarn("[quota-notification] 请求通知权限失败: \(error.localizedDescription)")
                    }
                    guard granted, let self else { return }
                    self.enqueue(providerID: providerID, providerName: providerName, increases: increases)
                }
            case .denied:
                logDebug("[quota-notification] 系统通知权限未开启，跳过 \(providerID) 额度更新通知")
            case .ephemeral:
                self.enqueue(providerID: providerID, providerName: providerName, increases: increases)
            @unknown default:
                logWarn("[quota-notification] 未知通知授权状态，跳过 \(providerID) 额度更新通知")
            }
        }
    }

    private func enqueue(providerID: String, providerName: String, increases: [QuotaIncrease]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(providerName) 额度已更新"
        content.body = increases.map(Self.messageLine).joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "quota-update-\(providerID)"

        let request = UNNotificationRequest(
            identifier: "quota-update-\(providerID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logWarn("[quota-notification] 发送 \(providerID) 通知失败: \(error.localizedDescription)")
            } else {
                logInfo("[quota-notification] 已发送 \(providerID) 额度更新通知（\(increases.count) 个模型）")
            }
        }
    }

    private static func messageLine(_ increase: QuotaIncrease) -> String {
        var changes: [String] = []
        if let interval = increase.interval {
            changes.append("短周期 \(percent(interval.previousPercent)) → \(percent(interval.currentPercent))")
        }
        if let weekly = increase.weekly {
            changes.append("周额度 \(percent(weekly.previousPercent)) → \(percent(weekly.currentPercent))")
        }
        return "\(increase.displayName)：\(changes.joined(separator: "，"))"
    }

    private static func percent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", value)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 菜单窗口当前处于前台时也显示恢复提示。
        completionHandler([.banner, .sound])
    }
}
