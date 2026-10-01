import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 配置模板与描述符对齐、`applyAndSave` 持久化阻塞，以及 `FileManagerBox` 的访问约束。对应 `ConfigStore`。
final class ConfigStoreTests: StateTestCase {

    // MARK: - FileManagerBox 访问约束
    /// 运行时验证 `FileManagerBox` 持有 `fileManager: FileManager` 字段。
    /// 防止有人把字段 rename 掉而不改 wrapper API（如果 rename 了 `fileManager`
    /// 字段但忘了同步更新 wrapper，type-level 检查会过但 runtime 行为会断）。
    /// 编译期验证 `fileManager` 必须是 `private` 没法用 Mirror（Mirror 能
    /// 看到 private 字段），但 `Tests/AccessCheck.swift` 提供了 tripwire：
    /// 取消注释 `_ = box.fileManager` 跑 `swift build --build-tests` 应该
    /// 失败（`'fileManager' is inaccessible due to 'private' protection level`）。
    func testFileManagerBoxFileManagerFieldExists() {
        let box = FileManagerBox()
        let mirror = Mirror(reflecting: box)
        let hasFileManagerField = mirror.children.contains { child in
            child.label == "fileManager" && child.value is FileManager
        }
        XCTAssertTrue(hasFileManagerField, "FileManagerBox 应该有 fileManager 字段")
    }
    // MARK: - Config Store Template & Descriptor Alignment Tests
    @MainActor
    func testConfigStoreTemplateMatchesAllDescriptors() {
        let templateKeys = Set(ConfigStore.templateProviders().keys)
        let descriptorIDs = Set(LLMMonitorApp.makeDescriptors().map(\.id))
        XCTAssertEqual(templateKeys, descriptorIDs)

        for descriptor in LLMMonitorApp.makeDescriptors() {
            XCTAssertEqual(descriptor.id, descriptor.kind.providerID)
        }

        let descriptorKinds = Set(LLMMonitorApp.makeDescriptors().map(\.kind))
        XCTAssertEqual(descriptorKinds, Set(ProviderKind.allCases))
    }
    @MainActor
    func testConfigStoreTemplateStartsDisabledAndRejectsPlaceholders() {
        let providers = ConfigStore.templateProviders()
        XCTAssertEqual(providers.count, ProviderKind.allCases.count)
        XCTAssertTrue(providers.values.allSatisfy { !$0.enabled })
        XCTAssertNil(providers[ProviderKind.minimaxTokenPlan.providerID]?.usableAPIKey)
        XCTAssertNil(providers[ProviderKind.glmCodingPlan.providerID]?.usableAPIKey)
        XCTAssertNil(providers[ProviderKind.deepseek.providerID]?.usableAPIKey)
        XCTAssertEqual(
            providers[ProviderKind.codexChatGpt.providerID]?.authPath,
            "~/.codex/auth.json"
        )
    }
    @MainActor
    func testConfigStoreEnsureProvidersPresentRestoresMissingDescriptorEntries() throws {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.providers.removeValue(forKey: ProviderKind.glmCodingPlan.providerID)
        config.providers.removeValue(forKey: ProviderKind.antigravity.providerID)
        try store.applyAndSave(config)

        XCTAssertTrue(store.ensureProvidersPresent(descriptors: LLMMonitorApp.makeDescriptors()))
        XCTAssertEqual(
            Set(store.config.providers.keys),
            Set(ProviderKind.allCases.map(\.providerID))
        )
        XCTAssertFalse(store.config.providers[ProviderKind.glmCodingPlan.providerID]?.enabled ?? true)
        XCTAssertFalse(store.config.providers[ProviderKind.antigravity.providerID]?.enabled ?? true)
    }
    @MainActor
    func testConfigStoreLoadsLegacyConfigWithCodableDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-legacy-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "refreshIntervalSeconds": 120,
          "providers": {
            "minimax_token_plan": {
              "enabled": true,
              "apiKey": "sk-cp-legacy-real-key"
            }
          }
        }
        """
        try Data(legacyJSON.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.config.refreshIntervalSeconds, 120)
        XCTAssertEqual(store.config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(
            store.config.providers[ProviderKind.minimaxTokenPlan.providerID]?.apiKey,
            "sk-cp-legacy-real-key"
        )
        XCTAssertNil(store.config.providers[ProviderKind.minimaxTokenPlan.providerID]?.authPath)
        XCTAssertTrue(store.ensureProvidersPresent(descriptors: LLMMonitorApp.makeDescriptors()))
        XCTAssertEqual(store.config.providers.count, ProviderKind.allCases.count)
    }
    @MainActor
    func testAppInstanceLockAllowsOnlyOneOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")

        do {
            let first = AppInstanceLock.acquire(at: lockURL)
            XCTAssertNotNil(first)
            XCTAssertNil(AppInstanceLock.acquire(at: lockURL))
        }

        XCTAssertNotNil(AppInstanceLock.acquire(at: lockURL))
    }
    @MainActor
    func testAppInstanceLockResultDistinguishesContentionFromFilesystemFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-result-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .acquired(let firstLock) = AppInstanceLock.acquireResult(at: lockURL) else {
            return XCTFail("首个实例应取得锁")
        }
        let contentionResult = withExtendedLifetime(firstLock) {
            AppInstanceLock.acquireResult(at: lockURL)
        }
        guard case .alreadyRunning = contentionResult else {
            return XCTFail("第二个实例应被识别为锁竞争")
        }

        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-lock-parent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        guard case .failed(.createDirectoryFailed) = AppInstanceLock.acquireResult(
            at: parentFile.appendingPathComponent("instance.lock")
        ) else {
            return XCTFail("锁目录创建失败不应伪装成已有实例")
        }
    }
    func testAppConfigSchemaVersionIsWrittenAndFutureVersionIsRejected() throws {
        let config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, AppConfig.currentSchemaVersion)

        let futureJSON = """
        {
          "schemaVersion": 999,
          "refreshIntervalSeconds": 300,
          "providers": {}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: futureJSON)) { error in
            XCTAssertEqual(error as? AppConfig.SchemaError, .unsupportedVersion(999))
        }
    }
    @MainActor
    func testConfigStoreDoesNotOverwriteFutureSchemaConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-future-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let futureJSON = Data("""
        {
          "schemaVersion": 999,
          "refreshIntervalSeconds": 300,
          "providers": {}
        }
        """.utf8)
        try futureJSON.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(configURL: url)
        XCTAssertThrowsError(try store.applyAndSave(.default)) { error in
            guard case ConfigStore.PersistenceError.corruptConfigBackupFailed(let thrownURL) = error else {
                return XCTFail("未来 schema 配置必须禁止自动写回，实际错误: \(error)")
            }
            XCTAssertEqual(thrownURL, url)
        }
        XCTAssertEqual(try Data(contentsOf: url), futureJSON)
    }
    @MainActor
    func testAppStateRestoresPersistedLastRefreshTime() throws {
        let store = makeIsolatedConfigStore()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let timestampURL = store.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("last-refresh.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ProviderKind.minimaxTokenPlan.providerID: timestamp])
            .write(to: timestampURL)

        var config = store.config
        config.providers[ProviderKind.minimaxTokenPlan.providerID]?.apiKey = "sk-cp-test-key"
        try store.applyAndSave(config)

        let state = AppState(
            descriptors: LLMMonitorApp.makeDescriptors(),
            configStore: store
        )
        let minimax = try XCTUnwrap(
            state.statuses.first(where: { $0.kind == .minimaxTokenPlan })
        )
        XCTAssertEqual(minimax.lastRefreshedAt, timestamp)
    }
    @MainActor
    func testCorruptConfigIsBackedUpBeforeRecoveryWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-corrupt-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let corruptData = Data("{broken".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: url)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(try Data(contentsOf: url), corruptData)

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("config.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)

        var recovered = store.config
        recovered.refreshIntervalSeconds = 600
        try store.applyAndSave(recovered)
        XCTAssertEqual(store.config.refreshIntervalSeconds, 600)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)), recovered)
    }
    @MainActor
    func testConfigStoreDetectsContentChangeWhenMtimeIsUnchanged() throws {
        let store = makeIsolatedConfigStore()
        let originalMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.configURL.path)[.modificationDate] as? Date
        )
        var changed = store.config
        changed.refreshIntervalSeconds += 1
        let data = try JSONEncoder().encode(changed)

        try data.write(to: store.configURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMtime],
            ofItemAtPath: store.configURL.path
        )

        XCTAssertTrue(
            store.hasChangedSinceLastRead(),
            "配置内容变化不能仅依赖 mtime 精度，否则连续保存可能漏掉 reload"
        )
    }
    @MainActor
    func testAppStateStartAfterStopRestartsConfigWatcher() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()

        let reloadExpectation = expectation(description: "配置 watcher 在重启后继续工作")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer {
            cancellable.cancel()
            state.stop()
        }

        state.start()
        var changed = store.config
        changed.refreshIntervalSeconds += 1
        let data = try JSONEncoder().encode(changed)
        try data.write(to: store.configURL, options: .atomic)

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
    }
    /// 审计降级项复现测试 1：生产写入路径（ConfigStore.persist → FileManagerBox
    /// .writePrivate → 临时文件 + rename）必须触发目录 `.write` watcher 的 reload。
    /// 该测试与 startAfterStop 测试一起，作为“目录 .write 掩码不会错过 rename 替换”
    /// 的 macOS 平台行为证据；若未来 macOS 行为变化导致本测试失败，再改事件模型。
    @MainActor
    func testConfigWatcherCatchesProductionPersistRenameWrite() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.start()
        defer { state.stop() }

        let reloadExpectation = expectation(description: "生产 persist 路径触发 reload")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer { cancellable.cancel() }

        var changed = store.config
        changed.refreshIntervalSeconds += 1
        try store.applyAndSave(changed)

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
    }
    /// 审计降级项复现测试 2：最坏情况——外部进程在同一目录创建临时文件后用
    /// rename(2) 覆盖 config.json。目录 `.write` 事件仍必须触发 reload。
    @MainActor
    func testConfigWatcherCatchesRawRenameOverConfigFile() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.start()
        defer { state.stop() }

        let reloadExpectation = expectation(description: "raw rename 覆盖触发 reload")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer { cancellable.cancel() }

        var changed = store.config
        changed.refreshIntervalSeconds += 2
        let data = try JSONEncoder().encode(changed)
        let stagingURL = store.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.json.editor-swap")
        try data.write(to: stagingURL)
        let renameResult = stagingURL.path.withCString { src in
            store.configURL.path.withCString { dst in
                Darwin.rename(src, dst)
            }
        }
        XCTAssertEqual(renameResult, 0, "rename(2) 覆盖 config.json 必须成功")

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
    }
    // MARK: - P1: ConfigStore.applyAndSave persistence blocked
    /// 当配置解析失败且 `backupCorruptConfig` 也失败时，`persistenceAllowed = false`，
    /// 后续 `applyAndSave` 必须抛 `corruptConfigBackupFailed`。
    /// 这个保护避免默认空配置覆盖用户的损坏原文件。
    ///
    /// 触发条件：把损坏的 `config.json` 设为 0o000（owner 也无法读），
    /// `ConfigStore.init` 的 `load` 走 EACCES 失败分支 →
    /// `backupCorruptConfig.copyItem(at: url, ...)` 源不可读 → 返回 nil →
    /// `persistenceAllowed = false`。`applyAndSave` 后续必须抛 `corruptConfigBackupFailed`。
    ///
    /// 注：原计划是 chmod 0o500 整个目录，但 `ConfigStore.init` 内部会主动
    /// `setAttributes(dir, 0o700)`，把目录权限改回可写，导致 backup 仍能成功。
    /// 设源文件为 0o000 不会被 init 改回，副作用更小。
    @MainActor
    func testConfigStoreApplyAndSaveThrowsWhenPersistenceDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "llm-monitor-persistence-blocked-\(UUID().uuidString)", isDirectory: true
            )
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // 写一个损坏的配置文件
        try Data("{broken".utf8).write(to: url)
        // 把源文件设为 0o000（owner 不可读）。copyItem 源不可读时必定抛 EACCES，
        // ConfigStore.init 走 backup-failed 分支并设 persistenceAllowed = false。
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: url.path
        )
        addTeardownBlock {
            // 还原文件权限让 teardown 能 unlink（unlink 实际只依赖父目录权限，
            // 但为了保险还是恢复一下）
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: directory)
        }

        // 触发 init：load 失败（EACCES）→ 尝试 backup（copyItem 源 0o000 也 EACCES）
        // → persistenceAllowed = false
        let store = ConfigStore(configURL: url)

        // 1. 验证：现在 applyAndSave 必须抛 .corruptConfigBackupFailed
        var newConfig = store.config
        newConfig.refreshIntervalSeconds = 999
        XCTAssertThrowsError(try store.applyAndSave(newConfig)) { error in
            guard case ConfigStore.PersistenceError.corruptConfigBackupFailed(let thrownURL) = error else {
                XCTFail("expected .corruptConfigBackupFailed, got \(error)")
                return
            }
            XCTAssertEqual(thrownURL, url, "抛出的 URL 应是 configURL")
        }

        // 2. 验证：applyAndSave 失败后 store.config 没被污染（仍是默认 / 加载失败时的空 config）
        XCTAssertNotEqual(
            store.config.refreshIntervalSeconds, 999,
            "applyAndSave 抛错后内存中的 config 不应被改写"
        )
    }
    @MainActor
    func testProviderStatusIsEnabledReflectsConfigAndControlsFiltering() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        let configStore = ConfigStore(configURL: configURL)

        var config = configStore.config
        config.providers["test_a"] = ProviderConfig(enabled: true)
        config.providers["test_b"] = ProviderConfig(enabled: false)
        try? configStore.applyAndSave(config)

        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .minimaxTokenPlan,
            iconSystemName: "star",
            accentColor: .minimax,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "test_a", displayName: "Test A", kind: .minimaxTokenPlan) }
        )
        let descB = FetcherDescriptor(
            id: "test_b",
            displayName: "Test B",
            kind: .glmCodingPlan,
            iconSystemName: "moon",
            accentColor: .glm,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "test_b", displayName: "Test B", kind: .glmCodingPlan) }
        )

        let appState = AppState(descriptors: [descA, descB], configStore: configStore)
        // This assertion only inspects derived status; do not leave the
        // scheduler alive long enough to trigger the production local scanner.
        appState.stop()

        XCTAssertEqual(appState.statuses.count, 2)
        XCTAssertTrue(appState.statuses.first(where: { $0.id == "test_a" })?.isEnabled ?? false)
        XCTAssertFalse(appState.statuses.first(where: { $0.id == "test_b" })?.isEnabled ?? true)

        let visibleCards = appState.statuses.filter { $0.isEnabled }
        XCTAssertEqual(visibleCards.count, 1)
        XCTAssertEqual(visibleCards.first?.id, "test_a")
    }

    // MARK: - clientBindings 解码合并（老配置补齐新增默认绑定）

    /// 组装一份最小可解码的 config.json 字典，附带调用方给的 clientBindings 数组。
    private func makeConfigJSON(
        clientBindings: [[String: Any]]? = nil,
        schemaVersion: Int? = nil
    ) -> Data {
        var json: [String: Any] = [
            "refreshIntervalSeconds": 300,
            "providers": [String: Any]()
        ]
        if let schemaVersion { json["schemaVersion"] = schemaVersion }
        if let clientBindings { json["clientBindings"] = clientBindings }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func decodeConfig(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func bindingEntry(
        clientID: String,
        quotaProviderID: String,
        sourceProviderAliases: [String],
        enabled: Bool
    ) -> [String: Any] {
        [
            "clientID": clientID,
            "quotaProviderID": quotaProviderID,
            "sourceProviderAliases": sourceProviderAliases,
            "enabled": enabled
        ]
    }

    /// 老用户配置：数组已存在、只有 5 条 opencode 绑定，且 opencode → deepseek 被
    /// 用户显式打开（默认是 false）。解码后必须补上两条 zcode 默认绑定，同时
    /// 用户的显式值原样保留——不能被默认值覆盖。
    func testDecodeAddsNewDefaultBindingsToExistingLegacyArray() throws {
        let existing: [[String: Any]] = [
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.minimax,
                sourceProviderAliases: [OpencodeLocalUsage.minimaxCodingPlanProviderID],
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.openAI,
                sourceProviderAliases: [OpencodeLocalUsage.openAIProviderID],
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.antigravity,
                sourceProviderAliases: OpencodeLocalUsage.antigravityProviderIDs,
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.zhipu,
                sourceProviderAliases: [OpencodeLocalUsage.glmProviderID],
                enabled: true
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.deepseek,
                sourceProviderAliases: [OpencodeLocalUsage.deepseekProviderID],
                enabled: true
            )
        ]
        let config = try decodeConfig(makeConfigJSON(clientBindings: existing))

        XCTAssertEqual(config.clientBindings.count, 7, "5 条 opencode + 2 条 zcode 默认绑定")
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax),
            "老配置应补上 zcode → minimax 默认绑定（enabled=true）"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek),
            "老配置应补上 zcode → deepseek 默认绑定（enabled=true）"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek),
            "用户显式打开的 opencode → deepseek 不应被默认值(false)覆盖"
        )
        // 补齐只追加到尾部，opencode 段落顺序与来源别名保持原样。
        XCTAssertEqual(
            config.clientBindings.prefix(5).map { "\($0.clientID):\($0.quotaProviderID)" },
            existing.map { "\($0["clientID"] as! String):\($0["quotaProviderID"] as! String)" }
        )
        XCTAssertEqual(
            config.clientBindings.first?.sourceProviderAliases,
            [OpencodeLocalUsage.minimaxCodingPlanProviderID]
        )
    }

    /// 已经包含全部默认绑定的配置解码后不应重复，也不应重排。
    func testDecodeDoesNotDuplicateOrReorderCompleteDefaultBindings() throws {
        let encoded = try JSONEncoder().encode(AppConfig.defaultClientBindings)
        let bindings = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

        let config = try decodeConfig(makeConfigJSON(clientBindings: bindings))

        XCTAssertEqual(config.clientBindings, AppConfig.defaultClientBindings)
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
    }

    /// 用户把某条默认绑定显式关掉后解码不能复活它（补齐只针对"缺失的组合"）。
    func testDecodeKeepsExplicitlyDisabledDefaultBindingDisabled() throws {
        let encoded = try JSONEncoder().encode(AppConfig.defaultClientBindings)
        var bindings = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in bindings.indices {
            if bindings[index]["clientID"] as? String == ClientID.zcode,
               bindings[index]["quotaProviderID"] as? String == QuotaProviderID.minimax {
                bindings[index]["enabled"] = false
            }
        }

        let config = try decodeConfig(makeConfigJSON(clientBindings: bindings))

        XCTAssertFalse(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax),
            "用户关掉的 zcode → minimax 不应被默认值复活"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
    }

    /// clientBindings 字段缺失（schema 0 legacy 路径）同样要经过合并，不能停在
    /// 5 条 opencode 上。
    func testDecodeWithoutClientBindingsFieldFallsBackToFullDefaults() throws {
        let config = try decodeConfig(makeConfigJSON())

        XCTAssertEqual(config.clientBindings, AppConfig.defaultClientBindings)
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
    }

    /// schema 1（有 clientBindings、无 zcode 新条目的老用户）走的是同一合并逻辑。
    func testSchema1ConfigAlsoReceivesNewDefaultBindings() throws {
        let existing: [[String: Any]] = [
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.zhipu,
                sourceProviderAliases: [OpencodeLocalUsage.glmProviderID],
                enabled: true
            )
        ]
        let config = try decodeConfig(
            makeConfigJSON(clientBindings: existing, schemaVersion: 1)
        )

        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.zhipu),
            "原有条目不应被改写"
        )
    }
}
