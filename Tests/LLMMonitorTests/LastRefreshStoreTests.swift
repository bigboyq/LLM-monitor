import XCTest
@testable import LLM_monitor

/// R1: last-refresh 持久化移出 MainActor 的合并窗口与最新性测试。
final class LastRefreshStoreTests: XCTestCase {

    private func makeTempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-last-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("last-refresh.json")
    }

    private func readJSON(_ url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    /// 并发 enqueue 旧/新快照后磁盘必为最新（合并窗口只保留最后一次有效写）。
    func testCoalescingKeepsLatestSnapshot() async throws {
        let url = try makeTempURL()
        // 极小合并窗口，让测试快速完成
        let store = LastRefreshStore(url: url, coalesceSeconds: 0.02)

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        // 连续 enqueue 三个快照，几乎同时
        await store.enqueue(["a": t1])
        await store.enqueue(["a": t2])
        await store.enqueue(["a": t3, "b": t3])

        // 等合并窗口 + 写盘
        try await Task.sleep(nanoseconds: 120_000_000)

        let disk = readJSON(url)
        XCTAssertEqual(disk["a"], t3, "磁盘必须是最新的快照，而不是旧值")
        XCTAssertEqual(disk["b"], t3)
    }

    /// flushNow 立即落盘，不等合并窗口。
    func testFlushNowWritesImmediately() async throws {
        let url = try makeTempURL()
        let store = LastRefreshStore(url: url, coalesceSeconds: 10)  // 大窗口，确保不会自动 flush
        let t = Date(timeIntervalSince1970: 5_000)
        await store.enqueue(["x": t])
        await store.flushNow()

        XCTAssertEqual(readJSON(url)["x"], t)
    }

    /// 写盘仍走私有文件（0600 权限）。
    func testWriteIsPrivate() async throws {
        let url = try makeTempURL()
        let store = LastRefreshStore(url: url, coalesceSeconds: 0.01)
        await store.enqueue(["a": Date(timeIntervalSince1970: 7_000)])
        await store.flushNow()

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "last-refresh.json 必须是 owner-only")
    }

    /// 旧 generation 的 flush 不应覆盖新值：enqueue 后再 enqueue 新值，旧 flush 失效。
    func testStaleFlushIsNoop() async throws {
        let url = try makeTempURL()
        let store = LastRefreshStore(url: url, coalesceSeconds: 0.05)
        let old = Date(timeIntervalSince1970: 1_111)
        let latest = Date(timeIntervalSince1970: 9_999)
        await store.enqueue(["a": old])
        // 在旧 flush 触发前再 enqueue 新值
        await store.enqueue(["a": latest])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(readJSON(url)["a"], latest, "旧 flush 不得覆盖新快照")
    }
}
