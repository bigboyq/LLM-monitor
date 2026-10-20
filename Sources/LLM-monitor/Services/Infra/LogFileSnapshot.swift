import Foundation

// MARK: - Log File Fingerprint & Snapshot

/// 日志文件指纹（用于缓存索引失效判定与增量比对）
struct LogFileFingerprint: Codable, Equatable, Hashable, Sendable {
    let path: String
    let modificationMs: Double
    let sizeBytes: Int

    init(path: String, modificationMs: Double, sizeBytes: Int) {
        self.path = path
        self.modificationMs = modificationMs
        self.sizeBytes = sizeBytes
    }
}

/// 日志文件元数据快照（避免在扫描过程中对同一文件重复 stat）
struct LogFileSnapshot: Sendable {
    let url: URL
    let modifiedAt: Date
    let sizeBytes: Int

    init(url: URL, modifiedAt: Date, sizeBytes: Int) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }

    init(url: URL, fileManager: FileManagerBox) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        self.url = url
        self.modifiedAt = (attributes[.modificationDate] as? Date) ?? Date.distantPast
        self.sizeBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    var fingerprint: LogFileFingerprint {
        LogFileFingerprint(
            path: url.path,
            modificationMs: modifiedAt.timeIntervalSince1970 * 1_000,
            sizeBytes: sizeBytes
        )
    }
}

/// 日志文件选取结果：mtime 最新优先切片，同时受文件数和原始字节数上限约束
struct LogFileSelection: Sendable {
    let snapshots: [LogFileSnapshot]
    /// 应用任何上限前发现的有效且非空快照数量
    let availableCount: Int
    /// 是否因字节上限丢弃了至少一个原本入选的文件
    let byteLimited: Bool
    /// 在选取前读取指纹/stat 失败的文件数
    let failedFileCount: Int

    init(
        snapshots: [LogFileSnapshot],
        availableCount: Int,
        byteLimited: Bool,
        failedFileCount: Int
    ) {
        self.snapshots = snapshots
        self.availableCount = availableCount
        self.byteLimited = byteLimited
        self.failedFileCount = failedFileCount
    }

    var truncatedByFileLimit: Bool {
        snapshots.count < availableCount
    }
}

// MARK: - Log File Selector

enum LogFileSelector {
    /// 统一日志文件选择器：mtime 最新优先，文件数与字节预算双重截断
    static func select(
        filePaths: [URL],
        fileManager: FileManagerBox,
        maxSessionFiles: Int,
        maxTotalRawBytes: Int,
        snapshotReader: ((URL) throws -> LogFileSnapshot)? = nil,
        onWarning: ((_ url: URL, _ error: any Error) -> Void)? = nil
    ) -> LogFileSelection {
        var candidates: [LogFileSnapshot] = []
        candidates.reserveCapacity(filePaths.count)
        var failedFileURLs: [URL] = []
        for url in filePaths {
            let snapshot: LogFileSnapshot?
            do {
                snapshot = try snapshotReader.map { try $0(url) }
                    ?? LogFileSnapshot(url: url, fileManager: fileManager)
            } catch {
                failedFileURLs.append(url)
                onWarning?(url, error)
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
        let fileCapped = Array(ordered.prefix(maxSessionFiles))
        var selected: [LogFileSnapshot] = []
        var currentBytes = 0
        var byteLimited = false
        for snapshot in fileCapped {
            let accumulated = SaturatingArithmetic.add(currentBytes, snapshot.sizeBytes)
            if accumulated > maxTotalRawBytes {
                byteLimited = true
                break
            }
            currentBytes = accumulated
            selected.append(snapshot)
        }
        return LogFileSelection(
            snapshots: selected,
            availableCount: candidates.count,
            byteLimited: byteLimited,
            failedFileCount: failedFileURLs.count
        )
    }
}
