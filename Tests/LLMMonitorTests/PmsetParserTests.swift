import XCTest
@testable import LLM_monitor

/// `pmset -g custom` / `pmset -g` 偏好字典的解析决策。
/// 拆自 `SleepHealthTests`，逐字搬移零逻辑变化。
final class PmsetParserTests: SleepHealthTestCase {

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
}
