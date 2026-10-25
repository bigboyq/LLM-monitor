import XCTest
@testable import LLM_monitor

/// Fleet Sync 协议层：编解码往返、报告校验、合并/选举纯函数、归因指纹、角色派生。
/// 对应 `Models/SyncModels.swift`（设计稿 docs/reviews/fleet-sync-design.md）。
final class SyncModelsTests: XCTestCase {

    // MARK: - 测试工厂

    private func identity(nodeID: UUID = UUID()) -> FleetNodeIdentity {
        FleetNodeIdentity(nodeID: nodeID, nodeName: "MacBook-Pro", timezoneID: "Asia/Shanghai", platform: "macOS")
    }

    private func totals(
        input: Int = 0, cacheRead: Int = 0, output: Int = 0,
        reasoning: Int = 0, turns: Int = 0, rounds: Int = 0
    ) -> FleetTotals {
        FleetTotals(input: input, cacheRead: cacheRead, output: output,
                    reasoning: reasoning, turns: turns, rounds: rounds)
    }

    private func clientRow(
        client: String = ClientID.codex, provider: String = QuotaProviderID.openAI,
        input: Int = 0, cacheRead: Int = 0, output: Int = 0,
        reasoning: Int = 0, turns: Int = 0, rounds: Int = 0
    ) -> FleetClientProviderUsage {
        FleetClientProviderUsage(clientID: client, quotaProviderID: provider, input: input,
                                 cacheRead: cacheRead, output: output, reasoning: reasoning,
                                 turns: turns, rounds: rounds)
    }

    private func bucket(
        dayKey: String,
        rows: [FleetClientProviderUsage],
        entries: [FleetUsageEntry] = [],
        totalsComplete: Bool = true,
        truncated: Bool = false
    ) -> FleetDailyBucket {
        FleetDailyBucket(
            dayKey: dayKey,
            totals: FleetTotals(summing: rows),
            clientProviders: rows,
            entries: entries,
            totalsComplete: totalsComplete,
            modelDetailsComplete: !truncated,
            sourceTruncated: truncated
        )
    }

    private func sevenBuckets(
        rows: [FleetClientProviderUsage] = [],
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> [FleetDailyBucket] {
        FleetMerger.dayKeyWindow(now: now).map { bucket(dayKey: $0, rows: rows) }
    }

    private func report(
        seq: Int = 1,
        nodeID: UUID = UUID(),
        daily: [FleetDailyBucket]? = nil,
        windows: [FleetWindowUsage]? = nil,
        quotas: [FleetQuotaReport]? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> NodeUsageReport {
        NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: identity(nodeID: nodeID),
            seq: seq,
            generatedAt: now,
            attributionFingerprint: "deadbeef",
            dailyBuckets: daily,
            windowUsage: windows,
            quotas: quotas
        )
    }

    private func windowRow(
        provider: String = QuotaProviderID.openAI,
        model: String = "chatgpt_plan",
        kind: String = "interval",
        start: Date = Date(timeIntervalSince1970: 1_799_000_000),
        end: Date = Date(timeIntervalSince1970: 1_800_000_000),
        input: Int = 10, cacheRead: Int = 20, output: Int = 30, reasoning: Int = 0,
        value: Double? = 0.12, currency: ModelPriceCurrency? = .usd,
        coverage: FleetCostCoverage = .full, complete: Bool = true, truncated: Bool = false
    ) -> FleetWindowUsage {
        FleetWindowUsage(
            quotaProviderID: provider, modelID: model, windowKind: kind,
            startAt: start, endAt: end, observedAt: end,
            input: input, cacheRead: cacheRead, output: output, reasoning: reasoning,
            value: value, currency: currency, coverage: coverage,
            complete: complete, sourceTruncated: truncated
        )
    }

    private func quota(
        provider: String = QuotaProviderID.openAI,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        activeWindow: Bool = true
    ) -> FleetQuotaReport {
        FleetQuotaReport(
            quotaProviderID: provider,
            fetchedAt: fetchedAt,
            models: [Self.modelQuota(active: activeWindow)],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "user@example.com",
            balanceDetail: nil
        )
    }

    private static func modelQuota(active: Bool = true, zeroRemaining: Bool = false) -> ModelQuota {
        ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 100,
            intervalUsageCount: zeroRemaining ? 100 : 40,
            intervalRemainingPercent: zeroRemaining ? 0 : 60,
            intervalStatus: active ? .present : .absent,
            intervalResetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 1000,
            weeklyUsageCount: zeroRemaining ? 1000 : 400,
            weeklyRemainingPercent: zeroRemaining ? 0 : 60,
            weeklyStatus: active ? .present : .absent,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_805_000_000),
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
    }

