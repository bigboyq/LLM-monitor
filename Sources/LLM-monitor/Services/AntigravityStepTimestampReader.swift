import Foundation
import SQLite3

/// Reads only the protobuf Timestamp carried by an Antigravity SQLite step.
/// Token usage remains RPC-only; this is a timestamp fallback for RPC events
/// whose newer schema omits `chatStartMetadata.createdAt`.
enum AntigravityStepTimestampReader {
    /// 直读原 .db 路径必须 READONLY：这是 IDE 正在实时写入的活动库，可写连接
    /// 可能触发 WAL recovery / checkpoint 写副作用。与 GLM/Minimax/Opencode
    /// reader 的 `readOnly: url.path == 原路径` 约定一致；只读连接撞上需要
    /// recovery 的 -shm/WAL 时抛 READONLY(8)/CANTOPEN(14) 家族错误，正是
    /// `SQLiteTempCopy` 白名单兜底到 /tmp 副本的场景。SQLiteTempCopy 的 /tmp
    /// 副本路径保持 READWRITE：副本上可能需要完成 WAL recovery。
    ///
    /// 暴露为 internal 是测试接缝：不打开数据库即可断言"原路径只读、副本可写"
    /// 的判定正确（SQLiteConnection 不暴露 open flags，无法事后内省）。
    static func opensReadOnly(dbPath: URL) -> Bool {
        let tempCopyDir = SQLiteTempCopy.appTempDir().standardizedFileURL.path
        return !dbPath.standardizedFileURL.path.hasPrefix(tempCopyDir + "/")
    }

    static func timestamps(
        dbPath: URL,
        stepIndices: Set<Int>
    ) throws -> [Int: Date] {
        guard !stepIndices.isEmpty else { return [:] }

        let connection = try SQLiteConnection(path: dbPath, readOnly: opensReadOnly(dbPath: dbPath))
        let sortedIndices = stepIndices.sorted()
        let placeholders = Array(repeating: "?", count: sortedIndices.count).joined(separator: ",")
        let sql = """
            SELECT idx, metadata
            FROM steps
            WHERE step_type = 15 AND idx IN (\(placeholders))
            """
        let rows = try connection.query(
            sql: sql,
            bind: { statement in
                for (offset, index) in sortedIndices.enumerated() {
                    guard sqlite3_bind_int64(statement, Int32(offset + 1), Int64(index)) == SQLITE_OK else {
                        return SQLITE_ERROR
                    }
                }
                return SQLITE_OK
            },
            map: { statement in
                let index = Int(sqlite3_column_int64(statement, 0))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 1) else {
                    return (index, Optional<Date>.none)
                }
                let length = Int(sqlite3_column_bytes(statement, 1))
                return (index, Self.timestamp(from: Data(bytes: blob, count: length)))
            }
        )

