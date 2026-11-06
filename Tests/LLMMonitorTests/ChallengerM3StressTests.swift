import XCTest
import Foundation
import SwiftUI
@testable import LLM_monitor

/// Empirical adversarial stress test suite for Milestone 3:
/// Codex Multi-Key Quota Support (Requirement R3).
///
/// Tests:
/// 1. Multi-key concurrent error isolation matrix (HTTP 401, 429, 500 alongside 200).
/// 2. Total admin failure isolation (all keys fail, ChatGPT plan succeeds).
/// 3. Total ChatGPT plan failure isolation (plan fails, admin keys succeed).
/// 4. Result merger persistence across multi-key churn and background refresh.
/// 5. Boundary conditions on allowances, percentages, and clamping (0, negative, overspent).
/// 6. Extreme calendar rollover (day 31 in Feb leap/non-leap years, year transitions).
/// 7. Multi-key deterministic ordering under high concurrency.
/// 8. View body stress evaluation with boundary and degenerate quota models.
final class ChallengerM3StressTests: XCTestCase {

    // MARK: - URLProtocol Mock Fixture

    private final class MockURLProtocol: URLProtocol {
        struct Response: Sendable {
            let statusCode: Int
            let headers: [String: String]
            let body: Data

            init(statusCode: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data) {
                self.statusCode = statusCode
                self.headers = headers
                self.body = body
            }
        }

        nonisolated(unsafe) static var defaultResponses: [String: Response] = [:]
        nonisolated(unsafe) static var customHandler: (@Sendable (URLRequest) -> Response?)? = nil
        nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

