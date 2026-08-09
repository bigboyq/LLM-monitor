import Foundation

/// Antigravity 本地 token 用量聚合。
///
/// 数据来源：扫描 `~/.gemini/antigravity/conversations/*.db` 找到 session 列表，
/// 对比本地 mtime + cache `~/.gemini/antigravity/.token-monitor/` 后通过
/// `GetCascadeTrajectoryGeneratorMetadata` RPC 拉取 per-session 增量。
///
/// `dailyTokenUsage` 总是包含最近 7 个本地自然日（包含今天），按日升序。
/// `today` 单独冗余存一份，避免 UI 每次都 `dailyTokenUsage.last`。
struct AntigravityLocalUsage: Equatable, Codable, Sendable {
    /// 今日聚合（本地时区今天 00:00 至今）
    let today: AntigravityDailyUsage?

    /// 最近 7 个本地自然日（升序）
    let dailyTokenUsage: [AntigravityDailyUsage]

    /// 扫描完成时间（用于 UI 展示"更新于 HH:MM"）
    let scannedAt: Date?

    /// 命中的本地 session 数（包含没有成功拉取元数据的）
    let sessionCount: Int

    /// 解析到的 generatorMetadata 事件总数
    let eventCount: Int

    /// 缓存未命中 + 拉取失败的 session 数
    let failedSessionCount: Int

    /// 最近额度窗口内的逐次模型调用，用于 Last Prompt 与窗口累计 hover。
    /// optional 让旧的持久化结果仍可解码；UI 统一按空数组处理 nil。
    let recentSamples: [LocalTokenUsageSample]?

    static let empty = AntigravityLocalUsage(
        today: nil,
        dailyTokenUsage: [],
        scannedAt: nil,
        sessionCount: 0,
        eventCount: 0,
        failedSessionCount: 0,
        recentSamples: []
    )

    init(
        today: AntigravityDailyUsage?,
        dailyTokenUsage: [AntigravityDailyUsage],
        scannedAt: Date?,
        sessionCount: Int,
        eventCount: Int,
        failedSessionCount: Int,
        recentSamples: [LocalTokenUsageSample]? = nil
    ) {
        self.today = today
        self.dailyTokenUsage = dailyTokenUsage
        self.scannedAt = scannedAt
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.failedSessionCount = failedSessionCount
        self.recentSamples = recentSamples
    }

    /// 自定义 `==` 排除 `scannedAt` —— `scannedAt` 是 metadata（每次扫描都是新 `Date`），
    /// 默认 Equatable 会让"内容没变但 scannedAt 变了"的两份 usage 永远 !=，
    /// 导致 `AppState.apply*LocalUsage` 的 no-op 检查形同虚设：
    /// 每次都打 logInfo + 触发 `@Published` willSet 无意义 UI reload。
    /// 业务字段（`today` / `dailyTokenUsage` / `sessionCount` / `eventCount` /
    /// `failedSessionCount`）决定内容是否真变。
    /// Codable 自动合成的 CodingKeys 不受影响 —— `scannedAt` 仍然被编解码。
    static func == (lhs: AntigravityLocalUsage, rhs: AntigravityLocalUsage) -> Bool {
        lhs.today == rhs.today
            && lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.failedSessionCount == rhs.failedSessionCount
            && lhs.recentSamples == rhs.recentSamples
    }
}

/// 单日 token 用量聚合。
///
/// Antigravity 给出 5 类 tokens，每类独立计数：
/// - `inputTokens`：原始输入 tokens（未命中缓存）
/// - `cacheReadTokens`：从缓存读出的输入 tokens
/// - `cacheWriteTokens`：写入缓存的输入 tokens
/// - `outputTokens`：生成 tokens（不含 reasoning）
/// - `reasoningTokens`：推理 tokens（与 output 可能重叠，单独报告）
///
/// `totalTokens` = `input + cacheRead + output + reasoning`。
/// `cacheWrite` 不计入 total —— 它只是缓存簿记，不消耗"对外配额"。
struct AntigravityDailyUsage: Equatable, Codable, Sendable, Identifiable {
    let dayStart: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    /// 当天的 user prompt 数量 (= codex 的 turns 概念)
    /// 数据来源：直接 SELECT count from .db steps where step_type=14, per-day 切片
    let turns: Int
    /// 当天的 LLM API call 数量 (= codex 的 rounds 概念)
    /// 数据来源：直接 SELECT count from .db steps where step_type=15, per-day 切片
    let rounds: Int

    var id: Date { dayStart }

    init(dayStart: Date,
         inputTokens: Int = 0,
         cacheReadTokens: Int = 0,
         cacheWriteTokens: Int = 0,
         outputTokens: Int = 0,
         reasoningTokens: Int = 0,
         totalTokens: Int = 0,
         turns: Int = 0,
         rounds: Int = 0) {
        self.dayStart = dayStart
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.turns = turns
        self.rounds = rounds
    }

    /// 从同结构相加
    static func + (lhs: AntigravityDailyUsage, rhs: AntigravityDailyUsage) -> AntigravityDailyUsage {
        AntigravityDailyUsage(
            dayStart: lhs.dayStart,
            inputTokens: SaturatingArithmetic.add(lhs.inputTokens, rhs.inputTokens),
            cacheReadTokens: SaturatingArithmetic.add(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: SaturatingArithmetic.add(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            outputTokens: SaturatingArithmetic.add(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: SaturatingArithmetic.add(lhs.reasoningTokens, rhs.reasoningTokens),
            totalTokens: SaturatingArithmetic.add(lhs.totalTokens, rhs.totalTokens),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }

    /// `cacheRead / (cacheRead + input)`，缓存命中率
    /// 当两个都是 0 时返回 nil
    var cacheHitRate: Double? {
        let cacheRead = Double(SaturatingArithmetic.add(cacheReadTokens, 0))
        let input = Double(SaturatingArithmetic.add(inputTokens, 0))
        let inputTotal = cacheRead + input
        guard inputTotal > 0 else { return nil }
        return cacheRead / inputTotal
    }

    var reasonRate: Double? {
        let output = Double(SaturatingArithmetic.add(outputTokens, 0))
        let reasoning = Double(SaturatingArithmetic.add(reasoningTokens, 0))
        let outputTotal = output + reasoning
        guard outputTotal > 0 else { return nil }
        return reasoning / outputTotal
    }
}

extension AntigravityDailyUsage: DailyUsageAddable {
    init(dayStart: Date) {
        self.init(dayStart: dayStart, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0, reasoningTokens: 0, totalTokens: 0, turns: 0, rounds: 0)
    }

    func withDayStart(_ date: Date) -> AntigravityDailyUsage {
        AntigravityDailyUsage(
            dayStart: date,
            inputTokens: self.inputTokens,
            cacheReadTokens: self.cacheReadTokens,
            cacheWriteTokens: self.cacheWriteTokens,
            outputTokens: self.outputTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens,
            turns: self.turns,
            rounds: self.rounds
        )
    }
}
