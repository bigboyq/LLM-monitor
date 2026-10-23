import Foundation
import Combine

// MARK: - 同步协调器（§6.5）

/// 面向（未来的）UI 的运行时状态。核心链路只维护这几个字段。
struct FleetSyncStatusInfo: Equatable, Sendable {
    var role: SyncRole = .off
    /// node：hub 可达；hub：服务在监听。
    var online: Bool = false
    var lastSyncAt: Date?
    var lastError: String?
    var snapshotGeneration: Int64?
}

/// 多机联动的运行时编排：角色派生、hub 服务与合并、node 推送与快照缓存。
///
/// - 角色由 `sync.hubURL` 单源派生（§3）；node **不创建** `NWListener`，
///   角色判定与 server 启动在同一个 switch 分支里。
/// - hub 自己作为一个节点参加合并：本机报告由同一 builder 生成、
///   **不经 HTTP**（§7.2），经 store.applyReport 落库并递增 generation。
/// - node 串行分配 seq（先持久化再发送，§6.2），POST 报告一次完成推 + 取；
///   仅当响应对应当前 upstreamKey、已验证的 hubUUID 且 generation 更新时
///   才提交快照（§6.5）。配置切换（configVersion 递增）后到达的迟到响应丢弃。
/// - 本地显示永不依赖网络（§3 不变量 3）：本机用量照常走既有链路。
@MainActor
final class FleetSyncCoordinator: ObservableObject {
    @Published private(set) var status = FleetSyncStatusInfo()
    /// node：hub 回传的最近快照；hub：本机装配的最近快照。
    @Published private(set) var latestSnapshot: FleetSnapshot?

    private let identityStore: NodeIdentityStore
    private let store: FleetStore
    private var client: SyncClient?
    private var server: HubServer?
    private var config = SyncConfig.default
    private var role: SyncRole = .off
    private var statuses: [ProviderStatus] = []
    private var bindings: [ClientProviderBinding] = []
    private var nodeName = ""
    private var configVersion = 0
    private var pushTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    /// node 侧：经 health 握手确认的 hubUUID（未验证来源的快照不收，§6.5）。
    private var verifiedHubUUID: UUID?
    /// hub 侧：每 nodeID 的最近请求时刻（<1s → 429，§4.3）。
    private var lastRequestByNode: [UUID: Date] = [:]
    /// hub 侧：上次装配快照的可见签名——日切 / stale 翻转这类无报告变化
    /// 也要递增 generation（§5.2 / §7.5）。
    private var lastAssembledSignature: String?
    /// hub 侧：本机报告重建的 2s 防抖（statuses 变更很频繁：每次 quota 刷新、
    /// 每次 scanner 应用结果都会 fire）。
    private var ownReportDebounceTask: Task<Void, Never>?
    /// node 侧：数据变更唤醒的最小推送间隔；短于它的变更由周期节拍覆盖。
    private var lastPushAt: Date?

    init(identityStore: NodeIdentityStore, store: FleetStore) {
        self.identityStore = identityStore
        self.store = store
    }

    /// hub 实际监听端口（端口 0 时由系统分配；测试/发现用）。
    var listeningPort: UInt16? { server?.boundPort }

    /// 本机稳定 nodeID（UI 标「本机」节点 / 生效额度来源判断用）。
    var localNodeID: UUID? {
        try? identityStore.identity().nodeID
    }

    /// 设置页「移除节点」：删除该节点的报告 / 窗口 / high-water（§10.4 / §7.6）。
    func removeNodeFromFleet(nodeID: UUID) {
        do {
            try store.removeNode(scope: hubScope, nodeID: nodeID)
            _ = try assembleSnapshot(now: Date())
        } catch {
            logWarn("[fleet-hub] 移除节点失败: \(error.localizedDescription)")
        }
    }

    /// fleet 内是否出现 ≥2 种非空归因指纹（§7.8：提示，不阻断）。
    var attributionFingerprintsInconsistent: Bool {
        let fingerprints = Set((latestSnapshot?.nodes ?? [])
            .compactMap(\.attributionFingerprint)
            .filter { !$0.isEmpty })
        return fingerprints.count > 1
    }

    // MARK: - 生命周期

