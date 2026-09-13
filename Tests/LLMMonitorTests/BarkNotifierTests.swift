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
        callback?(request)
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
        screenIsLocked: @escaping () -> Bool = { false }
    ) -> BarkQuotaNotifier {
        BarkQuotaNotifier(
            configProvider: StubConfigProvider(bark),
            screenIsLocked: screenIsLocked,
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
    private func jsonPayload(of request: URLRequest) throws -> [String: String] {
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
            JSONSerialization.jsonObject(with: data) as? [String: String],
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
        XCTAssertEqual(payload["title"], "GLM Coding Plan")
        XCTAssertEqual(payload["body"], "短周期 10% → 100%，周额度 40% → 90%")
        XCTAssertEqual(payload["sound"], "minuet")
        XCTAssertEqual(payload["group"], "我的额度")
        XCTAssertEqual(payload["id"], "llmmonitor-glm-general")
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
        XCTAssertEqual(payload["body"]?.contains("短周期"), true)
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
        XCTAssertTrue(payload["body"]?.contains("短周期") ?? false, "恢复文案应存在: \(payload["body"] ?? "")")
        XCTAssertFalse(payload["body"]?.contains("已用完") ?? true, "禁用（不通知）的耗尽事件不得混入: \(payload["body"] ?? "")")
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
        let ids = try RecordingURLProtocol.requests.map { try jsonPayload(of: $0)["id"] ?? "" }
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

        notifier.cancelPendingSends()
        // 释放挂起的请求；被取消的 data 调用会抛 CancellationError。
        RecordingURLProtocol.setHold(false)
        try await Task.sleep(nanoseconds: 500_000_000)
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
                sound: nil, skipWhenUnlocked: false, group: "我的额度"
            ),
            session: sessionWith(RecordingURLProtocol.self),
            screenIsLocked: { false }
        )
        XCTAssertEqual(message, "测试推送已发送，请在手机上查看")
        let sent = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(sent.url?.host, "api.day.app")
        XCTAssertEqual(sent.url?.path, "/k1", "device key 应被规范化")
        let payload = try jsonPayload(of: sent)
        XCTAssertEqual(payload["id"], BarkQuotaNotifier.testNotificationID)
        XCTAssertEqual(payload["group"], "我的额度")
    }

    @MainActor
    func testTestPushHonorsSkipWhenUnlocked() async {
        RecordingURLProtocol.reset()
        let message = await BarkQuotaNotifier.sendTestPush(
            config: BarkConfig(
                enabled: true, serverURL: "https://api.day.app", deviceKey: "k1",
                sound: nil, skipWhenUnlocked: true, group: nil
            ),
            session: sessionWith(RecordingURLProtocol.self),
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
            session: sessionWith(RecordingURLProtocol.self)
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
