import Foundation
import SQLite3

/// SQLite3 错误类型（统一两个 reader 用的 enum）
enum SQLiteConnectionError: Error, CustomStringConvertible {
    case openFailed(path: String, code: Int32, extendedCode: Int32, message: String)
    case prepareFailed(code: Int32, extendedCode: Int32, message: String, sql: String)
    case bindFailed(code: Int32, extendedCode: Int32, message: String, sql: String)
    case nullColumn(index: Int)
    case stepFailed(code: Int32, extendedCode: Int32, message: String)

    var description: String {
        switch self {
        case .openFailed(let path, let code, let extCode, let msg):
            return "SQLiteConnection open failed (code=\(code), extendedCode=\(extCode)) for path=\(path): \(msg)"
        case .prepareFailed(let code, let extCode, let msg, let sql):
            return "SQLiteConnection prepare failed (code=\(code), extendedCode=\(extCode)) for \(sql): \(msg)"
        case .bindFailed(let code, let extCode, let msg, let sql):
            return "SQLiteConnection bind failed (code=\(code), extendedCode=\(extCode)) for \(sql): \(msg)"
        case .nullColumn(let index):
            return "SQLiteConnection required column \(index) was NULL"
        case .stepFailed(let code, let extCode, let msg):
            return "SQLiteConnection step failed (code=\(code), extendedCode=\(extCode)): \(msg)"
        }
    }
}

import Darwin

/// 通用 SQLite3 connection（取代 AntigravityDBReader / MinimaxDBReader 里重复的
/// init / close / open flag / busy_timeout / extended_result_codes / query 模板）
///
/// 线程模型：单 instance 单线程使用。
///
/// open flags 策略：
/// 1. readOnly=true:
///    - 若不存在 -shm 且不存在非空 -wal：说明写端（ZCode / IDE 等）未运行且主库已 checkpoint，
///      使用 `file:<path>?immutable=1` URI 只读打开，绕过 SQLite 对 WAL 共享内存的检查，
///      避免在无 -shm 时准备语句抛出 SQLITE_CANTOPEN(14)，避免无意义的 /tmp 拷贝。
///    - 若存在 -shm 或非空 -wal：以标准 `SQLITE_OPEN_READONLY` 打开，尝试读取实时 WAL。
///      若遇需要 recovery 的 dirty WAL 或锁冲突抛错，由外层 `SQLiteTempCopy` 捕获并回退到 /tmp 副本。
/// 2. readOnly=false:
///    - 默认 `SQLITE_OPEN_READWRITE`（**不是** READONLY）：用于 /tmp 副本，
///      SQLite 必须能写回 WAL recovery，否则 prepare 阶段会返回 SQLITE_CANTOPEN(14)。
///
/// busy_timeout(300) 等 IDE 释放短写锁。
/// extended_result_codes(1) 拿 SQLITE_CANTOPEN_* 子类型诊断。
final class SQLiteConnection {
    private var handle: OpaquePointer?
    let path: String

    /// 判断是否满足直接以 immutable=1 URI 只读打开的条件：
    /// 仅在 readOnly=true 且不存在 -shm 且不存在非空 -wal 时成立。
    ///
    /// 语义：
    /// - 没有 -shm：表示写进程（ZCode / IDE 等）未运行或已干净退出。
    /// - 没有非空 -wal：表示没有待回放/checkpoint 的未落盘数据。
    /// 此时主库处于完全静止且一致的状态。使用 immutable=1 可以让 SQLite 完全跳过
    /// WAL 共享内存（-shm）检查，直接只读读取主库 pages，避免在无 -shm 时抛出
    /// SQLITE_CANTOPEN(14) 误触发 /tmp 副本拷贝。
    static func canOpenImmutable(path: URL, readOnly: Bool) -> Bool {
        guard readOnly else { return false }
        let shmPath = path.path + "-shm"
        let walPath = path.path + "-wal"
        var shmStat = stat()
        let shmExists = stat(shmPath, &shmStat) == 0
        guard !shmExists else { return false }
        var walStat = stat()
        let walHasData = (stat(walPath, &walStat) == 0) && (walStat.st_size > 0)
        return !walHasData
    }

