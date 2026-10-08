import Foundation

/// minimax 模型族常量（wire 名是稳定的小写 family id）。
///
/// 对齐 `AntigravityModelKind` 的 single-source-of-truth 惯例：`video` 的
/// 「日窗口」判定散落在 displayName、周倍率、聚合排除、fetcher 窗口长度、
/// 窗口标签与兜底长度等 6 处，各写一份 `"video"` 字面量迟早改漏。
enum MinimaxModelKind: String, Sendable, CaseIterable {
    case general
    case video
    case image
    case speech
    case music
    case tts

    /// `video` 是日窗口 family（独立小配额池）：周倍率 7、聚合排除、24h 兜底
    /// 长度、「日」标签、fetcher 不填 intervalWindowSeconds 都由这一个判定驱动。
    static func isVideo(_ modelName: String) -> Bool {
        modelName.lowercased() == video.rawValue
    }
}
