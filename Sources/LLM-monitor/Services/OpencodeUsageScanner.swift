import Foundation
import Combine

/// 扫描 opencode 的 `~/.local/share/opencode/opencode.db`，按 `providerID` 分片产出
/// `OpencodeLocalUsage`。各 Provider 卡片通过独立开关决定是否合并对应 slice；
/// `minimax` 本地能力分片仅保留在诊断快照。
///
/// 跟 minimax scanner 的关键区别（更简单）：
/// - **单源**（一个 opencode.db），不是双源 union
/// - **原生 reasoning**（GLM-5.2 账单自带 reasoning tokens），不需要字符分摊
/// - **整体快照缓存**：db+WAL 指纹不变就直接返回缓存快照，不做 per-source daily diff
/// - 保留最近 8 天的 recentSamples，供 quota 窗口内 token 明细使用
///
/// 仍复用：`SQLiteTempCopy.read`（活跃 WAL 的 CANTOPEN/BUSY 兜底）、`LocalUsageScanRunner`
/// （generation 守门 + 取消过滤）、`ScannerIndexIO`（versioned index.json）。
@MainActor
final class OpencodeUsageScanner: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: OpencodeLocalUsage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    nonisolated static let defaultDBURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
    }()

    nonisolated static let defaultCacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent(".token-monitor", isDirectory: true)
    }()

    private let dbURL: URL
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var inFlightTask: Task<Void, Never>?
    private var latestGeneration: UInt64 = 0
    /// 串行化整个 performScanPure（cache 读+SQL+写）。cancel+rescan 时老 worker 跑完才让新 worker 开始。
    nonisolated static let pipelineMutex = AsyncMutex()

    init(dbURL: URL = OpencodeUsageScanner.defaultDBURL,
         cacheDir: URL = OpencodeUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbURL = dbURL
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
            }
        }
        let dbURL = self.dbURL
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        let work: @Sendable () async throws -> OpencodeLocalUsage = {
            try await Self.pipelineMutex.withLock {
                try Self.performScanPure(
                    dbURL: dbURL, cacheDir: cacheDir, fileManager: fileManager,
                    calendar: calendar, now: now
                )
            }
        }
        await LocalUsageScanRunner.run(
            logTag: "[opencode-scan]",
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
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date
    ) throws -> OpencodeLocalUsage {
        try fileManager.createPrivateDirectory(at: cacheDir)

        // 1. db + WAL 指纹
        let fingerprint = try statFingerprint(dbURL: dbURL, fileManager: fileManager)

        // db 不存在 → 空（opencode 未安装/未运行过）
        guard fingerprint.exists else {
            logInfo("[opencode-scan] db 不存在: \(dbURL.path)")
            let empty = OpencodeLocalUsage.empty
            return empty
        }

        let scanNow = now()

        // 2. 指纹没变 → 直接用缓存快照（不做 SQL）。仍需按当前本地日重切
        // 7 天窗口，否则跨午夜且数据库没有新写入时，昨天会一直被当成今天。
        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        if index.matches(fingerprint), let snapshot = index.snapshot {
            logDebug("[opencode-scan] 指纹未变，复用缓存快照 (providers=\(snapshot.byProvider.count))")
            let rebased = rebaseCachedSnapshot(snapshot, calendar: calendar, now: scanNow)
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
            from: aggregate, dbPath: dbURL.path, calendar: calendar, now: scanNow
        )

        // 4. 写缓存
        index.update(fingerprint: fingerprint, snapshot: snapshot)
        try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        logInfo("[opencode-scan] ✓ providers=\(snapshot.byProvider.count) rounds=\(aggregate.roundCount.values.reduce(0, +))")
        return snapshot
    }

    /// 把原始 per-provider×day 聚合压成 7 天窗口的 `OpencodeLocalUsage`。
    nonisolated static func buildSnapshot(
        from aggregate: OpencodeDBAggregate,
        dbPath: String,
        calendar: Calendar,
        now: Date
    ) -> OpencodeLocalUsage {
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        var byProvider: [String: OpencodeProviderUsage] = [:]
        for (provider, byDay) in aggregate.perProviderDay {
            let allDaily = byDay.values.sorted { $0.dayStart < $1.dayStart }
            let recent7 = DailyUsageAggregation.filterLast7Days(
                allDaily: allDaily, today: todayStart, calendar: calendar
            )
            let today = allDaily.first(where: { $0.dayStart == todayStart })
            byProvider[provider] = OpencodeProviderUsage(
                today: today,
                dailyTokenUsage: recent7,
                roundCount: aggregate.roundCount[provider]
                    ?? SaturatingArithmetic.sum(allDaily.lazy.map(\.rounds)),
                cost: aggregate.cost[provider] ?? 0,
                recentSamples: aggregate.samples[provider] ?? []
            )
        }
        return OpencodeLocalUsage(
            byProvider: byProvider,
            modelsByProvider: aggregate.models,
            dbPath: dbPath,
            scannedAt: now
        )
    }

    // MARK: - DB read (fast path + /tmp copy fallback)

    nonisolated static func aggregateFromDB(
        dbPath: URL,
        calendar: Calendar,
        sampleCutoff: Date? = nil
    ) throws -> OpencodeDBAggregate {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: "[opencode-scan]") { url in
            let reader = try OpencodeDBReader(path: url, readOnly: url.path == dbPath.path)
            defer { reader.close() }
            return try reader.aggregate(calendar: calendar, sampleCutoff: sampleCutoff)
        }
    }

    /// 缓存只保留最近 7 天的日聚合；数据库指纹不变时，跨午夜需要把窗口向前滚动。
    nonisolated static func rebaseCachedSnapshot(
        _ snapshot: OpencodeLocalUsage,
        calendar: Calendar,
        now: Date
    ) -> OpencodeLocalUsage {
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        let sampleCutoff = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let rebased = snapshot.byProvider.mapValues { usage in
            let daily = DailyUsageAggregation.filterLast7Days(
                allDaily: usage.dailyTokenUsage,
                today: todayStart,
                calendar: calendar
            )
            let today = daily.last.flatMap { $0.hasActivity ? $0 : nil }
            return OpencodeProviderUsage(
                today: today,
                dailyTokenUsage: daily,
                roundCount: usage.roundCount,
                cost: usage.cost,
                recentSamples: usage.recentSamples.filter { $0.completedAt >= sampleCutoff }
            )
        }
        return OpencodeLocalUsage(
            byProvider: rebased,
            modelsByProvider: snapshot.modelsByProvider,
            dbPath: snapshot.dbPath,
            scannedAt: snapshot.scannedAt
        )
    }
}

