import Foundation

/// Local usage scanners shared versioned JSON cache read/write logic.
enum ScannerIndexIO {
    /// 从 cache location 加载版本化索引。生产环境传入 `provider.json`；测试
    /// 仍可传入临时目录，兼容原有的 `directory/index.json` 约定。
    /// - `currentVersion`：当前期望版本号
    /// - `migrate`：可选迁移闭包，旧版本 → 迁移后版本。返回 nil 表示不支持迁移，走 reset。
    /// - 文件不存在 / 版本不匹配(且无迁移路径) / JSON 解析失败 → 返回 `empty`
    nonisolated static func loadIndex<Index: Codable>(
        cacheDir: URL,
        fileManager: FileManagerBox,
        currentVersion: Int,
        empty: Index,
        version: (Index) -> Int,
        migrate: ((inout Index) -> Bool)? = nil,
        logTag: String
    ) throws -> Index {
        let url = indexURL(for: cacheDir)
        guard fileManager.fileExists(atPath: url.path) else {
            return empty
        }
        // 量级评估：索引内容由硬上限约束（dsh 的 recentSamples 上限 65,536 条、
        // antigravity 的 samples 只保留 8 天窗口），实测各 provider 的 index.json
        // 在数百 KB 量级，理论上限（dsh 全量 samples）约十几 MB。JSONDecoder 需要
        // 完整文档，此量级保留一次性读入，不做流式拆解。
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var idx = try decoder.decode(Index.self, from: data)
            let v = version(idx)
            if v == currentVersion {
                return idx
            }
            if let migrate = migrate, migrate(&idx) {
                logInfo("\(logTag) 索引从 v\(v) 迁移到 v\(currentVersion)")
                return idx
            }
            logInfo("\(logTag) 索引版本过旧 (\(v) != \(currentVersion))，重置索引全量重建")
            return empty
        } catch {
            logWarn("\(logTag) cache JSON 解析失败，重置: \(error.localizedDescription)")
            return empty
        }
    }

    /// 把索引写入 cache location（0o600 权限）。
    /// 紧凑格式：index 含数万条 recentSamples 时 `.prettyPrinted` 每轮多写数 MB。
    nonisolated static func saveIndex<Index: Encodable>(
        _ index: Index,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        let url = indexURL(for: cacheDir)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try fileManager.writePrivate(data, to: url)
    }

    /// 生产缓存是单个 `provider.json` 文件；保留目录输入兼容测试。
    nonisolated static func indexURL(for cacheLocation: URL) -> URL {
        cacheLocation.lastPathComponent.hasSuffix(".json")
            ? cacheLocation
            : cacheLocation.appendingPathComponent("index.json")
    }

    nonisolated static func ensureCacheDirectory(
        for cacheLocation: URL,
        fileManager: FileManagerBox
    ) throws {
        try fileManager.createPrivateDirectory(at: directoryURL(for: cacheLocation))
    }

    nonisolated static func directoryURL(for cacheLocation: URL) -> URL {
        cacheLocation.lastPathComponent.hasSuffix(".json")
            ? cacheLocation.deletingLastPathComponent()
            : cacheLocation
    }
}
