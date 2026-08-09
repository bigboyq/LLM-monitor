import Foundation
import SQLite3
import Darwin

/// SQLite 读策略：快路径直接 read 原 .db，file-level 错误（SQLITE_CANTOPEN=14 /
/// SQLITE_BUSY=5）时 copy .db + .db-wal + .db-shm 到 /tmp 副本上 read。
///
/// 适用：任何读 IDE / runtime 实时写入的 .db（antigravity IDE、minimax runtime），
/// IDE 侧的 -shm 可能跟系统 dylib 不兼容导致直接 read CANTOPEN，copy 到 /tmp
/// 后完全隔离 IDE 实时 -shm 状态。
///
/// 不适用：自己创建 + 自己读的 .db（无 IDE 锁）。
enum SQLiteTempCopy {
    /// 跑 `action(URL)`：
    /// 1. 先用原 .db 路径
    /// 2. 如果是 file-level 错误（SQLITE_CANTOPEN / SQLITE_BUSY），copy 到 /tmp 副本再试
    /// 3. 其他错误（NOTADB / SQL 错误等）copy 救不了，直接 propagate
    ///
    /// - Parameter logTag: 日志前缀（例如 `[antigravity-scan]`），用于 fallback 提示
    /// - Parameter action: 拿到 URL 后做实际读，抛错会被外层 catch
    static func read<T>(dbPath: URL, logTag: String, _ action: (URL) throws -> T) throws -> T {
        // 1. 快路径：直接 read 原 .db
        do {
            return try action(dbPath)
        } catch let error as SQLiteConnectionError {
            let code: Int32
            switch error {
            case .openFailed(_, let c, _, _):
                code = c
            case .prepareFailed(let c, _, _, _):
                code = c
            case .bindFailed:
                throw error
            case .nullColumn:
                throw error
            case .stepFailed(let c, _, _):
                code = c
            }
            // raw 值跟 SQLite3 C header 一致
            let baseCode = code & 0xFF
            guard baseCode == SQLITE_CANTOPEN || baseCode == SQLITE_BUSY else {
                throw error
            }
            let kind = baseCode == SQLITE_CANTOPEN ? "CANTOPEN" : "BUSY"
            logInfo("\(logTag) 直接 read \(kind) (code=\(code))，fallback 到 /tmp 副本")
        }

        // 2. 兜底：copy .db + .db-wal + .db-shm 到 /tmp 副本
        return try withTempCopy(dbPath: dbPath, action)
    }

    /// 在 `/tmp` 下生成一个 `UUID.{db,db-wal,db-shm}` 三件套，defer 在闭包退出时
    /// 不管成功失败都清理。defer 在第一次文件创建之前就注册：覆盖
    /// "复制 .db 成功 → 复制 -wal 失败" 这种半完成场景，确保残留文件被清理。
    private static func withTempCopy<T>(
        dbPath: URL,
        _ action: (URL) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        let tempDir = NSTemporaryDirectory()
        let uuid = UUID().uuidString
        let tempDB = URL(fileURLWithPath: tempDir).appendingPathComponent("\(uuid).db")
        let tempWAL = URL(fileURLWithPath: tempDir).appendingPathComponent("\(uuid).db-wal")
        let tempSHM = URL(fileURLWithPath: tempDir).appendingPathComponent("\(uuid).db-shm")

        defer {
            try? fileManager.removeItem(at: tempDB)
            try? fileManager.removeItem(at: tempWAL)
            try? fileManager.removeItem(at: tempSHM)
        }

        var copied = false
        for attempt in 1...3 {
            try? fileManager.removeItem(at: tempDB)
            try? fileManager.removeItem(at: tempWAL)
            try? fileManager.removeItem(at: tempSHM)

            let before = try sourceFingerprint(dbPath: dbPath, fileManager: fileManager)
            do {
                try copyPrivate(from: dbPath, to: tempDB, fileManager: fileManager)
                if before.wal.exists {
                    try copyPrivate(
                        from: URL(fileURLWithPath: dbPath.path + "-wal"),
                        to: tempWAL,
                        fileManager: fileManager
                    )
                }
                if before.shm.exists {
                    try copyPrivate(
                        from: URL(fileURLWithPath: dbPath.path + "-shm"),
                        to: tempSHM,
                        fileManager: fileManager
                    )
                }
            } catch {
                // checkpoint 可能在 stat 与 copy 之间删除 WAL/SHM。若源指纹确实
                // 变化则按瞬态竞争重试；稳定源上的真实权限/I/O 错误直接上抛。
                if let afterFailure = try? sourceFingerprint(dbPath: dbPath, fileManager: fileManager),
                   afterFailure != before,
                   attempt < 3 {
                    logInfo("[sqlite-copy] 复制期间 sidecar 发生变化，重试 \(attempt)/3")
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                throw error
            }
            let after = try sourceFingerprint(dbPath: dbPath, fileManager: fileManager)
            if before == after {
                copied = true
                break
            }
            logInfo("[sqlite-copy] 源数据库复制期间发生变化，重试 \(attempt)/3")
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard copied else {
            throw SQLiteTempCopyError.sourceChangedDuringSnapshot(path: dbPath.path)
        }

        return try action(tempDB)
    }

    private struct FileState: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationTime: TimeInterval
    }

    private struct SourceFingerprint: Equatable {
        let db: FileState
        let wal: FileState
        let shm: FileState
    }

    private enum SQLiteTempCopyError: Error, LocalizedError {
        case sourceChangedDuringSnapshot(path: String)

        var errorDescription: String? {
            switch self {
            case .sourceChangedDuringSnapshot(let path):
                return "SQLite source changed while copying snapshot: \(path)"
            }
        }
    }

    private static func sourceFingerprint(
        dbPath: URL,
        fileManager: FileManager
    ) throws -> SourceFingerprint {
        try SourceFingerprint(
            db: fileState(at: dbPath, fileManager: fileManager),
            wal: fileState(at: URL(fileURLWithPath: dbPath.path + "-wal"), fileManager: fileManager),
            shm: fileState(at: URL(fileURLWithPath: dbPath.path + "-shm"), fileManager: fileManager)
        )
    }

    private static func fileState(at url: URL, fileManager: FileManager) throws -> FileState {
        guard fileManager.fileExists(atPath: url.path) else {
            return FileState(exists: false, size: 0, modificationTime: 0)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileState(exists: true, size: size, modificationTime: modified)
    }

    private static func copyPrivate(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw posixError(operation: "open source", path: source.path)
        }
        defer { Darwin.close(sourceDescriptor) }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else {
            throw posixError(operation: "open destination", path: destination.path)
        }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed {
                try? fileManager.removeItem(at: destination)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw posixError(operation: "read", path: source.path)
            }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: offset),
                        bytesRead - offset
                    )
                }
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    throw posixError(operation: "write", path: destination.path)
                }
                if bytesWritten == 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO),
                        userInfo: [NSLocalizedDescriptionKey: "write made no progress for \(destination.path)"]
                    )
                }
                offset += bytesWritten
            }
        }
        guard Darwin.fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError(operation: "fchmod", path: destination.path)
        }
        completed = true
    }

    private static func posixError(operation: String, path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(code)))"
            ]
        )
    }
}