        return Dictionary(uniqueKeysWithValues: rows.compactMap { index, date in
            guard let date else { return nil }
            return (index, date)
        })
    }

    // MARK: - agy 方案 A：LLM step 流式时长（field 1 发起 → field 7 流式完成）

    /// agy 本地会话 `conversations/<session>.db` 的 `steps` 表里，`step_type = 15`
    /// 行的 metadata protobuf 携带两个 Timestamp：field 1 = 该 step 的发起时刻
    /// （与 transcript 行 `created_at` 同值，整秒），field 7 = 流式完成时刻
    /// （纳秒级）。本查询把全部 LLM steps 的 `f7 − f1` 纳秒差按 `idx` 收成映射；
    /// metadata 缺失或两个 Timestamp 任一不可解析的行不出现在结果里。
    ///
    /// 必须经 `SQLiteTempCopy.read` 调用（原路径 READONLY + WAL 竞态兜底由外层
    /// 负责，与 `timestamps(dbPath:stepIndices:)` 同一纪律）。
    static func llmStepStreamDurationNanos(dbPath: URL) throws -> [Int: Int64] {
        let connection = try SQLiteConnection(path: dbPath, readOnly: opensReadOnly(dbPath: dbPath))
        let rows = try connection.query(
            sql: """
                SELECT idx, metadata
                FROM steps
                WHERE step_type = 15
                """,
            map: { statement in
                let index = Int(sqlite3_column_int64(statement, 0))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 1) else {
                    return (index, Optional<Int64>.none)
                }
                let length = Int(sqlite3_column_bytes(statement, 1))
                return (index, Self.streamDurationNanos(from: Data(bytes: blob, count: length)))
            }
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { index, nanos in
            guard let nanos else { return nil }
            return (index, nanos)
        })
    }

    /// Test surface：单条 metadata blob 的双 Timestamp 解析（`f7 − f1` 纳秒差）。
    nonisolated static func streamDurationNanosForTest(from metadata: Data) -> Int64? {
        streamDurationNanos(from: metadata)
    }

    // MARK: - agy TTFT：gen_metadata f1.f11（与 Antigravity 会话库同 schema 同字段）

    /// agy 本地会话 `conversations/<session>.db` 的 `gen_metadata` 表逐行 `data`
    /// protobuf 携带的 `f1.f11` timeToFirstToken（protobuf Duration：f1=seconds、
    /// f2=nanos；<1s 时 proto3 省略 seconds 只剩 nanos）。agy 与 Antigravity 会话
    /// 库同 schema 同字段（`spec/providers/antigravity.md` § TTFT / streaming
    /// 时长字段，`spec/harnesses/agy.md` § 单次调用时长 实测注明；本机 91 库实测
    /// 2012/2012 行连接命中且全部可解出 f11）。
    ///
    /// 连接语义与 `AntigravitySessionDBReader.pair` 一致：`steps.idx ==
    /// gen.f20.last_step_index + 1`（同号冲突先到先得）。返回值以连接命中的
    /// steps.idx 为键——agy transcript 计量行用 `step_index == steps.idx` 查
    /// 方案 A 时长（同一映射键），scanner 用同一映射供给逐调用 TTFT；
    /// 连接不命中 / f11 缺失 / 不可解析 / 负值的行不出现在结果里。
    ///
    /// 必须经 `SQLiteTempCopy.read` 调用（原路径 READONLY + WAL 竞态兜底由外层
    /// 负责，与 `llmStepStreamDurationNanos` 同一纪律）。protobuf 遍历复用
    /// `AntigravitySessionDBReader.protoFields`（同一 L0 解码器，不重复造轮子）。
    static func llmCallTTFTSecondsByStepIndex(dbPath: URL) throws -> [Int: Double] {
        let connection = try SQLiteConnection(path: dbPath, readOnly: opensReadOnly(dbPath: dbPath))
        let rows = try connection.query(
            sql: "SELECT data FROM gen_metadata ORDER BY idx ASC",
            map: { statement -> Data? in
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 0) else {
                    return nil
                }
                let length = Int(sqlite3_column_bytes(statement, 0))
                return Data(bytes: blob, count: length)
            }
        )
        var result: [Int: Double] = [:]
        for data in rows {
            guard let data, !data.isEmpty,
                  let top = AntigravitySessionDBReader.protoFields(in: data),
                  let eventBytes = top.first(where: { $0.fieldNumber == 1 && $0.wireType == 2 })?.bytes,
                  let event = AntigravitySessionDBReader.protoFields(in: eventBytes) else {
                continue
            }
            // f1.f20 repeated string→string map：取 last_step_index（十进制字符串）。
            var lastStepIndex: Int?
            for field in event where field.fieldNumber == 20 && field.wireType == 2 {
                guard let entryBytes = field.bytes,
                      let mapEntry = AntigravitySessionDBReader.protoFields(in: entryBytes) else { continue }
                let key = mapEntry.first(where: { $0.fieldNumber == 1 && $0.wireType == 2 })?.bytes
                let value = mapEntry.first(where: { $0.fieldNumber == 2 && $0.wireType == 2 })?.bytes
                guard let key, String(data: key, encoding: .utf8) == "last_step_index",
                      let value,
                      let parsed = Int(String(data: value, encoding: .utf8) ?? "") else { continue }
                lastStepIndex = parsed
            }
            guard let lastStepIndex else { continue }
            // last_step_index + 1 报告溢出加法：畸形大数值走连接不命中，不 trap。
            let next = lastStepIndex.addingReportingOverflow(1)
            guard !next.overflow, result[next.partialValue] == nil else { continue }
            guard let ttftBytes = event.first(where: { $0.fieldNumber == 11 && $0.wireType == 2 })?.bytes,
                  let seconds = ttftDurationSeconds(from: ttftBytes) else { continue }
            result[next.partialValue] = seconds
        }
        return result
    }

    /// Test surface：单条 f11 Duration blob 的解析（seconds/nanos 形态覆盖）。
    nonisolated static func ttftDurationSecondsForTest(from data: Data) -> Double? {
        ttftDurationSeconds(from: data)
    }

    /// protobuf Duration（field 1 = seconds varint、field 2 = nanos varint）→ 秒。
    /// proto3 默认值省略：<1s 的时长 seconds 缺省只剩 nanos（按 0 秒处理）；
    /// 两个字段都缺省视为上游未提供 → nil；负值（负 int64 的 varint 解码为巨大
    /// 无符号数）或 nanos 越界 → nil。不做范围过滤（有效性域归聚合层）。
    private static func ttftDurationSeconds(from data: Data) -> Double? {
        guard let fields = AntigravitySessionDBReader.protoFields(in: data) else { return nil }
        let secondsRaw = fields.first { $0.fieldNumber == 1 && $0.wireType == 0 }?.varint
        let nanosRaw = fields.first { $0.fieldNumber == 2 && $0.wireType == 0 }?.varint
        guard secondsRaw != nil || nanosRaw != nil else { return nil }
        let seconds = secondsRaw.map(Int64.init(bitPattern:)) ?? 0
        let nanos = nanosRaw.map(Int64.init(bitPattern:)) ?? 0
        guard seconds >= 0, nanos >= 0, nanos <= 999_999_999 else { return nil }
        return Double(seconds) + Double(nanos) / 1_000_000_000
    }

    /// 解析 metadata protobuf 信封里的 field 1（发起）与 field 7（流式完成）两个
    /// length-delim Timestamp 子消息，返回 `f7 − f1` 纳秒差。与 `timestamp(from:)`
    /// 同一套 varint 上界纪律（varint 一律不得越过自己的消息边界）；任一字段
    /// 缺失或 Timestamp 不完整 → nil。只做增量添加，不改变既有解析行为。
    private static func streamDurationNanos(from metadata: Data) -> Int64? {
        var startNanos: Int64?
        var endNanos: Int64?
        var cursor = 0
        while cursor < metadata.count {
            guard let key = readVarint(from: metadata, cursor: &cursor, limit: metadata.count) else { return nil }
            let field = key >> 3
            let wireType = key & 7
            switch wireType {
            case 2:
                // 先比 cursor <= count 再比 length：双保险防止 readVarint 越过
                // 消息边界后 count - cursor 变负、UInt64(负数) 前置条件 trap。
                guard cursor <= metadata.count,
                      let length = readVarint(from: metadata, cursor: &cursor, limit: metadata.count),
                      length <= UInt64(metadata.count - cursor),
                      length <= UInt64(Int.max) else { return nil }
                let end = cursor + Int(length)
                let submessage = metadata.subdata(in: cursor..<end)
                if field == 1 { startNanos = timestampNanos(from: submessage) }
                if field == 7 { endNanos = timestampNanos(from: submessage) }
                cursor = end
            case 0:
                guard readVarint(from: metadata, cursor: &cursor, limit: metadata.count) != nil else { return nil }
            case 1:
                guard cursor <= metadata.count - 8 else { return nil }
                cursor += 8
            case 5:
                guard cursor <= metadata.count - 4 else { return nil }
                cursor += 4
            default:
                return nil
            }
        }
        guard let startNanos, let endNanos else { return nil }
        return endNanos - startNanos
    }

    /// 单个 protobuf Timestamp 子消息（field 1 = seconds varint、field 2 = nanos
    /// varint）→ 绝对纳秒。epoch 合理域与 `timestamp(from:)` 同款（2000–2100）。
    private static func timestampNanos(from data: Data) -> Int64? {
        var cursor = 0
        var seconds: Int64?
        var nanos: Int64 = 0
        while cursor < data.count {
            guard let key = readVarint(from: data, cursor: &cursor, limit: data.count) else { return nil }
            let field = key >> 3
            let wireType = key & 7
            switch wireType {
            case 0:
                guard let value = readVarint(from: data, cursor: &cursor, limit: data.count) else { return nil }
                if field == 1 {
                    seconds = Int64(bitPattern: value)
                } else if field == 2 {
                    guard value <= UInt64(Int64.max) else { return nil }
                    nanos = Int64(value)
                }
            case 1:
                guard cursor <= data.count - 8 else { return nil }
                cursor += 8
            case 2:
                guard cursor <= data.count,
                      let nestedLength = readVarint(from: data, cursor: &cursor, limit: data.count),
                      nestedLength <= UInt64(data.count - cursor),
                      nestedLength <= UInt64(Int.max) else { return nil }
                cursor += Int(nestedLength)
            case 5:
                guard cursor <= data.count - 4 else { return nil }
                cursor += 4
            default:
                return nil
            }
        }
        guard let seconds, (0 ... 999_999_999).contains(nanos) else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        let epoch = date.timeIntervalSince1970
        guard epoch >= 946_684_800, epoch < 4_102_444_800 else { return nil }
        // epoch 守卫已保证 seconds 为正且 < 4_102_444_800，乘积不会溢出 Int64。
        return seconds * 1_000_000_000 + nanos
    }

    /// Test surface for the small protobuf envelope used by `steps.metadata`.
    nonisolated static func timestampForTest(from metadata: Data) -> Date? {
        timestamp(from: metadata)
    }

    private static func timestamp(from metadata: Data) -> Date? {
        var cursor = 0
        guard readVarint(from: metadata, cursor: &cursor, limit: metadata.count) == 10,
              let length = readVarint(from: metadata, cursor: &cursor, limit: metadata.count),
              length <= UInt64(metadata.count - cursor),
              length <= UInt64(Int.max) else {
            return nil
        }

        let end = cursor + Int(length)
        var seconds: Int64?
        var nanos = 0
        while cursor < end {
            guard let key = readVarint(from: metadata, cursor: &cursor, limit: end) else { return nil }
            let field = key >> 3
            let wireType = key & 7

            switch wireType {
            case 0:
                guard let value = readVarint(from: metadata, cursor: &cursor, limit: end) else { return nil }
                if field == 1 {
                    seconds = Int64(bitPattern: value)
                } else if field == 2 {
                    guard value <= UInt64(Int.max) else { return nil }
                    nanos = Int(value)
                }
            case 1:
                guard cursor <= end - 8 else { return nil }
                cursor += 8
            case 2:
                // 先比 cursor <= end 再比 nestedLength：双保险防止 readVarint
                // 越过子消息边界后 end - cursor 变负、UInt64(负数) 前置条件
                // 直接 trap（进程不可恢复崩溃）。
                guard cursor <= end,
                      let nestedLength = readVarint(from: metadata, cursor: &cursor, limit: end),
                      nestedLength <= UInt64(end - cursor),
                      nestedLength <= UInt64(Int.max) else { return nil }
                cursor += Int(nestedLength)
            case 5:
                guard cursor <= end - 4 else { return nil }
                cursor += 4
            default:
                return nil
            }
        }

        guard let seconds, (0 ... 999_999_999).contains(nanos) else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        let epoch = date.timeIntervalSince1970
        guard epoch >= 946_684_800, epoch < 4_102_444_800 else { return nil }
        return date
    }

    /// `limit` 是本条 varint 允许读取的字节上界（不含）：外层信封传
    /// `data.count`，子消息内传子消息边界 `end`。没有上界时，子消息末尾
    /// 带续位的 varint 会吃掉后面的信封字节、把 cursor 推过 `end`——轻则
    /// 越界解析，重则让调用方算出负的剩余长度、`UInt64(负数)` 直接 trap。
    /// 撞上 limit 仍未终结（截断）时返回 nil，此时 cursor 可能已停在 limit。
    private static func readVarint(from data: Data, cursor: inout Int, limit: Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit, shift < 64 {
            let byte = data[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