    // MARK: - 编解码

    func testCodecRoundTripPreservesISO8601Dates() throws {
        let original = report(
            daily: sevenBuckets(rows: [clientRow(input: 1)]),
            windows: [windowRow()],
            quotas: [quota()]
        )
        let data = try FleetCodec.encode(original)
        let decoded = try FleetCodec.decode(NodeUsageReport.self, from: data)
        XCTAssertEqual(decoded, original, "iso8601 出网/入网必须无损往返")
    }

    func testCodecDateStrategyIsISO8601NotReferenceDate() throws {
        let original = report(seq: 7)
        let data = try FleetCodec.encode(original)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("generatedAt"), "字段名应保留")
        XCTAssertFalse(text.contains("\"generatedAt\":7"), "Date 不能被编成 2001 基准 Double（§5.3 实现约束）")
        XCTAssertTrue(text.contains("T"), "iso8601 字符串应带 T 分隔")
    }

    // MARK: - 角色派生

    func testSyncRoleDerivesFromHubURL() {
        var config = AppConfig.default
        XCTAssertEqual(SyncRole.derive(config: config), .off, "未配置 sync = 不参与")

        config.sync = SyncConfig(enabled: false, hubURL: "http://1.2.3.4:8787")
        XCTAssertEqual(SyncRole.derive(config: config), .off, "enabled=false 一票否决")

        config.sync = SyncConfig(enabled: true, hubURL: "")
        XCTAssertEqual(SyncRole.derive(config: config), .hub, "hubURL 空 = 主节点")

        config.sync = SyncConfig(enabled: true, hubURL: "http://192.168.1.20:8787")
        XCTAssertEqual(SyncRole.derive(config: config), .node, "hubURL 非空 = 副节点，且不监听端口")
    }

    // MARK: - 校验（§5.6）

    func testValidationAcceptsWellFormedReport() {
        let result = FleetReportValidator.validate(report(
            daily: sevenBuckets(rows: [clientRow(input: 5)]),
            windows: [windowRow()],
            quotas: [quota()]
        ))
        XCTAssertNil(result.envelopeError)
        XCTAssertNil(result.dailyBucketsError)
        XCTAssertNil(result.quotasError)
        XCTAssertEqual(result.windowRows.count, 1)
        XCTAssertEqual(result.windowDroppedRowCount, 0)
    }

    func testValidationRejectsWrongBucketCount() {
        let six = Array(sevenBuckets().dropLast())
        let result = FleetReportValidator.validate(report(daily: six))
        XCTAssertNotNil(result.dailyBucketsError, "必须恰有七个日桶")
    }

    func testValidationRejectsTotalsMismatch() {
        var rows = sevenBuckets()
        var bad = rows[6]
        bad = FleetDailyBucket(
            dayKey: bad.dayKey,
            totals: totals(input: 999),
            clientProviders: bad.clientProviders,
            entries: bad.entries,
            totalsComplete: true,
            modelDetailsComplete: true,
            sourceTruncated: false
        )
        rows[6] = bad
        let result = FleetReportValidator.validate(report(daily: rows))
        XCTAssertNotNil(result.dailyBucketsError, "totals 与 clientProviders 汇总不一致要拒收日桶通道")
    }

    func testValidationRejectsUnknownProviderAndDuplicateDayKey() {
        var rows = sevenBuckets(rows: [clientRow(provider: "not-a-provider")])
        let result = FleetReportValidator.validate(report(daily: rows))
        XCTAssertNotNil(result.dailyBucketsError, "未注册 provider ID 拒收")

        rows = sevenBuckets()
        rows[0] = FleetDailyBucket(
            dayKey: rows[1].dayKey, totals: .zero, clientProviders: [], entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        XCTAssertNotNil(FleetReportValidator.validate(report(daily: rows)).dailyBucketsError, "重复 dayKey 拒收")
    }

    func testValidationDropsBadWindowRowsIndividually() {
        let badBoundary = windowRow(start: Date(timeIntervalSince1970: 1_800_000_000),
                                    end: Date(timeIntervalSince1970: 1_799_000_000))
        let unknownProvider = windowRow(provider: "nope")
        let unpairedAmount = windowRow(value: 1.0, currency: nil)
        let good = windowRow()
        let result = FleetReportValidator.validate(report(windows: [badBoundary, unknownProvider, unpairedAmount, good]))
        XCTAssertEqual(result.windowRows, [good], "行级失败只丢该行，不整通道拒绝")
        XCTAssertEqual(result.windowDroppedRowCount, 3)
    }

    func testValidationEnvelopeRejectsVersionMismatch() {
        let bad = NodeUsageReport(
            protocolVersion: 99,
            node: identity(),
            seq: 1,
            generatedAt: Date(),
            attributionFingerprint: "",
            dailyBuckets: nil,
            windowUsage: nil,
            quotas: nil
        )
        XCTAssertNotNil(FleetReportValidator.validate(bad).envelopeError, "protocolVersion 不匹配整包拒绝")
    }

    // MARK: - 日桶合并（§7.1）

    func testMergeDailyBucketsSumsAuthoritativeTotals() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dayA = FleetMerger.dayKeyWindow(now: now)[6]
        let node1 = [bucket(dayKey: dayA, rows: [clientRow(input: 10, output: 5)])]
        let node2 = [bucket(dayKey: dayA, rows: [clientRow(input: 32, output: 8)])]
        let merged = FleetMerger.mergeDailyBuckets([node1, node2], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].totals.input, 42)
        XCTAssertEqual(merged[0].totals.output, 13)
        XCTAssertEqual(merged[0].clientProviders.count, 1, "同 (client, provider) 相加而不是并列两行")
    }

    func testMergeCoverageFullPlusNoneIsPartial() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now)[6]
        // 同键（client/provider/model）的两份贡献：一份有价、一份无价。
        let priced = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: 0.5, currency: .usd, coverage: .full, truncated: false
        )
        let unpriced = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: nil, currency: nil, coverage: .none, truncated: false
        )
        let node1 = [bucket(dayKey: day, rows: [], entries: [priced])]
        let node2 = [bucket(dayKey: day, rows: [], entries: [unpriced])]
        let merged = FleetMerger.mergeDailyBuckets([node1, node2], now: now)
        XCTAssertEqual(merged[0].entries.count, 1, "同键合并成一行")
        XCTAssertEqual(merged[0].entries[0].coverage, .partial, "full + none → partial（§7.1 / §10.7.2）")
        XCTAssertEqual(merged[0].entries[0].input, 2)
        XCTAssertEqual(merged[0].entries[0].value, 0.5, "金额只覆盖有价贡献")
    }

    func testMergeTruncatedEntryCannotBeFullEvenIfPriced() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now)[6]
        let entry = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: 0.5, currency: .usd, coverage: .full, truncated: true
        )
        let merged = FleetMerger.mergeDailyBuckets([[bucket(dayKey: day, rows: [], entries: [entry])]], now: now)
        XCTAssertEqual(merged[0].entries[0].coverage, .partial, "截尾样本的金额不能配完整 token 标 full")
    }

    func testMergeFlagsTotalsIncompleteWhenAnyNodeIncomplete() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now)[6]
        let complete = [bucket(dayKey: day, rows: [], totalsComplete: true)]
        let incomplete = [bucket(dayKey: day, rows: [], totalsComplete: false)]
        let merged = FleetMerger.mergeDailyBuckets([complete, incomplete], now: now)
        XCTAssertFalse(merged[0].totalsComplete, "任一节点 totals 不完整 → fleet 不完整")
    }

    // MARK: - 窗口聚合（§7.1 / §10.7.1）

    func testWindowAggregationOnlyMergesIdenticalRanges() {
        let node1 = UUID(), node2 = UUID(), node3 = UUID()
        let sameRange = windowRow(input: 100)
        let differentEnd = windowRow(end: Date(timeIntervalSince1970: 1_800_050_000), input: 7)
        let result = FleetMerger.aggregateWindows(
            [
                .init(nodeID: node1, stale: false, rows: [sameRange, differentEnd]),
                .init(nodeID: node2, stale: true, rows: [sameRange]),
                .init(nodeID: node3, stale: false, rows: []),
            ],
            knownNodeIDs: [node1, node2, node3]
        )
        XCTAssertEqual(result.count, 2, "范围不同不混加")
        let aggregate = try! XCTUnwrap(result.first { $0.input == 200 })
        XCTAssertEqual(aggregate.input, 200, "边界完全相同的两份贡献相加（100+100）")
        XCTAssertEqual(Set(aggregate.staleNodeIDs), [node2], "stale 节点同范围仍贡献并标注")
        XCTAssertEqual(aggregate.missingNodeIDs, [node3], "缺该范围的已知节点进 missingNodeIDs")
        XCTAssertEqual(result.first { $0.input == 7 }?.windowKind, "interval")
    }

    func testWindowAggregationKeepsCurrenciesSeparateInValueMap() {
        let node = UUID()
        let usd = windowRow(value: 1.5, currency: .usd)
        let cny = windowRow(value: 9.9, currency: .cny)
        let result = FleetMerger.aggregateWindows(
            [.init(nodeID: node, stale: false, rows: [usd, cny])],
            knownNodeIDs: [node]
        )
        XCTAssertEqual(result.count, 1, "同范围同键合并为一行")
        XCTAssertEqual(result[0].valueByCurrency["USD"], 1.5, "金额按币种分开保存，不做跨币种折算合并")
        XCTAssertEqual(result[0].valueByCurrency["CNY"], 9.9)
    }

    // MARK: - 额度选举（§2.1 / §7.7，M 裁定 = fetchedAt）

    func testElectionPrefersHubLocalQuotaEvenWhenStaler() {
        let hub = UUID()
        let hubQuota = quota(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let nodeQuota = quota(fetchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let elected = FleetMerger.electQuotas(
            candidates: [
                .init(sourceNodeID: hub, sourceNodeName: "hub", report: hubQuota),
                .init(sourceNodeID: UUID(), sourceNodeName: "node", report: nodeQuota),
            ],
            hubNodeID: hub,
            quotaMaxAgeSeconds: 1800,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(elected.count, 1)
        XCTAssertEqual(elected[0].sourceNodeID, hub, "hub 有有效本机额度就以自己为准")
        XCTAssertTrue(elected[0].isStale, "过期只标 stale，不淘汰")
    }

    func testElectionPicksFreshestFetchedAtAmongNodes() {
        let hub = UUID()
        let oldButRecentlyReported = UUID()
        let fresh = UUID()
        let elected = FleetMerger.electQuotas(
            candidates: [
                .init(sourceNodeID: oldButRecentlyReported, sourceNodeName: "A",
                      report: quota(fetchedAt: Date(timeIntervalSince1970: 1_600_000_000))),
                .init(sourceNodeID: fresh, sourceNodeName: "B",
                      report: quota(fetchedAt: Date(timeIntervalSince1970: 1_799_000_000))),
            ],
            hubNodeID: hub,
            quotaMaxAgeSeconds: 1800,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(elected[0].sourceNodeID, fresh, "副节点候选按 fetchedAt（不是上报时刻），2026-10-24 裁定")
        XCTAssertEqual(elected[0].sourceNodeName, "B")
    }

    func testElectionDeepSeekZeroBalanceIsValid() {
        let hub = UUID(), node = UUID()
        let zeroBalance = FleetQuotaReport(
            quotaProviderID: QuotaProviderID.deepseek,
            fetchedAt: Date(timeIntervalSince1970: 1_799_000_000),
            models: [Self.modelQuota(active: true, zeroRemaining: true)],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            balanceDetail: DeepseekBalanceDetail(currency: "CNY", total: 0, toppedUp: 0, granted: 0)
        )
        let elected = FleetMerger.electQuotas(
            candidates: [.init(sourceNodeID: node, sourceNodeName: "n", report: zeroBalance)],
            hubNodeID: hub,
            quotaMaxAgeSeconds: 1800,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(elected.count, 1, "present 余额窗口（含 0%）符合有效性")
        XCTAssertEqual(elected[0].quotaProviderID, QuotaProviderID.deepseek)
    }

    func testElectionSkipsQuotaWithoutActiveWindow() {
        let hub = UUID(), node = UUID()
        let inactive = quota(activeWindow: false)
        let elected = FleetMerger.electQuotas(
            candidates: [.init(sourceNodeID: node, sourceNodeName: "n", report: inactive)],
            hubNodeID: hub,
            quotaMaxAgeSeconds: 1800,
            now: Date()
        )
        XCTAssertTrue(elected.isEmpty, "没有任何活跃窗口的额度不参加选举")
    }

    // MARK: - 归因指纹（§7.8）

    func testAttributionFingerprintStableAndSensitive() {
        let bindings = ClientProviderBinding.defaultBindings
        let first = FleetAttributionFingerprint.compute(bindings)
        XCTAssertEqual(first.count, 8, "SHA256 前 8 个十六进制字符")
        XCTAssertEqual(first, FleetAttributionFingerprint.compute(bindings.shuffled()), "顺序无关")
        XCTAssertEqual(first, FleetAttributionFingerprint.compute(bindings), "跨调用稳定")

        var changedAlias = bindings
        changedAlias[0].sourceProviderAliases.append("new-alias")
        XCTAssertNotEqual(first, FleetAttributionFingerprint.compute(changedAlias), "别名表变化 → 指纹变化")

        var changedEnabled = bindings
        changedEnabled[0].enabled.toggle()
        XCTAssertNotEqual(first, FleetAttributionFingerprint.compute(changedEnabled), "enabled 变化 → 指纹变化")
    }

    // MARK: - dayKey 工具

    func testDayKeyWindowIsSevenAscendingDaysEndingToday() {
        let calendar = Calendar(identifier: .gregorian)
        var beijing = calendar
        beijing.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keys = FleetMerger.dayKeyWindow(now: now, calendar: beijing)
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(Set(keys).count, 7)
        XCTAssertEqual(keys.last, FleetMerger.dayKey(of: now, calendar: beijing), "最后一项是今天")
        XCTAssertEqual(keys.first, FleetMerger.dayKey(
            of: beijing.date(byAdding: .day, value: -6, to: now)!, calendar: beijing
        ), "第一项是六天前")
    }

    func testTotalsMatchesClientProviderSum() {
        let rows = [clientRow(input: 3, cacheRead: 4, output: 5, reasoning: 6, turns: 7, rounds: 8),
                    clientRow(client: ClientID.dsh, provider: QuotaProviderID.zhipu, input: 30)]
        let totals = FleetTotals(summing: rows)
        XCTAssertTrue(totals == rows)
        XCTAssertEqual(totals.input, 33)
        XCTAssertEqual(totals.rounds, 8)
    }
}
