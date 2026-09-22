import Foundation

/// Shared durable cache locations for all local-usage scanners.
///
/// Provider subdirectories are intentional: every scanner historically used an
/// `index.json`, so putting them directly in one directory would make the
/// caches overwrite one another.
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

    static func cacheDirectory(for provider: TokenMonitorProvider) -> URL {
        root.appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    /// Copy an old provider cache into the centralized location once. The old
    /// directory is deliberately left untouched so a failed upgrade remains
    /// recoverable and older app versions can still be launched.
    static func migrateLegacyIndexIfNeeded(
        from legacyDirectory: URL,
        to centralizedDirectory: URL,
        fileManager: FileManagerBox
    ) {
        do {
            try fileManager.createPrivateDirectory(at: centralizedDirectory)
            let source = legacyDirectory.appendingPathComponent("index.json")
            let destination = centralizedDirectory.appendingPathComponent("index.json")
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else {
                return
            }
            try fileManager.copyItem(at: source, to: destination)
            logInfo("[token-monitor] 已迁移缓存 \(source.path) → \(destination.path)")
        } catch {
            // A cache is disposable. Do not prevent the scanner from rebuilding
            // it when migration encounters a permission or stale-file error.
            logWarn("[token-monitor] 缓存迁移失败，将重建 \(centralizedDirectory.path): \(error.localizedDescription)")
        }
    }
}
