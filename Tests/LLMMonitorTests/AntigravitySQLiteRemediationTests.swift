import XCTest
import SQLite3
@testable import LLM_monitor

/// SQLite 读取修复：嵌套表示不重复计数、bucket 状态判定、totalTokens 的 computed /
/// server total 口径，以及 quota 分组缺失时的降级。
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

    func testUsageParserDoesNotDoubleCountNestedRepresentationsAndExcludesCacheWrite() throws {
        let data = Data(
            """
            {
              "inputTokens": 100,
              "outputTokens": 50,
              "cacheReadTokens": 20,
              "cacheWriteTokens": 5,
              "reasoningTokens": 10,
              "totalTokens": 185
            }
            """.utf8
        )
        let json = try JSONDecoder().decode(AnyJSON.self, from: data)
        let event = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(json))

        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheReadTokens, 20)
        XCTAssertEqual(event.cacheWriteTokens, 5)
        XCTAssertEqual(event.reasoningTokens, 10)
        XCTAssertEqual(event.totalTokens, 180, "total 不应重复计数，也不包含 cacheWrite")
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
        XCTAssertEqual(model.healthLevel, .critical)
    }

    /// 全部分量正则命中 → computed（分量和）权威。分量和不重复计数，
    /// 不包含 cacheWrite 簿记量。
    func testUsageEventUsesComputedTotalWhenAllComponentsMatch() throws {
        let mixed = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                {
                  "inputTokens": 100, "outputTokens": 50,
                  "cacheReadTokens": 20, "reasoningTokens": 10,
                  "totalTokens": 185
                }
                """.utf8
            )
        )
        let mixedEvent = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(mixed))
        XCTAssertEqual(mixedEvent.totalTokens, 180, "全部分量命中时取 computed（分量和），而非 server total")
        XCTAssertNil(mixedEvent.missingComponents, "全命中无未命中分量，不携带告警信息")
    }

    /// 部分命中（如 token 字段改名后只剩 cacheRead）→ server total 权威优先，
    /// 不得退化为单分量值（旧 allSatisfy 判据的实质缺陷：丢掉服务端权威
    /// total，日报口径系统性偏低且无日志）。
    func testUsageEventPrefersServerTotalWhenOnlySomeComponentsMatch() throws {
        // 只有 cacheRead 命中，server total 给一个系统性偏高的值
        let cacheReadOnly = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "cacheReadTokens": 300, "totalTokens": 99999 }
                """.utf8
            )
        )
        let event = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(cacheReadOnly))
        XCTAssertEqual(event.cacheReadTokens, 300)
        XCTAssertEqual(event.totalTokens, 99999, "部分命中时必须采用 server 权威 total，而非退化为单分量和")
        XCTAssertEqual(event.missingComponents, ["input", "output", "reasoning"], "未命中分量随事件带回调用方，由 scanner 聚合去重后告警")

        // 双分量命中、server total 也在：同样取 server total
        let inputOutputOnly = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "inputTokens": 10, "outputTokens": 5, "totalTokens": 123 }
                """.utf8
            )
        )
        let partialEvent = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(inputOutputOnly))
        XCTAssertEqual(partialEvent.totalTokens, 123)
        XCTAssertEqual(partialEvent.missingComponents, ["cacheRead", "reasoning"])
    }

    /// 部分命中但 server total 缺失（或字段存在但为 0，视为不可用）→ 退回
    /// computedTotal（尽力而为），事件本身不得被算成 0 而丢弃。
    func testUsageEventFallsBackToComputedTotalWhenServerTotalMissingOnPartialMatch() throws {
        // server total 字段缺失
        let noServerTotal = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "cacheReadTokens": 300 }
                """.utf8
            )
        )
        let event = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(noServerTotal))
        XCTAssertEqual(event.totalTokens, 300, "server total 缺失时退回 computed")
        XCTAssertNil(event.missingComponents, "回退 computed 路径沿用旧语义：仅在采用 server 权威 total 时标记未命中分量")

        // server total 为 0（字段存在但与命中的分量矛盾）→ 同样退回 computed
        let zeroServerTotal = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "inputTokens": 100, "totalTokens": 0 }
                """.utf8
            )
        )
        let zeroEvent = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(zeroServerTotal))
        XCTAssertEqual(zeroEvent.totalTokens, 100, "server total 为 0 视为不可用，退回 computed")
    }

    /// 全部分量未命中 → server total（原语义）；server 也没有 → computedTotal
    /// （= 0，事件由丢弃 guard 收掉）。
    func testUsageEventFallsBackToServerTotalWhenNoComponentMatched() throws {
        let noComponents = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "totalTokens": 512 }
                """.utf8
            )
        )
        let event = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(noComponents))
        XCTAssertEqual(event.totalTokens, 512, "分量全未命中时回退 server total")
        XCTAssertNil(event.missingComponents, "全未命中沿用原语义，不携带部分命中告警信息")

        // 分量全未命中且 server total 也为 0：事件完全无 token 数据，应被丢弃
        let allZero = try JSONDecoder().decode(
            AnyJSON.self,
            from: Data(
                """
                { "totalTokens": 0 }
                """.utf8
            )
        )
        XCTAssertNil(AntigravityFetcher.parseUsageEventForTest(allZero))
    }

    /// M3 回归网：某个 group 的 bucket 缺 `remainingFraction` 时，只跳过该
    /// group 并继续产出其余 group（对齐 postOptional 的部分可用语义），
    /// 不再让整次 Antigravity 额度刷新 throw。
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

    func testIDEWithoutCSRFIsNotAUsableServerCandidate() {
        let tokenlessIDE = AntigravityFetcher.ProcessMatch(pid: 10, command: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity", kind: .ide)
        let authenticatedIDE = AntigravityFetcher.ProcessMatch(pid: 11, command: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token test-token", kind: .ide)
        let cli = AntigravityFetcher.ProcessMatch(pid: 12, command: "/usr/local/bin/agy", kind: .cli)
        XCTAssertFalse(AntigravityFetcher.isUsableProcessCandidate(tokenlessIDE))
        XCTAssertTrue(AntigravityFetcher.isUsableProcessCandidate(authenticatedIDE))
        XCTAssertTrue(AntigravityFetcher.isUsableProcessCandidate(cli))
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
