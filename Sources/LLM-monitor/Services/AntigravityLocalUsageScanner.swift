import Foundation
import Combine
import os.log

/// 扫描 `~/.gemini/<antigravity|antigravity-ide>/conversations/`，只读取本地
/// session 文件的路径、扩展名和 mtime/size 指纹；token 数据不从 `.db` / `.pb` 内容读取。
/// 对 dirty session 通过 `AntigravityFetcher.getTrajectoryMetadata` RPC 拉取
/// per-event token 用量和结构信息，聚合后写入正式的 `index.json` daily cache。
/// 当新版 RPC 事件缺少时间戳时，`.db` session 只额外读取对应 step metadata 中的
/// protobuf Timestamp；`.pb` 没有该回退路径。
///
/// ## 优化重点
///
/// 1. **fingerprint-based diff**：每次扫描先 stat 所有 session 文件及其 WAL，
///    跟 `index.json` 里的文件/WAL `mtimeMs` / `sizeBytes` 对比；只有 changed
///    sessions 才走 RPC。
/// 2. **per-session daily 缓存**：aggregated daily 数据按 session 维度存
///    在 `index.dailyBySession`；changed session 只替换自己的缓存贡献，
///    全局汇总继续复用未变化 session 的缓存。
/// 3. **in-flight dedup**：`scan()` 调用时如果上一次还在跑，直接忽略。
/// 4. **serial RPC**：dirty session 串行拉 RPC（`fetchAll` 内部 for 循环）。
///    本地 session 文件只用于发现和指纹比较，不参与内容解析。
/// 5. **失败不重试**：RPC 失败或返回空事件时保留 last-good cache，
///    由下次外部 triggerAntigravityLocalUsageScan 调用（来自 antigravity 主 quota
///    refresh timer，默认 60s）自然重试。
/// 6. **failure 不更新 mtime**：RPC 失败的 session 在 `index.sessions` 里
///    mtime 保持不变，下次扫描会自然重试，不留"假成功"状态。
@MainActor
final class AntigravityLocalUsageScanner: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: AntigravityLocalUsage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    /// 默认 cache 目录，跟 ddarkr/token-monitor 对齐
    ///
    /// 历史上有两个 Antigravity IDE 产品的数据目录：
    ///
    /// 1. 旧版 `Antigravity.app`（2025 年起，`--app_data_dir antigravity`）→ `~/.gemini/antigravity/`
    /// 2. 新版 `Antigravity IDE.app`（2026 年起，`--app_data_dir antigravity-ide`）→ `~/.gemini/antigravity-ide/`
    ///
    /// scanner 同时扫两个目录（按顺序合并去重），新版的优先让新活跃数据先被 mtime diff 命中，
    /// 旧版数据兜底兼容老用户。
    ///
    /// 同时也接受两种 session 文件格式：`.db` 和 `.pb`。
    /// 两者都只用于文件发现与指纹比较，Token 和 Turn/Round 均走本地 RPC。
    nonisolated static let defaultConversationsDirs: [URL] = {
        let gemini = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
        return [
            // 新版 IDE（Antigravity IDE.app 2026+，带空格）
            gemini
                .appendingPathComponent("antigravity-ide", isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true),
            // 旧版 IDE（Antigravity.app 2025，无空格）—— 兜底兼容
            gemini
                .appendingPathComponent("antigravity", isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
        ]
    }()

    nonisolated static let defaultCacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent(".token-monitor", isDirectory: true)
    }()

    private let fetcher: AntigravityFetcher
    private let conversationsDirs: [URL]
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var inFlightTask: Task<Void, Never>?
    /// 每次 `scan()` / `cancelInFlight()` 递增 generation token。
    /// runScan 结束时跟 latest generation 比对, 不一致就丢弃结果,
    /// 防止旧 generation 的 task 在新 generation 启动后写回状态。
    private var latestGeneration: UInt64 = 0
    /// 整个 `performScanPure` pipeline 串行化. cancel+rescan 时两个 worker
    /// 会 race cache 写 (新 worker 读到旧 disk 状态, 算完写入 = 回滚新 worker
    /// 的 view). 用 async-aware 的 AsyncMutex 串行整个 pipeline, 老的 worker
    /// 跑完才让新 worker 开始, 彻底消除 revert 风险. "并发 RPC" 收益在
    /// cancel+rescan 时也用不上 (新 worker 等老 worker 几秒可接受).
    nonisolated static let pipelineMutex = AsyncMutex()

    /// 最近一次成功写入 index.json 的 generation. 旧 worker 即使晚到 mutex,
    /// `startedGeneration > self.lastCommittedGeneration` 才写盘, 否则 saveIndex
    /// 跳过保留新 worker 的 view. read + write 都在 `performScanPure` 内部, 跨
    /// `@MainActor` 边界 hop (AsyncMutex 持锁期间, 不会跟其他 worker 交叉).
    /// 每个 scanner 实例独立, 跨实例不共享.
    @MainActor private var lastCommittedGeneration: UInt64 = 0

    /// Test-only hook: `performScanPure` 入口会 `await` 这个闭包, 闭包默认 nil
    /// (生产零开销, 一个 nil-check). 测试可以注入一个 `TestGate.wait()`, 让
    /// worker 在 RPC / SQL / cache 写前阻塞, 精确控制 cancel + rescan 时序
    /// (而不是依赖 "扫描瞬间完成" 的间接验证, 那个测的是 '启动时 generation
    /// 已变' 分支, 不是真正在压力下的 cancel 路径).
    ///
    /// `#if DEBUG`: 隔离到 debug build, release build 的 binary 没有这个字段
    /// (避免生产代码带可变的非隔离测试状态). 测试 target 默认用 debug 编译
    /// (`DEBUG` defined), 可以正常访问.
    #if DEBUG
    nonisolated(unsafe) static var testGate: (@Sendable () async -> Void)?
    /// Test-only observer for deterministic cache-write assertions.
    nonisolated(unsafe) static var testSaveIndexHook: (@Sendable () -> Void)?
    #endif

    init(fetcher: AntigravityFetcher,
         conversationsDirs: [URL] = AntigravityLocalUsageScanner.defaultConversationsDirs,
         cacheDir: URL = AntigravityLocalUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.conversationsDirs = conversationsDirs
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        self.lastResult = Self.loadCachedResult(
            cacheDir: cacheDir,
            fileManager: fileManager,
            calendar: calendar,
            now: Date()
        )
    }

    /// performScanPure 在 mutex 内读 + 写本实例的 lastCommittedGeneration
    /// (`@MainActor private var`, 跨 actor 边界要 hop). 暴露成 method 让
    /// `await scanner.readLastCommittedGeneration()` 在主 actor 上跑.
    ///
    /// `internal` (不是 fileprivate) 因为 test 需要读这个值来验证 skip path.
    /// 生产代码只通过 performScanPure 间接使用, 不会直接调.
    @MainActor func readLastCommittedGeneration() -> UInt64 {
        return self.lastCommittedGeneration
    }

    /// 同上, 写路径. performScanPure 写盘成功后调这个更新本实例. `fileprivate`
    /// 只给 performScanPure 用, 外部不可见.
    @MainActor fileprivate func writeLastCommittedGeneration(_ value: UInt64) {
        self.lastCommittedGeneration = value
    }

    /// 触发一次扫描。如果上一次还在跑，直接忽略（dedup）。
    /// 完成时通过 `lastResult` / `lastError` 暴露结果。
    func scan() {
        guard inFlightTask == nil else { return }
        isScanning = true
        latestGeneration &+= 1
        let startedGeneration = latestGeneration
        inFlightTask = Task { [weak self] in
            await self?.runScan(startedGeneration: startedGeneration)
        }
    }

    /// 取消当前 in-flight scan。配置变更 / AppState.stop() 调用,
    /// 防止旧扫描结果写回新状态。
    /// 实际效果:
    /// 1. generation 递增 —— 旧 runScan 完成时 generation 比对失败, 主动 return
    /// 2. Task.cancel() —— 让继承取消状态的扫描工作尽快抛 CancellationError
    /// 3. isScanning 立即清 false —— 防止"cancel 后不 rescan"时 UI 永远显示
    ///    "scanning..." (P6 fix 的 defer generation 守门本意是"不让旧任务 defer
    ///    干扰新任务", 但 cancel 不 rescan 时旧任务 defer 因 generation 不匹配
    ///    跳过清理, isScanning 卡在 true, 这个守门的副作用要 cancel 主动补)
    /// 双保险, 即便 runScan 已过了 generation check, 也会被 cancel 中断。
    func cancelInFlight() {
        latestGeneration &+= 1
        isScanning = false
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    private func runScan(startedGeneration: UInt64) async {
        // scanner 自己的 defer：清 isScanning / inFlightTask（必须 generation 守门，
        // 否则旧任务的 defer 会误清新任务的状态）。generation 守门 + 取消 filter
        // 走 `LocalUsageScanRunner`，runner 也负责启动 / 完成的 generation check。
        defer {
            if startedGeneration == self.latestGeneration {
                self.isScanning = false
                self.inFlightTask = nil
            } else {
                logInfo("[antigravity-scan] 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(self.latestGeneration)")
            }
        }
        // 重 I/O + RPC 全部在 background 执行（文件元数据、文件遍历、HTTP RPC、缓存读写）。
        // scanner 是 @MainActor，但 performScanPure 是 nonisolated static 不碰 self，
        // 全部依赖通过参数传。这样菜单栏 UI 不会被 I/O 阻塞。
        let fetcher = self.fetcher
        let conversationsDirs = self.conversationsDirs
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        
        let work: @Sendable () async throws -> AntigravityLocalUsage = {
            try await Self.performScanPure(
                fetcher: fetcher,
                conversationsDirs: conversationsDirs,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now,
                startedGeneration: startedGeneration,
                scanner: self
            )
        }
        let applyResult: @MainActor (AntigravityLocalUsage) -> Void = { result in
            self.lastResult = result
            self.lastError = nil
        }
        let applyError: @MainActor (String) -> Void = { message in
            // 失败时保留上次的 lastResult（如果之前有），UI 不闪空白
            self.lastError = message
        }
        await LocalUsageScanRunner.run(
            logTag: "[antigravity-scan]",
            startedGeneration: startedGeneration,
            latestGeneration: { self.latestGeneration },
            work: work,
            applyResult: applyResult,
            applyError: applyError
        )
    }

}

