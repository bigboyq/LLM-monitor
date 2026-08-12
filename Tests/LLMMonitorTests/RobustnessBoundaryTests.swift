import XCTest
@testable import LLM_monitor

/// R11/R17/R18 等稳健性边界测试。
final class RobustnessBoundaryTests: XCTestCase {

    // MARK: - R11: AnyJSON 嵌套深度限制

    private func nestedJSON(depth: Int) -> String {
        // depth 层 object 包裹一个标量
        var json = "42"
        for _ in 0..<depth {
            json = "{\"a\":\(json)}"
        }
        return json
    }

    func testR11AnyJSONAcceptsDepth32() throws {
        // codingPath.count 到 32 仍可解码（不抛错即通过）。
        let json = nestedJSON(depth: 32)
        let value = try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))
        if case .object = value {} else { XCTFail("应为 object") }
    }

    func testR11AnyJSONRejectsDepth33() throws {
        let json = nestedJSON(depth: 33)
        XCTAssertThrowsError(try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))) { error in
            guard error is DecodingError else {
                XCTFail("应为 DecodingError，got \(error)")
                return
            }
        }
    }

    /// 宽但不深的 JSON 不受影响。
    func testR11AnyJSONWideButShallowIsUnaffected() throws {
        let pairs = (0..<1000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        let json = "{\(pairs)}"
        let value = try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))
        if case .object(let dict) = value {
            XCTAssertEqual(dict.count, 1000)
        } else {
            XCTFail("应为 object")
        }
    }

    // MARK: - R17: backoff 日志显示真实失败次数

    @MainActor
    func testR17NextDelayCapsExponentAtFiveButKeepsActualCount() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        // 第 1、5、10 次失败的 delay 都不应崩溃；指数封顶 5。
        // 第 1 次：60 * 2^1 = 120；第 5 次：60 * 2^5 = 1920；第 10 次：仍 60*2^5（封顶）。
        scheduler.recordFailure("a")  // 1
        let d1 = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        XCTAssertGreaterThan(d1, 0)
        for _ in 2...5 { scheduler.recordFailure("a") }
        let d5 = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        for _ in 6...10 { scheduler.recordFailure("a") }
        let d10 = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        // 第 5 次和第 10 次都封顶 30 分钟（±10% jitter），不应继续翻倍。
        XCTAssertLessThanOrEqual(d5, 30 * 60 * 1.1)
        XCTAssertLessThanOrEqual(d10, 30 * 60 * 1.1)
    }

    // MARK: - R14: Codex auth.json 有界读取

    private func makeAuthFile(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try Data(repeating: 0x61, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testR14ReadBoundedAcceptsSmallFile() throws {
        let url = try makeAuthFile(100)
        let data = try CodexFetcher.readBounded(url, maxBytes: CodexFetcher.maxAuthFileBytes)
        XCTAssertEqual(data.count, 100)
    }

    func testR14ReadBoundedAcceptsExactlyOneMiB() throws {
        let url = try makeAuthFile(CodexFetcher.maxAuthFileBytes)
        let data = try CodexFetcher.readBounded(url, maxBytes: CodexFetcher.maxAuthFileBytes)
        XCTAssertEqual(data.count, CodexFetcher.maxAuthFileBytes)
    }

    func testR14ReadBoundedRejectsOneMiBPlusOne() throws {
        let url = try makeAuthFile(CodexFetcher.maxAuthFileBytes + 1)
        XCTAssertThrowsError(try CodexFetcher.readBounded(url, maxBytes: CodexFetcher.maxAuthFileBytes)) { error in
            guard error is CodexFetcher.CodexAuthFileTooLargeError else {
                XCTFail("应为 CodexAuthFileTooLargeError，got \(error)")
                return
            }
        }
    }

    /// 合法 symlink 仍可读取（本地威胁模型不拒绝 symlink），但内容受大小限制。
    func testR14ReadBoundedFollowsLegitSymlink() throws {
        let target = try makeAuthFile(50)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-link-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        let data = try CodexFetcher.readBounded(link, maxBytes: CodexFetcher.maxAuthFileBytes)
        XCTAssertEqual(data.count, 50)
    }
}
