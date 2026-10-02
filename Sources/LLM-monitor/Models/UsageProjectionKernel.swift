import Foundation

// Provider × Harness 统一投影内核（P1）。
//
// 三层结构：
// - L0 各 scanner/reader：IO / 解码 / 预算 / 缓存，产出各 harness 自己的快照类型。
// - L1 适配（`HarnessUsageFrame`）：把一个 harness 的原始聚合成若干「帧」。
//   一帧 = 一个 (clientID, 切片键, quota 归属)。帧是内存态中间物，不落盘。
// - L2 内核（`UsageProjectionKernel.project`）：把帧按 (clientID, quotaProviderID)
//   归并成 `ProviderHarnessProjection` —— 7 天 daily + per-model 四桶 + 名义价值。
//
// 视图模型（`ClientUsageContribution` / `ProviderUsageProjection` /
// `ClientProviderUsageSummary`）只消费内核输出，不再自己算合并规则。

// MARK: - promptID 命名空间登记表

/// promptID 命名空间登记表：**每个 source 一条**。
///
/// 多份本地账本（codex / opencode / zcode / dsh / antigravity / minimax code）
/// 可能恰好使用相同的 prompt ID；不加命名空间会被去重成"同一次用户请求"，
/// turns 计数因此偏低。规则收口在这里，新增 harness 只需登记一条。
///
/// 登记项与实际口径：
/// - `native`：Antigravity / MiniMax Code / ZCode 智谱 native —— 各自独立账本，
///   保持裸格式（历史行为，不改）。
/// - `codex`：Codex scanner 已在构造点自带 `codex:` 前缀，这里保持不叠加。
/// - `dsh`：DSH scanner 原生 promptID 已含 `dsh:` 会话标识；本层只补**一层**
///   `dsh:<provider>:` 归因（旧 `DshUsageMerger` 叠的是 `dsh:dsh:<provider>:`，
///   属本阶段唯一允许的差异）。
/// - `opencode`：`opencode:<provider>:`（OpenCode 一份多 provider 账本）。
/// - `zcodeSlice`：`zcode:<slice>:`（ZCode 账本里的非智谱 provider 分片）。
enum UsageSampleNamespace: Sendable, Equatable, CaseIterable {
    case native
    case codex
    case dsh
    case opencode
    case zcodeSlice

    /// 施加到 promptID 前的命名空间；nil = 保持原样。
    /// `sourceKey` 为 nil 时退化为 `unknown`（与旧 merger 的兼容回退一致）。
    func prefix(sourceKey: String?) -> String? {
        switch self {
        case .native, .codex:
            return nil
        case .dsh:
            return "dsh:\(sourceKey ?? Self.unknownSourceKey):"
        case .opencode:
            return "opencode:\(sourceKey ?? Self.unknownSourceKey):"
        case .zcodeSlice:
            return "zcode:\(sourceKey ?? Self.unknownSourceKey):"
        }
    }

    func apply(
        to samples: [LocalTokenUsageSample],
        sourceKey: String? = nil
    ) -> [LocalTokenUsageSample] {
        guard let prefix = prefix(sourceKey: sourceKey) else { return samples }
        return samples.map { $0.withPromptIDPrefix(prefix) }
    }

    static let unknownSourceKey = "unknown"
}

// MARK: - L1 帧

/// 一个 harness 切片的用量帧（L1 适配产物）。
///
/// 帧已经是「同一 quota 归属下、同一个来源键」的最小单位：多个切片键的帧
/// 由内核相加。因此 DSH 这类"一份账本多 provider 路由"的数据源按 provider 键
/// 切帧，而不是先在适配层合并。
struct HarnessUsageFrame: Equatable, Sendable {
    let clientID: String
    /// harness 内切片键（opencode providerID / dsh provider 键 / zcode slice；
    /// 单源账本为 nil）。同时是 promptID 命名空间的归因键。
    let sourceKey: String?
    /// 归一后的 quota 归属。
    let quotaProviderID: String
    let daily: [UnifiedDailyTokenUsage]
    /// 已带终态 promptID 命名空间的逐次调用样本。
    let samples: [LocalTokenUsageSample]
    /// 来源快照的统计口径被截断（如 DSH 文件数/字节预算挤出最旧 session）。
    var isTruncated: Bool = false
    let scannedAt: Date?