// MARK: - Cache + index types

extension AntigravityLocalUsageScanner {
    struct SessionIndexEntry: Equatable, Codable, Sendable {
        var mtimeMs: Double
        var sizeBytes: Int
        /// `.db` 的 WAL 是活跃 session 最常变化的文件；主 session 文件可能长期不变。
        var walMtimeMs: Double
        var walSizeBytes: Int
        var fetchedAt: Date?
        var eventCount: Int

        init(
            mtimeMs: Double,
            sizeBytes: Int,
            walMtimeMs: Double = 0,
            walSizeBytes: Int = 0,
            fetchedAt: Date?,
            eventCount: Int
        ) {
            self.mtimeMs = mtimeMs
            self.sizeBytes = sizeBytes
            self.walMtimeMs = walMtimeMs
            self.walSizeBytes = walSizeBytes
            self.fetchedAt = fetchedAt
            self.eventCount = eventCount
        }

        private enum CodingKeys: String, CodingKey {
            case mtimeMs, sizeBytes, walMtimeMs, walSizeBytes, fetchedAt, eventCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mtimeMs = try container.decode(Double.self, forKey: .mtimeMs)
            sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
            // v2 index 没有 WAL 字段；以 0 迁移，若当前存在 WAL 会自然 dirty 一次。
            walMtimeMs = try container.decodeIfPresent(Double.self, forKey: .walMtimeMs) ?? 0
            walSizeBytes = try container.decodeIfPresent(Int.self, forKey: .walSizeBytes) ?? 0
            fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
            eventCount = try container.decode(Int.self, forKey: .eventCount)
        }
    }

