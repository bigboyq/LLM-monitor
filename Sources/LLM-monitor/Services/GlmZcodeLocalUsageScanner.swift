import Foundation
import os

/// 扫描 ZCode（智谱官方 CLI）的 `~/.zcode/cli/db/db.sqlite`，产出 `GlmLocalUsage`。
///
/// GLM Coding Plan 卡片的 **native 本地数据源**：读取 `model_usage` 表中
/// 智谱系 provider 的 5 类 token —— 正式 Coding Plan（`builtin:bigmodel-coding-plan`
/// 及迁移后 `account:bigmodel-*-coding-plan`，正常交互）、`offpeak-idle-plan`
/// （闲时任务，不消耗积分）与其余智谱前缀（其他智谱套餐，如体验套餐，不消耗积分），
/// 按本地自然日聚合 +
/// 7 天窗口 + 最近 8 天逐次调用样本。Reasoning 归类统一走 `ReasoningCharSplit`
/// 字符分摊，且只在 `GlmZcodeDBReader.querySamples` / `querySliceSamples` 行级
/// 发生一次（native `reasoning_tokens > 0` 账单值优先）；日聚合的 output/reasoning
/// 桶直接取行级分摊的按日累计，与样本严格同源——scanner 端不再有分摊步骤。
/// 活动套餐（zcode-plan）与额度重置卡已改由 `GlmZcodeAPIClient` 直连接口解析，
/// 本 scanner 仅负责扫描 SQLite（`db.sqlite` 与 `tasks-index.sqlite`）。
///
/// 生命周期外壳、db+WAL 指纹、快照缓存与 7 天 rebase 都在
/// `SingleDBSnapshotScanner` 基座；本类型只声明路径、缓存版本与三个 pipeline hook
/// （含每轮都刷新的闲时任务窗口读取）。
///
/// ZCode 是一份**多 provider 共享账本**：智谱系行进 GLM 卡，同表里的非智谱行
/// （`minimax` / `deepseek`）经 `providerSlices` 切出分片，供 MiniMax / DeepSeek
/// 卡消费 —— 一次扫描、一份 DB，不为第二类 provider 再开一个 scanner。
@MainActor
final class GlmZcodeLocalUsageScanner: SingleDBSnapshotScanner<GlmLocalUsage>, @unchecked Sendable {
    nonisolated static let scanLogTag = "[glm-zcode-scan]"
    /// 缓存版本 14：日聚合的 output/reasoning 口径统一为行级分摊按日累计
    /// （分摊只在 `querySamples` / `querySliceSamples` 行级发生一次），修复
    /// `UnifiedDailyUsageNormalizer.includingCurrentDay` 对日级 / 行级两套分桶
    /// 逐桶 max() 合并时的 Output+Reasoning 凭空膨胀。v13 快照的日聚合按旧
    /// 日级分摊口径算出，升版重扫重算。
    /// （v13：智谱主卡 reasoning 归类从 Method A 整轮硬分类改为与分片统一的
    /// `ReasoningCharSplit` 字符分摊（native `reasoning_tokens > 0` 仍账单值优先）。
    /// v12 快照的日聚合 / 样本 reasoning 按旧口径算出，升版重扫重算。
    /// v12：样本新增 `ttftSeconds`（`model_usage.time_to_first_token_ms`
    /// 原生逐调用列，主表与非智谱分片同口径）。v11 快照该字段恒为 nil，升版重扫补齐。
    /// v11：ZCode 同库内非智谱 provider（`minimax` / `deepseek`）按
    /// `ZcodeProviderSlice` 前缀切出分片，随快照一起供 MiniMax / DeepSeek 卡消费。
    /// v10 快照的 `providerSlices` 恒为 nil，直接复用会在卡片上永久缺这条来源，
    /// 必须重扫补齐。
    /// v10：识别 Zcode `0020_provider_model_selection` 迁移后的
    /// `account:bigmodel-` 前缀；v9：provider 三分类，额度窗口统计改为「仅正式
    /// Coding Plan 计入」的白名单口径——见 `spec/harnesses/zcode.md` 的 Off-peak 节。）
    // Rebuild dates previously truncated to whole seconds.
    nonisolated static let cacheIndexVersion = 15

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

