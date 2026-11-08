import Foundation

/// 所有 fetcher 共用的错误类型
enum QuotaError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, body: String)
    case decodingError(String)
    case networkError(String)
    case apiError(String)
    /// Antigravity 额度路径专有：Keychain 凭据里的 access_token 已过本地过期判定
    /// （`now >= expiry`），或远端配额接口对有效请求返回 401，或本地回退路径
    /// （2.4.2 起 keychain 过期/缺失时回退本地 language_server RPC）也失败。
    /// 落到同一提示：打开 Antigravity 可继续监控额度（IDE 运行期间经 host bridge
    /// 分发的新凭据在 language_server 内存中，本地回退随之恢复），重新登录可刷新
    /// Keychain 内 token。
    case credentialExpired
    /// R2: 响应体超过硬上限。只携带脱敏 endpoint 路径、上限和实测字节数，不含 body。
    case responseTooLarge(limit: Int, actual: Int, redactedPath: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key"
        case .invalidResponse:
            return "响应格式无效"
        case .httpError(let status, let body):
            let preview = String(body.prefix(200))
            // HTTPClient 的诊断摘要已经包含状态码，避免显示成“HTTP 503: HTTP 503...”。
            if preview.hasPrefix("HTTP \(status)") {
                return preview
            }
            return "HTTP \(status): \(preview)"
        case .decodingError(let msg):
            return "解析失败：\(msg)"
        case .networkError(let msg):
            return "网络错误：\(msg)"
        case .apiError(let msg):
            return "接口错误：\(msg)"
        case .credentialExpired:
            return "token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据"
        case .responseTooLarge(let limit, _, let redactedPath):
            return "响应过大（上限 \(limit) bytes）：\(redactedPath)"
        }
    }

    /// 将已知的鉴权失败翻译成用户可以直接执行的操作；其他错误保留统一错误文本。
    static func userFacingDescription(for error: Error, providerKind: ProviderKind) -> String {
        guard let quotaError = error as? QuotaError else {
            return error.localizedDescription
        }
        if case .httpError(status: 401, body: _) = quotaError {
            switch providerKind {
            case .codexChatGpt:
                return "Codex 登录已失效，请运行 codex login 后重试"
            case .antigravity:
                // 远端配额接口的 401 与本地过期判定（credentialExpired）落到同一
                // 提示：Keychain 凭据过期，由 Antigravity 客户端续期后恢复。
                return QuotaError.credentialExpired.localizedDescription
            case .minimaxTokenPlan:
                return "minimax API Key 无效或已过期"
            case .glmCodingPlan:
                return "GLM Coding Plan Key 无效或已过期"
            case .deepseek:
                return "DeepSeek API Key 无效或已过期"
            }
        }
        return quotaError.localizedDescription
    }
}
