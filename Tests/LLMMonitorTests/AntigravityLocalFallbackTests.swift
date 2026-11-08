import Foundation
import XCTest
@testable import LLM_monitor

/// 2.4.2 本地回退路径：keychain 过期/缺失或远端 401 时，额度改走本机
/// language_server RPC（`AntigravityProcessDiscovery` + 本地 quota/account RPC）。
///
/// 契约（`spec/providers/antigravity.md` § Remote Quota Path / § Discovery Flow）：
/// - 决策树：凭据新鲜 → 远端（不变）；凭据缺失/过期或远端 401 → 本地回退；
///   本地 RPC 成功后不再打远端
/// - 本地 quota 响应带 `response` 包装，group/bucket 归一化与远端共用
/// - CSRF 头仅在有非空 `--csrf_token` 时携带（CLI 后端无 CSRF）
/// - TOCTOU 复查失败抛「本地服务身份已变化」；远端 401 origin 下原样上抛，
///   凭据缺失/过期 origin 下落 `credentialExpired`
/// - 回退失败（无进程/端口/RPC 报错）：凭据缺失/过期 → `credentialExpired`
///   新文案；远端 401 且无本地后端 → 同一文案
/// - 取消错误原样上抛
final class AntigravityLocalFallbackTests: XCTestCase {
    // MARK: - Fixtures