    /// 顶层 index 状态，存到 `~/.gemini/antigravity/.token-monitor/index.json`。
    /// - `sessions`：所有已扫描过的本地 sessionId → session 文件及可选 WAL 的 mtime/size + 上次拉 RPC 的时间
    /// - `dailyBySession`：每个 session 按本地自然日拆开的 token 聚合
    ///   （让 changed session 只需要替换自己的贡献，不用重新拉取其他 session）
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var lastScannedAt: Date
        var sessions: [String: SessionIndexEntry]
        var dailyBySession: [String: [String: AntigravityDailyUsage]]
        var samplesBySession: [String: [LocalTokenUsageSample]]?

        static let empty = CacheIndex(
            version: 6,
            lastScannedAt: Date(timeIntervalSince1970: 0),
            sessions: [:],
            dailyBySession: [:],
            samplesBySession: [:]
        )
    }
}

// MARK: - Pipeline

// MARK: - Pipeline（off main actor）

extension AntigravityLocalUsageScanner {
    /// 纯计算 + I/O + RPC，不直接修改 self；由非 actor-isolated runner 执行。
    /// 所有依赖通过参数传，不依赖 @MainActor 隔离。失败抛错给外层 catch。
    ///
    /// 并发安全: 整个 pipeline 在 `Self.pipelineMutex` (AsyncMutex) 里串行执行.
    /// 多个 worker cancel+rescan 时, 旧 worker 跑完整个 pipeline 才让新 worker
    /// 开始. 同时 `lastCommittedGeneration` 守门防止旧 worker 的 saveIndex 回滚
    /// 新 worker 已写入的 cache (旧 worker 即使晚到 mutex, 也会跳过 saveIndex).
    /// runScan 端的 generation 守门 (startedGeneration == latestGeneration) 负责
    /// 旧 worker 的 in-memory result 不污染新 worker 状态.
    nonisolated static func performScanPure(
        fetcher: AntigravityFetcher,
        conversationsDirs: [URL],
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        startedGeneration: UInt64,
        scanner: AntigravityLocalUsageScanner
    ) async throws -> AntigravityLocalUsage {
        // Test-only: 让测试精确控制 worker 在做什么 (在 RPC / SQL / cache 写前
        // 阻塞等 cancel 触发). 生产环境 (release build) 没这个字段, 编译期消除.
        #if DEBUG
        if let gate = Self.testGate {
            await gate()
        }
        #endif
        // 整个 pipeline 在 AsyncMutex 里串行跑. 老的 worker 跑完 (包括
        // saveIndex) 才让新 worker 开始, 避免两个 worker 并发 loadIndex/saveIndex
        // 导致 cache revert.
        //
        // 关键: read lastCommittedGeneration + write to disk + update
        // lastCommittedGeneration 全部在 mutex 内部 (atomic). 旧 worker 即使
        // 晚到 mutex, 读到的也是新 worker 更新过的值, shouldSave=false 跳过
        // saveIndex, 磁盘保留新 worker 的 view. 跨 actor hop (`await scanner.read...`)
        // 在 mutex 内串行执行, 不会有 race.
        return try await Self.pipelineMutex.withLock {
            // hop 到主 actor 读 lastCommittedGeneration. AsyncMutex 持锁, 不会
            // 有别的 worker 在期间更新本实例 state (per-instance var).
            let lastCommitted = await scanner.readLastCommittedGeneration()
            let shouldSave = startedGeneration > lastCommitted
            let result = try await Self.performScanPureImpl(
                fetcher: fetcher,
                conversationsDirs: conversationsDirs,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now,
                shouldSave: shouldSave
            )
            if shouldSave {
                // 写盘成功 → 主 actor 更新本实例. 仍持有 mutex, 下一个 worker
                // 进来时 readLastCommittedGeneration 会看到本 worker 的值.
                await scanner.writeLastCommittedGeneration(startedGeneration)
            } else {
                logInfo("[antigravity-scan] 旧 generation (mine=\(startedGeneration), lastCommitted=\(lastCommitted)) 跳过 saveIndex, 保留新 worker 的 cache")
            }
            return result
        }
    }

