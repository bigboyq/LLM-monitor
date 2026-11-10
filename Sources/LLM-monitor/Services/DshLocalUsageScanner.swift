import Foundation
import Combine

/// Decode the durable JSONL artifacts written by DeepSeek Harness (`dsh`).
///
/// dsh's default persistence format is a zstd-compressed append-only log. The scanner
/// keeps the filesystem path and raw event work outside the main actor, uses a small
/// fingerprint/index cache, and limits both the number of files and the amount of
/// untrusted JSON it will inspect. A decompressor is injectable so tests can exercise
/// the pure parser without requiring a zstd binary.
struct DshLocalUsageScanLimits: Sendable {
    static let production = DshLocalUsageScanLimits(
        maxSessionFiles: 1_024,
        // 压缩产物字节口径（zstd 压缩比高，磁盘 1GB 约对应数 GB 明文）；
        // 触顶按 mtime 最新优先截断，最旧 session 被挤出 7 天统计。
        maxTotalRawBytes: 1024 * 1024 * 1024,
        maxJSONLLineBytes: 8 * 1024 * 1024,
        maxRecentSamples: 65_536,
        readChunkBytes: 1024 * 1024
    )

    let maxSessionFiles: Int
    let maxTotalRawBytes: Int
    let maxJSONLLineBytes: Int
    let maxRecentSamples: Int
    let readChunkBytes: Int

    init(
        maxSessionFiles: Int,
        maxTotalRawBytes: Int,
        maxJSONLLineBytes: Int,
        maxRecentSamples: Int,
        readChunkBytes: Int = 64 * 1024
    ) {
        self.maxSessionFiles = max(maxSessionFiles, 1)
        self.maxTotalRawBytes = max(maxTotalRawBytes, 1)
        self.maxJSONLLineBytes = max(maxJSONLLineBytes, 1)
        self.maxRecentSamples = max(maxRecentSamples, 1)
        self.readChunkBytes = max(min(readChunkBytes, self.maxJSONLLineBytes), 1)
    }
}

