import XCTest
import CoreGraphics
@testable import LLM_monitor

/// statuses → 圆环条目投影与条目顺序。对应 `EdgeDockProjection`。
final class EdgeDockProjectionTests: EdgeDockTestCase {

    // MARK: - 投影：statuses → 圆环条目

    func testProjectionOnlyIncludesEnabledProviders() {
        // 「开启监控的」就是这个过滤条件：disabled 的 provider 不该出现在边缘窗。
        let statuses = [
            makeStatus(id: "on", enabled: true, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 50)]))),
            makeStatus(id: "off", enabled: false, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 50)]))),
        ]
        let entries = EdgeDockProjection.entries(from: statuses)
        XCTAssertEqual(entries.map(\.id), ["on"])
    }

    func testProjectionSeparatesIntervalAndWeeklyWindows() {
        // 外环读 5 小时、内环读周额度，两个窗口各走各的原始百分比。
        let status = makeStatus(id: "dual", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 40, weeklyPercent: 85),
        ])))
        let entry = EdgeDockProjection.entries(from: [status])[0]
        XCTAssertEqual(entry.intervalFraction ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(entry.weeklyFraction ?? -1, 0.85, accuracy: 0.0001)
        XCTAssertTrue(entry.hasAnyQuotaWindow)
    }

    func testWeeklyRingUsesRawPercentNotEquivalentMultiplier() {
        // 内环表达"周额度本身还剩多少"，不能乘周等效倍率 N。
        // codex 的 N = 6，乘完 50% 会变成 300%（封顶满环），读出来就不是周额度了。
        let status = makeStatus(id: "codex", kind: .codexChatGpt, state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 40, weeklyPercent: 50),
        ])))
        XCTAssertEqual(EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.50, accuracy: 0.0001)
    }

    func testOnlyWeeklyWindowLeavesOuterRingEmpty() {
        // 只有周窗口的 provider：外环 nil（不画弧），内环有值。
        let status = makeStatus(id: "weekly_only", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: nil, weeklyPercent: 70),
        ])))
        let entry = EdgeDockProjection.entries(from: [status])[0]
        XCTAssertNil(entry.intervalFraction)
        XCTAssertEqual(entry.weeklyFraction ?? -1, 0.70, accuracy: 0.0001)
        XCTAssertTrue(entry.hasAnyQuotaWindow)
    }

    func testProjectionUsesWorstModelNotAveragePerWindow() {
        // 一个 provider 下多个 model 时每个窗口各取最低值：平均值会把瓶颈洗掉。
        let status = makeStatus(id: "multi", state: .ok(makeInfo([
            makeModel(name: "a", intervalPercent: 90, weeklyPercent: 95),
            makeModel(name: "b", intervalPercent: 20, weeklyPercent: 60),
            makeModel(name: "c", intervalPercent: 70, weeklyPercent: 30),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.20, accuracy: 0.0001
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.30, accuracy: 0.0001
        )
    }

    func testProjectionFractionsAreNilWithoutData() {
        // 没抓到数据 ≠ 满额。两个环都必须是 nil，视图才画压暗满环而不是空环。
        let ready = makeStatus(id: "ready", state: .ready)
        XCTAssertNil(EdgeDockProjection.intervalFraction(ready, at: Date()))
        XCTAssertNil(EdgeDockProjection.weeklyFraction(ready, at: Date()))
        let entry = EdgeDockProjection.entries(from: [ready]).first
        XCTAssertNil(entry?.intervalFraction)
        XCTAssertNil(entry?.weeklyFraction)
        XCTAssertFalse(entry?.hasAnyQuotaWindow ?? true)
    }

    func testProjectionKeepsLastSuccessWhileLoading() {
        // loading / failed 期间仍能用上次的成功数据画环，而不是闪成"无数据"。
        let info = makeInfo([makeModel(name: "g", intervalPercent: 42, weeklyPercent: 77)])
        for status in [
            makeStatus(id: "loading", state: .loading(lastSuccess: info)),
            makeStatus(id: "failed", state: .failed(message: "boom", lastSuccess: info)),
        ] {
            XCTAssertEqual(
                EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.42, accuracy: 0.0001
            )
            XCTAssertEqual(
                EdgeDockProjection.weeklyFraction(status, at: Date()) ?? -1, 0.77, accuracy: 0.0001
            )
        }
    }

    func testProjectionFailedWithoutCacheHasNoHealth() {
        let failed = makeStatus(id: "failed", state: .failed(message: "boom", lastSuccess: nil))
        XCTAssertNil(EdgeDockProjection.intervalFraction(failed, at: Date()))
        XCTAssertNil(EdgeDockProjection.entries(from: [failed]).first?.health)
    }

    func testProjectionSkipsModelsWithoutActiveWindow() {
        // 无窗口占位 model 不参与 min，否则一个 0% 占位会把整个环打成空环。
        let status = makeStatus(id: "placeholder", state: .ok(makeInfo([
            makeModel(name: "real", intervalPercent: 60),
            ModelQuota(
                modelName: "no_window",
                intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 0,
                intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            ),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Date()) ?? -1, 0.60, accuracy: 0.0001
        )
    }

    func testProjectionCarriesKindForBrandIcon() {
        // 中心图标按 kind 取品牌资源，投影必须把它带出来。
        let status = makeStatus(id: "glm", kind: .glmCodingPlan, state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 50),
        ])))
        XCTAssertEqual(EdgeDockProjection.entries(from: [status]).first?.kind, .glmCodingPlan)
    }

    func testProjectionEntryIDsAreStableAcrossOrdering() {
        // id 必须用 providerID 而不是显示名或下标：popover 定位与高亮靠它认人。
        // kind 要给成不同的两个：排序键是 `quotaProviderID`，两个同 kind 的条目
        // 在配置里是同一个键，配置本来就表达不了它们的先后。
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        // 没传 preferredIDs = 用户没配过顺序 → 退回显示名升序（ANTIGRAVITY < CODEX_CHATGPT）
        let ids = EdgeDockProjection.entries(from: statuses).map(\.id)
        XCTAssertEqual(ids, ["antigravity", "codex_chatgpt"], "默认按显示名升序")
        XCTAssertEqual(Set(ids).count, ids.count, "id 不重复")
    }

    // MARK: - 条目顺序 = 配置里的 provider 顺序

    /// dock 必须按设置页里排的顺序展示，且与菜单卡片**同序**：
    /// 两处各排各的会让用户在菜单里排好的位置到 dock 里失效。
    func testProjectionFollowsConfiguredProviderOrder() {
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "deepseek", kind: .deepseek, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        // 配置键是 quotaProviderID，不是 status.id / providerID —— 与菜单同一份。
        let ordered = EdgeDockProjection.entries(
            from: statuses,
            preferredIDs: [QuotaProviderID.deepseek, QuotaProviderID.openAI]
        )
        XCTAssertEqual(ordered.map(\.id), ["deepseek", "codex_chatgpt", "antigravity"],
                       "已配置的按配置排，没配的按显示名升序补在后面")

        // 与菜单卡片对同一份 statuses + 同一份顺序必须得到同一个次序。
        let cards = DisplayOrder.ordered(
            statuses,
            preferredIDs: [QuotaProviderID.deepseek, QuotaProviderID.openAI],
            id: { $0.kind.quotaProviderID },
            by: ProviderStatus.displayNameAscending
        )
        XCTAssertEqual(ordered.map(\.id), cards.map(\.id), "dock 与菜单卡片必须同序")
    }

    /// 配置里的顺序必须**真的**改变 dock 顺序——上一条钉的是"按配置排"，
    /// 这条钉的是"不是碰巧对"：给一个非默认序，输出必须跟着换。
    func testProjectionOrderActuallyTracksConfig() {
        let statuses = [
            makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "codex_chatgpt", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "deepseek", kind: .deepseek, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        XCTAssertEqual(
            EdgeDockProjection.entries(
                from: statuses, preferredIDs: [QuotaProviderID.antigravity, QuotaProviderID.deepseek]
            ).map(\.id),
            ["antigravity", "deepseek", "codex_chatgpt"]
        )
        XCTAssertEqual(
            EdgeDockProjection.entries(
                from: statuses, preferredIDs: [QuotaProviderID.zhipu]
            ).map(\.id),
            ["antigravity", "codex_chatgpt", "deepseek"],
            "配置里全是无效 id 时退回默认序，不该空掉"
        )
    }

    /// 两个条目共用同一个配置键（同一个 kind）不能让投影 trap：
    /// 命中判定每次鼠标移动都跑一遍 `entries`，这里崩就是整 app 崩。
    func testProjectionSurvivesDuplicateProviderKeys() {
        let statuses = [
            makeStatus(id: "dup_a", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
            makeStatus(id: "dup_b", kind: .codexChatGpt, state: .ok(makeInfo([makeModel(name: "g", intervalPercent: 30)]))),
        ]
        let entries = EdgeDockProjection.entries(from: statuses)
        XCTAssertEqual(entries.count, 1, "同一个配置键只保留先出现的那个")
        XCTAssertEqual(entries.first?.id, "dup_a")
    }

    func testProjectionEmptyStatusesProducesNoEntries() {
        // 一个 provider 都没开监控时，controller 据此完全不显示窗口。
        XCTAssertTrue(EdgeDockProjection.entries(from: []).isEmpty)
        XCTAssertTrue(EdgeDockProjection.entries(from: [makeStatus(id: "off", enabled: false, state: .ready)]).isEmpty)
    }
}