    /// `performScanPure` 的纯 sync 实现. 不含 testGate / AsyncMutex wrap, 在 mutex
    /// 内部跑. 调用方负责保证"同时间只有一个 worker 调这个".
    /// - `shouldSave`: 旧 generation worker 传 false, 跳过 saveIndex 让新 worker
    ///   的 view 留在磁盘.
    nonisolated static func performScanPureImpl(
        fetcher: AntigravityFetcher,
        conversationsDirs: [URL],
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        shouldSave: Bool
    ) async throws -> AntigravityLocalUsage {
        try ensureCacheDirectoriesExist(cacheDir: cacheDir, fileManager: fileManager)

        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let listing = listDBFilesWithStatus(
            conversationsDirs: conversationsDirs,
            fileManager: fileManager
        )
        let dbFiles = listing.files

        // 1. 只有所有 conversations root 都成功枚举（或明确不存在），且每个候选
        //    文件的属性都成功读取时，才能把未出现的 session 判为已删除。权限/TCC/
        //    瞬时 I/O 错误时保留 last-good cache，避免一次失败清空历史。
        let cachedIds = Set(index.sessions.keys)
        let removedIds = confirmedRemovedSessionIDs(cachedIds: cachedIds, listing: listing)
        if !listing.isComplete {
            logWarn("[antigravity-scan] conversations 枚举不完整，保留所有未发现 session 的 last-good cache")
        }
        for removedId in removedIds {
            index.sessions.removeValue(forKey: removedId)
            index.dailyBySession.removeValue(forKey: removedId)
            index.samplesBySession?.removeValue(forKey: removedId)
        }

        // 2. 找出 dirty sessions（文件/WAL 指纹变化，或缺少纯 RPC 的逐次调用缓存）。
        let dirty: [(String, AntigravityDBFileInfo)] = dbFiles.compactMap { (sessionId, info) in
            guard let cached = index.sessions[sessionId] else {
                return (sessionId, info)
            }
            if index.samplesBySession?[sessionId] == nil {
                logDebug("[antigravity-scan] session=\(sessionId) 缺少逐次调用缓存，强制重扫")
                return (sessionId, info)
            }
            if cached.mtimeMs != info.mtimeMs
                || cached.sizeBytes != info.sizeBytes
                || cached.walMtimeMs != info.walMtimeMs
                || cached.walSizeBytes != info.walSizeBytes {
                return (sessionId, info)
            }

            return nil
        }

        // 3. 串行拉 dirty sessions
        var failedCount = 0
        let nowDate = now()
        if !dirty.isEmpty {
            let results = try await fetchAll(fetcher: fetcher, dirty: dirty)
            let dirtyByID = Dictionary(uniqueKeysWithValues: dirty.map { ($0.0, $0.1) })
            for (_, entry) in results.enumerated() {
                let sessionId = entry.0
                switch entry.1 {
                case .success(let events):
                    guard isTrustworthyRPCResult(events) else {
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        logWarn("[antigravity-scan] session=\(sessionId) RPC 返回空 events，保留 last-good cache 并于下次重试")
                        continue
                    }
                    let recoveredEvents = Self.recoverMissingTimestamps(
                        events,
                        fileInfo: dirtyByID[sessionId]
                    )
                    let inputTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.inputTokens))
                    let outputTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.outputTokens))
                    let cacheReadTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.cacheReadTokens))
                    logDebug("[antigravity-scan] session=\(sessionId) ✓ events=\(events.count) input=\(inputTotal) output=\(outputTotal) cacheR=\(cacheReadTotal)")

                    // F1: 只计算一次 turn/round 明细。aggregateDaily 通过预计算的 counts
                    // 写入 turns/rounds，samples 直接复用 details.samples；不得再把同一份
                    // counts 叠加进 newDaily（旧实现会造成 turns/rounds 双倍计数）。
                    let details = Self.computeTurnRoundDetails(
                        sessionID: sessionId,
                        events: recoveredEvents,
                        calendar: calendar
                    )
                    let newDaily = Self.aggregateDaily(
                        events: recoveredEvents,
                        calendar: calendar,
                        counts: details.counts
                    )
                    let newSamples = details.samples
                    logDebug("[antigravity-scan] session=\(sessionId) R/T: turns=\(details.counts.totalTurns) rounds=\(details.counts.totalRounds) days=\(details.counts.perDay.count)")

                    index.dailyBySession[sessionId] = newDaily
                    if index.dailyBySession[sessionId]?.isEmpty == true {
                        index.dailyBySession.removeValue(forKey: sessionId)
                    }
                    var samplesBySession = index.samplesBySession ?? [:]
                    samplesBySession[sessionId] = newSamples.filter {
                        $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60)
                    }
                    index.samplesBySession = samplesBySession

                    if let info = dirtyByID[sessionId] {
                        let eventStats = Self.accountedEventStats(recoveredEvents)
                        if eventStats.droppedTimestampless > 0 {
                            logWarn(
                                "[antigravity-scan] session=\(sessionId) 丢弃无 timestamp 的 usage event: "
                                    + "accounted=\(eventStats.accounted), dropped=\(eventStats.droppedTimestampless), raw=\(events.count)"
                            )
                        }
                        index.sessions[sessionId] = SessionIndexEntry(
                            mtimeMs: info.mtimeMs,
                            sizeBytes: info.sizeBytes,
                            walMtimeMs: info.walMtimeMs,
                            walSizeBytes: info.walSizeBytes,
                            fetchedAt: nowDate,
                            eventCount: eventStats.accounted
                        )
                    }
                case .failure(let error):
                    failedCount = SaturatingArithmetic.add(failedCount, 1)
                    logWarn("[antigravity-scan] session=\(sessionId) ✗ RPC 失败: \(error.localizedDescription)")
                }
            }
        }

        // 4. 写回 index (整个 performScanPure 在 AsyncMutex 里跑, 这里不需要再
        //    加锁; mutex 保证同时间只有一个 worker 在写 index.json).
        //    shouldSave=false (旧 generation) 跳过, 保留新 worker 的 cache.
        if shouldSave {
            index.lastScannedAt = nowDate
            try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        }

        // 5. 汇总全局 daily + 过滤最近 7 天
        let allDaily = Self.computeGlobalDaily(from: index.dailyBySession, calendar: calendar)
        let todayStart = Self.todayCutoff(now: nowDate, calendar: calendar)
        let today = allDaily.first(where: { $0.dayStart == todayStart })
        let recent7 = Self.filterLast7Days(
            allDaily: allDaily,
            today: todayStart,
            calendar: calendar
        )
        let recentSamples = (index.samplesBySession ?? [:])
            .values
            .flatMap { $0 }
            .filter { $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60) }
            .sorted { $0.completedAt < $1.completedAt }

        return AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: recent7,
            scannedAt: nowDate,
            // sessionCount 描述本次发现的本地 session，不应因首次 RPC 失败而少算。
            sessionCount: dbFiles.count,
            eventCount: SaturatingArithmetic.sum(index.sessions.values.lazy.map(\.eventCount)),
            failedSessionCount: failedCount,
            recentSamples: recentSamples
        )
    }

    /// 只有非空事件列表才足以更新成功指纹。空列表既可能是 RPC 暂时未准备好，
    /// 也可能来自错误的本地 server/workspace，必须保留旧缓存并重试。
    nonisolated static func isTrustworthyRPCResult(
        _ events: [AntigravityFetcher.UsageEvent]
    ) -> Bool {
        !events.isEmpty
    }

    /// 串行拉多个 session 的 metadata。
    /// `nonisolated static`：fetcher 通过参数传，不碰 self，可在 background 跑。
    nonisolated static func fetchAll(
        fetcher: AntigravityFetcher,
        dirty: [(String, AntigravityDBFileInfo)]
    ) async throws -> [(String, Result<[AntigravityFetcher.UsageEvent], Error>)] {
        logInfo("[antigravity-scan] dirty sessions: \(dirty.count) — \(dirty.prefix(5).map { $0.0 }.joined(separator: ", "))\(dirty.count > 5 ? "…" : "")")
        try Task.checkCancellation()
        // 进程/端口发现对整次扫描只做一次，所有 session 复用同一快照。
        let servers = fetcher.discoverMetadataServers()
        var results: [(String, Result<[AntigravityFetcher.UsageEvent], Error>)] = []
        results.reserveCapacity(dirty.count)
        for (sessionId, _) in dirty {
            try Task.checkCancellation()
            let result: Result<[AntigravityFetcher.UsageEvent], Error>
            do {
                let events = try await fetcher.getTrajectoryMetadata(
                    sessionId: sessionId,
                    servers: servers
                )
                result = .success(events)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = .failure(error)
            }
            results.append((sessionId, result))
        }
        return results
    }
}

