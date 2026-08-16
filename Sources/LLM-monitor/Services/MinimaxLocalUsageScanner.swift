import Foundation
import Combine
import os.log

/// 扫描 minimax v2 的本地数据库：
/// - `~/.minimax/v2/sqlite/runtime-state.sqlite`（热路径，活跃 session 实时写入）
///   — 唯一支持、唯一扫描的数据源
///
/// ## 为什么 v2 是唯一主动源
///
/// v2 是当前活跃 session 实时写入的目标，包含 token 账本。旧版主 db 不再支持，
/// 因此不会参与路径探测、扫描、聚合或缓存。
///
/// ## 优化重点（跟 AntigravityLocalUsageScanner 同构）
///
/// 1. **db + WAL fingerprint diff**：每次扫描先 stat v2 `.db` 及对应
///    `.db-wal`，跟 cache v12 `index.json` 里的 db/WAL `mtimeMs` /
///    `sizeBytes` 对比；只有任一维度变化的 source 才走 SQL 聚合。
/// 2. **per-source daily 缓存**：aggregated daily 数据按 `runtime` source 维度存
///    在 `index.dailyBySource`（不是 per-session，因为 minimax 的
///    `local_runtime_token_usage` 表
///    没有 session 级别的 project 概念）。保留 per-source 结构以兼容现有 cache schema。
/// 3. **in-flight dedup**：`scan()` 调用时如果上一次还在跑，直接忽略。
/// 4. **serial SQL**：扫描单一 v2 数据库；copy 策略已经把 .db 读到 /tmp
///    隔离 runtime 锁。
/// 5. **失败不重试**：aggregate 单次尝试，失败就 logInfo 放弃。
///    期望下次外部 triggerMinimaxLocalUsageScan 调用（来自 minimax 主 quota
///    refresh timer，默认 60s）会再跑一次，runtime 通常那时已经暂停写。
/// 6. **failure 不更新 mtime**：SQL 失败的 source 在 `index.sources` 里
///    mtime 保持不变，下次扫描会自然重试，不留"假成功"状态。
/// 7. **数据覆盖保护**：先建 newDaily 再覆盖旧 index 时判
///    `if rtSucceeded || index.dailyBySource[source] == nil`（antigravity
///    1cb2e2e 修过的"成功数据被失败数据吞"bug）。
/// 8. **stat 失败保留 last-good**：只有明确 ENOENT / NSFileNoSuchFile 才清理
///    source cache；权限、瞬时 I/O 等元数据读取错误计入 degraded，并保留旧
///    `sources` / `dailyBySource` 供 UI 展示，下次扫描继续重试。
///
/// ## 跟 AntigravityLocalUsageScanner 的关键区别
///
/// - **不需要 RPC**：antigravity 要走 `GetCascadeTrajectoryGeneratorMetadata` RPC
///   拉 token 用量，minimax 的 `local_runtime_token_usage` 表**直接 SQL 聚合**就有完整账单。
///   零跨源 join，零 RPC 顺序漂移坑。
/// - **不需要 .db SQLite step_type 查询**：antigravity 要从 `step_type=14/15`
///   算 R/T（坑 8 跨源 join 间歇性空白），minimax 的 `turn_id` 字段在
///   `local_runtime_token_usage` 里，SQL 一次 `COUNT(DISTINCT turn_id)` 算完。
/// - **不删 -shm**：跟 antigravity 一样 copy `.db`+`.db-wal`+`.db-shm` 到 /tmp 副本上 read。
@MainActor
final class MinimaxLocalUsageScanner: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: MinimaxLocalUsage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    /// v2 runtime-state db 路径（热路径，活跃 session）— 唯一支持、唯一扫描的源
    nonisolated static let defaultRuntimeDBURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".minimax", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("runtime-state.sqlite")
    }()

    /// cache 目录，跟 antigravity 的 `~/.gemini/antigravity/.token-monitor/` 对齐
    nonisolated static let defaultCacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".minimax", isDirectory: true)
            .appendingPathComponent(".token-monitor", isDirectory: true)
    }()

    private let runtimeDBURL: URL
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
    /// worker 在 SQL / RPC 前阻塞, 精确控制 cancel + rescan 时序 (而不是依赖
    /// "扫描瞬间完成" 的间接验证, 那个测的是 '启动时 generation 已变' 分支, 不是
    /// 真正在压力下的 cancel 路径).
    ///
    /// `#if DEBUG`: 隔离到 debug build, release build 的 binary 没有这个字段
    /// (避免生产代码带可变的非隔离测试状态). 测试 target 默认用 debug 编译
    /// (`DEBUG` defined), 可以正常访问.
    #if DEBUG
    nonisolated(unsafe) static var testGate: (@Sendable () async -> Void)?
    /// Test-only observer for deterministic cache-write assertions.
    nonisolated(unsafe) static var testSaveIndexHook: (@Sendable () -> Void)?
    #endif

    init(runtimeDBURL: URL = MinimaxLocalUsageScanner.defaultRuntimeDBURL,
         cacheDir: URL = MinimaxLocalUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.runtimeDBURL = runtimeDBURL
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
        defer {
            // 关键: 只在当前 generation 仍是 latest 时清 isScanning / inFlightTask.
            // 避免 cancel + rescan 期间, 旧 gen=1 的 defer 把 isScanning 设 false
            // 但 gen=3 还在跑, UI 闪一下 '不在扫描' 然后 gen=3 又设回 true.
            // 同时避免旧任务的 defer 抢着清掉新任务的 inFlightTask 引用.
            if startedGeneration == self.latestGeneration {
                self.isScanning = false
                self.inFlightTask = nil
            } else {
                logInfo("[minimax-scan] 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(self.latestGeneration)")
            }
        }
        // 重 I/O 全部在 background 执行（SQL 聚合、文件遍历、缓存读写）。
        // 这是用 @MainActor class 的关键：scanner 实例的 @Published 状态
        // 只在主线程被改；performScanPure 是 nonisolated static 不碰 self。
        //
        // 先把所有依赖复制到本地变量，再交给非 actor-isolated runner 执行，
        // 避免重 I/O 占用 MainActor。
        let runtimeDBURL = self.runtimeDBURL
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        // cancel + rescan 期间，Task 取消会沿当前任务传播；AsyncMutex 仍保证
        // pipeline/cache 写串行。generation 和 lastCommittedGeneration 是第二层
        // 守门，防止已经越过取消检查的旧 worker 回写状态或磁盘。
        let work: @Sendable () async throws -> MinimaxLocalUsage = {
            try await Self.performScanPure(
                runtimeDBURL: runtimeDBURL,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now,
                startedGeneration: startedGeneration,
                scanner: self
            )
        }
        let applyResult: @MainActor (MinimaxLocalUsage) -> Void = { result in
            self.lastResult = result
            self.lastError = nil
        }
        let applyError: @MainActor (String) -> Void = { message in
            // 失败时保留上次的 lastResult（如果之前有），UI 不闪空白
            self.lastError = message
        }
        await LocalUsageScanRunner.run(
            logTag: "[minimax-scan]",
            startedGeneration: startedGeneration,
            latestGeneration: { self.latestGeneration },
            work: work,
            applyResult: applyResult,
            applyError: applyError
        )
    }

    /// 纯计算 + I/O，不直接修改 self；由非 actor-isolated runner 执行。
    /// 所有依赖都通过参数传，不依赖 @MainActor 隔离。失败抛错给外层 catch。
    ///
    /// 并发安全: 整个 pipeline 在 `Self.pipelineMutex` (AsyncMutex) 里串行执行.
    /// 多个 worker cancel+rescan 时, 旧 worker 跑完整个 pipeline 才让新 worker
    /// 开始. 同时 `lastCommittedGeneration` 守门防止旧 worker 的 saveIndex 回滚
    /// 新 worker 已写入的 cache (旧 worker 即使晚到 mutex, 也会跳过 saveIndex).
    /// runScan 端的 generation 守门 (startedGeneration == latestGeneration) 负责
    /// 旧 worker 的 in-memory result 不污染新 worker 状态.
    nonisolated static func performScanPure(
        runtimeDBURL: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        startedGeneration: UInt64,
        scanner: MinimaxLocalUsageScanner
    ) async throws -> MinimaxLocalUsage {
        // Test-only: 让测试精确控制 worker 在做什么 (在 SQL / cache 写前阻塞等
        // cancel 触发). 生产环境 (release build) 没这个字段, 编译期消除.
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
            let result = try Self.performScanPureImpl(
                runtimeDBURL: runtimeDBURL,
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
                logInfo("[minimax-scan] 旧 generation (mine=\(startedGeneration), lastCommitted=\(lastCommitted)) 跳过 saveIndex, 保留新 worker 的 cache")
            }
            return result
        }
    }

    /// performScanPure 的纯 sync 实现. 不含 testGate hook, 大部分路径走这里.
    /// - `shouldSave`: 旧 generation worker 传 false, 跳过 saveIndex 让新 worker
    ///   的 view 留在磁盘. 走完 SQL/RPC 是浪费但无害 (in-memory result 被 runScan
    ///   的 generation 守门扔掉).
    nonisolated static func performScanPureImpl(
        runtimeDBURL: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        shouldSave: Bool
    ) throws -> MinimaxLocalUsage {
        try Self.ensureCacheDirectoriesExist(cacheDir: cacheDir, fileManager: fileManager)

        var index = try Self.loadIndex(cacheDir: cacheDir, fileManager: fileManager)

        let sources: [(key: String, path: URL)] = [
            ("runtime", runtimeDBURL)
        ]
        var currentSourceInfo: [String: MinimaxDBFileInfo] = [:]
        var explicitlyMissingKeys: Set<String> = []
        var statFailedKeys: Set<String> = []
        for (key, url) in sources {
            switch Self.statDBFile(url, fileManager: fileManager) {
            case .available(let info):
                currentSourceInfo[key] = info
            case .missing:
                explicitlyMissingKeys.insert(key)
                logInfo("[minimax-scan] source=\(key) db 明确不存在: \(url.path)")
            case .unreadable(let message):
                statFailedKeys.insert(key)
                logWarn("[minimax-scan] source=\(key) stat 失败，保留 last-good 并下次重试: \(message)")
            }
        }

        let currentIds = Set(currentSourceInfo.keys)
        let cachedIds = Set(index.sources.keys)
            .union(index.dailyBySource.keys)
            .union(index.samplesBySource?.keys ?? Dictionary<String, [LocalTokenUsageSample]>().keys)
        let removedIds = cachedIds.intersection(explicitlyMissingKeys)
        for removedId in removedIds {
            logInfo("[minimax-scan] source=\(removedId) 消失，清理 cache")
            index.sources.removeValue(forKey: removedId)
            index.dailyBySource.removeValue(forKey: removedId)
            index.samplesBySource?.removeValue(forKey: removedId)
        }

        var dirty: [(key: String, info: MinimaxDBFileInfo)] = []
        for (key, info) in currentSourceInfo {
            if let cached = index.sources[key] {
                if index.samplesBySource?[key] == nil {
                    logInfo("[minimax-scan] source=\(key) 缺少逐次调用缓存，强制重扫")
                    dirty.append((key, info))
                } else if Self.isSourceDirty(cached: cached, current: info) {
                    logInfo("[minimax-scan] source=\(key) dirty (db mtime \(cached.mtimeMs)→\(info.mtimeMs), size \(cached.sizeBytes)→\(info.sizeBytes), wal mtime \(cached.walMtimeMs)→\(info.walMtimeMs), size \(cached.walSizeBytes)→\(info.walSizeBytes))")
                    dirty.append((key, info))
                }
            } else {
                logInfo("[minimax-scan] source=\(key) new (not in cache)")
                dirty.append((key, info))
            }
        }

        // 3. 扫 dirty sources
        var failedKeys = statFailedKeys
        for (key, info) in dirty {
            logInfo("[minimax-scan] scanning source=\(key) size=\(info.sizeBytes) mtimeMs=\(Int(info.mtimeMs)) walSize=\(info.walSizeBytes) walMtimeMs=\(Int(info.walMtimeMs))")
            do {
                let aggregate = try Self.aggregateFromDB(
                    dbPath: info.url,
                    calendar: calendar,
                    sampleCutoff: now().addingTimeInterval(-8 * 24 * 60 * 60)
                )

                // 字符分摊 outputTokens → reasoningTokens。raw.reasoning 永远 0 时
                // 走字符分摊路径；未来 > 0 时直接用账单。详见 MinimaxDailyUsage 注释。
                //
                // P1-1 sanity check (v2 only): v2 字符聚合是 per-day 聚合(不 join
                // token_usage),v2 message_rows.turn_id 100% NULL 无法 per-turn
                // 配对。如果 message 行数 >> token 行数(>2x),v2 runtime 早期 token
                // 写入不完整(7/11 实测 3.17x),字符聚合会偏(分母过大稀释 reason)。
                //
                // 修法: 比较真实 message 行数 vs token 行数(不是字符/rounds — 单位
                // 不一致会让正常数据也 warn)。仅对 runtime 检查。异常时**跳过当天
                // 的字符分摊**(per-day 把 chars 移除,scanner 自然走"无字符数据"
                // 路径,reason=0 输出)。recent days (7/14+) 实测对齐 1.0x,正常。
                let safeChars = Self.filterUnsafeV2CharCounts(
                    aggregate: aggregate
                )
                let adjustedPerDay = Self.applyReasoningSplit(
                    perDay: aggregate.perDay,
                    perDayChars: safeChars
                )

                var newDaily: [String: MinimaxDailyUsage] = [:]
                for (day, usage) in adjustedPerDay {
                    newDaily[LocalUsageDayKey.make(day, calendar: calendar)] = usage
                }

                index.dailyBySource[key] = newDaily
                var samplesBySource = index.samplesBySource ?? [:]
                samplesBySource[key] = Self.applyReasoningSplit(
                    samples: aggregate.samples,
                    rawPerDay: aggregate.perDay,
                    adjustedPerDay: adjustedPerDay,
                    calendar: calendar
                )
                index.samplesBySource = samplesBySource
                index.sources[key] = SourceIndexEntry(
                    mtimeMs: info.mtimeMs,
                    sizeBytes: info.sizeBytes,
                    walMtimeMs: info.walMtimeMs,
                    walSizeBytes: info.walSizeBytes,
                    scannedAt: now(),
                    eventCount: aggregate.eventCount,
                    sessionCount: aggregate.sessionCount
                )
                logInfo("[minimax-scan] source=\(key) ✓ events=\(aggregate.eventCount) sessions=\(aggregate.sessionCount) days=\(aggregate.perDay.count) charSplitDays=\(aggregate.perDayChars.count)")
            } catch {
                failedKeys.insert(key)
                logInfo("[minimax-scan] source=\(key) ✗ aggregate 失败 (下次 scan 再试): \(error)")
            }
        }

        // 4. 写回 index (整个 performScanPure 在 AsyncMutex 里跑, 这里不需要再
        //    加锁; mutex 保证同时间只有一个 worker 在写 index.json).
        //    shouldSave=false (旧 generation) 跳过, 保留新 worker 的 cache.
        if shouldSave {
            index.lastScannedAt = now()
            try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        }

        // 5. 合并 daily
        let allDaily = Self.computeGlobalDaily(from: index.dailyBySource, calendar: calendar)

        // 6. 算 today + 最近 7 天
        let nowDate = now()
        let todayStart = Self.todayCutoff(now: nowDate, calendar: calendar)
        let today = allDaily.first(where: { $0.dayStart == todayStart })
        let recent7 = Self.filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
        let recentSamples = (index.samplesBySource ?? [:])
            .values
            .flatMap { $0 }
            .filter { $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60) }
            .sorted { $0.completedAt < $1.completedAt }

        // 7. 算总数 + 失败 source 数（set union 处理 overlap）
        let totalSessions = SaturatingArithmetic.sum(
            index.sources.values.lazy.map(\.sessionCount)
        )
        let totalEvents = SaturatingArithmetic.sum(
            index.sources.values.lazy.map(\.eventCount)
        )
        // unreadable source 仍然存在于本轮业务视图，只是 degraded；missing source
        // 已被移除，不应算失败。
        let currentSourceKeys = currentIds.union(statFailedKeys)
        let cachedSourceKeys = Set(index.sources.keys)
        let failedCount = Self.computeFailedSessionCount(
            failedKeys: failedKeys,
            currentSourceKeys: currentSourceKeys,
            cachedSourceKeys: cachedSourceKeys
        )

        return MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: recent7,
            scannedAt: nowDate,
            sessionCount: totalSessions,
            eventCount: totalEvents,
            failedSessionCount: failedCount,
            recentSamples: recentSamples
        )
    }
}
// MARK: - Cache + index types

