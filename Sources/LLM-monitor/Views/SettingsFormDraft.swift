import Foundation

/// SettingsView 的表单可编辑草稿模型。
///
/// 仅包含可持久化编辑字段（配置项），排除错误提示、选择态、测试状态等瞬态 UI 状态。
/// 遵循 Equatable 实现统一脏检查（取代原先手拼 40+ 项的 draftFingerprint）。
struct SettingsFormDraft: Equatable {
    var globalInterval: Int = 300
    var periodicFullEveryN: Int = AppConfig.defaultPeriodicFullEveryN
    var statusBarIconStyle: StatusBarIconStyle = .chartBar
    var statusBarHealthDotEnabled: Bool = true
    var statusBarHealthColors: StatusBarHealthColors = .default
    var statusBarQuotaProvider: String = ""
    var statusBarQuotaSource: StatusBarQuotaSource = .plan
    var appearance: AppAppearance = .auto
    var systemNotificationSoundEnabled: Bool = true
    var edgeDockMode: EdgeDockMode = EdgeDockConfig.default.mode
    var edgeDockHideInFullscreen: Bool = EdgeDockConfig.default.hideInFullscreen
    var edgeDockCompactSize: EdgeDockCompactSize = EdgeDockConfig.default.compactSize
    var edgeDockIndependentRingColors: Bool = EdgeDockConfig.default.independentRingColors
    var holidaySource: String = ""
    var providerCardOrder: [String] = []
    var alertThresholds: AlertThresholdConfig = .default

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
    var chatgptAdminKeys: [CodexAdminKeyConfigDraft] = [CodexAdminKeyConfigDraft(id: "default")]

    var chatgptAdminApiKey: String {
        get { chatgptAdminKeys.first?.apiKey ?? "" }
        set {
            if chatgptAdminKeys.isEmpty {
                chatgptAdminKeys.append(CodexAdminKeyConfigDraft(id: "default", apiKey: newValue))
            } else {
                chatgptAdminKeys[0].apiKey = newValue
            }
        }
    }
    var chatgptBillingDay: Int {
        get { chatgptAdminKeys.first?.billingDay ?? 11 }
        set {
            if chatgptAdminKeys.isEmpty {
                chatgptAdminKeys.append(CodexAdminKeyConfigDraft(id: "default", billingDay: newValue))
            } else {
                chatgptAdminKeys[0].billingDay = newValue
            }
        }
    }
    var chatgptBillingTime: Date {
        get { chatgptAdminKeys.first?.billingTime ?? SettingsFormDraft.defaultBillingTime() }
        set {
            if chatgptAdminKeys.isEmpty {
                chatgptAdminKeys.append(CodexAdminKeyConfigDraft(id: "default", billingTime: newValue))
            } else {
                chatgptAdminKeys[0].billingTime = newValue
            }
        }
    }
    var chatgptMonthlyQuotaLimit: String {
        get { chatgptAdminKeys.first?.monthlyQuotaLimit ?? "40" }
        set {
            if chatgptAdminKeys.isEmpty {
                chatgptAdminKeys.append(CodexAdminKeyConfigDraft(id: "default", monthlyQuotaLimit: newValue))
            } else {
                chatgptAdminKeys[0].monthlyQuotaLimit = newValue
            }
        }
    }

    var antigravityEnabled: Bool = false
    var antigravityInterval: Int = 0
    /// Antigravity keychain → 远端兜底开关（2.5.0，config 缺省 true）。
    var antigravityAccessTokenFallback: Bool = true
    /// Antigravity agy 代理刷新开关（2.5.0 语义翻正，config 缺省 true）。
    var antigravityAllowTokenRefresh: Bool = true

    var glmEnabled: Bool = false
    var glmInterval: Int = 0
    var glmAuthPath: String = ""
    var glmApiKey: String = ""
    var glmZcodeJWTEnabled: Bool = false
    var glmNotifyCampaign: QuotaNotifyChannel = .none

    var deepseekEnabled: Bool = false
    var deepseekInterval: Int = 0
    var deepseekApiKey: String = ""

    var notifyChannels: [String: [QuotaNotificationKind: QuotaNotifyChannel]] = [:]

    init() {}

    /// 常规与 Provider 设置共用的预计周期，按运行时的有效主刷新间隔折算。
    func secondaryInfoRefreshInterval(providerInterval: Int = 0) -> Int {
        let interval = providerInterval > 0 ? providerInterval : globalInterval
        let effectiveInterval = min(max(interval, 10), AppConfig.maximumRefreshIntervalSeconds)
        return effectiveInterval * periodicFullEveryN
    }

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
        statusBarQuotaProvider = config.statusBarQuotaSelection?.providerID ?? ""
        statusBarQuotaSource = config.statusBarQuotaSelection?.source ?? .plan
        appearance = config.effectiveAppearance
        systemNotificationSoundEnabled = config.effectiveSystemNotificationSoundEnabled

        let dock = config.effectiveEdgeDockConfig
        edgeDockMode = dock.mode
        edgeDockHideInFullscreen = dock.hideInFullscreen
        edgeDockCompactSize = dock.compactSize
        edgeDockIndependentRingColors = dock.independentRingColors

