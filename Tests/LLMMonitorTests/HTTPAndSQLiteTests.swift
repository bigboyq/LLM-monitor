import XCTest
import Foundation
import SQLite3
@testable import LLM_monitor

final class HTTPAndSQLiteTests: XCTestCase {

    // MARK: - SQLiteTempCopy 清理语义

    /// `read` 把抛错的 action 透传给调用方；不管 action 成败，defer 都会清理 /tmp 副本。
    /// 这是基础保护层 —— 不管 action 内部因为什么原因抛错，临时文件都不会泄漏。
    ///
    /// 关于 ".db 成功 / -wal 失败" 这种半完成场景：要在测试里强制 -wal 复制失败
    /// 比较折腾（`fileExists` 默认跟随 symlink 让 dangling symlink 走不到 copy 分支；
    /// chmod 0 在 root / SIP 环境不生效；让 -wal 是目录会被当成目录递归复制）。
    /// 改在 `SQLiteTempCopy.swift` 的 defer 位置由代码评审保证：defer 注册在
    /// `copyToTemp` 任何文件创建之前，且覆盖 3 个 URL（db / wal / shm），抛错路径
    /// 必然进 defer 块清理。
    func testSQLiteTempCopyCleansUpAfterActionThrows() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        // T2: 不再统计 $TMPDIR 下所有 .db（会受无关文件/并发进程干扰）。
        // 改为快照本次测试前后的目录内容，断言没有新增的 SQLite 临时副本残留。
        let before = try currentTempEntries()

        do {
            _ = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { _ in
                throw NSError(domain: "test", code: 1)
            }
            XCTFail("expected error to propagate")
        } catch {
            // expected
        }

        let after = try currentTempEntries()
        let leaked = after.subtracting(before).filter { Self.isSQLiteTempCopyName($0) }
        XCTAssertTrue(leaked.isEmpty,
                      "SQLiteTempCopy 在 action 抛错后未清理 /tmp 副本: \(leaked)")
    }

    func testSQLiteTempCopyFallsBackOnPrepareFailedWithCantOpen() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        var callCount = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            callCount += 1
            if callCount == 1 {
                // 模拟直接读取时 prepare 阶段遇到 CANTOPEN 错误
                throw SQLiteConnectionError.prepareFailed(code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN, message: "unable to open database file", sql: "SELECT *")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600, "SQLite fallback 副本不能继承宽松权限")
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2, "遇到 CANTOPEN prepare 错误时，应当重试/回退到临时副本（调用次数应为 2）")
    }

    private func makeTempDB() throws -> URL {
        let srcDB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqlite-temp-copy-test-\(UUID().uuidString).db")
        try Data([0x00, 0x01]).write(to: srcDB)
        return srcDB
    }

    /// T2: 快照 $TMPDIR 当前条目，用于测试前后做差集判断残留。
    private func currentTempEntries() throws -> Set<String> {
        let tempDir = NSTemporaryDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        return Set(contents)
    }

    /// SQLiteTempCopy 的临时副本命名为 `<UUID>.db` / `<UUID>.db-wal` / `<UUID>.db-shm`。
    /// 只把 UUID 词干的三件套算作“本次可能产生的副本”，避免把无关 .db 误判为泄漏。
    private static func isSQLiteTempCopyName(_ name: String) -> Bool {
        let stems = [".db", ".db-wal", ".db-shm"]
        guard stems.contains(where: { name.hasSuffix($0) }) else { return false }
        let uuidRegex = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.db(-wal|-shm)?$"#
        return name.range(of: uuidRegex, options: .regularExpression) != nil
    }

    // MARK: - HTTPClient 取消语义

    func testHTTPRequestLogSanitizerRemovesQueryCredentialsAndFragment() {
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://api.example.com/v1/usage?access_token=secret")
            ),
            "https://api.example.com/v1/usage"
        )
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://alice:password@example.com:8443/private")
            ),
            "https://example.com:8443/private"
        )
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://example.com/docs/start#bearer-secret")
            ),
            "https://example.com/docs/start"
        )
    }

    func testHTTPRequestLogSanitizerPreservesOrdinaryOriginAndPath() {
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(
                URL(string: "https://example.com:9443/v1/models")
            ),
            "https://example.com:9443/v1/models"
        )
    }

    func testHTTPRequestLogSanitizerUsesFixedInvalidPlaceholder() {
        XCTAssertEqual(HTTPRequestLogSanitizer.sanitizedURL(nil), "<invalid-url>")
        XCTAssertEqual(
            HTTPRequestLogSanitizer.sanitizedURL(URL(string: "relative/path")),
            "<invalid-url>"
        )
    }

    func testHTTPNetworkErrorDescriptionCannotEchoCredentialURL() {
        let secretURL = URL(string: "https://user:password@example.com/path?token=secret")!
        let error = URLError(
            .cannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: secretURL]
        )

        let description = HTTPRequestLogSanitizer.networkErrorDescription(error)

        XCTAssertEqual(description, "无法连接服务器")
        XCTAssertFalse(description.contains("password"))
        XCTAssertFalse(description.contains("secret"))
    }

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
    /// 增加 failure 计数（污染指数退避）。修后必须透传 `CancellationError`。
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
}
