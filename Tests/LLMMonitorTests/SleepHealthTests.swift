import XCTest
@testable import LLM_monitor

/// 「节能（系统睡眠健康度）」纯判定逻辑的单元测试：
/// 覆盖 SleepHealthEvaluator 的 pmset 输出解析、断言白名单过滤与三色状态评估。
/// 真机 IOKit 探针（defaultAssertionProbe / defaultPmsetCustomRead）不在此覆盖范围。
final class SleepHealthTests: XCTestCase {
    /// 真机 `pmset -g custom` 原样输出 fixture（含 "Sleep On Power Button 1"、
    /// lowpowermode、hibernatefile 路径等必须被忽略的干扰行）
    private static let pmsetFixture = """
    Battery Power:
     Sleep On Power Button 1
     lowpowermode         1
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         20
     womp                 0
     networkoversleep     0
     sleep                1
     lessbright           1
     tcpkeepalive         0
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     lowpowermode         0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         120
     womp                 1
     networkoversleep     0
     sleep                1
     tcpkeepalive         0
     disksleep            10
    """

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// 快照构造便捷方法
    private func snapshot(
        assertionId: UInt32? = nil,
        type: String,
        detail: String? = nil,
        owner: String? = "TestApp",
        pid: Int32? = 100,
        createdSecondsAgo: TimeInterval? = 0,
        levelOn: Bool = true
    ) -> SleepAssertionSnapshot {
        SleepAssertionSnapshot(
            assertionId: assertionId,
            assertionType: type,
            detailName: detail,
            ownerName: owner,
            pid: pid,
            creationDate: createdSecondsAgo.map { now.addingTimeInterval(-$0) },
            levelOn: levelOn
        )
    }

    // MARK: - parsePmsetCustomOutput

    func testParsePmsetCustomOutputFullFixture() throws {
        let config = try XCTUnwrap(SleepHealthEvaluator.parsePmsetCustomOutput(Self.pmsetFixture))

        XCTAssertEqual(config.ac.sleepMinutes, 1)
        XCTAssertEqual(config.ac.womp, 1)
        XCTAssertEqual(config.ac.tcpkeepalive, 0)
        XCTAssertEqual(config.ac.powernap, 1)
        XCTAssertEqual(config.ac.displaysleepMinutes, 120)

        let battery = try XCTUnwrap(config.battery)
        XCTAssertEqual(battery.sleepMinutes, 1)
        XCTAssertEqual(battery.womp, 0)
        XCTAssertEqual(battery.tcpkeepalive, 0)
        XCTAssertEqual(battery.powernap, 1)
        XCTAssertEqual(battery.displaysleepMinutes, 20)
    }

    func testParsePmsetCustomOutputWithoutBatterySection() {
        // 删除 Battery 节（台式机形态），只保留 AC 节
        let lines = Self.pmsetFixture.split(separator: "\n")
        let acOnly = lines.drop { !$0.hasPrefix("AC Power:") }.joined(separator: "\n")

        let config = SleepHealthEvaluator.parsePmsetCustomOutput(acOnly)
        XCTAssertNotNil(config)
        XCTAssertNil(config?.battery, "无 Battery 节时 battery 应为 nil")
        XCTAssertEqual(config?.ac.sleepMinutes, 1)
        XCTAssertEqual(config?.ac.displaysleepMinutes, 120)
        XCTAssertEqual(config?.ac.womp, 1)
    }

    func testParsePmsetCustomOutputWithoutAnySectionReturnsNil() {
        XCTAssertNil(SleepHealthEvaluator.parsePmsetCustomOutput(""))
        XCTAssertNil(SleepHealthEvaluator.parsePmsetCustomOutput("System-wide power settings:\n Currently in use:"))
        XCTAssertNil(SleepHealthEvaluator.parsePmsetCustomOutput("garbage text without sections"))
    }

    func testParsePmsetCustomOutputIsCaseAndWhitespaceTolerant() {
        let text = "   ac power:   \n  sleep   15  \n  WOMP 0\n  battery power:\n  displaysleep 7 "
        let config = SleepHealthEvaluator.parsePmsetCustomOutput(text)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.ac.sleepMinutes, 15)
        XCTAssertEqual(config?.ac.womp, 0)
        XCTAssertEqual(config?.battery?.displaysleepMinutes, 7)
    }

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

    func testParsePmPreferencesDictionary() throws {
        let dict: [AnyHashable: Any] = [
            "AC Power": [
                "System Sleep Timer": 15,
                "Wake On LAN": 1,
                "TCPKeepAlivePref": 0,
                "DarkWakeBackgroundTasks": 1,
                "Display Sleep Timer": 120
            ],
            "Battery Power": [
                "System Sleep Timer": 5,
                "Wake On LAN": 0,
                "TCPKeepAlivePref": 0,
                "DarkWakeBackgroundTasks": 0,
                "Display Sleep Timer": 15
            ]
        ]
        let config = try XCTUnwrap(SleepHealthEvaluator.parsePmPreferencesDictionary(dict))
        XCTAssertEqual(config.ac.sleepMinutes, 15)
        XCTAssertEqual(config.ac.womp, 1)
        XCTAssertEqual(config.ac.tcpkeepalive, 0)
        XCTAssertEqual(config.ac.powernap, 1)
        XCTAssertEqual(config.ac.displaysleepMinutes, 120)

        let battery = try XCTUnwrap(config.battery)
        XCTAssertEqual(battery.sleepMinutes, 5)
        XCTAssertEqual(battery.womp, 0)
        XCTAssertEqual(battery.tcpkeepalive, 0)
        XCTAssertEqual(battery.powernap, 0)
        XCTAssertEqual(battery.displaysleepMinutes, 15)
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

    @MainActor
    func testSleepHealthServiceStopReleasesAssertion() {
        let service = SleepHealthService(
            now: { self.now },
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
