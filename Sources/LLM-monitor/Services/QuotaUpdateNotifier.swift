import Foundation
@preconcurrency import UserNotifications

/// 通知渠道。`barkAndSystem` 表示 Bark 推送和系统通知同时发送。
enum QuotaNotifyChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case system
    case barkAndSystem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不通知"
        case .system: return "系统通知"
        case .barkAndSystem: return "Bark + 系统通知"
        }
    }

    var sendsSystemNotification: Bool {
        self == .system || self == .barkAndSystem
    }

    var sendsBarkPush: Bool {
        self == .barkAndSystem
    }
}

/// 四类通知事件：5 小时 / 周额度窗口的恢复与耗尽。
enum QuotaNotificationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case intervalRestored
    case intervalExhausted
    case weeklyRestored
    case weeklyExhausted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .intervalRestored: return "5 小时额度已恢复"
        case .intervalExhausted: return "5 小时额度已耗尽"
        case .weeklyRestored: return "周额度已恢复"
        case .weeklyExhausted: return "周额度已耗尽"
        }
    }
}

/// 一次刷新中单个模型的单个窗口发生变化的事件。
struct QuotaEvent: Equatable, Sendable {
    let modelName: String
    let displayName: String
    let kind: QuotaNotificationKind
    let previousPercent: Double
    let currentPercent: Double
}

/// 每个 provider 的四类事件 → 渠道映射。nil 字段使用默认渠道。
struct QuotaNotifyChannels: Equatable, Sendable {
    var intervalRestored: QuotaNotifyChannel?
    var intervalExhausted: QuotaNotifyChannel?
    var weeklyRestored: QuotaNotifyChannel?
    var weeklyExhausted: QuotaNotifyChannel?

    func channel(for kind: QuotaNotificationKind) -> QuotaNotifyChannel {
        switch kind {
        case .intervalRestored: return intervalRestored ?? .system
        case .intervalExhausted: return intervalExhausted ?? .none
        case .weeklyRestored: return weeklyRestored ?? .system
        case .weeklyExhausted: return weeklyExhausted ?? .none
        }
    }
}

/// 比较两次成功的远程额度快照。只有两边都存在的窗口才参与比较，避免首次出现
/// model/window 时把“没有基线”误判成恢复或耗尽。
/// previous 支持两种来源：内存 `QuotaInfo`（测试便利入口）与持久化
/// `QuotaSnapshot`（AppState 主路径，跨重启连续）。
enum QuotaEventDetector {
    /// 恢复判定（2026-09-13 裁定）：回升超过 5 个百分点，或额度回到 98% 以上
    /// 且确实在回升。`rise > 0` 守门是刻意的：parked 在 100%（闲置 provider）
    /// 不算“回升”，否则每次刷新都会报一次“已恢复”。
    nonisolated private static let restoredHighWatermark = 98.0
    nonisolated private static let restoredMinimumRise = 5.0
    /// 剩余百分比低于该值视为“已耗尽”。
    nonisolated private static let exhaustedThreshold = 0.01

    nonisolated static func detect(current: QuotaInfo, previous: QuotaInfo?) -> [QuotaEvent] {
        guard let previous else { return [] }
        return detect(current: current, previousSnapshot: QuotaSnapshot(from: previous))
    }

    /// AppState 主路径：previous 来自 TriggerStateStore 的持久化基线。
    nonisolated static func detect(current: QuotaInfo, previousSnapshot: QuotaSnapshot?) -> [QuotaEvent] {
        guard let previousSnapshot else { return [] }

        return current.models.flatMap { model -> [QuotaEvent] in
            guard let old = previousSnapshot.models[model.modelName.lowercased()] else { return [] }

            var events: [QuotaEvent] = []
            if let event = windowEvent(
                kind: .intervalRestored,
                exhaustedKind: .intervalExhausted,
                previousPercent: old.intervalRemainingPercent,
                currentPercent: model.intervalRemainingPercent,
                previousPresent: old.intervalPresent,
                currentPresent: model.hasIntervalWindow,
                modelName: model.modelName,
                displayName: model.displayName
            ) {
                events.append(event)
            }
            if let event = windowEvent(
                kind: .weeklyRestored,
                exhaustedKind: .weeklyExhausted,
                previousPercent: old.weeklyRemainingPercent,
                currentPercent: model.weeklyRemainingPercent,
                previousPresent: old.weeklyPresent,
                currentPresent: model.hasWeeklyWindow,
                modelName: model.modelName,
                displayName: model.displayName
            ) {
                events.append(event)
            }
            return events
        }
    }

