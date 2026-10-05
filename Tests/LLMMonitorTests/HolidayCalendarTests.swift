import XCTest
import Foundation
@testable import LLM_monitor

/// 法定节假日快照（`HolidayCalendar` + `Resources/ChinaHolidays.json`）守门测试。
///
/// 两层护栏：
/// 1. **资源护栏** —— 独立本地解码直接校验随 app 打包的 JSON（与 app 内解码模型
///    解耦，风格同 `ModelPricingJSONTests`）：年份连续且含当前年、日期为真日期且
///    排序去重、source / fetchedAt 非空；
/// 2. **Rule A 定点断言** —— 用真实资源内容钉住代表性日期：春节 / 国庆在列、
///    inLieuDays 的调休放假日（周五）**在列**、workdays 的调休上班日（周日）
///    **不在列**（Rule A 的显式证据）、普通周三不在列。
/// 退化行为（资源缺失 → 空表）用注入实例断言，不动真资源。
final class HolidayCalendarTests: XCTestCase {

    // MARK: - 独立解码模型（与 app 内私有 Decodable 结构解耦，避免同义反复）

    private struct ResourceProbe: Decodable {
        let source: String
        let fetchedAt: String
        let holidays: [String]
    }

    /// 测试 target 没有自己的 resource bundle accessor：这里的 Bundle.module
    /// 经 @testable import LLM_monitor 解析到 app target 生成的 accessor
    /// （同 `ModelPricingJSONTests` 的说明），校验的是 Package.swift 的
    /// resources 声明真实打包了 ChinaHolidays.json。
    private func loadResourceJSON() throws -> ResourceProbe {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ChinaHolidays", withExtension: "json"),
            "ChinaHolidays.json 必须随 app target 打包（由 scripts/sync-holiday-data.sh 生成）"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ResourceProbe.self, from: data)
    }

    private var beijing: Calendar { PeakWindow.beijingCalendar }

    private func beijingDate(_ iso: String, hour: Int = 0, minute: Int = 0) -> Date {
        let parts = iso.split(separator: "-").map { Int($0)! }
        return beijing.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute
        ))!
    }

    // MARK: - 资源护栏（真实打包资源）

    func testResourceIsBundledAndParsable() throws {
        let doc = try loadResourceJSON()
        XCTAssertFalse(doc.holidays.isEmpty, "快照不应为空（上游每年都有法定假日）")
    }

    /// 跨年快照护栏：覆盖 [当前年-1, 当前年]（脚本保留策略），且年份连续。
    /// 「含当前年」是有意的年检：跨年后（如 2027-01-01）旧快照未覆盖新一年时
    /// 本用例变红，强制重跑 scripts/sync-holiday-data.sh 做年度同步。
    func testResourceYearsAreContinuousAndIncludeCurrentYear() throws {
        let doc = try loadResourceJSON()
        let years = Set(doc.holidays.map { Int($0.prefix(4))! }).sorted()
        XCTAssertEqual(years, Array(years.min()! ... years.max()!), "快照年份必须连续（min…max 无断档）")

        let currentYear = beijing.component(.year, from: Date())
        XCTAssertTrue(years.contains(currentYear), "快照必须覆盖当前年 \(currentYear)（否则请重跑 scripts/sync-holiday-data.sh）")
        XCTAssertGreaterThanOrEqual(years.min()!, currentYear - 1, "只保留 [当前年-1, …]，历史年份不应混入")
    }

    /// 日期格式护栏：排序 + 去重 + 全部是真日期（YYYY-MM-DD，Calendar round-trip
    /// 拒绝 2026-02-30 这类归一化伪日期）。真日期校验是脚本护栏的跨平台终审。
    func testResourceDatesAreValidUniqueAndSorted() throws {
        let doc = try loadResourceJSON()
        XCTAssertEqual(doc.holidays, doc.holidays.sorted(), "holidays 数组必须按字典序排序")
        XCTAssertEqual(Set(doc.holidays).count, doc.holidays.count, "holidays 数组必须去重")
        for date in doc.holidays {
            XCTAssertNotNil(
                HolidayCalendar.dateKey(fromISODateString: date, calendar: beijing),
                "非法日期混入快照: \(date)"
            )
        }
    }

    func testResourceMetadataIsPresent() throws {
        let doc = try loadResourceJSON()
        XCTAssertFalse(doc.source.isEmpty, "source（上游 URL）必须非空")
        XCTAssertFalse(doc.fetchedAt.isEmpty, "fetchedAt 必须非空")
        XCTAssertNotNil(HolidayCalendar.dateKey(fromISODateString: doc.fetchedAt, calendar: beijing),
                        "fetchedAt 必须是 YYYY-MM-DD 真日期: \(doc.fetchedAt)")
    }

    // MARK: - shared 单例（bundle 资源加载）

    func testSharedLoadsFromBundledResource() {
        XCTAssertTrue(HolidayCalendar.shared.isLoadedFromResource,
                      "shared 必须从打包资源加载；退化为空表说明资源缺失或解析失败")
        XCTAssertNotNil(HolidayCalendar.shared.source)
        XCTAssertNotNil(HolidayCalendar.shared.fetchedAt)
        XCTAssertTrue(HolidayCalendar.shared.covers(year: beijing.component(.year, from: Date())))
    }

    // MARK: - Rule A 定点断言（真实资源内容）

    /// 春节（2026-02-15 起）与国庆（2026-10-01）必须在列。
    func testSpringFestivalAndNationalDayAreHolidays() throws {
        let doc = try loadResourceJSON()
        let calendar = HolidayCalendar.make(holidays: doc.holidays)
        XCTAssertTrue(calendar.isHoliday(beijingDate("2026-02-15")), "春节首日必须在列")
        XCTAssertTrue(calendar.isHoliday(beijingDate("2026-10-01")), "国庆首日必须在列")
    }

    /// Rule A 显式证据：
    /// - `2026-01-02`（周五，上游 inLieuDays 调休放假日）**在列** —— 调休放掉的
    ///   周一–周五必须排除；
    /// - `2026-01-04`（周日，上游 workdays 调休上班日）**不在列** —— 调休上班的
    ///   周末本来就不是周一–周五，Rule A 下天然不算高峰（有意不建模 workdays）。
    func testInLieuFridayIsHolidayAndMakeupSundayIsNot() throws {
        let doc = try loadResourceJSON()
        let calendar = HolidayCalendar.make(holidays: doc.holidays)
        XCTAssertTrue(calendar.isHoliday(beijingDate("2026-01-02")),
                      "inLieuDays 的调休放假日（周五）必须并入非高峰集合")
        XCTAssertFalse(calendar.isHoliday(beijingDate("2026-01-04")),
                       "workdays 的调休上班日（周日）不建模：Rule A 下不算高峰")
    }

    /// 普通周三（国庆假期之后）不在列。
    func testOrdinaryWednesdayIsNotHoliday() throws {
        let doc = try loadResourceJSON()
        let calendar = HolidayCalendar.make(holidays: doc.holidays)
        XCTAssertFalse(calendar.isHoliday(beijingDate("2026-10-14")))
    }

    // MARK: - 退化与构造语义（注入实例，不动真资源）

    /// 空表退化：纯周一–周五口径，`isLoadedFromResource == false`，
    /// 不抛错、不崩（isHoliday 恒 false、coveredYears 为 nil）。
    func testEmptyCalendarDegradation() {
        let empty = HolidayCalendar.empty
        XCTAssertFalse(empty.isLoadedFromResource)
        XCTAssertNil(empty.source)
        XCTAssertNil(empty.fetchedAt)
        XCTAssertNil(empty.coveredYears)
        XCTAssertFalse(empty.covers(year: 2026))
        XCTAssertFalse(empty.isHoliday(beijingDate("2026-02-15")))
        XCTAssertFalse(empty.isHoliday(beijingDate("2026-10-01")))
    }

    /// `make` 构造语义：合法日期进集合（isHoliday 用给定 calendar 提取键）；
    /// 非法日期（伪日期 / 变体格式）静默跳过；正常构造的表 `isLoadedFromResource == true`
    /// （区别于资源缺失退化的 empty）。
    func testMakeSkipsInvalidDatesAndFlagsLoadedResource() {
        let calendar = HolidayCalendar.make(
            holidays: ["2026-02-15", "2026-02-30", "2026-2-5", "2026-13-01"],
            source: "fixture",
            fetchedAt: "2026-10-05"
        )
        XCTAssertTrue(calendar.isLoadedFromResource)
        XCTAssertTrue(calendar.isHoliday(beijingDate("2026-02-15")))
        XCTAssertFalse(calendar.isHoliday(beijingDate("2026-03-02")),
                       "2026-02-30 被 Calendar 归一化成的 3 月 2 日不得进表")
        XCTAssertEqual(calendar.coveredYears, 2026...2026)
        XCTAssertTrue(calendar.covers(year: 2026))
        XCTAssertFalse(calendar.covers(year: 2025))
    }

    /// "YYYY-MM-DD" → yyyyMMdd 键的严格性：必须是真日期（round-trip 校验），
    /// 紧凑/变体写法与垃圾输入一律拒绝。
    func testDateKeyValidation() {
        XCTAssertEqual(HolidayCalendar.dateKey(fromISODateString: "2026-02-15", calendar: beijing), 20260215)
        XCTAssertEqual(HolidayCalendar.dateKey(fromISODateString: "2026-10-01", calendar: beijing), 20261001)
        XCTAssertNil(HolidayCalendar.dateKey(fromISODateString: "2026-02-30", calendar: beijing),
                     "伪日期（2 月 30 日）必须被 round-trip 拒绝")
        XCTAssertNil(HolidayCalendar.dateKey(fromISODateString: "2026-13-01", calendar: beijing),
                     "月份越界必须被 round-trip 拒绝")
        XCTAssertNil(HolidayCalendar.dateKey(fromISODateString: "2026-2-5", calendar: beijing),
                     "非 10 字符的变体写法拒绝")
        XCTAssertNil(HolidayCalendar.dateKey(fromISODateString: "garbage", calendar: beijing))
    }
}
