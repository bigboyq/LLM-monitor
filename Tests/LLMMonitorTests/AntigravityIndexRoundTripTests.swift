import XCTest
import SQLite3
@testable import LLM_monitor

/// v9 索引的 round-trip / 旧版本重置已移至 `AntigravityCacheMaintenanceTests`；
/// 本文件保留与索引 I/O 同族的基础设施测试。
final class AntigravityIndexRoundTripTests: AntigravityTestCase {

    func testFileManagerBoxPrivateStoragePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = FileManagerBox()
        try fileManager.createPrivateDirectory(at: root)
        let directoryPermissions = try fileManager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        let file = root.appendingPathComponent("secret.json")
        try fileManager.writePrivate(Data("secret".utf8), to: file)
        let filePermissions = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
    }
}
