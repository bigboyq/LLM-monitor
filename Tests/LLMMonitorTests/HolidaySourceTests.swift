import XCTest
import Foundation
@testable import LLM_monitor

/// 节假日数据源（阶段 B）测试：源语义解析、config `holidaySource` 键、
/// 解析链优先级与降级、上游 chinese-days 格式转换、本地文件取数与缓存回写、
/// 设置页状态文案纯函数。
///
/// **全部不依赖网络**：远端取数路径不进测试；`refreshNow` 只用本地文件与
/// bundledOnly 源。`refreshNow` 成功会替换全局 `HolidayCalendar.shared`，
/// 每个触达 global 的用例在 `setUp`/`tearDown` 保存并恢复原表。
final class HolidaySourceTests: XCTestCase {

    private var originalSharedCalendar: HolidayCalendar?

    override func setUp() {
        super.setUp()
        originalSharedCalendar = HolidayCalendar.shared
    }

    override func tearDown() {
        if let originalSharedCalendar {
            HolidayCalendar.applyResolved(originalSharedCalendar)
        }
        super.tearDown()
    }

    private var beijing: Calendar { PeakWindow.beijingCalendar }

    // MARK: - 源语义（parseSource）

    func testParseSourceSemantics() {
        XCTAssertEqual(
            HolidayCalendar.parseSource(HolidayCalendar.defaultSourceURL),
            .remoteURL(HolidayCalendar.defaultSourceURL)
        )
        XCTAssertEqual(
            HolidayCalendar.parseSource("HTTPS://Example.com/days.json"),
            .remoteURL("HTTPS://Example.com/days.json"),
            "scheme 判定不区分大小写，原始串保留给 source 元信息"
        )
        XCTAssertEqual(HolidayCalendar.parseSource(""), .bundledOnly, "显式空串 = 只用内置快照")
        XCTAssertEqual(HolidayCalendar.parseSource("   "), .bundledOnly, "纯空白按空串处理")
        XCTAssertEqual(HolidayCalendar.parseSource("~/days.json"), .localFile("~/days.json"))
        XCTAssertEqual(HolidayCalendar.parseSource("/tmp/days.json"), .localFile("/tmp/days.json"))
        XCTAssertEqual(
            HolidayCalendar.parseSource("ftp://example.com/days.json"),
            .localFile("ftp://example.com/days.json"),
            "非 http(s) 的带 scheme 字符串不按 URL 取数（按本地路径，读文件失败报错）"
        )
    }

    // MARK: - config holidaySource 键