extension MinimaxLocalUsageScanner {
    /// failedSessionCount 计算：
    /// 失败 source = (a) 本次扫描失败 ∪ (b) 首次扫描仍没 cache 的 source。
    /// 用 set union 避免一个首次失败的 source 被算 2 次。
    /// 抽成 static 方便测试（不需要构造完整 scanner + 写临时 db）。
    /// `nonisolated`：纯 set 操作，不依赖 main actor，测试可在 XCTestCase sync context 直接调。
    nonisolated static func computeFailedSessionCount(
        failedKeys: Set<String>,
        currentSourceKeys: Set<String>,
        cachedSourceKeys: Set<String>
    ) -> Int {
        let neverScannedKeys = currentSourceKeys.subtracting(cachedSourceKeys)
        return failedKeys.union(neverScannedKeys).count
    }

    /// db 与 WAL 的完整文件指纹比较。WAL mtime 单独参与判断，确保 WAL
    /// 内容更新但复用相同文件大小时仍会触发扫描。
    nonisolated static func isSourceDirty(
        cached: SourceIndexEntry,
        current: MinimaxDBFileInfo
    ) -> Bool {
        cached.mtimeMs != current.mtimeMs
            || cached.sizeBytes != current.sizeBytes
            || cached.walMtimeMs != current.walMtimeMs
            || cached.walSizeBytes != current.walSizeBytes
    }

