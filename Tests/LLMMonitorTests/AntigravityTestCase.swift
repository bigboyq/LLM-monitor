import XCTest
import SQLite3
@testable import LLM_monitor

/// Antigravity 本地用量测试的共享基类：RPC 时代只放两个 fixture；阶段二b 起
/// scanner 数据源是 `.db` 直读，把 `AntigravitySessionDBReaderTests` 的程序化
/// `.db` fixture 构造辅助**下沉**到这里，供 reader 单测与 scanner 扫描单测共用。
class AntigravityTestCase: XCTestCase {

    // MARK: - 共享 fixture
    //
    // 这些成员刻意不是 `private`：多个测试类都继承本基类且分布在不同文件，
    // `private` 在跨文件时不可见。

    func makeEvent(
        timestamp: Date?,
        model: String? = nil,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        duration: Double? = nil
    ) -> AntigravityLocalUsageScanner.UsageEvent {
        AntigravityLocalUsageScanner.UsageEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            durationSeconds: duration
        )
    }

    var testCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - 程序化 .db fixture 构造（自 AntigravitySessionDBReaderTests 下沉）
    //
    // fixture 全部**程序化合成**：手写 protobuf 字节 + 现场建 SQLite 库，绝不拷贝
    // 真实会话 db（含用户对话内容）。字节布局对照
    // `spec/providers/antigravity.md` § Token & model data ARE in `.db` `gen_metadata`
    //（2026-11-08 实测字段表）与 `spec/harnesses/agy.md` § 单次调用时长 方案 A。

    // -- protobuf 字节构造 helpers --

    func pbVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    func pbVarintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        pbVarint(UInt64(field) << 3) + pbVarint(value)
    }

    func pbLenField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        pbVarint(UInt64(field) << 3 | 2) + pbVarint(UInt64(payload.count)) + payload
    }

    func pbStringField(_ field: Int, _ value: String) -> [UInt8] {
        pbLenField(field, Array(value.utf8))
    }

    /// protobuf Timestamp 子消息（field 1 = seconds、field 2 = nanos）。
    func pbTimestamp(seconds: UInt64, nanos: UInt64) -> [UInt8] {
        pbVarintField(1, seconds) + pbVarintField(2, nanos)
    }

    /// f20 map 的 `last_step_index` 条目（连接键：steps.idx == last_step_index + 1）。
    func lsi(_ value: UInt64) -> (key: String, value: String) {
        (key: "last_step_index", value: String(value))
    }

    // -- fixture 描述与构造 --

    /// 所有 gen 行共用的 trajectory UUID（会话 ID）。
    let fixtureTrajectoryID = "2eb1e0a0-1111-4bbb-8ccc-dddddddddddd"
    let fixtureFlashModel = "gemini-3.8-flash-n"
    let fixtureArgonModel = "gemini-4-argon"

    /// gen_metadata.data 的构造选项。
    struct GenRow {
        /// gen_metadata.idx；nil = 按插入序（offset + 1）。显式给值可模拟真实库的
        /// idx 空洞与副调用条目位置。
        var idx: Int? = nil
        /// `f1.f19` 模型名；nil = 不写该字段（后台/副调用条目形态）
        var model: String? = nil
        var displayName: String? = nil
        /// `f1.f4` usage 四桶 + normalized；nil = 无 usage 子消息
        var usage: (
            input: UInt64, cacheRead: UInt64, rawOutput: UInt64, reasoning: UInt64,
            normalized: UInt64?
        )? = nil
        /// `f1.f20` string→string map 条目
        var attributes: [(key: String, value: String)] = []
        /// 直接给原始 data 字节（覆盖以上构造，用于乱数据用例）
        var rawData: [UInt8]? = nil
        /// `f1.f4` usage 子消息存在但为**空消息**（0 字节）——presence 口径用例
        var emptyUsageSubmessage: Bool = false
    }

    struct StepRow {
        /// steps.idx；nil = 按插入序（offset + 1）。显式给值可模拟真实库的 idx 空洞。
        var idx: Int? = nil
        let type: Int
        var start: (seconds: UInt64, nanos: UInt64)? = nil
        var end: (seconds: UInt64, nanos: UInt64)? = nil
        /// metadata 列写 NULL
        var nullMetadata: Bool = false
        /// metadata 写入不可解析字节
        var garbageMetadata: Bool = false
    }

    /// 构造 gen_metadata.data 字节：顶层 f1 事件消息 + f4 trajectory UUID；事件内
    /// f4 usage / f17 usage 副本 + 16-hex 请求 id / f19 模型名 / f20 map / f21 显示名。
    /// f17 副本恒写入，证明 reader 忽略它不影响 f4 权威口径。
    func makeGenData(_ row: GenRow) -> [UInt8] {
        if let rawData = row.rawData { return rawData }
        var event: [UInt8] = []
        if row.emptyUsageSubmessage {
            event += pbLenField(4, [])
        } else if let usage = row.usage {
            var usageMsg: [UInt8] = []
            usageMsg += pbVarintField(2, usage.input)
            usageMsg += pbVarintField(3, usage.rawOutput)
            usageMsg += pbVarintField(5, usage.cacheRead)
            usageMsg += pbVarintField(9, usage.reasoning)
            if let normalized = usage.normalized {
                usageMsg += pbVarintField(10, normalized)
            }
            event += pbLenField(4, usageMsg)
        }
        event += pbLenField(17, pbVarintField(2, 7) + pbStringField(4, "0123456789abcdef"))
        if let model = row.model {
            event += pbStringField(19, model)
        }
        for attribute in row.attributes {
            event += pbLenField(20, pbStringField(1, attribute.key) + pbStringField(2, attribute.value))
        }
        if let displayName = row.displayName {
            event += pbStringField(21, displayName)
        }
        var top: [UInt8] = []
        top += pbLenField(1, event)
        top += pbStringField(4, fixtureTrajectoryID)
        return top
    }

    func makeStepMetadata(_ row: StepRow) -> Data? {
        if row.nullMetadata { return nil }
        if row.garbageMetadata { return Data([0x0A, 0x7F, 0x99]) }
        var metadata: [UInt8] = []
        if let start = row.start {
            metadata += pbLenField(1, pbTimestamp(seconds: start.seconds, nanos: start.nanos))
        }
        if let end = row.end {
            metadata += pbLenField(7, pbTimestamp(seconds: end.seconds, nanos: end.nanos))
        }
        return metadata.isEmpty ? nil : Data(metadata)
    }

    /// 现场合成一个 Antigravity 会话 .db。两个表的 DDL 可各自省略（probe 失败用例）。
    /// `at` 指向已存在的文件时先删除（含 WAL/SHM 周边），支持对同一 session
    /// 重写内容（模拟文件再变化）。
    @discardableResult
    func makeSessionDB(
        gen: [GenRow],
        steps: [StepRow],
        includeGenTable: Bool = true,
        includeStepsTable: Bool = true,
        at dbURL: URL? = nil
    ) throws -> URL {
        let resolvedURL = dbURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-session-db-\(UUID().uuidString).db")
        if dbURL == nil {
            addTeardownBlock { try? FileManager.default.removeItem(at: resolvedURL) }
        } else {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: resolvedURL.path + suffix)
            }
        }

        var ddl: [String] = []
        if includeGenTable {
            ddl.append("CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);")
        }
        if includeStepsTable {
            ddl.append(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, "
                    + "metadata BLOB, step_payload BLOB);"
            )
        }

        try openFixture(dbURL: resolvedURL) { database in
            XCTAssertEqual(sqlite3_exec(database, ddl.joined(separator: "\n"), nil, nil, nil), SQLITE_OK)
            for (offset, row) in gen.enumerated() {
                let data = Data(self.makeGenData(row))
                self.insertRow(
                    database: database,
                    sql: "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?);",
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, Int64(row.idx ?? offset + 1))
                        self.bindBlob(statement, index: 2, data)
                        sqlite3_bind_int64(statement, 3, Int64(data.count))
                    }
                )
            }
            for (offset, row) in steps.enumerated() {
                let metadata = self.makeStepMetadata(row)
                self.insertRow(
                    database: database,
                    sql: "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES (?, ?, ?, ?, ?);",
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, Int64(row.idx ?? offset + 1))
                        sqlite3_bind_int64(statement, 2, Int64(row.type))
                        sqlite3_bind_int64(statement, 3, 2)
                        self.bindBlob(statement, index: 4, metadata)
                        // step_payload 保持未绑定（NULL）
                    }
                )
            }
        }
        return resolvedURL
    }

    private func openFixture(dbURL: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                dbURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
            ),
            SQLITE_OK
        )
        guard let database else {
            XCTFail("failed to create SQLite fixture")
            return
        }
        defer { sqlite3_close(database) }
        try body(database)
    }

    private func insertRow(
        database: OpaquePointer,
        sql: String,
        bind: (OpaquePointer) -> Void
    ) {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else {
            XCTFail("failed to prepare fixture insert")
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func bindBlob(_ statement: OpaquePointer, index: Int32, _ blob: Data?) {
        let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
        if let blob {
            blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), transient)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
