import Foundation

/// 中国法定节假日静态快照 —— 高峰判定工作日口径（Rule A）的节假日数据源。
///
/// **Rule A（既定口径，GLM 与 DeepSeek 统一形状）**：高峰判定的"工作日" =
/// 周一–周五 ∧ 当天不是法定节假日。两个推论同样是有意决策：
/// - 调休换来的放假日（上游 `inLieuDays`，常为周一–周五）属于法定假日，必须排除；
/// - 调休上班的周六/周日（上游 `workdays`）**有意不建模**：它们本来就不满足
///   "周一–周五"，Rule A 下天然不算高峰，无需"调休上班日算高峰"的例外规则。
///
/// 非高峰日集合 = 上游 `holidays` ∪ `inLieuDays` 的日期并集，由
/// `scripts/sync-holiday-data.sh` 从 vsme/chinese-days 生成
/// （`Resources/ChinaHolidays.json`，静态离线快照，年份覆盖 [当前年-1, …]）。
///
/// **时区基准**：所有日期键按北京时间（`PeakWindow.beijingCalendar`，Asia/Shanghai）
/// 提取与比对——GLM / DeepSeek 的高峰判定统一以北京时间为准，与本机时区无关。
///
/// **缺数据兜底**：资源缺失或解析失败时退化为"空节假日表"（纯周一–周五口径，
/// `isLoadedFromResource == false`）并记一条日志，不抛错、不崩溃——缺节假日数据
/// 只意味着法定假日的周一–周五会被误判为高峰候选（白天时段仍按 slots 判定），
/// 属于可接受的降级，不应阻断 App 其他功能。
///
/// **阶段 B 接缝**：「数据源可配置 + 在线取数缓存」属于阶段 B，本阶段不实现。
/// 加载逻辑收在 `loadBundled()`（bundle 资源的唯一切入点，可替换），阶段 B 会在
/// `shared` 前面插一层"缓存/远程覆盖"并替换加载入口；`source` / `fetchedAt`
/// 元信息即为此预留的展示与提示字段。
struct HolidayCalendar: Sendable, Equatable {
    /// yyyyMMdd 序号化的节假日日期集合（如 20261001），按 `beijingCalendar` 提取。
    /// 用 Int 键而非 Date / ISO 字符串：判定路径是纯 Set 查找，无 formatter、
    /// 无逐次时区换算。
    private let holidayKeys: Set<Int>

    /// 快照来源（上游 URL）。空表退化为 nil；阶段 B 的"数据源可配置"展示用。
    let source: String?
    /// 快照抓取日期（"YYYY-MM-DD"）。空表退化为 nil。
    let fetchedAt: String?

    /// 是否成功加载自打包资源。`false` = 资源缺失 / 解析失败时退化的空表；
    /// 用注入实例（fixture）构造的正常表为 `true`（区分"资源缺失"与"真空表"）。
    let isLoadedFromResource: Bool

    /// 空节假日表：缺数据的退化形态（纯周一–周五口径）。
    static let empty = HolidayCalendar(holidayKeys: [], source: nil, fetchedAt: nil, isLoadedFromResource: false)

    /// 进程级单例：从打包资源加载一次。阶段 B 会在其前插入缓存/远程覆盖层，
    /// 见文件头「阶段 B 接缝」。
    static let shared: HolidayCalendar = loadBundled()