private extension DshLocalUsageScanLimits {
    var cacheKey: String {
        "\(maxSessionFiles):\(maxTotalRawBytes):\(maxJSONLLineBytes):\(maxRecentSamples)"
    }
}
@MainActor
final class DshLocalUsageScanner: LocalUsageScannerBase<DshLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[dsh-scan]"

    /// 整个扫描 pipeline 的串行锁（跨实例共享）。
    nonisolated static let pipelineMutex = AsyncMutex()

    /// DSH 的 session 文件通常是 append-only。扫描时如果只有一个活跃文件变化，
    /// 其余文件的解压和 JSONL 解析结果可以直接复用；进程内缓存保留最新 256 个
    /// 文件，容量外文件不会驱逐它们，避免每次刷新重解压整批历史。它不改变 index.json 格式，应用重启
    /// 后仍由现有快照缓存提供冷启动快路径。
    nonisolated private static let parsedFileCache = DshParsedFileCache(maximumEntryCount: 256)

    nonisolated static let defaultSessionsRoot: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }()

    nonisolated static let defaultCacheDir: URL = {
        TokenMonitorPaths.cacheFile(for: .dsh)
    }()

    typealias Decompressor = @Sendable (Data) throws -> Data
    typealias StreamingDecompressor = @Sendable (URL, URL, FileManagerBox) throws -> Void

    private let sessionsRoot: URL
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let decompressor: Decompressor?
    private let streamingDecompressor: StreamingDecompressor
    init(
        sessionsRoot: URL = DshLocalUsageScanner.defaultSessionsRoot,
        cacheDir: URL = DshLocalUsageScanner.defaultCacheDir,
        fileManager: FileManagerBox = FileManagerBox(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        decompressor: Decompressor? = nil,
        streamingDecompressor: @escaping StreamingDecompressor = {
            try DshLogDecoder.decompressToFile(input: $0, output: $1, fileManager: $2)
        }
    ) {
        self.sessionsRoot = sessionsRoot
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        self.decompressor = decompressor
        self.streamingDecompressor = streamingDecompressor
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
            paths: [sessionsRoot],
            dynamicExtensions: ["jsonl", "zst", "zstd"]
        )
    }

    /// 递归发现 dsh session 产物文件（session.jsonl / *.jsonl.zstd / *.jsonl.zst），
    /// 按路径排序。dsh 领域专用逻辑，放在 dsh scanner 而不是通用 FileManagerBox。
    nonisolated static func sessionFileURLs(
        in root: URL,
        fileManager: FileManagerBox
    ) throws -> [URL] {
        let relativePaths = try fileManager.subpathsOfDirectory(atPath: root.path)
        return relativePaths
            .filter { relativePath in
                let name = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
                return name == "session.jsonl"
                    || name.hasSuffix(".jsonl.zstd")
                    || name.hasSuffix(".jsonl.zst")
            }
            .map { root.appendingPathComponent($0) }
            .sorted { $0.path < $1.path }
    }

    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> DshLocalUsage? {
        guard let index = try? loadIndex(cacheDir: cacheDir, fileManager: fileManager),
              let snapshot = index.snapshot,
              index.calendarSignature == LocalUsageCalendarSignature.make(calendar) else { return nil }
        return rebaseCached(snapshot, calendar: calendar, now: now)
    }

    /// dsh 的 pipeline：mutex 串行 + detached utility 任务承载纯文件系统扫描。
    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> DshLocalUsage {
        let sessionsRoot = self.sessionsRoot
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        let decompressor = self.decompressor
        let streamingDecompressor = self.streamingDecompressor
        // DSH already has per-file fingerprints and parsed-file caches. Keep
        // those caches active for startup `.full`; only explicit hard-full
        // recovery bypasses them.
        let forceFull = mode.bypassesProviderCache
        return {
            try await Self.pipelineMutex.withLock {
                try await Task.detached(priority: .utility) {
                    try Self.performScanPure(
                        sessionsRoot: sessionsRoot,
                        cacheDir: cacheDir,
                        fileManager: fileManager,
                        calendar: calendar,
                        now: now,
                        decompressor: decompressor,
                        streamingDecompressor: streamingDecompressor,
                        limits: DshLocalUsageScanLimits.production,
                        forceFull: forceFull
                    )
                }.value
            }
        }
    }

    /// Pure filesystem scan. The `AsyncMutex` keeps cache read/decode/write and a
    /// possible cancel-triggered rescan serialized; generation guards reject stale
    /// in-memory results.
    nonisolated static func performScanPure(
        sessionsRoot: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        decompressor: Decompressor? = nil,
        streamingDecompressor: @escaping StreamingDecompressor = {
            try DshLogDecoder.decompressToFile(input: $0, output: $1, fileManager: $2)
        },
        limits: DshLocalUsageScanLimits = .production,
        forceFull: Bool = false,
        snapshotReader: ((URL) throws -> DshLogFileSnapshot)? = nil
    ) throws -> DshLocalUsage {
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            logInfo("[dsh-scan] sessions 目录不存在: \(sessionsRoot.path)")
            return DshLocalUsage(
                byProvider: [:],
                modelsByProvider: [:],
                sessionsRoot: sessionsRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now()
            )
        }
        try ScannerIndexIO.ensureCacheDirectory(for: cacheDir, fileManager: fileManager)

        let filePaths = try Self.sessionFileURLs(in: sessionsRoot, fileManager: fileManager)
        let selection = selectSessionSnapshots(
            filePaths: filePaths,
            fileManager: fileManager,
            limits: limits,
            snapshotReader: snapshotReader
        )
        if selection.truncatedByFileLimit || selection.byteLimited {
            logWarn(
                "[dsh-scan] session 文件超过上限，已按 mtime 最新优先截断: "
                    + "selected=\(selection.snapshots.count), available=\(selection.availableCount)"
                    + (selection.byteLimited ? ", byteTruncated=true" : "")
            )
        }
        let snapshots = selection.snapshots
        // 预算截断（文件数/字节上限挤出最旧 session）是"完整扫描了被故意缩减
        // 的文件集"，与读取失败（isPartial）是两回事；在结果上置位，让被挤出
        // 的历史对 UI/结果层可感知，而不是只留在日志里。
        let isBudgetTruncated = selection.truncatedByFileLimit || selection.byteLimited
        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let currentCalendarSignature = LocalUsageCalendarSignature.make(calendar)
        // stat 失败的记忆只在 dirty/full 模式消费：保留 last-good cache 并返回
        // partial，等下一轮 reconcile 重试。`.hardFull`（forceFull）是操作者的
        // 显式强制重试——忽略失败记忆，用当前可 stat 的文件集重建；本轮仍
        // stat 失败的文件按不存在处理（selectSessionSnapshots 已逐个 logWarn，
        // 且选择仍受文件数/字节预算约束，逃生口是"重试失败文件"，不是无界
        // 扫描）。仅当整个 sessions 根一个可读文件都不剩时维持 partial，避免
        // 用"干净空快照"覆盖 last-good。恢复后的下一轮 dirty reconcile 会因
        // fingerprint 变化自动把该文件重新纳入。
        let hardFullBypassesFailureMemory = forceFull && !snapshots.isEmpty
        if selection.failedFileCount > 0, !hardFullBypassesFailureMemory {
            // A file that cannot be stat'ed is not evidence of deletion. Keep
            // the previous self-consistent index and expose its last-good view
            // as partial so the next reconcile retries the file.
            let scanNow = now()
            let fallback = index.snapshot.map {
                rebaseCached($0, calendar: calendar, now: scanNow)
            } ?? DshLocalUsage(
                byProvider: [:],
                modelsByProvider: [:],
                sessionsRoot: sessionsRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: scanNow
            )
            return Self.markPartial(fallback)
        }
        guard !snapshots.isEmpty else {
            let empty = DshLocalUsage(
                byProvider: [:],
                modelsByProvider: [:],
                sessionsRoot: sessionsRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now(),
                isTruncated: isBudgetTruncated,
                recentSamplesLimit: limits.maxRecentSamples
            )
            try saveIndex(
                DshCacheIndex(
                    version: 8,
                    files: [],
                    snapshot: empty,
                    calendarSignature: LocalUsageCalendarSignature.make(calendar)
                ),
                cacheDir: cacheDir,
                fileManager: fileManager
            )
            return empty
        }

        let fingerprint = CacheFingerprint(files: snapshots.map(\.fingerprint))
        let calendarChanged = index.calendarSignature != currentCalendarSignature
        if calendarChanged {
            logInfo("[dsh-scan] calendar signature changed，重新解析文件以重建当前日桶")
        }
        if !forceFull, !calendarChanged, index.matches(fingerprint), let cached = index.snapshot {
            let providersHaveKnownSampleCompleteness = cached.byProvider.values.allSatisfy {
                $0.recentSamplesTruncated != nil
            }
            let cachedSampleMetadataKnown = providersHaveKnownSampleCompleteness
                && (cached.byProvider.isEmpty || cached.recentSamplesLimit != nil)
            let sampleLimitMatches = cached.byProvider.isEmpty
                || cached.recentSamplesLimit == limits.maxRecentSamples
            if cachedSampleMetadataKnown && sampleLimitMatches {
                let scanNow = now()
                let rebased = rebaseCached(cached, calendar: calendar, now: scanNow, limits: limits)
                if rebased != cached {
                    index.snapshot = rebased
                    try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
                }
                return rebased
            }
            logInfo("[dsh-scan] legacy/sample-limit cache缺少样本完整性元数据，重新聚合文件")
        }

        let scanNow = now()
        let outcome = try aggregateFiles(
            snapshots: snapshots,
            sessionsRoot: sessionsRoot,
            fileManager: fileManager,
            calendar: calendar,
            decompressor: decompressor,
            streamingDecompressor: streamingDecompressor,
            limits: limits,
            forceFull: forceFull
        )
        // 不存在"部分失败继续聚合"路径：非 bypass 轮次 selection.failedFileCount
        // > 0 已在上方提前 return，bypass 轮次又跳过 stat 失败记忆——因此走到
        // 这里时 stat 失败数恒为 0，outcome.failedFileCount 只统计下方
        // aggregateFiles 的文件解析失败（读取/解压/解码错误），所有模式下都
        // 按失败处理，partial 语义不变。
        assert(
            selection.failedFileCount == 0 || hardFullBypassesFailureMemory,
            "[dsh-scan] stat 失败必须在上方提前 return，不得混入本轮聚合"
        )
        let snapshot = buildSnapshot(
            aggregate: outcome.aggregate,
            sessionsRoot: sessionsRoot,
            calendar: calendar,
            now: scanNow,
            limits: limits,
            isTruncated: isBudgetTruncated
        )
        if outcome.failedFileCount > 0 {
            // Never replace a complete last-good snapshot with an aggregate
            // that silently omits failed files. Keep the old view visible and
            // return an explicitly partial result so the base lifecycle keeps
            // the source dirty/failed for the next reconcile.
            // Keep the index completely unchanged. The file fingerprints and
            // aggregate snapshot must describe the same source set; advancing
            // only successful fingerprints would allow a later deletion to
            // falsely hit the old aggregate forever.
            let lastGood = index.snapshot.map {
                rebaseCached($0, calendar: calendar, now: scanNow)
            } ?? snapshot
            return Self.markPartial(lastGood)
        }
        index = DshCacheIndex(
            version: 8,
            files: outcome.processedFingerprints,
            snapshot: snapshot,
            calendarSignature: currentCalendarSignature
        )
        try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        logInfo(
            "[dsh-scan] ✓ sessions=\(snapshot.sessionCount), providers=\(snapshot.byProvider.count), "
                + "events=\(snapshot.eventCount)"
                + (outcome.failedFileCount > 0 ? ", skippedFailedFiles=\(outcome.failedFileCount)" : "")
        )
        return snapshot
    }

    override nonisolated func scanResultIsComplete(_ result: DshLocalUsage) -> Bool {
        result.isPartial != true
    }

    private nonisolated static func markPartial(_ snapshot: DshLocalUsage) -> DshLocalUsage {
        var partial = snapshot
        partial.isPartial = true
        return partial
    }

    /// Select which session files participate in a scan. All valid snapshots are
    /// collected first, ordered newest-first (mtime desc, path asc as a stable
    /// tie-breaker), and only then capped by `maxSessionFiles` and
    /// `maxTotalRawBytes`. Selecting before capping keeps the newest sessions
    /// when the directory holds more artifacts than the limits allow.
    nonisolated static func selectSessionSnapshots(
        filePaths: [URL],
        fileManager: FileManagerBox,
        limits: DshLocalUsageScanLimits,
        snapshotReader: ((URL) throws -> DshLogFileSnapshot)? = nil
    ) -> DshFileSelection {
        LogFileSelector.select(
            filePaths: filePaths,
            fileManager: fileManager,
            maxSessionFiles: limits.maxSessionFiles,
            maxTotalRawBytes: limits.maxTotalRawBytes,
            snapshotReader: snapshotReader,
            onWarning: { url, error in
                logWarn(
                    "[dsh-scan] 无法读取 session 文件属性，保留 last-good cache: "
                        + "\(url.path), error: \(errorSummary(error))"
                )
            }
        )
    }

    /// Unified recent-samples contract shared by full scans and cached rebases:
    /// keep at most the last `LocalUsageRetentionWindow.days` calendar days
    /// (today plus the previous 7, which fully covers the 7-day daily window
    /// across midnight rebases), oldest-to-newest, capped at `maxCount`.
    nonisolated static func boundedRecentSamples(
        _ samples: [LocalTokenUsageSample],
        calendar: Calendar,
        now: Date,
        maxCount: Int
    ) -> [LocalTokenUsageSample] {
        boundedRecentSampleResult(samples, calendar: calendar, now: now, maxCount: maxCount).samples
    }

    private nonisolated static func boundedRecentSampleResult(
        _ samples: [LocalTokenUsageSample],
        calendar: Calendar,
        now: Date,
        maxCount: Int
    ) -> (samples: [LocalTokenUsageSample], truncated: Bool, latestOmittedAt: Date?) {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(LocalUsageRetentionWindow.days - 1),
            to: calendar.startOfDay(for: now)
        ) else {
            return ([], false, nil)
        }
        let eligible = samples
            .filter { $0.completedAt >= cutoff }
            .sorted { $0.completedAt < $1.completedAt }
        let truncated = eligible.count > maxCount
        let latestOmittedAt = truncated ? eligible[eligible.count - maxCount - 1].completedAt : nil
        return (Array(eligible.suffix(maxCount)), truncated, latestOmittedAt)
    }

    /// Reapply the current seven-day window to a cached snapshot. This keeps a
    /// healthy app from re-reading large logs just because midnight crossed.
    nonisolated static func rebaseCached(
        _ snapshot: DshLocalUsage,
        calendar: Calendar,
        now: Date,
        limits: DshLocalUsageScanLimits = .production
    ) -> DshLocalUsage {
        let rebasedProviders = snapshot.byProvider.mapValues { provider in
            let daily = DailyUsageAggregation.filterLast7Days(
                allDaily: provider.dailyTokenUsage,
                today: calendar.startOfDay(for: now),
                calendar: calendar
            )
            let sampleResult = boundedRecentSampleResult(
                provider.recentSamples,
                calendar: calendar,
                now: now,
                maxCount: limits.maxRecentSamples
            )
            let wasPreviouslyTruncated = provider.recentSamplesTruncated
            let retentionCutoff = calendar.date(
                byAdding: .day,
                value: -(LocalUsageRetentionWindow.days - 1),
                to: calendar.startOfDay(for: now)
            )
            let priorOmissionsStillRetained: Bool
            if wasPreviouslyTruncated == nil {
                priorOmissionsStillRetained = true
            } else if let latestOmitted = provider.latestOmittedSampleAt, let retentionCutoff {
                priorOmissionsStillRetained = latestOmitted >= retentionCutoff
            } else {
                priorOmissionsStillRetained = wasPreviouslyTruncated == true
            }
            let samplesTruncated = priorOmissionsStillRetained || sampleResult.truncated
            return DshProviderUsage(
                today: daily.last.flatMap { $0.hasActivity ? $0 : nil },
                dailyTokenUsage: daily,
                sessionCount: provider.sessionCount,
                roundCount: provider.roundCount,
                recentSamples: sampleResult.samples,
                recentSamplesTruncated: samplesTruncated,
                latestOmittedSampleAt: sampleResult.latestOmittedAt
                    ?? (priorOmissionsStillRetained ? provider.latestOmittedSampleAt : nil)
            )
        }
        // isTruncated 描述的是聚合数字本身的口径（是否被预算截断），不是新鲜
        // 度标记，所以窗口重算时保留；isPartial 是新鲜度标记，刻意不在此保留，
        // 由各扫描路径按当轮结果重新置位（markPartial）。
        return DshLocalUsage(
            byProvider: rebasedProviders,
            modelsByProvider: snapshot.modelsByProvider,
            sessionsRoot: snapshot.sessionsRoot,
            sessionCount: snapshot.sessionCount,
            eventCount: snapshot.eventCount,
            scannedAt: snapshot.scannedAt,
            isTruncated: snapshot.isTruncated,
            recentSamplesLimit: snapshot.recentSamplesLimit
        )
    }
}

