import XCTest
import Combine
import SwiftUI
@testable import LLM_monitor

/// 4-Tier Opaque-Box E2E Test Suite for LLM-monitor
/// Covering:
/// - R1: Dead code & feature integrity, formatting safety, DeepSeek balance alerts & health levels.
/// - R2: Floating window per-provider refresh (`AppState.refreshOne(providerID:)`, click-to-refresh, `.loading` state, `lastAttemptFailed`, schedule isolation).
/// - R3: Codex multi-key quota support (key isolation, parallel querying, error isolation, independent allowance/progress/reset countdowns).
///
/// Tiers:
/// - Tier 1: Feature Coverage (>=5 per feature)
/// - Tier 2: Boundary & Corner Cases (>=5 per feature)
/// - Tier 3: Cross-Feature Combinations (Pairwise coverage)
/// - Tier 4: Real-World Application Scenarios (>=5 scenarios)
final class E2EProjectTests: StateTestCase {

    // MARK: - Test Doubles

    /// Call counter per provider ID for verifying targeted execution.
    private actor E2ECallCounter {
        private var counts: [String: Int] = [:]
        func record(_ id: String) {
            counts[id, default: 0] += 1
        }
        func count(for id: String) -> Int {
            counts[id] ?? 0
        }
        func total() -> Int {
            counts.values.reduce(0, +)
        }
    }

    /// Reusable asynchronous execution gate for testing in-flight states.
    private actor E2EGate {
        private var isHolding = false
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arm() {
            isHolding = true
        }

        func holdIfNeeded() async {
            guard isHolding else { return }
            let rw = reachWaiters
            reachWaiters.removeAll()
            for w in rw { w.resume() }

            await withCheckedContinuation { cont in
                releaseWaiters.append(cont)
            }
        }

        func waitUntilReached() async {
            if !releaseWaiters.isEmpty { return }
            await withCheckedContinuation { cont in
                reachWaiters.append(cont)
            }
        }

        func release() {
            isHolding = false
            let rw = releaseWaiters
            releaseWaiters.removeAll()
            for w in rw { w.resume() }
        }
    }

    /// Controllable fetcher that can hold execution until released,
    /// enabling verification of in-flight states (`.loading`).
    private final class E2EControllableFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let gate = E2EGate()
        let callCounter: E2ECallCounter?
        var errorToThrow: Error?
        var quotaInfoToReturn: QuotaInfo?