    init<Daily: LocalUsageDaily>(
        clientID: String,
        sourceKey: String? = nil,
        quotaProviderID: String,
        daily: [Daily],
        samples: [LocalTokenUsageSample] = [],
        namespace: UsageSampleNamespace = .native,
        isTruncated: Bool = false,
        scannedAt: Date? = nil
    ) {
        self.init(
            clientID: clientID,
            sourceKey: sourceKey,
            quotaProviderID: quotaProviderID,
            daily: daily.map { UnifiedDailyTokenUsage($0) },
            samples: namespace.apply(to: samples, sourceKey: sourceKey),
            isTruncated: isTruncated,
            scannedAt: scannedAt
        )
    }

    init(
        clientID: String,
        sourceKey: String? = nil,
        quotaProviderID: String,
        daily: [UnifiedDailyTokenUsage],
        samples: [LocalTokenUsageSample] = [],
        isTruncated: Bool = false,
        scannedAt: Date? = nil
    ) {
        self.clientID = clientID
        self.sourceKey = sourceKey
        self.quotaProviderID = quotaProviderID
        self.daily = daily
        self.samples = samples
        self.isTruncated = isTruncated
        self.scannedAt = scannedAt
    }
}

// MARK: - L2 投影

/// 一个 (clientID × quotaProviderID) 的内核投影。
///
/// 这是"Provider × Harness 统一计算"的唯一产物：卡片层与设置页读的都是它，
/// 不再各自实现合并规则。
struct ProviderHarnessProjection: Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    /// 7 天 daily（已合并同一天的各帧，并按样本修补当日滞后值）。
    let daily: [UnifiedDailyTokenUsage]
    /// 归并后的逐次调用样本（已带命名空间）。
    let samples: [LocalTokenUsageSample]
    /// per-model 四桶（input / cacheRead / output / reasoning），按模型名分组。
    /// 模型名缺失（nil / 空串）归入 `ProviderHarnessProjection.unknownModelName`。
    let perModel: [String: TokenUsageBuckets]
    /// 名义价值（`ModelPricingCatalog.estimate`，DeepSeek 峰时倍率已登记表化）。
    let value: ModelCostEstimate
    /// 任一帧截断即整份展示数据按截断处理（保守取 true）。
    let isTruncated: Bool
    let scannedAt: Date?

    /// perModel 里代表"模型名缺失"的键。
    static let unknownModelName = "模型名缺失"
}

// MARK: - 内核

/// Provider × Harness 统一投影内核。
enum UsageProjectionKernel {
    /// 帧 → 投影。输出顺序 = 各 (clientID, quotaProviderID) 组首次出现的顺序，
    /// 与帧顺序一致（视图层依赖稳定的行序）。
    ///
    /// - `bindings`：client → quota 的显式绑定。帧自带 `quotaProviderID` 时直接采用；
    ///   只有帧未声明归属（空串）时才用绑定的 `sourceProviderAliases` 兜底解析。
    ///   P1 阶段调用方传空数组（开关仍由 `mergeOpencodeUsage` / `mergeZcodeUsage`
    ///   承担），P2 起由 config 显式化。
    /// - `deepseekPeakWindow`：名义价值用的峰谷窗口（默认官方口径）。
    static func project(
        frames: [HarnessUsageFrame],
        bindings: [ClientProviderBinding] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) -> [ProviderHarnessProjection] {
        var groups: [ProjectionGroup] = []
        var indexByKey: [String: Int] = [:]
        for frame in frames {
            let quotaProviderID = resolveQuotaProviderID(frame, bindings: bindings)
            let key = "\(frame.clientID)\u{1}\(quotaProviderID)"
            guard let index = indexByKey[key] else {
                indexByKey[key] = groups.count
                groups.append(ProjectionGroup(
                    clientID: frame.clientID,
                    quotaProviderID: quotaProviderID
                ))
                groups[groups.count - 1].absorb(frame)
                continue
            }
            groups[index].absorb(frame)
        }

        return groups.map { group in
            let samples = group.samples
            return ProviderHarnessProjection(
                clientID: group.clientID,
                quotaProviderID: group.quotaProviderID,
                daily: UnifiedDailyUsageNormalizer.includingCurrentDay(
                    dailyTokenUsage: group.daily,
                    samples: samples,
                    now: now,
                    calendar: calendar
                ),
                samples: samples,
                perModel: perModelBuckets(samples),
                value: ModelPricingCatalog.estimate(
                    samples: samples,
                    quotaProviderID: group.quotaProviderID,
                    deepseekPeakWindow: deepseekPeakWindow
                ),
                isTruncated: group.isTruncated,
                scannedAt: group.scannedAt
            )
        }
    }

