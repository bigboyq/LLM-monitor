import XCTest
@testable import LLM_monitor

/// R2: HTTP/RPC 响应体硬上限测试。
/// 直接验证 CappedDownloadDelegate 的累计/上限/提前拒绝逻辑（cap 机制的核心），
/// 并用 URLProtocol 覆盖正常交付路径（恰好等于上限、低于上限、非 2xx）。
final class ResponseCapTests: XCTestCase {

    /// 可注入响应的测试 URLProtocol，用于正常交付路径（不测 cancel race）。
    private final class TestURLProtocol: URLProtocol {
        static var responder: ((TestURLProtocol) -> Void)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            TestURLProtocol.responder?(self)
        }
        override func stopLoading() {}

        func send(status: Int, body: Data, contentLength: Int?) {
            var headers: [String: String] = [:]
            if let contentLength { headers["Content-Length"] = String(contentLength) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let testURL = URL(string: "https://example.com/quota")!
    private let redacted = "https://example.com/quota"

    // MARK: - cap 机制（直接测 delegate）

    /// 分块累计超过上限 → delegate 标记 overflow 并取消 task。
    func testDelegateOverflowCancelsTask() {
        let delegate = CappedDownloadDelegate(maxBytes: 1_000_000, redactedPath: redacted)
        let task = URLSession.shared.dataTask(with: testURL)
        XCTAssertEqual(task.state, .suspended)
        // 投递一个超过上限的块
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0x41, count: 1_500_000))
        XCTAssertTrue(delegate.overflowed)
        XCTAssertEqual(delegate.receivedBytes, 1_500_000)
        XCTAssertNotEqual(task.state, .suspended, "超上限应取消 data task（非 resumed 任务取消后转 .completed）")
    }

    /// 多块累计：前几块未超，最后一块超出 → 在超出那块取消。
    func testDelegateChunkedOverflow() {
        let delegate = CappedDownloadDelegate(maxBytes: 1_000, redactedPath: redacted)
        let task = URLSession.shared.dataTask(with: testURL)
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0x41, count: 600))
        XCTAssertFalse(delegate.overflowed)
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0x41, count: 300))
        XCTAssertFalse(delegate.overflowed, "600+300=900 未超 1000")
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0x41, count: 200))
        XCTAssertTrue(delegate.overflowed, "900+200=1100 超 1000")
        XCTAssertNotEqual(task.state, .suspended)
    }

    /// 恰好等于上限不触发 overflow。
    func testDelegateAtExactLimitDoesNotOverflow() {
        let delegate = CappedDownloadDelegate(maxBytes: 1_000, redactedPath: redacted)
        let task = URLSession.shared.dataTask(with: testURL)
        delegate.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 0x41, count: 1_000))
        XCTAssertFalse(delegate.overflowed, "恰好等于上限不应算 overflow")
        XCTAssertEqual(task.state, .suspended, "未超上限不取消")
    }

    /// Content-Length 声明超上限 → 提前拒绝（completionHandler(.cancel)）。
    func testDelegateDeclaredContentLengthEarlyReject() {
        let delegate = CappedDownloadDelegate(maxBytes: 1_000_000, redactedPath: redacted)
        let task = URLSession.shared.dataTask(with: testURL)
        let response = HTTPURLResponse(
            url: testURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "5000000"])!
        var disposition: URLSession.ResponseDisposition = .allow
        delegate.urlSession(.shared, dataTask: task, didReceive: response) { disposition = $0 }
        XCTAssertTrue(delegate.declaredTooLarge, "Content-Length 超上限应提前拒绝")
        XCTAssertEqual(disposition, .cancel)
    }

    /// Content-Length 未超 → 放行。
    func testDelegateDeclaredContentLengthAllowed() {
        let delegate = CappedDownloadDelegate(maxBytes: 1_000_000, redactedPath: redacted)
        let task = URLSession.shared.dataTask(with: testURL)
        let response = HTTPURLResponse(
            url: testURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "500"])!
        var disposition: URLSession.ResponseDisposition = .cancel
        delegate.urlSession(.shared, dataTask: task, didReceive: response) { disposition = $0 }
        XCTAssertFalse(delegate.declaredTooLarge)
        XCTAssertEqual(disposition, .allow)
    }

    // MARK: - 正常交付路径（URLProtocol）

    /// 恰好等于上限 → 允许通过。
    func testAllowsBodyExactlyAtLimit() async throws {
        let session = makeSession()
        TestURLProtocol.responder = { proto in
            proto.send(status: 200, body: Data(repeating: 0x41, count: 1_000_000), contentLength: nil)
        }
        let (data, http) = try await CappedDownloader.data(
            for: URLRequest(url: testURL), session: session, maxBytes: 1_000_000, redactedPath: redacted
        )
        XCTAssertEqual(data.count, 1_000_000)
        XCTAssertEqual(http.statusCode, 200)
    }

    /// 小于上限 → 正常返回。
    func testAllowsBodyUnderLimit() async throws {
        let session = makeSession()
        TestURLProtocol.responder = { proto in
            proto.send(status: 200, body: Data(repeating: 0x41, count: 100), contentLength: 100)
        }
        let (data, _) = try await CappedDownloader.data(
            for: URLRequest(url: testURL), session: session, maxBytes: 1_000_000, redactedPath: redacted
        )
        XCTAssertEqual(data.count, 100)
    }

    /// 非 2xx → CappedDownloader 仍返回响应（HTTPClient.send 层翻译为 httpError）。
    func testNon2xxReturnedAsResponse() async throws {
        let session = makeSession()
        TestURLProtocol.responder = { proto in
            proto.send(status: 503, body: Data("err".utf8), contentLength: 3)
        }
        let (data, http) = try await CappedDownloader.data(
            for: URLRequest(url: testURL), session: session, maxBytes: 1_000_000, redactedPath: redacted
        )
        XCTAssertEqual(http.statusCode, 503)
        XCTAssertEqual(String(data: data, encoding: .utf8), "err")
    }

    // MARK: - 常量与默认值

    func testHTTPClientDefaultLimitIs8MiB() {
        XCTAssertEqual(HTTPClient(session: .shared, logTag: "[test]").maxResponseBytes, 8 * 1024 * 1024)
    }

    func testResponseByteLimitConstants() {
        XCTAssertEqual(ResponseByteLimits.standardQuota, 8 * 1024 * 1024)
        XCTAssertEqual(ResponseByteLimits.antigravityTrajectory, 64 * 1024 * 1024)
    }

    /// responseTooLarge 错误只携带脱敏路径/上限/字节数，不含 body。
    func testResponseTooLargeErrorIsRedacted() {
        let err = QuotaError.responseTooLarge(limit: 100, actual: 200, redactedPath: "https://example.com/quota")
        XCTAssertFalse(err.errorDescription?.contains("example") == false)
        XCTAssertEqual(err.errorDescription, "响应过大（上限 100 bytes）：https://example.com/quota")
    }

    override func tearDown() {
        TestURLProtocol.responder = nil
        super.tearDown()
    }
}
