import Foundation
import Combine

/// agy（Antigravity CLI 分支）本地 transcript token 用量扫描预算。
///
/// transcript 是明文 JSONL（主文件 + 滚动分块），无压缩；预算形态与
/// `DshLocalUsageScanLimits` 一致，另加单个 cli log 文件的读取上限。
struct AgyLocalUsageScanLimits: Sendable {
    static let production = AgyLocalUsageScanLimits(
        maxSessionFiles: 1_024,
        // 明文 JSONL 字节口径；触顶按 mtime 最新优先截断，最旧 session 被
        // 挤出 7 天统计（isTruncated 置位，UI 提示口径不完整）。
        maxTotalRawBytes: 1024 * 1024 * 1024,
        maxJSONLLineBytes: 8 * 1024 * 1024,
        maxRecentSamples: 65_536,
        maxLogBytes: 16 * 1024 * 1024,
        readChunkBytes: 1024 * 1024
    )

    let maxSessionFiles: Int
    let maxTotalRawBytes: Int
    let maxJSONLLineBytes: Int
    let maxRecentSamples: Int
    /// 单个 cli log 文件的读取上限（防异常大文件整读占满内存；超限跳过该
    /// 文件的模型名，扫描本身不受影响）。
    let maxLogBytes: Int
    let readChunkBytes: Int

    init(
        maxSessionFiles: Int,
        maxTotalRawBytes: Int,
        maxJSONLLineBytes: Int,
        maxRecentSamples: Int,
        maxLogBytes: Int,
        readChunkBytes: Int = 64 * 1024
    ) {
        self.maxSessionFiles = max(maxSessionFiles, 1)
        self.maxTotalRawBytes = max(maxTotalRawBytes, 1)
        self.maxJSONLLineBytes = max(maxJSONLLineBytes, 1)
        self.maxRecentSamples = max(maxRecentSamples, 1)
        self.maxLogBytes = max(maxLogBytes, 1)
        self.readChunkBytes = max(min(readChunkBytes, self.maxJSONLLineBytes), 1)
    }
}

/// cli log 里的模型解析记录：文件名时间（本地时区）+ 正文解析出的模型名。
/// 时间线用于把 transcript 行的 UTC `created_at` join 到模型名。
struct AgyCliLogEntry: Equatable, Sendable {
    let startedAt: Date
    let modelName: String

    /// 每次运行一个文件：`cli-YYYYMMDD_HHMMSS.log`，文件名是**本地时间**。
    private static let fileNameRegex = try! NSRegularExpression(pattern: #"^cli-(\d{8})_(\d{6})\.log$"#)
    /// 模型解析行（go log 格式）：
    /// `I1004 01:02:49.791503       1 model_resolver.go:93] Resolving model gemini-3.1-pro-high`
    private static let modelRegex = try! NSRegularExpression(pattern: #"Resolving model (\S+)"#)

    static func matchesFileName(_ name: String) -> Bool {
        firstMatch(fileNameRegex, in: name) != nil
    }

    /// 解析单个 cli log。文件超限 / 文件名不可解析 / 正文无模型行 → nil
    ///（单文件隔离，不阻断时间线构建）。`formatter` 供调用方在循环内复用
    ///（缺省时经 `parseFileNameTime` 内部自建，保持既有调用兼容）。
    static func parse(
        _ url: URL,
        fileManager: FileManagerBox,
        maxLogBytes: Int,
        formatter: DateFormatter? = nil
    ) throws -> AgyCliLogEntry? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maxLogBytes else { return nil }
        guard let startedAt = parseFileNameTime(url.lastPathComponent, formatter: formatter) else { return nil }
        let text = String(decoding: try fileManager.contents(at: url), as: UTF8.self)
        // 同一次运行内模型可能被多次解析，取**最后**一条作为该次运行的模型。
        guard let match = allMatches(modelRegex, in: text).last,
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let modelName = String(text[range])
        return modelName.isEmpty ? nil : AgyCliLogEntry(startedAt: startedAt, modelName: modelName)
    }

    /// 构建文件名时间 formatter（本地时区）。DateFormatter 构造成本高，
    /// 循环场景请复用同一实例。
    static func makeFileNameTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }

