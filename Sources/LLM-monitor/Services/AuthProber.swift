import Foundation

/// 异步探测"使用本地认证的 provider"（antigravity / codex）当前是否真的能联通
/// 本地服务，并把结果缓存给 AppState 用。
///
/// ## 跟 ProviderRefreshScheduler 的边界
///
/// AuthProber **不**管定时刷新。AppState 仍然按 refreshIntervalSeconds 调度
/// `ProviderRefreshScheduler` 拉主 quota；AuthProber 单独负责"async 探测本地
/// 服务是否还活着"，结果只用来给 `ProviderStatus.state` 派生 `notConfigured` 提示，
/// 以及在检测到服务离线时主动 `rebuildStatuses() + rescheduleAll()`。
///
/// ## cache 语义
///
/// `availability: [providerID: Bool]`：
/// - `nil` —— 还没探测过（fetcher.hasLocalAuth() 当时就 false，根本没发起）
/// - `false` —— 探测了，结果为不可用
/// - `true` —— 探测了，结果为可用；或 refresh 成功路径调用 `markAvailable`
///
/// `isUnavailable(_:)` 只看 `== false`，不把 `nil` 当成不可用，避免误伤。
///
/// ## generation 守门
///
/// 故意不把 `AppState.configurationGeneration` 拉进 AuthProber。AuthProber 的
/// cache 是"系统事实"（IDE 是否启动），跟 config 无关；config 变更时
/// AppState 调 `reset()` 直接清空 cache + 取消所有 in-flight 即可。
/// 这样 AuthProber 不依赖外部状态机，独立可测。
@MainActor
final class AuthProber {
    /// 拿到 providerID 对应的 fetcher。返回 nil 表示当前 config 下该 provider
    /// 不可用 / 未启用 / 不存在，AuthProber 不会发起 probe。
    typealias FetcherProvider = (String) -> (any QuotaFetcher)?

    /// 拿到 fetcher 后同步判断能不能发起 `checkLocalAuth`。
    /// 默认是 `fetcher.hasLocalAuth()` —— 没本地 auth 文件的就不去探测。
    typealias CanProbe = (any QuotaFetcher) -> Bool

    /// cache 更新且值变化时触发。AppState 在这里做 rebuild + reschedule。
    typealias OnChange = (String, Bool) -> Void  // (providerID, isAvailable)

    private(set) var availability: [String: Bool] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 每次取消 / 重启 probe 都递增。旧 probe 即使已经通过取消检查，
    /// 在稍后回到 MainActor 时也不能覆盖更新一代的结果。
    private var generations: [String: UInt64] = [:]

#if DEBUG
    /// 仅测试使用：把任务停在 cancellation check 之后、MainActor apply 之前，
    /// 精确验证 generation 守门，而不是只验证 Task.isCancelled。
    static var testAfterCancellationCheck: (@Sendable () async -> Void)?
#endif

    private let fetcherProvider: FetcherProvider
    private let canProbe: CanProbe
    private let onChange: OnChange

    init(
        fetcherProvider: @escaping FetcherProvider,
        canProbe: @escaping CanProbe = { fetcher in fetcher.hasLocalAuth() },
        onChange: @escaping OnChange = { _, _ in }
    ) {
        self.fetcherProvider = fetcherProvider
        self.canProbe = canProbe
        self.onChange = onChange
    }

    // MARK: - 探测入口

    /// 启动一次异步 probe。`fetcherProvider` 返回 nil 或 `canProbe` 返回 false
    /// 时不发起 task（cache 保持原状）。
    /// - Returns: 是否真的启动了 task
    @discardableResult
    func scheduleProbe(for providerID: String) -> Bool {
        cancel(providerID: providerID)
        guard let fetcher = fetcherProvider(providerID) else { return false }
        guard canProbe(fetcher) else { return false }
        let generation = generations[providerID] ?? 0
        let task = Task { [weak self] in
            let isAvailable = await fetcher.checkLocalAuth()
            guard !Task.isCancelled else { return }
#if DEBUG
            let testHook = await MainActor.run { AuthProber.testAfterCancellationCheck }
            if let testHook { await testHook() }
#endif
            await MainActor.run {
                self?.apply(isAvailable: isAvailable, for: providerID, generation: generation)
            }
        }
        tasks[providerID] = task
        return true
    }

    /// refresh 成功路径调用：直接把 cache 置 true（不发探测）。
    func markAvailable(_ providerID: String) {
        cancel(providerID: providerID)
        let generation = generations[providerID] ?? 0
        apply(isAvailable: true, for: providerID, generation: generation)
    }

    // MARK: - 取消 / 重置

    func cancel(providerID: String) {
        tasks[providerID]?.cancel()
        tasks.removeValue(forKey: providerID)
        generations[providerID, default: 0] &+= 1
    }

    func cancelAll() {
        for providerID in tasks.keys {
            generations[providerID, default: 0] &+= 1
        }
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// config 变更时调：清掉所有 in-flight + 清 cache，让后续 rebuildStatuses
    /// 重新决定要不要 probe。
    func reset() {
        cancelAll()
        availability.removeAll()
        generations.removeAll()
    }

    // MARK: - 观察

    /// 是否已确认不可用（用于 status 显示）
    func isUnavailable(_ providerID: String) -> Bool {
        availability[providerID] == false
    }

    // MARK: - 内部

    private func apply(isAvailable: Bool, for providerID: String, generation: UInt64) {
        guard generations[providerID] == generation else { return }
        tasks.removeValue(forKey: providerID)
        let previous = availability[providerID]
        guard previous != isAvailable else { return }
        availability[providerID] = isAvailable
        onChange(providerID, isAvailable)
    }
}
