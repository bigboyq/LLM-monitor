import Foundation

/// db + WAL 的文件指纹（mtime + size 双维度）。单一结构供所有单库快照扫描器使用，
/// 取代各 scanner 私有的 `XxxDBFingerprint`。
struct DBFileFingerprint: Equatable, Sendable {
    let exists: Bool
    let mtimeMs: Double
    let sizeBytes: Int
    let walMtimeMs: Double
    let walSizeBytes: Int

    static let missing = DBFileFingerprint(
        exists: false, mtimeMs: 0, sizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0
    )
}

/// 单库快照扫描器的 on-disk index（version + db/WAL 指纹 + 完整快照）。
/// 字段与各 scanner 原来的 `CacheIndex` 完全一致，旧缓存文件无需迁移。
struct SnapshotCacheIndex<Usage: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    var version: Int
    var dbMtimeMs: Double
    var dbSizeBytes: Int
    var walMtimeMs: Double
    var walSizeBytes: Int
    var snapshot: Usage?

    func matches(_ fp: DBFileFingerprint) -> Bool {
        fp.exists
            && dbMtimeMs == fp.mtimeMs
            && dbSizeBytes == fp.sizeBytes
            && walMtimeMs == fp.walMtimeMs
            && walSizeBytes == fp.walSizeBytes
    }

    mutating func update(fingerprint: DBFileFingerprint, snapshot newSnapshot: Usage) {
        dbMtimeMs = fingerprint.mtimeMs
        dbSizeBytes = fingerprint.sizeBytes
        walMtimeMs = fingerprint.walMtimeMs
        walSizeBytes = fingerprint.walSizeBytes
        snapshot = newSnapshot
    }
}

/// 单一 SQLite db 的快照扫描器基座（当前：glm-zcode / opencode）。
///
/// 管线：stat db+WAL 指纹 → 指纹未变则复用缓存快照并按当前本地日重切 7 天窗口
/// （跨午夜滚动），指纹已变则重新聚合 + 写缓存。db 不存在返回子类的空快照。
///
/// 子类实现三个 hook：
/// - `emptySnapshot`：db 缺失时的空结果
/// - `buildSnapshot(now:)`：从 db 聚合并压成 7 天窗口快照
/// - `rebaseSnapshot(_:now:)`：缓存快照跨午夜的窗口滚动（含 samples 截断）
///
/// 仍复用：`SQLiteTempCopy.read`（活跃 WAL 的 CANTOPEN/BUSY 兜底）、
/// `LocalUsageScanRunner`（generation 守门 + 取消过滤）、`ScannerIndexIO`。
@MainActor
class SingleDBSnapshotScanner<Usage: Equatable & Codable & Sendable>: LocalUsageScannerBase<Usage>, @unchecked Sendable {
    typealias CacheIndex = SnapshotCacheIndex<Usage>

    nonisolated let dbURL: URL
    nonisolated let cacheDir: URL
    nonisolated let fileManager: FileManagerBox
    nonisolated let calendar: Calendar
    nonisolated let now: @Sendable () -> Date
    /// on-disk index 的版本号。格式变更时递增，旧缓存整体重建。
    nonisolated let cacheIndexVersion: Int

    init(
        dbURL: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        logTag: String,
        cacheIndexVersion: Int
    ) {
        self.dbURL = dbURL
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        self.cacheIndexVersion = cacheIndexVersion
        super.init(
            logTag: logTag,
            cachedResult: Self.loadCachedResult(
                cacheDir: cacheDir,
                fileManager: fileManager,
                logTag: logTag,
                currentVersion: cacheIndexVersion
            )
        )
    }

    override func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> Usage {
        { [self] in
            try await pipelineLock.withLock {
                try performScanLocked(nowDate: now())
            }
        }
    }

    // MARK: - 子类 hook

    /// db 不存在（客户端未安装 / 未运行过）时返回的空快照。
    nonisolated var emptySnapshot: Usage {
        fatalError("\(type(of: self)): subclass must override emptySnapshot")
    }