    /// spec § Local RPC Response Shapes 的三组 quota 原始形状（带 `response` 包装）。
    private static let localQuotaJSON = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-07-11T16:50:25Z"},
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.846885,"resetTime":"2026-07-08T13:09:12Z"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-07-15T08:09:12Z"},
        {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2026-07-08T13:09:12Z"}]},
      {"displayName":"Gemini 4 Argon","buckets":[
        {"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":1,"resetTime":"2026-07-15T08:09:12Z"}]}
    ]}}
    """

    private static let localTierJSON = #"{"response":{"currentTier":{"id":"free-tier","name":"Free"}}}"#

    private actor LocalStub {
        struct Call: Equatable {
            let pid: Int
            let port: Int
            let path: String
            let headers: [String: String]
            let body: Data
        }

        private var calls: [Call] = []
        /// path → (data, status)；返回 nil 时回落成功 quota 形状。
        private let handler: @Sendable (String) -> (Data, Int)?

        init(handler: @escaping @Sendable (String) -> (Data, Int)? = { _ in nil }) {
            self.handler = handler
        }

        func handle(server: AntigravityFetcher.ServerInfo, path: String, headers: [String: String], body: Data) throws -> (Data, Int) {
            calls.append(Call(pid: server.pid, port: server.httpsPort, path: path, headers: headers, body: body))
            if let custom = handler(path) {
                return custom
            }
            return (Data(AntigravityLocalFallbackTests.localQuotaJSON.utf8), 200)
        }

        func recorded() -> [Call] { calls }
    }

    private struct Fixture {
        let remote: RemoteStub
        let local: LocalStub
        let fetcher: AntigravityFetcher
    }

    /// RemoteStub 与 AntigravityRefreshCadenceTests 同款（本文件独立一份，避免跨套件耦合）。
    private actor RemoteStub {
        struct Call: Equatable {
            let host: String
            let path: String
        }

        private var calls: [Call] = []
        private let handler: @Sendable (String, String) -> (Data, Int)?

        init(handler: @escaping @Sendable (String, String) -> (Data, Int)? = { _, _ in nil }) {
            self.handler = handler
        }

        func handle(host: String, path: String, headers: [String: String], body: Data) throws -> (Data, Int) {
            calls.append(Call(host: host, path: path))
            return handler(host, path) ?? (Data(), 200)
        }

        func recorded() -> [Call] { calls }
    }

    private func makeFixture(
        credential: AntigravityCredential?,
        discovery: @escaping @Sendable () async throws -> AntigravityFetcher.ServerInfo,
        remoteHandler: @escaping @Sendable (String, String) -> (Data, Int)? = { _, _ in nil },
        localHandler: @escaping @Sendable (String) -> (Data, Int)? = { _ in nil },
        ownership: @escaping @Sendable (AntigravityFetcher.ServerInfo) -> Bool = { _ in true }
    ) -> Fixture {
        let remote = RemoteStub(handler: remoteHandler)
        let local = LocalStub(handler: localHandler)
        let fetcher = AntigravityFetcher(
            credentialReader: { credential },
            hubVersionProvider: { nil },
            remotePostOverride: { host, path, headers, body in
                try await remote.handle(host: host, path: path, headers: headers, body: body)
            },
            localServerDiscovery: discovery,
            localPostOverride: { server, path, headers, body in
                try await local.handle(server: server, path: path, headers: headers, body: body)
            },
            localOwnershipChecker: ownership
        )
        return Fixture(remote: remote, local: local, fetcher: fetcher)
    }

    private func discoveredServer(csrfToken: String? = nil) throws -> AntigravityFetcher.ServerInfo {
        AntigravityFetcher.ServerInfo(pid: 42, httpsPort: 54_321, csrfToken: csrfToken, kind: .ide)
    }

    private func throwingDiscovery() -> @Sendable () async throws -> AntigravityFetcher.ServerInfo {
        { throw QuotaError.networkError("stub: 未发现 Antigravity 进程") }
    }

    // MARK: - 决策树：keychain 过期 → 本地 RPC

    func testExpiredCredentialFallsBackToLocalRPCWithoutRemote() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer() }
        )

        let result = try await fixture.fetcher.fetch(mode: .background)

        // 本地 RPC 命中、远端零请求（本地成功后不再打远端）。
        let localCalls = await fixture.local.recorded()
        XCTAssertEqual(localCalls.map(\.path), [AntigravityFetcher.localQuotaSummaryPath])
        XCTAssertEqual(localCalls.first?.pid, 42)
        XCTAssertEqual(localCalls.first?.port, 54_321)
        XCTAssertEqual(localCalls.first?.body, Data("{}".utf8))
        // background 不带 CSRF 头时也不带账号 RPC；邮箱回退 Keychain 凭据。
        XCTAssertNil(localCalls.first?.headers["x-codeium-csrf-token"])
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertTrue(remoteCalls.isEmpty, "本地回退成功后不应打远端，实际 \(remoteCalls.count) 次")
        XCTAssertFalse(result.models.isEmpty)
        XCTAssertEqual(result.accountEmail, "user@example.com")
    }

    func testExpiredCredentialWithNoLocalProcessThrowsCredentialExpiredNewCopy() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: throwingDiscovery()
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .full)
            XCTFail("过期凭据 + 无本地后端必须抛 credentialExpired")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, "token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据")
            let remoteCalls = await fixture.remote.recorded()
            let localCalls = await fixture.local.recorded()
            XCTAssertTrue(remoteCalls.isEmpty)
            XCTAssertTrue(localCalls.isEmpty)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    func testMissingCredentialFallsBackToLocalRPCWithAccountMetadata() async throws {
        let userStatusJSON = """
        {"userStatus":{"email":"live@example.com","userTier":{"name":"Pro Max"}}}
        """
        let fixture = makeFixture(
            credential: nil,
            discovery: { try self.discoveredServer() },
            localHandler: { path in
                path == AntigravityFetcher.localUserStatusPath
                    ? (Data(userStatusJSON.utf8), 200)
                    : nil
            }
        )

        let result = try await fixture.fetcher.fetch(mode: .full)

        let localCalls = await fixture.local.recorded()
        XCTAssertEqual(
            Set(localCalls.map(\.path)),
            Set([
                AntigravityFetcher.localQuotaSummaryPath,
                AntigravityFetcher.localUserStatusPath,
                AntigravityFetcher.localLoadCodeAssistPath,
            ])
        )
        // GetUserStatus 携带固定 metadata 请求体（原契约）；quota/GetLoadCodeAssist 为 `{}`。
        // 注：JSONEncoder 对 synthesized Codable 的键序在本 Swift 运行时不稳定
        // （两个 encoder 实例可产出同长度不同键序的 JSON），因此按解码后的
        // 字段断言，不做原始字节比对。
        let userStatusCall = try XCTUnwrap(localCalls.first { $0.path == AntigravityFetcher.localUserStatusPath })
        let recordedMetadata = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: userStatusCall.body) as? [String: Any])?["metadata"] as? [String: Any]
        )
        XCTAssertEqual(recordedMetadata["ideName"] as? String, "antigravity")
        XCTAssertEqual(recordedMetadata["extensionName"] as? String, "antigravity")
        XCTAssertEqual(recordedMetadata["ideVersion"] as? String, "unknown")
        XCTAssertEqual(recordedMetadata["locale"] as? String, "en")
        // 邮箱/tier 来自本地 GetUserStatus（凭据缺失时的账号来源）。
        XCTAssertEqual(result.accountEmail, "live@example.com")
        XCTAssertEqual(result.planLabel, "Pro Max")
    }

    // MARK: - 决策树：远端 401 → 本地回退

    func testRemote401FallsBackToLocalRPC() async throws {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.valid(),
            discovery: { try self.discoveredServer() },
            remoteHandler: { _, path in
                path == quotaPath ? (Data(), 401) : nil
            }
        )

        let result = try await fixture.fetcher.fetch(mode: .background)

        // 远端仅 daily 主机一次 401（不做主机回退、本地成功后不再重试远端）。
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls, [RemoteStub.Call(host: "daily-cloudcode-pa.googleapis.com", path: quotaPath)])
        let localCalls = await fixture.local.recorded()
        XCTAssertEqual(localCalls.map(\.path), [AntigravityFetcher.localQuotaSummaryPath])
        XCTAssertFalse(result.models.isEmpty)
        XCTAssertEqual(result.accountEmail, "user@example.com")
    }

    func testRemote401WithNoLocalBackendThrowsCredentialExpired() async throws {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.valid(),
            discovery: throwingDiscovery(),
            remoteHandler: { _, path in
                path == quotaPath ? (Data(), 401) : nil
            }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("远端 401 + 无本地后端必须抛 credentialExpired")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, "token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据")
            let localCalls = await fixture.local.recorded()
            XCTAssertTrue(localCalls.isEmpty)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    func testRemote401WithLocalRPCErrorPropagatesExistingPath() async throws {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.valid(),
            discovery: { try self.discoveredServer() },
            remoteHandler: { _, path in
                path == quotaPath ? (Data(), 401) : nil
            },
            localHandler: { _ in (Data(), 503) }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("远端 401 + 本地 RPC 500 必须按现有路径上抛 httpError")
        } catch let error as QuotaError {
            guard case .httpError(let status, _) = error else {
                return XCTFail("期望 httpError，实际 \(error)")
            }
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    // MARK: - 本地响应解析（response 包装 → 归一化共用）

    func testLocalEnvelopeParsingNormalizesGroups() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer() }
        )

        let result = try await fixture.fetcher.fetch(mode: .background)

        XCTAssertEqual(result.models.map(\.modelName), [
            "gemini_models", "gemini_argon", "claude_and_gpt_models",
        ])
        let gemini = result.models[0]
        XCTAssertEqual(gemini.intervalRemainingPercent ?? 0, 84.6885, accuracy: 0.0001)
        XCTAssertEqual(gemini.weeklyRemainingPercent ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(gemini.intervalStatus, .present)
        XCTAssertEqual(gemini.weeklyStatus, .present)
        // Argon 仅周窗：5h absent（percent 0）。
        let argon = result.models[1]
        XCTAssertEqual(argon.intervalStatus, .absent)
        XCTAssertEqual(argon.intervalRemainingPercent ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(argon.weeklyStatus, .present)
        let claude = result.models[2]
        XCTAssertEqual(claude.intervalStatus, .present)
        XCTAssertEqual(claude.weeklyStatus, .present)
        // 计数字段保持本地 RPC 语义：恒 0。
        XCTAssertEqual(gemini.intervalTotalCount, 0)
        XCTAssertEqual(gemini.weeklyTotalCount, 0)
    }

    // MARK: - CSRF 头两种形态

    func testCSRFHeaderAttachedWhenServerHasToken() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer(csrfToken: "tok-1") }
        )

        _ = try await fixture.fetcher.fetch(mode: .background)

        let localCalls = await fixture.local.recorded()
        let call = try XCTUnwrap(localCalls.first)
        XCTAssertEqual(call.headers["x-codeium-csrf-token"], "tok-1")
        XCTAssertEqual(call.headers["Content-Type"], "application/json")
    }

    func testCSRFHeaderOmittedWhenServerHasNoToken() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer(csrfToken: nil) }
        )

        _ = try await fixture.fetcher.fetch(mode: .background)

        let localCalls = await fixture.local.recorded()
        let call = try XCTUnwrap(localCalls.first)
        XCTAssertNil(call.headers["x-codeium-csrf-token"])
        // 空白 CSRF 同样视为缺失。
        XCTAssertEqual(call.headers["Content-Type"], "application/json")
    }

    // MARK: - TOCTOU 复查

    func testTOCTOUFailurePropagatesForRemoteUnauthorizedOrigin() async throws {
        let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.valid(),
            discovery: { try self.discoveredServer() },
            remoteHandler: { _, path in
                path == quotaPath ? (Data(), 401) : nil
            },
            ownership: { _ in false }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("TOCTOU 复查失败必须抛错")
        } catch let error as QuotaError {
            guard case .networkError(let message) = error else {
                return XCTFail("期望 networkError，实际 \(error)")
            }
            XCTAssertTrue(message.contains("本地服务身份已变化"), message)
            XCTAssertTrue(message.contains("pid=42"))
            // 复查失败发生在任何 RPC 之前。
            let localCalls = await fixture.local.recorded()
            XCTAssertTrue(localCalls.isEmpty)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    func testTOCTOUFailureWithExpiredCredentialFallsToCredentialExpired() async throws {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer() },
            ownership: { _ in false }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("过期凭据 + TOCTOU 复查失败必须抛 credentialExpired")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, "token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据")
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
    }

    // MARK: - 可选账号 RPC（postOptional 语义 + tier 回退链）

    func testLocalUserStatusFailureNonFatalWithTierFallback() async throws {
        let tierPath = AntigravityFetcher.localLoadCodeAssistPath
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            discovery: { try self.discoveredServer() },
            localHandler: { path in
                // quota 走默认成功形状；仅 GetUserStatus 500（可选失败）、
                // GetLoadCodeAssist 200（tier 回退链末位生效）。
                path == AntigravityFetcher.localUserStatusPath
                    ? (Data(), 500)
                    : (path == tierPath ? (Data(AntigravityLocalFallbackTests.localTierJSON.utf8), 200) : nil)
            }
        )

        let result = try await fixture.fetcher.fetch(mode: .full)

        // GetUserStatus 500 不致命；tier 落 GetLoadCodeAssist.currentTier.name
        //（回退链末位），邮箱回退 Keychain 凭据。
        XCTAssertFalse(result.models.isEmpty)
        XCTAssertEqual(result.planLabel, "Free")
        XCTAssertEqual(result.accountEmail, "user@example.com")
    }

    func testParseAccountTierFallbackChain() {
        func account(_ userStatus: UserStatus?, fallback: String?) -> AntigravityFetcher.AccountInfo {
            AntigravityFetcher.parseAccount(userStatus: userStatus, fallbackTier: fallback)
        }

        // 1. userTier.name 优先。
        XCTAssertEqual(
            account(UserStatus(email: nil, userTier: UserTier(name: "Free"), planStatus: nil), fallback: "Ignored").planLabel,
            "Free"
        )
        // 2-6. planInfo 链按序回退，空白跳过。
        XCTAssertEqual(
            account(UserStatus(
                email: nil,
                userTier: nil,
                planStatus: PlanStatus(planInfo: PlanInfo(
                    planDisplayName: "  ",
                    displayName: "Pro Plan",
                    productName: "Antigravity Pro",
                    planName: "pro-monthly",
                    planShortName: "Pro"
                ))
            ), fallback: "Ignored").planLabel,
            "Pro Plan"
        )
        XCTAssertEqual(
            account(UserStatus(
                email: nil,
                userTier: nil,
                planStatus: PlanStatus(planInfo: PlanInfo(planName: "pro-monthly", planShortName: "Pro"))
            ), fallback: "Ignored").planLabel,
            "pro-monthly"
        )
        // 7. GetLoadCodeAssist.currentTier.name 是末位回退。
        XCTAssertEqual(account(nil, fallback: "Free").planLabel, "Free")
        XCTAssertNil(account(nil, fallback: nil).planLabel)
        // 邮箱取 userStatus.email；空白视为缺失。
        XCTAssertEqual(account(UserStatus(email: " a@b.com ", userTier: nil, planStatus: nil), fallback: nil).accountEmail, "a@b.com")
        XCTAssertNil(account(UserStatus(email: "  ", userTier: nil, planStatus: nil), fallback: nil).accountEmail)
    }
}
