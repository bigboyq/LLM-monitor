import XCTest
import SQLite3
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

    func testPartialDayReportMergesPerDayKey() throws {
        // 增量裁定 2026-10-24：只带部分天的报告按 dayKey upsert，缺席的天保留旧值。
        let node = UUID()
        try store.applyReport(
            report(seq: 1, nodeID: node, daily: buckets(input: 100)),
            validation: emptyValidation(),
            scope: scope
        )

        let todayKey = buckets(input: 0).last!.dayKey
        let revisedRows = [FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 200, cacheRead: 0, output: 0, reasoning: 0, turns: 0, rounds: 0
        )]
        let today = FleetDailyBucket(
            dayKey: todayKey, totals: FleetTotals(summing: revisedRows),
            clientProviders: revisedRows, entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let outcome = try store.applyReport(
            report(seq: 2, nodeID: node, daily: [today]),
            validation: FleetReportValidator.validate(report(seq: 2, nodeID: node, daily: [today])),
            scope: scope
        )
        XCTAssertTrue(outcome.dailyApplied)

        let stored = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets)
        XCTAssertEqual(stored.count, 7, "未补发的天不丢失")
        XCTAssertEqual(stored.last?.dayKey, todayKey)
        XCTAssertEqual(stored.last?.totals.input, 200, "补发的天被新值替换")
        XCTAssertEqual(stored.first?.totals.input, 100, "旧天保留原值")
    }

    func testSourceAwareDailyUpsertRetainsUnavailableReplacesHealthyAndAcknowledgesInput() throws {
        let node = UUID()
        let day = buckets(input: 0).last!.dayKey
        let codexOld = FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
        )
        let dshOld = FleetClientProviderUsage(
            clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek,
            input: 50, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
        )
        func entry(_ row: FleetClientProviderUsage, model: String) -> FleetUsageEntry {
            FleetUsageEntry(
                clientID: row.clientID, quotaProviderID: row.quotaProviderID, modelName: model,
                input: row.input, cacheRead: row.cacheRead, output: row.output, reasoning: row.reasoning,
                value: nil, currency: nil, coverage: .none, truncated: false
            )
        }
        let original = FleetDailyBucket(
            dayKey: day, totals: FleetTotals(summing: [codexOld, dshOld]),
            clientProviders: [codexOld, dshOld],
            entries: [entry(codexOld, model: "gpt"), entry(dshOld, model: "deepseek")],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let first = report(seq: 1, nodeID: node, daily: [original])
        try store.applyReport(first, validation: FleetReportValidator.validate(first), scope: scope)

        let codexUpdated = FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 120, cacheRead: 0, output: 0, reasoning: 0, turns: 2, rounds: 1
        )
        let unavailable = FleetDailyUnavailableSource(
            clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek, reason: .failed
        )
        let partial = FleetDailyBucket(
            dayKey: day, totals: FleetTotals(summing: [codexUpdated]),
            clientProviders: [codexUpdated], entries: [entry(codexUpdated, model: "gpt")],
            totalsComplete: false, modelDetailsComplete: false, sourceTruncated: false,
            unavailableSources: [unavailable]
        )
        let second = report(seq: 2, nodeID: node, daily: [partial])
        let applied = try store.applyReport(second, validation: FleetReportValidator.validate(second), scope: scope)
        XCTAssertTrue(applied.dailyApplied)

        let storedReport = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report)
        let merged = try XCTUnwrap(storedReport.dailyBuckets?.first)
        XCTAssertEqual(merged.clientProviders.map(\.input), [120, 50])
        XCTAssertEqual(merged.totals.input, 170)
        XCTAssertFalse(merged.totalsComplete)
        XCTAssertEqual(Set(merged.entries.compactMap(\.modelName)), Set(["gpt", "deepseek"]))
        XCTAssertEqual(storedReport.dailyInputDigests?[day], FleetDailyDigest.digest(partial),
                       "ACK记住部分输入摘要而不是合并后存桶的摘要")
        XCTAssertNotEqual(storedReport.dailyInputDigests?[day], FleetDailyDigest.digest(merged))

        // 同一 partial 输入即使再次到达，落库和ACK都稳定，不会把保留行再累加一份。
        let repeated = report(seq: 3, nodeID: node, daily: [partial])
        try store.applyReport(repeated, validation: FleetReportValidator.validate(repeated), scope: scope)
        let afterRepeat = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report)
        XCTAssertEqual(afterRepeat.dailyBuckets?.first?.totals.input, 170)
        XCTAssertEqual(afterRepeat.dailyInputDigests?[day], FleetDailyDigest.digest(partial))

        // 来源恢复后完整桶替换整天，不重复合并旧失败值。
        let codexRecovered = codexUpdated
        let dshRecovered = FleetClientProviderUsage(
            clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek,
            input: 60, cacheRead: 0, output: 0, reasoning: 0, turns: 2, rounds: 1
        )
        let recovered = FleetDailyBucket(
            dayKey: day, totals: FleetTotals(summing: [codexRecovered, dshRecovered]),
            clientProviders: [codexRecovered, dshRecovered],
            entries: [entry(codexRecovered, model: "gpt"), entry(dshRecovered, model: "deepseek")],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let fourth = report(seq: 4, nodeID: node, daily: [recovered])
        try store.applyReport(fourth, validation: FleetReportValidator.validate(fourth), scope: scope)
        let afterRecovery = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets?.first)
        XCTAssertEqual(afterRecovery.totals.input, 180)
        XCTAssertTrue(afterRecovery.totalsComplete)
        XCTAssertNil(afterRecovery.unavailableSources, "完整legacy桶继续使用原有whole-day形状")

        // 完整来源扫描可确认真实零量；未出现的旧来源（例如已禁用）必须清掉。
        let zero = FleetDailyBucket(
            dayKey: day, totals: .zero, clientProviders: [], entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false,
            unavailableSources: []
        )
        let fifth = report(seq: 5, nodeID: node, daily: [zero])
        try store.applyReport(fifth, validation: FleetReportValidator.validate(fifth), scope: scope)
        let afterZero = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets?.first)
        XCTAssertEqual(afterZero.totals, .zero)
        XCTAssertTrue(afterZero.clientProviders.isEmpty, "健康来源确认零量时旧贡献被删除")
        XCTAssertEqual(afterZero.unavailableSources, [])

        // 可选digest映射随report payload跨Store重启保存。
        let zeroDigest = FleetDailyDigest.digest(zero)
        store = nil
        store = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
        let reloaded = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report)
        XCTAssertEqual(reloaded.dailyInputDigests?[day], zeroDigest)
    }

    func testFirstPartialReportShowsHealthySourceWithNoPriorStoredBucket() throws {
        let node = UUID()
        let day = buckets(input: 0).last!.dayKey
        let codex = FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 25, cacheRead: 0, output: 4, reasoning: 0, turns: 1, rounds: 1
        )
        let bucket = FleetDailyBucket(
            dayKey: day, totals: FleetTotals(summing: [codex]),
            clientProviders: [codex], entries: [], totalsComplete: false,
            modelDetailsComplete: false, sourceTruncated: false,
            unavailableSources: [FleetDailyUnavailableSource(
                clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek, reason: .failed
            )]
        )
        let incoming = report(seq: 1, nodeID: node, daily: [bucket])
        XCTAssertNil(FleetReportValidator.validate(incoming).dailyBucketsError)
        try store.applyReport(incoming, validation: FleetReportValidator.validate(incoming), scope: scope)

        let stored = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets?.first)
        XCTAssertEqual(stored.totals.input, 25, "空scope首次接收也显示健康provider贡献")
        XCTAssertEqual(stored.clientProviders.map(\.clientID), [ClientID.codex])
        XCTAssertEqual(stored.unavailableSources?.map(\.sourceKey), ["\(ClientID.dsh)|\(QuotaProviderID.deepseek)"])
        XCTAssertFalse(stored.totalsComplete, "保留partial标志，不能伪装成完整总量")
    }

    func testDailyBucketsOutsideWindowAreDroppedOnUpsert() throws {
        // 日切回归：节点的报告窗口逐日滚动（今天 + 前六天），hub 落库必须
        // 只保留最新的 7 天 —— 只增不删会让快照载荷逐日变大（越过 2 MiB 上限
        // → 全员 500），节点卡片也会画出 N 根柱子而不是 7 根。
        let node = UUID()
        let first = self.report(seq: 1, nodeID: node, daily: buckets(input: 100))
        try store.applyReport(
            first,
            validation: FleetReportValidator.validate(first),
            scope: scope
        )
        var stored = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets)
        XCTAssertEqual(stored.count, 7, "首拍就是七天窗口")
        let oldestBefore = stored.first?.dayKey

        // 第二天：报告带一个更新的 dayKey（节点窗口前移一天）。
        let rows = [FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 0, rounds: 0
        )]
        let newerKey = "2999-01-01"
        let newerBucket = FleetDailyBucket(
            dayKey: newerKey, totals: FleetTotals(summing: rows),
            clientProviders: rows, entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let second = self.report(seq: 2, nodeID: node, daily: [newerBucket])
        try store.applyReport(
            second,
            validation: FleetReportValidator.validate(second),
            scope: scope
        )

        stored = try XCTUnwrap(store.loadHubState(scope: scope).nodes.first?.report.dailyBuckets)
        XCTAssertEqual(stored.count, 7, "滚出窗口的天被裁掉，存量不增")
        XCTAssertTrue(stored.contains { $0.dayKey == newerKey }, "新的一天留下")
        XCTAssertFalse(stored.contains { $0.dayKey == oldestBefore }, "最老的一天被裁掉")
    }

    func testCorruptWindowRowDoesNotBreakHubState() throws {
        // 一条坏行不能让整次装配失败：原来 loadHubState 抛错 → hub 对所有
        // 节点都回 500（一次坏行 = 全员中断）。
        let node = UUID()
        let report = self.report(seq: 1, nodeID: node, daily: buckets(input: 100), windows: [windowRow()])
        try store.applyReport(
            report,
            validation: FleetReportValidator.validate(report),
            scope: scope
        )

        // 直接往库里塞一条无法解码的 payload（跨版本 DTO 形状变化写下的旧行 /
        // 磁盘损坏都长这样）。
        let dbPath = directory.appendingPathComponent("fleet.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO sync_records (kind, scope, node_id, record_key, seq, generation, updated_at, payload_json)
            VALUES ('window', '\(scope)', '\(node.uuidString)', 'broken', 1, NULL, 0, X'7b7b7b')
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let generationBeforeCleanup = try store.generation(scope: scope)
        let state = try store.loadHubState(scope: scope)
        XCTAssertEqual(state.nodes.count, 1, "坏行不影响其他节点的读出")
        XCTAssertEqual(state.nodes.first?.windowRows.count, 1, "好行照常读出")
        XCTAssertEqual(state.generation, generationBeforeCleanup + 1,
                       "清理坏窗口行属于可见状态变化，必须递增 generation")

        let generationAfterCleanup = try store.generation(scope: scope)
        _ = try store.loadHubState(scope: scope)
        XCTAssertEqual(try store.generation(scope: scope), generationAfterCleanup,
                       "坏行只清理一次，不重复递增 generation")
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

    func testPruneWindowsCorruptOnlyCleanupAdvancesGenerationOnce() throws {
        let node = UUID()
        let fresh = windowRow(end: Date(timeIntervalSince1970: 9_000_000_000))
        let reportWithWindow = report(seq: 1, nodeID: node, windows: [fresh])
        try store.applyReport(
            reportWithWindow,
            validation: FleetReportValidator.validate(reportWithWindow),
            scope: scope
        )

        let dbPath = directory.appendingPathComponent("fleet.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO sync_records (kind, scope, node_id, record_key, seq, generation, updated_at, payload_json)
            VALUES ('window', '\(scope)', '\(node.uuidString)', 'broken-prune', 1, NULL, 0, X'7b7b7b')
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let before = try store.generation(scope: scope)
        XCTAssertEqual(try store.pruneWindows(scope: scope, olderThan: Date(timeIntervalSince1970: 1)), 0,
                       "仅清坏行不计作过期有效窗口")
        let after = try store.generation(scope: scope)
        XCTAssertEqual(after, before + 1, "prune 删除坏行也要让快照 generation 可见变化")
        XCTAssertEqual(try store.loadHubState(scope: scope).nodes.first?.windowRows.count, 1,
                       "清坏行保留未过期有效窗口")
        _ = try store.pruneWindows(scope: scope, olderThan: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(try store.generation(scope: scope), after, "再次 prune 不重复增长 generation")
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
