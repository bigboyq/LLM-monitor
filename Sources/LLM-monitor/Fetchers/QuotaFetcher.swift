import Foundation

enum RefreshMode: Sendable, Equatable {
    case full
    case background
}

/// 把"这次新抓的"和"上次缓存的"合成要给 UI 显示的最终值。
///
/// 默认实现 `identity` 直接返回新值（无合并）。provider 可以自带
/// 自定义 merger；当前 Codex 会在 reset credits 或 usage details 缺失时
/// 回填上次的对应字段——policy 跟 domain knowledge 一起放在 fetcher 旁边，
/// 避免在 AppState 里堆 `if kind == .minimaxTokenPlan { ... }` 之类的分支。
protocol RefreshResultMerger: Sendable {
    func merge(
        new: QuotaInfo,
        previous: QuotaInfo?,
        mode: RefreshMode
    ) -> QuotaInfo
}

/// 默认 merger：直接用新值。`mode` 和 `previous` 都被忽略。
struct IdentityRefreshResultMerger: RefreshResultMerger {
    func merge(new: QuotaInfo, previous: QuotaInfo?, mode: RefreshMode) -> QuotaInfo {
        new
    }
}

/// 额度抓取器协议 — 每个 provider 一个实现
///
/// `providerID` / `displayName` / `logTag` / `kind` 都是注册元信息；
/// 真实值由 `FetcherDescriptor` 提供，fetcher 只承载"如何抓取"。
///
/// **关于 `providerID` 镜像**：fetcher 自身存储 `providerID` 不是"乱复制"。
/// fetcher 是 `Sendable` 值类型，可能被独立使用（不依赖 `FetcherDescriptor`），
/// log tag / 自识别 / 错误消息都需要这个 id，所以是必要的 stored property。
/// 真实值由 `LLMMonitorApp.makeDescriptors()` 注入，必须跟对应 `FetcherDescriptor.id` 一致。
protocol QuotaFetcher: Sendable {
    /// provider 唯一 ID（用于状态匹配、日志和 UI）
    var providerID: String { get }

    /// 显示名
    var displayName: String { get }

    /// provider 类型
    var kind: ProviderKind { get }

    /// 日志前缀（例：`[minimax]`、`[codex]`、`[antigravity]`）。
    /// 默认 `[\(providerID)]`，fetcher 多数情况可重写为短 tag。
    /// 静态方法（`parse(data:)` 等）也可通过同名 static `logTag` 引用。
    var logTag: String { get }

    /// 抓取一次最新额度
    func fetch(mode: RefreshMode) async throws -> QuotaInfo

    /// 抓取一次最新额度（默认完整刷新）
    func fetch() async throws -> QuotaInfo

    /// 同步检查本地 auth 是否就绪（用于 UI 显示 notConfigured vs ready）
    /// - 对自管 auth 的 fetcher（如 codex 读 ~/.codex/auth.json）：返回 auth 文件是否存在
    /// - 对依赖 config.json apiKey 的 fetcher：返回 true（auth 由 AppState 用 config 检查）
    func hasLocalAuth() -> Bool

    /// 异步检查本地认证/服务是否可用。默认复用轻量同步检查；需要进程发现的
    /// provider 可以在后台实现，避免阻塞菜单与配置窗口。
    func checkLocalAuth() async -> Bool

    /// 合并策略：把"这次新抓的"和"上次缓存的"合成最终值。
    /// 默认 identity —— 直接用新值。
    /// provider 可以自带 merger；当前 Codex 在 reset credits 或 usage details
    /// 缺失时回填上次的对应字段，policy 放在 fetcher 旁边。
    var resultMerger: RefreshResultMerger { get }
}

extension QuotaFetcher {
    var logTag: String { "[\(providerID)]" }

    func fetch() async throws -> QuotaInfo {
        try await fetch(mode: .full)
    }

    func checkLocalAuth() async -> Bool {
        hasLocalAuth()
    }

    var resultMerger: RefreshResultMerger { IdentityRefreshResultMerger() }
}
