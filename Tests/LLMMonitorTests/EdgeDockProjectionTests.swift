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
        // 周充裕（85% × N=6 封顶 100 ≥ 40）：raw == effective，hover 文案维持单数值。
        XCTAssertEqual(entry.rawIntervalFraction ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            entry.rawIntervalFraction, entry.intervalFraction,
            "周不是瓶颈时原始值与有效额度一致"
        )
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

    // MARK: - 外环 = 5h 有效额度（min(5h 剩余, 周剩余 × 周等效倍率 N)，与状态栏同口径）

    /// 外环读 5h **有效额度**：codex 的周等效倍率 N = 6，周 10% 折算成 60%，
    /// 比原始 5h 的 90% 更紧 → 外环画 60% 而不是 90%。同时钉住内环不吃倍率
    /// （仍是原始周剩余 10%），防止有效额度口径渗透到内环。
    func testOuterRingUsesEffectiveQuotaWhenWeeklyTimesMultiplierIsTighter() {
        let status = makeStatus(id: "codex", kind: .codexChatGpt, state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 90, weeklyPercent: 10, now: Self.makeNow),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.60, accuracy: 0.0001,
            "周 10% × N=6 = 60% < 原始 5h 90%，外环取有效额度 60%"
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyFraction(status, at: Self.makeNow) ?? -1,
            0.10, accuracy: 0.0001,
            "内环仍是原始周剩余 10%，不乘倍率"
        )
        XCTAssertEqual(
            EdgeDockProjection.rawIntervalFraction(status) ?? -1,
            0.90, accuracy: 0.0001,
            "原始 5h 仍是 90%，只喂 hover 文案做对照，不参与画环"
        )
        // 投影把对照值带出条目：raw 0.90 ≠ 有效 0.60，hover 文案才能亮出
        // `5h 90%(60%有效)`，说明环为什么比 5h 剩余少。
        let entry = EdgeDockProjection.entries(from: [status], at: Self.makeNow)[0]
        XCTAssertEqual(entry.rawIntervalFraction ?? -1, 0.90, accuracy: 0.0001)
        XCTAssertEqual(entry.intervalFraction ?? -1, 0.60, accuracy: 0.0001)
    }

    /// antigravity 的 Claude/GPT 组周倍率 2026-10-13 从 1 调回 2（2026-10 初曾从 3 下调到 1）：
    /// 周剩余 × 2 = 60% 仍比原始 5h 的 90% 更紧——「周比 5h 更紧」的场景，实际只能用 60%。
    func testOuterRingUsesEffectiveQuotaForAntigravityClaudeGptGroup() {
        let status = makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([
            makeModel(
                name: AntigravityModelKind.claudeAndGptModels.rawValue,
                intervalPercent: 90,
                weeklyPercent: 30,
                now: Self.makeNow
            ),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.60, accuracy: 0.0001,
            "周 30% × N=2 = 60% < 原始 5h 90%，外环取有效额度 60%"
        )
        XCTAssertEqual(
            EdgeDockProjection.rawIntervalFraction(status) ?? -1,
            0.90, accuracy: 0.0001,
            "原始 5h 仍是 90%——有效额度收缩来自周瓶颈，原始值供 hover 文案对照"
        )
    }

    /// 外环颜色跟随**有效额度**而不是原始 5h：40% 的 5h 配 5% 的周（×6 = 30%），
    /// 有效额度 30%、瓶颈是周窗口 → 时间比例 0.6 → 动态黄线 min(60, 50) = 50，
    /// 30% < 50 → 黄。反事实：若仍按原始 5h 算，40% 配固定 30% 黄线会是 healthy——
    /// 这条测试钉住「颜色跟随有效额度、时间比例随瓶颈窗口走」的行为变化。
    func testOuterRingHealthFollowsEffectiveQuotaWithWeeklyBinding() {
        let status = makeStatus(id: "codex", kind: .codexChatGpt, state: .ok(makeInfo([
            quotaModel(intervalPercent: 40, weeklyPercent: 5, weeklyTimeFraction: 0.6),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.30, accuracy: 0.0001
        )
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(status, at: Self.makeNow), .warning,
            "瓶颈是周窗口：30% 低于动态黄线 min(60, 50) = 50；若按原始 5h（40% + 固定 30% 黄线）会是 healthy"
        )
    }

    /// 多 model 时有效额度也取**最低**的那个，且颜色与弧长来自同一个瓶颈：
    /// a 的 min(90, 90×6→封顶 100) = 90，b 的 min(80, 5×6 = 30) = 30 → 外环 30%，
    /// 颜色也按 b 的瓶颈（周窗口、动态黄线 50）判定 → 黄。若颜色另取 model
    /// （比如 a 的 90% 是绿的），弧长与颜色就指向两个不同的瓶颈。
    func testOuterRingEffectiveQuotaTakesWorstModel() {
        let status = makeStatus(id: "multi", kind: .codexChatGpt, state: .ok(makeInfo([
            quotaModel(intervalPercent: 90, weeklyPercent: 90, weeklyTimeFraction: 0.6),
            quotaModel(intervalPercent: 80, weeklyPercent: 5, weeklyTimeFraction: 0.6),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.30, accuracy: 0.0001
        )
        XCTAssertEqual(
            EdgeDockProjection.intervalHealth(status, at: Self.makeNow), .warning,
            "颜色来自瓶颈 model b（周瓶颈、30%），不与弧长脱钩"
        )
    }

    // MARK: - 聚合排除：minimax video / antigravity Claude and GPT 组不参与圆环聚合

    /// minimax 的 `video`（独立小配额池）不参与圆环与色档聚合（用户裁定 2026-10）：
    /// general 80%/60% + video 10%/5% 时，内外环与 health 只反映 general——否则外环
    /// 会被 video 的有效额度 min(10%, 5%×7=35%) = 10% 拖到 0.10。
    func testProjectionExcludesMinimaxVideoFromRingAggregation() {
        let status = makeStatus(id: "minimax", kind: .minimaxTokenPlan, state: .ok(makeInfo([
            makeModel(name: "general", intervalPercent: 80, weeklyPercent: 60, now: Self.makeNow),
            makeModel(name: "video", intervalPercent: 10, weeklyPercent: 5, now: Self.makeNow),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.80, accuracy: 0.0001,
            "外环只按 general：min(80%, 60%×10 封顶 100) = 80%"
        )
        XCTAssertEqual(
            EdgeDockProjection.rawIntervalFraction(status) ?? -1,
            0.80, accuracy: 0.0001,
            "原始 5h 同样排除 video（video 原始 10% 不参与取最低）"
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyFraction(status, at: Self.makeNow) ?? -1,
            0.60, accuracy: 0.0001,
            "内环只按 general 的周剩余 60%（video 的 5% 不参与）"
        )
        XCTAssertEqual(EdgeDockProjection.intervalHealth(status, at: Self.makeNow), .healthy)
        XCTAssertEqual(EdgeDockProjection.weeklyHealth(status, at: Self.makeNow), .healthy)
        XCTAssertEqual(
            EdgeDockProjection.entries(from: [status], at: Self.makeNow)[0].health, .healthy,
            "health 走 aggregateHealthLevel，同样排除 video"
        )
    }

    /// antigravity 的 Claude and GPT models 组同理：gemini 组独自决定圆环，
    /// claude 组的有效额度 min(5%, 2%×1=2%) 不再把外环拖到底。
    func testProjectionExcludesAntigravityClaudeGroupFromRingAggregation() {
        let status = makeStatus(id: "antigravity", kind: .antigravity, state: .ok(makeInfo([
            makeModel(name: AntigravityModelKind.geminiModels.rawValue, intervalPercent: 90, weeklyPercent: 80, now: Self.makeNow),
            makeModel(name: AntigravityModelKind.geminiArgon.rawValue, intervalPercent: nil, weeklyPercent: 1, now: Self.makeNow),
            makeModel(name: AntigravityModelKind.claudeAndGptModels.rawValue, intervalPercent: 5, weeklyPercent: 2, now: Self.makeNow),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.90, accuracy: 0.0001,
            "外环只按 gemini 组：min(90%, 80%×6 封顶 100) = 90%"
        )
        XCTAssertEqual(
            EdgeDockProjection.rawIntervalFraction(status) ?? -1,
            0.90, accuracy: 0.0001
        )
        XCTAssertEqual(
            EdgeDockProjection.weeklyFraction(status, at: Self.makeNow) ?? -1,
            0.80, accuracy: 0.0001,
            "内环只按 gemini 组的周剩余 80%"
        )
    }

    /// 回退分支：provider 只剩被排除的 model 时回退 `activeModels`——圆环与色档
    /// 仍按 video 判定，不退化为「无读数」。
    func testProjectionFallsBackWhenOnlyExcludedModelRemains() {
        let status = makeStatus(id: "minimax", kind: .minimaxTokenPlan, state: .ok(makeInfo([
            makeModel(name: "video", intervalPercent: 40, now: Self.makeNow),
        ])))
        XCTAssertEqual(
            EdgeDockProjection.intervalFraction(status, at: Self.makeNow) ?? -1,
            0.40, accuracy: 0.0001,
            "只有 video 时回退全集，外环仍画 video 的 40%"
        )
        XCTAssertEqual(EdgeDockProjection.intervalHealth(status, at: Self.makeNow), .healthy, "40% 高于固定 30% 黄线")
        XCTAssertNil(
            EdgeDockProjection.weeklyFraction(status, at: Self.makeNow),
            "回退后的 video 无周窗口，内环仍为 nil"
        )
        XCTAssertEqual(EdgeDockProjection.entries(from: [status], at: Self.makeNow)[0].health, .healthy)
    }

    // MARK: - hover 文案（5h 段双数值）

    /// 周折算不构成瓶颈（有效 == 原始）时维持单数值——没有差额就没有可解释的，
    /// 亮两个一样的数只是噪音。
    func testIntervalCaptionKeepsSingleValueWhenRawEqualsEffective() {
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.60, raw: 0.60),
            "5h 60%"
        )
    }

    /// 有效 < 原始：并排显示，先原始后有效（`5h 90%(30%有效)`）。只亮有效值会让
    /// 人误以为 5h 真的只剩这么多，双数值才说明差额来自周瓶颈。
    func testIntervalCaptionShowsDualValueWhenEffectiveIsLower() {
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.30, raw: 0.90),
            "5h 90%(30%有效)"
        )
    }

    /// raw 缺失时退回单数值（防御分支：正常投影里 5h 段出现时 raw 一定存在）。
    func testIntervalCaptionKeepsSingleValueWithoutRaw() {
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.60, raw: nil),
            "5h 60%"
        )
    }

    /// hover 文案统一遵循 Formatters.formatQuotaPercent：至多一位小数、整数不带 .0。
    func testIntervalCaptionPreservesAtMostOneDecimal() {
        // raw > effective (瓶颈): 原始值 1.0 (100%), 有效值 0.919 (91.9%)
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.919, raw: 1.0),
            "5h 100%(91.9%有效)"
        )
        // raw 缺失或等于 effective: 单数值保持小数
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.919, raw: nil),
            "5h 91.9%"
        )
        XCTAssertEqual(
            EdgeDockProjection.intervalCaption(effective: 0.0471, raw: 0.0471),
            "5h 4.7%"
        )
    }

    /// 升级提示点的朗读措辞：三档逐字钉死。措辞与 `healthText` 的词汇（预警 / 告急）
    /// 必须成对，改一半就会在同一句话里出现两套说法。
    ///
    /// `.healthy` 一档在生产路径上**不可达**——出点的判定保证周档位必然差于 5h 档位，
    /// 而 `.healthy` 是 rank 最大值（最好）。这里仍然断言它，只是为了给
    /// `switch` 的穷尽性分支钉一个值，避免以后有人顺手删掉分支后措辞悄悄消失。
    func testEscalationCaptionWordsTheThreeLevels() {
        XCTAssertEqual(EdgeDockProjection.escalationCaption(.critical), "中心点：周告急")
        XCTAssertEqual(EdgeDockProjection.escalationCaption(.warning), "中心点：周预警")
        XCTAssertEqual(EdgeDockProjection.escalationCaption(.healthy), "中心点：周正常")
    }

    // MARK: - 逐窗口色档（内外环独立取色的输入）

    /// 5h 档位：无周窗口（瓶颈 = 5h 短窗口，`bindingTimeFraction == nil`）时固定
    /// 30% 黄线、固定 15% 红线。三个值分别落在红、黄、绿三段上——任何一个阈值漂了
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

    // MARK: - 周额度升级提示（简版环心圆点）

    /// 真值表：圆点**只在周严格差于 5h 时**出现，颜色 = 周档位。
    ///
    /// 三行 `XCTAssert` 各钉一件事：前置的两档确实是表里写的那档（夹具漂了会先在
    /// 前置断言上炸，而不是让 `weeklyEscalationHealth` 的 nil 变成"碰巧对"）、
    /// 输出等于期望、以及出点时不变量「点永远比环差」。provider 一律用
    /// `codexChatGpt`（周倍率 N=6），所以周折算后总比 5h 松，5h 档位走固定
    /// 30% 黄线——百分比与档位的对应关系一眼可核。
    func testWeeklyEscalationHealthOnlyWhenWeeklyIsWorseThanInterval() {
        // (名字, 5h%, 周%, 剩余时间比例, 5h档, 周档, 期望圆点)
        let cases: [(String, Double, Double, Double, HealthLevel, HealthLevel, HealthLevel?)] = [
            // 周不差于 5h → 无点：同档（黄/黄、红/红、绿/绿）与周更健康都不画。
            ("both_warning", 25, 40, 0.6, .warning, .warning, nil),
            ("both_critical", 10, 10, 0.6, .critical, .critical, nil),
            ("both_healthy", 60, 90, 0.2, .healthy, .healthy, nil),
            // 周更健康（黄/绿）→ 无点。5h 已告急时周只到黄也不算"更差"——
            // 升级提示说的是「瓶颈已经从 5h 挪到周」，瓶颈还在 5h 就不是。
            ("weekly_healthier_warning", 25, 90, 0.2, .warning, .healthy, nil),
            ("weekly_healthier_critical", 10, 40, 0.6, .critical, .warning, nil),
            // 周严格更差 → 有点，颜色 = 周档位。
            ("weekly_worse_warning", 60, 40, 0.6, .healthy, .warning, .warning),
            ("weekly_worse_critical", 25, 10, 0.6, .warning, .critical, .critical),
            ("weekly_worse_critical_from_healthy", 60, 10, 0.6, .healthy, .critical, .critical),
        ]
        for (name, intervalPct, weeklyPct, timeFraction, intervalLevel, weeklyLevel, expected) in cases {
            let status = makeStatus(id: name, state: .ok(makeInfo([
                quotaModel(
                    intervalPercent: intervalPct,
                    weeklyPercent: weeklyPct,
                    weeklyTimeFraction: timeFraction
                ),
            ])))
            let entry = EdgeDockProjection.entries(from: [status], at: Self.makeNow)[0]
            XCTAssertEqual(entry.intervalHealth, intervalLevel, "\(name) 的 5h 档位")
            XCTAssertEqual(entry.weeklyHealth, weeklyLevel, "\(name) 的周档位")
            XCTAssertEqual(entry.weeklyEscalationHealth, expected, "\(name) 的升级提示档位")

            // 不变量：出点时点色必然比环色差（环取 intervalHealth ?? weeklyHealth）。
            if let escalation = entry.weeklyEscalationHealth {
                let ringLevel = entry.intervalHealth ?? entry.weeklyHealth
                XCTAssertNotNil(ringLevel, "\(name) 出点时环色必须存在")
                if let ringLevel {
                    XCTAssertLessThan(escalation, ringLevel, "\(name) 点必须比环差")
                }
            }
        }
    }

    /// 缺任一窗口 → 无点，而且是**语义正确**的 nil，不是"没算出来"：
    /// - 纯周窗口型（无 5h 窗口）：`intervalHealth == nil`，环本身已经是周色，
    ///   再补一个同色圆点等于什么都没说。
    /// - 纯 5h 型（无周窗口）：`weeklyHealth == nil`，没有可升级的周信息。
    /// - 完全没有数据：两个都是 nil。
    func testWeeklyEscalationHealthIsNilWithoutBothWindows() {
        let weeklyOnly = makeStatus(id: "weekly_only", state: .ok(makeInfo([
            weeklyModel(percent: 10, timeFraction: 0.6),
        ])))
        let weeklyOnlyEntry = EdgeDockProjection.entries(from: [weeklyOnly], at: Self.makeNow)[0]
        XCTAssertNil(weeklyOnlyEntry.intervalHealth, "纯周窗口型没有 5h 窗口")
        XCTAssertEqual(weeklyOnlyEntry.weeklyHealth, .critical)
        XCTAssertNil(
            weeklyOnlyEntry.weeklyEscalationHealth,
            "环本身就是周色，不需要再点一个同色的圆心"
        )

        let intervalOnly = makeStatus(id: "interval_only", state: .ok(makeInfo([
            makeModel(name: "g", intervalPercent: 25, now: Self.makeNow),
        ])))
        let intervalOnlyEntry = EdgeDockProjection.entries(from: [intervalOnly], at: Self.makeNow)[0]
        XCTAssertEqual(intervalOnlyEntry.intervalHealth, .warning)
        XCTAssertNil(intervalOnlyEntry.weeklyHealth, "纯 5h 型没有周窗口")
        XCTAssertNil(intervalOnlyEntry.weeklyEscalationHealth, "没有周信息就没有可提示的升级")

        let noData = makeStatus(id: "ready", state: .ready)
        XCTAssertNil(
            EdgeDockProjection.entries(from: [noData], at: Self.makeNow).first?.weeklyEscalationHealth
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
