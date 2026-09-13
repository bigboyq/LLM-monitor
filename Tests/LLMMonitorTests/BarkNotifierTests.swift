import XCTest
@testable import LLM_monitor

/// 拦截 URLSession 请求的 URLProtocol 桩：记录请求、可指定状态码、每个请求
/// 触发一次回调供测试 fulfill expectation（替代固定 RunLoop 等待）。
private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    private static var _statusCode = 200
    private static var _onReceive: (@Sendable (URLRequest) -> Void)?

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// 每收到一个请求回调一次；线程安全。
    static var onReceive: (@Sendable (URLRequest) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReceive }
        set { lock.lock(); defer { lock.unlock() }; _onReceive = newValue }
    }

    static func reset(statusCode: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        _requests = []
        _statusCode = statusCode
        _onReceive = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let statusCode = Self._statusCode
        let callback = Self._onReceive
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
        callback?(request)
    }

    override func stopLoading() {}
}

final class BarkNotifierTests: XCTestCase {
    @MainActor
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

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    private var stubbedSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    @MainActor
    private func makeNotifier(
        _ bark: BarkConfig,
        screenIsLocked: @escaping () -> Bool = { false }
    ) -> BarkQuotaNotifier {
        BarkQuotaNotifier(
            configProvider: StubConfigProvider(bark),
            screenIsLocked: screenIsLocked,
            sendQueue: BarkSendQueue(session: stubbedSession)
        )
    }

    private static func event(_ kind: QuotaNotificationKind, model: String = "general") -> QuotaEvent {
        QuotaEvent(
            modelName: model,
            displayName: model,
            kind: kind,
            previousPercent: 10,
            currentPercent: kind == .intervalRestored || kind == .weeklyRestored ? 100 : 0
        )
    }

    /// 等待累计收到第 n 个请求（1-based）。
    private func expectRequestCount(_ count: Int, timeout: TimeInterval = 5) async {
        let exp = expectation(description: "收到 \(count) 个请求")
        let lock = NSLock()
        RecordingURLProtocol.onReceive = { _ in
            lock.lock()
            let done = RecordingURLProtocol.requests.count >= count
            lock.unlock()
            if done { exp.fulfill() }
        }
        await fulfillment(of: [exp], timeout: timeout)
    }

