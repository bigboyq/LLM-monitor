import Foundation
import Combine
import AppKit

/// 状态栏图标主题样式
enum StatusBarIconStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case chartBar = "chartBar"
    case sparkles = "sparkles"
    case brain = "brain"
    case cpu = "cpu"
    case quotaLogo = "quotaLogo"
    case iconDuo = "iconDuo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chartBar: return "柱状图"
        case .sparkles: return "AI 星光"
        case .brain:    return "智能大脑"
        case .cpu:      return "芯片"
        case .quotaLogo: return "App 图标"
        case .iconDuo: return "Icon Duo"
        }
    }

    var systemImageName: String {
        switch self {
        case .chartBar: return "chart.bar.fill"
        case .sparkles: return "sparkles"
        case .brain:    return "brain.head.profile"
        case .cpu:      return "cpu.fill"
        case .quotaLogo: return "chart.donut.fill"
        case .iconDuo: return "circle.circle"
        }
    }

    /// 两种 SVG 仪表盘样式均为自包含图标，内部已表达健康度，不再叠加
    /// 通用右下角状态圆点。
    var isDashboardStyle: Bool {
        self == .quotaLogo || self == .iconDuo
    }
}

/// 状态栏健康度圆点颜色。用固定 sRGB 十六进制值保存，避免系统动态颜色在
/// 不同外观 / 显示器上被重新解释，也让手工编辑 config.json 仍然直观可读。
struct StatusBarHealthColors: Codable, Equatable, Sendable {
    var healthyHex: String
    var warningHex: String
    var criticalHex: String

    static let `default` = StatusBarHealthColors(
        healthyHex: "#34C759",
        warningHex: "#FFD60A",
        criticalHex: "#FF453A"
    )

    var healthyColor: NSColor { color(from: healthyHex) ?? .systemGreen }
    var warningColor: NSColor { color(from: warningHex) ?? .systemYellow }
    var criticalColor: NSColor { color(from: criticalHex) ?? .systemRed }

    func color(for health: HealthLevel?) -> NSColor? {
        switch health {
        case .healthy: return healthyColor
        case .warning: return warningColor
        case .critical: return criticalColor
        case nil: return nil
        }
    }

    func color(forHex hex: String) -> NSColor? {
        color(from: hex)
    }

    func hexValue(for health: HealthLevel?) -> String? {
        let rawValue: String?
        switch health {
        case .healthy: rawValue = healthyHex
        case .warning: rawValue = warningHex
        case .critical: rawValue = criticalHex
        case nil: rawValue = nil
        }
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6, UInt64(value, radix: 16) != nil else { return nil }
        return "#" + value.uppercased()
    }

    private func color(from hex: String) -> NSColor? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 应用配置 — 从 ~/Library/Application Support/LLM-monitor/config.json 读
/// Bark 推送配置。nil 等价于未启用；serverURL 允许自建服务，deviceKey 是
/// Bark App 里复制的推送 key。
///
/// 解码逐字段容错（`init(from:)`）：手工配置里单个字段类型写错只丢该字段、
/// 回退默认值，不再拖垮整个 bark 块（曾导致手改 `ttl` 类型后 deviceKey 一并
/// 失效）。结构级错误（bark 不是对象）仍由 AppConfig 的整块 catch 兜底。
struct BarkConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var serverURL: String
    var deviceKey: String
    /// 可选 Bark 自定义铃声名；nil 时用 App 默认。
    var sound: String?
    /// 人在电脑前时跳过 Bark 推送：屏幕亮着且未锁屏才跳过；显示器休眠
    /// （人离开后闲置）或已锁屏都正常推送。nil（字段不存在）= 不跳过。
    var skipWhenAwakeAndUnlocked: Bool?
    /// 消息有效期（秒）：过期后手机客户端自动删除该消息。0 = 不携带 ttl
    /// 参数（Bark 默认行为，消息不自动过期）。非法输入解码时归一化为 0。
    var ttl: Int = 0
    /// Bark 通知分组：相同 group 的通知在 iOS 通知中心折叠为一组。
    /// nil 或空白 = 不携带 group 参数（不在通知中心折叠）。
    var group: String?

    static let defaultServerURL = "https://api.day.app"
    /// group 留空时 UI 展示的占位默认值。
    static let defaultGroup = "LLMMonitor"

    /// 解析设置页草稿里的 TTL 文本：去空白后必须是正整数；空 / 非数字 /
    /// <= 0 一律归一化为 0（不落盘、不携带参数）。
    static func parseTTL(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ttl = Int(trimmed), ttl > 0 else { return 0 }
        return ttl
    }
}

