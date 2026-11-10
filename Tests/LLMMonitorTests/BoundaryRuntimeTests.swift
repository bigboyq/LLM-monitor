import XCTest
@testable import LLM_monitor

final class BoundaryRuntimeTests: StateTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("llm-monitor-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testStopFlushCannotBeOverwrittenByAlreadyWritingOlderBaseline() async throws {
        let configURL = try directory().appendingPathComponent("config.json")
        let writeLock = BoundaryObservedWriteLock()
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let io = BoundaryBaselineIO(entered: firstWriteEntered, release: releaseFirstWrite)
        let store = TriggerStateStore(configURL: configURL, writeFile: { data, url in
            try io.write(data, to: url)
        }, writeLock: writeLock)

        store.update(providerID: "old", info: QuotaInfo(models: [], resetCredits: nil, planLabel: nil,
                                                       accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date()))
        let entered = await Task.detached { boundaryWait(firstWriteEntered) }.value
        XCTAssertEqual(entered, .success)
        guard entered == .success else { releaseFirstWrite.signal(); return }
        store.reset(providerID: "old")

        // Release real synchronous I/O only when flush reaches the shared write
        // gate. No actor hop is inserted into the production write boundary.
        let release = Task.detached {
            let attempted = boundaryWait(writeLock.secondAttempt)
            releaseFirstWrite.signal()
            return attempted
        }
        store.flushSynchronously()
        let attempted = await release.value
        XCTAssertEqual(attempted, .success)
        await store.waitForPendingWrites()
        XCTAssertNil(TriggerStateStore(configURL: configURL).snapshot(for: "old"),
                     "The in-flight pre-reset baseline must never undo the stop flush")
    }

    @MainActor
    func testFailedSynchronousFlushCanRetryTheSameSequence() throws {
        let configURL = try directory().appendingPathComponent("config.json")
        let io = BoundaryBaselineIO(failFirst: true)
        let store = TriggerStateStore(configURL: configURL, writeFile: { data, url in
            try io.write(data, to: url)
        })
        store.update(providerID: "latest", info: QuotaInfo(models: [], resetCredits: nil, planLabel: nil,
                                                          accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date()))
        // No suspension: the async writer has not started on this actor yet.
        store.flushSynchronously()
        store.flushSynchronously()
        XCTAssertNotNil(TriggerStateStore(configURL: configURL).snapshot(for: "latest"),
                        "An unsuccessful write must not consume the sequence high-water")
    }

    @MainActor
    func testVerifiedSameGenerationGETEstablishesRestartedNodeMemoryWithoutRewritingCache() async throws {
        let hubID = UUID()
        let snapshot = boundarySnapshot(hubID: hubID, generation: 100)
        let response = try FleetCodec.encode(snapshot)
        let health = try FleetCodec.encode(FleetHealth(ok: true, nodeID: hubID, protocolVersion: FleetProtocol.version))
        let server = HubServer(handlers: HubServerHandlers(
            processReport: { _ in .json(500, "Error", Data()) },
            currentSnapshot: { .json(200, "OK", response) },
            health: { .json(200, "OK", health) }
        ))
        try server.start(port: 0, loopbackOnly: true)
        defer { server.stop() }
        let listening = await waitUntil { server.boundPort != nil }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(server.boundPort)
        let upstream = "http://127.0.0.1:\(port)"
        let scope = upstream + "|" + hubID.uuidString
        let store = try FleetStore(url: directory().appendingPathComponent("fleet.sqlite"))
        let persisted = boundarySnapshot(hubID: hubID, generation: 100, generatedAt: Date(timeIntervalSince1970: 123))
        try store.saveSnapshot(persisted, upstreamScope: scope)
        let coordinator = FleetSyncCoordinator(store: store, loadDeviceID: { UUID() })
        defer { coordinator.stop() }
        var config = AppConfig.default
        config.sync = SyncConfig(enabled: true, hubURL: upstream, pushIntervalSeconds: 60)
        coordinator.start(config: config, statuses: [])
        let published = await waitUntil { coordinator.latestSnapshot?.generation == 100 }
        XCTAssertTrue(published, "A current verified GET can fill the empty in-memory baseline after restart")
        XCTAssertTrue(coordinator.status.online)
        XCTAssertTrue(coordinator.status.lastError?.contains("HTTP 500") == true)
        XCTAssertEqual(try store.loadSnapshot(upstreamScope: scope), persisted,
                       "Same-generation hydration must not rewrite the persistent cache")
    }

    func testBarkTransportCancellationBeforeCompletionHasNoSuccessfulReceipt() async {
        let state = CappedDownloadState()
        do {
            let _: (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(state.setContinuation(continuation))
                state.cancel()
                boundaryCompleteSuccessfulDownload(state)
            }
            XCTFail("Cancellation wins before any successful receipt is completed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBarkTransportSuccessfulReceiptSurvivesLaterCancellationBeforeConsumerResumes() async throws {
        let state = CappedDownloadState()
        let (_, response): (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(state.setContinuation(continuation))
            boundaryCompleteSuccessfulDownload(state)
            // The consuming Bark actor has not resumed from await yet. Cancelling
            // here cannot retract the already confirmed HTTP 2xx delivery.
            state.cancel()
        }
        XCTAssertEqual(response.statusCode, 200)
    }

    @MainActor
    func testCancelledCodexLoaderCannotClearReplacementScanningOwner() async throws {
        let oldGate = TestAsyncGate()
        let newGate = TestAsyncGate()
        let (localUsage, writer) = try codexPipeline(gates: [oldGate, newGate])
        defer { localUsage.cancelInFlightAll() }
        let oldPass = Task { await localUsage.reconcile() }
        await oldGate.waitUntilReached()
        XCTAssertTrue(writer.isScanning)

        localUsage.cancelInFlightAll()
        XCTAssertFalse(writer.isScanning, "Cancellation must clear the old owner's scanning state immediately")
        writer.generation += 1
        let newPass = Task { await localUsage.reconcile() }
        await newGate.waitUntilReached()
        XCTAssertTrue(writer.isScanning)

        // The original async dependency ignores cancellation until its I/O has
        // finished. Its defer now runs while the replacement is still waiting.
        await oldGate.release()
        await oldPass.value
        XCTAssertTrue(writer.isScanning, "The old loader's defer cannot clear the replacement owner")
        XCTAssertEqual(writer.scanningTransitions, [true, false, true])
        XCTAssertNil(writer.details)
        XCTAssertTrue(writer.freshness.isAwaitingInitialScan(.codex))

        await newGate.release()
        await newPass.value
        XCTAssertFalse(writer.isScanning)
        XCTAssertEqual(writer.scanningTransitions, [true, false, true, false])
        XCTAssertEqual(writer.details?.scannedAt, Date(timeIntervalSince1970: 2))
        XCTAssertFalse(writer.freshness.isAwaitingInitialScan(.codex))
    }

    @MainActor
    func testCancelledCodexLoaderWithoutReplacementClearsScanningImmediately() async throws {
        let gate = TestAsyncGate()
        let (localUsage, writer) = try codexPipeline(gates: [gate])
        defer { localUsage.cancelInFlightAll() }
        let pass = Task { await localUsage.reconcile() }
        await gate.waitUntilReached()
        XCTAssertTrue(writer.isScanning)

        localUsage.cancelInFlightAll()
        XCTAssertFalse(writer.isScanning, "Stop cannot leave scanning set while cancelled I/O is still settling")
        await gate.release()
        await pass.value
        XCTAssertEqual(writer.scanningTransitions, [true, false])
        XCTAssertNil(writer.details)
        XCTAssertTrue(writer.freshness.isAwaitingInitialScan(.codex))
    }

    @MainActor
    func testCodexLoaderFromOldConfigurationCannotInitializeCurrentSource() async throws {
        let gate = TestAsyncGate()
        let (localUsage, writer) = try codexPipeline(gates: [gate])
        defer { localUsage.cancelInFlightAll() }
        let pass = Task { await localUsage.reconcile() }
        await gate.waitUntilReached()
        writer.generation += 1
        await gate.release()
        await pass.value
        XCTAssertFalse(writer.isScanning)
        XCTAssertNil(writer.details)
        XCTAssertTrue(writer.freshness.isAwaitingInitialScan(.codex))
        XCTAssertEqual(writer.freshness, .uninitialized)
    }

    @MainActor
    private func codexPipeline(gates: [TestAsyncGate]) throws -> (LocalUsageOrchestration, BoundaryCodexWriter) {
        let writer = BoundaryCodexWriter(authPath: try directory().appendingPathComponent("auth.json").path)
        let loader = BoundaryCodexLoader(gates: gates)
        let localUsage = LocalUsageOrchestration(writer: writer, loadCodexUsageDetails: { _, _, _ in
            await loader.load()
        })
        localUsage.updateActiveSources(.init(codex: true, antigravity: false, minimax: false,
                                             glm: false, dsh: false, opencode: false, agy: false))
        localUsage.testReadinessOverride = { $0 == "codex" }
        return (localUsage, writer)
    }
}

private actor BoundaryCodexLoader {
    private let gates: [TestAsyncGate]
    private var calls = 0

    init(gates: [TestAsyncGate]) { self.gates = gates }

    func load() async -> CodexUsageDetails? {
        let call = calls
        calls += 1
        guard call < gates.count else { return nil }
        await gates[call].hold()
        return CodexUsageDetails(primary: nil, secondary: nil, dailyTokenUsage: [],
                                 scannedAt: Date(timeIntervalSince1970: Double(call + 1)))
    }
}

@MainActor
private final class BoundaryCodexWriter: LocalUsageStatusWriting {
    let authPath: String
    var generation = 1
    var isScanning = false
    var scanningTransitions: [Bool] = []
    var details: CodexUsageDetails?
    var freshness = LocalUsageFreshnessSnapshot.uninitialized

    init(authPath: String) { self.authPath = authPath }
    func providerID(for kind: ProviderKind) -> String? { kind == .codexChatGpt ? "boundary-codex" : nil }
    func setScanningState(_ isScanning: Bool, for providerID: String) {
        self.isScanning = isScanning
        scanningTransitions.append(isScanning)
    }
    func setLocalUsageFreshness(_ value: LocalUsageFreshness, for source: LocalUsageSource) { freshness[source] = value }
    func markLocalUsageSourceInitialized(_ source: LocalUsageSource) { freshness.completeInitialScan(for: source) }
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {}
    func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?) {}
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {}
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {}
    func applyDshUsage(_ usage: DshLocalUsage?) {}
    func applyAgyUsage(_ usage: AgyLocalUsage?) {}
    func codexConfiguredAuthPath() -> String? { authPath }
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? {
        ("boundary-codex", authPath, nil, .distantPast, generation)
    }
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int) -> Bool {
        guard configurationGeneration == generation else { return false }
        self.details = details
        return true
    }
}

