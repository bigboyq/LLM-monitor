import Foundation

/// SettingsView 的表单可编辑草稿模型。
///
/// 仅包含可持久化编辑字段（配置项），排除错误提示、选择态、测试状态等瞬态 UI 状态。
/// 遵循 Equatable 实现统一脏检查（取代原先手拼 40+ 项的 draftFingerprint）。
struct SettingsFormDraft: Equatable {
    var globalInterval: Int = 300
    var periodicFullEveryN: Int = ProviderRefreshScheduler.periodicFullEveryNDefault
    var statusBarIconStyle: StatusBarIconStyle = .chartBar
    var statusBarHealthDotEnabled: Bool = true
    var statusBarHealthColors: StatusBarHealthColors = .default
    var statusBarPinnedProvider: String = ""
    var appearance: AppAppearance = .auto
    var systemNotificationSoundEnabled: Bool = true
    var edgeDockMode: EdgeDockMode = EdgeDockConfig.default.mode
    var edgeDockHideInFullscreen: Bool = EdgeDockConfig.default.hideInFullscreen
    var edgeDockCompactSize: EdgeDockCompactSize = EdgeDockConfig.default.compactSize
    var edgeDockIndependentRingColors: Bool = EdgeDockConfig.default.independentRingColors
    var holidaySource: String = ""
    var providerCardOrder: [String] = []
    var alertThresholds: AlertThresholdConfig = .default
    var clientBindings: [ClientProviderBinding] = AppConfig.defaultClientBindings

    // Bark
    var barkEnabled: Bool = false
    var barkServerURL: String = BarkConfig.defaultServerURL
    var barkDeviceKey: String = ""
    var barkSound: String = ""
    var barkGroup: String = ""
    var barkTTL: String = ""
    var barkSkipWhenAwakeAndUnlocked: Bool = false

    // Providers
    var minimaxEnabled: Bool = false
    var minimaxInterval: Int = 0
    var minimaxApiKey: String = ""

    var chatgptEnabled: Bool = false
    var chatgptInterval: Int = 0
    var chatgptAuthPath: String = ""
    var chatgptAdminCreditsEnabled: Bool = false
    var chatgptAdminApiKey: String = ""
    var chatgptBillingDay: Int = 11
    var chatgptBillingTime: Date = SettingsFormDraft.defaultBillingTime()
    var chatgptMonthlyQuotaLimit: String = "40"

    var antigravityEnabled: Bool = false
    var antigravityInterval: Int = 0

    var glmEnabled: Bool = false
    var glmInterval: Int = 0
    var glmApiKey: String = ""
    var glmZcodeCredentialEnabled: Bool = false
    var glmNotifyCampaign: QuotaNotifyChannel = .none

    /// 兼容历史测试与调用点
    var glmZcodePlanEnabled: Bool {
        get { glmZcodeCredentialEnabled }
        set { glmZcodeCredentialEnabled = newValue }
    }
    var glmBalanceLogParsing: Bool {
        get { glmZcodeCredentialEnabled }
        set { glmZcodeCredentialEnabled = newValue }
    }

    var deepseekEnabled: Bool = false
    var deepseekInterval: Int = 0
    var deepseekApiKey: String = ""

    var notifyChannels: [String: [QuotaNotificationKind: QuotaNotifyChannel]] = [:]

    init() {}

