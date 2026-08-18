import Foundation

/// opencode 本地 token 用量（按 provider 分片）。
///
/// 数据来源：opencode 的 SQLite `~/.local/share/opencode/opencode.db` `message` 表 ——
/// 每条 assistant message 的 `data` JSON 自带 `providerID` + `tokens{input,output,reasoning,
/// cache.{read,write}}` + `time.created`。opencode 是**多 provider 共享账本**（同一台机器
/// 可能既有 minimax 又有 GLM 调用），scanner 一次扫描按 `providerID` 分片：
/// - `zhipuai-coding-plan` → GLM 卡的 OpenCode 合并来源
/// - `minimax-cn-coding-plan` → Minimax Token Plan 卡的 OpenCode 合并来源
/// - `openai` → ChatGPT 卡的 OpenCode 合并来源
/// - Antigravity provider 使用若干兼容 ID 读取（当前没有数据时自然为空）
/// - `minimax` → 仅在 Opencode 诊断页保留，属于本地能力账本，不参与 Minimax 卡
///
/// opencode 自身不作为 menu bar 卡片展示 —— 它是后台数据源，只在设置面板有只读诊断。
struct OpencodeLocalUsage: Equatable, Codable, Sendable {
    /// key = opencode 的 `providerID`（如 `zhipuai-coding-plan` / `minimax`）
    let byProvider: [String: OpencodeProviderUsage]
    /// 各 provider 见过的 `modelID`（诊断面板用）
    let modelsByProvider: [String: [String]]
    /// 扫描的 db 路径（诊断面板用）
    let dbPath: String?
    let scannedAt: Date?

    static let empty = OpencodeLocalUsage(
        byProvider: [:], modelsByProvider: [:], dbPath: nil, scannedAt: nil
    )

    /// GLM Coding Plan 在 opencode 里的 providerID
    static let glmProviderID = "zhipuai-coding-plan"
    /// ZCode（智谱官方 CLI）中 GLM Coding Plan 的 providerID（native 源）
    static let zcodeGlmProviderID = "builtin:bigmodel-coding-plan"
    /// ZCode 中闲时任务（off-peak idle task）的 providerID。系统赠送的后台任务，
    /// 不消耗 Coding Plan 积分，`model_usage` 行写在同一张表但用独立 provider 区分。
    static let zcodeOffPeakProviderID = "offpeak-idle-plan"
    /// minimax 在 opencode 里的 providerID
    static let minimaxProviderID = "minimax"
    /// Minimax Token Plan 在 opencode 里的 providerID
    static let minimaxCodingPlanProviderID = "minimax-cn-coding-plan"
    /// ChatGPT / OpenAI 在 opencode 里的 providerID
    static let openAIProviderID = "openai"
    /// DeepSeek 在 opencode 里的 providerID
    static let deepseekProviderID = "deepseek"
    /// Antigravity 可能使用的 providerID。不同 OpenCode 版本 / 配置可能落在其中之一。
    static let antigravityProviderIDs = [
        "antigravity",
        "google-antigravity",
        "google-vertex",
        "google"
    ]

    /// GLM 分片（便捷访问）
    var glmSlice: OpencodeProviderUsage? { byProvider[Self.glmProviderID] }
    /// minimax 分片（便捷访问）
    var minimaxSlice: OpencodeProviderUsage? { byProvider[Self.minimaxProviderID] }
    /// Minimax Token Plan 分片；不包含 `minimax` 本地能力分片。
    var minimaxCodingPlanSlice: OpencodeProviderUsage? {
        byProvider[Self.minimaxCodingPlanProviderID]
    }
    /// OpenAI / ChatGPT 分片。
    var openAISlice: OpencodeProviderUsage? { byProvider[Self.openAIProviderID] }
    /// DeepSeek 分片。
    var deepseekSlice: OpencodeProviderUsage? { byProvider[Self.deepseekProviderID] }
    /// Antigravity 分片。若多个兼容 ID 同时存在则逐项相加。
    var antigravitySlice: OpencodeProviderUsage? {
        let slices = Self.antigravityProviderIDs.compactMap { byProvider[$0] }
        return OpencodeProviderUsage.merged(slices)
    }

    /// 自定义 `==` 排除 `scannedAt` —— metadata 每次扫描都变，不能让它每次都触发 UI reload。
    static func == (lhs: OpencodeLocalUsage, rhs: OpencodeLocalUsage) -> Bool {
        lhs.byProvider == rhs.byProvider
            && lhs.modelsByProvider == rhs.modelsByProvider
            && lhs.dbPath == rhs.dbPath
    }
}

/// 单个 provider 的 7 天用量聚合（同构 `MinimaxLocalUsage` 的相关字段）。
struct OpencodeProviderUsage: Equatable, Codable, Sendable {
    /// 今日聚合（本地时区今天 00:00 至今）
    let today: OpencodeDailyUsage?
    /// 最近 7 个本地自然日（升序，含今天）
    let dailyTokenUsage: [OpencodeDailyUsage]
    /// 该 provider 的累计、有 token 的 LLM round 数。
    let roundCount: Int
    /// 该 provider 的累计 cost（GLM 订阅制恒为 0）
    let cost: Double
    /// 最近 8 天的逐次 assistant 调用，供 quota 窗口内 token 汇总使用。
    let recentSamples: [LocalTokenUsageSample]
}

extension OpencodeProviderUsage {
    /// 合并多个 OpenCode provider alias，供 Antigravity 兼容不同 providerID。
    /// sample 的 promptID 加上来源前缀，避免跨 alias 合并时错误去重。
    static func merged(_ usages: [OpencodeProviderUsage]) -> OpencodeProviderUsage? {
        guard let first = usages.first else { return nil }
        return usages.dropFirst().enumerated().reduce(first) { result, item in
            let (index, usage) = item
            return result.merging(usage, samplePrefix: "alias\(index + 1)")
        }
    }

    func merging(_ other: OpencodeProviderUsage, samplePrefix: String? = nil) -> OpencodeProviderUsage {
        let mergedDaily = Self.mergeDaily(dailyTokenUsage, other.dailyTokenUsage)
        let lhsToday = today
        let rhsToday = other.today
        let mergedToday: OpencodeDailyUsage?
        switch (lhsToday, rhsToday) {
        case let (lhs?, rhs?): mergedToday = lhs + rhs
        case let (value?, nil), let (nil, value?): mergedToday = value
        case (nil, nil): mergedToday = nil
        }
        let prefix = samplePrefix.map { "opencode:\($0):" }
        // Alias providerID 可能指向同一批历史消息；比较原始 promptID，避免加
        // alias 命名空间后把同一轮调用当成两轮。保留 first-wins 的稳定结果。
        var seenPromptIDs = Set(recentSamples.map(\.promptID))
        let otherSamples = other.recentSamples.compactMap { sample -> LocalTokenUsageSample? in
            guard seenPromptIDs.insert(sample.promptID).inserted else { return nil }
            guard let prefix else { return sample }
            return sample.withPromptIDPrefix(prefix)
        }
        return OpencodeProviderUsage(
            today: mergedToday,
            dailyTokenUsage: mergedDaily,
            roundCount: SaturatingArithmetic.add(roundCount, other.roundCount),
            cost: cost + other.cost,
            recentSamples: recentSamples + otherSamples
        )
    }

    private static func mergeDaily(
        _ lhs: [OpencodeDailyUsage],
        _ rhs: [OpencodeDailyUsage]
    ) -> [OpencodeDailyUsage] {
        var byDay = Dictionary(uniqueKeysWithValues: lhs.map { ($0.dayStart, $0) })
        for day in rhs {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }
}
