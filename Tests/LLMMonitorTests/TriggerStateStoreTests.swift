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
    func testRoundtripPersistsBaselineAcrossInstances() throws {
        // 基线必须跨实例（= 跨重启）存活：停机期间的耗尽/恢复靠它补报。
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        XCTAssertNil(store.snapshot(for: "p"), "冷启动无基线")
        store.update(providerID: "p", info: info([model("General", interval: 12.5, weekly: 40)]))
        store.flushNow()

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
    func testDetectorConsumesReloadedBaselineToCatchDowntimeExhaustion() throws {
        // 重启场景：停机期间 5h 窗口被耗尽，重启后第一刷要能补报而不是漏掉。
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let first = TriggerStateStore(configURL: configURL)
        first.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))
        first.flushNow()

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
    func testResetDropsBaselineForNotConfiguredProvider() throws {
        let directory = try makeDirectory()
        let configURL = directory.appendingPathComponent("config.json")

        let store = TriggerStateStore(configURL: configURL)
        store.update(providerID: "p", info: info([model("general", interval: 30, weekly: 80)]))
        store.flushNow()
        store.reset(providerID: "p")
        store.flushNow()

        XCTAssertNil(TriggerStateStore(configURL: configURL).snapshot(for: "p"))
        // 重复 reset 是无害的 no-op。
        store.reset(providerID: "p")
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
}
