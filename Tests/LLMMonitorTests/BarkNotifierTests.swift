import XCTest
@testable import LLM_monitor

/// 拦截 URLSession 请求的 URLProtocol 桩：记录请求、可指定状态码、每个请求
/// 触发一次回调供测试 fulfill expectation（替代固定 RunLoop 等待）。
private final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    private static var _statusCode = 200
    private static var _onReceive: (@Sendable (URLRequest) -> Void)?
    /// hold 模式：请求挂起直到 releaseHold，用于构造"发送进行中"的确定性时序。
    private static var _hold = false
    private static let holdSemaphore = DispatchSemaphore(value: 0)

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
        _hold = false
        while holdSemaphore.wait(wallTimeout: .now()) == .success {}
    }

    static func setHold(_ enabled: Bool) {
        lock.lock(); _hold = enabled; lock.unlock()
        if !enabled {
            while holdSemaphore.wait(wallTimeout: .now()) == .success {}
            holdSemaphore.signal()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let statusCode = Self._statusCode
        let callback = Self._onReceive
        let hold = Self._hold
        Self.lock.unlock()

        // 请求进入即记录并回调（先于 hold）：测试能确定性地等到“请求已发出
        // 且正被挂起”，而不是等 hold 的 5s 信号量超时；也避免被 hold 卡住的
        // startLoading 把记录串扰到下一个测试的窗口里。
        callback?(request)

        if hold {
            _ = Self.holdSemaphore.wait(wallTimeout: .now() + 5)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 始终抛指定 URLError 的 URLProtocol 桩，验证失败 / 重试路径。
private final class FailingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _attempts = 0
    static var attempts: Int {
        lock.lock(); defer { lock.unlock() }
        return _attempts
    }
    /// 使用的错误码；瞬时错误应触发重试，非瞬时错误不应重试。
    static var errorCode: URLError.Code = .timedOut

    static func reset(errorCode: URLError.Code) {
        lock.lock(); defer { lock.unlock() }
        _attempts = 0
        self.errorCode = errorCode
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._attempts += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(Self.errorCode))
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

    private func sessionWith(_ type: URLProtocol.Type) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [type]
        return URLSession(configuration: config)
    }

    @MainActor
    private func makeNotifier(
        _ bark: BarkConfig,
        session: URLSession? = nil,
        screenInActiveUse: @escaping () -> Bool = { false }
    ) -> BarkQuotaNotifier {
        BarkQuotaNotifier(
            configProvider: StubConfigProvider(bark),
            screenInActiveUse: screenInActiveUse,
            sendQueue: BarkSendQueue(session: session ?? sessionWith(RecordingURLProtocol.self))
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

    /// 等待累计收到第 n 个请求（1-based）；fulfill 一次后自动摘除回调。
    private func expectRequestCount(_ count: Int, timeout: TimeInterval = 5) async {
        let exp = expectation(description: "收到 \(count) 个请求")
        RecordingURLProtocol.onReceive = { _ in
            if RecordingURLProtocol.requests.count >= count {
                RecordingURLProtocol.onReceive = nil
                exp.fulfill()
            }
        }
        await fulfillment(of: [exp], timeout: timeout)
    }

    /// URLProtocol 里 httpBody 会变成 httpBodyStream，这里统一读出来。
    /// payload 值混合字符串与数字（如 ttl），按弱类型字典解。
    private func jsonPayload(of request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                collected.append(buffer, count: read)
            }
            data = collected
        } else {
            data = Data()
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "POST body 应是字符串 JSON 对象: \(String(data: data, encoding: .utf8) ?? "<nil>")"
        )
        return object
    }

    // MARK: - 请求构造（POST JSON）

    func testBuildRequestPostsJSONPayload() throws {
        let request = try XCTUnwrap(BarkQuotaNotifier.buildRequest(
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

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "api.day.app")
        XCTAssertEqual(request.url?.path, "/abc123")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") ?? false
        )
        let payload = try jsonPayload(of: request)
        // 中文 / 箭头 / 换行经 JSON 传输，无需 URL percent encode。
        XCTAssertEqual(payload["title"] as? String, "GLM Coding Plan")
        XCTAssertEqual(payload["body"] as? String, "短周期 10% → 100%，周额度 40% → 90%")
        XCTAssertEqual(payload["sound"] as? String, "minuet")
        XCTAssertEqual(payload["group"] as? String, "我的额度")
        XCTAssertEqual(payload["id"] as? String, "llmmonitor-glm-general")
        XCTAssertNil(payload["ttl"], "未配置 ttl 时不携带该参数")
    }

    func testBuildRequestIncludesTTLOnlyWhenPositive() throws {
        // 2026-09-13 裁定：ttl > 0 按数字携带；0 / 负值一律不带（0 = 不过期）。
        func payloadWith(ttl: Int) throws -> [String: Any] {
            let request = try XCTUnwrap(BarkQuotaNotifier.buildRequest(
                config: BarkConfig(
                    enabled: true, serverURL: "https://api.day.app", deviceKey: "k",
                    sound: nil, skipWhenAwakeAndUnlocked: nil, ttl: ttl, group: nil
                ),
                providerName: "P",
                body: "b"
            ))
            return try jsonPayload(of: request)
        }
        XCTAssertEqual(try payloadWith(ttl: 3600)["ttl"] as? Int, 3600, "ttl > 0 应按 JSON 数字携带")
        XCTAssertNotNil(try payloadWith(ttl: 1)["ttl"], "最小正整数也应携带")
        XCTAssertNil(try payloadWith(ttl: 0)["ttl"], "ttl = 0 不携带")
        XCTAssertNil(try payloadWith(ttl: -5)["ttl"], "负值不携带")
    }

    func testBuildRequestPreservesServerBasePath() throws {
        // R4: 自建服务部署在反向代理子路径下时，base path 不能被丢弃。
        let request = try XCTUnwrap(BarkQuotaNotifier.buildRequest(
            config: BarkConfig(
                enabled: true, serverURL: "https://example.com/bark/", deviceKey: "k",
                sound: nil, group: nil
            ),
            providerName: "P",
            body: "b"
        ))
        XCTAssertEqual(request.url?.path, "/bark/k")
    }

    func testBuildRequestRejectsInvalidServerAndScheme() {
        func make(_ server: String) -> BarkConfig {
            BarkConfig(enabled: true, serverURL: server, deviceKey: "k", sound: nil, group: nil)
        }
        // 相对引用 / 无 host。
        XCTAssertNil(BarkQuotaNotifier.buildRequest(config: make("not a url"), providerName: "p", body: "b"))
        // scheme 白名单：只允许 https 和本机 http。
        XCTAssertNil(BarkQuotaNotifier.buildRequest(config: make("ftp://example.com"), providerName: "p", body: "b"))
        XCTAssertNil(BarkQuotaNotifier.buildRequest(config: make("file:///tmp"), providerName: "p", body: "b"))
        XCTAssertNil(BarkQuotaNotifier.buildRequest(config: make("http://example.com"), providerName: "p", body: "b"))
        // 本机 http 调试放行。
        XCTAssertNotNil(BarkQuotaNotifier.buildRequest(config: make("http://localhost:8080"), providerName: "p", body: "b"))
        XCTAssertNotNil(BarkQuotaNotifier.buildRequest(config: make("http://127.0.0.1:8080"), providerName: "p", body: "b"))
    }

    func testBuildRequestOmitsOptionalParamsWhenUnset() throws {
        let request = try XCTUnwrap(BarkQuotaNotifier.buildRequest(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k",
                sound: "  ", group: "  "
            ),
            providerName: "P",
            body: "b"
        ))
        // sound / group 留空（或纯空白）时不出现在 JSON payload 里。
        let payload = try jsonPayload(of: request)
        XCTAssertNil(payload["sound"])
        XCTAssertNil(payload["group"])
        XCTAssertNil(payload["id"])
        XCTAssertEqual(request.timeoutInterval, BarkQuotaNotifier.requestTimeout)
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
        // R5: 手工配置里的首尾空白会被规范化，不会出现在请求里。
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
        XCTAssertEqual(sent.url?.path, "/k1")
        let payload = try jsonPayload(of: sent)
        XCTAssertTrue((payload["body"] as? String)?.contains("短周期") ?? false)
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
        let payload = try jsonPayload(of: RecordingURLProtocol.requests[0])
        XCTAssertTrue((payload["body"] as? String)?.contains("短周期") ?? false, "恢复文案应存在: \(payload["body"] ?? "")")
        XCTAssertFalse((payload["body"] as? String)?.contains("已用完") ?? true, "禁用（不通知）的耗尽事件不得混入: \(payload["body"] ?? "")")
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
        let ids = try RecordingURLProtocol.requests.map { (try jsonPayload(of: $0)["id"] as? String) ?? "" }
        XCTAssertEqual(ids.count, 2)
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
        // 渠道正文按各自的事件列表生成，互不混入。
        XCTAssertEqual(group.systemLines.count, 2)
        XCTAssertTrue(group.systemLines[0].contains("短周期"))
        XCTAssertTrue(group.systemLines[1].contains("周额度"))
        XCTAssertEqual(group.barkLines.count, 1)
        XCTAssertTrue(group.barkLines[0].contains("周额度"))
        XCTAssertFalse(group.barkLines[0].contains("短周期"))
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
    func testSkipWhenAwakeAndUnlockedSuppressesPushOnlyWhenInActiveUse() async throws {
        // 屏幕谓词（2026-09-13 裁定）：亮屏 + 未锁屏（人在电脑前）→ 跳过；
        // 显示器休眠或已锁屏（人不在）→ 正常推送。通知器只看组合结论
        // screenInActiveUse（= 亮屏 && 未锁屏）。
        let config = BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, skipWhenAwakeAndUnlocked: true, group: nil
        )

        // 人在电脑前 → 跳过。
        let away = makeNotifier(config, screenInActiveUse: { true })
        away.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)

        // 不在电脑前（休眠或锁屏）→ 推送。
        let present = makeNotifier(config, screenInActiveUse: { false })
        present.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        await expectRequestCount(1)

        // 开关关闭时人在电脑前也推送。
        RecordingURLProtocol.reset()
        let disabled = makeNotifier(
            BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, skipWhenAwakeAndUnlocked: nil, group: nil
            ),
            screenInActiveUse: { true }
        )
        disabled.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        await expectRequestCount(1)
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
        // 冷却表在发送成功后才写入；等队列彻底空闲（首条已完成），再触发
        // 第二次，否则第二次可能在冷却生效前入队（竞态）。
        await notifier.sendQueue.awaitIdle()

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
        RecordingURLProtocol.onReceive = { _ in
            if RecordingURLProtocol.requests.count >= 2 { exp.fulfill() }
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

    @MainActor
    func testTransientNetworkErrorRetriesOnce() async throws {
        // 测试清单 7：瞬时网络错误（timedOut）重试一次。
        FailingURLProtocol.reset(errorCode: .timedOut)
        let notifier = makeNotifier(
            BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, group: nil
            ),
            session: sessionWith(FailingURLProtocol.self)
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        let exp = expectation(description: "第二次尝试")
        let poll = Task {
            while FailingURLProtocol.attempts < 2 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 10)
        poll.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(FailingURLProtocol.attempts, 2, "瞬时错误重试一次后放弃")
    }

    @MainActor
    func testNonTransientErrorDoesNotRetry() async throws {
        // 测试清单 7：非瞬时错误不重试，只尝试一次。
        FailingURLProtocol.reset(errorCode: .badServerResponse)
        let notifier = makeNotifier(
            BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, group: nil
            ),
            session: sessionWith(FailingURLProtocol.self)
        )
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(FailingURLProtocol.attempts, 1, "非瞬时错误不应重试")
    }

    @MainActor
    func testCancelAllClearsPendingBacklog() async throws {
        // R6: 队列可取消 —— hold 住第一个请求（发送进行中），其余积压在
        // cancelAll 后必须全部取消。
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        RecordingURLProtocol.setHold(true)
        defer { RecordingURLProtocol.setHold(false) }

        let models = (0..<5).map { Self.event(.intervalRestored, model: "model-\($0)") }
        notifier.notify(providerID: "p", providerName: "P", events: models, channels: allBarkChannels)
        await expectRequestCount(1)

        // 先等 4 个积压全部入队（1 个在途被 hold），消除 cancelAll 与入队 Task
        // 的竞态：否则 cancelAll 之后仍可能有操作继续入队并被发送。
        let backlogFull = expectation(description: "4 个操作全部入队")
        let poll = Task {
            while await notifier.sendQueue.pendingCount() < 4 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            backlogFull.fulfill()
        }
        await fulfillment(of: [backlogFull], timeout: 5)
        poll.cancel()

        // 直接 await 队列的 cancelAll（cancelPendingSends 是 fire-and-forget
        // 包装），保证取消在释放 hold 之前生效，时序确定。
        await notifier.sendQueue.cancelAll()
        // 释放挂起的请求；被取消的 data 调用会抛 CancellationError。
        RecordingURLProtocol.setHold(false)
        await notifier.sendQueue.awaitIdle()
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1, "积压里的 4 个不应发出")
        let remaining = await notifier.sendQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    @MainActor
    func testEnqueueAfterCancelAllStillDrains() async throws {
        // D1 回归：cancelAll 命中进行中的发送后，新入队的推送必须能被新的
        // drain 消费，而不是静默卡死。
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        await expectRequestCount(1)
        await notifier.sendQueue.awaitIdle()

        // 复现缺陷时序：cancelAll 紧跟新入队（不同模型避免命中冷却）。
        notifier.cancelPendingSends()
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored, model: "video")],
            channels: allBarkChannels
        )
        await expectRequestCount(2, timeout: 5)
        let remaining = await notifier.sendQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    func testCompactByCooldownKeyKeepsLatestPerModel() {
        // D3: 溢出合并 —— 每个模型保留最新一条，且不丢失任何模型。
        func op(_ model: String, body: String) -> BarkSendQueue.Operation {
            BarkSendQueue.Operation(
                request: URLRequest(url: URL(string: "https://api.day.app/k")!),
                cooldownKey: "llmmonitor-p-\(model)",
                label: model,
                eventCount: 1
            )
        }
        let ops = [
            op("a", body: "a-old"),
            op("b", body: "b-old"),
            op("a", body: "a-new"),
            op("c", body: "c"),
            op("b", body: "b-new"),
            op("d", body: "d"),
        ]
        let compacted = BarkSendQueue.compactByCooldownKey(ops, limit: 4)
        XCTAssertEqual(compacted.count, 4)
        // 顺序按各键最新一次出现的位置排列（a@0, c@3, b@4, d@5）。
        let keys = compacted.map { $0.cooldownKey ?? "" }
        XCTAssertEqual(keys, ["llmmonitor-p-a", "llmmonitor-p-c", "llmmonitor-p-b", "llmmonitor-p-d"])
        // 同键保留的是最新一条。
        XCTAssertEqual(compacted[0].label, "a")
        XCTAssertEqual(BarkSendQueue.compactByCooldownKey(ops, limit: 2).count, 2)
    }

    @MainActor
    func testFailedSendDoesNotStartCooldown() async throws {
        // D4: 发送失败（500 两次尝试均失败）不进入冷却，同一模型下一轮可
        // 立即重发；成功之后才冷却。
        RecordingURLProtocol.reset(statusCode: 500)
        let notifier = makeNotifier(BarkConfig(
            enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
            sound: nil, group: nil
        ))
        notifier.notify(
            providerID: "p", providerName: "P",
            events: [Self.event(.intervalRestored)],
            channels: allBarkChannels
        )
        // 先等首个请求落地（避免 awaitIdle 在入队 Task 启动前空转返回），
        // 再等队列彻底空闲（覆盖 1s 退避后的重试）。
        await expectRequestCount(1)
        await notifier.sendQueue.awaitIdle()
        let failedAttempts = RecordingURLProtocol.requests.count
        XCTAssertEqual(failedAttempts, 2, "500 应重试一次")

        RecordingURLProtocol.reset(statusCode: 200)
        let events = [Self.event(.intervalRestored)]
        notifier.notify(providerID: "p", providerName: "P", events: events, channels: allBarkChannels)
        await expectRequestCount(1)
        await notifier.sendQueue.awaitIdle()

        // 成功后同模型再触发应命中冷却。
        RecordingURLProtocol.onReceive = nil
        notifier.notify(providerID: "p", providerName: "P", events: events, channels: allBarkChannels)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(RecordingURLProtocol.requests.count, 1, "成功后的冷却窗口内不应重发")
    }

    // MARK: - 测试推送（R7：与正式推送共用参数）

    @MainActor
    func testTestPushReusesUnifiedParams() async throws {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: " k1 ",
                sound: nil, skipWhenAwakeAndUnlocked: false, group: "我的额度"
            ),
            session: sessionWith(RecordingURLProtocol.self),
            screenInActiveUse: { false }
        )
        XCTAssertEqual(message, "测试推送已发送，请在手机上查看")
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(sent.url?.host, "api.day.app")
        XCTAssertEqual(sent.url?.path, "/k1", "device key 应被规范化")
        let payload = try jsonPayload(of: sent)
        XCTAssertEqual(payload["id"] as? String, BarkQuotaNotifier.testNotificationID)
        XCTAssertEqual(payload["group"] as? String, "我的额度")
    }

    @MainActor
    func testTestPushHonorsSkipWhenAwakeAndUnlocked() async {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, skipWhenAwakeAndUnlocked: true, group: nil
            ),
            session: sessionWith(RecordingURLProtocol.self),
            screenInActiveUse: { true }
        )
        XCTAssertTrue(message.contains("正在使用电脑"))
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
            session: sessionWith(RecordingURLProtocol.self)
        )
        XCTAssertTrue(message.contains("请先填写"))
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty)
    }

    // MARK: - 配置持久化

    func testParseTTLNormalizesInput() {
        // 设置页草稿是文本：去空白后必须能解析为正整数，否则归一化为 0。
        XCTAssertEqual(BarkConfig.parseTTL("3600"), 3600)
        XCTAssertEqual(BarkConfig.parseTTL(" 60 "), 60)
        XCTAssertEqual(BarkConfig.parseTTL(""), 0)
        XCTAssertEqual(BarkConfig.parseTTL("   "), 0)
        XCTAssertEqual(BarkConfig.parseTTL("abc"), 0)
        XCTAssertEqual(BarkConfig.parseTTL("3.5"), 0)
        XCTAssertEqual(BarkConfig.parseTTL("0"), 0, "0 = 不过期")
        XCTAssertEqual(BarkConfig.parseTTL("-5"), 0)
    }

    func testBarkConfigPerFieldTolerantDecode() throws {
        // P2 回归：单个字段类型写错只回退该字段默认值，其余字段保留。
        let json = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {},
          "bark": {"enabled": true, "serverURL": "https://api.day.app", "deviceKey": "k", "ttl": "abc"}
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let bark = try XCTUnwrap(config.bark, "单字段类型错误不应拖垮整个 bark 块")
        XCTAssertEqual(bark.deviceKey, "k", "deviceKey 应保留")
        XCTAssertEqual(bark.serverURL, "https://api.day.app")
        XCTAssertEqual(bark.ttl, 0, "非法 ttl 归一化为 0（不携带参数）")
        XCTAssertNil(bark.sound)

        // 编码省略零值 / nil 字段：默认配置不产生 ttl 键。
        let encoded = String(data: try JSONEncoder().encode(bark), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("\"ttl\""), "ttl = 0 时不应写盘: \(encoded)")

        // 负值解码钳制为 0；结构级错误（bark 不是对象）仍按未配置处理。
        let negative = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "bark": {"enabled": true, "serverURL": "https://api.day.app", "deviceKey": "k", "ttl": -9}}
        """
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data(negative.utf8)).bark?.ttl, 0)
        let broken = """
        {"schemaVersion": 2, "refreshIntervalSeconds": 300, "providers": {}, "bark": "oops"}
        """
        XCTAssertNil(try JSONDecoder().decode(AppConfig.self, from: Data(broken.utf8)).bark)
    }

    func testBarkConfigCodingTolerantDecode() throws {
        let json = """
        {
          "schemaVersion": 2,
          "refreshIntervalSeconds": 300,
          "providers": {},
          "bark": {"enabled": true, "serverURL": "https://api.day.app", "deviceKey": "k", "skipWhenAwakeAndUnlocked": true, "ttl": 3600, "group": "g"}
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.bark?.deviceKey, "k")
        XCTAssertEqual(config.bark?.skipWhenAwakeAndUnlocked, true)
        XCTAssertEqual(config.bark?.ttl, 3600)
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
