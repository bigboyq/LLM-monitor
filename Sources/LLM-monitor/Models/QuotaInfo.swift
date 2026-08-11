import Foundation

/// 单个 model 的额度快照（来自 minimax API 的一个 model_remains 条目）
struct ModelQuota: Equatable, Codable, Sendable {
    /// model 标识（"general" / "video" / "image" / "speech" / "music" 等）
    let modelName: String

    /// 显示名（rule-based mapping of modelName → 用户可读名）
    var displayName: String {
        switch modelName.lowercased() {
        case "general":       return "通用 (M3)"
        case "video":         return "视频生成"
        case "image":         return "图像生成"
        case "speech":        return "语音合成"
        case "music":         return "音乐生成"
        case "tts":           return "TTS"
        case "chatgpt_plan":  return "ChatGPT Plan"
        case AntigravityModelKind.geminiModels.rawValue: return "Gemini Models"
        case AntigravityModelKind.claudeAndGptModels.rawValue: return "Claude and GPT models"
        case "glm_coding_plan": return "GLM-5.2"
        case "deepseek_balance": return "DeepSeek API 余额"
        default:              return modelName
        }
    }

    // MARK: 5 小时窗口

    /// 当前 interval 总配额（0 = 无固定额度，按量付费）
    let intervalTotalCount: Int

    /// 当前 interval 已用
    let intervalUsageCount: Int

    /// 当前 interval 剩余百分比 [0, 100]
    let intervalRemainingPercent: Double

    /// 统一窗口状态；已耗尽的窗口仍然是 `.present`。
    let intervalStatus: QuotaWindowStatus

    /// interval 结束时间（毫秒时间戳）
    let intervalResetsAt: Date?

    /// interval 窗口长度（秒，可选；ChatGPT/Codex 等动态窗口使用）
    let intervalWindowSeconds: Int?

    // MARK: 周窗口

    let weeklyTotalCount: Int
    let weeklyUsageCount: Int
    let weeklyRemainingPercent: Double
    /// 统一窗口状态；已耗尽的窗口仍然是 `.present`。
    let weeklyStatus: QuotaWindowStatus
    let weeklyResetsAt: Date?
    let weeklyWindowSeconds: Int?

    /// 5h 窗口是否存在（包括剩余 0% 的已耗尽窗口）。
    var hasIntervalWindow: Bool {
        intervalStatus.isPresent
    }

    /// 周窗口是否存在（包括剩余 0% 的已耗尽窗口）。
    var hasWeeklyWindow: Bool {
        weeklyStatus.isPresent
    }

    /// 至少有一个额度窗口存在时，模型才属于当前有效额度。
    var hasActiveQuotaWindow: Bool {
        hasIntervalWindow || hasWeeklyWindow
    }

    /// "差" 的健康度（红 > 黄 > 绿）。只有明确存在的窗口才参与计算；
    /// 如果没有任何有效窗口，保守返回 critical。
    var healthLevel: HealthLevel {
        var levels: [HealthLevel] = []
        if hasIntervalWindow {
            levels.append(Self.colorLevel(
                percent: intervalRemainingPercent,
                timeFraction: intervalTimeRemainingFraction
            ))
        }
        if hasWeeklyWindow {
            levels.append(Self.colorLevel(
                percent: weeklyRemainingPercent,
                timeFraction: weeklyTimeRemainingFraction
            ))
        }
        return levels.min() ?? .critical
    }

    /// 单窗口的颜色等级判定。给 `healthLevel` 和
    /// `SegmentedQuotaProgressBar.barColor` 共用，避免两边阈值漂移。
    ///
    /// - `percent < 15` → critical（红）
    /// - `percent < yellowThreshold` → warning（黄）
    ///   - `timeFraction == nil`：5h 短窗口，固定 30%
    ///   - `timeFraction != nil`：长窗口（>= 24h），`min(time%, 50)` —
    ///     剩余时间越少，黄色阈值越紧
    /// - 否则 → healthy（绿 / tint）
    static func colorLevel(percent: Double, timeFraction: Double?) -> HealthLevel {
        if percent < 15 { return .critical }
        let yellowThreshold = timeFraction.map { min($0 * 100.0, 50.0) } ?? 30.0
        if percent < yellowThreshold { return .warning }
        return .healthy
    }

