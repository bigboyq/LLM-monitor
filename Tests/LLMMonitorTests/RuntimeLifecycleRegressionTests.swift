import XCTest
import Combine
@testable import LLM_monitor

final class RuntimeLifecycleRegressionTests: StateTestCase {
    @MainActor
    func testAppStateInitialAndReenabledSourcesRequireVerification() async throws {
        let store = makeIsolatedConfigStore()
        let providerID = ProviderKind.minimaxTokenPlan.providerID
        var config = store.config
        config.providers = [providerID: ProviderConfig(enabled: true, apiKey: "audit-key")]
        try store.applyAndSave(config)
        let descriptor = FetcherDescriptor(id: providerID, displayName: "Audit", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            makeFetcher: { _ in TestQuotaFetcher(providerID: providerID, displayName: "Audit", kind: .minimaxTokenPlan) })
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }
        state.localUsage.testReconcilePass = { _ in }
        XCTAssertTrue(state.statuses[0].localUsageFreshness.isAwaitingInitialScan(.minimaxCode))
        state.setLocalUsageFreshness(.clean, for: .minimaxCode)
        XCTAssertFalse(state.statuses[0].localUsageFreshness.isAwaitingInitialScan(.minimaxCode))
        state.rebuildStatuses()
        XCTAssertFalse(state.statuses[0].localUsageFreshness.isAwaitingInitialScan(.minimaxCode),
                       "Unrelated rebuilds must preserve a verified source")
        config.providers[providerID]?.enabled = false
        try store.applyAndSave(config)
        let disabled = await waitUntil { !state.statuses[0].isEnabled }
        XCTAssertTrue(disabled)
        config.providers[providerID]?.enabled = true
        try store.applyAndSave(config)
        let enabled = await waitUntil { state.statuses[0].isEnabled }
        XCTAssertTrue(enabled)
        XCTAssertTrue(state.statuses[0].localUsageFreshness.isAwaitingInitialScan(.minimaxCode))
    }

    @MainActor
    func testRemovingAllStartupProvidersStillRunsOneEmptyReconcile() async throws {
        let store = makeIsolatedConfigStore()
        let fetcher = BlockingRefreshFetcher()
        let providerID = "startup-disabled"
        var config = store.config
        config.providers = [providerID: ProviderConfig(enabled: true, apiKey: "audit-key")]
        try store.applyAndSave(config)
        let descriptor = FetcherDescriptor(id: providerID, displayName: "Audit", kind: .minimaxTokenPlan,
                                           iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }
        var passes = 0
        state.localUsage.testReconcilePass = { _ in passes += 1 }
        await fetcher.gate.waitUntilReached()
        config.providers[providerID]?.enabled = false
        try store.applyAndSave(config)
        let disabled = await waitUntil { state.statuses.first?.isEnabled == false }
        XCTAssertTrue(disabled)
        await fetcher.gate.release()
        let reconciled = await waitUntil { passes == 1 && !state.isRefreshJobActive }
        XCTAssertTrue(reconciled, "The last removed provider must not leave an orphaned startup barrier")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 1)
    }

    @MainActor
    func testMissingSourceIsVerifiedZeroAndIsCheckedAgainAfterReenable() async {
        let writer = InitialScanWriter()
        let localUsage = LocalUsageOrchestration(writer: writer)
        defer { localUsage.cancelInFlightAll() }
        var active = LocalUsageOrchestration.ActiveSources(codex: false, antigravity: false,
            minimax: true, glm: false, dsh: false, opencode: false, agy: false)
        localUsage.updateActiveSources(active)
        localUsage.testReadinessOverride = { _ in false }
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.minimaxClears, 1)
        XCTAssertFalse(writer.freshness.isAwaitingInitialScan(.minimaxCode))
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.minimaxClears, 1)
        active.minimax = false
        localUsage.updateActiveSources(active)
        active.minimax = true
        writer.freshness.requireInitialScan(for: .minimaxCode)
        localUsage.updateActiveSources(active)
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.minimaxClears, 2)
        XCTAssertFalse(writer.freshness.isAwaitingInitialScan(.minimaxCode))
    }

    @MainActor
    func testInaccessibleSourcesRecoverToVerifiedMissingWithoutReadinessFlip() async {
        let writer = InitialScanWriter()
        let localUsage = LocalUsageOrchestration(writer: writer)
        defer { localUsage.cancelInFlightAll() }
        localUsage.updateActiveSources(.init(codex: true, antigravity: false,
            minimax: true, glm: false, dsh: false, opencode: false, agy: false))
        localUsage.testReadinessOverride = { _ in false }
        var explicitlyMissing = false
        localUsage.testSourceMissingOverride = { _ in explicitlyMissing }
        await localUsage.scanAllClients()
        for source in [LocalUsageSource.codex, .minimaxCode] {
            XCTAssertEqual(writer.freshness[source], .failed)
            XCTAssertTrue(writer.freshness.isAwaitingInitialScan(source))
        }
        explicitlyMissing = true
        await localUsage.scanAllClients()
        for source in [LocalUsageSource.codex, .minimaxCode] {
            XCTAssertEqual(writer.freshness[source], .clean)
            XCTAssertFalse(writer.freshness.isAwaitingInitialScan(source))
            XCTAssertEqual(writer.freshnessCalls[source], 2)
        }
        XCTAssertEqual(writer.minimaxClears, 1)
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.minimaxClears, 1, "Stable confirmed absence must not repeatedly clear/publish")
        XCTAssertEqual(writer.freshnessCalls[.codex], 2)
        XCTAssertEqual(writer.freshnessCalls[.minimaxCode], 2)
        explicitlyMissing = false
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.freshness[.codex], .failed)
        explicitlyMissing = true
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.freshness[.codex], .clean)
        XCTAssertEqual(writer.minimaxClears, 2, "A new uncertainty/absence transition must be checked and applied again")
    }

    @MainActor
    func testFailedInitialScanRemainsUnavailableUntilSuccessfulZeroScan() async {
        let writer = InitialScanWriter()
        let scanner = InitialScanScanner()
        let localUsage = LocalUsageOrchestration(writer: writer)
        defer { localUsage.cancelInFlightAll() }
        localUsage.updateActiveSources(.init(codex: false, antigravity: true,
            minimax: false, glm: false, dsh: false, opencode: false, agy: false))
        localUsage.testReadinessOverride = { $0 == "antigravity" }
        localUsage.testAntigravityScannerFactory = { scanner }
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.freshness[.antigravity], .failed)
        XCTAssertTrue(writer.freshness.isAwaitingInitialScan(.antigravity))
        scanner.shouldFail = false
        await localUsage.scanAllClients()
        XCTAssertEqual(writer.freshness[.antigravity], .clean)
        XCTAssertFalse(writer.freshness.isAwaitingInitialScan(.antigravity))
    }

    @MainActor
    func testCompleteInitialScanCanRemainDirtyWithoutRemainingUninitialized() async {
        let writer = InitialScanWriter()
        let scanner = InitialScanScanner()
        scanner.shouldFail = false
        let gate = TestAsyncGate()
        scanner.gate = gate
        let localUsage = LocalUsageOrchestration(writer: writer)
        defer { localUsage.cancelInFlightAll() }
        localUsage.updateActiveSources(.init(codex: false, antigravity: true,
            minimax: false, glm: false, dsh: false, opencode: false, agy: false))
        localUsage.testReadinessOverride = { $0 == "antigravity" }
        localUsage.testAntigravityScannerFactory = { scanner }
        let pass = Task { await localUsage.scanAllClients() }
        await gate.waitUntilReached()
        scanner.markDirty()
        await gate.release()
        await pass.value
        XCTAssertEqual(writer.freshness[.antigravity], .dirty)
        XCTAssertFalse(writer.freshness.isAwaitingInitialScan(.antigravity))
        XCTAssertFalse(writer.initializedBeforeResult, "The result must reach its consumer before initialization is published")
    }

    @MainActor
    func testColdQuotaFailureWithSuccessfulCodexScanPreservesFleetLastGood() async throws {
        let configStore = makeIsolatedConfigStore()
        let home = configStore.configURL.deletingLastPathComponent().appendingPathComponent("codex", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5))
        let jsonl = """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"audit-turn"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":123,"cached_input_tokens":0,"output_tokens":7,"reasoning_output_tokens":0}}}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"audit-turn"}}

        """
        try Data(jsonl.utf8).write(to: sessions.appendingPathComponent("audit.jsonl"))
        let authPath = home.appendingPathComponent("auth.json").path
        let details = await CodexFetcher.loadUsageDetailsAsync(authPath: authPath, model: nil)
        XCTAssertEqual(details?.recentSamples?.count, 1, "The real local scanner must succeed before testing admission")
        let providerID = ProviderKind.codexChatGpt.providerID
        var config = configStore.config
        config.providers = [providerID: ProviderConfig(enabled: true, authPath: authPath)]
        try configStore.applyAndSave(config)
        let fetcher = ErrorThrowingFetcher(providerID: providerID, kind: .codexChatGpt, errorToThrow: URLError(.notConnectedToInternet))
        let descriptor = FetcherDescriptor(id: providerID, displayName: "Codex", kind: .codexChatGpt,
            iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        let state = AppState(descriptors: [descriptor], configStore: configStore)
        defer { state.stop() }
        state.localUsage.testReadinessOverride = { $0 == "codex" }
        let settled = await waitUntil {
            if case .failed = state.statuses[0].state { return !state.isRefreshJobActive }
            return false
        }
        XCTAssertTrue(settled)
        XCTAssertNil(state.statuses[0].lastSuccess, "The existing cold-quota display contract is unchanged")
        XCTAssertTrue(state.statuses[0].localUsageFreshness.isAwaitingInitialScan(.codex))

        let fleet = try FleetStore(url: configStore.configURL.deletingLastPathComponent().appendingPathComponent("audit-fleet.sqlite"))
        let identity = UUID()
        let row = FleetClientProviderUsage(clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
            input: 999, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1)
        let bucket = FleetDailyBucket(dayKey: FleetMerger.dayKey(of: now), totals: FleetTotals(summing: [row]),
            clientProviders: [row], entries: [], totalsComplete: true, modelDetailsComplete: false, sourceTruncated: false)
        let old = NodeUsageReport(protocolVersion: FleetProtocol.version,
            node: .init(nodeID: identity, nodeName: "Audit", timezoneID: "UTC", platform: "macOS"),
            seq: 1, generatedAt: now, attributionFingerprint: "audit", dailyBuckets: [bucket], windowUsage: nil, quotas: nil)
        try fleet.applyReport(old, validation: FleetReportValidator.validate(old), scope: "audit")
        let report = UsageReportBuilder.build(.init(nodeID: identity, nodeName: "Audit",
            bindings: ClientProviderBinding.defaultBindings, statuses: state.statuses, now: now), seq: 2)
        try fleet.applyReport(report, validation: FleetReportValidator.validate(report), scope: "audit")
        let saved = try XCTUnwrap(fleet.loadHubState(scope: "audit").nodes.first?.report.dailyBuckets?.first { $0.dayKey == bucket.dayKey })
        XCTAssertEqual(saved.totals.input, 999)
    }

    @MainActor
    func testUnrelatedConfigReloadMustNotLeaveFinishedRequestLoading() async throws {
        let store = makeIsolatedConfigStore()
        let fetcher = BlockingRefreshFetcher()
        let providerID = "audit-loading"
        var config = store.config
        config.providers = [providerID: ProviderConfig(enabled: true, apiKey: "audit-key")]
        try store.applyAndSave(config)
        let descriptor = FetcherDescriptor(id: providerID, displayName: "Audit", kind: .minimaxTokenPlan,
                                           iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }
        state.localUsage.testReconcilePass = { _ in }
        let previous = QuotaInfo(models: [], resetCredits: nil, planLabel: "Previous", accountEmail: nil,
                                 codexUsageDetails: nil, fetchedAt: Date())
        state.mutateStatus(for: providerID) { $0.state = .ok(previous) }
        await fetcher.gate.waitUntilReached()
        XCTAssertTrue(state.isRefreshing)
        // A settings save/dock position write republishes config without changing auth.
        try store.applyAndSave(config)
        try await Task.sleep(for: .milliseconds(100))
        await fetcher.gate.release()
        let settled = await waitUntil { !state.isRefreshJobActive }
        XCTAssertTrue(settled)
        XCTAssertFalse(state.isRefreshing, "The stale completion must restore cached quota state, not retain a spinner until the next interval")
        XCTAssertEqual(state.statuses.first?.lastSuccess?.planLabel, "Previous")
    }

    @MainActor
    func testDisablingStartupPendingProviderMustNotStarveLocalReconcile() async throws {
        let store = makeIsolatedConfigStore()
        let first = BlockingRefreshFetcher()
        let firstID = "audit-first"
        let secondID = "audit-second"
        var config = store.config
        config.providers = [firstID: ProviderConfig(enabled: true, apiKey: "audit-key"),
                            secondID: ProviderConfig(enabled: true, apiKey: "audit-key")]
        try store.applyAndSave(config)
        let descriptors = [
            FetcherDescriptor(id: firstID, displayName: "first", kind: .minimaxTokenPlan,
                              iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in first }),
            FetcherDescriptor(id: secondID, displayName: "second", kind: .deepseek,
                              iconSystemName: "circle", accentColor: .chatgpt,
                              makeFetcher: { _ in TestQuotaFetcher(providerID: secondID, displayName: "second", kind: .deepseek) })
        ]
        let state = AppState(descriptors: descriptors, configStore: store)
        defer { state.stop() }
        var passes = 0
        state.localUsage.testReconcilePass = { _ in passes += 1 }
        await first.gate.waitUntilReached()
        config.providers[secondID]?.enabled = false
        try store.applyAndSave(config)
        let disabled = await waitUntil { state.statuses.first { $0.id == secondID }?.isEnabled == false }
        XCTAssertTrue(disabled)
        await first.gate.release()
        let settled = await waitUntil { !state.isRefreshJobActive }
        XCTAssertTrue(settled)
        XCTAssertEqual(passes, 1, "Removing an unstarted staggered provider must release the startup reconcile barrier exactly once")
    }

    @MainActor
    func testRecreatedConfigMustReloadWithoutSecondEdit() async throws {
        let store = makeIsolatedConfigStore()
        try store.applyAndSave(store.config)
        store.startWatching()
        defer { store.stopWatching() }
        let original = store.config.refreshIntervalSeconds
        try FileManager.default.removeItem(at: store.configURL)
        try await Task.sleep(for: .milliseconds(600))
        var changed = store.config
        changed.refreshIntervalSeconds = original + 27
        try JSONEncoder().encode(changed).write(to: store.configURL)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds,
                       "The first replacement after a missing-file retry must be consumed")
        changed.refreshIntervalSeconds += 1
        try JSONEncoder().encode(changed).write(to: store.configURL, options: .atomic)
        let secondReload = await waitUntil { store.config.refreshIntervalSeconds == changed.refreshIntervalSeconds }
        XCTAssertTrue(secondReload, "The replacement fd must continue watching subsequent writes")
    }

    func testStartupUnknownUsageMustNotEraseStoredDailyUsage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-runtime-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
        let now = Date()
        let identity = UUID()
        let row = FleetClientProviderUsage(clientID: ClientID.codex, quotaProviderID: QuotaProviderID.openAI,
                                          input: 123, cacheRead: 0, output: 0, reasoning: 0, turns: 1, rounds: 1)
        let bucket = FleetDailyBucket(dayKey: FleetMerger.dayKey(of: now), totals: FleetTotals(summing: [row]),
                                     clientProviders: [row], entries: [], totalsComplete: true,
                                     modelDetailsComplete: false, sourceTruncated: false)
        let old = NodeUsageReport(protocolVersion: FleetProtocol.version,
                                  node: FleetNodeIdentity(nodeID: identity, nodeName: "Audit", timezoneID: "UTC", platform: "macOS"),
                                  seq: 1, generatedAt: now, attributionFingerprint: "audit", dailyBuckets: [bucket], windowUsage: nil, quotas: nil)
        try store.applyReport(old, validation: FleetReportValidator.validate(old), scope: "audit")
        var status = ProviderStatus(id: ProviderKind.codexChatGpt.providerID, displayName: "Audit", kind: .codexChatGpt,
                                    iconSystemName: "circle", accentColor: .chatgpt,
                                    refreshIntervalSeconds: 300, state: .ready)
        status.localUsageFreshness = .uninitialized
        // Exactly the pre-first-reconcile state supplied by AppState.startFleetSync.
        let startup = UsageReportBuilder.build(UsageReportInput(nodeID: identity, nodeName: "Audit",
                                                               bindings: ClientProviderBinding.defaultBindings, statuses: [status], now: now), seq: 2)
        try store.applyReport(startup, validation: FleetReportValidator.validate(startup), scope: "audit")
        let saved = try XCTUnwrap(store.loadHubState(scope: "audit").nodes.first?.report.dailyBuckets?.first { $0.dayKey == bucket.dayKey })
        XCTAssertEqual(saved.totals.input, 123, "Unscanned startup state must preserve the previous successful source")

        func apply(_ status: ProviderStatus, seq: Int) throws -> FleetDailyBucket {
            let report = UsageReportBuilder.build(UsageReportInput(nodeID: identity, nodeName: "Audit",
                                                                    bindings: ClientProviderBinding.defaultBindings, statuses: [status], now: now), seq: seq)
            try store.applyReport(report, validation: FleetReportValidator.validate(report), scope: "audit")
            return try XCTUnwrap(store.loadHubState(scope: "audit").nodes.first?.report.dailyBuckets?.first { $0.dayKey == bucket.dayKey })
        }
        status.localUsageFreshness[.codex] = .failed
        let failed = try apply(status, seq: 3)
        XCTAssertEqual(failed.totals.input, 123, "A failed initial scan must retain last-good usage")
        XCTAssertTrue(failed.unavailableSources?.contains { $0.clientID == ClientID.codex && $0.reason == .failed } == true)
        for source in LocalUsageSource.allCases { status.localUsageFreshness[source] = .clean }
        let zero = try apply(status, seq: 4)
        XCTAssertEqual(zero.totals.input, 0, "A successful complete empty scan must clear old usage")
        XCTAssertTrue(zero.totalsComplete)
        status.isEnabled = false
        status.localUsageFreshness = .uninitialized
        XCTAssertTrue(try apply(status, seq: 5).totalsComplete, "Disabled providers must not leave unavailable markers")
        status.isEnabled = true
        let reenabled = try apply(status, seq: 6)
        XCTAssertFalse(reenabled.totalsComplete, "A re-enabled unscanned source must be checked again")
        for source in LocalUsageSource.allCases { status.localUsageFreshness[source] = .clean }
        XCTAssertTrue(try apply(status, seq: 7).totalsComplete)
    }

    func testQueuedBarkDuplicateMustRespectCooldownAfterFirstSuccess() async throws {
        AuditBarkURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditBarkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let queue = BarkSendQueue(session: session, retryDelay: 0)
        let operation = BarkSendQueue.Operation(request: URLRequest(url: URL(string: "https://audit.invalid/key")!),
                                                cooldownKey: "same-provider-model", label: "audit", eventCount: 1)
        await queue.enqueue(operation)
        let started = await waitUntil(timeout: 2, pollInterval: 0.01) { AuditBarkURLProtocol.requestCount > 0 }
        XCTAssertTrue(started)
        await queue.enqueue(operation)
        AuditBarkURLProtocol.release()
        await queue.awaitIdle()
        XCTAssertEqual(AuditBarkURLProtocol.requestCount, 1,
                       "A pending duplicate must be suppressed after the first successful send starts cooldown")
    }

    func testFailedBarkSendDoesNotSuppressAlreadyQueuedRetry() async throws {
        AuditBarkURLProtocol.reset(failingRequests: 2)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditBarkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let queue = BarkSendQueue(session: session, retryDelay: 0)
        let operation = BarkSendQueue.Operation(request: URLRequest(url: URL(string: "https://audit.invalid/key")!),
                                                cooldownKey: "failed-model", label: "retry", eventCount: 1)
        await queue.enqueue(operation)
        let started = await waitUntil { AuditBarkURLProtocol.requestCount > 0 }
        XCTAssertTrue(started)
        await queue.enqueue(operation)
        AuditBarkURLProtocol.release()
        await queue.awaitIdle()
        XCTAssertEqual(AuditBarkURLProtocol.requestCount, 3, "Two failed attempts must leave the queued operation eligible")
    }
}

