import XCTest
@testable import LLM_monitor

/// `CodexAdminKeyConfig.usedAmountAdjust`（每 Key 已用金额手动修正，美元，可为负）的
/// JSON 容错解码、设置草稿双向转换与设置页校验器。
final class CodexAdminKeyAdjustTests: XCTestCase {

    // MARK: - JSON 容错解码

    func testDecodeMissingUsedAmountAdjustFallsBackToZero() throws {
        let json = #"{"id":"k1","label":"L","apiKey":"sk-admin-1","monthlyQuotaLimit":40,"billingDay":11,"billingTime":"00:00"}"#
        let config = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.usedAmountAdjust, 0)
    }

    func testDecodeNegativeUsedAmountAdjust() throws {
        let json = #"{"id":"k1","apiKey":"sk-admin-1","usedAmountAdjust":-3.5}"#
        let config = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.usedAmountAdjust, -3.5)
    }

    /// 类型错误（字符串）不得让整个 Key 条目解码失败：兜底 0。
    func testDecodeTypeMismatchFallsBackToZero() throws {
        let json = #"{"id":"k1","apiKey":"sk-admin-1","usedAmountAdjust":"abc"}"#
        let config = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.usedAmountAdjust, 0)
    }

    func testEncodeDecodeRoundTrip() throws {
        let config = CodexAdminKeyConfig(
            id: "k1",
            label: "L",
            apiKey: "sk-admin-1",
            monthlyQuotaLimit: 40.0,
            billingDay: 11,
            billingTime: "00:00",
            usedAmountAdjust: -3.5
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: data)
        XCTAssertEqual(decoded.usedAmountAdjust, -3.5)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Draft 双向转换

    func testDraftRoundTripPreservesNegativeAdjust() throws {
        let config = CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: -2.5)
        let draft = CodexAdminKeyConfigDraft(from: config)
        XCTAssertEqual(draft.usedAmountAdjust, "-2.5")
        let back = try XCTUnwrap(draft.toConfig())
        XCTAssertEqual(back.usedAmountAdjust, -2.5)
    }

    func testDraftRoundTripFormatsIntegralAdjustWithoutDecimals() throws {
        let config = CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 5.0)
        let draft = CodexAdminKeyConfigDraft(from: config)
        XCTAssertEqual(draft.usedAmountAdjust, "5")
        let back = try XCTUnwrap(draft.toConfig())
        XCTAssertEqual(back.usedAmountAdjust, 5)
    }

    func testDraftInvalidAdjustFallsBackToZero() throws {
        let draft = CodexAdminKeyConfigDraft(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: "abc")
        let back = try XCTUnwrap(draft.toConfig())
        XCTAssertEqual(back.usedAmountAdjust, 0)
    }

    func testDraftScientificNotationParses() throws {
        let draft = CodexAdminKeyConfigDraft(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: "1e3")
        let back = try XCTUnwrap(draft.toConfig())
        XCTAssertEqual(back.usedAmountAdjust, 1000)
    }

    func testDraftDefaultsToZeroAdjust() {
        let draft = CodexAdminKeyConfigDraft(id: "k1", apiKey: "sk-admin-1")
        XCTAssertEqual(draft.usedAmountAdjust, "0")
    }

    // MARK: - 设置页校验器

    func testValidUsedAmountAdjustAcceptsNegativeAndZero() {
        XCTAssertEqual(SettingsView.validUsedAmountAdjust("0"), 0)
        XCTAssertEqual(SettingsView.validUsedAmountAdjust("-3.5"), -3.5)
        XCTAssertEqual(SettingsView.validUsedAmountAdjust(" 2 "), 2)
    }

    func testValidUsedAmountAdjustRejectsNonFiniteAndNonNumeric() {
        for invalid in ["", "   ", "abc", "nan", "infinity", "1e999"] {
            XCTAssertNil(SettingsView.validUsedAmountAdjust(invalid), "Expected \(invalid.debugDescription) to be rejected")
        }
    }

    // MARK: - usedAmountAdjustFixedAt（定值时间戳）

    func testDecodeMissingFixedAtFallsBackToNil() throws {
        let json = #"{"id":"k1","apiKey":"sk-admin-1","usedAmountAdjust":2.5}"#
        let config = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.usedAmountAdjustFixedAt)
        XCTAssertEqual(config.usedAmountAdjust, 2.5)
    }

    /// 类型错误（字符串）不得让整个 Key 条目解码失败：兜底 nil。
    func testDecodeFixedAtTypeMismatchFallsBackToNil() throws {
        let json = #"{"id":"k1","apiKey":"sk-admin-1","usedAmountAdjustFixedAt":"2026-11-11"}"#
        let config = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.usedAmountAdjustFixedAt)
    }

    /// ConfigStore 的 JSONEncoder/Decoder 无 date 策略 → Foundation 默认
    /// `.deferredToDate`（相对 2001-01-01 的秒数 Double），对称编解码可 round-trip
    func testFixedAtRoundTripWithDefaultDateCoding() throws {
        let stamp = Date(timeIntervalSince1970: 1_762_800_000)
        let config = CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 5.0, usedAmountAdjustFixedAt: stamp)
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["usedAmountAdjustFixedAt"] as? Double, "时间戳应编码为 JSON number")
        let decoded = try JSONDecoder().decode(CodexAdminKeyConfig.self, from: data)
        XCTAssertEqual(decoded.usedAmountAdjustFixedAt, stamp)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Draft 定值快照

    func testDraftSnapshotsInitialAdjustAndFixedAt() {
        let stamp = Date(timeIntervalSince1970: 1_762_800_000)
        let config = CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 5.0, usedAmountAdjustFixedAt: stamp)
        let draft = CodexAdminKeyConfigDraft(from: config)
        XCTAssertEqual(draft.usedAmountAdjust, "5")
        XCTAssertEqual(draft.initialUsedAmountAdjust, "5")
        XCTAssertEqual(draft.usedAmountAdjustFixedAt, stamp)

        // 新建 draft 默认未定值
        let fresh = CodexAdminKeyConfigDraft(id: "k2", apiKey: "sk-admin-2")
        XCTAssertEqual(fresh.initialUsedAmountAdjust, "0")
        XCTAssertNil(fresh.usedAmountAdjustFixedAt)
    }
}
