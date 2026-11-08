import Foundation

/// Provider 本地账本中的一次模型调用。
///
/// `inputTokens` 保留 sample 层的历史语义：是 cache-inclusive 总输入
///（uncached + cached）；`cachedInputTokens` 是独立的 cache-read bucket。
/// `sourceProviderID` 仍记录原始账本的 provider 标识（`dsh:provider`、
/// `zhipuai-coding-plan` 等）。规范化估算层通过 `TokenUsageBuckets.fromSample`
/// 做一次统一转换：`Input`（uncached）、`Cache read`、`Output`、`Reason`。
/// `cacheWrite` 不属于 sample 结构，也不参与总量或价格估算。
/// 不同 harness 的 raw 字段关系见 `spec/accounting.md` 及各 provider spec。
/// 相同 `promptID` 的多条 sample 属于同一次用户请求的多轮模型调用。
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
    /// 单次模型调用完整时长（发起→完成，含 TTFT、不含工具执行），秒。
    /// nil = 账本未提供（旧缓存 / 不记录时长的 harness）。窗口 token 速度
    /// （`LocalUsageSummaryBuilder.windowTokenRate`，全仓唯一实现）只认
    /// `0.2...3600` 秒内的值，nil 样本分子分母都不计。
    var durationSeconds: Double? = nil
    /// 单次模型调用首 token 延迟（TTFT，发起→首 token 到达），秒。
    /// nil = 账本未提供（旧缓存 / 不记录 TTFT 的 harness）。合成 Codable 下
    /// 旧缓存 JSON 缺该 key 解码为 nil，无需自定义 decode。有效性域与聚合
    /// 口径见 `LocalUsageSummaryBuilder` 的 TTFT 聚合函数（全仓唯一实现）；
    /// 各 harness 采集来源见 `spec/accounting.md` §TTFT 口径（OpenCode 无字段
    /// 恒 nil；MiniMax Code 由 request−decode 差分推导，2.5.3 曾显式写 0）。
    var ttftSeconds: Double? = nil

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

    var totalTokens: Int {
        TokenUsageBuckets.fromSample(self).totalTokens
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
            sourceProviderID: sourceProviderID,
            durationSeconds: durationSeconds,
            ttftSeconds: ttftSeconds
        )
    }
}

/// Per-prompt token-speed distribution for a set of local usage samples.
///
/// A prompt is included in the distribution only when every call in that prompt
/// has a valid duration. This avoids presenting partial multi-call prompts as a
/// complete request speed. `latest` always refers to the newest prompt in the
/// input, and is nil when that prompt is incomplete; it never falls back to an
/// older prompt.
struct PromptSpeedStatistics: Equatable, Sendable {
    let minimum: Double?
    let maximum: Double?
    let p50: Double?
    let latest: Double?
    let validPromptCount: Int
    let totalPromptCount: Int

    static let empty = PromptSpeedStatistics(
        minimum: nil,
        maximum: nil,
        p50: nil,
        latest: nil,
        validPromptCount: 0,
        totalPromptCount: 0
    )
}

