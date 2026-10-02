import XCTest
@testable import LLM_monitor

/// 「节能（系统睡眠健康度）」用例的共享 fixture 基类。
///
/// 原本是 `SleepHealthTests` 内的私有 `pmsetFixture` / `now` / `snapshot(...)`，
/// 被 pmset 解析、断言过滤、评估与服务四组用例同时引用；拆文件时抽到这里由子类
/// 继承，调用点一个字符都不用改（沿用 `GlmTestCase` 的既有约定）。
/// 它自己没有 `test*` 方法。
class SleepHealthTestCase: XCTestCase {

    /// 真机 `pmset -g custom` 原样输出 fixture（含 "Sleep On Power Button 1"、
    /// lowpowermode、hibernatefile 路径等必须被忽略的干扰行）
    static let pmsetFixture = """
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

    let now = Date(timeIntervalSince1970: 1_000_000)

    /// 快照构造便捷方法
    func snapshot(
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
}
