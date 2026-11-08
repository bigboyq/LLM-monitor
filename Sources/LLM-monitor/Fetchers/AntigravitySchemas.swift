import Foundation

// MARK: - Local RPC Models（2.4.2 回退路径）

/// 本地 RPC `GetUserStatus` 的 request body —— 单 metadata 块，固定字段。
/// 用 struct（而不是 `[String: Any]` 字典）让 Encodable 路径走 compile-time check。
struct UserStatusRequest: Encodable {
    struct Metadata: Encodable {
        let ideName: String
        let extensionName: String
        let ideVersion: String
        let locale: String
    }

    let metadata: Metadata
}

/// 本地 RPC `RetrieveUserQuotaSummary` 响应：带 `response` 包装
/// （远端同名接口没有这层包装，2026-11-08 实测）。
struct RetrieveUserQuotaSummaryEnvelope: Decodable {
    let response: RetrieveUserQuotaSummaryResponse
}

/// 本地 RPC `GetLoadCodeAssist` 响应：带 `response` 包装；
/// 内层复用远端模型（只消费 `currentTier.name` 作为 tier 回退链末位）。
struct LoadCodeAssistLocalEnvelope: Decodable {
    let response: LoadCodeAssistRemoteResponse
}

/// 本地 RPC `GetUserStatus` 响应（账号邮箱 + tier 回退链前六级）。
struct UserStatusEnvelope: Decodable {
    let userStatus: UserStatus?
}

struct UserStatus: Decodable {
    let email: String?
    let userTier: UserTier?
    let planStatus: PlanStatus?
}

struct UserTier: Decodable {
    let name: String?
}

struct PlanStatus: Decodable {
    let planInfo: PlanInfo?
}

struct PlanInfo: Decodable {
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planName: String?
    let planShortName: String?

    init(planDisplayName: String? = nil,
         displayName: String? = nil,
         productName: String? = nil,
         planName: String? = nil,
         planShortName: String? = nil) {
        self.planDisplayName = planDisplayName
        self.displayName = displayName
        self.productName = productName
        self.planName = planName
        self.planShortName = planShortName
    }
}

// MARK: - Response Models

/// 远端 `v1internal:loadCodeAssist` 响应（无本地 RPC 的 `response` 包装）。
///
/// 阶段一起额度主路径的 tier 只来自该接口：`currentTier.name` 优先，回退
/// `paidTier.name` / `paidTier.id`。2.4.2 起本地 RPC 回退路径复用本模型作为
/// `LoadCodeAssistLocalEnvelope.response`（回退链末位只取 `currentTier.name`，
/// 对齐旧 GetLoadCodeAssist 契约）；本地 `GetUserStatus` 的
/// `planStatus.planInfo` 细节展示名仅存在于回退路径的 GetUserStatus 解析。
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
