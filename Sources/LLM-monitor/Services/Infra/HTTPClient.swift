import Foundation

/// R2: HTTP/RPC 响应体硬上限常量。
enum ResponseByteLimits {
    /// 标准 quota / 状态响应上限。
    static let standardQuota: Int = 8 * 1024 * 1024
    /// Antigravity trajectory metadata 响应上限（单 session 可能很大）。
    static let antigravityTrajectory: Int = 64 * 1024 * 1024
}

/// R2: per-task `URLSessionDataDelegate`：按下载流累计字节，Content-Length 超限
/// 提前拒绝、实际字节超限取消任务。
///
/// 注意：这些回调只在 completion-handler 系任务上投递；async
/// `session.data(for:delegate:)` 便捷 API 在当前系统上不投递 didReceive
/// response / data 内容回调（macOS 27 实测，URLProtocol 桩与真实网络均不触发），
/// 本 delegate 的计数实际不会执行。真正生效的上限是 `CappedDownloader.data`
/// 在响应体返回后的字节校验：超限抛错、不进入调用方解析链路。单次响应的
/// 峰值内存仍由 URLSession 缓冲决定，该校验只保证超限响应不进入解析链路；
/// 要真正约束峰值需改用回调系任务 + delegate 流式计数（本 delegate 已保留
/// 待该用途）。
///
/// Content-Length 只用于“提前拒绝”（didReceive response 阶段），不能代替实际字节
/// 累计——服务端可能伪造或省略 Content-Length，也可能分块超限。保留本 delegate
/// 以便将来改用回调系任务时恢复流式计数。
final class CappedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maxBytes: Int
    let redactedPath: String
    var receivedBytes: Int = 0
    /// 实际累计字节超过上限（didReceive data 阶段触发）。
    var overflowed = false
    /// Content-Length 声明已超上限（didReceive response 阶段提前拒绝）。
    var declaredTooLarge = false

    init(maxBytes: Int, redactedPath: String) {
        self.maxBytes = maxBytes
        self.redactedPath = redactedPath
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // 提前拒绝：Content-Length 只做 advisory early reject。
        if let http = response as? HTTPURLResponse,
           http.expectedContentLength > maxBytes {
            declaredTooLarge = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        if receivedBytes > maxBytes {
            overflowed = true
            dataTask.cancel()
        }
    }

    // 注：不重写 willCacheResponse。当前 SDK 把该可选 requirement 声明为 async，
    // 同步实现只会“几乎匹配”并触发 warning，且实际不会被调用。R2 的字节计数上限
    // 完全由 didReceive response / didReceive data 保证，不依赖缓存控制。
}

enum CappedDownloader {
    /// 用给定 session 下载并施加 `maxBytes` 硬上限，超限抛 `responseTooLarge`。
    ///
    /// 实际生效的保证是响应体返回后的字节校验：async `session.data(for:delegate:)`
    /// 不向 per-task delegate 投递内容回调（见 `CappedDownloadDelegate` 注释），
    /// delegate 的流式计数/取消不会执行，超限响应体在返回后立即抛错，不进入
    /// 调用方解析链路。单次响应的峰值内存仍由 URLSession 缓冲决定，本校验只
    /// 保证超限响应不进入解析链路；要真正约束峰值需改用回调系任务 + delegate
    /// 流式计数（delegate 已保留待该用途）。
    ///
    /// `redactedPath` 仅用于错误日志与错误对象，不含 userinfo/query。
    static func data(
        for request: URLRequest,
        session: URLSession,
        maxBytes: Int,
        redactedPath: String
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = CappedDownloadDelegate(maxBytes: maxBytes, redactedPath: redactedPath)
        let data: Data
        let http: HTTPURLResponse
        do {
            let (payload, response) = try await session.data(for: request, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw QuotaError.invalidResponse
            }
            data = payload
            http = httpResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // 我们的 overflow / declaredTooLarge 取消 vs Task 真取消，用 delegate 标志区分。
            if delegate.overflowed || delegate.declaredTooLarge {
                logError("[http] 响应过大：上限 \(maxBytes) bytes，实际 \(delegate.receivedBytes) bytes，\(redactedPath)")
                throw QuotaError.responseTooLarge(
                    limit: maxBytes,
                    actual: delegate.receivedBytes,
                    redactedPath: redactedPath
                )
            }
            throw error
        } catch let error as URLError {
            throw error
        } catch {
            let description = HTTPRequestLogSanitizer.networkErrorDescription(error)
            throw QuotaError.networkError(description)
        }
        // 后置字节校验：这是 async data(for:delegate:) 路径上实际生效的上限。
        guard data.count <= maxBytes else {
            logError("[http] 响应过大：上限 \(maxBytes) bytes，实际 \(data.count) bytes，\(redactedPath)")
            throw QuotaError.responseTooLarge(
                limit: maxBytes,
                actual: data.count,
                redactedPath: redactedPath
            )
        }
        return (data, http)
    }
}

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
    /// R2: 响应体硬上限（字节）。标准 quota 默认 8 MiB。
    let maxResponseBytes: Int

    /// - Parameters:
    ///   - session: URLSession 实例（生产用 `.shared`，测试可注入 mock）
    ///   - logTag: 日志前缀，例如 `"[minimax]"`、`"[codex/usage]"`，HTTPClient 不附加额外方括号
    ///   - defaultTimeout: 强制套用的超时（秒），fetcher 即使 set 了 timeout 也会被覆盖
    ///   - maxResponseBytes: 响应体硬上限，默认 8 MiB
    init(
        session: URLSession,
        logTag: String,
        defaultTimeout: TimeInterval = 15,
        maxResponseBytes: Int = ResponseByteLimits.standardQuota
    ) {
        self.session = session
        self.logTag = logTag
        self.defaultTimeout = defaultTimeout
        self.maxResponseBytes = maxResponseBytes
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

        // R2: 响应体套用硬上限（返回后校验，见 CappedDownloader）：超限响应不
        // 进入解析链路；单次响应的峰值内存仍由 URLSession 缓冲决定。
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await CappedDownloader.data(
                for: request,
                session: session,
                maxBytes: maxResponseBytes,
                redactedPath: url
            )
        } catch is CancellationError {
            // Task 取消（如配置变更、停止刷新、窗口关闭）—— 不当 network error，
            // 透传给上层让 AppState 走 deferred 路径，不进 failure 计数。
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession 自己把请求 cancel 也是同样语义。
            throw error
        } catch let error as QuotaError {
            // responseTooLarge / invalidResponse 已经带好脱敏信息，直接透传。
            throw error
        } catch {
            let description = HTTPRequestLogSanitizer.networkErrorDescription(error)
            logError("\(logTag) 网络错误: \(description)")
            throw QuotaError.networkError(description)
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
