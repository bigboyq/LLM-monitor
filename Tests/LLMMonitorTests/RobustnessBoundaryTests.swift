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

    // MARK: - R17: 失败不拉长刷新间隔（固定间隔重试）

    /// 连续失败时每个定时周期都照常重试，且下次刷新始终按 baseInterval 排——
    /// 不存在 2^n 退避（旧实现第 1 次失败即翻倍到 120s、封顶 30min，0.3s 内
    /// 只会有 1 次调用）。
    @MainActor
    func testR17RepeatedFailuresKeepFixedInterval() async {
        var calls = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                return .completed(success: false)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            sleep: { _ in try? await Task.sleep(nanoseconds: 1) }
        )
        scheduler.schedule(for: "a")
        // 失败循环持续跑 0.3s（远超旧退避下第 2 次重试所需的 120s）
        try? await Task.sleep(nanoseconds: 300_000_000)
        let earliest = scheduler.earliestNextRefresh
        scheduler.cancelAll()

        XCTAssertGreaterThanOrEqual(
            calls, 10,
            "失败应随每个定时周期重试（旧指数退避下 0.3s 内最多 1 次调用）"
        )
        guard let earliest else {
            XCTFail("失败 provider 也必须有下一次刷新排期")
            return
        }
        let remaining = earliest.timeIntervalSinceNow
        XCTAssertLessThanOrEqual(remaining, 65, "失败后的下次刷新应按 baseInterval(60s) 排，不指数退避")
        XCTAssertGreaterThanOrEqual(remaining, 55, "失败后的下次刷新不应早于 baseInterval")
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
