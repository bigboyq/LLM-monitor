import Foundation

/// minimax 本地 token 用量聚合（同构 AntigravityLocalUsage）。
///
/// 数据来源：`~/.minimax/v2/sqlite/runtime-state.sqlite` 的
/// `local_runtime_token_usage` 表。旧版主数据库不再支持。
///
/// `dailyTokenUsage` 总是包含最近 7 个本地自然日（包含今天），按日升序。
/// `today` 单独冗余存一份，避免 UI 每次都 `dailyTokenUsage.last`。
///
/// 跟 antigravity 的关键区别：
/// - antigravity 还要走 `GetCascadeTrajectoryGeneratorMetadata` RPC + protobuf decode
///   才能拿到 token 用量；minimax 这边**直接 SQL 读 `local_runtime_token_usage` 表就有完整账单**。
/// - antigravity 的 turns/rounds 要从 .db 的 step_type=14/15 算（坑 8 跨源 join）；
///   minimax 直接 `COUNT(DISTINCT turn_id)` + `COUNT(*)` 在 SQL 里算完，零跨源 join。
struct MinimaxLocalUsage: Equatable, Codable, Sendable {
    /// 今日聚合（本地时区今天 00:00 至今）
    let today: MinimaxDailyUsage?

    /// 最近 7 个本地自然日（升序）
    let dailyTokenUsage: [MinimaxDailyUsage]

    /// 扫描完成时间（用于 UI 展示"更新于 HH:MM"）
    let scannedAt: Date?

    /// 命中的本地 session 数（去重后）
    let sessionCount: Int

    /// 解析到的 token_usage 行数（rounds = `COUNT(*)`）
    let eventCount: Int

    /// 失败 session 数（这里 minimax 没意义——所有 session 都在同一个 .db 里；
    /// 保留字段对齐 antigravity 语义，方便未来扩展）
    let failedSessionCount: Int

    /// 最近额度窗口内的逐次模型调用，用于 Last Prompt 与窗口累计 hover。
    let recentSamples: [LocalTokenUsageSample]?

    static let empty = MinimaxLocalUsage(
        today: nil,
        dailyTokenUsage: [],
        scannedAt: nil,
        sessionCount: 0,
        eventCount: 0,
        failedSessionCount: 0,
        recentSamples: []
    )

