import Foundation

/// 取数失败的轻量包装（`String` 不满足 `Error`，`Result` 需要真正的 Error 类型）。
struct HolidaySourceFailure: Error, Equatable {
    let reason: String
}

/// 节假日数据源服务：解析链编排 + best-effort 取数刷新。
///
/// 职责边界：解析与判定全是纯函数，收在 `Models/HolidayCalendar.swift`
/// （`parseSource` / `parseSourceDates` / `resolve` / `isStale`）；本类型只做
/// 编排——缓存文件 IO、HTTP（`Services/Infra/HTTPClient`，L0 基础设施）、
/// `HolidayCalendar.shared` 的应用与「该不该刷」的触发判定。
///
/// **触发条件**（`source` = `AppConfig.effectiveHolidaySource`）：
/// - 启动后：App 入口调 `start(source:)` —— 先走解析链应用既有数据（不阻塞、
///   不崩），缓存缺失 / 过期（`fetchedAt` 早于 7 天）/ 源变更时异步取数；
/// - 源变更：`AppState` 的 config 订阅调 `handleConfigChange(source:)`，
///   源字符串没变时 no-op（不会因其他配置项变更而误刷）；
/// - 设置页「立即更新」：`refreshNow(source:)` 强制取数一次，不受新鲜度限制。
///
/// **失败语义**：取数 / 解析 / 写缓存失败都只产出结果文案，既有 `shared` 表与
/// 缓存文件原样保留——节假日表是"锦上添花"的数据，绝不能因为刷新失败把好的
/// 判定搞坏。`bundledOnly`（显式空串）不发起任何网络请求。
///
/// **测试不依赖网络**：远端取数路径用 `init(session:)` 注入 URLProtocol 桩覆盖
/// （见 `HolidaySourceRemoteFetchTests`），本地文件路径、解析链与状态文案纯函数
/// 全部可注入 / 可直接断言。测试里应用过新表后应通过
/// `HolidayCalendar.applyResolved` 恢复原表（global 状态复位）。
@MainActor
final class HolidayCalendarService: ObservableObject {

    /// 缓存文件名（与打包资源同 schema：source / fetchedAt / holidays）。
    nonisolated static let cacheFileName = "holidays-cache.json"

    /// 默认缓存路径：`~/Library/Application Support/LLM-monitor/holidays-cache.json`。
    nonisolated static func defaultCacheURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support
            .appendingPathComponent("LLM-monitor", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    /// 缓存文件位置。生产从 `configStore.configURL` 同目录派生（AppState 注入）。
    let cacheURL: URL
    /// 取数客户端（CDN 属海外路径，用 overseas 档超时）。
    private let httpClient: HTTPClient
    /// 取数成功应用新表后的宿主回调（AppState：statusDidChange + 重排健康边界）。
    private let onCalendarApplied: () -> Void

    /// 最近一次取数结果文案（成功 / 失败原因；失败时既有数据原样保留）。
    @Published private(set) var lastRefreshMessage: String?
    /// 取数进行中（设置页按钮禁用 + 转圈）。
    @Published private(set) var isRefreshing: Bool = false
    /// 当前 `shared` 表是否来自本地缓存（false = 内置快照或空表）。状态行展示用。
    @Published private(set) var resolvedFromCache: Bool = false

    /// 本会话内最近一次成功取数所用的源字符串（会话内去重：启动 / config 变更
    /// 多次触发同一源时只在第一次真刷）。
    private var fetchedSource: String?
    /// 最近一次看到的配置源；config 变更检测基线（`adoptSource` seed，不触发取数）。
    private var lastSeenSource: String?
    private var refreshTask: Task<Void, Never>?

    init(
        cacheURL: URL? = nil,
        session: URLSession = .shared,
        onCalendarApplied: @escaping () -> Void = {}
    ) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.httpClient = HTTPClient(
            session: session,
            logTag: "[holidays]",
            defaultTimeout: HTTPTimeouts.overseas
        )
        self.onCalendarApplied = onCalendarApplied
    }

    // MARK: - 启动与配置变更

