import XCTest
@testable import LLM_monitor

/// 菜单「今日汇总」的计算缓存（`HarnessSummaryCache`）。
///
/// 缓存要解决的是一个不产生错误、只产生浪费的问题：菜单开着时
/// `MenuDisplayClock` 每秒 tick 一次，每次都让 `MenuContentView` 的 body 重 eval，
/// 而 body 里原本直接全量重算 `HarnessTodaySummary.summarize`（含每行定价）。
/// 所以断言也分两类：**该重算时重算了**（失效口径不能漏）与**不该重算时没重算**
/// （`computeCount` 不许涨）。
@MainActor
final class HarnessSummaryCacheTests: XCTestCase {

    private let calendar = Calendar.current
    /// 固定在今天 12:00：样本的"今天"判定不随跑测试的时刻漂移。
    private var now: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }
    private var today: Date { calendar.startOfDay(for: now) }

    // MARK: - 失效

    /// 广播到达后必须读到新值。这是缓存最容易出错的方向：宁可不缓存，
    /// 也不能拿一份过期的"今天合计"糊在菜单上。
    func testValueIsRecomputedAfterInvalidate() {
        let cache = HarnessSummaryCache()
        let first = codexStatus(totalTokens: 1_000)
        XCTAssertEqual(
            cache.value(for: [first], now: now, calendar: calendar).totalTokens, 1_000,
            "前提不成立：首次读必须已经算过一次"
        )
        let afterFirstRead = cache.computeCount

        // 模拟 provider 刷回新用量：`statusDidChange` 到达 → 标脏 → 下次读重算。
        cache.invalidate()
        let updated = codexStatus(totalTokens: 4_200)
        let summary = cache.value(for: [updated], now: now, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 4_200, "广播后必须读到新数据，不能是上一次的值")
        XCTAssertEqual(cache.computeCount, afterFirstRead + 1, "标脏后只该多算这一次")
    }

    /// 标脏不立刻算：数据变了但 body 未必重 eval，提前算就是没人读的浪费。
    func testInvalidateOnlyMarksStaleWithoutRecomputing() {
        let cache = HarnessSummaryCache()
        _ = cache.value(for: [codexStatus(totalTokens: 1_000)], now: now, calendar: calendar)
        let before = cache.computeCount

        cache.invalidate()

        XCTAssertEqual(cache.computeCount, before, "invalidate 只标脏，真正的计算推迟到读")
    }

    /// 跨天是唯一不经广播的失效源：`dayStart` 变了意味着"今天"这个口径本身
    /// 换了，而它不来自任何一次状态变更。不接这一条，菜单跨过零点后
    /// 会一直显示昨天那一份合计。
    func testDayRolloverRecomputesWithoutAnyInvalidate() {
        let cache = HarnessSummaryCache()
        _ = cache.value(for: [codexStatus(totalTokens: 1_000)], now: now, calendar: calendar)
        let before = cache.computeCount

        // 数据一个字节没变、也没人调 invalidate，只把墙钟推到第二天 12:00。
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let summary = cache.value(for: [codexStatus(totalTokens: 1_000)], now: tomorrow, calendar: calendar)

        XCTAssertEqual(summary.dayStart, calendar.startOfDay(for: tomorrow), "跨天后口径必须换到新的一天")
        XCTAssertEqual(cache.computeCount, before + 1, "跨天必须重算一次")
    }

    // MARK: - 不该重算

    /// 时钟 tick 本身不改变任何输入，因此一秒一次的重算必须变成"读缓存"。
    /// 这是这个缓存存在的全部理由，用连续多次读把它钉死。
    func testRepeatedReadsWithoutInvalidateDoNotRecompute() {
        let cache = HarnessSummaryCache()
        let statuses = [codexStatus(totalTokens: 1_000)]
        let first = cache.value(for: statuses, now: now, calendar: calendar)
        let afterFirstRead = cache.computeCount

        for tick in 1...10 {
            // 每次 tick 的墙钟都往前一秒，模拟 MenuDisplayClock。
            let ticked = cache.value(
                for: statuses,
                now: now.addingTimeInterval(Double(tick)),
                calendar: calendar
            )
            XCTAssertEqual(ticked, first, "第 \(tick) 次 tick 读到的必须是同一份汇总")
        }

        XCTAssertEqual(
            cache.computeCount, afterFirstRead,
            "10 次时钟 tick 不得触发任何一次重算——缓存失效了的话这里会涨 10"
        )
    }

    /// 种子里那份空汇总不是"没数据"，而是没有 provider 时的正常呈现；
    /// 第一次读就会被真实数据替换掉。
    func testFirstReadReplacesTheEmptySeed() {
        let cache = HarnessSummaryCache()
        XCTAssertTrue(cache.summary.sections.isEmpty, "种子应是空汇总")

        let summary = cache.value(for: [codexStatus(totalTokens: 1_000)], now: now, calendar: calendar)

        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertFalse(cache.summary.sections.isEmpty)
    }

    // MARK: - fixtures

    /// 一个最小可用的 ChatGPT / Codex 卡：`codexUsageDetails.recentSamples` 走
    /// 原生贡献（与 `HarnessTodaySummaryTests` 同一路径，不另造一套投影）。
    private func codexStatus(totalTokens: Int) -> ProviderStatus {
        let sample = LocalTokenUsageSample(
            completedAt: now,
            modelName: "gpt-5.5",
            promptID: "p1",
            inputTokens: totalTokens,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                lastPrompt: nil,
                dailyTokenUsage: [DailyTokenUsage(
                    dayStart: today,
                    inputTokens: totalTokens,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0
                )],
                recentSamples: [sample],
                scannedAt: now
            ),
            fetchedAt: now
        )
        return ProviderStatus(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .ok(info)
        )
    }
}
