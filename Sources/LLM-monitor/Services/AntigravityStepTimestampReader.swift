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
