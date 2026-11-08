import Foundation
import XCTest
@testable import LLM_monitor

/// 2.5.0 Antigravity 凭据策略决策树（`AntigravityFetcher.fetch`）的分支契约：
///
/// 1. ls 可用 → 本地 RPC（正路径见 `AntigravityLocalFallbackTests`）
/// 2. `accessTokenFallback` 关 → 统一提示（含「或在终端运行 agy models 手动刷新」）
/// 3. keychain access_token 未过期 → 远端（内存缓存优先）；远端 401 视同凭据不可用
/// 4. `allowTokenRefresh` 关 / 退避中 → 同 2 的提示
/// 5. 运行 agy models → 重读 keychain：新 token → 远端；失败/仍过期 → 退避 + 提示
///    （invalid_grant → 「请重新登录 Antigravity」）
final class AntigravityCredentialDecisionTreeTests: XCTestCase {
    private static let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private static let quotaPath = AntigravityFetcher.remoteQuotaSummaryPath
    /// 2.5.0 统一提示（步骤 2 / 4 / 5 普通失败共用）。
    private static let unifiedHint = "无法获取 Antigravity 额度：打开 Antigravity 可继续监控额度，重新登录可刷新凭据，或在终端运行 agy models 手动刷新"
    private static let reloginHint = "Antigravity 凭据已失效（invalid_grant）：请重新登录 Antigravity"

    private static let quotaJSON = """
    {"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.9}]}]}
    """

