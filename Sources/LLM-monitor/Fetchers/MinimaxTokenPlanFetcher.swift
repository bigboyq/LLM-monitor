import Foundation

/// minimax Token Plan 额度抓取器
///
/// 调 https://www.minimaxi.com/v1/token_plan/remains 拿到剩余额度
/// 响应 schema（实测）：
/// {
///   "model_remains": [
///     {
///       "start_time": 1783234800000,       // 毫秒
///       "end_time":   1783252800000,
///       "remains_time": 10629565,           // 毫秒，5h 窗口剩余
///       "current_interval_total_count": 0,  // 0 = 按量付费，无固定额度
///       "current_interval_usage_count": 0,
///       "model_name": "general",
///       "current_weekly_total_count": 0,
///       "current_weekly_usage_count": 0,
///       "weekly_start_time": 1782662400000,
///       "weekly_end_time":   1783267200000,
///       "weekly_remains_time": 25029565,
///       "current_interval_status": 1,       // 1 = 正常，2 = 有额度窗口但已耗尽
///       "current_interval_remaining_percent": 54,
///       "current_weekly_status": 1,
///       "current_weekly_remaining_percent": 64
///     },
///     { "model_name": "video", ... }
///   ],
///   "base_resp": { "status_code": 0, "status_msg": "success" }
/// }
struct MinimaxTokenPlanFetcher: QuotaFetcher {
    let providerID = "minimax_token_plan"
    let displayName = "minimax Token Plan"
    let kind: ProviderKind = .minimaxTokenPlan
    /// 短 log tag，`[minimax_token_plan]` 太长，统一用 `[minimax]`
    /// 同时作为 static，静态 parse 也能用。
    static let logTag = "[minimax]"
    var logTag: String { Self.logTag }

    private let apiKey: String
    private let endpoint: URL
    private let client: HTTPClient