extension BarkConfig {
    private enum CodingKeys: String, CodingKey {
        case enabled, serverURL, deviceKey, sound, skipWhenAwakeAndUnlocked, ttl, group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        serverURL = (try? c.decode(String.self, forKey: .serverURL)) ?? ""
        deviceKey = (try? c.decode(String.self, forKey: .deviceKey)) ?? ""
        sound = (try? c.decodeIfPresent(String.self, forKey: .sound)) ?? nil
        skipWhenAwakeAndUnlocked = (try? c.decodeIfPresent(Bool.self, forKey: .skipWhenAwakeAndUnlocked)) ?? nil
        ttl = max(0, (try? c.decodeIfPresent(Int.self, forKey: .ttl)) ?? 0)
        group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(serverURL, forKey: .serverURL)
        try c.encode(deviceKey, forKey: .deviceKey)
        try c.encodeIfPresent(sound, forKey: .sound)
        try c.encodeIfPresent(skipWhenAwakeAndUnlocked, forKey: .skipWhenAwakeAndUnlocked)
        if ttl > 0 {
            try c.encode(ttl, forKey: .ttl)
        }
        try c.encodeIfPresent(group, forKey: .group)
    }
}

struct AppConfig: Codable, Equatable {
    /// 当前配置 schema。缺失该字段的历史配置按 schema 0 解码并规范化到当前版本；
    /// schema 1 的 provider-level OpenCode 开关会迁移到 clientBindings。
    static let currentSchemaVersion = 2
    /// 防止手工配置的极大整数经过 `TimeInterval` 转换后无法安全转回 `Int`，
    /// 同时避免一次拼写错误让 provider 实际上永久停止刷新。
    static let maximumRefreshIntervalSeconds = 30 * 24 * 60 * 60

    let schemaVersion: Int

    /// 全局刷新间隔（秒）
    var refreshIntervalSeconds: Int

    /// 各 provider 配置（key = providerID）
    var providers: [String: ProviderConfig]

    /// Client → quota Provider 的显式绑定。缺失时从旧版 provider-level
    /// `mergeOpencodeUsage` 字段迁移生成，确保旧配置继续生效。
    var clientBindings: [ClientProviderBinding]

    /// 状态栏图标风格 (nil = 默认 chartBar)
    var statusBarIconStyle: StatusBarIconStyle?

    /// 是否显示状态栏健康度圆点 (nil = 默认开启)
    var statusBarHealthDotEnabled: Bool?

    /// 状态栏健康度圆点颜色 (nil = 默认绿 / 黄 / 红)
    var statusBarHealthColors: StatusBarHealthColors?

    /// 主菜单 Provider 卡片的自定义顺序。nil 或空数组表示使用默认的
    /// Provider 显示名称字母顺序；这里只保存 canonical QuotaProviderID，不保存显示名。
    var providerCardOrder: [String]?

    /// Bark 推送配置。nil 或 enabled=false 都表示不推送。
    var bark: BarkConfig?

    var effectiveStatusBarIconStyle: StatusBarIconStyle {
        statusBarIconStyle ?? .chartBar
    }

    var effectiveStatusBarHealthDotEnabled: Bool {
        statusBarHealthDotEnabled ?? true
    }

    var effectiveStatusBarHealthColors: StatusBarHealthColors {
        statusBarHealthColors ?? .default
    }

    static let `default` = AppConfig(
        refreshIntervalSeconds: 300,
        providers: [:],
        clientBindings: defaultClientBindings,
        providerCardOrder: nil
    )

