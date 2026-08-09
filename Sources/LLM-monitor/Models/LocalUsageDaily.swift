import Foundation

/// 7-day token 用量 hover 图表用的 daily 数据协议。
///
/// 五个 provider（antigravity / codex / minimax / GLM / OpenCode）的 daily struct 各自通过
/// computed property adapter conform（字段命名差异大 + codex 缺 `cacheWrite`）。
///
/// 字段语义（重点！）：
/// - `input` = **未命中 cache 的 input**（uncached）—— antigravity/minimax 直接映射
///   `inputTokens`；codex 是 `uncachedInputTokens`（总 input - cachedInputTokens）
/// - `cacheRead` = 命中 cache 的 input
/// - `cacheWrite` = 写入 cache 的 input（codex 不存，固定 0）
/// - `output` = 生成 tokens
/// - `reasoning` = 推理 tokens
/// - `turns` / `rounds` = user prompt 数 / LLM API call 数
///
/// 字段名刻意简短（`input` / `output` / `cacheRead`）是为了避开 4 个 daily type
/// 已有的 stored property 名字（同 `inputTokens` / `outputTokens` 等），让 adapter
/// 全部用 computed property 不冲突。
///
/// `Identifiable where ID == Date`：各 daily struct 都用 `var id: Date { dayStart }`，
/// 统一 ID 类型让泛型 view 的 `ForEach` 能直接用。
protocol LocalUsageDaily: Identifiable where ID == Date {
    var dayStart: Date { get }
    var input: Int { get }
    var cacheRead: Int { get }
    var cacheWrite: Int { get }
    var output: Int { get }
    var reasoning: Int { get }
    var turns: Int { get }
    var rounds: Int { get }
}

// MARK: - 默认实现（消除各 provider daily type 的重复定义）

extension LocalUsageDaily {
    /// `input + cacheRead + cacheWrite`（输入侧总量）。
    /// 这不是 uncached input；名称强调的是输入侧合计，包含 cacheWrite。
    var inputTotal: Int {
        SaturatingArithmetic.sum(input, cacheRead, cacheWrite)
    }

    /// `output + reasoning`（输出侧总量）
    var outputTotal: Int {
        SaturatingArithmetic.add(output, reasoning)
    }

    /// `cacheRead / (cacheRead + input)`，缓存命中率
    /// 当两个都是 0 时返回 nil
    var cacheHitRate: Double? {
        let safeCacheRead = Double(max(0, cacheRead))
        let safeInput = Double(max(0, input))
        let denominator = safeCacheRead + safeInput
        guard denominator > 0 else { return nil }
        return safeCacheRead / denominator
    }

    /// `reasoning / (output + reasoning)` 占比
    /// 当两个都是 0 时返回 nil
    var reasonRate: Double? {
        let safeReasoning = Double(max(0, reasoning))
        let safeOutput = Double(max(0, output))
        let denominator = safeOutput + safeReasoning
        guard denominator > 0 else { return nil }
        return safeReasoning / denominator
    }
}

// MARK: - antigravity adapter（字段名带 Tokens 后缀 → protocol 短名）

extension AntigravityDailyUsage: LocalUsageDaily {
    var input: Int { inputTokens }
    var cacheRead: Int { cacheReadTokens }
    var cacheWrite: Int { cacheWriteTokens }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningTokens }
}

// MARK: - minimax adapter（字段名带 Tokens 后缀 → protocol 短名）

extension MinimaxDailyUsage: LocalUsageDaily {
    var input: Int { inputTokens }
    var cacheRead: Int { cacheReadTokens }
    var cacheWrite: Int { cacheWriteTokens }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningTokens }
}

// MARK: - opencode adapter（同构 minimax，原生 reasoning）
// OpenCode 是共享本地数据源，因此 adapter 与其他 daily 类型集中放在这里，
// 不放进 scanner 或某个 provider 专属 model 文件。

extension OpencodeDailyUsage: LocalUsageDaily {
    var input: Int { inputTokens }
    var cacheRead: Int { cacheReadTokens }
    var cacheWrite: Int { cacheWriteTokens }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningTokens }
}

// MARK: - codex adapter（字段名完全不同 + 缺 cacheWrite）

extension DailyTokenUsage: LocalUsageDaily {
    var input: Int { uncachedInputTokens }
    var cacheRead: Int { cachedInputTokens }
    var cacheWrite: Int { 0 }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningOutputTokens }
}