    init(
        today: MinimaxDailyUsage?,
        dailyTokenUsage: [MinimaxDailyUsage],
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
    static func == (lhs: MinimaxLocalUsage, rhs: MinimaxLocalUsage) -> Bool {
        lhs.today == rhs.today
            && lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.failedSessionCount == rhs.failedSessionCount
            && lhs.recentSamples == rhs.recentSamples
    }
}

/// 单日 token 用量聚合（同构 AntigravityDailyUsage）。
///
/// minimax v2 的 `local_runtime_token_usage` 表给出 5 类 tokens：
/// - `input_tokens`：原始输入 tokens（未命中缓存）
/// - `output_tokens`：生成 tokens（**真实**给用户看的内容；scanner 已从账单
///   `output_tokens` 减去"藏在内的 thinking"分摊）
/// - `reasoning_tokens`：推理 tokens。两种来源：
///   1. **当前（M3 / M2.7）**：scanner 从 `session_messages.thinking_content`
///      字符数按比例分摊 `outputTokens` 出来（账单层 `reasoning_tokens` 永远是
///      0，但 runtime 把思考文本存到了 `thinking_content` 字段）
///   2. **未来（thinking model）**：scanner 检测到 `raw.reasoning > 0` 时直接用
///      账单的 reasoning 字段，不再做字符分摊
/// - `cache_read_tokens`：从 prompt cache 读出的输入 tokens
/// - `cache_write_tokens`：写入 prompt cache 的输入 tokens
///
/// `totalTokens` = `input + cacheRead + output + reasoning`（账单原始总和）。
/// scanner 在 reasoning 分摊后重算
/// `total = input + cacheRead + realOutput + reasoning`
/// = `input + cacheRead + output`，同时跟账单及字段总和保持一致。
/// `cacheWrite` 不计入 total —— 它只是缓存簿记，不消耗"对外配额"。
///
/// R/T 来自同一张表（`local_runtime_token_usage.turn_id`），SQL 一次聚合算完：
/// - `turns` = `COUNT(DISTINCT turn_id)` 当日去重 turn 数
/// - `rounds` = `COUNT(*)` 当日 round 数
///
/// ## 为什么 outputTokens 和 reasoningTokens 不再是账单的"原始"数字
///
/// M3 / M2.7 是 non-thinking model：账单把模型生成的所有 token（含 thinking 文本）
/// 都算进 `output_tokens` 字段，`reasoning_tokens` 字段恒为 0。但 runtime 实际
/// 在 `session_messages.data.thinking_content` 里**存了完整的思考过程**。
///
/// scanner 检测到这一点后会做字符分摊：
/// ```
/// rawReason = thinking_content 字符数
/// rawOutput = msg_content 字符数
/// reasonTokens  = outputTokens * rawReason / (rawReason + rawOutput)
/// realOutput   = outputTokens - reasonTokens
/// ```
/// 守恒：`reasonTokens + realOutput == outputTokens` 永远成立。
///
/// 字段含义对应变化：
/// - `outputTokens`：分摊后真实的"给用户看的内容" token（不再是账单原始值）
/// - `reasoningTokens`：分摊出来的思考 token（账单里一直是 0 的字段现在有值了）
/// - `totalTokens`：分摊前后总和不变，UI 上不需要感知
///
/// 当未来 `raw.reasoning` 字段非零时（minimax 切到 thinking model），scanner 自动切
/// 回直接用账单的 `raw.reasoning`（不字符分摊），保持 UI 数字最准。
struct MinimaxDailyUsage: Equatable, Codable, Sendable, Identifiable {
    let dayStart: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    /// 当日的 user prompt 数量（去重 turn_id）
    let turns: Int
    /// 当日的 LLM API call 数量（行数 = rounds）
    let rounds: Int

    var id: Date { dayStart }

    init(dayStart: Date,
         inputTokens: Int = 0,
         outputTokens: Int = 0,
         cacheReadTokens: Int = 0,
         cacheWriteTokens: Int = 0,
         reasoningTokens: Int = 0,
         totalTokens: Int = 0,
         turns: Int = 0,
         rounds: Int = 0) {
        self.dayStart = dayStart
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.turns = turns
        self.rounds = rounds
    }

    /// 从同结构相加（merge 两个 db 源时用）。所有业务计数按非负值做饱和
    /// 加法：损坏缓存中的负数归零，超过 Int 范围时固定为 Int.max。
    static func + (lhs: MinimaxDailyUsage, rhs: MinimaxDailyUsage) -> MinimaxDailyUsage {
        MinimaxDailyUsage(
            dayStart: lhs.dayStart,
            inputTokens: SaturatingArithmetic.add(lhs.inputTokens, rhs.inputTokens),
            outputTokens: SaturatingArithmetic.add(lhs.outputTokens, rhs.outputTokens),
            cacheReadTokens: SaturatingArithmetic.add(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: SaturatingArithmetic.add(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            reasoningTokens: SaturatingArithmetic.add(lhs.reasoningTokens, rhs.reasoningTokens),
            totalTokens: SaturatingArithmetic.add(lhs.totalTokens, rhs.totalTokens),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }

    // protocol extension 提供（Models/LocalUsageDaily.swift），避免 Antigravity 和
    // Minimax 两个 daily type 重复实现。
}

extension MinimaxDailyUsage: DailyUsageAddable {
    init(dayStart: Date) {
        self.init(dayStart: dayStart, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0, totalTokens: 0, turns: 0, rounds: 0)
    }

    func withDayStart(_ date: Date) -> MinimaxDailyUsage {
        MinimaxDailyUsage(
            dayStart: date,
            inputTokens: self.inputTokens,
            outputTokens: self.outputTokens,
            cacheReadTokens: self.cacheReadTokens,
            cacheWriteTokens: self.cacheWriteTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens,
            turns: self.turns,
            rounds: self.rounds
        )
    }
}
