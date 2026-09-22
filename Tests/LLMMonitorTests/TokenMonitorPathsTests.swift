import XCTest
@testable import LLM_monitor

final class TokenMonitorPathsTests: XCTestCase {
    func testAllDefaultScannerCachesUseCentralizedProviderDirectories() {
        let root = TokenMonitorPaths.root.standardizedFileURL.path
        let paths = [
            AntigravityLocalUsageScanner.defaultCacheDir,
            MinimaxLocalUsageScanner.defaultCacheDir,
            GlmZcodeLocalUsageScanner.defaultCacheDir,
            OpencodeUsageScanner.defaultCacheDir,
            DshLocalUsageScanner.defaultCacheDir
        ].map { $0.standardizedFileURL.path }

        XCTAssertEqual(Set(paths).count, 5)
        for path in paths {
            XCTAssertTrue(path.hasPrefix(root + "/"), "cache escaped centralized root: \(path)")
        }
    }

    func testLegacyIndexMigrationDoesNotOverwriteExistingCentralizedCache() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("token-monitor-migration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let centralized = root.appendingPathComponent("centralized", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: centralized, withIntermediateDirectories: true)

        let source = legacy.appendingPathComponent("index.json")
        let destination = centralized.appendingPathComponent("index.json")
        try Data("legacy".utf8).write(to: source)
        TokenMonitorPaths.migrateLegacyIndexIfNeeded(
            from: legacy,
            to: centralized,
            fileManager: FileManagerBox(fm)
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("legacy".utf8))
        XCTAssertTrue(fm.fileExists(atPath: source.path), "migration must remain recoverable")

        try Data("new".utf8).write(to: destination)
        try Data("legacy-again".utf8).write(to: source)
        TokenMonitorPaths.migrateLegacyIndexIfNeeded(
            from: legacy,
            to: centralized,
            fileManager: FileManagerBox(fm)
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }
}
