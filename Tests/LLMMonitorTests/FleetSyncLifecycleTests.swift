import XCTest
import Network
import Darwin
@testable import LLM_monitor

private func makeLifecycleSnapshot(hubID: UUID, nodeID: UUID, seq: Int, generation: Int64) -> FleetSnapshot {
    FleetSnapshot(
        protocolVersion: FleetProtocol.version,
        hubUUID: hubID,
        generation: generation,
        hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub", timezoneID: "UTC", platform: "test"),
        generatedAt: Date(),
        nodes: [FleetNodeSnapshot(
            nodeID: nodeID,
            nodeName: "node",
            lastSeenAt: Date(),
            seq: seq,
            stale: false,
            dailyBuckets: [],
            windowUsage: [],
            quotas: [],
            attributionFingerprint: nil,
            dailyDigests: [:]
        )],
        fleet: FleetAggregate(dailyBuckets: [], windowUsage: []),
        electedQuotas: []
    )
}

/// Runtime lifecycle regressions use real loopback HTTP listeners and isolated stores.
@MainActor
final class FleetSyncLifecycleTests: XCTestCase {
    private actor AsyncGate {
        private var isOpen = false

        func waitUntilOpen(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !isOpen && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return isOpen
        }

        func open() {
            isOpen = true
        }
    }

    private var directory: URL!
    private var coordinators: [FleetSyncCoordinator] = []

    private final class SnapshotResponder: @unchecked Sendable {
        enum Mode: Equatable { case aligned, wrongSequence, postFailure, staleSequence }

        private let lock = NSLock()
        private let hubID: UUID
        private var mode: Mode = .aligned
        private var getGeneration: Int64 = 1
        private var postCount = 0
        private var getCount = 0

        init(hubID: UUID) { self.hubID = hubID }

        func setMode(_ mode: Mode) {
            lock.lock()
            self.mode = mode
            lock.unlock()
        }

        func setGetGeneration(_ generation: Int64) {
            lock.lock()
            getGeneration = generation
            lock.unlock()
        }

        func posts() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return postCount
        }