// MARK: - LocalUsageScanner conformance

extension OpencodeUsageScanner: LocalUsageScanner {
    var lastResultPublisher: AnyPublisher<OpencodeLocalUsage?, Never> { $lastResult.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { $isScanning.eraseToAnyPublisher() }
}

// MARK: - fingerprint

/// opencode.db + WAL 的文件指纹（mtime + size）。fileprivate：只在本文件内用。
fileprivate struct OpencodeDBFingerprint: Equatable {
    let exists: Bool
    let mtimeMs: Double
    let sizeBytes: Int
    let walMtimeMs: Double
    let walSizeBytes: Int
}

extension OpencodeUsageScanner {
    /// 同时 stat `.db` 与 `.db-wal`。db 明确缺失 → exists=false；其它 stat 错误上抛。
    fileprivate nonisolated static func statFingerprint(dbURL: URL, fileManager: FileManagerBox) throws -> OpencodeDBFingerprint {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: dbURL.path)
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                return OpencodeDBFingerprint(exists: false, mtimeMs: 0, sizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0)
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
                return OpencodeDBFingerprint(exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
                                             walMtimeMs: 0, walSizeBytes: 0)
            }
            throw error
        }
        let walSize = (walAttrs[.size] as? NSNumber)?.intValue ?? 0
        let walMtime = (walAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return OpencodeDBFingerprint(exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
                                     walMtimeMs: walMtime * 1000, walSizeBytes: max(0, walSize))
    }

}

// MARK: - index

extension OpencodeUsageScanner {
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var dbMtimeMs: Double
        var dbSizeBytes: Int
        var walMtimeMs: Double
        var walSizeBytes: Int
        var snapshot: OpencodeLocalUsage?

        static let empty = CacheIndex(
            version: 2, dbMtimeMs: 0, dbSizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0, snapshot: nil
        )

        fileprivate func matches(_ fp: OpencodeDBFingerprint) -> Bool {
            fp.exists
                && dbMtimeMs == fp.mtimeMs
                && dbSizeBytes == fp.sizeBytes
                && walMtimeMs == fp.walMtimeMs
                && walSizeBytes == fp.walSizeBytes
        }

        fileprivate mutating func update(fingerprint: OpencodeDBFingerprint, snapshot: OpencodeLocalUsage) {
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
            currentVersion: 2, empty: .empty,
            version: { $0.version }, logTag: "[opencode-scan]"
        )
    }

    nonisolated static func saveIndex(_ index: CacheIndex, cacheDir: URL, fileManager: FileManagerBox) throws {
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动先展示上次成功扫描的快照；正常 scan 会重新按当前日期 rebased。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) -> OpencodeLocalUsage? {
        do {
            return try loadIndex(cacheDir: cacheDir, fileManager: fileManager).snapshot
        } catch {
            logWarn("[opencode-scan] 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }
}
