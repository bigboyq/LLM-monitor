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

    // MARK: - -0.0 与浮点尾数格式化

    func testDraftFormatsNegativeZeroAndFloatTailsCleanly() throws {
        let negZeroConfig = CodexAdminKeyConfig(
            id: "k1",
            apiKey: "sk-admin-1",
            monthlyQuotaLimit: 1000.0,
            usedAmountAdjust: -0.0
        )
        let negZeroDraft = CodexAdminKeyConfigDraft(from: negZeroConfig)
        XCTAssertEqual(negZeroDraft.usedAmountAdjust, "0")
        XCTAssertEqual(negZeroDraft.initialUsedAmountAdjust, "0")
        XCTAssertEqual(negZeroDraft.monthlyQuotaLimit, "1000")

        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(0.1 + 0.2), "0.3")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(-(0.1 + 0.2)), "-0.3")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(5.12 + 0.01), "5.13")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(0.1 + 0.2 - 0.3), "0")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(-(0.1 + 0.2 - 0.3)), "0")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(.nan), "0")
        XCTAssertEqual(CodexAdminKeyConfigDraft.formatDraftDouble(.infinity), "0")

        let parsedNegZero = try XCTUnwrap(
            CodexAdminKeyConfigDraft(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: "-0").toConfig()
        )
        XCTAssertEqual(parsedNegZero.usedAmountAdjust, 0)
        XCTAssertEqual(parsedNegZero.usedAmountAdjust.sign, .plus)

        let validatedNegZero = try XCTUnwrap(SettingsView.validUsedAmountAdjust("-0.0"))
        XCTAssertEqual(validatedNegZero, 0)
        XCTAssertEqual(validatedNegZero.sign, .plus)
    }

    // MARK: - 账期锚点变更对定值的影响

    @MainActor
    func testMergedCarryAdjustOnBillingAnchorChanges() {
        let stamp = Date(timeIntervalSince1970: 1_762_800_000)
        let now = stamp.addingTimeInterval(7200)
        let existing = CodexAdminKeyConfig(
            id: "k1",
            label: "Old",
            apiKey: "sk-admin-1",
            monthlyQuotaLimit: 40,
            billingDay: 11,
            billingTime: "08:00",
            usedAmountAdjust: 5.5,
            usedAmountAdjustFixedAt: stamp
        )

        // (a) 仅修改 billingDay 且未动边界扣除 → 重置为 0 与未定值
        let changedDay = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(
                id: "k1", label: "Old", apiKey: "sk-admin-1",
                monthlyQuotaLimit: 40, billingDay: 15, billingTime: "08:00",
                usedAmountAdjust: 5.5
            ),
            adjustText: "5.5",
            initialAdjustText: "5.5",
            existing: existing,
            now: now
        )
        XCTAssertEqual(changedDay.usedAmountAdjust, 0, accuracy: 0.0001)
        XCTAssertNil(changedDay.usedAmountAdjustFixedAt)
        XCTAssertEqual(changedDay.billingDay, 15)

        // (b) 仅修改 billingTime 且未动边界扣除 → 重置为 0 与未定值
        let changedTime = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(
                id: "k1", label: "Old", apiKey: "sk-admin-1",
                monthlyQuotaLimit: 40, billingDay: 11, billingTime: "09:30",
                usedAmountAdjust: 5.5
            ),
            adjustText: "5.5",
            initialAdjustText: "5.5",
            existing: existing,
            now: now
        )
        XCTAssertEqual(changedTime.usedAmountAdjust, 0, accuracy: 0.0001)
        XCTAssertNil(changedTime.usedAmountAdjustFixedAt)
        XCTAssertEqual(changedTime.billingTime, "09:30")

        // (c) 同时修改 billingDay / billingTime 且手动改了边界扣除 → 手动覆盖生效并定值为 now
        let changedAnchorAndAdjust = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(
                id: "k1", label: "Old", apiKey: "sk-admin-1",
                monthlyQuotaLimit: 40, billingDay: 20, billingTime: "10:00",
                usedAmountAdjust: 7.25
            ),
            adjustText: "7.25",
            initialAdjustText: "5.5",
            existing: existing,
            now: now
        )
        XCTAssertEqual(changedAnchorAndAdjust.usedAmountAdjust, 7.25, accuracy: 0.0001)
        XCTAssertEqual(changedAnchorAndAdjust.usedAmountAdjustFixedAt, now)

        // (d) 仅修改 label / monthlyQuotaLimit 且未动边界扣除（含等价时间格式 "8:00"）→ 保留现值与定值时间
        let nonAnchorEdit = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(
                id: "k1", label: "Renamed", apiKey: "sk-admin-1",
                monthlyQuotaLimit: 80, billingDay: 11, billingTime: "8:00",
                usedAmountAdjust: 5.5
            ),
            adjustText: "5.5",
            initialAdjustText: "5.5",
            existing: existing,
            now: now
        )
        XCTAssertEqual(nonAnchorEdit.usedAmountAdjust, 5.5, accuracy: 0.0001)
        XCTAssertEqual(nonAnchorEdit.usedAmountAdjustFixedAt, stamp)
        XCTAssertEqual(nonAnchorEdit.label, "Renamed")
        XCTAssertEqual(nonAnchorEdit.monthlyQuotaLimit, 80)

        // (e) existing == nil 且未动边界扣除 → 保持未定值
        let freshAnchor = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(
                id: "k2", label: "New", apiKey: "sk-admin-2",
                monthlyQuotaLimit: 40, billingDay: 15, billingTime: "09:00",
                usedAmountAdjust: 0
            ),
            adjustText: "0",
            initialAdjustText: "0",
            existing: nil,
            now: now
        )
        XCTAssertEqual(freshAnchor.usedAmountAdjust, 0, accuracy: 0.0001)
        XCTAssertNil(freshAnchor.usedAmountAdjustFixedAt)
    }
}