        func gets() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return getCount
        }

        func post(_ data: Data) -> HubServerResponse {
            lock.lock()
            defer { lock.unlock() }
            postCount += 1
            guard let report = try? FleetCodec.decode(NodeUsageReport.self, from: data) else {
                return .error(400, "Bad Request", "invalid report")
            }
            if case .postFailure = mode {
                return .error(500, "Internal Server Error", "trigger snapshot fallback")
            }
            if case .staleSequence = mode {
                let body = (try? FleetCodec.encode(FleetStaleSeqPayload(
                    error: "stale sequence", highWaterSeq: 7
                ))) ?? Data()
                return .json(409, "Conflict", body)
            }
            let ownSeq = mode == .wrongSequence ? report.seq - 1 : report.seq
            let generation: Int64 = mode == .aligned ? 100 : 1
            let snapshot = makeLifecycleSnapshot(hubID: hubID, nodeID: report.node.nodeID, seq: ownSeq, generation: generation)
            return .json(200, "OK", (try? FleetCodec.encode(snapshot)) ?? Data())
        }

        func get() -> HubServerResponse {
            lock.lock()
            getCount += 1
            let generation = getGeneration
            lock.unlock()
            let snapshot = makeLifecycleSnapshot(hubID: hubID, nodeID: UUID(), seq: 999, generation: generation)
            return .json(200, "OK", (try? FleetCodec.encode(snapshot)) ?? Data())
        }

    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        coordinators.forEach { $0.stop() }
        coordinators.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        name: String,
        store suppliedStore: FleetStore? = nil,
        deviceID: UUID? = nil,
        loadDeviceID: (() throws -> UUID)? = nil
    ) throws -> FleetSyncCoordinator {
        let store = try suppliedStore ?? FleetStore(url: directory.appendingPathComponent("\(name).sqlite"))
        let identityStore = DeviceIdentityStore(
            configDirectory: directory.appendingPathComponent("\(name)-identity", isDirectory: true)
        )
        let loader = loadDeviceID ?? {
            if let deviceID { return deviceID }
            return try identityStore.loadOrCreate()
        }
        let coordinator = FleetSyncCoordinator(store: store, loadDeviceID: loader)
        coordinators.append(coordinator)
        return coordinator
    }

    private func port() -> Int { Int.random(in: 49_152...65_000) }

    private func config(
        hubURL: String = "",
        port: Int = 8787,
        interval: Int = 1
    ) -> AppConfig {
        var value = AppConfig.default
        value.sync = SyncConfig(
            enabled: true,
            hubURL: hubURL,
            pushIntervalSeconds: interval,
            hubPort: port
        )
        return value
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), "condition did not become true", file: file, line: line)
    }

    private func startHub(_ coordinator: FleetSyncCoordinator, port: Int) async throws {
        coordinator.start(config: config(port: port), statuses: [])
        try await waitUntil { coordinator.listeningPort.map(Int.init) == port && coordinator.status.online }
    }

    func testNodePushesPeriodicallyWithoutLocalUpdatesAndStopClearsSnapshot() async throws {
        let hubPort = port()
        let hub = try makeCoordinator(name: "hub")
        try await startHub(hub, port: hubPort)
        let node = try makeCoordinator(name: "node")
        node.start(config: config(hubURL: "http://127.0.0.1:\(hubPort)"), statuses: [])

        try await waitUntil(timeout: 5) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq ?? 0) >= 1
        }
        let firstSeq = try XCTUnwrap(
            hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq
        )
        try await waitUntil(timeout: 4) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq ?? 0) > firstSeq
        }
        XCTAssertNotNil(node.latestSnapshot)
        node.stop()
        XCTAssertNil(node.latestSnapshot)
        XCTAssertNil(node.status.lastSyncAt)
    }

    func testSameUUIDHubDatabaseResetAcceptsConfirmedLowerGenerationAndBackfillsDailyBuckets() async throws {
        let hubPort = port()
        let hubID = UUID()
        let oldHubStore = try FleetStore(url: directory.appendingPathComponent("old-hub.sqlite"))
        let oldHub = try makeCoordinator(name: "old-hub", store: oldHubStore, deviceID: hubID)
        oldHub.start(config: config(port: hubPort), statuses: [])
        try await waitUntil { oldHub.status.online && oldHub.listeningPort.map(Int.init) == hubPort }
        for _ in 0..<500 { _ = try oldHubStore.bumpGeneration(scope: hubID.uuidString) }

        let nodeID = UUID()
        let nodeStore = try FleetStore(url: directory.appendingPathComponent("node.sqlite"))
        let node = try makeCoordinator(name: "node", store: nodeStore, deviceID: nodeID)
        let upstream = "http://127.0.0.1:\(hubPort)"
        node.start(config: config(hubURL: upstream, port: hubPort), statuses: [])
        try await waitUntil(timeout: 8) {
            node.status.online && (node.status.snapshotGeneration ?? 0) > 500
                && node.latestSnapshot?.nodes.first(where: { $0.nodeID == nodeID })?.dailyBuckets.count == 7
        }
        let scope = upstream + "|" + hubID.uuidString
        let oldGeneration = try XCTUnwrap(try nodeStore.cachedSnapshotGeneration(upstreamScope: scope))

        oldHub.stop()
        let replacementStore = try FleetStore(url: directory.appendingPathComponent("replacement-hub.sqlite"))
        let replacementHub = try makeCoordinator(name: "replacement-hub", store: replacementStore, deviceID: hubID)
        replacementHub.start(config: config(port: hubPort), statuses: [])
        try await waitUntil { replacementHub.status.online && replacementHub.listeningPort.map(Int.init) == hubPort }

        try await waitUntil(timeout: 6) {
            guard let acceptedGeneration = try? nodeStore.cachedSnapshotGeneration(upstreamScope: scope) else { return false }
            return acceptedGeneration < oldGeneration
        }
        try await waitUntil(timeout: 6) {
            replacementHub.latestSnapshot?.nodes.first(where: { $0.nodeID == nodeID })?.dailyBuckets.count == 7
        }
        XCTAssertLessThan(try replacementStore.generation(scope: hubID.uuidString), oldGeneration)
        XCTAssertTrue(node.status.online)
    }

    func testLowerGenerationWrongSequenceAndGETFallbackRemainRejected() async throws {
        let hubID = UUID()
        let hubPort = port()
        let responder = SnapshotResponder(hubID: hubID)
        let server = HubServer(handlers: HubServerHandlers(
            processReport: { data in responder.post(data) },
            currentSnapshot: { responder.get() },
            health: {
                let health = FleetHealth(ok: true, nodeID: hubID, protocolVersion: FleetProtocol.version)
                return .json(200, "OK", (try? FleetCodec.encode(health)) ?? Data())
            }
        ))
        try server.start(port: UInt16(hubPort), loopbackOnly: true)
        defer { server.stop() }
        try await waitUntil { server.boundPort.map(Int.init) == hubPort }

        let nodeID = UUID()
        let store = try FleetStore(url: directory.appendingPathComponent("gated-node.sqlite"))
        let node = try makeCoordinator(name: "gated-node", store: store, deviceID: nodeID)
        let upstream = "http://127.0.0.1:\(hubPort)"
        node.start(config: config(hubURL: upstream, port: hubPort), statuses: [])
        try await waitUntil(timeout: 6) { node.latestSnapshot?.generation == 100 }
        let scope = upstream + "|" + hubID.uuidString
        let baselinePosts = responder.posts()

        responder.setMode(.wrongSequence)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let wrongSequencePosts = responder.posts()
        XCTAssertGreaterThan(wrongSequencePosts, baselinePosts)
        XCTAssertEqual(node.latestSnapshot?.generation, 100, "a mismatched own.seq cannot authorize a generation rollback")
        XCTAssertEqual(try store.cachedSnapshotGeneration(upstreamScope: scope), 100)

        let beforeGet = responder.posts()
        responder.setMode(.postFailure)
        responder.setGetGeneration(100)
        let previousGets = responder.gets()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let fallbackPosts = responder.posts()
        XCTAssertGreaterThan(fallbackPosts, beforeGet)
        try await waitUntil(timeout: 3) { responder.gets() > previousGets && node.status.lastError != nil }
        XCTAssertEqual(node.latestSnapshot?.generation, 100, "GET fallback has no submitted-seq proof")
        XCTAssertEqual(try store.cachedSnapshotGeneration(upstreamScope: scope), 100)
        XCTAssertTrue(node.status.lastError?.contains("HTTP 500") == true,
                      "a same-generation GET must not hide the POST failure")
    }

    func testPOST500IsVisibleWhenGETFallbackFirstAcceptsSnapshot() async throws {
        let hubID = UUID()
        let hubPort = port()
        let responder = SnapshotResponder(hubID: hubID)
        responder.setMode(.postFailure)
        let server = HubServer(handlers: HubServerHandlers(
            processReport: { data in responder.post(data) },
            currentSnapshot: { responder.get() },
            health: {
                let health = FleetHealth(ok: true, nodeID: hubID, protocolVersion: FleetProtocol.version)
                return .json(200, "OK", (try? FleetCodec.encode(health)) ?? Data())
            }
        ))
        try server.start(port: UInt16(hubPort), loopbackOnly: true)
        defer { server.stop() }
        try await waitUntil { server.boundPort.map(Int.init) == hubPort }

        let node = try makeCoordinator(name: "http-500-node")
        node.start(config: config(hubURL: "http://127.0.0.1:\(hubPort)", port: hubPort), statuses: [])
        try await waitUntil(timeout: 6) { node.latestSnapshot?.generation == 1 && node.status.lastSyncAt != nil }

        XCTAssertTrue(node.status.online, "GET fallback still proves the HTTP link is reachable")
        XCTAssertTrue(node.status.lastError?.contains("HTTP 500") == true,
                      "accepting a fallback snapshot cannot turn a failed upload into success")
    }

    func test409SequenceRecoveryMessagePersistsUntilNextSuccessfulPOST() async throws {
        let hubID = UUID()
        let hubPort = port()
        let responder = SnapshotResponder(hubID: hubID)
        responder.setMode(.staleSequence)
        let server = HubServer(handlers: HubServerHandlers(
            processReport: { data in responder.post(data) },
            currentSnapshot: { responder.get() },
            health: {
                let health = FleetHealth(ok: true, nodeID: hubID, protocolVersion: FleetProtocol.version)
                return .json(200, "OK", (try? FleetCodec.encode(health)) ?? Data())
            }
        ))
        try server.start(port: UInt16(hubPort), loopbackOnly: true)
        defer { server.stop() }
        try await waitUntil { server.boundPort.map(Int.init) == hubPort }

        let node = try makeCoordinator(name: "http-409-node")
        node.start(config: config(hubURL: "http://127.0.0.1:\(hubPort)", port: hubPort), statuses: [])
        try await waitUntil(timeout: 6) {
            node.status.online && node.status.lastError?.contains("已重建本机序号") == true
        }
        let postsBeforeRecovery = responder.posts()

        responder.setMode(.aligned)
        try await waitUntil(timeout: 6) {
            responder.posts() > postsBeforeRecovery && node.status.lastError == nil
        }
    }

    func testLateSuccessfulFallbackFromOldHubCannotReplaceNewRuntime() async throws {
        let oldPort = port()
        let newPort = port()
        let oldHubID = UUID()
        let fallbackStarted = AsyncGate()
        let releaseFallback = AsyncGate()
        let oldServer = HubServer(handlers: HubServerHandlers(
            processReport: { _ in .error(500, "Internal Server Error", "old hub failure") },
            currentSnapshot: {
                await fallbackStarted.open()
                _ = await releaseFallback.waitUntilOpen(timeout: 5)
                let snapshot = makeLifecycleSnapshot(hubID: oldHubID, nodeID: UUID(), seq: 999, generation: 900)
                return .json(200, "OK", (try? FleetCodec.encode(snapshot)) ?? Data())
            },
            health: {
                let health = FleetHealth(ok: true, nodeID: oldHubID, protocolVersion: FleetProtocol.version)
                return .json(200, "OK", (try? FleetCodec.encode(health)) ?? Data())
            }
        ))
        try oldServer.start(port: UInt16(oldPort), loopbackOnly: true)
        defer { oldServer.stop() }
        try await waitUntil { oldServer.boundPort.map(Int.init) == oldPort }

        let newHub = try makeCoordinator(name: "late-response-new-hub")
        try await startHub(newHub, port: newPort)
        let node = try makeCoordinator(name: "late-response-node")
        var nodeConfig = config(hubURL: "http://127.0.0.1:\(oldPort)", interval: 60)
        node.start(config: nodeConfig, statuses: [])
        let fallbackDidStart = await fallbackStarted.waitUntilOpen(timeout: 5)
        XCTAssertTrue(fallbackDidStart)

        nodeConfig.sync?.hubURL = "http://127.0.0.1:\(newPort)"
        node.update(config: nodeConfig, statuses: [])
        await releaseFallback.open()
        try await waitUntil(timeout: 6) { node.latestSnapshot?.hubUUID == newHub.localNodeID && node.status.online }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(node.latestSnapshot?.hubUUID, newHub.localNodeID)
        XCTAssertNil(node.status.lastError, "a late success from the old upstream must be discarded before identity validation")
    }

    func testDeviceIdentityIsIndependentFromReadOnlyConfig() async throws {
        let configURL = directory.appendingPathComponent("identity-config.json")
        let configStore = ConfigStore(configURL: configURL)
        var initial = configStore.config
        let hubPort = port()
        initial.sync = SyncConfig(enabled: true, hubURL: "", hubPort: hubPort)
        try configStore.applyAndSave(initial)
        XCTAssertEqual(Darwin.chflags(configURL.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = Darwin.chflags(configURL.path, 0) }

        let state = AppState(descriptors: [], configStore: configStore)
        defer { state.stop() }
        state.start()
        let coordinator = try XCTUnwrap(state.fleetSync)
        try await waitUntil(timeout: 6) {
            coordinator.localNodeID != nil && coordinator.status.online
        }
        let deviceID = try XCTUnwrap(coordinator.localNodeID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".deviceId").path))
        let configText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(configText.contains(deviceID.uuidString), "设备 UUID 不应写入可同步 config.json")
        let identityAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(".deviceId").path
        )
        XCTAssertEqual((identityAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testOffStartupWithoutDeviceIdentityDoesNotProvisionOrReportError() throws {
        let coordinator = try makeCoordinator(name: "off-without-identity")
        var offConfig = config()
        offConfig.sync?.enabled = false

        coordinator.start(config: offConfig, statuses: [])

        XCTAssertEqual(coordinator.status.role, .off)
        XCTAssertNil(coordinator.localNodeID)
        XCTAssertNil(coordinator.status.lastError)
        XCTAssertNil(coordinator.listeningPort)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("off-without-identity-identity/.deviceId").path
        ), "off 启动不得创建设备身份")
    }

    func testDeviceIdentityLoadFailureStopsRuntimeAndSameConfigUpdateRetries() async throws {
        let hubPort = port()
        let store = try FleetStore(url: directory.appendingPathComponent("identity-switch-hub.sqlite"))
        var shouldFail = true
        let deviceID = UUID()
        let coordinator = FleetSyncCoordinator(store: store, loadDeviceID: {
            if shouldFail {
                throw NSError(domain: "IdentityReadFailure", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "device identity unavailable"])
            }
            return deviceID
        })
        coordinators.append(coordinator)
        let activeConfig = config(port: hubPort)
        coordinator.start(config: activeConfig, statuses: [])
        XCTAssertNil(coordinator.localNodeID)
        XCTAssertNil(coordinator.listeningPort)
        XCTAssertFalse(coordinator.status.online)
        XCTAssertTrue(coordinator.status.lastError?.contains("设备身份不可用") == true)

        shouldFail = false
        coordinator.update(config: activeConfig, statuses: [])
        try await waitUntil { coordinator.status.online && coordinator.listeningPort.map(Int.init) == hubPort }
        XCTAssertEqual(coordinator.localNodeID, deviceID)
    }

    func testNodeRecoversAfterHubStartsAtInitiallyUnavailableAddress() async throws {
        let hubPort = port()
        let node = try makeCoordinator(name: "node")
        node.start(config: config(hubURL: "http://127.0.0.1:\(hubPort)"), statuses: [])
        try await waitUntil(timeout: 5) { node.status.lastError != nil && !node.status.online }

        let hub = try makeCoordinator(name: "hub")
        try await startHub(hub, port: hubPort)
        try await waitUntil(timeout: 6) {
            node.status.online && hub.latestSnapshot?.nodes.contains { $0.nodeID == node.localNodeID } == true
        }
    }

    func testNodeRecoversAfterInvalidURLAndContinuesPeriodicPushes() async throws {
        let hubPort = port()
        let hub = try makeCoordinator(name: "invalid-url-hub")
        try await startHub(hub, port: hubPort)

        let nodeID = UUID()
        let node = try makeCoordinator(name: "invalid-url-node", deviceID: nodeID)
        var nodeConfig = config(hubURL: "::::", port: hubPort)
        node.start(config: nodeConfig, statuses: [])
        XCTAssertEqual(node.status.role, .node)
        XCTAssertNotNil(node.status.lastError)

        // 修正首次启动时的非法 URL；同角色、同身份也必须建立消费循环和 ticker。
        nodeConfig.sync?.hubURL = "http://127.0.0.1:\(hubPort)"
        node.update(config: nodeConfig, statuses: [])
        try await waitUntil(timeout: 6) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID }?.seq ?? 0) >= 1
                && node.status.online
        }
        let firstSeq = try XCTUnwrap(
            hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID }?.seq
        )
        try await waitUntil(timeout: 6) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID }?.seq ?? 0) > firstSeq
        }

        // 已运行时先切到非法 URL，再恢复；确保热更新仍复用 consumer 并能继续上报。
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let acceptedSeqBeforeSecondRecovery = try XCTUnwrap(
            hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID }?.seq
        )
        nodeConfig.sync?.hubURL = "::::"
        node.update(config: nodeConfig, statuses: [])
        XCTAssertFalse(node.status.online)
        XCTAssertNotNil(node.status.lastError)

        nodeConfig.sync?.hubURL = "http://127.0.0.1:\(hubPort)"
        node.update(config: nodeConfig, statuses: [])
        try await waitUntil(timeout: 6) {
            node.status.online
                && (hub.latestSnapshot?.nodes.first { $0.nodeID == nodeID }?.seq ?? 0)
                    > acceptedSeqBeforeSecondRecovery
        }

        nodeConfig.sync?.enabled = false
        node.update(config: nodeConfig, statuses: [])
        XCTAssertEqual(node.status.role, .off)
        XCTAssertNil(node.latestSnapshot)
        XCTAssertNil(node.status.lastSyncAt)
    }

    func testHubPortChangeRestartsListenerAndZeroIntervalTracksGlobalConfig() async throws {
        let hub = try makeCoordinator(name: "hub")
        let firstPort = port()
        let initial = config(port: firstPort)
        hub.start(config: initial, statuses: [])
        try await waitUntil { hub.listeningPort.map(Int.init) == firstPort && hub.status.online }
        let secondPort = port()
        var changed = config(port: secondPort, interval: 0)
        changed.refreshIntervalSeconds = 15
        hub.update(config: changed, statuses: [])
        try await waitUntil { hub.listeningPort.map(Int.init) == secondPort && hub.status.online }

        let node = try makeCoordinator(name: "node")
        var followsGlobal = config(hubURL: "http://127.0.0.1:\(secondPort)", interval: 0)
        followsGlobal.refreshIntervalSeconds = 13
        node.start(config: followsGlobal, statuses: [])
        XCTAssertEqual(followsGlobal.effectiveFleetSyncPushInterval, 13)

        followsGlobal.refreshIntervalSeconds = 21
        node.update(config: followsGlobal, statuses: [])
        XCTAssertEqual(followsGlobal.effectiveFleetSyncPushInterval, 21)
        try await waitUntil { node.status.online }
    }

    func testGlobalIntervalHotUpdateReschedulesPeriodicNodePushes() async throws {
        let hubPort = port()
        let hub = try makeCoordinator(name: "hot-interval-hub")
        try await startHub(hub, port: hubPort)
        let node = try makeCoordinator(name: "hot-interval-node")
        var nodeConfig = config(hubURL: "http://127.0.0.1:\(hubPort)", interval: 0)
        nodeConfig.refreshIntervalSeconds = 30
        node.start(config: nodeConfig, statuses: [])

        try await waitUntil(timeout: 5) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq ?? 0) >= 1
        }
        let firstSeq = try XCTUnwrap(
            hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq
        )
        // hub 对同一 nodeID 限制 1s 请求间隔；让配置触发的即时推送不会被429吞掉。
        try await Task.sleep(nanoseconds: 1_100_000_000)
        nodeConfig.refreshIntervalSeconds = 10 // effectiveGlobalRefreshInterval 的最小值
        node.update(config: nodeConfig, statuses: [])

        try await waitUntil(timeout: 5) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq ?? 0) > firstSeq
        }
        let afterUpdateSeq = try XCTUnwrap(
            hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq
        )
        try await waitUntil(timeout: 12) {
            (hub.latestSnapshot?.nodes.first { $0.nodeID == node.localNodeID }?.seq ?? 0) > afterUpdateSeq
        }
    }

    func testConfigChangesPreserveDeviceIdentityAndDisablingClearsSnapshot() async throws {
        let hubPort = port()
        let hub = try makeCoordinator(name: "identity-hub")
        try await startHub(hub, port: hubPort)
        let node = try makeCoordinator(name: "identity-node")
        var nodeConfig = config(hubURL: "http://127.0.0.1:\(hubPort)")
        node.start(config: nodeConfig, statuses: [])
        try await waitUntil(timeout: 5) {
            node.localNodeID != nil && hub.latestSnapshot?.nodes.contains { $0.nodeID == node.localNodeID } == true
        }
        let stableID = try XCTUnwrap(node.localNodeID)

        nodeConfig.sync?.nodeName = "renamed"
        node.update(config: nodeConfig, statuses: [])
        try await waitUntil(timeout: 5) {
            node.localNodeID == stableID
                && hub.latestSnapshot?.nodes.contains { $0.nodeID == stableID } == true
        }

        var disabled = nodeConfig
        disabled.sync?.enabled = false
        node.update(config: disabled, statuses: [])
        XCTAssertNil(node.latestSnapshot)
        XCTAssertNil(node.status.lastSyncAt)
        XCTAssertEqual(node.localNodeID, stableID, "关闭联动不应改变本机身份")
    }

    func testOldUpstreamFallbackFailureCannotOverwriteNewRuntime() async throws {
        let oldPort = port()
        let newPort = port()
        let oldHubID = UUID()
        let fallbackStarted = AsyncGate()
        let releaseFallback = AsyncGate()
        let oldHub = HubServer(handlers: HubServerHandlers(
            processReport: { _ in .error(500, "Internal Server Error", "old upstream failure") },
            currentSnapshot: {
                await fallbackStarted.open()
                let released = await releaseFallback.waitUntilOpen(timeout: 5)
                return .error(500, "Internal Server Error", released ? "old fallback failure" : "fallback gate timeout")
            },
            health: {
                let health = FleetHealth(ok: true, nodeID: oldHubID, protocolVersion: FleetProtocol.version)
                return .json(200, "OK", (try? FleetCodec.encode(health)) ?? Data())
            }
        ))
        try oldHub.start(port: UInt16(oldPort), loopbackOnly: true)
        defer { oldHub.stop() }
        try await waitUntil { oldHub.boundPort.map(Int.init) == oldPort }

        let newHub = try makeCoordinator(name: "new-upstream-hub")
        try await startHub(newHub, port: newPort)
        let node = try makeCoordinator(name: "switching-node")
        var nodeConfig = config(hubURL: "http://127.0.0.1:\(oldPort)")
        node.start(config: nodeConfig, statuses: [])
        let fallbackDidStart = await fallbackStarted.waitUntilOpen(timeout: 5)
        XCTAssertTrue(fallbackDidStart, "旧上游fallback GET应启动")

        nodeConfig.sync?.hubURL = "http://127.0.0.1:\(newPort)"
        node.update(config: nodeConfig, statuses: [])
        await releaseFallback.open()
        try await waitUntil(timeout: 8) {
            node.status.online && node.latestSnapshot?.hubUUID == newHub.localNodeID
        }
        XCTAssertNil(node.status.lastError, "旧上游 POST 与 fallback 的失败不得覆盖新 runtime")
    }

    func testPushIntervalZeroSurvivesDecodeEncode() throws {
        XCTAssertEqual(SyncConfig.default.pushIntervalSeconds, 0)

        let missingInterval = Data(#"{"enabled":true}"#.utf8)
        XCTAssertEqual(try FleetCodec.decode(SyncConfig.self, from: missingInterval).pushIntervalSeconds, 0)

        for invalid in [
            #"{"pushIntervalSeconds":"60"}"#,
            #"{"pushIntervalSeconds":86401}"#
        ] {
            XCTAssertEqual(
                try FleetCodec.decode(SyncConfig.self, from: Data(invalid.utf8)).pushIntervalSeconds,
                0,
                "缺失类型或越界值应回退到跟随全局刷新"
            )
        }

        let explicitSixty = Data(#"{"pushIntervalSeconds":60}"#.utf8)
        XCTAssertEqual(try FleetCodec.decode(SyncConfig.self, from: explicitSixty).pushIntervalSeconds, 60)

        let data = Data(#"{"enabled":true,"hubURL":"http://127.0.0.1:12345","pushIntervalSeconds":0}"#.utf8)
        let decoded = try FleetCodec.decode(SyncConfig.self, from: data)
        XCTAssertEqual(decoded.pushIntervalSeconds, 0)
        let roundTrip = try FleetCodec.decode(SyncConfig.self, from: FleetCodec.encode(decoded))
        XCTAssertEqual(roundTrip.pushIntervalSeconds, 0)
    }

    func testListenerFailureSetsOfflineError() async throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "fixture socket should be created")
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY.bigEndian))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "fixture should bind an ephemeral TCP port")
        XCTAssertEqual(Darwin.listen(descriptor, SOMAXCONN), 0, "fixture should listen")
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let portResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            withUnsafeMutablePointer(to: &addressLength) { lengthPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, lengthPointer)
                }
            }
        }
        XCTAssertEqual(portResult, 0)
        let occupiedPort = Int(UInt16(bigEndian: address.sin_port))

        let hub = try makeCoordinator(name: "conflicted-hub")
        hub.start(config: config(port: occupiedPort), statuses: [])
        try await waitUntil(timeout: 3) { !hub.status.online && hub.status.lastError != nil }
    }

    func testContentTypeRequiresExactJSONMediaTypeAndAllowsCharset() async throws {
        let hubPort = port()
        let hub = try makeCoordinator(name: "content-type-hub")
        try await startHub(hub, port: hubPort)
        let endpoint = URL(string: "http://127.0.0.1:\(hubPort)\(FleetProtocol.usageDayPath)")!

        var invalid = URLRequest(url: endpoint)
        invalid.httpMethod = "POST"
        invalid.httpBody = Data("{}".utf8)
        invalid.setValue("application/jsonp", forHTTPHeaderField: "Content-Type")
        let (invalidBody, invalidResponse) = try await URLSession.shared.data(for: invalid)
        let invalidStatus = try XCTUnwrap((invalidResponse as? HTTPURLResponse)?.statusCode)
        XCTAssertEqual(invalidStatus, 415)
        XCTAssertFalse(invalidBody.isEmpty)

        var withCharset = URLRequest(url: endpoint)
        withCharset.httpMethod = "POST"
        withCharset.httpBody = Data("{}".utf8)
        withCharset.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (_, charsetResponse) = try await URLSession.shared.data(for: withCharset)
        let charsetStatus = try XCTUnwrap((charsetResponse as? HTTPURLResponse)?.statusCode)
        XCTAssertNotEqual(charsetStatus, 415, "application/json with charset must reach report validation")
    }
}