        holidaySource = config.holidaySource ?? HolidayCalendar.defaultSourceURL
        alertThresholds = config.effectiveAlertThresholds

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

            let effective = pc.effectiveAdminKeys
            if !effective.isEmpty {
                chatgptAdminKeys = effective.map { CodexAdminKeyConfigDraft(from: $0) }
            } else {
                chatgptAdminKeys = [
                    CodexAdminKeyConfigDraft(
                        id: "default",
                        label: "",
                        apiKey: pc.adminApiKey ?? "",
                        monthlyQuotaLimit: pc.adminMonthlyQuotaLimit.map {
                            $0.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", $0) : String($0)
                        } ?? "40",
                        billingDay: pc.adminBillingDay ?? 11,
                        billingTime: SettingsView.parseBillingTime(from: pc.adminBillingTime)
                    )
                ]
            }
        }

        if let id = pid(for: .antigravity), let pc = config.providers[id] {
            antigravityEnabled = pc.enabled
            antigravityInterval = pc.refreshIntervalSeconds ?? 0
            antigravityAccessTokenFallback = pc.effectiveAccessTokenFallback
            antigravityAllowTokenRefresh = pc.effectiveAllowTokenRefresh
        }

        if let id = pid(for: .glmCodingPlan), let pc = config.providers[id] {
            glmEnabled = pc.enabled
            glmApiKey = pc.apiKey ?? ""
            glmZcodeJWTEnabled = pc.isZcodeCredentialEnabled
            glmInterval = pc.refreshIntervalSeconds ?? 0
            glmAuthPath = pc.authPath ?? ""
            glmNotifyCampaign = pc.notifyCampaign ?? .none
        }

        if let id = pid(for: .deepseek), let pc = config.providers[id] {
            deepseekEnabled = pc.enabled
            deepseekApiKey = pc.apiKey ?? ""
            deepseekInterval = pc.refreshIntervalSeconds ?? 0
        }
    }
}

/// SettingsView 中单个 Codex Admin API Key 的草稿模型
struct CodexAdminKeyConfigDraft: Identifiable, Equatable {
    var id: String
    var label: String
    var apiKey: String
    var monthlyQuotaLimit: String
    var billingDay: Int
    var billingTime: Date
    /// 当前账期边界日扣除值（美元，可为负；正数=增加已用）。默认 "0" 不扣除。
    var usedAmountAdjust: String
    /// 打开设置时的 adjust 快照：saveAndApply 据此区分「用户没动」（保留 config
    /// 现值与定值时间戳，含自动写回）与「用户改了」（定值为本拍）。
    var initialUsedAmountAdjust: String
    /// config 侧边界扣除定值时间戳的构造时快照（自动写回或手动修改产生）。
    var usedAmountAdjustFixedAt: Date?

    init(
        id: String = UUID().uuidString,
        label: String = "",
        apiKey: String = "",
        monthlyQuotaLimit: String = "40",
        billingDay: Int = 11,
        billingTime: Date = SettingsFormDraft.defaultBillingTime(),
        usedAmountAdjust: String = "0",
        initialUsedAmountAdjust: String = "0",
        usedAmountAdjustFixedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.apiKey = apiKey
        self.monthlyQuotaLimit = monthlyQuotaLimit
        self.billingDay = billingDay
        self.billingTime = billingTime
        self.usedAmountAdjust = usedAmountAdjust
        self.initialUsedAmountAdjust = initialUsedAmountAdjust
        self.usedAmountAdjustFixedAt = usedAmountAdjustFixedAt
    }

    /// Double → 草稿字符串：整数显示 %.0f，否则 String(value)，避免 "40.0" 尾零噪声。
    private static func formatDraftDouble(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(v)
    }

    init(from config: CodexAdminKeyConfig) {
        self.id = config.id
        self.label = config.label
        self.apiKey = config.apiKey
        self.monthlyQuotaLimit = Self.formatDraftDouble(config.monthlyQuotaLimit)
        self.billingDay = config.billingDay
        self.billingTime = SettingsView.parseBillingTime(from: config.billingTime)
        self.usedAmountAdjust = Self.formatDraftDouble(config.usedAmountAdjust)
        self.initialUsedAmountAdjust = self.usedAmountAdjust
        self.usedAmountAdjustFixedAt = config.usedAmountAdjustFixedAt
    }

    func toConfig() -> CodexAdminKeyConfig? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return nil }
        let limit = Double(monthlyQuotaLimit.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 40.0
        let adjust = Double(usedAmountAdjust.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
        return CodexAdminKeyConfig(
            id: id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: cleanKey,
            monthlyQuotaLimit: limit > 0 && limit.isFinite ? limit : 40.0,
            billingDay: billingDay,
            billingTime: Formatters.formatTimeOfDay(billingTime),
            // 已用修正允许负数与 0，仅拒绝非数字 / 非有限（如 "1e999" 溢出）时兜底 0。
            usedAmountAdjust: adjust.isFinite ? adjust : 0.0
        )
    }
}
