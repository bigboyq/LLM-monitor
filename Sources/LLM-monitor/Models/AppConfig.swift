import Foundation
import AppKit

// MARK: - Status Bar Appearance Config

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

    /// 自带完整图形的两种样式：App 图标（固定设计稿）与 Icon Duo（额度仪表盘），
    /// 都不叠加通用右下角状态圆点——设计稿没给圆点留位置，Icon Duo 的边缘弧贴着
    /// 画布，圆点只会压在图形上。
    var isDashboardStyle: Bool {
        self == .quotaLogo || self == .iconDuo
    }

    /// 该样式是否真的消费额度指标（`StatusBarQuotaMetrics`）。
    ///
    /// 目前只有 Icon Duo 仪表盘读它：`quotaLogo` 已改成固定设计稿（见
    /// `MenuBarLabel`），四种系统符号只有颜色随健康度变。这条让 `RenderSignature`
    /// 只在真正需要时把指标算进去——否则每次额度广播（每个 provider 一次）都会
    /// 改变签名，逼着另外四种样式白重合成一次 NSImage。
    var consumesQuotaMetrics: Bool {
        self == .iconDuo
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

// MARK: - Alert Threshold Config

/// 集中告警配置中心：控制 API 配额与账户余额的红黄健康度阈值。
/// 逐字段容错解码：手改坏单个字段只回退该字段默认值。
struct AlertThresholdConfig: Codable, Equatable, Sendable {
    /// API 额度（用量 × 时间系数）黄色警告阈值百分比（默认 60%）
    var apiQuotaWarningPercent: Double
    /// API 额度（用量 × 时间系数）红色严重阈值百分比（默认 30%）
    var apiQuotaCriticalPercent: Double
    /// DeepSeek 余额黄色警告阈值（默认 10）
    var deepseekBalanceWarning: Double
    /// DeepSeek 余额红色严重阈值（默认 3）
    var deepseekBalanceCritical: Double

    static let `default` = AlertThresholdConfig(
        apiQuotaWarningPercent: 60.0,
        apiQuotaCriticalPercent: 30.0,
        deepseekBalanceWarning: 10.0,
        deepseekBalanceCritical: 3.0
    )

    init(
        apiQuotaWarningPercent: Double = 60.0,
        apiQuotaCriticalPercent: Double = 30.0,
        deepseekBalanceWarning: Double = 10.0,
        deepseekBalanceCritical: Double = 3.0
    ) {
        let warning = min(max(apiQuotaWarningPercent, 0.0), 100.0)
        let critical = min(max(apiQuotaCriticalPercent, 0.0), warning)
        self.apiQuotaWarningPercent = warning
        self.apiQuotaCriticalPercent = critical

        let dsWarning = max(deepseekBalanceWarning, 0.0)
        let dsCritical = min(max(deepseekBalanceCritical, 0.0), dsWarning)
        self.deepseekBalanceWarning = dsWarning
        self.deepseekBalanceCritical = dsCritical
    }

    var normalized: AlertThresholdConfig {
        AlertThresholdConfig(
            apiQuotaWarningPercent: apiQuotaWarningPercent,
            apiQuotaCriticalPercent: apiQuotaCriticalPercent,
            deepseekBalanceWarning: deepseekBalanceWarning,
            deepseekBalanceCritical: deepseekBalanceCritical
        )
    }
}

extension AlertThresholdConfig {
    private enum CodingKeys: String, CodingKey {
        case apiQuotaWarningPercent
        case apiQuotaCriticalPercent
        case deepseekBalanceWarning
        case deepseekBalanceCritical
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = AlertThresholdConfig.default
        let rawWarning = (try? c.decode(Double.self, forKey: .apiQuotaWarningPercent)) ?? def.apiQuotaWarningPercent
        let rawCritical = (try? c.decode(Double.self, forKey: .apiQuotaCriticalPercent)) ?? def.apiQuotaCriticalPercent
        let rawDsWarning = (try? c.decode(Double.self, forKey: .deepseekBalanceWarning)) ?? def.deepseekBalanceWarning
        let rawDsCritical = (try? c.decode(Double.self, forKey: .deepseekBalanceCritical)) ?? def.deepseekBalanceCritical

        let validWarning = (rawWarning.isFinite && rawWarning >= 0 && rawWarning <= 100) ? rawWarning : def.apiQuotaWarningPercent
        let validCritical = (rawCritical.isFinite && rawCritical >= 0 && rawCritical <= 100) ? rawCritical : def.apiQuotaCriticalPercent
        let validDsWarning = (rawDsWarning.isFinite && rawDsWarning >= 0) ? rawDsWarning : def.deepseekBalanceWarning
        let validDsCritical = (rawDsCritical.isFinite && rawDsCritical >= 0) ? rawDsCritical : def.deepseekBalanceCritical

        apiQuotaWarningPercent = validWarning
        apiQuotaCriticalPercent = min(validCritical, validWarning)
        deepseekBalanceWarning = validDsWarning
        deepseekBalanceCritical = min(validDsCritical, validDsWarning)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiQuotaWarningPercent, forKey: .apiQuotaWarningPercent)
        try c.encode(apiQuotaCriticalPercent, forKey: .apiQuotaCriticalPercent)
        try c.encode(deepseekBalanceWarning, forKey: .deepseekBalanceWarning)
        try c.encode(deepseekBalanceCritical, forKey: .deepseekBalanceCritical)
    }

    /// 计算百分比配额的健康度（时间感知分母 = 100% * timeFraction）
    func colorLevel(percent: Double, timeFraction: Double?) -> HealthLevel {
        ModelQuota.colorLevel(
            percent: percent,
            timeFraction: timeFraction,
            warningPercent: apiQuotaWarningPercent,
            criticalPercent: apiQuotaCriticalPercent
        )
    }

    /// 计算 DeepSeek 纯余额健康度
    func deepseekHealthLevel(balance: Double?) -> HealthLevel {
        guard let balance else { return .critical }
        if balance <= 0 || balance < deepseekBalanceCritical {
            return .critical
        } else if balance < deepseekBalanceWarning {
            return .warning
        } else {
            return .healthy
        }
    }
}

