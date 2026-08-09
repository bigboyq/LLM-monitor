import Foundation

/// DeepSeek 余额抓取器
///
/// 调 DeepSeek 官方开放接口：
///   GET https://api.deepseek.com/user/balance
///
/// 鉴权：API Key 放进 `Authorization` Header（`Bearer <apiKey>`）
///
/// 响应 Schema：
/// {
///   "is_available": true,
///   "balance_infos": [
///     {
///       "currency": "CNY",
///       "total_balance": "100.00",
///       "granted_balance": "10.00",
///       "topped_up_balance": "90.00"
///     }
///   ]
/// }
struct DeepseekFetcher: QuotaFetcher {
    let providerID = "deepseek"
    let displayName = "DeepSeek"
    let kind: ProviderKind = .deepseek
    static let logTag = "[deepseek]"
    var logTag: String { Self.logTag }

    private let apiKey: String
    private let endpoint: URL
    private let client: HTTPClient

    init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.deepseek.com/user/balance")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = HTTPClient(session: session, logTag: Self.logTag, defaultTimeout: HTTPTimeouts.request)
    }

    func hasLocalAuth() -> Bool {
        return true
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw QuotaError.missingAPIKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        logDebug("\(logTag) Authorization header set, key length=\(trimmedKey.count)")

        let (data, _) = try await client.send(req, includeBodyInError: false)
        try Task.checkCancellation()

        return try Self.parse(data: data)
    }

    // MARK: - 响应解析

    static func parse(data: Data, now: Date = Date()) throws -> QuotaInfo {
        logInfo("\(logTag) parse: \(data.count) bytes")

        let decoder = JSONDecoder()
        let response: DeepseekBalanceResponse
        do {
            response = try decoder.decode(DeepseekBalanceResponse.self, from: data)
        } catch {
            logError("\(logTag) JSON 解析失败: \(error.localizedDescription)")
            throw QuotaError.decodingError("DeepSeek 返回的 JSON 无法解析")
        }

        let isAvailable = response.isAvailable ?? true
        let infoList = response.balanceInfos ?? []
        guard let mainInfo = infoList.first else {
            throw QuotaError.decodingError("DeepSeek 未返回任何余额条目")
        }

        let currency = mainInfo.currency ?? "CNY"
        let totalVal = try parseBalance(mainInfo.totalBalance, field: "total_balance")
        let grantedVal = try parseBalance(mainInfo.grantedBalance, field: "granted_balance")
        let toppedUpVal = try parseBalance(mainInfo.toppedUpBalance, field: "topped_up_balance")

        let remainingPercent: Double
        if !isAvailable || totalVal <= 0 {
            remainingPercent = 0
        } else {
            remainingPercent = 100
        }

        let model = ModelQuota(
            modelName: "deepseek_balance",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: remainingPercent,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: remainingPercent,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )

        let symbol = (currency.uppercased() == "USD") ? "$" : "¥"
        let formattedTotal = String(format: "%.2f", totalVal)
        let planLabel = "\(symbol)\(formattedTotal)"
        let detailMsg = "充值: \(symbol)\(String(format: "%.2f", toppedUpVal)) | 赠金: \(symbol)\(String(format: "%.2f", grantedVal))"

        return QuotaInfo(
            models: [model],
            resetCredits: nil,
            planLabel: planLabel,
            accountEmail: detailMsg,
            codexUsageDetails: nil,
            fetchedAt: now
        )
    }

    /// JSON numbers arrive as strings. Swift accepts spellings such as "NaN" and
    /// "inf" as `Double`, but those values cannot safely flow into percentage
    /// formatting and the integer conversions used by provider status logging.
    private static func parseBalance(_ rawValue: String?, field: String) throws -> Double {
        guard let rawValue else { return 0 }
        guard let value = Double(rawValue), value.isFinite else {
            throw QuotaError.decodingError("DeepSeek 返回了无效的 \(field)")
        }
        return value
    }
}

// MARK: - API 响应 Schema

struct DeepseekBalanceResponse: Codable, Sendable {
    let isAvailable: Bool?
    let balanceInfos: [DeepseekBalanceInfo]?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct DeepseekBalanceInfo: Codable, Sendable {
    let currency: String?
    let totalBalance: String?
    let grantedBalance: String?
    let toppedUpBalance: String?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}
