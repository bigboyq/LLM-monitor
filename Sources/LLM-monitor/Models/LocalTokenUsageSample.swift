import Foundation

/// Provider 本地账本中的一次模型调用。
///
/// 三个 provider 最终都归一到同一语义：
/// - `inputTokens` 是完整输入（包含 cached input）
/// - `cachedInputTokens` 是 input 的子集
/// - 相同 `promptID` 的多条 sample 属于同一次用户请求的多轮模型调用
struct LocalTokenUsageSample: Equatable, Codable, Sendable {
    let completedAt: Date
    let modelName: String?
    let promptID: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    /// 原始账本中的 provider 标识。只有数据源能可靠提供时才填写；旧缓存和
    /// 其他 scanner 缺失该字段时保持 nil，由调用方使用兼容回退逻辑。
    var sourceProviderID: String? = nil

    var usage: UsageMetricSummary {
        UsageMetricSummary(
            prompts: 1,
            rounds: 1,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens
        )
    }

    /// 给跨数据源合并用的 prompt 命名空间，避免 native Scanner 与 OpenCode
    /// 恰好使用相同 ID 时被错误地算成同一个 turn。
    func withPromptIDPrefix(_ prefix: String) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: completedAt,
            modelName: modelName,
            promptID: prefix + promptID,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            sourceProviderID: sourceProviderID
        )
    }
}

/// 本地用量摘要使用的闭区间边界（实际过滤区间为 [start, end)）。
/// 当服务端没有返回 reset time 时，使用调用时刻 + 窗口长度作为临时 end，
/// 避免把缓存中保留的全部历史样本误算进当前窗口。
struct LocalUsageWindowBounds: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// 把 provider-specific 的模型名、时间窗口和 prompt 分组统一成 UI 使用的摘要。
enum LocalUsageSummaryBuilder {
    nonisolated static func summary(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        start: Date?,
        end: Date?,
        excludeWindows: [GlmOffPeakWindow] = [],
        excludeGlmOffPeak: Bool = false
    ) -> UsageMetricSummary? {
        // 服务端 resetTime 通常按整秒（秒级）向上取整返回，而本地事件 completedAt 带有毫秒精度。
        // 导致触发当前配额窗口的第一笔请求（如 11:19:19.903）会比推算出的 start (11:19:20.000) 小几十毫秒而被误判剔除。
        // 增加 20 秒容差 (tolerance) 保持起始边界精准涵盖触发事件。
        let effectiveStart = start?.addingTimeInterval(-20)
        let matching = matchingSamples(
            samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName
        ).filter { sample in
            if let effectiveStart, sample.completedAt < effectiveStart { return false }
            if let end, sample.completedAt >= end { return false }
            // 闲时任务（off-peak）不消耗积分，额度窗口统计排除其 token，避免高估消耗。
            // 本地 token 柱图不走这条路径，仍保留闲时任务的真实消耗。
            if (excludeGlmOffPeak || !excludeWindows.isEmpty),
               isGlmOffPeakSample(sample, fallbackWindows: excludeWindows) { return false }
            return true
        }
        guard !matching.isEmpty else { return nil }
        return aggregate(matching)
    }

    nonisolated static func lastPrompt(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String
    ) -> LastPromptUsage? {
        let matching = matchingSamples(
            samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName
        )
        guard let latest = matching.max(by: { $0.completedAt < $1.completedAt }) else {
            return nil
        }
        let promptSamples = matching.filter { $0.promptID == latest.promptID }
        guard !promptSamples.isEmpty else { return nil }
        return LastPromptUsage(
            completedAt: promptSamples.map(\.completedAt).max() ?? latest.completedAt,
            usage: aggregate(promptSamples)
        )
    }