// MARK: - Bark Notification Config

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

// MARK: - 外观（2.0）

/// 应用外观：浅色 / 深色 / 自动（跟随系统，缺省）。写进 `NSApp.appearance`，
/// 对设置窗与所有 SwiftUI 面板生效；菜单栏 MenubarExtra 的原生样式仍随系统。
enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .auto: return "自动"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}

// MARK: - Fleet Sync Config（多机联动，2.0）

/// 多机联动配置。`enabled` 缺省 false → 现有用户零影响；`hubURL` 空 = 本机是
/// 主节点（hub），非空 = 副节点（node，且不监听端口）。角色由 `SyncRole.derive`
/// 单源派生，没有第二条路径。
///
/// 解码逐字段容错（与 `BarkConfig` 同档）：手改坏单个字段只回退该字段默认值，
/// 不拖垮整份配置；`nodeName` 是机器显示名（默认 hostname）；稳定设备身份
/// 单独存放在配置目录的 `.deviceId`，不属于可同步配置。
struct SyncConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    /// 副节点：主节点地址（`http://<主节点IP>:8787`）；留空 = 本机是主节点。
    var hubURL: String
    /// 上报周期（秒），默认 0 表示跟随全局刷新间隔。
    var pushIntervalSeconds: Int
    /// 主节点监听地址，默认 `0.0.0.0`（局域网）；可改 `127.0.0.1` 限本机。
    var hubBindHost: String
    /// 主节点监听端口，默认 8787。
    var hubPort: Int
    /// 空 = 用 hostname。
    var nodeName: String
    /// 超过该时长未上报的节点标 stale（默认 15 分钟）。
    var staleAfterSeconds: Int
    /// 副节点来源额度超过该时长标「额度已过期」（默认 30 分钟）。
    var quotaMaxAgeSeconds: Int
    /// hub 保留多少天的历史日桶 / 窗口范围。
    var retainDays: Int
    static let `default` = SyncConfig(
        enabled: false,
        hubURL: "",
        pushIntervalSeconds: 0,
        hubBindHost: "0.0.0.0",
        hubPort: 8787,
        nodeName: "",
        staleAfterSeconds: 900,
        quotaMaxAgeSeconds: 1800,
        retainDays: 7
    )

    private enum CodingKeys: String, CodingKey {
        case enabled, hubURL, pushIntervalSeconds, hubBindHost, hubPort
        case nodeName, staleAfterSeconds, quotaMaxAgeSeconds, retainDays
    }

    init(
        enabled: Bool = false,
        hubURL: String = "",
        pushIntervalSeconds: Int = 0,
        hubBindHost: String = "0.0.0.0",
        hubPort: Int = 8787,
        nodeName: String = "",
        staleAfterSeconds: Int = 900,
        quotaMaxAgeSeconds: Int = 1800,
        retainDays: Int = 7
    ) {
        self.enabled = enabled
        self.hubURL = hubURL
        self.pushIntervalSeconds = pushIntervalSeconds
        self.hubBindHost = hubBindHost
        self.hubPort = hubPort
        self.nodeName = nodeName
        self.staleAfterSeconds = staleAfterSeconds
        self.quotaMaxAgeSeconds = quotaMaxAgeSeconds
        self.retainDays = retainDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        hubURL = (try? c.decode(String.self, forKey: .hubURL)) ?? ""
        pushIntervalSeconds = Self.clamped(
            (try? c.decode(Int.self, forKey: .pushIntervalSeconds)) ?? 0,
            range: 0...(24 * 60 * 60), fallback: 0
        )
        hubBindHost = (try? c.decode(String.self, forKey: .hubBindHost)) ?? "0.0.0.0"
        hubPort = Self.clamped(
            (try? c.decode(Int.self, forKey: .hubPort)) ?? 8787,
            range: 1...65535, fallback: 8787
        )
        nodeName = (try? c.decode(String.self, forKey: .nodeName)) ?? ""
        staleAfterSeconds = Self.clamped(
            (try? c.decode(Int.self, forKey: .staleAfterSeconds)) ?? 900,
            range: 60...(30 * 24 * 60 * 60), fallback: 900
        )
        quotaMaxAgeSeconds = Self.clamped(
            (try? c.decode(Int.self, forKey: .quotaMaxAgeSeconds)) ?? 1800,
            range: 60...(30 * 24 * 60 * 60), fallback: 1800
        )
        retainDays = Self.clamped(
            (try? c.decode(Int.self, forKey: .retainDays)) ?? 7,
            range: 1...365, fallback: 7
        )
    }

    /// 默认节点显示名：hostname。
    static func defaultNodeName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func clamped(_ value: Int, range: ClosedRange<Int>, fallback: Int) -> Int {
        range.contains(value) ? value : fallback
    }

    /// 生效的主节点地址：去空白；空串保持空（= hub 角色）。
    var effectiveHubURL: String {
        hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生效的节点显示名：空 = hostname（由调用方解析）。
    var effectiveNodeName: String {
        nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - App Config

struct AppConfig: Codable, Equatable {
    /// 当前配置 schema。缺失该字段的历史配置按 schema 0 解码并规范化到当前版本；
    /// 旧版 clientBindings 与 provider-level OpenCode 归因开关已移除，解码时忽略；
    /// schema 3 新增多机联动 `sync` 配置节。
    static let currentSchemaVersion = 3
    /// 防止手工配置的极大整数经过 `TimeInterval` 转换后无法安全转回 `Int`，
    /// 同时避免一次拼写错误让 provider 实际上永久停止刷新。
    static let maximumRefreshIntervalSeconds = 30 * 24 * 60 * 60

    let schemaVersion: Int

    /// 全局刷新间隔（秒）
    var refreshIntervalSeconds: Int

    /// 各 provider 配置（key = providerID）
    var providers: [String: ProviderConfig]

    /// 内置自动归因路由的运行时快照，不再读写 config.json。
    /// 保留此属性供状态宿主与 Fleet 归因指纹使用，不是用户可选开关。
    var clientBindings: [ClientProviderBinding] { Self.defaultClientBindings }

    /// 状态栏图标风格 (nil = 默认 chartBar)
    var statusBarIconStyle: StatusBarIconStyle?

    /// 是否显示状态栏健康度圆点 (nil = 默认开启)
    var statusBarHealthDotEnabled: Bool?

    /// 状态栏健康度圆点颜色 (nil = 默认绿 / 黄 / 红)
    var statusBarHealthColors: StatusBarHealthColors?

    /// 本机系统通知是否播放默认提示音（nil = 开启）。此设置保存在本机 config.json，
    /// 不属于 Fleet 配额快照或节点同步内容。
    var systemNotificationSoundEnabled: Bool?

    /// 主菜单 Provider 卡片的自定义顺序。nil 或空数组表示使用默认的
    /// Provider 显示名称字母顺序；这里只保存 canonical QuotaProviderID，不保存显示名。
    var providerCardOrder: [String]?

    /// 状态栏小眼睛锚定的 Provider ID（nil 表示全 Provider 聚合，非零最小值）。
    var statusBarPinnedProvider: String?

    /// Bark 推送配置。nil 或 enabled=false 都表示不推送。
    var bark: BarkConfig?

    /// 屏幕边缘状态窗配置。nil 与 `mode = .hidden` 都表示不显示。
    /// 与 statusBar* 同为纯外观字段，手改出错按缺失处理，不进损坏恢复流程。
    var edgeDock: EdgeDockConfig?

    /// 应用外观（浅色 / 深色 / 自动）。缺省（nil）= 自动跟随系统。
    var appearance: AppAppearance?

    /// 法定节假日数据源（URL 或本地文件路径），供 `HolidayCalendar` 解析链取数。
    /// nil（缺省）= 上游 chinese-days CDN JSON（`HolidayCalendar.defaultSourceURL`，
    /// 与 `scripts/sync-holiday-data.sh` 的 `UPSTREAM_URL` 同值）；显式空串 =
    /// 只用随 App 打包的内置快照、不联网。类型写错按缺失处理（缺省语义）。
    var holidaySource: String?

    /// 多机联动配置。nil（未配置）或 `enabled=false` 都表示不参与联动，
    /// 现有用户零影响；坏值按缺失处理。
    var sync: SyncConfig?

    /// 集中告警阈值配置（nil = 默认阈值：API 60%/30%，DeepSeek 10/3）
    var alerts: AlertThresholdConfig?

    /// 次要信息刷新周期相对 Provider 刷新间隔的倍率（默认 20 倍）。
    /// 沿用 periodicFullEveryN 配置键；每 N 拍刷新中有一拍抓取次要信息，1 倍即每拍抓取。
    /// 影响范围：
    /// 1. Provider 刷新调度器：连续 N-1 次 background 后切换为 full 模式；
    /// 2. Codex 重置次数（reset-credits）抓取时机与陈旧度容忍阈值（max(3 × N × interval, 15m)）；
    /// 3. GLM ZCode 额度重置卡（5h/周卡）接口查询频率；
    /// 4. GLM ZCode 运营活动营销触达接口轮询频率（在开启通知时生效）。
    /// 5. Antigravity 独立账号/套餐 RPC 与 Codex Admin API 组织标题查询。
    static let defaultPeriodicFullEveryN: Int = 20
    static let periodicFullEveryNRange: ClosedRange<Int> = 1...30

    var periodicFullEveryN: Int?

    var effectivePeriodicFullEveryN: Int {
        let value = periodicFullEveryN ?? Self.defaultPeriodicFullEveryN
        return min(max(value, Self.periodicFullEveryNRange.lowerBound), Self.periodicFullEveryNRange.upperBound)
    }

    var effectiveAlertThresholds: AlertThresholdConfig {
        alerts ?? .default
    }

    var effectiveStatusBarIconStyle: StatusBarIconStyle {
        statusBarIconStyle ?? .chartBar
    }

    /// 边缘窗配置归一化后再交给几何层：手改 `"offset": 42` 不该产生一个
    /// 永远画在屏幕外、再也拖不回来的窗口。
    var effectiveEdgeDockConfig: EdgeDockConfig {
        (edgeDock ?? .default).normalized
    }

    var effectiveStatusBarHealthDotEnabled: Bool {
        statusBarHealthDotEnabled ?? true
    }

    var effectiveStatusBarHealthColors: StatusBarHealthColors {
        statusBarHealthColors ?? .default
    }

    var effectiveSystemNotificationSoundEnabled: Bool {
        systemNotificationSoundEnabled ?? true
    }

    /// 生效的节假日数据源字符串：缺省（nil）= 上游 chinese-days CDN URL；
    /// 显式空串原样返回（`HolidayCalendar.parseSource` 把它判为「仅内置快照」）。
    var effectiveHolidaySource: String {
        holidaySource ?? HolidayCalendar.defaultSourceURL
    }

    /// 生效外观：缺省自动跟随系统。
    var effectiveAppearance: AppAppearance {
        appearance ?? .auto
    }

    /// 生效的多机联动配置：未配置 = 关闭态默认值。
    var effectiveSyncConfig: SyncConfig {
        sync ?? .default
    }

    static let `default` = AppConfig(
        refreshIntervalSeconds: 300,
        providers: [:],
        providerCardOrder: nil
    )

    /// 默认 client → quota 绑定注册表（**兼容再导出**）。
    ///
    /// 事实源已迁到身份模块 `ClientProviderBinding.defaultBindings`（Models 层，
    /// 不反向依赖任何 Services / 配置类型）：绑定字面量与
    /// `defaultSourceProviderAliases(clientID:quotaProviderID:)` 都在那里。本别名
    /// 保留状态宿主、Fleet 指纹与旧内部调用点的只读兼容出口。
    static let defaultClientBindings: [ClientProviderBinding] = ClientProviderBinding.defaultBindings

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
        statusBarIconStyle: StatusBarIconStyle? = nil,
        statusBarHealthDotEnabled: Bool? = nil,
        statusBarHealthColors: StatusBarHealthColors? = nil,
        systemNotificationSoundEnabled: Bool? = nil,
        providerCardOrder: [String]? = nil,
        statusBarPinnedProvider: String? = nil,
        bark: BarkConfig? = nil,
        edgeDock: EdgeDockConfig? = nil,
        holidaySource: String? = nil,
        appearance: AppAppearance? = nil,
        sync: SyncConfig? = nil,
        alerts: AlertThresholdConfig? = nil,
        periodicFullEveryN: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.providers = providers
        self.statusBarIconStyle = statusBarIconStyle
        self.statusBarHealthDotEnabled = statusBarHealthDotEnabled
        self.statusBarHealthColors = statusBarHealthColors
        self.systemNotificationSoundEnabled = systemNotificationSoundEnabled
        self.providerCardOrder = providerCardOrder
        self.statusBarPinnedProvider = statusBarPinnedProvider
        self.bark = bark
        self.edgeDock = edgeDock
        self.holidaySource = holidaySource
        self.appearance = appearance
        self.sync = sync
        self.alerts = alerts
        self.periodicFullEveryN = periodicFullEveryN
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, refreshIntervalSeconds, providers
        case statusBarIconStyle, statusBarHealthDotEnabled
        case statusBarHealthColors
        case systemNotificationSoundEnabled
        case providerCardOrder
        case statusBarPinnedProvider
        case bark
        case edgeDock
        case holidaySource
        case appearance
        case sync
        case alerts
        case periodicFullEveryN
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // schemaVersion 缺失代表首个无版本配置格式；历史归因开关一律忽略。
        let sourceVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard (0...Self.currentSchemaVersion).contains(sourceVersion) else {
            throw SchemaError.unsupportedVersion(sourceVersion)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.refreshIntervalSeconds = try container.decode(Int.self, forKey: .refreshIntervalSeconds)
        self.providers = try container.decode([String: ProviderConfig].self, forKey: .providers)
        // 这些字段只影响图标外观，不应因手工拼写错误或新版本增加枚举值而让
        // 整份 provider 配置进入损坏恢复流程。未知值和类型不匹配均按缺失处理。
        //
        // 记一条告警：静默回落的外观（图标样式、健康点、卡片顺序、节假日源）
        // 排障时看不到任何线索——用户只看到「dock 回到默认位置」「节假日按
        // 官方数据算」，日志里却干干净净。与 edgeDock / bark 同一档记录。
        do {
            self.statusBarIconStyle = (try container.decodeIfPresent(String.self, forKey: .statusBarIconStyle))
                .flatMap(StatusBarIconStyle.init(rawValue:))
        } catch {
            logWarn("[config] statusBarIconStyle 字段解析失败，已按缺省处理：\(error.localizedDescription)")
            self.statusBarIconStyle = nil
        }
        do {
            self.statusBarHealthDotEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .statusBarHealthDotEnabled
            )
        } catch {
            logWarn("[config] statusBarHealthDotEnabled 字段解析失败，已按缺省处理：\(error.localizedDescription)")
            self.statusBarHealthDotEnabled = nil
        }
        do {
            self.statusBarHealthColors = try container.decodeIfPresent(
                StatusBarHealthColors.self,
                forKey: .statusBarHealthColors
            )
        } catch {
            logWarn("[config] statusBarHealthColors 字段解析失败，已按缺省处理：\(error.localizedDescription)")
            self.statusBarHealthColors = nil
        }
        do {
            self.systemNotificationSoundEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .systemNotificationSoundEnabled
            )
        } catch {
            logWarn("[config] systemNotificationSoundEnabled 字段解析失败，已按默认开启处理：\(error.localizedDescription)")
            self.systemNotificationSoundEnabled = nil
        }
        do {
            self.providerCardOrder = try container.decodeIfPresent([String].self, forKey: .providerCardOrder)
        } catch {
            logWarn("[config] providerCardOrder 字段解析失败，已按缺省处理：\(error.localizedDescription)")
            self.providerCardOrder = nil
        }
        do {
            self.statusBarPinnedProvider = try container.decodeIfPresent(String.self, forKey: .statusBarPinnedProvider)
        } catch {
            logWarn("[config] statusBarPinnedProvider 字段解析失败，已按未配置处理：\(error.localizedDescription)")
            self.statusBarPinnedProvider = nil
        }
        // 边缘窗同属外观字段：坏值按"没配过"处理，不能拖垮整份 provider 配置。
        //
        // 记一条告警：静默重置的位置/形态是排障噩梦——用户看到的是 dock 莫名回到
        // 默认位置，而日志里什么都没有。Bark 那边同样有这层记录。
        do {
            self.edgeDock = try container.decodeIfPresent(EdgeDockConfig.self, forKey: .edgeDock)
        } catch {
            logWarn("[config] edgeDock 字段解析失败，已按未配置处理：\(error.localizedDescription)")
            self.edgeDock = nil
        }
        // Bark 字段手工配置容错：类型不匹配按缺失处理，不进损坏恢复流程；
        // 但 serverURL / deviceKey 等必填 key 缺失会让整块配置失效，记录告警。
        do {
            self.bark = try container.decodeIfPresent(BarkConfig.self, forKey: .bark)
        } catch {
            logWarn("[config] bark 字段解析失败，已按未配置处理：\(error.localizedDescription)")
            self.bark = nil
        }
        // 节假日数据源与外观字段同一容错档：类型写错按缺省（上游 CDN）处理，
        // 但要记告警——源静默回退 CDN 时用户只会看到「节假日不对」，无从查起。
        // 显式空串会被原样保留（语义 = 只用内置快照、不联网）。
        do {
            self.holidaySource = try container.decodeIfPresent(String.self, forKey: .holidaySource)
        } catch {
            logWarn("[config] holidaySource 字段解析失败，已按缺省（上游 CDN）处理：\(error.localizedDescription)")
            self.holidaySource = nil
        }
        self.appearance = (try? container.decode(String.self, forKey: .appearance))
            .flatMap(AppAppearance.init(rawValue:))
        // 多机联动：坏值按未配置处理，不进损坏恢复流程——配置损坏不应让一个
        // 纯增量功能的缺失拖垮整份 provider 配置。
        do {
            self.sync = try container.decodeIfPresent(SyncConfig.self, forKey: .sync)
        } catch {
            logWarn("[config] sync 字段解析失败，已按未配置处理：\(error.localizedDescription)")
            self.sync = nil
        }
        do {
            self.alerts = try container.decodeIfPresent(AlertThresholdConfig.self, forKey: .alerts)
        } catch {
            logWarn("[config] alerts 字段解析失败，已按缺省阈值处理：\(error.localizedDescription)")
            self.alerts = nil
        }
        do {
            self.periodicFullEveryN = try container.decodeIfPresent(Int.self, forKey: .periodicFullEveryN)
        } catch {
            logWarn("[config] periodicFullEveryN 字段解析失败，已按缺省处理：\(error.localizedDescription)")
            self.periodicFullEveryN = nil
        }
    }

    /// 全局生效的刷新间隔：clamp 到 10s...30d（供 Provider scheduler 使用）。
    var effectiveGlobalRefreshInterval: TimeInterval {
        TimeInterval(min(max(refreshIntervalSeconds, 10), Self.maximumRefreshIntervalSeconds))
    }

    /// Fleet node 的唯一有效推送周期入口。配置为 0 时跟随全局刷新周期；
    /// 正值保留秒级设置，并限制在配置允许的 24 小时范围内。
    var effectiveFleetSyncPushInterval: TimeInterval {
        let configured = effectiveSyncConfig.pushIntervalSeconds
        if configured == 0 { return effectiveGlobalRefreshInterval }
        return TimeInterval(min(max(configured, 1), 24 * 60 * 60))
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

}

// MARK: - Provider Config

/// 历史 GLM 认证方式，仅用于兼容旧配置与调用；当前使用必填 API Key 与可选 JWT 扩展。
enum GlmAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey = "apiKey"
    case credential = "credential"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .credential: return "ZCode 凭证"
        }
    }
}

