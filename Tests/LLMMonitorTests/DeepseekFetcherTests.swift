import XCTest
import Foundation
@testable import LLM_monitor

final class DeepseekFetcherTests: XCTestCase {

    private final class StubURLProtocol: URLProtocol {
        struct Response {
            let statusCode: Int
            let headers: [String: String]
            let body: Data
        }
        nonisolated(unsafe) static var response: Response?
        nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]

        static func reset() {
            response = nil
            capturedHeaders.removeAll()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url, let response = Self.response else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
            let httpResponse = HTTPURLResponse(
                url: requestURL,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDeepseekFetcherParsesBalanceResponse() async throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.50",
              "granted_balance": "10.00",
              "topped_up_balance": "90.50"
            }
          ]
        }
        """.data(using: .utf8)!

        StubURLProtocol.response = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: json
        )

        let fetcher = DeepseekFetcher(
            apiKey: "sk-test-key-123456",
            session: makeSession()
        )

        let info = try await fetcher.fetch()
        XCTAssertEqual(info.models.count, 1)
        XCTAssertEqual(info.models.first?.modelName, "deepseek_balance")
        XCTAssertEqual(info.planLabel, "¥100.50")
        // R7: 余额明细走结构化字段，accountEmail 不再被占用。
        XCTAssertNil(info.accountEmail, "DeepSeek 余额不得占用 accountEmail")
        let detail = try XCTUnwrap(info.balanceDetail)
        XCTAssertEqual(detail.currency, "CNY")
        XCTAssertEqual(detail.total, 100.50, accuracy: 0.001)
        XCTAssertEqual(detail.toppedUp, 90.50, accuracy: 0.001)
        XCTAssertEqual(detail.granted, 10.00, accuracy: 0.001)
        XCTAssertEqual(detail.symbol, "¥")
        XCTAssertEqual(StubURLProtocol.capturedHeaders["Authorization"], "Bearer sk-test-key-123456")
    }

    func testDeepseekFetcherHandlesUnavailableAccount() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "0.00",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """.data(using: .utf8)!

        let info = try DeepseekFetcher.parse(data: json)
        XCTAssertEqual(info.models.first?.intervalRemainingPercent, 0)
        XCTAssertEqual(info.planLabel, "$0.00")
        XCTAssertEqual(info.balanceDetail?.currency, "USD")
        XCTAssertEqual(info.balanceDetail?.symbol, "$")
        XCTAssertEqual(info.balanceDetail?.granted ?? -1, 0, accuracy: 0.001)
    }

    func testDeepseekFetcherRejectsNonFiniteBalance() throws {
        let json = Data("""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "NaN",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """.utf8)

        XCTAssertThrowsError(try DeepseekFetcher.parse(data: json)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - API Key 缺失

    /// 空 / 全空白 API Key → `QuotaError.missingAPIKey`，且根本不该发起 HTTP 请求。
    func testDeepseekFetcherMissingAPIKeyThrowsBeforeAnyRequest() async throws {
        StubURLProtocol.response = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )

        let fetcher = DeepseekFetcher(
            apiKey: "   \n\t ",
            session: makeSession()
        )

        do {
            _ = try await fetcher.fetch()
            XCTFail("expected QuotaError.missingAPIKey")
        } catch let error as QuotaError {
            guard case .missingAPIKey = error else {
                XCTFail("expected .missingAPIKey, got \(error)")
                return
            }
        }
        XCTAssertTrue(
            StubURLProtocol.capturedHeaders.isEmpty,
            "API Key 缺失时不应发起任何 HTTP 请求"
        )
    }

    // MARK: - 响应 Schema 缺失

    /// `is_available` 有但 `balance_infos` 缺失 → `decodingError`（不要静默返回空余额）。
    func testDeepseekFetcherMissingBalanceInfosThrowsDecodingError() throws {
        let json = Data("""
        { "is_available": true }
        """.utf8)

        XCTAssertThrowsError(try DeepseekFetcher.parse(data: json)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    /// `balance_infos` 是空数组 → 同样视为无余额条目，抛 `decodingError`。
    func testDeepseekFetcherEmptyBalanceInfosThrowsDecodingError() throws {
        let json = Data("""
        { "is_available": true, "balance_infos": [] }
        """.utf8)

        XCTAssertThrowsError(try DeepseekFetcher.parse(data: json)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - JSON 畸形

    /// 响应不是合法 JSON → `decodingError`。
    func testDeepseekFetcherMalformedJSONThrowsDecodingError() throws {
        XCTAssertThrowsError(try DeepseekFetcher.parse(data: Data("not-json".utf8))) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - HTTP 错误

    /// 非 2xx → `QuotaError.httpError(status, body)`。
    func testDeepseekFetcherHTTPErrorThrows() async throws {
        StubURLProtocol.response = .init(
            statusCode: 500,
            headers: ["Content-Type": "text/plain"],
            body: Data("internal error".utf8)
        )

        let fetcher = DeepseekFetcher(
            apiKey: "sk-test-key-123456",
            session: makeSession()
        )

        do {
            _ = try await fetcher.fetch()
            XCTFail("expected QuotaError.httpError(500)")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                XCTFail("expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
        }
    }

    /// 401 → `httpError(401)`，再走 `userFacingDescription` 映射为 DeepSeek 专属文案。
    func testDeepseekFetcher401MapsToFriendlyAuthError() async throws {
        StubURLProtocol.response = .init(
            statusCode: 401,
            headers: ["Content-Type": "text/plain"],
            body: Data("unauthorized".utf8)
        )

        let fetcher = DeepseekFetcher(
            apiKey: "sk-test-key-123456",
            session: makeSession()
        )

        do {
            _ = try await fetcher.fetch()
            XCTFail("expected QuotaError.httpError(401)")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                XCTFail("expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(
                QuotaError.userFacingDescription(for: error, providerKind: .deepseek),
                "DeepSeek API Key 无效或已过期"
            )
        }
    }

    // MARK: - 取消路径

    /// 任务被取消 → fetch 透传 `CancellationError` / `URLError.cancelled`，
    /// 不包装成 `networkError`（上层 AppState 走 .deferred，不计 failure）。
    func testDeepseekFetcherCancellationPropagates() async {
        StubURLProtocol.response = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )

        let fetcher = DeepseekFetcher(
            apiKey: "sk-test-key-123456",
            session: makeSession()
        )

        let task = Task<Bool, Never> {
            do {
                _ = try await fetcher.fetch()
                return false
            } catch is CancellationError {
                return true
            } catch let error as URLError where error.code == .cancelled {
                return true
            } catch {
                return false
            }
        }
        task.cancel()

        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled, "fetch 应透传 CancellationError / URLError.cancelled")
    }

    // MARK: - R7: balanceDetail 结构化 + Codable 向后兼容

    /// 零赠金：granted=0 也能正常解析并展示。
    func testR7ZeroGrantedBalanceParsed() throws {
        let json = Data("""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "50.00", "granted_balance": "0.00", "topped_up_balance": "50.00" }
          ]
        }
        """.utf8)
        let info = try DeepseekFetcher.parse(data: json)
        XCTAssertEqual(info.balanceDetail?.granted ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(info.balanceDetail?.toppedUp ?? -1, 50, accuracy: 0.001)
    }

    /// 旧版 QuotaInfo 编码（无 balanceDetail 字段）能解码，balanceDetail 为 nil。
    func testR7QuotaInfoCodableBackwardCompat() throws {
        let oldJSON = """
        {"models":[],"resetCredits":null,"planLabel":"x","accountEmail":null,"codexUsageDetails":null,"fetchedAt":"2026-08-12T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(QuotaInfo.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.balanceDetail, "旧数据缺省 balanceDetail 为 nil")
    }

    /// balanceDetail round-trip 编解码。
    func testR7BalanceDetailRoundTrip() throws {
        let info = QuotaInfo(
            models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 1),
            balanceDetail: DeepseekBalanceDetail(currency: "USD", total: 12.5, toppedUp: 10, granted: 2.5)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(info)
        let decoded = try decoder.decode(QuotaInfo.self, from: data)
        XCTAssertEqual(decoded.balanceDetail, info.balanceDetail)
        XCTAssertEqual(decoded.balanceDetail?.symbol, "$")
    }
}
