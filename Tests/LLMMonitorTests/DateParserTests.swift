import XCTest
import Foundation
@testable import LLM_monitor

/// `DateParser` 的毫秒时间戳与 ISO8601 / Unix 解析规则。对应 `DateParser`。
final class DateParserTests: XCTestCase {

    // MARK: - DateParser

    func testDateParserParseMsNumberLarge() {
        let ms = 1_783_234_800_000.0
        let date = DateParser.parseMsTimestamp(NSNumber(value: ms))!
        XCTAssertEqual(date.timeIntervalSince1970, ms / 1000.0, accuracy: 0.001)
    }

    func testDateParserParseMsInt() {
        let ms: Int = 1_783_234_800_000
        let date = DateParser.parseMsTimestamp(ms)!
        XCTAssertEqual(date.timeIntervalSince1970, Double(ms) / 1000.0, accuracy: 0.001)
    }

    func testDateParserParseISO8601Fractional() {
        // 先用系统算参考值，避免手算
        let refString = "2026-07-18T00:47:58Z"
        let plain = DateParser.parse(refString)!
        // 把 plain 时刻 + 0.918242 秒（"小数日"的分数部分）作为期望值
        let expected = plain.addingTimeInterval(0.918242)
        let date = DateParser.parse("2026-07-18T00:47:58.918242Z")!
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDateParserParseISO8601Plain() {
        let date = DateParser.parse("2026-07-18T00:47:58Z")!
        let refString = "2026-07-18T00:47:58+00:00"
        let expected = DateParser.parse(refString)!
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)

        let padded = DateParser.parse("  2026-07-18T00:47:58Z  ")!
        XCTAssertEqual(padded.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        let paddedMs = DateParser.parseMsTimestamp("  1783234800000  ")!
        XCTAssertEqual(paddedMs.timeIntervalSince1970, 1_783_234_800, accuracy: 0.001)
    }

    func testDateParserParseUnixSeconds() {
        // < 1e12 = 秒
        let date = DateParser.parse(NSNumber(value: 1_700_000_000.0))!
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testDateParserParseUnixMillisAuto() {
        // > 1e12 = 毫秒
        let date = DateParser.parse(NSNumber(value: 1_700_000_000_000.0))!
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }
}