// MARK: - Filesystem operations (off main actor)

/// `internal`（default）：被 `extension AntigravityLocalUsageScanner` 里的
/// `nonisolated static func fetchAll` 引用，必须 >= 函数的 access level。
struct AntigravityDBFileInfo: Sendable {
    let url: URL
    let sizeBytes: Int
    let mtimeMs: Double
    let walSizeBytes: Int
    let walMtimeMs: Double
    let format: SessionStoreFormat
}

/// 一次 conversations roots 枚举的结果。
///
/// `isComplete=false` 表示至少一个 root 或候选文件遇到权限/TCC/瞬时 I/O 错误；
/// 此时 `files` 仍可用于刷新已成功发现的 session，但不能据此删除缓存。
struct AntigravityDBFileListing: Sendable {
    let files: [String: AntigravityDBFileInfo]
    let isComplete: Bool
}

/// Antigravity IDE 把每个 cascade 存成本地文件，扩展名用于识别文件格式和
/// 决定是否检查 SQLite WAL 指纹。Token 数据仍只来自 RPC；SQLite 仅在 RPC
/// 缺少时间戳时读取匹配 step metadata 做回填：
///
/// - `.db`（SQLite）：旧版 + 新版 IDE 早期格式；读取文件/WAL 指纹，必要时读取时间 metadata。
/// - `.pb`（protobuf）：新版 IDE 近期格式；只读取文件指纹，不做 protobuf 解析。
///   两种格式都依赖 RPC 提供 Token、时间和 stepIndices，再推算 R/T。
enum SessionStoreFormat: String, Sendable {
    case sqlite        // .db
    case protobuf      // .pb