// MARK: - LocalUsageScanner conformance
// conformance（lastResultPublisher / isScanningPublisher）由 LocalUsageScannerBase 提供。

// MARK: - Parsed data

typealias DshLogFileSnapshot = LogFileSnapshot
typealias DshLogFileFingerprint = LogFileFingerprint
typealias DshFileSelection = LogFileSelection

private struct DshRawEvent: Decodable {
    let type: String
    let seq: Int?
    let time: Int?
    let data: DshRawEventData?
}

private struct DshRawEventData: Decodable {
    let turn: Int?
    let step: Int?
    let usage: DshRawUsage?
    let message: DshRawMessage?
    let provider: String?
    let model: String?
    let contextWindow: Int?
    // v3/v4 的 chunk 流打包在 `assistant/message.data.stream[]` 里，逐条自带
    // time（v1 的 message 无此字段）。随 message 行一起进 JSONDecoder——message
    // 行本来就已解码，增量成本可接受；数组内其余字段由 JSONDecoder 自动忽略，
    // 不做局部手写解析。
    let stream: [DshStreamTimeEntry]?
}

/// v3/v4 `assistant/message.data.stream[]` 条目：TTFT 只取首条的 `time`，
/// 其余字段（type/chunk 等）由 JSONDecoder 忽略。
private struct DshStreamTimeEntry: Decodable {
    let time: Int64?
}

