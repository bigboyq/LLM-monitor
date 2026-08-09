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

/// 通用 SQLite3 connection（取代 AntigravityDBReader / MinimaxDBReader 里重复的
/// init / close / open flag / busy_timeout / extended_result_codes / query 模板）
///
/// 线程模型：单 instance 单线程使用。
///
/// open flags 默认 SQLITE_OPEN_READWRITE（**不是** READONLY）：
/// 对 /tmp/ 副本的 dirty WAL 状态，SQLite 必须能写回 WAL recovery，否则
/// prepare 阶段会返回 SQLITE_CANTOPEN(14)。READONLY 在 dirty WAL 上必然 CANTOPEN。
///
/// busy_timeout(300) 等 IDE 释放短写锁。
/// extended_result_codes(1) 拿 SQLITE_CANTOPEN_* 子类型诊断。
final class SQLiteConnection {
    private var handle: OpaquePointer?
    let path: String

    init(path: URL, readOnly: Bool = false) throws {
        self.path = path.path
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let code = sqlite3_open_v2(self.path, &db, flags, nil)
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
