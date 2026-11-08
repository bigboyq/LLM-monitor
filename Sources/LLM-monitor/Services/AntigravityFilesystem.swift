import Foundation

// MARK: - Filesystem operations (off main actor)

/// `internal`（default）：被 `extension AntigravityLocalUsageScanner` 里的
/// `nonisolated static func` 引用，必须 >= 函数的 access level。
struct AntigravityDBFileInfo: Sendable {
    let url: URL
    let sizeBytes: Int
    let mtimeMs: Double
    let walSizeBytes: Int
    let walMtimeMs: Double
}

/// 一次 conversations roots 枚举的结果。
///
/// `isComplete=false` 表示至少一个 root 或候选文件遇到权限/TCC/瞬时 I/O 错误；
/// 此时 `files` 仍可用于刷新已成功发现的 session，但不能据此删除缓存。
struct AntigravityDBFileListing: Sendable {
    let files: [String: AntigravityDBFileInfo]
    let isComplete: Bool
}

extension AntigravityLocalUsageScanner {
    /// `nonisolated static`：file I/O 不碰 self，可在 background 跑。
    ///
    /// - Parameters:
    ///   - cacheDir: 当前生效的 provider 缓存文件（`token-monitor/antigravity.json`）。
    ///   - legacyRPCCacheRoot: 旧版 v3 rpc-cache 所在的旧缓存根。真实历史位置是
    ///     a65dec3 时期的 cacheDir `~/.gemini/antigravity/.token-monitor`（即
    ///     `TokenMonitorPaths.legacyAntigravityCacheDir`）；根迁移只搬了
    ///     index.json、没有迁 rpc-cache，所以清理基址不能从当前 cacheDir 推导
    ///     ——provider `.json` 时代由 `directoryURL(for:)` 推出的
    ///     `.../token-monitor/rpc-cache` 从未存在过，清理因此失效。测试注入
    ///     临时目录验证。
    nonisolated static func ensureCacheDirectoriesExist(
        cacheDir: URL,
        fileManager: FileManagerBox,
        legacyRPCCacheRoot: URL = TokenMonitorPaths.legacyAntigravityCacheDir
    ) throws {
        try ScannerIndexIO.ensureCacheDirectory(for: cacheDir, fileManager: fileManager)
        // v3 以前曾额外写 `<旧缓存根>/rpc-cache/v1/<session>/usage.jsonl|manifest.json`，
        // 但生产读取始终只使用顶层 JSON。清理这份重复的历史明细；每次扫描
        // 幂等重试（目录不存在即 no-op），删除失败不阻断扫描。
        let legacyRPCCache = legacyRPCCacheRoot
            .appendingPathComponent("rpc-cache", isDirectory: true)
        if fileManager.fileExists(atPath: legacyRPCCache.path) {
            do {
                try fileManager.removeItem(at: legacyRPCCache)
                logInfo("[antigravity-scan] 已清理旧版未使用的 per-session RPC cache")
            } catch {
                logWarn("[antigravity-scan] 清理旧版 per-session RPC cache 失败，将于下次重试: \(error.localizedDescription)")
            }
        }
    }

    /// 列出 session 文件，并额外返回枚举是否完整。可注入目录/属性读取函数，
    /// 让测试稳定模拟 TCC、权限和瞬时 I/O 错误。
    ///
    /// 阶段二b 起只接受 `.db`（SQLite）会话：token/模型/时间戳/轮次全部来自
    /// `AntigravitySessionDBReader` 的直读，`.pb` 会话没有 `gen_metadata`
    /// 结构、RPC 支持也已退役，完全忽略（不发现、不指纹、不进 session 集）。
    nonisolated static func listDBFilesWithStatus(
        conversationsDirs: [URL],
        fileManager: FileManagerBox,
        directoryContents: ((URL) throws -> [URL])? = nil,
        resourceValues: ((URL) throws -> URLResourceValues)? = nil,
        fileAttributes: ((String) throws -> [FileAttributeKey: Any])? = nil
    ) -> AntigravityDBFileListing {
        var result: [String: AntigravityDBFileInfo] = [:]
        var isComplete = true
        for conversationsDir in conversationsDirs {
            // 用父目录名当 tag，让日志能区分各 conversations root 各扫到多少
            // session（默认只有一个 antigravity 目录；测试会注入多个）。
            let dirTag = conversationsDir.deletingLastPathComponent().lastPathComponent
            let entries: [URL]
            do {
                if let directoryContents {
                    entries = try directoryContents(conversationsDir)
                } else {
                    entries = try fileManager.contentsOfDirectory(
                        at: conversationsDir,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    )
                }
            } catch {
                if ScannerFileError.isExplicitlyMissing(error) {
                    logInfo("[antigravity-scan] list \(dirTag)/conversations/ — 目录明确不存在，按空目录处理")
                } else {
                    isComplete = false
                    logWarn("[antigravity-scan] list \(dirTag)/conversations/ — 枚举失败，保留 last-good cache: \(error.localizedDescription)")
                }
                continue
            }

            var accepted: [URL] = []
            for url in entries where url.pathExtension.lowercased() == "db" {
                accepted.append(url)
            }
            logInfo("[antigravity-scan] list \(dirTag)/conversations/ — \(entries.count) 文件, accepted \(accepted.count) (db=\(accepted.count))")

            for url in accepted {
                let sessionId = url.deletingPathExtension().lastPathComponent
                guard !sessionId.isEmpty else { continue }
                // 同 sessionId 只接受第一个出现（目录列表顺序优先）
                guard result[sessionId] == nil else { continue }
                let values: URLResourceValues
                do {
                    if let resourceValues {
                        values = try resourceValues(url)
                    } else {
                        values = try url.resourceValues(
                            forKeys: [.fileSizeKey, .contentModificationDateKey]
                        )
                    }
                } catch {
                    isComplete = false
                    logWarn("[antigravity-scan] session=\(sessionId) 属性读取失败，保留 last-good cache: \(error.localizedDescription)")
                    continue
                }
                guard let size = values.fileSize, let mtime = values.contentModificationDate else {
                    isComplete = false
                    logWarn("[antigravity-scan] session=\(sessionId) 缺少 size/mtime 属性，保留 last-good cache")
                    continue
                }
                // WAL 是活跃 session 最常变化的文件，与主文件一起构成指纹。
                let walAttributes: [FileAttributeKey: Any]?
                do {
                    if let fileAttributes {
                        walAttributes = try fileAttributes(url.path + "-wal")
                    } else {
                        walAttributes = try fileManager.attributesOfItem(
                            atPath: url.path + "-wal"
                        )
                    }
                } catch {
                    if ScannerFileError.isExplicitlyMissing(error) {
                        walAttributes = nil
                    } else {
                        isComplete = false
                        logWarn("[antigravity-scan] session=\(sessionId) WAL 属性读取失败，保留 last-good cache: \(error.localizedDescription)")
                        continue
                    }
                }
                let walSize = (walAttributes?[.size] as? NSNumber)?.intValue ?? 0
                let walMtime = (walAttributes?[.modificationDate] as? Date) ?? .distantPast
                result[sessionId] = AntigravityDBFileInfo(
                    url: url,
                    sizeBytes: size,
                    mtimeMs: mtime.timeIntervalSince1970 * 1000,
                    walSizeBytes: walSize,
                    walMtimeMs: walAttributes == nil ? 0 : walMtime.timeIntervalSince1970 * 1000
                )
            }
        }
        return AntigravityDBFileListing(files: result, isComplete: isComplete)
    }