        static func reset() {
            defaultResponses.removeAll()
            customHandler = nil
            capturedRequests.removeAll()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            Self.capturedRequests.append(request)

            let response: Response
            if let custom = Self.customHandler?(request) {
                response = custom
            } else if let r = Self.defaultResponses[url.path] {
                response = r
            } else {
                response = Response(statusCode: 404, body: Data("{\"error\": \"not found\"}".utf8))
            }

            let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        MockURLProtocol.defaultResponses["/v1/me"] = .init(
            statusCode: 200,
            body: Data("{\"object\": \"user\", \"id\": \"user-1\", \"orgs\": {\"data\": [{\"id\": \"org-1\", \"title\": \"Mock Org\"}]}}".utf8)
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAuthFile() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let authURL = tmp.appendingPathComponent("auth.json")
        let json = """
        {
          "tokens": {
            "access_token": "mock-token-xyz",
            "account_id": "mock-acct-123"
          }
        }
        """
        try json.data(using: .utf8)!.write(to: authURL)
        return authURL
    }

    private func makeCostsJSON(used: Double, orgName: String = "Test Org") -> Data {
        let result: [String: Any] = [
            "object": "organization.costs.result",
            "amount": [
                "currency": "usd",
                "value": used
            ],
            "line_item": NSNull(),
            "project_id": NSNull(),
            "organization_name": orgName
        ]
        let json: [String: Any] = [
            "object": "page",
            "data": [
                [
                    "object": "bucket",
                    "start_time": 1791676800,
                    "end_time": 1791763200,
                    "results": [result]
                ]
            ],
            "has_more": false
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func makeValidUsageJSON() -> Data {
        let json: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 20,
                    "limit_window_seconds": 1800,
                    "reset_at": 1_900_000_000
                ],
                "secondary_window": NSNull()
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func makeTestModel(name: String = "chatgpt_plan", percent: Double = 80.0) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: Int(100 - percent),
            intervalRemainingPercent: percent,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: 1800,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
    }

    // MARK: - 1. Multi-Key Error Isolation Matrix (4-Key Matrix: 401, 429, 500, 200)

    func testMultiKeyErrorIsolationMatrix() async throws {
        let authURL = try makeAuthFile()
        MockURLProtocol.defaultResponses["/backend-api/wham/usage"] = .init(
            statusCode: 200,
            body: makeValidUsageJSON()
        )
        MockURLProtocol.defaultResponses["/backend-api/wham/rate-limit-reset-credits"] = .init(
            statusCode: 200,
            body: Data("{\"available_count\": 0, \"total_earned\": 0}".utf8)
        )

        MockURLProtocol.customHandler = { request in
            guard let path = request.url?.path else { return nil }
            if path == "/v1/organization/costs" {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("key-401") {
                    return .init(statusCode: 401, body: Data("{\"error\": \"Unauthorized - Invalid API Key\"}".utf8))
                } else if auth.contains("key-429") {
                    return .init(statusCode: 429, body: Data("{\"error\": \"Rate limit exceeded - Try again later\"}".utf8))
                } else if auth.contains("key-500") {
                    return .init(statusCode: 500, body: Data("{\"error\": \"Internal server error\"}".utf8))
                } else if auth.contains("key-200") {
                    return .init(statusCode: 200, body: self.makeCostsJSON(used: 12.50, orgName: "Success Org"))
                }
            }
            return MockURLProtocol.defaultResponses[path]
        }

        let keys = [
            CodexAdminKeyConfig(id: "k-401", label: "BadAuth", apiKey: "key-401", monthlyQuotaLimit: 50.0),
            CodexAdminKeyConfig(id: "k-429", label: "RateLimited", apiKey: "key-429", monthlyQuotaLimit: 60.0),
            CodexAdminKeyConfig(id: "k-500", label: "Crashed", apiKey: "key-500", monthlyQuotaLimit: 70.0),
            CodexAdminKeyConfig(id: "k-200", label: "Healthy", apiKey: "key-200", monthlyQuotaLimit: 50.0)
        ]

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        let info = try await fetcher.fetch(mode: .full)

        // 1. QuotaInfo must not fail
        XCTAssertNil(info.mainQuotaError)
        XCTAssertEqual(info.models.first?.intervalRemainingPercent, 80.0)

        // 2. All 4 keys must be present in deterministic order
        XCTAssertEqual(info.allOpenAIApiCredits.count, 4)
        XCTAssertEqual(info.allOpenAIApiCredits.map(\.keyId), ["k-401", "k-429", "k-500", "k-200"])

        // 3. Key 401 failed
        let c401 = info.allOpenAIApiCredits[0]
        XCTAssertEqual(c401.lastAttemptFailed, true)
        XCTAssertNotNil(c401.errorMessage)
        XCTAssertTrue(c401.errorMessage?.contains("401") == true || c401.errorMessage?.contains("Unauthorized") == true)

        // 4. Key 429 failed
        let c429 = info.allOpenAIApiCredits[1]
        XCTAssertEqual(c429.lastAttemptFailed, true)
        XCTAssertNotNil(c429.errorMessage)
        XCTAssertTrue(c429.errorMessage?.contains("429") == true || c429.errorMessage?.contains("Rate limit") == true)

        // 5. Key 500 failed
        let c500 = info.allOpenAIApiCredits[2]
        XCTAssertEqual(c500.lastAttemptFailed, true)
        XCTAssertNotNil(c500.errorMessage)
        XCTAssertTrue(c500.errorMessage?.contains("500") == true || c500.errorMessage?.contains("Internal server error") == true)

        // 6. Key 200 succeeded with exact values
        let c200 = info.allOpenAIApiCredits[3]
        XCTAssertEqual(c200.lastAttemptFailed, false)
        XCTAssertNil(c200.errorMessage)
        XCTAssertEqual(c200.usedAmount, 12.50)
        XCTAssertEqual(c200.totalQuota, 50.0)
        XCTAssertEqual(c200.remainingAmount, 37.50)
        XCTAssertEqual(c200.remainingPercent, 75.0, accuracy: 0.001)

        // 7. Overall admin error must be nil because at least one key succeeded
        XCTAssertNil(info.openAIApiCreditsError)
    }

    // MARK: - 2. Total Admin Failure Isolation with ChatGPT Plan Success

    func testAllAdminKeysFailPreservesChatGPTPlan() async throws {
        let authURL = try makeAuthFile()
        MockURLProtocol.defaultResponses["/backend-api/wham/usage"] = .init(
            statusCode: 200,
            body: makeValidUsageJSON()
        )
        MockURLProtocol.defaultResponses["/backend-api/wham/rate-limit-reset-credits"] = .init(
            statusCode: 200,
            body: Data("{\"available_count\": 0, \"total_earned\": 0}".utf8)
        )

        MockURLProtocol.customHandler = { request in
            guard let path = request.url?.path else { return nil }
            if path == "/v1/organization/costs" {
                return .init(statusCode: 401, body: Data("{\"error\": \"Unauthorized\"}".utf8))
            }
            return MockURLProtocol.defaultResponses[path]
        }

        let keys = [
            CodexAdminKeyConfig(id: "k1", label: "Fail 1", apiKey: "key-1", monthlyQuotaLimit: 40.0),
            CodexAdminKeyConfig(id: "k2", label: "Fail 2", apiKey: "key-2", monthlyQuotaLimit: 80.0)
        ]

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        let info = try await fetcher.fetch(mode: .full)

        // ChatGPT Plan succeeds normally
        XCTAssertNil(info.mainQuotaError)
        XCTAssertEqual(info.models.first?.intervalRemainingPercent, 80.0)

        // Both keys marked failed
        XCTAssertEqual(info.allOpenAIApiCredits.count, 2)
        XCTAssertTrue(info.allOpenAIApiCredits.allSatisfy { $0.lastAttemptFailed == true })
        XCTAssertEqual(info.openAIApiCreditsError, "API赠金抓取失败")
    }

    // MARK: - 3. Total ChatGPT Plan Failure with Admin Keys Success

    func testPlanFailurePreservesAdminKeysSuccess() async throws {
        let authURL = try makeAuthFile()
        MockURLProtocol.defaultResponses["/backend-api/wham/usage"] = .init(
            statusCode: 500,
            body: Data("{\"error\": \"ChatGPT backend down\"}".utf8)
        )
        MockURLProtocol.defaultResponses["/backend-api/wham/rate-limit-reset-credits"] = .init(
            statusCode: 500,
            body: Data("{\"error\": \"Down\"}".utf8)
        )

        MockURLProtocol.customHandler = { request in
            guard let path = request.url?.path else { return nil }
            if path == "/v1/organization/costs" {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("k1") {
                    return .init(statusCode: 200, body: self.makeCostsJSON(used: 10.0, orgName: "Org 1"))
                } else if auth.contains("k2") {
                    return .init(statusCode: 200, body: self.makeCostsJSON(used: 20.0, orgName: "Org 2"))
                }
            }
            return MockURLProtocol.defaultResponses[path]
        }

        let keys = [
            CodexAdminKeyConfig(id: "k1", label: "Key 1", apiKey: "k1", monthlyQuotaLimit: 100.0),
            CodexAdminKeyConfig(id: "k2", label: "Key 2", apiKey: "k2", monthlyQuotaLimit: 200.0)
        ]

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        let info = try await fetcher.fetch(mode: .full)

        // Main quota has error message
        XCTAssertNotNil(info.mainQuotaError)
        XCTAssertTrue(info.models.isEmpty)

        // Admin keys successfully returned without disruption
        XCTAssertNil(info.openAIApiCreditsError)
        XCTAssertEqual(info.allOpenAIApiCredits.count, 2)

        let k1 = info.allOpenAIApiCredits[0]
        XCTAssertEqual(k1.keyId, "k1")
        XCTAssertEqual(k1.lastAttemptFailed, false)
        XCTAssertEqual(k1.usedAmount, 10.0)
        XCTAssertEqual(k1.totalQuota, 100.0)

        let k2 = info.allOpenAIApiCredits[1]
        XCTAssertEqual(k2.keyId, "k2")
        XCTAssertEqual(k2.lastAttemptFailed, false)
        XCTAssertEqual(k2.usedAmount, 20.0)
        XCTAssertEqual(k2.totalQuota, 200.0)
    }

    // MARK: - 4. Merger Multi-Key Persistence Across Churn

    func testMergerPreservesMultiKeyHistoricalDataAcrossChurn() {
        let merger = CodexFillingMissingMerger(adminApiCreditsEnabled: true)
        let now = Date()
        let cycleEnd = now.addingTimeInterval(30 * 86400)

        let prev = QuotaInfo(
            models: [makeTestModel(percent: 85.0)],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "user@example.com",
            codexUsageDetails: nil,
            fetchedAt: now,
            openAIApiCreditsList: [
                OpenAIApiCreditDetails(
                    organizationName: "Org Alpha",
                    totalQuota: 50.0,
                    usedAmount: 15.0,
                    cycleStart: now,
                    cycleEnd: cycleEnd,
                    fetchedAt: now,
                    lastAttemptFailed: false,
                    keyId: "k-alpha",
                    keyLabel: "Alpha"
                ),
                OpenAIApiCreditDetails(
                    organizationName: "Org Beta",
                    totalQuota: 100.0,
                    usedAmount: 40.0,
                    cycleStart: now,
                    cycleEnd: cycleEnd,
                    fetchedAt: now,
                    lastAttemptFailed: false,
                    keyId: "k-beta",
                    keyLabel: "Beta"
                )
            ]
        )

        // New refresh: Alpha succeeds with new used amount, Beta fails with 429
        let newlyFetched = QuotaInfo(
            models: [makeTestModel(percent: 80.0)],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "user@example.com",
            codexUsageDetails: nil,
            fetchedAt: now.addingTimeInterval(60),
            openAIApiCreditsList: [
                OpenAIApiCreditDetails(
                    organizationName: "Org Alpha",
                    totalQuota: 50.0,
                    usedAmount: 18.0,
                    cycleStart: now,
                    cycleEnd: cycleEnd,
                    fetchedAt: now.addingTimeInterval(60),
                    lastAttemptFailed: false,
                    keyId: "k-alpha",
                    keyLabel: "Alpha"
                ),
                OpenAIApiCreditDetails(
                    organizationName: "Org Beta",
                    totalQuota: 100.0,
                    usedAmount: 0.0,
                    cycleStart: now,
                    cycleEnd: cycleEnd,
                    fetchedAt: nil,
                    lastAttemptFailed: true,
                    keyId: "k-beta",
                    keyLabel: "Beta",
                    errorMessage: "HTTP 429 Too Many Requests"
                )
            ]
        )

        let merged = merger.merge(new: newlyFetched, previous: prev, mode: .background)

        XCTAssertEqual(merged.allOpenAIApiCredits.count, 2)

        // Alpha updated to 18.0
        let mAlpha = merged.allOpenAIApiCredits[0]
        XCTAssertEqual(mAlpha.keyId, "k-alpha")
        XCTAssertEqual(mAlpha.usedAmount, 18.0)
        XCTAssertEqual(mAlpha.lastAttemptFailed, false)

        // Beta preserved previous 40.0 used amount and marked stale with error
        let mBeta = merged.allOpenAIApiCredits[1]
        XCTAssertEqual(mBeta.keyId, "k-beta")
        XCTAssertEqual(mBeta.usedAmount, 40.0)
        XCTAssertEqual(mBeta.lastAttemptFailed, true)
        XCTAssertEqual(mBeta.errorMessage, "HTTP 429 Too Many Requests")
    }

    // MARK: - 5. Boundary Conditions on Quota Allowances & Clamping

    func testAllowanceAndPercentageBoundaryStress() {
        let now = Date()
        let cycleEnd = now.addingTimeInterval(30 * 86400)

        // 1. Zero Total Quota ($0)
        let zeroQuota = OpenAIApiCreditDetails(
            organizationName: "Zero",
            totalQuota: 0.0,
            usedAmount: 0.0,
            cycleStart: now,
            cycleEnd: cycleEnd
        )
        XCTAssertEqual(zeroQuota.remainingAmount, 0.0)
        XCTAssertEqual(zeroQuota.remainingPercent, 0.0)

        // 2. Negative Total Quota (-$50)
        let negQuota = OpenAIApiCreditDetails(
            organizationName: "Negative",
            totalQuota: -50.0,
            usedAmount: 10.0,
            cycleStart: now,
            cycleEnd: cycleEnd
        )
        XCTAssertEqual(negQuota.remainingAmount, 0.0)
        XCTAssertEqual(negQuota.remainingPercent, 0.0)

        // 3. Overspent ($150 used of $100 quota)
        let overspent = OpenAIApiCreditDetails(
            organizationName: "Overspent",
            totalQuota: 100.0,
            usedAmount: 150.0,
            cycleStart: now,
            cycleEnd: cycleEnd
        )
        XCTAssertEqual(overspent.remainingAmount, 0.0)
        XCTAssertEqual(overspent.remainingPercent, 0.0)

        // 4. Massive Overspent ($10,000 used of $50 quota)
        let massiveOverspent = OpenAIApiCreditDetails(
            organizationName: "Massive",
            totalQuota: 50.0,
            usedAmount: 10_000.0,
            cycleStart: now,
            cycleEnd: cycleEnd
        )
        XCTAssertEqual(massiveOverspent.remainingAmount, 0.0)
        XCTAssertEqual(massiveOverspent.remainingPercent, 0.0)

        // 5. Negative Used Amount (Refund / credit adjustment of -$20 on $100 quota)
        let refund = OpenAIApiCreditDetails(
            organizationName: "Refund",
            totalQuota: 100.0,
            usedAmount: -20.0,
            cycleStart: now,
            cycleEnd: cycleEnd
        )
        XCTAssertEqual(refund.remainingAmount, 120.0)
        // Percentage MUST clamp to 100.0%
        XCTAssertEqual(refund.remainingPercent, 100.0)

        // 6. Time Remaining Fraction Clamping
        let cStart = Date(timeIntervalSince1970: 10_000.0)
        let cEnd = Date(timeIntervalSince1970: 11_000.0)
        let timeCredit = OpenAIApiCreditDetails(
            organizationName: "Time",
            totalQuota: 100.0,
            usedAmount: 10.0,
            cycleStart: cStart,
            cycleEnd: cEnd
        )

        // Before start -> clamped to 1.0
        XCTAssertEqual(timeCredit.timeRemainingFraction(at: Date(timeIntervalSince1970: 9_000.0)), 1.0)
        // At start -> 1.0
        XCTAssertEqual(timeCredit.timeRemainingFraction(at: cStart), 1.0)
        // Midpoint -> 0.5
        XCTAssertEqual(timeCredit.timeRemainingFraction(at: Date(timeIntervalSince1970: 10_500.0)), 0.5, accuracy: 0.001)
        // At end -> 0.0
        XCTAssertEqual(timeCredit.timeRemainingFraction(at: cEnd), 0.0)
        // After end -> clamped to 0.0
        XCTAssertEqual(timeCredit.timeRemainingFraction(at: Date(timeIntervalSince1970: 12_000.0)), 0.0)

        // Degenerate end <= start
        let degenerateTime = OpenAIApiCreditDetails(
            organizationName: "Degen",
            totalQuota: 100.0,
            usedAmount: 10.0,
            cycleStart: cEnd,
            cycleEnd: cStart
        )
        XCTAssertEqual(degenerateTime.timeRemainingFraction(at: cStart), 0.0)
    }

    // MARK: - 6. Extreme Calendar Rollover Stress Tests

    func testExtremeCalendarRollovers() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Case A: Day 31 in Feb 2025 (Non-leap year, Feb has 28 days)
        let comp2025Feb = DateComponents(year: 2025, month: 2, day: 15, hour: 12)
        let feb15_2025 = cal.date(from: comp2025Feb)!

        let cycleFeb2025 = OpenAIApiCreditDetails.currentBillingCycle(
            day: 31,
            hour: 8,
            minute: 30,
            now: feb15_2025,
            calendar: cal
        )

        // Start should be Jan 31, 2025 at 08:30:00
        let expStartFeb2025 = cal.date(from: DateComponents(year: 2025, month: 1, day: 31, hour: 8, minute: 30, second: 0))!
        // End should be Feb 28, 2025 at 08:30:00 (clamped to 28)
        let expEndFeb2025 = cal.date(from: DateComponents(year: 2025, month: 2, day: 28, hour: 8, minute: 30, second: 0))!
        XCTAssertEqual(cycleFeb2025.start, expStartFeb2025)
        XCTAssertEqual(cycleFeb2025.end, expEndFeb2025)

        // After Feb 28 08:30 in non-leap year
        let feb28Night2025 = cal.date(from: DateComponents(year: 2025, month: 2, day: 28, hour: 20, minute: 0))!
        let cycleFeb28After = OpenAIApiCreditDetails.currentBillingCycle(
            day: 31,
            hour: 8,
            minute: 30,
            now: feb28Night2025,
            calendar: cal
        )
        // Start should now be Feb 28, 2025 08:30
        XCTAssertEqual(cycleFeb28After.start, expEndFeb2025)
        // End should be Mar 31, 2025 08:30
        let expEndMar2025 = cal.date(from: DateComponents(year: 2025, month: 3, day: 31, hour: 8, minute: 30, second: 0))!
        XCTAssertEqual(cycleFeb28After.end, expEndMar2025)

        // Case B: Day 31 in Feb 2024 (Leap year, Feb has 29 days)
        let comp2024Feb = DateComponents(year: 2024, month: 2, day: 15, hour: 12)
        let feb15_2024 = cal.date(from: comp2024Feb)!

        let cycleFeb2024 = OpenAIApiCreditDetails.currentBillingCycle(
            day: 31,
            hour: 10,
            minute: 0,
            now: feb15_2024,
            calendar: cal
        )
        let expStartFeb2024 = cal.date(from: DateComponents(year: 2024, month: 1, day: 31, hour: 10, minute: 0, second: 0))!
        let expEndFeb2024 = cal.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 10, minute: 0, second: 0))!
        XCTAssertEqual(cycleFeb2024.start, expStartFeb2024)
        XCTAssertEqual(cycleFeb2024.end, expEndFeb2024)

