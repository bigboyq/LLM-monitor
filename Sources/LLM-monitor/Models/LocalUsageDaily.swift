import Foundation

/// 7-day token 用量 hover 图表用的 daily 数据协议。
///
/// 六个 provider（antigravity / codex / minimax / GLM / OpenCode / DSH）的 daily struct
/// 各自通过 computed property adapter conform（字段命名差异大 + codex 缺 `cacheWrite`）。
///
/// 字段语义（重点！）：
/// - `input` = **未命中 cache 的 input**（uncached）—— antigravity/minimax 直接映射
///   `inputTokens`；codex 是 `uncachedInputTokens`（总 input - cachedInputTokens）
/// - `cacheRead` = 命中 cache 的 input
/// - `cacheWrite` = provider 原始诊断字段（codex 不存，固定 0），不进入估算层
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
    /// Normalized accounting buckets consumed by UI and pricing. `cacheWrite`
    /// is deliberately retained only as provider diagnostics.
    var accountingBuckets: TokenUsageBuckets {
        TokenUsageBuckets(
            input: max(input, 0),
            cacheRead: max(cacheRead, 0),
            output: max(output, 0),
            reasoning: max(reasoning, 0)
        )
    }

    /// Total displayed consumption. Cache-write tokens are intentionally not
    /// included because this is an estimate layer rather than a cache ledger.
    var totalTokens: Int {
        accountingBuckets.totalTokens
    }

    /// `input + cacheRead`（估算层输入侧总量）。`cacheWrite` 不计入。
    var inputTotal: Int {
        SaturatingArithmetic.add(accountingBuckets.input, accountingBuckets.cacheRead)
    }

    /// `output + reasoning`（输出侧总量）
    var outputTotal: Int {
        accountingBuckets.billableOutput
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

// MARK: - codex adapter（字段名完全不同 + 缺 cacheWrite）
// 其余五个本地数据源的 daily 已统一为 LocalDailyTokenUsage（自带 conformance）。

extension DailyTokenUsage: LocalUsageDaily {
    var input: Int { uncachedInputTokens }
    var cacheRead: Int { cachedInputTokens }
    var cacheWrite: Int { 0 }
    var output: Int { outputTokens }
    var reasoning: Int { reasoningOutputTokens }
}
