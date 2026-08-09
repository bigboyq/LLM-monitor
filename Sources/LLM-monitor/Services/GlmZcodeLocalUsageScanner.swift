import Foundation
import Combine

/// 扫描 ZCode（智谱官方 CLI）的 `~/.zcode/cli/db/db.sqlite`，产出 `GlmLocalUsage`。
///
/// GLM Coding Plan 卡片的 **native 本地数据源**：读取 `model_usage` 表中
/// `provider_id='builtin:bigmodel-coding-plan'`（正常交互）与
/// `provider_id='offpeak-idle-plan'`（闲时任务，不消耗积分）的 5 类 token，按本地自然日聚合 +
/// 7 天窗口 + 最近 8 天逐次调用样本。Reasoning 归类在 `GlmZcodeDBReader.queryPerDay`
/// 的 SQL `CASE` 内一次性走 Method A 完成（`reasoning_tokens` priority + `EXISTS` part 表
/// `type='reasoning'` 的整轮归类），不再有 scanner 端字符分摊步骤。
///
/// OpenCode 的 `zhipuai-coding-plan` 分片作为可叠加源（由 `mergeOpencodeUsage` 开关控制），
/// 与本 native 源字段相加。
///
/// 跟 minimax / antigravity scanner 的关键区别（更简单，对齐 OpencodeUsageScanner）：
/// - **单源**（一个 zcode db），不是双源 union，也不走 RPC
/// - **Method A 归类**（SQL CASE 直接判 `reasoning_tokens` priority + `EXISTS reasoning part`），
///   不走字符分摊估算;reader 输出 `GlmDailyUsage.reasoningTokens` 已是最终值
/// - **原生 turn_id**：turns 直接 `COUNT(DISTINCT turn_id)`
/// - **整体快照缓存**：db+WAL 指纹不变就直接返回缓存快照，不做 per-source daily diff
/// - 保留最近 8 天的 recentSamples，供 quota 窗口内 token 明细使用
///
/// 仍复用：`SQLiteTempCopy.read`（活跃 WAL 的 CANTOPEN/BUSY 兜底）、`LocalUsageScanRunner`
/// （generation 守门 + 取消过滤）、`ScannerIndexIO`（versioned index.json）。
@MainActor
final class GlmZcodeLocalUsageScanner: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: GlmLocalUsage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    nonisolated static let defaultDBURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }()

    /// ZCode tasks-index db（off_peak_tasks 表来源）
    nonisolated static let defaultTasksDBURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("tasks-index.sqlite")
    }()

    nonisolated static let defaultCacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent(".token-monitor", isDirectory: true)
    }()

    private let dbURL: URL
    private let tasksDBURL: URL
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var inFlightTask: Task<Void, Never>?
    private var latestGeneration: UInt64 = 0
    /// 串行化整个 performScanPure（cache 读+SQL+写）。cancel+rescan 时老 worker 跑完才让新 worker 开始。
    nonisolated static let pipelineMutex = AsyncMutex()

    init(dbURL: URL = GlmZcodeLocalUsageScanner.defaultDBURL,
         tasksDBURL: URL = GlmZcodeLocalUsageScanner.defaultTasksDBURL,
         cacheDir: URL = GlmZcodeLocalUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbURL = dbURL
        self.tasksDBURL = tasksDBURL
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        self.lastResult = Self.loadCachedResult(cacheDir: cacheDir, fileManager: fileManager)
    }

    func scan() {
        guard inFlightTask == nil else { return }
        isScanning = true
        latestGeneration &+= 1
        let startedGeneration = latestGeneration
        inFlightTask = Task { [weak self] in
            await self?.runScan(startedGeneration: startedGeneration)
        }
    }

    func cancelInFlight() {
        latestGeneration &+= 1
        isScanning = false
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    private func runScan(startedGeneration: UInt64) async {
        defer {
            if startedGeneration == self.latestGeneration {
                self.isScanning = false
                self.inFlightTask = nil
            } else {
                logInfo("[glm-zcode-scan] 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(self.latestGeneration)")
            }
        }
        let dbURL = self.dbURL
        let tasksDBURL = self.tasksDBURL
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        let work: @Sendable () async throws -> GlmLocalUsage = {
            try await Self.pipelineMutex.withLock {
                try Self.performScanPure(
                    dbURL: dbURL, tasksDBURL: tasksDBURL, cacheDir: cacheDir,
                    fileManager: fileManager, calendar: calendar, now: now
                )
            }
        }
        await LocalUsageScanRunner.run(
            logTag: "[glm-zcode-scan]",
            startedGeneration: startedGeneration,
            latestGeneration: { self.latestGeneration },
            work: work,
            applyResult: { result in
                self.lastResult = result
                self.lastError = nil
            },
            applyError: { message in
                self.lastError = message
            }
        )
    }

    // MARK: - pure scan

    /// 纯 I/O + 计算，不碰 self。在 pipelineMutex 内串行执行。
    nonisolated static func performScanPure(
        dbURL: URL,
        tasksDBURL: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date
    ) throws -> GlmLocalUsage {
        try fileManager.createPrivateDirectory(at: cacheDir)

        // 1. db + WAL 指纹
        let fingerprint = try statFingerprint(dbURL: dbURL, fileManager: fileManager)

        // db 不存在 → 空（zcode 未安装/未运行过）
        guard fingerprint.exists else {
            logInfo("[glm-zcode-scan] db 不存在: \(dbURL.path)")
            return GlmLocalUsage.empty
        }

        let scanNow = now()

        // 闲时任务窗口（每次扫描都读；off_peak_tasks 表小且稳定，单次 SELECT 开销可忽略）。
        // 不参与 db 指纹缓存判定 —— off_peak 表变更不触发 model_usage 指纹变化，但下次
        // quota refresh 成功后自然会触发新一轮 scan，足以拿到最新窗口。
        let offPeakWindows: [GlmOffPeakWindow]
        do {
            offPeakWindows = try readOffPeakWindows(tasksDBURL: tasksDBURL)
        } catch {
            // tasks-index 存在但表缺失 / schema 不符（旧版 ZCode）时不能静默吞掉：
            // 若返回空会把所有样本当高峰计入额度窗口，这里记一条警告便于诊断。
            logWarn("[glm-zcode-scan] 读取 off_peak_tasks 失败，按无闲时任务处理: \(error.localizedDescription)")
            offPeakWindows = []
        }

        // 2. 指纹没变 → 直接用缓存快照（不做 SQL）。仍需按当前本地日重切
        // 7 天窗口，否则跨午夜且数据库没有新写入时，昨天会一直被当成今天。
        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        if index.matches(fingerprint), let snapshot = index.snapshot {
            logDebug("[glm-zcode-scan] 指纹未变，复用缓存快照 (rounds=\(snapshot.eventCount))")
            var rebased = rebaseCachedSnapshot(snapshot, calendar: calendar, now: scanNow)
            // 闲时窗口可能在新一轮 scan 间期变化（新任务完成），rebase 时同步刷新
            rebased = GlmLocalUsage(
                today: rebased.today,
                dailyTokenUsage: rebased.dailyTokenUsage,
                scannedAt: rebased.scannedAt,
                sessionCount: rebased.sessionCount,
                eventCount: rebased.eventCount,
                failedSessionCount: rebased.failedSessionCount,
                recentSamples: rebased.recentSamples,
                offPeakWindows: offPeakWindows
            )
            if rebased != snapshot {
                index.update(fingerprint: fingerprint, snapshot: rebased)
                try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
            }
            return rebased
        }

        // 3. 聚合
        let aggregate = try aggregateFromDB(
            dbPath: dbURL,
            calendar: calendar,
            sampleCutoff: scanNow.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let snapshot = buildSnapshot(
            adjustedPerDay: aggregate.perDay,
            sessionCount: aggregate.sessionCount,
            roundCount: aggregate.roundCount,
            samples: aggregate.samples,
            offPeakWindows: offPeakWindows,
            calendar: calendar,
            now: scanNow
        )

        // 4. 写缓存
        index.update(fingerprint: fingerprint, snapshot: snapshot)
        try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        logInfo("[glm-zcode-scan] ✓ rounds=\(aggregate.roundCount) sessions=\(aggregate.sessionCount) offPeak=\(offPeakWindows.count)")
        return snapshot
    }

    /// 读闲时任务时间窗口。tasks-index db 不存在 / 表缺失 → 返回空（ZCode 旧版本）。
    nonisolated static func readOffPeakWindows(tasksDBURL: URL) throws -> [GlmOffPeakWindow] {
        // tasks-index db 不存在不算错误（旧 ZCode 版本）
        guard FileManager.default.fileExists(atPath: tasksDBURL.path) else { return [] }
        return try SQLiteTempCopy.read(dbPath: tasksDBURL, logTag: "[glm-zcode-offpeak]") { url in
            let reader = try GlmZcodeOffPeakReader(path: url, readOnly: url.path == tasksDBURL.path)
            defer { reader.close() }
            return try reader.windows()
        }
    }

    /// 把 per-day 聚合压成 7 天窗口的 `GlmLocalUsage`。
    ///
    /// `adjustedPerDay` 直接来自 `GlmZcodeDBReader.queryPerDay`,Method A 归类后的最终值
    /// (`outputTokens` / `reasoningTokens` 已经按 part 表 + native priority 算好)。
    /// buildSnapshot 只负责 7 天窗口滚动 + 今日挑选 + samples 保留。
    /// `dbPath` 之前是签名一部分,新签名不需要(诊断路径走 `OpencodeLocalUsage.dbPath`)。
    nonisolated static func buildSnapshot(
        adjustedPerDay: [Date: GlmDailyUsage],
        sessionCount: Int,
        roundCount: Int,
        samples: [LocalTokenUsageSample],
        offPeakWindows: [GlmOffPeakWindow],
        calendar: Calendar,
        now: Date
    ) -> GlmLocalUsage {
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        let allDaily = adjustedPerDay.values.sorted { $0.dayStart < $1.dayStart }
        let recent7 = DailyUsageAggregation.filterLast7Days(
            allDaily: allDaily, today: todayStart, calendar: calendar
        )
        let today = allDaily.first(where: { $0.dayStart == todayStart && $0.hasActivity })
        return GlmLocalUsage(
            today: today,
            dailyTokenUsage: recent7,
            scannedAt: now,
            sessionCount: sessionCount,
            eventCount: roundCount,
            failedSessionCount: 0,
            recentSamples: samples,
            offPeakWindows: offPeakWindows
        )
    }

    // MARK: - DB read (fast path + /tmp copy fallback)

    nonisolated static func aggregateFromDB(
        dbPath: URL,
        calendar: Calendar,
        sampleCutoff: Date? = nil
    ) throws -> GlmZcodeDBAggregate {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: "[glm-zcode-scan]") { url in
            let reader = try GlmZcodeDBReader(path: url, readOnly: url.path == dbPath.path)
            defer { reader.close() }
            return try reader.aggregate(calendar: calendar, sampleCutoff: sampleCutoff)
        }
    }

    /// 缓存只保留最近 7 天的日聚合；数据库指纹不变时，跨午夜需要把窗口向前滚动。
    /// rebase 会将 `scannedAt` 更新为调用方传入的 `now`，表示本次重切窗口的时间，
    /// 而不是上一次完整计算数据库的时间。
    nonisolated static func rebaseCachedSnapshot(
        _ snapshot: GlmLocalUsage,
        calendar: Calendar,
        now: Date
    ) -> GlmLocalUsage {
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        let daily = DailyUsageAggregation.filterLast7Days(
            allDaily: snapshot.dailyTokenUsage,
            today: todayStart,
            calendar: calendar
        )
        let today = daily.last.flatMap { $0.hasActivity ? $0 : nil }
        let sampleCutoff = now.addingTimeInterval(-8 * 24 * 60 * 60)
        return GlmLocalUsage(
            today: today,
            dailyTokenUsage: daily,
            scannedAt: now,
            sessionCount: snapshot.sessionCount,
            eventCount: snapshot.eventCount,
            failedSessionCount: snapshot.failedSessionCount,
            recentSamples: (snapshot.recentSamples ?? []).filter { $0.completedAt >= sampleCutoff },
            offPeakWindows: snapshot.offPeakWindows
        )
    }
}

