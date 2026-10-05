import XCTest
import Foundation
@testable import LLM_monitor

/// provider 卡片派生值 memo（`ProviderCardDerivedValues` + `LocalUsagePriceByDay`）
/// 的守门测试。
///
/// 钉的是两件事，缺一不可：
/// 1. **输入没变就不重算**——展示时钟每秒 tick 一次，投影 / 窗口快照 / 「今」行 /
///    7 天金额都是 O(samples) 的迭代（DSH 的 `recentSamples` 上限 65536），
///    不挡住 tick 就等于每秒重跑一遍万级迭代 + 逐条日历判定。
/// 2. **输入一变必重算**——漏一次失效不会崩、不会报错，只会静默显示过期数字。
///    覆盖 usage 变化与节假日表变化两档，外加两个"时间桶"边界。
///
/// 数值口径另有 `testMemoizedValueMatchesFreshCompute`，把命中值与现算值逐字比。
final class ProviderCardDerivedMemoTests: XCTestCase {

    // MARK: - fixture

    /// 固定样本时刻：北京时间 2026-09-16（周三）10:00，落在 DeepSeek 高峰时段
    /// 9–12 内。选固定值而不是 `Date()`，节假日翻倍率的两档才可复现。
    private func beijingPeakInstant() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 16
        components.hour = 10
        components.minute = 0
        return PeakWindow.beijingCalendar.date(from: components)!
    }

    private func sample(
        _ promptID: String,
        at completedAt: Date,
        model: String = "deepseek-v4-flash",
        input: Int = 1_000_000,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: completedAt,
            modelName: model,
            promptID: promptID,
            inputTokens: input + cacheRead,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: "dsh:deepseek-official"
        )
    }

    /// 一张 DeepSeek 卡，DSH 共享账本按 `deepseek-official` 路由（默认绑定已开）。
    private func makeStatus(
        samples: [LocalTokenUsageSample],
        day: Date,
        scannedAt: Date,
        kind: ProviderKind = .deepseek
    ) -> ProviderStatus {
        let daily = DshDailyUsage(
            dayStart: day,
            inputTokens: samples.reduce(0) { $0 + $1.inputTokens },
            outputTokens: samples.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: samples.reduce(0) { $0 + $1.cachedInputTokens },
            cacheWriteTokens: 0,
            reasoningTokens: samples.reduce(0) { $0 + $1.reasoningOutputTokens },
            totalTokens: samples.reduce(0) { $0 + $1.inputTokens + $1.outputTokens },
            turns: samples.count,
            rounds: samples.count
        )
        let usage = DshLocalUsage(
            byProvider: [
                "deepseek-official": DshProviderUsage(
                    today: daily,
                    dailyTokenUsage: [daily],
                    sessionCount: 1,
                    roundCount: samples.count,
                    recentSamples: samples
                )
            ],
            modelsByProvider: [:],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 1,
            eventCount: samples.count,
            scannedAt: scannedAt
        )
        var status = ProviderStatus(
            id: kind.providerID,
            displayName: "DeepSeek",
            kind: kind,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: scannedAt,
                balanceDetail: nil
            ))
        )
        status.dshUsage = usage
        return status
    }

    override func setUp() {
        super.setUp()
        ProviderCardDerivedValues.reset()
        LocalUsagePriceByDay.reset()
        // 空表 = 纯"周一–周五"口径：下面的倍率两档不受打包快照内容影响。
        HolidayCalendar.applyResolved(.empty)
    }

    override func tearDown() {
        ProviderCardDerivedValues.reset()
        LocalUsagePriceByDay.reset()
        HolidayCalendar.applyResolved(HolidayCalendar.loadBundled())
        super.tearDown()
    }

    // MARK: - 输入不变 → 不重算

    /// 同一张卡、展示时钟走了 12 小时（12 次 tick）、墙钟也走了 12 小时：
    /// 键的自然日桶都没变 → 一次都不该重算。
    func testTicksWithinOneDayDoNotRecompute() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let status = makeStatus(samples: [sample("turn-1", at: now)], day: day, scannedAt: now)

        let first = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)
        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 1)

        for tick in 1...12 {
            let displayDate = now.addingTimeInterval(TimeInterval(tick))
            _ = ProviderCardDerivedValues.resolve(
                status: status,
                displayDate: displayDate,
                now: displayDate
            )
        }
        XCTAssertEqual(
            ProviderCardDerivedValues.computeCount, 1,
            "只有展示时钟在动、底层数据一字未变时不得重算投影 / 快照 / 今行"
        )

        // 命中的值与现算值逐字相同（含金额与四桶）。
        let fresh = ProviderCardDerivedValues.make(
            status: status,
            displayDate: now.addingTimeInterval(12),
            now: now.addingTimeInterval(12)
        )
        XCTAssertEqual(first.projection, fresh.projection)
        XCTAssertEqual(first.windowUsageSnapshot, fresh.windowUsageSnapshot)
        XCTAssertEqual(first.todayUsageRow, fresh.todayUsageRow)
        XCTAssertEqual(first.todayUsageRow?.cost, fresh.todayUsageRow?.cost)
    }

    /// 7 天金额文案（卡片段3）同理：tick 不重算，命中值 == 现算值。
    func testPriceByDayTicksDoNotRecompute() {
        let day = PeakWindow.beijingCalendar.startOfDay(for: beijingPeakInstant())
        let samples = [sample("turn-1", at: beijingPeakInstant())]

        let first = LocalUsagePriceByDay.values(
            dayStarts: [day],
            recentSamples: samples,
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)
        for tick in 1...10 {
            _ = LocalUsagePriceByDay.values(
                dayStarts: [day],
                recentSamples: samples,
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: .deepseekDefault
            )
            XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1, "第 \(tick) 次 tick 不该重算")
        }
        XCTAssertEqual(
            first,
            LocalUsagePriceByDay.compute(
                dayStarts: [day],
                recentSamples: samples,
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: .deepseekDefault
            )
        )
    }

    // MARK: - 输入变化 → 必重算

    /// 本地用量变化（多一条样本）必须重算，且「今」行的金额跟着变。
    func testUsageChangeForcesRecomputeAndChangesValue() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let base = makeStatus(samples: [sample("turn-1", at: now)], day: day, scannedAt: now)

        let before = ProviderCardDerivedValues.resolve(status: base, displayDate: now, now: now)
        let beforeCost = try! XCTUnwrap(before.todayUsageRow?.cost)
        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 1)

        let grown = makeStatus(
            samples: [
                sample("turn-1", at: now),
                sample("turn-2", at: now.addingTimeInterval(1), input: 2_000_000)
            ],
            day: day,
            scannedAt: now
        )
        let after = ProviderCardDerivedValues.resolve(status: grown, displayDate: now, now: now)

        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 2, "usage 变化必须重算")
        let afterCost = try! XCTUnwrap(after.todayUsageRow?.cost)
        XCTAssertNotEqual(afterCost, beforeCost, "重算后的今行金额必须跟着新数据变")
        XCTAssertGreaterThan(try! XCTUnwrap(afterCost.value), try! XCTUnwrap(beforeCost.value))
        XCTAssertNotEqual(after.projection.recentSamples.count, before.projection.recentSamples.count)
    }

    /// 节假日表在运行期被换掉（解析链的 `applyResolved`）必须重算：DeepSeek 峰谷
    /// 判定吃 `HolidayCalendar.shared`（Rule A 的"周一–周五 ∧ 非法定节假日"）。
    func testHolidayTableChangeForcesRecompute() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let status = makeStatus(samples: [sample("turn-1", at: now)], day: day, scannedAt: now)

        let before = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)
        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 1)

        let today = HolidayCalendar.beijingDateString(on: now)
        HolidayCalendar.applyResolved(
            HolidayCalendar.make(holidays: [today], source: "memo-test", fetchedAt: today)
        )
        let after = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)

        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 2, "节假日表换版本必须重算")
        // 换了表之后命中的值必须等于**新表**下的现算值。
        XCTAssertEqual(after, ProviderCardDerivedValues.make(status: status, displayDate: now, now: now))
        // 换表不动本卡任何输入（status 一字未改），所以投影本身仍逐字相同；
        // 「同一条高峰样本 ×2 → ×1」的数值断言在下面的
        // `testHolidayTableChangeAltersPriceText`（固定时刻，两档可控）。
        XCTAssertEqual(before.projection, after.projection)
    }

    /// 节假日表换版对**金额**的可见影响：同一条高峰样本，工作日 ×2、同一天被标成
    /// 法定节假日后 ×1，金额文案随之改变。
    func testHolidayTableChangeAltersPriceText() {
        let instant = beijingPeakInstant()
        let day = PeakWindow.beijingCalendar.startOfDay(for: instant)
        let samples = [sample("turn-1", at: instant)]
        // 前提自检：样本必须落在"工作日 + 高峰时段"，两档倍率才真的分得开。
        XCTAssertEqual(
            PeakWindow.beijingCalendar.component(.weekday, from: instant), 4,
            "2026-09-16 必须是周三（Rule A 的工作日口径）"
        )
        XCTAssertEqual(
            DeepseekPeakWindow.deepseekDefault.status(
                at: instant,
                calendar: PeakWindow.beijingCalendar,
                holidays: .empty
            ),
            .peak(until: PeakWindow.beijingCalendar.date(from: {
                var c = DateComponents()
                c.year = 2026; c.month = 9; c.day = 16; c.hour = 12
                return c
            }())!),
            "10:00 必须落在 DeepSeek 高峰时段 9–12 内"
        )

        let weekday = try! XCTUnwrap(LocalUsagePriceByDay.values(
            dayStarts: [day],
            recentSamples: samples,
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )[day])
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)

        let iso = HolidayCalendar.beijingDateString(on: instant)
        HolidayCalendar.applyResolved(HolidayCalendar.make(holidays: [iso]))
        let holiday = try! XCTUnwrap(LocalUsagePriceByDay.values(
            dayStarts: [day],
            recentSamples: samples,
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )[day])

        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 2, "节假日表换版本必须重算")
        // 1M uncached input × ¥1/M：工作日高峰 ×2 → ¥2.00；同一天被标成法定假日
        // 后不算高峰（Rule A）→ ×1 → ¥1.00。
        XCTAssertEqual(weekday, "¥2.00")
        XCTAssertEqual(holiday, "¥1.00")
        XCTAssertNotEqual(weekday, holiday, "同一条样本：工作日 ×2、法定节假日 ×1，文案必须变")
    }

    /// 样本集合变化（内容变、条数不变）同样必须失效——只比条数是不够的。
    func testSampleContentChangeForcesPriceByDayRecompute() {
        let instant = beijingPeakInstant()
        let day = PeakWindow.beijingCalendar.startOfDay(for: instant)
        let one = sample("turn-1", at: instant, input: 1_000_000)
        let two = sample("turn-2", at: instant, input: 3_000_000)

        let before = try! XCTUnwrap(LocalUsagePriceByDay.values(
            dayStarts: [day],
            recentSamples: [one],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )[day])
        let after = try! XCTUnwrap(LocalUsagePriceByDay.values(
            dayStarts: [day],
            recentSamples: [two],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )[day])

        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 2)
        XCTAssertNotEqual(before, after)
    }

    /// 展示时钟跨自然日：今行的"今天"变了，必须重算（且当天无数据时整行消失）。
    func testDisplayDayRolloverForcesRecompute() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let status = makeStatus(samples: [sample("turn-1", at: now)], day: day, scannedAt: now)

        let today = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)
        XCTAssertNotNil(today.todayUsageRow)

        let tomorrow = day.addingTimeInterval(24 * 60 * 60)
        let nextDay = ProviderCardDerivedValues.resolve(status: status, displayDate: tomorrow, now: now)

        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 2, "跨自然日必须重算今行")
        XCTAssertNil(nextDay.todayUsageRow, "明天没有本地数据时今行整行不画")
    }

    /// 墙钟跨自然日：投影里的当日 max 修补变了，必须重算。
    func testWallClockDayRolloverForcesRecompute() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let status = makeStatus(samples: [sample("turn-1", at: now)], day: day, scannedAt: now)

        _ = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)
        _ = ProviderCardDerivedValues.resolve(
            status: status,
            displayDate: now,
            now: day.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 2, "墙钟跨自然日必须重算投影")
    }

    /// 缓存有界：槽位按 provider id 分，条目数 = 卡片数，不随 tick 数增长。
    func testMemoIsBoundedByProvider() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        for tick in 0..<5 {
            for kind in ProviderKind.allCases {
                let status = makeStatus(
                    samples: [sample("turn-\(tick)", at: now)],
                    day: day,
                    scannedAt: now,
                    kind: kind
                )
                _ = ProviderCardDerivedValues.resolve(
                    status: status,
                    displayDate: now.addingTimeInterval(TimeInterval(tick)),
                    now: now
                )
            }
        }
        XCTAssertEqual(
            ProviderCardDerivedValues.slotCount, ProviderKind.allCases.count,
            "槽位数应等于 provider 数，不随渲染轮次增长"
        )
    }

    // MARK: - 数值逐字不变

    /// memo 命中的值与现算值逐字相同（投影 / 窗口快照 / 今行三个字段各自比），
    /// 且第二次读取确实来自缓存（computeCount 不变）。
    func testMemoizedValueMatchesFreshCompute() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let status = makeStatus(
            samples: [
                sample("turn-1", at: now, input: 1_000_000, cacheRead: 200_000, output: 50_000, reasoning: 20_000),
                sample("turn-2", at: now.addingTimeInterval(30), input: 500_000, output: 10_000)
            ],
            day: day,
            scannedAt: now
        )

        let memoized = ProviderCardDerivedValues.resolve(status: status, displayDate: now, now: now)
        let cached = ProviderCardDerivedValues.resolve(
            status: status,
            displayDate: now.addingTimeInterval(1),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(ProviderCardDerivedValues.computeCount, 1)
        XCTAssertEqual(memoized, cached, "命中必须原样返回同一个值")

        let fresh = ProviderCardDerivedValues.make(
            status: status,
            displayDate: now.addingTimeInterval(1),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(cached.projection, fresh.projection)
        XCTAssertEqual(cached.projection.contributions.count, fresh.projection.contributions.count)
        XCTAssertEqual(cached.windowUsageSnapshot, fresh.windowUsageSnapshot)
        XCTAssertEqual(cached.todayUsageRow, fresh.todayUsageRow)
        XCTAssertEqual(cached.todayUsageRow?.metrics, fresh.todayUsageRow?.metrics)
        XCTAssertEqual(cached.todayUsageRow?.cost?.value, fresh.todayUsageRow?.cost?.value)
        XCTAssertEqual(cached.todayUsageRow?.cost?.displayText, fresh.todayUsageRow?.cost?.displayText)
    }
}
