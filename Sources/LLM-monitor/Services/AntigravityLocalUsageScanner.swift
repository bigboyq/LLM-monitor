import Foundation
import Combine
import os.log

/// 扫描 `~/.gemini/antigravity/conversations/`，对每个脏 session 用
/// `AntigravitySessionDBReader` 直读 `.db`（SQLite）内容：`probe` 版本指纹门 →
/// `readCalls`（gen_metadata ↔ steps 连接命中的逐调用 token/模型/时间戳）+
/// `readUserTurnSteps`（step_type=14 用户轮次边界），聚合后写入正式的
/// `index.json` daily cache。
///
/// 阶段二b（2026-11-08）起**本地 RPC / 进程发现 / `.pb` 支持全部退役**：
/// scanner 不依赖 Antigravity 进程运行、不发任何网络请求，也不做混合/回退。
///
/// ## 优化重点
///
/// 1. **fingerprint-based diff**：每次扫描先 stat 所有 session 文件及其 WAL，
///    跟 `index.json` 里的文件/WAL `mtimeMs` / `sizeBytes` 对比；未变化的
///    session 不开库，只有 changed sessions 才直读。
/// 2. **per-session daily 缓存**：aggregated daily 数据按 session 维度存
///    在 `index.dailyBySession`；changed session 只替换自己的缓存贡献，
///    全局汇总继续复用未变化 session 的缓存。
/// 3. **in-flight dedup**：`scan()` 调用时如果上一次还在跑，请求合并进
///    待执行槽位（更强模式优先），由 `LocalUsageScannerBase` 提供。
/// 4. **bounded 并发直读**：脏 session 以固定小批量并发读库，控制
///    SQLiteTempCopy 副本内存峰值；本地 db 毫秒级，全量重读便宜且确定
///    （脏了就全量重读，不再维护 offset/suffix/打击状态机）。
/// 5. **失败有界（两路收敛语义）**：读失败按错误类别区分——
///    - **probe 结构化不兼容**（表缺失/空表/乱数据/无模型名/非 SQLite 文件，
///      `.incompatible`）：由字节内容决定、同字节重探结果恒定，当轮采纳当前
///      文件指纹收敛（下轮不再重读同一份字节），保留 last-good daily/samples；
///    - **可重试故障**（SQLite 打开/拷贝/查询 I/O 类，`.retryable`）：**不采纳
///      指纹**，下一轮自然重试——瞬时 I/O 故障（如撤销 db 读权限再恢复，
///      mtime/size 不变）恢复后即可读回，不会把会话钉在漏计状态；连续
///      `retryableReadFailureConvergenceLimit`（3）次可重试失败后按不兼容
///      同款策略采纳指纹有界收敛，防永久故障把同一份字节变成每轮重读、
///      failedSessionCount 永远钉在 ≥1（freshness 永不 fresh）。
///    两条路径都记一次失败 + log、本轮继续扫其余，都绝不清空 last-good，
///    文件再变化时自然重新入账。
/// 6. **failure 不更新入账**：读失败的 session 保留 last-good 数据，
///    不产生「假成功」的历史清空。
@MainActor
final class AntigravityLocalUsageScanner: LocalUsageScannerBase<AntigravityLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[antigravity-scan]"

    /// 整个 `performScanPure` pipeline 串行化。cancel+rescan 时两个 worker
    /// 会 race cache 写（新 worker 读到旧 disk 状态，算完写入 = 回滚新 worker
    /// 的 view）。用 async-aware 的 AsyncMutex 串行整个 pipeline。
    nonisolated static let pipelineMutex = AsyncMutex()

    /// 默认扫描目录：`Antigravity.app` 的数据目录
    /// `~/.gemini/antigravity/`（`--app_data_dir antigravity`）。
    ///
    /// `Antigravity IDE.app` 的 `~/.gemini/antigravity-ide/` 曾被同时扫描，
    /// 现已剥离，不再支持。目录列表保留数组形态，作为测试注入多个 root 的接缝。
    nonisolated static let defaultConversationsDirs: [URL] = {
        let gemini = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
        return [
            gemini
                .appendingPathComponent("antigravity", isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
        ]
    }()

    nonisolated static let defaultCacheDir: URL =
        TokenMonitorPaths.cacheFile(for: .antigravity)

    private let conversationsDirs: [URL]
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// 最近一次成功写入 index.json 的 generation. 旧 worker 即使晚到 mutex,
    /// `startedGeneration > self.lastCommittedGeneration` 才写盘, 否则 saveIndex
    /// 跳过保留新 worker 的 view. read + write 都在 `performScanPure` 内部, 跨
    /// `@MainActor` 边界 hop (AsyncMutex 持锁期间, 不会跟其他 worker 交叉).
    /// 每个 scanner 实例独立, 跨实例不共享.
    @MainActor private var lastCommittedGeneration: UInt64 = 0

    /// Test-only hook: `performScanPure` 入口会 `await` 这个闭包, 闭包默认 nil
    /// (生产零开销, 一个 nil-check). 测试可以注入一个 `TestGate.wait()`, 让
    /// worker 在 db 读取 / cache 写前阻塞, 精确控制 cancel + rescan 时序.
    ///
    /// `#if DEBUG`: 隔离到 debug build, release build 的 binary 没有这个字段
    /// (避免生产代码带可变的非隔离测试状态). 测试 target 默认用 debug 编译
    /// (`DEBUG` defined), 可以正常访问.
    #if DEBUG
    nonisolated(unsafe) static var testGate: (@Sendable () async -> Void)?
    /// Test-only observer for deterministic cache-write assertions.
    /// Per-instance rather than static so parallel XCTest cases cannot observe
    /// or overwrite one another's cache-write counter.
    nonisolated(unsafe) var testSaveIndexHook: (@Sendable () -> Void)?
    #endif

    init(conversationsDirs: [URL] = AntigravityLocalUsageScanner.defaultConversationsDirs,
         cacheDir: URL = AntigravityLocalUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.conversationsDirs = conversationsDirs
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        super.init(
            logTag: Self.scanLogTag,
            cachedResult: Self.loadCachedResult(
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: Date()
            )
        )
        configureSourceLifecycle(
            paths: conversationsDirs,
            dynamicExtensions: ["db", "db-wal"]
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

    /// performScanPure 的 pipeline：mutex 串行 + lastCommittedGeneration 守门。
    /// 重 I/O（文件元数据、目录遍历、SQLite 直读、缓存读写）全部在 background
    /// 执行，菜单栏 UI 不会被阻塞；scanner 不发任何网络请求。
    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> AntigravityLocalUsage {
        let conversationsDirs = self.conversationsDirs
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        // Startup `.full` is a cache-assisted validation pass: unchanged
        // sessions reuse antigravity.json and changed sessions are re-read
        // from their `.db`. Only the settings-page action asks for a true
        // full rebuild.
        let forceFull = mode.bypassesProviderCache
        return {
            try await Self.performScanPure(
                conversationsDirs: conversationsDirs,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now,
                startedGeneration: startedGeneration,
                scanner: self,
                forceFull: forceFull
            )
        }
    }

    override nonisolated func scanResultIsComplete(_ result: AntigravityLocalUsage) -> Bool {
        result.failedSessionCount == 0
    }

}

// MARK: - Pipeline（off main actor）

extension AntigravityLocalUsageScanner {
    /// 纯计算 + I/O + db 直读，不直接修改 self；由非 actor-isolated runner 执行。
    /// 所有依赖通过参数传，不依赖 @MainActor 隔离。失败抛错给外层 catch。
    ///
    /// 并发安全: 整个 pipeline 在 `Self.pipelineMutex` (AsyncMutex) 里串行执行.
    /// 多个 worker cancel+rescan 时, 旧 worker 跑完整个 pipeline 才让新 worker
    /// 开始. 同时 `lastCommittedGeneration` 守门防止旧 worker 的 saveIndex 回滚
    /// 新 worker 已写入的 cache (旧 worker 即使晚到 mutex, 也会跳过 saveIndex).
    /// runScan 端的 generation 守门 (startedGeneration == latestGeneration) 负责
    /// 旧 worker 的 in-memory result 不污染新 worker 状态.
    nonisolated static func performScanPure(
        conversationsDirs: [URL],
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        startedGeneration: UInt64,
        scanner: AntigravityLocalUsageScanner,
        forceFull: Bool = false
    ) async throws -> AntigravityLocalUsage {
        // Test-only: 让测试精确控制 worker 在做什么 (在 db 读 / cache 写前
        // 阻塞等 cancel 触发). 生产环境 (release build) 没这个字段, 编译期消除.
        #if DEBUG
        if let gate = Self.testGate {
            await gate()
        }
        let saveIndexHook = scanner.testSaveIndexHook
        #else
        let saveIndexHook: (@Sendable () -> Void)? = nil
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
                conversationsDirs: conversationsDirs,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now,
                shouldSave: shouldSave,
                saveIndexHook: saveIndexHook,
                forceFull: forceFull
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
        conversationsDirs: [URL],
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        shouldSave: Bool,
        saveIndexHook: (@Sendable () -> Void)? = nil,
        forceFull: Bool = false,
        directoryContents: ((URL) throws -> [URL])? = nil
    ) async throws -> AntigravityLocalUsage {
        try ensureCacheDirectoriesExist(cacheDir: cacheDir, fileManager: fileManager)

        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let currentCalendarSignature = LocalUsageCalendarSignature.make(calendar)
        let calendarChanged = index.calendarSignature != currentCalendarSignature
        let requiresColdRebuild = forceFull || calendarChanged
        if calendarChanged {
            logInfo("[antigravity-scan] calendar signature changed，所有可读 session 重新建立日桶")
        }
        let listing = listDBFilesWithStatus(
            conversationsDirs: conversationsDirs,
            fileManager: fileManager,
            directoryContents: directoryContents
        )
        let dbFiles = listing.files

        // 1. 只有所有 conversations root 都成功枚举（或明确不存在），且每个候选
        //    文件的属性都成功读取时，才能把未出现的 session 判为已删除。权限/TCC/
        //    瞬时 I/O 错误时保留 last-good cache，避免一次失败清空历史。
        let cachedIds = trackedSessionIDs(in: index)
        let removedIds = confirmedRemovedSessionIDs(cachedIds: cachedIds, listing: listing)
        if !listing.isComplete {
            logWarn("[antigravity-scan] conversations 枚举不完整，保留所有未发现 session 的 last-good cache")
        }
        for removedId in removedIds {
            index.sessions.removeValue(forKey: removedId)
            index.dailyBySession.removeValue(forKey: removedId)
            index.samplesBySession?.removeValue(forKey: removedId)
        }

        // Antigravity can leave a placeholder cascade at 0 bytes. Its mtime
        // may still move during IDE housekeeping, but there is nothing to
        // read until the file grows. Heal both existing and newly discovered
        // placeholders locally, including during startup full mode.
        for (sessionID, info) in dbFiles {
            guard info.sizeBytes == 0, info.walSizeBytes == 0 else { continue }
            if var cached = index.sessions[sessionID],
               cached.sizeBytes == 0,
               cached.walSizeBytes == 0,
               cached.eventCount == 0 {
                guard cached.mtimeMs != info.mtimeMs || cached.walMtimeMs != info.walMtimeMs else {
                    continue
                }
                cached.mtimeMs = info.mtimeMs
                cached.sizeBytes = info.sizeBytes
                cached.walMtimeMs = info.walMtimeMs
                cached.walSizeBytes = info.walSizeBytes
                cached.fetchedAt = now()
                index.sessions[sessionID] = cached
            } else if index.sessions[sessionID] == nil {
                index.sessions[sessionID] = SessionIndexEntry(
                    mtimeMs: info.mtimeMs,
                    sizeBytes: info.sizeBytes,
                    walMtimeMs: info.walMtimeMs,
                    walSizeBytes: info.walSizeBytes,
                    fetchedAt: now(),
                    eventCount: 0
                )
            } else {
                continue
            }
            index.dailyBySession.removeValue(forKey: sessionID)
            index.samplesBySession?[sessionID] = []
            logDebug("[antigravity-scan] session=\(sessionID) 空 placeholder 仅更新 fingerprint，跳过读取")
        }

        // 2. 找出 dirty sessions（文件/WAL 指纹变化，或缺少缓存条目/样本）。
        let nowDate = now()
        let dirtyPlans: [DirtySessionPlan] = dbFiles.compactMap { (sessionId, info) in
            guard info.sizeBytes > 0 || info.walSizeBytes > 0 else { return nil }
            guard !requiresColdRebuild, let cached = index.sessions[sessionId] else {
                return DirtySessionPlan(sessionID: sessionId, fileInfo: info)
            }
            if index.samplesBySession?[sessionId] == nil {
                logDebug("[antigravity-scan] session=\(sessionId) 缺少逐次调用缓存，强制重读")
                return DirtySessionPlan(sessionID: sessionId, fileInfo: info)
            }
            // 可重试读失败的有界收敛：失败 streak 未达上限的 session 保持 dirty
            // 重试。首读即失败的新 session 已写当前指纹、指纹比对不可能命中，
            // 重试完全由这个条件驱动；指纹未采纳的 session 反正也会命中下面的
            // 指纹差异条件（streak 条件只是提前短路，语义等价）。
            if let failures = cached.consecutiveReadFailures,
               failures > 0,
               failures < Self.retryableReadFailureConvergenceLimit {
                logDebug("[antigravity-scan] session=\(sessionId) 可重试读取失败 streak=\(failures)，重试直读")
                return DirtySessionPlan(sessionID: sessionId, fileInfo: info)
            }
            if cached.mtimeMs != info.mtimeMs
                || cached.sizeBytes != info.sizeBytes
                || cached.walMtimeMs != info.walMtimeMs
                || cached.walSizeBytes != info.walSizeBytes {
                // 本地直读便宜且确定性：脏了就全量重读，不做 suffix/offset 增量。
                return DirtySessionPlan(sessionID: sessionId, fileInfo: info)
            }

            return nil
        }

        // 3. 有界并发直读 dirty sessions（SQLiteTempCopy 的 /tmp 副本随文件大小
        //    占内存，小批量归约控制峰值；本地读毫秒级，批间串行足够快）。
        // An incomplete root/file enumeration is retryable work even when all
        // visible session reads succeed. Otherwise a calendar rebuild could
        // advance its signature while silently omitting cached sessions.
        var failedCount = listing.isComplete ? 0 : 1
        if !dirtyPlans.isEmpty {
            for batchStart in stride(from: 0, to: dirtyPlans.count, by: Self.readBatchSize) {
                let batchEnd = min(batchStart + Self.readBatchSize, dirtyPlans.count)
                let batch = Array(dirtyPlans[batchStart..<batchEnd])
                let results = try await readAll(plans: batch)
                let infoByID = Dictionary(uniqueKeysWithValues: batch.map { ($0.sessionID, $0.fileInfo) })
                for entry in results {
                    let sessionId = entry.sessionID
                    guard let info = infoByID[sessionId] else { continue }
                    switch entry.result {
                    case .failure(let error):
                        // 读失败按错误类别二分（两路都记一次失败、保留 last-good、
                        // 绝不清空用户可见历史）：
                        // - 结构化不兼容：同字节重探结果恒定 → 当轮采纳指纹收敛；
                        // - 可重试 I/O 故障：不采纳指纹、下一轮自然重试（瞬时故障
                        //   恢复后即读回）；连续 retryableReadFailureConvergenceLimit
                        //   次失败后有界收敛，防永久故障把失败钉成常态。
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        let cached = index.sessions[sessionId]
                        switch error.kind {
                        case .incompatible:
                            Self.convergeWithCurrentFingerprint(
                                sessionId: sessionId,
                                info: info,
                                cachedEventCount: cached?.eventCount ?? 0,
                                index: &index,
                                now: nowDate
                            )
                            logWarn("[antigravity-scan] session=\(sessionId) ✗ 读取失败(不兼容): \(error.message)；本轮计一次失败，采纳当前指纹并保留 last-good 缓存（eventCount=\(cached?.eventCount ?? 0)）")
                        case .retryable:
                            let priorFailures = cached?.consecutiveReadFailures ?? 0
                            if priorFailures + 1 >= Self.retryableReadFailureConvergenceLimit {
                                // 有界收敛：连续 3 次可重试失败按不兼容同款策略
                                // 采纳指纹（保留 last-good、计数清零——收敛后下个
                                // 脏周期重新计数），文件再变化时自然重新入账。
                                Self.convergeWithCurrentFingerprint(
                                    sessionId: sessionId,
                                    info: info,
                                    cachedEventCount: cached?.eventCount ?? 0,
                                    index: &index,
                                    now: nowDate
                                )
                                logWarn("[antigravity-scan] session=\(sessionId) ✗ 连续 \(priorFailures + 1) 次可重试读取失败: \(error.message)；按有界收敛采纳当前指纹并保留 last-good 缓存（eventCount=\(cached?.eventCount ?? 0)）")
                            } else {
                                // 低于收敛上限：保留脏状态重试。条目处理——
                                // - 已有条目：原样保留旧指纹与 last-good（下轮指纹
                                //   不匹配保持 dirty），仅递增连续失败计数；
                                // - 无条目（首读即失败的新 session）：写当前指纹 +
                                //   计数，靠计数驱动下轮重试（见 dirtyPlans 的
                                //   streak 条件）——否则永久故障的新 session 会在
                                //   无缓存分支每轮重读、计数永无机会累计。
                                var healed = cached ?? SessionIndexEntry(
                                    mtimeMs: info.mtimeMs,
                                    sizeBytes: info.sizeBytes,
                                    walMtimeMs: info.walMtimeMs,
                                    walSizeBytes: info.walSizeBytes,
                                    fetchedAt: nowDate,
                                    eventCount: 0
                                )
                                healed.consecutiveReadFailures = priorFailures + 1
                                index.sessions[sessionId] = healed
                                if index.samplesBySession?[sessionId] == nil {
                                    var samplesBySession = index.samplesBySession ?? [:]
                                    samplesBySession[sessionId] = []
                                    index.samplesBySession = samplesBySession
                                }
                                logWarn("[antigravity-scan] session=\(sessionId) ✗ 读取失败(可重试 #\(priorFailures + 1)): \(error.message)；本轮计一次失败，保留脏状态下一轮重试")
                            }
                        }
                    case .success(let payload):
                        if payload.calls.isEmpty {
                            // 没有连接命中的调用：可能是 0 事件的旧会话，也可能
                            // 是版本指纹通过但数据被清空。照常写空缓存并采纳指
                            // 纹——本地读确定性，重读同一份字节结果不变。
                            logDebug("[antigravity-scan] session=\(sessionId) ✓ 无连接命中的调用（calls=0，turns=\(payload.turnStepIndexes.count)）")
                        }
                        let accounting = Self.accountCalls(
                            sessionID: sessionId,
                            calls: payload.calls,
                            turnStepIndexes: payload.turnStepIndexes,
                            calendar: calendar
                        )
                        if accounting.droppedTimestamplessCount > 0 {
                            logWarn(
                                "[antigravity-scan] session=\(sessionId) 丢弃无 timestamp 的调用: "
                                    + "accounted=\(accounting.accountedEventCount), dropped=\(accounting.droppedTimestamplessCount), calls=\(payload.calls.count)"
                            )
                        }
                        logDebug("[antigravity-scan] session=\(sessionId) ✓ 直读 calls=\(payload.calls.count) (accounted=\(accounting.accountedEventCount), turns=\(accounting.counts.totalTurns), rounds=\(accounting.counts.totalRounds))")

                        index.dailyBySession[sessionId] = accounting.daily
                        if index.dailyBySession[sessionId]?.isEmpty == true {
                            index.dailyBySession.removeValue(forKey: sessionId)
                        }
                        var samplesBySession = index.samplesBySession ?? [:]
                        samplesBySession[sessionId] = accounting.samples.filter {
                            $0.completedAt >= nowDate.addingTimeInterval(-LocalUsageRetentionWindow.seconds)
                        }
                        index.samplesBySession = samplesBySession

                        index.sessions[sessionId] = SessionIndexEntry(
                            mtimeMs: info.mtimeMs,
                            sizeBytes: info.sizeBytes,
                            walMtimeMs: info.walMtimeMs,
                            walSizeBytes: info.walSizeBytes,
                            fetchedAt: nowDate,
                            eventCount: accounting.accountedEventCount
                        )
                    }
                }
            }
        }

        // 4. 写回 index (整个 performScanPure 在 AsyncMutex 里跑, 这里不需要再
        //    加锁; mutex 保证同时间只有一个 worker 在写 index.json).
        //    shouldSave=false (旧 generation) 跳过, 保留新 worker 的 cache.
        if shouldSave {
            index.lastScannedAt = nowDate
            // 签名保持 all-or-nothing：唯一阻塞源是**枚举不完整**（那代表本轮
            // 可能漏扫 session）。读失败的 session 走两路有界收敛（结构化不兼容
            // 当轮采纳指纹；可重试 I/O 故障连续 3 次后采纳指纹），收敛后下轮
            // 指纹已匹配不再重读，失败状态因此不阻塞签名——否则一个永久不兼容
            // 的 session 会让失败永远钉住、每轮都因 calendarChanged 冷重建全部
            // session、失败 session 每轮重读，正是已退役的打击状态机要切断的
            // 循环。
            if listing.isComplete {
                index.calendarSignature = currentCalendarSignature
            }
            // 落盘前裁掉严格早于 8 天窗口的日桶（消费面只有 today/7 天窗口，
            // eventCount 独立于日桶），防止 index.json 随历史 session 无界增长。
            Self.pruneStaleDailyBuckets(index: &index, now: nowDate)
            try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager, hook: saveIndexHook)
        }

        // 5. 组装 AntigravityLocalUsage（只算自然日已入账的 tokens）
        let allDaily = computeGlobalDaily(from: index.dailyBySession, calendar: calendar)
        let todayStart = DailyUsageAggregation.todayCutoff(now: nowDate, calendar: calendar)
        let recent7 = filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
        let recentSamples = (index.samplesBySession ?? [:]).values
            .flatMap { $0 }
            .filter { $0.completedAt >= nowDate.addingTimeInterval(-LocalUsageRetentionWindow.seconds) }
            .sorted { $0.completedAt < $1.completedAt }
        return AntigravityLocalUsage(
            today: allDaily.first(where: { $0.dayStart == todayStart }),
            dailyTokenUsage: recent7,
            scannedAt: nowDate,
            // sessionCount 描述本次发现的本地 session，不应因首次读取失败而少算。
            sessionCount: dbFiles.count,
            eventCount: SaturatingArithmetic.sum(index.sessions.values.lazy.map(\.eventCount)),
            failedSessionCount: failedCount,
            recentSamples: recentSamples
        )
    }

    /// 每批并发直读的 session 数：SQLiteTempCopy 的 /tmp 副本按文件大小占内存，
    /// 小批量归约控制峰值（本地读毫秒级，批间串行不构成瓶颈）。
    nonisolated static let readBatchSize = 4

    /// 可重试读失败的**有界收敛**上限：同一 session 连续 N 次 SQLite I/O 类失败
    /// （权限、锁、EIO 等）后按结构化不兼容同款策略采纳当前指纹收敛并保留
    /// last-good。瞬时故障（如撤销 db 读权限再恢复，mtime/size 不变）在下一轮
    /// 自然重试、不丢数据；永久故障最多拖 N 轮即收敛——失败轮数有界，同一份
    /// 字节不会被每轮重读，`failedSessionCount` 也不会永远钉在 ≥1。
    nonisolated static let retryableReadFailureConvergenceLimit = 3

    /// 写回 index 前裁剪 `dailyBySession` 中严格早于 8 天窗口的日期桶（与
    /// samples 的 `-LocalUsageRetentionWindow.seconds` 谓词同式，按桶的
    /// `dayStart` 比较）。
    /// 日桶只有 today / 最近 7 天两个消费出口（`computeGlobalDaily` → today +
    /// `filterLast7Days`），session 级 `eventCount` 独立保存在 `sessions` 条目
    /// 里，因此旧桶删除不影响任何用户可见数字，只防止长期使用后 index.json
    /// 无界增长。全桶被裁的 session 条目一并移除。
    nonisolated static func pruneStaleDailyBuckets(
        index: inout CacheIndex,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-LocalUsageRetentionWindow.seconds)
        var removedBuckets = 0
        var removedSessions = 0
        for (sessionID, byDay) in index.dailyBySession {
            var kept: [String: AntigravityDailyUsage] = [:]
            kept.reserveCapacity(byDay.count)
            for (dayKey, usage) in byDay where usage.dayStart >= cutoff {
                kept[dayKey] = usage
            }
            removedBuckets += byDay.count - kept.count
            if kept.isEmpty {
                index.dailyBySession.removeValue(forKey: sessionID)
                removedSessions += 1
            } else if kept.count != byDay.count {
                index.dailyBySession[sessionID] = kept
            }
        }
        if removedBuckets > 0 || removedSessions > 0 {
            logInfo(
                "[antigravity-scan] 已裁剪 \(removedBuckets) 个超过 8 天窗口的日桶"
                    + "（清空 \(removedSessions) 个 session 的日桶缓存）"
            )
        }
    }

    struct DirtySessionPlan: Sendable {
        let sessionID: String
        let fileInfo: AntigravityDBFileInfo
    }

    /// 单个脏 session 的直读载荷。
    struct DirtySessionPayload: Sendable {
        /// `AntigravitySessionDBReader.readCalls`：连接命中的逐调用事件
        /// （gen idx 升序 = 时间序）。
        let calls: [AntigravitySessionDBReader.Call]
        /// `step_type=14`（用户轮次边界）行的 idx 升序数组。
        let turnStepIndexes: [Int]
    }

    /// 单次 session 直读失败的类别，决定失败轮的收敛策略（见
    /// `performScanPureImpl` 的 `.failure` 分支与类注释「失败有界」）。
    enum ReadFailureKind: Sendable {
        /// probe 结构化不兼容（gen_metadata 表缺失/空表/乱数据/无模型名/非
        /// SQLite 文件）：同字节重探结果恒定 → 当轮采纳文件指纹收敛。
        case incompatible
        /// 可重试故障（SQLite 打开/拷贝/查询 I/O 类）：同字节下一轮可能读成功
        /// → 不采纳指纹自然重试，连续 `retryableReadFailureConvergenceLimit`
        /// 次失败后有界收敛。
        case retryable
    }

    private struct DirtySessionReadError: Error, Sendable {
        let kind: ReadFailureKind
        let message: String
    }

    private struct DirtySessionReadResult: Sendable {
        let index: Int
        let sessionID: String
        let result: Result<DirtySessionPayload, DirtySessionReadError>
    }

    /// 单个 session 的完整直读：probe 版本指纹门 → readCalls + readUserTurnSteps。
    /// 全部经 `SQLiteTempCopy`（原路径 READONLY + CANTOPEN/BUSY 时 /tmp 副本兜底）。
    private nonisolated static func readSessionPayload(
        dbPath: URL
    ) throws -> DirtySessionPayload {
        switch try AntigravitySessionDBReader.probe(dbPath: dbPath) {
        case .viable:
            break
        case .incompatible(let reason):
            throw DirtySessionReadError(kind: .incompatible, message: "版本指纹不兼容（\(reason)）")
        case .retryable(let reason):
            throw DirtySessionReadError(kind: .retryable, message: "probe 读取失败（\(reason)）")
        }
        do {
            let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbPath)
            let turns = try AntigravitySessionDBReader.readUserTurnSteps(dbPath: dbPath)
            return DirtySessionPayload(calls: calls, turnStepIndexes: turns.map(\.idx))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // probe 门通过后 readCalls / readUserTurnSteps 的抛错只剩 SQLite
            // 打开/拷贝/查询 I/O 类（结构化数据问题已被 probe 拦截）→ 全部
            // 视为可重试；CancellationToken 原样上抛，绝不伪装成读失败。
            throw DirtySessionReadError(kind: .retryable, message: error.localizedDescription)
        }
    }

    /// 失败轮的指纹收敛（结构化不兼容当轮 / 可重试达到上限轮共用）：采纳当前
    /// 文件指纹（下一轮不再重读同一份字节），保留 last-good daily/samples/
    /// eventCount，并补写空 samples 占位（避免「缺缓存」分支反复触发重读）。
    /// 新条目的 `consecutiveReadFailures` 为 nil——收敛即清零，下个脏周期
    /// 重新计数。
    private nonisolated static func convergeWithCurrentFingerprint(
        sessionId: String,
        info: AntigravityDBFileInfo,
        cachedEventCount: Int,
        index: inout CacheIndex,
        now: Date
    ) {
        index.sessions[sessionId] = SessionIndexEntry(
            mtimeMs: info.mtimeMs,
            sizeBytes: info.sizeBytes,
            walMtimeMs: info.walMtimeMs,
            walSizeBytes: info.walSizeBytes,
            fetchedAt: now,
            eventCount: cachedEventCount
        )
        if index.samplesBySession?[sessionId] == nil {
            var samplesBySession = index.samplesBySession ?? [:]
            samplesBySession[sessionId] = []
            index.samplesBySession = samplesBySession
        }
    }

    /// 以固定并发度直读多个 session。`nonisolated static`：无 self 依赖，
    /// 可在 background 跑；取消沿 task group 传播。
    private nonisolated static func readAll(
        plans: [DirtySessionPlan]
    ) async throws -> [DirtySessionReadResult] {
        let planTags = plans.prefix(5).map { "\($0.sessionID)(full)" }.joined(separator: ", ")
        logInfo("[antigravity-scan] dirty sessions: \(plans.count) — \(planTags)\(plans.count > 5 ? "…" : "")")
        try Task.checkCancellation()

        let concurrency = min(Self.readBatchSize, max(plans.count, 1))
        var nextIndex = 0
        var results: [DirtySessionReadResult] = []
        results.reserveCapacity(plans.count)

        return try await withThrowingTaskGroup(of: DirtySessionReadResult.self) { group in
            for _ in 0..<concurrency {
                guard nextIndex < plans.count else { break }
                addReadTask(to: &group, index: nextIndex, plans: plans)
                nextIndex += 1
            }

            while let result = try await group.next() {
                results.append(result)
                guard nextIndex < plans.count else { continue }
                addReadTask(to: &group, index: nextIndex, plans: plans)
                nextIndex += 1
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private nonisolated static func addReadTask(
        to group: inout ThrowingTaskGroup<DirtySessionReadResult, Error>,
        index: Int,
        plans: [DirtySessionPlan]
    ) {
        let plan = plans[index]
        let sessionID = plan.sessionID
        let dbPath = plan.fileInfo.url

        group.addTask {
            try Task.checkCancellation()
            do {
                let payload = try readSessionPayload(dbPath: dbPath)
                return DirtySessionReadResult(
                    index: index,
                    sessionID: sessionID,
                    result: .success(payload)
                )
            } catch let readError as DirtySessionReadError {
                // readSessionPayload 已把一切失败包成带类别的 DirtySessionReadError，
                // 原样透传——不得在此重包成 retryable（会把结构化不兼容误分类）。
                return DirtySessionReadResult(
                    index: index,
                    sessionID: sessionID,
                    result: .failure(readError)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 理论到不了这里，万一到达按可重试兜底（保守默认，有界收敛封顶）。
                return DirtySessionReadResult(
                    index: index,
                    sessionID: sessionID,
                    result: .failure(DirtySessionReadError(kind: .retryable, message: error.localizedDescription))
                )
            }
        }
    }
}
