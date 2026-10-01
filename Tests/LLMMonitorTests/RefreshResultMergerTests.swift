import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 多客户端额度合并的 identity 与 codex 缺失回退。对应 `RefreshResultMerger`。
final class RefreshResultMergerTests: StateTestCase {

    // MARK: - 测试 fixture
    /// 构造一个简单的 ModelQuota，测试用（不依赖具体业务字段）
    func makeModel(
        _ name: String,
        intervalPercent: Double = 80,
        weeklyPercent: Double = 70,
        weeklyStatus: QuotaWindowStatus = .present
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 20,
            intervalRemainingPercent: intervalPercent,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 1000,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: weeklyPercent,
            weeklyStatus: weeklyStatus,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }
    func makeQuotaInfo(
        models: [ModelQuota] = [],
        resetCredits: ResetCreditsInfo? = nil,
        planLabel: String? = nil,
        accountEmail: String? = nil,
        codexUsageDetails: CodexUsageDetails? = nil,
        fetchedAt: Date = Date()
    ) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: resetCredits,
            planLabel: planLabel,
            accountEmail: accountEmail,
            codexUsageDetails: codexUsageDetails,
            fetchedAt: fetchedAt
        )
    }
    // MARK: - RefreshResultMerger: identity / codex 缺失回退
    /// CodexFillingMissingMerger 4 行为 in 1：
    /// - 新值 nil + previous 有值 → 用 previous 的 (回退 resetCredits / codexUsageDetails)
    /// - 新值非 nil → 用 new (不污染)
    /// - 没 previous → 直接返回 new
    /// - 必须始终保留最新 quota models (回退字段不影响主 quota)
    func testFillingMissingMergerBehaviors() {
        let merger = CodexFillingMissingMerger()
        // 1. 新值 nil + previous 有 resetCredits → 回退到 previous
        do {
            let prevEntry = ResetCreditEntry(
                id: "credit-1", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "Full reset (Weekly + 5 hr)", description: nil
            )
            let prevReset = ResetCreditsInfo(entries: [prevEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: prevReset)
            let new = makeQuotaInfo(
                models: [makeModel("chatgpt_plan", intervalPercent: 42)],
                resetCredits: nil
            )
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.resetCredits, prevReset, "新值 nil 时应回退到上次的 resetCredits")
            XCTAssertEqual(merged.models, new.models, "Codex merger 必须始终保留最新 quota models")
        }
        // 2. 新值 nil + previous 有 codexUsageDetails → 回退
        do {
            let prevDetails = CodexUsageDetails(
                primary: nil, secondary: nil, lastPrompt: nil, dailyTokenUsage: nil, scannedAt: Date()
            )
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], codexUsageDetails: prevDetails)
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], codexUsageDetails: nil)
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.codexUsageDetails, prevDetails, "新值 nil 时应回退到上次的 codexUsageDetails")
        }
        // 3. 新值非 nil → 用 new (不污染)
        do {
            let prevEntry = ResetCreditEntry(
                id: "credit-1", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "Prev", description: nil
            )
            let newEntry = ResetCreditEntry(
                id: "credit-2", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "New", description: nil
            )
            let prevReset = ResetCreditsInfo(entries: [prevEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let newReset = ResetCreditsInfo(entries: [newEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: prevReset)
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: newReset)
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.resetCredits, newReset, "新值非 nil 时直接用新值")
        }
        // 4. 没 previous → 直接返回 new (保持 nil)
        do {
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: nil)
            let merged = merger.merge(new: new, previous: nil, mode: .background)
            XCTAssertEqual(merged.resetCredits, nil, "没 previous 时直接用 new（保持 nil）")
        }
    }
    /// Merger 注入 / fetcher 接线 3 in 1：
    /// - IdentityRefreshResultMerger 不修改 models (always returns new)
    /// - MinimaxTokenPlanFetcher 用默认 identity merger (保留本次完整响应)
    /// - CodexFetcher.resultMerger 是 CodexFillingMissingMerger
    func testRefreshResultMergerWiring() {
        // 1. IdentityRefreshResultMerger 不修改 models
        do {
            let merger = IdentityRefreshResultMerger()
            let new = makeQuotaInfo(models: [makeModel("general")])
            let previous = makeQuotaInfo(models: [makeModel("general", intervalPercent: 1)])
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.models, new.models, "identity merger 不应改 models")
        }
        // 2. MinimaxTokenPlanFetcher 用默认 identity merger
        do {
            let minimaxFetcher = MinimaxTokenPlanFetcher(apiKey: "test")
            let new = makeQuotaInfo(models: [makeModel("video", intervalPercent: 20)])
            let previous = makeQuotaInfo(models: [makeModel("video", intervalPercent: 80)])
            let merged = minimaxFetcher.resultMerger.merge(
                new: new, previous: previous, mode: .background
            )
            XCTAssertEqual(merged, new, "Minimax 应使用默认 identity merger, 保留本次完整响应")
        }
        // 3. CodexFetcher.resultMerger 是 CodexFillingMissingMerger
        do {
            let codexFetcher = CodexFetcher()
            XCTAssertNotNil(codexFetcher.resultMerger as? CodexFillingMissingMerger,
                            "CodexFetcher.resultMerger 应是 CodexFillingMissingMerger")
        }
    }
}