    /// 文件名时间按**本地时区**解析（行内 `created_at` 是 UTC，join 时统一成
    /// 绝对时刻比较，两个语义在这里汇合）。`formatter` 缺省时内部自建。
    static func parseFileNameTime(_ name: String, formatter: DateFormatter? = nil) -> Date? {
        guard let match = firstMatch(fileNameRegex, in: name),
              match.numberOfRanges > 2,
              let dateRange = Range(match.range(at: 1), in: name),
              let timeRange = Range(match.range(at: 2), in: name) else {
            return nil
        }
        let resolved = formatter ?? makeFileNameTimeFormatter()
        return resolved.date(from: "\(name[dateRange])_\(name[timeRange])")
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func allMatches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        Array(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)))
    }
}

@MainActor
final class AgyLocalUsageScanner: LocalUsageScannerBase<AgyLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[agy-scan]"

    /// 整个扫描 pipeline 的串行锁（跨实例共享）。
    nonisolated static let pipelineMutex = AsyncMutex()

    /// 默认扫描根：`~/.gemini/antigravity-cli/brain/`（agy CLI 的会话落盘目录）。
    nonisolated static var defaultBrainRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
    }

    /// 模型名 sidecar 目录：`~/.gemini/antigravity-cli/log/`（每次运行一个
    /// `cli-*.log`）。
    nonisolated static var defaultLogDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("log", isDirectory: true)
    }

    nonisolated static let defaultCacheDir: URL = {
        TokenMonitorPaths.cacheFile(for: .agy)
    }()

    private let brainRoot: URL
    private let logDirectory: URL
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        brainRoot: URL = AgyLocalUsageScanner.defaultBrainRoot,
        logDirectory: URL = AgyLocalUsageScanner.defaultLogDirectory,
        cacheDir: URL = AgyLocalUsageScanner.defaultCacheDir,
        fileManager: FileManagerBox = FileManagerBox(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.brainRoot = brainRoot
        self.logDirectory = logDirectory
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
        // brain 下的 transcript（jsonl）与 log 下的 cli log（log）都触发 dirty；
        // transcript 追加是高频事件，指纹 diff + 缓存短路负责消化。
        configureSourceLifecycle(
            paths: [brainRoot, logDirectory],
            dynamicExtensions: ["jsonl", "log"]
        )
    }

    /// 递归发现 agy transcript 文件并按路径排序。领域专用逻辑放在 scanner。
    nonisolated static func transcriptFileURLs(
        in root: URL,
        fileManager: FileManagerBox
    ) throws -> [URL] {
        let relativePaths = try fileManager.subpathsOfDirectory(atPath: root.path)
        return relativePaths
            .filter { isTranscriptPath($0) }
            .map { root.appendingPathComponent($0) }
            .sorted { $0.path < $1.path }
    }

    /// 读取集合：主 `transcript.jsonl` + 滚动分块 `chunks/transcript/*.jsonl`。
    ///
    /// 本机 8 个 session 实测的行重叠关系（按 created_at + step_index 比对）：
    /// - `transcript.jsonl` 与 `transcript_full.jsonl` 的行集合**完全相等**
    ///   （full 是别名），只读主文件不漏；
    /// - `chunks/transcript/` 当前与主文件逐字节相同（未轮转）；轮转后旧行只
    ///   存在于分块，因此**合并读取**并用 (sessionID, created_at, step_index)
    ///   去重兜底，不重不漏；
    /// - `chunks/transcript_full/` **落后**于主文件（实测 21 行主文件只含 18
    ///   行），不读——读它会漏行，读主文件 + transcript 分块已覆盖全集。
    nonisolated static func isTranscriptPath(_ relativePath: String) -> Bool {
        let lowered = relativePath.lowercased()
        let name = URL(fileURLWithPath: lowered).lastPathComponent
        if name == "transcript.jsonl" { return true }
        // 尾斜杠保证不误匹配 chunks/transcript_full/（实测该分块集落后主文件）。
        return lowered.contains("/chunks/transcript/") && name.hasSuffix(".jsonl")
    }

    /// brain 根的下一级目录名即 session 目录名（uuid）。传入的 url 必须位于
    /// root 之下（生产路径恒成立；越界时退化为文件名，dedupe 键仍保持稳定）。
    nonisolated static func sessionID(for url: URL, in root: URL) -> String {
        let basePath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return url.lastPathComponent }
        let relative = String(path.dropFirst(basePath.count + 1))
        return relative.split(separator: "/").first.map(String.init) ?? relative
    }

    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> AgyLocalUsage? {
        guard let index = try? loadIndex(cacheDir: cacheDir, fileManager: fileManager),
              let snapshot = index.snapshot,
              index.calendarSignature == LocalUsageCalendarSignature.make(calendar) else { return nil }
        return AgyLocalUsageAggregation.rebaseCached(
            snapshot,
            calendar: calendar,
            now: now,
            limits: .production
        )
    }

    /// agy 的 pipeline：mutex 串行 + detached utility 任务承载纯文件系统扫描。
    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> AgyLocalUsage {
        let brainRoot = self.brainRoot
        let logDirectory = self.logDirectory
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        // transcript 追加是常态，启动 `.full` 与普通 dirty 一样走指纹短路；
        // 只有显式 hardFull（操作员恢复入口）绕过缓存。
        let forceFull = mode.bypassesProviderCache
        return {
            try await Self.pipelineMutex.withLock {
                try await Task.detached(priority: .utility) {
                    try Self.performScanPure(
                        brainRoot: brainRoot,
                        logDirectory: logDirectory,
                        cacheDir: cacheDir,
                        fileManager: fileManager,
                        calendar: calendar,
                        now: now,
                        limits: AgyLocalUsageScanLimits.production,
                        forceFull: forceFull
                    )
                }.value
            }
        }
    }

    override nonisolated func scanResultIsComplete(_ result: AgyLocalUsage) -> Bool {
        result.isPartial != true
    }

    private nonisolated static func markPartial(_ snapshot: AgyLocalUsage) -> AgyLocalUsage {
        var partial = snapshot
        partial.isPartial = true
        return partial
    }

    /// Pure filesystem scan。`AsyncMutex` 保证 cache 读/写与 cancel 触发的重扫
    /// 串行；generation 守门拒绝旧 in-memory 结果。
    nonisolated static func performScanPure(
        brainRoot: URL,
        logDirectory: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        limits: AgyLocalUsageScanLimits = .production,
        forceFull: Bool = false,
        snapshotReader: ((URL) throws -> AgyLogFileSnapshot)? = nil
    ) throws -> AgyLocalUsage {
        guard fileManager.fileExists(atPath: brainRoot.path) else {
            logInfo("[agy-scan] brain 目录不存在: \(brainRoot.path)")
            return AgyLocalUsage(
                dailyTokenUsage: [],
                models: [],
                recentSamples: [],
                sessionsRoot: brainRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now()
            )
        }
        try ScannerIndexIO.ensureCacheDirectory(for: cacheDir, fileManager: fileManager)

        let filePaths = try Self.transcriptFileURLs(in: brainRoot, fileManager: fileManager)
        let selection = selectFileSnapshots(
            filePaths: filePaths,
            fileManager: fileManager,
            limits: limits,
            snapshotReader: snapshotReader
        )
        let isBudgetTruncated = selection.truncatedByFileLimit || selection.byteLimited
        if isBudgetTruncated {
            logWarn(
                "[agy-scan] transcript 文件超过上限，已按 mtime 最新优先截断: "
                    + "selected=\(selection.snapshots.count), available=\(selection.availableCount)"
                    + (selection.byteLimited ? ", byteTruncated=true" : "")
            )
        }
        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let currentCalendarSignature = LocalUsageCalendarSignature.make(calendar)
        let hardFullBypassesFailureMemory = forceFull && !selection.snapshots.isEmpty
        if selection.failedFileCount > 0, !hardFullBypassesFailureMemory {
            // stat 失败不是删除证据：保留 last-good cache 并按 partial 暴露，
            // 下一轮 reconcile 重试该文件。last-good 视图必须按当前日历重算
            // 7 天窗口（对齐 DSH 同分支语义），否则跨午夜后日桶冻结在旧窗口。
            return markPartial(lastGoodOrEmpty(
                index: index,
                brainRoot: brainRoot,
                calendar: calendar,
                scanNow: now(),
                limits: limits
            ))
        }
        guard !selection.snapshots.isEmpty else {
            let empty = AgyLocalUsage(
                dailyTokenUsage: [],
                models: [],
                recentSamples: [],
                sessionsRoot: brainRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now(),
                isTruncated: isBudgetTruncated
            )
            try saveIndex(
                AgyCacheIndex(
                    version: 2,
                    files: [],
                    snapshot: empty,
                    calendarSignature: currentCalendarSignature
                ),
                cacheDir: cacheDir,
                fileManager: fileManager
            )
            return empty
        }

        // cli log 时间线：目录缺失 / 枚举失败 / 全部文件不可解析时返回空时间线，
        // 所有行走兜底（模型名缺失），不得让模型 join 失败阻断扫描。
        // 必须在指纹短路判定之前解析：log-only 变化（transcript 指纹不变）靠
        // 时间线签名让短路失效并触发全量重聚合，否则模型名刷新会被旧缓存吞掉。
        let timeline = parseCliLogTimeline(
            logDirectory: logDirectory,
            fileManager: fileManager,
            limits: limits
        )
        let fingerprint = CacheFingerprint(
            files: selection.snapshots.map(\.fingerprint),
            timelineSignature: timelineSignature(for: timeline)
        )
        let calendarChanged = index.calendarSignature != currentCalendarSignature
        if calendarChanged {
            logInfo("[agy-scan] calendar signature changed，重新解析文件以重建当前日桶")
        }
        if !forceFull, !calendarChanged, index.matches(fingerprint), let cached = index.snapshot {
            let scanNow = now()
            let rebased = AgyLocalUsageAggregation.rebaseCached(
                cached,
                calendar: calendar,
                now: scanNow,
                limits: limits
            )
            if rebased != cached {
                index.snapshot = rebased
                try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
            }
            return rebased
        }

        let scanNow = now()
        let outcome = try aggregateFiles(
            snapshots: selection.snapshots,
            brainRoot: brainRoot,
            timeline: timeline,
            calendar: calendar,
            limits: limits
        )
        if outcome.failedFileCount > 0 {
            // Never replace a complete last-good snapshot with an aggregate that
            // silently omits failed files. Keep the index completely unchanged
            // (fingerprints 与 snapshot 必须描述同一文件集) 并按 partial 暴露。
            let lastGood = index.snapshot.map {
                AgyLocalUsageAggregation.rebaseCached($0, calendar: calendar, now: scanNow, limits: limits)
            } ?? AgyLocalUsageAggregation.buildSnapshot(
                aggregate: outcome.aggregate,
                sessionsRoot: brainRoot.path,
                calendar: calendar,
                now: scanNow,
                limits: limits,
                isTruncated: isBudgetTruncated
            )
            return markPartial(lastGood)
        }
        let snapshot = AgyLocalUsageAggregation.buildSnapshot(
            aggregate: outcome.aggregate,
            sessionsRoot: brainRoot.path,
            calendar: calendar,
            now: scanNow,
            limits: limits,
            isTruncated: isBudgetTruncated
        )
        try saveIndex(
            AgyCacheIndex(
                version: 2,
                files: outcome.processedFingerprints,
                snapshot: snapshot,
                calendarSignature: currentCalendarSignature,
                timelineSignature: timelineSignature(for: timeline)
            ),
            cacheDir: cacheDir,
            fileManager: fileManager
        )
        logInfo(
            "[agy-scan] ✓ sessions=\(snapshot.sessionCount), models=\(snapshot.models.count), "
                + "events=\(snapshot.eventCount)"
                + (isBudgetTruncated ? ", truncated=true" : "")
                + (timeline.isEmpty ? ", modelJoin=unavailable" : "")
        )
        return snapshot
    }

    // MARK: - 文件选择

    /// Select which transcript files participate in a scan：mtime 最新优先，
    /// 文件数与字节预算双重截断（与 DSH 同款选择器语义）。
    nonisolated static func selectFileSnapshots(
        filePaths: [URL],
        fileManager: FileManagerBox,
        limits: AgyLocalUsageScanLimits,
        snapshotReader: ((URL) throws -> AgyLogFileSnapshot)? = nil
    ) -> AgyFileSelection {
        var candidates: [AgyLogFileSnapshot] = []
        candidates.reserveCapacity(filePaths.count)
        var failedFileURLs: [URL] = []
        for url in filePaths {
            let snapshot: AgyLogFileSnapshot?
            do {
                snapshot = try snapshotReader.map { try $0(url) }
                    ?? AgyLogFileSnapshot(url: url, fileManager: fileManager)
            } catch {
                failedFileURLs.append(url)
                logWarn(
                    "[agy-scan] 无法读取 transcript 文件属性，保留 last-good cache: "
                        + "\(url.path), error: \(errorSummary(error))"
                )
                continue
            }
            guard let snapshot else { continue }
            guard snapshot.sizeBytes > 0 else { continue }
            candidates.append(snapshot)
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.path < rhs.url.path
        }
        let fileCapped = Array(ordered.prefix(limits.maxSessionFiles))
        var selected: [AgyLogFileSnapshot] = []
        var currentBytes = 0
        var byteLimited = false
        for snapshot in fileCapped {
            let accumulated = SaturatingArithmetic.add(currentBytes, snapshot.sizeBytes)
            if accumulated > limits.maxTotalRawBytes {
                byteLimited = true
                break
            }
            currentBytes = accumulated
            selected.append(snapshot)
        }
        return AgyFileSelection(
            snapshots: selected,
            availableCount: candidates.count,
            byteLimited: byteLimited,
            failedFileCount: failedFileURLs.count
        )
    }

    // MARK: - cli log 时间线

    /// 枚举 `cli-*.log` 构建模型名时间线（升序）。任一文件失败只跳过该文件。
    nonisolated static func parseCliLogTimeline(
        logDirectory: URL,
        fileManager: FileManagerBox,
        limits: AgyLocalUsageScanLimits
    ) -> [AgyCliLogEntry] {
        guard fileManager.fileExists(atPath: logDirectory.path) else { return [] }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            logWarn("[agy-scan] cli log 目录无法枚举，模型名将全部走兜底: \(logDirectory.path)")
            return []
        }
        var entries: [AgyCliLogEntry] = []
        // 时间线解析在单个 detached task 内串行执行，线程受限；复用同一个
        // formatter，避免每个 log 文件都重建一次（DateFormatter 构造成本高）。
        let fileNameFormatter = AgyCliLogEntry.makeFileNameTimeFormatter()
        for url in urls where AgyCliLogEntry.matchesFileName(url.lastPathComponent) {
            do {
                if let entry = try AgyCliLogEntry.parse(
                    url,
                    fileManager: fileManager,
                    maxLogBytes: limits.maxLogBytes,
                    formatter: fileNameFormatter
                ) {
                    entries.append(entry)
                }
            } catch {
                logWarn(
                    "[agy-scan] 跳过无法读取的 cli log: \(url.path), error: \(errorSummary(error))"
                )
            }
        }
        return entries.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.modelName < $1.modelName
        }
    }

    /// 时间线的稳定签名：空时间线 → nil（与旧缓存 nil 对 nil 的短路兼容，空
    /// log 目录不破坏短路）；非空 → 逐条 `startedAt|modelName` 拼接。任何
    /// log 新增 / 变化都会改变签名，使指纹短路失效并触发全量重聚合。
    private nonisolated static func timelineSignature(for timeline: [AgyCliLogEntry]) -> String? {
        guard !timeline.isEmpty else { return nil }
        return timeline
            .map { "\($0.startedAt.timeIntervalSince1970)|\($0.modelName)" }
            .joined(separator: "\n")
    }

    // MARK: - 聚合

    private struct AgyFileAggregationOutcome: Sendable {
        var aggregate = AgyLocalUsageAggregation.AgyAggregate()
        /// 完整读取并解析成功的文件指纹。失败文件刻意不入缓存，下一轮重试。
        var processedFingerprints: [AgyLogFileFingerprint] = []
        var failedFileCount = 0
    }

    private nonisolated static func aggregateFiles(
        snapshots: [AgyLogFileSnapshot],
        brainRoot: URL,
        timeline: [AgyCliLogEntry],
        calendar: Calendar,
        limits: AgyLocalUsageScanLimits
    ) throws -> AgyFileAggregationOutcome {
        var outcome = AgyFileAggregationOutcome()
        // 防重复集合跨**本轮全部文件**共享：主 transcript 与其分块、分块彼此
        // 之间的重叠行都由 (sessionID, created_at, step_index) 去重兜底。
        var seen = Set<String>()
        for snapshot in snapshots {
            try Task.checkCancellation()
            do {
                let usages = try parseFile(
                    fileURL: snapshot.url,
                    sessionID: sessionID(for: snapshot.url, in: brainRoot),
                    timeline: timeline,
                    limits: limits,
                    seen: &seen
                )
                outcome.processedFingerprints.append(snapshot.fingerprint)
                for usage in usages {
                    try Task.checkCancellation()
                    AgyLocalUsageAggregation.apply(usage, to: &outcome.aggregate, calendar: calendar)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单文件可恢复错误：隔离坏文件，其余继续聚合。
                outcome.failedFileCount += 1
                logWarn(
                    "[agy-scan] 跳过无法读取的 transcript 文件（已隔离，下一轮重试）: "
                        + "\(snapshot.url.path), error: \(errorSummary(error))"
                )
            }
        }
        return outcome
    }

    /// MODEL 行的判定 marker（纯 ASCII，不会出现在 UTF-8 多字节序列内部）。
    /// 与 DSH 的字节级一级过滤同款：与用量无关的行（SYSTEM / 其他）不进
    /// JSON 解析，这是 transcript 扫描的主要 CPU 成本所在。
    private nonisolated static let modelRowMarker = Data("\"source\":\"MODEL\"".utf8)

    /// 单文件行数预算熔断（`maxSessionFiles * 10_000` 行）。必须抛错而不是
    /// 静默返回前半部分：半结果会被 aggregateFiles 视为成功并把完整指纹写入
    /// 缓存，尾部数据永久丢失；按失败隔离（failedFileCount → markPartial）
    /// 才能保住 last-good、指纹不入缓存并在下一轮重试。
    private struct AgyLineBudgetExceededError: LocalizedError {
        let fileURL: URL
        let budget: Int

        var errorDescription: String? {
            "transcript 行数超过预算 \(budget) 行，已按失败隔离: \(fileURL.path)"
        }
    }

    /// 流式解析单个 transcript 文件。行缓冲受 maxJSONLLineBytes 约束，峰值内存
    /// 与文件大小无关；取消按读取分块检查，且取消必须抛 CancellationError
    /// （静默半结果会被写进指纹缓存，尾部数据永久缺失）。
    private nonisolated static func parseFile(
        fileURL: URL,
        sessionID: String,
        timeline: [AgyCliLogEntry],
        limits: AgyLocalUsageScanLimits,
        seen: inout Set<String>
    ) throws -> [AgyParsedUsage] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var usages: [AgyParsedUsage] = []
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
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                pending.append(chunk[chunk.index(after: newline)...])
                discardingOversizedLine = false
                // 跨块超长行同样计入行数上限，防止无换行的超长行绕过预算。
                lineCount += 1
                if lineCount > limits.maxSessionFiles * 10_000 {
                    throw AgyLineBudgetExceededError(
                        fileURL: fileURL,
                        budget: limits.maxSessionFiles * 10_000
                    )
                }
            } else {
                pending.append(chunk)
            }

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                lineCount += 1

                if !discardingOversizedLine, line.count <= limits.maxJSONLLineBytes,
                   line.range(of: modelRowMarker) != nil {
                    consumeLine(
                        line,
                        sessionID: sessionID,
                        timeline: timeline,
                        limits: limits,
                        seen: &seen,
                        usages: &usages
                    )
                }
                discardingOversizedLine = false
                if lineCount > limits.maxSessionFiles * 10_000 {
                    throw AgyLineBudgetExceededError(
                        fileURL: fileURL,
                        budget: limits.maxSessionFiles * 10_000
                    )
                }
            }

            if !discardingOversizedLine, pending.count > limits.maxJSONLLineBytes {
                pending.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
            }
        }

        if !discardingOversizedLine, !pending.isEmpty,
           pending.count <= limits.maxJSONLLineBytes,
           pending.range(of: modelRowMarker) != nil {
            consumeLine(
                pending,
                sessionID: sessionID,
                timeline: timeline,
                limits: limits,
                seen: &seen,
                usages: &usages
            )
        }
        return usages
    }

    private nonisolated static func consumeLine(
        _ line: Data,
        sessionID: String,
        timeline: [AgyCliLogEntry],
        limits: AgyLocalUsageScanLimits,
        seen: inout Set<String>,
        usages: inout [AgyParsedUsage]
    ) {
        guard let row = AgyLocalUsageAggregation.parseModelRow(
            line,
            maxLineBytes: limits.maxJSONLLineBytes
        ) else { return }
        // 去重只跳过本行的聚合；外层读取循环继续推进。
        guard seen.insert(AgyLocalUsageAggregation.dedupeKey(sessionID: sessionID, row: row)).inserted else {
            return
        }
        usages.append(AgyLocalUsageAggregation.makeUsage(
            raw: row,
            sessionID: sessionID,
            modelName: AgyLocalUsageAggregation.resolvedModelName(
                createdAt: row.createdAt,
                timeline: timeline
            )
        ))
    }

    // MARK: - 私有工具

    private nonisolated static func lastGoodOrEmpty(
        index: AgyCacheIndex,
        brainRoot: URL,
        calendar: Calendar,
        scanNow: Date,
        limits: AgyLocalUsageScanLimits
    ) -> AgyLocalUsage {
        guard let snapshot = index.snapshot else {
            return AgyLocalUsage(
                dailyTokenUsage: [],
                models: [],
                recentSamples: [],
                sessionsRoot: brainRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: scanNow
            )
        }
        // 有 last-good 快照时按当前日历重算 7 天窗口并重剪样本（rebaseCached），
        // 再把 scannedAt 推进到本轮扫描时刻（scannedAt 出 ==，不影响 UI 复用
        // 判定；partial 视图的时间戳应反映这次扫描而非冻结的落盘时刻）。
        let rebased = AgyLocalUsageAggregation.rebaseCached(
            snapshot,
            calendar: calendar,
            now: scanNow,
            limits: limits
        )
        return AgyLocalUsage(
            dailyTokenUsage: rebased.dailyTokenUsage,
            models: rebased.models,
            recentSamples: rebased.recentSamples,
            sessionsRoot: rebased.sessionsRoot,
            sessionCount: rebased.sessionCount,
            eventCount: rebased.eventCount,
            scannedAt: scanNow,
            isPartial: rebased.isPartial,
            isTruncated: rebased.isTruncated
        )
    }

    private nonisolated static func errorSummary(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(200))
    }
}