    /// 恢复：回升 > 5pp，或回到 98% 以上且严格回升；
    /// 耗尽：上次还有余量、本次降到阈值以下。
    private nonisolated static func windowEvent(
        kind: QuotaNotificationKind,
        exhaustedKind: QuotaNotificationKind,
        previousPercent: Double,
        currentPercent: Double,
        previousPresent: Bool,
        currentPresent: Bool,
        modelName: String,
        displayName: String
    ) -> QuotaEvent? {
        guard previousPresent,
              currentPresent,
              previousPercent.isFinite,
              currentPercent.isFinite else {
            return nil
        }

        let rise = currentPercent - previousPercent
        if rise > restoredMinimumRise
            || (currentPercent > restoredHighWatermark && rise > 0) {
            return QuotaEvent(
                modelName: modelName,
                displayName: displayName,
                kind: kind,
                previousPercent: previousPercent,
                currentPercent: currentPercent
            )
        }

        if previousPercent > exhaustedThreshold,
           currentPercent <= exhaustedThreshold {
            return QuotaEvent(
                modelName: modelName,
                displayName: displayName,
                kind: exhaustedKind,
                previousPercent: previousPercent,
                currentPercent: currentPercent
            )
        }

        return nil
    }
}

/// 一次刷新的事件批次：按模型把事件合并成组，并按渠道拆分事件正文。
///
/// 语义：每个渠道只包含该渠道已启用的事件文案 —— 「不通知」的事件不会混进
/// 同模型其它渠道的通知里，保证每类事件的独立配置真正生效。系统通知与
/// Bark 共用本结构，保证两端通知粒度和渠道判定一致。
struct QuotaEventBatch: Equatable, Sendable {
    /// 单个模型的合并结果：一个模型一次刷新在单个渠道至多产生一条通知。
    struct ModelGroup: Equatable, Sendable {
        let modelName: String
        let displayName: String
        /// 渠道配置为「系统通知 / Bark + 系统通知」的事件。
        let systemEvents: [QuotaEvent]
        /// 渠道配置为「Bark + 系统通知」的事件。
        let barkEvents: [QuotaEvent]
        /// Bark 覆盖通知 id：provider + 模型，与本次事件组合无关，同类或
        /// 不同组合的新推送都覆盖手机上该模型的旧推送。
        let barkNotificationID: String

        var sendsSystem: Bool { !systemEvents.isEmpty }
        var sendsBark: Bool { !barkEvents.isEmpty }
        var systemLines: [String] { systemEvents.map(SystemQuotaUpdateNotifier.messageLine) }
        var barkLines: [String] { barkEvents.map(SystemQuotaUpdateNotifier.messageLine) }
    }

    let providerID: String
    let providerName: String
    let modelGroups: [ModelGroup]

    init(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    ) {
        self.providerID = providerID
        self.providerName = providerName

        // 保持 detector 输出顺序；模型名不区分大小写地分组。
        var order: [String] = []
        var byModel: [String: (displayName: String, events: [QuotaEvent])] = [:]
        for event in events {
            let key = event.modelName.lowercased()
            if byModel[key] == nil {
                order.append(key)
                byModel[key] = (event.displayName, [])
            }
            byModel[key]!.events.append(event)
        }

        self.modelGroups = order.map { key in
            let (displayName, modelEvents) = byModel[key]!
            return ModelGroup(
                modelName: key,
                displayName: displayName,
                systemEvents: modelEvents.filter {
                    channels.channel(for: $0.kind).sendsSystemNotification
                },
                barkEvents: modelEvents.filter {
                    channels.channel(for: $0.kind).sendsBarkPush
                },
                barkNotificationID: Self.barkNotificationID(
                    providerID: providerID,
                    modelName: key
                )
            )
        }
    }

