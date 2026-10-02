import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// `ConfigStore` 的配置监听（目录 `.write` watcher）行为：重启后继续工作、
/// 生产 persist 的 rename 写入、外部 raw rename 覆盖都要触发 reload。
/// 对应 `ConfigStore` 的 watcher 与 `AppState` 的 start/stop 生命周期。
final class ConfigWatcherTests: StateTestCase {

    // MARK: - Config Watcher

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
}