    /// 截断标志的合并规则：任一来源截断即截断（快照级口径，不随 provider 分片稀释）。
    static func anyTruncated(_ frames: [HarnessUsageFrame]) -> Bool {
        frames.contains(where: \.isTruncated)
    }

    /// 帧未声明 quota 归属时，用绑定的 `sourceProviderAliases` 解析。
    private static func resolveQuotaProviderID(
        _ frame: HarnessUsageFrame,
        bindings: [ClientProviderBinding]
    ) -> String {
        guard frame.quotaProviderID.isEmpty else { return frame.quotaProviderID }
        guard let sourceKey = frame.sourceKey else { return "" }
        return bindings.first { binding in
            guard binding.clientID == frame.clientID, binding.enabled else { return false }
            let value = sourceKey.lowercased()
            return binding.sourceProviderAliases.contains { alias in
                let needle = alias.lowercased()
                return value == needle || value.contains(needle)
            }
        }?.quotaProviderID ?? ""
    }

    /// 样本按模型名分组的四桶聚合。桶转换统一走 `TokenUsageBuckets.fromSample`。
    private static func perModelBuckets(
        _ samples: [LocalTokenUsageSample]
    ) -> [String: TokenUsageBuckets] {
        var result: [String: TokenUsageBuckets] = [:]
        for sample in samples {
            let name = sample.modelName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (name?.isEmpty == false) ? name! : ProviderHarnessProjection.unknownModelName
            let buckets = TokenUsageBuckets.fromSample(sample)
            result[key] = result[key].map {
                TokenUsageBuckets(
                    input: SaturatingArithmetic.add($0.input, buckets.input),
                    cacheRead: SaturatingArithmetic.add($0.cacheRead, buckets.cacheRead),
                    output: SaturatingArithmetic.add($0.output, buckets.output),
                    reasoning: SaturatingArithmetic.add($0.reasoning, buckets.reasoning)
                )
            } ?? buckets
        }
        return result
    }

    /// 归并累加器。帧顺序决定组顺序，逐日相加用饱和算术。
    private struct ProjectionGroup {
        let clientID: String
        let quotaProviderID: String
        var dailyByDay: [Date: UnifiedDailyTokenUsage] = [:]
        var samples: [LocalTokenUsageSample] = []
        var isTruncated: Bool = false
        var scannedAt: Date?

        /// 组内逐日相加后的 daily（按日升序）。当日 max 修补由内核的
        /// `UnifiedDailyUsageNormalizer` 在这一步之后统一施加。
        var daily: [UnifiedDailyTokenUsage] {
            dailyByDay.values.sorted { $0.dayStart < $1.dayStart }
        }

