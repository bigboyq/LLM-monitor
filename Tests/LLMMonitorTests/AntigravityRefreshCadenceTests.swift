import Foundation
import XCTest
@testable import LLM_monitor

/// Antigravity 额度路径（阶段一：Keychain 凭据 + 远端 Google API）的抓取节奏与
/// 主机回退契约：
/// - `.background` 只请求 `retrieveUserQuotaSummary`；`.full` 追加 `loadCodeAssist`
/// - tier（loadCodeAssist）失败不影响主额度；主额度失败抛错
/// - 主机回退序 Daily → cloudcode-pa → sandbox，仅 401 终止（credentialExpired）
/// - 过期凭据零网络请求（mock 证伪）
/// - UA 为 hub 身份（版本取注入值，缺省回退 2.26.0）
/// - 默认刷新间隔 300s（仅 provider 未显式配置时生效）
final class AntigravityRefreshCadenceTests: XCTestCase {
    private static let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private static let prodHost = "cloudcode-pa.googleapis.com"
    private static let sandboxHost = "daily-cloudcode-pa.sandbox.googleapis.com"

    private static let quotaJSON = """
    {"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.8}]},{"displayName":"Claude and GPT models","buckets":[{"window":"weekly","remainingFraction":1}]}]}
    """
    private static let tierJSON = #"{"currentTier":{"id":"pro-tier","name":"Pro"}}"#

    // MARK: - Fixtures

    private actor RemoteStub {
        struct Call: Equatable {
            let host: String
            let path: String
            let headers: [String: String]
            let body: Data
        }

        private var calls: [Call] = []
        /// (host, path) → (data, status)；返回 nil 时回落 `({}, 200)`。
        private let handler: @Sendable (String, String) -> (Data, Int)?
        private let transportFailureHosts: Set<String>

        init(
            transportFailureHosts: Set<String> = [],
            handler: @escaping @Sendable (String, String) -> (Data, Int)? = { _, _ in nil }
        ) {
            self.transportFailureHosts = transportFailureHosts
            self.handler = handler
        }

        func handle(host: String, path: String, headers: [String: String], body: Data) throws -> (Data, Int) {
            calls.append(Call(host: host, path: path, headers: headers, body: body))
            if transportFailureHosts.contains(host) {
                throw URLError(.cannotConnectToHost)
            }
            return handler(host, path) ?? (Self.defaultResponse(path: path), 200)
        }

        /// handler 未指定的端点按成功回落：quota → 分组 JSON，tier → currentTier JSON。
        private static func defaultResponse(path: String) -> Data {
            path == AntigravityFetcher.remoteLoadCodeAssistPath
                ? Data(AntigravityRefreshCadenceTests.tierJSON.utf8)
                : Data(AntigravityRefreshCadenceTests.quotaJSON.utf8)
        }

        func recorded() -> [Call] { calls }
    }

    private func makeFetcher(
        credential: AntigravityCredential? = AntigravityCredentialFixtures.valid(),
        hubVersion: String? = nil,
        stub: RemoteStub
    ) -> AntigravityFetcher {
        AntigravityFetcher(
            credentialReader: { credential },
            hubVersionProvider: { hubVersion },
            remotePostOverride: { host, path, headers, body in
                try await stub.handle(host: host, path: path, headers: headers, body: body)
            }
        )
    }

    // MARK: - 刷新节奏（.background vs .full）

    func testBackgroundFetchCallsOnlyQuotaEndpoint() async throws {
        let stub = RemoteStub()
        let fetcher = makeFetcher(stub: stub)

        let result = try await fetcher.fetch(mode: .background)

        let calls = await stub.recorded()
        XCTAssertEqual(calls.map(\.path), [AntigravityFetcher.remoteQuotaSummaryPath])
        XCTAssertEqual(calls.map(\.host), [Self.dailyHost])
        // background 不带 tier；邮箱来自 Keychain 凭据。
        XCTAssertNil(result.planLabel)
        XCTAssertEqual(result.accountEmail, "user@example.com")
        XCTAssertFalse(result.models.isEmpty)
    }