/// The second lock attempt is the synchronous flush while the first writer is
/// inside I/O. Observing acquisition, rather than sleeping, fixes the ordering.
private final class BoundaryObservedWriteLock: NSLock, @unchecked Sendable {
    let secondAttempt = DispatchSemaphore(value: 0)
    private let countLock = NSLock()
    private var attempts = 0

    override func lock() {
        countLock.lock()
        attempts += 1
        let isSecond = attempts == 2
        countLock.unlock()
        if isSecond { secondAttempt.signal() }
        super.lock()
    }
}

private final class BoundaryBaselineIO: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private let entered: DispatchSemaphore?
    private let release: DispatchSemaphore?
    private let failFirst: Bool

    init(entered: DispatchSemaphore? = nil, release: DispatchSemaphore? = nil, failFirst: Bool = false) {
        self.entered = entered
        self.release = release
        self.failFirst = failFirst
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        writes += 1
        let first = writes == 1
        lock.unlock()
        if first {
            entered?.signal()
            if let release, release.wait(timeout: .now() + 5) != .success {
                throw URLError(.timedOut)
            }
            if failFirst { throw CocoaError(.fileWriteNoPermission) }
        }
        try FileManagerBox().writePrivate(data, to: url)
    }
}

private func boundarySnapshot(hubID: UUID, generation: Int64, generatedAt: Date = Date()) -> FleetSnapshot {
    FleetSnapshot(protocolVersion: FleetProtocol.version, hubUUID: hubID, generation: generation,
                  hub: FleetNodeIdentity(nodeID: hubID, nodeName: "hub", timezoneID: "UTC", platform: "test"),
                  generatedAt: generatedAt, nodes: [], fleet: FleetAggregate(dailyBuckets: [], windowUsage: []), electedQuotas: [])
}

private func boundaryCompleteSuccessfulDownload(_ state: CappedDownloadState) {
    state.complete(declaredTooLarge: false, declaredContentLength: 0, overflowed: false,
                   receivedBytes: 0, maxBytes: BarkQuotaNotifier.responseByteLimit,
                   redactedPath: "bark://fixture/<redacted>",
                   response: HTTPURLResponse(url: URL(string: "https://fixture.invalid/key")!,
                                             statusCode: 200, httpVersion: nil, headerFields: nil),
                   accumulatedData: Data(), error: nil)
}

private func boundaryWait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 5)
}