    struct SourceIndexEntry: Equatable, Codable, Sendable {
        var mtimeMs: Double
        var sizeBytes: Int
        /// `.db-wal` mtime。与 size 一起检测同尺寸 WAL 的内容更新。
        var walMtimeMs: Double
        /// `.db-wal` size。跟 `MinimaxDBFileInfo.walSizeBytes` 对齐。
        /// 字段缺失或 cache 版本不匹配时会重置并全量重建，避免不完整
        /// 指纹静默绕过 WAL 更新检查。
        var walSizeBytes: Int
        var scannedAt: Date?
        var eventCount: Int
        var sessionCount: Int
    }

    /// 顶层 index 状态，存到 `~/.minimax/.token-monitor/index.json`。
    /// - `sources`：v2 runtime .db → 它的 mtime/size + 上次聚合时间
    /// - `dailyBySource`：每个 source 按本地自然日拆开的 token 聚合
    ///   （让 changed source 只需要换它自己的 daily 集合，不用 merge 其他 source）
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var lastScannedAt: Date
        var sources: [String: SourceIndexEntry]
        var dailyBySource: [String: [String: MinimaxDailyUsage]]
        var samplesBySource: [String: [LocalTokenUsageSample]]?

        static let empty = CacheIndex(
            version: 14, // v14 重新规范化 inputTokens 为 uncached + cached
            lastScannedAt: Date(timeIntervalSince1970: 0),
            sources: [:],
            dailyBySource: [:],
            samplesBySource: [:]
        )
    }
}

