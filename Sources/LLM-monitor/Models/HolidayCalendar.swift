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
/// **数据源解析链（阶段 B，已落地）**：`shared` 不再只来自打包快照，默认参数
/// `HolidayCalendar = .shared` 在调用时求值，因此更新后各判定点自然读到新表。
/// 完整链条（编排在 `Services/HolidayCalendarService.swift`，本类型只提供纯解析）：
/// ① 本地缓存文件（存在且可解析）→ ② 内置 bundle 快照（`loadBundled()`，缺失 /
/// 解析失败内部退化为空表）→ ③ `.empty`。取数（URL 走 HTTPClient / 本地路径直读）
/// 成功后写缓存并 `applyResolved` 替换 `shared`；失败不清空既有数据。数据源由
/// config 顶层 `holidaySource` 配置（缺省 = 上游 chinese-days CDN URL；显式空串 =
/// 只用内置快照、不联网），`source` / `fetchedAt` 元信息即状态行的展示字段。
struct HolidayCalendar: Sendable, Equatable {
    /// yyyyMMdd 序号化的节假日日期集合（如 20261001），按 `beijingCalendar` 提取。
    /// 用 Int 键而非 Date / ISO 字符串：判定路径是纯 Set 查找，无 formatter、
    /// 无逐次时区换算。
    private let holidayKeys: Set<Int>

    /// 快照来源（配置源字符串或上游 URL）。空表退化为 nil；设置页状态行与
    /// 缓存回写（`HolidayCalendarService`）的展示字段。
    let source: String?
    /// 快照抓取日期（"YYYY-MM-DD"）。空表退化为 nil。
    let fetchedAt: String?

    /// 是否成功加载自打包资源。`false` = 资源缺失 / 解析失败时退化的空表；
    /// 用注入实例（fixture）构造的正常表为 `true`（区分"资源缺失"与"真空表"）。
    let isLoadedFromResource: Bool

    /// 空节假日表：缺数据的退化形态（纯周一–周五口径）。
    static let empty = HolidayCalendar(holidayKeys: [], source: nil, fetchedAt: nil, isLoadedFromResource: false)

    /// 进程级单例。默认从打包资源加载；数据源解析链（缓存命中 / 取数成功）经
    /// `applyResolved` 原子替换。读走锁保护的快照，默认参数
    /// `HolidayCalendar = .shared` 在**调用时**求值，替换后各判定点自然读到新表。
    static var shared: HolidayCalendar {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedStorage
    }

    /// `shared` 快照的单调版本号：每次 `applyResolved` 替换快照 +1。
    ///
    /// 存在的理由是**派生值的 memo**：`ModelPricingCatalog.estimate` 的
    /// `holidays` 默认参数在调用时求值 `HolidayCalendar.shared`，而节假日表
    /// 在运行期会换（本地缓存命中 / 远程取数成功，见 `HolidayCalendarService`），
    /// 换表后 DeepSeek 峰谷判定（Rule A 的"周一–周五 ∧ 非法定节假日"）结果会变。
    /// memo 的键里带上这个版本号，换表即失效重算；同值重复 `applyResolved` 也会
    /// 换版本号——那只是多算一次，方向是保守的。
    static var sharedRevision: Int {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedRevisionStorage
    }

    private static let sharedLock = NSLock()
    /// `nonisolated(unsafe)`：可变静态在并发下的正确性由 `sharedLock` 保证
    /// （ HolidayCalendar 是 Sendable 值类型，读写都是锁内的整份拷贝）。
    private nonisolated(unsafe) static var sharedStorage = HolidayCalendar.loadBundled()
    /// 与 `sharedStorage` 同锁读写；初值 0 表示"进程内还没换过表"。
    private nonisolated(unsafe) static var sharedRevisionStorage: Int = 0