    /// 指纹已变：从 db 聚合并压成 7 天窗口快照。
    nonisolated func buildSnapshot(now: Date) throws -> Usage {
        fatalError("\(type(of: self)): subclass must override buildSnapshot(now:)")
    }

    /// 指纹未变：把缓存快照按当前日期重切 7 天窗口。仍需重切的原因：跨午夜且
    /// 数据库没有新写入时，昨天会一直被当成今天。
    nonisolated func rebaseSnapshot(_ snapshot: Usage, now: Date) throws -> Usage {
        fatalError("\(type(of: self)): subclass must override rebaseSnapshot(_:now:)")
    }

    // MARK: - 共享管线

    /// 纯 I/O + 计算。在 `pipelineMutex` 内串行执行。
    nonisolated private func performScanLocked(nowDate: Date) throws -> Usage {
        try fileManager.createPrivateDirectory(at: cacheDir)

        // 1. db + WAL 指纹
        let fingerprint = try Self.statFingerprint(dbURL: dbURL, fileManager: fileManager)
        guard fingerprint.exists else {
            logInfo("\(logTag) db 不存在: \(dbURL.path)")
            return emptySnapshot
        }

        // 2. 指纹没变 → 直接用缓存快照（不做 SQL）。rebase 后窗口/样本有实际变化
        //    才回写缓存，避免每轮空写盘。
        var index = try Self.loadIndex(
            cacheDir: cacheDir, fileManager: fileManager,
            logTag: logTag, currentVersion: cacheIndexVersion
        )
        if index.matches(fingerprint), let snapshot = index.snapshot {
            logDebug("\(logTag) 指纹未变，复用缓存快照")
            let rebased = try rebaseSnapshot(snapshot, now: nowDate)
            if rebased != snapshot {
                index.update(fingerprint: fingerprint, snapshot: rebased)
                try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
            }
            return rebased
        }

        // 3. 聚合 + 写缓存
        let snapshot = try buildSnapshot(now: nowDate)
        index.update(fingerprint: fingerprint, snapshot: snapshot)
        try Self.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        return snapshot
    }

    // MARK: - 指纹与 index I/O（static 保持子类测试表面稳定）

    /// 同时 stat `.db` 与 `.db-wal`。db 明确缺失 → exists=false；WAL 缺失按零指纹；
    /// 其它 stat 错误上抛（保留 last-good 语义由调用方处理）。
    nonisolated static func statFingerprint(
        dbURL: URL,
        fileManager: FileManagerBox
    ) throws -> DBFileFingerprint {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: dbURL.path)
        } catch {
            if ScannerFileError.isExplicitlyMissing(error) {
                return .missing
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
                return DBFileFingerprint(
                    exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
                    walMtimeMs: 0, walSizeBytes: 0
                )
            }
            throw error
        }
        let walSize = (walAttrs[.size] as? NSNumber)?.intValue ?? 0
        let walMtime = (walAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return DBFileFingerprint(
            exists: true, mtimeMs: mtime * 1000, sizeBytes: max(0, size),
            walMtimeMs: walMtime * 1000, walSizeBytes: max(0, walSize)
        )
    }

    nonisolated static func loadIndex(
        cacheDir: URL,
        fileManager: FileManagerBox,
        logTag: String,
        currentVersion: Int
    ) throws -> CacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir, fileManager: fileManager,
            currentVersion: currentVersion, empty: emptyIndex(version: currentVersion),
            version: { $0.version }, logTag: logTag
        )
    }

    nonisolated static func saveIndex(
        _ index: CacheIndex,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }

    /// 冷启动先展示上次成功扫描的快照；正常 scan 会重新按当前日期 rebase。
    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        logTag: String,
        currentVersion: Int
    ) -> Usage? {
        do {
            return try loadIndex(
                cacheDir: cacheDir, fileManager: fileManager,
                logTag: logTag, currentVersion: currentVersion
            ).snapshot
        } catch {
            logWarn("\(logTag) 冷启动恢复 index 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func emptyIndex(version: Int) -> CacheIndex {
        CacheIndex(
            version: version, dbMtimeMs: 0, dbSizeBytes: 0,
            walMtimeMs: 0, walSizeBytes: 0, snapshot: nil
        )
    }
}