    /// 稳定的覆盖 id：`llmmonitor-{providerID}-{model}`。不掺入事件类型，
    /// 事件组合变化（单事件 ↔ 多事件）时 id 保持不变，始终覆盖该模型的
    /// 上一条 Bark 通知，避免历史通知堆积。
    private static func barkNotificationID(
        providerID: String,
        modelName: String
    ) -> String {
        "llmmonitor-\(providerID)-\(modelName)"
    }
}

/// 通知器由 @MainActor 的 AppState 持有与调用，协议整体限定 MainActor，
/// 避免用 @preconcurrency 掩盖隔离不匹配。
@MainActor
protocol QuotaUpdateNotifying: AnyObject {
    /// `channels` 由调用方（AppState）按 provider 配置计算好；通知器只按
    /// 自身渠道（系统 / Bark）过滤后发送。
    func notify(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    )
}

@MainActor
final class CompositeQuotaUpdateNotifier: QuotaUpdateNotifying {
    private let notifiers: [any QuotaUpdateNotifying]

    init(notifiers: [any QuotaUpdateNotifying]) {
        self.notifiers = notifiers
    }

    func notify(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    ) {
        for notifier in notifiers {
            notifier.notify(
                providerID: providerID,
                providerName: providerName,
                events: events,
                channels: channels
            )
        }
    }
}

/// 测试和不需要系统通知的调用方使用；产品入口显式注入 SystemQuotaUpdateNotifier。
@MainActor
final class NoopQuotaUpdateNotifier: QuotaUpdateNotifying {
    func notify(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    ) {}
}

/// macOS 本地通知。应用启动时检查授权状态；如果启动检查尚未完成，额度变化路径
/// 仍会自行申请权限并在授权后继续发送当次通知。
///
/// 协议一致性放在文件尾部的 @MainActor 扩展上：类本体保持非隔离，
/// UNUserNotificationCenterDelegate 回调（后台线程）不受全局 actor 推断影响；
/// 仅 `notify` / `enqueue` 显式 MainActor（由 MainActor 的 AppState 调用）。
final class SystemQuotaUpdateNotifier: NSObject,
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

