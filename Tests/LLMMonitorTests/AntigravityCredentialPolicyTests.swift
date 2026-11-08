import Foundation
import XCTest
@testable import LLM_monitor

/// 2.5.0 凭据策略共享测试设施：可控时钟、计数型钥匙串 reader、记录型 agy runner。
/// 被 `AntigravityCredentialPolicyTests` / `AntigravityCredentialDecisionTreeTests` 使用。
final class AntigravityTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ now: Date = Date()) {
        self.now = now
    }

    func date() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// 记录钥匙串读取次数的凭据 reader（`setCredential` 可在 agy runner stub 内
/// 调用，模拟「agy 刷新写回 keychain → 重读拿到新 token」）。
final class AntigravityCountingCredentialReader: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var credential: AntigravityCredential?

    init(credential: AntigravityCredential?) {
        self.credential = credential
    }

    func read() -> AntigravityCredential? {
        lock.lock()
        count += 1
        lock.unlock()
        return credential
    }

    func setCredential(_ credential: AntigravityCredential?) {
        lock.lock()
        self.credential = credential
        lock.unlock()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// 记录调用次数与并发峰值的 agy runner stub（mutex 串行化验证用）。
/// 计数状态收进同步方法（NSLock 不直接出现在 async 上下文）。
final class AntigravityTestAgyRunner: @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var inFlight = 0
        private var peakInFlight = 0

        func begin() -> Int {
            lock.lock()
            calls += 1
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            let index = calls
            lock.unlock()
            return index
        }

        func end() {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        var maxConcurrentCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return peakInFlight
        }
    }

    private let counter = Counter()
    private let result: @Sendable (_ callIndex: Int) async throws -> AntigravityAgyRunOutcome

    init(result: @escaping @Sendable (_ callIndex: Int) async throws -> AntigravityAgyRunOutcome) {
        self.result = result
    }

    func run(executablePath: String) async throws -> AntigravityAgyRunOutcome {
        let index = counter.begin()
        defer { counter.end() }
        return try await result(index)
    }

    var callCount: Int { counter.callCount }
    var maxConcurrentCalls: Int { counter.maxConcurrentCalls }
}

/// 测试用的可变值盒子（替代被闭包捕获的局部 var，规避 Sendable 捕获告警）。
final class AntigravityTestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

/// `AntigravityCredentialPolicy` 单元契约（2.5.0）：启动预检三态、开关生效态、
/// 内存 token 缓存、agy 退避、agy 运行互斥与可执行查找。
final class AntigravityCredentialPolicyTests: XCTestCase {
    // MARK: - 启动预检

    func testPreflightReadableCredentialSeedsCacheWithoutFlags() {
        let credential = AntigravityCredentialFixtures.valid()
        let policy = AntigravityCredentialPolicy(
            credentialReader: { credential },
            keychainOutcomeReader: { .readable("go-keyring-base64:x") },
            agyLocator: { "/usr/local/bin/agy" }
        )

        policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)

