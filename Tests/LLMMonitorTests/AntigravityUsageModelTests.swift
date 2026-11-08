import XCTest
import SQLite3
@testable import LLM_monitor

/// `AntigravityLocalUsage` / `AntigravityDailyUsage` 数据模型，以及 scanner 的纯函数
/// 聚合（日桶切分、全局求和、7 天过滤）与 session 存储格式解析。
final class AntigravityUsageModelTests: AntigravityTestCase {

    // MARK: - 测试

    func testAntigravityDailyUsageCacheHitRate() {
        // cacheRead=80, input=20 → 80% hit rate
        let day = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_700_000_000),
            inputTokens: 20,
            cacheReadTokens: 80
        )
        XCTAssertEqual(day.cacheHitRate ?? 0, 0.8, accuracy: 0.000_001)
    }

    func testAntigravityDailyUsageCacheHitRateNilWhenNoInput() {
        let day = AntigravityDailyUsage(dayStart: Date())
        XCTAssertNil(day.cacheHitRate)
    }

    func testAntigravityDailyUsageReasonRate() {
        // reasoning=30, output=70 → 30%
        let day = AntigravityDailyUsage(
            dayStart: Date(),
            outputTokens: 70,
            reasoningTokens: 30
        )
        XCTAssertEqual(day.reasonRate ?? 0, 0.3, accuracy: 0.000_001)
    }

    func testAntigravityDailyUsagePlus() {
        let a = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_000_000),
            inputTokens: 100, outputTokens: 50, totalTokens: 150
        )
        let b = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_000_000),
            inputTokens: 200, outputTokens: 80, reasoningTokens: 10, totalTokens: 290
        )
        let sum = a + b
        XCTAssertEqual(sum.inputTokens, 300)
        XCTAssertEqual(sum.outputTokens, 130)
        XCTAssertEqual(sum.reasoningTokens, 10)
        XCTAssertEqual(sum.totalTokens, 440)
    }

    /// `AntigravityLocalUsage` 自定义 `==` 排除 `scannedAt`：
    /// 业务字段全等 + scannedAt 不同时 == 应当返回 true（让 AppState no-op 检查生效）。
    /// 修前：自动合成 Equatable 因 scannedAt 永远 != 而 false，no-op 形同虚设。
    func testAntigravityLocalUsageEqualityIgnoresScannedAt() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let today = AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)
        let days = [AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)]
        let lhs = AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        let rhs = AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 9_999_999),  // 不同的 scannedAt
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertEqual(lhs, rhs, "业务字段相同 + scannedAt 不同 → == 应当 true (no-op 生效)")
    }

    /// 业务字段不同时 == 必须 false（不能让 no-op 误判命中）。
    func testAntigravityLocalUsageEqualityDetectsBusinessFieldChanges() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let base = AntigravityLocalUsage(
            today: AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150),
            dailyTokenUsage: [AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)],
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        // sessionCount 变 → !=
        let sessionCountChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 6,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, sessionCountChanged)
        // eventCount 变 → !=
        let eventCountChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 51,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, eventCountChanged)
        // dailyTokenUsage 内容变 → !=
        let dayChanged = AntigravityDailyUsage(dayStart: day, inputTokens: 999, outputTokens: 50, totalTokens: 1049)
        let dailyChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: [dayChanged],
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, dailyChanged)
    }

    func testComputeGlobalDailySumsAcrossSessions() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let todayKey = LocalUsageDayKey.make(today, calendar: testCalendar)

        let bySession: [String: [String: AntigravityDailyUsage]] = [
            "s1": [todayKey: AntigravityDailyUsage(dayStart: today, inputTokens: 100, totalTokens: 100)],
            "s2": [todayKey: AntigravityDailyUsage(dayStart: today, inputTokens: 200, outputTokens: 50, totalTokens: 250)],
        ]
        let global = AntigravityLocalUsageScanner.computeGlobalDaily(from: bySession, calendar: testCalendar)
        XCTAssertEqual(global.count, 1)
        XCTAssertEqual(global[0].inputTokens, 300)
        XCTAssertEqual(global[0].outputTokens, 50)
        XCTAssertEqual(global[0].totalTokens, 350)
    }

    func testFilterLast7DaysIncludesToday() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let days = (0..<10).map { offset in
            AntigravityDailyUsage(
                dayStart: testCalendar.date(byAdding: .day, value: -offset, to: today)!,
                totalTokens: offset
            )
        }
        let recent = AntigravityLocalUsageScanner.filterLast7Days(allDaily: days, today: today)
        XCTAssertEqual(recent.count, 7)
        // 应该按日升序；6 天前 total=6，今天 total=0
        XCTAssertEqual(recent.first?.totalTokens, 6)
        XCTAssertEqual(recent.last?.totalTokens, 0)
    }

    func testFilterLast7DaysEmptyWhenNoData() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let recent = AntigravityLocalUsageScanner.filterLast7Days(allDaily: [], today: today)
        XCTAssertTrue(recent.isEmpty)
    }

    func testIsoDayKeyFormat() {
        let date = testCalendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 7, day: 15))!
        let key = LocalUsageDayKey.make(date, calendar: testCalendar)
        XCTAssertEqual(key, "2026-07-15")
    }

    func testDefaultConversationsDirsOnlyContainsAntigravityDir() {
        let dirs = AntigravityLocalUsageScanner.defaultConversationsDirs
        XCTAssertEqual(dirs.count, 1, "antigravity-ide 已剥离，默认只扫一个目录")
        XCTAssertTrue(dirs[0].path.contains(".gemini/antigravity/conversations"),
                      "必须指向 antigravity 数据目录: \(dirs[0].path)")
        XCTAssertFalse(dirs[0].path.contains("antigravity-ide"),
                       "不应再扫描 antigravity-ide: \(dirs[0].path)")
    }

    func testAntigravitySampleModelClassifierMatchesQuotaPools() {
        XCTAssertEqual(
            AntigravityModelKind.pool(forSampleModelName: "gemini-4-argon-trial"),
            .geminiArgon,
            "Argon 应先于通用 Gemini 分类"
        )
        XCTAssertEqual(AntigravityModelKind.pool(forSampleModelName: "gemini-3.8-flash"), .geminiModels)
        for model in ["claude-opus-5.5", "gpt-4.1", "anthropic-sonnet", "openai/gpt-4.1"] {
            XCTAssertEqual(
                AntigravityModelKind.pool(forSampleModelName: model),
                .claudeAndGptModels,
                "\(model) 应归入 Claude and GPT quota pool"
            )
        }
        XCTAssertNil(AntigravityModelKind.pool(forSampleModelName: nil))
        XCTAssertNil(AntigravityModelKind.pool(forSampleModelName: "future-unknown-model"))
        XCTAssertEqual(AntigravityModelKind.geminiArgon.displayName, "Gemini 4 Argon")
    }

    func testAntigravityQuotaModelMatchingKeepsUnknownGeminiFallback() {
        XCTAssertTrue(LocalUsageSummaryBuilder.modelMatches(
            providerKind: .antigravity,
            quotaModelName: AntigravityModelKind.geminiModels.rawValue,
            sampleModelName: nil
        ))
        XCTAssertTrue(LocalUsageSummaryBuilder.modelMatches(
            providerKind: .antigravity,
            quotaModelName: AntigravityModelKind.geminiModels.rawValue,
            sampleModelName: "future-unknown-model"
        ))
        XCTAssertFalse(LocalUsageSummaryBuilder.modelMatches(
            providerKind: .antigravity,
            quotaModelName: AntigravityModelKind.geminiArgon.rawValue,
            sampleModelName: "future-unknown-model"
        ))
    }
}
