import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 状态 / 排期类测试的共享基类与共享替身。
///
/// 下面这个类只放跨文件复用的方法：`tearDown` 复位 `AuthProber` 的测试钩子，以及被
/// 5 个测试文件调用的 `makeIsolatedConfigStore`。其余 fixture 跟着各自的测试走。
///
/// 类声明之后的类型是**跨测试文件共用**的替身，原先全部是文件作用域 `private`
/// （`SchedulerTestClock` / `TestQuotaFetcher`）或某个测试类里的嵌套类型
/// （`ModeLog` / `WeakSchedulerHolder` / `CallCounter` / `SlowProbeControl` /
/// `TestAsyncGate` / `SlowFetcher`）—— 拆文件后必须提到模块内可见。
class StateTestCase: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated {
            AuthProber.testAfterCancellationCheck = nil
        }
        super.tearDown()
    }

    @MainActor
    func makeIsolatedConfigStore() -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-config-test-\(UUID().uuidString)", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return ConfigStore(configURL: configURL)
    }
}


final class SchedulerTestClock: @unchecked Sendable {
    var date: Date

    init(date: Date) {
        self.date = date
    }

    func advance(by seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

struct TestQuotaFetcher: QuotaFetcher {
    let providerID: String
    let displayName: String
    let kind: ProviderKind

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        QuotaInfo(models: [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date())
    }

    func hasLocalAuth() -> Bool { true }
}

    /// 假 scanner：模拟 @Published lastResult / isScanning，能从外部 push 状态。
    /// 做成泛型类，方便 `MinimaxLocalUsage` / `AntigravityLocalUsage` 各造一个。
    @MainActor
    final class FakeLocalScanner<Usage: Equatable & Sendable>: LocalUsageScanner {
        let usage: Usage
        var scanCount = 0
        // 内部 CurrentValueSubject，模拟 @Published
        let resultSubject = CurrentValueSubject<Usage?, Never>(nil)
        let scanningSubject = CurrentValueSubject<Bool, Never>(false)

        init(usage: Usage) { self.usage = usage }

        func scan() {
            scanCount += 1
            scanningSubject.send(true)
            // 模拟一次 scan 立刻产出一个非 nil 结果
            scanningSubject.send(false)
            resultSubject.send(usage)
        }

        func scan(mode: LocalUsageScanMode) { scan() }

        var isDirty: Bool { false }
        var lastFreshAt: Date? { nil }
        func markDirty() {}
        func markFresh(at date: Date) {}
        func waitUntilSettled() async throws {}

        func cancelInFlight() {
            // 测试 fake: no-op (没有 in-flight task 概念)
        }

        var lastResultPublisher: AnyPublisher<Usage?, Never> { resultSubject.eraseToAnyPublisher() }
        var isScanningPublisher: AnyPublisher<Bool, Never> { scanningSubject.eraseToAnyPublisher() }
    }

    /// 跨 actor 边界的轻量计数器。让 refreshHandler 闭包能异步记录被调次数。
    actor CallCounter {
        private(set) var calls: Int = 0
        private(set) var lastMode: RefreshMode = .full

        func tickCalled(mode: RefreshMode) {
            calls += 1
            lastMode = mode
        }
    }

    /// 记录 refresh handler 收到的 mode 序列；record 返回记录后的总数。
    actor ModeLog {
        private var modes: [RefreshMode] = []
        func record(_ mode: RefreshMode) -> Int {
            modes.append(mode)
            return modes.count
        }
        func snapshot() -> [RefreshMode] { modes }
    }

    /// 持有 scheduler 的弱引用，供 handler 在记满后自行 cancelAll。
    /// @unchecked Sendable：handler 与 scheduler 都在 MainActor，访问串行。
    final class WeakSchedulerHolder: @unchecked Sendable {
        weak var sched: ProviderRefreshScheduler?
    }

    /// 跟 `CallCounter` 配合：用可控的 `hasLocalAuth` / `checkLocalAuth` 模拟本地服务
    /// 状态。每个 providerID 一个 fetcher，登记到 `fetcherMap` 里供测试构造 prober。
    ///
    /// 非 `@MainActor`：要让 `QuotaFetcher` (`Sendable`) 的 conformance 合法，
    /// class 本身不能 actor-isolated。`hasLocalAuthResult` / `checkLocalAuthResult` /
    /// `checkLocalAuthCalls` 在测试中只在主线程改，安全。
    final class FakeFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let logTag: String

        var hasLocalAuthResult: Bool
        var checkLocalAuthResult: Bool
        /// checkLocalAuth 调用次数（用于断言"确实发起了探测"）
        var checkLocalAuthCalls: Int = 0

        init(providerID: String, hasLocalAuth: Bool, checkLocalAuth: Bool) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = .antigravity  // 测试只需满足 usesExternalAuth = true 即可
            self.logTag = "[\(providerID)]"
            self.hasLocalAuthResult = hasLocalAuth
            self.checkLocalAuthResult = checkLocalAuth
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { hasLocalAuthResult }
        func checkLocalAuth() async -> Bool {
            checkLocalAuthCalls += 1
            return checkLocalAuthResult
        }
    }

    actor SlowProbeControl {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var resultContinuation: CheckedContinuation<Bool, Never>?

        func waitForResult() async -> Bool {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return await withCheckedContinuation { continuation in
                resultContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resume(_ result: Bool) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }

    actor TestAsyncGate {
        private var reached = false
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func hold() async {
            reached = true
            let waiters = reachWaiters
            reachWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilReached() async {
            if reached { return }
            await withCheckedContinuation { continuation in
                reachWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// 让 refresh fetch 停在网络等待处，精确验证 full refresh waiter 的取消传播。
    final class BlockingRefreshFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID = "refresh_wait_cancel"
        let displayName = "refresh_wait_cancel"
        let kind = ProviderKind.codexChatGpt
        let logTag = "[refresh_wait_cancel]"
        let gate = TestAsyncGate()
        let calls = CallCounter()

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            await calls.tickCalled(mode: mode)
            await gate.hold()
            return QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    final class SlowFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID = "a"
        let displayName = "a"
        let kind = ProviderKind.antigravity
        let logTag = "[a]"
        let control = SlowProbeControl()

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            QuotaInfo(
                models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }

        func checkLocalAuth() async -> Bool {
            await control.waitForResult()
        }
    }

    /// 可控 throw 的 fetcher，用来验证 AppState catch 里的取消分支
    final class ErrorThrowingFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let logTag: String
        /// 每次 fetch 调用都会抛这个错误；nil 时返回成功
        var errorToThrow: Error?
        /// fetch 调用次数
        var fetchCallCount: Int = 0

        init(providerID: String, kind: ProviderKind = .codexChatGpt, errorToThrow: Error? = nil) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = kind
            self.logTag = "[\(providerID)]"
            self.errorToThrow = errorToThrow
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            fetchCallCount += 1
            if let errorToThrow {
                throw errorToThrow
            }
            return QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }
