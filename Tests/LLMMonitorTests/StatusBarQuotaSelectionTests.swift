import XCTest
import Foundation
@testable import LLM_monitor

/// The status item is a projection of one stable provider/source identity. These tests
/// pin source discovery, selection isolation and the distinction between missing data
/// and an empty quota.
final class StatusBarQuotaSelectionTests: XCTestCase {
    @MainActor
    func testMenuPlanCardKeepsSelectedSourceAndRoutesEachSourceToItsProvider() throws {
        let (state, store, directory) = try makeFixture()
        defer { state.stop(); try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, StatusBarQuotaSource)] = [
            ("codex_chatgpt", .plan),
            ("codex_chatgpt", .apiCredit(keyID: "workspace-a")),
            ("glm_coding_plan", .activityPlan(planID: "start", entitlementID: "entitlement-a")),
        ]
        for (providerID, source) in cases {
            let status = try XCTUnwrap(state.statuses.first { $0.id == providerID })
            let row = MenuQuotaProviderRow(
                status: status, localStatus: status, fleet: nil,
                selectedStatusBarSource: source, configStore: store,
                onSelectStatusBarQuota: { selected in
                    state.setStatusBarQuotaSelection(StatusBarQuotaSelection(providerID: providerID, source: selected))
                },
                onRefresh: {}, onUsageRefresh: {}, onSettings: {}, onOpenDetails: {}
            )
            XCTAssertEqual(row.planCard.selectedStatusBarSource, source)
            XCTAssertEqual(row.planCard.presentation, .plan)
            row.selectPlanQuotaSource(source)
            XCTAssertEqual(store.config.statusBarQuotaSelection, StatusBarQuotaSelection(providerID: providerID, source: source))
        }
    }

    @MainActor
    private func makeFixture(
        adminEnabled: Bool = false,
        adminKeys: [CodexAdminKeyConfig] = [],
        zcodeEnabled: Bool = false
    ) throws -> (AppState, ConfigStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-bar-quota-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        var config = store.config
        config.providers["codex_chatgpt"] = ProviderConfig(
            enabled: true,
            authPath: "/tmp/auth.json",
            adminApiCreditsEnabled: adminEnabled,
            adminApiKeys: adminKeys
        )
        config.providers["glm_coding_plan"] = ProviderConfig(
            enabled: true,
            apiKey: "glm-test-key",
            zcodeJWTEnabled: zcodeEnabled
        )
        try store.applyAndSave(config)

        let descriptors = [
            FetcherDescriptor(
                id: "codex_chatgpt", displayName: "ChatGPT Plan", kind: .codexChatGpt,
                iconSystemName: "star", accentColor: .chatgpt,
                makeFetcher: { _ in CodexFetcher(authPath: nil) }
            ),
            FetcherDescriptor(
                id: "glm_coding_plan", displayName: "GLM Coding Plan", kind: .glmCodingPlan,
                iconSystemName: "sparkles", accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "glm-test-key") }
            )
        ]
        let state = AppState(descriptors: descriptors, configStore: store)
        state.stop()
        return (state, store, directory)
    }

    private func makeModel(
        interval: Double? = nil,
        weekly: Double? = nil,
        intervalSeconds: Int? = nil,
        weeklySeconds: Int? = nil,
        now: Date
    ) -> ModelQuota {
        ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: interval ?? 0,
            intervalStatus: interval == nil ? .absent : .present,
            intervalResetsAt: interval == nil ? nil : now.addingTimeInterval(3600),
            intervalWindowSeconds: interval == nil ? nil : (intervalSeconds ?? 18_000),
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: weekly ?? 0,
            weeklyStatus: weekly == nil ? .absent : .present,
            weeklyResetsAt: weekly == nil ? nil : now.addingTimeInterval(3 * 86_400),
            weeklyWindowSeconds: weekly == nil ? nil : (weeklySeconds ?? 604_800)
        )
    }

    @MainActor
    private func setQuota(_ quota: QuotaInfo, for providerID: String, in state: AppState) {
        state.mutateStatus(for: providerID) { $0.state = .ok(quota) }
    }

    @MainActor
    func testProviderSelectionDefaultsToItsSingleWeeklyPlanAndNeverFallsBack() throws {
        let (state, store, directory) = try makeFixture()
        defer { state.stop(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        setQuota(
            QuotaInfo(
                models: [makeModel(weekly: 62, now: now)], resetCredits: nil,
                planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now
            ),
            for: "codex_chatgpt", in: state
        )
        let unrelated = ModelQuota(
            modelName: "general", intervalTotalCount: 100, intervalUsageCount: 10,
            intervalRemainingPercent: 90, intervalStatus: .present,
            intervalResetsAt: now.addingTimeInterval(3600), intervalWindowSeconds: 18_000,
            weeklyTotalCount: 100, weeklyUsageCount: 20, weeklyRemainingPercent: 80,
            weeklyStatus: .present, weeklyResetsAt: now.addingTimeInterval(86_400),
            weeklyWindowSeconds: 604_800
        )
        setQuota(
            QuotaInfo(models: [unrelated], resetCredits: nil, planLabel: nil,
                      accountEmail: nil, codexUsageDetails: nil, fetchedAt: now),
            for: "glm_coding_plan", in: state
        )

        var config = store.config
        config.statusBarQuotaSelection = StatusBarQuotaSelection(providerID: "codex_chatgpt", source: .plan)
        try store.applyAndSave(config)
        let metrics = state.statusBarQuotaMetrics(at: now)
        XCTAssertNotNil(metrics.singleQuota, "weekly-only plan uses the single-gauge presentation")
        XCTAssertEqual(metrics.singleQuota?.remainingFraction ?? -1, 0.62, accuracy: 0.001)
        XCTAssertEqual(metrics.singleQuota?.timeRemainingFraction ?? -1, 3.0 / 7.0, accuracy: 0.001)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("ChatGPT"))
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("周"))

        // The source identity remains `.plan` as its available window type changes.
        setQuota(
            QuotaInfo(
                models: [makeModel(interval: 70, weekly: 40, now: now)], resetCredits: nil,
                planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now
            ),
            for: "codex_chatgpt", in: state
        )
        let dual = state.statusBarQuotaMetrics(at: now)
        XCTAssertNil(dual.singleQuota)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("5h / 周"))
        XCTAssertEqual(store.config.statusBarQuotaSelection, config.statusBarQuotaSelection)

        setQuota(
            QuotaInfo(
                models: [makeModel(interval: 70, weekly: nil, intervalSeconds: 30 * 86_400, now: now)],
                resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now
            ),
            for: "codex_chatgpt", in: state
        )
        let monthly = state.statusBarQuotaMetrics(at: now)
        XCTAssertNotNil(monthly.singleQuota)
        XCTAssertEqual(monthly.singleQuota?.remainingFraction ?? -1, 0.70, accuracy: 0.001)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("月"))
        XCTAssertEqual(store.config.statusBarQuotaSelection, config.statusBarQuotaSelection)

        // Disabling the selected provider preserves its identity and must not pick
        // the unrelated GLM quota just because it still has a reading.
        state.mutateStatus(for: "codex_chatgpt") { $0.isEnabled = false }
        let disabledProvider = state.statusBarQuotaMetrics(at: now)
        XCTAssertNotNil(disabledProvider.singleQuota)
        XCTAssertNil(disabledProvider.singleQuota?.remainingFraction)
        XCTAssertNil(state.systemHealthLevel(at: now))
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("暂无数据"))

        state.mutateStatus(for: "codex_chatgpt") { $0.isEnabled = true }
        setQuota(
            QuotaInfo(models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now),
            for: "codex_chatgpt", in: state
        )
        let empty = state.statusBarQuotaMetrics(at: now)
        XCTAssertNotNil(empty.singleQuota, "an explicit selection remains visible when its source has no reading")
        XCTAssertNil(empty.singleQuota?.remainingFraction)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("暂无数据"))
        XCTAssertNil(state.systemHealthLevel(at: now), "an explicitly selected source with no reading has unknown health")
    }

    @MainActor
    func testTwoWindowPlanRemainsDualAndSpecificAPICreditDoesNotMixKeysOrProviders() throws {
        let keys = [
            CodexAdminKeyConfig(id: "workspace-a", label: "A", apiKey: "sk-a", monthlyQuotaLimit: 100),
            CodexAdminKeyConfig(id: "workspace-b", label: "B", apiKey: "sk-b", monthlyQuotaLimit: 100)
        ]
        let (state, store, directory) = try makeFixture(adminEnabled: true, adminKeys: keys)
        defer { state.stop(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let dual = makeModel(interval: 70, weekly: 40, now: now)
        setQuota(
            QuotaInfo(models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now),
            for: "codex_chatgpt", in: state
        )
        let creditA = OpenAIApiCreditDetails(
            organizationName: "A", totalQuota: 100, usedAmount: 10,
            cycleStart: now.addingTimeInterval(-86_400), cycleEnd: now.addingTimeInterval(86_400),
            fetchedAt: now, keyId: "workspace-a", keyLabel: "A"
        )
        let creditB = OpenAIApiCreditDetails(
            organizationName: "B", totalQuota: 100, usedAmount: 73,
            cycleStart: now.addingTimeInterval(-86_400), cycleEnd: now.addingTimeInterval(86_400),
            fetchedAt: now, keyId: "workspace-b", keyLabel: "B"
        )
        let info = QuotaInfo(
            models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: now,
            openAIApiCreditsList: [creditA, creditB]
        )
        setQuota(info, for: "codex_chatgpt", in: state)
        setQuota(
            QuotaInfo(models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now),
            for: "glm_coding_plan", in: state
        )

        let options = state.statusBarQuotaOptions(providerID: "codex_chatgpt")
        XCTAssertTrue(options.contains { $0.source == .apiCredit(keyID: "workspace-a") })
        XCTAssertTrue(options.contains { $0.source == .apiCredit(keyID: "workspace-b") })
        var config = store.config
        config.statusBarQuotaSelection = StatusBarQuotaSelection(providerID: "codex_chatgpt", source: .plan)
        try store.applyAndSave(config)
        XCTAssertNil(state.statusBarQuotaMetrics(at: now).singleQuota, "two plan windows retain the dual gauge")

        config.statusBarQuotaSelection = StatusBarQuotaSelection(
            providerID: "codex_chatgpt", source: .apiCredit(keyID: "workspace-b")
        )
        try store.applyAndSave(config)
        let selected = state.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(selected.singleQuota?.remainingFraction ?? -1, 0.27, accuracy: 0.001)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("ChatGPT"))
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("B"))

        let stale = OpenAIApiCreditDetails(
            organizationName: "B", totalQuota: 100, usedAmount: 73,
            cycleStart: now.addingTimeInterval(-86_400), cycleEnd: now.addingTimeInterval(86_400),
            fetchedAt: now.addingTimeInterval(-60), lastAttemptFailed: true,
            keyId: "workspace-b", keyLabel: "B"
        )
        setQuota(
            QuotaInfo(models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now,
                      openAIApiCreditsList: [creditA, stale]),
            for: "codex_chatgpt", in: state
        )
        XCTAssertEqual(state.statusBarQuotaMetrics(at: now).singleQuota?.remainingFraction ?? -1,
                       0.27, accuracy: 0.001, "a failed refresh retains the last successful reading")
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("可能过期"))

        let expired = OpenAIApiCreditDetails(
            organizationName: "B", totalQuota: 100, usedAmount: 73,
            cycleStart: now.addingTimeInterval(-3 * 86_400), cycleEnd: now.addingTimeInterval(-60),
            fetchedAt: now.addingTimeInterval(-60), keyId: "workspace-b", keyLabel: "B"
        )
        setQuota(
            QuotaInfo(models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now,
                      openAIApiCreditsList: [creditA, expired]),
            for: "codex_chatgpt", in: state
        )
        XCTAssertNil(state.statusBarQuotaMetrics(at: now).singleQuota?.remainingFraction,
                     "a stale billing cycle is unknown until the provider refreshes it")

        let failedFirstFetch = OpenAIApiCreditDetails(
            organizationName: "B", totalQuota: 100, usedAmount: 0,
            cycleStart: now.addingTimeInterval(-86_400), cycleEnd: now.addingTimeInterval(86_400),
            fetchedAt: nil, lastAttemptFailed: true, keyId: "workspace-b", keyLabel: "B"
        )
        setQuota(
            QuotaInfo(models: [dual], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now,
                      openAIApiCreditsList: [creditA, failedFirstFetch]),
            for: "codex_chatgpt", in: state
        )
        XCTAssertNil(state.statusBarQuotaMetrics(at: now).singleQuota?.remainingFraction,
                     "a failed first request cannot present the configured limit as 100% remaining")
    }

    @MainActor
    func testGLMActivityOptionsRemainIndependentAndExpiredBalanceIsZero() throws {
        let (state, store, directory) = try makeFixture(zcodeEnabled: true)
        defer { state.stop(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let activity = GlmActivityPlanBalance(
            planID: "plan-1", planName: "活动套餐", entitlementID: "entitlement-1",
            showName: "GLM-5.3", modelNames: ["glm-5.3"], totalUnits: 100,
            usedUnits: 40, remainingUnits: 60, expiresAt: now.addingTimeInterval(-60), observedAt: now
        )
        let info = QuotaInfo(
            models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: now,
            glmZcodePackage: GlmZcodePackageSnapshot(activityPlanBalances: [activity])
        )
        setQuota(info, for: "glm_coding_plan", in: state)
        let options = state.statusBarQuotaOptions(providerID: "glm_coding_plan")
        let source = StatusBarQuotaSource.activityPlan(planID: "plan-1", entitlementID: "entitlement-1")
        XCTAssertTrue(options.contains { $0.source == source })
        var config = store.config
        config.statusBarQuotaSelection = StatusBarQuotaSelection(providerID: "glm_coding_plan", source: source)
        try store.applyAndSave(config)
        let metrics = state.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.singleQuota?.remainingFraction ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("GLM"))

        config.providers["glm_coding_plan"]?.zcodeJWTEnabled = false
        try store.applyAndSave(config)
        XCTAssertFalse(state.statusBarQuotaOptions(providerID: "glm_coding_plan").contains { $0.source == source })
        let disabled = state.statusBarQuotaMetrics(at: now)
        XCTAssertNotNil(disabled.singleQuota)
        XCTAssertNil(disabled.singleQuota?.remainingFraction)
        XCTAssertTrue(state.statusBarQuotaTitle(at: now).contains("暂无数据"))
    }

    @MainActor
    func testGlobalAggregateUsesPlanReadingsAndRelaysPastExhaustedPlans() throws {
        let (state, _, directory) = try makeFixture(
            adminEnabled: true,
            adminKeys: [CodexAdminKeyConfig(id: "api-month", label: "API", apiKey: "sk-api", monthlyQuotaLimit: 100)],
            zcodeEnabled: true
        )
        defer { state.stop(); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let exhausted = makeModel(interval: 0, weekly: 0, now: now)
        let active = makeModel(interval: 40, weekly: 50, now: now)
        let zeroCredit = OpenAIApiCreditDetails(
            organizationName: "API", totalQuota: 100, usedAmount: 100,
            cycleStart: now.addingTimeInterval(-86_400), cycleEnd: now.addingTimeInterval(86_400),
            fetchedAt: now, keyId: "api-month", keyLabel: "API"
        )
        setQuota(
            QuotaInfo(models: [exhausted], resetCredits: nil, planLabel: nil, accountEmail: nil,
                      codexUsageDetails: nil, fetchedAt: now, openAIApiCredits: zeroCredit),
            for: "codex_chatgpt", in: state
        )
        let expiredActivity = GlmActivityPlanBalance(
            planID: "plan-expired", planName: "Expired", entitlementID: "entitlement-expired",
            showName: "GLM-5.3", modelNames: ["glm-5.3"], totalUnits: 100,
            usedUnits: 100, remainingUnits: 0, expiresAt: now.addingTimeInterval(-60), observedAt: now
        )
        setQuota(
            QuotaInfo(
                models: [active], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now,
                glmZcodePackage: GlmZcodePackageSnapshot(activityPlanBalances: [expiredActivity])
            ),
            for: "glm_coding_plan", in: state
        )

        XCTAssertNil(state.configStore.config.statusBarQuotaSelection)
        let metrics = state.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.40, accuracy: 0.001,
                       "global display relays past the exhausted Codex plan to the active GLM plan")
        XCTAssertEqual(metrics.interval.avgAvailable, 0.20, accuracy: 0.001,
                       "the global plan arc includes both plan windows, including the exhausted one")
        XCTAssertNil(metrics.singleQuota, "global multi-provider dual-window plan keeps the dual gauge")
    }
}
