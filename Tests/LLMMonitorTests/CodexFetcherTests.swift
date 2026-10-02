import XCTest
import Foundation
@testable import LLM_monitor

/// 这套测试覆盖 `fetch / fetchUsage / fetchResetCredits` 的 HTTP 集成路径、
/// auth.json 读取、401 → 用户文案映射、reset credits 各种 fallback 分支。
///
/// URLProtocol 注入 + 临时 auth.json + 注入的 `usageURL / resetCreditsURL` 让
/// 测试完全在本地运行，不打真实 ChatGPT 后端。
final class CodexFetcherTests: XCTestCase {

    // MARK: - URLProtocol fixture

    /// 用 `URLProtocol` 注入响应：按 `request.url?.path` 区分 usage / reset-credits，
    /// 其他路径返回 404。
    private final class StubURLProtocol: URLProtocol {
        struct Response {
            let statusCode: Int
            let headers: [String: String]
            let body: Data
        }
        /// `(path, response)` 列表。`nil` 表示该 path 不被本协议处理。
        /// 同一 path 注册多次按 LIFO 取最后一个。
        nonisolated(unsafe) static var responses: [String: Response] = [:]
        /// 记录每个 path 被请求时实际带的 header（`Authorization` 验证用）。
        nonisolated(unsafe) static var capturedHeaders: [String: [String: String]] = [:]
        /// 记录每个 path 被请求的次数。
        nonisolated(unsafe) static var callCounts: [String: Int] = [:]
        /// 取消传播测试用：path 在此集合中的请求只计数、永不回包 —— 请求保持
        /// in-flight，取消（URLError.cancelled）成为唯一出口。注意不能在
        /// startLoading 里阻塞等待：那会堵住 session 的串行回调队列，连
        /// 取消完成事件都无法派发。
        nonisolated(unsafe) static var neverRespondPaths: Set<String> = []

        static func reset() {
            responses.removeAll()
            capturedHeaders.removeAll()
            callCounts.removeAll()
            neverRespondPaths.removeAll()
        }

        override class func canInit(with request: URLRequest) -> Bool {
            guard let path = request.url?.path else { return false }
            return responses[path] != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let response = Self.responses[url.path] else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            Self.callCounts[url.path, default: 0] += 1
            // 记录带过来的 header
            var captured: [String: String] = [:]
            for (k, v) in request.allHTTPHeaderFields ?? [:] {
                captured[k] = v
            }
            Self.capturedHeaders[url.path] = captured

            // callCount 已落地再返回：测试轮询 callCount 即可得知请求已发起
            if Self.neverRespondPaths.contains(url.path) {
                return
            }

            let httpResponse = HTTPURLResponse(
                url: url,
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

    private static let usagePath = "/backend-api/wham/usage"
    private static let resetPath = "/backend-api/wham/rate-limit-reset-credits"

    /// 构造一个走 StubURLProtocol 的 session，注入到 fetcher 里。
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 写一个最小可用的 auth.json 到临时文件，返回 URL。
    private func makeAuthFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fetcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        // 真实的 auth.json 结构最小化：只填 fetch 必需的 tokens.access_token。
        let json: [String: Any] = [
            "tokens": [
                "access_token": "test-bearer-abcdef",
                "account_id": "acc_test_001"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - auth.json 读取 + header 构造

    /// 验证 `fetchUsage` 走 `Authorization: Bearer <access_token>` + `OpenAI-Beta: codex-1`
    /// + `originator: Codex Desktop` + `ChatGPT-Account-ID`，并把 auth.json 里
    /// account_id 透传到 header。
    func testCodexFetcherFetchUsageSendsCorrectAuthHeaders() async throws {
        let authURL = try makeAuthFile()
        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validUsageJSON()
        )

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )
        _ = try await fetcher.fetch(mode: .background)

        let captured = try XCTUnwrap(StubURLProtocol.capturedHeaders[Self.usagePath])
        XCTAssertEqual(captured["Authorization"], "Bearer test-bearer-abcdef")
        XCTAssertEqual(captured["OpenAI-Beta"], "codex-1")
        XCTAssertEqual(captured["originator"], "Codex Desktop")
        XCTAssertEqual(captured["ChatGPT-Account-ID"], "acc_test_001")
    }

    /// auth.json 缺 access_token → `missingAPIKey`，fetch 抛 `QuotaError.missingAPIKey`。
    /// 这种情况根本不应该发起 HTTP 请求。
    func testCodexFetcherMissingAccessTokenThrowsBeforeAnyRequest() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fetcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let authURL = dir.appendingPathComponent("auth.json")
        let json: [String: Any] = ["tokens": ["account_id": "acc_x"]]
        try JSONSerialization.data(withJSONObject: json).write(to: authURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )
        // 没注册任何 stub 响应；如果发起请求会因 canInit=false 被 URLError.badURL
        // 拦截，所以"fetch 没抛网络错而是抛 missingAPIKey"间接证明 fetch 根本没发请求。
        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("expected QuotaError.missingAPIKey")
        } catch let error as QuotaError {
            guard case .missingAPIKey = error else {
                XCTFail("expected .missingAPIKey, got \(error)")
                return
            }
        }
        XCTAssertNil(StubURLProtocol.callCounts[Self.usagePath], "auth 缺失时不应发 usage 请求")
    }

