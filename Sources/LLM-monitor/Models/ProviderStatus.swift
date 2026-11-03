import Foundation

/// UI 用的 provider 状态：把 fetcher 跟最新抓取结果绑在一起
struct ProviderStatus: Identifiable, Equatable, Sendable {
    /// UI 状态机。
    ///
    /// 关键设计：`State` 自带"上次成功数据"（`.loading` / `.failed` 都带
    /// `lastSuccess: QuotaInfo?`），状态机本身是 single source of truth。
    /// 之前用单独的 `_lastSuccess` 字段跟 `.failed.lastSuccess` 重复存了一份
    /// ——`.failed` 跟 `._lastSuccess` 任意一处忘记更新，UI 就会拿到
    /// 过期数据（实测 P1 fix 时就吃过这个亏）。现在 `.loading(lastSuccess:)`
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

    /// Freshness of each local usage source consumed by this card.
    ///
    /// This is intentionally separate from the quota health above. AppState can write
    /// the same `.dsh` / `.opencode` entry to every consumer status, and the
    /// provider-neutral projection below will resolve it for each card.
    var localUsageFreshness: LocalUsageFreshnessSnapshot = .clean
    /// Antigravity 本地 token 用量聚合（来自 AntigravityLocalUsageScanner）
    /// 只在 `kind == .antigravity` 时使用；其他 provider 永远 nil。
    var antigravityLocalUsage: AntigravityLocalUsage?
    /// agy CLI（Antigravity 的命令行分支）本地 token 用量聚合（来自
    /// AgyLocalUsageScanner）。与 `antigravityLocalUsage` 同卡并列：agy 的模型
    /// 本质是 Gemini，本地用量归 `.antigravity` 卡，是该卡本地用量的贡献来源之一。
    /// 只在 `kind == .antigravity` 时使用；其他 provider 永远 nil。
    var agyUsage: AgyLocalUsage?
    /// minimax 本地 token 用量聚合（来自 MinimaxLocalUsageScanner，v2 runtime-state 单源）
    /// 只在 `kind == .minimaxTokenPlan` 时使用；其他 provider 永远 nil。
    var minimaxLocalUsage: MinimaxLocalUsage?

    /// GLM 本地 token 用量聚合（来自 GlmZcodeLocalUsageScanner，读 ZCode 官方 CLI db）
    /// 只在 `kind == .glmCodingPlan` 时使用；其他 provider 永远 nil。
    var glmLocalUsage: GlmLocalUsage?

    /// ZCode 活动套餐余额（UI 投影）。优先从 quotaInfo?.glmZcodePackage 获取，
    /// 回退至本地 scanner 快照。
    /// 只有 `.glmCodingPlan` 的卡片读它（`GlmActivityPlanBalancesView`）。
    var glmActivityPlanBalances: [GlmActivityPlanBalance] {
        if let balances = lastSuccess?.glmZcodePackage?.activityPlanBalances {
            return balances
        }
        return glmLocalUsage?.activityPlanBalances ?? []
    }

    /// ZCode 活动套餐生效前预告（UI 投影）。优先从 quotaInfo?.glmZcodePackage 获取，
    /// 回退至本地 scanner 快照。
    /// 只有 `.glmCodingPlan` 的卡片读它（`GlmActivityPlanBalancesView`）。
    var glmActivityPlanPreviews: [GlmActivityPlanPreview] {
        if let previews = lastSuccess?.glmZcodePackage?.activityPlanPreviews {
            return previews
        }
        return glmLocalUsage?.activityPlanPreviews ?? []
    }

    /// ZCode 额度重置卡快照（UI 投影）。
    /// 只有 `.glmCodingPlan` 的卡片读它（`GlmActivityPlanBalancesView`）。
    var glmResetCards: GlmResetCardsSnapshot? {
        lastSuccess?.glmZcodePackage?.resetCards
    }

    /// GLM 闲时任务窗口（UI 投影）。非 GLM 卡恒为空——ZCode 是一份多 provider
    /// 账本，`glmLocalUsage` 也挂在 MiniMax / DeepSeek 卡上，闲时窗口只属于智谱任务。
    var glmOffPeakWindows: [GlmOffPeakWindow] {
        glmLocalUsage?.offPeakWindows ?? []
    }

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

    /// client → quota 内置自动归因路由快照，保留供内部诊断与兼容调用点使用。
    /// 生产投影直接使用 `ClientProviderBinding.defaultBindings`；此处旧 config 的
    /// aliases / enabled 值不会改变归因。native 账本直接归属各自 provider。
    var clientBindings: [ClientProviderBinding] = ClientProviderBinding.defaultBindings

    /// 兼容仍查询该关系的内部调用点。只检查内置路由是否存在，忽略旧快照中的 enabled。
    func isClientBindingEnabled(clientID: String, quotaProviderID: String) -> Bool {
        ClientProviderBinding.defaultBindings.contains {
            $0.clientID == clientID && $0.quotaProviderID == quotaProviderID
        }
    }

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

