import XCTest
import SQLite3
@testable import LLM_monitor

/// 远端配额解析的降级语义（bucket 缺失跳组、全组不可用抛错、分组归一/排序）
/// 与 WAL 指纹、注入日历的 7 天过滤。RPC 解析器（嵌套计数/total 口径）与进程
/// 候选判定已随本地 RPC 数据源退役删除。
final class AntigravitySQLiteRemediationTests: AntigravityTestCase {

    // MARK: - 测试

    func testAnyJSONRejectsNonFiniteAndOutOfRangeIntegers() throws {
        let huge = try JSONDecoder().decode(AnyJSON.self, from: Data("1e100".utf8))
        XCTAssertNil(huge.intValue)
        XCTAssertNil(AnyJSON.number(.infinity).intValue)
        XCTAssertNil(AnyJSON.number(.nan).intValue)
        XCTAssertNil(AnyJSON.number(1.5).intValue)
        XCTAssertEqual(AnyJSON.number(42).intValue, 42)
    }

    func testMissingQuotaBucketHasInactiveStatus() throws {
        let data = Data(
            """
            {
              "groups": [{
                "displayName": "Gemini",
                "buckets": [{
                  "bucketId": "weekly-model",
                  "window": "weekly",
                  "remainingFraction": 0.75
                }]
              }]
            }
            """.utf8
        )
        let model = try XCTUnwrap(AntigravityFetcher.parseQuotaModelsForTest(data).first)
        XCTAssertEqual(model.intervalStatus, .absent)
        XCTAssertEqual(model.weeklyStatus, .present)
        XCTAssertEqual(model.weeklyRemainingPercent, 75)
    }

    func testExhaustedQuotaBucketRemainsPresent() throws {
        let data = Data(
            """
            {
              "groups": [{
                "displayName": "Gemini",
                "buckets": [{
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0
                }]
              }]
            }
            """.utf8
        )
        let model = try XCTUnwrap(AntigravityFetcher.parseQuotaModelsForTest(data).first)
        XCTAssertEqual(model.intervalStatus, .present)
        XCTAssertEqual(model.intervalRemainingPercent, 0)
        XCTAssertTrue(model.hasIntervalWindow)
    }

    /// 全部分量正则命中 → computed（分量和）权威。分量和不重复计数，
    /// 不包含 cacheWrite 簿记量。
    func testQuotaModelsSkipGroupWithMissingFractionButKeepOthers() throws {
        let data = Data(
            """
            {
              "groups": [
                {
                  "displayName": "Gemini",
                  "buckets": [{
                    "bucketId": "weekly-model",
                    "window": "weekly",
                    "remainingFraction": 0.75
                  }]
                },
                {
                  "displayName": "Claude",
                  "buckets": [{
                    "bucketId": "claude-5h",
                    "window": "5h"
                  }]
                }
              ]
            }
            """.utf8
        )
        let models = try AntigravityFetcher.parseQuotaModelsForTest(data)
        XCTAssertEqual(models.count, 1, "缺 remainingFraction 的 group 应被跳过，其余照常产出")
        XCTAssertEqual(models.first?.modelName, "gemini_models")
        XCTAssertEqual(models.first?.weeklyRemainingPercent, 75)
    }

    func testQuotaModelsDistinguishesGeminiArgonAndSortsGroups() throws {
        let data = Data(
            """
            {
              "groups": [
                {
                  "displayName": "Claude and GPT models",
                  "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                  "buckets": [
                    { "bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.63 },
                    { "bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0 }
                  ]
                },
                {
                  "displayName": "Gemini 4 Argon",
                  "description": "For paid Pro plans, Argon quota is separate.",
                  "buckets": [
                    { "bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.85 }
                  ]
                },
                {
                  "displayName": "Gemini Models",
                  "description": "Models within this group: Gemini Flash, Gemini Pro",
                  "buckets": [
                    { "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.90 },
                    { "bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0 }
                  ]
                }
              ]
            }
            """.utf8
        )
        let models = try AntigravityFetcher.parseQuotaModelsForTest(data)
        XCTAssertEqual(models.map(\.modelName), [
            AntigravityModelKind.geminiModels.rawValue,
            AntigravityModelKind.geminiArgon.rawValue,
            AntigravityModelKind.claudeAndGptModels.rawValue
        ])
        XCTAssertEqual(models.map(\.displayName), [
            "Gemini Models",
            "Gemini 4 Argon",
            "Claude and GPT models"
        ])
        XCTAssertEqual(models[1].hasIntervalWindow, false, "Gemini 4 Argon 仅含周窗口")
        XCTAssertEqual(models[1].hasWeeklyWindow, true)
        XCTAssertEqual(models[1].weeklyRemainingPercent, 85, accuracy: 0.001)
    }

    /// M3 的另一面：全部 group 都不可用（都缺 fraction / 都无 bucket）时，
    /// 仍抛 decodingError —— 部分可用语义不等于"静默返回空额度"。
    func testQuotaModelsAllGroupsUnavailableStillThrows() {
        let data = Data(
            """
            {
              "groups": [
                {
                  "displayName": "Gemini",
                  "buckets": [{ "bucketId": "gemini-5h", "window": "5h" }]
                },
                {
                  "displayName": "Claude",
                  "buckets": []
                }
              ]
            }
            """.utf8
        )
        XCTAssertThrowsError(try AntigravityFetcher.parseQuotaModelsForTest(data)) { error in
            guard case QuotaError.decodingError = error else {
                XCTFail("expected .decodingError, got \(error)")
                return
            }
        }
    }

    func testListDBFilesIncludesWALFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-wal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let db = root.appendingPathComponent("session.db")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        try Data(repeating: 1, count: 20).write(to: db)
        try Data(repeating: 2, count: 37).write(to: wal)

        let files = AntigravityLocalUsageScanner.listDBFilesWithStatus(conversationsDirs: [root], fileManager: FileManagerBox()).files
        let info = try XCTUnwrap(files["session"])
        XCTAssertEqual(info.walSizeBytes, 37)
        XCTAssertGreaterThan(info.walMtimeMs, 0)
    }

    func testSevenDayFilterUsesInjectedCalendarTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 29)))
        let usage = AntigravityDailyUsage(dayStart: today, totalTokens: 99)

        let result = AntigravityLocalUsageScanner.filterLast7Days(allDaily: [usage], today: today, calendar: calendar)
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.last?.dayStart, today)
        XCTAssertEqual(result.last?.totalTokens, 99)
    }
}
