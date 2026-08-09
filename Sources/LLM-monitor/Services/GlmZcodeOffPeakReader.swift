import Foundation
import SQLite3

/// 一个已完成的闲时任务（off-peak task）的运行时间窗口。
///
/// ZCode 闲时任务是系统赠送的、不消耗 Coding Plan 积分的后台任务，需提前排队。
/// 它的 `model_usage` 行写在同一张表（同 session_id），但 `provider_id` 是独立的
/// `offpeak-idle-plan`（非 `builtin:bigmodel-coding-plan`）。落在这个
/// `[started_at, ended_at]` 时间窗口内的调用不扣积分。额度窗口（5h/week）统计时需要
/// 把这部分 sample 排除，避免高估积分消耗；本地 token 柱图仍保留（真实 token 消耗）。
struct GlmOffPeakWindow: Equatable, Codable, Sendable {
    /// 闲时任务开始时间（off_peak_tasks.started_at，epoch ms → Date）
    let startedAt: Date
    /// 闲时任务结束时间（off_peak_tasks.ended_at，epoch ms → Date）
    let endedAt: Date

    /// sample.completedAt 是否落在本闲时任务窗口内（闭区间，容差 2 秒）。
    /// off_peak.ended_at 与最后一轮 model_usage.completed_at 实测差 ~1 秒，闭区间 +
    /// 小容差确保边界 round 不会被误判。
    func contains(_ date: Date, tolerance: TimeInterval = 2) -> Bool {
        date >= startedAt.addingTimeInterval(-tolerance)
            && date <= endedAt.addingTimeInterval(tolerance)
    }
}

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