private struct DshRawMessage: Decodable {
    let content: [DshRawContentBlock]?
}

private struct DshRawContentBlock: Decodable {
    let type: String?
    let text: String?
    let arguments: String?
}

private struct DshRawUsage: Decodable {
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
}

private struct DshProviderContext: Sendable {
    let provider: String
    let model: String?
}

private struct DshParsedUsage: Sendable {
    let timestamp: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    /// 单次模型调用时长（`assistant/message.time` − 对应 `step/start.time`，秒）。
    /// 解析期差分好再落 `DshFileParseResult`，缓存命中时无需重放事件序。
    /// nil = step/start 缺失、turn/step 对不上或差值非法。
    let durationSeconds: Double?
    /// 单次调用首字延迟（秒）。v1：该 step 首条 `assistant/chunk.time` −
    /// `step/start.time`；v3/v4：`assistant/message.data.stream[0].time` −
    /// `step/start.time`。nil = 非流式调用、两种首 chunk 证据缺失、key 对不上
    /// 或差值非正。
    let ttftSeconds: Double?
    let turn: Int?
    let step: Int?
    let seq: Int?
    let provider: String
    let model: String?
    let sessionID: String
}

private struct DshFileParseResult: Sendable {
    let usages: [DshParsedUsage]
    let activeProviders: Set<String>
}