    // MARK: - URL 构造

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
            notificationID: "llmmonitor-glm-general"
        ))

        XCTAssertEqual(url.host, "api.day.app")
        // 中文与箭头必须被 percent-encode，不能裸露在 URL 里。
        XCTAssertFalse(url.absoluteString.contains("→"))
        XCTAssertTrue(url.absoluteString.contains("%E7%9F%AD"))
        XCTAssertTrue(url.absoluteString.contains("sound=minuet"))
        XCTAssertTrue(url.absoluteString.contains("group="))
        XCTAssertTrue(url.absoluteString.contains("id=llmmonitor-glm-general"))
    }

    func testBuildURLPreservesServerBasePath() throws {
        // R4: 自建服务部署在反向代理子路径下时，base path 不能被丢弃。
        let url = try XCTUnwrap(BarkQuotaNotifier.buildURL(
            config: BarkConfig(
                enabled: true, serverURL: "https://example.com/bark/", deviceKey: "k",
                sound: nil, group: nil
            ),
            providerName: "P",
            body: "b"
        ))
        XCTAssertEqual(url.path, "/bark/k/P/b")
    }

    func testBuildURLRejectsInvalidServerAndScheme() {
        func make(_ server: String) -> BarkConfig {
            BarkConfig(enabled: true, serverURL: server, deviceKey: "k", sound: nil, group: nil)
        }
        // 相对引用 / 无 host。
        XCTAssertNil(BarkQuotaNotifier.buildURL(config: make("not a url"), providerName: "p", body: "b"))
        // scheme 白名单：只允许 https 和本机 http。
        XCTAssertNil(BarkQuotaNotifier.buildURL(config: make("ftp://example.com"), providerName: "p", body: "b"))
        XCTAssertNil(BarkQuotaNotifier.buildURL(config: make("file:///tmp"), providerName: "p", body: "b"))
        XCTAssertNil(BarkQuotaNotifier.buildURL(config: make("http://example.com"), providerName: "p", body: "b"))
        // 本机 http 调试放行。
        XCTAssertNotNil(BarkQuotaNotifier.buildURL(config: make("http://localhost:8080"), providerName: "p", body: "b"))
        XCTAssertNotNil(BarkQuotaNotifier.buildURL(config: make("http://127.0.0.1:8080"), providerName: "p", body: "b"))
        // R4 之外的长度上限仍然生效。
        let long = String(repeating: "很", count: 1100)
        XCTAssertNil(BarkQuotaNotifier.buildURL(
            config: make("https://api.day.app"), providerName: long, body: long
        ))
    }

    func testBuildURLOmitsOptionalParamsWhenUnset() throws {
        let url = try XCTUnwrap(BarkQuotaNotifier.buildURL(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k",
                sound: "  ", group: "  "
            ),
            providerName: "P",
            body: "b"
        ))
        // sound / group 留空（或纯空白）时不携带对应 query 参数。
        XCTAssertFalse(url.query?.contains("sound=") ?? false)
        XCTAssertFalse(url.query?.contains("group=") ?? false)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertNil(components?.queryItems?.first { $0.name == "id" })
    }

    // MARK: - 发送行为

    @MainActor
    func testDisabledOrIncompleteConfigSendsNothing() async throws {
        let notifier = makeNotifier(BarkConfig(
            enabled: false, serverURL: "https://api.day.app", deviceKey: "k",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testEnabledConfigSendsRequestWithNormalizedConfig() async throws {
        // R5: 手工配置里的首尾空白会被规范化，不会编码进 URL。
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: " https://api.day.app ", deviceKey: " k1 ",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "GLM",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        await expectRequestCount(1)
        let sent = RecordingURLProtocol.requests[0]
        XCTAssertEqual(sent.url?.host, "api.day.app")
        XCTAssertTrue(sent.url?.path.hasPrefix("/k1/") ?? false)
    }

    @MainActor
    func testMergesSameModelEventsIntoSinglePushFilteringDisabledChannel() async throws {
        // R1: 同一模型「恢复 → Bark+系统、耗尽 → 不通知」时，Bark 推送只含
        // 恢复文案，被禁用的耗尽事件不得混入正文。
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored), Self.event(.weeklyExhausted)],
            channels: QuotaNotifyChannels(
                intervalRestored: .barkAndSystem,
                intervalExhausted: .none,
                weeklyRestored: nil,
                weeklyExhausted: nil
            )
        )
        await expectRequestCount(1)
        let body = RecordingURLProtocol.requests[0].url?.path ?? "<no request>"
        XCTAssertTrue(body.contains("短周期"), "恢复文案应存在: \(body)")
        XCTAssertFalse(body.contains("已用完"), "禁用（不通知）的耗尽事件不得混入: \(body)")
    }

    @MainActor
    func testDifferentModelsGetSeparatePushesWithStableIDs() async throws {
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored), Self.event(.intervalRestored, model: "video")],
            channels: allBarkChannels
        )
        await expectRequestCount(2)
        let ids = RecordingURLProtocol.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ids[0], "llmmonitor-p-general")
        XCTAssertEqual(ids[1], "llmmonitor-p-video")
    }

    @MainActor
    func testBarkNotificationIDIsStableAcrossEventCombinationChanges() {
        // R2: 事件组合从单事件变为双事件时，覆盖 id 必须保持不变，否则
        // 旧通知无法被覆盖、继续堆积。
        let channels = QuotaNotifyChannels(
            intervalRestored: .barkAndSystem, intervalExhausted: .barkAndSystem,
            weeklyRestored: .barkAndSystem, weeklyExhausted: .barkAndSystem
        )
        let single = QuotaEventBatch(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)], channels: channels
        )
        let combined = QuotaEventBatch(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored), Self.event(.weeklyRestored)],
            channels: channels
        )
        XCTAssertEqual(single.modelGroups[0].barkNotificationID, "llmmonitor-p-general")
        XCTAssertEqual(single.modelGroups[0].barkNotificationID, combined.modelGroups[0].barkNotificationID)
    }

    func testBatchSplitsEventsPerChannel() {
        // R1: 渠道拆分语义 —— system 只含启用系统通知的事件，bark 只含
        // 启用 Bark 的事件，「不通知」的事件两边都不出现。
        let channels = QuotaNotifyChannels(
            intervalRestored: .system,
            intervalExhausted: .none,
            weeklyRestored: .barkAndSystem,
            weeklyExhausted: .none
        )
        let batch = QuotaEventBatch(
            providerID: "p", providerName: "P",
            events: [
                Self.event(.intervalRestored),
                Self.event(.weeklyRestored),
                Self.event(.intervalExhausted),
                Self.event(.weeklyExhausted),
            ],
            channels: channels
        )
        let group = batch.modelGroups[0]
        // 「Bark + 系统通知」同时进入两个渠道；「不通知」两边都不出现。
        XCTAssertEqual(group.systemEvents.map(\.kind), [.intervalRestored, .weeklyRestored])
        XCTAssertEqual(group.barkEvents.map(\.kind), [.weeklyRestored])
        XCTAssertTrue(group.sendsSystem)
        XCTAssertTrue(group.sendsBark)
    }

    @MainActor
    func testSkipsWhenNoEventRoutesToBark() async throws {
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: QuotaNotifyChannels(
                intervalRestored: .system, intervalExhausted: .system,
                weeklyRestored: .system, weeklyExhausted: .system
            )
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testSkipWhenUnlockedSuppressesPushOnUnlockedSession() async throws {
        let notifier = makeNotifier(
            BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, skipWhenUnlocked: true, group: nil
            ),
            screenIsLocked: { false }
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testCooldownSuppressesRapidRepeatForSameModel() async throws {
        // R6: 同一模型（同一覆盖 id）60s 冷却窗口内的重复触发只发一次。
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        let events = [Self.event(.intervalRestored)]
        notifier.notify(providerID: "p", providerName: "P", events: events, channels: allBarkChannels)
        await expectRequestCount(1)

        RecordingURLProtocol.onReceive = nil
        notifier.notify(providerID: "p", providerName: "P", events: events, channels: allBarkChannels)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1, "冷却窗口内的重复推送应被跳过")
    }

    @MainActor
    func testRetriesOnceOnServerError() async throws {
        // R6: 5xx 触发一次重试（共 2 个请求），之后放弃。
        RecordingURLProtocol.reset(statusCode: 500)
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        let exp = expectation(description: "第二次请求（重试）")
        let lock = NSLock()
        RecordingURLProtocol.onReceive = { _ in
            lock.lock()
            let count = RecordingURLProtocol.requests.count
            lock.unlock()
            if count >= 2 { exp.fulfill() }
        }
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        await fulfillment(of: [exp], timeout: 10)
        // 重试后不再继续（不会出现第 3 个请求）。
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(RecordingURLProtocol.requests.count, 2)
    }

    // MARK: - 测试推送（R7：与正式推送共用参数）

    @MainActor
    func testTestPushReusesUnifiedParams() async throws {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: " k1 ",
                sound: nil, skipWhenUnlocked: false, group: "我的额度"
            ),
            session: stubbedSession,
            screenIsLocked: { false }
        )
        XCTAssertEqual(message, "测试推送已发送，请在手机上查看")
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(sent.url?.host, "api.day.app")
        XCTAssertTrue(sent.url?.path.hasPrefix("/k1/") ?? false, "device key 应被规范化")
        let components = try XCTUnwrap(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "id" }?.value, BarkQuotaNotifier.testNotificationID)
        XCTAssertEqual(components.queryItems?.first { $0.name == "group" }?.value, "我的额度")
    }

    @MainActor
    func testTestPushHonorsSkipWhenUnlocked() async {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, skipWhenUnlocked: true, group: nil
            ),
            session: stubbedSession,
            screenIsLocked: { false }
        )
        XCTAssertTrue(message.contains("未锁屏"))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testTestPushRejectsIncompleteConfig() async {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "   ",
                sound: nil, group: nil
            ),
            session: stubbedSession
        )
        XCTAssertTrue(message.contains("请先填写"))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    // MARK: - 配置持久化

    func testBarkConfigCodingTolerantDecode() throws {
        let json = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {},
          "bark": {"enabled": true, "serverURL": "https://api.day.app", "deviceKey": "k", "skipWhenUnlocked": true, "group": "g"}
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.bark?.deviceKey, "k")
        XCTAssertEqual(config.bark?.skipWhenUnlocked, true)
        XCTAssertEqual(config.bark?.group, "g")
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