    func testFullFetchAddsLoadCodeAssist() async throws {
        let stub = RemoteStub()
        let fetcher = makeFetcher(stub: stub)

        let result = try await fetcher.fetch(mode: .full)

        let calls = await stub.recorded()
        XCTAssertEqual(
            Set(calls.map(\.path)),
            Set([AntigravityFetcher.remoteQuotaSummaryPath, AntigravityFetcher.remoteLoadCodeAssistPath])
        )
        // tier 取 currentTier.name；邮箱来自 Keychain。
        XCTAssertEqual(result.planLabel, "Pro")
        XCTAssertEqual(result.accountEmail, "user@example.com")
    }

    func testTierFailureDoesNotFailQuota() async throws {
        let tierPath = AntigravityFetcher.remoteLoadCodeAssistPath
        let stub = RemoteStub(handler: { _, path in
            path == tierPath ? (Data("{}".utf8), 503) : nil
        })
        let fetcher = makeFetcher(stub: stub)

        let result = try await fetcher.fetch(mode: .full)

        let calls = await stub.recorded()
        // tier 在全部 3 台主机上 503，主额度不受影响。
        XCTAssertEqual(calls.filter { $0.path == tierPath }.count, Self.remoteHostsCount)
        XCTAssertNil(result.planLabel)
        XCTAssertFalse(result.models.isEmpty)
        XCTAssertEqual(result.accountEmail, "user@example.com")
    }

    func testQuotaFailureThrowsAfterExhaustingHosts() async {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let stub = RemoteStub(handler: { _, path in
            path == quotaPath ? (Data("{}".utf8), 503) : nil
        })
        let fetcher = makeFetcher(stub: stub)

        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("主额度接口失败必须抛错")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                return XCTFail("期望 httpError，实际 \(error)")
            }
            XCTAssertEqual(status, 503)
            let calls = await stub.recorded()
            // 非 401 的 HTTP 错误逐主机回退，全部失败后抛最后一台的错误。
            XCTAssertEqual(calls.map(\.host), [Self.dailyHost, Self.prodHost, Self.sandboxHost])
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    // MARK: - 主机回退

    func testNon401FallsBackToNextHost() async throws {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let stub = RemoteStub(handler: { host, path in
            host == Self.dailyHost && path == quotaPath ? (Data(), 503) : nil
        })
        let fetcher = makeFetcher(stub: stub)

        _ = try await fetcher.fetch(mode: .background)

        let calls = await stub.recorded()
        XCTAssertEqual(calls.map(\.host), [Self.dailyHost, Self.prodHost])
    }

    func testTransportFailureFallsBackToNextHost() async throws {
        let stub = RemoteStub(transportFailureHosts: [Self.dailyHost])
        let fetcher = makeFetcher(stub: stub)

        _ = try await fetcher.fetch(mode: .background)

        let calls = await stub.recorded()
        XCTAssertEqual(calls.map(\.host), [Self.dailyHost, Self.prodHost])
    }