/// 单个 provider 的配置
///
/// 所有字段除 `enabled` 外都是 optional。nil 字段在 JSON 里**完全不写**，
/// 让配置文件保持干净——只展示当前 provider 真正关心的字段。
struct ProviderConfig: Codable, Equatable {
    /// 是否启用（false 则不抓取、UI 状态胶囊显示「未配置」）
    var enabled: Bool

    /// API Key（明文，文件权限 0600）。某些 provider（如 codex）从外部 auth.json 读，传 nil
    var apiKey: String?

    /// 显示名（可选，覆盖默认名）
    var displayName: String?

    /// 该 provider 自己的刷新间隔（秒）。nil = 用全局 config.refreshIntervalSeconds
    var refreshIntervalSeconds: Int?

    /// 自管 auth 的 fetcher 用：auth 路径（如 codex 的 ~/.codex/auth.json 或 GLM 的 ~/.zcode/v2）
    var authPath: String?

    /// 历史认证方式（apiKey / credential），不再控制运行时；设置保存时移除。
    var glmAuthMode: GlmAuthMode?

    /// 是否启用 ZCode JWT 附加数据（活动套餐、重置卡、营销活动）。
    /// nil 时兼容旧 glmAuthMode / parseZcode* 字段；显式 false 优先并关闭附加查询。
    var zcodeJWTEnabled: Bool?

