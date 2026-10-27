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
///   普通响应仅当对应当前 upstreamKey、已验证的 hubUUID 且 generation 更新时
///   才提交快照（§6.5）。唯一例外是当前 POST 响应的本机 seq 精确匹配本轮已提交
///   seq 时，可确认同 UUID hub 的数据重建并接受较低 generation。配置切换后迟到响应丢弃。
/// - 本地显示永不依赖网络（§3 不变量 3）：本机用量照常走既有链路。
@MainActor
final class FleetSyncCoordinator: ObservableObject {
    @Published private(set) var status = FleetSyncStatusInfo()
    /// node：hub 回传的最近快照；hub：本机装配的最近快照。
    @Published private(set) var latestSnapshot: FleetSnapshot?

    private let store: FleetStore
    /// 设备身份加载/创建回调。来源是配置目录中的独立 `.deviceId` 文件。
    private let loadDeviceID: (() throws -> UUID)?
    /// 本机稳定节点身份：来自独立设备身份存储，与可同步配置无关。
    private var nodeID: UUID?
    private var client: SyncClient?
    private var server: HubServer?
    private var config = SyncConfig.default
    private var role: SyncRole = .off
    private var statuses: [ProviderStatus] = []
    private var bindings: [ClientProviderBinding] = []
    private var effectivePushInterval: TimeInterval = AppConfig.default.effectiveFleetSyncPushInterval
    private var nodeName = ""
    private var configVersion = 0
    private var pushTask: Task<Void, Never>?
    private var pushTimerTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<NodePushWake>.Continuation?
    private var isStarting = false
    private var hubRuntimeID: UUID?
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
    /// node 侧：最近一次被接受快照回执的逐天摘要（upstreamScope → dayKey → digest）。
    /// 内存态即可：重启/换 hub 后为空 → 首拍全量重建基线（等价首次配置）。
    private var dailyDigestCache: [String: [String: String]] = [:]
    /// node 侧：数据变更唤醒的最小推送间隔；短于它的变更由周期节拍覆盖。
    private var lastPushAt: Date?

    private enum NodePushWake: Sendable {
        case initialOrConfiguration
        case periodic
        case dataChanged
    }

    private func hubListenerConfigChanged(from old: SyncConfig, to new: SyncConfig) -> Bool {
        old.hubPort != new.hubPort || old.hubBindHost != new.hubBindHost
    }

    init(store: FleetStore, loadDeviceID: (() throws -> UUID)? = nil) {
        self.store = store
        self.loadDeviceID = loadDeviceID
    }

    /// hub 实际监听端口（端口 0 时由系统分配；测试/发现用）。
    var listeningPort: UInt16? { server?.boundPort }

