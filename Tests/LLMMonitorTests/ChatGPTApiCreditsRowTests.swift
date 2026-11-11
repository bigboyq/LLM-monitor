import XCTest
@testable import LLM_monitor

@MainActor
final class ChatGPTApiCreditsRowTests: XCTestCase {
    func testNamedKeysUseTheirNamesInsteadOfCurrencyOrOrganization() {
        let now = Date()
        for name in ["个人账号", "团队项目"] {
            let credits = OpenAIApiCreditDetails(
                organizationName: "Shared Organization",
                totalQuota: 40,
                usedAmount: 5,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                keyLabel: " \(name) \n"
            )
            let row = ChatGPTApiCreditsRow(credits: credits, tint: .chatgptBrand, error: nil)
            XCTAssertEqual(row.titleText, "API赠金 · \(name)")
        }
    }

    func testUnnamedKeysRemainDistinguishableByListPosition() {
        let now = Date()
        for (index, label) in [nil, "", " \n"].enumerated() {
            let credits = OpenAIApiCreditDetails(
                organizationName: nil,
                totalQuota: 40,
                usedAmount: 0,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                keyLabel: label
            )
            let row = ChatGPTApiCreditsRow(
                credits: credits, tint: .chatgptBrand, error: nil, keyNumber: index + 1
            )
            XCTAssertEqual(row.titleText, "API赠金 · API Key #\(index + 1)")
        }
    }

    // MARK: - 估算标记与扣除明细 tooltip

    func testEstimateMarkerAppearsOnlyForApproximateNonFailedCredits() {
        let now = Date()
        func makeRow(
            approximate: Bool,
            lastAttemptFailed: Bool? = false,
            errorMessage: String? = nil,
            rowError: String? = nil
        ) -> ChatGPTApiCreditsRow {
            let credits = OpenAIApiCreditDetails(
                organizationName: nil,
                totalQuota: 40,
                usedAmount: 5,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                lastAttemptFailed: lastAttemptFailed,
                errorMessage: errorMessage,
                carryApproximate: approximate
            )
            return ChatGPTApiCreditsRow(credits: credits, tint: .chatgptBrand, error: rowError)
        }

        XCTAssertTrue(makeRow(approximate: true).showsCarryEstimateMarker, "approximate=true 且非失败态 → 显示估算标记")
        XCTAssertFalse(makeRow(approximate: false).showsCarryEstimateMarker, "approximate=false → 不显示")
        XCTAssertFalse(makeRow(approximate: true, lastAttemptFailed: true).showsCarryEstimateMarker, "失败态优先：lastAttemptFailed 时不显示估算图标")
        XCTAssertFalse(makeRow(approximate: true, errorMessage: "HTTP 500").showsCarryEstimateMarker, "失败态优先：errorMessage 非空时不显示")
        XCTAssertFalse(makeRow(approximate: true, rowError: "抓取失败").showsCarryEstimateMarker, "失败态优先：行级 error 非空时不显示")
    }

    func testNormalTooltipAppendsCarryDeductionDetail() {
        let now = Date()
        func makeRow(
            carryDeduction: Double = 0,
            carryApproximate: Bool = false
        ) -> ChatGPTApiCreditsRow {
            let credits = OpenAIApiCreditDetails(
                organizationName: nil,
                totalQuota: 40,
                usedAmount: 5,
                cycleStart: now,
                cycleEnd: now.addingTimeInterval(86400),
                carryDeduction: carryDeduction,
                carryApproximate: carryApproximate
            )
            return ChatGPTApiCreditsRow(credits: credits, tint: .chatgptBrand, error: nil)
        }

        // 为零 → 保持原有 tooltip 不追加
        XCTAssertEqual(makeRow().normalTooltip, "总额度: $40，已用: $5.00，剩余: $35")

        // 估算 carry
        let estimateRow = makeRow(carryDeduction: 5, carryApproximate: true)
        XCTAssertTrue(estimateRow.normalTooltip.contains("，边界扣除: $5.00（估算）"))

        // 精确 carry（无「（估算）」后缀）
        let preciseRow = makeRow(carryDeduction: 3.5)
        XCTAssertTrue(preciseRow.normalTooltip.contains("，边界扣除: $3.50"))
        XCTAssertFalse(preciseRow.normalTooltip.contains("（估算）"))
    }
}
