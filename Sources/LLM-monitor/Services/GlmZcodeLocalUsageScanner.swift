import Foundation

/// 扫描 ZCode（智谱官方 CLI）的 `~/.zcode/cli/db/db.sqlite`，产出 `GlmLocalUsage`。
///
/// GLM Coding Plan 卡片的 **native 本地数据源**：读取 `model_usage` 表中
/// `provider_id='builtin:bigmodel-coding-plan'`（正常交互）与
/// `provider_id='offpeak-idle-plan'`（闲时任务，不消耗积分）的 5 类 token，按本地自然日聚合 +
/// 7 天窗口 + 最近 8 天逐次调用样本。Reasoning 归类在 `GlmZcodeDBReader.queryPerDay`
/// 的 SQL `CASE` 内一次性走 Method A 完成（`reasoning_tokens` priority + `EXISTS` part 表
/// `type='reasoning'` 的整轮归类），不再有 scanner 端字符分摊步骤。
///
/// 生命周期外壳、db+WAL 指纹、快照缓存与 7 天 rebase 都在
/// `SingleDBSnapshotScanner` 基座；本类型只声明路径、缓存版本与三个 pipeline hook
/// （含每轮都刷新的闲时任务窗口读取）。
@MainActor
final class GlmZcodeLocalUsageScanner: SingleDBSnapshotScanner<GlmLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[glm-zcode-scan]"
    /// 缓存版本 8：recentSamples 新增 `sourceProviderID`，用于精确区分
    /// coding-plan 与 offpeak-idle-plan。v7 快照缺少来源标记，必须重扫，避免
    /// 并发正常请求仅凭时间窗口被误判成闲时。
    nonisolated static let cacheIndexVersion = 8

    /// 整个扫描 pipeline 的串行锁（跨实例共享）。
    nonisolated static let pipelineMutex = AsyncMutex()

    override nonisolated var pipelineLock: AsyncMutex { Self.pipelineMutex }

    nonisolated static let defaultDBURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }()

    /// ZCode tasks-index db（off_peak_tasks 表来源）
    let tasksDBURL: URL

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

    init(dbURL: URL = GlmZcodeLocalUsageScanner.defaultDBURL,
         tasksDBURL: URL = GlmZcodeLocalUsageScanner.defaultTasksDBURL,
         cacheDir: URL = GlmZcodeLocalUsageScanner.defaultCacheDir,
         fileManager: FileManagerBox = FileManagerBox(),
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.tasksDBURL = tasksDBURL
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

    override nonisolated var emptySnapshot: GlmLocalUsage {
        GlmLocalUsage.empty
    }

    override nonisolated func buildSnapshot(now: Date) throws -> GlmLocalUsage {
        // 闲时任务窗口每次扫描都读（off_peak_tasks 表小且稳定，单次 SELECT 开销
        // 可忽略）。不参与 db 指纹缓存判定 —— off_peak 表变更不触发 model_usage
        // 指纹变化，但下次 quota refresh 成功后自然会触发新一轮 scan。
        let offPeakWindows = readOffPeakWindowsWithFallback()
        let aggregate = try Self.aggregateFromDB(
            dbPath: dbURL,
            calendar: calendar,
            sampleCutoff: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let snapshot = Self.buildSnapshot(
            adjustedPerDay: aggregate.perDay,
            sessionCount: aggregate.sessionCount,
            roundCount: aggregate.roundCount,
            samples: aggregate.samples,
            offPeakWindows: offPeakWindows,
            calendar: calendar,
            now: now
        )
        logInfo("\(logTag) ✓ rounds=\(aggregate.roundCount) sessions=\(aggregate.sessionCount) offPeak=\(offPeakWindows.count)")
        return snapshot
    }

    override nonisolated func rebaseSnapshot(_ snapshot: GlmLocalUsage, now: Date) throws -> GlmLocalUsage {
        var rebased = Self.rebaseCachedSnapshot(snapshot, calendar: calendar, now: now)
        // 闲时窗口可能在新一轮 scan 间期变化（新任务完成），rebase 时同步刷新。
        let offPeakWindows = readOffPeakWindowsWithFallback()
        if rebased.offPeakWindows != offPeakWindows {
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
        }
        return rebased
    }

    private nonisolated func readOffPeakWindowsWithFallback() -> [GlmOffPeakWindow] {
        do {
            return try Self.readOffPeakWindows(tasksDBURL: tasksDBURL)
        } catch {
            // tasks-index 存在但表缺失 / schema 不符（旧版 ZCode）时不能静默吞掉：
            // 若返回空会把所有样本当高峰计入额度窗口，这里记一条警告便于诊断。
            logWarn("\(logTag) 读取 off_peak_tasks 失败，按无闲时任务处理: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 纯函数（保持既有测试表面）

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

    /// 冷启动缓存读取（保持既有两参数测试签名）。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) -> GlmLocalUsage? {
        loadCachedResult(
            cacheDir: cacheDir,
            fileManager: fileManager,
            logTag: scanLogTag,
            currentVersion: cacheIndexVersion
        )
    }
}
