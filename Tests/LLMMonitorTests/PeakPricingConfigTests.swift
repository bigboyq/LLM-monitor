import XCTest
@testable import LLM_monitor

final class PeakPricingConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> ProviderConfig {
        try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
    }

    func testProviderDefaultsAndConfiguredWindowSurviveSaving() throws {
        let defaults = try decode("{}")
        XCTAssertEqual(defaults.effectivePeakWindow(for: .deepseek), .deepseekDefault)
        XCTAssertEqual(defaults.effectivePeakWindow(for: .glmCodingPlan), .zhipuDefault)
        XCTAssertNil(defaults.effectivePeakWindow(for: .codexChatGpt))

        let custom = try decode(#"{"peakWindow":{"slots":[{"startHour":20,"endHour":24},{"startHour":8,"endHour":10}],"weekdaysOnly":false,"multiplier":1.5}}"#)
        let window = try XCTUnwrap(custom.effectivePeakWindow(for: .deepseek))
        XCTAssertEqual(window.slots.map(\.startHour), [8, 20])
        XCTAssertEqual(window.multiplier, 1.5)
        XCTAssertFalse(window.weekdaysOnly)
        XCTAssertEqual(try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertTrue(window.scheduleLabel.contains("每天"))
        XCTAssertFalse(window.scheduleLabel.contains("法定节假日"))
    }

    func testOldWindowPayloadDefaultsToWeekdaysAndDoublePricing() throws {
        let config = try decode(#"{"peakWindow":{"slots":[{"startHour":14,"endHour":18}]}}"#)
        XCTAssertEqual(config.effectivePeakWindow(for: .glmCodingPlan), .zhipuDefault)
    }

    func testInvalidWindowsAndMultipliersAreRejected() {
        for window in [
            #"{"slots":[]}"#,
            #"{"slots":[{"startHour":-1,"endHour":12}]}"#,
            #"{"slots":[{"startHour":12,"endHour":12}]}"#,
            #"{"slots":[{"startHour":12,"endHour":25}]}"#,
            #"{"slots":[{"startHour":9,"endHour":12},{"startHour":11,"endHour":14}]}"#,
            #"{"slots":[{"startHour":9,"endHour":12}],"multiplier":0}"#,
            #"{"slots":[{"startHour":9,"endHour":12}],"multiplier":-2}"#
        ] {
            XCTAssertThrowsError(try decode("{\"peakWindow\":\(window)}"), window)
        }
    }

    func testCustomMultiplierAppliesOnlyInConfiguredWindowToAllBillingComponents() throws {
        let cal = PeakWindow.beijingCalendar
        // 周六；weekdaysOnly=false 才会命中，时段也不同于默认值。
        let date = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 21)))
        for multiplier in [1.5, 3.0] {
            let window = PeakWindow(startHour: 20, endHour: 24, weekdaysOnly: false, multiplier: multiplier)
            let sample = LocalTokenUsageSample(
                completedAt: date, modelName: "deepseek-v3-flash", promptID: "peak",
                inputTokens: 2_000_000, cachedInputTokens: 1_000_000,
                outputTokens: 1_000_000, reasoningOutputTokens: 0
            )
            let cost = ModelPricingCatalog.estimate(samples: [sample], quotaProviderID: QuotaProviderID.deepseek, deepseekPeakWindow: window)
            // Flash 基础价：输入1、缓存0.02、输出4（每百万 token）。
            XCTAssertEqual(try XCTUnwrap(cost.value), 5.02 * multiplier, accuracy: 0.000001)
            let offPeakSample = LocalTokenUsageSample(
                completedAt: date.addingTimeInterval(-2 * 3600), modelName: sample.modelName, promptID: "off-peak",
                inputTokens: sample.inputTokens, cachedInputTokens: sample.cachedInputTokens,
                outputTokens: sample.outputTokens, reasoningOutputTokens: sample.reasoningOutputTokens
            )
            let offPeakCost = ModelPricingCatalog.estimate(samples: [offPeakSample], quotaProviderID: QuotaProviderID.deepseek, deepseekPeakWindow: window)
            XCTAssertEqual(try XCTUnwrap(offPeakCost.value), 5.02, accuracy: 0.000001)
            let midnight = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 9)))
            XCTAssertEqual(window.status(at: date, calendar: cal), .peak(until: midnight))
        }
    }
}
