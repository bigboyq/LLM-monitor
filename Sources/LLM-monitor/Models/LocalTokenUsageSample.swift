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

/// 额度窗口内的本地 token 用量：短周期（`5h`）窗口与周窗口各一条。
///
/// 这是 provider 卡片「额度窗口用量」区块的**唯一**数据形状：额度行（每个 model
/// 一条）负责"还剩多少"，这个区块负责"这一轮额度里本机实际烧了多少"。
///
/// 两条窗口都可以是 `nil`（provider 只有其中一个窗口，或根本没有额度窗口——
/// 余额型 DeepSeek）。`usage` 为 `nil` 表示"窗口存在但本地没有记录"，与
/// "窗口不存在"是两件事：前者画一行 0 / `—`，后者整行不画。
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
    /// 窗口边界与 `CombinedQuotaWindowRow.primaryUsage` / `weeklyUsage`
    /// **同源**：同一份 `windowBounds(resetsAt:explicitWindowSeconds:fallbackSeconds:)`
    /// 加同一份 `summary(…excludeWindows:excludeGlmOffPeak:)`。这里不再推第二套
    /// 边界——两处一旦各自算各自的 "5h 从什么时候开始"，区块里的数和 hover 明细
    /// 里的数就会对不上，而这种漂移只能靠肉眼发现。
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
                )
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
            return QuotaWindowUsageSnapshot.Window(
                label: first.label,
                usage: total,
                resetsAt: windows.compactMap(\.resetsAt).min(),
                cost: mergeCost(windows.compactMap(\.cost))
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
/// **声明序即行序**：`SettingsView.glmUsageRows` 按 `allCases` 顺序输出空组被
/// 跳过的行，所以新增 case 时把它放在想要的位置即可（GLM 行之下再跟
/// DeepSeek / MiniMax 分片行，见 `SettingsView.zcodeRowOrder`）。
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
        case .offPeak: return "闲时任务"
        case .other: return "其他任务"
        }
    }

    /// sample → 分类。无来源标记（旧缓存 / 手工构造）与 OpenCode / DSH 合并
    /// 样本都归 Coding Plan —— 与额度窗口白名单的兼容回退语义保持一致。
    nonisolated static func classify(_ sample: LocalTokenUsageSample) -> GlmUsageCategory {
        if LocalUsageSummaryBuilder.isGlmOffPeakSample(sample, fallbackWindows: []) {
            return .offPeak
        }
        if LocalUsageSummaryBuilder.isGlmStartPlanSample(sample) {
            return .startPlan
        }
        if LocalUsageSummaryBuilder.isGlmOtherPlanSample(sample) {
            return .other
        }
        return .normal
    }
}
