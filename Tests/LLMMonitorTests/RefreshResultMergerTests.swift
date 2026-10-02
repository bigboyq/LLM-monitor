import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 多客户端额度合并的 identity 与 codex 缺失回退。对应 `RefreshResultMerger`。
///
/// 同时承载 Codex reset credits 的独立新鲜度语义（合并/过期/恢复 + `isStale`
/// 阈值），拆自 `CodexResetCreditsFreshnessTests`，逐字搬移零逻辑变化。
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

    // MARK: - R3: Codex reset credits 独立新鲜度（合并自 CodexResetCreditsFreshnessTests）
    // 通过 `CodexFillingMissingMerger`（纯函数）覆盖：首次失败无旧值、成功后失败、
    // 连续失败、恢复成功、background 跳过不冒充失败，外加 isStale 阈值语义。

    private let merger = CodexFillingMissingMerger()

    private func resetCredits(available: Int, fetchedAt: Date, failed: Bool = false) -> ResetCreditsInfo {
        ResetCreditsInfo(
            entries: (0..<available).map { i in
                ResetCreditEntry(
                    id: "c\(i)",
                    status: "available",
                    expiresAt: Date().addingTimeInterval(86_400),
                    grantedAt: nil,
                    resetType: nil,
                    title: nil,
                    description: nil
                )
            },
            serverAvailableCount: available,
            totalEarnedCount: available,
            fetchedAt: fetchedAt,
            lastAttemptFailed: failed
        )
    }

    private func quota(resetCredits: ResetCreditsInfo?, fetchedAt: Date = Date()) -> QuotaInfo {
        QuotaInfo(
            models: [],
            resetCredits: resetCredits,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: fetchedAt
        )
    }

    /// 首次 full 失败、无旧值 → 没有 resetCredits 可显示，整张卡不算失败。
    func testFirstFullFailureWithNoPreviousLeavesNoResetCredits() {
        let new = quota(resetCredits: nil)  // full 抓取但 reset credits 失败
        let merged = merger.merge(new: new, previous: nil, mode: .full)
        XCTAssertNil(merged.resetCredits, "无旧值时 reset credits 失败不应凭空产生数据")
    }

    /// 成功后失败：previous 有 fresh 值，full 抓取 reset credits 失败 → 保留旧值并标记过期。
    func testSuccessThenFullFailureMarksStale() {
        let prevFetchedAt = Date().addingTimeInterval(-300)
        let previous = quota(resetCredits: resetCredits(available: 3, fetchedAt: prevFetchedAt))
        // 下一次 full：主 quota 成功，但 reset credits 子请求失败（new.resetCredits = nil）
        let new = quota(resetCredits: nil)
        let merged = merger.merge(new: new, previous: previous, mode: .full)

        let resets = merged.resetCredits
        XCTAssertEqual(resets?.availableCount, 3, "保留上次的 reset credits 值")
        XCTAssertEqual(resets?.fetchedAt, prevFetchedAt, "保留上次的实际抓取时间，不用主 fetchedAt 冒充")
        XCTAssertTrue(resets?.lastAttemptFailed == true, "full 失败应标记过期")
    }

    /// 连续失败：旧值与过期标志继续保留。
    func testConsecutiveFullFailuresKeepStaleValue() {
        let prevFetchedAt = Date().addingTimeInterval(-600)
        let stalePrev = quota(resetCredits: resetCredits(available: 2, fetchedAt: prevFetchedAt, failed: true))
        let new = quota(resetCredits: nil)
        let merged = merger.merge(new: new, previous: stalePrev, mode: .full)

        XCTAssertEqual(merged.resetCredits?.availableCount, 2)
        XCTAssertEqual(merged.resetCredits?.fetchedAt, prevFetchedAt)
        XCTAssertTrue(merged.resetCredits?.lastAttemptFailed == true)
    }

    /// 恢复成功：full 抓取重新拿到 reset credits → 清除失败标志，更新时间。
    func testRecoveryFullSuccessClearsStale() {
        let stalePrev = quota(resetCredits: resetCredits(available: 2, fetchedAt: Date().addingTimeInterval(-600), failed: true))
        let freshAt = Date()
        let new = quota(resetCredits: resetCredits(available: 5, fetchedAt: freshAt), fetchedAt: freshAt)
        let merged = merger.merge(new: new, previous: stalePrev, mode: .full)

        XCTAssertEqual(merged.resetCredits?.availableCount, 5, "用新的成功值")
        XCTAssertEqual(merged.resetCredits?.fetchedAt, freshAt)
        XCTAssertFalse(merged.resetCredits?.lastAttemptFailed ?? true, "恢复成功应清除过期标志")
    }

    /// background 刷新按设计跳过 reset credits：保留 previous 值与新鲜度，不冒充失败。
    func testBackgroundSkipDoesNotMasqueradeAsFailure() {
        let prevFetchedAt = Date().addingTimeInterval(-120)
        let freshPrev = quota(resetCredits: resetCredits(available: 4, fetchedAt: prevFetchedAt, failed: false))
        let new = quota(resetCredits: nil)  // background 不请求 reset credits
        let merged = merger.merge(new: new, previous: freshPrev, mode: .background)

        XCTAssertEqual(merged.resetCredits?.availableCount, 4)
        XCTAssertEqual(merged.resetCredits?.fetchedAt, prevFetchedAt, "不更新时间")
        XCTAssertFalse(merged.resetCredits?.lastAttemptFailed ?? true, "background 跳过不算失败")
    }

    /// isStale：失败立即过期；成功但年龄超过 max(3×interval, 15min) 过期；新鲜不过期。
    func testIsStaleThresholds() {
        let interval: TimeInterval = 300
        let now = Date(timeIntervalSince1970: 10_000)

        // 失败 → 立即过期
        let failed = resetCredits(available: 1, fetchedAt: now, failed: true)
        XCTAssertTrue(failed.isStale(now: now, refreshIntervalSeconds: interval))

        // 新鲜 → 不过期
        let fresh = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(fresh.isStale(now: now, refreshIntervalSeconds: interval))

        // 年龄 > max(3×300=900, 900) = 900s → 过期；恰好 900 不过期，901 过期
        let boundary = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-900))
        XCTAssertFalse(boundary.isStale(now: now, refreshIntervalSeconds: interval))
        let over = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-901))
        XCTAssertTrue(over.isStale(now: now, refreshIntervalSeconds: interval))

        // 小间隔 provider 仍至少 15 分钟才按年龄过期：interval=10s → max(30, 900)=900
        let smallInterval = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-500))
        XCTAssertFalse(smallInterval.isStale(now: now, refreshIntervalSeconds: 10))
    }

    /// R3 followup: 调用方按 `periodicFullEveryN`（默认 20）把 interval 预放大后再传入
    /// isStale；放大后的实际阈值是 `3 × (N × interval)`，默认 300s × 20 × 3 = 18000s = 5h。
    /// 这个测试钉死"5h 边界"的语义——也是为什么 8c6a97f 把 background 路径的过期判定
    /// 从旧的 15min 误报改为现在的 5h 真阈值。如果未来 caller 忘了 pre-scale，
    /// 这个测试会直接红。
    func testIsStaleUsesPeriodicFullPeriodAt5hBoundary() {
        // 模拟 caller 已经在 QuotaViews.swift 里把 interval × N 后传进来
        let intervalSeconds: TimeInterval = 300
        let periodicFullEveryN = 20
        let scaled = intervalSeconds * Double(periodicFullEveryN)  // 6000
        let now = Date(timeIntervalSince1970: 100_000)

        // 5h = 18000s；恰好 18000 不过期，18001 过期
        let exactlyThreshold = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-18000)
        )
        XCTAssertFalse(
            exactlyThreshold.isStale(now: now, refreshIntervalSeconds: scaled),
            "恰好 5h 仍应判定为新鲜"
        )

        let overThreshold = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-18001)
        )
        XCTAssertTrue(
            overThreshold.isStale(now: now, refreshIntervalSeconds: scaled),
            "超过 5h 应判定为过期"
        )

        // 4h 仍在 5h 阈值内 → 不过期
        let fourHoursOld = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-4 * 3600)
        )
        XCTAssertFalse(
            fourHoursOld.isStale(now: now, refreshIntervalSeconds: scaled),
            "4h 仍应判定为新鲜（5h 阈值内）"
        )

        // 防回归：如果 caller 忘了 pre-scale，传原始 interval=300，旧的 15min 误报逻辑
        // 会让 4h 数据被错误判定为过期——这就是 8c6a97f 修复前的 bug 行为。
        // 我们用同样的 4h 数据，传 unscaled interval 验证它确实会被误判。
        let preR3Behavior = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-4 * 3600)
        )
        XCTAssertTrue(
            preR3Behavior.isStale(now: now, refreshIntervalSeconds: intervalSeconds),
            "未 pre-scale 的 4h 数据按 3×300=900s 阈值会被误判为过期（防 R3 前行为回归）"
        )
    }
}
