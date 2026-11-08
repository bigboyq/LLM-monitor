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
        // 阶段一起远端 401 与本地过期判定落到同一提示（credentialExpired）。
        XCTAssertEqual(
            QuotaError.userFacingDescription(for: error, providerKind: .antigravity),
            "token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据"
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
        static var onStopLoading: (() -> Void)?
        private(set) var isStopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            TestURLProtocol.responder?(self)
        }
        override func stopLoading() {
            isStopped = true
            TestURLProtocol.onStopLoading?()
        }

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

        func sendChunked(
            status: Int,
            chunks: [Data],
            contentLength: Int? = nil,
            delayBetweenChunks: TimeInterval = 0.1,
            onChunkSent: ((Int) -> Void)? = nil,
            beforeChunk: ((Int) -> Void)? = nil,
            onSendLoopFinished: (() -> Void)? = nil
        ) {
            var headers: [String: String] = [:]
            if let contentLength { headers["Content-Length"] = String(contentLength) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            DispatchQueue.global().async {
                defer { onSendLoopFinished?() }
                Thread.sleep(forTimeInterval: delayBetweenChunks)
                for (idx, chunk) in chunks.enumerated() {
                    if self.isStopped { break }
                    // 确定性握手缝：投递前允许测试阻塞等待真实事件
                    //（如「客户端已因超限中止」），消除对 chunk 间隔 sleep 的时序假设。
                    beforeChunk?(idx)
                    if self.isStopped { break }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    onChunkSent?(idx + 1)
                    Thread.sleep(forTimeInterval: delayBetweenChunks)
                }
                if !self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    /// 测试辅助：确定性握手门闩 + 线程安全状态收集（参照 WriterGate 模式）。
    /// 把「后续 chunk 必须等客户端越过 cap 中止后再投递」的时序窗口换成对真实
    /// 事件（`stopLoading` 被调用）的阻塞等待，彻底消除对 sleep 时长的依赖。
    private final class StreamGate: @unchecked Sendable {
        private let lock = NSLock()
        private var aborted = false
        private var sendLoopDone = false
        private var chunk3GateTimedOut = false
        private var sentCount = 0

        /// `stopLoading` 回调：客户端已因超限中止连接。
        func clientDidAbort() { lock.withLock { aborted = true } }
        var clientAborted: Bool { lock.withLock { aborted } }

        func markSendLoopFinished() { lock.withLock { sendLoopDone = true } }
        var isSendLoopDone: Bool { lock.withLock { sendLoopDone } }

        func markChunk3GateTimedOut() { lock.withLock { chunk3GateTimedOut = true } }
        var chunk3GateDidTimeOut: Bool { lock.withLock { chunk3GateTimedOut } }

        func recordChunkSent(_ count: Int) { lock.withLock { sentCount = count } }
        var chunksSent: Int { lock.withLock { sentCount } }

        /// 阻塞等待「客户端已中止」真实事件；deadline 轮询，超时返回 false。
        func waitUntilClientAborted(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !clientAborted, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return clientAborted
        }

        /// 阻塞等待发送循环收尾；deadline 轮询，保证断言读到最终状态。
        func waitUntilSendLoopFinished(timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            while !isSendLoopDone, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
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
    }

    /// responseTooLarge 错误只携带脱敏路径/上限/字节数，不含 body。
    func testResponseTooLargeErrorIsRedacted() {
        let err = QuotaError.responseTooLarge(limit: 100, actual: 200, redactedPath: "https://example.com/quota")
        XCTAssertFalse(err.errorDescription?.contains("example") == false)
        XCTAssertEqual(err.errorDescription, "响应过大（上限 100 bytes）：https://example.com/quota")
    }

    /// 分块传输超限提前中止：收到第 2 块超出上限后立即 abort，第 3 块不会被投递。
    ///
    /// 确定性握手：第 3 块的投递决定挂在「客户端已因超限中止」这一真实事件
    /// （`stopLoading` 回调）之后——发送侧阻塞等待中止事件再尝试第 3 块，此时
    /// `isStopped` 必为真而跳过投递；不再依赖 chunk 间隔 sleep 留出的时序窗口
    ///（并行负载下该窗口会被压缩，导致第 3 块被抢先投递）。
    func testChunkedStreamingAbortsEarlyWhenExceedingCapWithoutReadingLaterChunks() async {
        let session = makeSession()
        let gate = StreamGate()

        TestURLProtocol.onStopLoading = { gate.clientDidAbort() }
        TestURLProtocol.responder = { proto in
            proto.sendChunked(
                status: 200,
                chunks: [
                    Data(repeating: 0x41, count: 600), // chunk 1 (600 <= 1000)
                    Data(repeating: 0x42, count: 600), // chunk 2 (1200 > 1000, 超限取消)
                    Data(repeating: 0x43, count: 600)  // chunk 3 (中止事件后才尝试，必被跳过)
                ],
                contentLength: nil,
                delayBetweenChunks: 0,
                onChunkSent: { gate.recordChunkSent($0) },
                beforeChunk: { index in
                    // 第 3 块投递前必须先观察到客户端中止（真实 stopLoading 事件）。
                    if index == 2, !gate.waitUntilClientAborted(timeout: 10) {
                        gate.markChunk3GateTimedOut()
                    }
                },
                onSendLoopFinished: { gate.markSendLoopFinished() }
            )
        }

        do {
            _ = try await CappedDownloader.data(
                for: URLRequest(url: testURL), session: session, maxBytes: 1_000, redactedPath: redacted
            )
            XCTFail("分块流超限应抛 responseTooLarge")
        } catch let error as QuotaError {
            XCTAssertEqual(
                error,
                .responseTooLarge(limit: 1_000, actual: 1_200, redactedPath: redacted)
            )
        } catch {
            XCTFail("应抛 QuotaError.responseTooLarge，实际 \(error)")
        }

        // 等发送循环收尾后断言最终状态，避免与后台投递线程竞态。
        gate.waitUntilSendLoopFinished(timeout: 10)
        XCTAssertFalse(
            gate.chunk3GateDidTimeOut,
            "客户端未在 10s 内中止连接：cap 未生效或投递链路异常"
        )
        XCTAssertEqual(gate.chunksSent, 2, "第 3 块不应被发送或处理，流在超限时已提前终止")
        XCTAssertTrue(gate.clientAborted, "任务超限必须触发 stopLoading 中止连接")
    }

    /// 伪造过小的 Content-Length 无法绕过流式硬上限。
    func testFakeSmallContentLengthDoesNotBypassStreamingCap() async {
        let session = makeSession()
        TestURLProtocol.responder = { proto in
            proto.sendChunked(
                status: 200,
                chunks: [
                    Data(repeating: 0x41, count: 600),
                    Data(repeating: 0x42, count: 600)
                ],
                contentLength: 50 // 伪造 50 字节声明
            )
        }

        do {
            _ = try await CappedDownloader.data(
                for: URLRequest(url: testURL), session: session, maxBytes: 1_000, redactedPath: redacted
            )
            XCTFail("伪造 Content-Length 不得绕过实际流式字节硬上限")
        } catch let error as QuotaError {
            XCTAssertEqual(
                error,
                .responseTooLarge(limit: 1_000, actual: 1_200, redactedPath: redacted)
            )
        } catch {
            XCTFail("应抛 QuotaError.responseTooLarge，实际 \(error)")
        }
    }

    /// 响应头 Content-Length 声明超限时在收到任何数据前提前拒绝。
    /// 即使实际 body 只有 500 字节（未超 1000 上限），只要 Content-Length 声明超限，
    /// 便根据头部提前拒绝并抛出声明值（actual: 50000），无需也不等待读取 body。
    func testDeclaredContentLengthExceedingCapRejectsEarlyWithoutLoadingBody() async {
        let session = makeSession()

        TestURLProtocol.responder = { proto in
            proto.send(
                status: 200,
                body: Data(repeating: 0x41, count: 500),
                contentLength: 50_000 // 声明 50KB > 1KB 上限
            )
        }

        do {
            _ = try await CappedDownloader.data(
                for: URLRequest(url: testURL), session: session, maxBytes: 1_000, redactedPath: redacted
            )
            XCTFail("声明超限时应提前拒绝")
        } catch let error as QuotaError {
            XCTAssertEqual(
                error,
                .responseTooLarge(limit: 1_000, actual: 50_000, redactedPath: redacted),
                "应当按响应头声明的 50000 字节提前拒绝，而非实际传输的 500 字节"
            )
        } catch {
            XCTFail("应抛 QuotaError.responseTooLarge，实际 \(error)")
        }
    }

    private final class DummyChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    }

    private final class MockChallengeParentDelegate: NSObject, URLSessionDelegate {
        var didReceiveChallenge = false
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            didReceiveChallenge = true
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func testDelegateForwardsAuthenticationChallengeToParentDelegate() {
        let parent = MockChallengeParentDelegate()
        let delegate = CappedDownloadDelegate(maxBytes: 1000, redactedPath: redacted, parentDelegate: parent)
        let space = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )
        var called = false
        delegate.urlSession(.shared, didReceive: challenge) { disposition, _ in
            called = true
            XCTAssertEqual(disposition, .performDefaultHandling)
        }
        XCTAssertTrue(called)
        XCTAssertTrue(parent.didReceiveChallenge)
    }

    func testDelegateTaskChallengeForwardsToParentDelegate() {
        let parent = MockChallengeParentDelegate()
        let delegate = CappedDownloadDelegate(maxBytes: 1000, redactedPath: redacted, parentDelegate: parent)
        let task = URLSession.shared.dataTask(with: testURL)
        let space = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )
        var called = false
        delegate.urlSession(.shared, task: task, didReceive: challenge) { disposition, _ in
            called = true
            XCTAssertEqual(disposition, .performDefaultHandling)
        }
        XCTAssertTrue(called)
        XCTAssertTrue(parent.didReceiveChallenge)
    }

    override func tearDown() {
        TestURLProtocol.responder = nil
        TestURLProtocol.onStopLoading = nil
        super.tearDown()
    }
}
