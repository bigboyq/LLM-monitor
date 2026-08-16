import XCTest
import Foundation
import AppKit
@testable import LLM_monitor

final class ProviderModelTests: XCTestCase {

    func testProviderUsageProjectionAggregatesMultipleClientsByDay() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ClientUsageContribution(
            clientID: ClientID.openCode,
            displayName: "OpenCode",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 100, cacheRead: 20, output: 30, reasoning: 10, rounds: 2)
            ],
            scannedAt: day
        )
        let second = ClientUsageContribution(
            clientID: ClientID.dsh,
            displayName: "DSH",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 40, cacheRead: 5, output: 15, reasoning: 5, rounds: 1)
            ],
            scannedAt: day.addingTimeInterval(10)
        )

        let projection = ProviderUsageProjection(contributions: [first, second])
        let total = try! XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(total.input, 140)
        XCTAssertEqual(total.cacheRead, 25)
        XCTAssertEqual(total.output, 45)
        XCTAssertEqual(total.reasoning, 15)
        XCTAssertEqual(total.totalTokens, 225)
        XCTAssertEqual(projection.clientIDs, [ClientID.openCode, ClientID.dsh])
        XCTAssertEqual(projection.scannedAt, day.addingTimeInterval(10))
    }

    func testClientProviderSummaryUsesAggregateTokensAndCacheHitRate() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            providerName: "ChatGPT Plan",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 80, cacheRead: 20, output: 30, reasoning: 10)
            ],
            recentSamples: [
                LocalTokenUsageSample(
                    completedAt: day,
                    modelName: "gpt-4.1",
                    promptID: "prompt-1",
                    inputTokens: 100,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    reasoningOutputTokens: 10
                )
            ],
            scannedAt: day
        )

        XCTAssertEqual(summary.totalTokens, 140)
        XCTAssertEqual(summary.inputTokens, 80)
        XCTAssertEqual(summary.cacheReadTokens, 20)
        XCTAssertEqual(summary.outputTokens, 30)
        XCTAssertEqual(summary.reasoningTokens, 10)
        XCTAssertEqual(summary.cacheHitRate ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.costEstimate.currency, .usd)
        XCTAssertEqual(summary.costEstimate.value ?? -1, 0.00049, accuracy: 0.000001)
        XCTAssertEqual(summary.priceTextByDay[day], "$0.00")
    }

    func testCurrentDayUsesSamplesWhenDailyAggregateIsBehind() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let sample = LocalTokenUsageSample(
            completedAt: now,
            modelName: "MiniMax-M3",
            promptID: "dsh:turn-1",
            inputTokens: 381_000,
            cachedInputTokens: 26_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:minimax"
        )

        let summary = ClientProviderUsageSummary(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            providerName: "MiniMax",
            dailyTokenUsage: [UnifiedDailyTokenUsage(dayStart: today)],
            recentSamples: [sample],
            scannedAt: now
        )

        let day = try! XCTUnwrap(summary.dailyTokenUsage.first)
        XCTAssertEqual(day.input, 381_000)
        XCTAssertEqual(day.cacheRead, 26_000_000)
        XCTAssertEqual(day.output, 71_000)
        XCTAssertEqual(summary.priceTextByDay[today], "¥11.86")
    }

    func testUnknownModelIsNotAssignedAnEstimatedPrice() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(),
            modelName: "future-model",
            promptID: "prompt-1",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 30,
            reasoningOutputTokens: 0
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertNil(estimate.value)
        XCTAssertNil(estimate.currency)
        XCTAssertEqual(estimate.unpricedModelNames, ["future-model"])
    }

    func testClientSummaryExplainsUnpricedModelTokenImpact() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.minimaxCode,
            quotaProviderID: QuotaProviderID.minimax,
            providerName: "MiniMax",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 80, cacheRead: 20, output: 30, reasoning: 10)
            ],
            recentSamples: [
                LocalTokenUsageSample(
                    completedAt: day,
                    modelName: nil,
                    promptID: "unknown-model",
                    inputTokens: 100,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    reasoningOutputTokens: 10
                )
            ],
            scannedAt: day
        )

        XCTAssertEqual(summary.unpricedModelUsage.count, 1)
        XCTAssertEqual(summary.unpricedModelUsage.first?.modelName, "模型名缺失")
        XCTAssertEqual(summary.unpricedModelUsage.first?.totalTokens, 140)
        XCTAssertEqual(summary.unpricedModelUsage.first?.sampleCount, 1)
    }

    func testPricingAliasesAndAugust17Snapshot() {
        let codexPrices = [
            ModelPricingCatalog.pricing(for: "gpt-5.6-sol", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-5.6-terra", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-5.6-luna", quotaProviderID: QuotaProviderID.openAI)
        ].compactMap { $0 }
        XCTAssertEqual(codexPrices.map(\.inputPerMillion), [5, 2, 0.2])
        XCTAssertEqual(codexPrices.map(\.outputPerMillion), [30, 12, 1.2])

        let gemini36 = ModelPricingCatalog.pricing(
            for: "gemini-3.6-flash", quotaProviderID: QuotaProviderID.antigravity
        )
        let gemini37 = ModelPricingCatalog.pricing(
            for: "gemini-3.7-flash", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(gemini36?.currency, gemini37?.currency)
        XCTAssertEqual(gemini36?.inputPerMillion, gemini37?.inputPerMillion)
        XCTAssertEqual(gemini36?.cacheReadPerMillion, gemini37?.cacheReadPerMillion)
        XCTAssertEqual(gemini36?.outputPerMillion, gemini37?.outputPerMillion)

        let minimax = ModelPricingCatalog.pricing(
            for: "minimax/MiniMax-M3", quotaProviderID: QuotaProviderID.minimax
        )
        XCTAssertEqual(minimax?.inputPerMillion, 2.022)
        XCTAssertEqual(minimax?.cacheReadPerMillion, 0.4044)
        XCTAssertEqual(minimax?.outputPerMillion, 8.088)

        let glm52 = ModelPricingCatalog.pricing(for: "GLM-5.2", quotaProviderID: QuotaProviderID.zhipu)
        let glm53 = ModelPricingCatalog.pricing(for: "GLM-5.3", quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(glm52?.currency, glm53?.currency)
        XCTAssertEqual(glm52?.inputPerMillion, glm53?.inputPerMillion)
        XCTAssertEqual(glm52?.cacheReadPerMillion, glm53?.cacheReadPerMillion)
        XCTAssertEqual(glm52?.outputPerMillion, glm53?.outputPerMillion)

        let deepseekFlash = ModelPricingCatalog.pricing(
            for: "deepseek-v4-flash", quotaProviderID: QuotaProviderID.deepseek
        )
        let deepseekPro = ModelPricingCatalog.pricing(
            for: "deepseek-v4-pro", quotaProviderID: QuotaProviderID.deepseek
        )
        XCTAssertEqual(deepseekFlash?.currency, .cny)
        XCTAssertEqual(deepseekFlash?.inputPerMillion, 1.5)
        XCTAssertEqual(deepseekFlash?.cacheReadPerMillion, 0.05)
        XCTAssertEqual(deepseekFlash?.outputPerMillion, 4.5)
        XCTAssertEqual(deepseekPro?.currency, .cny)
        XCTAssertEqual(deepseekPro?.inputPerMillion, 4.5)
        XCTAssertEqual(deepseekPro?.cacheReadPerMillion, 0.15)
        XCTAssertEqual(deepseekPro?.outputPerMillion, 13.5)
        XCTAssertEqual(ModelPricingCatalog.lastUpdated, "2026-08-17")
    }

    func testDeepseekPricingUsesOffPeakBaseAndDoublesAtPeak() {
        let calendar = DeepseekPeakWindow.beijingCalendar
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10))!
        let peak = day
        let offPeak = day.addingTimeInterval(3 * 60 * 60)
        let sample = LocalTokenUsageSample(
            completedAt: peak,
            modelName: "deepseek-v4-flash",
            promptID: "p1",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0
        )

        let peakEstimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        XCTAssertEqual(peakEstimate.value ?? -1, 3.32, accuracy: 0.000001)

        let offPeakSample = LocalTokenUsageSample(
            completedAt: offPeak,
            modelName: "deepseek-v4-flash",
            promptID: "p2",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0
        )
        let offPeakEstimate = ModelPricingCatalog.estimate(
            samples: [offPeakSample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        XCTAssertEqual(offPeakEstimate.value ?? -1, 1.66, accuracy: 0.000001)
    }

    func testDeepseekDshPricingKeepsSeparateCacheReadBucket() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "deepseek-v4-flash",
            promptID: "dsh-sample",
            inputTokens: 698_000,
            cachedInputTokens: 39_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:deepseek-official"
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: DeepseekPeakWindow(slots: [], weekdaysOnly: true)
        )

        XCTAssertEqual(estimate.value ?? -1, 3.3165, accuracy: 0.000001)
        XCTAssertEqual(estimate.currency, .cny)
    }

    func testMiniMaxDshM3PricingKeepsSeparateCacheReadBucket() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "MiniMax-M3",
            promptID: "dsh-minimax-sample",
            inputTokens: 381_000,
            cachedInputTokens: 26_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:minimax"
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.minimax
        )

        XCTAssertEqual(estimate.value ?? -1, 11.85903, accuracy: 0.000001)
        XCTAssertEqual(estimate.currency, .cny)
    }

    func testClientRegistrySeparatesMultiProviderClientsFromQuotaProviders() {
        let openCode = try! XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.openCode })
        let dsh = try! XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.dsh })
        XCTAssertGreaterThan(openCode.supportedQuotaProviderIDs.count, 2)
        XCTAssertGreaterThan(dsh.supportedQuotaProviderIDs.count, 1)
        XCTAssertEqual(ProviderKind.deepseek.quotaProviderID, QuotaProviderID.deepseek)
        XCTAssertEqual(ProviderKind.glmCodingPlan.quotaProviderID, QuotaProviderID.zhipu)
    }

    func testLegacyProviderMergeFlagsMigrateToClientBindings() throws {
        let json = """
        {
          "schemaVersion": 1,
          "refreshIntervalSeconds": 300,
          "providers": {
            "glm_coding_plan": {"enabled": false, "mergeOpencodeUsage": false},
            "deepseek": {"enabled": false, "mergeOpencodeUsage": true}
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertFalse(config.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu
        ))
        XCTAssertTrue(config.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek
        ))
    }

    func testClientBindingsEncodeDecodeRoundTrip() throws {
        // 把 schema v2 config 编码回 JSON 再解码，必须保持 clientBindings 不丢失。
        // 覆盖 setClientBindingEnabled 的两条路径：
        // 1) 更新已有 binding（openCode + deepseek 改为 enabled = true）；
        // 2) 新增 binding（minimax + codex 这对在 default 中存在；
        //    改 antigravity binding 走更新路径以验证重复 binding 不重复写入）。
        var config = AppConfig.default
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek,
            enabled: true
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu,
            enabled: false
        )

        let encoded = try JSONEncoder().encode(config)
        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: encoded)

        XCTAssertEqual(roundTripped.clientBindings.count, config.clientBindings.count,
                       "clientBindings encode/decode 必须保持原有数量，重复 set 不能添加副本")
        XCTAssertTrue(roundTripped.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek
        ))
        XCTAssertFalse(roundTripped.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu
        ))
    }

    func testSetClientBindingEnabledAppendsForUnknownPair() throws {
        // 给一个 default 中不存在的 (clientID, quotaProviderID) 对调用
        // setClientBindingEnabled 必须 append 一个新 binding，而不是静默失败。
        var config = AppConfig.default
        let before = config.clientBindings.count
        config.setClientBindingEnabled(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            enabled: true
        )
        XCTAssertEqual(config.clientBindings.count, before + 1)
        XCTAssertTrue(config.isClientBindingEnabled(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek
        ))
    }

    // MARK: - QuotaInfo: accountEmail

    func testQuotaInfoAccountEmailRoundTrip() throws {
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Free",
            accountEmail: "eve@example.com",
            codexUsageDetails: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(QuotaInfo.self, from: data)
        XCTAssertEqual(decoded.accountEmail, "eve@example.com")
        XCTAssertEqual(decoded.planLabel, "Free")
    }

    func testShouldUseDeepseekBalanceRowForDeepseekProvider() {
        let model = ModelQuota(
            modelName: "deepseek_balance",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 100,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 100,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        XCTAssertTrue(QuotaSummary.shouldUseDeepseekBalanceRow(providerKind: .deepseek, model: model))
        XCTAssertFalse(QuotaSummary.shouldUseDeepseekBalanceRow(providerKind: .minimaxTokenPlan, model: model))
    }

    func testQuotaInfoAccountEmailBackwardCompatibility() throws {
        // 旧版 JSON 没有 accountEmail 字段 → 应 decode 成 nil 而不是崩
        let json = """
        {
          "models": [],
          "resetCredits": null,
          "planLabel": "Free",
          "codexUsageDetails": null,
          "fetchedAt": "2026-07-15T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(QuotaInfo.self, from: json)
        XCTAssertEqual(info.planLabel, "Free")
        XCTAssertNil(info.accountEmail)
    }

    func testMenuShowsSetupGuideOnlyWhenAllProvidersAreNotConfigured() {
        let makeStatus: (ProviderStatus.State) -> ProviderStatus = { state in
            ProviderStatus(
                id: UUID().uuidString,
                displayName: "test",
                kind: .minimaxTokenPlan,
                iconSystemName: "circle",
                accentColor: .minimax,
                refreshIntervalSeconds: 300,
                state: state
            )
        }

        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: []))
        XCTAssertTrue(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.notConfigured(reason: "API Key 未填写")),
            makeStatus(.notConfigured(reason: "已禁用"))
        ]))
        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.ready),
            makeStatus(.notConfigured(reason: "已禁用"))
        ]))
        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.failed(message: "error", lastSuccess: nil))
        ]))
    }

    // MARK: - ProviderConfig: serverPath removed

    func testProviderConfigDecodeIgnoresServerPath() throws {
        // 旧版 config.json 可能还残留 serverPath 字段，应被忽略而非报错
        let json = """
        {
          "enabled": true,
          "serverPath": "/Applications/Antigravity.app",
          "refreshIntervalSeconds": 60
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.refreshIntervalSeconds, 60)
        XCTAssertNil(config.apiKey)
    }

    func testProviderConfigEncodeOmitsServerPath() throws {
        let config = ProviderConfig(enabled: true, refreshIntervalSeconds: 60)
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("serverPath"), "encode 不应写出已删除字段: \(json)")
        XCTAssertTrue(json.contains("\"enabled\""))
    }

    func testMinimaxLocalUsageEqualityIgnoresScannedAt() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let today = MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)
        let days = [MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)]
        let lhs = MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        let rhs = MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 9_999_999),  // 不同的 scannedAt
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertEqual(lhs, rhs, "业务字段相同 + scannedAt 不同 → == 应当 true (no-op 生效)")
    }

    /// 业务字段不同时 == 必须 false（不能让 no-op 误判命中）。
    func testMinimaxLocalUsageEqualityDetectsBusinessFieldChanges() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let base = MinimaxLocalUsage(
            today: MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10),
            dailyTokenUsage: [MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)],
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        // sessionCount 变 → !=
        let sessionCountChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 6,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, sessionCountChanged)
        // eventCount 变 → !=
        let eventCountChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 51,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, eventCountChanged)
        // dailyTokenUsage 内容变 → !=
        let dayChanged = MinimaxDailyUsage(dayStart: day, inputTokens: 999, outputTokens: 50, turns: 3, rounds: 10)
        let dailyChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: [dayChanged],
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, dailyChanged)
    }

    func testModelQuotaTimeRemainingFraction() {
        let futureDate = Date().addingTimeInterval(3.5 * 24 * 60 * 60) // 3.5 days in future

        // 1. ChatGPT Plan single primary window (7 days / 604800s)
        let chatgptQuota = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 97,
            intervalStatus: .present,
            intervalResetsAt: futureDate,
            intervalWindowSeconds: 7 * 24 * 60 * 60,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        XCTAssertNotNil(chatgptQuota.intervalTimeRemainingFraction)
        if let fraction = chatgptQuota.intervalTimeRemainingFraction {
            XCTAssertGreaterThan(fraction, 0.45)
            XCTAssertLessThan(fraction, 0.55)
        }

        // 2. 5h short interval window (18000s) -> should return nil for intervalTimeRemainingFraction
        let shortQuota = ModelQuota(
            modelName: "general",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 50,
            intervalStatus: .present,
            intervalResetsAt: futureDate,
            intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 50,
            weeklyStatus: .present,
            weeklyResetsAt: futureDate,
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertNil(shortQuota.intervalTimeRemainingFraction)
        XCTAssertNotNil(shortQuota.weeklyTimeRemainingFraction)
    }

    func testHealthLevelNewThresholds() {
        let futureDate = Date().addingTimeInterval(3.5 * 24 * 60 * 60) // 50% time remaining (~3.5d of 7d)

        // 1. 5h window: 14% -> critical (red)
        let c1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 14, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(c1.healthLevel, .critical)

        // 2. 5h window: 25% -> warning (yellow)
        let w1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 25, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(w1.healthLevel, .warning)

        // 3. 5h window: 30% -> healthy (green)
        let h1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 30, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(h1.healthLevel, .healthy)

        // 4. Week window with 80% time remaining -> yellow threshold is min(80, 50) = 50%
        // weeklyRemaining = 45% -> warning (yellow)
        let farFutureDate = Date().addingTimeInterval(5.6 * 24 * 60 * 60)
        let w2 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 45, weeklyStatus: .present, weeklyResetsAt: farFutureDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(w2.healthLevel, .warning)

        // 5. Week window with 20% time remaining (1.4d in future) -> yellow threshold is min(20, 50) = 20%
        // weeklyRemaining = 25% (>= 20%) -> healthy (green)
        let nearExpiryDate = Date().addingTimeInterval(1.4 * 24 * 60 * 60)
        let h2 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 25, weeklyStatus: .present, weeklyResetsAt: nearExpiryDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(h2.healthLevel, .healthy)

        // 6. Dual window: 5h is 20% (warning), week is 10% (critical) -> min is critical (red)
        let combo = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 20, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 10, weeklyStatus: .present, weeklyResetsAt: futureDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(combo.healthLevel, .critical)
    }

    // MARK: - ProviderKind Consistency & Unified Quota Hover Tests

    @MainActor
    func testProviderKindConsistencyAndHoverRules() {
        for kind in ProviderKind.allCases {
            XCTAssertFalse(kind.providerID.isEmpty)
            XCTAssertFalse(kind.logTag.isEmpty)
            XCTAssertFalse(kind.logTag.contains("_"))
        }

        let ids = ProviderKind.allCases.map(\.providerID)
        XCTAssertEqual(Set(ids).count, ids.count)

        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(300)
        let samples = [
            LocalTokenUsageSample(completedAt: start, modelName: "MiniMax-M3", promptID: "p1", inputTokens: 10, cachedInputTokens: 4, outputTokens: 3, reasoningOutputTokens: 0),
            LocalTokenUsageSample(completedAt: start.addingTimeInterval(1), modelName: "MiniMax-M3", promptID: "p1", inputTokens: 20, cachedInputTokens: 5, outputTokens: 7, reasoningOutputTokens: 0)
        ]
        let summary = LocalUsageSummaryBuilder.summary(samples: samples, providerKind: .minimaxTokenPlan, quotaModelName: "general", start: start, end: end)
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 30)
    }

    func testLocalUsageWindowBoundsUseFallbackWhenResetTimeIsMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: nil,
            explicitWindowSeconds: nil,
            fallbackSeconds: 5 * 60 * 60,
            now: now
        )

        XCTAssertEqual(bounds?.start, now)
        XCTAssertEqual(bounds?.end, now.addingTimeInterval(5 * 60 * 60))
    }

    func testLocalUsageWindowBoundsPreferServerResetTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(90 * 60)
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: reset,
            explicitWindowSeconds: 60 * 60,
            fallbackSeconds: 5 * 60 * 60,
            now: now
        )

        XCTAssertEqual(bounds?.end, reset)
        XCTAssertEqual(bounds?.start, reset.addingTimeInterval(-60 * 60))
    }

    // MARK: - ModelQuota.colorLevel (barColor / healthLevel / summaryColor 共享阈值)

    func testModelQuotaColorLevelShortWindow() {
        // timeFraction=nil: 5h 短窗口，固定 30% 黄阈值
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 14.9, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 15, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 29.9, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 30, timeFraction: nil), .healthy)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 100, timeFraction: nil), .healthy)
    }

    func testModelQuotaColorLevelLongWindowTimeAware() {
        // timeFraction!=nil: 长窗口，黄阈值 = min(time% * 100, 50)
        // 还剩 100% 时间 → 阈值 50%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 49, timeFraction: 1.0), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 50, timeFraction: 1.0), .healthy)
        // 还剩 20% 时间 → 阈值 20%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 19, timeFraction: 0.2), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 20, timeFraction: 0.2), .healthy)
        // 临界永远是 15%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 14.9, timeFraction: 0.2), .critical)
    }

    func testIntervalTimeRemainingFractionDropsModelNameHack() {
        // modelName 不再决定 fallback：必须显式有 intervalWindowSeconds
        let q = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
            intervalWindowSeconds: nil,  // 显式 nil
            weeklyTotalCount: 0, weeklyUsageCount: 0,
            weeklyRemainingPercent: 0, weeklyStatus: .absent,
            weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertNil(q.intervalTimeRemainingFraction, "没有 intervalWindowSeconds 就不能 fallback 到 modelName=chatgpt_plan")
    }

    func testBindingConstraintTextBothBranches() {
        let weeklyBindingText = QuotaWindowsHoverPresentation.bindingConstraintText(
            primaryLabel: "5h", weeklyIsBinding: true, weeklyEquivalentMultiplier: 5, weeklyLabel: "周额度"
        )
        XCTAssertTrue(weeklyBindingText.contains("取周额度"))
        XCTAssertTrue(weeklyBindingText.contains("5h还有余量但周额度已先耗尽"))
        XCTAssertFalse(weeklyBindingText.contains("取5h是 binding constraint"))

        let primaryBindingText = QuotaWindowsHoverPresentation.bindingConstraintText(
            primaryLabel: "5h", weeklyIsBinding: false, weeklyEquivalentMultiplier: 5, weeklyLabel: "周"
        )
        XCTAssertTrue(primaryBindingText.contains("取5h窗口"))
        XCTAssertTrue(primaryBindingText.contains("5h是 binding constraint"))
    }

    func testEquivalentQuotaAllocationSegmentFillsBoundaryConditions() {
        // 0% weekly units -> 0 fills
        let zeroFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0, weeklyFraction: 0, segments: 5
        )
        XCTAssertEqual(zeroFills, [0, 0, 0, 0, 0])

        // 100% (weeklyUnits = 5) -> [1, 1, 1, 1, 1]
        let fullFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 1.0, weeklyFraction: 1.0, segments: 5
        )
        XCTAssertEqual(fullFills, [1.0, 1.0, 1.0, 1.0, 1.0])

        // Exact tie (weeklyUnits == normalizedPrimary = 0.5) -> [0.5, 0, 0, 0, 0]
        let tieFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.5, weeklyFraction: 0.1, segments: 5
        )
        XCTAssertEqual(tieFills, [0.5, 0.0, 0.0, 0.0, 0.0])
    }

    private struct MockDailyUsage: LocalUsageDaily {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        let turns: Int
        let rounds: Int

        var id: Date { dayStart }
        var dayStart: Date { Date() }
        var input: Int { inputTokens }
        var cacheRead: Int { cacheReadTokens }
        var cacheWrite: Int { cacheWriteTokens }
        var output: Int { outputTokens }
        var reasoning: Int { reasoningTokens }
        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens }
    }

    func testAllDailyUsageTypesConformToLocalUsageDaily() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let antigravity = AntigravityDailyUsage(
            dayStart: day, inputTokens: 10, cacheReadTokens: 20,
            cacheWriteTokens: 30, outputTokens: 40, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let minimax = MinimaxDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let opencode = OpencodeDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let glm = GlmDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let codex = DailyTokenUsage(
            dayStart: day, inputTokens: 30, cachedInputTokens: 20,
            outputTokens: 40, reasoningOutputTokens: 50, rounds: 7, turns: 6
        )

        let dailyValues: [any LocalUsageDaily] = [antigravity, minimax, opencode, glm, codex]
        XCTAssertEqual(dailyValues.map(\.input), [10, 10, 10, 10, 10])
        XCTAssertEqual(dailyValues.map(\.cacheRead), [20, 20, 20, 20, 20])
        XCTAssertEqual(dailyValues.map(\.cacheWrite), [30, 30, 30, 30, 0])
        XCTAssertEqual(dailyValues.map(\.output), [40, 40, 40, 40, 40])
        XCTAssertEqual(dailyValues.map(\.reasoning), [50, 50, 50, 50, 50])
        XCTAssertEqual(dailyValues.map(\.turns), [6, 6, 6, 6, 6])
        XCTAssertEqual(dailyValues.map(\.rounds), [7, 7, 7, 7, 7])
    }

    func testLocalUsageChartScaleCrossDayMax() {
        // Day 1: high output (1000), low reasoning (10)
        let day1 = MockDailyUsage(inputTokens: 100, outputTokens: 1000, cacheReadTokens: 50, cacheWriteTokens: 0, reasoningTokens: 10, turns: 1, rounds: 1)
        // Day 2: low output (10), high reasoning (1000)
        let day2 = MockDailyUsage(inputTokens: 200, outputTokens: 10, cacheReadTokens: 100, cacheWriteTokens: 0, reasoningTokens: 1000, turns: 1, rounds: 1)

        let scale = LocalUsageChartScale(days: [day1, day2])
        // Output total for Day 1 is 1010, Day 2 is 1010. Max output total across days should be 1010.
        XCTAssertEqual(scale.maxOutputWeight, 1010)
        XCTAssertEqual(scale.maxUncached, 200)
    }
}