// MARK: - DB file I/O

/// Per-source .db file metadata（db/WAL 的 mtime + size + path），scanner 用来做 diff。
/// `internal`（default）：跟 `AntigravityDBFileInfo` 对齐——同形态 type 用同 access level。
///
/// **加入 WAL 指纹的原因**：minimax v2 runtime 用 SQLite WAL 模式，
/// 写新数据到 `runtime-state.sqlite-wal` 但**不立刻 checkpoint** 写回 `.db`。
/// 实测 minimax runtime 36+ 小时不 flush（mtime/size 完全不动），scanner 的
/// mtime/size diff 在这期间永远不标 dirty，新数据永远不进来。
/// 因此同时比较 WAL mtime 和 size；WAL reset 后即使复用相同容量，内容更新
/// 仍会触发扫描。
struct MinimaxDBFileInfo: Sendable {
    let url: URL
    let sizeBytes: Int
    let mtimeMs: Double
    /// `.db-wal` 修改时间（找不到或 stat 失败时 = 0）。
    let walMtimeMs: Double
    /// `.db-wal` 文件 size（找不到或 stat 失败时 = 0）。用于检测 WAL 模式下的
    /// lazy write —— mtime/size 没动但 WAL 涨了的情况。
    let walSizeBytes: Int
}