        mutating func absorb(_ frame: HarnessUsageFrame) {
            for day in frame.daily {
                dailyByDay[day.dayStart] = dailyByDay[day.dayStart].map { $0 + day } ?? day
            }
            samples.append(contentsOf: frame.samples)
            isTruncated = isTruncated || frame.isTruncated
            if let scanned = frame.scannedAt {
                scannedAt = max(scannedAt ?? scanned, scanned)
            }
        }
    }
}

// MARK: - DSH 适配（L1）

/// DSH（DeepSeek Harness）共享账本 → 帧。
///
/// dsh 是一份多 provider 路由的 session 账本。这里按**单个 provider 键**切帧
/// （而不是先合并成一份 `DshProviderUsage`），归并交给内核：
/// - 同一天的多个 provider 帧由内核相加（等价于旧 `mergeDaily` 的逐日相加）；
/// - 每个 provider 帧的样本带 `dsh:<provider>:` 单层命名空间，跨路由仍能区分
///   prompt，不会被误去重。
enum DshHarnessFrames {
    static let deepseekProviderIDs = ["deepseek", "deepseek-official", "deepseek-cn", "deepseek-v4"]
    static let minimaxProviderIDs = ["minimax", "minimax-cn", "minimax-cn-coding-plan"]
    static let glmProviderIDs = ["glm", "zhipu", "zhipuai", "bigmodel", "builtin:bigmodel-coding-plan", "account:bigmodel-individual-coding-plan"]

    /// quota 归属 → 该卡消费的 dsh provider 别名。
    static func providerIDs(forQuotaProviderID quotaProviderID: String) -> [String] {
        switch quotaProviderID {
        case QuotaProviderID.deepseek: return deepseekProviderIDs
        case QuotaProviderID.minimax: return minimaxProviderIDs
        case QuotaProviderID.zhipu: return glmProviderIDs
        default: return []
        }
    }

    /// 快照 → 每 provider 键一帧（键名升序，保证样本拼接顺序稳定）。
    /// 没有命中任何别名时返回空数组（等价旧行为的 nil：不产生贡献）。
    static func frames(
        from usage: DshLocalUsage?,
        quotaProviderID: String
    ) -> [HarnessUsageFrame] {
        guard let usage else { return [] }
        let aliases = providerIDs(forQuotaProviderID: quotaProviderID)
        guard aliases.isEmpty == false else { return [] }
        return usage.byProvider.keys
            .filter { matches($0, aliases: aliases) }
            .sorted()
            .compactMap { key in
                guard let provider = usage.byProvider[key] else { return nil }
                return HarnessUsageFrame(
                    clientID: ClientID.dsh,
                    sourceKey: key,
                    quotaProviderID: quotaProviderID,
                    daily: Self.daily(of: provider),
                    samples: provider.recentSamples,
                    namespace: .dsh,
                    isTruncated: usage.isTruncated == true,
                    scannedAt: usage.scannedAt
                )
            }
    }

    /// 截断标志的多来源合并规则（供 UI 展示链与回归测试直接引用）。
    /// `nil` 视为未截断 / 未知（旧缓存快照），不触发提示。
    static func anyTruncated(_ usages: DshLocalUsage?...) -> Bool {
        usages.contains { $0?.isTruncated == true }
    }

    /// provider 键的 daily：逐日取值，并把 `today` 补进窗口（若 daily 里没有该日）。
    private static func daily(of provider: DshProviderUsage) -> [UnifiedDailyTokenUsage] {
        var byDay: [Date: UnifiedDailyTokenUsage] = [:]
        if let today = provider.today,
           provider.dailyTokenUsage.contains(where: { $0.dayStart == today.dayStart }) == false {
            byDay[today.dayStart] = UnifiedDailyTokenUsage(today)
        }
        for day in provider.dailyTokenUsage {
            let unified = UnifiedDailyTokenUsage(day)
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + unified } ?? unified
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func matches(_ providerID: String, aliases: [String]) -> Bool {
        let value = providerID.lowercased()
        return aliases.contains { alias in
            let needle = alias.lowercased()
            return value == needle || value.contains(needle)
        }
    }
}