    /// 周窗口剩余时间比例。0.0 = 即将过期，1.0 = 刚重置。
    /// 仅在周窗口存在且 weeklyResetsAt 已知时返回有效值；
    /// `weeklyWindowSeconds` 缺失时按 7 天兜底（minimax fetcher 当前把
    /// windowSeconds 写死成 nil，但 weeklyEndTime 一定有）。
    /// 5h 窗口不参与计算（用户偏好：进度条上只看周）。
    var weeklyTimeRemainingFraction: Double? {
        guard hasWeeklyWindow else { return nil }
        guard let end = weeklyResetsAt else {
            logWarn("[quota] model \(modelName) weekly window is present but reset time is missing")
            assertionFailure("ModelQuota weekly window is present without weeklyResetsAt")
            return nil
        }
        let length = weeklyWindowSeconds ?? (7 * 24 * 60 * 60)
        guard length > 0 else { return nil }
        let remaining = end.timeIntervalSinceNow
        return min(max(remaining / TimeInterval(length), 0), 1)
    }

    /// interval 窗口剩余时间比例。0.0 = 即将过期，1.0 = 刚重置。
    /// 仅在 interval 窗口属于 24h+ 长窗口（如 ChatGPT Plan 单窗口）时返回有效值；
    /// 5h 短窗口 / `intervalWindowSeconds` 未知一律返回 nil。
    /// Caller（fetcher）负责把 windowSeconds 填好；这里不做 modelName 特判。
    var intervalTimeRemainingFraction: Double? {
        guard hasIntervalWindow,
              let end = intervalResetsAt,
              let length = intervalWindowSeconds,
              length >= 86400 else { return nil }
        let remaining = end.timeIntervalSinceNow
        return min(max(remaining / TimeInterval(length), 0), 1)
    }
}

/// 通用额度数据 — 一个 provider 抓取一次的结果
struct QuotaInfo: Equatable, Codable, Sendable {
    /// 该 provider 下的所有 model 额度（一般 1-5 个）
    let models: [ModelQuota]

    /// Reset credits（codex / ChatGPT 用：剩余可用的重置次数）
    let resetCredits: ResetCreditsInfo?

    /// 显示用的套餐等级
    let planLabel: String?

    /// 登录账号（仅 Antigravity 提供；其他 provider 留空）
    let accountEmail: String?

    /// Codex / ChatGPT Plan 的本地 token 统计明细
    let codexUsageDetails: CodexUsageDetails?

    /// 数据抓取时刻
    let fetchedAt: Date

    // MARK: - 派生属性

    /// 当前至少有一个有效额度窗口的 model。原始 `models` 仍保留无权限占位
    /// 记录，便于日志和后续状态码诊断。
    var activeModels: [ModelQuota] {
        models.filter(\.hasActiveQuotaWindow)
    }

    /// 综合健康度：只计算当前有效 model；全部无效时保守返回 critical。
    var healthLevel: HealthLevel {
        activeModels.map(\.healthLevel).min() ?? .critical
    }

    /// 主 model（按显示顺序，第一个有效额度 model）
    var primaryModel: ModelQuota? {
        activeModels.first
    }
}

struct UsageMetricSummary: Equatable, Codable, Sendable {
    let prompts: Int
    let rounds: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    /// 跨数据源逐字段相加。cachedInputTokens 仍然是 inputTokens 的子集，
    /// 不会把 cache 当成额外 input 重复计入。
    static func + (lhs: UsageMetricSummary, rhs: UsageMetricSummary) -> UsageMetricSummary {
        UsageMetricSummary(
            prompts: SaturatingArithmetic.add(lhs.prompts, rhs.prompts),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds),
            inputTokens: SaturatingArithmetic.add(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: SaturatingArithmetic.add(lhs.cachedInputTokens, rhs.cachedInputTokens),
            outputTokens: SaturatingArithmetic.add(lhs.outputTokens, rhs.outputTokens),
            reasoningOutputTokens: SaturatingArithmetic.add(
                lhs.reasoningOutputTokens,
                rhs.reasoningOutputTokens
            )
        )
    }

    var hasReasoningOutput: Bool {
        reasoningOutputTokens > 0
    }

    /// 未命中 cache 的纯新输入 = `max(inputTokens - cachedInputTokens, 0)`。
    ///
    /// `inputTokens` 按约定是完整输入（含 cache），`cachedInputTokens` 是其子集。
    /// 7 天柱图（`LocalUsageDaily.input`）展示的是 uncached，hover 也用这个值让两边
    /// 口径一致。饱和减法容忍损坏缓存里 cache > input 的矛盾值。
    var uncachedInputTokens: Int {
        let safeInput = SaturatingArithmetic.add(inputTokens, 0)
        let safeCached = SaturatingArithmetic.add(cachedInputTokens, 0)
        return max(0, safeInput - safeCached)
    }

