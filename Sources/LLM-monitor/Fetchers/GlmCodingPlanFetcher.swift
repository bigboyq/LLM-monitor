import Foundation

/// GLM Coding Plan 额度抓取器
///
/// 调智谱 GLM Coding Plan 的内部监控接口（与官方 zai-coding-plugins 同源）：
///   GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
///
/// 鉴权：Coding Plan Key 直接放进 `Authorization` 请求头（裸 token，无 `Bearer` 前缀），
/// 与 Anthropic / OpenAI 协议接入用的同一个 key（格式 `<id>.<secret>`）。
///
/// 响应 schema（实测）：
/// {
///   "code": 200,                  // 业务码；200 = 成功
///   "msg": "Operation successful",
///   "success": true,
///   "data": {
///     "level": "lite",            // 套餐档位：lite / pro / max
///     "limits": [
///       { "type":"CREDIT_LIMIT", "unit":3, "number":5,
///         "usage":2000,           // 窗口总积分（Lite 5h = 2000）
///         "currentValue":114,      // 已用
///         "remaining":1885,        // 剩余
///         "percentage":5,          // 已用百分比（注意：是 used，不是 remaining）
///         "nextResetTime":1785486276273 },   // 毫秒时间戳
///       { "type":"CREDIT_LIMIT", "unit":6, "number":1,
///         "usage":10000, ... "nextResetTime":1786072666998 }   // 周窗口（Lite = 10000）
///     ]
///   }
/// }
///
/// **业务级错误**：智谱监控接口的错误（含鉴权失败）走 HTTP 200 + body `code`。
/// 例如 Key 无效时返回 `{ "code": 1000, "msg": "身份验证失败。", "success": false }`，
/// HTTP 状态仍是 200 —— 因此必须在 parse 阶段检查 `code`，不能只看 HTTP 2xx。
///
/// **窗口识别**：优先使用接口返回的稳定窗口标识：`unit=3, number=5` 是 5h，
/// `unit=6, number=1` 是周窗口。`nextResetTime` 只作为旧响应或标识缺失时的回退；
/// 周窗口刚好跨过重置点时，它的下次重置时间可能反而早于 5h 窗口，不能单独依赖时间排序。
struct GlmCodingPlanFetcher: QuotaFetcher {
    let providerID = "glm_coding_plan"
    let displayName = "GLM Coding Plan"
    let kind: ProviderKind = .glmCodingPlan
    /// 短 log tag，`[glm_coding_plan]` 太长，统一用 `[glm]`，同时作为 static 供 parse 用。
    static let logTag = "[glm]"
    var logTag: String { Self.logTag }

    private let apiKey: String
    private let endpoint: URL
    private let client: HTTPClient

