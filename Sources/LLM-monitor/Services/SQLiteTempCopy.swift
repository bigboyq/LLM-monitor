import Foundation
import SQLite3
import Darwin

/// SQLite 读策略：优先直接 read 原 .db，file-level 错误（SQLITE_CANTOPEN=14 /
/// SQLITE_BUSY=5 / SQLITE_READONLY=8 家族 / SQLITE_IOERR=10 / SQLITE_CORRUPT=11）
/// 或 immutable=1 直读复检发现写进程出现（`lostImmutableRace`）时 copy .db +
/// .db-wal + .db-shm 到私有临时副本上 read。
///
/// 适用：任何读 IDE / runtime 实时写入的 .db（antigravity、minimax runtime），
/// IDE 侧的 -shm 可能跟系统 dylib 不兼容导致直接 read CANTOPEN，copy 到 /tmp
/// 后完全隔离 IDE 实时 -shm 状态。
///
/// 不适用：自己创建 + 自己读的 .db（无 IDE 锁）。
enum SQLiteTempCopy {
    /// R12: 应用专属临时目录名，副本只出现在 `$TMPDIR/llm-monitor-sqlite/`。
    static let appTempSubdir = "llm-monitor-sqlite"

    /// R12: 应用专属临时目录（`$TMPDIR/llm-monitor-sqlite/`，0700）。
    static func appTempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(appTempSubdir, isDirectory: true)
    }

    /// R12: 启动时清理专属临时目录内超过 `maxAge`（默认 24h）的残留副本。
    /// 只扫描该目录内部；目录是 symlink / 非普通目录时放弃清理并 warning，
    /// 绝不扫描或删除 `$TMPDIR` 其他文件。
    static func sweepStaleCopies(now: Date = Date(), maxAge: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        let dir = appTempDir()
        // lstat 检测路径本身是不是 symlink/非目录（不跟随）。
        var st = stat()
        guard lstat(dir.path, &st) == 0 else {
            return  // 目录不存在——无需清理
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            logWarn("[sqlite-copy] 专属临时目录是 symlink 或非目录，跳过清理")
            return
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries {
            let entryURL = dir.appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: entryURL.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) > maxAge {
                try? fm.removeItem(at: entryURL)
            }
        }
    }

    /// R12: 确保专属临时目录存在且权限为 0700。
    private static func ensureAppTempDir() throws -> URL {
        let dir = appTempDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
        return dir
    }

    /// 跑 `action(URL)`：
    /// 1. 先用原 .db 路径
    /// 2. 如果是 file-level 错误（SQLITE_CANTOPEN / SQLITE_BUSY / SQLITE_READONLY
    ///    家族含 READONLY_RECOVERY(264) 等扩展码 / SQLITE_IOERR），copy 到 /tmp 副本再试
    /// 3. 其他错误（NOTADB / SQL 错误等）copy 救不了，直接 propagate
    ///
    /// - Parameter logTag: 日志前缀（例如 `[antigravity-scan]`），用于 fallback 提示
    /// - Parameter action: 拿到 URL 后做实际读，抛错会被外层 catch
    static func read<T>(
        dbPath: URL,
        logTag: String,
        _ action: (URL) throws -> T
    ) throws -> T {
        // L2: 本轮入口是否为直读 CORRUPT（副本读取同样 CORRUPT 时据此记忆持久损坏）。
        var directCorrupt = false
        // 1. 快路径：直接 read 原 .db
        do {
            return try action(dbPath)
        } catch let error as SQLiteConnectionError {
            let code: Int32
            switch error {
            case .lostImmutableRace:
                // FIX6: immutable=1 直读在打开后的复检中发现 -shm/-wal 出现（写进程刚
                // 出现）。这不是扫描失败，而是「直读前提失效」——必须路由进 withTempCopy
                // 用一致性快照副本完成本轮读取，而不是上抛导致整轮扫描失败。
                logInfo("\(logTag) immutable=1 直读复检发现 -shm/-wal 出现（写进程刚出现），fallback 到 /tmp 副本")
                return try withTempCopy(dbPath: dbPath, action)
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
            // L2: 直读 CORRUPT 且持久损坏记忆命中（上次副本读取同样 CORRUPT 且源
            // 指纹未变）——真损坏而非竞态撕裂，跳过 /tmp 全量拷贝快速失败。
            if baseCode == SQLITE_CORRUPT,
               isPersistentCorruptionRemembered(dbPath: dbPath, fileManager: .default) {
                logInfo("\(logTag) 直接 read CORRUPT (code=\(code))，且持久损坏记忆命中（源指纹未变），跳过 /tmp 拷贝快速失败")
                throw error
            }
            // 可回退白名单：只收"file-level、拷贝副本确实可能救"的错误，逐条理由：
            // - CANTOPEN(14)：IDE 遗留的 -shm 与本进程 dylib 不兼容等，直连打不开；
            //   副本完全隔离源 -shm/WAL 状态。
            // - BUSY(5)：IDE 短写锁 busy_timeout(300ms) 内没等到；副本上无竞争。
            // - READONLY(8)：直读路径以 SQLITE_OPEN_READONLY 打开（见
            //   SQLiteConnection），写入方崩溃遗留需要 recovery 的 -shm/WAL 时，
            //   只读连接抛扩展码 SQLITE_READONLY_RECOVERY(264) /
            //   READONLY_CANTINIT 等，& 0xFF 后主码都是 8——这正是副本最该兜住的
            //   场景：副本以 READWRITE 打开，可以在副本上完成 WAL recovery。
            // - IOERR(10)（含 IOERR_SHORT_READ 等扩展码）：保守纳入。源被短暂锁住 /
            //   -shm 状态异常（IOERR_SHMOPEN、IOERR_SHMLOCK 等扩展码）时，拷到本地
            //   /tmp 换一条干净 I/O 路径可能救回；副本路径仍失败则错误照常上抛。
            //   注意回退的最坏代价并非「多一次尝试」：活跃持续写入下，每轮的 db
            //   全量拷贝都可能在拷完的瞬间失效（withTempCopy 的逐文件指纹校验会立即
            //   放弃该轮），最多重试 3 轮后抛 sourceChangedDuringSnapshot——最坏情况
            //   是向 $TMPDIR 做 3 次 GB 级 db 全量拷贝后仍失败，调用方按本轮扫描
            //   失败处理。
            // - CORRUPT(11)：并发写方的 auto-checkpoint 可能在直读进行到一半时原地
            //   改写/截断主库页，无锁 immutable 直读会把撕裂页读成 CORRUPT；此时源
            //   库本身通常完好，重拷一份一致快照即可自愈。若库真损坏，副本读取会在
            //   同一位置同样失败并上抛——首轮仍多付一次有界的全量拷贝代价，之后由
            //   L2 的持久损坏记忆在后续轮次跳过拷贝（源指纹未变即快速失败）。
            // 救不了的维持上抛：NOTADB（文件本身不是数据库，拷贝无用）、SQL / 绑定
            // 等逻辑错误（换路径结果一样）。
            guard baseCode == SQLITE_CANTOPEN || baseCode == SQLITE_BUSY
                || baseCode == SQLITE_READONLY || baseCode == SQLITE_IOERR
                || baseCode == SQLITE_CORRUPT else {
                throw error
            }
            let kind: String
            switch baseCode {
            case SQLITE_CANTOPEN: kind = "CANTOPEN"
            case SQLITE_BUSY: kind = "BUSY"
            case SQLITE_READONLY: kind = "READONLY"
            case SQLITE_CORRUPT: kind = "CORRUPT"
            default: kind = "IOERR"
            }
            logInfo("\(logTag) 直接 read \(kind) (code=\(code))，fallback 到 /tmp 副本")
            directCorrupt = baseCode == SQLITE_CORRUPT
        }

        // 2. 兜底：copy .db + .db-wal + .db-shm 到 /tmp 副本
        do {
            return try withTempCopy(dbPath: dbPath, action)
        } catch let copyError as SQLiteConnectionError {
            // L2: 本轮入口是直读 CORRUPT 且副本上的读取同样 CORRUPT → 判定为持久
            // 损坏而非并发 checkpoint 撕裂（撕裂页重拷即自愈；真损坏重拷后仍在同一
            // 位置失败）。按源库路径 + 源指纹（mtime/size）记忆，进程内不落盘，
            // 文件变化即失效；后续轮次跳过 /tmp 拷贝快速失败。
            guard directCorrupt, isCorrupt(copyError) else { throw copyError }
            rememberPersistentCorruption(dbPath: dbPath, fileManager: .default)
            logInfo("\(logTag) /tmp 副本上的读取同样 CORRUPT，判定持久损坏并记忆，后续轮次跳过拷贝")
            throw copyError
        }
    }

    /// 在 `/tmp` 下生成一个 `UUID.{db,db-wal,db-shm}` 三件套，defer 在闭包退出时
    /// 不管成功失败都清理。defer 在第一次文件创建之前就注册：覆盖
    /// "复制 .db 成功 → 复制 -wal 失败" 这种半完成场景，确保残留文件被清理。
    ///
    /// FIX12: 拷贝循环带逐文件指纹校验——db（大文件）拷完立即复验源指纹，失效则
    /// 立即放弃本轮剩余拷贝（wal/shm 不拷）进入下一轮；最多 3 轮，耗尽后抛
    /// `sourceChangedDuringSnapshot`（defer 同样覆盖该失败路径，不留临时副本）。
    private static func withTempCopy<T>(
        dbPath: URL,
        _ action: (URL) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        // R12: 副本只出现在应用专属临时目录 $TMPDIR/llm-monitor-sqlite/（0700）。
        let tempDir = try ensureAppTempDir()
        let uuid = UUID().uuidString
        let tempDB = tempDir.appendingPathComponent("\(uuid).db")
        let tempWAL = tempDir.appendingPathComponent("\(uuid).db-wal")
        let tempSHM = tempDir.appendingPathComponent("\(uuid).db-shm")

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
            // FIX12: 本轮是否已在「db 拷完立即复验」处判定失效（wal/shm 不再拷贝）。
            var roundAbandonedAfterDB = false
            do {
                try copyPrivate(from: dbPath, to: tempDB, fileManager: fileManager)
                // FIX12: 逐文件指纹校验 —— db（大文件）拷完立即复验源指纹。活跃持续
                // 写入下 db 拷贝可能耗时数秒，拷完即失效是常态而非例外；本轮已报废，
                // 继续拷 wal/shm 纯属浪费（下一轮反正全部重来），立即放弃剩余拷贝。
                if try sourceFingerprint(dbPath: dbPath, fileManager: fileManager) != before {
                    roundAbandonedAfterDB = true
                    logInfo("[sqlite-copy] db 拷贝后源指纹已变化，放弃本轮 wal/shm 拷贝，重试 \(attempt)/3")
                }
                if !roundAbandonedAfterDB {
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
            if roundAbandonedAfterDB {
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                break
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
            // FIX12: defer（注册于循环之前）同样覆盖本失败路径——3 轮耗尽抛错前，
            // 本轮 tempDB/tempWAL/tempSHM 残留已被清理，不会在 $TMPDIR 留下
            // GB 级垃圾。
            throw SQLiteTempCopyError.sourceChangedDuringSnapshot(path: dbPath.path)
        }

        return try action(tempDB)
    }

    // FIX12: internal（原 private）——测试钩子 sourceFingerprintOverride 需要构造
    // 这两个值类型来模拟「源指纹持续变化」。
    struct FileState: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationTime: TimeInterval
    }

    struct SourceFingerprint: Equatable {
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

    /// FIX12 测试钩子（internal，仅测试注入；生产路径恒为 nil、零开销）：非 nil 时
    /// `sourceFingerprint` 改走注入实现，用于在测试中模拟「活跃写入下源指纹持续
    /// 变化」而无需真实并发写进程。
    ///
    /// L3: 原为无同步的可变全局 static——生产路径每次指纹采样都会读它，测试可能
    /// 并发写入。改为 NSLock 保护的存取器，外部读/写/置 nil 的用法不变。
    typealias SourceFingerprintProbe = (
        _ dbPath: URL, _ fileManager: FileManager
    ) throws -> SourceFingerprint

    private nonisolated(unsafe) static var storedSourceFingerprintOverride: SourceFingerprintProbe?
    private static let sourceFingerprintOverrideLock = NSLock()

    nonisolated(unsafe) static var sourceFingerprintOverride: SourceFingerprintProbe? {
        get { sourceFingerprintOverrideLock.withLock { storedSourceFingerprintOverride } }
        set { sourceFingerprintOverrideLock.withLock { storedSourceFingerprintOverride = newValue } }
    }

    // MARK: - L2: 持久损坏源库记忆

    /// L2: 持久损坏源库记忆（进程内、不落盘）：key = 源库路径，value = 记忆时的
    /// 源指纹（db + -wal + -shm 的 mtime/size）。直读 CORRUPT 且源指纹与记忆一致
    /// 时跳过 /tmp 拷贝快速失败；指纹变化（文件被替换/修复/追加写入）即失效。
    /// 键按路径天然有界（App 只读固定的几个源库），无需淘汰。
    private nonisolated(unsafe) static var persistentCorruptionMemory: [String: SourceFingerprint] = [:]
    private static let corruptionMemoryLock = NSLock()

    /// 错误主码是否 SQLITE_CORRUPT(11)（含扩展码）。
    private static func isCorrupt(_ error: SQLiteConnectionError) -> Bool {
        switch error {
        case .lostImmutableRace, .bindFailed, .nullColumn:
            return false
        case .openFailed(_, let code, _, _),
             .prepareFailed(let code, _, _, _),
             .stepFailed(let code, _, _):
            return code & 0xFF == SQLITE_CORRUPT
        }
    }

    /// L2: 持久损坏记忆是否命中（源指纹与记忆一致）。指纹采样失败或源已变化
    /// （记忆失效并移除）时返回 false，按正常回退处理——记忆只是跳拷贝的
    /// 优化，任何不确定情形都退回「重拷一次」的保守路径。
    private static func isPersistentCorruptionRemembered(
        dbPath: URL,
        fileManager: FileManager
    ) -> Bool {
        let remembered = corruptionMemoryLock.withLock {
            persistentCorruptionMemory[dbPath.path]
        }
        guard let remembered else { return false }
        guard let current = try? sourceFingerprint(dbPath: dbPath, fileManager: fileManager) else {
            return false
        }
        if current != remembered {
            // 源文件已变化：记忆失效（可能已被替换/修复），移除后恢复回退。
            corruptionMemoryLock.withLock {
                if persistentCorruptionMemory[dbPath.path] == remembered {
                    persistentCorruptionMemory[dbPath.path] = nil
                }
            }
            return false
        }
        return true
    }

    /// L2: 记录持久损坏源库（当前源指纹）。指纹采样失败时不记忆——下一轮仍按
    /// 原路径重拷一次，与既有行为一致。
    private static func rememberPersistentCorruption(dbPath: URL, fileManager: FileManager) {
        guard let fingerprint = try? sourceFingerprint(dbPath: dbPath, fileManager: fileManager) else {
            return
        }
        corruptionMemoryLock.withLock {
            persistentCorruptionMemory[dbPath.path] = fingerprint
        }
    }

    private static func sourceFingerprint(
        dbPath: URL,
        fileManager: FileManager
    ) throws -> SourceFingerprint {
        if let override = sourceFingerprintOverride {
            return try override(dbPath, fileManager)
        }
        return try SourceFingerprint(
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