    func start(config appConfig: AppConfig, statuses: [ProviderStatus]) {
        self.statuses = statuses
        self.bindings = appConfig.clientBindings
        self.config = appConfig.effectiveSyncConfig
        self.nodeName = self.config.effectiveNodeName.isEmpty
            ? NodeIdentityStore.defaultNodeName()
            : self.config.effectiveNodeName
        boot()
    }

    /// 配置或本机数据变化：hub 立即重建本机报告；node 唤醒推送循环。
    /// configVersion 递增让在飞响应作废（§6.5）。
    func update(config appConfig: AppConfig, statuses: [ProviderStatus]) {
        let newConfig = appConfig.effectiveSyncConfig
        let newRole = SyncRole.derive(config: appConfig)
        let roleChanged = newRole != role
        let upstreamChanged = newConfig.effectiveHubURL != config.effectiveHubURL
        configVersion += 1

        self.statuses = statuses
        self.bindings = appConfig.clientBindings
        self.config = newConfig
        self.nodeName = newConfig.effectiveNodeName.isEmpty
            ? NodeIdentityStore.defaultNodeName()
            : newConfig.effectiveNodeName

        switch newRole {
        case .off:
            if role != .off || roleChanged { shutdown() }
        case .hub:
            if roleChanged || upstreamChanged || server == nil {
                shutdown()
                boot()
            } else {
                scheduleOwnReportRebuild()
            }
        case .node:
            if roleChanged || upstreamChanged {
                shutdown()
                boot()
            } else {
                wakeNodeLoop()
            }
        }
    }