    /// 历史日志解析开关，仅用于兼容旧配置并迁移 JWT 扩展开关。
    var parseZcodeBalanceLog: Bool?

    /// 历史套餐解析开关，仅保留旧配置兼容。
    var parseZcodePlan: Bool?

    /// 历史凭据解析开关，仅用于兼容旧配置并迁移 JWT 扩展开关。
    var parseZcodeCredential: Bool?

    /// ZCode 运营活动推送通知渠道（none / system / barkAndSystem）
    var notifyCampaign: QuotaNotifyChannel?

    /// 兼容旧配置迁移的认证方式解析结果；不控制主额度认证。
    var effectiveGlmAuthMode: GlmAuthMode {
        if let glmAuthMode { return glmAuthMode }
        if (parseZcodeCredential ?? parseZcodePlan ?? parseZcodeBalanceLog ?? false) {
            return .credential
        }
        return .apiKey
    }

    /// 是否启用 ZCode JWT 附加查询。新字段显式值优先，旧配置按原设置迁移。
    var isZcodeCredentialEnabled: Bool {
        if let zcodeJWTEnabled { return zcodeJWTEnabled }
        return effectiveGlmAuthMode == .credential
    }

    /// 兼容历史计算属性：是否启用 ZCode 套餐解析
    var isZcodePlanEnabled: Bool {
        isZcodeCredentialEnabled
    }

