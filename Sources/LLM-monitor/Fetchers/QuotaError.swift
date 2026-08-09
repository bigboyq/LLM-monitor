import Foundation

/// 所有 fetcher 共用的错误类型
enum QuotaError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, body: String)
    case decodingError(String)
    case networkError(String)

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
                return "Antigravity 登录已失效，请重新启动 Antigravity 并完成登录"
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