    init(apiKey: String,
         endpoint: URL = URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!,
         session: URLSession = .shared) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = HTTPClient(session: session, logTag: Self.logTag, defaultTimeout: HTTPTimeouts.request)
    }

    func hasLocalAuth() -> Bool {
        // minimax 的 auth 在 config.json 的 apiKey 字段，不由 fetcher 自管
        // AppState 用 config.apiKey 判断 ready，这里始终返回 true
        return true
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        guard !apiKey.isEmpty else { throw QuotaError.missingAPIKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")  // ⚠️ 必须发完整 key
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 之前这里打印 `apiKey.prefix(8)`，即便前缀也可能被 release log 收集。
        // 现在完全不打印 key —— 长度 + scheme 足够诊断（"auth set, key len=N"）。
        // 如果需要排查 401 走 `logDebug` 即可，release 默认不输出。
        logDebug("\(logTag) Authorization header set, key length=\(apiKey.count)")

        // 非 2xx 响应体可能带账号/诊断数据，只记录状态与字节数。
        let (data, _) = try await client.send(req, includeBodyInError: false)
        try Task.checkCancellation()

        return try Self.parse(data: data)
    }

    // MARK: - 响应解析

    static func parse(data: Data) throws -> QuotaInfo {
        logInfo("\(logTag) parse: \(data.count) bytes")

        // JSONDecoder 会接受 `1.0` 这类可精确转成 Int 的浮点 token。额度计数
        // 属于服务端账本字段，不能静默截断或宽松转换；先从原始 JSON 类型严格
        // 审核四个 count 字段，再交给 Decodable 构造响应模型。
        try validateModelCountJSONTypes(data)

        // 1. 用 JSONDecoder 解码，跟 CodexFetcher/AntigravityFetcher 一致
        let decoder = JSONDecoder()
        let response: MinimaxResponse
        do {
            response = try decoder.decode(MinimaxResponse.self, from: data)
        } catch {
            logError("\(logTag) JSON 解析失败: \(error.localizedDescription)")
            throw QuotaError.decodingError("minimax 返回的 JSON 无法解析")
        }

        // 2. base_resp 检查（minimax 用 gRPC 风格，status_code=0 是成功）
        guard let baseResp = response.baseResp else {
            throw QuotaError.decodingError("响应缺少 base_resp")
        }
        guard let code = baseResp.statusCode else {
            throw QuotaError.decodingError("base_resp 缺少 status_code")
        }
        if code != 0 {
            let msg = baseResp.statusMsg ?? "unknown"
            logError("\(logTag) base_resp 错误: code=\(code), msg=\(msg)")
            if code == 1004 {
                throw QuotaError.httpError(status: 401, body: "minimax API Key 无效或已过期（\(msg)）")
            }
            throw QuotaError.decodingError("minimax 返回错误 [\(code)]: \(msg)")
        }
        logDebug("\(logTag) base_resp.status_code = 0 (成功)")

        // 3. model_remains 列表
        let entries = response.modelRemains
        logInfo("\(logTag) model_remains 共 \(entries.count) 条")

        // 单条 record 缺 `model_name` → 跳过这条（之前 JSONSerialization 走
        // `guard let modelName = ... else { continue }`，JSONDecoder 走 `compactMap`）
        var models: [ModelQuota] = []
        for entry in entries {
            guard let modelName = entry.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelName.isEmpty else {
                logWarn("\(logTag) 跳过缺少 model_name 的记录")
                continue
            }
            let intervalCounts = try validatedCounts(
                total: entry.intervalTotalCount,
                usage: entry.intervalUsageCount,
                fieldPrefix: "model_remains[\(modelName)].current_interval"
            )
            let weeklyCounts = try validatedCounts(
                total: entry.weeklyTotalCount,
                usage: entry.weeklyUsageCount,
                fieldPrefix: "model_remains[\(modelName)].current_weekly"
            )

            guard let intervalRemainingPercent = entry.intervalRemainingPercent,
                  intervalRemainingPercent.isFinite,
                  (0...100).contains(intervalRemainingPercent) else {
                throw QuotaError.decodingError(
                    "model_remains[\(modelName)] 缺少或包含非法 current_interval_remaining_percent"
                )
            }

            if let weeklyPercent = entry.weeklyRemainingPercent,
               (!weeklyPercent.isFinite || !(0...100).contains(weeklyPercent)) {
                throw QuotaError.decodingError(
                    "model_remains[\(modelName)] 包含非法 current_weekly_remaining_percent"
                )
            }

            // Minimax uses status=2 for a subscribed window whose remaining
            // quota has reached 0. ModelQuota uses .present to mean that the
            // window exists, so normalize the exhausted-but-present state here;
            // otherwise the UI incorrectly falls back to the weekly window.
            let intervalStatus = normalizedWindowStatus(entry.intervalStatus, defaultStatus: .present)
            let weeklyStatus = normalizedWindowStatus(
                entry.weeklyStatus,
                defaultStatus: entry.weeklyRemainingPercent == nil ? .absent : .present
            )
            if weeklyStatus.isPresent {
                guard let weeklyPercent = entry.weeklyRemainingPercent,
                      weeklyPercent.isFinite,
                      (0...100).contains(weeklyPercent) else {
                    throw QuotaError.decodingError(
                        "model_remains[\(modelName)] 声明周窗口有效，但缺少合法 current_weekly_remaining_percent"
                    )
                }
            }

            let m = ModelQuota(
                modelName: modelName,
                intervalTotalCount: intervalCounts.total,
                intervalUsageCount: intervalCounts.usage,
                intervalRemainingPercent: intervalRemainingPercent,
                intervalStatus: intervalStatus,
                intervalResetsAt: entry.endTime.flatMap(DateParser.parseMsTimestamp),
                intervalWindowSeconds: nil,
                weeklyTotalCount: weeklyCounts.total,
                weeklyUsageCount: weeklyCounts.usage,
                weeklyRemainingPercent: entry.weeklyRemainingPercent ?? 0,
                weeklyStatus: weeklyStatus,
                weeklyResetsAt: entry.weeklyEndTime.flatMap(DateParser.parseMsTimestamp),
                weeklyWindowSeconds: nil
            )
            logDebug("\(logTag)   - \(m.modelName): 5h=\(m.intervalRemainingPercent)%, 周=\(m.weeklyRemainingPercent)%, resetsAt=\(m.intervalResetsAt?.description ?? "nil")")
            models.append(m)
        }

        guard !models.isEmpty else {
            logError("\(logTag) model_remains 数组为空")
            throw QuotaError.decodingError("model_remains 数组为空")
        }

        logInfo("\(logTag) parse 成功：\(models.count) 个 model")
        return QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    /// Converts Minimax's raw window status into the shared presence status.
    /// Raw status 2 means the quota window is active but exhausted (0% left);
    /// raw status 3 and other non-active codes mean that the window is absent.
    private static func normalizedWindowStatus(
        _ rawStatus: Int?,
        defaultStatus: QuotaWindowStatus
    ) -> QuotaWindowStatus {
        guard let rawStatus else { return defaultStatus }
        switch rawStatus {
        case 1, 2:
            return .present
        default:
            return .absent
        }
    }


    /// 原始 JSON 数字类型检查。缺少 count 字段仍按历史兼容路径视为 0；
    /// 字段一旦出现，则只接受非负、Int 可表示的整数 token。
    private static func validateModelCountJSONTypes(_ data: Data) throws {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QuotaError.decodingError("minimax 返回的 JSON 无法解析")
        }
        guard let root = json as? [String: Any],
              let rawEntries = root["model_remains"] as? [Any] else {
            return // 结构错误交给下面的 JSONDecoder 给出统一错误。
        }

        let countKeys = [
            "current_interval_total_count",
            "current_interval_usage_count",
            "current_weekly_total_count",
            "current_weekly_usage_count",
        ]
        for (index, rawEntry) in rawEntries.enumerated() {
            guard let entry = rawEntry as? [String: Any] else { continue }
            // 无名记录按既有业务规则整体跳过；其中的无关脏字段不能让其他合法
            // model 的额度全部不可用。
            guard let modelName = entry["model_name"] as? String,
                  !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            for key in countKeys {
                guard let rawValue = entry[key] else { continue }
                guard strictNonnegativeJSONInteger(rawValue) != nil else {
                    throw QuotaError.decodingError(
                        "model_remains[#\(index)].\(key) 不是合法非负整数"
                    )
                }
            }
        }
    }

    private static func strictNonnegativeJSONInteger(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber,
              !DateParser.isBoolean(number) else {
            return nil
        }

        // JSONSerialization 用浮点 NSNumber 表示含小数点或指数的 number token；
        // 即使值恰好等于整数（1.0 / 1e0）也拒绝，避免 schema 漂移被隐藏。
        let type = String(cString: number.objCType)
        guard type != "f", type != "d", type != "D",
              let value = Int(number.stringValue),
              value >= 0 else {
            return nil
        }
        return value
    }

    private static func validatedCounts(
        total: Int?,
        usage: Int?,
        fieldPrefix: String
    ) throws -> (total: Int, usage: Int) {
        let total = total ?? 0
        let usage = usage ?? 0
        guard total >= 0, usage >= 0 else {
            throw QuotaError.decodingError("\(fieldPrefix) 计数必须为非负整数")
        }
        // total == 0 表示按量付费、没有固定额度，不对 usage 设置上限。
        guard total == 0 || usage <= total else {
            throw QuotaError.decodingError("\(fieldPrefix)_usage_count 超过固定 total")
        }
        return (total, usage)
    }
}

