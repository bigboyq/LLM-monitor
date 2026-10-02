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

    // MARK: - 逐窗口色档（内外环独立取色的输入）

    /// 5h 档位：固定 30% 黄线（`colorLevel` 的 `timeFraction == nil` 分支）、
    /// 固定 15% 红线。三个值分别落在红、黄、绿三段上——任何一个阈值漂了
    /// （比如有人把黄线改成 20%），这条会跟着红。
    func testIntervalHealthUsesFixedThirtyPercentYellowLine() {
        let red = makeStatus(id: "red", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 10),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(red, at: Self.makeNow), .critical,
            "10% 低于固定 15% 的红线"
        )

        let yellow = makeStatus(id: "yellow", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 25),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(yellow, at: Self.makeNow), .warning,
            "25% 在 15% 红线与 30% 黄线之间"
        )

        let green = makeStatus(id: "green", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 30),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(green, at: Self.makeNow), .healthy,
            "30% 正好压线，不吃动态黄线"
        )
    }

    /// 周档位：阈值 = min(剩余时间%, 50)。剩余时间多（0.6）时黄线收紧到 50%，
    /// 40% 落在黄线以下 → 黄；剩余时间少（0.2）时黄线只有 20%，40% 高于它 → 绿。
    /// 同一个百分比、不同的剩余时间给出不同的颜色，正是"时间感知阈值"存在的理由。
    func testWeeklyHealthTightensWithRemainingTime() {
        let plentyOfTime = makeStatus(id: "plenty", state: .ok(makeInfo([
            weeklyModel(percent: 40, timeFraction: 0.6),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.weeklyHealth(plentyOfTime, at: Self.makeNow), .warning,
            "剩余时间 60% 时黄线是 min(60, 50) = 50，40% 在黄线以下"
        )

        let runningOut = makeStatus(id: "short", state: .ok(makeInfo([
            weeklyModel(percent: 40, timeFraction: 0.2),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.weeklyHealth(runningOut, at: Self.makeNow), .healthy,
            "剩余时间 20% 时黄线是 20，40% 在黄线以上"
        )
    }

    /// 周色档**不吃**周等效倍率——与 `weeklyFraction` 同一个理由。内环表达的是
    /// "周额度本身还剩多少"，乘完 N 之后 40% 变成 240%，永远绿，读出来就不是周额度了。
    func testWeeklyHealthUsesRawPercentNotEquivalentMultiplier() {
        let status = makeStatus(id: "codex", kind: .codexChatGpt, state: .ok(makeInfo([
            weeklyModel(percent: 20, timeFraction: 0.6),
        ])))
        // 20% 低于 50% 的黄线，但高于固定 15% 的红线 → 黄。
        XCTAssertEqual(EdgeDockProjection.weeklyHealth(status, at: Self.makeNow), .warning)
        XCTAssertEqual(EdgeDockProjection.weeklyFraction(status, at: Self.makeNow) ?? -1, 0.20, accuracy: 0.0001)
    }

    /// 一个 provider 下多个 model 时**逐窗口**取最差档：颜色必须和弧长指向同一个
    /// 瓶颈，否则会出现"弧长来自 model a、颜色来自 model b"。
    func testPerWindowHealthTakesTheWorstModel() {
        let status = makeStatus(id: "multi", state: .ok(makeInfo([
            quotaModel(intervalPercent: 90, weeklyPercent: 95, weeklyTimeFraction: 0.6),
            quotaModel(intervalPercent: 10, weeklyPercent: 20, weeklyTimeFraction: 0.6),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(status, at: Self.makeNow), .critical,
            "10% 低于固定 15% 的红线，最差的那个 model 决定整环"
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyHealth(status, at: Self.makeNow), .warning,
            "20% 低于 min(60, 50) = 50 的黄线"
        )
    }

    /// 没有某个窗口 = 该窗口的色档是 nil（"读不到"），而不是某一档颜色。
    /// 视图据此落回中性灰：灰 ≠ 绿 ≠ 红。
    func testPerWindowHealthIsNilWithoutThatWindow() {
        let intervalOnly = makeStatus(id: "interval_only", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 50),
        ])))
        XCTAssertEqual(EdgeDockProjection.intervalHealth(intervalOnly, at: Self.makeNow), .healthy)
        XCTAssertNil(EdgeDockProjection.weeklyHealth(intervalOnly, at: Self.makeNow))

        let noData = makeStatus(id: "ready", state: .ready)
        XCTAssertNil(EdgeDockProjection.intervalHealth(noData, at: Self.makeNow))
        XCTAssertNil(EdgeDockProjection.weeklyHealth(noData, at: Self.makeNow))
        XCTAssertNil(EdgeDockProjection.entries(from: [noData]).first?.intervalHealth)
        XCTAssertNil(EdgeDockProjection.entries(from: [noData]).first?.weeklyHealth)
    }

    /// 投影必须把两个色档一起带出来：视图按 entry 取色，不回头再算一遍。
    /// 漏带的后果是"弧长有、颜色却是灰的"——用户读成没有数据。
    func testProjectionCarriesPerWindowHealth() {
        let status = makeStatus(id: "dual", state: .ok(makeInfo([
            quotaModel(intervalPercent: 20, weeklyPercent: 90, weeklyTimeFraction: 0.6),
        ])))
        let entry = EdgeDockProjection.entries(from: [status], at: Self.makeNow)[0]
        XCTAssertEqual(entry.intervalHealth, .warning)
        XCTAssertEqual(entry.weeklyHealth, .healthy)
        XCTAssertNotEqual(
            entry.intervalHealth, entry.weeklyHealth,
            "这正是独立取色要表达的差别：5h 已经偏紧、周还很空"
        )
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
