import XCTest
import Foundation
@testable import LLM_monitor

/// 节假日**远程**取数分支（`HolidayCalendarService.fetch` 的 `.remoteURL`）测试：
/// HTTP 成功解析 → 应用新表 + 写缓存 + 触发宿主回调；非快照格式 / HTTP 错误 →
/// 失败文案可读且既有数据（`shared` 表与缓存文件）原样保留。
///
/// **不依赖网络**：`init(session:)` 注入 URLProtocol 桩，同步/异步都由桩应答。
/// 每个触达 global `HolidayCalendar.shared` 的用例在 `tearDown` 复位原表。
final class HolidaySourceRemoteFetchTests: XCTestCase {

    /// 可注入响应体的 URLProtocol 桩（状态码 + body），供远程取数分支断言。
    private final class HolidayStubURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var _statusCode = 200
        private static var _body = Data("{}".utf8)
        private static var _errorCode: URLError.Code?
        private static var _requests: [URL] = []

        static var requests: [URL] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        /// 正常应答（状态码 + body）；`errorCode` 非 nil 时改为抛 URLError。
        static func reset(statusCode: Int = 200, body: Data = Data("{}".utf8), errorCode: URLError.Code? = nil) {
            lock.lock(); defer { lock.unlock() }
            _statusCode = statusCode
            _body = body
            _errorCode = errorCode
            _requests = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self._requests.append(request.url!)
            let statusCode = Self._statusCode
            let body = Self._body
            let errorCode = Self._errorCode
            Self.lock.unlock()

            if let errorCode {
                client?.urlProtocol(self, didFailWithError: URLError(errorCode))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private let sourceURL = "https://holidays.example.com/days.json"
    private var originalSharedCalendar: HolidayCalendar!

    override func setUp() {
        super.setUp()
        originalSharedCalendar = HolidayCalendar.shared
        HolidayStubURLProtocol.reset()
    }

    override func tearDown() {
        HolidayCalendar.applyResolved(originalSharedCalendar)
        super.tearDown()
    }

    private var beijing: Calendar { PeakWindow.beijingCalendar }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HolidayStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func beijingDate(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").map { Int($0)! }
        return beijing.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        ))!
    }

    private func snapshotJSON(holidays: [String]) -> Data {
        let document = HolidayCalendar.CacheDocument(
            source: "upstream-snapshot",
            fetchedAt: "2026-01-01",
            holidays: holidays
        )
        // 编码失败只可能是测试自身写错了 fixture，直接崩溃暴露。
        return try! JSONEncoder().encode(document)
    }

    // MARK: - 远程成功

    @MainActor
    func testRemoteSnapshotAppliesWritesCacheAndFiresCallback() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let year = beijing.component(.year, from: Date())
        let holidays = ["\(year)-10-01", "\(year)-10-02", "\(year)-10-03"]
        HolidayStubURLProtocol.reset(body: snapshotJSON(holidays: holidays))

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        var appliedCount = 0
        let service = HolidayCalendarService(
            cacheURL: cacheURL,
            session: makeSession(),
            onCalendarApplied: { appliedCount += 1 }
        )

        let message = await service.refreshNow(source: sourceURL)
        XCTAssertTrue(message.hasPrefix("更新成功"), "实际文案：\(message)")
        XCTAssertEqual(
            HolidayStubURLProtocol.requests.map(\.absoluteString),
            [sourceURL],
            "只应向配置的源发一次 GET"
        )

        // shared 被替换（tearDown 复位）。
        XCTAssertTrue(HolidayCalendar.shared.isHoliday(beijingDate("\(year)-10-02")))
        XCTAssertEqual(HolidayCalendar.shared.source, sourceURL)
        XCTAssertTrue(service.resolvedFromCache)
        XCTAssertEqual(appliedCount, 1, "应用新表后必须触发一次宿主回调（UI 刷新）")

        // 缓存按快照 schema 落盘：source = 配置源、fetchedAt = 本次取数日。
        let cached = try JSONDecoder().decode(
            HolidayCalendar.CacheDocument.self,
            from: Data(contentsOf: cacheURL)
        )
        XCTAssertEqual(cached.source, sourceURL)
        XCTAssertEqual(cached.fetchedAt, HolidayCalendar.beijingDateString())
        XCTAssertEqual(cached.holidays, holidays)
    }

    // MARK: - 远程失败：格式不对 / HTTP 错误 / 超时

    /// 远程返回非快照格式（ICS）→ 失败文案可读，既有表与缓存文件都不动。
    @MainActor
    func testRemoteNonSnapshotPayloadFailsWithoutReplacingTableOrCache() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let year = beijing.component(.year, from: Date())
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:国庆节\nEND:VEVENT\nEND:VCALENDAR"
        HolidayStubURLProtocol.reset(body: Data(ics.utf8))

        // 预置缓存：失败时必须原样保留（不被空表 / 损坏内容覆盖）。
        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        let sentinel = snapshotJSON(holidays: ["\(year)-01-01"])
        try sentinel.write(to: cacheURL)

        var appliedCount = 0
        let service = HolidayCalendarService(
            cacheURL: cacheURL,
            session: makeSession(),
            onCalendarApplied: { appliedCount += 1 }
        )

        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: sourceURL)
        XCTAssertTrue(message.contains("仅支持本项目 JSON 快照格式"), "实际文案：\(message)")
        XCTAssertEqual(appliedCount, 0, "失败不得触发应用回调")
        XCTAssertEqual(HolidayCalendar.shared, before, "失败不清空既有数据")
        XCTAssertEqual(
            try Data(contentsOf: cacheURL),
            sentinel,
            "失败不得改写既有缓存"
        )
        XCTAssertFalse(service.resolvedFromCache)
    }

    /// HTTP 5xx → 失败文案带状态码可读，既有数据保留。
    @MainActor
    func testRemoteServerErrorFailsWithReadableReason() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let year = beijing.component(.year, from: Date())
        HolidayStubURLProtocol.reset(statusCode: 503, body: Data("upstream down".utf8))

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        let sentinel = snapshotJSON(holidays: ["\(year)-01-01"])
        try sentinel.write(to: cacheURL)

        let service = HolidayCalendarService(cacheURL: cacheURL, session: makeSession())
        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: sourceURL)
        XCTAssertTrue(message.contains("网络请求失败"), "实际文案：\(message)")
        XCTAssertTrue(message.contains("503"), "文案应带 HTTP 状态码：\(message)")
        XCTAssertEqual(HolidayCalendar.shared, before)
        XCTAssertEqual(try Data(contentsOf: cacheURL), sentinel, "失败不得改写既有缓存")
    }

    /// 网络超时 → 文案映射为中文「请求超时」，不清数据。
    @MainActor
    func testRemoteTimeoutFailsWithMappedReason() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        HolidayStubURLProtocol.reset(errorCode: .timedOut)

        let cacheURL = dir.appendingPathComponent(HolidayCalendarService.cacheFileName)
        let service = HolidayCalendarService(cacheURL: cacheURL, session: makeSession())
        let before = HolidayCalendar.shared
        let message = await service.refreshNow(source: sourceURL)
        XCTAssertTrue(message.contains("网络请求失败"), "实际文案：\(message)")
        XCTAssertTrue(message.contains("超时"), "超时文案应可读：\(message)")
        XCTAssertFalse(message.contains("-1001"), "不暴露 Foundation 数字错误码：\(message)")
        XCTAssertEqual(HolidayCalendar.shared, before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "失败且此前无缓存时不应新建缓存文件"
        )
    }
}
