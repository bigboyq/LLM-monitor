import XCTest
@testable import LLM_monitor

/// `LocalUsageScanRunner` 的直接单测：不经 `LocalUsageScannerBase`，
/// 直接用闭包注入 work / applyResult / applyError，验证单次扫描生命周期的
/// 漏斗语义（成功 / 失败 / 取消过滤）与 generation 守门（启动放弃 / 完成丢弃 /
/// 出错丢弃）。`LocalUsageScannerBase` 之外的接线由
/// ScannerAndLoggingTests 覆盖。
final class LocalUsageScanRunnerTests: XCTestCase {

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom-message" }
    }

    /// 门闩 actor：让 work 挂起直到测试主动放行（用于注入确定性的取消时机）。
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// 记录 work 是否真的被执行（区分"守门放弃"与"work 没跑所以没写回"）。
    private actor WorkProbe {
        private(set) var runCount = 0
        func record() { runCount += 1 }
    }

    /// work 成功且 generation 未变：applyResult 收到结果，applyError 不触发
    @MainActor
    func testSuccessFunnelAppliesResultWhenGenerationUnchanged() async {
        var applied: [Int] = []
        var errors: [String] = []

        await LocalUsageScanRunner.run(
            logTag: "[runner-test]",
            startedGeneration: 7,
            latestGeneration: { 7 },
            work: { 42 },
            applyResult: { applied.append($0) },
            applyError: { errors.append($0) }
        )

        XCTAssertEqual(applied, [42], "成功路径应恰好写回一次结果")
        XCTAssertTrue(errors.isEmpty, "成功路径不应写 lastError")
    }

    /// work 抛非取消错误且 generation 未变：applyError 收到
    /// error.localizedDescription，applyResult 不触发
    @MainActor
    func testFailureFunnelAppliesLocalizedErrorMessage() async {
        var applied: [Int] = []
        var errors: [String] = []

        await LocalUsageScanRunner.run(
            logTag: "[runner-test]",
            startedGeneration: 1,
            latestGeneration: { 1 },
            work: { throw Boom() },
            applyResult: { applied.append($0) },
            applyError: { errors.append($0) }
        )

        XCTAssertTrue(applied.isEmpty, "失败路径不应写 lastResult")
        XCTAssertEqual(errors, ["boom-message"], "失败路径应写 error.localizedDescription 摘要")
    }

    /// CancellationFilter 协作：CancellationError 与 URLError.cancelled 都是
    /// 取消错误，既不写 lastResult 也不污染 lastError
    @MainActor
    func testCancellationErrorsAreFilteredWithoutWriteback() async {
        let cancellationErrors: [Error] = [CancellationError(), URLError(.cancelled)]
        for error in cancellationErrors {
            var applied: [Int] = []
            var errors: [String] = []

            await LocalUsageScanRunner.run(
                logTag: "[runner-test]",
                startedGeneration: 1,
                latestGeneration: { 1 },
                work: { throw error },
                applyResult: { applied.append($0) },
                applyError: { errors.append($0) }
            )

            XCTAssertTrue(applied.isEmpty, "\(error) 不应写 lastResult")
            XCTAssertTrue(errors.isEmpty, "\(error) 不应污染 lastError")
        }
    }

    /// work 期间任务被 Task.cancel()：即使 work 抛的是非取消错误，
    /// runner 侧 `Task.isCancelled` 也应让 CancellationFilter 吞掉它
    @MainActor
    func testTaskCancelledDuringWorkSuppressesErrorWriteback() async {
        let gate = Gate()
        var applied: [Int] = []
        var errors: [String] = []

        let task = Task { @MainActor in
            await LocalUsageScanRunner.run(
                logTag: "[runner-test]",
                startedGeneration: 1,
                latestGeneration: { 1 },
                work: {
                    await gate.wait()
                    throw Boom()
                },
                applyResult: { applied.append($0) },
                applyError: { errors.append($0) }
            )
        }

        task.cancel()
        await gate.release()
        await task.value

        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(errors.isEmpty, "已取消任务抛出的非取消错误也不应写回 lastError")
    }

    // MARK: - generation 守门

    /// 启动时 generation 已落后（cancel + 新一轮已发生）：直接放弃，work 不跑
    @MainActor
    func testStaleGenerationAbandonsRunBeforeWorkStarts() async {
        let probe = WorkProbe()
        var applied: [Int] = []
        var errors: [String] = []

        await LocalUsageScanRunner.run(
            logTag: "[runner-test]",
            startedGeneration: 3,
            latestGeneration: { 4 },
            work: {
                await probe.record()
                return 42
            },
            applyResult: { applied.append($0) },
            applyError: { errors.append($0) }
        )

        let runs = await probe.runCount
        XCTAssertEqual(runs, 0, "stale generation 的 run 应在 work 之前就放弃")
        XCTAssertTrue(applied.isEmpty, "stale generation 的 run 不应写 lastResult")
        XCTAssertTrue(errors.isEmpty, "stale generation 的 run 不应写 lastError")
    }

    /// work 成功但期间 generation 已前进（cancel + rescan 抢走 token）：结果丢弃
    @MainActor
    func testGenerationAdvancedDuringWorkDiscardsResult() async {
        let probe = WorkProbe()
        var latest: UInt64 = 1
        var applied: [Int] = []
        var errors: [String] = []

        await LocalUsageScanRunner.run(
            logTag: "[runner-test]",
            startedGeneration: 1,
            latestGeneration: { latest },
            work: {
                await probe.record()
                await MainActor.run { latest = 2 }
                return 42
            },
            applyResult: { applied.append($0) },
            applyError: { errors.append($0) }
        )

        let runs = await probe.runCount
        XCTAssertEqual(runs, 1, "work 应已执行，只是结果被守门丢弃")
        XCTAssertTrue(applied.isEmpty, "generation 已前进时成功结果必须丢弃")
        XCTAssertTrue(errors.isEmpty)
    }

    /// work 失败且期间 generation 已前进：错误同样丢弃，不写回旧状态
    @MainActor
    func testGenerationAdvancedDuringWorkDiscardsError() async {
        let probe = WorkProbe()
        var latest: UInt64 = 1
        var applied: [Int] = []
        var errors: [String] = []

        await LocalUsageScanRunner.run(
            logTag: "[runner-test]",
            startedGeneration: 1,
            latestGeneration: { latest },
            work: {
                await probe.record()
                await MainActor.run { latest = 2 }
                throw Boom()
            },
            applyResult: { applied.append($0) },
            applyError: { errors.append($0) }
        )

        let runs = await probe.runCount
        XCTAssertEqual(runs, 1, "work 应已执行，只是错误被守门丢弃")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(errors.isEmpty, "generation 已前进时错误必须丢弃")
    }
}
