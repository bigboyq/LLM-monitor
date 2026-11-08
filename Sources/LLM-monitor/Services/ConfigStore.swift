import Foundation
import Combine
import AppKit

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