    init(path: URL, readOnly: Bool = false) throws {
        self.path = path.path
        var db: OpaquePointer?
        let targetPath: String
        let flags: Int32

        if Self.canOpenImmutable(path: path, readOnly: readOnly) {
            if var components = URLComponents(url: path, resolvingAgainstBaseURL: false) {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "immutable", value: "1")]
                targetPath = components.string ?? (path.absoluteString + "?immutable=1")
            } else {
                targetPath = path.absoluteString + "?immutable=1"
            }
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            targetPath = self.path
            flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        }

        let code = sqlite3_open_v2(targetPath, &db, flags, nil)
        if code != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            let extCode = db.map { sqlite3_extended_errcode($0) } ?? code
            if let db { sqlite3_close(db) }
            throw SQLiteConnectionError.openFailed(path: self.path, code: code, extendedCode: extCode, message: msg)
        }
        guard let db else {
            throw SQLiteConnectionError.openFailed(path: self.path, code: -1, extendedCode: -1, message: "nil db handle")
        }

        // 启用扩展错误码，便于诊断 CANTOPEN_* 子类型
        sqlite3_extended_result_codes(db, 1)

        // 300ms busy timeout：等 IDE 释放短写锁
        sqlite3_busy_timeout(db, 300)
        self.handle = db
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    /// 安全读取必填文本列。`sqlite3_column_text` 对 SQL NULL 返回空指针，
    /// 直接交给 `String(cString:)` 会崩溃。
    static func requiredText(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else {
            throw SQLiteConnectionError.nullColumn(index: Int(column))
        }
        return String(cString: pointer)
    }

    static func requiredInt64(_ statement: OpaquePointer, column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            throw SQLiteConnectionError.nullColumn(index: Int(column))
        }
        return sqlite3_column_int64(statement, column)
    }

    /// 可选聚合列的安全读取：SQL NULL 按业务统计的零值处理。
    static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64 {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return 0 }
        return sqlite3_column_int64(statement, column)
    }

    static func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return 0 }
        return sqlite3_column_double(statement, column)
    }

    static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: pointer)
    }

    // MARK: - 三个 DB reader 共享的小工具（此前各自持有一份逐字相同的实现）

    /// SQLITE_TRANSIENT 析构器：绑定临时 buffer 时让 SQLite 自行复制内容。
    static let sqliteTransientDestructor = unsafeBitCast(
        Int(-1), to: sqlite3_destructor_type.self
    )

    /// R9: Int64? → 非负 Int 饱和（NULL 当 0，负值当 0，超出 Int 范围封顶）。
    /// SQL 聚合列进入业务模型的统一边界。
    @inline(__always)
    static func nnClamp(_ x: Int64?) -> Int {
        let v = Int(clamping: x ?? 0)
        return v < 0 ? 0 : v
    }

    /// `(? IS NULL OR column >= ?)` 双占位时间下界的统一绑定。SQLite 不支持把
    /// 一个值绑到多个占位符，两个位置各绑同一个 cutoff 毫秒值；cutoff 为 nil
    /// 时两处都绑 NULL（谓词恒真，退化为无下界）。
    static func bindNullableMsCutoff(
        _ cutoffMs: Int64?,
        startingAt index: Int32
    ) -> (OpaquePointer) -> Int32 {
        { stmt in
            let first: Int32 = cutoffMs.map {
                sqlite3_bind_int64(stmt, index, $0)
            } ?? sqlite3_bind_null(stmt, index)
            guard first == SQLITE_OK else { return first }
            return cutoffMs.map {
                sqlite3_bind_int64(stmt, index + 1, $0)
            } ?? sqlite3_bind_null(stmt, index + 1)
        }
    }

    // MARK: - 通用 query

    /// 通用 SELECT helper：
    /// - `bind`：可选，绑定参数（在 prepare 之后、step 之前调用）
    /// - `map`：必选，从每行 statement 抽出结果
    /// - 返回 `[T]`，自动 finalize statement
    ///
    /// 错误处理：
    /// - open 失败 / 句柄被 close → `openFailed`
    /// - prepare 失败 → `prepareFailed`（携带 SQL 文本）
    /// - step 失败（除 SQLITE_ROW / SQLITE_DONE 外）→ `stepFailed`
    func query<T>(
        sql: String,
        bind: ((OpaquePointer) -> Int32)? = nil,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        guard let handle else {
            throw SQLiteConnectionError.openFailed(path: self.path, code: -1, extendedCode: -1, message: "closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            let extCode = sqlite3_extended_errcode(handle)
            throw SQLiteConnectionError.prepareFailed(code: prep, extendedCode: extCode, message: msg, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        // 绑定参数（如果给）
        if let bind {
            let bindCode = bind(stmt)
            guard bindCode == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(handle))
                let extCode = sqlite3_extended_errcode(handle)
                throw SQLiteConnectionError.bindFailed(
                    code: bindCode,
                    extendedCode: extCode,
                    message: msg,
                    sql: sql
                )
            }
        }

        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try map(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(handle))
                let extCode = sqlite3_extended_errcode(handle)
                throw SQLiteConnectionError.stepFailed(code: rc, extendedCode: extCode, message: msg)
            }
        }
        return out
    }
}