// MARK: - Response models (Decodable)

/// minimax `/v1/token_plan/remains` 顶层响应。
/// `Decodable` 让 `JSONDecoder` 路径跟 AntigravityFetcher/CodexFetcher 走同一条风格。
///
/// 字段命名严格匹配 minimax 返回的 snake_case；用 `CodingKeys` 显式声明避免
/// "let modelName: String" 自动 convert 出错。如果 minimax 加新字段，加一行
/// optional property 即可（不让 decoder 因为未知字段失败 —— `modelRemains`
/// 已经是 optional，codex 的 `id_token` 之类字段直接忽略）。
struct MinimaxResponse: Decodable {
    let modelRemains: [MinimaxModelRemain]
    let baseResp: MinimaxBaseResp?

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 顶层关键字段的缺失/类型变化必须显式失败，不能伪装成真实的空额度。
        self.modelRemains = try c.decode([MinimaxModelRemain].self, forKey: .modelRemains)
        self.baseResp = try c.decodeIfPresent(MinimaxBaseResp.self, forKey: .baseResp)
    }
}

/// `model_remains` 数组的单条记录。所有 numeric 字段都是 optional —— minimax
/// schema 没文档，不同 model 的字段子集不一样（比如 video 才有 `remains_time`）。
/// `modelName` 也 optional：缺 `model_name` 的 record 走 `compactMap` 跳过。
struct MinimaxModelRemain: Decodable {
    let modelName: String?
    let intervalTotalCount: Int?
    let intervalUsageCount: Int?
    let intervalRemainingPercent: Double?
    let intervalStatus: Int?
    let endTime: Int?
    let weeklyTotalCount: Int?
    let weeklyUsageCount: Int?
    let weeklyRemainingPercent: Double?
    let weeklyStatus: Int?
    let weeklyEndTime: Int?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case intervalTotalCount = "current_interval_total_count"
        case intervalUsageCount = "current_interval_usage_count"
        case intervalRemainingPercent = "current_interval_remaining_percent"
        case intervalStatus = "current_interval_status"
        case endTime = "end_time"
        case weeklyTotalCount = "current_weekly_total_count"
        case weeklyUsageCount = "current_weekly_usage_count"
        case weeklyRemainingPercent = "current_weekly_remaining_percent"
        case weeklyStatus = "current_weekly_status"
        case weeklyEndTime = "weekly_end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // model_name 缺失或类型错误的记录按既有业务规则整体跳过；不要继续解码
        // 其中无关字段，否则一个本就不会展示的坏 record 会拖垮所有合法 model。
        let decodedModelName = try? c.decodeIfPresent(String.self, forKey: .modelName)
        self.modelName = decodedModelName
        guard let decodedModelName,
              !decodedModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.intervalTotalCount = nil
            self.intervalUsageCount = nil
            self.intervalRemainingPercent = nil
            self.intervalStatus = nil
            self.endTime = nil
            self.weeklyTotalCount = nil
            self.weeklyUsageCount = nil
            self.weeklyRemainingPercent = nil
            self.weeklyStatus = nil
            self.weeklyEndTime = nil
            return
        }

        // 字段可以缺失，但字段一旦存在就必须保持正确类型；`try?` 会把 schema
        // 漂移静默降级成 nil，最终显示成真实的 0%，因此这里使用 decodeIfPresent。
        self.intervalTotalCount = try c.decodeIfPresent(Int.self, forKey: .intervalTotalCount)
        self.intervalUsageCount = try c.decodeIfPresent(Int.self, forKey: .intervalUsageCount)
        self.intervalRemainingPercent = try c.decodeIfPresent(Double.self, forKey: .intervalRemainingPercent)
        self.intervalStatus = try c.decodeIfPresent(Int.self, forKey: .intervalStatus)
        self.endTime = try c.decodeIfPresent(Int.self, forKey: .endTime)
        self.weeklyTotalCount = try c.decodeIfPresent(Int.self, forKey: .weeklyTotalCount)
        self.weeklyUsageCount = try c.decodeIfPresent(Int.self, forKey: .weeklyUsageCount)
        self.weeklyRemainingPercent = try c.decodeIfPresent(Double.self, forKey: .weeklyRemainingPercent)
        self.weeklyStatus = try c.decodeIfPresent(Int.self, forKey: .weeklyStatus)
        self.weeklyEndTime = try c.decodeIfPresent(Int.self, forKey: .weeklyEndTime)
    }
}

/// `base_resp` gRPC 风格状态块。
struct MinimaxBaseResp: Decodable {
    let statusCode: Int?
    let statusMsg: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMsg = "status_msg"
    }
}
