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

    /// 审计降级项复现测试 3：文件被**删除**后（不只是 rename 替换）watcher 必须
    /// 经退避重试重新挂上，否则用户「删掉重写」配置时 reload 永久失聪。
    ///
    /// 生产路径：`.delete` 事件 → `startConfigWatcher` → `open(O_EVTONLY)` 失败 →
    /// 记一次 attempt → 排一个退避 task → 醒来再试；退避时长
    /// `min(1 << min(attempt, 5), 30)`，首档 1s。测试不注入间隔（`ConfigStore`
    /// 没暴露这条缝，也不该为测试改生产可见性），而是等首档退避自然走完。
    ///
    /// **必须让文件真的缺失够久**（> 首档 1s）再写回，否则会出现一条假绿路径：
    /// 写回得太快时，`.delete` 事件处理里的 `open` 可能直接成功，测试根本没进
    /// 退避分支，却照样绿——把"退避重开"换成"事件处理里直接重开"也测不出来。
    /// 让它缺失超过首档，第一次退避醒来时文件仍然不在，才真的排上了第二轮。
    ///
    /// 断言放在**恢复之后再改一次配置**：只看"删了没崩"太弱，watcher 可能压根没
    /// 挂上而测试照样绿；必须证明重开后的 fd 真的重新收到了事件。
    @MainActor
    func testConfigWatcherRecoversAfterConfigFileIsDeletedAndRecreated() async throws {
        let store = makeIsolatedConfigStore()
        try store.applyAndSave(store.config)  // 先落盘，watcher 才有文件可 open
        let state = AppState(descriptors: [], configStore: store)
        state.start()
        defer { state.stop() }

        func write(_ interval: Int) throws {
            var cfg = store.config
            cfg.refreshIntervalSeconds = interval
            try JSONEncoder().encode(cfg).write(to: store.configURL, options: .atomic)
        }

        try FileManager.default.removeItem(at: store.configURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.configURL.path),
            "前置条件：config.json 必须先真的删掉，否则走不到 open 失败分支"
        )

        // 保持缺失超过首档退避（1s），让退避分支确定被走到。
        let deletedAt = Date()
        _ = await waitUntil(timeout: 3, pollInterval: 0.05) { @MainActor in
            Date().timeIntervalSince(deletedAt) > 1.5
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.configURL.path),
            "退避窗口内不得提前把文件写回来，否则测的就不是退避路径"
        )

        try write(60)  // 写回：下一次退避醒来时 open 才能成功

        // 轮询间隔必须**大于 reload 的 250ms debounce**，否则连续写入会一直把
        // debounce 计时器往后推，reload 永远不发生——那是测试自己造的假阴性。
        // 退避此刻已在第 2 档（2s）附近，10s 足够覆盖。
        let reloaded = await waitUntil(timeout: 10, pollInterval: 0.4) { @MainActor in
            try? write(90)
            return store.config.refreshIntervalSeconds == 90
        }
        XCTAssertTrue(
            reloaded,
            "文件删除后 watcher 必须经退避重开 fd；恢复后的变更仍要触发 reload，否则 reload 永久失聪"
        )
    }
}