    /// 本机稳定 nodeID（UI 标「本机」节点 / 生效额度来源判断用）。
    var localNodeID: UUID? { nodeID }

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
        if role != .off || server != nil || client != nil {
            shutdown(clearSyncedState: true)
        }
        isStarting = true
        let newConfig = appConfig.effectiveSyncConfig
        self.config = newConfig
        self.effectivePushInterval = appConfig.effectiveFleetSyncPushInterval
        self.statuses = statuses
        self.bindings = appConfig.clientBindings
        self.nodeName = self.config.effectiveNodeName.isEmpty
            ? SyncConfig.defaultNodeName()
            : self.config.effectiveNodeName
        do {
            if SyncRole.derive(config: appConfig) != .off {
                try resolveNodeIDIfNeeded()
            }
        } catch {
            role = SyncRole.derive(config: appConfig)
            status.role = role
            status.online = false
            status.lastError = "设备身份不可用：\(error.localizedDescription)"
            isStarting = false
            return
        }
        isStarting = false
        boot()
    }

    /// 配置或本机数据变化：hub 立即重建本机报告；node 唤醒推送循环。
    /// configVersion 递增让在飞响应作废（§6.5）。
    func update(config appConfig: AppConfig, statuses: [ProviderStatus]) {
        let newConfig = appConfig.effectiveSyncConfig
        let previousConfig = config
        let newRole = SyncRole.derive(config: appConfig)
        let roleChanged = newRole != role
        let upstreamChanged = newConfig.effectiveHubURL != previousConfig.effectiveHubURL
        let bindingsChanged = appConfig.clientBindings != bindings
        let newEffectivePushInterval = appConfig.effectiveFleetSyncPushInterval
        let effectiveIntervalChanged = newEffectivePushInterval != effectivePushInterval
        let oldNodeID = nodeID

        var identityError: Error?
        if newRole != .off && nodeID == nil {
            do {
                try resolveNodeIDIfNeeded()
            } catch {
                identityError = error
            }
        }
        let identityChanged = oldNodeID != nodeID

        // configVersion 只在影响运行时或上报内容的配置/角色变化时递增。
        // statuses 变化也走
        // 这条路（每次配额刷新、每次扫描落库、每次 rebuildStatuses 都广播），
        // 若一并自增，在飞推送的响应会被当成「迟到响应」丢掉：快照不落缓存、
        // 摘要回执不推进（增量补发退化成每拍全量）、lastSyncAt 不刷新。
        if newConfig != config || roleChanged || bindingsChanged || effectiveIntervalChanged {
            configVersion += 1
        }

        self.statuses = statuses
        self.bindings = appConfig.clientBindings
        self.config = newConfig
        self.effectivePushInterval = newEffectivePushInterval
        self.nodeName = newConfig.effectiveNodeName.isEmpty
            ? SyncConfig.defaultNodeName()
            : newConfig.effectiveNodeName

        if isStarting { return }

        if let identityError {
            shutdown(clearSyncedState: true)
            role = newRole
            status.role = newRole
            status.online = false
            status.lastError = "设备身份不可用：\(identityError.localizedDescription)"
            return
        }

        switch newRole {
        case .off:
            if role != .off || roleChanged { shutdown(clearSyncedState: true) }
        case .hub:
            if roleChanged || upstreamChanged || identityChanged || server == nil {
                shutdown(clearSyncedState: true)
                boot()
            } else if hubListenerConfigChanged(from: previousConfig, to: newConfig) {
                restartHubListener()
            } else {
                scheduleOwnReportRebuild()
            }
        case .node:
            if roleChanged {
                shutdown(clearSyncedState: true)
                boot()
            } else if upstreamChanged || identityChanged {
                resetNodeSnapshotState()
                do {
                    client = try SyncClient(hubURL: newConfig.effectiveHubURL)
                    status.lastError = nil
                    // 初次配置可能因非法 URL 未创建消费循环和 ticker；修正
                    // upstream 后必须补齐 runtime，单独 yield 到 nil continuation
                    // 会让节点永久停摆。已运行时复用同一个串行 consumer。
                    activateNodePushRuntime()
                } catch {
                    client = nil
                    status.online = false
                    status.lastError = error.localizedDescription
                }
            } else if effectiveIntervalChanged {
                ensureNodePushRuntime()
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
        wakeContinuation?.yield(.dataChanged)
    }

    private func resetNodeSnapshotState() {
        verifiedHubUUID = nil
        dailyDigestCache.removeAll()
        lastPushAt = nil
        latestSnapshot = nil
        status.online = false
        status.lastSyncAt = nil
        status.snapshotGeneration = nil
        status.lastError = nil
    }

    func stop() {
        shutdown(clearSyncedState: true)
    }

    // MARK: - 启动 / 停机

    /// 身份解析只在本协调器尚无身份时调用；配置更新和角色切换都不会改变身份。
    /// 存储读取/创建成功后才将身份发布到 runtime。
    private func resolveNodeIDIfNeeded() throws {
        guard nodeID == nil else { return }
        guard let loadDeviceID else { throw DeviceIdentityUnavailable.persistenceUnavailable }
        nodeID = try loadDeviceID()
    }

    private enum DeviceIdentityUnavailable: LocalizedError {
        case persistenceUnavailable

        var errorDescription: String? {
            "当前协调器没有设备身份存储回调"
        }
    }

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

    private func shutdown(clearSyncedState: Bool = false) {
        configVersion += 1
        pushTask?.cancel()
        pushTask = nil
        pushTimerTask?.cancel()
        pushTimerTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        ownReportDebounceTask?.cancel()
        ownReportDebounceTask = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        hubRuntimeID = nil
        server?.stop()
        server = nil
        client = nil
        verifiedHubUUID = nil
        dailyDigestCache.removeAll()
        lastRequestByNode.removeAll()
        lastAssembledSignature = nil
        role = .off
        status.role = .off
        status.online = false
        if clearSyncedState {
            latestSnapshot = nil
            dailyDigestCache.removeAll()
            lastPushAt = nil
            status.lastSyncAt = nil
            status.snapshotGeneration = nil
            status.lastError = nil
        }
    }

    // MARK: - Hub 侧

    private var hubScope: String {
        nodeID?.uuidString ?? "hub-unavailable"
    }

    private func startHub() {
        do {
            guard nodeID != nil else { throw HubBootError.noIdentity }
            status.online = false
            status.lastError = nil
            try startHubListener()
            applyOwnReport()
            startHubMaintenance()
        } catch {
            server?.stop()
            server = nil
            hubRuntimeID = nil
            status.online = false
            status.lastError = "hub 启动失败：\(error.localizedDescription)"
            logError("[fleet-hub] 启动失败: \(error.localizedDescription)")
        }
    }

    private func startHubListener() throws {
        guard nodeID != nil else { throw HubBootError.noIdentity }
        let runtimeID = UUID()
        hubRuntimeID = runtimeID
        let server = HubServer(handlers: HubServerHandlers(
            processReport: { [weak self] body in
                await self?.hubProcessReport(body: body, runtimeID: runtimeID)
                    ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
            },
            currentSnapshot: { [weak self] in
                await self?.hubCurrentSnapshotResponse(runtimeID: runtimeID)
                    ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
            },
            health: { [weak self] in
                await self?.hubHealthResponse(runtimeID: runtimeID)
                    ?? HubServerResponse.error(500, "Internal Server Error", "hub 已停止")
            }
        ))
        self.server = server
        let loopbackOnly = config.hubBindHost == "127.0.0.1" || config.hubBindHost == "localhost"
        let port = UInt16(min(max(config.hubPort, 1), 65535))
        try server.start(port: port, loopbackOnly: loopbackOnly) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.hubListenerDidUpdate(event, runtimeID: runtimeID)
            }
        }
    }

    private func restartHubListener() {
        server?.stop()
        server = nil
        hubRuntimeID = nil
        status.online = false
        status.lastError = nil
        do {
            try startHubListener()
        } catch {
            server?.stop()
            server = nil
            hubRuntimeID = nil
            status.online = false
            status.lastError = "hub 启动失败：\(error.localizedDescription)"
            logError("[fleet-hub] 重启监听失败: \(error.localizedDescription)")
        }
    }

    private func hubListenerDidUpdate(_ event: HubServer.ListenerEvent, runtimeID: UUID) {
        guard hubRuntimeID == runtimeID, server != nil else { return }
        switch event {
        case .ready(let port):
            status.online = true
            status.lastError = nil
            logInfo("[fleet-hub] 监听端口 \(port)（scope=\(hubScope)）")
        case .failed(let message):
            status.online = false
            status.lastError = "hub 监听失败：\(message)"
            logError("[fleet-hub] NWListener 失败: \(message)")
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
    private enum HubBootError: Error { case noIdentity }

    private func applyOwnReport() {
        do {
            guard let identity = nodeID else { throw HubBootError.noIdentity }
            let seq = try store.allocateLocalSeq()
            let input = UsageReportInput(
                nodeID: identity,
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

    private func hubProcessReport(body: Data, runtimeID: UUID) async -> HubServerResponse {
        guard hubRuntimeID == runtimeID, role == .hub else {
            return HubServerResponse.error(503, "Service Unavailable", "hub runtime 已切换")
        }
        let report: NodeUsageReport
        do {
            report = try FleetCodec.decode(NodeUsageReport.self, from: body)
        } catch {
            return HubServerResponse.error(400, "Bad Request", "报告解码失败：\(error.localizedDescription)")
        }
        // 每节点限流（§4.3）。
        let nodeID = report.node.nodeID
        let now = Date()
        // 限流表按对端提供的 nodeID 建键且从不清理 → 无鉴权监听下，LAN 上任意
        // 主机都能用随机 UUID 把它撑大。顺手裁掉早于最小间隔数倍的旧条目。
        let staleBefore = now.addingTimeInterval(-FleetProtocol.minRequestInterval * 10)
        if lastRequestByNode.count > 64 {
            lastRequestByNode = lastRequestByNode.filter { $0.value > staleBefore }
        }
        if let last = lastRequestByNode[nodeID],
           now.timeIntervalSince(last) < FleetProtocol.minRequestInterval {
            return HubServerResponse.error(429, "Too Many Requests", "同一节点请求间隔不足 1s")
        }
        lastRequestByNode[nodeID] = now

        let validation = FleetReportValidator.validate(report)
        guard validation.envelopeValid else {
            return HubServerResponse.error(400, "Bad Request", validation.envelopeError ?? "信封校验失败")
        }
        do {
            let outcome = try store.applyReport(report, validation: validation, scope: hubScope)
            if outcome.rejectedStaleSeq {
                // 序号落后必须回**可区分**的状态码：回 200 的话 node 会以为
                // 推送成功，而 hub 一份都没收——数据永远不落地，且 hub 上同
                // nodeID 的另一台机器的数据会被当成本机的显示。
                logWarn("[fleet-hub] 报告序号落后（seq=\(report.seq) ≤ high-water=\(outcome.highWaterSeq)），拒收")
                return staleSeqResponse(highWater: outcome.highWaterSeq)
            }
            if validation.dailyBucketsError != nil {
                logWarn("[fleet-hub] 日桶通道拒绝：\(validation.dailyBucketsError!)")
            }
            if validation.quotasError != nil {
                logWarn("[fleet-hub] 额度通道拒绝：\(validation.quotasError!)")
            }
            if validation.windowDroppedRowCount > 0 {
                logWarn("[fleet-hub] 丢弃窗口行 \(validation.windowDroppedRowCount) 条")
            }
            // 日志纪律（§9.3）：只记状态与尺寸，不记 body/header——对端可控的
            // nodeName / dayKey 不进日志（可注入换行伪造日志行）。
            logInfo("[fleet-hub] POST \(FleetProtocol.usageDayPath) status=200 bytes=\(body.count)")
            return snapshotResponse(acknowledging: report.node.nodeID)
        } catch {
            logError("[fleet-hub] 报告落库失败: \(error.localizedDescription)")
            return HubServerResponse.error(500, "Internal Server Error", "报告落库失败")
        }
    }

    /// 序号落后的响应：409 + hub 侧 high-water。node 据此重建本机序号
    /// （§7.3），否则这份报告会永久被拒；快照由 node 用 GET 兜底取（响应体
    /// 只留 500 字符，塞不进快照）。
    private func staleSeqResponse(highWater: Int) -> HubServerResponse {
        let payload = FleetStaleSeqPayload(
            error: "报告序号落后于主节点 high-water",
            highWaterSeq: highWater
        )
        let body = (try? FleetCodec.encode(payload)) ?? Data("{\"error\":\"seq stale\"}".utf8)
        return HubServerResponse.json(409, "Conflict", body)
    }

    private func hubCurrentSnapshotResponse(runtimeID: UUID) async -> HubServerResponse {
        guard hubRuntimeID == runtimeID, role == .hub else {
            return HubServerResponse.error(503, "Service Unavailable", "hub runtime 已切换")
        }
        return snapshotResponse()
    }

    private func hubHealthResponse(runtimeID: UUID) async -> HubServerResponse {
        guard hubRuntimeID == runtimeID, role == .hub else {
            return HubServerResponse.error(503, "Service Unavailable", "hub runtime 已切换")
        }
        guard let nodeID else {
            return HubServerResponse.error(500, "Internal Server Error", "身份不可用")
        }
        do {
            let payload = FleetHealth(
                ok: true,
                nodeID: nodeID,
                protocolVersion: FleetProtocol.version
            )
            return HubServerResponse.json(200, "OK", try FleetCodec.encode(payload))
        } catch {
            return HubServerResponse.error(500, "Internal Server Error", "身份不可用")
        }
    }

    private func snapshotResponse(acknowledging nodeID: UUID? = nil) -> HubServerResponse {
        do {
            let snapshot = try assembleSnapshot(now: Date())
            // The hub keeps the full per-node snapshot for its own UI. A node only
            // needs the fleet aggregate plus its own compact sequence/digest ACK;
            // returning every node's detail duplicates the aggregate and scales
            // the response with all local histories.
            let responseSnapshot = snapshot.nodeResponse(acknowledging: nodeID)
            let data = try FleetCodec.encode(responseSnapshot)
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
        guard let identity = nodeID else { throw HubBootError.noIdentity }
        let scope = identity.uuidString
        let state = try store.loadHubState(scope: scope)
        let staleAfter = TimeInterval(config.staleAfterSeconds)

        // 装配侧再过一道窗口：快照只含 today + previous six（§4）。落库侧已经
        // 裁过，这里防的是旧库/异常数据把窗口外的天带进快照（载荷与节点卡片
        // 的「7 天」口径都依赖这个不变量）。
        let allowedDays = Set(FleetMerger.dayKeyWindow(now: now))
        let nodeSnapshots: [FleetNodeSnapshot] = state.nodes.map { record in
            let buckets = (record.report.dailyBuckets ?? [])
                .filter { allowedDays.contains($0.dayKey) }
            return FleetNodeSnapshot(
                nodeID: record.nodeID,
                nodeName: record.report.nodeName ?? record.nodeID.uuidString,
                lastSeenAt: record.lastSeenAt,
                seq: record.seq,
                stale: now.timeIntervalSince(record.lastSeenAt) > staleAfter,
                dailyBuckets: buckets,
                windowUsage: record.windowRows,
                quotas: record.report.quotas ?? [],
                attributionFingerprint: record.report.attributionFingerprint,
                // 逐天摘要回执（增量日桶 2026-10-24）：node 据此只补发不一致的天。
                // 回执覆盖**已存的全部天**（不是只覆盖上面发布的那几天）：hub 与
                // 节点时钟差一天时，节点那天不在 hub 的窗口里、不会进快照，但回执
                // 仍要认它——否则 node 每拍都在重发那一天（回执永远不覆盖它）。
                // 整条日桶通道缺席时回执也缺席（等效空回执 → 触发全量补发）。
                dailyDigests: record.report.dailyBuckets == nil ? nil : Dictionary(
                    (record.report.dailyBuckets ?? []).map { bucket in
                        // A source-aware partial bucket is stored as a merged
                        // view, so ACK the last accepted input digest instead
                        // of hashing that merged view. Older rows have no input
                        // digest map and fall back to their stored bucket hash.
                        let digest = record.report.dailyInputDigests?[bucket.dayKey]
                            ?? FleetDailyDigest.digest(bucket)
                        return (bucket.dayKey, digest)
                    },
                    uniquingKeysWith: { _, new in new }
                )
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
        // 窗口前沿过滤（2026-10-27）：快照只携带每 (provider, model, kind)
        // 最新的少数边界——历史边界组没有新贡献也没有消费方，透传它们只会
        // 把存储的历史累积搬进下发给每个节点的载荷。
        let fleetWindows = FleetMerger.windowFrontier(
            FleetMerger.aggregateWindows(
                windowContributions,
                knownNodeIDs: nodeSnapshots.map(\.nodeID)
            )
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
            hubNodeID: identity,
            quotaMaxAgeSeconds: TimeInterval(config.quotaMaxAgeSeconds),
            now: now
        )

        let snapshot = FleetSnapshot(
            protocolVersion: FleetProtocol.version,
            hubUUID: identity,
            generation: state.generation,
            hub: FleetNodeIdentity(
                nodeID: identity,
                nodeName: nodeName,
                timezoneID: TimeZone.current.identifier,
                platform: "macOS"
            ),
            generatedAt: now,
            nodes: nodeSnapshots.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString },
            fleet: FleetAggregate(dailyBuckets: fleetDaily, windowUsage: fleetWindows),
            electedQuotas: elected,
            participantCount: nodeSnapshots.count
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
            guard nodeID != nil else {
                status.lastError = "节点身份不可用"
                return
            }
        } catch {
            status.online = false
            status.lastError = error.localizedDescription
            logError("[fleet-node] 初始化失败: \(error.localizedDescription)")
            return
        }
        status.online = false
        activateNodePushRuntime()
    }

    /// 配置热更新可能发生在启动失败后，此时 client 可以重建，但 consumer 和
    /// ticker 尚不存在。统一从这里补齐；已有 consumer 保持单一串行执行。
    private func ensureNodePushRuntime() {
        guard client != nil else {
            startNodeLoop()
            return
        }
        activateNodePushRuntime()
    }

    private func activateNodePushRuntime() {
        guard client != nil else { return }
        guard nodeID != nil else {
            status.lastError = "节点身份不可用"
            return
        }
        if pushTask == nil || wakeContinuation == nil {
            pushTask?.cancel()
            wakeContinuation?.finish()
            let (wake, continuation) = AsyncStream<NodePushWake>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            wakeContinuation = continuation
            pushTask = Task { @MainActor [weak self] in
                for await reason in wake {
                    guard let self, !Task.isCancelled else { break }
                    if case .dataChanged = reason,
                       let last = self.lastPushAt,
                       Date().timeIntervalSince(last) < 5 {
                        continue
                    }
                    await self.nodePushCycle(versionAtStart: self.configVersion)
                }
            }
        }

        startNodePushTimer(interval: effectivePushInterval)
        wakeContinuation?.yield(.initialOrConfiguration)
    }

    private func startNodePushTimer(interval: TimeInterval) {
        pushTimerTask?.cancel()
        pushTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                self.wakeContinuation?.yield(.periodic)
            }
        }
    }

    private func nodePushCycle(versionAtStart: Int) async {
        guard let client else { return }
        lastPushAt = Date()
        do {
            guard let identity = nodeID else { return }
            // 先持久化递增 seq（fleet.sqlite），成功后才发送（§7.3）。
            let seq = try store.allocateLocalSeq()
            let input = UsageReportInput(
                nodeID: identity,
                nodeName: nodeName,
                bindings: bindings,
                statuses: statuses
            )
            var report = UsageReportBuilder.build(input, seq: seq)

            if verifiedHubUUID == nil {
                let health = try await client.fetchHealth()
                guard configVersion == versionAtStart else { return }
                guard health.ok, health.protocolVersion == FleetProtocol.version else {
                    status.lastError = "hub 协议版本不匹配"
                    return
                }
                verifiedHubUUID = health.nodeID
            }
            // 增量日桶（2026-10-24）：按回执摘要只发不一致的天；缓存为空（首次
            // 接触/重启/hub 丢数据）时保持全量。seq 已持久化，心跳节拍不跳号。
            if let verified = verifiedHubUUID {
                let upstreamScope = client.upstreamKey + "|" + verified.uuidString
                FleetDailyBackfill.filterReport(
                    &report,
                    cachedDigests: dailyDigestCache[upstreamScope] ?? [:]
                )
            }
            let snapshot = try await client.postReport(report)
            // 迟到响应丢弃：配置版本已变（§6.5）。
            guard configVersion == versionAtStart else { return }
            // 只有真实 POST 成功才解除上次上传错误；先清除旧错误，再采纳响应，
            // 让 acceptSnapshot 新发现的 hub 身份变化错误继续显示。
            status.lastError = nil
            _ = try acceptSnapshot(snapshot, from: client, submittedSeq: seq)
            status.online = true
            status.lastSyncAt = Date()
        } catch {
            // 所有在途请求的成功与错误路径都必须经过同一版本门控。
            // 上游、身份或角色切换后的旧错误不能覆盖新 runtime 状态。
            guard configVersion == versionAtStart else { return }
            // 409：hub 侧 high-water 更高（换了机器 / 本机序号被重置）→ 重建本机
            // 序号，下一拍就能收下。不重建的话这份报告会**永久**被拒，而界面
            // 一直显示「已连接」、数据永远不落地。
            if case QuotaError.httpError(let code, let body) = error,
               code == 409,
               let payload = Self.decodeStaleSeq(body) {
                do {
                    try store.resetLocalSeq(to: payload.highWaterSeq)
                } catch {
                    status.online = true
                    status.lastError = "主节点拒收旧序号，保存新序号失败：\(error.localizedDescription)"
                    logError("[fleet-node] 重建本机序号失败: \(error.localizedDescription)")
                    return
                }
                status.lastError = "报告序号落后，已重建本机序号（high-water=\(payload.highWaterSeq)）"
                status.online = true
                logWarn("[fleet-node] 报告序号落后，已重建本机序号=\(payload.highWaterSeq)")
                // 兜底 GET 一次快照：幂等重试照样能拿到全局数据（hub 的 409
                // 体只放得下 high-water，装不下快照）。
                let fallbackSnapshot = try? await client.fetchSnapshot()
                guard configVersion == versionAtStart else { return }
                if let snapshot = fallbackSnapshot {
                    _ = try? acceptSnapshot(snapshot, from: client)
                    status.online = true
                    status.lastSyncAt = Date()
                }
                return
            }
            if case QuotaError.httpError(let statusCode, _) = error {
                // GET 只恢复读取快照的能力，不代表 POST 报告已被 hub 接收；保留
                // 失败状态直到下一次真正成功的 POST。429 是限流提示，不覆盖旧错误。
                if statusCode != 429 {
                    status.lastError = error.localizedDescription
                }
                // 推送被拒但链路是通的（4xx/5xx）：兜底拉一次快照（§4.2 GET），
                // 让离线期间的额度/用量变化仍能同步回来。兜底成功后**直接返回**
                // （原实现会继续往下走把 online 又置回 false，兜底等于白做）。
                let fallbackSnapshot = try? await client.fetchSnapshot()
                guard configVersion == versionAtStart else { return }
                if let snapshot = fallbackSnapshot {
                    _ = try? acceptSnapshot(snapshot, from: client)
                    status.online = true
                    status.lastSyncAt = Date()
                    return
                }
                // 429（间隔限流）不算离线：本轮已被 hub 拒收，等下个节拍。
                if statusCode == 429 {
                    logInfo("[fleet-node] 推送被限流，下个节拍重试")
                    return
                }
                // 5xx 是 hub 侧的问题（快照超限、落库失败……），链路本身是通的
                // → 不判离线，只报错误（§8：只有网络失败才算离线）。
                if (500...599).contains(statusCode) {
                    status.lastError = error.localizedDescription
                    logWarn("[fleet-node] hub 返回 \(statusCode)（链路正常）：\(error.localizedDescription)")
                    return
                }
            }
            status.online = false
            status.lastError = error.localizedDescription
            logWarn("[fleet-node] 推送失败（保留最后有效快照）: \(error.localizedDescription)")
        }
    }

    /// 解析 hub 的 409 响应体（带 hub 侧 high-water）。
    private static func decodeStaleSeq(_ body: String) -> FleetStaleSeqPayload? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? FleetCodec.decode(FleetStaleSeqPayload.self, from: data)
    }

    /// 仅接受已验证 hub 且 generation 更新的快照（§6.5）；
    /// 只有当前 POST 响应精确确认本轮 seq 时，才允许同 UUID hub 重建后的低 generation。
    /// 返回是否采纳：hub 换机（身份变了）时返回 false 并触发重新握手，
    /// 不再把快照静默丢掉（原来会永远收不到数据，界面却显示「已连接」）。
    private func acceptSnapshot(
        _ snapshot: FleetSnapshot,
        from client: SyncClient,
        submittedSeq: Int? = nil
    ) throws -> Bool {
        guard snapshot.protocolVersion == FleetProtocol.version else { return false }
        if let verified = verifiedHubUUID, snapshot.hubUUID != verified {
            logWarn("[fleet-node] 主节点身份已变更（\(verified.uuidString) → \(snapshot.hubUUID.uuidString)），重新握手")
            verifiedHubUUID = nil
            status.lastError = "主节点身份已变更，正在重新握手"
            return false
        }
        guard let verified = verifiedHubUUID, snapshot.hubUUID == verified else { return false }
        let upstreamScope = client.upstreamKey + "|" + snapshot.hubUUID.uuidString
        let cached = try store.cachedSnapshotGeneration(upstreamScope: upstreamScope)
        // A successful POST response can prove that a same-UUID hub has reset or
        // rolled back its database: it must include this exact accepted report.
        // Ordinary GETs and stale/mismatched POST snapshots keep the strict gate.
        let confirmsSubmittedReport: Bool
        if let submittedSeq,
           let identity = nodeID,
           let own = snapshot.nodes.first(where: { $0.nodeID == identity }) {
            confirmsSubmittedReport = own.seq == submittedSeq
        } else {
            confirmsSubmittedReport = false
        }
        if let cached, snapshot.generation <= cached, !confirmsSubmittedReport { return false }
        let nodeSnapshot = nodeID.map(snapshot.compactedForNode) ?? snapshot
        // 内容未变化的快照不重写缓存（2026-10-27 裁定）：generation 未推进
        // 且仅凭本轮 seq 确认接受 ⇒ hub 可见状态与缓存同代（generatedAt /
        // 本节点 seq 每拍必变，字节比较没有意义）。digest 回执仍照常更新。
        let contentUnchanged = snapshot.generation == cached && confirmsSubmittedReport
        if !contentUnchanged {
            try store.saveSnapshot(nodeSnapshot, upstreamScope: upstreamScope)
        }
        // 回执只在快照被接受时更新：hub 未应用我们的数据（重放拒绝等）时，
        // 回执保持旧值 → 下拍按差异自然重发。
        if let identity = nodeID,
           let own = nodeSnapshot.nodes.first(where: { $0.nodeID == identity }) {
            dailyDigestCache[upstreamScope] = own.dailyDigests ?? [:]
        }
        latestSnapshot = nodeSnapshot
        status.snapshotGeneration = nodeSnapshot.generation
        return true
    }
}