        let preflight = policy.preflightSnapshot
        XCTAssertFalse(preflight.keychainAccessDenied)
        XCTAssertFalse(preflight.keychainEntryMissing)
        XCTAssertFalse(preflight.agyCLIMissing)
        // 预检读到的凭据播种内存缓存：currentCredentialForRemote 不再读钥匙串。
        XCTAssertEqual(policy.currentCredentialForRemote(), credential)
    }

    func testPreflightAccessDeniedAutoDisablesFallbackSwitch() {
        let reader = AntigravityCountingCredentialReader(credential: AntigravityCredentialFixtures.valid())
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            keychainOutcomeReader: { .accessDenied },
            agyLocator: { "/usr/local/bin/agy" }
        )

        policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)

        XCTAssertTrue(policy.preflightSnapshot.keychainAccessDenied)
        XCTAssertFalse(
            policy.isAccessTokenFallbackActive(configEnabled: true),
            "预检发现钥匙串授权被拒 → 运行时自动 disable ①"
        )
        // 自动 disable 不影响 ②。
        XCTAssertTrue(policy.isAutoRefreshActive(configEnabled: true))
        XCTAssertFalse(preflightHasEntryMissing(policy))
    }

    func testPreflightEntryMissingIsSoftUnavailableSwitchStaysActive() {
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            keychainOutcomeReader: { .entryMissing },
            agyLocator: { "/usr/local/bin/agy" }
        )

        policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)

        XCTAssertTrue(policy.preflightSnapshot.keychainEntryMissing)
        XCTAssertTrue(
            policy.isAccessTokenFallbackActive(configEnabled: true),
            "条目不存在（未登录）是软不可用：不 disable，登录后自动恢复"
        )
        XCTAssertFalse(policy.preflightSnapshot.keychainAccessDenied)
    }

    func testPreflightAgyMissingAutoDisablesAutoRefresh() {
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            keychainOutcomeReader: { .entryMissing },
            agyLocator: { nil }
        )

        policy.runPreflight(accessTokenFallbackOn: false, autoRefreshOn: true)

        XCTAssertTrue(policy.preflightSnapshot.agyCLIMissing)
        XCTAssertFalse(policy.isAutoRefreshActive(configEnabled: true))
        // ① 未探测（开关关）→ 无钥匙串结论。
        XCTAssertFalse(policy.preflightSnapshot.keychainAccessDenied)
        XCTAssertFalse(policy.preflightSnapshot.keychainEntryMissing)
    }

    func testPreflightSkipsProbesWhenSwitchesOff() {
        let reader = AntigravityCountingCredentialReader(credential: nil)
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            keychainOutcomeReader: { reader.read() != nil ? .readable("x") : .entryMissing },
            agyLocator: { "/usr/local/bin/agy" }
        )

        policy.runPreflight(accessTokenFallbackOn: false, autoRefreshOn: false)

        let preflight = policy.preflightSnapshot
        XCTAssertFalse(preflight.keychainAccessDenied)
        XCTAssertFalse(preflight.keychainEntryMissing)
        XCTAssertFalse(preflight.agyCLIMissing)
        XCTAssertEqual(reader.readCount, 0, "开关关闭的路径不做任何探测")
    }

    /// 预检失败自动 disable 后原因消除（agy 安装了）→ 用户重开开关/热重载触发
    /// 重新预检即恢复（结果整体替换，不做后台自动复活）。
    func testPreflightReRunReplacesResultsEnablingRecovery() {
        let located = AntigravityTestBox<String?>(nil)
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            keychainOutcomeReader: { .entryMissing },
            agyLocator: { located.value }
        )

        policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)
        XCTAssertTrue(policy.preflightSnapshot.agyCLIMissing)
        XCTAssertFalse(policy.isAutoRefreshActive(configEnabled: true))

        located.value = "/usr/local/bin/agy"  // 用户安装了 agy
        policy.runPreflight(accessTokenFallbackOn: true, autoRefreshOn: true)
        XCTAssertFalse(policy.preflightSnapshot.agyCLIMissing)
        XCTAssertTrue(policy.isAutoRefreshActive(configEnabled: true), "重新预检后开关恢复生效")
    }

    private func preflightHasEntryMissing(_ policy: AntigravityCredentialPolicy) -> Bool {
        policy.preflightSnapshot.keychainEntryMissing
    }

    // MARK: - 内存 token 缓存

    func testMemoryCacheHitAvoidsKeychainReread() {
        let credential = AntigravityCredentialFixtures.valid()
        let reader = AntigravityCountingCredentialReader(credential: credential)
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            clock: { Date() }
        )

        XCTAssertNil(policy.memoryCachedFreshCredential(), "缓存冷 → nil，不读钥匙串")
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(policy.currentCredentialForRemote(), credential)
        XCTAssertEqual(reader.readCount, 1)
        // 未过期的下一拍直接用内存缓存。
        XCTAssertEqual(policy.currentCredentialForRemote(), credential)
        XCTAssertEqual(reader.readCount, 1, "缓存命中时不再读钥匙串")
    }

    func testExpiredCacheTriggersKeychainReread() {
        let clock = AntigravityTestClock()
        let reader = AntigravityCountingCredentialReader(credential: AntigravityCredentialFixtures.valid())
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            clock: { clock.date() }
        )

        _ = policy.currentCredentialForRemote()
        XCTAssertEqual(reader.readCount, 1)
        clock.advance(3700)  // 超过 1h 有效期
        _ = policy.currentCredentialForRemote()
        XCTAssertEqual(reader.readCount, 2, "内存过期后重读 keychain")
    }

    func testCredentialAfterAgyRefreshForcesRereadAndUpdatesCache() {
        let clock = AntigravityTestClock()
        let reader = AntigravityCountingCredentialReader(credential: AntigravityCredentialFixtures.valid())
        let policy = AntigravityCredentialPolicy(
            credentialReader: { reader.read() },
            clock: { clock.date() }
        )

        _ = policy.currentCredentialForRemote()
        XCTAssertEqual(reader.readCount, 1)
        // 缓存仍新鲜；agy 刷新后的强制重读绕过缓存。
        _ = policy.credentialAfterAgyRefresh()
        XCTAssertEqual(reader.readCount, 2)
        // 回填后再走 currentCredentialForRemote 不重读。
        _ = policy.currentCredentialForRemote()
        XCTAssertEqual(reader.readCount, 2)
    }

    // MARK: - 退避

    func testBackoffWindowHonoredAndExpires() {
        let clock = AntigravityTestClock()
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            clock: { clock.date() }
        )

        XCTAssertFalse(policy.isBackedOff())
        policy.startBackoff(intervalSeconds: 300)
        XCTAssertTrue(policy.isBackedOff())
        clock.advance(299)
        XCTAssertTrue(policy.isBackedOff())
        clock.advance(1)
        XCTAssertFalse(policy.isBackedOff(), "退避一个刷新周期后自然过期")
    }

    // MARK: - agy 运行

    func testRunAgyRefreshUsesLocatedExecutableAndRecordsOutcome() async throws {
        let located = AntigravityTestBox<String?>("/usr/local/bin/agy")
        let executableRecorder = AntigravityTestBox<String?>(nil)
        let runner = AntigravityTestAgyRunner { callIndex in
            return callIndex == 1 ? .success : .failure(reloginRequired: true)
        }
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            agyLocator: { located.value },
            agyRunner: { executable in
                executableRecorder.value = executable
                return try await runner.run(executablePath: executable)
            }
        )

        let first = try await policy.runAgyRefresh()
        XCTAssertEqual(first, .success)
        XCTAssertEqual(executableRecorder.value, "/usr/local/bin/agy")
        located.value = nil
        let second = try await policy.runAgyRefresh()
        XCTAssertEqual(second, .failure(reloginRequired: false), "locator 为 nil 按普通失败（不 disable）")
        XCTAssertEqual(runner.callCount, 1, "locator 为 nil 时不调 runner")
    }

    /// 同一 policy 上并发的两次 agy 刷新被 AsyncMutex 串行化（峰值并发 = 1）。
    func testRunAgyRefreshIsSerializedByMutex() async throws {
        let runner = AntigravityTestAgyRunner { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return .success
        }
        let policy = AntigravityCredentialPolicy(
            credentialReader: { nil },
            agyLocator: { "/usr/local/bin/agy" },
            agyRunner: { try await runner.run(executablePath: $0) }
        )

        async let first: AntigravityAgyRunOutcome = policy.runAgyRefresh()
        async let second: AntigravityAgyRunOutcome = policy.runAgyRefresh()
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes, [.success, .success])
        XCTAssertEqual(runner.callCount, 2)
        XCTAssertEqual(runner.maxConcurrentCalls, 1, "agy models 运行必须互斥")
    }

    // MARK: - agy 可执行查找（纯函数）

    func testLocateExecutableSearchesPathDirectoriesThenLocalBin() {
        var existing: Set<String> = []
        func exists(_ path: String) -> Bool { existing.contains(path) }

        // PATH 里第一个命中即返回。
        existing = ["/usr/local/bin/agy"]
        XCTAssertEqual(
            AntigravityAgyCLI.locateExecutable(
                pathEnvironment: "/usr/bin:/usr/local/bin",
                homeDirectory: "/Users/test",
                fileExists: exists
            ),
            "/usr/local/bin/agy"
        )
        // PATH 无命中 → ~/.local/bin/agy 兜底。
        existing = ["/Users/test/.local/bin/agy"]
        XCTAssertEqual(
            AntigravityAgyCLI.locateExecutable(
                pathEnvironment: "/usr/bin:/opt/homebrew/bin",
                homeDirectory: "/Users/test",
                fileExists: exists
            ),
            "/Users/test/.local/bin/agy"
        )
        // 皆无 → nil。
        existing = []
        XCTAssertNil(
            AntigravityAgyCLI.locateExecutable(
                pathEnvironment: "/usr/bin",
                homeDirectory: "/Users/test",
                fileExists: exists
            )
        )
        // 空 PATH 与尾部斜杠目录同样安全。
        existing = ["/opt/bin/agy"]
        XCTAssertEqual(
            AntigravityAgyCLI.locateExecutable(
                pathEnvironment: ":/opt/bin/",
                homeDirectory: "/Users/test",
                fileExists: exists
            ),
            "/opt/bin/agy"
        )
        // PATH 段里同名文件（stragy / imagery）不误命中。
        existing = ["/opt/bin/stragy", "/opt/bin/imagery"]
        XCTAssertNil(
            AntigravityAgyCLI.locateExecutable(
                pathEnvironment: "/opt/bin",
                homeDirectory: "/Users/test",
                fileExists: exists
            )
        )
    }
}