    var cacheHitRate: Double? {
        let safeInputTokens = SaturatingArithmetic.add(inputTokens, 0)
        let safeCachedInputTokens = SaturatingArithmetic.add(cachedInputTokens, 0)
        guard safeInputTokens > 0 else { return nil }
        // cachedInputTokens 是 inputTokens 的子集，而不是要与 input 相加的独立分量。
        // 防御独立构造或损坏缓存中的矛盾值，命中率始终限制在 0...1。
        return Double(min(safeCachedInputTokens, safeInputTokens)) / Double(safeInputTokens)
    }

    var reasonRate: Double? {
        let safeReasoningOutputTokens = SaturatingArithmetic.add(reasoningOutputTokens, 0)
        let safeOutputTokens = SaturatingArithmetic.add(outputTokens, 0)
        // 比例计算不能使用饱和 Int 总量：当两个分量都接近 Int.max 时，分母
        // 会被压成 Int.max，导致 reasoning 比例错误地接近 1 而不是 0.5。
        // Double 的数量级足以安全容纳两个非负 Int 分量之和。
        let total = Double(safeOutputTokens) + Double(safeReasoningOutputTokens)
        guard total > 0 else { return nil }
        return Double(safeReasoningOutputTokens) / total
    }
}

/// 远程额度窗口的积分用量。GLM 返回的是积分而不是 token，必须与本地 token 统计分开显示。
struct QuotaCountUsage: Equatable, Codable, Sendable {
    let used: Int
    let total: Int
}

struct LastPromptUsage: Equatable, Codable, Sendable {
    let completedAt: Date
    let usage: UsageMetricSummary
}

/// 按本地自然日聚合的 Codex token 用量。inputTokens 是服务端原始输入总量，
/// cachedInputTokens 是其中的缓存命中量，图表会单独绘制未缓存输入与缓存输入。
struct DailyTokenUsage: Equatable, Codable, Sendable, Identifiable {
    let dayStart: Date
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    /// 当天的 API 调用轮次（每个 event 算 1 轮）。
    let rounds: Int
    /// 当天的用户对话轮次（每个 user prompt 算 1 轮）。
    let turns: Int

    var id: Date { dayStart }
    var uncachedInputTokens: Int {
        let safeInputTokens = SaturatingArithmetic.add(inputTokens, 0)
        let safeCachedInputTokens = SaturatingArithmetic.add(cachedInputTokens, 0)
        return max(safeInputTokens - safeCachedInputTokens, 0)
    }
    var inputTotal: Int {
        SaturatingArithmetic.add(uncachedInputTokens, cachedInputTokens)
    }
    var outputTotal: Int {
        SaturatingArithmetic.add(outputTokens, reasoningOutputTokens)
    }

    init(
        dayStart: Date,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        rounds: Int = 0,
        turns: Int = 0
    ) {
        self.dayStart = dayStart
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.rounds = rounds
        self.turns = turns
    }
}

struct CodexUsageDetails: Equatable, Codable, Sendable {
    /// wham/usage 的 primary_window 对应的本地统计；窗口长度由 API 决定。
    let primary: UsageMetricSummary?
    /// wham/usage 的 secondary_window 对应的本地统计（接口未返回时为 nil）。
    let secondary: UsageMetricSummary?
    let lastPrompt: LastPromptUsage?
    /// 包含今天在内的最近七个本地自然日（00:00–23:59）。
    let dailyTokenUsage: [DailyTokenUsage]?
    let scannedAt: Date?
}

/// 单条 reset credit 记录（对齐 codex RateLimitResetCredit 真实 schema）
struct ResetCreditEntry: Equatable, Codable, Sendable {
    /// credit ID（codex 用 UUID-like 字符串，e.g. "RateLimitResetCredit_4af6566fb0f0819184f78027a71e35c1"）
    let id: String

    /// 状态："available" / "used" / "expired" / 其他
    let status: String

    /// 过期时间（ISO8601 字符串，可能为 nil）
    let expiresAt: Date?

    /// 授予时间（ISO8601 字符串，可选展示）
    let grantedAt: Date?

    /// 类型（e.g. "codex_rate_limits"），所有 entry 都一样
    let resetType: String?

    /// 标题（e.g. "Full reset (Weekly + 5 hr)"），最关键的可读信息
    let title: String?

    /// 描述文字（e.g. "Thanks for using Codex! You've been granted one free rate limit reset."）
    let description: String?
}

/// reset credits 汇总
struct ResetCreditsInfo: Equatable, Codable, Sendable {
    let entries: [ResetCreditEntry]

