import Foundation

/// 两个 SQLite scanner（minimax / antigravity）共享的 versioned index.json 读写逻辑。
/// codex 不使用磁盘 index（LRU actor cache），因此不参与。
enum ScannerIndexIO {
    /// 从 `cacheDir/index.json` 加载版本化索引。
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
        let url = cacheDir.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: url.path) else {
            return empty
        }
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
            logWarn("\(logTag) index.json 解析失败，重置: \(error.localizedDescription)")
            return empty
        }
    }

    /// 把索引写入 `cacheDir/index.json`（0o600 权限）。
    /// 紧凑格式：index 含数万条 recentSamples 时 `.prettyPrinted` 每轮多写数 MB。
    nonisolated static func saveIndex<Index: Encodable>(
        _ index: Index,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        let url = cacheDir.appendingPathComponent("index.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try fileManager.writePrivate(data, to: url)
    }
}
