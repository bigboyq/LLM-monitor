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

    // MARK: - ProviderConfig 占位 Key 守门与刷新间隔钳制（自 UsableAPIKeyHealthLevelTests 解散归入）

    func testUsableAPIKeyRules() {
        XCTAssertNil(ProviderConfig(apiKey: nil).usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "   \n\t  ").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "REPLACE-WITH-YOUR-KEY").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "sk-cp-REPLACE-WITH-YOUR-KEY").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "sk-cp-xxx-REPLACE-THIS-TOKEN").usableAPIKey)
        XCTAssertEqual(ProviderConfig(apiKey: "test-key-with-valid-format-12345").usableAPIKey, "test-key-with-valid-format-12345")
        XCTAssertEqual(ProviderConfig(apiKey: "  sk-cp-real-key  \n").usableAPIKey, "sk-cp-real-key")
    }

    func testEffectiveRefreshIntervalRules() {
        let global = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        XCTAssertEqual(global.effectiveRefreshInterval(for: "anything"), 300)

        let override = AppConfig(refreshIntervalSeconds: 300, providers: ["minimax_token_plan": ProviderConfig(refreshIntervalSeconds: 60)])
        XCTAssertEqual(override.effectiveRefreshInterval(for: "minimax_token_plan"), 60)

        let zeroClamped = AppConfig(refreshIntervalSeconds: 0, providers: [:])
        XCTAssertEqual(zeroClamped.effectiveRefreshInterval(for: "x"), 10)

        let hugeClamped = AppConfig(refreshIntervalSeconds: Int.max, providers: [:])
        XCTAssertEqual(
            hugeClamped.effectiveRefreshInterval(for: "x"),
            TimeInterval(AppConfig.maximumRefreshIntervalSeconds)
        )

        let hugeOverride = AppConfig(
            refreshIntervalSeconds: 300,
            providers: ["x": ProviderConfig(refreshIntervalSeconds: Int.max)]
        )
        XCTAssertEqual(
            hugeOverride.effectiveRefreshInterval(for: "x"),
            TimeInterval(AppConfig.maximumRefreshIntervalSeconds)
        )
    }

    /// 外观四字段 + `holidaySource` 类型写错时按缺省处理、不进损坏恢复流程
    /// （容错语义回归护栏）。这些字段此前一律 `try?` 静默回落，现在补 logWarn
    /// ——用户看到的是「图标样式回默认 / 节假日按官方数据算」，日志里必须有线索。
    func testAppearanceFieldsWithWrongTypesFallBackToDefaults() throws {
        let json = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {},
          "statusBarIconStyle": 42,
          "statusBarHealthDotEnabled": "yes",
          "statusBarHealthColors": "#ff0000",
          "providerCardOrder": "glm_coding_plan",
          "holidaySource": 7
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.statusBarIconStyle)
        XCTAssertNil(config.statusBarHealthDotEnabled)
        XCTAssertNil(config.statusBarHealthColors)
        XCTAssertNil(config.providerCardOrder)
        XCTAssertNil(config.holidaySource)

        // 生效值回落到缺省（与字段缺省时一致）。
        XCTAssertEqual(config.effectiveStatusBarIconStyle, AppConfig.default.effectiveStatusBarIconStyle)
        XCTAssertEqual(
            config.effectiveStatusBarHealthDotEnabled,
            AppConfig.default.effectiveStatusBarHealthDotEnabled
        )
        XCTAssertEqual(config.effectiveHolidaySource, HolidayCalendar.defaultSourceURL)
    }
}