    static func defaultBillingTime() -> Date {
        var components = DateComponents()
        components.hour = 8
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    init(from config: AppConfig, descriptors: [FetcherDescriptor]) {
        globalInterval = config.refreshIntervalSeconds
        periodicFullEveryN = config.effectivePeriodicFullEveryN
        statusBarIconStyle = config.effectiveStatusBarIconStyle
        statusBarHealthDotEnabled = config.effectiveStatusBarHealthDotEnabled
        statusBarHealthColors = config.effectiveStatusBarHealthColors
        statusBarPinnedProvider = config.statusBarPinnedProvider ?? ""
        appearance = config.effectiveAppearance
        systemNotificationSoundEnabled = config.effectiveSystemNotificationSoundEnabled

        let dock = config.effectiveEdgeDockConfig
        edgeDockMode = dock.mode
        edgeDockHideInFullscreen = dock.hideInFullscreen
        edgeDockCompactSize = dock.compactSize
        edgeDockIndependentRingColors = dock.independentRingColors

        holidaySource = config.holidaySource ?? HolidayCalendar.defaultSourceURL
        alertThresholds = config.effectiveAlertThresholds
        clientBindings = config.clientBindings

        if let bark = config.bark {
            barkEnabled = bark.enabled
            barkServerURL = bark.serverURL
            barkDeviceKey = bark.deviceKey
            barkSound = bark.sound ?? ""
            barkGroup = bark.group ?? ""
            barkTTL = bark.ttl > 0 ? String(bark.ttl) : ""
            barkSkipWhenAwakeAndUnlocked = bark.skipWhenAwakeAndUnlocked ?? false
        } else {
            barkEnabled = false
            barkServerURL = BarkConfig.defaultServerURL
            barkDeviceKey = ""
            barkSound = ""
            barkGroup = ""
            barkTTL = ""
            barkSkipWhenAwakeAndUnlocked = false
        }

        for kind in ProviderKind.windowedKinds {
            guard let id = descriptors.first(where: { $0.kind == kind })?.id else { continue }
            let pc = config.providers[id]
            var channels: [QuotaNotificationKind: QuotaNotifyChannel] = [:]
            channels[.intervalRestored] = pc?.notifyIntervalRestored ?? QuotaNotifyChannels().channel(for: .intervalRestored)
            channels[.intervalExhausted] = pc?.notifyIntervalExhausted ?? QuotaNotifyChannels().channel(for: .intervalExhausted)
            channels[.weeklyRestored] = pc?.notifyWeeklyRestored ?? QuotaNotifyChannels().channel(for: .weeklyRestored)
            channels[.weeklyExhausted] = pc?.notifyWeeklyExhausted ?? QuotaNotifyChannels().channel(for: .weeklyExhausted)
            notifyChannels[id] = channels
        }

        providerCardOrder = DisplayOrder.normalizedIDs(
            descriptors,
            preferredIDs: config.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        )

        func pid(for kind: ProviderKind) -> String? {
            descriptors.first(where: { $0.kind == kind })?.id
        }

        if let id = pid(for: .minimaxTokenPlan), let pc = config.providers[id] {
            minimaxEnabled = pc.enabled
            minimaxApiKey = pc.apiKey ?? ""
            minimaxInterval = pc.refreshIntervalSeconds ?? 0
        }

        if let id = pid(for: .codexChatGpt), let pc = config.providers[id] {
            chatgptEnabled = pc.enabled
            chatgptAuthPath = pc.authPath ?? ""
            chatgptInterval = pc.refreshIntervalSeconds ?? 0
            chatgptAdminCreditsEnabled = pc.adminApiCreditsEnabled ?? false
            chatgptAdminApiKey = pc.adminApiKey ?? ""
            chatgptBillingDay = pc.adminBillingDay ?? 11
            chatgptBillingTime = SettingsView.parseBillingTime(from: pc.adminBillingTime)
            if let limit = pc.adminMonthlyQuotaLimit {
                chatgptMonthlyQuotaLimit = limit.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", limit) : String(limit)
            } else {
                chatgptMonthlyQuotaLimit = "40"
            }
        }

        if let id = pid(for: .antigravity), let pc = config.providers[id] {
            antigravityEnabled = pc.enabled
            antigravityInterval = pc.refreshIntervalSeconds ?? 0
        }

        if let id = pid(for: .glmCodingPlan), let pc = config.providers[id] {
            glmEnabled = pc.enabled
            glmApiKey = pc.apiKey ?? ""
            glmInterval = pc.refreshIntervalSeconds ?? 0
            glmZcodeCredentialEnabled = pc.isZcodeCredentialEnabled
            glmNotifyCampaign = pc.notifyCampaign ?? .none
        }

        if let id = pid(for: .deepseek), let pc = config.providers[id] {
            deepseekEnabled = pc.enabled
            deepseekApiKey = pc.apiKey ?? ""
            deepseekInterval = pc.refreshIntervalSeconds ?? 0
        }
    }
}
