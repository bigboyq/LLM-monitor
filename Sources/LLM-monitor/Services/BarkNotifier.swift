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
            skipWhenUnlocked: skipWhenUnlocked,
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
/// 配置读取器抽象：Bark 开关保存在 ConfigStore 里，但通知发生在刷新路径，
/// 每次发送前实时读取，用户在设置页保存后无需重启即可生效。
@MainActor
protocol BarkConfigProviding: AnyObject {
    var bark: BarkConfig? { get }
}

@MainActor
final class BarkQuotaNotifier: @preconcurrency QuotaUpdateNotifying {
    static let testNotificationID = "llmmonitor-test-push"

    private let configProvider: BarkConfigProviding
    private let screenIsLocked: () -> Bool
    /// 所有推送经共享串行队列发出：有界积压 + 冷却 + 有限重试。
    private let sendQueue: BarkSendQueue

    init(
        configProvider: BarkConfigProviding,
        screenIsLocked: @escaping () -> Bool = BarkQuotaNotifier.defaultScreenIsLocked,
        sendQueue: BarkSendQueue = BarkSendQueue()
    ) {
        self.configProvider = configProvider
        self.screenIsLocked = screenIsLocked
        self.sendQueue = sendQueue
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

        // 用户选择「非锁屏时跳过」且当前会话未锁屏时，直接跳过推送。
        if bark.skipWhenUnlocked ?? false, !screenIsLocked() {
            logDebug("[bark] 会话未锁屏，按配置跳过 \(providerID) Bark 推送")
            return
        }

        for group in barkGroups {
            let body = group.barkLines.joined(separator: "\n")
            guard let url = Self.buildURL(
                config: bark,
                providerName: providerName,
                body: body,
                notificationID: group.barkNotificationID
            ) else {
                logWarn("[bark] \(providerName)/\(group.displayName) 推送 URL 构造失败或超长，跳过")
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let operation = BarkSendQueue.Operation(
                request: request,
                cooldownKey: group.barkNotificationID,
                label: "\(providerName)/\(group.displayName)",
                eventCount: group.barkEvents.count
            )
            Task { await sendQueue.enqueue(operation) }
        }
    }

    /// 设置页测试推送：与正式推送走同一套配置规范化、URL 构造和锁屏策略，
    /// 仅绕过发送队列的冷却（允许连续点击验证）。返回面向用户的提示文案。
    static func sendTestPush(
        config draft: BarkConfig,
        session: URLSession = .shared,
        screenIsLocked: @escaping () -> Bool = BarkQuotaNotifier.defaultScreenIsLocked
    ) async -> String {
        let config = draft.normalized
        guard config.enabled, config.isComplete else {
            return "请先填写服务端地址和 Device Key"
        }
        if config.skipWhenUnlocked ?? false, !screenIsLocked() {
            return "当前未锁屏，已按「非锁屏时跳过推送」跳过本次测试；配置本身无误。"
        }
        guard let url = buildURL(
            config: config,
            providerName: "LLM Monitor",
            body: "这是一条测试推送 🎉",
            notificationID: testNotificationID
        ) else {
            return "URL 构造失败：请检查服务端地址（支持 https 或本机 http）"
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
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

    /// macOS 会话锁屏状态。`CGSessionCopyCurrentDictionary` 返回当前登录会话
    /// 的字典，`kCGSSessionScreenIsLocked` 在锁屏（含屏保锁定）时为 true。
    nonisolated static func defaultScreenIsLocked() -> Bool {
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

    // MARK: - URL 构造

    /// 拼接 `GET {server}/{key}/{title}/{body}` 形式的推送 URL。
    ///
    /// - 保留自建服务 server URL 里的 base path（如 `https://example.com/bark`），
    ///   反向代理子路径部署也能工作；
    /// - 路径段逐段 percent-encode（不含段内 `/`），经 `percentEncodedPath`
    ///   写入避免 URLComponents 对 `%` 二次编码；
    /// - scheme 仅允许 https（本机调试允许 http）；
    /// - `id` 使用稳定字符串：相同 id 的新推送覆盖手机上的旧通知（需 Bark
    ///   v1.5.2+ / bark-server v2.2.5+）；`group` 取用户配置，留空则不携带。
    nonisolated private static let pathSegmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    nonisolated static func buildURL(
        config rawConfig: BarkConfig,
        providerName: String,
        body: String,
        notificationID: String? = nil
    ) -> URL? {
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

        // 保留 server URL 的 base path（去掉尾部斜杠）再拼接推送段。
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let segments = [config.deviceKey, providerName, body]
            .map { $0.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? $0 }
        components.percentEncodedPath = basePath + "/" + segments.joined(separator: "/")

        var queryItems: [URLQueryItem] = []
        if let sound = config.sound, !sound.isEmpty {
            queryItems.append(URLQueryItem(name: "sound", value: sound))
        }
        if let group = config.group, !group.isEmpty {
            queryItems.append(URLQueryItem(name: "group", value: group))
        }
        if let notificationID, !notificationID.isEmpty {
            queryItems.append(URLQueryItem(name: "id", value: notificationID))
        }
        components.queryItems = queryItems

        // Bark 官方文档限制推送 URL 长度（含 query）在 2048 以内。
        guard let url = components.url, url.absoluteString.count <= 2048 else { return nil }
        return url
    }
}

/// 串行发送队列：避免多模型同轮事件 / 短刷新间隔 / 阈值反复波动造成的请求
/// 突发。单并发 + 有界积压 + 每个 notificationID 的冷却窗口 + 瞬时错误一次
/// 重试。sends 都是短 GET，不做任务取消。
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
            pending.removeFirst()
            logWarn("[bark] 发送队列积压超过 \(Self.maximumPending)，丢弃最旧的推送")
        }
        Task { await self.drain() }
    }

    private func isCoolingDown(_ key: String) -> Bool {
        guard let last = lastSentAt[key] else { return false }
        return Date().timeIntervalSince(last) < Self.cooldownInterval
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty {
            let operation = pending.removeFirst()
            if let key = operation.cooldownKey {
                lastSentAt[key] = Date()
            }
            await Self.send(operation, session: session)
        }
    }

    private nonisolated static func send(_ operation: Operation, session: URLSession) async {
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
                logInfo("[bark] 已发送 \(operation.label) 的 Bark 推送（\(operation.eventCount) 个事件合并）")
                return
            } catch is CancellationError {
                return
            } catch {
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