    /// 服务端给的总可用数（优先用，没有就自己数）
    let serverAvailableCount: Int?

    /// 服务端给的累计获得数（注意：实测可能跟 credits 数组长度不一致，慎用）
    let totalEarnedCount: Int?

    /// R3: 该 reset credits 值的实际抓取时间，独立于主 quota 的 `fetchedAt`。
    /// 主 quota 成功但 reset credits 子请求失败时，主 `fetchedAt` 不能冒充子接口时间。
    /// 旧缓存/解码缺省为 nil（UI 按不可判定处理，不显示过期）。
    let fetchedAt: Date?

    /// R3: 最近一次 full 抓取是否失败。true 表示当前值是回填的旧数据，需要提示过期。
    /// background 刷新按设计跳过 reset credits，不算失败，不置位。
    let lastAttemptFailed: Bool

    init(
        entries: [ResetCreditEntry],
        serverAvailableCount: Int?,
        totalEarnedCount: Int?,
        fetchedAt: Date? = nil,
        lastAttemptFailed: Bool = false
    ) {
        self.entries = entries
        self.serverAvailableCount = serverAvailableCount
        self.totalEarnedCount = totalEarnedCount
        self.fetchedAt = fetchedAt
        self.lastAttemptFailed = lastAttemptFailed
    }

    private enum CodingKeys: String, CodingKey {
        case entries, serverAvailableCount, totalEarnedCount, fetchedAt, lastAttemptFailed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ResetCreditEntry].self, forKey: .entries) ?? []
        serverAvailableCount = try c.decodeIfPresent(Int.self, forKey: .serverAvailableCount)
        totalEarnedCount = try c.decodeIfPresent(Int.self, forKey: .totalEarnedCount)
        // 旧数据没有这两个字段 → nil / false（向后兼容）。
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        lastAttemptFailed = try c.decodeIfPresent(Bool.self, forKey: .lastAttemptFailed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
        try c.encodeIfPresent(serverAvailableCount, forKey: .serverAvailableCount)
        try c.encodeIfPresent(totalEarnedCount, forKey: .totalEarnedCount)
        try c.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
        if lastAttemptFailed { try c.encode(lastAttemptFailed, forKey: .lastAttemptFailed) }
    }

    /// 当前可用的次数（status == "available"）
    var availableCount: Int {
        serverAvailableCount ?? entries.filter { $0.status.lowercased() == "available" }.count
    }

    /// 已使用的次数
    var usedCount: Int {
        entries.filter { $0.status.lowercased() == "used" }.count
    }

    /// 最早的过期时间（用于显示"X 天后过期"）
    var nearestExpiry: Date? {
        entries
            .filter { $0.status.lowercased() == "available" }
            .compactMap { $0.expiresAt }
            .min()
    }

    /// 是否展示：至少有一条 entry 才展示
    var shouldDisplay: Bool { !entries.isEmpty }

    /// R3: 返回一份标记为"过期（最近 full 抓取失败）"的副本，保留原值与原 fetchedAt。
    func markingStale() -> ResetCreditsInfo {
        ResetCreditsInfo(
            entries: entries,
            serverAvailableCount: serverAvailableCount,
            totalEarnedCount: totalEarnedCount,
            fetchedAt: fetchedAt,
            lastAttemptFailed: true
        )
    }

    /// R3: 是否应对外显示"可能过期"。
    /// - `lastAttemptFailed` 立即判定过期；
    /// - 否则当数据年龄超过 `max(3 × 刷新间隔, 15 分钟)` 时也判定过期；
    /// - 没有 `fetchedAt`（旧数据）时不按年龄判定。
    func isStale(now: Date, refreshIntervalSeconds: TimeInterval) -> Bool {
        if lastAttemptFailed { return true }
        guard let fetchedAt else { return false }
        let threshold = max(refreshIntervalSeconds * 3, 15 * 60)
        return now.timeIntervalSince(fetchedAt) > threshold
    }
}

enum HealthLevel: String, Sendable, Comparable {
    case healthy
    case warning
    case critical

    var rank: Int {
        // 数值越大表示越健康；Comparable 升序的最小值因此代表最差等级。
        switch self {
        case .healthy:  return 2
        case .warning:  return 1
        case .critical: return 0
        }
    }

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension QuotaInfo {
    /// 辅助方法：使用本地会话用量明细去富化配额快照
    func enriched(with details: CodexUsageDetails?) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: resetCredits,
            planLabel: planLabel,
            accountEmail: accountEmail,
            codexUsageDetails: details,
            fetchedAt: fetchedAt
        )
    }
}
