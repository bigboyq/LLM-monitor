import XCTest
import Foundation
@testable import LLM_monitor

/// 请求由测试显式完成，避免用网络延迟猜测源切换时序。
private final class ControlledHolidayProtocol: URLProtocol {
    private final class Requests: @unchecked Sendable {
        let lock = NSLock()
        var pending: [String: ControlledHolidayProtocol] = [:]
    }
    private static let requests = Requests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.lock.lock()
        Self.requests.pending[request.url!.absoluteString] = self
        Self.requests.lock.unlock()
    }
    override func stopLoading() {}

    static func contains(_ source: String) -> Bool {
        requests.lock.lock(); defer { requests.lock.unlock() }
        return requests.pending[source] != nil
    }
    static func finish(_ source: String) {
        requests.lock.lock()
        let request = requests.pending.removeValue(forKey: source)
        requests.lock.unlock()
        guard let request else { return }
        let body = Data(#"{"source":"fixture","fetchedAt":"2026-11-10","holidays":["2026-11-11"]}"#.utf8)
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(
            url: request.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: body)
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

final class HolidaySourceLifecycleTests: XCTestCase {
    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "源切换状态未在期限内到达")
    }

    @MainActor
    func testBlankManualDraftDoesNotSuppressCommittedSourceChange() async throws {
        let original = HolidayCalendar.shared
        defer { HolidayCalendar.applyResolved(original) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var applied = 0
        let service = HolidayCalendarService(cacheURL: cache, onCalendarApplied: { applied += 1 })
        service.adoptSource("custom")
        HolidayCalendar.applyResolved(.make(holidays: ["2026-11-11"], source: "custom", fetchedAt: "2026-11-10"))
        _ = await service.refreshNow(source: "")
        XCTAssertEqual(HolidayCalendar.shared, HolidayCalendar.loadBundled())
        XCTAssertEqual(applied, 1)
        service.handleConfigChange(source: "")
        try await waitFor { applied == 2 }
        XCTAssertEqual(HolidayCalendar.shared, HolidayCalendar.loadBundled())
        XCTAssertFalse(service.resolvedFromCache)
    }

    @MainActor
    func testManualOldSourceCannotOverwriteBundledSourceOrCache() async throws {
        let original = HolidayCalendar.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { HolidayCalendar.applyResolved(original); try? FileManager.default.removeItem(at: dir) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledHolidayProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = dir.appendingPathComponent("cache.json")
        let sentinel = Data("unchanged".utf8)
        try sentinel.write(to: cache)
        var applied = 0
        let service = HolidayCalendarService(cacheURL: cache, session: session, onCalendarApplied: { applied += 1 })
        let source = "https://holidays.invalid/\(UUID().uuidString)"
        service.adoptSource(source)
        let manual = Task { await service.refreshNow(source: source) }
        try await waitFor { ControlledHolidayProtocol.contains(source) }
        service.handleConfigChange(source: "")
        try await waitFor { applied == 1 }
        ControlledHolidayProtocol.finish(source)
        let message = await manual.value
        XCTAssertTrue(message.contains("已忽略"))
        XCTAssertEqual(HolidayCalendar.shared, HolidayCalendar.loadBundled())
        XCTAssertEqual(try Data(contentsOf: cache), sentinel)
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshMessage)
    }

    @MainActor
    func testNewSourceStartsWhileManualOldSourceIsPendingAndKeepsItsRefreshState() async throws {
        let original = HolidayCalendar.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { HolidayCalendar.applyResolved(original); try? FileManager.default.removeItem(at: dir) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledHolidayProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = dir.appendingPathComponent("cache.json")
        let service = HolidayCalendarService(cacheURL: cache, session: session)
        let old = "https://holidays.invalid/\(UUID().uuidString)"
        let new = "https://holidays.invalid/\(UUID().uuidString)"
        service.adoptSource(old)
        let manual = Task { await service.refreshNow(source: old) }
        try await waitFor { ControlledHolidayProtocol.contains(old) }
        service.handleConfigChange(source: new)
        try await waitFor { ControlledHolidayProtocol.contains(new) }
        ControlledHolidayProtocol.finish(old)
        _ = await manual.value
        XCTAssertTrue(service.isRefreshing, "旧请求结束不能关闭新源的转圈")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        ControlledHolidayProtocol.finish(new)
        try await waitFor { !service.isRefreshing }
        XCTAssertEqual(HolidayCalendar.shared.source, new)
        let document = try JSONDecoder().decode(HolidayCalendar.CacheDocument.self, from: Data(contentsOf: cache))
        XCTAssertEqual(document.source, new)
        XCTAssertTrue(service.lastRefreshMessage?.hasPrefix("更新成功") == true)
    }
}