// MARK: - LocalUsageScanner conformance

extension GlmZcodeLocalUsageScanner: LocalUsageScanner {
    var lastResultPublisher: AnyPublisher<GlmLocalUsage?, Never> { $lastResult.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { $isScanning.eraseToAnyPublisher() }
}

// MARK: - fingerprint

/// zcode db + WAL 的文件指纹（mtime + size）。fileprivate：只在本文件内用。
fileprivate struct GlmZcodeDBFingerprint: Equatable {
    let exists: Bool
    let mtimeMs: Double
    let sizeBytes: Int
    let walMtimeMs: Double
    let walSizeBytes: Int
}

extension GlmZcodeLocalUsageScanner {
    /// 同时 stat `.db` 与 `.db-wal`。db 明确缺失 → exists=false；其它 stat 错误上抛。
    fileprivate nonisolated static func statFingerprint(dbURL: URL, fileManager: FileManagerBox) throws -> GlmZcodeDBFingerprint {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: dbURL.path)
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                return GlmZcodeDBFingerprint(exists: false, mtimeMs: 0, sizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0)
            }
            throw error
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let walPath = dbURL.path + "-wal"
        let walAttrs: [FileAttributeKey: Any]
        do {
            walAttrs = try fileManager.attributesOfItem(atPath: walPath)
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                return GlmZcodeDBFingerprint(exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
                                             walMtimeMs: 0, walSizeBytes: 0)
            }
            throw error
        }
        let walSize = (walAttrs[.size] as? NSNumber)?.intValue ?? 0
        let walMtime = (walAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return GlmZcodeDBFingerprint(exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
                                     walMtimeMs: walMtime * 1000, walSizeBytes: max(0, walSize))
    }
}