    /// 四类额度事件的通知渠道（5 小时 / 周额度 × 恢复 / 耗尽）。
    /// nil（字段不存在）= 使用默认渠道（恢复 → 系统通知，耗尽 → 不通知），
    /// 与引入通知配置前的行为一致。
    var notifyIntervalRestored: QuotaNotifyChannel?
    var notifyIntervalExhausted: QuotaNotifyChannel?
    var notifyWeeklyRestored: QuotaNotifyChannel?
    var notifyWeeklyExhausted: QuotaNotifyChannel?

    /// 是否启用 OpenAI API 赠金监测（ChatGPT 专用）
    var adminApiCreditsEnabled: Bool?

    /// OpenAI Admin API Key (sk-admin-...)
    var adminApiKey: String?

    /// 每月账单日（1-31）
    var adminBillingDay: Int?

    /// 账单重置时间（"HH:mm"，如 "08:00"）
    var adminBillingTime: String?

    /// 每月 API 赠金额度上限（美元，如 40.0）
    var adminMonthlyQuotaLimit: Double?

    enum CodingKeys: String, CodingKey {
        case enabled, apiKey, displayName, refreshIntervalSeconds, authPath
        case glmAuthMode, zcodeJWTEnabled
        case parseZcodeBalanceLog
        case parseZcodePlan
        case parseZcodeCredential
        case notifyCampaign
        case notifyIntervalRestored, notifyIntervalExhausted
        case notifyWeeklyRestored, notifyWeeklyExhausted
        case adminApiCreditsEnabled
        case adminApiKey
        case adminBillingDay
        case adminBillingTime
        case adminMonthlyQuotaLimit
    }