    /// 数据源解析链成功后替换 `shared`（缓存命中 / 取数成功都走这里）。
    static func applyResolved(_ calendar: HolidayCalendar) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        sharedStorage = calendar
        sharedRevisionStorage &+= 1
    }

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

    /// 从打包资源加载（解析链的第 ② 层兜底：缓存缺失 / 损坏时使用）。
    /// 缺失 / 解析失败一律退化为空表 + 告警日志，不崩溃——与 ModelPricing.json
    /// 的"崩溃暴露问题"策略刻意不同：价格缺失会让所有 provider 显示未定价（必须
    /// 修），节假日缺失只影响少数法定假日的判定形状，降级可接受。
    static func loadBundled() -> HolidayCalendar {
        // 资源 bundle 整体缺失时 `Bundle.module` 访问器自身会 fatalError，走不到
        // 下面本意的降级分支——先探测再访问（probe 的候选与判定口径与 accessor 同序同形）。
        guard ResourceBundleProbe.isResourceBundleAvailable else {
            logWarn("HolidayCalendar: 资源 bundle 缺失（安装可能不完整），节假日判定退化为纯周一–周五口径")
            return .empty
        }
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

    /// 快照 JSON 的文档 schema（打包资源与本地缓存 `holidays-cache.json` 同构，
    /// 由 scripts/sync-holiday-data.sh 生成；取数成功后按此 schema 写缓存）。
    struct CacheDocument: Codable, Equatable, Sendable {
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
        let doc = try JSONDecoder().decode(CacheDocument.self, from: data)
        let calendar = PeakWindow.beijingCalendar
        let keys = Set(doc.holidays.compactMap { HolidayCalendar.dateKey(fromISODateString: $0, calendar: calendar) })
        self.init(holidayKeys: keys, source: doc.source, fetchedAt: doc.fetchedAt, isLoadedFromResource: true)
    }

    /// 从 "YYYY-MM-DD" 字符串集合构造（非法日期静默跳过）——测试 fixture 与
    /// 缓存/取数路径（`make(document:)`）的公共入口。`isLoadedFromResource` 为
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

    /// "YYYY-MM-DD" → 当日 00:00 的 Date（`isStale` 用）。非法日期返回 nil。
    static func date(fromISODateString text: String, calendar: Calendar) -> Date? {
        guard let key = dateKey(fromISODateString: text, calendar: calendar) else { return nil }
        var comps = DateComponents()
        comps.year = key / 10000
        comps.month = (key / 100) % 100
        comps.day = key % 100
        return calendar.date(from: comps)
    }

    // MARK: - 数据源语义与解析链（阶段 B）

    /// config `holidaySource` 的缺省值：上游 chinese-days CDN JSON（与
    /// `scripts/sync-holiday-data.sh` 的 `UPSTREAM_URL` 同值）。
    static let defaultSourceURL = "https://cdn.jsdelivr.net/npm/chinese-days/dist/chinese-days.json"

    /// 缓存新鲜度窗口（天）：`fetchedAt` 早于该天数才重新取数。
    static let defaultMaxAgeDays = 7

    /// 节假日数据源形态（config 顶层 `holidaySource` 的语义）。
    enum Source: Equatable, Sendable {
        /// HTTP(S) URL（原始字符串保留给快照 source 元信息）。
        case remoteURL(String)
        /// 本地文件路径（支持 `~` 前缀展开）。
        case localFile(String)
        /// 显式空串：只用内置快照，不联网、不读缓存。
        case bundledOnly
    }

    /// 解析 config 源字符串：http/https → remoteURL；空白串 → bundledOnly；
    /// 其余一律按本地路径处理。调用方传入的应是 `AppConfig.effectiveHolidaySource`
    /// （缺省键已替换为 `defaultSourceURL`）。
    static func parseSource(_ raw: String) -> Source {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .bundledOnly }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return .remoteURL(trimmed)
        }
        return .localFile(trimmed)
    }

    /// 快照日期（ISO "YYYY-MM-DD"，排序）。设置页状态展示与缓存回写用。
    var holidayDates: [String] {
        holidayKeys.sorted().map { key in
            String(format: "%04d-%02d-%02d", key / 10000, (key / 100) % 100, key % 100)
        }
    }

    /// 数据源解析统一入口：返回**排序去重后的**法定节假日 ISO 日期列表。
    /// 依次尝试：① 本项目快照格式（source / fetchedAt / holidays）；② 上游
    /// chinese-days 格式按脚本同款规则转换（默认源的 payload 就是该格式，App 内
    /// 转换与 `sync-holiday-data.sh` 产出一致）。两者都不是（如 ICS / 任意 HTML）
    /// 返回 nil，调用方给出明确失败文案——不猜测、不部分采用。
    static func parseSourceDates(
        _ data: Data,
        now: Date = Date(),
        calendar: Calendar = PeakWindow.beijingCalendar
    ) -> [String]? {
        if let doc = try? JSONDecoder().decode(CacheDocument.self, from: data) {
            let dates = Set(doc.holidays).sorted()
            if !dates.isEmpty { return dates }
        }
        return parseChineseDaysDates(data, now: now, calendar: calendar)
    }

    /// 上游 chinese-days 格式（顶层 holidays / workdays / inLieuDays 三个扁平映射）
    /// → 快照日期列表。转换规则与 `sync-holiday-data.sh` 完全一致：
    /// 非高峰日集合 = `holidays` ∪ `inLieuDays`（workdays 有意丢弃，Rule A），
    /// 年份过滤 `[当前年-1, …]`。解析失败或结果为空返回 nil（按格式不支持处理）。
    ///
    /// **键集校验与脚本护栏同款**：上游 schema 改名 / 缺键时必须整体拒绝，而不是
    /// 只按还能读到的那部分数据静默产出快照（`workdays` 明明缺了却照样"成功"会让
    /// 数据问题被隐藏）。三键缺一即返回 nil，由调用方给出既有的「仅支持本项目
    /// JSON 快照格式」失败文案，不新增文案。
    static func parseChineseDaysDates(
        _ data: Data,
        now: Date = Date(),
        calendar: Calendar = PeakWindow.beijingCalendar
    ) -> [String]? {
        struct UpstreamDocument: Decodable {
            // 值形态不参与判定（"English,中文,旗标"），宽松解码只取日期键。
            let holidays: [String: LossyString]?
            let workdays: [String: LossyString]?
            let inLieuDays: [String: LossyString]?
        }
        struct LossyString: Decodable {
            init(from decoder: Decoder) throws {
                _ = try? decoder.singleValueContainer().decode(String.self)
            }
        }
        guard let doc = try? JSONDecoder().decode(UpstreamDocument.self, from: data),
              let holidayKeys = doc.holidays?.keys,
              // workdays 不参与判定，但必须存在：缺它 = 上游 schema 已变。
              doc.workdays != nil,
              let inLieuKeys = doc.inLieuDays?.keys else { return nil }
        let minYear = calendar.component(.year, from: now) - 1
        let dates = Set(holidayKeys)
            .union(inLieuKeys)
            .compactMap { key -> String? in
                guard let year = Int(key.prefix(4)), year >= minYear else { return nil }
                return dateKey(fromISODateString: key, calendar: calendar).map { _ in key }
            }
            .sorted()
        return dates.isEmpty ? nil : dates
    }

    /// 从快照文档构造（缓存命中路径与取数路径共用；非法日期静默跳过）。
    static func make(document: CacheDocument) -> HolidayCalendar {
        make(holidays: document.holidays, source: document.source, fetchedAt: document.fetchedAt)
    }

    /// 解析链（纯函数，可注入）：① 本地缓存数据（存在、可解析且非空）→
    /// ② 内置 bundle 快照（`bundled` 注入点，生产即 `loadBundled()`，其内部在
    /// 资源缺失/损坏时退化为 `.empty`）。返回是否命中了缓存，供状态行
    /// 「来源：缓存/内置」展示。
    static func resolve(
        cacheData: Data?,
        bundled: () -> HolidayCalendar = { HolidayCalendar.loadBundled() }
    ) -> (calendar: HolidayCalendar, usedCache: Bool) {
        if let data = cacheData,
           let doc = try? JSONDecoder().decode(CacheDocument.self, from: data),
           !doc.holidays.isEmpty {
            return (make(document: doc), true)
        }
        return (bundled(), false)
    }

    /// 北京时间 "YYYY-MM-DD"（取数 `fetchedAt` 戳的登记口径）。
    static func beijingDateString(on now: Date = Date()) -> String {
        let calendar = PeakWindow.beijingCalendar
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 缓存是否过期：`fetchedAt`（"YYYY-MM-DD"）距 `now` 超过 `maxAgeDays` 个
    /// 自然日（按 `calendar` 计算日期差，忽略当日时刻）。fetchedAt 缺失 / 非法
    /// 视为已过期。
    static func isStale(
        fetchedAt: String,
        now: Date = Date(),
        maxAgeDays: Int = HolidayCalendar.defaultMaxAgeDays,
        calendar: Calendar = PeakWindow.beijingCalendar
    ) -> Bool {
        guard let fetched = date(fromISODateString: fetchedAt, calendar: calendar) else { return true }
        let days = calendar.dateComponents([.day], from: fetched, to: now).day
        return (days ?? Int.max) > maxAgeDays
    }
}