    static let defaultClientBindings: [ClientProviderBinding] = [
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.minimax,
            sourceProviderAliases: [OpencodeLocalUsage.minimaxCodingPlanProviderID],
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            sourceProviderAliases: [OpencodeLocalUsage.openAIProviderID],
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.antigravity,
            sourceProviderAliases: OpencodeLocalUsage.antigravityProviderIDs,
            enabled: false
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu,
            sourceProviderAliases: [OpencodeLocalUsage.glmProviderID],
            enabled: true
        ),
        ClientProviderBinding(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek,
            sourceProviderAliases: [OpencodeLocalUsage.deepseekProviderID],
            enabled: false
        )
    ]

    enum SchemaError: LocalizedError, Equatable {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "不支持的配置 schemaVersion: \(version)"
            }
        }
    }

    init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        refreshIntervalSeconds: Int,
        providers: [String: ProviderConfig],
        clientBindings: [ClientProviderBinding] = AppConfig.defaultClientBindings,
        statusBarIconStyle: StatusBarIconStyle? = nil,
        statusBarHealthDotEnabled: Bool? = nil,
        statusBarHealthColors: StatusBarHealthColors? = nil,
        providerCardOrder: [String]? = nil,
        bark: BarkConfig? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.providers = providers
        self.clientBindings = clientBindings
        self.statusBarIconStyle = statusBarIconStyle
        self.statusBarHealthDotEnabled = statusBarHealthDotEnabled
        self.statusBarHealthColors = statusBarHealthColors
        self.providerCardOrder = providerCardOrder
        self.bark = bark
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, refreshIntervalSeconds, providers, clientBindings
        case statusBarIconStyle, statusBarHealthDotEnabled
        case statusBarHealthColors
        case providerCardOrder
        case bark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // schemaVersion 缺失代表首个无版本配置格式；缺失 clientBindings 时，
        // 由 legacyClientBindings 从旧的 ProviderConfig 字段生成迁移结果。
        let sourceVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard (0...Self.currentSchemaVersion).contains(sourceVersion) else {
            throw SchemaError.unsupportedVersion(sourceVersion)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.refreshIntervalSeconds = try container.decode(Int.self, forKey: .refreshIntervalSeconds)
        self.providers = try container.decode([String: ProviderConfig].self, forKey: .providers)
        self.clientBindings = try container.decodeIfPresent(
            [ClientProviderBinding].self,
            forKey: .clientBindings
        ) ?? Self.legacyClientBindings(from: self.providers)
        // 这些字段只影响图标外观，不应因手工拼写错误或新版本增加枚举值而让
        // 整份 provider 配置进入损坏恢复流程。未知值和类型不匹配均按缺失处理。
        self.statusBarIconStyle = (try? container.decode(String.self, forKey: .statusBarIconStyle))
            .flatMap(StatusBarIconStyle.init(rawValue:))
        self.statusBarHealthDotEnabled = try? container.decode(Bool.self, forKey: .statusBarHealthDotEnabled)
        self.statusBarHealthColors = try? container.decode(
            StatusBarHealthColors.self,
            forKey: .statusBarHealthColors
        )
        self.providerCardOrder = try? container.decode([String].self, forKey: .providerCardOrder)
        // Bark 字段手工配置容错：类型不匹配按缺失处理，不进损坏恢复流程；
        // 但 serverURL / deviceKey 等必填 key 缺失会让整块配置失效，记录告警。
        do {
            self.bark = try container.decodeIfPresent(BarkConfig.self, forKey: .bark)
        } catch {
            logWarn("[config] bark 字段解析失败，已按未配置处理：\(error.localizedDescription)")
            self.bark = nil
        }
    }

    /// 全局生效的刷新间隔：clamp 到 10s...30d（供 Provider scheduler 使用）。
    var effectiveGlobalRefreshInterval: TimeInterval {
        TimeInterval(min(max(refreshIntervalSeconds, 10), Self.maximumRefreshIntervalSeconds))
    }

    /// 实际生效的刷新间隔：优先用 provider 自己的，否则用全局，最后 clamp 到 10s...30d。
    ///
    /// 之前 AppState.scheduleRefresh 直接用 `TimeInterval(pc?.refreshIntervalSeconds ?? ...)`，
    /// 如果用户手填 0 / 负数，`Task.sleep` 立即返回，刷新任务高速循环
    /// （实测 1 秒能跑几十次 refresh，CPU 飙到 100%，minimax quota API 也会被频繁 hit）。
    func effectiveRefreshInterval(for providerID: String) -> TimeInterval {
        let value = providers[providerID]?.refreshIntervalSeconds ?? refreshIntervalSeconds
        return TimeInterval(min(max(value, 10), Self.maximumRefreshIntervalSeconds))
    }

    func isClientBindingEnabled(clientID: String, quotaProviderID: String) -> Bool {
        clientBindings.first {
            $0.clientID == clientID && $0.quotaProviderID == quotaProviderID
        }?.enabled ?? false
    }

    mutating func setClientBindingEnabled(
        clientID: String,
        quotaProviderID: String,
        enabled: Bool
    ) {
        guard let index = clientBindings.firstIndex(where: {
            $0.clientID == clientID && $0.quotaProviderID == quotaProviderID
        }) else {
            clientBindings.append(
                ClientProviderBinding(
                    clientID: clientID,
                    quotaProviderID: quotaProviderID,
                    enabled: enabled
                )
            )
            return
        }
        clientBindings[index].enabled = enabled
    }

    private static func legacyClientBindings(
        from providers: [String: ProviderConfig]
    ) -> [ClientProviderBinding] {
        let legacyPairs: [(ProviderKind, String, [String])] = [
            (.minimaxTokenPlan, QuotaProviderID.minimax, [OpencodeLocalUsage.minimaxCodingPlanProviderID]),
            (.codexChatGpt, QuotaProviderID.openAI, [OpencodeLocalUsage.openAIProviderID]),
            (.antigravity, QuotaProviderID.antigravity, OpencodeLocalUsage.antigravityProviderIDs),
            (.glmCodingPlan, QuotaProviderID.zhipu, [OpencodeLocalUsage.glmProviderID]),
            (.deepseek, QuotaProviderID.deepseek, [OpencodeLocalUsage.deepseekProviderID])
        ]
        return legacyPairs.map { kind, quotaProviderID, aliases in
            ClientProviderBinding(
                clientID: ClientID.openCode,
                quotaProviderID: quotaProviderID,
                sourceProviderAliases: aliases,
                enabled: providers[kind.providerID]?.shouldMergeOpencodeUsage(for: kind) ?? (kind == .glmCodingPlan)
            )
        }
    }
}