    // MARK: - Fixtures

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
            return handler(host, path) ?? (Data(AntigravityCredentialDecisionTreeTests.quotaJSON.utf8), 200)
        }

        func recorded() -> [Call] { calls }
    }

    private struct Fixture {
        let remote: RemoteStub
        let policy: AntigravityCredentialPolicy
        let reader: AntigravityCountingCredentialReader
        let runner: AntigravityTestAgyRunner
        let clock: AntigravityTestClock
        let fetcher: AntigravityFetcher
    }

    /// 统一 fixture：独立 policy（可控时钟 + 计数 reader + 记录 runner）+
    /// 「无本地后端」发现 stub（决策树第 1 步立即跳过）。`reader` 可预建传入，
    /// 供 runner stub 内调用 `setCredential` 模拟「agy 刷新写回 keychain」。
    private func makeFixture(
        credential: AntigravityCredential? = AntigravityCredentialFixtures.valid(),
        accessTokenFallback: Bool = true,
        autoRefresh: Bool = true,
        keychainOutcome: AntigravityKeychain.KeychainReadOutcome = .entryMissing,
        agyLocated: String? = "/usr/local/bin/agy",
        remoteHandler: @escaping @Sendable (String, String) -> (Data, Int)? = { _, _ in nil },
        runnerResult: (@Sendable (_ callIndex: Int) async throws -> AntigravityAgyRunOutcome)? = nil,
        externalReader: AntigravityCountingCredentialReader? = nil
    ) -> Fixture {
        let clock = AntigravityTestClock()
        let reader = externalReader ?? AntigravityCountingCredentialReader(credential: credential)
        let runner = AntigravityTestAgyRunner { callIndex in
            if let runnerResult {
                return try await runnerResult(callIndex)
            }
            return .success
        }
        let remote = RemoteStub(handler: remoteHandler)
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            keychainOutcomeReader: { keychainOutcome },
            agyLocator: { agyLocated },
            agyRunner: { executable in
                XCTAssertEqual(executable, "/usr/local/bin/agy")
                return try await runner.run(executablePath: executable)
            },
            clock: { clock.date() }
        )
        let fetcher = AntigravityFetcher(
            credentialReader: { reader.read() },
            hubVersionProvider: { nil },
            remotePostOverride: { host, path, headers, body in
                try await remote.handle(host: host, path: path, headers: headers, body: body)
            },
            localServerDiscovery: {
                throw QuotaError.networkError("stub: 无本地后端")
            },
            policy: policy,
            accessTokenFallbackEnabled: accessTokenFallback,
            autoRefreshEnabled: autoRefresh,
            refreshIntervalSeconds: 300
        )
        return Fixture(
            remote: remote,
            policy: policy,
            reader: reader,
            runner: runner,
            clock: clock,
            fetcher: fetcher
        )
    }

    // MARK: - 步骤 2：accessTokenFallback 关

    func testAccessTokenFallbackOffEndsWithHintAndNoProbes() async {
        let fixture = makeFixture(accessTokenFallback: false)

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("兜底关闭必须抛统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        // 钥匙串零读取、远端零请求、agy 零运行。
        XCTAssertEqual(fixture.reader.readCount, 0)
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertTrue(remoteCalls.isEmpty)
        XCTAssertEqual(fixture.runner.callCount, 0)
    }

    /// 预检发现钥匙串授权被拒 → 开关运行时自动 disable：即使 config 开启且
    /// credentialReader 仍可返回凭据，也不走远端。
    func testPreflightKeychainDeniedDisablesFallbackEvenWithReadableCredential() async {
        let fixture = makeFixture(
            autoRefresh: false,
            keychainOutcome: .accessDenied
        )
        fixture.policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)
        XCTAssertFalse(fixture.policy.isAccessTokenFallbackActive(configEnabled: true))

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("预检自动 disable ① 必须落统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertEqual(fixture.reader.readCount, 0, "自动 disable 后不读钥匙串")
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertTrue(remoteCalls.isEmpty)
    }

    // MARK: - 步骤 3：keychain token → 远端（内存缓存优先）

    func testFreshTokenGoesRemoteWithoutAgy() async throws {
        let fixture = makeFixture(autoRefresh: false)

        let result = try await fixture.fetcher.fetch(mode: .background)

        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls, [RemoteStub.Call(host: Self.dailyHost, path: Self.quotaPath)])
        XCTAssertEqual(result.antigravityQuotaSource, .remoteCloudCode)
        XCTAssertEqual(result.accountEmail, "user@example.com")
        XCTAssertEqual(fixture.runner.callCount, 0)
        // 首拍：内存缓存冷 → 读一次钥匙串。
        XCTAssertEqual(fixture.reader.readCount, 1)
    }

    /// 连续两拍：第二拍内存缓存命中 → 不再读钥匙串（省钥匙串访问）。
    func testMemoryCacheHitSkipsKeychainReadAcrossFetches() async throws {
        let fixture = makeFixture(autoRefresh: false)

        _ = try await fixture.fetcher.fetch(mode: .background)
        _ = try await fixture.fetcher.fetch(mode: .background)

        XCTAssertEqual(fixture.reader.readCount, 1, "缓存命中时不读钥匙串")
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls.count, 2)
    }

    /// token 本地未过期但远端 401 → 视同凭据不可用，走刷新/提示分支。
    func testRemote401WithFreshTokenFallsIntoCredentialBranch() async {
        let fixture = makeFixture(
            autoRefresh: false,
            remoteHandler: { _, path in
                path == Self.quotaPath ? (Data(), 401) : nil
            }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("远端 401（autoRefresh 关）必须落统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        // 仅 401 终止主机回退，不做主机轮换。
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls, [RemoteStub.Call(host: Self.dailyHost, path: Self.quotaPath)])
        XCTAssertEqual(fixture.runner.callCount, 0)
    }

    // MARK: - 步骤 4：autoRefresh 关 / 退避中

    func testAutoRefreshOffHintsWithAgyModelsCopy() async {
        let fixture = makeFixture(credential: AntigravityCredentialFixtures.expired(), autoRefresh: false)

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("autoRefresh 关必须抛统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint, "步骤 4 与步骤 2 同文案（含 agy models 手动刷新）")
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertEqual(fixture.runner.callCount, 0, "autoRefresh 关不运行 agy")
    }

    /// 预检发现找不到 agy CLI → ② 运行时自动 disable：过期 token 直接落提示。
    func testPreflightAgyMissingSkipsAgyRun() async {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            agyLocated: nil
        )
        fixture.policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)
        XCTAssertFalse(fixture.policy.isAutoRefreshActive(configEnabled: true))

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("预检自动 disable ② 必须落统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertEqual(fixture.runner.callCount, 0)
    }

    // MARK: - 步骤 5：agy models 代理刷新

    /// token 过期 + autoRefresh 开 → 运行 agy → 重读 keychain（新 token 未过期）
    /// → 远端（来源仍是 remoteCloudCode）。
    func testExpiredTokenWithAutoRefreshRunsAgyThenRemote() async throws {
        let reader = AntigravityCountingCredentialReader(credential: AntigravityCredentialFixtures.expired())
        let fixture = makeFixture(
            credential: nil,
            runnerResult: { _ in
                // agy 认证流写回 keychain：重读拿到未过期的新 token。
                reader.setCredential(AntigravityCredentialFixtures.valid())
                return .success
            },
            externalReader: reader
        )

        let result = try await fixture.fetcher.fetch(mode: .background)

        XCTAssertEqual(fixture.runner.callCount, 1)
        // 重读发生在 agy 成功之后（首读过期 1 次 + agy 后强制重读 1 次）。
        XCTAssertEqual(fixture.reader.readCount, 2)
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls, [RemoteStub.Call(host: Self.dailyHost, path: Self.quotaPath)])
        XCTAssertEqual(result.antigravityQuotaSource, .remoteCloudCode)
        XCTAssertFalse(fixture.policy.isBackedOff(), "刷新成功不退避")
    }

    /// agy 失败 → 退避一个刷新周期 + 统一提示；退避期内下一拍不再调 agy。
    func testAgyFailureStartsBackoffAndSkipsAgyUntilExpiry() async {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            runnerResult: { _ in .failure(reloginRequired: false) }
        )

        for round in 0..<2 {
            do {
                _ = try await fixture.fetcher.fetch(mode: .background)
                XCTFail("agy 失败必须抛统一提示")
            } catch let error as QuotaError {
                guard case .credentialExpired = error else {
                    return XCTFail("期望 credentialExpired，实际 \(error)")
                }
                XCTAssertEqual(error.errorDescription, Self.unifiedHint)
            } catch {
                XCTFail("期望 QuotaError，实际 \(error)")
            }
            if round == 0 {
                XCTAssertTrue(fixture.policy.isBackedOff())
                XCTAssertEqual(fixture.runner.callCount, 1)
            }
        }
        XCTAssertEqual(fixture.runner.callCount, 1, "退避期内不再运行 agy")
        XCTAssertEqual(fixture.reader.readCount, 2, "退避拍只重读一次钥匙串（agy 成功路径的重读不存在）")

        // 退避期（300s）结束 → 下一拍重新运行 agy。
        fixture.clock.advance(300)
        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("agy 持续失败仍必须抛统一提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertEqual(fixture.runner.callCount, 2, "退避过期后重试 agy")
    }

    /// invalid_grant 类失败 → 「请重新登录 Antigravity」提示（同样退避）。
    func testReloginFailureThrowsReloginCopy() async {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            runnerResult: { _ in .failure(reloginRequired: true) }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("invalid_grant 失败必须抛重新登录提示")
        } catch let error as QuotaError {
            guard case .credentialReloginRequired = error else {
                return XCTFail("期望 credentialReloginRequired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.reloginHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertTrue(fixture.policy.isBackedOff())
    }

    /// agy 成功但重读 keychain 仍过期 → 退避 + 统一提示。
    func testAgySuccessButKeychainStillExpiredBacksOff() async {
        let fixture = makeFixture(
            credential: AntigravityCredentialFixtures.expired(),
            runnerResult: { _ in .success }
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("agy 成功但 keychain 仍过期必须退避 + 提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertTrue(fixture.policy.isBackedOff())
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertTrue(remoteCalls.isEmpty, "无可用 token 不打远端")
    }

    /// agy 刷新后的全新 token 仍被远端 401 → 退避避免每拍空转。
    func testAgySuccessFreshTokenButRemote401BacksOff() async {
        let reader = AntigravityCountingCredentialReader(credential: AntigravityCredentialFixtures.expired())
        let fixture = makeFixture(
            credential: nil,
            remoteHandler: { _, _ in (Data(), 401) },
            runnerResult: { _ in
                reader.setCredential(AntigravityCredentialFixtures.valid())
                return .success
            },
            externalReader: reader
        )

        do {
            _ = try await fixture.fetcher.fetch(mode: .background)
            XCTFail("agy 刷新后仍 401 必须退避 + 提示")
        } catch let error as QuotaError {
            guard case .credentialExpired = error else {
                return XCTFail("期望 credentialExpired，实际 \(error)")
            }
            XCTAssertEqual(error.errorDescription, Self.unifiedHint)
        } catch {
            XCTFail("期望 QuotaError，实际 \(error)")
        }
        XCTAssertTrue(fixture.policy.isBackedOff())
        XCTAssertEqual(fixture.runner.callCount, 1)
        let remoteCalls = await fixture.remote.recorded()
        XCTAssertEqual(remoteCalls.count, 1, "过期 token 不打远端；仅 agy 刷新后的远端重试 401 一次")
    }
}