    nonisolated static let defaultCacheDir: URL =
        TokenMonitorPaths.cacheFile(for: .glmZcode)

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
        configureSourceLifecycle(
            paths: [
                dbURL.deletingLastPathComponent(),
                tasksDBURL.deletingLastPathComponent()
            ],
            watchedFiles: [
                dbURL,
                URL(fileURLWithPath: dbURL.path + "-wal"),
                tasksDBURL,
                URL(fileURLWithPath: tasksDBURL.path + "-wal")
            ],
            excludedPaths: [TokenMonitorPaths.root]
        )
    }

    // MARK: - pipeline hooks

    override nonisolated var emptySnapshot: GlmLocalUsage {
        GlmLocalUsage.empty
    }

    override nonisolated func buildSnapshot(now: Date) throws -> GlmLocalUsage {
        // 闲时任务窗口每次扫描都读（off_peak_tasks 表小且稳定，单次 SELECT 开销
        // 可忽略）。不参与 db 指纹缓存判定 —— off_peak 表变更不触发 model_usage
        // 指纹变化，但下一次 Provider batch settle 后的 reconcile 会触发新一轮 scan。
        let offPeakWindows = readOffPeakWindowsWithFallback()
        let aggregate = try Self.aggregateFromDB(
            dbPath: dbURL,
            calendar: calendar,
            sampleCutoff: now.addingTimeInterval(-LocalUsageRetentionWindow.seconds)
        )
        let snapshot = Self.buildSnapshot(
            adjustedPerDay: aggregate.perDay,
            sessionCount: aggregate.sessionCount,
            roundCount: aggregate.roundCount,
            samples: aggregate.samples,
            providerSlices: Self.providerSlices(from: aggregate.providerSlices, calendar: calendar, now: now),
            offPeakWindows: offPeakWindows,
            activityPlanBalances: nil,
            activityPlanPreviews: nil,
            calendar: calendar,
            now: now
        )
        logInfo("\(logTag) ✓ rounds=\(aggregate.roundCount) sessions=\(aggregate.sessionCount) offPeak=\(offPeakWindows.count) slices=\(snapshot.providerSlices?.count ?? 0)")
        return snapshot
    }

    override nonisolated func rebaseSnapshot(_ snapshot: GlmLocalUsage, now: Date) throws -> GlmLocalUsage {
        var rebased = Self.rebaseCachedSnapshot(snapshot, calendar: calendar, now: now)
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
                offPeakWindows: offPeakWindows,
                activityPlanBalances: rebased.activityPlanBalances,
                activityPlanPreviews: rebased.activityPlanPreviews,
                providerSlices: rebased.providerSlices
            )
        }
        return rebased
    }

    private nonisolated func readOffPeakWindowsWithFallback() -> [GlmOffPeakWindow] {
        do {
            return try Self.readOffPeakWindows(tasksDBURL: tasksDBURL, fileManager: fileManager)
        } catch {
            // tasks-index 存在但表缺失 / schema 不符（旧版 ZCode）时不能静默吞掉：
            // 若返回空会把所有样本当高峰计入额度窗口，这里记一条警告便于诊断。
            logWarn("\(logTag) 读取 off_peak_tasks 失败，按无闲时任务处理: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 纯函数（保持既有测试表面）

    /// 读闲时任务时间窗口。tasks-index db 不存在 / 表缺失 → 返回空（ZCode 旧版本）。
    nonisolated static func readOffPeakWindows(
        tasksDBURL: URL,
        fileManager: FileManagerBox = FileManagerBox()
    ) throws -> [GlmOffPeakWindow] {
        // tasks-index db 不存在不算错误（旧 ZCode 版本）
        guard fileManager.fileExists(atPath: tasksDBURL.path) else { return [] }
        // 先直读：SQLiteConnection 在无 -shm 且无 dirty WAL 时走 immutable=1 直读，
        // ZCode 未运行时 0ms 直读且不产生副本；ZCode 运行时走只读共享内存。
        // 仅在 dirty WAL 需 recovery 或锁冲突等真实异常时，SQLiteTempCopy 才 fallback 到 /tmp 副本。
        return try SQLiteTempCopy.read(dbPath: tasksDBURL, logTag: "[glm-zcode-offpeak]") { url in
            let reader = try GlmZcodeOffPeakReader(path: url, readOnly: url.path == tasksDBURL.path)
            defer { reader.close() }
            return try reader.windows()
        }
    }

    /// 把 per-day 聚合压成 7 天窗口的 `GlmLocalUsage`。
    ///
    /// `adjustedPerDay` 直接来自 `GlmZcodeDBReader.queryPerDay`,output/reasoning
    /// 已是行级分摊按日累计的最终值（与样本严格同源，见
    /// `GlmZcodeDBReader.perDayAlignedWithRowSplitSamples`）。
    /// buildSnapshot 只负责 7 天窗口滚动 + 今日挑选 + samples 保留。
    /// `providerSlices` 是同库内非智谱 provider 的分片（已由
    /// `providerSlices(from:calendar:now:)` 压成 7 天窗口），照原样挂到快照上。
    nonisolated static func buildSnapshot(
        adjustedPerDay: [Date: GlmDailyUsage],
        sessionCount: Int,
        roundCount: Int,
        samples: [LocalTokenUsageSample],
        providerSlices: [String: OpencodeProviderUsage] = [:],
        offPeakWindows: [GlmOffPeakWindow],
        activityPlanBalances: [GlmActivityPlanBalance]? = nil,
        activityPlanPreviews: [GlmActivityPlanPreview]? = nil,
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
            offPeakWindows: offPeakWindows,
            activityPlanBalances: activityPlanBalances,
            activityPlanPreviews: activityPlanPreviews,
            providerSlices: providerSlices
        )
    }

    /// 把 reader 的分片原始聚合压成 7 天窗口，形状与 `OpencodeUsageScanner`
    /// 的同名步骤一致（today + 7 天日聚合 + 累计 rounds + 最近 8 天样本）。
    nonisolated static func providerSlices(
        from aggregate: ZcodeProviderSliceAggregate,
        calendar: Calendar,
        now: Date
    ) -> [String: OpencodeProviderUsage] {
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        var out: [String: OpencodeProviderUsage] = [:]
        for (slice, byDay) in aggregate.perSliceDay {
            let allDaily = byDay.values.sorted { $0.dayStart < $1.dayStart }
            let recent7 = DailyUsageAggregation.filterLast7Days(
                allDaily: allDaily, today: todayStart, calendar: calendar
            )
            let today = allDaily.first(where: { $0.dayStart == todayStart && $0.hasActivity })
            out[slice] = OpencodeProviderUsage(
                today: today,
                dailyTokenUsage: recent7,
                roundCount: aggregate.roundCount[slice]
                    ?? SaturatingArithmetic.sum(allDaily.lazy.map(\.rounds)),
                recentSamples: aggregate.samples[slice] ?? []
            )
        }
        return out
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
        let sampleCutoff = now.addingTimeInterval(-LocalUsageRetentionWindow.seconds)
        return GlmLocalUsage(
            today: today,
            dailyTokenUsage: daily,
            scannedAt: now,
            sessionCount: snapshot.sessionCount,
            eventCount: snapshot.eventCount,
            failedSessionCount: snapshot.failedSessionCount,
            recentSamples: (snapshot.recentSamples ?? []).filter { $0.completedAt >= sampleCutoff },
            offPeakWindows: snapshot.offPeakWindows,
            activityPlanBalances: snapshot.activityPlanBalances,
            activityPlanPreviews: snapshot.activityPlanPreviews,
            providerSlices: rebaseProviderSlices(snapshot.providerSlices, calendar: calendar, now: now)
        )
    }

    /// 分片同样只缓存 7 天日聚合：跨午夜时把窗口向前滚动，并把 8 天样本裁到
    /// 最近 8 天（与智谱 native 样本同口径）。
    nonisolated static func rebaseProviderSlices(
        _ slices: [String: OpencodeProviderUsage]?,
        calendar: Calendar,
        now: Date
    ) -> [String: OpencodeProviderUsage]? {
        guard let slices, slices.isEmpty == false else { return slices }
        let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        let sampleCutoff = now.addingTimeInterval(-LocalUsageRetentionWindow.seconds)
        return slices.mapValues { usage in
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
                recentSamples: usage.recentSamples.filter { $0.completedAt >= sampleCutoff }
            )
        }
    }

    /// 冷启动缓存读取（保持既有两参数测试签名）。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar = .autoupdatingCurrent
    ) -> GlmLocalUsage? {
        loadCachedResult(
            cacheDir: cacheDir,
            fileManager: fileManager,
            logTag: scanLogTag,
            currentVersion: cacheIndexVersion,
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
        )
    }
}