/// 单个 provider 的配置
///
/// 所有字段除 `enabled` 外都是 optional。nil 字段在 JSON 里**完全不写**，
/// 让配置文件保持干净——只展示当前 provider 真正关心的字段。
struct ProviderConfig: Codable, Equatable {
    /// 是否启用（false 则不抓取、UI 显示"未启用"）
    var enabled: Bool

    /// API Key（明文，文件权限 0600）。某些 provider（如 codex）从外部 auth.json 读，传 nil
    var apiKey: String?

    /// 显示名（可选，覆盖默认名）
    var displayName: String?

    /// 该 provider 自己的刷新间隔（秒）。nil = 用全局 config.refreshIntervalSeconds
    var refreshIntervalSeconds: Int?

    /// 自管 auth 的 fetcher 用：auth.json 路径（如 codex 的 ~/.codex/auth.json）
    var authPath: String?

    /// GLM Coding Plan 高峰期开始小时（24h 制，本地时区）。nil = 默认 14
    var peakStartHour: Int?
    /// GLM Coding Plan 高峰期结束小时（24h 制，半开区间）。nil = 默认 18
    var peakEndHour: Int?
    /// GLM Coding Plan 高峰期是否仅工作日（周一–周五）。nil = 默认 true
    var peakWeekdaysOnly: Bool?

    /// 是否把对应的 OpenCode provider 用量合并到菜单栏卡片。
    /// nil = 使用 provider 的默认值：GLM 默认开启，其余 provider 默认关闭。
    var mergeOpencodeUsage: Bool?

    /// 是否解析 ZCode 余额轮询日志，在 GLM 卡显示活动套餐（zcode-plan，如周末
    /// 体验套餐）的用量 / 剩余 / 过期时间。nil（字段不存在）= 关闭，不读日志。
    var parseZcodeBalanceLog: Bool?

    /// 四类额度事件的通知渠道（5 小时 / 周额度 × 恢复 / 耗尽）。
    /// nil（字段不存在）= 使用默认渠道（恢复 → 系统通知，耗尽 → 不通知），
    /// 与引入通知配置前的行为一致。
    var notifyIntervalRestored: QuotaNotifyChannel?
    var notifyIntervalExhausted: QuotaNotifyChannel?
    var notifyWeeklyRestored: QuotaNotifyChannel?
    var notifyWeeklyExhausted: QuotaNotifyChannel?

    enum CodingKeys: String, CodingKey {
        case enabled, apiKey, displayName, refreshIntervalSeconds, authPath
        case peakStartHour, peakEndHour, peakWeekdaysOnly, mergeOpencodeUsage
        case parseZcodeBalanceLog
        case notifyIntervalRestored, notifyIntervalExhausted
        case notifyWeeklyRestored, notifyWeeklyExhausted
    }

