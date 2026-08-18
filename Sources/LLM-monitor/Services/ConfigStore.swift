import Foundation
import Combine
import AppKit

/// 状态栏图标主题样式
enum StatusBarIconStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case chartBar = "chartBar"
    case sparkles = "sparkles"
    case brain = "brain"
    case cpu = "cpu"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chartBar: return "柱状图"
        case .sparkles: return "AI 星光"
        case .brain:    return "智能大脑"
        case .cpu:      return "芯片"
        }
    }

    var systemImageName: String {
        switch self {
        case .chartBar: return "chart.bar.fill"
        case .sparkles: return "sparkles"
        case .brain:    return "brain.head.profile"
        case .cpu:      return "cpu.fill"
        }
    }
}

/// 状态栏健康度指示模式
enum StatusBarIndicatorMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case colored = "colored"
    case monochrome = "monochrome"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colored:    return "健康度着色"
        case .monochrome: return "单色模版"
        }
    }
}

/// 应用配置 — 从 ~/Library/Application Support/LLM-monitor/config.json 读
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

    /// 状态栏指示模式 (nil = 默认 colored)
    var statusBarIndicatorMode: StatusBarIndicatorMode?

    /// 是否显示状态栏健康度圆点 (nil = 默认开启)
    var statusBarHealthDotEnabled: Bool?

    /// 主菜单 Provider 卡片的自定义顺序。nil 或空数组表示使用默认的
    /// Provider 显示名称字母顺序；这里只保存 canonical QuotaProviderID，不保存显示名。
    var providerCardOrder: [String]?

    var effectiveStatusBarIconStyle: StatusBarIconStyle {
        statusBarIconStyle ?? .chartBar
    }

    var effectiveStatusBarIndicatorMode: StatusBarIndicatorMode {
        statusBarIndicatorMode ?? .colored
    }

    var effectiveStatusBarHealthDotEnabled: Bool {
        statusBarHealthDotEnabled ?? true
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
        statusBarIndicatorMode: StatusBarIndicatorMode? = nil,
        statusBarHealthDotEnabled: Bool? = nil,
        providerCardOrder: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.providers = providers
        self.clientBindings = clientBindings
        self.statusBarIconStyle = statusBarIconStyle
        self.statusBarIndicatorMode = statusBarIndicatorMode
        self.statusBarHealthDotEnabled = statusBarHealthDotEnabled
        self.providerCardOrder = providerCardOrder
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, refreshIntervalSeconds, providers, clientBindings
        case statusBarIconStyle, statusBarIndicatorMode, statusBarHealthDotEnabled
        case providerCardOrder
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
        self.statusBarIndicatorMode = (try? container.decode(String.self, forKey: .statusBarIndicatorMode))
            .flatMap(StatusBarIndicatorMode.init(rawValue:))
        self.statusBarHealthDotEnabled = try? container.decode(Bool.self, forKey: .statusBarHealthDotEnabled)
        self.providerCardOrder = try? container.decode([String].self, forKey: .providerCardOrder)
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

    /// DeepSeek 高峰期是否仅工作日（周一–周五，周末全天平价）。nil = 默认 true
    var deepseekPeakWeekdaysOnly: Bool?

    /// 是否把对应的 OpenCode provider 用量合并到菜单栏卡片。
    /// nil = 使用 provider 的默认值：GLM 默认开启，其余 provider 默认关闭。
    var mergeOpencodeUsage: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled, apiKey, displayName, refreshIntervalSeconds, authPath
        case peakStartHour, peakEndHour, peakWeekdaysOnly, mergeOpencodeUsage
        case deepseekPeakWeekdaysOnly
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
         deepseekPeakWeekdaysOnly: Bool? = nil) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.displayName = displayName
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.authPath = authPath
        self.peakStartHour = peakStartHour
        self.peakEndHour = peakEndHour
        self.peakWeekdaysOnly = peakWeekdaysOnly
        self.mergeOpencodeUsage = mergeOpencodeUsage
        self.deepseekPeakWeekdaysOnly = deepseekPeakWeekdaysOnly
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
        self.deepseekPeakWeekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .deepseekPeakWeekdaysOnly)
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

    /// 解析为 DeepSeek 高峰期窗口。nil 字段回退官方默认（9–12 & 14–18 / 仅工作日）。
    var deepseekPeakWindow: DeepseekPeakWindow {
        let d = DeepseekPeakWindow.defaultWindow
        let weekdays = deepseekPeakWeekdaysOnly ?? d.weekdaysOnly
        return DeepseekPeakWindow(slots: d.slots, weekdaysOnly: weekdays)
    }
}

/// 配置文件读写 + 文件变化监听
@MainActor
final class ConfigStore: ObservableObject {
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
