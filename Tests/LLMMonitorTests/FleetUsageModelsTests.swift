import XCTest
@testable import LLM_monitor

/// Fleet UI 投影（§10）：生效额度解析、菜单 fleet 汇总（双行 + 节点分组 +
/// 单节点退化）、卡片 fleet 用量、来源标注文案。
final class FleetUsageModelsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_123_000)

    private func chatGPTStatus(active: Bool = true) -> ProviderStatus {
        ProviderStatus(
            id: ProviderKind.codexChatGpt.providerID,
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "dollarsign.circle",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: active
                ? .ok(QuotaInfo(
                    models: [Self.activeModel("chatgpt_plan")],
                    resetCredits: nil, planLabel: "Plus", accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil))
                : .notConfigured(reason: "未配置")
        )
    }

    private static func activeModel(_ name: String) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100, intervalUsageCount: 40,
            intervalRemainingPercent: 60, intervalStatus: .present,
            intervalResetsAt: nil, intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 0, weeklyUsageCount: 0,
            weeklyRemainingPercent: 0, weeklyStatus: .absent,
            weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
    }

    private func elected(
        provider: String = QuotaProviderID.zhipu,
        nodeID: UUID = UUID(),
        nodeName: String = "iMac",
        stale: Bool = false,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_799_000_000)
    ) -> FleetElectedQuota {
        FleetElectedQuota(
            quotaProviderID: provider,
            sourceNodeID: nodeID,
            sourceNodeName: nodeName,
            fetchedAt: fetchedAt,
            models: [Self.activeModel("glm_coding_plan")],
            resetCredits: nil, planLabel: "Lite", accountEmail: nil,
            balanceDetail: nil,
            isStale: stale
        )
    }

    // MARK: - 生效额度（§7.7）

    func testEffectiveQuotaPrefersLocalValidLastSuccess() {
        let result = FleetUsageProjection.effectiveQuota(
            status: chatGPTStatus(active: true),
            elected: [elected(provider: QuotaProviderID.openAI, nodeName: "iMac")],
            for: QuotaProviderID.openAI
        )
        XCTAssertTrue(result.isLocal)
        XCTAssertEqual(result.quota?.planLabel, "Plus")
        XCTAssertNil(result.sourceTagText, "本机额度不标来源")
    }

    func testEffectiveQuotaFallsBackToElectedWithSourceTag() {
        let result = FleetUsageProjection.effectiveQuota(
            status: chatGPTStatus(active: false),
            elected: [elected(nodeName: "iMac")],
            for: QuotaProviderID.zhipu
        )
        XCTAssertFalse(result.isLocal)
        XCTAssertEqual(result.quota?.planLabel, "Lite")
        XCTAssertEqual(result.sourceTagText, "来自 iMac")
    }

    func testEffectiveQuotaStaleTag() {
        let result = FleetUsageProjection.effectiveQuota(
            status: nil,
            elected: [elected(nodeName: "iMac", stale: true)],
            for: QuotaProviderID.zhipu
        )
        XCTAssertEqual(result.sourceTagText, "来自 iMac · 已过期")
    }

    func testEffectiveQuotaUnavailableWhenNeither() {
        let result = FleetUsageProjection.effectiveQuota(
            status: chatGPTStatus(active: false),
            elected: [],
            for: QuotaProviderID.openAI
        )
        XCTAssertNil(result.quota)
    }

    // MARK: - 菜单汇总（§10.2）

    private func menuSnapshot(nodeCount: Int, perNodeInput: [Int]) -> FleetSnapshot {
        let hubID = UUID()
        let todayKey = FleetMerger.dayKey(of: now)
        func buckets(input: Int, nodeID: UUID, nodeName: String, stale: Bool) -> FleetNodeSnapshot {
            let rows = [FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                input: input, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
            )]
            let entries = [FleetUsageEntry(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                modelName: "gpt-5.5", input: input, cacheRead: 0, output: 0, reasoning: 0,
                value: 0.5, currency: .usd, coverage: .full, truncated: false
            )]
            let bucket = FleetDailyBucket(
                dayKey: todayKey, totals: FleetTotals(summing: rows),
                clientProviders: rows, entries: entries,
                totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
            )
            return FleetNodeSnapshot(
                nodeID: nodeID, nodeName: nodeName,
                lastSeenAt: now, seq: 1, stale: stale,
                dailyBuckets: [bucket], windowUsage: [], quotas: [],
                attributionFingerprint: "deadbeef"
            )
        }
        let nodes = (0..<nodeCount).map { index in
            buckets(
                input: perNodeInput[index],
                nodeID: index == 0 ? hubID : UUID(),
                nodeName: index == 0 ? "hub" : "node\(index)",
                stale: index == 2
            )
        }
        let fleetDaily = FleetMerger.mergeDailyBuckets(nodes.map(\.dailyBuckets), now: now)
        return FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: hubID,
            generation: 3,
            hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub",
                                   timezoneID: "Asia/Shanghai", platform: "macOS"),
            generatedAt: now,
            nodes: nodes,
            fleet: FleetAggregate(dailyBuckets: fleetDaily, windowUsage: []),
            electedQuotas: []
        )
    }

    func testMenuSummarySingleNodeDegrades() {
        let snapshot = menuSnapshot(nodeCount: 1, perNodeInput: [100])
        let summary = FleetUsageProjection.menuSummary(
            snapshot: snapshot, localNodeID: snapshot.hubUUID, now: now
        )
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary!.multiNode, "单节点时菜单保持今天的单行形态（§10.6 L）")
    }

    func testMenuSummaryFleetTotalsAndNodeOrdering() {
        let snapshot = menuSnapshot(nodeCount: 3, perNodeInput: [100, 300, 50])
        let summary = FleetUsageProjection.menuSummary(
            snapshot: snapshot, localNodeID: snapshot.hubUUID, now: now
        )!
        XCTAssertTrue(summary.multiNode)
        XCTAssertEqual(summary.fleetTotals.tokens, 450, "今日全部 = 各节点同日权威合计之和")
        XCTAssertEqual(summary.fleetTotals.valueText, "$1.50", "三节点同键 entry 合并后 $0.5×3")

        XCTAssertEqual(summary.sections.count, 1)
        let section = summary.sections[0]
        XCTAssertEqual(section.clientID, ClientID.codex)
        XCTAssertEqual(section.totalTokens, 450, "段头 = fleet 该 client 的权威日合计")
        XCTAssertEqual(section.nodes.count, 3)
        XCTAssertTrue(section.nodes[0].isLocal, "本机节点排第一（§10.2）")
        XCTAssertEqual(section.nodes[1].nodeName, "node1", "其余按 token 降序")
        XCTAssertEqual(section.nodes[2].nodeName, "node2")
        XCTAssertFalse(section.nodes[2].stale == false && section.models.isEmpty)
        XCTAssertEqual(section.models.count, 3, "各节点模型明细（不反推段头 totals）")
    }

    // MARK: - 卡片用量（§10.1）

    func testCardUsageWindowRowsAndTodayRow() {
        let snapshot = menuSnapshot(nodeCount: 2, perNodeInput: [100, 100])
        let start = now.addingTimeInterval(-3600)
        var withWindow = snapshot
        withWindow = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: snapshot.nodes,
            fleet: FleetAggregate(
                dailyBuckets: snapshot.fleet.dailyBuckets,
                windowUsage: [
                    FleetWindowAggregate(
                        quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan",
                        windowKind: "interval", startAt: start, endAt: now,
                        input: 40, cacheRead: 60, output: 10, reasoning: 0,
                        valueByCurrency: ["USD": 1.5], coverage: .full, complete: true,
                        contributingNodeIDs: snapshot.nodes.map(\.nodeID),
                        staleNodeIDs: [], missingNodeIDs: []
                    )
                ]
            ),
            electedQuotas: snapshot.electedQuotas
        )
        let usage = FleetUsageProjection.cardUsage(
            snapshot: withWindow, quotaProviderID: QuotaProviderID.openAI, now: now
        )!
        XCTAssertEqual(usage.daily.count, withWindow.fleet.dailyBuckets.count, "日桶数与快照一致（真实 hub 恒 7 桶）")
        XCTAssertEqual(usage.windowRows.count, 1)
        XCTAssertEqual(usage.windowRows[0].label, "5h")
        XCTAssertEqual(usage.windowRows[0].cost?.value, 1.5)
        XCTAssertNil(usage.incompleteNotice, "全覆盖时不提示")
        XCTAssertEqual(usage.todayRow?.label, "今")
        XCTAssertEqual(usage.todayRow?.input, 200, "fleet 今行 = 今日 bucket 合计")
    }

    func testCardUsageMarksIncompleteWhenNodeMissingRange() {
        let snapshot = menuSnapshot(nodeCount: 2, perNodeInput: [100, 100])
        var withWindow = snapshot
        withWindow = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: snapshot.nodes,
            fleet: FleetAggregate(
                dailyBuckets: snapshot.fleet.dailyBuckets,
                windowUsage: [
                    FleetWindowAggregate(
                        quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan",
                        windowKind: "interval", startAt: now.addingTimeInterval(-3600), endAt: now,
                        input: 40, cacheRead: 0, output: 0, reasoning: 0,
                        valueByCurrency: [:], coverage: .none, complete: true,
                        contributingNodeIDs: [snapshot.nodes[0].nodeID],
                        staleNodeIDs: [], missingNodeIDs: [snapshot.nodes[1].nodeID]
                    )
                ]
            ),
            electedQuotas: []
        )
        let usage = FleetUsageProjection.cardUsage(
            snapshot: withWindow, quotaProviderID: QuotaProviderID.openAI, now: now
        )!
        XCTAssertEqual(usage.windowRows[0].incomplete, true, "缺范围节点 → 行标记不完整")
        XCTAssertEqual(usage.incompleteNotice, "部分节点缺该范围或已离线")
    }

    // MARK: - 金额文案

    func testCostTextMixedCurrencyAndUnpriced() {
        let priced = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "a", input: 1, cacheRead: 0, output: 0, reasoning: 0,
            value: 1.0, currency: .usd, coverage: .full, truncated: false
        )
        let cny = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.zhipu,
            modelName: "b", input: 1, cacheRead: 0, output: 0, reasoning: 0,
            value: 7.0, currency: .cny, coverage: .full, truncated: false
        )
        let unpriced = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.zhipu,
            modelName: "c", input: 1, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none, truncated: false
        )
        XCTAssertEqual(FleetUsageProjection.costText(entries: [priced]), "$1.00")
        let mixed = FleetUsageProjection.costText(entries: [priced, cny])
        XCTAssertTrue(mixed.contains("14"), "混币折算 CNY 总额：¥7 + $1×7 = 14")
        XCTAssertTrue(mixed.contains("含$"), "USD 原额以构成标注呈现")
        XCTAssertEqual(FleetUsageProjection.costText(entries: [priced, unpriced]).contains("部分计价"), true)
        XCTAssertEqual(FleetUsageProjection.costText(entries: [unpriced]), "未定价")
    }
}