    init(enabled: Bool = true,
         apiKey: String? = nil,
         displayName: String? = nil,
         refreshIntervalSeconds: Int? = nil,
         authPath: String? = nil,
         peakStartHour: Int? = nil,
         peakEndHour: Int? = nil,
         peakWeekdaysOnly: Bool? = nil,
         mergeOpencodeUsage: Bool? = nil,
         parseZcodeBalanceLog: Bool? = nil,
         notifyIntervalRestored: QuotaNotifyChannel? = nil,
         notifyIntervalExhausted: QuotaNotifyChannel? = nil,
         notifyWeeklyRestored: QuotaNotifyChannel? = nil,
         notifyWeeklyExhausted: QuotaNotifyChannel? = nil) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.displayName = displayName
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.authPath = authPath
        self.peakStartHour = peakStartHour
        self.peakEndHour = peakEndHour
        self.peakWeekdaysOnly = peakWeekdaysOnly
        self.mergeOpencodeUsage = mergeOpencodeUsage
        self.parseZcodeBalanceLog = parseZcodeBalanceLog
        self.notifyIntervalRestored = notifyIntervalRestored
        self.notifyIntervalExhausted = notifyIntervalExhausted
        self.notifyWeeklyRestored = notifyWeeklyRestored
        self.notifyWeeklyExhausted = notifyWeeklyExhausted
    }

    /// 自定义 decode 只为一个默认值：`enabled` 缺失按 true 处理（编译器合成的
    /// Codable 会在缺 key 时直接抛错，把整份配置送进损坏恢复流程）。
    /// encode 走编译器合成：optional 字段自动 encodeIfPresent，与 nil 字段
    /// 不写盘的约定一致。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
        self.authPath = try c.decodeIfPresent(String.self, forKey: .authPath)
        self.peakStartHour = try c.decodeIfPresent(Int.self, forKey: .peakStartHour)
        self.peakEndHour = try c.decodeIfPresent(Int.self, forKey: .peakEndHour)
        self.peakWeekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .peakWeekdaysOnly)
        self.mergeOpencodeUsage = try c.decodeIfPresent(Bool.self, forKey: .mergeOpencodeUsage)
        self.parseZcodeBalanceLog = try c.decodeIfPresent(Bool.self, forKey: .parseZcodeBalanceLog)
        // 渠道枚举值写错时按缺失处理，不让整份配置进入损坏恢复流程。
        self.notifyIntervalRestored = (try? c.decode(String.self, forKey: .notifyIntervalRestored))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyIntervalExhausted = (try? c.decode(String.self, forKey: .notifyIntervalExhausted))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyWeeklyRestored = (try? c.decode(String.self, forKey: .notifyWeeklyRestored))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyWeeklyExhausted = (try? c.decode(String.self, forKey: .notifyWeeklyExhausted))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
    }
}

extension ProviderConfig {
    /// OpenCode 合并开关的兼容默认值。GLM 在该功能引入前就使用 OpenCode，
    /// 因此缺失配置时继续保持开启；其它 provider 保持原有的本地 Scanner 口径。
    func shouldMergeOpencodeUsage(for kind: ProviderKind) -> Bool {
        mergeOpencodeUsage ?? (kind == .glmCodingPlan)
    }

    /// 真正可用的 API Key：剔除空白 / 空 / 模板占位符（含 "REPLACE"）。
    ///
    /// 之前调用点（ConfigStore 日志 / AppState rebuildStatuses / AppState refreshProviderDirectly）
    /// 各自用不同的占位符判断（`hasPrefix("sk-cp-REPLACE")`），导致：
    /// - 模板生成的 `"REPLACE-WITH-YOUR-KEY"`（无前缀）会被误判为有效 key
    /// - 用户手写的 `"your-key-here"` / `"sk-cp-xxx-REPLACE-THIS-TOKEN"` 等会漏过
    ///
    /// 现在统一用这一处判断，ConfigStore 自动补全的 `sk-cp-REPLACE-WITH-YOUR-KEY` 也安全。
    var usableAPIKey: String? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              !key.localizedCaseInsensitiveContains("REPLACE") else {
            return nil
        }
        return key
    }

    /// 保存设置时的归一化入口：与默认渠道一致写 nil，保持 config.json 干净。
    /// 默认值的唯一来源是 `QuotaNotifyChannels.channel(for:)`，避免两处硬编码漂移。
    mutating func setNotifyChannel(
        _ channel: QuotaNotifyChannel,
        for kind: QuotaNotificationKind
    ) {
        let isDefault = channel == QuotaNotifyChannels().channel(for: kind)
        let value: QuotaNotifyChannel? = isDefault ? nil : channel
        switch kind {
        case .intervalRestored: notifyIntervalRestored = value
        case .intervalExhausted: notifyIntervalExhausted = value
        case .weeklyRestored: notifyWeeklyRestored = value
        case .weeklyExhausted: notifyWeeklyExhausted = value
        }
    }

    /// 解析为 GLM 高峰期窗口。nil 字段回退官方默认（14–18 / 仅工作日）；
    /// 非法配置（end ≤ start 或越界）整体回退默认，避免 UI 误判成永久高峰/非高峰。
    var glmPeakWindow: GlmPeakWindow {
        let d = GlmPeakWindow.zhipuDefault
        let start = peakStartHour ?? d.startHour
        let end = peakEndHour ?? d.endHour
        let weekdays = peakWeekdaysOnly ?? d.weekdaysOnly
        let validRange = 0...23
        guard validRange.contains(start),
              validRange.contains(end),
              end > start else {
            return d
        }
        return GlmPeakWindow(startHour: start, endHour: end, weekdaysOnly: weekdays)
    }
}

/// 配置文件读写 + 文件变化监听
@MainActor
final class ConfigStore: ObservableObject, BarkConfigProviding {
    enum PersistenceError: LocalizedError {
        case corruptConfigBackupFailed(URL)

