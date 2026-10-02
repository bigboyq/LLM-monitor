import Foundation

/// GLM 官方客户端（ZCode CLI）本地 token 用量聚合（同构 MinimaxLocalUsage）。
///
/// 数据来源：ZCode 的 SQLite `~/.zcode/cli/db/db.sqlite` `model_usage` 表 ——
/// 每行一次模型请求，带智谱系 `provider_id`（`builtin:bigmodel-coding-plan` /
/// `offpeak-idle-plan` / 其余 `builtin:bigmodel-%`）+ `model_id`（如 `GLM-5.3`）
/// + 5 类 token（`input_tokens` / `output_tokens` / `reasoning_tokens` /
/// `cache_creation_input_tokens` / `cache_read_input_tokens`）+ 原生 `turn_id`。
///
/// 跟 minimax / opencode 的关键区别：
/// - **单源**（一个 zcode db），不是双源 union
/// - **原生 reasoning**（GLM 账单自带 reasoning tokens），不需要字符分摊
/// - **原生 turn_id**：turns 直接 `COUNT(DISTINCT turn_id)`（ZCode 一次 user prompt
///   触发的多次模型调用共享同一个 turn_id）；rounds = `COUNT(*)`（每行 = 一次模型请求，
///   含主 agent / subagent / retry / title 生成）
/// - **多 provider 账本**：智谱系行走 GLM 卡，同表里的非智谱 provider 行
///   （`minimax` / `deepseek`）按 `providerSlices` 切出分片，并入对应卡
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

    /// ZCode 活动套餐（zcode-plan，如周末体验套餐）余额快照，来自
    /// `GlmZcodeBalanceLogReader` 对 ZCode 余额轮询日志的解析。
    /// optional 让旧缓存/关闭开关的快照仍可解码：nil = 未解析（开关关闭或
    /// 尚未扫到），`[]` = 解析成功但当前无活动套餐。UI 按空数组处理 nil。
    let activityPlanBalances: [GlmActivityPlanBalance]?

    /// 非智谱 provider 分片（`ZcodeProviderSlice`），key = 分片 rawValue
    /// （`minimax` / `deepseek`）。ZCode 是一份多 provider 共享账本，这些分片
    /// 与智谱系行同表同扫，但并入的是 MiniMax / DeepSeek 卡而不是 GLM 卡。
    /// optional 让旧缓存快照仍可解码；UI 与卡片层按 nil = 无分片处理。
    let providerSlices: [String: OpencodeProviderUsage]?

    /// MiniMax 分片（便捷访问）。
    var minimaxSlice: OpencodeProviderUsage? {
        providerSlices?[ZcodeProviderSlice.minimax.rawValue]
    }

    /// DeepSeek 分片（便捷访问）。
    var deepseekSlice: OpencodeProviderUsage? {
        providerSlices?[ZcodeProviderSlice.deepseek.rawValue]
    }

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
        offPeakWindows: [GlmOffPeakWindow] = [],
        activityPlanBalances: [GlmActivityPlanBalance]? = nil,
        providerSlices: [String: OpencodeProviderUsage]? = nil
    ) {
        self.today = today
        self.dailyTokenUsage = dailyTokenUsage
        self.scannedAt = scannedAt
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.failedSessionCount = failedSessionCount
        self.recentSamples = recentSamples
        self.offPeakWindows = offPeakWindows
        self.activityPlanBalances = activityPlanBalances
        self.providerSlices = providerSlices
    }

    /// 自定义 `==` 排除 `scannedAt` —— `scannedAt` 是 metadata（每次扫描都是新 `Date`），
    /// 默认 Equatable 会让"内容没变但 scannedAt 变了"的两份 usage 永远 !=，
    /// 导致 `AppState.apply*LocalUsage` 的 no-op 检查形同虚设：
    /// 每次都打 logInfo + 触发 `@Published` willSet 无意义 UI reload。
    /// 业务字段（`today` / `dailyTokenUsage` / `sessionCount` / `eventCount` /
    /// `failedSessionCount` / `offPeakWindows` / `activityPlanBalances` /
    /// `providerSlices`）决定内容是否真变。
    /// Codable 自动合成的 CodingKeys 不受影响 —— `scannedAt` 仍然被编解码。
    static func == (lhs: GlmLocalUsage, rhs: GlmLocalUsage) -> Bool {
        lhs.today == rhs.today
            && lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.failedSessionCount == rhs.failedSessionCount
            && lhs.recentSamples == rhs.recentSamples
            && lhs.offPeakWindows == rhs.offPeakWindows
            && lhs.activityPlanBalances == rhs.activityPlanBalances
            && lhs.providerSlices == rhs.providerSlices
    }
}

/// 一个已完成的闲时任务（off-peak task）的运行时间窗口。
///
/// ZCode 闲时任务是系统赠送的、不消耗 Coding Plan 积分的后台任务，需提前排队。
/// 它的 `model_usage` 行写在同一张表（同 session_id），但 `provider_id` 是独立的
/// `offpeak-idle-plan`（非 `builtin:bigmodel-coding-plan`）。落在这个
/// `[started_at, ended_at]` 时间窗口内的调用不扣积分。额度窗口（5h/week）统计时需要
/// 把这部分 sample 排除，避免高估积分消耗；本地 token 柱图仍保留（真实 token 消耗）。
struct GlmOffPeakWindow: Equatable, Codable, Sendable {
    /// 闲时任务开始时间（off_peak_tasks.started_at，epoch ms → Date）
    let startedAt: Date
    /// 闲时任务结束时间（off_peak_tasks.ended_at，epoch ms → Date）
    let endedAt: Date

    /// sample.completedAt 是否落在本闲时任务窗口内（闭区间，容差 2 秒）。
    /// off_peak.ended_at 与最后一轮 model_usage.completed_at 实测差 ~1 秒，闭区间 +
    /// 小容差确保边界 round 不会被误判。
    func contains(_ date: Date, tolerance: TimeInterval = 2) -> Bool {
        date >= startedAt.addingTimeInterval(-tolerance)
            && date <= endedAt.addingTimeInterval(tolerance)
    }
}

/// ZCode 活动套餐（zcode-plan，如周末体验套餐）的一条余额快照。
///
/// 数据来源不是任何公开 API，而是 ZCode 自己的余额轮询日志：ZCode 桌面端每
/// ~60 秒请求一次 `https://zcode.z.ai/api/v1/zcode-plan/billing/balance`，并把
/// **完整响应 JSON** 原样打进 `~/.zcode/v2/logs/YYYY-MM-DD.log`（行内标记
/// `billing/balance 请求完成`）。解析日志即可零鉴权拿到
/// `total / used / remaining / expires_at`。
///
/// 注意口径：该接口只覆盖 zcode SaaS 活动套餐，**不含** bigmodel coding plan
/// 积分池（后者走 open.bigmodel.cn monitor 接口，需要 Coding Plan Key）。
struct GlmActivityPlanBalance: Equatable, Codable, Sendable {
    let planID: String
    let planName: String
    let entitlementID: String
    /// 余额展示名（通常为模型名，如 `GLM-5.3-Flash`）
    let showName: String
    /// 从 `capabilities` 的 `model:xxx` 提取的模型 ID；缺失时回退 `[showName]`
    let modelNames: [String]
    let totalUnits: Int
    let usedUnits: Int
    let remainingUnits: Int
    /// 套餐过期时间（unix 秒）。缺失 / 解析失败为 nil
    let expiresAt: Date?
    /// 该快照在日志里的落盘时间（用于 UI 标注数据新旧；ZCode 未运行时不更新）
    let observedAt: Date?
}