    /// `date` 是否为法定节假日 / 调休放假日。日期键按传入 calendar 提取
    /// （默认北京时间，与快照生成口径一致）。
    func isHoliday(_ date: Date, calendar: Calendar = PeakWindow.beijingCalendar) -> Bool {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return false }
        return holidayKeys.contains(year * 10000 + month * 100 + day)
    }

    /// 快照覆盖的年份范围（min–max；数据按年连续，连续性由 HolidayCalendarTests
    /// 守门）。空表返回 nil。
    var coveredYears: ClosedRange<Int>? {
        guard let first = holidayKeys.min(), let last = holidayKeys.max() else { return nil }
        return first / 10000 ... last / 10000
    }

    /// 快照是否覆盖某年份（节假日数据按年发布，未覆盖年份的判定回退纯周一–周五）。
    func covers(year: Int) -> Bool {
        guard let range = coveredYears else { return false }
        return range.contains(year)
    }

    // MARK: - 加载与构造

    /// 从打包资源加载（`loadBundled` 是阶段 B 插入缓存/远程覆盖层前的唯一切入点）。
    /// 缺失 / 解析失败一律退化为空表 + 告警日志，不崩溃——与 ModelPricing.json
    /// 的"崩溃暴露问题"策略刻意不同：价格缺失会让所有 provider 显示未定价（必须
    /// 修），节假日缺失只影响少数法定假日的判定形状，降级可接受。
    static func loadBundled() -> HolidayCalendar {
        guard let url = Bundle.module.url(forResource: "ChinaHolidays", withExtension: "json") else {
            logWarn("HolidayCalendar: ChinaHolidays.json 缺失（Bundle.module 找不到打包资源），节假日判定退化为纯周一–周五口径")
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try HolidayCalendar(resourceData: data)
        } catch {
            logWarn("HolidayCalendar: ChinaHolidays.json 解析失败（\(error.localizedDescription)），节假日判定退化为纯周一–周五口径")
            return .empty
        }
    }

    /// 快照 JSON 的解码形态（由 scripts/sync-holiday-data.sh 生成）。
    private struct ResourceDocument: Decodable {
        let source: String
        let fetchedAt: String
        let holidays: [String]
    }

    private init(holidayKeys: Set<Int>, source: String?, fetchedAt: String?, isLoadedFromResource: Bool) {
        self.holidayKeys = holidayKeys
        self.source = source
        self.fetchedAt = fetchedAt
        self.isLoadedFromResource = isLoadedFromResource
    }

    /// 解析快照 JSON。个别非法日期（格式错 / 非真日期）跳过——脚本护栏 + 测试
    /// 守门之下不应出现，出现时也不该让整张表失效；整体解析失败走 catch 退化。
    private init(resourceData data: Data) throws {
        let doc = try JSONDecoder().decode(ResourceDocument.self, from: data)
        let calendar = PeakWindow.beijingCalendar
        let keys = Set(doc.holidays.compactMap { HolidayCalendar.dateKey(fromISODateString: $0, calendar: calendar) })
        self.init(holidayKeys: keys, source: doc.source, fetchedAt: doc.fetchedAt, isLoadedFromResource: true)
    }

    /// 从 "YYYY-MM-DD" 字符串集合构造（非法日期静默跳过）——测试 fixture 与
    /// 阶段 B 注入层的公共入口。`isLoadedFromResource` 为
    /// `true`（正常构造的表，区别于资源缺失退化的 `empty`）。
    static func make(
        holidays: some Collection<String>,
        source: String? = nil,
        fetchedAt: String? = nil
    ) -> HolidayCalendar {
        let calendar = PeakWindow.beijingCalendar
        let keys = Set(holidays.compactMap { HolidayCalendar.dateKey(fromISODateString: $0, calendar: calendar) })
        return HolidayCalendar(holidayKeys: keys, source: source, fetchedAt: fetchedAt, isLoadedFromResource: true)
    }

    /// "YYYY-MM-DD" → yyyyMMdd Int 键。必须是真日期：超出当月天数 / 月份范围的
    /// 伪日期（如 2026-02-30）会被 Calendar 归一化到相邻月，round-trip 不一致即
    /// 拒绝。失败返回 nil。
    static func dateKey(fromISODateString text: String, calendar: Calendar) -> Int? {
        // 严格 10 字符 "YYYY-MM-DD"（4 + '-' + 2 + '-' + 2），不允许紧凑/变体写法。
        guard text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return year * 10000 + month * 100 + day
    }
}