// MARK: - index

extension GlmZcodeLocalUsageScanner {
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var dbMtimeMs: Double
        var dbSizeBytes: Int
        var walMtimeMs: Double
        var walSizeBytes: Int
        var snapshot: GlmLocalUsage?

        /// 缓存版本跳升至 8：recentSamples 新增 `sourceProviderID`，用于精确区分
        /// coding-plan 与 offpeak-idle-plan。v7 快照缺少来源标记，必须重扫，避免
        /// 并发正常请求仅凭时间窗口被误判成闲时。
        static let empty = CacheIndex(
            version: 8, dbMtimeMs: 0, dbSizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0, snapshot: nil
        )

        fileprivate func matches(_ fp: GlmZcodeDBFingerprint) -> Bool {
            fp.exists
                && dbMtimeMs == fp.mtimeMs
                && dbSizeBytes == fp.sizeBytes
                && walMtimeMs == fp.walMtimeMs
                && walSizeBytes == fp.walSizeBytes
        }

        fileprivate mutating func update(fingerprint: GlmZcodeDBFingerprint, snapshot: GlmLocalUsage) {
            dbMtimeMs = fingerprint.mtimeMs
            dbSizeBytes = fingerprint.sizeBytes
            walMtimeMs = fingerprint.walMtimeMs
            walSizeBytes = fingerprint.walSizeBytes
            self.snapshot = snapshot
        }
    }

    nonisolated static func loadIndex(cacheDir: URL, fileManager: FileManagerBox) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir, fileManager: fileManager,
            currentVersion: 8, empty: .empty,
            version: { $0.version }, logTag: "[glm-zcode-scan]"
        )
    }

    nonisolated static func saveIndex(_ index: CacheIndex, cacheDir: URL, fileManager: FileManagerBox) throws {
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动先展示上次成功扫描的快照；正常 scan 会重新按当前日期 rebased。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) -> GlmLocalUsage? {
        do {
            return try loadIndex(cacheDir: cacheDir, fileManager: fileManager).snapshot
        } catch {
            logWarn("[glm-zcode-scan] 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }
}
