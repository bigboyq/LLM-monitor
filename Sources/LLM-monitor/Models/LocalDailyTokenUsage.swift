import Foundation

/// 单日 token 用量聚合 —— 五个本地数据源（antigravity / minimax / GLM ZCode /
/// opencode / dsh）共享的 daily 结构。
///
/// 各来源原先各自维护字段完全同构的 `XxxDailyUsage`（含逐字相同的 `+` /
/// `withDayStart` / `init(dayStart:)` / `hasActivity` 样板），现收口为单一类型 +
/// 保留原名 typealias。**字段名与合成 Codable 的 JSON 键与各来源原先的类型完全
/// 一致，on-disk index.json 缓存无需版本迁移。**
///
/// 字段语义（各来源在扫描层已归一到同一口径）：
/// - `inputTokens`：未命中 cache 的输入 tokens（uncached）
/// - `cacheReadTokens` / `cacheWriteTokens`：缓存读 / 写的输入 tokens
/// - `outputTokens`：生成 tokens（minimax 为字符分摊后的真实输出）
/// - `reasoningTokens`：推理 tokens（原生账单值或分摊值）
/// - `totalTokens` = `input + cacheRead + output + reasoning`；`cacheWrite` 只是
///   缓存簿记，不计入 total
/// - `turns` = 当日去重 user prompt 数；`rounds` = 当日 LLM API call 数
///
/// codex 的 `DailyTokenUsage`（`uncachedInputTokens` / `cachedInputTokens` 命名，
/// 随 QuotaInfo 持久化）不参与本次归一，仍走 `LocalUsageDaily` 协议适配。
struct LocalDailyTokenUsage: Equatable, Codable, Sendable, Identifiable {
    let dayStart: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let turns: Int
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

    var hasActivity: Bool {
        inputTokens > 0
            || outputTokens > 0
            || cacheReadTokens > 0
            || cacheWriteTokens > 0
            || reasoningTokens > 0
            || rounds > 0
            || turns > 0
    }

    /// 跨来源/跨天合并（饱和加法：负数归零，溢出封顶 Int.max）。
    static func + (lhs: LocalDailyTokenUsage, rhs: LocalDailyTokenUsage) -> LocalDailyTokenUsage {
        LocalDailyTokenUsage(
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
}

// MARK: - 历史类型名（保留原名，调用方与测试零改动）

typealias AntigravityDailyUsage = LocalDailyTokenUsage
typealias MinimaxDailyUsage = LocalDailyTokenUsage
typealias GlmDailyUsage = LocalDailyTokenUsage
typealias OpencodeDailyUsage = LocalDailyTokenUsage
typealias DshDailyUsage = LocalDailyTokenUsage

// MARK: - DailyUsageAddable（computeGlobalDaily / filterLast7Days 泛型约束）

extension LocalDailyTokenUsage: DailyUsageAddable {
    init(dayStart: Date) {
        self.init(
            dayStart: dayStart,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, totalTokens: 0, turns: 0, rounds: 0
        )
    }

    func withDayStart(_ date: Date) -> LocalDailyTokenUsage {
        LocalDailyTokenUsage(
            dayStart: date,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: turns,
            rounds: rounds
        )
    }
}

// MARK: - LocalUsageDaily（7 天 hover 图表协议；identity 适配）

extension LocalDailyTokenUsage: LocalUsageDaily {
    var input: Int { inputTokens }
    var cacheRead: Int { cacheReadTokens }
    var cacheWrite: Int { cacheWriteTokens }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningTokens }
}
