import Foundation

/// 扫描 opencode 的 `~/.local/share/opencode/opencode.db`，按 `providerID` 分片产出
/// `OpencodeLocalUsage`。各 Provider 卡片通过 `clientBindings[]` 派生的运行时绑定
/// 决定是否合并对应 slice；`minimax` 本地能力分片仅保留在诊断快照。
///
/// 生命周期外壳、db+WAL 指纹、快照缓存与 7 天 rebase 都在
/// `SingleDBSnapshotScanner` 基座；本类型只声明路径、缓存版本与 pipeline hook。
/// 保留最近 8 天的 recentSamples，供 quota 窗口内 token 明细使用。
@MainActor
final class OpencodeUsageScanner: SingleDBSnapshotScanner<OpencodeLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[opencode-scan]"
    nonisolated static let cacheIndexVersion = 2

    /// 整个扫描 pipeline 的串行锁（跨实例共享）。
    nonisolated static let pipelineMutex = AsyncMutex()

    override nonisolated var pipelineLock: AsyncMutex { Self.pipelineMutex }

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

    init(dbURL: URL = OpencodeUsageScanner.defaultDBURL,
         cacheDir: URL = OpencodeUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        super.init(
            dbURL: dbURL,
            cacheDir: cacheDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now,
            logTag: Self.scanLogTag,
            cacheIndexVersion: Self.cacheIndexVersion
        )
    }

    // MARK: - pipeline hooks

    override nonisolated var emptySnapshot: OpencodeLocalUsage {
        OpencodeLocalUsage.empty
    }

    override nonisolated func buildSnapshot(now: Date) throws -> OpencodeLocalUsage {
        let aggregate = try Self.aggregateFromDB(
            dbPath: dbURL,
            calendar: calendar,
            sampleCutoff: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let snapshot = Self.buildSnapshot(
            from: aggregate, dbPath: dbURL.path, calendar: calendar, now: now
        )
        logInfo("\(logTag) ✓ providers=\(snapshot.byProvider.count) rounds=\(aggregate.roundCount.values.reduce(0, +))")
        return snapshot
    }

    override nonisolated func rebaseSnapshot(_ snapshot: OpencodeLocalUsage, now: Date) throws -> OpencodeLocalUsage {
        Self.rebaseCachedSnapshot(snapshot, calendar: calendar, now: now)
    }

    // MARK: - 纯函数（保持既有测试表面）

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