// MARK: - Fingerprint/index

struct AgyLogFileSnapshot: Sendable {
    let url: URL
    let modifiedAt: Date
    let sizeBytes: Int

    init(url: URL, fileManager: FileManagerBox) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        self.url = url
        self.modifiedAt = (attributes[.modificationDate] as? Date) ?? Date.distantPast
        self.sizeBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    var fingerprint: AgyLogFileFingerprint {
        AgyLogFileFingerprint(
            path: url.path,
            modificationMs: modifiedAt.timeIntervalSince1970 * 1_000,
            sizeBytes: sizeBytes
        )
    }
}

/// Result of transcript-file selection: the newest-first slice that fits both
/// caps, plus counters for diagnostics.
struct AgyFileSelection: Sendable {
    let snapshots: [AgyLogFileSnapshot]
    /// Valid, non-empty snapshots discovered before any cap was applied.
    let availableCount: Int
    /// True when the raw-byte cap dropped at least one otherwise-selected file.
    let byteLimited: Bool
    /// Number of files whose fingerprint/stat read failed before selection.
    let failedFileCount: Int

    var truncatedByFileLimit: Bool { snapshots.count < availableCount }
}

struct AgyLogFileFingerprint: Codable, Equatable, Sendable {
    let path: String
    let modificationMs: Double
    let sizeBytes: Int
}

