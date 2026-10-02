import XCTest
import SQLite3
@testable import LLM_monitor

/// GLM 扫描器 / DB reader 用例的共享 fixture 基类。
///
/// 原本是 `GlmTests` 内的私有方法，被 scanner、off-peak 与余额日志三组用例
/// 同时引用；拆文件时抽到这里由子类继承，调用点一个字符都不用改
/// （沿用 `EdgeDockTestCase` 的既有约定）。它自己没有 `test*` 方法。
class GlmTestCase: XCTestCase {

    // MARK: - GLM ZCode Local Usage Scanner Tests

    func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    static func todayMidnight(calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date())
    }

    func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    func makeDatabase() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("glm-zcode-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "open failed") }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE model_usage (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, turn_id TEXT,
            started_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'completed',
            model_id TEXT NOT NULL, provider_id TEXT NOT NULL DEFAULT 'builtin:bigmodel-coding-plan',
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0, assistant_message_id TEXT
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY, message_id TEXT, data TEXT
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "create table failed") }
        return path
    }

    func insert(databaseURL path: String, id: String, sessionID: String, turnID: String?, timestamp: Int64, input: Int, output: Int, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, status: String = "completed", model: String = "GLM-5.2", provider: String = "builtin:bigmodel-coding-plan", assistantMessageID: String? = nil) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO model_usage (id, session_id, turn_id, started_at, status, model_id, provider_id, input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens, cache_creation_input_tokens, assistant_message_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionID as NSString).utf8String, -1, nil)
        if let turnID { sqlite3_bind_text(stmt, 3, (turnID as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, timestamp)
        sqlite3_bind_text(stmt, 5, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (provider as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, Int32(input))
        sqlite3_bind_int(stmt, 9, Int32(output))
        sqlite3_bind_int(stmt, 10, Int32(reasoning))
        sqlite3_bind_int(stmt, 11, Int32(cacheRead))
        sqlite3_bind_int(stmt, 12, Int32(cacheWrite))
        if let assistantMessageID { sqlite3_bind_text(stmt, 13, (assistantMessageID as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 13) }
        sqlite3_step(stmt)
    }

    /// 插入一个 `part` 行。`data` 是 JSON 字符串（type='reasoning' / 'text' / 故意坏的 JSON）。
    func insertPart(databaseURL path: String, id: String, messageID: String, jsonData: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO part (id, message_id, data) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (messageID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (jsonData as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }
}
