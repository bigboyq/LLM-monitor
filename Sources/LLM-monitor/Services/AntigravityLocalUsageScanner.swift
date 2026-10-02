import Foundation
import Combine
import os.log

/// 扫描 `~/.gemini/antigravity/conversations/`，只读取本地
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
/// 4. **bounded RPC**：dirty session 以固定并发度拉 RPC，避免单个 session 阻塞整批，
///    同时不给本地 language server 制造无界请求洪峰。本地 session 文件只用于发现和
///    指纹比较，不参与内容解析。
/// 5. **失败有界重试**：RPC 失败或返回空事件时保留 last-good cache，
///    由下一次 Provider batch settle 后、source 仍 dirty 时的 reconcile 重试。
///    重试是有界的：连续空 suffix 2 次后升级 offset=0 全量核验并可按成功
///    收敛推进指纹；零 metadata 全量结果 3 轮打击后收敛（保留 last-good）；
///    有 raw metadata 但零可计账 event 的全量页同样 3 轮打击后收敛
///    （保留 last-good，offset 刻意不推进，文件再变化时用可能已修复的
///    解析器重试）。收敛不计失败，calendar 签名因此可以在全部 session
///    成功/收敛后推进。
/// 6. **failure 不更新 mtime**：RPC 失败的 session 在 `index.sessions` 里
///    mtime 保持不变，下次扫描会自然重试，不留"假成功"状态。
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
    ///
    /// 同时也接受两种 session 文件格式：`.db` 和 `.pb`。
    /// 两者都只用于文件发现与指纹比较，Token 和 Turn/Round 均走本地 RPC。
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

    private let fetcher: AntigravityFetcher
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
    /// Per-instance rather than static so parallel XCTest cases cannot observe
    /// or overwrite one another's cache-write counter.
    nonisolated(unsafe) var testSaveIndexHook: (@Sendable () -> Void)?
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
            dynamicExtensions: ["db", "db-wal", "pb"]
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
    /// 重 I/O + RPC 全部在 background 执行（文件元数据、文件遍历、HTTP RPC、
    /// 缓存读写），菜单栏 UI 不会被 I/O 阻塞。
    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> AntigravityLocalUsage {
        let fetcher = self.fetcher
        let conversationsDirs = self.conversationsDirs
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        // Startup `.full` is a cache-assisted validation pass: unchanged
        // sessions reuse antigravity.json and changed append-only sessions
        // use their persisted offset. Only the settings-page action asks
        // for a true RPC rebuild.
        let forceFull = mode.bypassesProviderCache
        return {
            try await Self.performScanPure(
                fetcher: fetcher,
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

private struct DirtySessionFetchError: Error, Sendable {
    let message: String

    var localizedDescription: String { message }
}

private enum DirtySessionFetchPayload: Sendable {
    case events(
        events: [AntigravityFetcher.UsageEvent],
        metadataEntryCount: Int,
        wasIncremental: Bool
    )
    /// An incremental suffix returned no metadata. Keep the session dirty and
    /// retry with backoff; a transiently stale language server must not be
    /// turned into a successful fingerprint update.
    case emptyIncremental
}

private struct DirtySessionFetchResult: Sendable {
    let index: Int
    let sessionID: String
    let result: Result<DirtySessionFetchPayload, DirtySessionFetchError>
}

// Cache/index 类型（SessionIndexEntry / CacheIndex）见 AntigravityLocalUsageCache.swift

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
        scanner: AntigravityLocalUsageScanner,
        forceFull: Bool = false
    ) async throws -> AntigravityLocalUsage {
        // Test-only: 让测试精确控制 worker 在做什么 (在 RPC / SQL / cache 写前
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
                fetcher: fetcher,
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

    /// Test-only RPC 替身（仅 `performScanPureImpl` 的注入接缝）：非 nil 时替代
    /// 真实的 `GetCascadeTrajectoryGeneratorMetadata` 网络请求，参数为
    /// `(sessionID, offset)`，返回该页解析出的 events 与 raw metadata 条数。
    /// offset=0 即全量/核验请求。生产路径恒传 nil，零开销。
    typealias TrajectoryMetadataFetch = @Sendable (
        _ sessionID: String,
        _ offset: Int
    ) async throws -> (events: [AntigravityFetcher.UsageEvent], metadataEntryCount: Int)

    /// `performScanPure` 的纯 sync 实现. 不含 testGate / AsyncMutex wrap, 在 mutex
    /// 内部跑. 调用方负责保证"同时间只有一个 worker 调这个".
    /// - `shouldSave`: 旧 generation worker 传 false, 跳过 saveIndex 让新 worker
    ///   的 view 留在磁盘.
    /// - `metadataFetch`: 仅测试用的 RPC 替身，见 `TrajectoryMetadataFetch`。
    nonisolated static func performScanPureImpl(
        fetcher: AntigravityFetcher,
        conversationsDirs: [URL],
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        shouldSave: Bool,
        saveIndexHook: (@Sendable () -> Void)? = nil,
        forceFull: Bool = false,
        directoryContents: ((URL) throws -> [URL])? = nil,
        metadataFetch: TrajectoryMetadataFetch? = nil
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
        // 用「被跟踪的 sessionId」而不是只有 `sessions.keys`：全新 session 首轮就
        // 返回 0 条 metadata 时，打击计数先于 `sessions` 条目落盘（`continue`
        // 发生在建条目之前）。若只按 `sessions.keys` 判定删除，这类 id 永远进不了
        // removedIds，打击计数永久残留在 index.json；同 sessionId 复活时从残留值
        // 续算，1~2 轮即提前收敛成「空终结条目」，静默丢弃该指纹周期的数据。
        let cachedIds = trackedSessionIDs(in: index)
        let removedIds = confirmedRemovedSessionIDs(cachedIds: cachedIds, listing: listing)
        if !listing.isComplete {
            logWarn("[antigravity-scan] conversations 枚举不完整，保留所有未发现 session 的 last-good cache")
        }
        for removedId in removedIds {
            index.sessions.removeValue(forKey: removedId)
            index.dailyBySession.removeValue(forKey: removedId)
            index.samplesBySession?.removeValue(forKey: removedId)
            index.emptyFullStrikesBySession?.removeValue(forKey: removedId)
            index.partialHitWarnedBySession?.removeValue(forKey: removedId)
            Self.clearZeroAccountedFullStrikes(for: removedId, on: &index)
            Self.clearOffsetRegressionStrikes(for: removedId, on: &index)
            Self.clearCalendarRebuildPending(for: removedId, on: &index)
        }

        // Antigravity can leave a placeholder cascade at 0 bytes. Its mtime
        // may still move during IDE housekeeping, but there is no metadata to
        // fetch until the file grows. Heal both existing and newly discovered
        // placeholders locally, including during startup full mode.
        for (sessionID, info) in dbFiles {
            guard info.sizeBytes == 0, info.walSizeBytes == 0 else { continue }
            if var cached = index.sessions[sessionID],
               cached.sizeBytes == 0,
               cached.walSizeBytes == 0,
               cached.eventCount == 0,
               cached.generatorMetadataOffset == 0 {
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
                    eventCount: 0,
                    generatorMetadataOffset: 0
                )
            } else {
                continue
            }
            index.dailyBySession.removeValue(forKey: sessionID)
            index.samplesBySession?[sessionID] = []
            logDebug("[antigravity-scan] session=\(sessionID) 空 placeholder 仅更新 fingerprint，跳过 RPC")
        }

        // 2. 找出 dirty sessions（文件/WAL 指纹变化，或缺少纯 RPC 的逐次调用缓存）。
        let nowDate = now()
        let dirtyPlans: [DirtySessionPlan] = dbFiles.compactMap { (sessionId, info) in
            guard info.sizeBytes > 0 || info.walSizeBytes > 0 else { return nil }
            guard !requiresColdRebuild, let cached = index.sessions[sessionId] else {
                return DirtySessionPlan(
                    sessionID: sessionId,
                    fileInfo: info,
                    requestedOffset: 0,
                    isIncremental: false
                )
            }
            if index.samplesBySession?[sessionId] == nil {
                logDebug("[antigravity-scan] session=\(sessionId) 缺少逐次调用缓存，强制重扫")
                return DirtySessionPlan(
                    sessionID: sessionId,
                    fileInfo: info,
                    requestedOffset: 0,
                    isIncremental: false
                )
            }
            if cached.mtimeMs != info.mtimeMs
                || cached.sizeBytes != info.sizeBytes
                || cached.walMtimeMs != info.walMtimeMs
                || cached.walSizeBytes != info.walSizeBytes {
                // 带旧日历待重建标记的 session 文件重新活跃：排一次 offset=0
                // full 按当前日历重建日桶（替代增量合并，避免新旧日历混桶）。
                // 标记保留到该 full 成功替换日桶后再清除，重扫失败不丢失待办。
                if index.calendarRebuildPendingSessions?.contains(sessionId) == true {
                    return DirtySessionPlan(
                        sessionID: sessionId,
                        fileInfo: info,
                        requestedOffset: 0,
                        isIncremental: false
                    )
                }
                if info.sizeBytes < cached.sizeBytes
                    || info.walSizeBytes < cached.walSizeBytes
                    || cached.generatorMetadataOffset <= 0 {
                    return DirtySessionPlan(
                        sessionID: sessionId,
                        fileInfo: info,
                        requestedOffset: 0,
                        isIncremental: false
                    )
                }
                if let lastEmptySuffixAt = cached.lastEmptySuffixAt,
                   nowDate.timeIntervalSince(lastEmptySuffixAt) < 30 {
                    return nil
                }
                if cached.consecutiveEmptySuffixes >= Self.emptySuffixVerificationThreshold {
                    // 连续两次空 suffix（跨至少一次 30s 节流）：不再盲目重试同一
                    // suffix，升级为 offset=0 全量核验。核验若确认 raw metadata
                    // 总数未变则按成功收敛推进指纹；若 server 追上/截断则走正常
                    // 全量重算；若返回 0 条则进入零 metadata 打击计数（有界）。
                    return DirtySessionPlan(
                        sessionID: sessionId,
                        fileInfo: info,
                        requestedOffset: 0,
                        isIncremental: false,
                        isVerification: true
                    )
                }
                return DirtySessionPlan(
                    sessionID: sessionId,
                    fileInfo: info,
                    requestedOffset: cached.generatorMetadataOffset,
                    isIncremental: true
                )
            }

            return nil
        }

        // 3. 有界并发拉 dirty sessions
        // An incomplete root/file enumeration is retryable work even when all
        // visible session RPCs succeed. Otherwise a calendar rebuild could
        // advance its signature while silently omitting cached sessions.
        var failedCount = listing.isComplete ? 0 : 1
        if !dirtyPlans.isEmpty {
            // Keep only a small completed batch of parsed events alive. The old
            // implementation retained all 166 result arrays until the last RPC
            // completed, which amplified the full-scan peak.
            let batchSize = dirtyPlans.contains(where: { !$0.isIncremental }) ? 2 : 4
            for batchStart in stride(from: 0, to: dirtyPlans.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, dirtyPlans.count)
                let batch = Array(dirtyPlans[batchStart..<batchEnd])
                let results = try await fetchAll(
                    fetcher: fetcher,
                    plans: batch,
                    metadataFetch: metadataFetch
                )
                let dirtyByID = Dictionary(uniqueKeysWithValues: batch.map { ($0.sessionID, $0.fileInfo) })
                let verificationByID = Set(batch.filter(\.isVerification).map(\.sessionID))
                for entry in results {
                let sessionId = entry.sessionID
                guard let info = dirtyByID[sessionId] else { continue }
                switch entry.result {
                case .success(.emptyIncremental):
                    failedCount = SaturatingArithmetic.add(failedCount, 1)
                    // 空 suffix 是真实的页结果（增量页成功返回、suffix 为空），
                    // 但它只有 0 条 raw 条目可解析，**不含任何解析证据**——与下面的
                    // .failure 同理，不能用它证明解析已恢复。因此这里刻意不清零
                    // 零可计账计数：若"raw 非零但零可计账"与"空 suffix"交替出现，
                    // 计数会被反复清掉、永远凑不满 3 轮观察期 → failedCount 永不
                    // 归零 → 签名永不推进 → 每轮 reconcile 全量冷重建，正好破坏
                    // 打击机制守住的"持久失败有界收敛"不变量。
                    //
                    // 解析健康度的正面证据只有两类：产出可计账 event 的页（走分叉前
                    // 的统一清零点），以及核验收敛页——后者是 offset=0 全量页且确认
                    // 服务端总数未变，事件已在缓存入账故直接丢弃，解析结果不影响
                    // "确无新事件"这一结论，属于对该 session 的有效证据。
                    if var cached = index.sessions[sessionId] {
                        cached.lastEmptySuffixAt = nowDate
                        cached.consecutiveEmptySuffixes = SaturatingArithmetic.add(
                            cached.consecutiveEmptySuffixes, 1
                        )
                        index.sessions[sessionId] = cached
                        logWarn("[antigravity-scan] session=\(sessionId) 增量 suffix 暂时为空，保留 dirty 并延迟重试（连续空 suffix \(cached.consecutiveEmptySuffixes)/\(Self.emptySuffixVerificationThreshold)）")
                    } else {
                        logWarn("[antigravity-scan] session=\(sessionId) 增量 suffix 暂时为空，保留 dirty 并延迟重试")
                    }
                case .success(.events(let events, let metadataEntryCount, let wasIncremental)):
                    // 零 raw metadata 的全量/核验页不可信（连错 server/workspace，
                    // 或 language server 重启后丢失 trajectory 记忆）。保留
                    // last-good 并累计打击计数，连续 `zeroMetadataFullStrikeLimit`
                    // 轮后按成功收敛，终结"每轮全量 RPC 无限重试"。
                    if metadataEntryCount == 0 {
                        // 零 metadata 页（raw 总数为 0，无从谈起解析失败）是
                        // "确定不是零可计账页"的页结果，到达即打破零可计账
                        // 连续性；本分支的打击与收敛两条出口共用此清零点。
                        Self.clearZeroAccountedFullStrikes(for: sessionId, on: &index)
                        var strikes = index.emptyFullStrikesBySession ?? [:]
                        let strikeCount = SaturatingArithmetic.add(strikes[sessionId] ?? 0, 1)
                        if strikeCount >= Self.zeroMetadataFullStrikeLimit {
                            if let cached = index.sessions[sessionId] {
                                // 已有 last-good：采用当前文件指纹，但完整保留
                                // eventCount / offset / daily / samples —— 零
                                // metadata 绝不清空用户可见的历史数据。日历变更
                                // 轮中保留的是旧日历日桶：打 calendarRebuildPending
                                // 标记，文件重新活跃时排一次 offset=0 full 按当前
                                // 日历重建（成功后清除标记）。
                                index.sessions[sessionId] = SessionIndexEntry(
                                    mtimeMs: info.mtimeMs,
                                    sizeBytes: info.sizeBytes,
                                    walMtimeMs: info.walMtimeMs,
                                    walSizeBytes: info.walSizeBytes,
                                    fetchedAt: nowDate,
                                    eventCount: cached.eventCount,
                                    generatorMetadataOffset: cached.generatorMetadataOffset,
                                    lastMaxStepIndex: cached.lastMaxStepIndex,
                                    lastTurnIndex: cached.lastTurnIndex
                                )
                                if index.samplesBySession?[sessionId] == nil {
                                    var samplesBySession = index.samplesBySession ?? [:]
                                    samplesBySession[sessionId] = []
                                    index.samplesBySession = samplesBySession
                                }
                                if calendarChanged {
                                    var pending = index.calendarRebuildPendingSessions ?? []
                                    pending.insert(sessionId)
                                    index.calendarRebuildPendingSessions = pending
                                }
                                logInfo("[antigravity-scan] session=\(sessionId) 连续 \(strikeCount) 轮零 metadata 全量结果，收敛并保留 last-good 缓存（eventCount=\(cached.eventCount)）\(calendarChanged ? "；daily 仍为旧日历分桶，已标记待 full 重建" : "")")
                            } else {
                                // 从无数据：写空终结条目，让该 session 脱离
                                // dirty 集合；文件再变化时按 full plan 正常重扫。
                                index.sessions[sessionId] = SessionIndexEntry(
                                    mtimeMs: info.mtimeMs,
                                    sizeBytes: info.sizeBytes,
                                    walMtimeMs: info.walMtimeMs,
                                    walSizeBytes: info.walSizeBytes,
                                    fetchedAt: nowDate,
                                    eventCount: 0,
                                    generatorMetadataOffset: 0
                                )
                                var samplesBySession = index.samplesBySession ?? [:]
                                samplesBySession[sessionId] = []
                                index.samplesBySession = samplesBySession
                                logInfo("[antigravity-scan] session=\(sessionId) 连续 \(strikeCount) 轮零 metadata 全量结果，收敛为空 session 终结态")
                            }
                            Self.clearEmptyFullStrikes(for: sessionId, on: &index)
                            continue
                        }
                        strikes[sessionId] = strikeCount
                        index.emptyFullStrikesBySession = strikes
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        logWarn("[antigravity-scan] session=\(sessionId) RPC 返回空 events（全量），保留 last-good cache 并重试（strike \(strikeCount)/\(Self.zeroMetadataFullStrikeLimit)）")
                        continue
                    }
                    // 空后缀核验收敛：offset=0 全量核验返回的 raw metadata 总数
                    // 与缓存一致 → "确无新事件"。按成功收敛：只推进文件指纹并
                    // 清零空 suffix 状态，不计失败；核验页重新交付的 events 已在
                    // 缓存中入账，直接丢弃，重复聚合会双算。
                    if verificationByID.contains(sessionId),
                       let cached = index.sessions[sessionId],
                       metadataEntryCount == cached.generatorMetadataOffset {
                        index.sessions[sessionId] = SessionIndexEntry(
                            mtimeMs: info.mtimeMs,
                            sizeBytes: info.sizeBytes,
                            walMtimeMs: info.walMtimeMs,
                            walSizeBytes: info.walSizeBytes,
                            fetchedAt: nowDate,
                            eventCount: cached.eventCount,
                            generatorMetadataOffset: cached.generatorMetadataOffset,
                            lastMaxStepIndex: cached.lastMaxStepIndex,
                            lastTurnIndex: cached.lastTurnIndex
                        )
                        Self.clearEmptyFullStrikes(for: sessionId, on: &index)
                        // 核验收敛页（raw 总数与缓存一致、events 已在缓存入账）
                        // 同样不是零可计账页证据，到达即打破连续性。
                        Self.clearZeroAccountedFullStrikes(for: sessionId, on: &index)
                        logInfo("[antigravity-scan] session=\(sessionId) 全量核验确认 metadata 总数未变（offset=\(metadataEntryCount)），按成功收敛推进指纹")
                        continue
                    }
                    // 全量页 offset 回归：返回的 raw metadata 总数小于缓存的
                    // offset（server 丢数据/截断/连错 workspace）。照常全量
                    // 替换会把 offset/eventCount 直接覆盖成小值，本地已入账
                    // 历史永久丢失——绝不回退 last-good。镜像零 metadata 打击
                    // 机制：连续 `offsetRegressionStrikeLimit` 轮后按成功收敛
                    // （采用当前文件指纹、完整保留 last-good、offset 不回退），
                    // 观察期内计失败阻塞签名推进（有界，避免 server 永久缺
                    // 数据拖成每轮全量冷重建循环）。零 metadata（count=0）由
                    // 上方分支先行处理，核验收敛（count == offset）已在上方
                    // 优先收敛，均不会到达这里；增量页没有 count vs offset 的
                    // 对账关系，不参与本检查。回归页在解析统计前即被拒绝，不
                    // 构成零可计账页判定，顺带清零该计数与零 metadata 计数。
                    if !wasIncremental,
                       let cached = index.sessions[sessionId],
                       cached.generatorMetadataOffset > 0,
                       metadataEntryCount < cached.generatorMetadataOffset {
                        Self.clearEmptyFullStrikes(for: sessionId, on: &index)
                        Self.clearZeroAccountedFullStrikes(for: sessionId, on: &index)
                        var strikes = index.offsetRegressionStrikesBySession ?? [:]
                        let strikeCount = SaturatingArithmetic.add(strikes[sessionId] ?? 0, 1)
                        if strikeCount >= Self.offsetRegressionStrikeLimit {
                            // 收敛：采用当前文件指纹，完整保留 eventCount /
                            // offset / daily / samples——offset 刻意不回退，
                            // server 端恢复（count >= offset）后由全量重算或
                            // 增量消费自然补齐。日历变更轮收敛的 session 保留
                            // 的 last-good daily 仍按旧日历分桶，与零 metadata/
                            // 零可计账收敛同款：打 calendarRebuildPending 标记，
                            // 文件重新活跃时排一次 offset=0 full 重建。
                            index.sessions[sessionId] = SessionIndexEntry(
                                mtimeMs: info.mtimeMs,
                                sizeBytes: info.sizeBytes,
                                walMtimeMs: info.walMtimeMs,
                                walSizeBytes: info.walSizeBytes,
                                fetchedAt: nowDate,
                                eventCount: cached.eventCount,
                                generatorMetadataOffset: cached.generatorMetadataOffset,
                                lastMaxStepIndex: cached.lastMaxStepIndex,
                                lastTurnIndex: cached.lastTurnIndex
                            )
                            if index.samplesBySession?[sessionId] == nil {
                                var samplesBySession = index.samplesBySession ?? [:]
                                samplesBySession[sessionId] = []
                                index.samplesBySession = samplesBySession
                            }
                            if calendarChanged {
                                var pending = index.calendarRebuildPendingSessions ?? []
                                pending.insert(sessionId)
                                index.calendarRebuildPendingSessions = pending
                            }
                            Self.clearOffsetRegressionStrikes(for: sessionId, on: &index)
                            logInfo("[antigravity-scan] session=\(sessionId) 连续 \(strikeCount) 轮全量页 metadata 总数(\(metadataEntryCount)) < 缓存 offset(\(cached.generatorMetadataOffset))，收敛并保留 last-good 缓存（offset 不回退）\(calendarChanged ? "；daily 仍为旧日历分桶，已标记待 full 重建" : "")")
                            continue
                        }
                        strikes[sessionId] = strikeCount
                        index.offsetRegressionStrikesBySession = strikes
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        logWarn("[antigravity-scan] session=\(sessionId) 全量页 metadata 总数(\(metadataEntryCount)) < 缓存 offset(\(cached.generatorMetadataOffset))，拒绝覆盖 last-good 并重试（strike \(strikeCount)/\(Self.offsetRegressionStrikeLimit)）")
                        continue
                    }
                    guard isTrustworthyRPCResult(
                        events,
                        metadataEntryCount: metadataEntryCount
                    ) else {
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        logWarn("[antigravity-scan] session=\(sessionId) RPC 返回空 events，保留 last-good cache 并于下次重试")
                        continue
                    }
                    // 拿到非零 metadata：该 session 的零 metadata 打击计数清零，
                    // 回到正常路径。此处能到达的全量页必然 count >= 缓存 offset
                    // （回归页已在上方拒绝），顺带清零 offset 回归打击计数；
                    // 增量页虽无对账关系，但成功交付 suffix 同样说明 server
                    // 正常服务，一并清零。
                    Self.clearEmptyFullStrikes(for: sessionId, on: &index)
                    Self.clearOffsetRegressionStrikes(for: sessionId, on: &index)
                    let recoveredEvents = Self.recoverMissingTimestamps(
                        events,
                        fileInfo: info
                    )
                    let inputTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.inputTokens))
                    let outputTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.outputTokens))
                    let cacheReadTotal = SaturatingArithmetic.sum(recoveredEvents.lazy.map(\.cacheReadTokens))
                    let eventStats = Self.accountedEventStats(recoveredEvents)
                    if eventStats.droppedTimestampless > 0 {
                        logWarn(
                            "[antigravity-scan] session=\(sessionId) 丢弃无 timestamp 的 usage event: "
                                + "accounted=\(eventStats.accounted), dropped=\(eventStats.droppedTimestampless), parsed=\(events.count), rawMetadata=\(metadataEntryCount)"
                        )
                    }

                    // 页级不可信防线（全量/增量 alike，上提到全量/增量分叉前统一
                    // 覆盖两种页）：raw metadata 非零但可计账 event 为零（events
                    // 为空，或 events 全部缺失 timestamp 且本地回填后仍为零）。多
                    // 由 token 字段改名/换层级导致解析失败，此时若照常推进——全量
                    // 替换会清零 last-good daily/samples/eventCount 且 offset 推进
                    // 整页 raw 条数；增量合并则把 offset 推进 raw 条数——这批数据
                    // 都会被永久跳过，除非再触发 full 否则不可恢复（生产里活跃
                    // session 有缓存后永远走增量，见 plan 逻辑）。打击有界（镜像
                    // 零 metadata 机制）：连续 `zeroAccountedFullStrikeLimit` 轮后
                    // 按成功收敛——否则持续零可计账的 session 会让 failedCount 永
                    // 不归零、签名永不推进、每轮 reconcile 全量冷重建。
                    guard eventStats.accounted > 0 else {
                        var strikes = index.zeroAccountedFullStrikesBySession ?? [:]
                        let strikeCount = SaturatingArithmetic.add(strikes[sessionId] ?? 0, 1)
                        if strikeCount >= Self.zeroAccountedFullStrikeLimit {
                            if let cached = index.sessions[sessionId] {
                                // 收敛：采用当前文件指纹，完整保留 eventCount /
                                // offset / lastMaxStepIndex / lastTurnIndex 与
                                // daily / samples。offset 刻意不推进——恢复路径
                                // 是文件再变化时 session 重新 dirty，从保留
                                // offset 重取同一批页、用（可能已修复的）解析器
                                // 重试；下次日历失效的冷重建也会 offset=0 全量
                                // 重来。补写空 samples 条目，避免"缺 samples
                                // 缓存"分支让指纹未变的 session 反复吃 full plan。
                                index.sessions[sessionId] = SessionIndexEntry(
                                    mtimeMs: info.mtimeMs,
                                    sizeBytes: info.sizeBytes,
                                    walMtimeMs: info.walMtimeMs,
                                    walSizeBytes: info.walSizeBytes,
                                    fetchedAt: nowDate,
                                    eventCount: cached.eventCount,
                                    generatorMetadataOffset: cached.generatorMetadataOffset,
                                    lastMaxStepIndex: cached.lastMaxStepIndex,
                                    lastTurnIndex: cached.lastTurnIndex
                                )
                                if index.samplesBySession?[sessionId] == nil {
                                    var samplesBySession = index.samplesBySession ?? [:]
                                    samplesBySession[sessionId] = []
                                    index.samplesBySession = samplesBySession
                                }
                                if calendarChanged {
                                    var pending = index.calendarRebuildPendingSessions ?? []
                                    pending.insert(sessionId)
                                    index.calendarRebuildPendingSessions = pending
                                }
                                logInfo("[antigravity-scan] session=\(sessionId) 连续 \(strikeCount) 轮零可计账 event 页，收敛并保留 last-good 缓存（eventCount=\(cached.eventCount)，offset=\(cached.generatorMetadataOffset) 不推进）\(calendarChanged ? "；daily 仍为旧日历分桶，已标记待 full 重建" : "")")
                            } else {
                                // 从无数据：写空终结条目（offset=0，不消费未
                                // 解析的 raw 条目），让该 session 脱离 dirty
                                // 集合；文件再变化时按 full plan 正常重扫。
                                index.sessions[sessionId] = SessionIndexEntry(
                                    mtimeMs: info.mtimeMs,
                                    sizeBytes: info.sizeBytes,
                                    walMtimeMs: info.walMtimeMs,
                                    walSizeBytes: info.walSizeBytes,
                                    fetchedAt: nowDate,
                                    eventCount: 0,
                                    generatorMetadataOffset: 0
                                )
                                var samplesBySession = index.samplesBySession ?? [:]
                                samplesBySession[sessionId] = []
                                index.samplesBySession = samplesBySession
                                logInfo("[antigravity-scan] session=\(sessionId) 连续 \(strikeCount) 轮零可计账 event 页，收敛为空 session 终结态")
                            }
                            Self.clearZeroAccountedFullStrikes(for: sessionId, on: &index)
                            continue
                        }
                        strikes[sessionId] = strikeCount
                        index.zeroAccountedFullStrikesBySession = strikes
                        failedCount = SaturatingArithmetic.add(failedCount, 1)
                        logWarn("[antigravity-scan] session=\(sessionId) 页有 \(metadataEntryCount) 条 raw metadata 但零可计账 event（parsed=\(events.count)，incremental=\(wasIncremental)），保留 last-good cache 并于下次重试（strike \(strikeCount)/\(Self.zeroAccountedFullStrikeLimit)）")
                        continue
                    }
                    // 拿到可入账 event：该 session 的零可计账打击计数清零（覆盖
                    // 全量/增量两种页），进入正常分叉路径。
                    Self.clearZeroAccountedFullStrikes(for: sessionId, on: &index)

                    // 部分命中分量告警（替代 parseUsageEvent 的逐事件 logWarn）：
                    // 按 session 聚合为一条汇总——记录该 session 本页观测到的
                    // 未命中分量集合与涉及事件数，集合与上次已告警一致时不重复
                    // 告警（去重状态见 CacheIndex.partialHitWarnedBySession）。
                    var observedMissing = Set<String>()
                    var partialHitEventCount = 0
                    for event in recoveredEvents {
                        guard let missing = event.missingComponents, !missing.isEmpty else { continue }
                        partialHitEventCount += 1
                        observedMissing.formUnion(missing)
                    }
                    if !observedMissing.isEmpty,
                       index.partialHitWarnedBySession?[sessionId] != observedMissing {
                        var warned = index.partialHitWarnedBySession ?? [:]
                        warned[sessionId] = observedMissing
                        index.partialHitWarnedBySession = warned
                        logWarn("[antigravity-scan] session=\(sessionId) \(partialHitEventCount) 个 usage 事件仅命中部分 token 分量（未命中分量: \(observedMissing.sorted().joined(separator: "/"))），total 采用 server 权威值")
                    }

                    if wasIncremental, let cached = index.sessions[sessionId] {
                        logDebug("[antigravity-scan] session=\(sessionId) ✓ 增量 metadata=\(metadataEntryCount), events=\(events.count) (accounted=\(eventStats.accounted)) input=\(inputTotal) output=\(outputTotal) cacheR=\(cacheReadTotal)")
                        let details = Self.computeTurnRoundDetails(
                            sessionID: sessionId,
                            events: recoveredEvents,
                            calendar: calendar,
                            initialPrevMaxStepIndex: cached.lastMaxStepIndex,
                            initialTurnIndex: cached.lastTurnIndex ?? 0
                        )
                        let incDaily = Self.aggregateDaily(
                            events: recoveredEvents,
                            calendar: calendar,
                            counts: details.counts
                        )
                        let existingDaily = index.dailyBySession[sessionId] ?? [:]
                        index.dailyBySession[sessionId] = Self.mergeDaily(existing: existingDaily, incremental: incDaily)

                        let existingSamples = index.samplesBySession?[sessionId] ?? []
                        var samplesBySession = index.samplesBySession ?? [:]
                        samplesBySession[sessionId] = (existingSamples + details.samples).filter {
                            $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60)
                        }
                        index.samplesBySession = samplesBySession

                        index.sessions[sessionId] = SessionIndexEntry(
                            mtimeMs: info.mtimeMs,
                            sizeBytes: info.sizeBytes,
                            walMtimeMs: info.walMtimeMs,
                            walSizeBytes: info.walSizeBytes,
                            fetchedAt: nowDate,
                            eventCount: SaturatingArithmetic.add(cached.eventCount, eventStats.accounted),
                            generatorMetadataOffset: Self.advanceGeneratorMetadataOffset(
                                cached.generatorMetadataOffset,
                                by: metadataEntryCount
                            ),
                            lastMaxStepIndex: details.lastMaxStepIndex ?? cached.lastMaxStepIndex,
                            lastTurnIndex: details.lastTurnIndex
                        )
                    } else {
                        logDebug("[antigravity-scan] session=\(sessionId) ✓ 全量 metadata=\(metadataEntryCount), events=\(events.count) (accounted=\(eventStats.accounted)) input=\(inputTotal) output=\(outputTotal) cacheR=\(cacheReadTotal)")
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
                        index.dailyBySession[sessionId] = newDaily
                        if index.dailyBySession[sessionId]?.isEmpty == true {
                            index.dailyBySession.removeValue(forKey: sessionId)
                        }
                        var samplesBySession = index.samplesBySession ?? [:]
                        samplesBySession[sessionId] = details.samples.filter {
                            $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60)
                        }
                        index.samplesBySession = samplesBySession

                        index.sessions[sessionId] = SessionIndexEntry(
                            mtimeMs: info.mtimeMs,
                            sizeBytes: info.sizeBytes,
                            walMtimeMs: info.walMtimeMs,
                            walSizeBytes: info.walSizeBytes,
                            fetchedAt: nowDate,
                            eventCount: eventStats.accounted,
                            generatorMetadataOffset: metadataEntryCount,
                            lastMaxStepIndex: details.lastMaxStepIndex,
                            lastTurnIndex: details.lastTurnIndex
                        )
                        // full 成功已按当前日历重建日桶，旧日历待重建标记随之清除
                        // （零可计账打击计数已在分叉前的统一清零点处理）。
                        Self.clearCalendarRebuildPending(for: sessionId, on: &index)
                    }
                case .failure(let error):
                    failedCount = SaturatingArithmetic.add(failedCount, 1)
                    // RPC 失败是传输层结果、不含解析证据，刻意不清零
                    // zeroAccountedFullStrikesBySession（理由见 .emptyIncremental
                    // 分支注释）：网络抖动若也打断计数，观察期永远凑不满。
                    logWarn("[antigravity-scan] session=\(sessionId) ✗ RPC 失败: \(error)")
                }
                }
            }
        }

        // 4. 写回 index (整个 performScanPure 在 AsyncMutex 里跑, 这里不需要再
        //    加锁; mutex 保证同时间只有一个 worker 在写 index.json).
        //    shouldSave=false (旧 generation) 跳过, 保留新 worker 的 cache.
        if shouldSave {
            index.lastScannedAt = nowDate
            // 签名保持 all-or-nothing，不需要按 session 签名：持久失败源全部
            // 变成有界收敛——空 suffix 连续 2 次后升级核验并可收敛；零 metadata
            // 全量 3 轮打击后收敛；有 raw metadata 但零可计账 event 的页（全量/
            // 增量 alike，打击上提到分叉前统一覆盖，增量页同款，避免解析损坏时
            // offset 被无条件推进、raw 条目被永久吞掉）同样 3 轮打击后收敛
            // （保留 last-good，offset 刻意不推进）；全量页 count < 缓存 offset
            // 的回归页同样 3 轮打击后收敛（保留 last-good，offset 绝不回退）；
            // 且收敛
            // 不计失败——所以 `failedCount > 0`（进而所有 session 以 batch=2 走
            // full plan）的轮数是有界的（通常 ≤ 3），之后 failedCount 归零、
            // 签名自然推进、回到便宜的 dirty/offset 模式。枚举不完整仍阻塞
            // 签名推进（正确：那代表本轮可能漏扫 session），保持原样。
            //
            // 注意：零 metadata / 零可计账收敛的 session 若是在日历变更轮收敛
            // 的，其 last-good daily 仍按旧日历分桶，但签名照常推进。这不是
            // 宣称旧日历桶已 current，而是有标记兜底：这些 session 记录在
            // `calendarRebuildPendingSessions`，文件重新活跃（指纹变化）时
            // 会被排一次 offset=0 full 按当前日历重建（成功后清除标记），
            // 下一次日历失效的冷重建也会对它们全量重规划。若反而让签名停在
            // 旧值，每轮 reconcile 都会全量冷重建、对零 metadata session 反复
            // 打 RPC（旧策略的矛盾所在），代价远大于收益。
            if failedCount == 0 {
                index.calendarSignature = currentCalendarSignature
            }
            // 落盘前裁掉严格早于 8 天窗口的日桶（消费面只有 today/7 天窗口，
            // eventCount 独立于日桶），防止 index.json 随历史 session 无界增长。
            Self.pruneStaleDailyBuckets(index: &index, now: nowDate)
            try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager, hook: saveIndexHook)
        }

        // 5. 组装 AntigravityLocalUsage（只算自然日已入账的 tokens）
        let allDaily = computeGlobalDaily(from: index.dailyBySession, calendar: calendar)
        let todayStart = todayCutoff(now: nowDate, calendar: calendar)
        let recent7 = filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
        let recentSamples = (index.samplesBySession ?? [:]).values
            .flatMap { $0 }
            .filter { $0.completedAt >= nowDate.addingTimeInterval(-8 * 24 * 60 * 60) }
            .sorted { $0.completedAt < $1.completedAt }
        return AntigravityLocalUsage(
            today: allDaily.first(where: { $0.dayStart == todayStart }),
            dailyTokenUsage: recent7,
            scannedAt: nowDate,
            // sessionCount 描述本次发现的本地 session，不应因首次 RPC 失败而少算。
            sessionCount: dbFiles.count,
            eventCount: SaturatingArithmetic.sum(index.sessions.values.lazy.map(\.eventCount)),
            failedSessionCount: failedCount,
            recentSamples: recentSamples
        )
    }

    /// 基线判据：未提供 raw metadata 计数时，空事件列表不可信——既可能是 RPC
    /// 暂时未准备好，也可能来自错误的本地 server/workspace，必须保留旧缓存并重试。
    /// 提供 `metadataEntryCount` 时（全量/核验页），非零 raw 条数即为通过：raw
    /// 条目可以合法地不含 token 字段，offset 必须按 raw 条数推进。raw 非零但
    /// 可计账为零的页（全量与增量 alike）由归约处的零可计账打击机制有界收敛
    /// ——合法的零 token 页代价是按文件变化的有界重试，换取解析损坏时不吞掉
    /// suffix 的 offset。
    nonisolated static func isTrustworthyRPCResult(
        _ events: [AntigravityFetcher.UsageEvent],
        metadataEntryCount: Int? = nil
    ) -> Bool {
        if let metadataEntryCount {
            return metadataEntryCount > 0
        }
        return !events.isEmpty
    }

    /// 连续空 suffix 达到该次数后，下一个 dirty plan 升级为 offset=0 全量核验。
    /// 两次空 suffix 之间至少隔着一次 30s 节流，给滞后的 server 两次追赶机会。
    nonisolated static let emptySuffixVerificationThreshold = 2

    /// 零 metadata 全量结果的连续打击上限：达到后该 session 按成功收敛
    /// （有 last-good 保留 last-good，无数据写空终结条目）。3 轮观察期兼顾
    /// "连错 server 需要观察"与"不能被拖入永久全量循环"。
    nonisolated static let zeroMetadataFullStrikeLimit = 3

    /// "有 raw metadata 但零可计账 event"页（全量/增量 alike）的连续打击上限：
    /// 达到后该 session 按成功收敛（有 last-good 保留 last-good 且 offset 刻意
    /// 不推进，无数据写空终结条目）。与 `zeroMetadataFullStrikeLimit` 同款，
    /// 保证"所有持久失败模式有界收敛"的不变量：解析损坏/天然全零 token 的
    /// session 不能把 failedCount 拖成永久 > 0。
    nonisolated static let zeroAccountedFullStrikeLimit = 3

    /// 全量页 offset 回归（count < 缓存 offset）的连续打击上限：达到后按成功
    /// 收敛（采用当前文件指纹、完整保留 last-good，offset 绝不回退）。与
    /// `zeroMetadataFullStrikeLimit` 同款，保证 server 永久缺数据时失败轮数
    /// 有界、签名能推进，不拖成每轮全量冷重建。
    nonisolated static let offsetRegressionStrikeLimit = 3

    /// 清除 session 的零 metadata 打击计数（拿到非零 metadata 或收敛时）。
    /// 字典清空后写回 nil，避免 index.json 长期残留空对象。
    private nonisolated static func clearEmptyFullStrikes(
        for sessionID: String,
        on index: inout CacheIndex
    ) {
        guard let strikes = index.emptyFullStrikesBySession,
              strikes[sessionID] != nil else { return }
        var updated = strikes
        updated.removeValue(forKey: sessionID)
        index.emptyFullStrikesBySession = updated.isEmpty ? nil : updated
    }

    /// 清除 session 的旧日历重建待办标记（full 成功按当前日历重建日桶后调用；
    /// session 被确认删除时也走这里保持卫生）。集合清空后写回 nil，避免
    /// index.json 长期残留空数组。
    private nonisolated static func clearCalendarRebuildPending(
        for sessionID: String,
        on index: inout CacheIndex
    ) {
        guard var pending = index.calendarRebuildPendingSessions,
              pending.contains(sessionID) else { return }
        pending.remove(sessionID)
        index.calendarRebuildPendingSessions = pending.isEmpty ? nil : pending
    }

    /// 清除 session 的零可计账页（全量/增量 alike）打击计数（页成功入账、收敛
    /// 或 session 被确认删除时）。字典清空后写回 nil，避免 index.json 长期残留
    /// 空对象。
    private nonisolated static func clearZeroAccountedFullStrikes(
        for sessionID: String,
        on index: inout CacheIndex
    ) {
        guard let strikes = index.zeroAccountedFullStrikesBySession,
              strikes[sessionID] != nil else { return }
        var updated = strikes
        updated.removeValue(forKey: sessionID)
        index.zeroAccountedFullStrikesBySession = updated.isEmpty ? nil : updated
    }

    /// 清除 session 的全量页 offset 回归打击计数（拿到 count >= 缓存 offset 的
    /// 页、收敛或 session 被确认删除时）。字典清空后写回 nil，避免 index.json
    /// 长期残留空对象。
    private nonisolated static func clearOffsetRegressionStrikes(
        for sessionID: String,
        on index: inout CacheIndex
    ) {
        guard let strikes = index.offsetRegressionStrikesBySession,
              strikes[sessionID] != nil else { return }
        var updated = strikes
        updated.removeValue(forKey: sessionID)
        index.offsetRegressionStrikesBySession = updated.isEmpty ? nil : updated
    }

    /// 写回 index 前裁剪 `dailyBySession` 中严格早于 8 天窗口的日期桶（与
    /// samples 的 `-8 * 24 * 60 * 60` 谓词同式，按桶的 `dayStart` 比较）。
    /// 日桶只有 today / 最近 7 天两个消费出口（`computeGlobalDaily` → today +
    /// `filterLast7Days`），session 级 `eventCount` 独立保存在 `sessions` 条目
    /// 里，因此旧桶删除不影响任何用户可见数字，只防止长期使用后 index.json
    /// 无界增长。全桶被裁的 session 条目一并移除。
    nonisolated static func pruneStaleDailyBuckets(
        index: inout CacheIndex,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-8 * 24 * 60 * 60)
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

    /// The protocol offset advances by raw generatorMetadata entries, including
    /// entries that do not contain a usable token event and are filtered out.
    nonisolated static func advanceGeneratorMetadataOffset(
        _ current: Int,
        by metadataEntryCount: Int
    ) -> Int {
        SaturatingArithmetic.add(max(current, 0), max(metadataEntryCount, 0))
    }

    struct DirtySessionPlan: Sendable {
        let sessionID: String
        let fileInfo: AntigravityDBFileInfo
        let requestedOffset: Int
        let isIncremental: Bool
        /// offset=0 全量核验计划：由连续空 suffix 升级而来。线上请求形态与
        /// full plan 相同（`isIncremental == false`），只影响结果归约：核验页
        /// 若确认 metadata 总数未变，则按成功收敛并推进指纹，而不是重放已
        /// 入账的 events（重复聚合会双算）。
        var isVerification: Bool = false
    }

    /// 以固定并发度拉多个 session 的 metadata。
    /// `nonisolated static`：fetcher 通过参数传，不碰 self，可在 background 跑。
    fileprivate nonisolated static func fetchAll(
        fetcher: AntigravityFetcher,
        plans: [DirtySessionPlan],
        metadataFetch: TrajectoryMetadataFetch? = nil
    ) async throws -> [DirtySessionFetchResult] {
        let planTags = plans.prefix(5).map { plan -> String in
            if plan.isVerification { return "\(plan.sessionID)(verify)" }
            return "\(plan.sessionID)\(plan.isIncremental ? "(inc)" : "(full)")"
        }.joined(separator: ", ")
        logInfo("[antigravity-scan] dirty sessions: \(plans.count) — \(planTags)\(plans.count > 5 ? "…" : "")")
        try Task.checkCancellation()
        // 进程/端口发现对整次扫描只做一次，所有 session 复用同一快照。
        let servers = fetcher.discoverMetadataServers()
        guard !servers.isEmpty else {
            return plans.enumerated().map { index, item in
                DirtySessionFetchResult(
                    index: index,
                    sessionID: item.sessionID,
                    result: .failure(DirtySessionFetchError(
                        message: "未发现 Antigravity 或 agy CLI 进程，请先启动 Antigravity 并完成登录"
                    ))
                )
            }
        }

        // Full responses are much more expensive than suffixes: each in-flight
        // request temporarily holds Data plus the per-entry decode objects. Keep
        // startup/recovery full scans at two and allow four only for small
        // incremental suffixes.
        let hasFullPlan = plans.contains { !$0.isIncremental }
        let concurrencyLimit = hasFullPlan ? 2 : 4
        let concurrency = min(concurrencyLimit, max(plans.count, 1))
        var nextIndex = 0
        var results: [DirtySessionFetchResult] = []
        results.reserveCapacity(plans.count)

        return try await withThrowingTaskGroup(of: DirtySessionFetchResult.self) { group in
            for _ in 0..<concurrency {
                guard nextIndex < plans.count else { break }
                addFetchTask(
                    to: &group,
                    index: nextIndex,
                    plans: plans,
                    fetcher: fetcher,
                    servers: servers,
                    metadataFetch: metadataFetch
                )
                nextIndex += 1
            }

            while let result = try await group.next() {
                results.append(result)
                guard nextIndex < plans.count else { continue }
                addFetchTask(
                    to: &group,
                    index: nextIndex,
                    plans: plans,
                    fetcher: fetcher,
                    servers: servers,
                    metadataFetch: metadataFetch
                )
                nextIndex += 1
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private nonisolated static func addFetchTask(
        to group: inout ThrowingTaskGroup<DirtySessionFetchResult, Error>,
        index: Int,
        plans: [DirtySessionPlan],
        fetcher: AntigravityFetcher,
        servers: [AntigravityFetcher.ServerInfo],
        metadataFetch: TrajectoryMetadataFetch? = nil
    ) {
        let plan = plans[index]
        let sessionID = plan.sessionID
        let offset = plan.requestedOffset
        let isIncremental = plan.isIncremental

        group.addTask {
            try Task.checkCancellation()
            do {
                let requestedOffset = isIncremental ? offset : 0
                let page: AntigravityFetcher.TrajectoryMetadataPage
                if let metadataFetch {
                    // Test-only 替身路径：不出网，按 (sessionID, offset) 返回。
                    let stubbed = try await metadataFetch(sessionID, requestedOffset)
                    page = AntigravityFetcher.TrajectoryMetadataPage(
                        events: stubbed.events,
                        metadataEntryCount: stubbed.metadataEntryCount
                    )
                } else {
                    page = try await fetcher.getTrajectoryMetadata(
                        sessionId: sessionID,
                        offset: requestedOffset,
                        servers: servers
                    )
                }
                if isIncremental {
                    if page.metadataEntryCount > 0 {
                        return DirtySessionFetchResult(
                            index: index,
                            sessionID: sessionID,
                            result: .success(.events(
                                events: page.events,
                                metadataEntryCount: page.metadataEntryCount,
                                wasIncremental: true
                            ))
                        )
                    }

                    // Do not mark the file fingerprint successful: a server can
                    // transiently return an empty suffix before its trajectory
                    // index catches up. The plan-level timestamp throttles the
                    // retry without falling back to another large full fetch.
                    logInfo("[antigravity-scan] session=\(sessionID) 增量 offset=\(offset) 暂无 metadata，保留 dirty")
                    return DirtySessionFetchResult(
                        index: index,
                        sessionID: sessionID,
                        result: .success(.emptyIncremental)
                    )
                } else {
                    return DirtySessionFetchResult(
                        index: index,
                        sessionID: sessionID,
                        result: .success(.events(
                            events: page.events,
                            metadataEntryCount: page.metadataEntryCount,
                            wasIncremental: false
                        ))
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return DirtySessionFetchResult(
                    index: index,
                    sessionID: sessionID,
                    result: .failure(DirtySessionFetchError(message: error.localizedDescription))
                )
            }
        }
    }
}

// 文件系统与 index I/O（AntigravityDBFileInfo / AntigravityDBFileListing / SessionStoreFormat
// 以及 recoverMissingTimestamps / listDBFilesWithStatus / loadIndex 等）见 AntigravityFilesystem.swift