    /// 卡片头部点使用的综合健康度（统一 colorLevel 口径，方案 A）。
    /// - `lastSuccess` 为 nil → nil（保持灰点语义：没数据 ≠ 健康）。
    /// - 有数据但没有有效窗口 model → .critical（聚合口径保守误红）。
    /// - 否则取各 model `aggregateHealthLevel`（实际可用口径 min(5h, 周 × N)）的最差值。
    ///
    /// 聚合 model 集合已排除 minimax video / antigravity Claude and GPT 组
    /// （`QuotaInfo.aggregateQuotaModels`，滤后为空回退全集）。
    ///
    /// 高峰判定跟随 `AppState.systemHealthLevel` 现状：`glmPeakWindow` 命中 .peak
    /// 即保底 .warning（红色优先，floor 不吞掉红色）；`deepseekPeakWindow` 不参与
    /// 卡头点 floor。deepseek 余额接入集中告警配置中心（余额 < 3 红色，< 10 黄色）。
    func aggregateHealthLevel(
        alertThresholds: AlertThresholdConfig = .default,
        at now: Date = Date()
    ) -> HealthLevel? {
        guard let info = lastSuccess else { return nil }
        if kind == .deepseek {
            if let balance = info.balanceDetail?.total {
                if balance <= 0 || balance < alertThresholds.deepseekBalanceCritical {
                    return .critical
                } else if balance < alertThresholds.deepseekBalanceWarning {
                    return .warning
                } else {
                    return .healthy
                }
            }
            if let firstModel = info.aggregateQuotaModels(providerKind: .deepseek).first {
                return firstModel.intervalRemainingPercent > 0 ? .healthy : .critical
            }
            return .critical
        }
        let isPeak: Bool
        if let glmPeak = glmPeakWindow, case .peak = glmPeak.status(at: now, calendar: PeakWindow.beijingCalendar) {
            isPeak = true
        } else {
            isPeak = false
        }
        return info.aggregateQuotaModels(providerKind: kind)
            .map { $0.aggregateHealthLevel(providerKind: kind, isPeakPrice: isPeak, alertThresholds: alertThresholds, at: now) }
            .min() ?? .critical
    }

    /// GLM 高峰判定（`AppState.systemHealthLevel` / `statusBarQuotaMetrics` 共用）：
    /// glmPeakWindow 命中 `.peak` 即 true。
    func isGlmPeak(at now: Date) -> Bool {
        guard let glmPeak = glmPeakWindow else { return false }
        if case .peak = glmPeak.status(at: now, calendar: PeakWindow.beijingCalendar) { return true }
        return false
    }

    /// Effective freshness for the local usage footer. The legacy scanning
    /// flag remains a compatibility fallback until AppState writes the source
    /// transition itself; source-level `.scanning` also works for shared data.
    var effectiveLocalUsageFreshness: LocalUsageFreshness {
        if isScanningLocalUsage { return .scanning }
        return localUsageFreshness.resolved(for: localUsageConsumers.map(\.source))
    }

    /// Sources which can contribute to this status under the built-in automatic attribution.
    /// This is also the source→client/provider mapping used by Fleet freshness.
    var localUsageConsumers: [LocalUsageConsumer] {
        func consumers(_ sources: [LocalUsageSource]) -> [LocalUsageConsumer] {
            sources.map { LocalUsageConsumer(source: $0, quotaProviderID: kind.quotaProviderID) }
        }

        switch kind {
        case .codexChatGpt:
            return consumers([.codex, .opencode])
        case .antigravity:
            return consumers([.antigravity, .agy, .opencode])
        case .minimaxTokenPlan:
            return consumers([.minimaxCode, .dsh, .zcode, .opencode])
        case .glmCodingPlan:
            return consumers([.zcode, .dsh, .opencode])
        case .deepseek:
            return consumers([.dsh, .zcode, .opencode])
        }
    }

    /// 「用户没配过顺序」时的默认排序：显示名升序，同名再按 id 兜底。
    ///
    /// 菜单卡片（[MenuContentView]）与边缘 dock（[EdgeDockProjection]）**共用**这一个
    /// 比较器。两处各写一份时，dock 和菜单迟早按不同顺序排列，而它们本来就该是
    /// 同一份配置（`providerCardOrder`）的两种呈现。
    static func displayNameAscending(_ lhs: ProviderStatus, _ rhs: ProviderStatus) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
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

    /// 有窗口额度（5 小时 / 周额度）的 provider，配置四类通知渠道的入口。
    /// DeepSeek 填的是余额百分比而非时间窗口，暂不接入。
    static let windowedKinds: [ProviderKind] = [
        .codexChatGpt,
        .glmCodingPlan,
        .minimaxTokenPlan,
        .antigravity,
    ]

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
