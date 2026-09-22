import Foundation

// MARK: - Request Bodies

/// `GetUserStatus` 的 request body —— 单 metadata 块，固定字段。
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

/// `GetCascadeTrajectoryGeneratorMetadata` 的 request body。
/// - `includeMessages: false`：避免服务端序列化并回传长会话消息正文。
/// - `generatorMetadataOffset`：后缀增量拉取偏移量（基于已入账的 generatorMetadata 条目数），
///   nil 时拉取完整列表。
struct TrajectoryMetadataRequest: Encodable, Equatable {
    let cascadeId: String
    let includeMessages: Bool
    let generatorMetadataOffset: Int?

    init(cascadeId: String, includeMessages: Bool = false, generatorMetadataOffset: Int? = nil) {
        self.cascadeId = cascadeId
        self.includeMessages = includeMessages
        self.generatorMetadataOffset = generatorMetadataOffset
    }
}

// MARK: - Response Models

struct LoadCodeAssistEnvelope: Decodable {
    let response: LoadCodeAssistResponse
}

struct LoadCodeAssistResponse: Decodable {
    let currentTier: LoadCodeAssistTier?
}

struct LoadCodeAssistTier: Decodable {
    let id: String?
    let name: String?
}

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

struct RetrieveUserQuotaSummaryEnvelope: Decodable {
    let response: RetrieveUserQuotaSummaryResponse
}

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