    init(apiKey: String,
         endpoint: URL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!,
         session: URLSession = .shared) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = HTTPClient(session: session, logTag: Self.logTag, defaultTimeout: HTTPTimeouts.request)
    }

    func hasLocalAuth() -> Bool {
        // Coding Plan Key 存在 config.json 的 apiKey 字段，不由 fetcher 自管；
        // AppState 用 config.usableAPIKey 判断 ready，这里始终返回 true。
        return true
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        guard !apiKey.isEmpty else { throw QuotaError.missingAPIKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        // Coding Plan Key 作为裸 token 直接放进 Authorization（无 Bearer），与官方插件一致。
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 不打印 key —— 长度足够诊断（"auth set, key len=N"）。
        logDebug("\(logTag) Authorization header set, key length=\(apiKey.count)")

        // 非 2xx 响应体可能带诊断数据，只记录状态与字节数（由 HTTPClient 统一处理）。
        let (data, _) = try await client.send(req, includeBodyInError: false)
        try Task.checkCancellation()

        return try Self.parse(data: data)
    }

    // MARK: - 响应解析

    static func parse(data: Data, now: Date = Date()) throws -> QuotaInfo {
        logInfo("\(logTag) parse: \(data.count) bytes")

        let decoder = JSONDecoder()
        let response: GlmQuotaResponse
        do {
            response = try decoder.decode(GlmQuotaResponse.self, from: data)
        } catch {
            logError("\(logTag) JSON 解析失败: \(error.localizedDescription)")
            throw QuotaError.decodingError("GLM Coding Plan 返回的 JSON 无法解析")
        }

        // 业务码检查：智谱监控接口的错误（含鉴权失败）走 HTTP 200 + body code。
        guard response.code == 200 else {
            let code = response.code ?? -1
            let msg = response.msg ?? "unknown"
            if code == 1000 {
                logError("\(logTag) 身份验证失败: code=\(code)")
                // 401 语义对用户最直观（Key 无效 / 过期），即便传输层是 200。
                throw QuotaError.httpError(status: 401, body: "Coding Plan Key 无效或已过期（\(msg)）")
            }
            logError("\(logTag) 业务错误: code=\(code), msg=\(msg)")
            throw QuotaError.decodingError("GLM Coding Plan 返回错误 [\(code)]: \(msg)")
        }

        guard let payload = response.data else {
            throw QuotaError.decodingError("响应缺少 data")
        }

        let model = try buildModelQuota(from: payload, now: now)

        // 套餐档位 → pill（lite→Lite / pro→Pro / max→Max）
        let rawLevel = payload.level?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let planLabel = rawLevel.isEmpty ? nil : rawLevel.capitalized

        logInfo("\(logTag) parse 成功：level=\(rawLevel), 5h=\(model.intervalRemainingPercent)%, 周=\(model.weeklyRemainingPercent)%")
        return QuotaInfo(
            models: [model],
            resetCredits: nil,
            planLabel: planLabel,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    /// 把 `data.limits` 里的两条 CREDIT_LIMIT 聚合到一个 `ModelQuota`（5h + 周双窗口）。
    private static func buildModelQuota(from data: GlmQuotaData, now: Date) throws -> ModelQuota {
        let creditLimits = (data.limits ?? []).filter {
            $0.type == "CREDIT_LIMIT" && ($0.usage ?? 0) > 0
        }
        guard !creditLimits.isEmpty else {
            logError("\(logTag) 未返回任何 CREDIT_LIMIT")
            throw QuotaError.decodingError("GLM Coding Plan 未返回任何有效积分额度")
        }

        let (intervalLimit, weeklyLimit) = classifyWindows(creditLimits)

        let interval = try window(from: intervalLimit)

        let weekly: (total: Int, used: Int, remainingPercent: Double, resetsAt: Date?)?
        if let weeklyLimit {
            weekly = try window(from: weeklyLimit)
        } else {
            weekly = nil
        }

        // 某些响应在 5h 窗口没有使用记录时不返回 nextResetTime。仍需给本地
        // token 窗口一个明确边界，否则 summary 会把整个缓存样本集当成最近 5h。
        let intervalResetsAt = interval.resetsAt ?? now.addingTimeInterval(5 * 3600)

        return ModelQuota(
            modelName: "glm_coding_plan",
            intervalTotalCount: interval.total,
            intervalUsageCount: interval.used,
            intervalRemainingPercent: interval.remainingPercent,
            intervalStatus: .present,
            intervalResetsAt: intervalResetsAt,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: weekly?.total ?? 0,
            weeklyUsageCount: weekly?.used ?? 0,
            weeklyRemainingPercent: weekly?.remainingPercent ?? 0,
            weeklyStatus: weekly == nil ? .absent : .present,
            weeklyResetsAt: weekly?.resetsAt,
            weeklyWindowSeconds: 7 * 86_400
        )
    }

    /// 使用服务端的窗口元数据分类。只有在元数据不完整或出现未知值时，
    /// 才回退到 reset time，兼容旧版本接口响应。
    private static func classifyWindows(
        _ limits: [GlmQuotaLimit]
    ) -> (interval: GlmQuotaLimit, weekly: GlmQuotaLimit?) {
        let intervalByMetadata = limits.first { $0.unit == 3 && $0.number == 5 }
        let weeklyByMetadata = limits.first { $0.unit == 6 && $0.number == 1 }

        if let intervalByMetadata,
           let weeklyByMetadata,
           intervalByMetadata.nextResetTime != weeklyByMetadata.nextResetTime {
            return (intervalByMetadata, weeklyByMetadata)
        }

        // 两条窗口都没有 reset time 时，排序只能退回稳定的输入顺序。
        // 兼容旧响应：没有可识别元数据时，按 reset time 推断。
        let sorted = limits.sorted {
            ($0.nextResetTime ?? Int.max) < ($1.nextResetTime ?? Int.max)
        }
        return (sorted[0], sorted.count > 1 ? sorted.last : nil)
    }

    /// 解析单条 CREDIT_LIMIT 为 (总 / 已用 / 剩余百分比 / 重置时间)。
    /// `percentage` 字段是"已用百分比"，这里不直接用 —— 按 `remaining / usage` 重算
    /// "剩余百分比"以跟 dashboard 一致并避免取整误差。
    private static func window(
        from limit: GlmQuotaLimit
    ) throws -> (total: Int, used: Int, remainingPercent: Double, resetsAt: Date?) {
        let total = limit.usage ?? 0
        let used = limit.currentValue ?? 0
        // remaining 缺失时退回 total - used；服务端取整可能让 remaining 与 total-used 差 1，
        // 这属正常。Coding Plan 按任务扣积分，单个任务可能让 currentValue 超过窗口
        // 的 nominal usage（例如 total=2000、used=2011、remaining=0），这应显示为
        // 0% 可用，而不是让整个 provider 刷新失败。
        let remaining = limit.remaining ?? max(total - used, 0)

        guard total > 0, used >= 0, remaining >= 0 else {
            throw QuotaError.decodingError(
                "GLM Coding Plan 积分额度字段非法: total=\(total), used=\(used), remaining=\(remaining)"
            )
        }

        if used > total {
            logWarn("\(logTag) 积分已超出 nominal total，按 0% 可用处理: total=\(total), used=\(used), remaining=\(remaining)")
        }
        guard remaining <= total else {
            throw QuotaError.decodingError(
                "GLM Coding Plan 积分额度字段非法: total=\(total), used=\(used), remaining=\(remaining)"
            )
        }

        let pct = used > total
            ? 0
            : min(max(Double(remaining) / Double(total) * 100, 0), 100)
        let resetsAt = limit.nextResetTime.flatMap(DateParser.parseMsTimestamp)
        return (total, used, pct, resetsAt)
    }
}

// MARK: - Response models (Decodable)

/// `/api/monitor/usage/quota/limit` 顶层响应。所有字段 optional —— 业务级错误（code != 200）
/// 不会带 `data`；字段类型变化交给下面的显式校验，而非静默降级。
struct GlmQuotaResponse: Decodable {
    let code: Int?
    let msg: String?
    let success: Bool?
    let data: GlmQuotaData?
}

struct GlmQuotaData: Decodable {
    let level: String?
    let limits: [GlmQuotaLimit]?
}

/// 单条额度窗口。JSON 键已是 camelCase（`nextResetTime` / `currentValue`），无需 CodingKeys。
struct GlmQuotaLimit: Decodable {
    let type: String?
    let unit: Int?
    let number: Int?
    /// 窗口总积分（注意：字段名叫 `usage`，实际是 total，不是已用量）
    let usage: Int?
    /// 已用积分
    let currentValue: Int?
    /// 剩余积分
    let remaining: Int?
    /// 已用百分比 [0, 100]（注意是 used，不是 remaining）
    let percentage: Int?
    /// 下次重置时间（毫秒时间戳）
    let nextResetTime: Int?
}
