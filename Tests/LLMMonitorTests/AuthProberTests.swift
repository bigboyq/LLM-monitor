import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 鉴权探测的缓存、取消与 onChange 触发。对应 `AuthProber`。
final class AuthProberTests: StateTestCase {

    // MARK: - AuthProber: 探测 cache + 取消 + onChange 触发
    @MainActor
    func makeTestProber(
        fetchers: [String: FakeFetcher],
        onChange: @escaping (String, Bool) -> Void = { _, _ in }
    ) -> AuthProber {
        AuthProber(
            fetcherProvider: { providerID in fetchers[providerID] },
            onChange: onChange
        )
    }
    /// scheduleProbe 三个分支 + 探测结果双路径：
    /// - canProbe = true + checkLocalAuth = true → cache=true, onChange(true)
    /// - canProbe = true + checkLocalAuth = false → cache=false, onChange(false)
    /// - canProbe = false（hasLocalAuth=false） → 不启动 task, cache 保持 nil
    /// - canProbe = false（fetcherProvider=nil） → 不启动 task
    @MainActor
    func testAuthProberScheduleProbeDispatch() async {
        // 1. canProbe = true, checkLocalAuth = true → cache=true + onChange(true)
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var firedID: String?
            var firedAvailable: Bool?
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { id, isAvailable in
                    firedID = id
                    firedAvailable = isAvailable
                }
            )
            XCTAssertTrue(prober.scheduleProbe(for: "a"), "canProbe=true 应启动 task")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 1, "checkLocalAuth 真的被调了")
            XCTAssertEqual(prober.availability["a"], true)
            XCTAssertFalse(prober.isUnavailable("a"))
            XCTAssertEqual(firedID, "a")
            XCTAssertEqual(firedAvailable, true)
        }
        // 2. canProbe = true, checkLocalAuth = false → cache=false + onChange(false)
        do {
            let fetcher = FakeFetcher(providerID: "b", hasLocalAuth: true, checkLocalAuth: false)
            var firedID: String?
            var firedAvailable: Bool?
            let prober = makeTestProber(
                fetchers: ["b": fetcher],
                onChange: { id, isAvailable in
                    firedID = id
                    firedAvailable = isAvailable
                }
            )
            prober.scheduleProbe(for: "b")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(prober.availability["b"], false)
            XCTAssertTrue(prober.isUnavailable("b"), "isUnavailable 应返回 true（cache=false）")
            XCTAssertEqual(firedID, "b")
            XCTAssertEqual(firedAvailable, false)
        }
        // 3. canProbe = false（hasLocalAuth=false） → 不启动 task, cache 保持 nil
        do {
            let fetcher = FakeFetcher(providerID: "c", hasLocalAuth: false, checkLocalAuth: true)
            let prober = makeTestProber(fetchers: ["c": fetcher])
            XCTAssertFalse(prober.scheduleProbe(for: "c"), "hasLocalAuth=false 时 scheduleProbe 应返回 false")
            XCTAssertNil(prober.availability["c"], "cache 保持 nil")
            XCTAssertFalse(prober.isUnavailable("c"), "nil 不应被算作不可用")
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 0, "checkLocalAuth 不应被调")
        }
        // 4. canProbe = false（fetcherProvider=nil, provider 没在 config 里） → 不启动 task
        do {
            let prober = makeTestProber(fetchers: [:])
            XCTAssertFalse(prober.scheduleProbe(for: "ghost"), "fetcherProvider=nil 时 scheduleProbe 应返回 false")
        }
    }
    @MainActor
    func testAuthProberGenerationsGuardPreventsStaleApply() async {
        let fetcher = SlowFetcher()
        let applyGate = TestAsyncGate()
        let slowProber = AuthProber(fetcherProvider: { _ in fetcher })
        AuthProber.testAfterCancellationCheck = { await applyGate.hold() }
        defer { AuthProber.testAfterCancellationCheck = nil }

        XCTAssertTrue(slowProber.scheduleProbe(for: "a"))
        await fetcher.control.waitUntilStarted()
        await fetcher.control.resume(false)
        await applyGate.waitUntilReached()
        slowProber.cancel(providerID: "a")
        await applyGate.release()
        await Task.yield()

        XCTAssertNil(slowProber.availability["a"], "旧 generation 结果不得回写 availability")
    }
    /// markAvailable 路径：跳过 probe 直接设 cache=true + 触发 onChange。
    /// 幂等性：值未变（nil→true 或 true→true）不重复触发。
    @MainActor
    func testAuthProberMarkAvailableAndIdempotency() {
        var fires = 0
        var lastID: String?
        var lastAvailable: Bool?
        let prober = makeTestProber(
            fetchers: [:],
            onChange: { id, isAvailable in
                fires += 1
                lastID = id
                lastAvailable = isAvailable
            }
        )
        // 首次 markAvailable(nil→true)：fire 1 次
        prober.markAvailable("a")
        XCTAssertEqual(fires, 1, "首次 markAvailable 应触发 1 次 onChange")
        XCTAssertEqual(prober.availability["a"], true)
        XCTAssertFalse(prober.isUnavailable("a"))
        XCTAssertEqual(lastID, "a")
        XCTAssertEqual(lastAvailable, true)
        // 连续 markAvailable 2 次（true→true）：不重复触发
        prober.markAvailable("a")
        prober.markAvailable("a")
        XCTAssertEqual(fires, 1, "值未变时不重复触发 onChange")
        // 切到另一个 provider：fire 又 1 次
        prober.markAvailable("b")
        XCTAssertEqual(fires, 2)
        XCTAssertEqual(lastID, "b")
        XCTAssertEqual(lastAvailable, true)
    }
    /// reset / cancel / rescan 三个稳定性场景：
    /// - reset 清空 cache
    /// - 重复 scheduleProbe(值未变) 不重复 fire, fetcher 真跑了 N 次
    /// - 第一次 probe 还在跑时立刻 scheduleProbe 第二次 → 第一次被取消, 只 fire 1 次
    /// - schedule 后立刻 cancel → 跑完也不 fire, cache 仍为 nil
    @MainActor
    func testAuthProberResetCancelAndRescanStability() async {
        // 1. reset 清空 cache
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            let prober = makeTestProber(fetchers: ["a": fetcher])
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(prober.availability["a"], true, "probe 完成后 cache 已被设")
            prober.reset()
            XCTAssertNil(prober.availability["a"], "reset 应清空 cache")
        }
        // 2. 重复 scheduleProbe(值未变): 不重复 fire, 但 fetcher 真跑了 N 次
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires = 0
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, _ in fires += 1 }
            )
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fires, 1, "true→true 不重复触发 onChange")
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 2, "两次 scheduleProbe 都该真发起 checkLocalAuth")
        }
        // 3. 第一次 probe 还在跑时立刻 scheduleProbe 第二次 → 第一次被取消, 只 fire 1 次
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires: [Bool] = []
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, isAvailable in fires.append(isAvailable) }
            )
            prober.scheduleProbe(for: "a")
            prober.scheduleProbe(for: "a")  // 立刻再 schedule, 第一次 task 还没走完
            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(fires, [true], "只触发一次 onChange（true）")
            XCTAssertEqual(prober.availability["a"], true)
        }
        // 4. schedule 后立刻 cancel → 跑完也不 fire, cache 仍为 nil
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires = 0
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, _ in fires += 1 }
            )
            prober.scheduleProbe(for: "a")
            prober.cancel(providerID: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fires, 0, "cancel 后 checkLocalAuth 完成后 onChange 不应触发")
            XCTAssertNil(prober.availability["a"], "cancel 后 cache 仍为 nil")
        }
    }
}