    func testConfigHolidaySourceDefaultsAndExplicitEmpty() throws {
        // 缺省：不落键，生效值 = 上游 chinese-days CDN URL。
        let missing = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}}
        """
        let decodedMissing = try JSONDecoder().decode(AppConfig.self, from: Data(missing.utf8))
        XCTAssertNil(decodedMissing.holidaySource)
        XCTAssertEqual(decodedMissing.effectiveHolidaySource, HolidayCalendar.defaultSourceURL)

        // 显式空串：保留 ""（仅内置快照、不联网），不回退默认。
        let explicitEmpty = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "holidaySource": ""}
        """
        let decodedEmpty = try JSONDecoder().decode(AppConfig.self, from: Data(explicitEmpty.utf8))
        XCTAssertEqual(decodedEmpty.holidaySource, "")
        XCTAssertEqual(decodedEmpty.effectiveHolidaySource, "")

        // 自定义路径原样保留。
        let custom = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "holidaySource": "~/days.json"}
        """
        let decodedCustom = try JSONDecoder().decode(AppConfig.self, from: Data(custom.utf8))
        XCTAssertEqual(decodedCustom.holidaySource, "~/days.json")

        // 类型写错按缺失处理（外观字段同档容错，不进损坏恢复流程）。
        let malformed = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "holidaySource": 42}
        """
        let decodedMalformed = try JSONDecoder().decode(AppConfig.self, from: Data(malformed.utf8))
        XCTAssertNil(decodedMalformed.holidaySource)
        XCTAssertEqual(decodedMalformed.effectiveHolidaySource, HolidayCalendar.defaultSourceURL)
    }

    func testConfigHolidaySourceEncodeOmitsDefaultAndKeepsExplicitEmpty() throws {
        // 缺省（nil）不落键。
        let defaultConfig = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        let defaultData = try JSONEncoder().encode(defaultConfig)
        let defaultDoc = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        XCTAssertNil(defaultDoc?["holidaySource"], "缺省值不应写入 config.json")

        // 显式空串必须落键（它是"仅内置快照"的显式语义，不能被省略吞掉）。
        var bundledOnly = defaultConfig
        bundledOnly.holidaySource = ""
        let emptyData = try JSONEncoder().encode(bundledOnly)
        let emptyDoc = try JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
        XCTAssertEqual(emptyDoc?["holidaySource"] as? String, "")
    }

    /// 回归：GLM peak* 三字段删除后，旧配置里的残留键由 JSONDecoder 静默忽略
    /// （与 DeepSeek 移除峰谷配置时同规矩），不进损坏恢复流程、不改变判定。
    func testLegacyResidualPeakKeysAreSilentlyIgnored() throws {
        let legacy = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {
            "glm_coding_plan": {
              "enabled": true,
              "apiKey": "k",
              "peakStartHour": 9,
              "peakEndHour": 12,
              "peakWeekdaysOnly": false
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.providers["glm_coding_plan"]?.enabled, true)
        XCTAssertEqual(decoded.providers["glm_coding_plan"]?.apiKey, "k")
    }

    // MARK: - 解析链（resolve：缓存 → bundle → empty）

    func testResolvePrefersValidCacheOverBundled() throws {
        let document = HolidayCalendar.CacheDocument(
            source: "~/cache.json",
            fetchedAt: "2026-10-05",
            holidays: ["2026-10-01", "2026-10-02"]
        )
        let data = try JSONEncoder().encode(document)
        let bundled = HolidayCalendar.make(holidays: ["2027-01-01"], source: "bundled", fetchedAt: "2026-10-04")

        let (calendar, usedCache) = HolidayCalendar.resolve(cacheData: data, bundled: { bundled })
        XCTAssertTrue(usedCache)
        XCTAssertEqual(calendar.source, "~/cache.json")
        XCTAssertEqual(calendar.fetchedAt, "2026-10-05")
        XCTAssertTrue(calendar.isHoliday(beijingDate("2026-10-01")))
        XCTAssertFalse(calendar.isHoliday(beijingDate("2027-01-01")), "缓存命中时不得混入 bundle 日期")
    }

    func testResolveFallsBackToBundledWhenCacheCorruptOrEmpty() throws {
        let bundled = HolidayCalendar.make(holidays: ["2026-02-15"], source: "bundled", fetchedAt: "2026-10-04")

        // 损坏 JSON → 回落 bundle
        let (corruptResult, corruptUsed) = HolidayCalendar.resolve(
            cacheData: Data("not-json".utf8), bundled: { bundled }
        )
        XCTAssertFalse(corruptUsed)
        XCTAssertEqual(corruptResult.source, "bundled")

        // holidays 为空数组的缓存不算有效数据 → 回落 bundle
        let emptyDoc = try JSONEncoder().encode(
            HolidayCalendar.CacheDocument(source: "x", fetchedAt: "2026-10-05", holidays: [])
        )
        let (emptyResult, emptyUsed) = HolidayCalendar.resolve(cacheData: emptyDoc, bundled: { bundled })
        XCTAssertFalse(emptyUsed)
        XCTAssertEqual(emptyResult.source, "bundled")

        // 缓存缺失 → bundle
        let (missingResult, missingUsed) = HolidayCalendar.resolve(cacheData: nil, bundled: { bundled })
        XCTAssertFalse(missingUsed)
        XCTAssertEqual(missingResult.source, "bundled")

        // bundle 也缺（注入 .empty）→ 空表退化，不崩
        let (degraded, degradedUsed) = HolidayCalendar.resolve(cacheData: nil, bundled: { .empty })
        XCTAssertFalse(degradedUsed)
        XCTAssertEqual(degraded, .empty)
        XCTAssertFalse(degraded.isLoadedFromResource)
    }

    // MARK: - 数据格式解析（parseSourceDates）

    func testParseSourceDatesAcceptsSnapshotFormat() throws {
        let document = HolidayCalendar.CacheDocument(
            source: "x", fetchedAt: "2026-10-05",
            holidays: ["2026-10-01", "2026-02-16", "2026-10-01"]
        )
        let dates = HolidayCalendar.parseSourceDates(try JSONEncoder().encode(document))
        XCTAssertEqual(dates, ["2026-02-16", "2026-10-01"], "排序去重")
    }

    func testParseSourceDatesTransformsChineseDaysUpstreamFormat() {
        let currentYear = beijing.component(.year, from: Date())
        let upstream = """
        {
          "holidays": {
            "\(currentYear)-10-01": "National Day,国庆节,1",
            "\(currentYear - 2)-05-01": "Old,劳动节,1",
            "\(currentYear)-02-30": "Fake,伪日期,1"
          },
          "workdays": {
            "\(currentYear)-10-10": "Makeup,调休上班,1"
          },
          "inLieuDays": {
            "\(currentYear + 1)-01-02": "InLieu,调休放假日,1"
          }
        }
        """
        let dates = HolidayCalendar.parseSourceDates(Data(upstream.utf8))
        XCTAssertEqual(
            dates,
            ["\(currentYear)-10-01", "\(currentYear + 1)-01-02"],
            "holidays ∪ inLieuDays、workdays 有意丢弃（Rule A）、年份过滤 [当前年-1, …]、伪日期剔除"
        )
    }

    func testParseSourceDatesRejectsNonSnapshotFormats() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:国庆节
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertNil(HolidayCalendar.parseSourceDates(Data(ics.utf8)), "ICS 不解析，交由调用方报格式错误")
        XCTAssertNil(HolidayCalendar.parseSourceDates(Data("<html>404</html>".utf8)))
        XCTAssertNil(HolidayCalendar.parseSourceDates(Data("{}".utf8)))
        // 空 holidays 的快照文档不算有效数据。
        let emptySnapshot = """
        {"source": "x", "fetchedAt": "2026-10-05", "holidays": []}
        """
        XCTAssertNil(HolidayCalendar.parseSourceDates(Data(emptySnapshot.utf8)))
    }

    // MARK: - 新鲜度（isStale）与日期戳

    func testIsStaleWindow() throws {
        let now = try XCTUnwrap(beijing.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9)))
        XCTAssertFalse(HolidayCalendar.isStale(fetchedAt: "2026-10-12", now: now), "当天不判过期")
        XCTAssertFalse(HolidayCalendar.isStale(fetchedAt: "2026-10-05", now: now), "恰好 7 个自然日不判过期")
        XCTAssertTrue(HolidayCalendar.isStale(fetchedAt: "2026-10-04", now: now), "超过 7 天判过期")
        XCTAssertTrue(HolidayCalendar.isStale(fetchedAt: "garbage", now: now), "非法 fetchedAt 视为过期")
        XCTAssertEqual(HolidayCalendar.beijingDateString(on: now), "2026-10-12")
    }

    // MARK: - 服务取数（本地文件 / bundledOnly，不触网）

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testRefreshNowWithLocalSnapshotFileAppliesWritesCacheAndFiresCallback() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("days.json")
        let snapshot = HolidayCalendar.CacheDocument(
            source: "original-source",
            fetchedAt: "2026-01-01",
            holidays: ["2026-10-01", "2026-10-02", "2026-10-03"]
        )
        try JSONEncoder().encode(snapshot).write(to: sourceURL)

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        var appliedCount = 0
        let service = HolidayCalendarService(cacheURL: cacheURL) { appliedCount += 1 }

        let message = await service.refreshNow(source: sourceURL.path)
        XCTAssertTrue(message.hasPrefix("更新成功"), "实际文案：\(message)")
        XCTAssertTrue(service.resolvedFromCache, "取数成功后 shared 来自缓存回写")
        XCTAssertEqual(appliedCount, 1, "应用新表后必须触发一次宿主回调（UI 刷新）")

        // shared 已替换为新表（tearDown 恢复原表）。
        XCTAssertTrue(HolidayCalendar.shared.isHoliday(beijingDate("2026-10-02")))
        XCTAssertEqual(HolidayCalendar.shared.source, sourceURL.path)

        // 缓存文件按快照 schema 落盘：source = 配置源、fetchedAt = 本次取数日。
        let cachedData = try Data(contentsOf: cacheURL)
        let cached = try JSONDecoder().decode(HolidayCalendar.CacheDocument.self, from: cachedData)
        XCTAssertEqual(cached.source, sourceURL.path)
        XCTAssertEqual(cached.fetchedAt, HolidayCalendar.beijingDateString())
        XCTAssertEqual(cached.holidays, ["2026-10-01", "2026-10-02", "2026-10-03"])
    }

    @MainActor
    func testRefreshNowWithInvalidFormatFailsWithoutReplacingExistingTable() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("days.ics")
        try Data("BEGIN:VCALENDAR\nEND:VCALENDAR".utf8).write(to: sourceURL)

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        var appliedCount = 0
        let service = HolidayCalendarService(cacheURL: cacheURL) { appliedCount += 1 }

        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: sourceURL.path)
        XCTAssertTrue(message.contains("仅支持本项目 JSON 快照格式"), "实际文案：\(message)")
        XCTAssertTrue(message.contains("scripts/sync-holiday-data.sh"))
        XCTAssertEqual(appliedCount, 0, "失败不得触发应用回调")
        XCTAssertEqual(HolidayCalendar.shared, before, "失败不清空既有数据")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), "失败不写缓存")
        XCTAssertFalse(service.resolvedFromCache)
    }

    @MainActor
    func testRefreshNowWithMissingFileFailsWithReadableReason() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = HolidayCalendarService(cacheURL: dir.appendingPathComponent("cache.json"))
        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: dir.appendingPathComponent("missing.json").path)
        XCTAssertTrue(message.contains("无法读取文件"), "实际文案：\(message)")
        XCTAssertEqual(HolidayCalendar.shared, before)
    }

    @MainActor
    func testRefreshNowWithBundledOnlySourceNeverTouchesNetworkOrCache() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        var appliedCount = 0
        let service = HolidayCalendarService(cacheURL: cacheURL) { appliedCount += 1 }

        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: "")
        XCTAssertTrue(message.contains("仅使用内置快照"), "实际文案：\(message)")
        XCTAssertEqual(HolidayCalendar.shared, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(appliedCount, 0)
    }

    @MainActor
    func testRefreshNowWithLocalChineseDaysFileTransformsLikeScript() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let currentYear = beijing.component(.year, from: Date())
        let sourceURL = dir.appendingPathComponent("chinese-days.json")
        let upstream = """
        {
          "holidays": {"\(currentYear)-10-01": "National Day,国庆节,1"},
          "workdays": {"\(currentYear)-10-10": "Makeup,调休上班,1"},
          "inLieuDays": {"\(currentYear)-01-02": "InLieu,调休放假日,1"}
        }
        """
        try Data(upstream.utf8).write(to: sourceURL)

        let service = HolidayCalendarService(
            cacheURL: dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        )
        let message = await service.refreshNow(source: sourceURL.path)
        XCTAssertTrue(message.hasPrefix("更新成功"), "实际文案：\(message)")
        // 与 sync-holiday-data.sh 同款转换：inLieu 并入、workdays 丢弃。
        XCTAssertTrue(HolidayCalendar.shared.isHoliday(beijingDate("\(currentYear)-01-02")))
        XCTAssertFalse(HolidayCalendar.shared.isHoliday(beijingDate("\(currentYear)-10-10")))
    }

    // MARK: - 设置页状态文案（纯函数）

    func testStatusLineText() {
        let covered = HolidayCalendar.make(
            holidays: ["2025-10-01", "2026-01-01"],
            source: "x",
            fetchedAt: "2026-10-05"
        )
        XCTAssertEqual(
            HolidayCalendarService.statusLine(for: covered, fromCache: true),
            "2025–2026 · 抓取于 2026-10-05 · 来源：缓存"
        )
        XCTAssertEqual(
            HolidayCalendarService.statusLine(for: covered, fromCache: false),
            "2025–2026 · 抓取于 2026-10-05 · 来源：内置"
        )
        // 单年区间不写 "2026–2026"。
        let singleYear = HolidayCalendar.make(
            holidays: ["2026-01-01"], source: "x", fetchedAt: "2026-10-05"
        )
        XCTAssertTrue(HolidayCalendarService.statusLine(for: singleYear, fromCache: true).hasPrefix("2026 · "))
        // 空表退化形态。
        XCTAssertEqual(
            HolidayCalendarService.statusLine(for: .empty, fromCache: false),
            "未覆盖任何年份 · 无抓取记录 · 来源：内置"
        )
    }

    func testCoverageWarningText() {
        let currentYear = beijing.component(.year, from: Date())
        let covered = HolidayCalendar.make(
            holidays: ["\(currentYear)-10-01"], source: "x", fetchedAt: "2026-10-05"
        )
        XCTAssertNil(
            HolidayCalendarService.coverageWarning(for: covered, currentYear: currentYear),
            "当前年份已覆盖时无提示"
        )
        let warning = HolidayCalendarService.coverageWarning(for: .empty, currentYear: currentYear + 1)
        XCTAssertEqual(
            warning,
            "节假日表未覆盖 \(currentYear + 1)，\(currentYear + 1) 年按纯周一–周五判定"
        )
    }

    // MARK: - 工具

    private func beijingDate(_ iso: String) -> Date {
        beijingDate(iso, calendar: beijing)
    }

    private func beijingDate(_ iso: String, calendar: Calendar) -> Date {
        let parts = iso.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        ))!
    }
}
