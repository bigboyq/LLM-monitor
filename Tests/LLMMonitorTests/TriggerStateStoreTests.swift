import XCTest
@testable import LLM_monitor

final class TriggerStateStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-trigger-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func model(_ name: String, interval: Double, weekly: Double) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: Int(100 - interval),
            intervalRemainingPercent: interval,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: Int(100 - weekly),
            weeklyRemainingPercent: weekly,
            weeklyStatus: .present,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }

    private func info(_ models: [ModelQuota]) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    @MainActor
    func testRoundtripPersistsBaselineAcrossInstances() async throws {
        // 基线必须跨实例（= 跨重启）存活：停机期间的耗尽/恢复靠它补报。
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        XCTAssertNil(store.snapshot(for: "p"), "冷启动无基线")
        store.update(providerID: "p", info: info([model("General", interval: 12.5, weekly: 40)]))
        await store.waitForPendingWrites()

        let reloaded = TriggerStateStore(configURL: configURL)
        let baseline = try XCTUnwrap(reloaded.snapshot(for: "p"))
        XCTAssertEqual(
            baseline.models["general"],
            QuotaWindowBaseline(
                intervalPresent: true,
                intervalRemainingPercent: 12.5,
                weeklyPresent: true,
                weeklyRemainingPercent: 40
            )
        )
    }

    @MainActor
    func testDetectorConsumesReloadedBaselineToCatchDowntimeExhaustion() async throws {
        // 重启场景：停机期间 5h 窗口被耗尽，重启后第一刷要能补报而不是漏掉。
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let first = TriggerStateStore(configURL: configURL)
        first.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))
        await first.waitForPendingWrites()

        let restarted = TriggerStateStore(configURL: configURL)
        let events = QuotaEventDetector.detect(
            current: info([model("general", interval: 0, weekly: 80)]),
            previousSnapshot: restarted.snapshot(for: "p")
        )
        XCTAssertEqual(events.map(\.kind), [.intervalExhausted])
    }

    @MainActor
    func testSnapshotExtractionMatchesDetectorKeys() {
        // key 与 QuotaEventDetector 的匹配键一致：modelName.lowercased()，冲突取 first。
        let snapshot = QuotaSnapshot(from: info([
            model("General", interval: 10, weekly: 20),
            model("general", interval: 30, weekly: 60),
        ]))
        XCTAssertEqual(
            snapshot.models["general"],
            QuotaWindowBaseline(
                intervalPresent: true,
                intervalRemainingPercent: 10,
                weeklyPresent: true,
                weeklyRemainingPercent: 20
            ),
            "同名模型冲突时应取 first"
        )
    }

    @MainActor
    func testResetDropsBaselineForNotConfiguredProvider() async throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))
        store.reset(providerID: "p")
        await store.waitForPendingWrites()

        XCTAssertNil(TriggerStateStore(configURL: configURL).snapshot(for: "p"))
        // 重复 reset 是无害的 no-op。
        store.reset(providerID: "p")
    }

    /// 落盘移出 MainActor 后，"刷新成功后记录基线"的时序不变：内存基线在
    /// `update` 返回时立即可读（检测器同一次刷新里读到的 previous 就是新基线），
    /// 文件随后由 writer actor 异步落盘。
    @MainActor
    func testUpdateIsVisibleInMemoryBeforeDiskFlush() async throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        let stateURL = directory.appendingPathComponent("notification-state.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))

        // 同步段内就应可读：不依赖任何 await。
        XCTAssertEqual(
            store.snapshot(for: "p")?.models["general"]?.intervalRemainingPercent,
            30,
            "update 返回时内存基线必须已是新值（检测器读 previous 不受落盘时序影响）"
        )

        // 落盘是异步的，但必定发生且内容一致。
        await store.waitForPendingWrites()
        let reloaded = TriggerStateStore(configURL: configURL)
        XCTAssertEqual(
            reloaded.snapshot(for: "p")?.models["general"]?.intervalRemainingPercent,
            30,
            "异步落盘后重载必须拿到同一基线"
        )

        // 仍是私有文件（0600），与同步直写时一致。
        let perms = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "notification-state.json 必须是 owner-only")
    }

    /// 连续更新（refreshAll 突发 / 多 provider）必须全部落盘，且文件最终是最新
    /// 快照——writer 串行执行 + seq 丢弃迟到旧快照，杜绝旧值覆盖新值。
    @MainActor
    func testRapidUpdatesEndUpWithLatestSnapshotOnDisk() async throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 10, weekly: 80)]))
        store.update(providerID: "p", info: info([model("general", interval: 20, weekly: 80)]))
        store.update(providerID: "q", info: info([model("general", interval: 30, weekly: 80)]))
        await store.waitForPendingWrites()

        let reloaded = TriggerStateStore(configURL: configURL)
        XCTAssertEqual(
            reloaded.snapshot(for: "p")?.models["general"]?.intervalRemainingPercent, 20,
            "同一 provider 的后一次刷新必须落盘"
        )
        XCTAssertEqual(
            reloaded.snapshot(for: "q")?.models["general"]?.intervalRemainingPercent, 30,
            "突发刷新里的其他 provider 也必须落盘"
        )
    }

    @MainActor
    func testCorruptBaselineFileFallsBackToEmpty() throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        let stateURL = directory.appendingPathComponent("notification-state.json")
        try Data("not json".utf8).write(to: stateURL)

        let store = TriggerStateStore(configURL: configURL)
        XCTAssertNil(store.snapshot(for: "p"), "坏文件应容错降级为空基线")
    }

    /// 停机兜底：`flushSynchronously` 是同步方法，**返回时**文件就必须是当前内存
    /// 快照（不等 actor 的异步写）。`AppState.stop()` 走这条路径 —— 进程在
    /// encode + fsync 的毫秒级窗口里退出时，靠它保住最后一次基线。
    @MainActor
    func testFlushSynchronouslyWritesLatestSnapshotWithoutAwaiting() throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        let stateURL = directory.appendingPathComponent("notification-state.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))
        store.update(providerID: "q", info: info([model("general", interval: 55, weekly: 10)]))

        // 不同步等待：调用返回即刻读文件。
        store.flushSynchronously()

        let reloaded = TriggerStateStore(configURL: configURL)
        XCTAssertEqual(
            reloaded.snapshot(for: "p")?.models["general"]?.intervalRemainingPercent, 30,
            "同步兜底必须把 p 的基线写完"
        )
        XCTAssertEqual(
            reloaded.snapshot(for: "q")?.models["general"]?.weeklyRemainingPercent, 10,
            "同步兜底必须把 q 的基线写完"
        )
        let perms = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "兜底写同样走 writePrivate（0600）")
    }

    /// 兜底写之后，排在 writer actor 队列里、seq 不更新的旧快照不得再把文件回退。
    @MainActor
    func testFlushSynchronouslyFloorStopsQueuedOlderWritesFromRegressingFile() async throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 10, weekly: 80)]))
        // 不 waitForPendingWrites：这次写的 Task 仍可能排在 actor 队列里。
        store.flushSynchronously()
        // 兜底之后又有一次新基线（写盘正常走异步路径）。
        store.update(providerID: "p", info: info([model("general", interval: 90, weekly: 80)]))

        await store.waitForPendingWrites()
        let reloaded = TriggerStateStore(configURL: configURL)
        XCTAssertEqual(
            reloaded.snapshot(for: "p")?.models["general"]?.intervalRemainingPercent, 90,
            "兜底后到达的新基线必须落盘，且不被更早的排队快照覆盖"
        )
    }
}