@MainActor
    func notify(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    ) {
        // 模型级合并：同一模型的事件合成一条系统通知，正文只含系统渠道事件。
        var lastNotified = lastNotifiedAt
        let systemGroups = Self.groupsAfterCooldown(
            QuotaEventBatch(
                providerID: providerID,
                providerName: providerName,
                events: events,
                channels: channels
            ).modelGroups.filter(\.sendsSystem),
            providerID: providerID,
            now: Date(),
            lastNotifiedAt: &lastNotified
        )
        guard !systemGroups.isEmpty else { return }
        lastNotifiedAt = lastNotified
        guard let center else { return }

        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Task { @MainActor [weak self] in
                    self?.enqueue(providerID: providerID, providerName: providerName, groups: systemGroups)
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    if let error {
                        logWarn("[quota-notification] 请求通知权限失败: \(error.localizedDescription)")
                    }
                    guard granted else { return }
                    Task { @MainActor [weak self] in
                        self?.enqueue(providerID: providerID, providerName: providerName, groups: systemGroups)
                    }
                }
            case .denied:
                logDebug("[quota-notification] 系统通知权限未开启，跳过 \(providerID) 额度更新通知")
            case .ephemeral:
                Task { @MainActor [weak self] in
                    self?.enqueue(providerID: providerID, providerName: providerName, groups: systemGroups)
                }
            @unknown default:
                logWarn("[quota-notification] 未知通知授权状态，跳过 \(providerID) 额度更新通知")
            }
        }
    }

    @MainActor
    private func enqueue(providerID: String, providerName: String, groups: [QuotaEventBatch.ModelGroup]) {
        guard let center else { return }
        for group in groups {
            let lines = group.systemLines
            let content = UNMutableNotificationContent()
            content.title = Self.notificationTitle(
                providerName: providerName,
                events: group.systemEvents
            )
            content.body = lines.joined(separator: "\n")
            content.sound = .default
            // 线程带 provider 维度：不同 Provider 的同名模型不会串进同一个
            // macOS 通知线程。
            content.threadIdentifier = Self.threadIdentifier(
                providerID: providerID,
                modelName: group.modelName
            )

            let request = UNNotificationRequest(
                identifier: "\(content.threadIdentifier)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    logWarn("[quota-notification] 发送 \(providerName)/\(group.displayName) 通知失败: \(error.localizedDescription)")
                } else {
                    logInfo("[quota-notification] 已发送 \(providerName)/\(group.displayName) 额度更新通知（\(lines.count) 个事件合并）")
                }
            }
        }
    }

    /// macOS 通知线程标识：provider + 模型，避免不同 Provider 的同名模型互串。
    static func threadIdentifier(providerID: String, modelName: String) -> String {
        "quota-update-\(providerID)-\(modelName)"
    }

    // MARK: - 冷却（与 Bark 队列同口径，抑制阈值抖动刷屏）

    /// 同一模型两条系统通知的最小间隔。
    nonisolated static let cooldownInterval: TimeInterval = 60

    /// 最近一次系统通知时间，键 = threadIdentifier。仅 notify（MainActor）读写。
    private var lastNotifiedAt: [String: Date] = [:]

    /// 纯函数：按冷却窗口过滤分组并记录发送时间。测试直接构造调用。
    nonisolated static func groupsAfterCooldown(
        _ groups: [QuotaEventBatch.ModelGroup],
        providerID: String,
        now: Date,
        lastNotifiedAt: inout [String: Date]
    ) -> [QuotaEventBatch.ModelGroup] {
        groups.filter { group in
            let key = threadIdentifier(providerID: providerID, modelName: group.modelName)
            if let last = lastNotifiedAt[key],
               now.timeIntervalSince(last) < cooldownInterval {
                logDebug("[quota-notification] \(key) 命中冷却窗口，跳过本次系统通知")
                return false
            }
            lastNotifiedAt[key] = now
            return true
        }
    }

    /// 通知标题跟随事件类型：纯耗尽 →「已用完」，纯恢复 →「已恢复」，
    /// 混合（如 5h 耗尽 + 周恢复同帧）→ 中性「额度提醒」。
    nonisolated static func notificationTitle(providerName: String, events: [QuotaEvent]) -> String {
        let kinds = Set(events.map(\.kind))
        if kinds.isSubset(of: [.intervalExhausted, .weeklyExhausted]) {
            return "\(providerName) 额度已用完"
        }
        if kinds.isSubset(of: [.intervalRestored, .weeklyRestored]) {
            return "\(providerName) 额度已恢复"
        }
        return "\(providerName) 额度提醒"
    }

    static func messageLine(_ event: QuotaEvent) -> String {
        switch event.kind {
        case .intervalRestored, .weeklyRestored:
            let window = event.kind == .intervalRestored ? "短周期" : "周额度"
            return "\(event.displayName)：\(window) \(Formatters.formatQuotaPercent(event.previousPercent)) → \(Formatters.formatQuotaPercent(event.currentPercent))"
        case .intervalExhausted:
            return "\(event.displayName)：5 小时额度已用完（剩 \(Formatters.formatQuotaPercent(event.currentPercent))）"
        case .weeklyExhausted:
            return "\(event.displayName)：周额度已用完（剩 \(Formatters.formatQuotaPercent(event.currentPercent))）"
        }
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

@MainActor
extension SystemQuotaUpdateNotifier: QuotaUpdateNotifying {}
