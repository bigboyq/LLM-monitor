import Foundation

// MARK: - Filesystem operations (off main actor)

/// `internal`（default）：被 `extension AntigravityLocalUsageScanner` 里的
/// `nonisolated static func fetchAll` 引用，必须 >= 函数的 access level。
struct AntigravityDBFileInfo: Sendable {
    let url: URL
    let sizeBytes: Int
    let mtimeMs: Double
    let walSizeBytes: Int
    let walMtimeMs: Double
    let format: SessionStoreFormat
}

/// 一次 conversations roots 枚举的结果。
///
/// `isComplete=false` 表示至少一个 root 或候选文件遇到权限/TCC/瞬时 I/O 错误；
/// 此时 `files` 仍可用于刷新已成功发现的 session，但不能据此删除缓存。
struct AntigravityDBFileListing: Sendable {
    let files: [String: AntigravityDBFileInfo]
    let isComplete: Bool
}

/// Antigravity 把每个 cascade 存成本地文件，扩展名用于识别文件格式和
/// 决定是否检查 SQLite WAL 指纹。Token 数据仍只来自 RPC；SQLite 仅在 RPC
/// 缺少时间戳时读取匹配 step metadata 做回填：
///
/// - `.db`（SQLite）：读取文件/WAL 指纹，必要时读取时间 metadata。
/// - `.pb`（protobuf）：只读取文件指纹，不做 protobuf 解析。该格式最初由已剥离的
///   Antigravity IDE.app 引入，`~/.gemini/antigravity/` 中同样会出现，故保留支持。
///   两种格式都依赖 RPC 提供 Token、时间和 stepIndices，再推算 R/T。
enum SessionStoreFormat: String, Sendable {
    case sqlite        // .db
    case protobuf      // .pb

    /// 从文件扩展名推断格式。未知扩展名返回 nil。
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "db": self = .sqlite
        case "pb": self = .protobuf
        default: return nil
        }
    }
}

extension AntigravityLocalUsageScanner {
    /// Newer Antigravity responses can omit `createdAt` while still carrying
    /// `stepIndices`. For SQLite sessions, those indices identify the matching
    /// `step_type=15` rows whose metadata contains the authoritative timestamp.
    /// Token values remain sourced exclusively from the RPC response.
    nonisolated static func recoverMissingTimestamps(
        _ events: [AntigravityFetcher.UsageEvent],
        fileInfo: AntigravityDBFileInfo?
    ) -> [AntigravityFetcher.UsageEvent] {
        guard let fileInfo, fileInfo.format == .sqlite else { return events }
        let missingIndices = Set(
            events
                .filter { $0.timestamp == nil }
                .flatMap { $0.stepIndices ?? [] }
        )
        guard !missingIndices.isEmpty else { return events }

        let timestamps: [Int: Date]
        do {
            timestamps = try SQLiteTempCopy.read(
                dbPath: fileInfo.url,
                logTag: "[antigravity-scan] timestamp fallback"
            ) { dbPath in
                try AntigravityStepTimestampReader.timestamps(
                    dbPath: dbPath,
                    stepIndices: missingIndices
                )
            }
        } catch {
            logWarn("[antigravity-scan] timestamp fallback failed: \(error.localizedDescription)")
            return events
        }

        var recovered = 0
        let mapped = events.map { event in
            guard event.timestamp == nil,
                  let timestamp = (event.stepIndices ?? [])
                    .compactMap({ timestamps[$0] })
                    .min() else {
                return event
            }
            recovered = SaturatingArithmetic.add(recovered, 1)
            return event.withTimestamp(timestamp)
        }
        if recovered > 0 {
            logInfo("[antigravity-scan] timestamp fallback recovered \(recovered) events from SQLite step metadata")
        }
        return mapped
    }

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
            var perFmt: [String: Int] = [:]
            for url in entries {
                guard let format = SessionStoreFormat(fileExtension: url.pathExtension) else { continue }
                perFmt[format.rawValue] = SaturatingArithmetic.add(
                    perFmt[format.rawValue, default: 0],
                    1
                )
                accepted.append(url)
            }
            logInfo("[antigravity-scan] list \(dirTag)/conversations/ — \(entries.count) 文件, accepted \(accepted.count) (\(perFmt.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")))")

            for url in accepted {
                guard let format = SessionStoreFormat(fileExtension: url.pathExtension) else { continue }
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
                let walAttributes: [FileAttributeKey: Any]?
                if format == .sqlite {
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
                } else {
                    walAttributes = nil
                }
                let walSize = (walAttributes?[.size] as? NSNumber)?.intValue ?? 0
                let walMtime = (walAttributes?[.modificationDate] as? Date) ?? .distantPast
                result[sessionId] = AntigravityDBFileInfo(
                    url: url,
                    sizeBytes: size,
                    mtimeMs: mtime.timeIntervalSince1970 * 1000,
                    walSizeBytes: walSize,
                    walMtimeMs: walAttributes == nil ? 0 : walMtime.timeIntervalSince1970 * 1000,
                    format: format
                )
            }
        }
        return AntigravityDBFileListing(files: result, isComplete: isComplete)
    }

    /// 本 index 里被跟踪的全部 sessionId = `sessions` 的键 ∪ 全部 per-session
    /// 状态字段的键。
    ///
    /// 打击计数（空 suffix / 零可计账 / offset 回归）、部分命中告警去重与旧日历
    /// 待重建标记，都会在写 `index.sessions[id]` **之前**被写入——那些分支
    /// `continue` 得早，先攒计数、后建条目。只按 `sessions.keys` 算「已跟踪」会
    /// 漏掉仅有打击计数的 session：文件删除时清理循环看不到它的键，残留永久留在
    /// index.json；同 sessionId 复活时从残留值续算，1~2 轮即提前收敛成「空终结
    /// 条目」，把该指纹周期的数据静默丢掉。
    nonisolated static func trackedSessionIDs(in index: CacheIndex) -> Set<String> {
        var ids = Set(index.sessions.keys)
        if let strikes = index.emptyFullStrikesBySession { ids.formUnion(strikes.keys) }
        if let strikes = index.zeroAccountedFullStrikesBySession { ids.formUnion(strikes.keys) }
        if let strikes = index.offsetRegressionStrikesBySession { ids.formUnion(strikes.keys) }
        if let warned = index.partialHitWarnedBySession { ids.formUnion(warned.keys) }
        ids.formUnion(index.calendarRebuildPendingSessions ?? [])
        return ids
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

    nonisolated static func loadIndex(cacheDir: URL, fileManager: FileManagerBox) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 7,
            empty: .empty,
            version: { $0.version },
            migrate: { idx in
                guard (2...6).contains(idx.version) else { return false }
                if idx.version <= 5 {
                    // v5 及更早版本的 per-session samples / daily R/T 可能来自
                    // 旧版本的 samples / R/T 结果可能来自 SQLite 读取路径。纯 RPC
                    // 版本的 stepIndices 推断结果不能与旧结果混用；清空逐次调用索引，使每个现有 session 都因
                    // samplesBySession?[sessionId] == nil 而强制重新走 RPC。
                    // dailyBySession 保留为 RPC 失败时的 last-good fallback。
                    idx.samplesBySession = [:]
                }
                idx.version = 7
                return true
            },
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
            let todayStart = todayCutoff(now: now, calendar: calendar)
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
