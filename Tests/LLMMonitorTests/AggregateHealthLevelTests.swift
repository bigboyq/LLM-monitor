import XCTest
import Foundation
@testable import LLM_monitor

final class AggregateHealthLevelTests: XCTestCase {

    @MainActor
    func testAppStateSystemHealthLevel() {
        let descriptors = [
            FetcherDescriptor(
                id: "test_a",
                displayName: "Test A",
                kind: .minimaxTokenPlan,
                iconSystemName: "bubble.left",
                accentColor: .minimax,
                makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "key") }
            ),
            FetcherDescriptor(
                id: "test_b",
                displayName: "Test B",
                kind: .codexChatGpt,
                iconSystemName: "sparkles",
                accentColor: .chatgpt,
                makeFetcher: { _ in CodexFetcher(authPath: nil) }
            ),
            FetcherDescriptor(
                id: "test_glm",
                displayName: "Test GLM",
                kind: .glmCodingPlan,
                iconSystemName: "bolt",
                accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
            )
        ]

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        let store = ConfigStore(configURL: configURL)
        // Custom test descriptors are not part of ConfigStore's built-in
        // template. Explicitly disable them so the test does not inherit
        // AppState's compatibility fallback for a missing provider entry.
        var initialConfig = store.config
        for id in ["test_a", "test_b", "test_glm"] {
            initialConfig.providers[id] = ProviderConfig(enabled: false)
        }
        try? store.applyAndSave(initialConfig)
        let appState = AppState(descriptors: descriptors, configStore: store)
        defer { appState.stop() }

        // 默认全未启用 -> nil
        XCTAssertNil(appState.systemHealthLevel)

        // 启用 test_a 设为 ok / healthy
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(cfg)
        appState.rebuildStatuses()

        let healthyModel = ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 20,
            intervalRemainingPercent: 80.0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 18000,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let healthyInfo = QuotaInfo(
            models: [healthyModel],
            resetCredits: nil,
            planLabel: "Standard",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        appState.mutateStatus(for: "test_a") { st in
            st.state = .ok(healthyInfo)
        }

        XCTAssertEqual(appState.systemHealthLevel, .healthy)

        // 设为 warning
        let warningModel = ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 80,
            intervalRemainingPercent: 20.0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 18000,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let warningInfo = QuotaInfo(
            models: [warningModel],
            resetCredits: nil,
            planLabel: "Standard",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        appState.mutateStatus(for: "test_a") { st in
            st.state = .ok(warningInfo)
        }

        XCTAssertEqual(appState.systemHealthLevel, .warning)

        // 设为 critical 失败
        appState.mutateStatus(for: "test_a") { st in
            st.state = .failed(message: "Auth error", lastSuccess: nil)
        }

        XCTAssertEqual(appState.systemHealthLevel, .critical)

        // 时间派生状态可注入固定 now：同一份 provider 数据在高峰边界前后应切换。
        cfg = store.config
        cfg.providers["test_glm"] = ProviderConfig(
            enabled: true,
            apiKey: "key",
            peakStartHour: 14,
            peakEndHour: 18,
            peakWeekdaysOnly: false
        )
        try? store.applyAndSave(cfg)
        appState.rebuildStatuses()
        appState.mutateStatus(for: "test_a") { $0.state = .ok(healthyInfo) }
        appState.mutateStatus(for: "test_glm") { $0.state = .ok(healthyInfo) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = DateComponents(year: 2026, month: 8, day: 10)
        let beforePeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 13, minute: 59
        ))!
        let duringPeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 14, minute: 0
        ))!
        let afterPeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 18, minute: 0
        ))!

        XCTAssertEqual(appState.systemHealthLevel(at: beforePeak), .healthy)
        XCTAssertEqual(appState.systemHealthLevel(at: duringPeak), .warning)
        XCTAssertEqual(appState.systemHealthLevel(at: afterPeak), .healthy)
    }

    /// 修复回归：状态栏 SF Symbol 圆点（systemHealthLevel）与卡片头部点
    /// （ProviderStatus.aggregateHealthLevel）必须同口径。GLM N=5 反例：
    /// 5h 剩 40%（无 reset 时间）、周剩 8%（8%×5=40%，并列瓶颈取 5h →
    /// 固定 30% 黄线 → 绿）；旧实现走逐窗口 healthLevel 时周 8% 直接判红，
    /// 两处颜色反向。
    @MainActor
    func testSystemHealthLevelMatchesCardAggregateHealthLevel() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_glm"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(cfg)

        let descriptors = [
            FetcherDescriptor(
                id: "test_glm",
                displayName: "Test GLM",
                kind: .glmCodingPlan,
                iconSystemName: "bolt",
                accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
            )
        ]
        let appState = AppState(descriptors: descriptors, configStore: store)
        defer { appState.stop() }

        // 固定在周六上午（非 GLM 高峰窗口：工作日 14:00–18:00）：高峰保底会把
        // 期望的 healthy 压成 warning，用真实 Date() 的断言在高峰时段必然翻车。
        let now = Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 3, hour: 10)
        )!

        let glmModel = ModelQuota(
            modelName: "glm_coding_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 60,
            intervalRemainingPercent: 40.0,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 100,
            weeklyUsageCount: 92,
            weeklyRemainingPercent: 8.0,
            weeklyStatus: .present,
            weeklyResetsAt: now.addingTimeInterval(7 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        let info = QuotaInfo(
            models: [glmModel],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: now
        )
        appState.mutateStatus(for: "test_glm") { $0.state = .ok(info) }

        let status = appState.statuses.first(where: { $0.id == "test_glm" })!
        XCTAssertEqual(status.aggregateHealthLevel(at: now), .healthy, "卡片头部点按实际可用口径（周 × 5，瓶颈 5h）应为绿")
        // 旧逐窗口口径对该反例判红（周 8% < 15 直接 critical），保留交叉断言。
        XCTAssertEqual(info.healthLevel, .critical)
        XCTAssertEqual(appState.systemHealthLevel(at: now), status.aggregateHealthLevel(at: now), "状态栏 SF Symbol 圆点必须与卡片头部点同色")
        XCTAssertEqual(appState.systemHealthLevel(at: now), .healthy)
    }

    @MainActor
    // MARK: - 统一 colorLevel 判定（方案 A）

    /// `ModelQuota.aggregateHealthLevel`：binding 选择与并列取 5h、周 × N 折算、
    /// 高峰 floor、无窗口 .critical。
    func testModelQuotaAggregateHealthLevel() {
        let week = 7.0 * 24 * 3600

        func makeModel(
            intervalPercent: Double?,
            weeklyPercent: Double?,
            weeklyTimeFraction: Double = 1.0
        ) -> ModelQuota {
            ModelQuota(
                modelName: "model",
                intervalTotalCount: 100,
                intervalUsageCount: 100 - Int(intervalPercent ?? 0),
                intervalRemainingPercent: intervalPercent ?? 0,
                intervalStatus: intervalPercent != nil ? .present : .absent,
                intervalResetsAt: intervalPercent != nil ? Date().addingTimeInterval(3600) : nil,
                intervalWindowSeconds: intervalPercent != nil ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: 100 - Int(weeklyPercent ?? 0),
                weeklyRemainingPercent: weeklyPercent ?? 0,
                weeklyStatus: weeklyPercent != nil ? .present : .absent,
                weeklyResetsAt: weeklyPercent != nil
                    ? Date().addingTimeInterval(week * weeklyTimeFraction)
                    : nil,
                weeklyWindowSeconds: weeklyPercent != nil ? Int(week) : nil
            )
        }

        // 1. 无任何窗口 → .critical（对齐 statusBarHealthLevel 的历史语义）。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan),
            .critical
        )

        // 2. 仅 5h 短窗口：固定 30% 黄线、< 15 红。35% 绿 / 25% 黄 / 10% 红。
        XCTAssertEqual(makeModel(intervalPercent: 35, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .healthy)
        XCTAssertEqual(makeModel(intervalPercent: 25, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .warning)
        XCTAssertEqual(makeModel(intervalPercent: 10, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .critical)

        // 3. 仅周窗口：周 × N 折算参与。GLM N=5：周 8% → 40%，瓶颈周（tf≈1 →
        //    黄线 50）→ 黄。若未折算，8% 会直接落进 < 15 的红区。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: 8).aggregateHealthLevel(providerKind: .glmCodingPlan),
            .warning
        )
        // codex N=6：周 6% → 36% → 黄（原始 6% 为红，折算改变判定）。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: 6).aggregateHealthLevel(providerKind: .codexChatGpt),
            .warning
        )

        // 4. 双窗口并列（5h 40% = 周 8%×5）：并列取 5h → tf 为 nil（固定 30% 黄线）
        //    → 40% 绿。若错误地取周瓶颈（tf≈1 → 黄线 50），40% 会是黄。
        XCTAssertEqual(
            makeModel(intervalPercent: 40, weeklyPercent: 8).aggregateHealthLevel(providerKind: .glmCodingPlan),
            .healthy
        )

        // 5. 高峰 floor：healthy 被压到 warning；critical 保持 critical（红色优先）。
        XCTAssertEqual(
            makeModel(intervalPercent: 80, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: true),
            .warning
        )
        XCTAssertEqual(
            makeModel(intervalPercent: 80, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: false),
            .healthy
        )
        XCTAssertEqual(
            makeModel(intervalPercent: 10, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: true),
            .critical
        )
    }

    /// `ProviderStatus.aggregateHealthLevel`：nil 透传（灰点）、空窗口 .critical、
    /// deepseek 余额卡头点与旧 `healthLevel` 行为一致、GLM 高峰 floor。
    func testProviderStatusAggregateHealthLevel() {
        func makeBalanceModel(percent: Double) -> ModelQuota {
            ModelQuota(
                modelName: "deepseek_balance",
                intervalTotalCount: 0,
                intervalUsageCount: 0,
                intervalRemainingPercent: percent,
                intervalStatus: .present,
                intervalResetsAt: nil,
                intervalWindowSeconds: nil,
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: 0,
                weeklyStatus: .absent,
                weeklyResetsAt: nil,
                weeklyWindowSeconds: nil
            )
        }

        func makeStatus(
            kind: ProviderKind,
            state: ProviderStatus.State,
            glmPeakWindow: PeakWindow? = nil
        ) -> ProviderStatus {
            var status = ProviderStatus(
                id: "t", displayName: "T", kind: kind,
                iconSystemName: "c", accentColor: .minimax,
                refreshIntervalSeconds: 60, state: state
            )
            status.glmPeakWindow = glmPeakWindow
            return status
        }

        // 1. lastSuccess 为 nil → nil（保持灰点语义）。
        XCTAssertNil(makeStatus(kind: .codexChatGpt, state: .ready).aggregateHealthLevel())
        XCTAssertNil(
            makeStatus(kind: .glmCodingPlan, state: .loading(lastSuccess: nil)).aggregateHealthLevel()
        )

        // 2. deepseek 余额模型：新路径与旧 `healthLevel` 完全一致（50% 绿 / 0% 红），
        //    卡头点现状颜色不变。
        for percent in [50.0, 0.0] {
            let status = makeStatus(
                kind: .deepseek,
                state: .ok(QuotaInfo(
                    models: [makeBalanceModel(percent: percent)],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            )
            XCTAssertEqual(status.aggregateHealthLevel(), status.healthLevel)
        }
        XCTAssertEqual(
            makeStatus(
                kind: .deepseek,
                state: .ok(QuotaInfo(
                    models: [makeBalanceModel(percent: 50)],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            ).aggregateHealthLevel(),
            .healthy
        )

        // 3. 有数据但 models 为空（无有效窗口 model）→ .critical（对齐 QuotaInfo.healthLevel 现状）。
        XCTAssertEqual(
            makeStatus(
                kind: .minimaxTokenPlan,
                state: .ok(QuotaInfo(
                    models: [],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            ).aggregateHealthLevel(),
            .critical
        )

        // 4. GLM 高峰 floor：高峰时 healthy → warning；非高峰保持 healthy。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let offPeak = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 10))!
        let peak = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 15))!
        let glmHealthy = makeStatus(
            kind: .glmCodingPlan,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "glm_coding_plan",
                    intervalTotalCount: 100, intervalUsageCount: 20,
                    intervalRemainingPercent: 80,
                    intervalStatus: .present,
                    intervalResetsAt: Date().addingTimeInterval(3600),
                    intervalWindowSeconds: 5 * 3600,
                    weeklyTotalCount: 0, weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0, weeklyStatus: .absent,
                    weeklyResetsAt: nil, weeklyWindowSeconds: nil
                )],
                resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: Date()
            )),
            glmPeakWindow: PeakWindow(startHour: 14, endHour: 18, weekdaysOnly: false)
        )
        XCTAssertEqual(glmHealthy.aggregateHealthLevel(at: offPeak), .healthy)
        XCTAssertEqual(glmHealthy.aggregateHealthLevel(at: peak), .warning, "高峰时卡头点保底黄色")
    }

    // MARK: - 单模型健康度档位与窗口 present 判定（自 UsableAPIKeyHealthLevelTests 解散归入）

    func testHealthLevelAndQuotaStatusRules() throws {
        let absentWeekly = ModelQuota(modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 80, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil)
        XCTAssertEqual(absentWeekly.healthLevel, .healthy)

        let presentWeekly = ModelQuota(modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 80, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 10, weeklyStatus: .present, weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil)
        XCTAssertEqual(presentWeekly.healthLevel, .critical)

        XCTAssertTrue(QuotaWindowStatus.present.isPresent)
        XCTAssertFalse(QuotaWindowStatus.absent.isPresent)
    }
}