        // Case C: Year boundary transition (Dec 31 -> Jan 31)
        let dec31_2025 = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 18, minute: 0))!
        let cycleYearEnd = OpenAIApiCreditDetails.currentBillingCycle(
            day: 31,
            hour: 12,
            minute: 0,
            now: dec31_2025,
            calendar: cal
        )
        let expStartYearEnd = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 12, minute: 0, second: 0))!
        let expEndYearEnd = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12, minute: 0, second: 0))!
        XCTAssertEqual(cycleYearEnd.start, expStartYearEnd)
        XCTAssertEqual(cycleYearEnd.end, expEndYearEnd)

        // Case D: Extreme out-of-range parameters (negative and oversized day/hour/minute)
        let extremeCycle = OpenAIApiCreditDetails.currentBillingCycle(
            day: 999, // clamped to 31
            hour: 99, // clamped to 23
            minute: 99, // clamped to 59
            now: feb15_2025,
            calendar: cal
        )
        let expectedClampedStart = cal.date(from: DateComponents(year: 2025, month: 1, day: 31, hour: 23, minute: 59, second: 0))!
        let expectedClampedEnd = cal.date(from: DateComponents(year: 2025, month: 2, day: 28, hour: 23, minute: 59, second: 0))!
        XCTAssertEqual(extremeCycle.start, expectedClampedStart)
        XCTAssertEqual(extremeCycle.end, expectedClampedEnd)
    }

    // MARK: - 7. High-Concurrency Multi-Key Race Stress

    func testHighConcurrencyMultiKeyOrderingAndSafety() async throws {
        let authURL = try makeAuthFile()
        MockURLProtocol.defaultResponses["/backend-api/wham/usage"] = .init(
            statusCode: 200,
            body: makeValidUsageJSON()
        )
        MockURLProtocol.defaultResponses["/backend-api/wham/rate-limit-reset-credits"] = .init(
            statusCode: 200,
            body: Data("{\"available_count\": 0, \"total_earned\": 0}".utf8)
        )

        MockURLProtocol.customHandler = { request in
            guard let path = request.url?.path else { return nil }
            if path == "/v1/organization/costs" {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                for i in 0..<10 {
                    if auth.contains("key-stress-\(i)") {
                        if i % 3 == 0 {
                            return .init(statusCode: 429, body: Data("{\"error\": \"Rate limit\"}".utf8))
                        } else {
                            return .init(statusCode: 200, body: self.makeCostsJSON(used: Double(i * 5), orgName: "Org \(i)"))
                        }
                    }
                }
            }
            return MockURLProtocol.defaultResponses[path]
        }

        let keys = (0..<10).map { i in
            CodexAdminKeyConfig(
                id: "k-stress-\(i)",
                label: "Key \(i)",
                apiKey: "key-stress-\(i)",
                monthlyQuotaLimit: Double((i + 1) * 10)
            )
        }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            adminApiCreditsEnabled: true,
            adminApiKeys: keys,
            session: makeSession()
        )

        // Concurrently run 5 fetches to stress-test parallel execution
        try await withThrowingTaskGroup(of: QuotaInfo.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await fetcher.fetch(mode: .full)
                }
            }
            for try await info in group {
                XCTAssertEqual(info.allOpenAIApiCredits.count, 10)
                let ids = info.allOpenAIApiCredits.map(\.keyId)
                let expectedIds = (0..<10).map { "k-stress-\($0)" }
                XCTAssertEqual(ids, expectedIds, "Keys must maintain strict configuration order under concurrent resolution")

                for i in 0..<10 {
                    let k = info.allOpenAIApiCredits[i]
                    if i % 3 == 0 {
                        XCTAssertEqual(k.lastAttemptFailed, true)
                        XCTAssertNotNil(k.errorMessage)
                    } else {
                        XCTAssertEqual(k.lastAttemptFailed, false)
                        XCTAssertEqual(k.usedAmount, Double(i * 5))
                    }
                }
            }
        }
    }

    // MARK: - 8. View Body Evaluation Under Stress & Boundary Values

    func testChatGPTApiCreditsRowViewEvaluationWithAdversarialData() {
        let now = Date()
        let end = now.addingTimeInterval(86400)

        let cases: [OpenAIApiCreditDetails] = [
            // Zero limit
            OpenAIApiCreditDetails(organizationName: "Zero Org", totalQuota: 0.0, usedAmount: 0.0, cycleStart: now, cycleEnd: end),
            // Overspent
            OpenAIApiCreditDetails(organizationName: "Over Org", totalQuota: 50.0, usedAmount: 200.0, cycleStart: now, cycleEnd: end),
            // Huge string length
            OpenAIApiCreditDetails(
                organizationName: String(repeating: "A", count: 500),
                totalQuota: 100.0,
                usedAmount: 10.0,
                cycleStart: now,
                cycleEnd: end,
                keyLabel: String(repeating: "Label", count: 50)
            ),
            // Failed with long error message
            OpenAIApiCreditDetails(
                organizationName: "Err Org",
                totalQuota: 50.0,
                usedAmount: 0.0,
                cycleStart: now,
                cycleEnd: end,
                lastAttemptFailed: true,
                errorMessage: String(repeating: "Database timeout error. ", count: 20)
            )
        ]

        for (idx, credit) in cases.enumerated() {
            let row = ChatGPTApiCreditsRow(
                credits: credit,
                tint: .chatgptBrand,
                error: credit.errorMessage
            )
            // Access SwiftUI View body property to ensure evaluation produces no division by zero or fatal crashes
            let _ = row.body
            XCTAssertTrue(true, "Row #\(idx) evaluated successfully without fatal error")
        }
    }
}