private struct CacheFingerprint: Sendable {
    let files: [AgyLogFileFingerprint]
    /// cli log 时间线签名（空时间线 → nil）：log-only 变化会改变签名，
    /// 防止指纹短路吞掉模型名刷新。
    let timelineSignature: String?
}

private struct AgyCacheIndex: Codable, Equatable, Sendable {
    let version: Int
    let files: [AgyLogFileFingerprint]
    var snapshot: AgyLocalUsage?
    var calendarSignature: String?
    /// 指纹短路必须同时比对的时间线签名；v2 起生效（旧 v1 缓存一次性失效重建）。
    var timelineSignature: String? = nil

    func matches(_ fingerprint: CacheFingerprint) -> Bool {
        version == 2
            && files == fingerprint.files
            && timelineSignature == fingerprint.timelineSignature
    }
}

private extension AgyLocalUsageScanner {
    private nonisolated static func loadIndex(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws -> AgyCacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 2,
            empty: AgyCacheIndex(version: 2, files: [], snapshot: nil, calendarSignature: nil),
            version: { $0.version },
            logTag: "[agy-scan]"
        )
    }

    private nonisolated static func saveIndex(
        _ index: AgyCacheIndex,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        // 不变量："partial 永不入盘"。isPartial 是新鲜度标记（markPartial 按轮
        // 动态置位），落盘的 last-good snapshot 必须以 complete 形态保存。
        assert(
            index.snapshot?.isPartial != true,
            "[agy-scan] partial snapshot 不允许写入 index.json"
        )
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }
}