    init(enabled: Bool = true,
         apiKey: String? = nil,
         displayName: String? = nil,
         refreshIntervalSeconds: Int? = nil,
         authPath: String? = nil,
         glmAuthMode: GlmAuthMode? = nil,
         zcodeJWTEnabled: Bool? = nil,
         parseZcodeBalanceLog: Bool? = nil,
         parseZcodePlan: Bool? = nil,
         parseZcodeCredential: Bool? = nil,
         notifyCampaign: QuotaNotifyChannel? = nil,
         notifyIntervalRestored: QuotaNotifyChannel? = nil,
         notifyIntervalExhausted: QuotaNotifyChannel? = nil,
         notifyWeeklyRestored: QuotaNotifyChannel? = nil,
         notifyWeeklyExhausted: QuotaNotifyChannel? = nil,
         adminApiCreditsEnabled: Bool? = nil,
         adminApiKey: String? = nil,
         adminBillingDay: Int? = nil,
         adminBillingTime: String? = nil,
         adminMonthlyQuotaLimit: Double? = nil) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.displayName = displayName
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.authPath = authPath
        self.glmAuthMode = glmAuthMode
        self.zcodeJWTEnabled = zcodeJWTEnabled
        self.parseZcodeBalanceLog = parseZcodeBalanceLog
        self.parseZcodePlan = parseZcodePlan
        self.parseZcodeCredential = parseZcodeCredential
        self.notifyCampaign = notifyCampaign
        self.notifyIntervalRestored = notifyIntervalRestored
        self.notifyIntervalExhausted = notifyIntervalExhausted
        self.notifyWeeklyRestored = notifyWeeklyRestored
        self.notifyWeeklyExhausted = notifyWeeklyExhausted
        self.adminApiCreditsEnabled = adminApiCreditsEnabled
        self.adminApiKey = adminApiKey
        self.adminBillingDay = adminBillingDay
        self.adminBillingTime = adminBillingTime
        self.adminMonthlyQuotaLimit = adminMonthlyQuotaLimit
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
        self.glmAuthMode = (try? c.decode(String.self, forKey: .glmAuthMode))
            .flatMap(GlmAuthMode.init(rawValue:))
        self.zcodeJWTEnabled = try c.decodeIfPresent(Bool.self, forKey: .zcodeJWTEnabled)
        self.parseZcodeBalanceLog = try c.decodeIfPresent(Bool.self, forKey: .parseZcodeBalanceLog)
        self.parseZcodePlan = try c.decodeIfPresent(Bool.self, forKey: .parseZcodePlan)
        self.parseZcodeCredential = try c.decodeIfPresent(Bool.self, forKey: .parseZcodeCredential)
        self.notifyCampaign = (try? c.decode(String.self, forKey: .notifyCampaign))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        // 渠道枚举值写错时按缺失处理，不让整份配置进入损坏恢复流程。
        self.notifyIntervalRestored = (try? c.decode(String.self, forKey: .notifyIntervalRestored))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyIntervalExhausted = (try? c.decode(String.self, forKey: .notifyIntervalExhausted))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyWeeklyRestored = (try? c.decode(String.self, forKey: .notifyWeeklyRestored))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.notifyWeeklyExhausted = (try? c.decode(String.self, forKey: .notifyWeeklyExhausted))
            .flatMap(QuotaNotifyChannel.init(rawValue:))
        self.adminApiCreditsEnabled = try c.decodeIfPresent(Bool.self, forKey: .adminApiCreditsEnabled)
        self.adminApiKey = try c.decodeIfPresent(String.self, forKey: .adminApiKey)
        self.adminBillingDay = try c.decodeIfPresent(Int.self, forKey: .adminBillingDay)
        self.adminBillingTime = try c.decodeIfPresent(String.self, forKey: .adminBillingTime)
        self.adminMonthlyQuotaLimit = try c.decodeIfPresent(Double.self, forKey: .adminMonthlyQuotaLimit)
    }
}

extension ProviderConfig {
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
}
