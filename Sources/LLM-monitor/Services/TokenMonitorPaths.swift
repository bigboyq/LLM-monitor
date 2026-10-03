import Foundation

/// Shared durable cache locations for all local-usage scanners.
///
/// Each provider owns one file directly under the shared directory. The
/// explicit provider suffix keeps the files independent without another
/// directory level.
enum TokenMonitorProvider: String, CaseIterable, Sendable {
    case antigravity
    case minimax
    case glmZcode = "glm-zcode"
    case opencode
    case dsh
    case agy
}

enum TokenMonitorPaths {
    static let root: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("LLM-monitor", isDirectory: true)
            .appendingPathComponent("token-monitor", isDirectory: true)
    }()

    static func cacheFile(for provider: TokenMonitorProvider) -> URL {
        root.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }

    /// 根迁移（b24f6f9）之前 Antigravity scanner 的旧缓存目录：
    /// `~/.gemini/antigravity/.token-monitor`。index.json 已随迁移搬进新根，
    /// 但旧版 v3 写的 `rpc-cache/v1/<session>/` per-session 明细从未迁移，
    /// 升级用户的这份残留仍由 Antigravity 扫描启动时的清理逻辑负责删除。
    static let legacyAntigravityCacheDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent(".token-monitor", isDirectory: true)
    }()
}
