import XCTest
@testable import LLM_monitor

/// 睡眠断言快照的白名单过滤与 offender 身份/排序决策。
/// 拆自 `SleepHealthTests`，逐字搬移零逻辑变化。
final class SleepAssertionFilterTests: SleepHealthTestCase {

    // MARK: - filterOffenders

    func testFilterOffendersExcludesSystemWhitelistedAssertions() {
        let snapshots = [
            // powerd 屏幕亮断言："Powerd - Prevent sleep while display is on"
            snapshot(
                type: "PreventUserIdleSystemSleep",
                detail: "Powerd - Prevent sleep while display is on",
                owner: "powerd",
                pid: 334
            ),
            // bluetoothd 的 com.apple.BTStack
            snapshot(
                type: "PreventUserIdleSystemSleep",
                detail: "com.apple.BTStack",
                owner: "bluetoothd",
                pid: 385
            ),
            // WindowServer 的鼠标键盘 UserIsActive（类型过滤天然排除）
            snapshot(type: "UserIsActive", detail: "LocalHardwareKeyboard", owner: "WindowServer", pid: 393),
            // loginwindow / hidd 同属白名单
            snapshot(type: "PreventSystemSleep", detail: nil, owner: "loginwindow", pid: 111),
            snapshot(type: "NoIdleSleepAssertion", detail: nil, owner: "hidd", pid: 112),
        ]

        XCTAssertTrue(SleepHealthEvaluator.filterOffenders(snapshots: snapshots, ownPID: 999, now: now).isEmpty)
    }

    func testFilterOffendersExcludesOwnPIDAndLevelOff() {
        let snapshots = [
            // 本 App 自己的防休眠断言：避免自查自报
            snapshot(
                type: "PreventUserIdleSystemSleep",
                detail: "LLM-Monitor Keep-Awake",
                owner: "LLM-monitor",
                pid: 42_000
            ),
            // level 非 On（255）的断言不构成阻塞
            snapshot(type: "PreventUserIdleSystemSleep", owner: "SomeApp", pid: 200, levelOn: false),
            // 类型不在睡眠锁集合内
            snapshot(type: "NoDisplaySleepAssertion", owner: "VideoApp", pid: 201),
            // pid 缺失的未知进程断言应保留（pid 记 0）
            snapshot(type: "PreventSystemSleep", owner: "MysteryDaemon", pid: nil),
        ]

        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: snapshots, ownPID: 42_000, now: now,
            pathProvider: { _ in nil }
        )
        XCTAssertEqual(offenders.count, 1)
        XCTAssertEqual(offenders.first?.processName, "MysteryDaemon")
        XCTAssertEqual(offenders.first?.pid, 0)
    }

    func testFilterOffendersKeepsThirdPartyAssertionsWithHeldSeconds() {
        let zcode = snapshot(
            type: "NoIdleSleepAssertion",
            detail: "Electron",
            owner: "ZCode",
            pid: 55_585,
            createdSecondsAgo: 90
        )
        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: [zcode], ownPID: 1, now: now,
            // 注入 nil 路径解析，隔离真机进程状态（PID 可能被系统进程复用）
            pathProvider: { _ in nil }
        )
        XCTAssertEqual(offenders.count, 1)
        XCTAssertEqual(offenders[0].pid, 55_585)
        XCTAssertEqual(offenders[0].processName, "ZCode")
        XCTAssertEqual(offenders[0].assertionType, "NoIdleSleepAssertion")
        XCTAssertEqual(offenders[0].detail, "Electron")
        XCTAssertEqual(offenders[0].heldSeconds, 90, accuracy: 0.001)
    }

    // 真机实测：/usr/libexec/sharingd 持有 PreventUserIdleSystemSleep "Handoff"，
    // 属系统正常行为；按可执行路径判定系统自有进程，不按名称逐个打补丁。
    func testFilterOffendersExcludesSystemDaemonByExecutablePath() {
        let snapshots = [
            snapshot(type: "PreventUserIdleSystemSleep", detail: "Handoff", owner: "sharingd", pid: 668),
            snapshot(type: "NoIdleSleepAssertion", detail: "Electron", owner: "ZCode", pid: 555),
        ]
        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: snapshots, ownPID: 1, now: now,
            pathProvider: { pid in
                pid == 668 ? "/usr/libexec/sharingd" : "/Applications/ZCode.app/Contents/MacOS/ZCode"
            }
        )
        XCTAssertEqual(offenders.map(\.processName), ["ZCode"])
    }

    func testFilterOffendersKeepsUnknownProcessWhenPathUnresolvable() {
        // 路径解析失败且名称不在白名单：保守按第三方处理（宁误报不漏报）
        let mystery = snapshot(type: "PreventUserIdleSystemSleep", owner: "MysteryDaemon", pid: 400)
        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: [mystery], ownPID: 1, now: now,
            pathProvider: { _ in nil }
        )
        XCTAssertEqual(offenders.count, 1)
        XCTAssertEqual(offenders.first?.processName, "MysteryDaemon")
    }

    func testFilterOffendersHandlesMissingFieldsAndSortsByHeldSeconds() {
        let snapshots = [
            snapshot(type: "NoIdleSleepAssertion", owner: "NewApp", pid: 300, createdSecondsAgo: 10),
            snapshot(type: "PreventUserIdleSystemSleep", owner: "OldApp", pid: 301, createdSecondsAgo: 3600),
            // creationDate 缺失按 heldSeconds = 0；ownerName 缺省「未知」；detail 缺省空串
            snapshot(type: "PreventSystemSleep", owner: nil, pid: 302, createdSecondsAgo: nil),
            // 未来时间戳（时钟偏差）不得产生负持有时长
            snapshot(type: "NoIdleSleepAssertion", owner: "FutureApp", pid: 303, createdSecondsAgo: -60),
        ]

        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: snapshots, ownPID: 1, now: now,
            pathProvider: { _ in nil }
        )
        XCTAssertEqual(offenders.map(\.processName), ["OldApp", "NewApp", "未知", "FutureApp"])
        XCTAssertEqual(offenders[0].heldSeconds, 3600)
        XCTAssertEqual(offenders[1].heldSeconds, 10)
        XCTAssertEqual(offenders[2].heldSeconds, 0)
        XCTAssertEqual(offenders[2].detail, "")
        XCTAssertEqual(offenders[3].heldSeconds, 0)
    }

    func testOffenderIdPrioritizesAssertionIdToAvoidCollisions() {
        let s1 = snapshot(
            assertionId: 12345,
            type: "NoIdleSleepAssertion",
            detail: "Electron",
            owner: "AppA",
            pid: 500
        )
        let s2 = snapshot(
            assertionId: 12346,
            type: "NoIdleSleepAssertion",
            detail: "Electron",
            owner: "AppA",
            pid: 500
        )

        let offenders = SleepHealthEvaluator.filterOffenders(
            snapshots: [s1, s2],
            ownPID: 1,
            now: now,
            pathProvider: { _ in nil }
        )

        XCTAssertEqual(offenders.count, 2)
        XCTAssertEqual(offenders[0].id, "12345")
        XCTAssertEqual(offenders[1].id, "12346")
        XCTAssertNotEqual(offenders[0].id, offenders[1].id, "同一进程相同类型的多条断言不应产生重复 id")
    }
}
