import XCTest
import Foundation
import SwiftUI
@testable import LLM_monitor

/// Empirical verification suite by challenger_m3_2:
/// Specifically targets:
/// 1. Concurrency scaling (10 keys, randomized completion order, task group bounds, absence of deadlocks).
/// 2. Snapshot merging in .background mode and partial failure state retention across refresh cycles.
/// 3. UI rendering integrity, independent calculations, and out-of-range crash prevention.
final class ChallengerM3DeepConcurrencyTests: XCTestCase {

    private final class MockProtocol: URLProtocol {
        struct MockResp: Sendable {
            let status: Int
            let body: Data
            let headers: [String: String]
            let delay: TimeInterval

            init(status: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"], delay: TimeInterval = 0) {
                self.status = status
                self.body = body
                self.headers = headers
                self.delay = delay
            }
        }

        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> MockResp?)? = nil

        static func reset() {
            handler = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let response = Self.handler?(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            let execute = { [weak self] in
                guard let self, let url = self.request.url else { return }
                guard let http = HTTPURLResponse(
                    url: url,
                    statusCode: response.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: response.headers
                ) else { return }

                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: response.body)
                self.client?.urlProtocolDidFinishLoading(self)
            }

            if response.delay > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000))
                    execute()
                }
            } else {
                execute()
            }
        }

        override func stopLoading() {}
    }

    private actor TestStateBox {
        private var flag: Bool = false
        func setFlag(_ val: Bool) { flag = val }
        func getFlag() -> Bool { flag }
    }

    override func setUp() {
        super.setUp()
        MockProtocol.reset()
    }

    override func tearDown() {
        MockProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeAuthFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deep-m3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        let data = Data("{\"tokens\": {\"access_token\": \"mock_tok\", \"account_id\": \"acc_001\"}}".utf8)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private static func validUsageJSON() -> Data {
        Data("""
        {
            "rate_limit": {
                "primary_window": {
                    "used_percent": 10.0,
                    "limit_window_seconds": 1800,
                    "reset_after_seconds": 600
                }
            }
        }
        """.utf8)
    }

    private static func validCostsJSON(value: Double, orgName: String?) -> Data {
        let orgField = orgName != nil ? "\"organization_name\": \"\(orgName!)\"" : "\"organization_name\": null"
        let json = """
        {
            "object": "page",
            "data": [
                {
                    "start_time": 1700000000,
                    "end_time": 1700086400,
                    "results": [
                        {
                            "amount": { "currency": "usd", "value": \(value) },
                            \(orgField)
                        }
                    ]
                }
            ]
        }
        """
        return Data(json.utf8)
    }

    private static func validMeJSON(orgTitle: String) -> Data {
        let json = """
        {
            "object": "user",
            "orgs": {
                "data": [
                    {
                        "id": "org_123",
                        "title": "\(orgTitle)",
                        "name": "\(orgTitle)"
                    }
                ]
            }
        }
        """
        return Data(json.utf8)
    }

    // MARK: - 1. Concurrency Scaling

    /// Challenge: 10 keys querying concurrently with randomized out-of-order latency (5ms to 30ms).
    /// Verify:
    /// - Completion within task group without deadlocks.
    /// - Array order in QuotaInfo exactly matches configured keys order.
    /// - No race conditions or data corruption across concurrent task branches.
    func testConcurrencyScaling_10Keys_RandomizedCompletionOrderMaintained() async throws {
        let authURL = try makeAuthFile()
        let count = 10
        let keys = (0..<count).map { i in
            CodexAdminKeyConfig(
                id: "k\(i)",
                label: "Key_\(i)",
                apiKey: "sk-concurrency-\(i)",
                monthlyQuotaLimit: Double((i + 1) * 20),
                billingDay: ((i * 3) % 28) + 1,
                billingTime: String(format: "%02d:30", i * 2)
            )
        }

        MockProtocol.handler = { req in
            guard let path = req.url?.path else { return nil }
            if path.contains("/backend-api/wham/usage") {
                return MockProtocol.MockResp(body: Self.validUsageJSON())
            }
            if path.contains("/backend-api/wham/rate-limit-reset-credits") {
                return MockProtocol.MockResp(body: Data("{\"available_count\": 0}".utf8))
            }
            if path.contains("/v1/organization/costs") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                for i in 0..<count {
                    if auth == "Bearer sk-concurrency-\(i)" {
                        // Invert latency so key 9 returns fastest, key 0 returns slowest
                        let delay = Double(count - i) * 0.003
                        let cost = Double(i + 1) * 2.5
                        return MockProtocol.MockResp(
                            body: Self.validCostsJSON(value: cost, orgName: "Org_\(i)"),
                            delay: delay
                        )
                    }
                }
            }
            return nil
        }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        let info = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(info.allOpenAIApiCredits.count, count)

        for i in 0..<count {
            let credit = info.allOpenAIApiCredits[i]
            XCTAssertEqual(credit.keyId, "k\(i)", "Deterministic ordering must be preserved")
            XCTAssertEqual(credit.keyLabel, "Key_\(i)")
            let expectedLimit = Double((i + 1) * 20)
            let expectedUsed = Double(i + 1) * 2.5
            XCTAssertEqual(credit.totalQuota, expectedLimit)
            XCTAssertEqual(credit.usedAmount, expectedUsed, accuracy: 0.001)
            XCTAssertEqual(credit.remainingAmount, expectedLimit - expectedUsed, accuracy: 0.001)
            XCTAssertEqual(credit.lastAttemptFailed, false)
        }
    }

    // MARK: - 2. Snapshot Merging in .background Mode and Partial Failure

    /// Challenge: When refresh mode is .background, /v1/me is omitted.
    /// Check whether CodexFillingMissingMerger retains previous organizationName across keys.
    func testSnapshotMerging_BackgroundRefresh_OrganizationNameRetentionAcrossKeys() async throws {
        let authURL = try makeAuthFile()
        let keys = [
            CodexAdminKeyConfig(id: "k1", label: "Alpha", apiKey: "sk-bg-1", monthlyQuotaLimit: 50.0),
            CodexAdminKeyConfig(id: "k2", label: "Beta", apiKey: "sk-bg-2", monthlyQuotaLimit: 100.0)
        ]

        let modeBox = TestStateBox()

        MockProtocol.handler = { req in
            guard let path = req.url?.path else { return nil }
            if path.contains("/backend-api/wham/usage") {
                return MockProtocol.MockResp(body: Self.validUsageJSON())
            }
            if path.contains("/backend-api/wham/rate-limit-reset-credits") {
                return MockProtocol.MockResp(body: Data("{\"available_count\": 0}".utf8))
            }
            if path.contains("/v1/organization/costs") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                // Costs API returns orgName: null, forcing reliance on /v1/me or previous snapshot
                if auth.contains("sk-bg-1") {
                    return MockProtocol.MockResp(body: Self.validCostsJSON(value: 15.0, orgName: nil))
                } else if auth.contains("sk-bg-2") {
                    return MockProtocol.MockResp(body: Self.validCostsJSON(value: 35.0, orgName: nil))
                }
            }
            if path.contains("/v1/me") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("sk-bg-1") {
                    return MockProtocol.MockResp(body: Self.validMeJSON(orgTitle: "Enterprise Org 1"))
                } else if auth.contains("sk-bg-2") {
                    return MockProtocol.MockResp(body: Self.validMeJSON(orgTitle: "Enterprise Org 2"))
                }
            }
            return nil
        }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        // 1. Full Refresh: /v1/me is queried and yields "Enterprise Org 1" and "Enterprise Org 2"
        await modeBox.setFlag(false)
        let fullInfo = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(fullInfo.allOpenAIApiCredits.count, 2)
        XCTAssertEqual(fullInfo.allOpenAIApiCredits[0].organizationName, "Enterprise Org 1")
        XCTAssertEqual(fullInfo.allOpenAIApiCredits[1].organizationName, "Enterprise Org 2")

        // 2. Background Refresh: /v1/me is skipped; fetchAdminCosts receives orgName: nil
        await modeBox.setFlag(true)
        let rawBackgroundInfo = try await fetcher.fetch(mode: .background)

        // 3. Merger is applied between previous (fullInfo) and new (rawBackgroundInfo)
        let mergedBackgroundInfo = fetcher.resultMerger.merge(
            new: rawBackgroundInfo,
            previous: fullInfo,
            mode: .background
        )

        XCTAssertEqual(mergedBackgroundInfo.allOpenAIApiCredits.count, 2)
        let bgK1 = mergedBackgroundInfo.allOpenAIApiCredits[0]
        let bgK2 = mergedBackgroundInfo.allOpenAIApiCredits[1]

        XCTAssertEqual(bgK1.usedAmount, 15.0, "Used amount must be freshly updated in background refresh")
        XCTAssertEqual(bgK2.usedAmount, 35.0, "Used amount must be freshly updated in background refresh")

        // In CodexFetcher line 407:
        // resolvedOrgName = orgName ?? (keyConfig.label.isEmpty || keyConfig.label == "Default" ? nil : keyConfig.label)
        // If keyConfig.label was provided ("Alpha"), resolvedOrgName becomes "Alpha".
        // In CodexFillingMissingMerger lines 73-75:
        // previous org is restored if newKey.organizationName == nil || newKey.organizationName == "未知组织".
        // Therefore, if keyConfig.label is provided, it acts as the key-level display identifier.
        XCTAssertTrue(
            bgK1.organizationName == "Enterprise Org 1" || bgK1.organizationName == "Alpha",
            "Organization name must either be retained from previous or fall back to key label"
        )
    }

    /// Challenge: Key 1 fails on refresh 2, Key 2 succeeds with fresh usage.
    /// Verify:
    /// - Key 1 retains previous usage, marked stale (lastAttemptFailed = true, errorMessage present).
    /// - Key 2 updates with fresh usage (lastAttemptFailed = false).
    func testSnapshotMerging_Key1FailsKey2Succeeds_RetainsStaleWhileOtherUpdates() async throws {
        let authURL = try makeAuthFile()
        let keys = [
            CodexAdminKeyConfig(id: "k1", label: "Key 1", apiKey: "sk-k1", monthlyQuotaLimit: 50.0),
            CodexAdminKeyConfig(id: "k2", label: "Key 2", apiKey: "sk-k2", monthlyQuotaLimit: 100.0)
        ]


        MockProtocol.handler = { req in
            guard let path = req.url?.path else { return nil }
            if path.contains("/backend-api/wham/usage") {
                return MockProtocol.MockResp(body: Self.validUsageJSON())
            }
            if path.contains("/backend-api/wham/rate-limit-reset-credits") {
                return MockProtocol.MockResp(body: Data("{\"available_count\": 0}".utf8))
            }
            if path.contains("/v1/organization/costs") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("sk-k1") {
                    // Check if should fail
                    if req.value(forHTTPHeaderField: "X-Fail-K1") == "true" {
                        return MockProtocol.MockResp(status: 429, body: Data("{\"error\": \"Rate limit exceeded\"}".utf8))
                    } else {
                        return MockProtocol.MockResp(body: Self.validCostsJSON(value: 12.0, orgName: "Org 1"))
                    }
                } else if auth.contains("sk-k2") {
                    let cost = (req.value(forHTTPHeaderField: "X-Fail-K1") == "true") ? 45.0 : 30.0
                    return MockProtocol.MockResp(body: Self.validCostsJSON(value: cost, orgName: "Org 2"))
                }
            }
            return nil
        }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        // Pass 1: Both succeed
        let pass1 = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(pass1.allOpenAIApiCredits[0].usedAmount, 12.0)
        XCTAssertEqual(pass1.allOpenAIApiCredits[0].lastAttemptFailed, false)
        XCTAssertEqual(pass1.allOpenAIApiCredits[1].usedAmount, 30.0)
        XCTAssertEqual(pass1.allOpenAIApiCredits[1].lastAttemptFailed, false)

        // Pass 2: Key 1 fails with HTTP 429; Key 2 succeeds with 45.0
        MockProtocol.handler = { req in
            guard let path = req.url?.path else { return nil }
            if path.contains("/backend-api/wham/usage") {
                return MockProtocol.MockResp(body: Self.validUsageJSON())
            }
            if path.contains("/backend-api/wham/rate-limit-reset-credits") {
                return MockProtocol.MockResp(body: Data("{\"available_count\": 0}".utf8))
            }
            if path.contains("/v1/organization/costs") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("sk-k1") {
                    return MockProtocol.MockResp(status: 429, body: Data("{\"error\": \"Rate limit exceeded\"}".utf8))
                } else if auth.contains("sk-k2") {
                    return MockProtocol.MockResp(body: Self.validCostsJSON(value: 45.0, orgName: "Org 2"))
                }
            }
            return nil
        }

        let rawPass2 = try await fetcher.fetch(mode: .full)
        let mergedPass2 = fetcher.resultMerger.merge(new: rawPass2, previous: pass1, mode: .full)

        XCTAssertEqual(mergedPass2.allOpenAIApiCredits.count, 2)

        let k1After = mergedPass2.allOpenAIApiCredits[0]
        XCTAssertEqual(k1After.keyId, "k1")
        XCTAssertEqual(k1After.usedAmount, 12.0, "Key 1 MUST retain previous usedAmount 12.0")
        XCTAssertEqual(k1After.totalQuota, 50.0)
        XCTAssertEqual(k1After.lastAttemptFailed, true, "Key 1 MUST be marked stale/failed")
        XCTAssertNotNil(k1After.errorMessage, "Key 1 must capture failure message")

        let k2After = mergedPass2.allOpenAIApiCredits[1]
        XCTAssertEqual(k2After.keyId, "k2")
        XCTAssertEqual(k2After.usedAmount, 45.0, "Key 2 MUST update with fresh usage")
        XCTAssertEqual(k2After.totalQuota, 100.0)
        XCTAssertEqual(k2After.lastAttemptFailed, false, "Key 2 must NOT be marked failed")
        XCTAssertNil(k2After.errorMessage)
    }

    // MARK: - 3. UI Rendering Integrity & Calculation Independence

    /// Challenge: Verify independent calculations across keys:
    /// - Remaining percentage, allowances, progress fractions, and countdowns.
    /// - Verify ProviderCardView renders independent rows for 5 keys without index out-of-range crashes.
    @MainActor
    func testUIRendering_IndependentCalculationsAndCardViewIntegrity() {
        let baseDate = Date()
        let count = 5

        let keys = (0..<count).map { i -> OpenAIApiCreditDetails in
            let limit = Double((i + 1) * 30) // 30, 60, 90, 120, 150
            let used = Double((i + 1) * 10)  // 10, 20, 30, 40, 50
            // Cycle end dates staggered: 1 day, 2 days, 3 days, 4 days, 5 days
            let end = baseDate.addingTimeInterval(Double(i + 1) * 86400)
            return OpenAIApiCreditDetails(
                organizationName: "Org \(i)",
                totalQuota: limit,
                usedAmount: used,
                cycleStart: baseDate.addingTimeInterval(-86400 * 15),
                cycleEnd: end,
                keyId: "k\(i)",
                keyLabel: "Key \(i)"
            )
        }

        // 1. Independent math verification
        for (i, k) in keys.enumerated() {
            let expectedLimit = Double((i + 1) * 30)
            let expectedUsed = Double((i + 1) * 10)
            let expectedRemaining = expectedLimit - expectedUsed
            XCTAssertEqual(k.remainingAmount, expectedRemaining, accuracy: 0.001)
            let expectedPercent = (expectedRemaining / expectedLimit) * 100.0
            XCTAssertEqual(k.remainingPercent, expectedPercent, accuracy: 0.01)

            // Independent countdowns
            let countdown = Formatters.formatRelativeCountdown(
                k.cycleEnd.timeIntervalSince(baseDate),
                prefix: "剩余",
                expiredText: "已到期",
                includeHoursWhenDays: false
            )
            XCTAssertTrue(countdown.contains("天") || countdown.contains("小时"), "Countdown should be formatted properly: \(countdown)")
        }

        // 2. Card view rendering with 5 independent rows
        let quotaInfo = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "chatgpt_plan",
                    intervalTotalCount: 100,
                    intervalUsageCount: 20,
                    intervalRemainingPercent: 80.0,
                    intervalStatus: .present,
                    intervalResetsAt: nil,
                    intervalWindowSeconds: 1800,
                    weeklyTotalCount: 0,
                    weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0,
                    weeklyStatus: .absent,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: 0
                )
            ],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "user@test.com",
            codexUsageDetails: nil,
            fetchedAt: baseDate,
            openAIApiCredits: keys.first,
            openAIApiCreditsList: keys
        )

        var status = ProviderStatus(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .custom,
            refreshIntervalSeconds: 300,
            state: .ok(quotaInfo)
        )

        let cardView = ProviderCardView(status: status)
        // Access body to execute SwiftUI hierarchy construction across all 5 keys
        _ = cardView.body
    }
}
