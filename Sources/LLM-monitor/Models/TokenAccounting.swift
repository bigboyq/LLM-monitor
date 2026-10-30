import Foundation

/// Describes how a harness reports its raw input counters.
enum TokenInputAccounting: String, Codable, Equatable, Sendable {
    /// The raw input counter already includes cache-read tokens.
    case cacheInclusive
    /// Cache-read tokens are reported as a separate counter.
    case uncachedOnly
}

/// Describes the relationship between a harness' raw output and reasoning
/// counters. This is source metadata; UI code consumes normalized buckets.
enum TokenOutputAccounting: String, Codable, Equatable, Sendable {
    /// Raw output contains reasoning as a subset and may be split when the
    /// harness gives enough information.
    case reasoningIncluded
    /// Output and reasoning are independent reported buckets.
    case independent
    /// The scanner has already normalized the raw source into output/reasoning
    /// buckets. No further subtraction is allowed.
    case normalized
}

/// The accounting contract for one harness/source family.
struct TokenAccountingDefinition: Codable, Equatable, Sendable {
    let name: String
    let input: TokenInputAccounting
    let output: TokenOutputAccounting

    /// cacheWrite is deliberately outside this project’s estimate layer. It
    /// may remain in provider-specific diagnostics, but never enters the
    /// normalized total or value estimate.
    var includesCacheWriteInEstimate: Bool { false }

    /// Converts raw source counters into the disjoint buckets consumed by the
    /// UI. `input` is always the uncached input bucket here; cacheRead remains
    /// separate. The sample layer can reconstruct cache-inclusive input when
    /// it needs to preserve the existing LocalTokenUsageSample contract.
    func normalizedBuckets(
        rawInput: Int,
        cacheRead: Int,
        rawOutput: Int,
        rawReasoning: Int
    ) -> TokenUsageBuckets {
        let safeInput = max(rawInput, 0)
        let safeCacheRead = max(cacheRead, 0)
        let safeOutput = max(rawOutput, 0)
        let safeReasoning = max(rawReasoning, 0)

        let uncachedInput: Int
        let effectiveCacheRead: Int
        switch input {
        case .cacheInclusive:
            effectiveCacheRead = min(safeCacheRead, safeInput)
            uncachedInput = max(safeInput - effectiveCacheRead, 0)
        case .uncachedOnly:
            effectiveCacheRead = safeCacheRead
            uncachedInput = safeInput
        }

        let output: Int
        let reasoning: Int
        switch self.output {
        case .reasoningIncluded:
            // If raw reasoning is unavailable, keep all raw output in Output
            // and deliberately report Reason = 0. This avoids inventing a
            // split and preserves the provider's raw total.
            let splitReasoning = min(safeReasoning, safeOutput)
            output = safeOutput - splitReasoning
            reasoning = splitReasoning
        case .independent, .normalized:
            output = safeOutput
            reasoning = safeReasoning
        }

        return TokenUsageBuckets(
            input: uncachedInput,
            cacheRead: effectiveCacheRead,
            output: output,
            reasoning: reasoning
        )
    }
}

/// Normalized four-bucket estimate input. cacheWrite is intentionally absent:
/// this layer is an estimate, not a provider billing ledger.
struct TokenUsageBuckets: Equatable, Sendable {
    let input: Int
    let cacheRead: Int
    let output: Int
    let reasoning: Int

    static let zero = Self(input: 0, cacheRead: 0, output: 0, reasoning: 0)

    var totalTokens: Int {
        SaturatingArithmetic.sum(input, cacheRead, output, reasoning)
    }

    var billableOutput: Int {
        SaturatingArithmetic.add(output, reasoning)
    }

    var cacheInclusiveInput: Int {
        SaturatingArithmetic.add(input, cacheRead)
    }

    static func + (lhs: TokenUsageBuckets, rhs: TokenUsageBuckets) -> TokenUsageBuckets {
        TokenUsageBuckets(
            input: SaturatingArithmetic.add(lhs.input, rhs.input),
            cacheRead: SaturatingArithmetic.add(lhs.cacheRead, rhs.cacheRead),
            output: SaturatingArithmetic.add(lhs.output, rhs.output),
            reasoning: SaturatingArithmetic.add(lhs.reasoning, rhs.reasoning)
        )
    }

