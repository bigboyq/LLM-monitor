import Foundation
import CoreGraphics

extension BarkConfig {
    /// 规范化副本：server / key / sound / group 去首尾空白。校验和实际请求
    /// 都使用规范化后的值，避免手工配置里的空格被编码进 URL。
    var normalized: BarkConfig {
        BarkConfig(
            enabled: enabled,
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceKey: deviceKey.trimmingCharacters(in: .whitespacesAndNewlines),
            sound: sound?.trimmingCharacters(in: .whitespacesAndNewlines),
            skipWhenAwakeAndUnlocked: skipWhenAwakeAndUnlocked,
            ttl: ttl,
            group: group?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// serverURL 与 deviceKey 齐全才算配置完整。
    var isComplete: Bool {
        !serverURL.isEmpty && !deviceKey.isEmpty
    }
}

/// 通过自建或官方 Bark 服务器把额度事件推送到 iPhone。
/// 复用系统通知的文案生成逻辑，保持两端提示一致。
///
/// 合并规则：一次刷新里同一个模型的多个事件合并为一条推送，但每个渠道只
/// 包含该渠道已启用的事件文案（「不通知」的事件不会混进其它渠道的通知）。
///
/// 传输采用官方文档的 POST JSON 形式（`POST {server}/{key}`，参数放 JSON
/// body）：标题 / 正文 / group / id 不再拼进 URL，规避 URL 编码与 2048
/// 长度限制，自建服务的 base path 也只需原样保留。
///
/// 配置读取器抽象：Bark 开关保存在 ConfigStore 里，但通知发生在刷新路径，
/// 每次发送前实时读取，用户在设置页保存后无需重启即可生效。
@MainActor
protocol BarkConfigProviding: AnyObject {
    var bark: BarkConfig? { get }
}

@MainActor
final class BarkQuotaNotifier: QuotaUpdateNotifying {
    static let testNotificationID = "llmmonitor-test-push"
    /// 单次推送请求超时；正式推送与测试推送共用。
    nonisolated static let requestTimeout: TimeInterval = 15

    private let configProvider: BarkConfigProviding
    /// 「人在电脑前」判定（屏幕亮且未锁屏）。注入以便测试。
    private let screenInActiveUse: () -> Bool
    /// 所有推送经共享串行队列发出：有界积压 + 冷却 + 有限重试 + 可取消。
    /// internal 供 @testable 查询积压状态。
    let sendQueue: BarkSendQueue

    init(
        configProvider: BarkConfigProviding,
        screenInActiveUse: @escaping () -> Bool = BarkQuotaNotifier.defaultScreenInActiveUse,
        sendQueue: BarkSendQueue = BarkSendQueue()
    ) {
        self.configProvider = configProvider
        self.screenInActiveUse = screenInActiveUse
        self.sendQueue = sendQueue
    }

    /// App 退出（applicationWillTerminate）时取消未完成的推送。
    func cancelPendingSends() {
        Task { await sendQueue.cancelAll() }
    }

    func notify(
        providerID: String,
        providerName: String,
        events: [QuotaEvent],
        channels: QuotaNotifyChannels
    ) {
        guard !events.isEmpty else { return }
        guard let bark = effectiveConfig else {
            logDebug("[bark] 未启用或配置不完整，跳过 \(providerID) Bark 推送")
            return
        }

        // 模型级合并；正文按渠道过滤，「不通知」的事件不进入任何通知。
        let groups = QuotaEventBatch(
            providerID: providerID,
            providerName: providerName,
            events: events,
            channels: channels
        ).modelGroups
        let barkGroups = groups.filter(\.sendsBark)
        guard !barkGroups.isEmpty else { return }

        // 「人在电脑前时跳过」：屏幕亮着且未锁屏才跳过；显示器休眠（人离开后
        // 闲置）或已锁屏都视为不在电脑前，正常推送。
        if bark.skipWhenAwakeAndUnlocked ?? false, screenInActiveUse() {
            logDebug("[bark] 人在电脑前（屏幕亮且未锁屏），按配置跳过 \(providerID) Bark 推送")
            return
        }

        // 批量入队：单 Task 保持入队顺序，也避免每组各起一个 Task。
        let operations = barkGroups.compactMap { group -> BarkSendQueue.Operation? in
            guard let request = Self.buildRequest(
                config: bark,
                providerName: providerName,
                body: group.barkLines.joined(separator: "\n"),
                notificationID: group.barkNotificationID
            ) else {
                logWarn("[bark] \(providerName)/\(group.displayName) 推送请求构造失败，跳过")
                return nil
            }
            return BarkSendQueue.Operation(
                request: request,
                cooldownKey: group.barkNotificationID,
                label: "\(providerName)/\(group.displayName)",
                eventCount: group.barkEvents.count
            )
        }
        guard !operations.isEmpty else { return }
        Task { [sendQueue] in
            for operation in operations {
                await sendQueue.enqueue(operation)
            }
        }
    }

    /// 设置页测试推送：与正式推送走同一套配置规范化、请求构造和屏幕策略，
    /// 仅绕过发送队列的冷却（允许连续点击验证）。返回面向用户的提示文案。
    static func sendTestPush(
        config draft: BarkConfig,
        session: URLSession = .shared,
        screenInActiveUse: @escaping () -> Bool = BarkQuotaNotifier.defaultScreenInActiveUse
    ) async -> String {
        let config = draft.normalized
        guard config.enabled, config.isComplete else {
            return "请先填写服务端地址和 Device Key"
        }
        if config.skipWhenAwakeAndUnlocked ?? false, screenInActiveUse() {
            return "当前正在使用电脑（屏幕亮且未锁屏），已按「人在电脑前时跳过推送」跳过本次测试；配置本身无误。"
        }
        guard let request = buildRequest(
            config: config,
            providerName: "LLM Monitor",
            body: "这是一条测试推送 🎉",
            notificationID: testNotificationID
        ) else {
            return "请求构造失败：请检查服务端地址（支持 https 或本机 http）"
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "推送失败：服务端返回非 HTTP 响应"
            }
            guard (200..<300).contains(http.statusCode) else {
                // 不回显服务端响应（可能包含 device key 等敏感内容）。
                return "推送失败：HTTP \(http.statusCode)，请检查服务端地址与 Device Key"
            }
            return "测试推送已发送，请在手机上查看"
        } catch is CancellationError {
            return "测试推送已取消"
        } catch {
            return "推送请求失败：\(error.localizedDescription)"
        }
    }

    /// 「人在电脑前」= 屏幕亮着且会话未锁屏。显示器休眠（人离开后闲置）或
    /// 已锁屏（含屏保锁定）都返回 false → 正常推送 Bark。
    nonisolated static func defaultScreenInActiveUse() -> Bool {
        !isDisplayAsleep() && !isSessionLocked()
    }

    /// 显示器是否休眠。查询失败（无显示器等异常环境）按"亮屏"处理，
    /// 宁可漏 Bark 不误发。
    nonisolated static func isDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// macOS 会话锁屏状态。`CGSessionCopyCurrentDictionary` 返回当前登录会话
    /// 的字典，`kCGSSessionScreenIsLocked` 在锁屏（含屏保锁定）时为 true。
    /// 拿不到会话字典时按"未锁屏"处理（与显示器判定叠加后仍偏保守）。
    nonisolated static func isSessionLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["kCGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// serverURL / deviceKey 任一为空或 enabled=false 都视为未配置。
    /// 返回规范化后的配置副本，实际请求不携带空白。
    private var effectiveConfig: BarkConfig? {
        guard let bark = configProvider.bark, bark.enabled else { return nil }
        let normalized = bark.normalized
        guard normalized.isComplete else { return nil }
        return normalized
    }

    // MARK: - 请求构造

    /// 构造 `POST {server}/{key}` 请求，参数放 JSON body（Bark 官方文档支持）：
    /// 标题 / 正文 / sound / group / id 全部经 JSON 传输，无需 URL percent
    /// encode，也没有 GET 的 2048 长度上限；自建服务 base path 原样保留。
    ///
    /// scheme 仅允许 https（本机调试允许 http），`id` 使用稳定字符串：相同
    /// id 的新推送覆盖手机上的旧通知（需 Bark v1.5.2+ / bark-server v2.2.5+）。
    nonisolated private static let pathSegmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    nonisolated static func buildRequest(
        config rawConfig: BarkConfig,
        providerName: String,
        body: String,
        notificationID: String? = nil
    ) -> URLRequest? {
        // 统一规范化（trim），避免调用方传入带空白的原始配置。
        let config = rawConfig.normalized
        guard var components = URLComponents(string: config.serverURL) else { return nil }
        // 相对引用（如 "not a url"）也能被 URLComponents 解析；这里要求
        // scheme + host 齐全才算合法的 Bark 服务端。
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        // https 之外只放开本机 http 调试；ftp / file 等一律拒绝。
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            return nil
        }

        // 保留 server URL 的 base path（去掉尾部斜杠）再拼 device key 段。
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let keySegment = config.deviceKey
            .addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? config.deviceKey
        components.percentEncodedPath = basePath + "/" + keySegment
        guard let url = components.url else { return nil }

        // ttl 是数值参数（消息有效期秒数，过期后手机端自动删除），
        // 按数字传输；0 / 未配置 = 不携带，走 Bark 默认（不自动过期）。
        var payload: [String: Any] = [
            "title": providerName,
            "body": body,
        ]
        if let sound = config.sound, !sound.isEmpty {
            payload["sound"] = sound
        }
        if let group = config.group, !group.isEmpty {
            payload["group"] = group
        }
        if let ttl = config.ttl, ttl > 0 {
            payload["ttl"] = ttl
        }
        if let notificationID, !notificationID.isEmpty {
            payload["id"] = notificationID
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        return request
    }
}

/// 串行发送队列：避免多模型同轮事件 / 短刷新间隔 / 阈值反复波动造成的请求
/// 突发。单并发 + 有界积压 + 每个 notificationID 的冷却窗口 + 瞬时错误一次
/// 重试；积压可查询、可整体取消（App 退出时调用）。
actor BarkSendQueue {
    struct Operation {
        let request: URLRequest
        /// 冷却窗口的键：正式推送用覆盖 id（provider + 模型），nil 表示不冷却。
        let cooldownKey: String?
        let label: String
        let eventCount: Int
    }

    /// 同一模型两次推送的最小间隔，抑制阈值附近反复触发的通知风暴。
    nonisolated static let cooldownInterval: TimeInterval = 60
    /// 积压上限：超出时丢弃最旧的操作。
    nonisolated static let maximumPending = 10
    /// 瞬时错误重试前的退避。
    nonisolated private static let retryDelay: TimeInterval = 1

    private var pending: [Operation] = []
    private var draining = false
    private var currentTask: Task<Void, Never>?
    /// drain 代际：cancelAll 递增使进行中的旧 drain 失效退出，保证取消后
    /// 新积压总能被新 drain 消费（否则会静默卡死直到下一次 enqueue）。
    private var generation = 0
    private var lastSentAt: [String: Date] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func enqueue(_ operation: Operation) {
        if let key = operation.cooldownKey, isCoolingDown(key) {
            logDebug("[bark] \(operation.label) 命中冷却窗口，跳过本次推送")
            return
        }
        pending.append(operation)
        if pending.count > Self.maximumPending {
            // 溢出时按冷却键合并、保留每个模型最新一条：detector 的比较基线
            // 在刷新后已更新，直接丢最旧会永久丢掉该模型的通知。
            pending = Self.compactByCooldownKey(pending, limit: Self.maximumPending)
            logWarn("[bark] 发送队列积压超过 \(Self.maximumPending)，已按模型合并到最新一条")
        }
        if !draining || currentTask?.isCancelled == true {
            draining = true
            generation += 1
            let gen = generation
            currentTask = Task { await self.drain(generation: gen) }
        }
    }

    /// 当前积压的待发送数量（测试与诊断用）。
    func pendingCount() -> Int {
        pending.count
    }

    /// 等待队列清空且不再有进行中的 drain（测试用）。
    func awaitIdle() async {
        while draining || !pending.isEmpty {
            await Task.yield()
        }
    }

    /// 清空积压并取消进行中的发送（App 退出时调用）。
    func cancelAll() {
        pending.removeAll()
        currentTask?.cancel()
        generation += 1
        // 被取消的旧 drain 在 defer 里因代际不匹配不会清 draining；这里直接清，
        // 否则 cancelAll 之后若无新 enqueue，awaitIdle 会永久等待。进行中的
        // 旧 drain 退出时 defer 同样跳过清理（draining 已为 false），无副作用。
        draining = false
    }

    private func isCoolingDown(_ key: String) -> Bool {
        guard let last = lastSentAt[key] else { return false }
        return Date().timeIntervalSince(last) < Self.cooldownInterval
    }

    private func drain(generation gen: Int) async {
        defer {
            // 只有仍然有效的代际才清理运行标记；被取消的旧 drain 不得
            // 重置新 drain 的状态。
            if gen == self.generation {
                draining = false
                currentTask = nil
            }
        }
        while !pending.isEmpty, !Task.isCancelled, gen == self.generation {
            let operation = pending.removeFirst()
            await send(operation)
        }
    }

    /// 发送单个操作；成功后才写入冷却表，失败/取消的发送不冷却，
    /// 下一轮刷新（或重启后的首次刷新）可尽快重试。
    private func send(_ operation: Operation) async {
        for attempt in 1...2 {
            do {
                let (_, response) = try await session.data(for: operation.request)
                guard let http = response as? HTTPURLResponse else {
                    logWarn("[bark] \(operation.label) Bark 推送返回非 HTTP 响应")
                    return
                }
                if (500...599).contains(http.statusCode), attempt == 1 {
                    logWarn("[bark] \(operation.label) Bark 服务端 HTTP \(http.statusCode)，\(Int(Self.retryDelay))s 后重试")
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    // 4xx 是配置/请求问题，重试无意义；只记状态码，不回显可能
                    // 包含 device key 的服务端响应或完整 URL。
                    logWarn("[bark] \(operation.label) Bark 推送失败: HTTP \(http.statusCode)（\(operation.eventCount) 个事件）")
                    return
                }
                if let key = operation.cooldownKey {
                    lastSentAt[key] = Date()
                }
                logInfo("[bark] 已发送 \(operation.label) 的 Bark 推送（\(operation.eventCount) 个事件合并）")
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                if attempt == 1, Self.isTransient(error) {
                    logWarn("[bark] \(operation.label) 网络错误 \(error.localizedDescription)，\(Int(Self.retryDelay))s 后重试")
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    continue
                }
                logWarn("[bark] \(operation.label) Bark 推送请求失败: \(error.localizedDescription)")
                return
            }
        }
    }

    /// 溢出合并：保留每个冷却键最新一条，无键操作原样保留，按原顺序排列后
    /// 截断到 limit。internal 供 @testable 直接验证。
    nonisolated static func compactByCooldownKey(
        _ operations: [Operation],
        limit: Int
    ) -> [Operation] {
        var latestByKey: [String: (index: Int, operation: Operation)] = [:]
        var keyOrder: [String] = []
        var keyless: [(index: Int, operation: Operation)] = []
        for (index, operation) in operations.enumerated() {
            guard let key = operation.cooldownKey else {
                keyless.append((index, operation))
                continue
            }
            if latestByKey[key] == nil {
                keyOrder.append(key)
            }
            latestByKey[key] = (index, operation)
        }
        let merged = (keyless + keyOrder.compactMap { latestByKey[$0] })
            .sorted { $0.index < $1.index }
            .map { $0.operation }
        return Array(merged.suffix(limit))
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