@MainActor
private final class InitialScanWriter: LocalUsageStatusWriting {
    var freshness = LocalUsageFreshnessSnapshot.uninitialized
    var minimaxClears = 0
    var antigravityResultApplied = false
    var initializedBeforeResult = false
    var freshnessCalls: [LocalUsageSource: Int] = [:]
    func providerID(for kind: ProviderKind) -> String? { kind.providerID }
    func setScanningState(_ isScanning: Bool, for providerID: String) {}
    func setLocalUsageFreshness(_ value: LocalUsageFreshness, for source: LocalUsageSource) {
        freshnessCalls[source, default: 0] += 1
        freshness[source] = value
    }
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) { antigravityResultApplied = usage != nil }
    func markLocalUsageSourceInitialized(_ source: LocalUsageSource) {
        if source == .antigravity && !antigravityResultApplied { initializedBeforeResult = true }
        freshness.completeInitialScan(for: source)
    }
    func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?) { if usage == nil { minimaxClears += 1 } }
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {}
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {}
    func applyDshUsage(_ usage: DshLocalUsage?) {}
    func applyAgyUsage(_ usage: AgyLocalUsage?) {}
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? { nil }
    func codexConfiguredAuthPath() -> String? { nil }
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int) -> Bool { true }
}

@MainActor
private final class InitialScanScanner: LocalUsageScannerBase<AntigravityLocalUsage>, @unchecked Sendable {
    var shouldFail = true
    var gate: TestAsyncGate?
    init() { super.init(logTag: "[initial-scan-test]", cachedResult: nil) }
    override func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> AntigravityLocalUsage {
        let fail = shouldFail
        let gate = gate
        return {
            if let gate { await gate.hold() }
            if fail { throw URLError(.noPermissionsToReadFile) }
            return .empty
        }
    }
}

private final class AuditBarkURLProtocol: URLProtocol {
    private final class RequestState: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var failingRequests = 0
    }
    private static let state = RequestState()
    private static let hold = DispatchSemaphore(value: 0)
    static var requestCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.count
    }
    static func reset(failingRequests: Int = 0) {
        state.lock.lock()
        state.count = 0
        state.failingRequests = failingRequests
        state.lock.unlock()
        while hold.wait(timeout: .now()) == .success {}
    }
    static func release() { hold.signal() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock()
        Self.state.count += 1
        let ordinal = Self.state.count
        let status = ordinal <= Self.state.failingRequests ? 500 : 200
        Self.state.lock.unlock()
        if ordinal == 1 { _ = Self.hold.wait(timeout: .now() + 5) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