    /// Converts the persisted sample contract into the normalized buckets.
    /// Samples intentionally keep `inputTokens` cache-inclusive for backward
    /// compatibility; this is the single conversion used by pricing and
    /// normalized summaries.
    static func fromSample(_ sample: LocalTokenUsageSample) -> Self {
        let input = max(sample.inputTokens, 0)
        let cached = max(sample.cachedInputTokens, 0)
        return Self(
            input: max(input - min(cached, input), 0),
            cacheRead: min(cached, input),
            output: max(sample.outputTokens, 0),
            reasoning: max(sample.reasoningOutputTokens, 0)
        )
    }
}

/// Aggregates persisted samples after they cross the accounting boundary.
/// Keeping this here prevents Settings, cards, and stale-current-day repair
/// from each reimplementing input/cache/output/reasoning conversions.
enum UnifiedTokenUsageAggregator {
    static func day(
        from samples: [LocalTokenUsageSample],
        dayStart: Date,
        calendar: Calendar = .current
    ) -> UnifiedDailyTokenUsage {
        var buckets = TokenUsageBuckets.zero
        var promptIDs = Set<String>()
        for sample in samples {
            let sampleBuckets = TokenUsageBuckets.fromSample(sample)
            buckets = TokenUsageBuckets(
                input: SaturatingArithmetic.add(buckets.input, sampleBuckets.input),
                cacheRead: SaturatingArithmetic.add(buckets.cacheRead, sampleBuckets.cacheRead),
                output: SaturatingArithmetic.add(buckets.output, sampleBuckets.output),
                reasoning: SaturatingArithmetic.add(buckets.reasoning, sampleBuckets.reasoning)
            )
            if sample.promptID.isEmpty == false {
                promptIDs.insert(sample.promptID)
            }
        }
        return UnifiedDailyTokenUsage(
            dayStart: calendar.startOfDay(for: dayStart),
            input: buckets.input,
            cacheRead: buckets.cacheRead,
            output: buckets.output,
            reasoning: buckets.reasoning,
            turns: promptIDs.count,
            rounds: samples.count
        )
    }

    static func days(
        from samples: [LocalTokenUsageSample],
        calendar: Calendar = .current
    ) -> [UnifiedDailyTokenUsage] {
        let grouped = Dictionary(grouping: samples) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return grouped.keys.sorted().map { dayStart in
            day(from: grouped[dayStart] ?? [], dayStart: dayStart, calendar: calendar)
        }
    }
}

/// Single source of truth for the six supported local usage families.
enum TokenAccountingCatalog {
    static let dsh = TokenAccountingDefinition(
        name: "DSH",
        input: .uncachedOnly,
        output: .reasoningIncluded
    )

    static let minimax = TokenAccountingDefinition(
        name: "MiniMax Code",
        input: .uncachedOnly,
        output: .reasoningIncluded
    )

    static let codex = TokenAccountingDefinition(
        name: "Codex",
        input: .cacheInclusive,
        output: .independent
    )

    /// Antigravity RPC 的 `usage.outputTokens` **已含思考**：用户在本机 271 个
    /// 会话（60,373 条含 token 事件）上实测 100% 满足
    /// `outputTokens == thinkingOutputTokens + responseOutputTokens`。这里必须走
    /// `.reasoningIncluded`（与 DSH 同款关系），让规范化 Output = rawOutput −
    /// reasoning、Reason = reasoning，四桶才守恒——`.independent` 会把思考算两遍
    /// （Output+Reason 虚高）。agy 无独立条目：口径与 antigravity raw 一致、在
    /// `AgyLocalUsageAggregation` reader 层经字符分摊守恒拆分，不经本条目。
    static let antigravity = TokenAccountingDefinition(
        name: "Antigravity",
        input: .uncachedOnly,
        output: .reasoningIncluded
    )

    static let opencode = TokenAccountingDefinition(
        name: "OpenCode",
        input: .uncachedOnly,
        output: .independent
    )

    /// ZCode's Method A rows are already normalized by the SQL reader; native
    /// reasoning fields are independent. The reader therefore owns the mixed
    /// source decision and exposes normalized buckets to this layer.
    static let zcode = TokenAccountingDefinition(
        name: "ZCode",
        input: .cacheInclusive,
        output: .normalized
    )
}
