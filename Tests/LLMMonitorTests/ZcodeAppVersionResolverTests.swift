import XCTest
@testable import LLM_monitor

final class ZcodeAppVersionResolverTests: XCTestCase {

    private func writeTempPlist(version: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-info-\(UUID().uuidString).plist")
        var dict: [String: Any] = ["CFBundleIdentifier": "dev.zcode.app"]
        if let version {
            dict["CFBundleShortVersionString"] = version
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    override func tearDown() {
        ZcodeAppVersionResolver.invalidateCache()
        super.tearDown()
    }

    // MARK: - resolveAppVersion（可注入 plist 路径的纯解析）

    func testResolveReadsShortVersionFromPlist() throws {
        let plistURL = try writeTempPlist(version: "9.9.9")
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let version = ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: plistURL, fallback: "3.17.1")
        XCTAssertEqual(version, "9.9.9")
    }

    func testResolveTrimsWhitespaceVersion() throws {
        let plistURL = try writeTempPlist(version: "  4.2.0  ")
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let version = ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: plistURL, fallback: "3.17.1")
        XCTAssertEqual(version, "4.2.0")
    }

    func testResolveFallsBackWhenPlistMissing() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-zcode-\(UUID().uuidString).plist")
        let version = ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: missingURL, fallback: "3.17.1")
        XCTAssertEqual(version, "3.17.1")
    }

    func testResolveFallsBackOnNilURL() {
        let version = ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: nil, fallback: "3.17.1")
        XCTAssertEqual(version, "3.17.1")
    }

    func testResolveFallsBackWhenVersionEmptyOrMissing() throws {
        let emptyPlist = try writeTempPlist(version: "")
        defer { try? FileManager.default.removeItem(at: emptyPlist) }
        XCTAssertEqual(
            ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: emptyPlist, fallback: "3.17.1"),
            "3.17.1",
            "CFBundleShortVersionString 为空字符串时必须回退，不得上报空版本"
        )

        let missingKeyPlist = try writeTempPlist(version: nil)
        defer { try? FileManager.default.removeItem(at: missingKeyPlist) }
        XCTAssertEqual(
            ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: missingKeyPlist, fallback: "3.17.1"),
            "3.17.1",
            "缺 CFBundleShortVersionString 键时必须回退"
        )
    }

    func testResolveFallsBackOnMalformedPlist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-zcode-\(UUID().uuidString).plist")
        try Data("not a plist at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let version = ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: url, fallback: "3.17.1")
        XCTAssertEqual(version, "3.17.1")
    }

    func testResolveFallsBackOnDirectoryURL() {
        let dirURL = FileManager.default.temporaryDirectory
        XCTAssertEqual(ZcodeAppVersionResolver.resolveAppVersion(infoPlistURL: dirURL, fallback: "3.17.1"), "3.17.1")
    }

    // MARK: - 缓存与显式刷新

    func testRefreshCachesResultAndCurrentAppVersionReadsCache() throws {
        let plistURL = try writeTempPlist(version: "8.8.8")
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let refreshed = ZcodeAppVersionResolver.refreshCachedAppVersion(infoPlistURL: plistURL, fallback: "3.17.1")
        XCTAssertEqual(refreshed, "8.8.8")
        XCTAssertEqual(ZcodeAppVersionResolver.currentAppVersion, "8.8.8", "缓存生效：currentAppVersion 直接返回上次解析结果")

        // invalidate 后重新解析：解析路径由缓存移除触发
        ZcodeAppVersionResolver.invalidateCache()
        let refreshedAgain = ZcodeAppVersionResolver.refreshCachedAppVersion(infoPlistURL: plistURL, fallback: "3.17.1")
        XCTAssertEqual(refreshedAgain, "8.8.8")
    }

    func testRefreshWithUnknownBundleIdentifierFallsBack() {
        let version = ZcodeAppVersionResolver.refreshCachedAppVersion(
            bundleIdentifier: "com.example.nonexistent.zcode.\(UUID().uuidString)",
            fallback: "3.17.1"
        )
        XCTAssertEqual(version, "3.17.1", "测试宿主机没有该 app，定位失败必须回退而非 throw")
    }

    func testRealPathNeverThrowsOnTestHost() {
        // 真实解析路径（宿主机可能未装 ZCode.app）：任何异常都必须安全回退到默认版本
        XCTAssertNoThrow(ZcodeAppVersionResolver.invalidateCache())
        let version = ZcodeAppVersionResolver.currentAppVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version == GlmZcodeAPIClient.defaultAppVersion || !version.isEmpty)
    }
}