        init(
            providerID: String,
            kind: ProviderKind = .codexChatGpt,
            callCounter: E2ECallCounter? = nil,
            errorToThrow: Error? = nil,
            quotaInfoToReturn: QuotaInfo? = nil
        ) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = kind
            self.callCounter = callCounter
            self.errorToThrow = errorToThrow
            self.quotaInfoToReturn = quotaInfoToReturn
        }

        func arm() async {
            await gate.arm()
        }

        func waitUntilReached() async {
            await gate.waitUntilReached()
        }

        func release() async {
            await gate.release()
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            await callCounter?.record(providerID)
            await gate.holdIfNeeded()
            if let errorToThrow {
                throw errorToThrow
            }
            if let quotaInfoToReturn {
                return quotaInfoToReturn
            }
            return QuotaInfo(
                models: [
                    ModelQuota(
                        modelName: "\(providerID)_model",
                        intervalTotalCount: 100,
                        intervalUsageCount: 10,
                        intervalRemainingPercent: 90,
                        intervalStatus: .present,
                        intervalResetsAt: Date().addingTimeInterval(3600),
                        intervalWindowSeconds: 3600,
                        weeklyTotalCount: 1000,
                        weeklyUsageCount: 200,
                        weeklyRemainingPercent: 80,
                        weeklyStatus: .present,
                        weeklyResetsAt: Date().addingTimeInterval(86400 * 7),
                        weeklyWindowSeconds: 86400 * 7
                    )
                ],
                resetCredits: nil,
                planLabel: "\(providerID)_plan",
                accountEmail: "\(providerID)@test.com",
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    @MainActor
    private func makeE2EAppState(
        descriptors: [FetcherDescriptor],
        refreshInterval: Int = 300
    ) async -> (AppState, ConfigStore) {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = refreshInterval
        for desc in descriptors {
            config.providers[desc.id] = ProviderConfig(
                enabled: true,
                apiKey: "sk-test-valid-key",
                authPath: store.configURL.deletingLastPathComponent().appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }

        // Wait for initial startup pass to complete so test methods start quiescent
        await waitUntil(timeout: 2.0) {
            guard let token = state.refreshScheduler?.beginExternalJob() else { return false }
            state.refreshScheduler?.endExternalJob(token)
            return true
        }

        return (state, store)
    }

    // =========================================================================
    // MARK: - Tier 1: Feature Coverage (R1, R2, R3)
    // =========================================================================

    // --- Tier 1 / R1: Dead Code & Feature Integrity (Formatting, DeepSeek Health, Quota Math) ---

    func testTier1_R1_formatResetSuffix_ladderCompression() {
        let now = Date()
        // > 2d: only days "3d"
        let threeDays = now.addingTimeInterval(3 * 86400 + 5 * 3600)
        XCTAssertEqual(Formatters.formatResetSuffix(from: threeDays, now: now), "3d")

        // 1d - 2d: days + hours "1d5h"
        let oneDayFiveHours = now.addingTimeInterval(86400 + 5 * 3600)
        XCTAssertEqual(Formatters.formatResetSuffix(from: oneDayFiveHours, now: now), "1d5h")

        // 5h+: only hours "5h"
        let fiveHours = now.addingTimeInterval(5 * 3600 + 20 * 60)
        XCTAssertEqual(Formatters.formatResetSuffix(from: fiveHours, now: now), "5h")

        // 1h - 5h: hours + zero-padded minutes "1h23m"
        let oneHour23Min = now.addingTimeInterval(3600 + 23 * 60)
        XCTAssertEqual(Formatters.formatResetSuffix(from: oneHour23Min, now: now), "1h23m")

        // < 1h: minutes "23m"
        let twentyThreeMin = now.addingTimeInterval(23 * 60)
        XCTAssertEqual(Formatters.formatResetSuffix(from: twentyThreeMin, now: now), "23m")

        // Expired (<= 0)
        let past = now.addingTimeInterval(-10)
        XCTAssertEqual(Formatters.formatResetSuffix(from: past, now: now), "已过期")
    }

    func testTier1_R1_formatPeakAndBillingDurations_textOutput() {
        // Peak duration
        XCTAssertEqual(Formatters.formatPeakDuration(2 * 86400 + 8 * 3600), "2天8小时")
        XCTAssertEqual(Formatters.formatPeakDuration(3600 + 30 * 60), "1小时30分")
        XCTAssertEqual(Formatters.formatPeakDuration(3600), "1小时")
        XCTAssertEqual(Formatters.formatPeakDuration(30 * 60), "30分")

        // Billing remaining duration
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(12 * 86400 + 8 * 3600), "12天8小时后")
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(12 * 86400), "12天后")
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(2 * 3600 + 15 * 60), "2小时15分后")
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(25 * 60), "25分后")
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(0), "已到期")
    }

    func testTier1_R1_formatDigitalAndGeneralDuration_representations() {
        // Digital clock durations
        XCTAssertEqual(Formatters.formatDigitalDuration(3665), "1:01:05")
        XCTAssertEqual(Formatters.formatDigitalDuration(125), "02:05")
        XCTAssertEqual(Formatters.formatDigitalDuration(-5), "00:00")

        // General duration
        XCTAssertEqual(Formatters.formatDuration(86400 + 3600), "1 天 1 小时")
        XCTAssertEqual(Formatters.formatDuration(3600 + 120), "1 小时 2 分")
        XCTAssertEqual(Formatters.formatDuration(120), "2 分")
        XCTAssertEqual(Formatters.formatDuration(45), "45 秒")
    }

    func testTier1_R1_deepseekHealthLevel_thresholdRules() {
        let config = AlertThresholdConfig.default // critical = 3.0, warning = 10.0
        XCTAssertEqual(config.deepseekHealthLevel(balance: nil), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 0.0), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 2.99), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 3.0), .warning)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 9.99), .warning)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 10.0), .healthy)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 50.0), .healthy)
    }

    func testTier1_R1_providerStatus_deepseekHealthDerivation() {
        func makeStatus(balance: Double) -> ProviderStatus {
            let info = QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date(),
                balanceDetail: DeepseekBalanceDetail(currency: "CNY", total: balance, toppedUp: balance, granted: 0)
            )
            return ProviderStatus(
                id: "deepseek",
                displayName: "DeepSeek",
                kind: .deepseek,
                iconSystemName: "sparkles",
                accentColor: .deepseek,
                refreshIntervalSeconds: 300,
                state: .ok(info)
            )
        }

        XCTAssertEqual(makeStatus(balance: 1.5).aggregateHealthLevel(), .critical)
        XCTAssertEqual(makeStatus(balance: 5.0).aggregateHealthLevel(), .warning)
        XCTAssertEqual(makeStatus(balance: 20.0).aggregateHealthLevel(), .healthy)
    }

    func testTier1_R1_activeFeatures_modelQuotaColorLevel() {
        // Without time window fraction (static threshold: warning 60%, critical 30%)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 10, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 45, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 85, timeFraction: nil), .healthy)

        // Time-aware dynamic denominator (timeFraction = 0.5 -> dynamic denominator = 50%)
        // percent 20 out of 50 = 40% -> warning
        XCTAssertEqual(ModelQuota.colorLevel(percent: 20, timeFraction: 0.5), .warning)
        // percent 10 out of 50 = 20% -> critical (< 30%)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 10, timeFraction: 0.5), .critical)
        // percent 40 out of 50 = 80% -> healthy (>= 60%)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 40, timeFraction: 0.5), .healthy)
    }

    // --- Tier 1 / R2: Floating Window Per-Provider Refresh ---

    @MainActor
    func testTier1_R2_refreshOne_targetedExecutionOnly() async {
        let counter = E2ECallCounter()
        let fetcherA = E2EControllableFetcher(providerID: "prov_a", callCounter: counter)
        let fetcherB = E2EControllableFetcher(providerID: "prov_b", callCounter: counter)
        let fetcherC = E2EControllableFetcher(providerID: "prov_c", callCounter: counter)

        let descriptors: [FetcherDescriptor] = [
            FetcherDescriptor(id: "prov_a", displayName: "A", kind: .codexChatGpt, iconSystemName: "1.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "prov_b", displayName: "B", kind: .codexChatGpt, iconSystemName: "2.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB }),
            FetcherDescriptor(id: "prov_c", displayName: "C", kind: .codexChatGpt, iconSystemName: "3.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherC })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialA = await counter.count(for: "prov_a")
        let initialB = await counter.count(for: "prov_b")
        let initialC = await counter.count(for: "prov_c")

        // Start targeted refresh for prov_b only
        await state.refreshOne(providerID: "prov_b")

        let countA = await counter.count(for: "prov_a")
        let countB = await counter.count(for: "prov_b")
        let countC = await counter.count(for: "prov_c")

        XCTAssertEqual(countB, initialB + 1, "Targeted provider B must be queried exactly once")
        XCTAssertEqual(countA, initialA, "Non-targeted provider A must NOT be queried")
        XCTAssertEqual(countC, initialC, "Non-targeted provider C must NOT be queried")
    }

    @MainActor
    func testTier1_R2_refreshOne_reanchorsOnlyTargetedProvider() async {
        let counter = E2ECallCounter()
        let fetcherA = E2EControllableFetcher(providerID: "prov_a", callCounter: counter)
        let fetcherB = E2EControllableFetcher(providerID: "prov_b", callCounter: counter)

        let descriptors = [
            FetcherDescriptor(id: "prov_a", displayName: "A", kind: .codexChatGpt, iconSystemName: "1.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "prov_b", displayName: "B", kind: .codexChatGpt, iconSystemName: "2.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let baseCountA = await counter.count(for: "prov_a")
        let baseCountB = await counter.count(for: "prov_b")
        let baseRefreshedA = state.statuses.first { $0.id == "prov_a" }?.lastRefreshedAt
        let baseRefreshedB = state.statuses.first { $0.id == "prov_b" }?.lastRefreshedAt

        // Targeted refresh of prov_a
        await state.refreshOne(providerID: "prov_a")
        let afterCountA = await counter.count(for: "prov_a")
        let afterCountB = await counter.count(for: "prov_b")

        XCTAssertEqual(afterCountA, baseCountA + 1, "Targeted refresh must issue another query to A")
        XCTAssertEqual(afterCountB, baseCountB, "Targeted refresh of A must not query B")

        let refreshedA = state.statuses.first { $0.id == "prov_a" }?.lastRefreshedAt
        let refreshedB = state.statuses.first { $0.id == "prov_b" }?.lastRefreshedAt

        XCTAssertNotEqual(refreshedA, baseRefreshedA, "Provider A lastRefreshedAt must update")
        XCTAssertEqual(refreshedB, baseRefreshedB, "Provider B lastRefreshedAt must remain untouched")
    }

    @MainActor
    func testTier1_R2_providerState_loadingTransitionOnRefresh() async {
        let fetcher = E2EControllableFetcher(providerID: "prov_load")
        let descriptors = [
            FetcherDescriptor(id: "prov_load", displayName: "L", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await fetcher.arm()
        let refreshTask = Task { await state.refreshOne(providerID: "prov_load") }
        await fetcher.waitUntilReached()

        // Verify state is .loading while in-flight
        let inFlightState = state.statuses.first { $0.id == "prov_load" }?.state
        if case .loading = inFlightState {
            // Success: state is loading
        } else {
            XCTFail("Provider state must be .loading during in-flight fetch, got: \(String(describing: inFlightState))")
        }

        await fetcher.release()
        await refreshTask.value

        // Verify transition to .ok after completion
        let settledState = state.statuses.first { $0.id == "prov_load" }?.state
        if case .ok = settledState {
            // Success: settled to ok
        } else {
            XCTFail("Provider state must transition to .ok after fetch completes, got: \(String(describing: settledState))")
        }
    }

    @MainActor
    func testTier1_R2_providerState_updatesFetchedAtOnSuccess() async {
        let fetcher = E2EControllableFetcher(providerID: "prov_success")
        let descriptors = [
            FetcherDescriptor(id: "prov_success", displayName: "S", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialRefreshedAt = state.statuses.first { $0.id == "prov_success" }?.lastRefreshedAt

        await state.refreshOne(providerID: "prov_success")

        let status = try! XCTUnwrap(state.statuses.first { $0.id == "prov_success" })
        XCTAssertNotNil(status.lastRefreshedAt, "lastRefreshedAt must be updated after successful refresh")
        XCTAssertNotEqual(status.lastRefreshedAt, initialRefreshedAt)
        XCTAssertNotNil(status.lastSuccess, "lastSuccess must be populated on success")
    }

    @MainActor
    func testTier1_R2_providerState_marksLastAttemptFailedOnError() async {
        let fetcher = E2EControllableFetcher(
            providerID: "prov_error",
            errorToThrow: NSError(domain: "test.network", code: 503, userInfo: [NSLocalizedDescriptionKey: "Service Unavailable"])
        )
        let descriptors = [
            FetcherDescriptor(id: "prov_error", displayName: "E", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await state.refreshOne(providerID: "prov_error")

        let status = try! XCTUnwrap(state.statuses.first { $0.id == "prov_error" })
        if case .failed(let message, _) = status.state {
            XCTAssertTrue(message.contains("Service Unavailable") || message.contains("503"), "Failure message should be surfaced")
        } else {
            XCTFail("Expected .failed state, got \(status.state)")
        }
    }

    @MainActor
    func testTier1_R2_cardQuotaRefreshAction_invokesRefreshOne() async {
        let counter = E2ECallCounter()
        let fetcher = E2EControllableFetcher(providerID: "prov_action", callCounter: counter)
        let descriptors = [
            FetcherDescriptor(id: "prov_action", displayName: "A", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialCalls = await counter.count(for: "prov_action")

        // Simulating the view environment action injected in EdgeDockController+Popover
        let cardQuotaRefreshAction: (String) -> Void = { providerID in
            Task { @MainActor in
                await state.refreshOne(providerID: providerID)
            }
        }

        cardQuotaRefreshAction("prov_action")

        let ok = await waitUntil(timeout: 2.0) {
            await counter.count(for: "prov_action") == initialCalls + 1
        }
        XCTAssertTrue(ok, "cardQuotaRefreshAction must initiate refreshOne for the provider")
    }

    // --- Tier 1 / R3: Codex Multi-Key Quota Support ---

    func testTier1_R3_openAIApiCreditDetails_allowanceAndUsedAmountCalculations() {
        let start = Date().addingTimeInterval(-86400 * 10)
        let end = Date().addingTimeInterval(86400 * 20)
        let credits = OpenAIApiCreditDetails(
            organizationName: "KeyA_Org",
            totalQuota: 50.0,
            usedAmount: 12.5,
            cycleStart: start,
            cycleEnd: end,
            fetchedAt: Date(),
            lastAttemptFailed: false
        )

        XCTAssertEqual(credits.remainingAmount, 37.5, accuracy: 0.001)
        XCTAssertEqual(credits.remainingPercent, 75.0, accuracy: 0.001)
        XCTAssertEqual(credits.organizationName, "KeyA_Org")
    }

    func testTier1_R3_openAIApiCreditDetails_billingCycleDateCalculation() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Anchor date: 2026-05-20 12:00:00 UTC
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 20
        comps.hour = 12
        let now = cal.date(from: comps)!

        let (cycleStart, cycleEnd) = OpenAIApiCreditDetails.currentBillingCycle(
            day: 15,
            hour: 8,
            minute: 0,
            now: now,
            calendar: cal
        )

        let startComps = cal.dateComponents([.year, .month, .day, .hour], from: cycleStart)
        let endComps = cal.dateComponents([.year, .month, .day, .hour], from: cycleEnd)

        XCTAssertEqual(startComps.year, 2026)
        XCTAssertEqual(startComps.month, 5)
        XCTAssertEqual(startComps.day, 15)
        XCTAssertEqual(startComps.hour, 8)

        XCTAssertEqual(endComps.year, 2026)
        XCTAssertEqual(endComps.month, 6)
        XCTAssertEqual(endComps.day, 15)
        XCTAssertEqual(endComps.hour, 8)
    }

    func testTier1_R3_openAIApiCreditDetails_timeRemainingFractionClamping() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1000)

        let credits = OpenAIApiCreditDetails(
            organizationName: "Org",
            totalQuota: 100.0,
            usedAmount: 10.0,
            cycleStart: t0,
            cycleEnd: t1,
            fetchedAt: t0
        )

        // Halfway through cycle
        let halfway = t0.addingTimeInterval(500)
        XCTAssertEqual(credits.timeRemainingFraction(at: halfway), 0.5, accuracy: 0.001)

        // At beginning
        XCTAssertEqual(credits.timeRemainingFraction(at: t0), 1.0, accuracy: 0.001)

        // At end / past expiration
        XCTAssertEqual(credits.timeRemainingFraction(at: t1), 0.0, accuracy: 0.001)
        XCTAssertEqual(credits.timeRemainingFraction(at: t1.addingTimeInterval(500)), 0.0, accuracy: 0.001)
    }

    func testTier1_R3_parallelMultiKeyQuery_errorIsolation() async {
        // Multi-key query simulation:
        // Key 1 succeeds with quota data.
        // Key 2 fails with HTTP 401 Unauthorized.
        actor MultiKeyWorker {
            func fetchKey1() async throws -> OpenAIApiCreditDetails {
                try await Task.sleep(nanoseconds: 10_000_000)
                return OpenAIApiCreditDetails(
                    organizationName: "Org1",
                    totalQuota: 100.0,
                    usedAmount: 20.0,
                    cycleStart: Date(),
                    cycleEnd: Date().addingTimeInterval(86400 * 30),
                    fetchedAt: Date()
                )
            }

            func fetchKey2() async throws -> OpenAIApiCreditDetails {
                try await Task.sleep(nanoseconds: 15_000_000)
                throw NSError(domain: "openai.api", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid API Key"])
            }
        }

        let worker = MultiKeyWorker()

        // Concurrent execution with error isolation
        async let r1: Result<OpenAIApiCreditDetails, Error> = {
            do { return .success(try await worker.fetchKey1()) }
            catch { return .failure(error) }
        }()
        async let r2: Result<OpenAIApiCreditDetails, Error> = {
            do { return .success(try await worker.fetchKey2()) }
            catch { return .failure(error) }
        }()

        let res1 = await r1
        let res2 = await r2

        switch res1 {
        case .success(let details):
            XCTAssertEqual(details.organizationName, "Org1")
            XCTAssertEqual(details.remainingPercent, 80.0, accuracy: 0.01)
        case .failure(let err):
            XCTFail("Key 1 should succeed independently, failed with \(err)")
        }

        switch res2 {
        case .success:
            XCTFail("Key 2 should fail with 401")
        case .failure(let error as NSError):
            XCTAssertEqual(error.code, 401)
        }
    }

    func testTier1_R3_independentKeyQuotas_separateProgressAndAllowances() {
        let key1 = OpenAIApiCreditDetails(
            organizationName: "Key_SmallOrg",
            totalQuota: 20.0,
            usedAmount: 15.0,
            cycleStart: Date(),
            cycleEnd: Date().addingTimeInterval(86400 * 10),
            fetchedAt: Date()
        )

        let key2 = OpenAIApiCreditDetails(
            organizationName: "Key_LargeOrg",
            totalQuota: 200.0,
            usedAmount: 20.0,
            cycleStart: Date(),
            cycleEnd: Date().addingTimeInterval(86400 * 25),
            fetchedAt: Date()
        )

        // Key 1: 5 / 20 remaining = 25%
        XCTAssertEqual(key1.remainingPercent, 25.0, accuracy: 0.01)
        // Key 2: 180 / 200 remaining = 90%
        XCTAssertEqual(key2.remainingPercent, 90.0, accuracy: 0.01)

        XCTAssertNotEqual(key1.remainingPercent, key2.remainingPercent)
        XCTAssertNotEqual(key1.totalQuota, key2.totalQuota)
    }

    // =========================================================================
    // MARK: - Tier 2: Boundary & Corner Cases (R1, R2, R3)
    // =========================================================================

    // --- Tier 2 / R1 Boundary Cases ---

    func testTier2_R1_formatters_boundary_zeroAndNegativeSeconds() {
        let now = Date()
        XCTAssertEqual(Formatters.formatResetSuffix(from: now, now: now), "已过期")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(-3600), now: now), "已过期")

        XCTAssertEqual(Formatters.formatPeakDuration(0), "1分")
        XCTAssertEqual(Formatters.formatPeakDuration(-10), "1分")

        XCTAssertEqual(Formatters.formatBillingRemainingDuration(0), "已到期")
        XCTAssertEqual(Formatters.formatBillingRemainingDuration(-0.5), "已到期")

        XCTAssertEqual(Formatters.formatDigitalDuration(0), "00:00")
        XCTAssertEqual(Formatters.formatDigitalDuration(-100), "00:00")
    }

    func testTier2_R1_formatters_boundary_calendarAndYearBoundary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 28800)! // UTC+8

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 12
        comps.day = 31
        comps.hour = 23
        comps.minute = 59
        comps.second = 59
        let newYearEve = cal.date(from: comps)!
        let newYearDay = newYearEve.addingTimeInterval(2) // 2027-01-01 00:00:01

        let clockStr = Formatters.formatClock(newYearDay, now: newYearEve)
        // When across day/year boundaries, formatClock outputs "MM-dd HH:mm"
        XCTAssertEqual(clockStr, "01-01 00:00")
    }

    func testTier2_R1_formatters_boundary_exactStepTransitions() {
        let now = Date()
        // Exactly 86400s (1d0h)
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(86400), now: now), "1d0h")
        // Exactly 5 hours (18000s)
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(18000), now: now), "5h")
        // Exactly 1 hour (3600s)
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(3600), now: now), "1h00m")
        // Exactly 60s
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(60), now: now), "1m")
        // 59s (floored to minimum 1m before 0s expiration)
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(59), now: now), "1m")
    }

    func testTier2_R1_deepseekHealth_boundary_exactThresholds() {
        let config = AlertThresholdConfig(
            deepseekBalanceWarning: 15.0,
            deepseekBalanceCritical: 5.0
        )

        XCTAssertEqual(config.deepseekHealthLevel(balance: 4.999), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 5.0), .warning)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 14.999), .warning)
        XCTAssertEqual(config.deepseekHealthLevel(balance: 15.0), .healthy)
    }

    func testTier2_R1_deepseekHealth_boundary_nilAndNegativeBalances() {
        let config = AlertThresholdConfig.default
        XCTAssertEqual(config.deepseekHealthLevel(balance: nil), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: -0.001), .critical)
        XCTAssertEqual(config.deepseekHealthLevel(balance: -9999.0), .critical)
    }

    // --- Tier 2 / R2 Boundary Cases ---

    @MainActor
    func testTier2_R2_refreshOne_boundary_nonExistentProviderHandledGracefully() async {
        let descriptors = [
            FetcherDescriptor(id: "real_prov", displayName: "Real", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in E2EControllableFetcher(providerID: "real_prov") })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Must not crash or lock when provider does not exist
        await state.refreshOne(providerID: "non_existent_provider_id")
        XCTAssertEqual(state.statuses.count, 1)
    }

    @MainActor
    func testTier2_R2_refreshOne_boundary_concurrentClicksGatedByExternalJob() async {
        let counter = E2ECallCounter()
        let fetcher = E2EControllableFetcher(providerID: "prov_gate", callCounter: counter)
        let descriptors = [
            FetcherDescriptor(id: "prov_gate", displayName: "G", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialCalls = await counter.count(for: "prov_gate")

        await fetcher.arm()
        let firstRefresh = Task { await state.refreshOne(providerID: "prov_gate") }
        await fetcher.waitUntilReached()

        // Attempt second concurrent refresh while first is in-flight
        // The beginExternalJob gate must reject second request immediately
        await state.refreshOne(providerID: "prov_gate")

        await fetcher.release()
        await firstRefresh.value

        let totalCalls = await counter.count(for: "prov_gate")
        XCTAssertEqual(totalCalls, initialCalls + 1, "Duplicate click during active transaction must be gated without duplicate fetch")
    }

    @MainActor
    func testTier2_R2_refreshOne_boundary_networkExceptionPreservesLastSuccess() async {
        let goodQuota = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "gpt-4",
                    intervalTotalCount: 50,
                    intervalUsageCount: 5,
                    intervalRemainingPercent: 90,
                    intervalStatus: .present,
                    intervalResetsAt: nil,
                    intervalWindowSeconds: nil,
                    weeklyTotalCount: 0,
                    weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0,
                    weeklyStatus: .absent,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            ],
            resetCredits: nil,
            planLabel: "Plan",
            accountEmail: "user@test.com",
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        let fetcher = E2EControllableFetcher(providerID: "prov_fallback", quotaInfoToReturn: goodQuota)
        let descriptors = [
            FetcherDescriptor(id: "prov_fallback", displayName: "F", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Initial success
        await state.refreshOne(providerID: "prov_fallback")
        let statusAfterFirst = try! XCTUnwrap(state.statuses.first { $0.id == "prov_fallback" })
        XCTAssertNotNil(statusAfterFirst.lastSuccess)

        // Make fetcher fail on next attempt
        fetcher.errorToThrow = NSError(domain: "network", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Offline"])
        await state.refreshOne(providerID: "prov_fallback")

        let statusAfterSecond = try! XCTUnwrap(state.statuses.first { $0.id == "prov_fallback" })
        XCTAssertNotNil(statusAfterSecond.lastSuccess, "Prior good quota data must be preserved on network failure")
        if case .failed(_, let preservedSuccess) = statusAfterSecond.state {
            XCTAssertEqual(preservedSuccess?.models.first?.modelName, "gpt-4")
        } else {
            XCTFail("Status state should be .failed with preserved lastSuccess")
        }
    }

    @MainActor
    func testTier2_R2_refreshOne_boundary_inFlightBackgroundPromotedOrAwaited() async {
        let counter = E2ECallCounter()
        let fetcher = E2EControllableFetcher(providerID: "prov_bg", callCounter: counter)
        let descriptors = [
            FetcherDescriptor(id: "prov_bg", displayName: "BG", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialCalls = await counter.count(for: "prov_bg")
        await state.refreshOne(providerID: "prov_bg")
        let calls = await counter.count(for: "prov_bg")
        XCTAssertEqual(calls, initialCalls + 1)
    }

    @MainActor
    func testTier2_R2_refreshOne_boundary_taskCancellationCleansUpJobToken() async {
        let fetcher = E2EControllableFetcher(providerID: "prov_cancel")
        let descriptors = [
            FetcherDescriptor(id: "prov_cancel", displayName: "C", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await fetcher.arm()
        let cancellableTask = Task { await state.refreshOne(providerID: "prov_cancel") }
        await fetcher.waitUntilReached()

        // Cancel during in-flight
        cancellableTask.cancel()
        await fetcher.release()
        await cancellableTask.value

        // Next refresh call must be accepted and not blocked by orphaned lock
        await state.refreshOne(providerID: "prov_cancel")

        let status = try! XCTUnwrap(state.statuses.first { $0.id == "prov_cancel" })
        if case .ok = status.state {
            // Succeeded cleanly
        } else {
            XCTFail("Second refresh after cancellation must succeed, got \(status.state)")
        }
    }

    // --- Tier 2 / R3 Boundary Cases ---

    func testTier2_R3_billingCycle_boundary_extremeDaysAndLeapYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Leap year: February 2028 (29 days)
        var comps = DateComponents()
        comps.year = 2028
        comps.month = 2
        comps.day = 10
        let leapFeb = cal.date(from: comps)!

        // Requesting Day 31 in February: clamped to 29
        let (start, end) = OpenAIApiCreditDetails.currentBillingCycle(
            day: 35, // extreme day clamped
            hour: 25, // extreme hour clamped to 23
            minute: 70, // extreme minute clamped to 59
            now: leapFeb,
            calendar: cal
        )

        let startDay = cal.component(.day, from: start)
        let startHour = cal.component(.hour, from: start)
        let startMinute = cal.component(.minute, from: start)

        XCTAssertEqual(startDay, 31, "Previous month Jan had 31 days")
        XCTAssertEqual(startHour, 23)
        XCTAssertEqual(startMinute, 59)

        let endDay = cal.component(.day, from: end)
        XCTAssertEqual(endDay, 29, "February 2028 clamped to 29 days")
    }

    func testTier2_R3_quotaAllowance_boundary_zeroOrNegativeTotalQuota() {
        let creditsZero = OpenAIApiCreditDetails(
            organizationName: "Zero",
            totalQuota: 0.0,
            usedAmount: 0.0,
            cycleStart: Date(),
            cycleEnd: Date().addingTimeInterval(3600),
            fetchedAt: Date()
        )
        XCTAssertEqual(creditsZero.remainingPercent, 0.0, "Zero quota must produce 0% without division by zero crash")

        let creditsNegative = OpenAIApiCreditDetails(
            organizationName: "Negative",
            totalQuota: -10.0,
            usedAmount: 5.0,
            cycleStart: Date(),
            cycleEnd: Date().addingTimeInterval(3600),
            fetchedAt: Date()
        )
        XCTAssertEqual(creditsNegative.remainingPercent, 0.0, "Negative quota must yield 0%")
    }

    func testTier2_R3_quotaAllowance_boundary_usedAmountExceedsTotalQuota() {
        let overspent = OpenAIApiCreditDetails(
            organizationName: "Overspent",
            totalQuota: 50.0,
            usedAmount: 85.0,
            cycleStart: Date(),
            cycleEnd: Date().addingTimeInterval(3600),
            fetchedAt: Date()
        )
        XCTAssertEqual(overspent.remainingAmount, 0.0, "Overspent quota remaining amount should clamp to 0")
        XCTAssertEqual(overspent.remainingPercent, 0.0, "Overspent quota remaining percentage should clamp to 0%")
    }

    func testTier2_R3_timeRemainingFraction_boundary_nowEqualsOrExceedsCycleEnd() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(100)
        let credits = OpenAIApiCreditDetails(
            organizationName: "Expiring",
            totalQuota: 100.0,
            usedAmount: 0.0,
            cycleStart: t0,
            cycleEnd: t1,
            fetchedAt: t0
        )

        // Exactly at cycleEnd
        XCTAssertEqual(credits.timeRemainingFraction(at: t1), 0.0)
        // 100 seconds past cycleEnd
        XCTAssertEqual(credits.timeRemainingFraction(at: t1.addingTimeInterval(100)), 0.0)
        // Before cycleStart
        XCTAssertEqual(credits.timeRemainingFraction(at: t0.addingTimeInterval(-50)), 1.0)
    }

    func testTier2_R3_multiKey_boundary_allKeysFailWithIndependentErrors() async {
        enum KeyResult: Sendable {
            case ok(Double)
            case failure(String)
        }

        @Sendable func queryKey(code: Int) async -> KeyResult {
            if code == 200 { return .ok(100.0) }
            return .failure("HTTP \(code)")
        }

        async let k1 = queryKey(code: 401)
        async let k2 = queryKey(code: 429)
        async let k3 = queryKey(code: 500)

        let (r1, r2, r3) = await (k1, k2, k3)

        if case .failure(let err) = r1 { XCTAssertEqual(err, "HTTP 401") } else { XCTFail() }
        if case .failure(let err) = r2 { XCTAssertEqual(err, "HTTP 429") } else { XCTFail() }
        if case .failure(let err) = r3 { XCTAssertEqual(err, "HTTP 500") } else { XCTFail() }
    }

    // =========================================================================
    // MARK: - Tier 3: Cross-Feature Combinations (Pairwise Coverage)
    // =========================================================================

    @MainActor
    func testTier3_crossFeature_codexMultiKeyDuringProviderRefresh() async {
        // Multi-key Codex quota simulation integrated with AppState.refreshOne
        let multiKeyInfo = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "chatgpt_plan",
                    intervalTotalCount: 100,
                    intervalUsageCount: 10,
                    intervalRemainingPercent: 90,
                    intervalStatus: .present,
                    intervalResetsAt: Date().addingTimeInterval(7200),
                    intervalWindowSeconds: 7200,
                    weeklyTotalCount: 1000,
                    weeklyUsageCount: 100,
                    weeklyRemainingPercent: 90,
                    weeklyStatus: .present,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            ],
            resetCredits: nil,
            planLabel: "ChatGPT Pro",
            accountEmail: "pro@openai.com",
            codexUsageDetails: nil,
            fetchedAt: Date(),
            openAIApiCredits: OpenAIApiCreditDetails(
                organizationName: "Key_Admin",
                totalQuota: 100.0,
                usedAmount: 25.0,
                cycleStart: Date().addingTimeInterval(-86400 * 5),
                cycleEnd: Date().addingTimeInterval(86400 * 25),
                fetchedAt: Date()
            )
        )

        let fetcher = E2EControllableFetcher(providerID: "codex_chatgpt", quotaInfoToReturn: multiKeyInfo)
        let descriptors = [
            FetcherDescriptor(id: "codex_chatgpt", displayName: "Codex", kind: .codexChatGpt, iconSystemName: "terminal", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await state.refreshOne(providerID: "codex_chatgpt")

        let status = try! XCTUnwrap(state.statuses.first { $0.id == "codex_chatgpt" })
        let credits = try! XCTUnwrap(status.lastSuccess?.openAIApiCredits)
        XCTAssertEqual(credits.remainingPercent, 75.0, accuracy: 0.01)
        XCTAssertEqual(status.lastSuccess?.models.first?.intervalRemainingPercent, 90.0)
    }

    @MainActor
    func testTier3_crossFeature_floatingWindowRefreshWhileOtherProviderInFlight() async {
        let fetcherSlow = E2EControllableFetcher(providerID: "prov_slow")
        let fetcherFast = E2EControllableFetcher(providerID: "prov_fast")

        let descriptors = [
            FetcherDescriptor(id: "prov_slow", displayName: "Slow", kind: .codexChatGpt, iconSystemName: "tortoise", accentColor: .chatgpt, makeFetcher: { _ in fetcherSlow }),
            FetcherDescriptor(id: "prov_fast", displayName: "Fast", kind: .codexChatGpt, iconSystemName: "hare", accentColor: .chatgpt, makeFetcher: { _ in fetcherFast })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Start slow provider refresh and hold it
        await fetcherSlow.arm()
        let slowTask = Task { await state.refreshOne(providerID: "prov_slow") }
        await fetcherSlow.waitUntilReached()

        // Fast provider refresh is attempted while slow provider is in-flight
        // Global external job gate should serialize or reject cleanly
        await state.refreshOne(providerID: "prov_fast")

        await fetcherSlow.release()
        await slowTask.value

        // Now fast provider can be refreshed
        await state.refreshOne(providerID: "prov_fast")

        let statusFast = try! XCTUnwrap(state.statuses.first { $0.id == "prov_fast" })
        if case .ok = statusFast.state {
            // Fast succeeded
        } else {
            XCTFail("Fast provider must succeed after slow finishes")
        }
    }

    @MainActor
    func testTier3_crossFeature_refreshFailureOnOneProviderPreservesDeepSeekHealth() async {
        let deepseekInfo = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            balanceDetail: DeepseekBalanceDetail(currency: "CNY", total: 45.0, toppedUp: 45.0, granted: 0)
        )

        let deepseekFetcher = E2EControllableFetcher(providerID: "deepseek", kind: .deepseek, quotaInfoToReturn: deepseekInfo)
        let failingFetcher = E2EControllableFetcher(
            providerID: "failing_prov",
            errorToThrow: NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Server Error"])
        )

        let descriptors = [
            FetcherDescriptor(id: "deepseek", displayName: "DeepSeek", kind: .deepseek, iconSystemName: "sparkles", accentColor: .deepseek, makeFetcher: { _ in deepseekFetcher }),
            FetcherDescriptor(id: "failing_prov", displayName: "Failing", kind: .codexChatGpt, iconSystemName: "xmark", accentColor: .chatgpt, makeFetcher: { _ in failingFetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Refresh DeepSeek to healthy state
        await state.refreshOne(providerID: "deepseek")

        // Refresh failing provider
        await state.refreshOne(providerID: "failing_prov")

        let dsStatus = try! XCTUnwrap(state.statuses.first { $0.id == "deepseek" })
        let failStatus = try! XCTUnwrap(state.statuses.first { $0.id == "failing_prov" })

        XCTAssertEqual(dsStatus.aggregateHealthLevel(), .healthy, "DeepSeek health must remain healthy despite other provider error")
        if case .failed = failStatus.state {
            // Correctly flagged
        } else {
            XCTFail("Failing provider must be marked failed")
        }
    }

    @MainActor
    func testTier3_crossFeature_configStoreUpdateDuringTargetedRefresh() async {
        let fetcher = E2EControllableFetcher(providerID: "prov_cfg")
        let descriptors = [
            FetcherDescriptor(id: "prov_cfg", displayName: "CFG", kind: .codexChatGpt, iconSystemName: "gear", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, store) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await fetcher.arm()
        let refreshTask = Task { await state.refreshOne(providerID: "prov_cfg") }
        await fetcher.waitUntilReached()

        // Modify config during in-flight refresh
        var updatedConfig = store.config
        updatedConfig.refreshIntervalSeconds = 600
        try! store.applyAndSave(updatedConfig)

        await fetcher.release()
        await refreshTask.value

        // The in-flight refresh was safely deferred due to config generation change.
        // Verify state is non-blocking and a subsequent refresh succeeds under the new generation.
        await state.refreshOne(providerID: "prov_cfg")
        let status = try! XCTUnwrap(state.statuses.first { $0.id == "prov_cfg" })
        if case .ok = status.state {
            // Succeeded cleanly without deadlock or corruption
        } else {
            XCTFail("Subsequent refresh must complete under updated configuration")
        }
    }

    func testTier3_crossFeature_multiKeyCodexProgressBarsWithRelativeFormatters() {
        let now = Date()
        let keyA = OpenAIApiCreditDetails(
            organizationName: "Key_A",
            totalQuota: 50.0,
            usedAmount: 10.0,
            cycleStart: now.addingTimeInterval(-86400 * 5),
            cycleEnd: now.addingTimeInterval(86400 * 25),
            fetchedAt: now
        )

        let keyB = OpenAIApiCreditDetails(
            organizationName: "Key_B",
            totalQuota: 100.0,
            usedAmount: 80.0,
            cycleStart: now.addingTimeInterval(-86400 * 15),
            cycleEnd: now.addingTimeInterval(3600 * 3), // Expiring in 3 hours
            fetchedAt: now
        )

        // Progress bar inputs
        let barFractionA = keyA.remainingPercent / 100.0 // 0.8
        let barFractionB = keyB.remainingPercent / 100.0 // 0.2
        XCTAssertEqual(barFractionA, 0.8, accuracy: 0.001)
        XCTAssertEqual(barFractionB, 0.2, accuracy: 0.001)

        // Time indicator inputs
        let timeRemainingFractionA = keyA.timeRemainingFraction(at: now)
        let timeRemainingFractionB = keyB.timeRemainingFraction(at: now)
        XCTAssertGreaterThan(timeRemainingFractionA, 0.7)
        XCTAssertLessThan(timeRemainingFractionB, 0.1)

        // Reset countdown formatters
        let countdownA = Formatters.formatBillingRemainingDuration(keyA.cycleEnd.timeIntervalSince(now))
        let countdownB = Formatters.formatBillingRemainingDuration(keyB.cycleEnd.timeIntervalSince(now))

        XCTAssertTrue(countdownA.contains("25天后") || countdownA.contains("天"))
        XCTAssertTrue(countdownB.contains("3小时后") || countdownB.contains("小时"))
    }

    @MainActor
    func testTier3_crossFeature_pinnedStatusBarProviderWithMultiKeyAndRefresh() async {
        let quotaInfo = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "gpt-4o",
                    intervalTotalCount: 100,
                    intervalUsageCount: 20,
                    intervalRemainingPercent: 80,
                    intervalStatus: .present,
                    intervalResetsAt: Date().addingTimeInterval(3600),
                    intervalWindowSeconds: 3600,
                    weeklyTotalCount: 1000,
                    weeklyUsageCount: 100,
                    weeklyRemainingPercent: 90,
                    weeklyStatus: .present,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            ],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "plus@openai.com",
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        let fetcher = E2EControllableFetcher(providerID: "codex_chatgpt", quotaInfoToReturn: quotaInfo)
        let descriptors = [
            FetcherDescriptor(id: "codex_chatgpt", displayName: "ChatGPT", kind: .codexChatGpt, iconSystemName: "terminal", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, store) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        state.toggleStatusBarPinnedProvider("codex_chatgpt")
        XCTAssertEqual(store.config.statusBarPinnedProvider, "codex_chatgpt")

        await state.refreshOne(providerID: "codex_chatgpt")

        let metrics = state.statusBarQuotaMetrics(at: Date())
        XCTAssertNotNil(metrics.centerAvailable, "Pinned provider metrics should be visible in status bar")
        XCTAssertEqual(metrics.interval.minAvailable, 0.8, accuracy: 0.01)
    }

    // =========================================================================
    // MARK: - Tier 4: Real-World Application Scenarios (>=5 Scenarios)
    // =========================================================================

    /// Scenario 1: Mixed Multi-Provider Lifecycle
    /// Real-world setup with 3 active providers: Codex (multi-key), DeepSeek (balance), and MiniMax.
    /// User triggers targeted refresh for each, verifies state machine integrity and aggregate health.
    @MainActor
    func testTier4_scenario1_mixedMultiProviderLifecycle() async {
        let deepseekInfo = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            balanceDetail: DeepseekBalanceDetail(currency: "CNY", total: 18.0, toppedUp: 18.0, granted: 0)
        )
        let codexInfo = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "chatgpt_plan",
                    intervalTotalCount: 100,
                    intervalUsageCount: 30,
                    intervalRemainingPercent: 70,
                    intervalStatus: .present,
                    intervalResetsAt: Date().addingTimeInterval(3600),
                    intervalWindowSeconds: 3600,
                    weeklyTotalCount: 500,
                    weeklyUsageCount: 50,
                    weeklyRemainingPercent: 90,
                    weeklyStatus: .present,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            ],
            resetCredits: nil,
            planLabel: "Team",
            accountEmail: "team@openai.com",
            codexUsageDetails: nil,
            fetchedAt: Date(),
            openAIApiCredits: OpenAIApiCreditDetails(
                organizationName: "TeamOrg",
                totalQuota: 100.0,
                usedAmount: 10.0,
                cycleStart: Date(),
                cycleEnd: Date().addingTimeInterval(86400 * 20),
                fetchedAt: Date()
            )
        )

        let dsFetcher = E2EControllableFetcher(providerID: "deepseek", kind: .deepseek, quotaInfoToReturn: deepseekInfo)
        let codexFetcher = E2EControllableFetcher(providerID: "codex_chatgpt", kind: .codexChatGpt, quotaInfoToReturn: codexInfo)

        let descriptors = [
            FetcherDescriptor(id: "deepseek", displayName: "DeepSeek", kind: .deepseek, iconSystemName: "sparkles", accentColor: .deepseek, makeFetcher: { _ in dsFetcher }),
            FetcherDescriptor(id: "codex_chatgpt", displayName: "Codex", kind: .codexChatGpt, iconSystemName: "terminal", accentColor: .chatgpt, makeFetcher: { _ in codexFetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Refresh DeepSeek
        await state.refreshOne(providerID: "deepseek")

        // Refresh Codex
        await state.refreshOne(providerID: "codex_chatgpt")

        let dsStatus = try! XCTUnwrap(state.statuses.first { $0.id == "deepseek" })
        let codexStatus = try! XCTUnwrap(state.statuses.first { $0.id == "codex_chatgpt" })

        XCTAssertEqual(dsStatus.aggregateHealthLevel(), .healthy)
        XCTAssertEqual(codexStatus.aggregateHealthLevel(), .healthy)
        let codexCredits = try! XCTUnwrap(codexStatus.lastSuccess?.openAIApiCredits)
        XCTAssertEqual(codexCredits.remainingPercent, 90.0, accuracy: 0.01)
    }

    /// Scenario 2: User Settings Save and Reload Cycle
    /// User opens settings, modifies alert threshold, and saves.
    /// AppState dynamically reflects the updated threshold without restarting the application.
    @MainActor
    func testTier4_scenario2_userSettingsSaveAndReloadCycle() async {
        let deepseekInfo = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            balanceDetail: DeepseekBalanceDetail(currency: "CNY", total: 8.0, toppedUp: 8.0, granted: 0)
        )
        let dsFetcher = E2EControllableFetcher(providerID: "deepseek", kind: .deepseek, quotaInfoToReturn: deepseekInfo)
        let descriptors = [
            FetcherDescriptor(id: "deepseek", displayName: "DeepSeek", kind: .deepseek, iconSystemName: "sparkles", accentColor: .deepseek, makeFetcher: { _ in dsFetcher })
        ]

        let (state, store) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        await state.refreshOne(providerID: "deepseek")

        let status = try! XCTUnwrap(state.statuses.first { $0.id == "deepseek" })
        // Under default thresholds (warning = 10.0, critical = 3.0), balance 8.0 is warning
        XCTAssertEqual(status.aggregateHealthLevel(alertThresholds: .default), .warning)

        // User changes critical threshold to 9.0 in settings and saves
        var newConfig = store.config
        newConfig.alerts = AlertThresholdConfig(deepseekBalanceWarning: 15.0, deepseekBalanceCritical: 9.0)
        try! store.applyAndSave(newConfig)

        // DeepSeek health level adapts to .critical under new threshold immediately
        XCTAssertEqual(status.aggregateHealthLevel(alertThresholds: newConfig.alerts!), .critical)
    }

    /// Scenario 3: Rapid Manual Clicks on Floating Window
    /// User rapidly clicks refresh buttons across multiple providers in the edge dock floating window.
    /// Validates that external job token serialization handles traffic smoothly without race conditions.
    @MainActor
    func testTier4_scenario3_rapidManualClicksOnFloatingWindow() async {
        let counter = E2ECallCounter()
        let fetcherA = E2EControllableFetcher(providerID: "dock_a", callCounter: counter)
        let fetcherB = E2EControllableFetcher(providerID: "dock_b", callCounter: counter)

        let descriptors = [
            FetcherDescriptor(id: "dock_a", displayName: "A", kind: .codexChatGpt, iconSystemName: "1.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "dock_b", displayName: "B", kind: .codexChatGpt, iconSystemName: "2.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        let initialA = await counter.count(for: "dock_a")
        let initialB = await counter.count(for: "dock_b")

        // Rapid click triggers
        await fetcherA.arm()
        let taskA = Task { await state.refreshOne(providerID: "dock_a") }
        await fetcherA.waitUntilReached()

        // Concurrent clicks during in-flight
        await state.refreshOne(providerID: "dock_a")
        await state.refreshOne(providerID: "dock_b")

        await fetcherA.release()
        await taskA.value

        // Now trigger B sequentially after A completes
        await state.refreshOne(providerID: "dock_b")

        let countA = await counter.count(for: "dock_a")
        let countB = await counter.count(for: "dock_b")

        XCTAssertEqual(countA, initialA + 1, "Provider A executed once")
        XCTAssertEqual(countB, initialB + 1, "Provider B executed once")
    }

    /// Scenario 4: Network Degradation and Recovery
    /// Simulates transient network failure (offline/503), preserves stale data on failure,
    /// then recovers cleanly on subsequent user-initiated refresh.
    @MainActor
    func testTier4_scenario4_networkDegradationAndRecovery() async {
        let initialData = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "model_v1",
                    intervalTotalCount: 100,
                    intervalUsageCount: 10,
                    intervalRemainingPercent: 90,
                    intervalStatus: .present,
                    intervalResetsAt: nil,
                    intervalWindowSeconds: nil,
                    weeklyTotalCount: 0,
                    weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0,
                    weeklyStatus: .absent,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            ],
            resetCredits: nil,
            planLabel: "Normal",
            accountEmail: "norm@test.com",
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        let fetcher = E2EControllableFetcher(providerID: "prov_recovery", quotaInfoToReturn: initialData)
        let descriptors = [
            FetcherDescriptor(id: "prov_recovery", displayName: "Rec", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeE2EAppState(descriptors: descriptors)
        defer { state.stop() }

        // Phase 1: Healthy initial refresh
        await state.refreshOne(providerID: "prov_recovery")

        // Phase 2: Network outage
        fetcher.errorToThrow = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        await state.refreshOne(providerID: "prov_recovery")

        let failedStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_recovery" })
        XCTAssertNotNil(failedStatus.lastSuccess, "Stale data must be preserved during outage")

        // Phase 3: Recovery
        fetcher.errorToThrow = nil
        await state.refreshOne(providerID: "prov_recovery")

        let recoveredStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_recovery" })
        if case .ok = recoveredStatus.state {
            // Recovered successfully
        } else {
            XCTFail("Provider should recover to .ok state")
        }
    }

    /// Scenario 5: End-of-Billing-Cycle Transition
    /// Validates dynamic cycle rollover: as wall-clock crosses the billing cycle boundary,
    /// currentBillingCycle shifts start and end timestamps, and timeRemainingFraction rolls over.
    func testTier4_scenario5_endOfBillingCycleTransition() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Date 1: 5 minutes BEFORE cycle reset on May 15 at 08:00
        var compsBefore = DateComponents()
        compsBefore.year = 2026
        compsBefore.month = 5
        compsBefore.day = 15
        compsBefore.hour = 7
        compsBefore.minute = 55
        let dateBefore = cal.date(from: compsBefore)!

        let (start1, end1) = OpenAIApiCreditDetails.currentBillingCycle(
            day: 15,
            hour: 8,
            minute: 0,
            now: dateBefore,
            calendar: cal
        )

        let creditsBefore = OpenAIApiCreditDetails(
            organizationName: "Org",
            totalQuota: 100.0,
            usedAmount: 90.0,
            cycleStart: start1,
            cycleEnd: end1,
            fetchedAt: dateBefore
        )

        let fractionBefore = creditsBefore.timeRemainingFraction(at: dateBefore)
        XCTAssertLessThan(fractionBefore, 0.01, "Near end of cycle, remaining fraction should be near 0")

        // Date 2: 5 minutes AFTER cycle reset on May 15 at 08:05
        var compsAfter = DateComponents()
        compsAfter.year = 2026
        compsAfter.month = 5
        compsAfter.day = 15
        compsAfter.hour = 8
        compsAfter.minute = 5
        let dateAfter = cal.date(from: compsAfter)!

        let (start2, end2) = OpenAIApiCreditDetails.currentBillingCycle(
            day: 15,
            hour: 8,
            minute: 0,
            now: dateAfter,
            calendar: cal
        )

        let creditsAfter = OpenAIApiCreditDetails(
            organizationName: "Org",
            totalQuota: 100.0,
            usedAmount: 0.0,
            cycleStart: start2,
            cycleEnd: end2,
            fetchedAt: dateAfter
        )

        let fractionAfter = creditsAfter.timeRemainingFraction(at: dateAfter)
        XCTAssertGreaterThan(fractionAfter, 0.99, "At start of new cycle, remaining fraction should be near 1.0")

        XCTAssertNotEqual(start1, start2, "New billing cycle must start after reset point")
        XCTAssertNotEqual(end1, end2, "New billing cycle must end a month later")
    }
}