    /// 从文件扩展名推断格式。未知扩展名返回 nil。
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "db": self = .sqlite
        case "pb": self = .protobuf
        default: return nil
        }
    }
}

extension AntigravityLocalUsageScanner {
    /// Newer Antigravity responses can omit `createdAt` while still carrying
    /// `stepIndices`. For SQLite sessions, those indices identify the matching
    /// `step_type=15` rows whose metadata contains the authoritative timestamp.
    /// Token values remain sourced exclusively from the RPC response.
    nonisolated static func recoverMissingTimestamps(
        _ events: [AntigravityFetcher.UsageEvent],
        fileInfo: AntigravityDBFileInfo?
    ) -> [AntigravityFetcher.UsageEvent] {
        guard let fileInfo, fileInfo.format == .sqlite else { return events }
        let missingIndices = Set(
            events
                .filter { $0.timestamp == nil }
                .flatMap { $0.stepIndices ?? [] }
        )
        guard !missingIndices.isEmpty else { return events }

        let timestamps: [Int: Date]
        do {
            timestamps = try SQLiteTempCopy.read(
                dbPath: fileInfo.url,
                logTag: "[antigravity-scan] timestamp fallback"
            ) { dbPath in
                try AntigravityStepTimestampReader.timestamps(
                    dbPath: dbPath,
                    stepIndices: missingIndices
                )
            }
        } catch {
            logWarn("[antigravity-scan] timestamp fallback failed: \(error.localizedDescription)")
            return events
        }

        var recovered = 0
        let mapped = events.map { event in
            guard event.timestamp == nil,
                  let timestamp = (event.stepIndices ?? [])
                    .compactMap({ timestamps[$0] })
                    .min() else {
                return event
            }
            recovered = SaturatingArithmetic.add(recovered, 1)
            return event.withTimestamp(timestamp)
        }
        if recovered > 0 {
            logInfo("[antigravity-scan] timestamp fallback recovered \(recovered) events from SQLite step metadata")
        }
        return mapped
    }