/// 只缓存解析结果，不缓存聚合结果：聚合仍然会从每个文件的结果重新计算，
/// 因而文件新增、删除、窗口变化和失败重试都不会受到旧聚合状态污染。
private final class DshParsedFileCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: DshLogFileFingerprint
        let limitsKey: String
        let result: DshFileParseResult
    }

    private let lock = NSLock()
    private let maximumEntryCount: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    init(maximumEntryCount: Int) {
        self.maximumEntryCount = max(maximumEntryCount, 1)
    }

    var capacity: Int { maximumEntryCount }

    func value(
        for snapshot: DshLogFileSnapshot,
        limits: DshLocalUsageScanLimits
    ) -> DshFileParseResult? {
        let key = snapshot.url.path
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key],
              entry.fingerprint == snapshot.fingerprint,
              entry.limitsKey == limits.cacheKey else {
            return nil
        }
        touch(key)
        return entry.result
    }

    func store(
        _ result: DshFileParseResult,
        for snapshot: DshLogFileSnapshot,
        limits: DshLocalUsageScanLimits
    ) {
        let key = snapshot.url.path
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(
            fingerprint: snapshot.fingerprint,
            limitsKey: limits.cacheKey,
            result: result
        )
        touch(key)
        while recency.count > maximumEntryCount {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }

    func removeAll(except paths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { paths.contains($0.key) }
        recency.removeAll { !paths.contains($0) }
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

private struct DshMutableProviderAggregate: Sendable {
    var daily: [Date: DshDailyUsage] = [:]
    var turnsByDay: [Date: Set<String>] = [:]
    var sessions: Set<String> = []
    var models: Set<String> = []
    var recentSamples: [LocalTokenUsageSample] = []
}

private struct DshAggregate: Sendable {
    var providers: [String: DshMutableProviderAggregate] = [:]
    var sessions: Set<String> = []
    var eventCount: Int = 0
    var modelProviders: [String: Set<String>] = [:]
}

// MARK: - Parsing helpers

private struct DshFileAggregationOutcome: Sendable {
    var aggregate = DshAggregate()
    /// Fingerprints of files that were fully read, decompressed, and parsed.
    /// Files that failed are deliberately excluded so the cache never records
    /// them as successfully processed; the next scan retries them.
    var processedFingerprints: [DshLogFileFingerprint] = []
    var failedFileCount = 0
}

private extension DshLocalUsageScanner {
    private nonisolated static func aggregateFiles(
        snapshots: [DshLogFileSnapshot],
        sessionsRoot: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        decompressor: Decompressor?,
        streamingDecompressor: @escaping StreamingDecompressor,
        limits: DshLocalUsageScanLimits,
        forceFull: Bool
    ) throws -> DshFileAggregationOutcome {
        var outcome = DshFileAggregationOutcome()
        // Keep the newest cache-capacity files as a fixed hot set. Files beyond
        // that set are still parsed and aggregated, but are deliberately not
        // inserted into the cache so they cannot evict any hot entry while a
        // scan walks the complete (potentially much larger) selected set.
        let orderedSnapshots = snapshots.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path < $1.url.path
        }
        let hotCachePaths = Set(
            orderedSnapshots.prefix(parsedFileCache.capacity).map { $0.url.path }
        )
        parsedFileCache.removeAll(except: hotCachePaths)
        for snapshot in orderedSnapshots {
            try Task.checkCancellation()
            do {
                let result: DshFileParseResult
                if !forceFull, let cached = parsedFileCache.value(
                    for: snapshot,
                    limits: limits
                ) {
                    result = cached
                } else {
                    if snapshot.url.lastPathComponent.lowercased().hasSuffix(".zstd")
                        || snapshot.url.lastPathComponent.lowercased().hasSuffix(".zst") {
                        if let decompressor {
                            // 注入式内存解压器是测试注入点（生产 decompressor 恒为 nil，
                            // 走下方流式解压）。输入必须分块读入并受 maxTotalRawBytes 硬
                            // 上限约束：selection 只保证 stat 时刻的字节数，读取期间文件可
                            // 能被继续追加，不能把超预算的整文件一次性载入堆；解压结果与
                            // 流式路径共用同一上限，超限按单文件失败隔离、下一轮重试，
                            // 与 decompressToFile 的 outputTooLarge 语义一致。
                            let compressed = try readCompressedInput(from: snapshot.url, limits: limits)
                            let data = try decompressor(compressed)
                            try DshLogDecoder.checkDecompressedByteCount(data.count)
                            result = try parseFile(
                                data: data,
                                sessionID: snapshot.url.deletingLastPathComponent().lastPathComponent,
                                limits: limits
                            )
                        } else {
                            let temporary = try fileManager.temporaryURL()
                            defer { try? fileManager.removeItem(at: temporary) }
                            try streamingDecompressor(snapshot.url, temporary, fileManager)
                            result = try parseFile(
                                fileURL: temporary,
                                sessionID: snapshot.url.deletingLastPathComponent().lastPathComponent,
                                limits: limits
                            )
                        }
                    } else {
                        // 明文 JSONL 同样走流式解析：maxTotalRawBytes 已放宽到
                        // 1GB，单个大文件若用 Data(contentsOf:) 全量读入会一次性
                        // 占满整个字节预算的堆内存；parseFile(fileURL:) 的行缓冲
                        // 受 maxJSONLLineBytes 约束，峰值内存与文件大小无关。
                        result = try parseFile(
                            fileURL: snapshot.url,
                            sessionID: snapshot.url.deletingLastPathComponent().lastPathComponent,
                            limits: limits
                        )
                    }
                    if hotCachePaths.contains(snapshot.url.path) {
                        parsedFileCache.store(result, for: snapshot, limits: limits)
                    }
                }
                outcome.processedFingerprints.append(snapshot.fingerprint)
                guard !result.usages.isEmpty else { continue }
                for usage in result.usages {
                    try Task.checkCancellation()
                    add(usage, to: &outcome.aggregate, calendar: calendar, limits: limits)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单文件可恢复错误：隔离坏文件，其余 snapshot 继续聚合。
                // 日志只含路径/阶段/错误摘要，不落原始内容。
                outcome.failedFileCount += 1
                logWarn(
                    "[dsh-scan] 跳过无法读取的 session 文件（已隔离，下一轮重试）: "
                        + "\(snapshot.url.path), error: \(errorSummary(error))"
                )
            }
        }
        return outcome
    }

    private nonisolated static func errorSummary(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(200))
    }

    /// 注入式内存解压器的输入读取：FileHandle 分块读入，受 maxTotalRawBytes
    /// 硬上限约束（selection 按读取前的 stat 截断，读取期间文件继续增长时在
    /// 预算处停止并抛错，由 aggregateFiles 按单文件失败隔离；截断的压缩前缀
    /// 本身也无法解压，不按前缀继续）。取消检查按分块进行，与
    /// parseFile(fileURL:) 的粒度一致。
    private nonisolated static func readCompressedInput(
        from url: URL,
        limits: DshLocalUsageScanLimits
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = limits.maxTotalRawBytes - data.count
            guard remaining > 0 else {
                // 预算读满后仍有剩余字节，说明文件已超过单轮扫描的压缩字节预算。
                guard let extra = try handle.read(upToCount: 1), extra.isEmpty else {
                    throw DshLogDecoder.DecoderError.inputTooLarge(bytes: data.count)
                }
                return data
            }
            guard let chunk = try handle.read(upToCount: min(limits.readChunkBytes, remaining)),
                  !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
        }
    }

    /// 内存全量解析变体。生产路径（明文 JSONL 与流式解压）已统一走
    /// `parseFile(fileURL:)`；这里仅供注入的内存解压器（测试场景）使用，
    /// 行级语义与流式变体保持一致。
    private nonisolated static func parseFile(
        data: Data,
        sessionID: String,
        limits: DshLocalUsageScanLimits
    ) throws -> DshFileParseResult {
        var context: DshProviderContext?
        var stepStarts: [String: Int] = [:]
        var stepFirstChunkMs: [String: Int] = [:]
        var usages: [DshParsedUsage] = []
        var activeProviders = Set<String>()
        var seen = Set<String>()
        let decoder = JSONDecoder()
        var offset = 0
        var lineCount = 0
        while offset < data.count {
            try Task.checkCancellation()
            let searchStart = data.index(data.startIndex, offsetBy: offset)
            let newline = data[searchStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let lineLength = newline - offset
            lineCount += 1
            if lineLength > limits.maxJSONLLineBytes {
                offset = newline == data.endIndex ? data.endIndex : newline + 1
                continue
            }
            if lineLength > 0 {
                let line = data.subdata(in: offset..<newline)
                consumeLine(
                    line,
                    sessionID: sessionID,
                    decoder: decoder,
                    limits: limits,
                    context: &context,
                    stepStarts: &stepStarts,
                    stepFirstChunkMs: &stepFirstChunkMs,
                    usages: &usages,
                    activeProviders: &activeProviders,
                    seen: &seen
                )
            }
            offset = newline == data.endIndex ? data.endIndex : newline + 1
            if lineCount > limits.maxSessionFiles * 10_000 { break }
        }
        return DshFileParseResult(usages: usages, activeProviders: activeProviders)
    }

    /// Parse a decompressed artifact directly from disk. The line buffer is bounded by
    /// `maxJSONLLineBytes`, so the full decompressed session never exists in memory.
    /// 行级语义（换行切分、超长行跳过、行数上限、dedup seen-set）与 `parseFile(data:)`
    /// 保持一致；取消检查按读取分块进行（粒度受 readChunkBytes 约束），且取消必须
    /// 抛出 CancellationError 而不是静默返回半解析结果——否则半结果会被当作成功
    /// 写入 parsedFileCache，后续扫描命中缓存后永远缺失该文件的尾部数据。
    private nonisolated static func parseFile(
        fileURL: URL,
        sessionID: String,
        limits: DshLocalUsageScanLimits
    ) throws -> DshFileParseResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        var context: DshProviderContext?
        var stepStarts: [String: Int] = [:]
        var stepFirstChunkMs: [String: Int] = [:]
        var usages: [DshParsedUsage] = []
        var activeProviders = Set<String>()
        var seen = Set<String>()
        var pending = Data()
        pending.reserveCapacity(min(limits.readChunkBytes, limits.maxJSONLLineBytes))
        var discardingOversizedLine = false
        var lineCount = 0

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: limits.readChunkBytes), !chunk.isEmpty else {
                break
            }
            if discardingOversizedLine {
                guard let newline = chunk.firstIndex(of: 0x0A) else {
                    continue
                }
                pending.append(chunk[chunk.index(after: newline)...])
                discardingOversizedLine = false
                // 跨块超长行同样计入行数上限（与 parseFile(data:) 一致），
                // 防止用无换行的超长行无限填充绕过行数预算。
                lineCount += 1
                if lineCount > limits.maxSessionFiles * 10_000 {
                    return DshFileParseResult(usages: usages, activeProviders: activeProviders)
                }
            } else {
                pending.append(chunk)
            }

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                lineCount += 1

                if !discardingOversizedLine, line.count <= limits.maxJSONLLineBytes {
                    consumeLine(
                        line,
                        sessionID: sessionID,
                        decoder: decoder,
                        limits: limits,
                        context: &context,
                        stepStarts: &stepStarts,
                        stepFirstChunkMs: &stepFirstChunkMs,
                        usages: &usages,
                        activeProviders: &activeProviders,
                        seen: &seen
                    )
                }
                discardingOversizedLine = false
                if lineCount > limits.maxSessionFiles * 10_000 {
                    return DshFileParseResult(usages: usages, activeProviders: activeProviders)
                }
            }

            if !discardingOversizedLine && pending.count > limits.maxJSONLLineBytes {
                pending.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
            }
        }

        if !discardingOversizedLine, !pending.isEmpty,
           pending.count <= limits.maxJSONLLineBytes {
            consumeLine(
                pending,
                sessionID: sessionID,
                decoder: decoder,
                limits: limits,
                context: &context,
                stepStarts: &stepStarts,
                stepFirstChunkMs: &stepFirstChunkMs,
                usages: &usages,
                activeProviders: &activeProviders,
                seen: &seen
            )
        }
        return DshFileParseResult(usages: usages, activeProviders: activeProviders)
    }

    /// 一级过滤 marker 的字节形态：只有命中这些 marker 的行才可能被
    /// `consumeLine` 消费，其余行（tool-call 等占解压后字节的大多数）无需进
    /// JSONDecoder。marker 为纯 ASCII，不会出现在 UTF-8 多字节序列内部，
    /// 字节级命中与解码后的 type 判断一致，不会漏判。step/start / step/end
    /// 只为差分出单次调用时长（发起时刻表进、清除防泄漏），不产 token。
    /// assistant/chunk 只为差分单次调用 TTFT（每 step 首条才被解析，见
    /// `consumeLine` 的节流注释）；v3/v4 文件的 chunk 流打包在
    /// `assistant/message.data.stream[]` 里（无独立 chunk 行），TTFT 走
    /// message 侧的 stream 差分路径。
    private nonisolated static let requestContextMarker = Data("request/context".utf8)
    private nonisolated static let assistantMessageMarker = Data("assistant/message".utf8)
    private nonisolated static let stepStartMarker = Data("step/start".utf8)
    private nonisolated static let stepEndMarker = Data("step/end".utf8)
    private nonisolated static let assistantChunkMarker = Data("assistant/chunk".utf8)

    private nonisolated static func consumeLine(
        _ line: Data,
        sessionID: String,
        decoder: JSONDecoder,
        limits: DshLocalUsageScanLimits,
        context: inout DshProviderContext?,
        stepStarts: inout [String: Int],
        stepFirstChunkMs: inout [String: Int],
        usages: inout [DshParsedUsage],
        activeProviders: inout Set<String>,
        seen: inout Set<String>
    ) {
        // assistant/chunk 占解压后字节的大头，但它只在「尚有 step 未记录到首条
        // chunk」时才有信息量（每 step 只取第一条 → TTFT）。字节级节流：所有
        // pending step 都已见过首 chunk 后，纯 chunk 行不再进 JSONDecoder，按
        // 字节扫描直接跳过；首个 step/start 会重新打开解码窗口。
        let hasChunkMarker = line.range(of: assistantChunkMarker) != nil
        if hasChunkMarker,
           line.range(of: requestContextMarker) == nil,
           line.range(of: assistantMessageMarker) == nil,
           line.range(of: stepStartMarker) == nil,
           line.range(of: stepEndMarker) == nil,
           !stepStarts.keys.contains(where: { stepFirstChunkMs[$0] == nil }) {
            return
        }
        guard line.isEmpty == false,
              line.count <= limits.maxJSONLLineBytes,
              // 字节级预过滤：与用量无关的行不进 JSONDecoder（解压后逐行
              // decode 是 DSH 扫描的主要 CPU 成本）
              line.range(of: requestContextMarker) != nil
                  || line.range(of: assistantMessageMarker) != nil
                  || line.range(of: stepStartMarker) != nil
                  || line.range(of: stepEndMarker) != nil
                  || hasChunkMarker,
              let event = try? decoder.decode(DshRawEvent.self, from: line) else {
            return
        }
        if event.type == "request/context" {
            let provider = normalizedProvider(event.data?.provider)
            if provider != "unknown" {
                context = DshProviderContext(
                    provider: provider,
                    model: normalizedOptionalString(event.data?.model)
                )
            }
        } else if event.type == "step/start" {
            // 记录本次模型调用的发起时刻；step/end 清除防泄漏，assistant/message
            // 命中即弹出（同一步不应二次计价）。turn/step 缺一的事件没有稳定
            // 归属键，assistant/message 侧同样要求两者齐全，对不上自然落 nil。
            if let turn = event.data?.turn, let step = event.data?.step, let time = event.time {
                stepStarts[stepStartKey(sessionID: sessionID, turn: turn, step: step)] = time
            }
        } else if event.type == "step/end" {
            if let turn = event.data?.turn, let step = event.data?.step {
                let key = stepStartKey(sessionID: sessionID, turn: turn, step: step)
                stepStarts.removeValue(forKey: key)
                stepFirstChunkMs.removeValue(forKey: key)
            }
        } else if event.type == "assistant/chunk" {
            // 每 step 只认首条 chunk（首个流式输出块的到达时刻 = 首 token 时刻）。
            // turn/step 缺一无法与 step/start 配对，直接跳过；重复 chunk（首条已
            // 记录）也跳过。v4 文件无此事件类型（chunk 聚合进 attempt.data.stream），
            // 相应调用自然落 nil。
            if let turn = event.data?.turn, let step = event.data?.step, let timeMs = event.time {
                let key = stepStartKey(sessionID: sessionID, turn: turn, step: step)
                if stepStarts[key] != nil, stepFirstChunkMs[key] == nil {
                    stepFirstChunkMs[key] = timeMs
                }
            }
        } else if event.type == "assistant/message",
                  let usage = event.data?.usage,
                  let timestamp = event.time.map({ Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }) {
            let provider = context?.provider ?? "unknown"
            let key = usageKey(
                sessionID: sessionID,
                provider: provider,
                turn: event.data?.turn,
                step: event.data?.step,
                seq: event.seq,
                time: event.time
            )
            // Dedup only skips aggregation of this line. It must not stop the
            // surrounding reader from advancing to the next line.
            if seen.insert(key).inserted {
                // 时长差分：assistant/message.time − step/start.time（毫秒），覆盖
                // 发起→完成的完整调用窗口（含 TTFT、不含工具执行——工具在
                // assistant/message 之后）。step/start 缺失、key 对不上、差值非正
                // 或超 1h（账本异常）都落 nil，宁缺勿假。
                var durationSeconds: Double? = nil
                var ttftSeconds: Double? = nil
                if let turn = event.data?.turn, let step = event.data?.step, let timeMs = event.time {
                    let anchorKey = stepStartKey(sessionID: sessionID, turn: turn, step: step)
                    if let startMs = stepStarts.removeValue(forKey: anchorKey) {
                        let deltaMs = timeMs - startMs
                        if deltaMs > 0, deltaMs <= 3_600_000 {
                            durationSeconds = Double(deltaMs) / 1000.0
                        }
                        // TTFT 差分 v1 路径：该 step 首条 assistant/chunk.time −
                        // step/start.time（毫秒）。缺失（非流式调用）或差值非正 →
                        // nil；此处只做忠实换算，范围过滤归聚合层。
                        if let firstChunkMs = stepFirstChunkMs.removeValue(forKey: anchorKey) {
                            let ttftDeltaMs = firstChunkMs - startMs
                            if ttftDeltaMs > 0 {
                                ttftSeconds = Double(ttftDeltaMs) / 1000.0
                            }
                        }
                        // TTFT 差分 v3/v4 路径：chunk 流打包在 message.data.stream[]
                        // 里，首条 time 即首 token 时刻。v1 的 message 无 stream 字段、
                        // v3/v4 无独立 chunk 行，两条路天然互斥；stream 首条 time 有效
                        // 且差值为正时以它为准，缺失或非正则沿用上面的 chunk 行结果
                        // （真实账本中两者同为 nil）。
                        if let firstStreamMs = event.data?.stream?.first?.time {
                            let ttftDeltaMs = Int(firstStreamMs) - startMs
                            if ttftDeltaMs > 0 {
                                ttftSeconds = Double(ttftDeltaMs) / 1000.0
                            }
                        }
                    }
                }
                let parsed = normalizeUsage(
                    usage,
                    provider: provider,
                    model: context?.model,
                    message: event.data?.message
                )
                usages.append(DshParsedUsage(
                    timestamp: timestamp,
                    inputTokens: parsed.input,
                    cacheReadTokens: parsed.cacheRead,
                    cacheWriteTokens: parsed.cacheWrite,
                    outputTokens: parsed.output,
                    reasoningTokens: parsed.reasoning,
                    durationSeconds: durationSeconds,
                    ttftSeconds: ttftSeconds,
                    turn: event.data?.turn,
                    step: event.data?.step,
                    seq: event.seq,
                    provider: provider,
                    model: context?.model,
                    sessionID: sessionID
                ))
                activeProviders.insert(provider)
            }
        }
    }

    private nonisolated static func add(
        _ usage: DshParsedUsage,
        to aggregate: inout DshAggregate,
        calendar: Calendar,
        limits: DshLocalUsageScanLimits
    ) {
        let day = calendar.startOfDay(for: usage.timestamp)
        var provider = aggregate.providers[usage.provider, default: DshMutableProviderAggregate()]
        let existing = provider.daily[day]
            ?? DshDailyUsage(dayStart: day)
        let buckets = TokenAccountingCatalog.dsh.normalizedBuckets(
            rawInput: usage.inputTokens,
            cacheRead: usage.cacheReadTokens,
            rawOutput: usage.outputTokens,
            rawReasoning: usage.reasoningTokens
        )
        provider.daily[day] = DshDailyUsage(
            dayStart: day,
            inputTokens: SaturatingArithmetic.add(existing.inputTokens, buckets.input),
            outputTokens: SaturatingArithmetic.add(existing.outputTokens, buckets.output),
            cacheReadTokens: SaturatingArithmetic.add(existing.cacheReadTokens, buckets.cacheRead),
            cacheWriteTokens: SaturatingArithmetic.add(existing.cacheWriteTokens, usage.cacheWriteTokens),
            reasoningTokens: SaturatingArithmetic.add(existing.reasoningTokens, buckets.reasoning),
            totalTokens: SaturatingArithmetic.add(
                existing.totalTokens,
                buckets.totalTokens
            ),
            turns: existing.turns,
            rounds: SaturatingArithmetic.add(existing.rounds, 1)
        )
        let turnKey = usage.turn.map { "\(usage.sessionID):turn:\($0)" } ?? "event:\(usage.sessionID):\(usage.seq ?? 0)"
        if provider.turnsByDay[day, default: []].insert(turnKey).inserted {
            provider.daily[day] = provider.daily[day]?.withIncrementedTurns()
        }
        provider.sessions.insert(usage.sessionID)
        if let model = usage.model, !model.isEmpty {
            provider.models.insert(model)
        }
        let promptID = usage.turn.map {
            "dsh:\(usage.sessionID):turn:\($0)"
        } ?? "dsh:\(usage.sessionID):event:\(usage.seq ?? 0):\(usage.timestamp.timeIntervalSince1970)"
        let sample = LocalTokenUsageSample(
            completedAt: usage.timestamp,
            modelName: usage.model,
            promptID: promptID,
            inputTokens: buckets.cacheInclusiveInput,
            cachedInputTokens: buckets.cacheRead,
            outputTokens: buckets.output,
            reasoningOutputTokens: buckets.reasoning,
            // DSH stores uncached input and cache-read tokens separately. We
            // fold them into `inputTokens` here so all scanners feed
            // `tokenComponents` with the same cache-inclusive input bucket.
            // The `sourceProviderID` marker stays so diagnostics can still
            // tell where each sample came from.
            sourceProviderID: "dsh:\(usage.provider)",
            durationSeconds: usage.durationSeconds,
            ttftSeconds: usage.ttftSeconds
        )
        provider.recentSamples.append(sample)
        aggregate.providers[usage.provider] = provider
        aggregate.sessions.insert(usage.sessionID)
        aggregate.eventCount = SaturatingArithmetic.add(aggregate.eventCount, 1)
        if let model = usage.model, !model.isEmpty {
            aggregate.modelProviders[usage.provider, default: []].insert(model)
        }
    }

    private nonisolated static func buildSnapshot(
        aggregate: DshAggregate,
        sessionsRoot: URL,
        calendar: Calendar,
        now: Date,
        limits: DshLocalUsageScanLimits = .production,
        isTruncated: Bool = false
    ) -> DshLocalUsage {
        let today = calendar.startOfDay(for: now)
        var providers: [String: DshProviderUsage] = [:]
        for (providerID, mutable) in aggregate.providers {
            let allDaily = mutable.daily.values.sorted { $0.dayStart < $1.dayStart }
            let recent7 = DailyUsageAggregation.filterLast7Days(
                allDaily: allDaily,
                today: today,
                calendar: calendar
            )
            let sampleResult = boundedRecentSampleResult(
                mutable.recentSamples,
                calendar: calendar,
                now: now,
                maxCount: limits.maxRecentSamples
            )
            providers[providerID] = DshProviderUsage(
                today: recent7.last.flatMap { $0.hasActivity ? $0 : nil },
                dailyTokenUsage: recent7,
                sessionCount: mutable.sessions.count,
                roundCount: SaturatingArithmetic.sum(allDaily.lazy.map(\.rounds)),
                recentSamples: sampleResult.samples,
                recentSamplesTruncated: sampleResult.truncated,
                latestOmittedSampleAt: sampleResult.latestOmittedAt
            )
        }
        return DshLocalUsage(
            byProvider: providers,
            modelsByProvider: aggregate.modelProviders.mapValues { $0.sorted() },
            sessionsRoot: sessionsRoot.path,
            sessionCount: aggregate.sessions.count,
            eventCount: aggregate.eventCount,
            scannedAt: now,
            isTruncated: isTruncated,
            recentSamplesLimit: limits.maxRecentSamples
        )
    }

    private nonisolated static func normalizeUsage(
        _ usage: DshRawUsage,
        provider: String,
        model: String?,
        message: DshRawMessage?
    ) -> (
        input: Int,
        cacheRead: Int,
        cacheWrite: Int,
        output: Int,
        reasoning: Int
    ) {
        let output = max(0, usage.outputTokens ?? 0)
        let nativeReasoning = max(0, usage.reasoningTokens ?? 0)
        let reasoning = nativeReasoning > 0
            ? min(nativeReasoning, output)
            : estimateM3ReasoningTokens(
                rawOutput: output,
                provider: provider,
                model: model,
                message: message
            )
        return (
            max(0, usage.inputTokens ?? 0),
            max(0, usage.cacheReadTokens ?? 0),
            max(0, usage.cacheWriteTokens ?? 0),
            output,
            reasoning
        )
    }

    /// DSH's MiniMax-M3 usage records currently expose raw output tokens but
    /// often omit reasoningTokens. The persisted message still distinguishes
    /// reasoning/text/tool-call blocks, so estimate the split locally without
    /// changing the shared accounting contract or affecting other DSH models.
    ///
    /// This is deliberately event-local: usage and content belong to the same
    /// assistant/message event, which avoids the day-level alignment problem
    /// that MiniMax Code has to solve in its separate SQLite tables.
    ///
    /// The char-proportion formula itself lives in `ReasoningCharSplit`, shared
    /// verbatim with the MiniMax Code runtime and the ZCode provider slices.
    private nonisolated static func estimateM3ReasoningTokens(
        rawOutput: Int,
        provider: String,
        model: String?,
        message: DshRawMessage?
    ) -> Int {
        guard rawOutput > 0,
              isMiniMaxM3(provider: provider, model: model),
              let blocks = message?.content,
              !blocks.isEmpty else {
            return 0
        }

        var reasoningChars = 0
        var visibleChars = 0
        for block in blocks {
            let type = block.type?.lowercased().replacingOccurrences(of: "_", with: "-")
            switch type {
            case "reasoning":
                reasoningChars = SaturatingArithmetic.add(
                    reasoningChars,
                    block.text?.count ?? 0
                )
            case "text":
                visibleChars = SaturatingArithmetic.add(
                    visibleChars,
                    block.text?.count ?? 0
                )
            case "tool-call":
                // Tool-call arguments are model-generated output and are the
                // DSH equivalent of MiniMax Code's tool_call_args bucket.
                visibleChars = SaturatingArithmetic.add(
                    visibleChars,
                    block.arguments?.count ?? 0
                )
            default:
                continue
            }
        }

        return ReasoningCharSplit.split(
            outputTokens: rawOutput,
            reasoningChars: reasoningChars,
            visibleChars: visibleChars
        )?.reasoning ?? 0
    }

    private nonisolated static func isMiniMaxM3(provider: String, model: String?) -> Bool {
        let providerID = provider.lowercased()
        guard providerID == "minimax"
                || providerID == "minimax-cn"
                || providerID == "minimax-cn-coding-plan"
        else { return false }

        let modelID = (model ?? "")
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let modelLeaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return modelLeaf == "m3"
            || modelLeaf == "minimax-m3"
            || modelLeaf.hasPrefix("minimax-m3-")
    }

    /// Replay dedup identity per `spec/harnesses/dsh.md`:
    /// - both `turn` and `step` present → `(sessionID, provider, turn, step)`;
    ///   `seq` is intentionally NOT part of the key, so a retried/replayed
    ///   logical event with a fresh `seq` still counts once.
    /// - `turn` or `step` missing → the event has no stable harness identity,
    ///   so `seq` (or the raw timestamp when `seq` is also missing) becomes the
    ///   fallback identity. Distinct malformed events stay distinct instead of
    ///   collapsing into one bucket; replays that keep the same `seq` still
    ///   dedup.
    private nonisolated static func usageKey(
        sessionID: String,
        provider: String,
        turn: Int?,
        step: Int?,
        seq: Int?,
        time: Int?
    ) -> String {
        if let turn, let step {
            return "ts:\(sessionID):\(provider):\(turn):\(step)"
        }
        let turnPart = turn.map { "t\($0)" } ?? "t-"
        let identity = seq.map { "seq\($0)" } ?? "time\(time.map(String.init) ?? "-")"
        return "fb:\(sessionID):\(provider):\(turnPart):\(identity)"
    }

    /// step 发起时刻表的归属键：`(sessionID, turn, step)`。step/start 与
    /// step/end 都不带 provider，时序归属是 harness 层概念，不掺 provider。
    private nonisolated static func stepStartKey(sessionID: String, turn: Int, step: Int) -> String {
        "\(sessionID):turn:\(turn):step:\(step)"
    }

    private nonisolated static func normalizedProvider(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private nonisolated static func normalizedOptionalString(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

private extension DshDailyUsage {
    func withIncrementedTurns() -> DshDailyUsage {
        DshDailyUsage(
            dayStart: dayStart,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: SaturatingArithmetic.add(turns, 1),
            rounds: rounds
        )
    }
}

// MARK: - Fingerprint/index

private struct CacheFingerprint: Sendable {
    let files: [DshLogFileFingerprint]

    func matches(_ other: CacheFingerprint) -> Bool {
        files == other.files
    }
}

private struct DshCacheIndex: Codable, Equatable, Sendable {
    let version: Int
    let files: [DshLogFileFingerprint]
    var snapshot: DshLocalUsage?
    var calendarSignature: String?
}

private extension DshCacheIndex {
    func matches(_ fingerprint: CacheFingerprint) -> Bool {
        // v6：样本新增 ttftSeconds（非 v4 文件每 step 首条 assistant/chunk −
        // step/start 差分）；v5 快照该字段恒为 nil，版本不匹配即整体重建。
        // v7：v3/v4 的 message.data.stream 首 chunk 时间差分接入 TTFT（v1 仍走
        // chunk 行路径）；v6 快照的 v3/v4 样本 ttft 恒为 nil，版本不匹配即整体重建。
        // v8: rebuild dates previously truncated to whole seconds.
        return version == 8 && files == fingerprint.files
    }
}

private extension DshLocalUsageScanner {
    private nonisolated static func loadIndex(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws -> DshCacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 8,
            empty: DshCacheIndex(version: 8, files: [], snapshot: nil, calendarSignature: nil),
            version: { $0.version },
            logTag: "[dsh-scan]"
        )
    }

    private nonisolated static func saveIndex(
        _ index: DshCacheIndex,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        // 不变量："partial 永不入盘"。isPartial 是新鲜度标记（markPartial 按轮
        // 动态置位），落盘的 last-good snapshot 必须以 complete 形态保存；debug
        // 断言守住 rebaseCached / 各扫描路径不会把 partial 写回 index.json。
        assert(
            index.snapshot?.isPartial != true,
            "[dsh-scan] partial snapshot 不允许写入 index.json"
        )
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }
}

