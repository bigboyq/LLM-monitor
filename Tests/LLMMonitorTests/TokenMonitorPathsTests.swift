import XCTest
@testable import LLM_monitor

final class TokenMonitorPathsTests: XCTestCase {
    func testAllDefaultScannerCachesUseCentralizedProviderFiles() {
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
            XCTAssertTrue(path.hasSuffix(".json"), "cache is not a provider JSON file: \(path)")
            XCTAssertFalse(path.dropFirst(root.count + 1).contains("/"), "cache has an unexpected subdirectory: \(path)")
        }
    }

    func testProviderFileNamesAreStable() {
        XCTAssertEqual(TokenMonitorPaths.cacheFile(for: .antigravity).lastPathComponent, "antigravity.json")
        XCTAssertEqual(TokenMonitorPaths.cacheFile(for: .minimax).lastPathComponent, "minimax.json")
        XCTAssertEqual(TokenMonitorPaths.cacheFile(for: .glmZcode).lastPathComponent, "glm-zcode.json")
        XCTAssertEqual(TokenMonitorPaths.cacheFile(for: .opencode).lastPathComponent, "opencode.json")
        XCTAssertEqual(TokenMonitorPaths.cacheFile(for: .dsh).lastPathComponent, "dsh.json")
    }
}
