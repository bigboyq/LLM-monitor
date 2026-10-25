import XCTest
@testable import LLM_monitor

final class FleetCostTextPropagationTests: XCTestCase {
    private func snapshot(now: Date, aggregate: FleetWindowAggregate) -> FleetSnapshot {
        let hubID = UUID()
        return FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: hubID,
            generation: 1,
            hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub", timezoneID: "UTC", platform: "test"),
            generatedAt: now,
            nodes: [],
            fleet: FleetAggregate(dailyBuckets: [], windowUsage: [aggregate]),
            electedQuotas: []
        )
    }

    func testTruncatedDshPartialCostTextSurvivesThroughFinalVisibleRow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-cost-dsh-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ id: String, body: String, mtime: Date) throws {
            let folder = sessions.appendingPathComponent("--Project--", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("session.jsonl")
            try body.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path.path)
        }

        let sessionUsage = [
            #"{"type":"session","version":0,"id":"new","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax-cn","model":"MiniMax-M3"}}"#,
            #"{"type":"assistant/message","seq":2,"time":\#(Int64((now.timeIntervalSince1970 - 60) * 1000)),"data":{"turn":1,"step":0,"usage":{"inputTokens":100000000,"outputTokens":1000000,"reasoningTokens":0}}}"#
        ].joined(separator: "\n") + "\n"
        let oldHeader = #"{"type":"session","version":0,"id":"old","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"# + "\n"
        try write("new", body: sessionUsage, mtime: now)
        try write("old", body: oldHeader, mtime: Date(timeIntervalSince1970: 1_600_000_000))

        let scanned = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessions,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { now },
            decompressor: { $0 },
            limits: DshLocalUsageScanLimits(
                maxSessionFiles: 1,
                maxTotalRawBytes: 1_000_000,
                maxJSONLLineBytes: 1_000_000,
                maxRecentSamples: 10
            )
        )
        XCTAssertTrue(scanned.isTruncated == true)
        XCTAssertEqual(scanned.byProvider["minimax-cn"]?.recentSamples.count, 1)

        let info = QuotaInfo(
            models: [ModelQuota(
                modelName: "general",
                intervalTotalCount: 1000, intervalUsageCount: 1,
                intervalRemainingPercent: 99, intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3 * 60 * 60), intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
        )
        var status = ProviderStatus(
            id: ProviderKind.minimaxTokenPlan.providerID, displayName: "MiniMax",
            kind: .minimaxTokenPlan, iconSystemName: "dollarsign.circle", accentColor: .minimax,
            refreshIntervalSeconds: 300, state: .ok(info)
        )
        status.isEnabled = true
        status.dshUsage = scanned
        let nodeID = UUID()
        let report = UsageReportBuilder.build(UsageReportInput(
            nodeID: nodeID, nodeName: "probe", bindings: ClientProviderBinding.defaultBindings,
            statuses: [status], now: now, calendar: calendar
        ), seq: 1)
        let built = try XCTUnwrap(report.windowUsage?.first { $0.windowKind == "interval" })
        XCTAssertGreaterThan(built.value ?? 0, 0)
        XCTAssertEqual(built.coverage, .partial)
        XCTAssertFalse(built.complete)

        let aggregates = FleetMerger.aggregateWindows(
            [.init(nodeID: nodeID, stale: false, rows: [built])], knownNodeIDs: [nodeID]
        )
        let hubID = UUID()
        let fleetSnapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version, hubUUID: hubID, generation: 1,
            hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub", timezoneID: "UTC", platform: "test"),
            generatedAt: now, nodes: [], fleet: FleetAggregate(dailyBuckets: [], windowUsage: aggregates),
            electedQuotas: []
        )
        let usage = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: fleetSnapshot, quotaProviderID: QuotaProviderID.minimax, now: now
        ))
        let fleetRow = try XCTUnwrap(usage.windowRows.first)
        XCTAssertTrue(try XCTUnwrap(fleetRow.costText).contains("部分计价"))

        let windowSnapshot = ProviderCardView.fleetWindowSnapshot(rows: usage.windowRows)
        let visibleRow = try XCTUnwrap(QuotaWindowUsageSection.visibleRows(
            snapshot: windowSnapshot, today: nil, offPeak: nil
        ).first)
        XCTAssertTrue(try XCTUnwrap(visibleRow.costText).contains("部分计价"))
    }

    func testMixedCurrencyCostTextSurvivesFleetWindowRowConversion() throws {
        let now = Date(timeIntervalSince1970: 1_800_123_000)
        func aggregate(kind: String, endOffset: TimeInterval) -> FleetWindowAggregate {
            FleetWindowAggregate(
                quotaProviderID: QuotaProviderID.openAI,
                modelID: "chatgpt_plan",
                windowKind: kind,
                startAt: now.addingTimeInterval(-5 * 60 * 60), endAt: now.addingTimeInterval(endOffset),
                input: 500, cacheRead: 0, output: 10, reasoning: 0,
                valueByCurrency: [ModelPriceCurrency.usd.rawValue: 0.5, ModelPriceCurrency.cny.rawValue: 1.0],
                coverage: .full, complete: true,
                contributingNodeIDs: [UUID()], staleNodeIDs: [], missingNodeIDs: []
            )
        }
        let card = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: FleetSnapshot(
                protocolVersion: FleetProtocol.version,
                hubUUID: UUID(), generation: 1,
                hub: FleetNodeIdentity(nodeID: UUID(), nodeName: "hub", timezoneID: "UTC", platform: "test"),
                generatedAt: now, nodes: [],
                fleet: FleetAggregate(dailyBuckets: [], windowUsage: [aggregate(kind: "interval", endOffset: 0), aggregate(kind: "weekly", endOffset: 3_600)]),
                electedQuotas: []
            ),
            quotaProviderID: QuotaProviderID.openAI, now: now
        ))
        let fleetRow = try XCTUnwrap(card.windowRows.first)
        XCTAssertNil(fleetRow.cost)
        let expectedText = try XCTUnwrap(fleetRow.costText)
        XCTAssertTrue(expectedText.contains("含"))
        XCTAssertTrue(expectedText.contains("$0.5"))

        let windowSnapshot = ProviderCardView.fleetWindowSnapshot(rows: card.windowRows)
        let visibleRows = QuotaWindowUsageSection.visibleRows(
            snapshot: windowSnapshot, today: nil, offPeak: nil
        )
        XCTAssertEqual(visibleRows.map(\.label), ["5h", "周"])
        XCTAssertEqual(visibleRows.map(\.costText), [expectedText, expectedText])
    }

    func testMixedTodayCostTextSurvivesFleetTodayRowReconstruction() throws {
        let now = Date(timeIntervalSince1970: 1_800_123_000)
        let calendar = Calendar.current
        let entries = [
            FleetUsageEntry(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                modelName: "gpt", input: 100, cacheRead: 0, output: 0, reasoning: 0,
                value: 0.5, currency: .usd, coverage: .full, truncated: false
            ),
            FleetUsageEntry(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.zhipu,
                modelName: "glm", input: 100, cacheRead: 0, output: 0, reasoning: 0,
                value: 1.0, currency: .cny, coverage: .full, truncated: false
            )
        ]
        let clientRows = [
            FleetClientProviderUsage(clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                                     input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1),
            FleetClientProviderUsage(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.zhipu,
                                     input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1)
        ]
        let bucket = FleetDailyBucket(
            dayKey: FleetMerger.dayKey(of: now, calendar: calendar),
            totals: FleetTotals(summing: clientRows), clientProviders: clientRows, entries: entries,
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let hubID = UUID()
        let fleetSnapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version, hubUUID: hubID, generation: 1,
            hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub", timezoneID: "UTC", platform: "test"),
            generatedAt: now, nodes: [],
            fleet: FleetAggregate(dailyBuckets: [bucket], windowUsage: []), electedQuotas: []
        )
        let card = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: fleetSnapshot, quotaProviderID: QuotaProviderID.openAI, now: now, calendar: calendar
        ))
        let projected = try XCTUnwrap(card.todayRow)
        XCTAssertNil(projected.cost)
        let expectedText = try XCTUnwrap(projected.costText)
        let today = try XCTUnwrap(ProviderCardView.fleetRow(projected))
        let visible = try XCTUnwrap(QuotaWindowUsageSection.visibleRows(
            snapshot: ProviderCardView.fleetWindowSnapshot(rows: []), today: today, offPeak: nil
        ).first)
        XCTAssertEqual(visible.label, "今")
        XCTAssertEqual(visible.costText, expectedText)
    }

    func testOffPeakCostTextSurvivesFleetRowReconstruction() throws {
        let now = Date(timeIntervalSince1970: 1_800_123_000)
        let aggregate = FleetWindowAggregate(
            quotaProviderID: QuotaProviderID.zhipu,
            modelID: "glm-off-peak",
            windowKind: "glmOffPeak",
            startAt: now.addingTimeInterval(-3_600), endAt: now,
            input: 20, cacheRead: 0, output: 4, reasoning: 0,
            valueByCurrency: [ModelPriceCurrency.cny.rawValue: 0.12],
            coverage: .partial, complete: false,
            contributingNodeIDs: [UUID()], staleNodeIDs: [], missingNodeIDs: []
        )
        let card = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: snapshot(now: now, aggregate: aggregate),
            quotaProviderID: QuotaProviderID.zhipu, now: now
        ))
        let fleetRow = try XCTUnwrap(card.windowRows.first { $0.label == "闲" })
        let expectedText = try XCTUnwrap(fleetRow.costText)
        let offPeak = try XCTUnwrap(ProviderCardView.fleetRow(fleetRow))
        let visible = try XCTUnwrap(QuotaWindowUsageSection.visibleRows(
            snapshot: ProviderCardView.fleetWindowSnapshot(rows: card.windowRows),
            today: nil,
            offPeak: offPeak
        ).first { $0.label == "闲" })
        XCTAssertEqual(visible.costText, expectedText)
    }
}