    /// hub 侧防抖：statuses 在一次 reconcile 里会连续变更多次，
    /// 落库一次合并后的报告即可。
    private func scheduleOwnReportRebuild() {
        ownReportDebounceTask?.cancel()
        ownReportDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.applyOwnReport()
        }
    }

    /// node 侧节流：数据变更唤醒推送循环，但距上次推送不足 5s 时交给周期节拍。
    private func wakeNodeLoop() {
        if let last = lastPushAt, Date().timeIntervalSince(last) < 5 { return }
        wakeContinuation?.yield()
    }

    func stop() {
        shutdown()
    }

    // MARK: - 启动 / 停机

    private func boot() {
        role = SyncRole.derive(config: currentAppConfigProxy)
        status.role = role
        status.lastError = nil
        switch role {
        case .off:
            status.online = false
        case .hub:
            startHub()
        case .node:
            startNodeLoop()
        }
    }

    /// boot/update 只拿得到 SyncConfig 与派生角色；角色重派生统一走这里。
    private var currentAppConfigProxy: AppConfig {
        // SyncRole 只依赖 sync 节：装一个只带 sync 的配置即可，避免持有整份。
        var config = AppConfig.default
        config.sync = self.config
        return config
    }

    private func shutdown() {
        pushTask?.cancel()
        pushTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        ownReportDebounceTask?.cancel()
        ownReportDebounceTask = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        server?.stop()
        server = nil
        client = nil
        verifiedHubUUID = nil
        lastRequestByNode.removeAll()
        lastAssembledSignature = nil
        role = .off
        status.role = .off
        status.online = false
    }

    // MARK: - Hub 侧

    private var hubScope: String {
        // scope = hubUUID（§5.7）。identity 失败时用兜底串——applyReport 会因
        // identity 错误根本走不到这里。
        (try? identityStore.identity().nodeID.uuidString) ?? "hub-unavailable"
    }

    private func startHub() {
        do {
            let identity = try identityStore.identity()
            let loopbackOnly = config.hubBindHost == "127.0.0.1" || config.hubBindHost == "localhost"
            let server = HubServer(handlers: HubServerHandlers(
                processReport: { [weak self] body in
                    await self?.hubProcessReport(body: body) ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
                },
                currentSnapshot: { [weak self] in
                    await self?.hubCurrentSnapshotResponse() ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
                },
                health: { [weak self] in
                    await self?.hubHealthResponse() ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
                }
            ))
            let port = UInt16(min(max(config.hubPort, 1), 65535))
            try server.start(port: port, loopbackOnly: loopbackOnly)
            self.server = server
            status.online = true
            logInfo("[fleet-hub] 监听端口 \(server.boundPort.map(String.init) ?? String(port))（scope=\(identity.nodeID.uuidString)）")
            applyOwnReport()
            startHubMaintenance()
        } catch {
            status.online = false
            status.lastError = "hub 启动失败：\(error.localizedDescription)"
            logError("[fleet-hub] 启动失败: \(error.localizedDescription)")
        }
    }

    /// hub 维护节拍：日切 / 窗口到期 / stale 翻转的快照重算与 generation 递增
    /// 不必等待新报告（§7.5）；顺手清过期窗口。
    private func startHubMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.hubMaintenanceTick()
            }
        }
    }

    private func hubMaintenanceTick() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(config.retainDays) * 24 * 60 * 60)
        do {
            _ = try store.pruneWindows(scope: hubScope, olderThan: cutoff)
            _ = try assembleSnapshot(now: Date())
        } catch {
            logWarn("[fleet-hub] 维护节拍失败: \(error.localizedDescription)")
        }
    }

    /// hub 本机数据变化：同一 builder 生成报告，不经 HTTP（§7.2）。
    private func applyOwnReport() {
        do {
            let identity = try identityStore.identity()
            let seq = try identityStore.allocateSeq()
            let input = UsageReportInput(
                identity: identity,
                nodeName: nodeName,
                bindings: bindings,
                statuses: statuses
            )
            let report = UsageReportBuilder.build(input, seq: seq)
            let validation = FleetReportValidator.validate(report)
            let outcome = try store.applyReport(report, validation: validation, scope: hubScope)
            logInfo("[fleet-hub] 本机报告 seq=\(seq) daily=\(outcome.dailyApplied) quotas=\(outcome.quotasApplied)")
            _ = try assembleSnapshot(now: Date())
        } catch {
            status.lastError = "本机报告落库失败：\(error.localizedDescription)"
            logError("[fleet-hub] 本机报告落库失败: \(error.localizedDescription)")
        }
    }

    private func hubProcessReport(body: Data) async -> HubServerResponse {
        let report: NodeUsageReport
        do {
            report = try FleetCodec.decode(NodeUsageReport.self, from: body)
        } catch {
            return HubServerResponse.error(400, "Bad Request", "报告解码失败：\(error.localizedDescription)")
        }
        // 每节点限流（§4.3）。
        let nodeID = report.node.nodeID
        if let last = lastRequestByNode[nodeID],
           Date().timeIntervalSince(last) < FleetProtocol.minRequestInterval {
            return HubServerResponse.error(429, "Too Many Requests", "同一节点请求间隔不足 1s")
        }
        lastRequestByNode[nodeID] = Date()

        let validation = FleetReportValidator.validate(report)
        guard validation.envelopeValid else {
            return HubServerResponse.error(400, "Bad Request", validation.envelopeError ?? "信封校验失败")
        }
        do {
            let outcome = try store.applyReport(report, validation: validation, scope: hubScope)
            if outcome.rejectedStaleSeq {
                logInfo("[fleet-hub] node=\(report.node.nodeName) seq=\(report.seq) 重复/乱序，拒绝")
            }
            if validation.dailyBucketsError != nil {
                logWarn("[fleet-hub] node=\(report.node.nodeName) 日桶通道拒绝：\(validation.dailyBucketsError!)")
            }
            if validation.quotasError != nil {
                logWarn("[fleet-hub] node=\(report.node.nodeName) 额度通道拒绝：\(validation.quotasError!)")
            }
            if validation.windowDroppedRowCount > 0 {
                logWarn("[fleet-hub] node=\(report.node.nodeName) 丢弃窗口行 \(validation.windowDroppedRowCount) 条")
            }
            logInfo("[fleet-hub] POST /v1/usage/day node=\(report.node.nodeName) status=200 bytes=\(body.count)")
            return snapshotResponse()
        } catch {
            logError("[fleet-hub] 报告落库失败: \(error.localizedDescription)")
            return HubServerResponse.error(500, "Internal Server Error", "报告落库失败")
        }
    }

    private func hubCurrentSnapshotResponse() async -> HubServerResponse {
        snapshotResponse()
    }

    private func hubHealthResponse() async -> HubServerResponse {
        do {
            let identity = try identityStore.identity()
            let payload = FleetHealth(
                ok: true,
                nodeID: identity.nodeID,
                protocolVersion: FleetProtocol.version
            )
            return HubServerResponse.json(200, "OK", try FleetCodec.encode(payload))
        } catch {
            return HubServerResponse.error(500, "Internal Server Error", "身份不可用")
        }
    }

    private func snapshotResponse() -> HubServerResponse {
        do {
            let snapshot = try assembleSnapshot(now: Date())
            let data = try FleetCodec.encode(snapshot)
            guard data.count <= FleetProtocol.maxResponseBodyBytes else {
                logError("[fleet-hub] 快照超过 \(FleetProtocol.maxResponseBodyBytes) bytes")
                return HubServerResponse.error(500, "Internal Server Error", "快照超过响应上限")
            }
            return HubServerResponse.json(200, "OK", data)
        } catch {
            logError("[fleet-hub] 快照装配失败: \(error.localizedDescription)")
            return HubServerResponse.error(500, "Internal Server Error", "快照装配失败")
        }
    }

    // MARK: - 快照装配（hub）

    /// 纯读装配：不修改 store。可见签名变化时递增 generation（持久）。
    func assembleSnapshot(now: Date) throws -> FleetSnapshot {
        let identity = try identityStore.identity()
        let scope = identity.nodeID.uuidString
        let state = try store.loadHubState(scope: scope)
        let staleAfter = TimeInterval(config.staleAfterSeconds)

        let nodeSnapshots: [FleetNodeSnapshot] = state.nodes.map { record in
            FleetNodeSnapshot(
                nodeID: record.nodeID,
                nodeName: record.report.nodeName ?? record.nodeID.uuidString,
                lastSeenAt: record.lastSeenAt,
                seq: record.seq,
                stale: now.timeIntervalSince(record.lastSeenAt) > staleAfter,
                dailyBuckets: record.report.dailyBuckets ?? [],
                windowUsage: record.windowRows,
                quotas: record.report.quotas ?? [],
                attributionFingerprint: record.report.attributionFingerprint
            )
        }

        let fleetDaily = FleetMerger.mergeDailyBuckets(
            nodeSnapshots.map(\.dailyBuckets),
            now: now
        )
        let windowContributions = nodeSnapshots.map { node in
            FleetMerger.NodeWindowContribution(
                nodeID: node.nodeID,
                stale: node.stale,
                rows: node.windowUsage
            )
        }
        let fleetWindows = FleetMerger.aggregateWindows(
            windowContributions,
            knownNodeIDs: nodeSnapshots.map(\.nodeID)
        )
        let candidates = nodeSnapshots.flatMap { node in
            node.quotas.map { quota in
                FleetMerger.QuotaCandidate(
                    sourceNodeID: node.nodeID,
                    sourceNodeName: node.nodeName,
                    report: quota
                )
            }
        }
        let elected = FleetMerger.electQuotas(
            candidates: candidates,
            hubNodeID: identity.nodeID,
            quotaMaxAgeSeconds: TimeInterval(config.quotaMaxAgeSeconds),
            now: now
        )

        let snapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: identity.nodeID,
            generation: state.generation,
            hub: FleetNodeIdentity(
                nodeID: identity.nodeID,
                nodeName: nodeName,
                timezoneID: TimeZone.current.identifier,
                platform: "macOS"
            ),
            generatedAt: now,
            nodes: nodeSnapshots.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString },
            fleet: FleetAggregate(dailyBuckets: fleetDaily, windowUsage: fleetWindows),
            electedQuotas: elected
        )

        // 可见签名（stale 集合 / 日窗 / generation 基线）变化 → 递增 generation，
        // 让 node 能感知日切与 stale 翻转（§5.2）。
        let signature = snapshotVisibilitySignature(snapshot)
        if let last = lastAssembledSignature, last != signature {
            _ = try store.bumpGeneration(scope: scope)
            lastAssembledSignature = signature
            var bumped = snapshot
            bumped.generation = try store.generation(scope: scope)
            latestSnapshot = bumped
            return bumped
        }
        lastAssembledSignature = signature
        latestSnapshot = snapshot
        return snapshot
    }

    private func snapshotVisibilitySignature(_ snapshot: FleetSnapshot) -> String {
        let nodePart = snapshot.nodes
            .map { "\($0.nodeID.uuidString):\($0.stale ? "s" : "a"):\($0.dailyBuckets.count):\($0.quotas.count)" }
            .joined(separator: ",")
        let dayPart = snapshot.fleet.dailyBuckets.map(\.dayKey).joined(separator: ",")
        let electedPart = snapshot.electedQuotas.map { "\($0.quotaProviderID):\($0.sourceNodeID.uuidString):\($0.isStale)" }
            .joined(separator: ",")
        return nodePart + "|" + dayPart + "|" + electedPart
    }

    // MARK: - Node 侧

    private func startNodeLoop() {
        do {
            let client = try SyncClient(hubURL: config.effectiveHubURL)
            self.client = client
            _ = try? identityStore.identity() // 启动即验证身份可用；失败走错误态
        } catch {
            status.online = false
            status.lastError = error.localizedDescription
            logError("[fleet-node] 初始化失败: \(error.localizedDescription)")
            return
        }
        status.online = false

        let wake = AsyncStream<Void> { continuation in
            self.wakeContinuation = continuation
        }
        let interval = TimeInterval(max(config.pushIntervalSeconds, 1))
        pushTask = Task { [weak self] in
            // 启动先推一次；后续每 interval 或数据变更唤醒。
            self?.wakeContinuation?.yield()
            for await _ in wake {
                guard let self, !Task.isCancelled else { break }
                await self.nodePushCycle()
                // 周期节拍：interval 后再唤醒一次（数据变更也会提前唤醒）。
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    self?.wakeContinuation?.yield()
                }
                _ = await timer.value
            }
        }
    }

    private func nodePushCycle() async {
        guard let client else { return }
        let versionAtStart = configVersion
        lastPushAt = Date()
        do {
            let identity = try identityStore.identity()
            // 先持久化递增 seq，成功后才发送（§6.2）。
            let seq = try identityStore.allocateSeq()
            let input = UsageReportInput(
                identity: identity,
                nodeName: nodeName,
                bindings: bindings,
                statuses: statuses
            )
            let report = UsageReportBuilder.build(input, seq: seq)

            if verifiedHubUUID == nil {
                let health = try await client.fetchHealth()
                guard health.ok, health.protocolVersion == FleetProtocol.version else {
                    status.lastError = "hub 协议版本不匹配"
                    return
                }
                verifiedHubUUID = health.nodeID
            }
            let snapshot = try await client.postReport(report)
            // 迟到响应丢弃：配置版本已变（§6.5）。
            guard configVersion == versionAtStart else { return }
            try acceptSnapshot(snapshot, from: client)
            status.online = true
            status.lastSyncAt = Date()
            status.lastError = nil
        } catch {
            // 推送被拒但链路是通的（4xx/5xx）：兜底拉一次快照（§4.2 GET），
            // 让离线期间的额度/用量变化仍能同步回来。
            if case QuotaError.httpError = error {
                if let snapshot = try? await client.fetchSnapshot() {
                    guard configVersion == versionAtStart else { return }
                    try? acceptSnapshot(snapshot, from: client)
                    status.online = true
                    status.lastSyncAt = Date()
                }
            }
            // 429（间隔限流）不算离线：本轮已被 hub 拒收，等下个节拍。
            if case QuotaError.httpError(let statusCode, _) = error, statusCode == 429 {
                logInfo("[fleet-node] 推送被限流，下个节拍重试")
                return
            }
            status.online = false
            status.lastError = error.localizedDescription
            logWarn("[fleet-node] 推送失败（保留最后有效快照）: \(error.localizedDescription)")
        }
    }

    /// 仅接受已验证 hub 且 generation 更新的快照（§6.5）。
    private func acceptSnapshot(_ snapshot: FleetSnapshot, from client: SyncClient) throws {
        guard snapshot.protocolVersion == FleetProtocol.version else { return }
        guard let verified = verifiedHubUUID, snapshot.hubUUID == verified else { return }
        let upstreamScope = client.upstreamKey + "|" + snapshot.hubUUID.uuidString
        let cached = try store.cachedSnapshotGeneration(upstreamScope: upstreamScope)
        if let cached, snapshot.generation <= cached { return }
        try store.saveSnapshot(snapshot, upstreamScope: upstreamScope)
        latestSnapshot = snapshot
        status.snapshotGeneration = snapshot.generation
    }
}
