import XCTest
@testable import LLM_monitor

/// 拦截 URLSession 请求的 URLProtocol 桩，记录请求并返回 200。
private final class RecordingURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []

    static func reset() {
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class BarkNotifierTests: XCTestCase {
    private final class StubConfigProvider: BarkConfigProviding {
        var bark: BarkConfig?
        init(_ bark: BarkConfig?) { self.bark = bark }
    }

    private let allBarkChannels = QuotaNotifyChannels(
        intervalRestored: .barkAndSystem,
        intervalExhausted: .barkAndSystem,
        weeklyRestored: .barkAndSystem,
        weeklyExhausted: .barkAndSystem
    )
    private let noneBarkChannels = QuotaNotifyChannels(
        intervalRestored: .system,
        intervalExhausted: .system,
        weeklyRestored: .system,
        weeklyExhausted: .system
    )

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    private var stubbedSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func event(_ kind: QuotaNotificationKind) -> QuotaEvent {
        QuotaEvent(
            modelName: "general",
            displayName: "general",
            kind: kind,
            previousPercent: 10,
            currentPercent: kind == .intervalRestored || kind == .weeklyRestored ? 100 : 0
        )
    }

    func testBuildURLPercentEncodesPathSegmentsAndAppendsQuery() throws {
        let url = try XCTUnwrap(BarkQuotaNotifier.buildURL(
            config: BarkConfig(
                enabled: true,
                serverURL: "https://api.day.app",
                deviceKey: "abc123",
                sound: "minuet",
                group: "我的额度"
            ),
            providerName: "GLM Coding Plan",
            body: "短周期 10% → 100%，周额度 40% → 90%",
            notificationID: "llmmonitor-glm-general-intervalRestored"
        ))

        XCTAssertEqual(url.host, "api.day.app")
        // 中文与箭头必须被 percent-encode，不能裸露在 URL 里。
        XCTAssertFalse(url.absoluteString.contains("→"))
        XCTAssertTrue(url.absoluteString.contains("%E7%9F%AD"))
        XCTAssertTrue(url.absoluteString.contains("sound=minuet"))
        XCTAssertTrue(url.absoluteString.contains("group="))
        XCTAssertTrue(url.absoluteString.contains("id=llmmonitor-glm-general-intervalRestored"))
    }

    func testBuildURLOmitsOptionalParamsWhenUnset() throws {
        let url = try XCTUnwrap(BarkQuotaNotifier.buildURL(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k",
                sound: nil, group: "  "
            ),
            providerName: "P",
            body: "b"
        ))
        // group / sound 留空时不携带对应 query 参数。
        XCTAssertFalse(url.query?.contains("group=") ?? false)
        XCTAssertFalse(url.absoluteString.contains("sound="))
    }

    @MainActor
    func testMergesSameModelEventsIntoSinglePushWithUnionChannel() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1", sound: nil
            )),
            session: stubbedSession
        )
        // 同一模型两个事件：恢复走 bark+system、耗尽走 system（合并后渠道并集
        // 含 Bark，两条文案合进一条推送）。
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored), Self.event(.weeklyExhausted)],
            channels: QuotaNotifyChannels(
                intervalRestored: .barkAndSystem,
                intervalExhausted: .system,
                weeklyRestored: nil,
                weeklyExhausted: nil
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1)
        // URL.path 返回解码后的文本，直接匹配中文即可。
        let body = RecordingURLProtocol.requests.first?.url?.path ?? "<no request>"
        XCTAssertTrue(body.contains("已用完"), "耗尽文案应在同一条推送里: \(body)")
    }

    @MainActor
    func testDifferentModelsGetSeparatePushes() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1", sound: nil
            )),
            session: stubbedSession
        )
        let first = Self.event(.intervalRestored)
        let second = QuotaEvent(
            modelName: "video",
            displayName: "video",
            kind: .intervalRestored,
            previousPercent: 10,
            currentPercent: 100
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [first, second],
            channels: allBarkChannels
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(RecordingURLProtocol.requests.count, 2)
        // 同类事件各自带稳定的覆盖 id，且不同模型的 id 不同。
        let ids = RecordingURLProtocol.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("llmmonitor-p-") })
    }

    func testBuildURLRejectsInvalidServerAndOverlongURL() {
        XCTAssertNil(BarkQuotaNotifier.buildURL(
            config: BarkConfig(enabled: true, serverURL: "not a url", deviceKey: "k", sound: nil),
            providerName: "p",
            body: "b"
        ))

        let long = String(repeating: "很", count: 1100)
        XCTAssertNil(BarkQuotaNotifier.buildURL(
            config: BarkConfig(enabled: true, serverURL: "https://api.day.app", deviceKey: "k", sound: nil),
            providerName: long,
            body: long
        ))
    }

    @MainActor
    func testDisabledOrIncompleteConfigSendsNothing() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: false, serverURL: "https://api.day.app", deviceKey: "k", sound: nil
            )),
            session: stubbedSession
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        // URL 请求是异步 Task；disabled 时不应发出任何请求。
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testEnabledConfigSendsRequestWithExpectedPath() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1", sound: nil
            )),
            session: stubbedSession
        )
        notifier.notify(
            providerID: "p", providerName: "GLM",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1)
        let sent = RecordingURLProtocol.requests[0]
        XCTAssertTrue(sent.url?.path.contains("/k1/") ?? false)
    }

    @MainActor
    func testSkipsWhenNoEventRoutesToBark() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1", sound: nil
            )),
            session: stubbedSession
        )
        // 事件存在但渠道全部是 system：不推送。
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored), Self.event(.weeklyExhausted)],
            channels: noneBarkChannels
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testSkipWhenUnlockedSuppressesPushOnUnlockedSession() {
        let notifier = BarkQuotaNotifier(
            configProvider: StubConfigProvider(BarkConfig(
                enabled: true,
                serverURL: "https://api.day.app",
                deviceKey: "k1",
                sound: nil,
                skipWhenUnlocked: true
            )),
            session: stubbedSession,
            screenIsLocked: { false }
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    func testBarkConfigCodingTolerantDecode() throws {
        let json = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {},
          "bark": {"enabled": true, "serverURL": "https://api.day.app", "deviceKey": "k", "skipWhenUnlocked": true}
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.bark?.deviceKey, "k")
        XCTAssertEqual(config.bark?.skipWhenUnlocked, true)
        XCTAssertNil(config.bark?.sound)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        XCTAssertEqual(decoded, config)

        // bark 字段类型写错时按缺失处理，不进入损坏恢复流程。
        let broken = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "bark": "oops"}
        """
        let fallback = try JSONDecoder().decode(AppConfig.self, from: Data(broken.utf8))
        XCTAssertNil(fallback.bark)
    }
}
