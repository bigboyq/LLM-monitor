import Foundation
import CoreGraphics

/// 通过自建或官方 Bark 服务器把额度事件推送到 iPhone。
/// 复用系统通知的文案生成逻辑，保持两端提示一致。
///
/// 合并规则：一次刷新里同一个模型的多个事件合并为一条推送，渠道取该模型
/// 全部事件渠道的并集（任一事件配了 Bark 就推送）。
///
/// 配置读取器抽象：Bark 开关保存在 ConfigStore 里，但通知发生在刷新路径，
/// 每次发送前实时读取，用户在设置页保存后无需重启即可生效。
@MainActor
protocol BarkConfigProviding: AnyObject {
    var bark: BarkConfig? { get }
}

@MainActor
final class BarkQuotaNotifier: @preconcurrency QuotaUpdateNotifying {
    /// Bark 官方文档限制推送 URL 长度（含 query）在 2048 以内。
    nonisolated private static let maximumURLLength = 2048

    private let configProvider: BarkConfigProviding
    private let session: URLSession
    /// 锁屏状态探测，测试注入。
    private let screenIsLocked: () -> Bool

    init(
        configProvider: BarkConfigProviding,
        session: URLSession = .shared,
        screenIsLocked: @escaping () -> Bool = BarkQuotaNotifier.defaultScreenIsLocked
    ) {
        self.configProvider = configProvider
        self.session = session
        self.screenIsLocked = screenIsLocked
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

        // 模型级合并：同一模型的事件合成一条推送，渠道取并集。
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
            send(
                config: bark,
                providerName: providerName,
                model: group.displayName,
                body: group.lines.joined(separator: "\n"),
                notificationID: group.barkNotificationID,
                eventCount: group.events.count
            )
        }
    }

    private func send(
        config: BarkConfig,
        providerName: String,
        model: String,
        body: String,
        notificationID: String,
        eventCount: Int
    ) {
        guard let url = Self.buildURL(
            config: config,
            providerName: providerName,
            body: body,
            notificationID: notificationID
        ) else {
            logWarn("[bark] 推送 URL 构造失败或超长，跳过 \(model) 的 Bark 推送")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        Task { [session] in
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    logWarn("[bark] Bark 推送返回非 HTTP 响应（\(model)）")
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
                    logWarn("[bark] Bark 推送失败: HTTP \(http.statusCode) \(detail)（\(model)）")
                    return
                }
                logInfo("[bark] 已发送 \(model) 的 Bark 推送（\(eventCount) 个事件合并）")
            } catch is CancellationError {
                // 外部取消不算失败。
            } catch {
                logWarn("[bark] Bark 推送请求失败: \(error.localizedDescription)（\(model)）")
            }
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
    private var effectiveConfig: BarkConfig? {
        guard let bark = configProvider.bark, bark.enabled else { return nil }
        let server = bark.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = bark.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !key.isEmpty else { return nil }
        return bark
    }

    /// 拼接 `GET {server}/{key}/{title}/{body}` 形式的推送 URL。路径段逐段
    /// percent-encode（不含段内 `/`），通过 `percentEncodedPath` 写入避免
    /// URLComponents 对 `%` 二次编码；文案里的 `→`、换行、空格都能安全传输。
    ///
    /// `id` 使用稳定字符串：相同 id 的新推送会覆盖手机上的旧通知（需 Bark
    /// v1.5.2+ / bark-server v2.2.5+）。`group` 取用户配置，留空则不携带。
    nonisolated private static let pathSegmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    nonisolated static func buildURL(
        config: BarkConfig,
        providerName: String,
        body: String,
        notificationID: String? = nil
    ) -> URL? {
        guard var components = URLComponents(string: config.serverURL) else { return nil }
        // 相对引用（如 "not a url"）也能被 URLComponents 解析；这里要求
        // scheme + host 齐全才算合法的 Bark 服务端。
        guard components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else {
            return nil
        }
        let segments = [config.deviceKey, providerName, body]
            .map { $0.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? $0 }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        var queryItems: [URLQueryItem] = []
        if let sound = config.sound?.trimmingCharacters(in: .whitespacesAndNewlines), !sound.isEmpty {
            queryItems.append(URLQueryItem(name: "sound", value: sound))
        }
        if let group = config.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            queryItems.append(URLQueryItem(name: "group", value: group))
        }
        if let notificationID, !notificationID.isEmpty {
            queryItems.append(URLQueryItem(name: "id", value: notificationID))
        }
        components.queryItems = queryItems
        guard let url = components.url, url.absoluteString.count <= maximumURLLength else { return nil }
        return url
    }
}
