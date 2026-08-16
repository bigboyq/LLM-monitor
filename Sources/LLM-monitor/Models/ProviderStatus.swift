import Foundation

/// UI 用的 provider 状态：把 fetcher 跟最新抓取结果绑在一起
struct ProviderStatus: Identifiable, Equatable, Sendable {
    /// UI 状态机。
    ///
    /// 关键设计：`State` 自带"上次成功数据"（`.loading` / `.failed` 都带
    /// `lastSuccess: QuotaInfo?`），状态机本身是 single source of truth。
    /// 之前用单独的 `_lastSuccess` 字段跟 `.failed.lastSuccess` 重复存了一份
    /// ——`.failed` 跟 `._lastSuccess` 任意一处忘记更新，UI 跟 healthLevel
    /// 就会不一致（实测 P1 fix 时就吃过这个亏）。现在 `.loading(lastSuccess:)`
    /// / `.failed(_, lastSuccess:)` 直接把上次成功数据挂在 case 上，
    /// 迁 `.ok` → `.loading` → `.ok/.failed` 不会有"漏更新"窗口。
    /// Production writes are centralized in `AppState`; views consume this value model
    /// and should not mutate provider state directly.
    enum State: Equatable, Sendable {
        case notConfigured(reason: String)        // 没配 / 禁用 / key 缺失
        case ready                                 // 配置 ok，等待首次抓取
        case loading(lastSuccess: QuotaInfo?)      // 抓取中（带上次成功数据兜底）
        case ok(QuotaInfo)                         // 抓取成功
        case failed(message: String,               // 抓取失败
                    lastSuccess: QuotaInfo?)
    }

    let id: String
    let displayName: String
    let kind: ProviderKind
    let iconSystemName: String
    let accentColor: AccentColor

    /// 派生于当前 config 的刷新间隔（秒），init 时定下来后不再变。
    /// `let`（之前是 `var`）—— interval 来自 config，config 变更会走 rebuildStatuses 整个 status 替换。
    let refreshIntervalSeconds: Int

    /// 是否在配置中启用（来自 ProviderConfig.enabled，false 时在菜单中隐藏）
    var isEnabled: Bool = true

    var state: State
    var lastRefreshedAt: Date?
    var isScanningLocalUsage: Bool = false
    /// Antigravity 本地 token 用量聚合（来自 AntigravityLocalUsageScanner）
    /// 只在 `kind == .antigravity` 时使用；其他 provider 永远 nil。
    var antigravityLocalUsage: AntigravityLocalUsage?
    /// minimax 本地 token 用量聚合（来自 MinimaxLocalUsageScanner，v2 runtime-state 单源）
    /// 只在 `kind == .minimaxTokenPlan` 时使用；其他 provider 永远 nil。
    var minimaxLocalUsage: MinimaxLocalUsage?

    /// GLM 本地 token 用量聚合（来自 GlmZcodeLocalUsageScanner，读 ZCode 官方 CLI db）
    /// 只在 `kind == .glmCodingPlan` 时使用；其他 provider 永远 nil。
    var glmLocalUsage: GlmLocalUsage?

    /// DeepSeek Harness (`dsh`) session-log token usage。
    /// 这是共享本地数据源，不在 `ProviderKind` 中增加一个独立 provider；
    /// 按 request/context provider 分片后合并到对应卡片。
    var dshUsage: DshLocalUsage?

    /// GLM Coding Plan 高峰期窗口（来自 config，纯本地时间计算）。
    /// 只在 `kind == .glmCodingPlan` 时使用；其他 provider 永远 nil。
    var glmPeakWindow: GlmPeakWindow?

    /// DeepSeek 高峰期窗口（来自 config，基于北京时间计算）。
    /// 只在 `kind == .deepseek` 时使用；其他 provider 永远 nil。
    var deepseekPeakWindow: DeepseekPeakWindow?

    /// 是否把对应 OpenCode provider 的用量合并进这张卡。
    /// 这是 config 派生的展示开关，不影响后台扫描或诊断页。
    var mergeOpencodeUsage: Bool = false

    /// opencode 本地用量快照（四张卡共用的后台数据源）。
    /// 每张卡只读取自己的 provider slice；不会把 `minimax` 本地能力账本
    /// 自动算入 Minimax Token Plan。
    var opencodeUsage: OpencodeLocalUsage?

    /// 是否配置且启用（仅看 enabled 字段，最终由 AppState 控制）
    var isConfigured: Bool {
        if case .notConfigured = state { return false }
        return true
    }

    /// 最近一次成功的数据。从 `state` 派生 —— 不再有单独的 `_lastSuccess` 字段，
    /// 避免跟 `state.failed.lastSuccess` 重复存。
    var lastSuccess: QuotaInfo? {
        switch state {
        case .ok(let info):        return info
        case .loading(let prev):   return prev
        case .failed(_, let last): return last
        case .notConfigured, .ready: return nil
        }
    }

    /// 当前可展示的健康度。
    /// - `.notConfigured` / `.ready` 返回 nil（UI 显示灰点，避免误导为"健康"）。
    /// - `.loading` / `.failed` 在没有 `lastSuccess` 时也返回 nil。
    /// - 其他情况取最新一次成功数据的 healthLevel。
    var healthLevel: HealthLevel? {
        lastSuccess?.healthLevel
    }
}

/// provider 类型枚举（每加一个 provider 加一个 case）
enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case minimaxTokenPlan
    case codexChatGpt
    case antigravity
    case glmCodingPlan
    case deepseek

    /// Stable configuration/status identifier. Keep this separate from `rawValue`
    /// so enum naming/serialization can evolve without changing existing config keys.
    var providerID: String {
        switch self {
        case .minimaxTokenPlan: return "minimax_token_plan"
        case .codexChatGpt:     return "codex_chatgpt"
        case .antigravity:      return "antigravity"
        case .glmCodingPlan:    return "glm_coding_plan"
        case .deepseek:         return "deepseek"
        }
    }

    /// 短 log tag（无方括号，无 `/`）。
    /// `AppState.applyLocalUsage` 用这个构造 `[<tag>/apply]` 日志前缀。
    /// 这是 UI/state 侧的稳定镜像值；网络 fetcher 的日志标签仍由各自调用点维护。
    var logTag: String {
        switch self {
        case .minimaxTokenPlan: return "minimax"
        case .codexChatGpt:     return "codex"
        case .antigravity:      return "antigravity"
        case .glmCodingPlan:    return "glm"
        case .deepseek:         return "deepseek"
        }
    }

    /// 这个 provider 是否自己管理认证（读外部 auth.json 而不是 config.json 的 apiKey）
    var usesExternalAuth: Bool {
        switch self {
        case .codexChatGpt:     return true   // 读 ~/.codex/auth.json
        case .antigravity:      return true   // 复用本地 Antigravity language_server 登录态
        case .minimaxTokenPlan: return false
        case .glmCodingPlan:    return false  // Coding Plan Key 存在 config.json 的 apiKey
        case .deepseek:         return false  // API Key 存在 config.json 的 apiKey
        }
    }
}

/// 强调色 — provider 品牌色（保持低调，不要花里胡哨）
enum AccentColor: String, Sendable {
    case minimax = "minimax"
    case chatgpt = "chatgpt"
    case antigravity = "antigravity"
    case glm = "glm"
    case deepseek = "deepseek"
    case custom = "custom"
}