/// Call-level TTFT (time-to-first-token) distribution for a set of local usage
/// samples. The statistical unit is a single model call (unlike
/// `PromptSpeedStatistics`, which groups calls by prompt): every sample with a
/// valid `ttftSeconds` contributes one value, and MiniMax Code's explicit 0
/// participates like any other value. `p50` is nil iff there is no valid
/// sample; `validCallCount` / `totalCallCount` let the UI disclose coverage.
struct CallTTFTStatistics: Equatable, Sendable {
    let p50: Double?
    let validCallCount: Int
    let totalCallCount: Int
    static let empty = CallTTFTStatistics(p50: nil, validCallCount: 0, totalCallCount: 0)
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
        let matching = windowSamples(
            samples: samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName,
            start: start,
            end: end,
            excludeWindows: excludeWindows,
            excludeGlmOffPeak: excludeGlmOffPeak
        )
        guard !matching.isEmpty else { return nil }
        return aggregate(matching)
    }

    /// 窗口口径的样本**筛选**（与 `summary` 同一份规则），返回样本本身而不是聚合值。
    ///
    /// 存在的理由是计价：`ModelPricingCatalog.estimate` 要的是样本（它逐条按模型
    /// 查价、DeepSeek 还要逐条按 `completedAt` 判峰时 ×2），给不了聚合值。这里把
    /// 筛选单独提出来，`summary` 与「额度窗口用量」区块的**金额**都走它——两处一旦
    /// 各写一份筛选，token 数和金额就会落在不同的一批样本上，而这种错位不崩不报错。
    nonisolated static func windowSamples(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        start: Date?,
        end: Date?,
        excludeWindows: [GlmOffPeakWindow] = [],
        excludeGlmOffPeak: Bool = false
    ) -> [LocalTokenUsageSample] {
        // 服务端 resetTime 通常按整秒（秒级）向上取整返回，而本地事件 completedAt 带有毫秒精度。
        // 导致触发当前配额窗口的第一笔请求（如 11:19:19.903）会比推算出的 start (11:19:20.000) 小几十毫秒而被误判剔除。
        // 增加 20 秒容差 (tolerance) 保持起始边界精准涵盖触发事件。
        let effectiveStart = start?.addingTimeInterval(-20)
        return matchingSamples(
            samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName
        ).filter { sample in
            if let effectiveStart, sample.completedAt < effectiveStart { return false }
            if let end, sample.completedAt >= end { return false }
            // 闲时任务（off-peak）与其他智谱套餐任务（如体验套餐）都不消耗积分，
            // 额度窗口统计排除其 token，避免高估消耗。本地 token 柱图不走这条
            // 路径，仍保留这些任务的真实消耗。
            if (excludeGlmOffPeak || !excludeWindows.isEmpty),
               isGlmOffPeakSample(sample, fallbackWindows: excludeWindows)
                    || isGlmOtherPlanSample(sample) { return false }
            return true
        }
    }

    /// 按 `GlmUsageCategory` 取**今日**样本：`now` 所在本地自然日内、分类命中
    /// 的样本，返回样本本身而不是聚合值。
    ///
    /// 这是「闲」行（`offPeakTodaySamples`）与「免 / 速 / 它」今日动态行
    /// （`ProviderCardDerivedValues.glmCategoryUsageRows`）共享的唯一今日切片
    /// 谓词——「全仓仅一份」的语义从 offPeak 专属泛化到按分类。判定与
    /// `GlmUsageCategory.classify` 同一互斥口径；唯一例外是 **offPeak**：旧缓存
    /// 没有来源标记的样本要靠 `offPeakWindows` 时间窗口回退（classify 不带
    /// 窗口，无法回退），normal 侧对应地把带窗口回退的闲时样本排除，其余分类
    /// 的样本必有来源标记、与 classify 恒等。
    nonisolated static func glmCategoryTodaySamples(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        category: GlmUsageCategory,
        offPeakWindows: [GlmOffPeakWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LocalTokenUsageSample] {
        let todayStart = calendar.startOfDay(for: now)
        guard let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }
        let categorySamples = samples.filter { sample in
            guard sample.completedAt >= todayStart, sample.completedAt < todayEnd else { return false }
            switch category {
            case .offPeak:
                return isGlmOffPeakSample(sample, fallbackWindows: offPeakWindows)
            case .normal:
                return !isGlmOffPeakSample(sample, fallbackWindows: offPeakWindows)
                    && GlmUsageCategory.classify(sample) == .normal
            case .startPlan, .highSpeed, .other:
                return GlmUsageCategory.classify(sample) == category
            }
        }
        return matchingSamples(
            categorySamples,
            providerKind: providerKind,
            quotaModelName: quotaModelName
        )
    }

    /// 今日闲时（off-peak）任务的**样本**筛选：取 `now` 所在本地自然日内、落在
    /// `offPeakWindows` 时间窗口内（或来源标记为闲时 provider）的样本，返回样本
    /// 本身而不是聚合值。
    ///
    /// 存在的理由与 `windowSamples` 相同：计价（`ModelPricingCatalog.estimate`）要的
    /// 是样本。「闲」行（`ProviderCardDerivedValues.offPeakUsageRow`）的 token 数与
    /// 金额必须落在同一批样本上，所以筛选单独提出来，`offPeakTodaySummary` 与
    /// 「闲」行的**金额**都走它。实现委托共享助手 `glmCategoryTodaySamples`
    /// （`.offPeak` 分类），对外签名与行为不变。
    ///
    /// - OpenCode 合并样本（promptID 带 `opencode:` 前缀）是正常消耗，不算闲时，排除。
    /// - 闲时任务不消耗 Coding Plan 积分，额度窗口统计排除它们（见 `summary(excludeWindows:)`），
    ///   这里单独筛出供 UI 展示真实消耗。
    nonisolated static func offPeakTodaySamples(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        offPeakWindows: [GlmOffPeakWindow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LocalTokenUsageSample] {
        glmCategoryTodaySamples(
            samples: samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName,
            category: .offPeak,
            offPeakWindows: offPeakWindows,
            now: now,
            calendar: calendar
        )
    }

    /// 按 `GlmUsageCategory` 聚合**今日** token 汇总（`glmCategoryTodaySamples`
    /// 的聚合形态）。「免 / 速 / 它」今日动态行的 token 四桶走它。
    nonisolated static func glmCategoryTodaySummary(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        category: GlmUsageCategory,
        offPeakWindows: [GlmOffPeakWindow] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageMetricSummary? {
        let matching = glmCategoryTodaySamples(
            samples: samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName,
            category: category,
            offPeakWindows: offPeakWindows,
            now: now,
            calendar: calendar
        )
        guard !matching.isEmpty else { return nil }
        return aggregate(matching)
    }

    /// 今日闲时（off-peak）任务 token 汇总：取 `now` 所在本地自然日内、落在
    /// `offPeakWindows` 时间窗口内的样本，聚合出单独展示的"今日闲时"用量。
    ///
    /// 判定谓词只有 `offPeakTodaySamples` 一份，这里只是它的聚合形态。
    nonisolated static func offPeakTodaySummary(
        samples: [LocalTokenUsageSample],
        providerKind: ProviderKind,
        quotaModelName: String,
        offPeakWindows: [GlmOffPeakWindow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageMetricSummary? {
        glmCategoryTodaySummary(
            samples: samples,
            providerKind: providerKind,
            quotaModelName: quotaModelName,
            category: .offPeak,
            offPeakWindows: offPeakWindows,
            now: now,
            calendar: calendar
        )
    }

    /// 优先使用 ZCode `model_usage.provider_id` 精确识别闲时样本（显式枚举判定
    /// `OpencodeLocalUsage.isZcodeOffPeakProvider`，覆盖账号化新 ID 与历史裸值）。
    /// 只有旧缓存或手工构造的 sample 没有来源标记时，才回退到历史时间窗口算法；
    /// OpenCode 合并样本始终是正常消耗，不能因与后台任务并发而被排除。
    /// （internal：`GlmUsageCategory.classify` 复用同一判定。）
    nonisolated static func isGlmOffPeakSample(
        _ sample: LocalTokenUsageSample,
        fallbackWindows: [GlmOffPeakWindow]
    ) -> Bool {
        if let sourceProviderID = sample.sourceProviderID {
            return OpencodeLocalUsage.isZcodeOffPeakProvider(sourceProviderID)
        }
        guard !sample.promptID.hasPrefix("opencode:") else { return false }
        return fallbackWindows.contains(where: { $0.contains(sample.completedAt) })
    }

    /// 体验套餐 Start Plan：`provider_id` 含 `bigmodel-start-plan`
    /// （`account:bigmodel-start-plan` / `builtin:bigmodel-start-plan`）。
    ///
    /// 判定放在 `isGlmOtherPlanSample` 之前：Start Plan 本来也满足「智谱前缀 +
    /// 未登记进正式套餐 / 闲时两个集合」，不先摘出来就会被算进「其他任务」。
    /// 这里只影响设置页拆行；额度窗口排除仍由 `isGlmOtherPlanSample` 整体
    /// 覆盖（Start Plan 依旧不消耗积分），两处口径互不影响。
    nonisolated static func isGlmStartPlanSample(_ sample: LocalTokenUsageSample) -> Bool {
        guard let sourceProviderID = sample.sourceProviderID else { return false }
        return sourceProviderID.contains("bigmodel-start-plan")
    }

    /// 加速卡（highspeed-card）：`provider_id` 命中显式集合
    /// `OpencodeLocalUsage.zcodeGlmHighspeedProviderIDs`
    /// （`account:bigmodel-highspeed-card` 等）。
    ///
    /// 与 Start Plan 同一处理：判定放在 `isGlmOtherPlanSample` 之前单独摘出，
    /// 这里只影响设置页拆行与「额度窗口」表格的今日动态行；额度窗口排除仍由
    /// `isGlmOtherPlanSample` 整体覆盖（加速卡同样不消耗积分，继续排除在
    /// 5h / 周窗口之外），两处口径互不影响。
    nonisolated static func isGlmHighspeedSample(_ sample: LocalTokenUsageSample) -> Bool {
        guard let sourceProviderID = sample.sourceProviderID else { return false }
        return OpencodeLocalUsage.isZcodeGlmHighspeedProvider(sourceProviderID)
    }

    /// 「其他」智谱任务：智谱前缀（`builtin:bigmodel-` / `account:bigmodel-` /
    /// `account:zai-`）但不属于任何已登记分类的 provider —— 体验套餐
    /// （`*:start-plan`）、未登记新套餐（含未来 `*-coding-plan` 变体）等。这类任务
    /// 不消耗 Coding Plan 积分，额度窗口统计排除；token 柱图保留真实消耗。闲时
    /// provider（含账号化新 ID）虽也带智谱前缀，但已由 `isGlmOffPeakSample` 识别，
    /// 这里显式排除以保持三桶互斥。OpenCode / DSH 来源（`zhipuai-coding-plan`、
    /// `dsh:glm` 等）不带这些前缀，不受影响。缺 `sourceProviderID` 的旧缓存
    /// 保持原时间窗口回退语义。
    nonisolated static func isGlmOtherPlanSample(_ sample: LocalTokenUsageSample) -> Bool {
        guard let sourceProviderID = sample.sourceProviderID else { return false }
        return OpencodeLocalUsage.zcodeBigmodelProviderPrefixes.contains(where: sourceProviderID.hasPrefix)
            && !OpencodeLocalUsage.isZcodeGlmCodingPlanProvider(sourceProviderID)
            && !OpencodeLocalUsage.isZcodeOffPeakProvider(sourceProviderID)
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
            if let quotaPool = AntigravityModelKind(rawValue: quota) {
                if let samplePool = AntigravityModelKind.pool(forSampleModelName: sampleModelName) {
                    return samplePool == quotaPool
                }
                // Preserve the quota-window fallback: unknown/missing local model names
                // remain included in Gemini Models, while other known pools do not claim them.
                return quotaPool == .geminiModels
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

    /// 窗口 token 速度（tok/s）的**唯一**实现：Σ(Output+Reason) ÷ Σ单次调用时长。
    ///
    /// 口径：分子 = `outputTokens + reasoningOutputTokens`（billable 两桶）；分母 =
    /// 单次调用完整时长（发起→完成，含 TTFT、不含工具执行）。聚合是 **Σ/Σ 加权**
    /// ——等价于把窗口内所有秒摊到一起看平均速度，而不是各样本速率的算术平均
    /// （那会让大量短请求淹没长请求）。有效性过滤 `durationSeconds ∈ [0.2, 3600]`：
    /// 亚秒样本把速率拉成噪声，超 1h 的多为账本异常；`durationSeconds == nil`
    /// （账本未提供时长）的样本分子分母都不计。没有有效样本返回 nil。
    nonisolated static func windowTokenRate(
        samples: [LocalTokenUsageSample]
    ) -> Double? {
        windowTokenRateComponents(samples: samples).map { $0.numerator / $0.denominator }
    }

    /// Prompt-level speed distribution. Calls sharing a namespaced `promptID`
    /// form one statistical sample; its speed is the combined billable output
    /// divided by the combined valid call duration. A prompt with any missing or
    /// out-of-range call duration is omitted from min/max/P50 in its entirety.
    /// The newest prompt is selected by its latest `completedAt`; promptID
    /// ascending is the deterministic tie break when timestamps match.
    nonisolated static func promptSpeedStatistics(
        samples: [LocalTokenUsageSample]
    ) -> PromptSpeedStatistics {
        let grouped = Dictionary(grouping: samples, by: \.promptID)
        guard !grouped.isEmpty else { return .empty }

        struct PromptRate {
            let promptID: String
            let completedAt: Date
            let rate: Double?
        }

        let prompts = grouped.map { promptID, calls -> PromptRate in
            let completedAt = calls.map(\.completedAt).max() ?? .distantPast
            guard calls.allSatisfy({ hasValidTokenRateDuration($0) }),
                  let rate = windowTokenRate(samples: calls) else {
                return PromptRate(promptID: promptID, completedAt: completedAt, rate: nil)
            }
            return PromptRate(
                promptID: promptID,
                completedAt: completedAt,
                rate: rate
            )
        }

        let latestPrompt = prompts.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.promptID < $1.promptID
        }.first!
        let rates = prompts.compactMap(\.rate).sorted()
        guard !rates.isEmpty else {
            return PromptSpeedStatistics(
                minimum: nil,
                maximum: nil,
                p50: nil,
                latest: latestPrompt.rate,
                validPromptCount: 0,
                totalPromptCount: prompts.count
            )
        }
        let middle = rates.count / 2
        let p50 = rates.count.isMultiple(of: 2)
            ? (rates[middle - 1] + rates[middle]) / 2
            : rates[middle]
        return PromptSpeedStatistics(
            minimum: rates.first,
            maximum: rates.last,
            p50: p50,
            latest: latestPrompt.rate,
            validPromptCount: rates.count,
            totalPromptCount: prompts.count
        )
    }

    /// `windowTokenRate` 的分量形态：返回 (Σ分子, Σ分母)，让 `windowUsage` 把
    /// 中间量一并写进产物（`QuotaWindowUsageSnapshot.Window.rateNumerator` /
    /// `rateDenominator`），`combineWindowUsage` 才能跨池先加和再相除。过滤规则
    /// 与口径全仓只有这一份，`windowTokenRate` 是它的商值形态。
    private nonisolated static func windowTokenRateComponents(
        samples: [LocalTokenUsageSample]
    ) -> (numerator: Double, denominator: Double)? {
        let valid = samples.compactMap { sample -> (tokens: Int, seconds: Double)? in
            guard hasValidTokenRateDuration(sample),
                  let duration = sample.durationSeconds else { return nil }
            return (SaturatingArithmetic.sum(sample.outputTokens, sample.reasoningOutputTokens), duration)
        }
        guard !valid.isEmpty else { return nil }
        let numerator = SaturatingArithmetic.sum(valid.lazy.map(\.tokens))
        let denominator = valid.reduce(0.0) { $0 + $1.seconds }
        guard denominator.isFinite, denominator > 0 else { return nil }
        return (numerator: Double(numerator), denominator: denominator)
    }

    /// Shared duration gate for both call-level rates and complete-prompt gating.
    private nonisolated static func hasValidTokenRateDuration(
        _ sample: LocalTokenUsageSample
    ) -> Bool {
        guard let duration = sample.durationSeconds else { return false }
        return duration.isFinite && duration >= 0.2 && duration <= 3600
    }

    // MARK: - TTFT（首字延迟）

    /// 调用级 TTFT（首字延迟）P50 分布，全仓唯一实现。统计单位是**单次调用**
    /// （与 `promptSpeedStatistics` 的 prompt 级不同）：所有 `ttftSeconds` 有效
    /// 样本排序取中位——偶数个取中间两数平均，奇数取中间值；p50 为 nil 当且
    /// 仅当无有效样本。MiniMax Code 显式写的 0（无上游数据）正常参与。
    nonisolated static func callTTFTStatistics(
        samples: [LocalTokenUsageSample]
    ) -> CallTTFTStatistics {
        let values = samples.compactMap { sample -> Double? in
            guard hasValidTTFT(sample), let ttft = sample.ttftSeconds else { return nil }
            return ttft
        }
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let p50 = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return CallTTFTStatistics(
            p50: p50,
            validCallCount: sorted.count,
            totalCallCount: samples.count
        )
    }

    /// 窗口 TTFT 算术平均：Σ有效 ttft ÷ 有效调用数（每次调用**等权**）。与
    /// token 速率的 Σ/Σ 加权不同——TTFT 没有随调用变大的分子量纲，按调用数
    /// 平均即是窗口口径；MiniMax Code 的 0 也参与（0 是合法值，不是缺失）。
    /// 无有效样本返回 nil——宁出 `—` 不出假平均。
    nonisolated static func windowTTFTMeanSeconds(
        samples: [LocalTokenUsageSample]
    ) -> Double? {
        windowTTFTComponents(samples: samples).map { $0.sum / Double($0.count) }
    }

    /// `windowTTFTMeanSeconds` 的分量形态：返回 (Σttft, 有效调用数)，供
    /// `QuotaWindowUsageSnapshot.Window` 多额度池合并先 Σttft / Σ次数 再相除
    /// （模式照 `windowTokenRateComponents`）。有效性过滤与口径全仓只有这一
    /// 份，`windowTTFTMeanSeconds` 是它的商值形态。
    nonisolated static func windowTTFTComponents(
        samples: [LocalTokenUsageSample]
    ) -> (sum: Double, count: Int)? {
        let valid = samples.compactMap { sample -> Double? in
            guard hasValidTTFT(sample), let ttft = sample.ttftSeconds else { return nil }
            return ttft
        }
        guard !valid.isEmpty else { return nil }
        let sum = valid.reduce(0.0) { $0 + $1 }
        return (sum: sum, count: valid.count)
    }

    /// TTFT 有效性共享门（调用级分布与窗口平均同一份）：有限、`>= 0`、
    /// `<= 3600`（超 1h 多为账本异常）。**0 合法**——MiniMax Code 无上游数据、
    /// scanner 显式写 0，0 必须参与聚合；这与 `hasValidTokenRateDuration` 的
    /// `[0.2, 3600]` 下限不同：时长下限挡的是把速率拉成噪声的亚秒样本，而
    /// TTFT 本来就可以是亚秒级，不能用下限挡 0。
    private nonisolated static func hasValidTTFT(
        _ sample: LocalTokenUsageSample
    ) -> Bool {
        guard let ttft = sample.ttftSeconds else { return false }
        return ttft.isFinite && ttft >= 0 && ttft <= 3600
    }
}

/// 额度窗口内的本地 token 用量：短周期（`5h`）窗口与周窗口各一条。
///
/// 这是 provider 卡片「额度窗口用量」区块的**唯一**数据形状：额度行（每个 model
/// 一条）负责"还剩多少"，这个区块负责"这一轮额度里本机实际烧了多少"。
///
/// 两条窗口都可以是 `nil`（provider 只有其中一个窗口，或根本没有额度窗口——
/// 余额型 DeepSeek）。`usage` 为 `nil` 表示"窗口存在但本地没有记录"，与
/// "窗口不存在"在数据上仍是两件事；但 UI 上（第五轮改版）全零行整行跳过
/// （`QuotaWindowUsageSection.visibleRows`），两个模块都不出 `0 / —` 行。
struct QuotaWindowUsageSnapshot: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        /// 窗口标签（`5h` / `周` / minimax video 的 `日`），由调用方给——
        /// 标签口径归 `QuotaSummary` 管，这里不自造。
        let label: String
        let usage: UsageMetricSummary?
        let resetsAt: Date?
        /// 这一轮窗口里本地 token 的名义价值（原币种）。
        ///
        /// `nil` 有两种含义，UI 用 `—` 与「未定价」区分：
        /// 窗口内没有本地样本（还不值得估价）／样本全部未定价。后者由
        /// `ModelCostEstimate.displayText` 自己说，字段本身不重复这个信息。
        let cost: ModelCostEstimate?
        /// Fleet 聚合的完整计价说明（部分计价或混币）；本地窗口默认由 `cost` 推导。
        let costText: String?
        /// 窗口内本地 token 速度（tok/s）：Σ(Output+Reason) ÷ Σ单次调用时长，
        /// 只统计 `durationSeconds ∈ [0.2, 3600]` 的样本——口径唯一实现在
        /// `LocalUsageSummaryBuilder.windowTokenRate`。nil = 窗口内没有时长有效
        /// 的样本（不是"速度为 0"），UI 与 cost 的 `—` 同款处理。
        var tokensPerSecond: Double? = nil
        /// 速率合并用的中间量：Σ(Output+Reason)（billable 分子）与 Σ时长（秒，
        /// 分母）。与 `tokensPerSecond` 同源同批样本、由 `windowUsage` 一并写入，
        /// `combineWindowUsage` 靠它们先加和再相除（Σ/Σ，不是各池速率的平均）。
        /// 手工构造的 Window（fleet 行 / 测试夹具）缺省 nil，不参与速率合并。
        var rateNumerator: Double? = nil
        var rateDenominator: Double? = nil
        /// 窗口内本地调用的首字延迟均值（TTFT，秒）：Σ有效 ttft ÷ 有效调用数
        /// （算术平均，口径唯一实现在 `LocalUsageSummaryBuilder.windowTTFTMeanSeconds`）。
        /// nil = 窗口内没有 TTFT 有效的样本（不是"首字延迟为 0"），UI 与
        /// tokensPerSecond 的 `—` 同款处理。
        var ttftSeconds: Double? = nil
        /// TTFT 合并用的中间量：Σ有效 ttft（秒）与有效调用数。与 `ttftSeconds`
        /// 同源同批样本、由 `windowUsage` 一并写入，`combineWindowUsage` 靠它们
        /// 先 Σsum ÷ Σcount 再相除（模式照 rateNumerator/rateDenominator）。
        /// 手工构造的 Window（fleet 行 / 测试夹具）缺省 nil，不参与 TTFT 合并。
        var ttftSumSeconds: Double? = nil
        var ttftCallCount: Int? = nil

        init(
            label: String,
            usage: UsageMetricSummary?,
            resetsAt: Date?,
            cost: ModelCostEstimate?,
            costText: String? = nil,
            tokensPerSecond: Double? = nil,
            rateNumerator: Double? = nil,
            rateDenominator: Double? = nil,
            ttftSeconds: Double? = nil,
            ttftSumSeconds: Double? = nil,
            ttftCallCount: Int? = nil
        ) {
            self.label = label
            self.usage = usage
            self.resetsAt = resetsAt
            self.cost = cost
            self.costText = costText
            self.tokensPerSecond = tokensPerSecond
            self.rateNumerator = rateNumerator
            self.rateDenominator = rateDenominator
            self.ttftSeconds = ttftSeconds
            self.ttftSumSeconds = ttftSumSeconds
            self.ttftCallCount = ttftCallCount
        }
    }

    let interval: Window?
    let weekly: Window?
    /// 参与合计的额度池（model）数量。> 1 时重置时刻是"最早的那个"，UI 必须
    /// 在 hover 明细里说清楚，否则会被读成"这个 provider 只重置一次"。
    let poolCount: Int

    var isEmpty: Bool { interval == nil && weekly == nil }
}

extension LocalUsageSummaryBuilder {
    /// 单个 model 在两个额度窗口内的本地 token 用量。
    ///
    /// 窗口边界**单源**于同一份
    /// `windowBounds(resetsAt:explicitWindowSeconds:fallbackSeconds:)`
    /// 加同一份 `summary(…excludeWindows:excludeGlmOffPeak:)`。「额度窗口」表格的
    /// 5h / 周 行（经 `windowUsageSnapshot`）从这里取数，别处不再推第二套边界——
    /// 一旦各自算各自的 "5h 从什么时候开始"，两边的数就会对不上，而这种漂移只能
    /// 靠肉眼发现。
    ///
    /// - Parameters:
    ///   - intervalFallbackSeconds: 短周期窗口缺 `windowSeconds` 时的兜底长度
    ///     （minimax video 是 24h，其余 5h），由调用方按 `QuotaSummary` 的口径给。
    ///   - intervalUsageOverride / weeklyUsageOverride: **已经**按外部口径算好的
    ///     窗口用量（ChatGPT 的 `codexUsageDetails` 与 OpenCode 合并结果，见
    ///     `ChatGPTPlanModelRow.preferUsageDetails`）。给非 nil 时直接采用，
    ///     不再从 samples 重算——那些样本已经被 `codexUsageDetails` 统计过一次。
    ///   - quotaProviderID / deepseekPeakWindow: 计价用。价格目录按
    ///     QuotaProviderID 查表，DeepSeek 的峰时 ×2 还要按**每条样本的时刻**判，
    ///     所以窗口窗口内跨峰谷的一批样本不会被粗暴地整体乘 2。
    nonisolated static func windowUsage(
        model: ModelQuota,
        providerKind: ProviderKind,
        samples: [LocalTokenUsageSample],
        intervalLabel: String,
        weeklyLabel: String,
        intervalFallbackSeconds: TimeInterval = 5 * 60 * 60,
        excludeWindows: [GlmOffPeakWindow] = [],
        excludeGlmOffPeak: Bool = false,
        intervalUsageOverride: UsageMetricSummary? = nil,
        weeklyUsageOverride: UsageMetricSummary? = nil,
        quotaProviderID: String = "",
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) -> QuotaWindowUsageSnapshot {
        func window(
            _ label: String,
            resetsAt: Date?,
            windowSeconds: Int?,
            fallbackSeconds: TimeInterval,
            usageOverride: UsageMetricSummary?
        ) -> QuotaWindowUsageSnapshot.Window {
            let bounds = windowBounds(
                resetsAt: resetsAt,
                explicitWindowSeconds: windowSeconds,
                fallbackSeconds: fallbackSeconds
            )
            // 金额与 token 数**必须**用同一批样本：先按窗口口径筛出样本，聚合出
            // token 桶、逐条计价出金额。两条路各筛一次的话，DeepSeek 跨峰谷时
            // （×2 的只有一部分样本）金额会和"用这批 token 乘出来的钱"对不上。
            let windowSamples = Self.windowSamples(
                samples: samples,
                providerKind: providerKind,
                quotaModelName: model.modelName,
                start: bounds?.start,
                end: bounds?.end,
                excludeWindows: excludeWindows,
                excludeGlmOffPeak: excludeGlmOffPeak
            )
            // token 速度与金额同源：同用这批 windowSamples（usageOverride 存在时
            // 也是——cost 同样不因 override 跳过），分子分母一并带出给
            // combineWindowUsage 做 Σ/Σ 合并。
            let tokenRate = Self.windowTokenRateComponents(samples: windowSamples)
            // TTFT 与金额/速度同源：同用这批 windowSamples，Σsum/Σcount 一并带出
            // 给 combineWindowUsage 做多池合并（模式照 tokenRate）。
            let ttftParts = Self.windowTTFTComponents(samples: windowSamples)
            return QuotaWindowUsageSnapshot.Window(
                label: label,
                usage: usageOverride ?? (windowSamples.isEmpty
                    ? nil
                    : aggregate(windowSamples)),
                resetsAt: resetsAt,
                cost: windowSamples.isEmpty ? nil : ModelPricingCatalog.estimate(
                    samples: windowSamples,
                    quotaProviderID: quotaProviderID,
                    deepseekPeakWindow: deepseekPeakWindow
                ),
                tokensPerSecond: tokenRate.map { $0.numerator / $0.denominator },
                rateNumerator: tokenRate?.numerator,
                rateDenominator: tokenRate?.denominator,
                ttftSeconds: ttftParts.map { $0.sum / Double($0.count) },
                ttftSumSeconds: ttftParts?.sum,
                ttftCallCount: ttftParts?.count
            )
        }

        let intervalWindow: QuotaWindowUsageSnapshot.Window? = model.hasIntervalWindow
            ? window(
                intervalLabel,
                resetsAt: model.intervalResetsAt,
                windowSeconds: model.intervalWindowSeconds,
                fallbackSeconds: intervalFallbackSeconds,
                usageOverride: intervalUsageOverride
            )
            : nil

        let weeklyWindow: QuotaWindowUsageSnapshot.Window? = model.hasWeeklyWindow
            ? window(
                weeklyLabel,
                resetsAt: model.weeklyResetsAt,
                windowSeconds: model.weeklyWindowSeconds,
                fallbackSeconds: 7 * 24 * 60 * 60,
                usageOverride: weeklyUsageOverride
            )
            : nil

        return QuotaWindowUsageSnapshot(
            interval: intervalWindow,
            weekly: weeklyWindow,
            poolCount: 1
        )
    }

    /// provider 级合计：各 model 的同名窗口相加。
    ///
    /// **为什么相加而不是取最吃紧的那个 model**：额度行的 `modelMatches` 已经把样本
    /// 按 model 配额**互斥**切开（Antigravity 的两组按 3P / 非 3P 分，minimax 只有
    /// `general` 匹配 token 账本），所以各 model 的窗口用量互不重叠，相加就是
    /// "这个 provider 在这一轮额度窗口里本机烧了多少"的真值。取最吃紧的那个 model
    /// 反而会**丢掉**另一个池子的消耗——额度行是按 model 并排展示的，读者能自己对上，
    /// 区块只有一个数字，它必须回答整体。
    ///
    /// 窗口缺失的一侧不参与；重置时刻取**最早**的那个（多个 model 各自按自己的
    /// 节奏重置，取最早 = "离下一次重置还有多久"这个问题的答案）。
    ///
    /// 金额同样相加，但**只在币种一致时**相加：混币种时把两笔数加成一个数是编造
    /// （口径与 `ModelPricingCatalog.estimate` 里那处币种冲突的处理一致——落到
    /// "部分计价"而不是给出一个假的总价）。
    nonisolated static func combineWindowUsage(
        _ snapshots: [QuotaWindowUsageSnapshot]
    ) -> QuotaWindowUsageSnapshot {
        func merged(
            _ keyPath: KeyPath<QuotaWindowUsageSnapshot, QuotaWindowUsageSnapshot.Window?>
        ) -> QuotaWindowUsageSnapshot.Window? {
            let windows = snapshots.compactMap { $0[keyPath: keyPath] }
            guard let first = windows.first else { return nil }
            let present = windows.compactMap(\.usage)
            let total: UsageMetricSummary? = present.isEmpty
                ? nil
                : present.dropFirst().reduce(present[0], +)
            // 速率合并走 Σ分子 ÷ Σ时长（与单池同口径，精度优先），不是各池
            // tokensPerSecond 的算术平均——各池样本量与时长不同，平均会算错总速度。
            // 中间量只有 windowUsage 产出的窗口带（手工构造的 Window 缺省 nil），
            // 缺中间量的窗口无法参与加权，只能缺席：合并速率为 nil 时 UI 显示 —，
            // 不给一个口径错误的假平均。
            let rateParts = windows.compactMap { (window: QuotaWindowUsageSnapshot.Window)
                -> (numerator: Double, denominator: Double)? in
                guard let numerator = window.rateNumerator,
                      let denominator = window.rateDenominator else { return nil }
                return (numerator, denominator)
            }
            var mergedRate: (numerator: Double, denominator: Double)? = nil
            if !rateParts.isEmpty {
                let numerator = rateParts.reduce(0) { $0 + $1.numerator }
                let denominator = rateParts.reduce(0) { $0 + $1.denominator }
                if denominator.isFinite, denominator > 0 {
                    mergedRate = (numerator, denominator)
                }
            }
            // TTFT 合并走 Σttft ÷ Σ调用数（与单池同口径），不是各池 ttftSeconds
            // 的算术平均——各池调用数不同，平均会算错整体首字延迟。中间量只有
            // windowUsage 产出的窗口带（手工构造的 Window 缺省 nil），缺中间量的
            // 窗口不参与加权、只能缺席；全部缺席时合并结果为 nil（UI 显示 —），
            // 不给一个口径错误的假平均。
            let ttftParts = windows.compactMap { (window: QuotaWindowUsageSnapshot.Window)
                -> (sum: Double, count: Int)? in
                guard let sum = window.ttftSumSeconds,
                      let count = window.ttftCallCount else { return nil }
                return (sum, count)
            }
            var mergedTTFT: (sum: Double, count: Int)? = nil
            if !ttftParts.isEmpty {
                let sum = ttftParts.reduce(0) { $0 + $1.sum }
                let count = ttftParts.reduce(0) { $0 + $1.count }
                if sum.isFinite, count > 0 {
                    mergedTTFT = (sum, count)
                }
            }
            return QuotaWindowUsageSnapshot.Window(
                label: first.label,
                usage: total,
                resetsAt: windows.compactMap(\.resetsAt).min(),
                cost: mergeCost(windows.compactMap(\.cost)),
                tokensPerSecond: mergedRate.map { $0.numerator / $0.denominator },
                rateNumerator: mergedRate?.numerator,
                rateDenominator: mergedRate?.denominator,
                ttftSeconds: mergedTTFT.map { $0.sum / Double($0.count) },
                ttftSumSeconds: mergedTTFT?.sum,
                ttftCallCount: mergedTTFT?.count
            )
        }
        return QuotaWindowUsageSnapshot(
            interval: merged(\.interval),
            weekly: merged(\.weekly),
            poolCount: snapshots.filter { !$0.isEmpty }.count
        )
    }

    /// 若干个 model 池的金额合并成一条。币种不一致（或有一侧完全估不出）时返回
    /// nil，UI 显示 `—`——宁可少一个数，也不要给一个跨币种的假总价。
    private nonisolated static func mergeCost(
        _ estimates: [ModelCostEstimate]
    ) -> ModelCostEstimate? {
        guard !estimates.isEmpty else { return nil }
        let currencies = Set(estimates.compactMap(\.currency))
        let values = estimates.compactMap(\.value)
        guard currencies.count == 1, !values.isEmpty else { return nil }
        return ModelCostEstimate(
            value: values.reduce(0, +),
            currency: currencies.first,
            pricedModelNames: Set(estimates.flatMap(\.pricedModelNames)).sorted(),
            unpricedModelNames: Set(estimates.flatMap(\.unpricedModelNames)).sorted()
        )
    }
}

/// GLM 本地任务的 provider 分类（与 GLM 卡额度窗口白名单同一口径）。
/// 弹窗卡片维持合并汇总；设置 → 客户端 → ZCode 按此分类拆行展示
/// （对齐 Antigravity 按模型分组拆行的模式）。
///
/// **声明序即行序**：`ClientUsageAggregation.glmUsageRows` 按 `allCases` 顺序输出
/// 空组被跳过的行，所以新增 case 时把它放在想要的位置即可（GLM 行之下再跟
/// DeepSeek / MiniMax 分片行，见 `ClientUsageAggregation.zcodeRowRank`）。
enum GlmUsageCategory: String, CaseIterable, Sendable {
    /// 正式 Coding Plan（显式全集见
    /// `OpencodeLocalUsage.zcodeGlmCodingPlanProviderIDs`，唯一计入额度窗口的
    /// 来源；无来源标记与 OpenCode / DSH 合并样本也归此类）
    case normal
    /// 体验套餐 Start Plan（`provider_id` 含 `bigmodel-start-plan`，如
    /// `account:bigmodel-start-plan` / `builtin:bigmodel-start-plan`）。
    /// 从「其他任务」里单独拆出成行，不消耗积分 —— 额度窗口口径不受影响
    /// （仍由 `isGlmOtherPlanSample` 整体排除，见 `summary(excludeWindows:)`）。
    case startPlan
    /// 加速卡（显式全集见 `OpencodeLocalUsage.zcodeGlmHighspeedProviderIDs`，
    /// ZCode highspeed-card 权益，model_id 是普通 GLM 模型）。从「其他任务」里
    /// 单独拆出成行，不消耗积分 —— 额度窗口口径不受影响（仍由
    /// `isGlmOtherPlanSample` 整体覆盖，见 `summary(excludeWindows:)`）。
    case highSpeed
    /// 闲时任务（显式全集见 `OpencodeLocalUsage.zcodeOffPeakProviderIDs`，
    /// 含账号化新 ID 与历史裸值，不消耗积分）
    case offPeak
    /// 其他智谱套餐（智谱前缀下未登记进上述集合的 provider，如未来新套餐，
    /// 不消耗积分）
    case other

    var displayName: String {
        switch self {
        case .normal: return "Coding Plan"
        case .startPlan: return "Start Plan"
        case .highSpeed: return "加速卡"
        case .offPeak: return "闲时任务"
        case .other: return "其他任务"
        }
    }

    /// sample → 分类。无来源标记（旧缓存 / 手工构造）与 OpenCode / DSH 合并
    /// 样本都归 Coding Plan —— 与额度窗口白名单的兼容回退语义保持一致。
    /// 判定序 offPeak → startPlan → highSpeed → other 保持五个分类互斥。
    nonisolated static func classify(_ sample: LocalTokenUsageSample) -> GlmUsageCategory {
        if LocalUsageSummaryBuilder.isGlmOffPeakSample(sample, fallbackWindows: []) {
            return .offPeak
        }
        if LocalUsageSummaryBuilder.isGlmStartPlanSample(sample) {
            return .startPlan
        }
        if LocalUsageSummaryBuilder.isGlmHighspeedSample(sample) {
            return .highSpeed
        }
        if LocalUsageSummaryBuilder.isGlmOtherPlanSample(sample) {
            return .other
        }
        return .normal
    }
}
