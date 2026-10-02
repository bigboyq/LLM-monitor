import XCTest
import Foundation
@testable import LLM_monitor

/// `Services/Infra/HTTPClient.swift`：取消透传、诊断错误体截断、QuotaError
/// 文案，以及 HTTP/RPC 响应体硬上限（R2 cap 机制）。
/// 由 `HTTPAndSQLiteTests` 的 HTTP 部分 + 整份 `ResponseCapTests` 合并而成，
/// 逐字搬移零逻辑变化。
final class HTTPClientTests: XCTestCase {

    // MARK: - HTTPClient 取消语义

    func testQuotaErrorDoesNotDuplicateHTTPStatus() {
        let error = QuotaError.httpError(status: 503, body: "HTTP 503，响应 12 bytes")
        XCTAssertEqual(error.localizedDescription, "HTTP 503，响应 12 bytes")
    }

    func testQuotaErrorProvidesProviderSpecificAuthenticationGuidance() {
        let error = QuotaError.httpError(status: 401, body: "unauthorized")

        XCTAssertEqual(
            QuotaError.userFacingDescription(for: error, providerKind: .codexChatGpt),
            "Codex 登录已失效，请运行 codex login 后重试"
        )
        XCTAssertEqual(
            QuotaError.userFacingDescription(for: error, providerKind: .antigravity),
            "Antigravity 登录已失效，请重新启动 Antigravity 并完成登录"
        )
        // round 11 P1：minimax / GLM 也需要 provider-specific 提示，
        // 否则用户看到通用 "HTTP 401" 不知道该换 key 还是换账号。
        XCTAssertEqual(
            QuotaError.userFacingDescription(for: error, providerKind: .minimaxTokenPlan),
            "minimax API Key 无效或已过期"
        )
        XCTAssertEqual(
            QuotaError.userFacingDescription(for: error, providerKind: .glmCodingPlan),
            "GLM Coding Plan Key 无效或已过期"
        )
    }

    /// 之前 `HTTPClient.send` 把 `CancellationError` / `URLError.cancelled` 包装成
    /// `QuotaError.networkError`，配置变更 / 停止刷新时取消请求会被记成 provider failed、
    /// 走失败排期。修后必须透传 `CancellationError`。
    func testHTTPClientSurfacesCancellationError() async throws {
        let cancellableURL = URL(string: "https://example.invalid/slow")!
        let client = HTTPClient(
            session: HangingSession.makeSession(),
            logTag: "[test/cancel]",
            defaultTimeout: 30
        )
        var req = URLRequest(url: cancellableURL)
        req.httpMethod = "GET"

        let task = Task<Bool, Error> {
            do {
                _ = try await client.send(req, includeBodyInError: true)
                return false  // 不应该走到这里
            } catch is CancellationError {
                return true
            } catch let error as URLError where error.code == .cancelled {
                return true
            } catch {
                // networkError 包装算失败
                XCTFail("CancellationError 被包装成 \(error)")
                return false
            }
        }

        // 立即取消 —— 让 hanging session 抛 cancelled
        task.cancel()

        let wasCancelled = try await task.value
        XCTAssertTrue(wasCancelled, "HTTPClient.send 应当透传 CancellationError，而不是包成 QuotaError.networkError")
    }

    /// `URLSession` 子类：所有请求都挂住，不返回任何响应。
    /// 直到 task 被取消。
    private final class HangingSession: NSObject, URLSessionDelegate {
        static func makeSession() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HangingProtocol.self]
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        }
    }

    private final class HangingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // 不调用 urlProtocol(_:didReceive:response:cacheStoragePolicy:) / didFinishLoading
            // 让请求一直挂住。取消时 URLProtocol 会被通知 stopLoading。
        }

        override func stopLoading() {
            // Task 取消 → URLSession 调用 stopLoading，模拟真实场景的 cancelled
            if let client = client {
                let error = URLError(.cancelled)
                client.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private final class ErrorResponseProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 600))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testHTTPClientCapsDiagnosticErrorBodyAt500Characters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ErrorResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = HTTPClient(session: session, logTag: "[test/body-limit]")
        let request = URLRequest(url: URL(string: "https://example.invalid/error")!)

        do {
            _ = try await client.send(request, includeBodyInError: true)
            XCTFail("expected HTTP error")
        } catch let error as QuotaError {
            guard case .httpError(let status, let body) = error else {
                XCTFail("expected QuotaError.httpError, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body.count, 500)
            XCTAssertTrue(body.allSatisfy { $0 == "A" })
        }
    }

    // MARK: - R2: HTTP/RPC 响应体硬上限

    // R2 cap 测试（原 `ResponseCapTests`）：直接验证 CappedDownloadDelegate 的
    // 累计/上限/提前拒绝逻辑（cap 机制的核心），并用 URLProtocol 覆盖正常交付
    // 路径（恰好等于上限、低于上限、非 2xx）。

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

    // MARK: - 后置字节校验（async data(for:delegate:) 不投递内容回调）

    /// async `session.data(for:delegate:)` 在当前系统上不向 per-task delegate
    /// 投递 didReceive response / data 内容回调，delegate 的流式计数不执行；
    /// 实际生效的上限是返回后的字节校验：URLProtocol 桩返回超过上限的响应体
    /// → 抛 responseTooLarge（携带上限/实际字节数/脱敏路径）。
    func testOversizedBodyThrowsResponseTooLargeAfterReturn() async {
        let session = makeSession()
        TestURLProtocol.responder = { proto in
            proto.send(status: 200, body: Data(repeating: 0x41, count: 1_000_001), contentLength: nil)
        }
        do {
            _ = try await CappedDownloader.data(
                for: URLRequest(url: testURL), session: session, maxBytes: 1_000_000, redactedPath: redacted
            )
            XCTFail("超过上限的响应体应抛 responseTooLarge")
        } catch let error as QuotaError {
            XCTAssertEqual(
                error,
                .responseTooLarge(limit: 1_000_000, actual: 1_000_001, redactedPath: redacted)
            )
        } catch {
            XCTFail("应抛 QuotaError.responseTooLarge，实际 \(error)")
        }
    }

    /// HTTPClient.send 走同一后置校验：超限透传 responseTooLarge（QuotaError
    /// catch 直通，不被改写成 networkError / httpError）。
    func testHTTPClientSendPropagatesResponseTooLarge() async {
        let client = HTTPClient(session: makeSession(), logTag: "[test/cap]", maxResponseBytes: 1_000)
        TestURLProtocol.responder = { proto in
            proto.send(status: 200, body: Data(repeating: 0x41, count: 1_001), contentLength: nil)
        }
        do {
            _ = try await client.send(URLRequest(url: testURL))
            XCTFail("超过上限的响应体应抛 responseTooLarge")
        } catch let error as QuotaError {
            XCTAssertEqual(error, .responseTooLarge(limit: 1_000, actual: 1_001, redactedPath: redacted))
        } catch {
            XCTFail("应抛 QuotaError.responseTooLarge，实际 \(error)")
        }
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
