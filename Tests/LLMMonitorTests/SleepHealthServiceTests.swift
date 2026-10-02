import XCTest
@testable import LLM_monitor

/// `SleepHealthService` 的防休眠开关、stop() 对称复位、in-flight probe 失效与
/// 探针失败不得发布假绿。
/// 拆自 `SleepHealthTests`，逐字搬移零逻辑变化。
final class SleepHealthServiceTests: SleepHealthTestCase {

    @MainActor
    func testSleepHealthServiceStopReleasesAssertion() {
        // 时钟闭包会被捕获进 detached 任务：捕获值而非 self，才能满足 @Sendable
        let fixedNow = self.now
        let service = SleepHealthService(
            now: { fixedNow },
            assertionProbe: { [] },
            pmsetCustomReader: { "AC Power:\n sleep 15\n" }
        )

        service.setKeepAwake(true)
        XCTAssertTrue(service.isKeepAwakeOn)

        service.stop()
        XCTAssertFalse(service.isKeepAwakeOn, "stop() 必须对称复位并释放断言")
    }

    @MainActor
    func testSleepHealthServiceStopInvalidatesInFlightProbe() async {
        let entered = expectation(description: "probe starts")
        let release = DispatchSemaphore(value: 0)
        let service = SleepHealthService(
            assertionProbe: {
                entered.fulfill()
                release.wait()
                return []
            },
            powerConfigProbe: { nil }
        )

        service.refreshNow()
        await fulfillment(of: [entered], timeout: 1)
        service.stop()
        release.signal()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(service.report, "stop() 后已返回的旧 probe 不应发布 report")
    }

    /// M6: 断言探针失败时「探不到」≠「无违规」——按空快照评估会把探针失败
    /// 包装成 .healthy（假绿）。失败轮次不得发布任何健康报告；探针恢复后重新发布。
    @MainActor
    func testAssertionProbeFailureDoesNotPublishFalseGreen() async {
        final class ProbeState {
            var calls = 0
        }
        let state = ProbeState()
        let service = SleepHealthService(
            assertionProbe: {
                state.calls += 1
                if state.calls == 1 {
                    throw SleepHealthError.probeUnavailable("IOPMCopyAssertionsByProcess 失败：IOReturn 1")
                }
                return []
            },
            powerConfigProbe: { nil }
        )

        // 第一轮：断言探针失败 → 不发布健康结论
        service.refreshNow()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(service.report, "断言探针失败时不得发布健康报告（探不到 ≠ 无违规）")

        // 第二轮：探针恢复 → 重新发布
        service.refreshNow()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.report?.status, .healthy, "探针恢复后应重新发布健康结论")
    }

    /// L4: stop() 清除旧报告——停止评估后不给任何健康结论，UI 不得继续显示
    /// 停止前的三色状态。
    @MainActor
    func testStopClearsPreviousReport() async {
        let service = SleepHealthService(
            assertionProbe: { [] },
            powerConfigProbe: { nil }
        )

        service.refreshNow()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(service.report, "前置条件：刷新完成后应有报告")

        service.stop()
        XCTAssertNil(service.report, "stop() 必须清除旧报告")
        XCTAssertFalse(service.isKeepAwakeOn, "stop() 仍须对称复位防休眠开关")
    }
}