        var errorDescription: String? {
            switch self {
            case .corruptConfigBackupFailed(let url):
                return "配置文件无法解析，且备份原文件失败：\(url.path)"
            }
        }
    }

    @Published private(set) var config: AppConfig

    /// BarkQuotaNotifier 每次推送前实时读取，设置保存后无需重启即生效。
    var bark: BarkConfig? { config.bark }

    /// 配置文件绝对路径
    let configURL: URL

    /// 上次成功读取或写入的配置内容。
    ///
    /// 文件监听只告诉我们配置目录发生了写事件；单独比较 mtime 在极短时间内
    /// 连续保存时可能漏掉内容变化。保存内容指纹不依赖文件系统的 mtime 精度。
    private var lastKnownData: Data?
    /// 配置损坏且无法备份时禁止后续写入，避免用默认配置覆盖原文件。
    private var persistenceAllowed = true

    /// `configURL` 可注入，测试不再读取或创建用户真实的 Application Support 配置。
    init(configURL overrideURL: URL? = nil) {
        let fm = FileManager.default
        let appDir: URL
        let url: URL
        if let overrideURL {
            url = overrideURL
            appDir = overrideURL.deletingLastPathComponent()
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            appDir = support.appendingPathComponent("LLM-monitor", isDirectory: true)
            url = appDir.appendingPathComponent("config.json")
        }
        do {
            try fm.createDirectory(
                at: appDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: appDir.path
            )
        } catch {
            logError("ConfigStore: 无法创建或收紧配置目录权限: \(error.localizedDescription)")
        }

        self.configURL = url

        logInfo("ConfigStore: 配置文件路径 = \(url.path)")

        // 首次启动：写模板文件，方便用户编辑
        let templateError: String?
        if !fm.fileExists(atPath: url.path) {
            logInfo("ConfigStore: 首次启动，写入模板")
            templateError = Self.writeTemplate(to: url)
        } else {
            templateError = nil
        }

        let loaded: AppConfig?
        let loadError: Error?
        if let data = Self.data(from: url) {
            do {
                loaded = try Self.decode(data)
                loadError = nil
            } catch {
                loaded = nil
                loadError = error
            }
        } else {
            loaded = nil
            loadError = nil
        }

        if let loaded {
            self.config = loaded
            logInfo("ConfigStore: 加载成功，\(loaded.providers.count) 个 provider")
            for (id, pc) in loaded.providers {
                let keyDesc: String
                if pc.usableAPIKey != nil {
                    keyDesc = "key=set"
                } else if let key = pc.apiKey, !key.isEmpty {
                    keyDesc = "key=template"
                } else {
                    keyDesc = "key=nil (外部 auth)"
                }
                logInfo("  - \(id): enabled=\(pc.enabled), \(keyDesc), displayName=\(pc.displayName ?? "<default>")")
            }
        } else {
            self.config = .default
            if fm.fileExists(atPath: url.path) {
                if let schemaError = loadError as? AppConfig.SchemaError {
                    persistenceAllowed = false
                    logError("ConfigStore: \(schemaError.localizedDescription)；保留原文件，禁止旧版本自动写回")
                } else if let backupURL = Self.backupCorruptConfig(at: url) {
                    logError("ConfigStore: 配置解析失败，原文件已备份到 \(backupURL.path)；当前使用默认空配置")
                } else {
                    persistenceAllowed = false
                    logError("ConfigStore: 配置解析失败且原文件备份失败，禁止自动写回默认配置")
                }
            } else {
                logWarn("ConfigStore: 配置文件不存在，使用默认空配置")
            }
        }

        self.lastKnownData = Self.data(from: url)

        if let err = templateError {
            logError("ConfigStore: 初始化错误 = \(err)")
        }
    }

    /// 用所有已注册的 descriptors 补全缺失的 provider 段（不覆盖已有配置）
    /// 这样配置文件永远是"全 provider 示例 + 当前启用状态"，新加的 provider 也会自动出现
    @discardableResult
    func ensureProvidersPresent(descriptors: [FetcherDescriptor]) -> Bool {
        var updated = config
        var changed = false
        for d in descriptors {
            if updated.providers[d.id] == nil {
                let placeholder: ProviderConfig
                if d.kind.usesExternalAuth {
                    switch d.kind {
                    case .codexChatGpt:
                        placeholder = ProviderConfig(
                            enabled: false,
                            authPath: "~/.codex/auth.json"
                        )
                    case .antigravity:
                        placeholder = ProviderConfig(
                            enabled: false
                        )
                    case .minimaxTokenPlan:
                        placeholder = ProviderConfig(
                            enabled: false,
                            apiKey: "REPLACE-WITH-YOUR-KEY"
                        )
                    case .glmCodingPlan, .deepseek:
                        // 走 else 分支（非外部 auth）；此处为满足 switch 穷尽，不可达。
                        placeholder = ProviderConfig(
                            enabled: false,
                            apiKey: "REPLACE-WITH-YOUR-KEY"
                        )
                    }
                } else {
                    placeholder = ProviderConfig(
                        enabled: false,
                        apiKey: "REPLACE-WITH-YOUR-KEY"
                    )
                }
                updated.providers[d.id] = placeholder
                changed = true
                logInfo("ConfigStore: 补全缺失 provider 段: \(d.id) (kind=\(d.kind), usesExternalAuth=\(d.kind.usesExternalAuth))")
            }
        }
        if changed {
            do {
                try applyAndSave(updated)
            } catch {
                logError("ConfigStore: 补全 provider 后写回失败: \(error.localizedDescription)")
                return false
            }
        }
        return changed
    }