    func test401TerminatesWithoutFallback() async {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let stub = RemoteStub(handler: { _, path in
            path == quotaPath ? (Data(), 401) : nil
        })
        let fetcher = makeFetcher(stub: stub)

        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("远端 401 必须抛 credentialExpired")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            // 远端 401 与本地过期判定落到同一提示。
            XCTAssertEqual(error.errorDescription, "token 已过期，请打开 Antigravity 更新凭据")
            // 仅 401 终止：不做主机回退。
            let calls = await stub.recorded()
            XCTAssertEqual(calls.map(\.host), [Self.dailyHost])
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    // MARK: - 凭据门控

    func testExpiredCredentialMakesNoNetworkRequests() async {
        let stub = RemoteStub()
        let fetcher = makeFetcher(credential: AntigravityCredentialFixtures.expired(), stub: stub)

        do {
            _ = try await fetcher.fetch(mode: .full)
            XCTFail("过期凭据必须抛 credentialExpired")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, "token 已过期，请打开 Antigravity 更新凭据")
            // 过期时不发任何网络请求（mock 证伪）。
            let calls = await stub.recorded()
            XCTAssertTrue(calls.isEmpty, "过期凭据不应发起任何网络请求，实际 \(calls.count) 次")
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    func testMissingCredentialThrowsWithoutNetwork() async {
        let stub = RemoteStub()
        let fetcher = makeFetcher(credential: nil, stub: stub)

        do {
            _ = try await fetcher.fetch(mode: .background)
            XCTFail("缺少凭据必须抛错")
        } catch let error as QuotaError {
            guard case .networkError(let message) = error else {
                return XCTFail("期望 networkError，实际 \(error)")
            }
            XCTAssertTrue(message.contains("未读取到 Antigravity 登录凭据"))
            let calls = await stub.recorded()
            XCTAssertTrue(calls.isEmpty)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    // MARK: - 请求头 / UA 构造

    func testRemoteHeadersUseHubUserAgent() async throws {
        let stub = RemoteStub()
        let fetcher = makeFetcher(hubVersion: "2.30.1", stub: stub)

        _ = try await fetcher.fetch(mode: .background)

        let calls = await stub.recorded()
        guard let call = calls.first else {
            return XCTFail("应至少发起一次请求")
        }
        XCTAssertEqual(
            call.headers["User-Agent"],
            "antigravity/hub/2.30.1 (aidev_client; os_type=darwin; arch=arm64)"
        )
        XCTAssertEqual(call.headers["Authorization"], "Bearer test-access-token")
        XCTAssertEqual(call.headers["Content-Type"], "application/json")
        XCTAssertEqual(call.body, Data("{}".utf8))
    }

    func testHubUserAgentFallsBackTo26Version() {
        XCTAssertEqual(
            AntigravityFetcher.hubUserAgent(version: nil),
            "antigravity/hub/2.26.0 (aidev_client; os_type=darwin; arch=arm64)"
        )
        // 空白版本同样回退。
        XCTAssertEqual(
            AntigravityFetcher.hubUserAgent(version: "   "),
            "antigravity/hub/2.26.0 (aidev_client; os_type=darwin; arch=arm64)"
        )
    }

    func testReadAntigravityAppVersionReadsPlist() throws {
        let tempDir = NSTemporaryDirectory()
            .appending("antigravity-ua-fixture-\(UUID().uuidString)")
        let contentsURL = URL(fileURLWithPath: tempDir).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let info: [String: Any] = ["CFBundleShortVersionString": "  2.31.4  "]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        XCTAssertEqual(
            AntigravityFetcher.readAntigravityAppVersion(bundlePath: tempDir),
            "2.31.4"
        )

        // 读不到 Info.plist → nil（调用方回退 2.26.0）。
        XCTAssertNil(
            AntigravityFetcher.readAntigravityAppVersion(
                bundlePath: tempDir + "/missing"
            )
        )
    }

    // MARK: - tier 解析（远端无 response 包装）

    func testTierResolutionFallbackChain() throws {
        func decode(_ json: String) throws -> LoadCodeAssistRemoteResponse {
            try JSONDecoder().decode(LoadCodeAssistRemoteResponse.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"currentTier":{"id":"pro-tier","name":"Pro"}}"#).tierName, "Pro")
        XCTAssertEqual(try decode(#"{"paidTier":{"id":"paid-tier","name":"Paid"}}"#).tierName, "Paid")
        XCTAssertEqual(try decode(#"{"paidTier":{"id":"paid-tier"}}"#).tierName, "paid-tier")
        XCTAssertNil(try decode(#"{}"#).tierName)
        // 空白视为缺失，继续回退。
        XCTAssertEqual(
            try decode(#"{"currentTier":{"name":"   "},"paidTier":{"name":"Free"}}"#).tierName,
            "Free"
        )
    }

    // MARK: - 默认刷新间隔

    func testDefaultRefreshIntervalIs300s() {
        var config = AppConfig(refreshIntervalSeconds: 60, providers: [
            ProviderKind.antigravity.providerID: ProviderConfig(enabled: true)
        ])
        // provider 未显式配置 → antigravity 用专属默认 300s（不再继承全局 60s）。
        XCTAssertEqual(config.effectiveRefreshInterval(for: "antigravity"), 300)
        // 其他 provider 仍继承全局。
        XCTAssertEqual(config.effectiveRefreshInterval(for: "minimax_token_plan"), 60)

        // 显式配置不受影响。
        config.providers["antigravity"] = ProviderConfig(enabled: true, refreshIntervalSeconds: 600)
        XCTAssertEqual(config.effectiveRefreshInterval(for: "antigravity"), 600)
    }

    private static let remoteHostsCount = AntigravityFetcher.remoteHosts.count
}