    /// `nonisolated static`：file I/O 不碰 self，可在 background 跑。
    nonisolated static func ensureCacheDirectoriesExist(cacheDir: URL, fileManager: FileManagerBox) throws {
        try fileManager.createPrivateDirectory(at: cacheDir)
        // v3 以前曾额外写 `rpc-cache/v1/<session>/usage.jsonl|manifest.json`，但
        // 生产读取始终只使用 index.json。升级后主动清理这份重复的历史明细；
        // 删除失败不阻断扫描，下次扫描仍会继续尝试。
        let legacyRPCCache = cacheDir.appendingPathComponent("rpc-cache", isDirectory: true)
        if fileManager.fileExists(atPath: legacyRPCCache.path) {
            do {
                try fileManager.removeItem(at: legacyRPCCache)
                logInfo("[antigravity-scan] 已清理旧版未使用的 per-session RPC cache")
            } catch {
                logWarn("[antigravity-scan] 清理旧版 per-session RPC cache 失败，将于下次重试: \(error.localizedDescription)")
            }
        }
    }

    /// 列出 session 文件，并额外返回枚举是否完整。可注入目录/属性读取函数，
    /// 让测试稳定模拟 TCC、权限和瞬时 I/O 错误。
    nonisolated static func listDBFilesWithStatus(
        conversationsDirs: [URL],
        fileManager: FileManagerBox,
        directoryContents: ((URL) throws -> [URL])? = nil,
        resourceValues: ((URL) throws -> URLResourceValues)? = nil,
        fileAttributes: ((String) throws -> [FileAttributeKey: Any])? = nil
    ) -> AntigravityDBFileListing {
        var result: [String: AntigravityDBFileInfo] = [:]
        var isComplete = true
        for conversationsDir in conversationsDirs {
            // 用父目录名当 tag：antigravity-ide / antigravity，让日志能区分
            // "新 IDE 目录扫到多少 session" vs "旧 IDE 目录扫到多少"。
            let dirTag = conversationsDir.deletingLastPathComponent().lastPathComponent
            let entries: [URL]
            do {
                if let directoryContents {
                    entries = try directoryContents(conversationsDir)
                } else {
                    entries = try fileManager.contentsOfDirectory(
                        at: conversationsDir,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    )
                }
            } catch {
                if ScannerFileError.isExplicitlyMissing(error) {
                    logInfo("[antigravity-scan] list \(dirTag)/conversations/ — 目录明确不存在，按空目录处理")
                } else {
                    isComplete = false
                    logWarn("[antigravity-scan] list \(dirTag)/conversations/ — 枚举失败，保留 last-good cache: \(error.localizedDescription)")
                }
                continue
            }

            var accepted: [URL] = []
            var perFmt: [String: Int] = [:]
            for url in entries {
                guard let format = SessionStoreFormat(fileExtension: url.pathExtension) else { continue }
                perFmt[format.rawValue] = SaturatingArithmetic.add(
                    perFmt[format.rawValue, default: 0],
                    1
                )
                accepted.append(url)
            }
            logInfo("[antigravity-scan] list \(dirTag)/conversations/ — \(entries.count) 文件, accepted \(accepted.count) (\(perFmt.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")))")