private enum MinimaxDBStatResult {
    case available(MinimaxDBFileInfo)
    case missing
    case unreadable(String)
}

private extension MinimaxLocalUsageScanner {
    /// `nonisolated static`：file stat 不碰 self，可在 background 跑。
    ///
    /// 同时 stat `.db` 和 `.db-wal`。只有明确不存在才返回 `.missing`；
    /// 权限或瞬时 I/O 错误返回 `.unreadable`，调用方必须保留 last-good cache。
    /// WAL 明确不存在用零指纹；WAL stat 失败则整个 source 视为 unreadable，
    /// 避免把“读不到”误判成“WAL 已删除”并基于不完整快照提交新缓存。
    nonisolated static func statDBFile(
        _ url: URL,
        fileManager: FileManagerBox
    ) -> MinimaxDBStatResult {
        let dbAttributes: [FileAttributeKey: Any]
        do {
            dbAttributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                return .missing
            }
            return .unreadable("\(url.path): \(error.localizedDescription)")
        }
        guard let sizeNumber = dbAttributes[.size] as? NSNumber,
              let mtime = dbAttributes[.modificationDate] as? Date else {
            return .unreadable("\(url.path): stat 未返回 size/mtime")
        }

        // WAL fingerprint: `dbPath + "-wal"` 同时读取 mtime + size。
        let walPath = url.path + "-wal"
        let walFingerprint: (mtimeMs: Double, sizeBytes: Int)
        do {
            let walAttributes = try fileManager.attributesOfItem(atPath: walPath)
            guard let walSizeNumber = walAttributes[.size] as? NSNumber,
                  let walMtime = walAttributes[.modificationDate] as? Date else {
                return .unreadable("\(walPath): stat 未返回 size/mtime")
            }
            walFingerprint = (
                walMtime.timeIntervalSince1970 * 1000,
                max(0, walSizeNumber.intValue)
            )
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                walFingerprint = (0, 0)
            } else {
                return .unreadable("\(walPath): \(error.localizedDescription)")
            }
        }
        return .available(MinimaxDBFileInfo(
            url: url,
            sizeBytes: max(0, sizeNumber.intValue),
            mtimeMs: mtime.timeIntervalSince1970 * 1000,
            walMtimeMs: walFingerprint.mtimeMs,
            walSizeBytes: walFingerprint.sizeBytes
        ))
    }

}

