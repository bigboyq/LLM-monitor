import Foundation

/// GLM 官方客户端（ZCode CLI）本地 token 用量聚合（同构 MinimaxLocalUsage）。
///
/// 数据来源：ZCode 的 SQLite `~/.zcode/cli/db/db.sqlite` `model_usage` 表 ——
/// 每行一次模型请求，带 `provider_id='builtin:bigmodel-coding-plan'` + `model_id='GLM-5.2'`
/// + 5 类 token（`input_tokens` / `output_tokens` / `reasoning_tokens` /
/// `cache_creation_input_tokens` / `cache_read_input_tokens`）+ 原生 `turn_id`。
///
/// 跟 minimax / opencode 的关键区别：
/// - **单源**（一个 zcode db），不是双源 union
/// - **原生 reasoning**（GLM-5.2 账单自带 reasoning tokens），不需要字符分摊
/// - **原生 turn_id**：turns 直接 `COUNT(DISTINCT turn_id)`（ZCode 一次 user prompt
///   触发的多次模型调用共享同一个 turn_id）；rounds = `COUNT(*)`（每行 = 一次模型请求，
///   含主 agent / subagent / retry / title 生成）
///
/// `dailyTokenUsage` 总是包含最近 7 个本地自然日（包含今天），按日升序。
/// `today` 单独冗余存一份，避免 UI 每次都 `dailyTokenUsage.last`。
struct GlmLocalUsage: Equatable, Codable, Sendable {
    /// 今日聚合（本地时区今天 00:00 至今）
    let today: GlmDailyUsage?

    /// 最近 7 个本地自然日（升序）
    let dailyTokenUsage: [GlmDailyUsage]

    /// 扫描完成时间（用于 UI 展示"更新于 HH:MM"）
    let scannedAt: Date?

    /// 命中的本地 session 数（去重 session_id 后）
    let sessionCount: Int

    /// 解析到的 model_usage 行数（rounds = `COUNT(*)`）
    let eventCount: Int

    /// 失败 session 数（zcode 单源没有跨 session RPC 失败的概念，恒为 0；
    /// 保留字段对齐 minimax / antigravity 语义，方便未来扩展）
    let failedSessionCount: Int

    /// 最近额度窗口内的逐次模型调用，用于 Last Prompt 与窗口累计 hover。
    /// optional 让旧的持久化结果仍可解码；UI 统一按空数组处理 nil。
    let recentSamples: [LocalTokenUsageSample]?

    /// 已完成的闲时任务（off-peak）时间窗口列表（来自 ZCode off_peak_tasks 表）。
    /// 额度窗口优先按 sample 的 provider 身份排除闲时任务；这些窗口用于旧缓存缺少
    /// 来源字段时的兼容回退。本地 token 柱图始终保留闲时任务的真实消耗。
    let offPeakWindows: [GlmOffPeakWindow]

    static let empty = GlmLocalUsage(
        today: nil,
        dailyTokenUsage: [],
        scannedAt: nil,
        sessionCount: 0,
        eventCount: 0,
        failedSessionCount: 0,
        recentSamples: [],
        offPeakWindows: []
    )

    init(
        today: GlmDailyUsage?,
        dailyTokenUsage: [GlmDailyUsage],
        scannedAt: Date?,
        sessionCount: Int,
        eventCount: Int,
        failedSessionCount: Int,
        recentSamples: [LocalTokenUsageSample]? = nil,
        offPeakWindows: [GlmOffPeakWindow] = []
    ) {
        self.today = today
        self.dailyTokenUsage = dailyTokenUsage
        self.scannedAt = scannedAt
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.failedSessionCount = failedSessionCount
        self.recentSamples = recentSamples
        self.offPeakWindows = offPeakWindows
    }

    /// 自定义 `==` 排除 `scannedAt` —— `scannedAt` 是 metadata（每次扫描都是新 `Date`），
    /// 默认 Equatable 会让"内容没变但 scannedAt 变了"的两份 usage 永远 !=，
    /// 导致 `AppState.apply*LocalUsage` 的 no-op 检查形同虚设：
    /// 每次都打 logInfo + 触发 `@Published` willSet 无意义 UI reload。
    /// 业务字段（`today` / `dailyTokenUsage` / `sessionCount` / `eventCount` /
    /// `failedSessionCount` / `offPeakWindows`）决定内容是否真变。
    /// Codable 自动合成的 CodingKeys 不受影响 —— `scannedAt` 仍然被编解码。
    static func == (lhs: GlmLocalUsage, rhs: GlmLocalUsage) -> Bool {
        lhs.today == rhs.today
            && lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.failedSessionCount == rhs.failedSessionCount
            && lhs.recentSamples == rhs.recentSamples
            && lhs.offPeakWindows == rhs.offPeakWindows
    }
}

