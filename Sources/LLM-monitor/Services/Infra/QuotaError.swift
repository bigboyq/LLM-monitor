import Foundation

/// 所有 fetcher 共用的错误类型
enum QuotaError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, body: String)
    case decodingError(String)
    case networkError(String)
    case apiError(String)
    /// Antigravity 额度路径专有：2.5.0 凭据策略下所有「拿不到可用额度」的收口提示
    /// ——钥匙串兜底开关关闭（或预检自动 disable）、token 过期/缺失、autoRefresh
    /// 关闭、agy 刷新失败或刷新后仍无可用 token（退避期间同样落此提示）。
    /// 统一给出三条出路：打开 Antigravity（恢复本地路径 / 刷新凭据）、重新登录、
    /// 在终端运行 agy models 手动刷新。
    case credentialExpired
    /// Antigravity 额度路径专有：agy 刷新输出的 `invalid_grant` 类 OAuth 错误
    /// ——keychain 里的 refresh_token 已被服务端吊销，自动刷新不可恢复，用户必须
    /// 重新登录 Antigravity。
    case credentialReloginRequired
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
            return "无法获取 Antigravity 额度：打开 Antigravity 可继续监控额度，重新登录可刷新凭据，或在终端运行 agy models 手动刷新"
        case .credentialReloginRequired:
            return "Antigravity 凭据已失效（invalid_grant）：请重新登录 Antigravity"
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