    /// 先用同目录 0600 临时文件原子替换目标，再发布新配置；任何编码、写入、
    /// 权限设置或 rename 错误都会在 `config` 赋值前抛出。
    func applyAndSave(_ newConfig: AppConfig) throws {
        guard persistenceAllowed else {
            throw PersistenceError.corruptConfigBackupFailed(configURL)
        }
        try persist(newConfig)
        config = newConfig
        logInfo("ConfigStore: 配置已写回并应用 \(configURL.path)")
    }

    private func persist(_ value: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        // ConfigStore 受 MainActor 隔离；这个一次性 FileManagerBox 不会跨 actor
        // 或并发任务共享，符合其“调用方必须自行串行化”的使用约束。
        try FileManagerBox().writePrivate(data, to: configURL)
        lastKnownData = data
    }

    // MARK: - 公开

    /// 强制从磁盘重读
    func reload() {
        reload(using: Self.data(from: configURL))
    }

    /// 用 watcher 已读取的内容重载配置，避免再次同步读取同一个文件。
    func reload(using data: Data?) {
        guard let data else {
            logError("ConfigStore.reload: 解析失败，保留上次配置")
            return
        }
        let fresh: AppConfig
        do {
            fresh = try Self.decode(data)
        } catch let error as AppConfig.SchemaError {
            persistenceAllowed = false
            logError("ConfigStore.reload: \(error.localizedDescription)，保留上次配置")
            return
        } catch {
            logError("ConfigStore.reload: 解析失败，保留上次配置")
            return
        }
        let oldCount = config.providers.count
        config = fresh
        lastKnownData = data
        persistenceAllowed = true
        logInfo("ConfigStore.reload: 成功，providers \(oldCount) → \(fresh.providers.count)")
    }

    /// 用系统默认 app 打开配置文件（TextEdit / VSCode / Cursor …）
    func openInDefaultEditor() {
        NSWorkspace.shared.open(configURL)
    }

    /// 外部检查"是否需要 reload"
    func hasChangedSinceLastRead() -> Bool {
        hasChangedSinceLastRead(using: Self.data(from: configURL))
    }

    /// 用已经在后台读取的内容检查配置是否变化，避免 watcher 在主线程同步读盘。
    func hasChangedSinceLastRead(using currentData: Data?) -> Bool {
        guard let currentData else { return false }
        guard let lastKnownData else { return true }
        return currentData != lastKnownData
    }

    /// watcher 专用的无日志读取入口；调用方负责在合适的后台上下文执行。
    nonisolated static func dataForWatcher(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }


    // MARK: - 文件变化监听（DispatchSource watcher）

    /// 只监听 config.json 单文件本身，而不是整个配置目录：log.txt 与
    /// last-refresh.json 就在同一个目录里，目录级 `.write` 监听会让每条日志
    /// append / 每次时间戳落盘都触发一轮 debounce + 读盘 + 指纹比对。
    private var configMonitorSource: DispatchSourceFileSystemObject?
    private var configReloadTask: Task<Void, Never>?
    /// config.json 被删除/替换后重新挂载 watcher 的重试 task（带退避）。
    private var configWatcherRetryTask: Task<Void, Never>?
    private var configWatcherRetryAttempt = 0

    /// 启动配置文件监听（幂等）。AppState.start() 调用；编辑器保存（含原子替换）、
    /// 手工编辑都会触发 debounce 后的 reload。
    func startWatching() {
        guard configMonitorSource == nil, configWatcherRetryTask == nil else { return }
        startConfigWatcher()
    }

    func stopWatching() {
        configReloadTask?.cancel()
        configReloadTask = nil
        configWatcherRetryTask?.cancel()
        configWatcherRetryTask = nil
        configWatcherRetryAttempt = 0
        configMonitorSource?.cancel()
        configMonitorSource = nil
    }