    /// App 启动入口：seed 源基线后，异步走「解析链 → 按需取数」，不阻塞调用方。
    func start(source rawSource: String) {
        adoptSource(rawSource)
        let source = rawSource
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.startupFlow(source: source)
        }
    }

    /// config 变更入口：源字符串变了才重新解析 + 按需取数（源未变 no-op，
    /// 其他配置项的保存不会触发节假日取数）。
    func handleConfigChange(source rawSource: String) {
        guard rawSource != lastSeenSource else { return }
        start(source: rawSource)
    }

    /// seed 源基线（`AppState.init` 调用）：只记录「当前是什么源」，不解析不取数。
    func adoptSource(_ rawSource: String) {
        lastSeenSource = rawSource
    }

    private func startupFlow(source: String) async {
        // 1. 解析链：本地缓存（存在且可解析）→ 内置快照（可能退化空表）。
        //    bundledOnly 跳过缓存：该语义就是「只用内置快照」。
        if case .bundledOnly = HolidayCalendar.parseSource(source) {
            HolidayCalendar.applyResolved(HolidayCalendar.loadBundled())
            resolvedFromCache = false
        } else {
            let cacheData = try? Data(contentsOf: cacheURL)
            let (calendar, usedCache) = HolidayCalendar.resolve(cacheData: cacheData)
            HolidayCalendar.applyResolved(calendar)
            resolvedFromCache = usedCache
        }
        // 2. 按需取数（缓存缺失 / 过期 / 源变更；非 force 受新鲜度窗口约束）。
        await refreshIfPossible(source: source, force: false)
    }

    // MARK: - 取数

    /// 设置页「立即更新」：强制取数一次（不受新鲜度窗口限制），返回结果文案。
    func refreshNow(source rawSource: String) async -> String {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSeenSource = source
        return await refresh(source: source, force: true)
    }

    private func refreshIfPossible(source: String, force: Bool) async {
        if !force, !shouldFetch(source: source) { return }
        _ = await refresh(source: source, force: force)
    }

    @discardableResult
    private func refresh(source: String, force: Bool) async -> String {
        guard !isRefreshing else { return force ? "已有节假日更新在进行中" : "" }
        if case .bundledOnly = HolidayCalendar.parseSource(source) {
            let message = "节假日数据源为空：仅使用内置快照，不联网更新"
            if force { lastRefreshMessage = message }
            return message
        }
        isRefreshing = true
        defer { isRefreshing = false }

        switch await fetch(from: source) {
        case .success(let document):
            // 写缓存（best-effort；写失败不影响应用新表）。
            writeCache(document)
            let calendar = HolidayCalendar.make(document: document)
            HolidayCalendar.applyResolved(calendar)
            resolvedFromCache = true
            fetchedSource = source
            let years: String
            if let range = calendar.coveredYears {
                years = range.lowerBound == range.upperBound
                    ? "\(range.lowerBound)"
                    : "\(range.lowerBound)–\(range.upperBound)"
            } else {
                years = "无覆盖年份"
            }
            let message = "更新成功：覆盖 \(years)（\(document.holidays.count) 天，抓取于 \(document.fetchedAt)）"
            lastRefreshMessage = message
            onCalendarApplied()
            return message
        case .failure(let failure):
            // 失败不清空既有数据：shared 与缓存都保持原样，只报原因。
            let message = "节假日更新失败：\(failure.reason)"
            lastRefreshMessage = message
            return message
        }
    }

    /// 非强制取数的触发判定：bundledOnly 不刷；本会话已按该源刷过不刷；
    /// 缓存缺失 / 损坏 / 来自其他源 / `fetchedAt` 过期才刷。
    private func shouldFetch(source: String) -> Bool {
        if case .bundledOnly = HolidayCalendar.parseSource(source) { return false }
        if fetchedSource == source { return false }
        guard let data = try? Data(contentsOf: cacheURL),
              let document = try? JSONDecoder().decode(HolidayCalendar.CacheDocument.self, from: data) else {
            return true
        }
        if document.source != source { return true }
        return HolidayCalendar.isStale(fetchedAt: document.fetchedAt)
    }

    private func fetch(
        from rawSource: String
    ) async -> Result<HolidayCalendar.CacheDocument, HolidaySourceFailure> {
        let fetchedAt = HolidayCalendar.beijingDateString()
        switch HolidayCalendar.parseSource(rawSource) {
        case .bundledOnly:
            return .failure(HolidaySourceFailure(reason: "仅内置快照模式不发起取数"))
        case .localFile(let path):
            let expanded = (path as NSString).expandingTildeInPath
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
                return parse(data, source: rawSource, fetchedAt: fetchedAt)
            } catch {
                return .failure(HolidaySourceFailure(reason: "无法读取文件 \(path)（\(error.localizedDescription)）"))
            }
        case .remoteURL(let urlString):
            guard let url = URL(string: urlString) else {
                return .failure(HolidaySourceFailure(reason: "URL 无效：\(urlString)"))
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            do {
                let (data, _) = try await httpClient.send(request)
                return parse(data, source: rawSource, fetchedAt: fetchedAt)
            } catch is CancellationError {
                return .failure(HolidaySourceFailure(reason: "已取消"))
            } catch {
                return .failure(HolidaySourceFailure(reason: "网络请求失败（\(error.localizedDescription)）"))
            }
        }
    }

    /// 解析取到的数据为缓存文档。source / fetchedAt 以本次取数登记为准
    /// （fetchedAt 是「上次从源取数」的日期，驱动 7 天新鲜度窗口）。
    private func parse(
        _ data: Data,
        source: String,
        fetchedAt: String
    ) -> Result<HolidayCalendar.CacheDocument, HolidaySourceFailure> {
        guard let dates = HolidayCalendar.parseSourceDates(data) else {
            return .failure(HolidaySourceFailure(
                reason: "仅支持本项目 JSON 快照格式，可用 scripts/sync-holiday-data.sh 生成"
            ))
        }
        return .success(HolidayCalendar.CacheDocument(
            source: source,
            fetchedAt: fetchedAt,
            holidays: dates
        ))
    }

    private func writeCache(_ document: HolidayCalendar.CacheDocument) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            // 缓存与 config.json 同属用户数据，落盘必须 0600、目录 0700，不能依赖
            // 进程 umask（`Data.write(.atomic)` 会按 umask 留下 0644）。统一走
            // `FileManagerBox` 的私有写入口（临时文件 0600 出生 + rename）。
            let fileManager = FileManagerBox()
            try fileManager.createPrivateDirectory(at: cacheURL.deletingLastPathComponent())
            try fileManager.writePrivate(data, to: cacheURL)
        } catch {
            logWarn("HolidayCalendarService: 缓存写入失败（\(error.localizedDescription)），新表仍已应用")
        }
    }

    // MARK: - 设置页状态文案（纯函数，可测）

    /// 状态行：`2025–2026 · 抓取于 2026-10-05 · 来源：缓存`（内置表来源为「内置」）。
    /// 纯函数，`nonisolated` 供测试与任意上下文直接调用。
    nonisolated static func statusLine(for calendar: HolidayCalendar, fromCache: Bool) -> String {
        let years: String
        if let range = calendar.coveredYears {
            years = range.lowerBound == range.upperBound
                ? "\(range.lowerBound)"
                : "\(range.lowerBound)–\(range.upperBound)"
        } else {
            years = "未覆盖任何年份"
        }
        let fetched = calendar.fetchedAt.map { "抓取于 \($0)" } ?? "无抓取记录"
        let origin = fromCache ? "缓存" : "内置"
        return "\(years) · \(fetched) · 来源：\(origin)"
    }

    /// 当前年份未被快照覆盖时的橙色提示；nil = 已覆盖（纯周一–周五降级提示见
    /// `HolidayCalendar.empty` 的退化语义）。纯函数，`nonisolated` 同上。
    nonisolated static func coverageWarning(for calendar: HolidayCalendar, currentYear: Int) -> String? {
        guard !calendar.covers(year: currentYear) else { return nil }
        return "节假日表未覆盖 \(currentYear)，\(currentYear) 年按纯周一–周五判定"
    }

    /// 设置页状态行（读当前 `shared` 表 + 本服务的来源标记）。
    var statusLineText: String {
        Self.statusLine(for: HolidayCalendar.shared, fromCache: resolvedFromCache)
    }

    /// 设置页橙色覆盖提示（读当前 `shared` 表，年份按北京时间）。
    var coverageWarningText: String? {
        let year = PeakWindow.beijingCalendar.component(.year, from: Date())
        return Self.coverageWarning(for: HolidayCalendar.shared, currentYear: year)
    }
}
