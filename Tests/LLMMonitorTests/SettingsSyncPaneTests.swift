import AppKit
import SwiftUI
import XCTest
import Darwin
@testable import LLM_monitor

/// 设置页「多机联动」pane 的**字段闸门**：主节点地址与监听端口在落盘前必须
/// 过校验，非法值不许进 config.json。
///
/// 两个闸门守的是同一条后果链：地址 / 端口写坏 → 角色派生或监听行为与用户
/// 的预期不符 → 机器离线，而界面上原本没有任何地方能显示失败原因（现在
/// 「连接状态」行会显示 `fleetRuntimeStatus.lastError`）。
final class SettingsSyncPaneTests: XCTestCase {

    @MainActor
    private func makeDraftController(
        initialSync: SyncConfig = .default,
        debounceNanoseconds: UInt64 = 600_000_000
    ) throws -> (URL, ConfigStore, SettingsSyncDraftController) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-sync-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        var config = store.config
        config.sync = initialSync
        try store.applyAndSave(config)
        return (directory, store, SettingsSyncDraftController(
            configStore: store,
            debounceNanoseconds: debounceNanoseconds
        ))
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition did not become true", file: file, line: line)
    }


    // MARK: - 主节点地址校验

    /// 空地址合法：清空 = 本机变回主节点（`SyncRole.derive` 按「空即 hub」派生）。
    @MainActor
    func testHubURLAcceptsEmptyAsBackToHubRole() {
        XCTAssertEqual(SettingsSyncPane.checkHubURL(""), .valid)
        XCTAssertEqual(SettingsSyncPane.checkHubURL("   "), .valid)
    }

    /// http / https 且 host 非空 = 合法（与 `SyncClient.init` 的解析口径一致）。
    @MainActor
    func testHubURLAcceptsHTTPAndHTTPSWithHost() {
        for raw in ["http://192.168.1.20:8787", "https://hub.local:8787", "http://127.0.0.1:8787"] {
            XCTAssertEqual(SettingsSyncPane.checkHubURL(raw), .valid, "\(raw) 应当合法")
        }
    }

    /// 漏 scheme 的地址（`192.168.1.20:8787`）必须被拒。
    ///
    /// 它曾被原样写进 config.json：本机按「非空即副节点」派生后
    /// `SyncClient.init` 抛 `invalidHubURL`，机器从此离线，且界面上没有任何
    /// 地方能显示原因。
    @MainActor
    func testHubURLRejectsAddressWithoutScheme() {
        guard case .invalid = SettingsSyncPane.checkHubURL("192.168.1.20:8787") else {
            return XCTFail("漏 scheme 的地址必须被拒绝")
        }
    }

    /// 非 http(s) 的 scheme、缺 host 的地址同样拒绝（同一把尺子）。
    @MainActor
    func testHubURLRejectsBadSchemeOrMissingHost() {
        for raw in ["ftp://192.168.1.20:8787", "ws://hub.local", "http://", "not a url"] {
            guard case .invalid = SettingsSyncPane.checkHubURL(raw) else {
                return XCTFail("\(raw) 必须被拒绝")
            }
        }
    }

    // MARK: - 监听端口

    @MainActor
    func testPortCommitAppliesAnInRangePort() {
        XCTAssertEqual(SettingsSyncPane.portCommit(draft: "9000", stored: 8787), .apply(9000))
        XCTAssertEqual(SettingsSyncPane.portCommit(draft: " 9000 ", stored: 8787), .apply(9000))
    }

    @MainActor
    func testPortCommitKeepsTheStoredPortWhenUnchanged() {
        XCTAssertEqual(SettingsSyncPane.portCommit(draft: "8787", stored: 8787), .unchanged)
    }

    /// 越界 / 非数字 → 判非法：配置不落盘，输入框回滚到已生效端口。输入框继续
    /// 显示 99999 而同屏报「监听中（端口 8787）」是自相矛盾的。
    @MainActor
    func testPortCommitRejectsOutOfRangeAndGarbage() {
        for raw in ["99999", "0", "-1", "abc", ""] {
            XCTAssertEqual(
                SettingsSyncPane.portCommit(draft: raw, stored: 8787), .invalid,
                "\(raw) 必须判为非法（不落盘 + 输入框回滚）"
            )
        }
    }

    // MARK: - 草稿防抖与配置热更新

    @MainActor
    func testRapidEditsAcrossFieldsAreDebouncedIndependently() async throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setNodeNameDraft("Living Room Mac")
        try await Task.sleep(nanoseconds: 100_000_000)
        drafts.setHubURLDraft("http://192.168.1.20:8787")
        try await waitUntil {
            store.config.effectiveSyncConfig.nodeName == "Living Room Mac"
                && store.config.effectiveSyncConfig.hubURL == "http://192.168.1.20:8787"
        }
    }

    @MainActor
    func testExternalChangeWinsAndCancelsPendingEditForSameField() async throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setNodeNameDraft("local pending")
        var external = store.config
        var sync = external.effectiveSyncConfig
        sync.nodeName = "external value"
        external.sync = sync
        try store.applyAndSave(external)

        try await waitUntil { drafts.nodeNameDraft == "external value" }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "external value")
        XCTAssertEqual(drafts.nodeNameDraft, "external value")
    }

    @MainActor
    func testExternalChangeRebasesBeforeImmediateFlush() throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setNodeNameDraft("stale local edit")
        var external = store.config
        var sync = external.effectiveSyncConfig
        sync.nodeName = "external value"
        external.sync = sync
        try store.applyAndSave(external)

        // No actor/run-loop yield between external publication and closing the pane.
        XCTAssertEqual(drafts.nodeNameDraft, "external value")
        drafts.flushPendingEdits()
        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "external value")
    }

    @MainActor
    func testOwnConfigPublicationDoesNotRollbackNewerDraft() async throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setNodeNameDraft("first value")
        drafts.submitNodeName()
        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "first value")

        drafts.setNodeNameDraft("newer value")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(drafts.nodeNameDraft, "newer value")
        try await waitUntil {
            store.config.effectiveSyncConfig.nodeName == "newer value"
        }
        XCTAssertEqual(drafts.nodeNameDraft, "newer value")
    }

    @MainActor
    func testSubmittingOneFieldDoesNotCancelAnotherPendingField() async throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setNodeNameDraft("Basement Mac")
        try await Task.sleep(nanoseconds: 100_000_000)
        drafts.setHubURLDraft("http://192.168.1.21:8787")
        drafts.submitHubURL()
        XCTAssertEqual(store.config.effectiveSyncConfig.hubURL, "http://192.168.1.21:8787")

        try await waitUntil {
            store.config.effectiveSyncConfig.nodeName == "Basement Mac"
        }
    }

    @MainActor
    func testInvalidURLDoesNotPersistOnDebounceOrPaneFlush() async throws {
        let (directory, store, drafts) = try makeDraftController()
        defer { try? FileManager.default.removeItem(at: directory) }

        drafts.setHubURLDraft("not a URL")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.config.effectiveSyncConfig.hubURL, "")
        XCTAssertNotNil(drafts.hubURLError)

        drafts.setNodeNameDraft("saved on close")
        drafts.setHubURLDraft("still invalid")
        drafts.flushPendingEdits()
        XCTAssertEqual(store.config.effectiveSyncConfig.hubURL, "")
        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "saved on close")
        XCTAssertNotNil(drafts.hubURLError)
    }

    @MainActor
    func testWriteFailuresStayVisiblePerFieldAndCanBeRetriedAfterRecovery() throws {
        let (directory, store, drafts) = try makeDraftController()
        let configURL = store.configURL
        defer {
            _ = configURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.chflags(path, 0)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let original = store.config.effectiveSyncConfig
        let flagResult = configURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chflags(path, UInt32(UF_IMMUTABLE))
        }
        XCTAssertEqual(flagResult, 0, "fixture must make config.json immutable")

        drafts.setNodeNameDraft("Retry node")
        drafts.setHubURLDraft("http://127.0.0.1:8787")
        drafts.setPortDraft("9123")
        drafts.setPushInterval(17)
        drafts.setEnabled(true)
        drafts.flushPendingEdits()

        XCTAssertEqual(store.config.effectiveSyncConfig, original, "failed writes must not appear applied")
        XCTAssertEqual(drafts.nodeNameDraft, "Retry node", "failed text edits remain available to retry")
        XCTAssertEqual(drafts.hubURLDraft, "http://127.0.0.1:8787")
        XCTAssertEqual(drafts.portDraft, "9123")
        for field in [
            SettingsSyncDraftController.Field.enabled,
            .hubURL,
            .nodeName,
            .port,
            .pushInterval
        ] {
            XCTAssertNotNil(drafts.saveError(for: field), "\(field) must expose its own write failure")
        }

        let clearResult = configURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chflags(path, 0)
        }
        XCTAssertEqual(clearResult, 0, "fixture must restore config.json writability")

        drafts.submitPort()
        XCTAssertEqual(store.config.effectiveSyncConfig.hubPort, 9123)
        XCTAssertNil(drafts.saveError(for: .port))
        XCTAssertNotNil(drafts.saveError(for: .nodeName), "success on port must not hide another field failure")
        XCTAssertNotNil(drafts.saveError(for: .hubURL))

        drafts.submitNodeName()
        drafts.submitHubURL()
        drafts.setPushInterval(17)
        drafts.setEnabled(true)

        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "Retry node")
        XCTAssertEqual(store.config.effectiveSyncConfig.hubURL, "http://127.0.0.1:8787")
        XCTAssertEqual(store.config.effectiveSyncConfig.pushIntervalSeconds, 17)
        XCTAssertTrue(store.config.effectiveSyncConfig.enabled)
        for field in [
            SettingsSyncDraftController.Field.enabled,
            .hubURL,
            .nodeName,
            .port,
            .pushInterval
        ] {
            XCTAssertNil(drafts.saveError(for: field), "successful retry should clear only the recovered field error")
        }
    }

    @MainActor
    func testInjectedControllerRetainsFailedDraftAcrossPaneRecreationAndRetries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-sync-pane-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)
        let controller = SettingsSyncDraftController(configStore: store)
        defer {
            state.stop()
            let configURL = store.configURL
            _ = configURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.chflags(path, 0)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let configURL = store.configURL
        let flagResult = configURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chflags(path, UInt32(UF_IMMUTABLE))
        }
        XCTAssertEqual(flagResult, 0, "fixture must make config.json immutable")

        controller.setNodeNameDraft("retry after returning")
        controller.flushPendingEdits() // 同步 onDisappear 行为
        XCTAssertNotNil(controller.saveError(for: .nodeName))
        XCTAssertEqual(controller.nodeNameDraft, "retry after returning")

        XCTAssertTrue(controller.hasSaveErrors)
        let firstPane = SettingsSyncPane(state: state, drafts: controller)
        let recreatedPane = SettingsSyncPane(state: state, drafts: controller)
        XCTAssertTrue(firstPane.draftController === controller)
        XCTAssertTrue(recreatedPane.draftController === controller)
        XCTAssertEqual(recreatedPane.draftController.nodeNameDraft, "retry after returning")

        let clearResult = configURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chflags(path, 0)
        }
        XCTAssertEqual(clearResult, 0, "fixture must restore config.json writability")
        recreatedPane.draftController.submitNodeName()
        XCTAssertEqual(store.config.effectiveSyncConfig.nodeName, "retry after returning")
        XCTAssertNil(controller.saveError(for: .nodeName))
    }

    @MainActor
    func testDisabledConnectionStatusShowsNotEnabledAndHidesRuntimeError() {
        let status = FleetSyncStatusInfo(
            role: .off,
            online: false,
            lastSyncAt: nil,
            lastError: "old connection failure",
            snapshotGeneration: nil
        )
        XCTAssertEqual(
            SettingsSyncPane.connectionText(enabled: false, role: .off, hubPort: 8787, status: status),
            "未启用"
        )
        XCTAssertNil(SettingsSyncPane.visibleConnectionError(
            enabled: false,
            lastError: status.lastError
        ))

        let onlineHub = FleetSyncStatusInfo(
            role: .hub,
            online: true,
            lastSyncAt: nil,
            lastError: nil,
            snapshotGeneration: nil
        )
        XCTAssertEqual(
            SettingsSyncPane.connectionText(enabled: true, role: .hub, hubPort: 9123, status: onlineHub),
            "监听中（端口 9123）"
        )
    }

    // MARK: - 局域网地址

    /// 取到的地址绝不能是 127.0.0.1——回环地址不是副节点能连上的地址，
    /// 摆在「主节点地址」一格里等于骗用户复制一条废地址。
    @MainActor
    func testLANAddressIsNeverLoopback() {
        guard let address = LANAddressResolver.currentLANAddress() else { return }
        XCTAssertNotEqual(address, "127.0.0.1", "回环地址不能当局域网地址")
        XCTAssertFalse(address.hasPrefix("127."), "回环地址不能当局域网地址：\(address)")
    }

    // MARK: - 渲染

    /// pane 真渲染一遍：字段区的排版改动最容易在运行期塌掉（地址文案、控制列
    /// 宽度、行内错误文案），这里兜一层「渲染得出来」。
    @MainActor
    func testSyncPaneRenders() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-sync-pane-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)
        defer { state.stop() }

        let hosting = NSHostingView(rootView: AnyView(SettingsSyncPane(state: state)))
        hosting.frame = CGRect(x: 0, y: 0, width: 700, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "pane 必须渲染得出来")
    }
}
