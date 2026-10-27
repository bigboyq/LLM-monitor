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

    // MARK: - 「今」行金额（§10.7）

    /// 节点带金额的日桶 → 节点口径的「今」行要给金额。
    private func nodeWithEntries(
        entries: [FleetUsageEntry],
        dayKey: String? = nil
    ) -> FleetNodeSnapshot {
        let key = dayKey ?? FleetMerger.dayKey(of: now)
        let rows = [FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
        )]
        let bucket = FleetDailyBucket(
            dayKey: key, totals: FleetTotals(summing: rows),
            clientProviders: rows, entries: entries,
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        return FleetNodeSnapshot(
            nodeID: UUID(), nodeName: "iMac",
            lastSeenAt: now, seq: 1, stale: false,
            dailyBuckets: [bucket], windowUsage: [], quotas: [],
            attributionFingerprint: "deadbeef",
            dailyDigests: [bucket.dayKey: FleetDailyDigest.digest(bucket)]
        )
    }

    func testNodeScopeTodayRowCarriesCost() throws {
        let entry = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.5", input: 100, cacheRead: 0, output: 0, reasoning: 0,
            value: 1.25, currency: .usd, coverage: .full, truncated: false
        )
        let usage = FleetUsageProjection.nodeCardUsage(
            node: nodeWithEntries(entries: [entry]),
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        let today = try XCTUnwrap(usage.todayRow)
        XCTAssertEqual(today.cost?.value, 1.25, "节点口径的「今」行要带金额")
        XCTAssertNil(today.costText, "单币种走 cost，不出混币文案")
    }

    func testPartialPricingIsShownWithNonNilTodayAndWindowAmounts() throws {
        let partialEntry = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.5", input: 100, cacheRead: 0, output: 0, reasoning: 0,
            value: 1.25, currency: .usd, coverage: .partial, truncated: false
        )
        let base = nodeWithEntries(entries: [partialEntry])
        let window = FleetWindowUsage(
            quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: "interval",
            startAt: now.addingTimeInterval(-18_000), endAt: now,
            input: 50, cacheRead: 0, output: 0, reasoning: 0,
            value: 0.5, currency: .usd, coverage: .partial, complete: false, sourceTruncated: false
        )
        let node = FleetNodeSnapshot(
            nodeID: base.nodeID, nodeName: base.nodeName, lastSeenAt: now, seq: 1, stale: false,
            dailyBuckets: base.dailyBuckets, windowUsage: [window], quotas: [],
            attributionFingerprint: base.attributionFingerprint, dailyDigests: base.dailyDigests
        )
        let usage = FleetUsageProjection.nodeCardUsage(
            node: node, quotaProviderID: QuotaProviderID.openAI, now: now
        )
        XCTAssertEqual(usage.todayRow?.cost?.value, 1.25)
        XCTAssertTrue(try XCTUnwrap(usage.todayRow?.costText).contains("部分计价"))
        XCTAssertEqual(usage.windowRows.first?.cost?.value, 0.5)
        XCTAssertTrue(try XCTUnwrap(usage.windowRows.first?.costText).contains("部分计价"))
        XCTAssertTrue(try XCTUnwrap(usage.dayValues.first?.valueText).contains("部分计价"))
    }

    func testNodeWindowUsageSelectsPreferredSingleHistoryPerModelAndKind() throws {
        let base = nodeWithEntries(entries: [])
        let preferredEnd = now
        let windows = [
            FleetWindowUsage(
                quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: "interval",
                startAt: preferredEnd.addingTimeInterval(-18_000), endAt: preferredEnd,
                input: 40, cacheRead: 0, output: 0, reasoning: 0,
                value: 1, currency: .usd, coverage: .full, complete: true, sourceTruncated: false
            ),
            FleetWindowUsage(
                quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: "interval",
                startAt: preferredEnd.addingTimeInterval(-18_000), endAt: preferredEnd.addingTimeInterval(600),
                input: 99, cacheRead: 0, output: 0, reasoning: 0,
                value: 2, currency: .usd, coverage: .full, complete: true, sourceTruncated: false
            ),
            FleetWindowUsage(
                quotaProviderID: QuotaProviderID.zhipu, modelID: "chatgpt_plan", windowKind: "interval",
                startAt: preferredEnd.addingTimeInterval(-18_000), endAt: preferredEnd,
                input: 700, cacheRead: 0, output: 0, reasoning: 0,
                value: 3, currency: .usd, coverage: .full, complete: true, sourceTruncated: false
            )
        ]
        let node = FleetNodeSnapshot(
            nodeID: base.nodeID, nodeName: base.nodeName, lastSeenAt: now, seq: 1, stale: false,
            dailyBuckets: base.dailyBuckets, windowUsage: windows, quotas: [],
            attributionFingerprint: base.attributionFingerprint, dailyDigests: base.dailyDigests
        )
        let usage = FleetUsageProjection.nodeCardUsage(
            node: node, quotaProviderID: QuotaProviderID.openAI, now: now,
            preferredWindowEnds: ["interval": preferredEnd]
        )
        XCTAssertEqual(usage.windowRows.count, 1, "按 model/kind 选择一个历史窗口，且过滤其他 provider")
        XCTAssertEqual(usage.windowRows.first?.input, 40, "优先与当前生效额度边界一致的窗口")
    }

    func testTodayRowMixedCurrencyFallsBackToCostText() {
        // fleet 混币（USD + CNY）时金额不该退化成「—」：单币种 estimate 装不下，
        // 走混币文案（CNY 折算总额 + USD 构成标注）。
        let entries = [
            FleetUsageEntry(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                modelName: "gpt-5.5", input: 100, cacheRead: 0, output: 0, reasoning: 0,
                value: 2.0, currency: .usd, coverage: .full, truncated: false
            ),
            FleetUsageEntry(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.zhipu,
                modelName: "glm-5", input: 100, cacheRead: 0, output: 0, reasoning: 0,
                value: 10.0, currency: .cny, coverage: .full, truncated: false
            )
        ]
        let usage = FleetUsageProjection.nodeCardUsage(
            node: nodeWithEntries(entries: entries),
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        let today = usage.todayRow
        XCTAssertNil(today?.cost, "混币没有单币种 estimate")
        XCTAssertNotNil(today?.costText, "混币给出文案而不是「—」")
        XCTAssertTrue(today?.costText?.contains("$") == true, "文案里带 USD 构成标注")
    }

    // MARK: - 合并模型行的身份

    func testMergedModelRowIdentityIsStableAcrossComputations() {
        // 合并行没有节点归属，但 ModelRow 的身份由 nodeID 拼出 → 原来每次
        // 重算都生成新 UUID，ForEach 判定为「另一批行」→ 整段每秒重建。
        let entries = [FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "gpt-5.5", input: 100, cacheRead: 0, output: 0, reasoning: 0,
            value: 0.5, currency: .usd, coverage: .full, truncated: false
        )]
        let first = FleetUsageProjection.mergedModelRows(entries: entries)
        let second = FleetUsageProjection.mergedModelRows(entries: entries)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "同一份数据每次算出同一个身份")
        XCTAssertEqual(first.first?.id, "\(FleetUsageProjection.stableUUID(for: "\(ClientID.codex)|\(QuotaProviderID.openAI)|gpt-5.5").uuidString):gpt-5.5")
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
                attributionFingerprint: "deadbeef",
                dailyDigests: [bucket.dayKey: FleetDailyDigest.digest(bucket)]
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

    /// 菜单 fleet 汇总的客户端段带「主力 provider」：今日占比条的段色归属。
    /// 与本地路径同一个纯函数、同一个并列口径（字典序小者）。
    func testMenuSummaryClientSectionCarriesDominantProvider() {
        let rows = [
            FleetClientProviderUsage(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.zhipu,
                input: 100, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1),
            FleetClientProviderUsage(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax,
                input: 300, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1),
            FleetClientProviderUsage(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek,
                input: 200, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1),
            FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                input: 50, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1),
        ]
        let entries = rows.map { row in
            FleetUsageEntry(
                clientID: row.clientID, quotaProviderID: row.quotaProviderID,
                modelName: "m", input: row.input, cacheRead: 0, output: 0, reasoning: 0,
                value: nil, currency: nil, coverage: .full, truncated: false)
        }
        let bucket = FleetDailyBucket(
            dayKey: FleetMerger.dayKey(of: now, calendar: .current),
            totals: FleetTotals(summing: rows),
            clientProviders: rows, entries: entries,
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let hubID = UUID()
        let node = FleetNodeSnapshot(
            nodeID: hubID, nodeName: "hub",
            lastSeenAt: now, seq: 1, stale: false,
            dailyBuckets: [bucket], windowUsage: [], quotas: [],
            attributionFingerprint: "deadbeef",
            dailyDigests: [bucket.dayKey: FleetDailyDigest.digest(bucket)]
        )
        let snapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: hubID, generation: 1,
            hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub",
                                   timezoneID: "Asia/Shanghai", platform: "macOS"),
            generatedAt: now, nodes: [node],
            fleet: FleetAggregate(
                dailyBuckets: FleetMerger.mergeDailyBuckets([node.dailyBuckets], now: now),
                windowUsage: []),
            electedQuotas: []
        )

        let summary = try! XCTUnwrap(FleetUsageProjection.menuSummary(
            snapshot: snapshot, localNodeID: hubID, now: now
        ))
        let zcode = try! XCTUnwrap(summary.sections.first { $0.clientID == ClientID.zcode })
        XCTAssertEqual(zcode.dominantQuotaProviderID, QuotaProviderID.minimax,
                       "主 provider 是段内今日 token 最大的一路")
        let codex = try! XCTUnwrap(summary.sections.first { $0.clientID == ClientID.codex })
        XCTAssertEqual(codex.dominantQuotaProviderID, QuotaProviderID.openAI)
    }

    func testMissingFleetTodayBucketProducesUnavailableSummaryNotLocalFallback() {
        let populated = menuSnapshot(nodeCount: 2, perNodeInput: [100, 300])
        let nodes = populated.nodes.map { node in
            FleetNodeSnapshot(
                nodeID: node.nodeID,
                nodeName: node.nodeName,
                lastSeenAt: node.lastSeenAt,
                seq: node.seq,
                stale: node.stale,
                dailyBuckets: [],
                windowUsage: node.windowUsage,
                quotas: node.quotas,
                attributionFingerprint: node.attributionFingerprint,
                dailyDigests: [:]
            )
        }
        let emptyDailySnapshot = FleetSnapshot(
            protocolVersion: populated.protocolVersion,
            hubUUID: populated.hubUUID,
            generation: populated.generation,
            hub: populated.hub,
            generatedAt: populated.generatedAt,
            nodes: nodes,
            fleet: FleetAggregate(dailyBuckets: [], windowUsage: []),
            electedQuotas: populated.electedQuotas
        )

        let summary = FleetUsageProjection.menuSummary(
            snapshot: emptyDailySnapshot,
            localNodeID: populated.hubUUID,
            now: now
        )
        XCTAssertEqual(summary?.multiNode, true)
        XCTAssertEqual(summary?.hasDailyData, false)
        XCTAssertEqual(summary?.dailyNotice, "全局今日用量尚未同步")
        XCTAssertTrue(summary?.sections.isEmpty == true)

        let card = FleetUsageProjection.cardUsage(
            snapshot: emptyDailySnapshot,
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        XCTAssertNotNil(card)
        XCTAssertTrue(card?.daily.isEmpty == true)
        XCTAssertNil(card?.todayRow)
        XCTAssertEqual(card?.dailyNotice, "全局今日用量尚未同步")
    }

    func testPartialDailyBucketKeepsKnownTotalsAndSurfacesUnavailableSource() {
        let populated = menuSnapshot(nodeCount: 2, perNodeInput: [100, 300])
        let complete = populated.fleet.dailyBuckets[0]
        let partial = FleetDailyBucket(
            dayKey: complete.dayKey,
            totals: complete.totals,
            clientProviders: complete.clientProviders,
            entries: complete.entries,
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: false,
            unavailableSources: [FleetDailyUnavailableSource(
                clientID: ClientID.codex,
                quotaProviderID: QuotaProviderID.openAI,
                reason: .failed
            )]
        )
        let partialSnapshot = FleetSnapshot(
            protocolVersion: populated.protocolVersion,
            hubUUID: populated.hubUUID,
            generation: populated.generation,
            hub: populated.hub,
            generatedAt: populated.generatedAt,
            nodes: populated.nodes,
            fleet: FleetAggregate(dailyBuckets: [partial], windowUsage: []),
            electedQuotas: populated.electedQuotas
        )

        let summary = try! XCTUnwrap(FleetUsageProjection.menuSummary(
            snapshot: partialSnapshot,
            localNodeID: populated.hubUUID,
            now: now
        ))
        XCTAssertTrue(summary.hasDailyData, "partial bucket still carries known data")
        XCTAssertEqual(summary.fleetTotals.tokens, 400, "partiality must not erase healthy/retained totals")
        XCTAssertTrue(summary.dailyNotice?.contains("Codex") == true)
        XCTAssertTrue(summary.dailyNotice?.contains(QuotaProviderID.openAI) == false,
                      "UI notice does not expose raw provider IDs")

        let card = try! XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: partialSnapshot,
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        ))
        XCTAssertTrue(card.dailyNotice?.contains("Codex") == true)
    }

    func testNodeCardDailyNoticeDistinguishesMissingPartialAndCompleteZero() {
        let populated = menuSnapshot(nodeCount: 2, perNodeInput: [100, 300])
        let sourceNode = populated.nodes[0]
        let dayKey = FleetMerger.dayKey(of: now)
        let zeroBucket = FleetDailyBucket(
            dayKey: dayKey,
            totals: .zero,
            clientProviders: [],
            entries: [],
            totalsComplete: true,
            modelDetailsComplete: true,
            sourceTruncated: false,
            unavailableSources: []
        )
        func node(with buckets: [FleetDailyBucket]) -> FleetNodeSnapshot {
            FleetNodeSnapshot(
                nodeID: sourceNode.nodeID,
                nodeName: sourceNode.nodeName,
                lastSeenAt: sourceNode.lastSeenAt,
                seq: sourceNode.seq,
                stale: false,
                dailyBuckets: buckets,
                windowUsage: [],
                quotas: [],
                attributionFingerprint: sourceNode.attributionFingerprint,
                dailyDigests: nil
            )
        }

        let completeZero = FleetUsageProjection.nodeCardUsage(
            node: node(with: [zeroBucket]),
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        XCTAssertNil(completeZero.dailyNotice, "完整的零用量是合法数据，不应提示未同步")

        let partialBucket = FleetDailyBucket(
            dayKey: dayKey,
            totals: .zero,
            clientProviders: [],
            entries: [],
            totalsComplete: false,
            modelDetailsComplete: false,
            sourceTruncated: false,
            unavailableSources: [FleetDailyUnavailableSource(
                clientID: ClientID.codex,
                quotaProviderID: QuotaProviderID.openAI,
                reason: .failed
            )]
        )
        let partial = FleetUsageProjection.nodeCardUsage(
            node: node(with: [partialBucket]),
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        XCTAssertTrue(partial.dailyNotice?.contains("Codex") == true)

        let missing = FleetUsageProjection.nodeCardUsage(
            node: node(with: []),
            quotaProviderID: QuotaProviderID.openAI,
            now: now
        )
        XCTAssertEqual(missing.dailyNotice, "该节点今日用量尚未同步")
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

    func testMenuSummaryHidesZeroDataNodesAndSections() {
        // node1 有量、node2 该客户端全零：只出 node1 的节点行；
        // 若整段全零（唯一客户端为空）则整段不出。
        let snapshot = menuSnapshot(nodeCount: 2, perNodeInput: [100, 0])
        let summary = FleetUsageProjection.menuSummary(
            snapshot: snapshot, localNodeID: nil, now: now
        )!
        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertEqual(summary.sections[0].nodes.count, 1, "全零贡献的节点不展示节点行")
        XCTAssertEqual(summary.sections[0].nodes[0].totalTokens, 100)
        XCTAssertEqual(summary.sections[0].models.count, 1, "全零明细不出模型行")

        let allZero = menuSnapshot(nodeCount: 2, perNodeInput: [0, 0])
        let empty = FleetUsageProjection.menuSummary(
            snapshot: allZero, localNodeID: nil, now: now
        )!
        XCTAssertTrue(empty.sections.isEmpty, "整段全零 → 段不出现")
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

    func testDailyCardTotalsRemainAllProviderWhileWindowsFilterProvider() throws {
        let base = menuSnapshot(nodeCount: 1, perNodeInput: [10])
        let nodeID = base.nodes[0].nodeID
        let openAINodeWindow = FleetWindowUsage(
            quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: "interval",
            startAt: now.addingTimeInterval(-100), endAt: now,
            input: 7, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none, complete: true, sourceTruncated: false
        )
        let zhipuNodeWindow = FleetWindowUsage(
            quotaProviderID: QuotaProviderID.zhipu, modelID: "glm", windowKind: "interval",
            startAt: now.addingTimeInterval(-100), endAt: now,
            input: 99, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none, complete: true, sourceTruncated: false
        )
        let providers = [
            FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                input: 10, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
            ),
            FleetClientProviderUsage(
                clientID: ClientID.codex, quotaProviderID: QuotaProviderID.zhipu,
                input: 20, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
            )
        ]
        let bucket = FleetDailyBucket(
            dayKey: FleetMerger.dayKey(of: now), totals: FleetTotals(summing: providers),
            clientProviders: providers, entries: [], totalsComplete: true,
            modelDetailsComplete: true, sourceTruncated: false
        )
        let node = FleetNodeSnapshot(
            nodeID: nodeID, nodeName: "hub", lastSeenAt: now, seq: 1, stale: false,
            dailyBuckets: [bucket], windowUsage: [openAINodeWindow, zhipuNodeWindow], quotas: [],
            attributionFingerprint: "deadbeef", dailyDigests: [bucket.dayKey: FleetDailyDigest.digest(bucket)]
        )
        let openAIWindow = FleetWindowAggregate(
            quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan", windowKind: "interval",
            startAt: now.addingTimeInterval(-100), endAt: now,
            input: 7, cacheRead: 0, output: 0, reasoning: 0,
            valueByCurrency: [:], coverage: .none, complete: true,
            contributingNodeIDs: [nodeID], staleNodeIDs: [], missingNodeIDs: []
        )
        let zhipuWindow = FleetWindowAggregate(
            quotaProviderID: QuotaProviderID.zhipu, modelID: "glm", windowKind: "interval",
            startAt: now.addingTimeInterval(-100), endAt: now,
            input: 99, cacheRead: 0, output: 0, reasoning: 0,
            valueByCurrency: [:], coverage: .none, complete: true,
            contributingNodeIDs: [nodeID], staleNodeIDs: [], missingNodeIDs: []
        )
        let snapshot = FleetSnapshot(
            protocolVersion: base.protocolVersion, hubUUID: base.hubUUID, generation: 1,
            hub: base.hub, generatedAt: now, nodes: [node],
            fleet: FleetAggregate(dailyBuckets: [bucket], windowUsage: [openAIWindow, zhipuWindow]),
            electedQuotas: []
        )

        let fleetUsage = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: snapshot, quotaProviderID: QuotaProviderID.openAI, now: now
        ))
        let nodeUsage = FleetUsageProjection.nodeCardUsage(
            node: node, quotaProviderID: QuotaProviderID.openAI, now: now
        )
        XCTAssertEqual(fleetUsage.todayRow?.input, 30, "全局日桶按设计保留所有 provider 的合计")
        XCTAssertEqual(nodeUsage.todayRow?.input, 30, "单节点日桶按设计保留所有 provider 的合计")
        XCTAssertEqual(fleetUsage.windowRows.map(\.input), [7], "窗口摘要仍按当前 provider 筛选")
        XCTAssertEqual(nodeUsage.windowRows.map(\.input), [7], "节点窗口摘要仍按当前 provider 筛选")
    }

    func testCardUsageParsesGregorianDayKeysWithCallerTimezone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let probeNow = utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30))!
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let key = FleetMerger.dayKey(of: probeNow, calendar: japanese)
        XCTAssertEqual(key, "2026-10-24")

        let nodeID = UUID()
        let rows = [FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 12, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
        )]
        let bucket = FleetDailyBucket(
            dayKey: key, totals: FleetTotals(summing: rows), clientProviders: rows,
            entries: [], totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let node = FleetNodeSnapshot(
            nodeID: nodeID, nodeName: "hub", lastSeenAt: probeNow, seq: 1, stale: false,
            dailyBuckets: [bucket], windowUsage: [], quotas: [],
            attributionFingerprint: "deadbeef", dailyDigests: [key: FleetDailyDigest.digest(bucket)]
        )
        let snapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version, hubUUID: nodeID, generation: 1,
            hub: FleetNodeIdentity(nodeID: nodeID, nodeName: "hub", timezoneID: "America/Los_Angeles", platform: "macOS"),
            generatedAt: probeNow, nodes: [node],
            fleet: FleetAggregate(dailyBuckets: [bucket], windowUsage: []), electedQuotas: []
        )
        let expectedStart = FleetMerger.gregorianDayCalendar(matching: japanese).startOfDay(for: probeNow)

        let fleetUsage = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: snapshot, quotaProviderID: QuotaProviderID.openAI,
            now: probeNow, calendar: japanese
        ))
        let nodeUsage = FleetUsageProjection.nodeCardUsage(
            node: node, quotaProviderID: QuotaProviderID.openAI,
            now: probeNow, calendar: japanese
        )
        XCTAssertEqual(fleetUsage.daily.first?.dayStart, expectedStart)
        XCTAssertEqual(nodeUsage.daily.first?.dayStart, expectedStart)
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

    func testCardUsageMarksStaleDailyContributionWithoutWindowRows() {
        let snapshot = menuSnapshot(nodeCount: 3, perNodeInput: [100, 100, 20])
        let usage = try! XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: snapshot, quotaProviderID: QuotaProviderID.openAI, now: now
        ))
        XCTAssertTrue(usage.windowRows.isEmpty)
        XCTAssertNotNil(usage.incompleteNotice, "窗口行缺席时也须提示正在展示 stale 节点的日桶")

        let dayKey = FleetMerger.dayKey(of: now)
        let zeroBucket = FleetDailyBucket(
            dayKey: dayKey, totals: .zero, clientProviders: [], entries: [],
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false
        )
        let staleZeroNode = FleetNodeSnapshot(
            nodeID: UUID(), nodeName: "offline-empty", lastSeenAt: now, seq: 1, stale: true,
            dailyBuckets: [zeroBucket], windowUsage: [], quotas: [],
            attributionFingerprint: nil, dailyDigests: nil
        )
        let activeSnapshot = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: [snapshot.nodes[0], snapshot.nodes[1], staleZeroNode],
            fleet: FleetAggregate(
                dailyBuckets: FleetMerger.mergeDailyBuckets(
                    [snapshot.nodes[0].dailyBuckets, snapshot.nodes[1].dailyBuckets, staleZeroNode.dailyBuckets],
                    now: now
                ),
                windowUsage: []
            ),
            electedQuotas: []
        )
        let zeroOnlyUsage = FleetUsageProjection.cardUsage(
            snapshot: activeSnapshot, quotaProviderID: QuotaProviderID.openAI, now: now
        )
        XCTAssertNil(zeroOnlyUsage?.incompleteNotice, "无用量/金额贡献的 stale 节点不应挂告警")
    }

    // MARK: - 窗口范围选择（§10.7.1 W 裁定）

    func testPreferredRangePrefersExactBoundaryOverNewerEnd() {
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        let matching = Self.aggregate(endAt: boundary, input: 10)
        let newer = Self.aggregate(endAt: boundary.addingTimeInterval(600), input: 99)
        let picked = FleetUsageProjection.preferredRange(matching, over: newer, preferredEnd: boundary)
        XCTAssertEqual(picked.endAt, boundary, "边界命中的范围优先于 endAt 更新的范围")
        let noMatch = FleetUsageProjection.preferredRange(matching, over: newer, preferredEnd: nil)
        XCTAssertEqual(noMatch.endAt, newer.endAt, "无匹配取 endAt 最新者")
        let flipped = FleetUsageProjection.preferredRange(newer, over: matching, preferredEnd: boundary)
        XCTAssertEqual(flipped.endAt, boundary, "参数顺序无关：命中边界的赢")
    }

    func testGlobalAndNodeRangeSelectionMatchesWireSecondAfterCodecRoundTrip() throws {
        let preferredEnd = try XCTUnwrap(DateParser.parse("2026-07-18T00:47:58.918242Z"))
        let precise = Self.aggregate(endAt: preferredEnd, input: 10)
        let decodedPrecise = try FleetCodec.decode(
            FleetWindowAggregate.self, from: FleetCodec.encode(precise)
        )
        XCTAssertNotEqual(decodedPrecise.endAt, preferredEnd, "FleetCodec 的线格式只保留整秒")
        XCTAssertTrue(FleetISO8601.matchesWholeSecond(decodedPrecise.endAt, preferredEnd))
        let newer = Self.aggregate(endAt: preferredEnd.addingTimeInterval(600), input: 99)
        let snapshot = menuSnapshot(nodeCount: 1, perNodeInput: [100])
        let globalSnapshot = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: snapshot.nodes,
            fleet: FleetAggregate(
                dailyBuckets: snapshot.fleet.dailyBuckets,
                windowUsage: [decodedPrecise, newer]
            ),
            electedQuotas: []
        )
        let globalUsage = try XCTUnwrap(FleetUsageProjection.cardUsage(
            snapshot: globalSnapshot,
            quotaProviderID: QuotaProviderID.openAI,
            now: now,
            preferredWindowEnds: ["interval": preferredEnd]
        ))
        XCTAssertEqual(globalUsage.windowRows.first?.input, 10, "全局卡应选中协议秒精度匹配的较旧范围")

        let preciseNodeRow = FleetWindowUsage(
            quotaProviderID: QuotaProviderID.openAI,
            modelID: "chatgpt_plan",
            windowKind: "interval",
            startAt: decodedPrecise.startAt,
            endAt: decodedPrecise.endAt,
            input: 10, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none, complete: true, sourceTruncated: false
        )
        let newerNodeRow = FleetWindowUsage(
            quotaProviderID: QuotaProviderID.openAI,
            modelID: "chatgpt_plan",
            windowKind: "interval",
            startAt: newer.startAt,
            endAt: newer.endAt,
            input: 99, cacheRead: 0, output: 0, reasoning: 0,
            value: nil, currency: nil, coverage: .none, complete: true, sourceTruncated: false
        )
        let node = FleetNodeSnapshot(
            nodeID: snapshot.nodes[0].nodeID,
            nodeName: snapshot.nodes[0].nodeName,
            lastSeenAt: snapshot.nodes[0].lastSeenAt,
            seq: snapshot.nodes[0].seq,
            stale: false,
            dailyBuckets: snapshot.nodes[0].dailyBuckets,
            windowUsage: [preciseNodeRow, newerNodeRow],
            quotas: [],
            attributionFingerprint: nil,
            dailyDigests: nil
        )
        let nodeUsage = FleetUsageProjection.nodeCardUsage(
            node: node,
            quotaProviderID: QuotaProviderID.openAI,
            now: now,
            preferredWindowEnds: ["interval": preferredEnd]
        )
        XCTAssertEqual(nodeUsage.windowRows.first?.input, 10, "单节点卡也应使用相同的协议精度规则")
    }

    private static func aggregate(endAt: Date, input: Int) -> FleetWindowAggregate {
        FleetWindowAggregate(
            quotaProviderID: QuotaProviderID.openAI, modelID: "chatgpt_plan",
            windowKind: "interval", startAt: endAt.addingTimeInterval(-5 * 60 * 60), endAt: endAt,
            input: input, cacheRead: 0, output: 0, reasoning: 0,
            valueByCurrency: [:], coverage: .none, complete: true,
            contributingNodeIDs: [], staleNodeIDs: [], missingNodeIDs: []
        )
    }

    func testCardUsageSelectsOneRangePerModelAndKind() {
        let snapshot = menuSnapshot(nodeCount: 2, perNodeInput: [100, 100])
        let boundary = now
        let staleRange = Self.aggregate(endAt: boundary.addingTimeInterval(-3600), input: 7)
        let boundaryRange = Self.aggregate(endAt: boundary, input: 40)
        var withRanges = snapshot
        withRanges = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: snapshot.nodes,
            fleet: FleetAggregate(
                dailyBuckets: snapshot.fleet.dailyBuckets,
                windowUsage: [staleRange, boundaryRange]
            ),
            electedQuotas: []
        )
        let usage = FleetUsageProjection.cardUsage(
            snapshot: withRanges,
            quotaProviderID: QuotaProviderID.openAI,
            now: now,
            preferredWindowEnds: ["interval": boundary]
        )!
        XCTAssertEqual(usage.windowRows.count, 1, "同 (model, kind) 多范围只展示选中的一个")
        XCTAssertEqual(usage.windowRows[0].input, 40, "选中与生效额度边界一致的范围")
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

        let partialPriced = FleetUsageEntry(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            modelName: "a", input: 1, cacheRead: 0, output: 0, reasoning: 0,
            value: 1.0, currency: .usd, coverage: .partial, truncated: false
        )
        XCTAssertTrue(FleetUsageProjection.costText(entries: [partialPriced]).contains("部分计价"),
                      "有金额但 coverage 不完整时也必须明示部分计价")
        XCTAssertTrue(FleetUsageProjection.mergedModelRows(entries: [partialPriced]).first?.costText.contains("部分计价") == true,
                      "合并模型明细行须保留 coverage")
    }

    // MARK: - 窗口行标签

    /// wire windowKind → 行标签映射：「免 / 速 / 它」必须与本地卡的行标签常量
    /// 逐字同源——fleet 路径按行标签从 windowRows 取行
    /// （`ProviderCardView` 的 fleetRow 映射），标签漂移会让行静默消失。
    /// 未知 kind 原样返回（不吞掉未来新增 kind 的可诊断性）。
    func testWindowLabelMapsGlmCategoryKindsToLocalRowLabels() {
        XCTAssertEqual(
            FleetUsageProjection.windowLabel(for: "glmStartPlan"),
            QuotaWindowUsageSection.startPlanRowLabel,
            "glmStartPlan = Start Plan 体验套餐行（免）"
        )
        XCTAssertEqual(
            FleetUsageProjection.windowLabel(for: "glmHighspeed"),
            QuotaWindowUsageSection.highSpeedRowLabel,
            "glmHighspeed = 加速卡行（速）"
        )
        XCTAssertEqual(
            FleetUsageProjection.windowLabel(for: "glmOtherPlan"),
            QuotaWindowUsageSection.otherPlanRowLabel,
            "glmOtherPlan = 其他智谱任务行（它）"
        )
        XCTAssertEqual(FleetUsageProjection.windowLabel(for: "interval"), "5h")
        XCTAssertEqual(FleetUsageProjection.windowLabel(for: "weekly"), "周")
        XCTAssertEqual(FleetUsageProjection.windowLabel(for: "glmOffPeak"), "闲")
        XCTAssertEqual(FleetUsageProjection.windowLabel(for: "mystery"), "mystery",
                       "未知 windowKind 原样返回")
    }
}
