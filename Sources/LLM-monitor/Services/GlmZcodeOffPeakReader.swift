import Foundation

/// 读 ZCode `~/.zcode/v2/tasks-index.sqlite` 的 `off_peak_tasks` 表，产出已完成的
/// 闲时任务时间窗口列表。新 sample 优先按 provider 身份分类；窗口保留给旧缓存兼容
/// 回退和闲时任务时间诊断。
///
/// 只取 `status='completed'` 且 `started_at` / `ended_at` 都非空的行（排队中 / 运行中
/// / 失败的闲时任务不产生 model_usage，不需要排除）。直接 read 原 .db；CANTOPEN / BUSY
/// 时由调用方（`SQLiteTempCopy.read`）走 /tmp 副本。
final class GlmZcodeOffPeakReader {
    private let connection: SQLiteConnection

    init(path: URL, readOnly: Bool = false) throws {
        self.connection = try SQLiteConnection(path: path, readOnly: readOnly)
    }

    func close() { connection.close() }

    /// 返回所有已完成闲时任务的 `[started_at, ended_at]` 窗口（按开始时间升序）。
    func windows() throws -> [GlmOffPeakWindow] {
        let sql = """
        SELECT started_at, ended_at
        FROM off_peak_tasks
        WHERE status = 'completed'
          AND started_at IS NOT NULL
          AND ended_at IS NOT NULL
          AND ended_at >= started_at
        ORDER BY started_at ASC
        """
        let rows: [(Int64, Int64)] = try connection.query(sql: sql) { stmt in
            let start = try SQLiteConnection.requiredInt64(stmt, column: 0)
            let end = try SQLiteConnection.requiredInt64(stmt, column: 1)
            return (start, end)
        }
        return rows.compactMap { start, end in
            // epoch ms → Date；防御负数 / 溢出
            guard start > 0, end > 0 else { return nil }
            return GlmOffPeakWindow(
                startedAt: Date(timeIntervalSince1970: Double(start) / 1000),
                endedAt: Date(timeIntervalSince1970: Double(end) / 1000)
            )
        }
    }
}
