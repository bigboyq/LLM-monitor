import Foundation

enum HTTPRequestLogSanitizer {
    /// 日志只保留请求定位所需的 origin 与 path。userinfo、query 和 fragment 可能包含
    /// access token、session ID 或一次性凭据，任何情况下都不能进入日志。
    static func sanitizedURL(_ url: URL?) -> String {
        guard
            let url,
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = source.scheme,
            !scheme.isEmpty,
            let host = source.host,
            !host.isEmpty
        else {
            return "<invalid-url>"
        }

        var sanitized = URLComponents()
        sanitized.scheme = scheme
        sanitized.host = host
        sanitized.port = source.port
        sanitized.percentEncodedPath = source.percentEncodedPath
        return sanitized.string ?? "<invalid-url>"
    }

    /// 网络层的原始 localizedDescription 可能回显完整请求 URL。映射为稳定的中文
    /// 摘要，既避免泄露 userinfo/query，也避免把 Foundation 的数字错误码暴露给用户。
    static func networkErrorDescription(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "网络请求失败"
        }
        switch urlError.code {
        case .timedOut:
            return "请求超时"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析服务器地址"
        case .cannotConnectToHost:
            return "无法连接服务器"
        case .networkConnectionLost:
            return "网络连接中断"
        case .notConnectedToInternet:
            return "当前没有网络连接"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "安全连接失败"
        case .cancelled:
            return "请求已取消"
        default:
            return "网络请求失败"
        }
    }
}

/// 轻量 HTTP 请求层：集中 URLSession + timeout + 状态校验 + 日志。
///
/// 适用：标准 JSON-over-HTTPS 的 provider（minimax、codex）。
/// 不适用：Antigravity —— 它走本地 HTTPS + CSRF + 自定义 trust delegate + JSON body
/// 编码的 RPC 流程（AntigravityFetcher.rawPost/checkHTTP 维持原样）。
///
/// 抽象边界：
/// - HTTPClient 只负责"发出去、收回来、判状态"。
/// - schema 解析、敏感 header 脱敏日志（如 Bearer 前缀）由 fetcher 自己负责，
///   不放在 HTTPClient 里，避免 HTTPClient 去 peek request headers。
///
/// 设计动机（9-commit refactor #8）：
/// - 之前 MinimaxTokenPlanFetcher.fetch() 和 CodexFetcher.fetchUsage/ResetCredits
///   各自手写 URLSession.data → cast HTTPURLResponse → 2xx 检查 → log，
///   行为重复 ~30 行 × 3 处。
/// - 抽 HTTPClient 后，fetcher 退化成"构造 URLRequest + 解析 data"两步。
/// - 全局日志策略默认不记录 response body，因为其中可能含账号、凭据或诊断信息；
///   错误日志只输出 "HTTP 503，响应 1.2KB bytes" 摘要。
/// - 保留 `includeBodyInError` 作为显式诊断开关，但调用方只有在确认响应不含敏感
///   数据且确有排障需要时才能启用。
///
/// `URLSession` 本身是 thread-safe，HTTPClient 没有可变状态（logTag/defaultTimeout/session
/// 都是 init 时确定，init 之后不再修改），所以可以标记 `@unchecked Sendable`，
/// 让 QuotaFetcher: Sendable 的 fetcher 能持有它作为 stored property。
final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let logTag: String
    private let defaultTimeout: TimeInterval

    /// - Parameters:
    ///   - session: URLSession 实例（生产用 `.shared`，测试可注入 mock）
    ///   - logTag: 日志前缀，例如 `"[minimax]"`、`"[codex/usage]"`，HTTPClient 不附加额外方括号
    ///   - defaultTimeout: 强制套用的超时（秒），fetcher 即使 set 了 timeout 也会被覆盖
    init(session: URLSession, logTag: String, defaultTimeout: TimeInterval = 15) {
        self.session = session
        self.logTag = logTag
        self.defaultTimeout = defaultTimeout
    }

    /// 发送请求并校验 HTTP 状态。
    ///
    /// 行为：
    /// 1. 强制 `request.timeoutInterval = defaultTimeout`（避免 fetcher 漏设或设错）
    /// 2. 记录脱敏后的 `scheme://host[:port]/path`，不记录 userinfo/query/fragment
    /// 3. `URLSession.data(for:)` 失败 → `QuotaError.networkError`（logError）
    /// 4. 响应非 `HTTPURLResponse` → `QuotaError.invalidResponse`（logError）
    /// 5. `logInfo("\(logTag) HTTP \(status), \(bytes) bytes")`
    /// 6. 2xx → 返回 `(Data, HTTPURLResponse)`
    /// 7. 非 2xx → `QuotaError.httpError(status, body)`，body 内容由 `includeBodyInError` 决定
    ///
    /// - Parameter includeBodyInError:
    ///   - `false`（默认）：错误日志和 QuotaError.httpError.body 只包含
    ///     "HTTP 503，响应 1.2KB bytes" 摘要，不暴露原始 response body。
    ///   - `true`：显式诊断选项，错误日志和 QuotaError.httpError.body 会包含原始 body
    ///     前 500 字符。仅应在调用方确认响应不含敏感数据时临时启用。
    func send(
        _ request: URLRequest,
        includeBodyInError: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        // URLRequest 是 value type，按值传进来后是 let；改成本地 var 副本再修改 timeout
        var request = request
        // 强制覆盖 timeout：URLRequest 默认 60s，不主动收紧会变成 60s 超时
        request.timeoutInterval = defaultTimeout

        let method = request.httpMethod ?? "GET"
        let url = HTTPRequestLogSanitizer.sanitizedURL(request.url)
        logInfo("\(logTag) \(method) \(url)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            // Task 取消（如配置变更、停止刷新、窗口关闭）—— 不当 network error，
            // 透传给上层让 AppState 走 deferred 路径，不进 failure 计数。
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession 自己把请求 cancel 也是同样语义。
            throw error
        } catch {
            let description = HTTPRequestLogSanitizer.networkErrorDescription(error)
            logError("\(logTag) 网络错误: \(description)")
            throw QuotaError.networkError(description)
        }

        guard let http = response as? HTTPURLResponse else {
            logError("\(logTag) 响应非 HTTP")
            throw QuotaError.invalidResponse
        }

        logInfo("\(logTag) HTTP \(http.statusCode), \(data.count) bytes")

        guard (200..<300).contains(http.statusCode) else {
            let bodyText: String
            if includeBodyInError {
                let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
                bodyText = String(rawBody.prefix(500))
                logError("\(logTag) 错误响应体: \(bodyText)")
            } else {
                bodyText = "HTTP \(http.statusCode)，响应 \(data.count) bytes"
                logError("\(logTag) \(bodyText)")
            }
            throw QuotaError.httpError(status: http.statusCode, body: bodyText)
        }

        return (data, http)
    }
}
