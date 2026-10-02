import XCTest
@testable import LLM_monitor

final class TruncationProjectionChainTests: XCTestCase {

    // MARK: - isTruncated 展示链（merger 规则 → contribution → projection → summary）

    private func makeDshSnapshot(isTruncated: Bool?) -> DshLocalUsage {
        var snapshot = DshLocalUsage(
            byProvider: [
                "deepseek-official": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: Date(timeIntervalSince1970: 1_700_000_000),
                        inputTokens: 10, outputTokens: 1, totalTokens: 11, turns: 1, rounds: 1
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 1,
                    recentSamples: []
                )
            ],
            modelsByProvider: ["deepseek-official": ["deepseek-v4-flash"]],
            sessionsRoot: "/tmp/dsh-sessions",
            sessionCount: 1,
            eventCount: 1,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        snapshot.isTruncated = isTruncated
        return snapshot
    }

    func testDshTruncationMergerRuleTreatsAnyTruncatedSourceAsTruncated() {
        // 合并规则：任一来源截断即截断（保守取 true）；nil 视为未截断/未知。
        // 引用点已从 `DshUsageMerger` 迁到 `DshHarnessFrames.anyTruncated`。
        XCTAssertFalse(DshHarnessFrames.anyTruncated(), "无来源 → 无截断")
        XCTAssertFalse(DshHarnessFrames.anyTruncated(nil), "nil 快照 → 未知，按未截断")
        XCTAssertFalse(DshHarnessFrames.anyTruncated(makeDshSnapshot(isTruncated: false)))
        XCTAssertTrue(DshHarnessFrames.anyTruncated(makeDshSnapshot(isTruncated: true)))
        XCTAssertTrue(
            DshHarnessFrames.anyTruncated(
                makeDshSnapshot(isTruncated: false),
                nil,
                makeDshSnapshot(isTruncated: true)
            ),
            "多来源混合时任一截断即整份展示数据按截断处理"
        )
        XCTAssertFalse(
            DshHarnessFrames.anyTruncated(
                makeDshSnapshot(isTruncated: false),
                makeDshSnapshot(isTruncated: nil)
            )
        )
    }

    func testDshTruncationFlagSurfacesThroughProjectionAndSummaryRows() throws {
        // 快照上的 isTruncated 必须穿透 usageProjection 的 DSH contribution 到达
        // 展示模型；nil（旧缓存快照）不得触发提示。
        var status = ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .ready
        )

        status.dshUsage = makeDshSnapshot(isTruncated: true)
        let truncatedProjection = status.usageProjection(for: nil)
        let dshContribution = try XCTUnwrap(
            truncatedProjection.contributions.first { $0.clientID == ClientID.dsh },
            "DSH 快照存在时必须产生 DSH contribution"
        )
        XCTAssertTrue(dshContribution.isTruncated, "截断标志必须透传到 contribution")
        XCTAssertTrue(
            truncatedProjection.isTruncated,
            "任一 contribution 截断即整卡按截断处理"
        )

        status.dshUsage = makeDshSnapshot(isTruncated: nil)
        let unknownProjection = status.usageProjection(for: nil)
        let unknownContribution = try XCTUnwrap(
            unknownProjection.contributions.first { $0.clientID == ClientID.dsh }
        )
        XCTAssertFalse(unknownContribution.isTruncated, "nil 视为未截断/未知，不显示提示")
        XCTAssertFalse(unknownProjection.isTruncated)

        // 全部来源未截断 → 整卡不提示。
        let allClear = ProviderUsageProjection(contributions: [
            ClientUsageContribution(
                clientID: ClientID.dsh, displayName: "DSH",
                dailyTokenUsage: [UnifiedDailyTokenUsage]()
            ),
            ClientUsageContribution(
                clientID: ClientID.openCode, displayName: "OpenCode",
                dailyTokenUsage: [UnifiedDailyTokenUsage]()
            )
        ])
        XCTAssertFalse(allClear.isTruncated)

        // 多来源聚合（DSH 截断 + 其他来源正常）→ 整卡截断。
        let mixed = ProviderUsageProjection(contributions: [
            ClientUsageContribution(
                clientID: ClientID.dsh, displayName: "DSH",
                dailyTokenUsage: [UnifiedDailyTokenUsage](),
                isTruncated: true
            ),
            ClientUsageContribution(
                clientID: ClientID.openCode, displayName: "OpenCode",
                dailyTokenUsage: [UnifiedDailyTokenUsage]()
            )
        ])
        XCTAssertTrue(mixed.isTruncated)

        // 展示模型（设置页展开行数据）承载标志，供 UI 提示渲染。
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.deepseek,
            providerName: "DeepSeek",
            usageGroupID: QuotaProviderID.deepseek,
            dailyTokenUsage: [UnifiedDailyTokenUsage](),
            recentSamples: [],
            scannedAt: nil,
            isTruncated: true
        )
        XCTAssertTrue(summary.isTruncated)
    }
}