    /// 本 index 里被跟踪的全部 sessionId。
    ///
    /// v9 起唯一的 per-session 状态就是 `sessions` 条目（读取失败时也先写条目再
    /// 采纳指纹，见 `performScanPureImpl`），不存在"只有打击计数、没有条目"的
    /// 早期 return 路径；保留函数形态作为删除判定的唯一入口。
    nonisolated static func trackedSessionIDs(in index: CacheIndex) -> Set<String> {
        Set(index.sessions.keys)
    }

    /// 枚举完整时，未出现的被跟踪 session 才能被确认删除。
    nonisolated static func confirmedRemovedSessionIDs(
        cachedIds: Set<String>,
        listing: AntigravityDBFileListing
    ) -> Set<String> {
        guard listing.isComplete else { return [] }
        return cachedIds.subtracting(listing.files.keys)
    }

    // MARK: Index I/O

    /// v9（阶段二b）：v8 及更早索引携带 RPC 增量状态机字段（offset / strikes 等），
    /// 数据源已整体切换为 `.db` 直读——不做字段级迁移，直接重置为空缓存，首个
    /// 扫描轮对全部 session 全量重读（本地读毫秒级；daily/samples 按新口径重建）。
    /// `ScannerIndexIO.loadIndex` 对不支持的版本会打一行「索引版本过旧，重置索引
    /// 全量重建」日志后返回 `empty`。
    nonisolated static func loadIndex(cacheDir: URL, fileManager: FileManagerBox) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 10,
            empty: .empty,
            version: { $0.version },
            logTag: "[antigravity-scan]"
        )
    }

    nonisolated static func saveIndex(
        _ index: CacheIndex,
        cacheDir: URL,
        fileManager: FileManagerBox,
        hook: (@Sendable () -> Void)? = nil
    ) throws {
        #if DEBUG
        hook?()
        #endif
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动时恢复 index 中的 last-good local usage；后续 scan 仍会校验 session 指纹。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> AntigravityLocalUsage? {
        do {
            let index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
            guard !index.sessions.isEmpty, index.lastScannedAt.timeIntervalSince1970 > 0 else {
                return nil
            }
            let signature = LocalUsageCalendarSignature.make(calendar)
            guard index.calendarSignature == signature else {
                logInfo("[antigravity-scan] 冷启动缓存 calendar signature 不匹配，等待当前日历重建")
                return nil
            }
            let allDaily = computeGlobalDaily(from: index.dailyBySession, calendar: calendar)
            let todayStart = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
            let recent7 = filterLast7Days(allDaily: allDaily, today: todayStart, calendar: calendar)
            let samples = (index.samplesBySession ?? [:]).values
                .flatMap { $0 }
                .filter { $0.completedAt >= now.addingTimeInterval(-LocalUsageRetentionWindow.seconds) }
                .sorted { $0.completedAt < $1.completedAt }
            return AntigravityLocalUsage(
                today: allDaily.first(where: { $0.dayStart == todayStart }),
                dailyTokenUsage: recent7,
                scannedAt: index.lastScannedAt,
                sessionCount: index.sessions.count,
                eventCount: SaturatingArithmetic.sum(index.sessions.values.lazy.map(\.eventCount)),
                failedSessionCount: 0,
                recentSamples: samples
            )
        } catch {
            logWarn("[antigravity-scan] 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }
}