    // MARK: - 401 → 用户文案

    /// 401 → `QuotaError.httpError(401)`，再走 `userFacingDescription` 翻译成
    /// "Codex 登录已失效，请运行 codex login 后重试"。这是 round 11 Error UX P1
    /// 的回归网。
    func testCodexFetcher401MapsToFriendlyAuthError() async throws {
        let authURL = try makeAuthFile()
        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 401,
            headers: ["Content-Type": "text/plain"],
            body: Data("unauthorized".utf8)
        )

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )

        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("expected QuotaError.httpError(401)")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                XCTFail("expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(
                QuotaError.userFacingDescription(for: error, providerKind: .codexChatGpt),
                "Codex 登录已失效，请运行 codex login 后重试"
            )
        }
    }

    // MARK: - 200 happy path

    /// 200 + 合法 rate_limit JSON → 完整 QuotaInfo，含 model.primaryWindow 解析
    /// + reset credits（.full 模式才会抓 reset credits，验证 .background 模式
    /// 不会触发第二次请求）。
    func testCodexFetcherFetchBackgroundModeDoesNotCallResetCredits() async throws {
        let authURL = try makeAuthFile()
        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validUsageJSON()
        )
        StubURLProtocol.responses[Self.resetPath] = .init(
            statusCode: 500,
            headers: [:],
            body: Data("nope".utf8)
        )

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )
        let info = try await fetcher.fetch(mode: .background)

        XCTAssertEqual(info.models.count, 1)
        XCTAssertEqual(info.models.first?.modelName, "chatgpt_plan")
        XCTAssertEqual(info.models.first?.intervalRemainingPercent, 80)
        XCTAssertNil(info.resetCredits, ".background 模式不抓 reset credits")
        XCTAssertEqual(StubURLProtocol.callCounts[Self.usagePath], 1)
        XCTAssertNil(StubURLProtocol.callCounts[Self.resetPath],
                     ".background 模式不应触发 reset credits 请求")
    }

    /// .full 模式下，usage + reset credits 两次都应被调用，且 reset credits 解析
    /// 出 `available_count=2`。
    func testCodexFetcherFetchFullModeParsesResetCreditsAvailableCount() async throws {
        let authURL = try makeAuthFile()
        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validUsageJSON()
        )
        StubURLProtocol.responses[Self.resetPath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validResetCreditsJSON(availableCount: 2, totalEarned: 5)
        )

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )
        let info = try await fetcher.fetch(mode: .full)

        XCTAssertEqual(StubURLProtocol.callCounts[Self.usagePath], 1)
        XCTAssertEqual(StubURLProtocol.callCounts[Self.resetPath], 1)
        XCTAssertNotNil(info.resetCredits)
        XCTAssertEqual(info.resetCredits?.serverAvailableCount, 2)
        XCTAssertEqual(info.resetCredits?.totalEarnedCount, 5)
        // 显式 available entries 共 1 条（id=credit-1），serverAvailableCount=2
        // → 解析层补 1 条 synthetic "available"
        XCTAssertEqual(info.resetCredits?.entries.count, 2)
        XCTAssertEqual(
            info.resetCredits?.entries.filter { $0.status.lowercased() == "available" }.count,
            2
        )
    }

    /// M1 回归网：secondary_window 存在但缺 `reset_at` 时透传 nil（保持
    /// weeklyStatus=.present）。不按窗口长度合成边界 —— 合成值曾泄漏进 UI
    /// 阈值判定与本地分桶。消费面对 nil 安全降级（固定黄线），不 trap。
    func testCodexWeeklyWindowWithoutResetAtPassesThroughNil() throws {
        func usageJSON(secondaryWindow: [String: Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 20,
                        "limit_window_seconds": 1800,
                        "reset_at": 1_900_000_000
                    ],
                    "secondary_window": secondaryWindow
                ]
            ])
        }

        // 1) 有窗口长度：reset_at 缺失仍透传 nil，窗口长度照常透传
        let withWindow = try CodexFetcher.parseUsage(
            try CodexFetcher.parseUsageData(usageJSON(secondaryWindow: [
                "used_percent": 40, "limit_window_seconds": 604_800
            ]))
        )
        XCTAssertEqual(withWindow.weeklyStatus, .present)
        XCTAssertNil(withWindow.weeklyResetsAt, "缺 reset_at 时不合成边界，透传 nil")
        XCTAssertEqual(withWindow.weeklyWindowSeconds, 604_800)
        XCTAssertNil(withWindow.weeklyTimeRemainingFraction, "消费面契约：reset 缺失时降级为 nil（固定黄线）")

        // 2) 无窗口长度：同样透传 nil
        let withoutWindow = try CodexFetcher.parseUsage(
            try CodexFetcher.parseUsageData(usageJSON(secondaryWindow: ["used_percent": 40]))
        )
        XCTAssertEqual(withoutWindow.weeklyStatus, .present)
        XCTAssertNil(withoutWindow.weeklyResetsAt)
        XCTAssertNil(withoutWindow.weeklyTimeRemainingFraction)
    }

    /// M5 回归网：full 模式下 reset-credits 请求因整个刷新任务被取消而失败时，
    /// fetch 必须把取消传播出去（抛 CancellationError），而不是吞掉错误、
    /// 返回 resetCredits=nil 的"成功"。与 Deepseek / GLM / minimax 的取消语义对齐。
    func testCodexFetcherFetchFullModePropagatesTaskCancellationFromResetCredits() async throws {
        let authURL = try makeAuthFile()
        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validUsageJSON()
        )
        StubURLProtocol.responses[Self.resetPath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validResetCreditsJSON(availableCount: 1, totalEarned: 1)
        )
        // reset-credits 永不回包：取消发生时该请求必然仍 in-flight
        StubURLProtocol.neverRespondPaths.insert(Self.resetPath)
        defer {
            StubURLProtocol.neverRespondPaths.remove(Self.resetPath)
        }

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )

        let task = Task { try await fetcher.fetch(mode: .full) }
        // 等 usage 与 reset 都已发起；usage 无挂起、stub 同步回包，稍候即完成
        for _ in 0..<500 where (StubURLProtocol.callCounts[Self.usagePath] ?? 0) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<500 where (StubURLProtocol.callCounts[Self.resetPath] ?? 0) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StubURLProtocol.callCounts[Self.usagePath], 1, "usage 请求应已发起")
        XCTAssertEqual(StubURLProtocol.callCounts[Self.resetPath], 1, "reset-credits 请求应已发起")
        // 给 usage 响应完全落地留出余量，确保取消只打断 reset 子请求
        try await Task.sleep(nanoseconds: 200_000_000)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后的 full 抓取不应吞掉取消、伪装成功返回")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "reset-credits 因取消失败时 fetch 应传播 CancellationError，实际: \(error)"
            )
        }
    }

    /// reset credits 响应里 `credits=[]` 但 `available_count=3`：
    /// entries 全部用 synthetic 补齐，serverAvailableCount 保留为 3。
    func testCodexFetcherResetCreditsFillsSyntheticWhenServerCountExceedsEntries() throws {
        let data = Self.validResetCreditsJSON(availableCount: 3, totalEarned: 3)
        let parsed = try CodexFetcher.parseResetCreditsData(data)
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertTrue(parsed.entries.allSatisfy { $0.status.lowercased() == "available" })
        // serverAvailableCount 保留 — 上层 UI 用它显示 "可用 N / 共 M 条"
        XCTAssertEqual(parsed.serverAvailableCount, 3)
    }

    /// reset credits 完全没 `credits` 字段 + 没有 `available_count`：
    /// 解析层不抛错，entries 是空，serverAvailableCount 是 nil。
    /// 这是真实服务器可能返回的子集（"只用 available_count 兜底"），必须能安全走通。
    func testCodexFetcherResetCreditsAcceptsEmptyBody() throws {
        let data = Data("{}".utf8)
        let parsed = try CodexFetcher.parseResetCreditsData(data)
        XCTAssertTrue(parsed.entries.isEmpty)
        XCTAssertNil(parsed.serverAvailableCount)
        XCTAssertNil(parsed.totalEarnedCount)
    }

    /// `available_count` 超过 `maxResetCreditEntries`：拒绝该响应，抛 `decodingError`。
    /// 这是 round 12 里的"超长响应保护"分支。
    func testCodexFetcherResetCreditsRejectsExcessiveAvailableCount() {
        // available_count = 1_000_001，超过 maxResetCreditEntries = 1_000
        let json: [String: Any] = ["available_count": 1_000_001]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try CodexFetcher.parseResetCreditsData(data)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - 解析错误分支

    /// usage 缺 `rate_limit` → `decodingError("usage 响应缺少 rate_limit")`。
    /// 这是 schema-drift 防御：服务器少给字段时不应静默返回空数据。
    func testCodexFetcherUsageMissingRateLimitThrowsDecodingError() {
        let data = Data("{}".utf8)
        XCTAssertThrowsError(try CodexFetcher.parseUsageData(data)) { error in
            guard case let QuotaError.decodingError(message) = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("rate_limit"),
                          "错误消息应提到 rate_limit 缺失，实际：\(message)")
        }
    }

    /// usage 顶层不是 JSON 对象（如裸数组）→ `decodingError`。
    func testCodexFetcherUsageTopLevelNotObjectThrows() {
        let data = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try CodexFetcher.parseUsageData(data)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    /// R3 Codable 向后兼容：旧格式（无 fetchedAt/lastAttemptFailed）能解码。
    /// 拆自 `CodexResetCreditsFreshnessTests`：这是 reset-credits 响应体的解码契约，
    /// 归到解析层（`parseResetCreditsData` 同一路径）而非合并层。
    func testResetCreditsCodableBackwardCompat() throws {
        let oldJSON = """
        {"entries":[],"serverAvailableCount":2,"totalEarnedCount":3}
        """
        let decoded = try JSONDecoder().decode(ResetCreditsInfo.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(decoded.serverAvailableCount, 2)
        XCTAssertNil(decoded.fetchedAt, "旧数据缺省 fetchedAt 为 nil")
        XCTAssertFalse(decoded.lastAttemptFailed, "旧数据缺省 lastAttemptFailed 为 false")
    }

    func testCodexFetcherExtractsPlanLabelAndAccountEmailFromJWTAndDict() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-jwt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // JWT header: {"alg":"none"} -> e30
        // JWT payload: {"email":"user@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"team"}}
        let headerBase64 = "e30"
        let payloadJSON = "{\"email\":\"user@example.com\",\"https://api.openai.com/auth\":{\"chatgpt_plan_type\":\"team\"}}"
        let payloadBase64 = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let fakeJWT = "\(headerBase64).\(payloadBase64).fake_signature"

        let authURL = dir.appendingPathComponent("auth.json")
        let json: [String: Any] = [
            "tokens": [
                "access_token": "test-access-token",
                "id_token": fakeJWT
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: authURL)

        StubURLProtocol.responses[Self.usagePath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validUsageJSON()
        )
        // .full 模式会并发打 usage + reset-credits 两条请求；只 stub usage 会让
        // StubURLProtocol.canInit 对 reset path 返回 false → 真网络打 chatgpt.com。
        StubURLProtocol.responses[Self.resetPath] = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Self.validResetCreditsJSON(availableCount: 1, totalEarned: 3)
        )

        let fetcher = CodexFetcher(
            authPath: authURL.path,
            session: makeSession()
        )

        let info = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(info.planLabel, "Team")
        XCTAssertEqual(info.accountEmail, "user@example.com")
        // .full 模式必须两条请求都发出去（各 1 次），且 reset-credits 分支的解析结果
        // 真的落到 info 上（此前这条路径从未被断言覆盖，只靠 usage stub 兜底）。
        XCTAssertEqual(StubURLProtocol.callCounts[Self.usagePath], 1)
        XCTAssertEqual(StubURLProtocol.callCounts[Self.resetPath], 1)
        XCTAssertEqual(info.resetCredits?.serverAvailableCount, 1)
        XCTAssertEqual(info.resetCredits?.totalEarnedCount, 3)
    }

    // MARK: - 辅助 JSON 构造

    /// 合法的 `wham/usage` 响应：primary 用了 20%（剩 80%），window 1800s。
    private static func validUsageJSON() -> Data {
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

    /// 合法的 `wham/rate-limit-reset-credits` 响应：1 条显式 entry，available_count=2。
    private static func validResetCreditsJSON(availableCount: Int, totalEarned: Int) -> Data {
        let json: [String: Any] = [
            "available_count": availableCount,
            "total_earned_count": totalEarned,
            "credits": [
                [
                    "id": "credit-1",
                    "status": "available",
                    "expires_at": "2030-01-01T00:00:00Z",
                    "granted_at": "2026-01-01T00:00:00Z",
                    "reset_type": "monthly",
                    "title": "Test Credit",
                    "description": "synthetic test"
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}