    /// 今日闲时（off-peak）任务 token 汇总：取 `now` 所在本地自然日内、落在
    /// `offPeakWindows` 时间窗口内的样本，聚合出单独展示的"今日闲时"用量。
    ///
    /// - OpenCode 合并样本（promptID 带 `opencode:` 前缀）是正常消耗，不算闲时，排除。
    /// - 闲时任务不消耗 Coding Plan 积分，额度窗口统计排除它们（见 `summary(excludeWindows:)`），
    ///   这里单独列出供 UI 展示真实消耗。
    nonisolated static func offPeakTodaySummary(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        offPeakWindows: [GlmOffPeakWindow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageMetricSummary? {
        let todayStart = calendar.startOfDay(for: now)
        guard let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        let offPeakSamples = samples.filter { sample in
            guard sample.completedAt >= todayStart, sample.completedAt < todayEnd else { return false }
            return isGlmOffPeakSample(sample, fallbackWindows: offPeakWindows)
        }
        guard !offPeakSamples.isEmpty else { return nil }
        let matching = matchingSamples(
            offPeakSamples,
            providerKind: providerKind,
            quotaModelName: quotaModelName
        )
        guard !matching.isEmpty else { return nil }
        return aggregate(matching)
    }

    /// 优先使用 ZCode `model_usage.provider_id` 精确识别闲时样本。只有旧缓存或
    /// 手工构造的 sample 没有来源标记时，才回退到历史时间窗口算法；OpenCode
    /// 合并样本始终是正常消耗，不能因与后台任务并发而被排除。
    private nonisolated static func isGlmOffPeakSample(
        _ sample: LocalTokenUsageSample,
        fallbackWindows: [GlmOffPeakWindow]
    ) -> Bool {
        if let sourceProviderID = sample.sourceProviderID {
            return sourceProviderID == OpencodeLocalUsage.zcodeOffPeakProviderID
        }
        guard !sample.promptID.hasPrefix("opencode:") else { return false }
        return fallbackWindows.contains(where: { $0.contains(sample.completedAt) })
    }

    nonisolated static func windowStart(
        resetsAt: Date?,
        explicitWindowSeconds: Int?,
        fallbackSeconds: TimeInterval,
        now: Date = Date()
    ) -> Date? {
        windowBounds(
            resetsAt: resetsAt,
            explicitWindowSeconds: explicitWindowSeconds,
            fallbackSeconds: fallbackSeconds,
            now: now
        )?.start
    }

    /// 构造本地用量窗口。reset time 缺失时采用 `now + duration` 的临时结束时间，
    /// 保持当前统计仍然有明确边界；UI 的 reset 展示仍使用原始 API 值，不伪造服务端时间。
    nonisolated static func windowBounds(
        resetsAt: Date?,
        explicitWindowSeconds: Int?,
        fallbackSeconds: TimeInterval,
        now: Date = Date()
    ) -> LocalUsageWindowBounds? {
        let duration = explicitWindowSeconds.map(TimeInterval.init) ?? fallbackSeconds
        guard duration.isFinite, duration > 0,
              now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let end = resetsAt ?? now.addingTimeInterval(duration)
        guard end.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return LocalUsageWindowBounds(
            start: end.addingTimeInterval(-duration),
            end: end
        )
    }

    private nonisolated static func matchingSamples(
        _ samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String
    ) -> [LocalTokenUsageSample] {
        samples.filter {
            modelMatches(
                providerKind: providerKind,
                quotaModelName: quotaModelName,
                sampleModelName: $0.modelName
            )
        }
    }

    nonisolated static func modelMatches(
        providerKind: ProviderKind,
        quotaModelName: String,
        sampleModelName: String?
    ) -> Bool {
        let quota = quotaModelName.lowercased()
        let sample = sampleModelName?.lowercased() ?? ""

        switch providerKind {
        case .codexChatGpt:
            return quota == "chatgpt_plan"
        case .minimaxTokenPlan:
            // 本地 token_usage 是文本模型账本；媒体额度不会写入这两张表。
            guard quota == "general" else { return false }
            return sample.isEmpty
                || sample.contains("minimax")
                || sample.contains("m2")
                || sample.contains("m3")
        case .antigravity:
            let is3P = sample.contains("anthropic")
                || sample.contains("openai")
                || sample.contains("claude")
                || sample.contains("gpt")
            if quota == AntigravityModelKind.claudeAndGptModels.rawValue {
                return is3P
            }
            if quota == AntigravityModelKind.geminiModels.rawValue {
                return !is3P
            }
            return sample == quota
        case .glmCodingPlan:
            // OpenCode 的 GLM modelID 通常是 glm-*；保留 zhipu 兼容实际/旧版本命名。
            guard quota == "glm_coding_plan" else { return false }
            return sample.isEmpty || sample.contains("glm") || sample.contains("zhipu")
        case .deepseek:
            guard quota == "deepseek_balance" else { return false }
            return sample.isEmpty || sample.contains("deepseek")
        }
    }

    private nonisolated static func aggregate(
        _ samples: [LocalTokenUsageSample]
    ) -> UsageMetricSummary {
        UsageMetricSummary(
            prompts: Set(samples.map(\.promptID)).count,
            rounds: samples.count,
            inputTokens: SaturatingArithmetic.sum(samples.lazy.map(\.inputTokens)),
            cachedInputTokens: SaturatingArithmetic.sum(samples.lazy.map(\.cachedInputTokens)),
            outputTokens: SaturatingArithmetic.sum(samples.lazy.map(\.outputTokens)),
            reasoningOutputTokens: SaturatingArithmetic.sum(samples.lazy.map(\.reasoningOutputTokens))
        )
    }
}