    private func startConfigWatcher() {
        configMonitorSource?.cancel()
        configWatcherRetryTask?.cancel()
        configWatcherRetryTask = nil

        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // 编辑器"先删后写"或瞬时替换会让文件短暂不存在；带退避重试，
            // 直到文件重新可打开。open() 失败只是一个 syscall，成本可忽略。
            let attempt = configWatcherRetryAttempt
            configWatcherRetryAttempt = min(attempt + 1, 5)
            if attempt == 0 {
                logWarn("ConfigStore: 配置文件暂不可监听（可能正被替换），稍后重试: \(configURL.path)")
            } else {
                logDebug("ConfigStore: 配置文件监听重试第 \(attempt + 1) 次")
            }
            let delaySeconds = min(1 << min(attempt, 5), 30)
            configWatcherRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.startConfigWatcher() }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 本应用的 writePrivate 与多数编辑器都用"临时文件 + rename"原子替换：
            // fd 仍指向旧 inode，必须重新打开新文件，否则后续变更全部丢失。
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.startConfigWatcher()
            }
            self.scheduleConfigReload()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.configMonitorSource = source
        configWatcherRetryAttempt = 0
        logInfo("ConfigStore: 配置文件监听启动 (基于 config.json 单文件 DispatchSource)")
    }

    /// 编辑器保存时可能连发多个事件（写 + 原子替换）。先 debounce，再把配置文件
    /// 读取放到 utility task，避免每个事件都在 MainActor 上同步读盘；最终的
    /// config 解码和发布仍回到 MainActor。
    private func scheduleConfigReload() {
        configReloadTask?.cancel()
        let configURL = self.configURL
        configReloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            let data = await Task.detached(priority: .utility) {
                ConfigStore.dataForWatcher(from: configURL)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.configReloadTask = nil
            guard self.hasChangedSinceLastRead(using: data) else { return }
            logInfo("ConfigStore: 检测到配置文件更新，触发 reload")
            self.reload(using: data)
        }
    }

    // MARK: - 内部

    private static func data(from url: URL) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            logError("ConfigStore: 读取配置失败 \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    private static func decode(_ data: Data) throws -> AppConfig {
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    private static func backupCorruptConfig(at url: URL) -> URL? {
        let backupURL = URL(fileURLWithPath: "\(url.path).corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: backupURL.path
            )
            return backupURL
        } catch {
            logError("ConfigStore: 无法备份损坏配置 \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// 首次启动的 config.json 模板 provider 段。
    ///
    /// **已知边界**：`templateProviders` 在 `ConfigStore.init` 里被 `writeTemplate`
    /// 调用，此时 `LLMMonitorApp.makeDescriptors()` 还没跑，所以 `descriptors`
    /// 不可用。模板里的 provider 段通过 `ProviderKind.providerID` 生成。
    /// 新增 provider 时**仍需**同步增加默认配置段（CI 由
    /// `ConfigStoreTemplateTests` 锁住一致性）。
    /// 运行时入口则由 `ensureProvidersPresent(descriptors:)` 负责
    /// descriptor-driven 补全，不受模板遗漏影响。
    ///
    /// `nonisolated static` 让 test 可以在主 actor 之外直接调用，验证模板
    /// 内容跟 `LLMMonitorApp.makeDescriptors()` 一致；不必走磁盘写入。
    nonisolated static func templateProviders() -> [String: ProviderConfig] {
        [
            ProviderKind.minimaxTokenPlan.providerID: ProviderConfig(
                enabled: false,
                apiKey: "sk-cp-REPLACE-WITH-YOUR-KEY"
            ),
            ProviderKind.codexChatGpt.providerID: ProviderConfig(
                enabled: false,
                authPath: "~/.codex/auth.json"
            ),
            ProviderKind.antigravity.providerID: ProviderConfig(
                enabled: false
            ),
            ProviderKind.glmCodingPlan.providerID: ProviderConfig(
                enabled: false,
                apiKey: "REPLACE-WITH-YOUR-CODING-PLAN-KEY"
            ),
            ProviderKind.deepseek.providerID: ProviderConfig(
                enabled: false,
                apiKey: "sk-REPLACE-WITH-YOUR-KEY"
            )
        ]
    }

    /// 写首次启动的 config.json 模板（基于 `templateProviders()` + 默认
    /// `refreshIntervalSeconds`）。
    private static func writeTemplate(to url: URL) -> String? {
        let providers = templateProviders()
        let config = AppConfig(
            refreshIntervalSeconds: 300,
            providers: providers
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try FileManagerBox().writePrivate(data, to: url)
            return nil
        } catch {
            return "无法创建配置文件模板：\(error.localizedDescription)"
        }
    }
}
