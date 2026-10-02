import XCTest
@testable import LLM_monitor

final class MixedCurrencyEstimateTests: XCTestCase {
    // MARK: - 折算数学

    func testMixedCurrencyFoldsUsdIntoCnyAtFixedRate() {
        let estimate = MixedCurrencyEstimate(usd: 1, cny: 3)

        XCTAssertEqual(estimate.usdTotal, 1)
        XCTAssertEqual(estimate.cnyTotal, 3)
        XCTAssertEqual(estimate.cnyEquivalentTotal, 10)
        XCTAssertEqual(MixedCurrencyEstimate.usdToCNYRate, 7)
        XCTAssertEqual(estimate.displayText, "10（含$1)")
    }

    func testDecimalConversionKeepsFractionalUsdExact() {
        // 0.3 × 7 必须是 2.1，不允许出现 2.0999999… 这类 Double 尾差。
        let usdOnly = MixedCurrencyEstimate(usd: Decimal(string: "0.3")!, cny: 0)
        XCTAssertEqual(usdOnly.cnyEquivalentTotal, Decimal(string: "2.1")!)
        // 纯 USD 的文案仍是 USD 原额（不折算），折算额只在混合形态里出现。
        XCTAssertEqual(usdOnly.displayText, "$0.30")

        let mixed = MixedCurrencyEstimate(usd: Decimal(string: "0.3")!, cny: Decimal(string: "0.2")!)
        XCTAssertEqual(mixed.cnyEquivalentTotal, Decimal(string: "2.3")!)
        XCTAssertEqual(mixed.displayText, "2.3（含$0.3)")
    }

    func testAccumulatedUsdStaysExactAcrossManyProviders() {
        // 十份 0.1 USD：若中间退化成 Double 再折算，总额会偏离 7.00。
        let repeated = MixedCurrencyEstimate(usd: Decimal(string: "1.0")!, cny: 0)
        XCTAssertEqual(repeated.cnyEquivalentTotal, 7)

        var total = MixedCurrencyEstimate(usd: 0, cny: 0)
        for _ in 0..<10 {
            total = MixedCurrencyEstimate(
                usd: total.usdTotal + Decimal(string: "0.1")!,
                cny: total.cnyTotal
            )
        }
        XCTAssertEqual(total.usdTotal, 1)
        XCTAssertEqual(total.cnyEquivalentTotal, 7)
    }

    // MARK: - 单币种文案

    func testPureCnyUsesTwoDecimalsAndNoParenthetical() {
        let estimate = MixedCurrencyEstimate(usd: 0, cny: Decimal(string: "10.5")!)

        XCTAssertEqual(estimate.displayText, "¥10.50")
        XCTAssertFalse(estimate.displayText.contains("含"))
    }

    func testPureUsdUsesTwoDecimalsAndNoParenthetical() {
        let estimate = MixedCurrencyEstimate(usd: Decimal(string: "3.2")!, cny: 0)

        XCTAssertEqual(estimate.displayText, "$3.20")
        XCTAssertFalse(estimate.displayText.contains("含"))
    }

    func testZeroTotalsFallBackToCnySymbol() {
        let estimate = MixedCurrencyEstimate(usd: 0, cny: 0)

        XCTAssertTrue(estimate.isEmpty)
        XCTAssertEqual(estimate.displayText, "¥0.00")
    }

    func testNonZeroTotalIsNotEmpty() {
        XCTAssertFalse(MixedCurrencyEstimate(usd: 0, cny: 0.01).isEmpty)
        XCTAssertFalse(MixedCurrencyEstimate(usd: 0.01, cny: 0).isEmpty)
    }

    // MARK: - 从 [ModelCostEstimate] 归集

    func testCollectsEstimatesByCurrencyAndSkipsUnpricedOnes() {
        let estimates = [
            makeEstimate(value: 3, currency: .cny, unpriced: []),
            makeEstimate(value: 1, currency: .usd, unpriced: []),
            // 未计价：value == nil，必须跳过。
            makeEstimate(value: nil, currency: .cny, unpriced: ["mystery-model"]),
            // 部分计价：value 仍参与归集（unpriced 只是提示，不是排除）。
            makeEstimate(value: 2, currency: .cny, unpriced: ["other-model"])
        ]

        let collected = MixedCurrencyEstimate(estimates: estimates)

        XCTAssertEqual(collected.cnyTotal, 5)
        XCTAssertEqual(collected.usdTotal, 1)
        XCTAssertEqual(collected.cnyEquivalentTotal, 12)
        XCTAssertEqual(collected.displayText, "12（含$1)")
    }

    func testEmptyOrAllUnpricedEstimatesYieldEmptyTotals() {
        XCTAssertEqual(MixedCurrencyEstimate(estimates: []), MixedCurrencyEstimate(usd: 0, cny: 0))
        XCTAssertTrue(MixedCurrencyEstimate(estimates: []).isEmpty)

        let allUnpriced = MixedCurrencyEstimate(estimates: [
            makeEstimate(value: nil, currency: nil, unpriced: ["mystery-model"])
        ])
        XCTAssertTrue(allUnpriced.isEmpty)
        XCTAssertEqual(allUnpriced.displayText, "¥0.00")
    }

    func testCollectedSingleCurrencyMatchesDirectInitializer() {
        let collected = MixedCurrencyEstimate(estimates: [
            makeEstimate(value: 1.5, currency: .usd, unpriced: []),
            makeEstimate(value: 2.25, currency: .usd, unpriced: [])
        ])

        XCTAssertEqual(collected, MixedCurrencyEstimate(usd: Decimal(string: "3.75")!, cny: 0))
        XCTAssertEqual(collected.displayText, "$3.75")
    }

    func testDoubleToDecimalConversionDropsBinaryTailWithoutChangingValue() {
        // 0.1 + 0.2 在 Double 下是 0.30000000000000004；归集后必须显示为 0.30。
        let collected = MixedCurrencyEstimate(estimates: [
            makeEstimate(value: 0.1, currency: .cny, unpriced: []),
            makeEstimate(value: 0.2, currency: .cny, unpriced: [])
        ])

        XCTAssertEqual(collected.cnyTotal, Decimal(string: "0.3")!)
        XCTAssertEqual(collected.displayText, "¥0.30")
    }

    private func makeEstimate(
        value: Double?,
        currency: ModelPriceCurrency?,
        unpriced: [String]
    ) -> ModelCostEstimate {
        ModelCostEstimate(
            value: value,
            currency: currency,
            pricedModelNames: value == nil ? [] : ["model"],
            unpricedModelNames: unpriced
        )
    }
}