// MARK: - Index I/O

extension MinimaxLocalUsageScanner {
    /// `nonisolated static`：不依赖 self，background 安全。
    nonisolated static func ensureCacheDirectoriesExist(cacheDir: URL, fileManager: FileManagerBox) throws {
        try fileManager.createPrivateDirectory(at: cacheDir)
    }

    nonisolated static func loadIndex(cacheDir: URL, fileManager: FileManagerBox) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 14,
            empty: .empty,
            version: { $0.version },
            logTag: "[minimax-scan]"
        )
    }

    nonisolated static func saveIndex(_ index: CacheIndex, cacheDir: URL, fileManager: FileManagerBox) throws {
        #if DEBUG
        Self.testSaveIndexHook?()
        #endif
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动先展示上次成功扫描的 local usage；随后正常 scan 会校验指纹并更新它。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> MinimaxLocalUsage? {
        do {
            let index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
            guard !index.sources.isEmpty, index.lastScannedAt.timeIntervalSince1970 > 0 else {
                return nil
            }
            let allDaily = computeGlobalDaily(from: index.dailyBySource, calendar: calendar)
            let todayStart = todayCutoff(now: now, calendar: calendar)
            let recent7 = filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
            let samples = (index.samplesBySource ?? [:]).values
                .flatMap { $0 }
                .filter { $0.completedAt >= now.addingTimeInterval(-8 * 24 * 60 * 60) }
                .sorted { $0.completedAt < $1.completedAt }
            return MinimaxLocalUsage(
                today: allDaily.first(where: { $0.dayStart == todayStart }),
                dailyTokenUsage: recent7,
                scannedAt: index.lastScannedAt,
                sessionCount: SaturatingArithmetic.sum(index.sources.values.lazy.map(\.sessionCount)),
                eventCount: SaturatingArithmetic.sum(index.sources.values.lazy.map(\.eventCount)),
                failedSessionCount: 0,
                recentSamples: samples
            )
        } catch {
            logWarn("[minimax-scan] 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - DB read strategy (fast path + copy fallback)

extension MinimaxLocalUsageScanner {
    /// 读一个 .db → per-day aggregate。
    ///
    /// 直接 read 原 .db；CANTOPEN / BUSY 时 copy 到 /tmp 副本 read。详见 `SQLiteTempCopy`。
    nonisolated static func aggregateFromDB(
        dbPath: URL,
        calendar: Calendar,
        sampleCutoff: Date? = nil
    ) throws -> MinimaxDBAggregate {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: "[minimax-scan]") { url in
            let reader = try MinimaxDBReader(path: url, readOnly: url.path == dbPath.path)
            defer { reader.close() }
            return try reader.aggregate(
                calendar: calendar,
                sampleCutoff: sampleCutoff
            )
        }
    }
}
