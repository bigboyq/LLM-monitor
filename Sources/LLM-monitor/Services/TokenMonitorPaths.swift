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
}
