import XCTest
@testable import LLM_monitor

/// `SleepHealthEvaluator.evaluate` 的三色状态决策与 offender 行文案格式化。
/// 拆自 `SleepHealthTests`，逐字搬移零逻辑变化。
final class SleepHealthEvaluatorTests: SleepHealthTestCase {

    // MARK: - evaluate

    func testEvaluateKeepAwakeShortCircuitsEverything() {
        let offenders = [
            snapshot(type: "NoIdleSleepAssertion", owner: "ZCode", pid: 55_585, createdSecondsAgo: 90)
        ]
        // 开关开启时无论断言/电源配置如何都直接红色
        let status = SleepHealthEvaluator.evaluate(
            keepAwakeOn: true,
            snapshots: offenders,
            ownPID: 1,
            acSleepMinutes: 0,
            now: now,
            pathProvider: { _ in nil }
        )
        XCTAssertEqual(status, .keepAwake)
    }

    func testEvaluateBlockedByAssertionsBeatsAcSleepDisabled() {
        let offenders = [
            snapshot(type: "NoIdleSleepAssertion", owner: "ZCode", pid: 55_585, createdSecondsAgo: 90)
        ]
        // 断言黄优先于 AC 休眠黄
        let status = SleepHealthEvaluator.evaluate(
            keepAwakeOn: false,
            snapshots: offenders,
            ownPID: 1,
            acSleepMinutes: 0,
            now: now,
            pathProvider: { _ in nil }
        )
        guard case .blockedByAssertions(let listed) = status else {
            return XCTFail("期望 blockedByAssertions，实际 \(status)")
        }
        XCTAssertEqual(
            listed,
            SleepHealthEvaluator.filterOffenders(
                snapshots: offenders, ownPID: 1, now: now,
                pathProvider: { _ in nil }
            )
        )
        XCTAssertEqual(listed.first?.heldSeconds ?? -1, 90, accuracy: 0.001)
    }

    func testEvaluateAcSleepDisabledWhenNoOffenders() {
        let status = SleepHealthEvaluator.evaluate(
            keepAwakeOn: false,
            snapshots: [],
            ownPID: 1,
            acSleepMinutes: 0,
            now: now
        )
        XCTAssertEqual(status, .acSleepDisabled)
    }

    func testEvaluateHealthyAndUnknownAcSleepStaysGreen() {
        let systemNoise = [
            snapshot(
                type: "PreventUserIdleSystemSleep",
                detail: "Powerd - Prevent sleep while display is on",
                owner: "powerd",
                pid: 334
            ),
            snapshot(type: "UserIsActive", owner: "WindowServer", pid: 393),
        ]
        // 全部通过为绿（系统白名单断言不算违规）
        XCTAssertEqual(
            SleepHealthEvaluator.evaluate(
                keepAwakeOn: false,
                snapshots: systemNoise,
                ownPID: 1,
                acSleepMinutes: 1,
                now: now
            ),
            .healthy
        )
        // acSleep == nil 表示未读取成功，不得误判为黄
        XCTAssertEqual(
            SleepHealthEvaluator.evaluate(
                keepAwakeOn: false,
                snapshots: [],
                ownPID: 1,
                acSleepMinutes: nil,
                now: now
            ),
            .healthy
        )
    }

    /// header 悬浮清单与设置页节能 Tab 共用的行文案格式化。
    func testSleepAssertionOffenderRowText() {
        let now = Date()
        let offender = SleepAssertionOffender(
            pid: 1234,
            processName: "Electron",
            assertionType: "PreventUserIdleSystemSleep",
            detail: "Electron",
            heldSeconds: 0,
            creationDate: now.addingTimeInterval(-90)
        )
        XCTAssertEqual(
            offender.rowText(now: now),
            "Electron · PID 1234 · 阻止空闲休眠 · 已持续 01:30"
        )

        // 超过 1 小时按 h:mm:ss。
        let longHeld = SleepAssertionOffender(
            pid: 1234,
            processName: "Electron",
            assertionType: "PreventUserIdleSystemSleep",
            detail: "Electron",
            heldSeconds: 0,
            creationDate: now.addingTimeInterval(-90 * 60)
        )
        XCTAssertEqual(
            longHeld.rowText(now: now),
            "Electron · PID 1234 · 阻止空闲休眠 · 已持续 1:30:00"
        )

        // 优先按创建时间实时推算；无创建时间时回退快照的已持有时长。
        let snapshotOnly = SleepAssertionOffender(
            pid: 8,
            processName: "SomeApp",
            assertionType: "PreventSystemSleep",
            detail: "",
            heldSeconds: 3605,
            creationDate: nil
        )
        XCTAssertEqual(
            snapshotOnly.rowText(now: now),
            "SomeApp · PID 8 · 阻止系统休眠 · 已持续 1:00:05"
        )

        // 未知断言类型原样展示；负时长钳到 0。
        let unknown = SleepAssertionOffender(
            pid: 2,
            processName: "Mystery",
            assertionType: "FutureAssertion",
            detail: "",
            heldSeconds: 0,
            creationDate: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            unknown.rowText(now: now),
            "Mystery · PID 2 · FutureAssertion · 已持续 00:00"
        )
        XCTAssertEqual(SleepAssertionOffender.formatHeldDuration(-5), "00:00")
        XCTAssertEqual(SleepAssertionOffender.formatHeldDuration(59), "00:59")
        XCTAssertEqual(SleepAssertionOffender.formatHeldDuration(3600), "1:00:00")
    }
}
