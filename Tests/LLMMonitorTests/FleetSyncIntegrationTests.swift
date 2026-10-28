import XCTest
@testable import LLM_monitor

/// hub ↔ node 核心链路端到端：真实 NWListener 监听回环 + `SyncClient` HTTP 往返。
/// 覆盖 §12 验收清单里的：seq 先持久化/乱序不覆盖、报告省略日桶仍可更新额度与
/// 心跳、hub 本机数据入合并、额度选举、429 限流、路径白名单、415/413。
@MainActor
final class FleetSyncIntegrationTests: XCTestCase {

    private final class ProvisionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func record(_ uuid: UUID) {
            lock.lock(); defer { lock.unlock() }
            ids.append(uuid)
        }
        var generated: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return ids
        }
    }

    private var directory: URL!
    private var hub: FleetSyncCoordinator!
    private var hubProvision: ProvisionRecorder!
    private var client: SyncClient!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-it-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hub?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func startHub(statuses: [ProviderStatus] = []) async throws -> UInt16 {
        let provisionRecorder = ProvisionRecorder()
        hubProvision = provisionRecorder
        hub = FleetSyncCoordinator(
            store: try FleetStore(url: directory.appendingPathComponent("fleet.sqlite")),
            loadDeviceID: { [provisionRecorder] in
                let uuid = UUID()
                provisionRecorder.record(uuid)
                return uuid
            }
        )
        var config = AppConfig.default
        config.sync = SyncConfig(enabled: true, hubURL: "", hubPort: 0) // 0 = 系统分配端口
        hub.start(config: config, statuses: statuses)
        // NWListener ready 是异步的：等端口就绪。
        for _ in 0..<100 where hub.listeningPort == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let port = try XCTUnwrap(hub.listeningPort, "hub 应在回环上拿到端口")
        client = try SyncClient(hubURL: "http://127.0.0.1:\(port)")
        return port
    }

    private func nodeReport(
        seq: Int, nodeID: UUID = UUID(), input: Int = 100,
        quotas: [FleetQuotaReport]? = nil
    ) -> NodeUsageReport {
        let now = Date()
        let buckets = FleetMerger.dayKeyWindow(now: now).map { dayKey in
            let rows: [FleetClientProviderUsage] = dayKey == FleetMerger.dayKey(of: now)
                ? [FleetClientProviderUsage(
                    clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                    input: input, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
                )]
                : []
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
        return NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: FleetNodeIdentity(nodeID: nodeID, nodeName: "Node-MBP",
                                    timezoneID: TimeZone.current.identifier, platform: "macOS"),
            seq: seq,
            generatedAt: now,
            attributionFingerprint: "deadbeef",
            dailyBuckets: buckets,
            windowUsage: [],
            quotas: quotas
        )
    }

    private func nodeQuota(fetchedAt: Date = Date().addingTimeInterval(-60)) -> FleetQuotaReport {
        FleetQuotaReport(
            quotaProviderID: QuotaProviderID.zhipu,
            fetchedAt: fetchedAt,
            models: [ModelQuota(
                modelName: "glm_coding_plan",
                intervalTotalCount: 100, intervalUsageCount: 20,
                intervalRemainingPercent: 80, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 0, weeklyStatus: .absent,
                weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: "Lite", accountEmail: nil, balanceDetail: nil
        )
    }

    // MARK: - 端点行为

    func testHealthReturnsHubIdentityAndVersion() async throws {
        let port = try await startHub()
        let health = try await client.fetchHealth()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.protocolVersion, FleetProtocol.version)
        XCTAssertEqual(health.nodeID, hub.localNodeID, "hubUUID = hub 的稳定 nodeID")
        _ = port
    }

    func testPostReportReturnsMergedSnapshotWithElectedQuota() async throws {
        try await startHub()
        let nodeID = UUID()
        let snapshot = try await client.postReport(
            nodeReport(seq: 1, nodeID: nodeID, input: 100, quotas: [nodeQuota()])
        )
        XCTAssertEqual(snapshot.protocolVersion, FleetProtocol.version)
        XCTAssertEqual(snapshot.hubUUID, hub.localNodeID)
        XCTAssertGreaterThanOrEqual(snapshot.generation, 1, "接受报告递增 generation")

        // POST 回包只含本节点轻量回执（§3）；完整逐节点数据在 hub 侧快照。
        let nodeEntry = try XCTUnwrap(snapshot.nodes.first { $0.nodeID == nodeID })
        XCTAssertTrue(nodeEntry.dailyBuckets.isEmpty)
        let hubNode = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(hubNode.nodeName, "Node-MBP")
        XCTAssertFalse(hubNode.stale)
        XCTAssertEqual(hubNode.dailyBuckets.last?.totals.input, 100)

        // fleet 聚合 = hub 自己（空）+ node：今天的总量来自 node。
        let today = try XCTUnwrap(snapshot.fleet.dailyBuckets.last)
        XCTAssertEqual(today.totals.input, 100)

        // hub 本机无有效额度 → 选举 node 上报的 zhipu 额度。
        let elected = try XCTUnwrap(snapshot.electedQuotas.first { $0.quotaProviderID == QuotaProviderID.zhipu })
        XCTAssertEqual(elected.sourceNodeID, nodeID)
        XCTAssertEqual(elected.sourceNodeName, "Node-MBP")
        XCTAssertFalse(elected.isStale)
    }

    func testStaleSeqReplayDoesNotOverwriteAndStillReturnsSnapshot() async throws {
        try await startHub()
        let nodeID = UUID()
        let first = try await client.postReport(nodeReport(seq: 10, nodeID: nodeID, input: 100))
        // 每节点限流 1s（§4.3）：两次请求之间稍等，让重放真正进业务逻辑。
        try await Task.sleep(nanoseconds: 1_100_000_000)

        // 重放被拒：回 409（讲清楚「没收」）。回 200 会让 node 以为推送成功
        // ——数据永远不落地，而界面一直显示「已连接」。
        do {
            _ = try await client.postReport(nodeReport(seq: 10, nodeID: nodeID, input: 999))
            XCTFail("重放应被拒（409）")
        } catch QuotaError.httpError(let status, let body) {
            XCTAssertEqual(status, 409)
            let payload = try FleetCodec.decode(FleetStaleSeqPayload.self, from: Data(body.utf8))
            XCTAssertEqual(payload.highWaterSeq, 10, "响应体带 hub 侧 high-water")
        }

        // 兜底 GET 仍能拿到全局数据（被拒的旧数据没被覆盖）。
        let snapshot = try await client.fetchSnapshot()
        XCTAssertEqual(snapshot.fleet.dailyBuckets.last?.totals.input, 100, "重复/乱序报告不重放旧数据")
        XCTAssertEqual(snapshot.generation, first.generation, "拒绝重放不递增 generation")

        try await Task.sleep(nanoseconds: 1_100_000_000)
        // 更低 seq 同样被拒。
        do {
            _ = try await client.postReport(nodeReport(seq: 3, nodeID: nodeID, input: 777))
            XCTFail("更低的 seq 应被拒（409）")
        } catch QuotaError.httpError(let status, let body) {
            XCTAssertEqual(status, 409)
            let payload = try FleetCodec.decode(FleetStaleSeqPayload.self, from: Data(body.utf8))
            XCTAssertEqual(payload.highWaterSeq, 10)
        }
        let older = try await client.fetchSnapshot()
        XCTAssertEqual(older.fleet.dailyBuckets.last?.totals.input, 100)
        XCTAssertEqual(older.generation, first.generation, "拒绝重放不递增 generation")
    }

    func testHeartbeatOnlyReportStillAccepted() async throws {
        try await startHub()
        let nodeID = UUID()
        _ = try await client.postReport(nodeReport(seq: 1, nodeID: nodeID, input: 50))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        // 省略全部数据通道（心跳 + 窗口空数组）。
        let heartbeat = NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: FleetNodeIdentity(nodeID: nodeID, nodeName: "Node-MBP",
                                    timezoneID: "Asia/Shanghai", platform: "macOS"),
            seq: 2,
            generatedAt: Date(),
            attributionFingerprint: "deadbeef",
            dailyBuckets: nil,
            windowUsage: [],
            quotas: nil
        )
        let snapshot = try await client.postReport(heartbeat)
        let node = try XCTUnwrap(snapshot.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(node.seq, 2)
        let stored = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(stored.dailyBuckets.last?.totals.input, 50, "省略日桶保留旧值")
    }

    func testPartialDayChannelMergesPerDayKey() async throws {
        try await startHub()
        let nodeID = UUID()
        _ = try await client.postReport(nodeReport(seq: 1, nodeID: nodeID, input: 100))
        let firstStored = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })

        // 只带今天的日桶通道：按 dayKey 逐桶 upsert，缺席的天保留旧值。
        try await Task.sleep(nanoseconds: 1_100_000_000)
        var partial = nodeReport(seq: 2, nodeID: nodeID, input: 200)
        partial.dailyBuckets = [try XCTUnwrap(partial.dailyBuckets?.last)]
        let second = try await client.postReport(partial)
        let secondStored = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(secondStored.dailyBuckets.count, 7, "未携带的天保留旧值")
        XCTAssertEqual(secondStored.dailyBuckets.last?.totals.input, 200, "携带的天替换为新值")
        XCTAssertEqual(Array(secondStored.dailyBuckets.dropLast()),
                       Array(firstStored.dailyBuckets.dropLast()),
                       "未携带的天与首拍逐字节一致")
        XCTAssertEqual(second.fleet.dailyBuckets.last?.totals.input, 200, "fleet 聚合使用合并后的值")
    }

    func testSourceAwarePartialMergeRetainsFailedSourceValues() async throws {
        try await startHub()
        let nodeID = UUID()
        var initial = nodeReport(seq: 1, nodeID: nodeID, input: 100)
        let day = try XCTUnwrap(initial.dailyBuckets?.last?.dayKey)
        let dshOld = FleetClientProviderUsage(
            clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek,
            input: 40, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1
        )
        initial.dailyBuckets = initial.dailyBuckets?.map { bucket in
            guard bucket.dayKey == day else { return bucket }
            let rows = bucket.clientProviders + [dshOld]
            return FleetDailyBucket(
                dayKey: bucket.dayKey, totals: FleetTotals(summing: rows),
                clientProviders: rows, entries: [], totalsComplete: true,
                modelDetailsComplete: true, sourceTruncated: false
            )
        }
        _ = try await client.postReport(initial)

        let codex = FleetClientProviderUsage(
            clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 200, cacheRead: 0, output: 0, reasoning: 0, turns: 2, rounds: 2
        )
        let partial = FleetDailyBucket(
            dayKey: day, totals: FleetTotals(summing: [codex]),
            clientProviders: [codex], entries: [], totalsComplete: false,
            modelDetailsComplete: false, sourceTruncated: false,
            unavailableSources: [FleetDailyUnavailableSource(
                clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek, reason: .failed
            )]
        )
        try await Task.sleep(nanoseconds: 1_100_000_000)
        var secondReport = nodeReport(seq: 2, nodeID: nodeID, input: 200)
        secondReport.dailyBuckets = [partial]
        _ = try await client.postReport(secondReport)
        let secondStored = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })
        let storedPartial = try XCTUnwrap(secondStored.dailyBuckets.first { $0.dayKey == day })
        XCTAssertEqual(storedPartial.totals.input, 240, "健康新值加失败来源旧值")

        try await Task.sleep(nanoseconds: 1_100_000_000)
        var repeatedReport = nodeReport(seq: 3, nodeID: nodeID, input: 200)
        repeatedReport.dailyBuckets = [partial]
        _ = try await client.postReport(repeatedReport)
        let repeatedStored = try XCTUnwrap(hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(repeatedStored.dailyBuckets.first { $0.dayKey == day }?.totals.input, 240,
                       "重复partial请求不能累计旧失败值")
    }

    func testStaleSeqReportIsRejectedWithConflictAndHighWater() async throws {
        // 序号落后必须回**可区分**的状态码：回 200 的话 node 会以为推送成功，
        // 而 hub 一份都没收——数据永远不落地，且 hub 上同 nodeID 的另一台机器
        // 的数据会被当成本机的显示。
        try await startHub()
        let nodeID = UUID()
        _ = try await client.postReport(nodeReport(seq: 10, nodeID: nodeID, input: 100))
        try await Task.sleep(nanoseconds: 1_100_000_000)

        do {
            _ = try await client.postReport(nodeReport(seq: 3, nodeID: nodeID, input: 200))
            XCTFail("序号落后应被拒")
        } catch QuotaError.httpError(let status, let body) {
            XCTAssertEqual(status, 409, "陈旧 seq 回 409（可区分），不是 200")
            let payload = try FleetCodec.decode(FleetStaleSeqPayload.self, from: Data(body.utf8))
            XCTAssertEqual(payload.highWaterSeq, 10, "响应体带 hub 侧 high-water")
        }
        // 兜底 GET 仍能取到快照（幂等重试不丢全局数据）。
        let fallback = try await client.fetchSnapshot()
        XCTAssertEqual(fallback.fleet.dailyBuckets.last?.totals.input, 100)

        // hub 状态不受影响：被拒的报告一份都没应用。
        let state = try XCTUnwrap(hub.latestSnapshot)
        let entry = try XCTUnwrap(state.nodes.first { $0.nodeID == nodeID })
        XCTAssertEqual(entry.dailyBuckets.last?.totals.input, 100, "被拒的报告没有覆盖已存数据")
    }

    func testRapidDuplicatePostGetsRateLimited() async throws {
        try await startHub()
        let nodeID = UUID()
        _ = try await client.postReport(nodeReport(seq: 1, nodeID: nodeID))
        do {
            _ = try await client.postReport(nodeReport(seq: 2, nodeID: nodeID))
            XCTFail("同一 nodeID <1s 的第二次请求应被 429 拒绝")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                return XCTFail("期望 httpError，得到 \(error)")
            }
            XCTAssertEqual(status, 429)
        }
    }

    func testUnknownPathIs404AndWrongContentTypeIs415() async throws {
        let port = try await startHub()
        let base = URL(string: "http://127.0.0.1:\(port)")!

        var request = URLRequest(url: base.appendingPathComponent("/v1/nope"))
        request.timeoutInterval = 5
        let (_, response404) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response404 as! HTTPURLResponse).statusCode, 404)

        var badType = URLRequest(url: base.appendingPathComponent(FleetProtocol.usageDayPath))
        badType.httpMethod = "POST"
        badType.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        badType.httpBody = Data("{}".utf8)
        badType.timeoutInterval = 5
        let (_, response415) = try await URLSession.shared.data(for: badType)
        XCTAssertEqual((response415 as! HTTPURLResponse).statusCode, 415)
    }

    func testOversizedBodyIs413() async throws {
        let port = try await startHub()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(FleetProtocol.usageDayPath)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(repeating: 0x61, count: FleetProtocol.maxRequestBodyBytes + 1024)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as! HTTPURLResponse).statusCode, 413)
        } catch {
            // hub 超限即断开（不等 body 读完就回 413 并关闭连接）：客户端可能
            // 表现为连接被取消 / 上传超时 / 连接被重置，而不是读到 413 ——
            // 这几种结果都证明请求没有进入业务逻辑。
            let code = (error as? URLError)?.code
            XCTAssertTrue(
                code == .cancelled || code == .timedOut || code == .networkConnectionLost,
                "意外错误：\(String(describing: code))"
            )
        }
    }

    // MARK: - hub 本机数据并入合并（§7.2）

    func testHubOwnReportJoinsFleetWithoutHTTP() async throws {
        let todayStart = Calendar.current.startOfDay(for: Date())
        var hubStatus = ProviderStatus(
            id: ProviderKind.codexChatGpt.providerID,
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "dollarsign.circle",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "chatgpt_plan",
                    intervalTotalCount: 100, intervalUsageCount: 10,
                    intervalRemainingPercent: 90, intervalStatus: .present,
                    intervalResetsAt: nil, intervalWindowSeconds: 5 * 60 * 60,
                    weeklyTotalCount: 0, weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0, weeklyStatus: .absent,
                    weeklyResetsAt: nil, weeklyWindowSeconds: nil
                )],
                resetCredits: nil,
                planLabel: "Plus",
                accountEmail: nil,
                codexUsageDetails: CodexUsageDetails(
                    primary: nil,
                    secondary: nil,
                    dailyTokenUsage: [DailyTokenUsage(
                        dayStart: todayStart,
                        inputTokens: 200, cachedInputTokens: 0,
                        outputTokens: 0, reasoningOutputTokens: 0,
                        rounds: 1, turns: 1
                    )],
                    recentSamples: [],
                    scannedAt: Date()
                ),
                fetchedAt: Date(),
                balanceDetail: nil
            ))
        )
        hubStatus.isEnabled = true
        try await startHub(statuses: [hubStatus])

        // hub 自己也发一份报告：fleet 合计 = hub + node。
        let snapshot = try await client.postReport(nodeReport(seq: 1, input: 300))
        let today = try XCTUnwrap(snapshot.fleet.dailyBuckets.last)
        XCTAssertEqual(today.totals.input, 500, "hub 本机 200 + node 300")

        // hub 本机有有效 zhipu 之外的 openai 额度：openai 选举落 hub 自己。
        let openAI = try XCTUnwrap(snapshot.electedQuotas.first { $0.quotaProviderID == QuotaProviderID.openAI })
        let hubID = try XCTUnwrap(hub.localNodeID)
        XCTAssertEqual(openAI.sourceNodeID, hubID, "hub 本机有效额度优先（§2.1）")
    }

    func testHubHealthyLocalUsageSurvivesEmptyNodePostWhileDshIsFailed() async throws {
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        var codex = ProviderStatus(
            id: ProviderKind.codexChatGpt.providerID,
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "dollarsign.circle",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [], resetCredits: nil, planLabel: "Plus", accountEmail: nil,
                codexUsageDetails: CodexUsageDetails(
                    primary: nil,
                    secondary: nil,
                    dailyTokenUsage: [DailyTokenUsage(
                        dayStart: todayStart,
                        inputTokens: 210, cachedInputTokens: 10,
                        outputTokens: 20, reasoningOutputTokens: 0,
                        rounds: 2, turns: 1
                    )],
                    recentSamples: [],
                    scannedAt: now
                ),
                fetchedAt: now, balanceDetail: nil
            ))
        )
        codex.isEnabled = true

        var deepseek = ProviderStatus(
            id: ProviderKind.deepseek.providerID,
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "dollarsign.circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .failed(message: "DSH scan failed", lastSuccess: nil)
        )
        deepseek.isEnabled = true
        deepseek.localUsageFreshness[.dsh] = .failed

        try await startHub(statuses: [codex, deepseek])
        let hubID = try XCTUnwrap(hub.localNodeID)
        let dayKey = FleetMerger.dayKey(of: todayStart)

        // Verify the hub's own real Builder→Store path before a remote node arrives.
        let initialHub = try XCTUnwrap(hub.latestSnapshot)
        let localNode = try XCTUnwrap(initialHub.nodes.first { $0.nodeID == hubID })
        let localToday = try XCTUnwrap(localNode.dailyBuckets.first { $0.dayKey == dayKey })
        XCTAssertEqual(localToday.totals.input, 200)
        XCTAssertEqual(localToday.unavailableSources, [FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            reason: .failed
        )])
        XCTAssertFalse(localToday.totalsComplete)

        // A separate empty node builds a normal report and sends it over the real loopback HTTP client.
        let emptyNodeID = UUID()
        let emptyReport = UsageReportBuilder.build(UsageReportInput(
            nodeID: emptyNodeID,
            nodeName: "Empty-Node",
            bindings: ClientProviderBinding.defaultBindings,
            statuses: [],
            now: now
        ), seq: 1)
        let snapshot = try await client.postReport(emptyReport)

        // 逐节点明细在 hub 侧快照（POST 回包只有本节点轻量回执）。
        let afterPost = try XCTUnwrap(hub.latestSnapshot)
        let remoteNode = try XCTUnwrap(afterPost.nodes.first { $0.nodeID == emptyNodeID })
        XCTAssertEqual(remoteNode.dailyBuckets.first { $0.dayKey == dayKey }?.totals, .zero)
        let hubNode = try XCTUnwrap(afterPost.nodes.first { $0.nodeID == hubID })
        let hubToday = try XCTUnwrap(hubNode.dailyBuckets.first { $0.dayKey == dayKey })
        XCTAssertEqual(hubToday.totals.input, 200)
        XCTAssertEqual(hubToday.unavailableSources, localToday.unavailableSources)

        let fleetToday = try XCTUnwrap(snapshot.fleet.dailyBuckets.first { $0.dayKey == dayKey })
        XCTAssertEqual(fleetToday.totals.input, 200, "空node的零桶不能清掉hub本机健康贡献")
        XCTAssertEqual(fleetToday.unavailableSources, localToday.unavailableSources,
                       "hub本机DSH失败标记在Fleet聚合后仍保留")
        XCTAssertFalse(fleetToday.totalsComplete)
    }

    // MARK: - node 协调器端到端

    func testNodeCoordinatorPushesAndCachesSnapshot() async throws {
        try await startHub()
        let nodeProvision = ProvisionRecorder()
        let node = FleetSyncCoordinator(
            store: try FleetStore(url: directory.appendingPathComponent("node-fleet.sqlite")),
            loadDeviceID: { [nodeProvision] in
                let uuid = UUID()
                nodeProvision.record(uuid)
                return uuid
            }
        )
        var config = AppConfig.default
        config.sync = SyncConfig(
            enabled: true,
            hubURL: "http://127.0.0.1:\(hub.listeningPort!)",
            pushIntervalSeconds: 60
        )
        node.start(config: config, statuses: [])
        defer { node.stop() }

        // 启动先推一次；等它上线并缓存快照。
        for _ in 0..<200 {
            if node.status.online, node.latestSnapshot != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(node.status.online, "node 应完成 health 握手 + 首次推送，错误：\(node.status.lastError ?? "nil")")
        XCTAssertNotNil(node.latestSnapshot)
        XCTAssertGreaterThanOrEqual(node.status.snapshotGeneration ?? 0, 1)

        // 快照缓存已落 fleet.sqlite（重开可读）。
        let nodeStore = try FleetStore(url: directory.appendingPathComponent("node-fleet.sqlite"))
        let upstreamScope = "http://127.0.0.1:\(hub.listeningPort!)|\(node.latestSnapshot!.hubUUID.uuidString)"
        XCTAssertNotNil(try nodeStore.loadSnapshot(upstreamScope: upstreamScope))
    }
}
