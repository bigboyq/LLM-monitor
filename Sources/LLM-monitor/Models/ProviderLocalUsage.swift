import Foundation

/// 单源本地 token 用量快照容器 —— antigravity（RPC + .db step 统计）与
/// minimax（v2 runtime-state 单库 SQL）共享的同构形态。
///
/// `dailyTokenUsage` 总是包含最近 7 个本地自然日（包含今天），按日升序。
/// `today` 单独冗余存一份，避免 UI 每次都 `dailyTokenUsage.last`。
///
/// 两个来源原本各自维护字段完全同构的 `AntigravityLocalUsage` /
/// `MinimaxLocalUsage`（含逐字相同的自定义 `==`），现收口为单一类型 +
/// 保留原名 typealias（JSON 键不变，on-disk 缓存无需迁移）。
/// GLM 容器多一个 `offPeakWindows` 字段、opencode / dsh 是 byProvider 分片
/// 形态，均不参与本次合并。
struct ProviderLocalUsage: Equatable, Codable, Sendable {
    /// 今日聚合（本地时区今天 00:00 至今）
    let today: LocalDailyTokenUsage?

    /// 最近 7 个本地自然日（升序）
    let dailyTokenUsage: [LocalDailyTokenUsage]

    /// 扫描完成时间（用于 UI 展示"更新于 HH:MM"）
    let scannedAt: Date?

    /// 命中的本地 session 数（antigravity 含未成功拉取元数据的；minimax 去重后）
    let sessionCount: Int

    /// 解析到的事件总数（antigravity = generatorMetadata 事件；minimax = token_usage 行数）
    let eventCount: Int

    /// 失败 session 数（minimax 单库下恒为 0，保留字段对齐语义）
    let failedSessionCount: Int

    /// 最近额度窗口内的逐次模型调用，用于 Last Prompt 与窗口累计 hover。
    /// optional 让旧的持久化结果仍可解码；UI 统一按空数组处理 nil。
    let recentSamples: [LocalTokenUsageSample]?

    static let empty = ProviderLocalUsage(
        today: nil,
        dailyTokenUsage: [],
        scannedAt: nil,
        sessionCount: 0,
        eventCount: 0,
        failedSessionCount: 0,
        recentSamples: []
    )

    init(
        today: LocalDailyTokenUsage?,
        dailyTokenUsage: [LocalDailyTokenUsage],
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
    /// 业务字段决定内容是否真变；Codable 合成的 CodingKeys 不受影响 ——
    /// `scannedAt` 仍然被编解码。
    static func == (lhs: ProviderLocalUsage, rhs: ProviderLocalUsage) -> Bool {
        lhs.today == rhs.today
            && lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.failedSessionCount == rhs.failedSessionCount
            && lhs.recentSamples == rhs.recentSamples
    }
}

// MARK: - 历史类型名（保留原名，调用方与测试零改动）

typealias AntigravityLocalUsage = ProviderLocalUsage
typealias MinimaxLocalUsage = ProviderLocalUsage