            for url in accepted {
                guard let format = SessionStoreFormat(fileExtension: url.pathExtension) else { continue }
                let sessionId = url.deletingPathExtension().lastPathComponent
                guard !sessionId.isEmpty else { continue }
                // 同 sessionId 只接受第一个出现（新 IDE 目录在前优先）
                guard result[sessionId] == nil else { continue }
                let values: URLResourceValues
                do {
                    if let resourceValues {
                        values = try resourceValues(url)
                    } else {
                        values = try url.resourceValues(
                            forKeys: [.fileSizeKey, .contentModificationDateKey]
                        )
                    }
                } catch {
                    isComplete = false
                    logWarn("[antigravity-scan] session=\(sessionId) 属性读取失败，保留 last-good cache: \(error.localizedDescription)")
                    continue
                }
                guard let size = values.fileSize, let mtime = values.contentModificationDate else {
                    isComplete = false
                    logWarn("[antigravity-scan] session=\(sessionId) 缺少 size/mtime 属性，保留 last-good cache")
                    continue
                }
                let walAttributes: [FileAttributeKey: Any]?
                if format == .sqlite {
                    do {
                        if let fileAttributes {
                            walAttributes = try fileAttributes(url.path + "-wal")
                        } else {
                            walAttributes = try fileManager.attributesOfItem(
                                atPath: url.path + "-wal"
                            )
                        }
                    } catch {
                        if ScannerFileError.isExplicitlyMissing(error) {
                            walAttributes = nil
                        } else {
                            isComplete = false
                            logWarn("[antigravity-scan] session=\(sessionId) WAL 属性读取失败，保留 last-good cache: \(error.localizedDescription)")
                            continue
                        }
                    }
                } else {
                    walAttributes = nil
                }
                let walSize = (walAttributes?[.size] as? NSNumber)?.intValue ?? 0
                let walMtime = (walAttributes?[.modificationDate] as? Date) ?? .distantPast
                result[sessionId] = AntigravityDBFileInfo(
                    url: url,
                    sizeBytes: size,
                    mtimeMs: mtime.timeIntervalSince1970 * 1000,
                    walSizeBytes: walSize,
                    walMtimeMs: walAttributes == nil ? 0 : walMtime.timeIntervalSince1970 * 1000,
                    format: format
                )
            }
        }
        return AntigravityDBFileListing(files: result, isComplete: isComplete)
    }

    /// 枚举完整时，未出现的缓存 session 才能被确认删除。
    nonisolated static func confirmedRemovedSessionIDs(
        cachedIds: Set<String>,
        listing: AntigravityDBFileListing
    ) -> Set<String> {
        guard listing.isComplete else { return [] }
        return cachedIds.subtracting(listing.files.keys)
    }

    // MARK: Index I/O

    nonisolated static func loadIndex(cacheDir: URL, fileManager: FileManagerBox) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 6,
            empty: .empty,
            version: { $0.version },
            migrate: { idx in
                guard (2...5).contains(idx.version) else { return false }
                idx.version = 6
                // v5 及更早版本的 per-session samples / daily R/T 可能来自
                // 旧版本的 samples / R/T 结果可能来自 SQLite 读取路径。纯 RPC
                // 版本的 stepIndices 推断结果不能与旧结果混用；清空逐次调用索引，使每个现有 session 都因
                // samplesBySession?[sessionId] == nil 而强制重新走 RPC。
                // dailyBySession 保留为 RPC 失败时的 last-good fallback。
                idx.samplesBySession = [:]
                return true
            },
            logTag: "[antigravity-scan]"
        )
    }

    nonisolated static func saveIndex(_ index: CacheIndex, cacheDir: URL, fileManager: FileManagerBox) throws {
        #if DEBUG
        Self.testSaveIndexHook?()
        #endif
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动时恢复 index 中的 last-good local usage；后续 scan 仍会校验 session 指纹。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> AntigravityLocalUsage? {
        do {
            let index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
            guard !index.sessions.isEmpty, index.lastScannedAt.timeIntervalSince1970 > 0 else {
                return nil
            }
            let allDaily = computeGlobalDaily(from: index.dailyBySession, calendar: calendar)
            let todayStart = todayCutoff(now: now, calendar: calendar)
            let recent7 = filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
            let samples = (index.samplesBySession ?? [:]).values
                .flatMap { $0 }
                .filter { $0.completedAt >= now.addingTimeInterval(-8 * 24 * 60 * 60) }
                .sorted { $0.completedAt < $1.completedAt }
            return AntigravityLocalUsage(
                today: allDaily.first(where: { $0.dayStart == todayStart }),
                dailyTokenUsage: recent7,
                scannedAt: index.lastScannedAt,
                sessionCount: index.sessions.count,
                eventCount: SaturatingArithmetic.sum(index.sessions.values.lazy.map(\.eventCount)),
                failedSessionCount: 0,
                recentSamples: samples
            )
        } catch {
            logWarn("[antigravity-scan] 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }
}
