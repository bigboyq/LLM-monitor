import XCTest
@testable import LLM_monitor

/// `fleet.sqlite` 单表存储：通道独立落库、high-water seq、窗口 upsert 与清理、
/// generation 持久化、副节点快照缓存（§5.7 / §7.6）。
final class FleetStoreTests: XCTestCase {

    private var directory: URL!
    private var store: FleetStore!
    private let scope = UUID().uuidString

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-store-\(UUID().uuidString)", isDirectory: true)
        store = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 工厂

    private func report(
        seq: Int,
        nodeID: UUID = UUID(),
        daily: [FleetDailyBucket]? = nil,
        windows: [FleetWindowUsage]? = nil,
        quotas: [FleetQuotaReport]? = nil,
        nodeName: String = "MacBook-Pro"
    ) -> NodeUsageReport {
        NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: FleetNodeIdentity(nodeID: nodeID, nodeName: nodeName,
                                    timezoneID: "Asia/Shanghai", platform: "macOS"),
            seq: seq,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            attributionFingerprint: "deadbeef",
            dailyBuckets: daily,
            windowUsage: windows,
            quotas: quotas
        )
    }

    private func emptyValidation(dailyError: String? = nil) -> FleetReportValidation {
        FleetReportValidation(
            envelopeError: nil,
            dailyBucketsError: dailyError,
            windowRows: [],
            windowDroppedRowCount: 0,
            quotasError: nil
        )
    }

    private func buckets(input: Int) -> [FleetDailyBucket] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return FleetMerger.dayKeyWindow(now: now).map { dayKey in
            let rows = [FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                input: input, cacheRead: 0, output: 0, reasoning: 0, turns: 0, rounds: 0
            )]
            return FleetDailyBucket(
                dayKey: dayKey,
                totals: FleetTotals(summing: rows),
                clientProviders: rows,
                entries: [],
                totalsComplete: true,
                modelDetailsComplete: true,
                sourceTruncated: false
            )
        }
    }

    private func windowRow(
        provider: String = QuotaProviderID.openAI,
        end: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> FleetWindowUsage {
        FleetWindowUsage(
            quotaProviderID: provider, modelID: "chatgpt_plan", windowKind: "interval",
            startAt: end.addingTimeInterval(-5 * 60 * 60), endAt: end, observedAt: end,
            input: 10, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none,
            complete: true, sourceTruncated: false
        )
    }

    private func quota(provider: String = QuotaProviderID.openAI) -> FleetQuotaReport {
        FleetQuotaReport(
            quotaProviderID: provider,
            fetchedAt: Date(timeIntervalSince1970: 1_799_000_000),
            models: [ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100, intervalUsageCount: 10,
                intervalRemainingPercent: 90, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 0, weeklyStatus: .absent,
                weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: "Plus", accountEmail: nil, balanceDetail: nil
        )
    }

    // MARK: - seq high-water

    func testStaleSeqReplaysNothing() throws {
        let node = UUID()
        let first = try store.applyReport(
            report(seq: 5, nodeID: node, daily: buckets(input: 100)),
            validation: emptyValidation(),
            scope: scope
        )
        XCTAssertTrue(first.dailyApplied)

        let replay = try store.applyReport(
            report(seq: 5, nodeID: node, daily: buckets(input: 999)),
            validation: emptyValidation(),
            scope: scope
        )
        XCTAssertTrue(replay.rejectedStaleSeq, "seq <= high-water 不应用任何通道")

        let older = try store.applyReport(
            report(seq: 3, nodeID: node, daily: buckets(input: 777)),
            validation: emptyValidation(),
            scope: scope
        )
        XCTAssertTrue(older.rejectedStaleSeq, "乱序（更小 seq）同样拒绝")

        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.report.dailyBuckets?.last?.totals.input, 100, "旧数据未被重放覆盖")
    }

    func testHeartbeatOnlyReportUpdatesSeqAndLastSeen() throws {
        let node = UUID()
        try store.applyReport(
            report(seq: 1, nodeID: node, daily: buckets(input: 10)),
            validation: emptyValidation(),
            scope: scope,
            receivedAt: Date(timeIntervalSince1970: 1_000)
        )
        // 省略全部数据通道的心跳（§6.5：用量问题不卡住心跳）。
        let heartbeat = try store.applyReport(
            report(seq: 2, nodeID: node),
            validation: emptyValidation(),
            scope: scope,
            receivedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertFalse(heartbeat.rejectedStaleSeq)
        XCTAssertTrue(heartbeat.heartbeatUpdated)

        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.seq, 2)
        XCTAssertEqual(state.nodes.first?.lastSeenAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(state.nodes.first?.report.dailyBuckets?.last?.totals.input, 10, "省略通道保留旧值")
    }

    func testInvalidDailyChannelKeepsOldBuckets() throws {
        let node = UUID()
        try store.applyReport(
            report(seq: 1, nodeID: node, daily: buckets(input: 10), quotas: [quota()]),
            validation: emptyValidation(),
            scope: scope
        )
        // 日桶校验失败 + 额度通道有效：日桶保留旧值，额度独立更新（§6.5）。
        let newerQuota = quota(provider: QuotaProviderID.zhipu)
        let outcome = try store.applyReport(
            report(seq: 2, nodeID: node, daily: buckets(input: 555), quotas: [newerQuota]),
            validation: emptyValidation(dailyError: "totals 与 clientProviders 汇总不一致"),
            scope: scope
        )
        XCTAssertFalse(outcome.dailyApplied)
        XCTAssertTrue(outcome.quotasApplied)

        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.report.dailyBuckets?.last?.totals.input, 10)
        XCTAssertEqual(state.nodes.first?.report.quotas?.map(\.quotaProviderID), [QuotaProviderID.zhipu])
    }

    // MARK: - 窗口

    func testWindowRowsUpsertAndMissingRangeRetained() throws {
        let node = UUID()
        let first = windowRow(end: Date(timeIntervalSince1970: 1_800_000_000))
        let second = windowRow(end: Date(timeIntervalSince1970: 1_805_000_000))
        // 走真实校验路径：store 只落校验后的行（§6.5）。
        try store.applyReport(
            report(seq: 1, nodeID: node, windows: [first, second]),
            validation: FleetReportValidator.validate(
                report(seq: 1, nodeID: node, windows: [first, second])
            ),
            scope: scope
        )
        // 新报告只带一个范围：旧范围不删除（§5.1 / §7.6）。
        try store.applyReport(
            report(seq: 2, nodeID: node, windows: [second]),
            validation: FleetReportValidator.validate(
                report(seq: 2, nodeID: node, windows: [second])
            ),
            scope: scope
        )
        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.windowRows.count, 2)

        // 同范围重复上报 → upsert 覆盖，不重复行。
        try store.applyReport(
            report(seq: 3, nodeID: node, windows: [second, second]),
            validation: FleetReportValidator.validate(
                report(seq: 3, nodeID: node, windows: [second, second])
            ),
            scope: scope
        )
        let upserted = try store.loadHubState(scope: scope)
        XCTAssertEqual(upserted.nodes.first?.windowRows.count, 2)
    }

    func testObservedAtOverwrittenWithHubReceiveTime() throws {
        let node = UUID()
        let row = windowRow()
        let rawReport = report(seq: 1, nodeID: node, windows: [row])
        let receivedAt = Date(timeIntervalSince1970: 1_999_000_000)
        try store.applyReport(rawReport,
                              validation: FleetReportValidator.validate(rawReport),
                              scope: scope, receivedAt: receivedAt)
        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.windowRows.first?.observedAt, receivedAt,
                       "hub 用接收时刻覆盖不信任的上报 observedAt（§5.5）")
    }

    func testPruneWindowsRemovesOnlyExpiredAndKeepsNodeMeta() throws {
        let node = UUID()
        let old = windowRow(end: Date(timeIntervalSince1970: 1_000_000_000))
        let fresh = windowRow(end: Date(timeIntervalSince1970: 9_000_000_000))
        let reportWithWindows = report(seq: 1, nodeID: node, windows: [old, fresh])
        try store.applyReport(
            reportWithWindows,
            validation: FleetReportValidator.validate(reportWithWindows),
            scope: scope
        )

        let removed = try store.pruneWindows(scope: scope, olderThan: Date(timeIntervalSince1970: 5_000_000_000))
        XCTAssertEqual(removed, 1)
        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.windowRows.map(\.endAt), [fresh.endAt])
        XCTAssertEqual(state.nodes.first?.seq, 1, "窗口清理不丢 high-water（§7.6）")
    }

    // MARK: - 本机序号

    func testAllocateLocalSeqPersistsAndIncrements() throws {
        XCTAssertEqual(try store.allocateLocalSeq(), 1)
        XCTAssertEqual(try store.allocateLocalSeq(), 2)
        XCTAssertEqual(try store.allocateLocalSeq(), 3)
        // 重开（模拟进程重启）：序号延续，迟到报告可被 hub 的 high-water 拒绝。
        let reopened = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
        XCTAssertEqual(try reopened.allocateLocalSeq(), 4)
    }

    // MARK: - generation

    func testGenerationMonotonicAndPersistsAcrossReopen() throws {
        XCTAssertEqual(try store.generation(scope: scope), 0)
        try store.applyReport(report(seq: 1), validation: emptyValidation(), scope: scope)
        let afterFirst = try store.generation(scope: scope)
        XCTAssertGreaterThanOrEqual(afterFirst, 1)
        try store.applyReport(report(seq: 2), validation: emptyValidation(), scope: scope)
        let afterSecond = try store.generation(scope: scope)
        XCTAssertGreaterThan(afterSecond, afterFirst, "心跳更新也递增 generation（§5.2）")

        // 重开数据库：generation 跨重启可比（§5.2）。
        let reopened = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
        XCTAssertEqual(try reopened.generation(scope: scope), afterSecond)
    }

    // MARK: - 节点移除与信封信息

    func testRemoveNodeDeletesAllKinds() throws {
        let node = UUID()
        let reportWithWindows = report(
            seq: 1, nodeID: node, daily: buckets(input: 1), windows: [windowRow()]
        )
        try store.applyReport(
            reportWithWindows,
            validation: FleetReportValidator.validate(reportWithWindows),
            scope: scope
        )
        XCTAssertEqual(try store.loadHubState(scope: scope).nodes.count, 1)
        try store.removeNode(scope: scope, nodeID: node)
        XCTAssertEqual(try store.loadHubState(scope: scope).nodes.count, 0, "强制换 UUID 后旧节点可手动移除（§7.6）")
    }

    func testNodeNamePersistedWithEnvelope() throws {
        let node = UUID()
        try store.applyReport(
            report(seq: 1, nodeID: node, nodeName: "iMac-Studio"),
            validation: emptyValidation(),
            scope: scope
        )
        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.first?.report.nodeName, "iMac-Studio", "nodeName 随信封更新，快照装配要用")
        XCTAssertEqual(state.nodes.first?.report.timezoneID, "Asia/Shanghai")
    }

    // MARK: - 副节点快照缓存

    func testSnapshotCacheRoundTripAndGenerationGate() throws {
        let snapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: UUID(),
            generation: 7,
            hub: FleetNodeIdentity(nodeID: UUID(), nodeName: "hub", timezoneID: "Asia/Shanghai", platform: "macOS"),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            nodes: [],
            fleet: FleetAggregate(dailyBuckets: [], windowUsage: []),
            electedQuotas: []
        )
        let upstreamScope = "http://192.168.1.20:8787|\(snapshot.hubUUID.uuidString)"
        XCTAssertNil(try store.cachedSnapshotGeneration(upstreamScope: upstreamScope))
        try store.saveSnapshot(snapshot, upstreamScope: upstreamScope)
        XCTAssertEqual(try store.cachedSnapshotGeneration(upstreamScope: upstreamScope), 7)
        XCTAssertEqual(try store.loadSnapshot(upstreamScope: upstreamScope), snapshot)

        // 不同 upstream + hubUUID 的缓存互不干扰（§6.5 隔离）。
        let otherScope = "http://10.0.0.2:8787|\(UUID().uuidString)"
        XCTAssertNil(try store.loadSnapshot(upstreamScope: otherScope))
    }
}
