import Foundation

// MARK: - Response Models

/// 远端 `v1internal:loadCodeAssist` 响应（无本地 RPC 的 `response` 包装）。
///
/// 阶段一起额度路径的 tier 只来自该接口：`currentTier.name` 优先，回退
/// `paidTier.name` / `paidTier.id`。本地 RPC `GetUserStatus` 的
/// `planStatus.planInfo` 细节展示名（planDisplayName / productName 等）在远端
/// 无对应字段，planLabel 回退链相应缩短为上面三级。
struct LoadCodeAssistRemoteResponse: Decodable {
    let currentTier: LoadCodeAssistTier?
    let paidTier: LoadCodeAssistTier?

    /// tier 名称解析（首个非空 trimmed 值生效）：
    /// `currentTier.name` > `paidTier.name` > `paidTier.id`。
    var tierName: String? {
        StringUtilities.firstTrimmed(currentTier?.name, paidTier?.name, paidTier?.id)
    }
}

struct LoadCodeAssistTier: Decodable {
    let id: String?
    let name: String?
}

/// 远端 `v1internal:retrieveUserQuotaSummary` 响应体：`{groups: [...]}`。
/// 与本地 RPC 同形，但**没有** `response` 包装（2026-11-08 实测）。
struct RetrieveUserQuotaSummaryResponse: Decodable {
    let groups: [QuotaGroup]
}

struct QuotaGroup: Decodable {
    let displayName: String
    let description: String?
    let buckets: [QuotaBucket]
}

struct QuotaBucket: Decodable {
    let bucketId: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: Date?
}

final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              ["127.0.0.1", "localhost"].contains(challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
