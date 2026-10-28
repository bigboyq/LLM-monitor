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
            startAt: start, endAt: end,
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

    func testValidationAcceptsPartialDayChannelAndRejectsOverSeven() {
        // 增量裁定 2026-10-24：通道可只带部分天（补发/修正），0–7 桶合法。
        let single = [sevenBuckets()[6]]
        XCTAssertNil(FleetReportValidator.validate(report(daily: single)).dailyBucketsError,
                     "只带今天的部分通道应通过校验")

        var eight = sevenBuckets()
        eight.append(FleetDailyBucket(
            dayKey: "2020-01-01", totals: .zero, clientProviders: [], entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        ))
        XCTAssertNotNil(FleetReportValidator.validate(report(daily: eight)).dailyBucketsError,
                        "超过 7 桶仍拒收")
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

    func testDayKeyRequiresASCIIZeroPaddedRealGregorianDate() {
        XCTAssertTrue(FleetReportValidator.isValidDayKey("2024-02-29"), "有效闰日通过")
        XCTAssertTrue(FleetReportValidator.isValidDayKey("2000-02-29"), "400 年规则下的闰日通过")
        XCTAssertFalse(FleetReportValidator.isValidDayKey("2024-02-31"), "不存在的日期拒收")
        XCTAssertFalse(FleetReportValidator.isValidDayKey("2023-02-29"), "非闰年的 2 月 29 日拒收")
        XCTAssertFalse(FleetReportValidator.isValidDayKey("2024-2-09"), "月份必须补零")
        XCTAssertFalse(FleetReportValidator.isValidDayKey("2024-02-9"), "日期必须补零")
        XCTAssertFalse(FleetReportValidator.isValidDayKey("２０２４-02-29"), "只接受 ASCII 数字")
    }

    func testValidationRejectsIncompleteDailyTotalsWithoutBlockingOtherChannels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now)[6]
        let incomplete = bucket(dayKey: day, rows: [], totalsComplete: false, truncated: true)
        let validation = FleetReportValidator.validate(report(
            daily: [incomplete], windows: [windowRow()], quotas: [quota()], now: now
        ))
        XCTAssertNotNil(validation.dailyBucketsError, "不完整日桶不能替换 hub 的权威桶")
        XCTAssertEqual(validation.windowRows.count, 1, "日桶拒绝不阻断有效窗口行")
        XCTAssertNil(validation.quotasError, "日桶拒绝不阻断有效额度通道")
    }

    func testSourceAwarePartialDailyBucketValidatesAndRejectsUnavailableRows() {
        let day = FleetMerger.dayKeyWindow(now: Date(timeIntervalSince1970: 1_800_000_000)).last!
        let healthy = clientRow(input: 12)
        let unavailable = FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            reason: .failed
        )
        let partial = FleetDailyBucket(
            dayKey: day,
            totals: FleetTotals(summing: [healthy]),
            clientProviders: [healthy],
            entries: [],
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: false,
            unavailableSources: [unavailable]
        )
        XCTAssertNil(FleetReportValidator.validate(report(daily: [partial])).dailyBucketsError,
                     "明确标记未覆盖来源时，健康来源仍可落库")

        let conflictingRow = clientRow(client: ClientID.dsh, provider: QuotaProviderID.deepseek, input: 7)
        let inconsistent = FleetDailyBucket(
            dayKey: day,
            totals: FleetTotals(summing: [healthy, conflictingRow]),
            clientProviders: [healthy, conflictingRow],
            entries: [],
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: false,
            unavailableSources: [unavailable]
        )
        XCTAssertNotNil(FleetReportValidator.validate(report(daily: [inconsistent])).dailyBucketsError,
                       "不可用来源不能同时出现在本次行数据中")

        let duplicate = FleetDailyBucket(
            dayKey: day,
            totals: FleetTotals(summing: [healthy]),
            clientProviders: [healthy],
            entries: [],
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: false,
            unavailableSources: [unavailable, unavailable]
        )
        XCTAssertNotNil(FleetReportValidator.validate(report(daily: [duplicate])).dailyBucketsError,
                       "同一来源重复声明必须拒收")
    }

    func testDayKeysUseGregorianCalendarAndKeepCallerTimezone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let boundary = utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30))!

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var beijingGregorian = Calendar(identifier: .gregorian)
        beijingGregorian.timeZone = buddhist.timeZone
        let buddhistKey = FleetMerger.dayKey(of: boundary, calendar: buddhist)
        XCTAssertEqual(buddhistKey, "2026-10-25")
        XCTAssertTrue(FleetReportValidator.isValidDayKey(buddhistKey))
        XCTAssertEqual(
            FleetMerger.dayKeyWindow(now: boundary, calendar: buddhist),
            FleetMerger.dayKeyWindow(now: boundary, calendar: beijingGregorian),
            "非Gregorian系统日历仍应按同一时区产出Gregorian窗口"
        )
        let bucket = bucket(dayKey: buddhistKey, rows: [])
        XCTAssertEqual(
            FleetMerger.mergeDailyBuckets([[bucket]], now: boundary, calendar: buddhist).map(\.dayKey),
            [buddhistKey],
            "生成、校验和hub窗口筛选采用同一种Gregorian日键"
        )

        var losAngelesJapanese = Calendar(identifier: .japanese)
        losAngelesJapanese.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var losAngelesGregorian = Calendar(identifier: .gregorian)
        losAngelesGregorian.timeZone = losAngelesJapanese.timeZone
        let japaneseKey = FleetMerger.dayKey(of: boundary, calendar: losAngelesJapanese)
        XCTAssertEqual(japaneseKey, "2026-10-24", "日界使用输入calendar的时区")
        XCTAssertTrue(FleetReportValidator.isValidDayKey(japaneseKey))
        XCTAssertEqual(
            FleetMerger.dayKeyWindow(now: boundary, calendar: losAngelesJapanese),
            FleetMerger.dayKeyWindow(now: boundary, calendar: losAngelesGregorian)
        )
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

    func testMergeDailyBucketsPropagatesPartialSourceCoverage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now).last!
        let unavailable = FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            reason: .truncated
        )
        let partial = FleetDailyBucket(
            dayKey: day,
            totals: FleetTotals(summing: [clientRow(input: 10)]),
            clientProviders: [clientRow(input: 10)],
            entries: [],
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: true,
            unavailableSources: [unavailable]
        )
        let complete = bucket(dayKey: day, rows: [clientRow(input: 5)])
        let merged = try XCTUnwrap(FleetMerger.mergeDailyBuckets([[partial], [complete]], now: now).first)
        XCTAssertEqual(merged.totals.input, 15)
        XCTAssertFalse(merged.totalsComplete)
        XCTAssertFalse(merged.modelDetailsComplete)
        XCTAssertTrue(merged.sourceTruncated)
        XCTAssertEqual(merged.unavailableSources, [unavailable])
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

    func testMergeCoveragePreservesPartialEntryWithAmount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FleetMerger.dayKeyWindow(now: now)[6]
        let partial = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 10, cacheRead: 0, output: 2, reasoning: 0,
            value: 0.5, currency: .usd, coverage: .partial, truncated: false
        )
        let merged = FleetMerger.mergeDailyBuckets(
            [[bucket(dayKey: day, rows: [], entries: [partial])]], now: now
        )
        XCTAssertEqual(merged.first?.entries.first?.coverage, .partial,
                       "已有金额不代表所有输入样本均已计价")

        let partialWithoutAggregateAmount = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: nil, currency: nil, coverage: .partial, truncated: false
        )
        let stillPartial = FleetMerger.mergeDailyBuckets(
            [[bucket(dayKey: day, rows: [], entries: [partialWithoutAggregateAmount])]], now: now
        )
        XCTAssertEqual(stillPartial.first?.entries.first?.coverage, .partial,
                       "原partial状态不能因本行没有可合并金额而丢失")

        let malformedNoneWithAmount = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.1", input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: 0.1, currency: .usd, coverage: .none, truncated: false
        )
        let conservative = FleetMerger.mergeDailyBuckets(
            [[bucket(dayKey: day, rows: [], entries: [malformedNoneWithAmount])]], now: now
        )
        XCTAssertEqual(conservative.first?.entries.first?.coverage, .partial,
                       "none+amount 的不一致wire行不得升级为full")
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

    func testWindowFrontierKeepsNewestBoundariesPerGroup() {
        func aggregate(end: TimeInterval, kind: String = "interval") -> FleetWindowAggregate {
            let endAt = Date(timeIntervalSince1970: end)
            return FleetWindowAggregate(
                quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: kind,
                startAt: endAt.addingTimeInterval(-18_000), endAt: endAt,
                input: Int(end - 1_798_000_000), cacheRead: 0, output: 0, reasoning: 0,
                valueByCurrency: [:], coverage: .none, complete: true,
                contributingNodeIDs: [], staleNodeIDs: [], missingNodeIDs: []
            )
        }
        let frontier = FleetMerger.windowFrontier([
            aggregate(end: 1_799_000_000),   // 同组最旧：超出前沿，丢弃
            aggregate(end: 1_799_500_000),
            aggregate(end: 1_800_000_000),
            aggregate(end: 1_800_000_000, kind: "weekly"),  // 不同 kind 独立成组
        ])
        XCTAssertEqual(frontier.count, 3, "每组只保留最新两个边界，weekly 独立成组")
        XCTAssertNil(frontier.first { $0.windowKind == "interval" && $0.input == 1_000_000 },
                     "最旧的 interval 边界被前沿过滤丢弃")
        XCTAssertEqual(frontier.filter { $0.windowKind == "interval" }.count, 2)
    }

    // MARK: - 日桶金额汇总与下行瘦身（2026-10-27 裁定）

    private func pricedEntry(
        model: String, input: Int, value: Double?, currency: ModelPriceCurrency?,
        coverage: FleetCostCoverage = .full, truncated: Bool = false
    ) -> FleetUsageEntry {
        FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: model, input: input, cacheRead: 0, output: 0, reasoning: 0,
            value: value, currency: currency, coverage: coverage, truncated: truncated
        )
    }

    private func nodeBucket(
        _ dayKey: String, entries: [FleetUsageEntry], complete: Bool = true
    ) -> FleetDailyBucket {
        let rows: [FleetClientProviderUsage] = entries.isEmpty ? [] : [
            FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                input: entries.reduce(0) { $0 + $1.input }, cacheRead: 0, output: 0,
                reasoning: 0, turns: 1, rounds: 1
            )
        ]
        return FleetDailyBucket(
            dayKey: dayKey,
            totals: FleetTotals(summing: rows),
            clientProviders: rows,
            entries: entries,
            totalsComplete: complete,
            modelDetailsComplete: complete,
            sourceTruncated: false
        )
    }

    func testMergeDailyBucketsComputesValueRollupAndCostPartial() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dayKey = FleetMerger.dayKey(of: now)
        let merged = FleetMerger.mergeDailyBuckets(
            [[nodeBucket(dayKey, entries: [
                pricedEntry(model: "gpt-5.5", input: 10, value: 0.4, currency: .usd),
                pricedEntry(model: "glm", input: 20, value: 7.0, currency: .cny),
                pricedEntry(model: "free", input: 30, value: nil, currency: nil, coverage: .none),
            ])]],
            now: now
        )
        XCTAssertEqual(merged.count, 1)
        let bucket = merged[0]
        XCTAssertEqual(bucket.valueByCurrency?["USD"], 0.4, "桶级金额按币种分列汇总")
        XCTAssertEqual(bucket.valueByCurrency?["CNY"], 7.0)
        XCTAssertTrue(bucket.costPartial, "存在未计价贡献时置 costPartial（纯金额汇总表达不了）")
    }

    func testNodeResponseStripsOldDailyBucketsKeepingRollup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(withDays days: [String]) -> FleetSnapshot {
            // fleet 聚合桶来自 mergeDailyBuckets——valueByCurrency 由合并侧计算。
            let raw = days.enumerated().map { offset, day in
                nodeBucket(day, entries: [
                    pricedEntry(model: "m\(offset)", input: 10, value: 1.0, currency: .usd)
                ])
            }
            return FleetSnapshot(
                protocolVersion: FleetProtocol.version,
                hubUUID: UUID(),
                generation: 3,
                hub: FleetNodeIdentity(nodeID: UUID(), nodeName: "hub",
                                       timezoneID: "Asia/Shanghai", platform: "macOS"),
                generatedAt: now,
                nodes: [],
                fleet: FleetAggregate(
                    dailyBuckets: FleetMerger.mergeDailyBuckets([raw], now: now),
                    windowUsage: []
                ),
                electedQuotas: [],
                participantCount: 2
            )
        }

        let dayKeys = FleetMerger.dayKeyWindow(now: now)
        let full = snapshot(withDays: dayKeys)
        let forNode = full.nodeResponse(acknowledging: nil)

        let fullDayKeys = Set(dayKeys.suffix(FleetProtocol.fullDailyBucketsForNode))
        for bucket in forNode.fleet.dailyBuckets {
            if fullDayKeys.contains(bucket.dayKey) {
                XCTAssertFalse(bucket.entries.isEmpty, "最新 2 天保持完整桶")
                XCTAssertFalse(bucket.clientProviders.isEmpty)
            } else {
                XCTAssertTrue(bucket.entries.isEmpty, "历史天明细被裁掉")
                XCTAssertTrue(bucket.clientProviders.isEmpty)
                XCTAssertEqual(bucket.totals.input, 10, "历史天保留权威 totals")
                XCTAssertEqual(bucket.valueByCurrency?["USD"], 1.0, "历史天保留金额汇总")
            }
        }
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

    func testWindowAggregationPreservesPartialAndIncompleteCoverage() {
        let node = UUID()
        let partial = windowRow(coverage: .partial)
        let partialResult = FleetMerger.aggregateWindows(
            [.init(nodeID: node, stale: false, rows: [partial])], knownNodeIDs: [node]
        )
        XCTAssertEqual(partialResult.first?.coverage, .partial,
                       "有非零金额但来源声明partial时仍需显示部分计价")

        let incomplete = windowRow(coverage: .full, complete: false)
        let incompleteResult = FleetMerger.aggregateWindows(
            [.init(nodeID: node, stale: false, rows: [incomplete])], knownNodeIDs: [node]
        )
        XCTAssertEqual(incompleteResult.first?.coverage, .partial,
                       "complete=false不能聚合成full")
        XCTAssertFalse(incompleteResult.first?.complete ?? true)

        let malformedNoneWithAmount = windowRow(coverage: .none)
        let conservative = FleetMerger.aggregateWindows(
            [.init(nodeID: node, stale: false, rows: [malformedNoneWithAmount])],
            knownNodeIDs: [node]
        )
        XCTAssertEqual(conservative.first?.coverage, .partial,
                       "none+amount的wire不一致状态不得聚合成full")
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
