import Foundation

/// 单个 provider 一次 refresh 的结果。
///
/// - `deferred`: 请求未实际发起（已有 in-flight / 配置刚变化 / auth 缺失），
///   timer 循环里按 1s 短重试节奏继续轮询。
/// - `completed(success:)`: 请求真的完成了。`success=false` 时调度器计入失败计数
///   并按指数退避延长下次间隔。
enum ProviderRefreshOutcome: Sendable, Equatable {
    case deferred
    case completed(success: Bool)
}

/// 集中管理 per-provider 的定时刷新：
/// - 每个 provider 一个独立 Task，独立 fetch，互不阻塞
/// - 同一 provider 重复触发走 in-flight dedup（`markInFlight` 返回 false）
/// - 连续失败按指数退避（从 2× 开始：2×, 4×, 8×, 16×, 32×，封顶 30 分钟 + ±10% jitter）
/// - `.deferred` outcome 按 1s 短重试节奏继续轮询，避让配置刚变化或手动刷新期间
///
/// 这个类**只**管 timer + in-flight + 退避 + 失败计数。不做：
/// - fetcher 构造（依赖 config / descriptor，留在 AppState）
/// - 状态写回（`statuses[idx] = ...`，依赖 ProviderStatus，留在 AppState）
/// - 后置副作用（codex detail refresh、antigravity/minimax local usage 触发）
///
/// 配合 `AppState.configurationGeneration` 丢弃旧配置下的结果——逻辑在
/// `refreshHandler` 闭包里用 generation 对比实现，调度器不感知 generation。
@MainActor
final class ProviderRefreshScheduler {
    /// 实际 fetch 的回调。`AppState.refreshProviderDirectly` 是这个闭包。
    typealias RefreshHandler = (String, RefreshMode) async -> ProviderRefreshOutcome
    /// 取一个 provider 的基础刷新间隔（秒）。通常 `configStore.config.effectiveRefreshInterval(for:)`。
    typealias IntervalProvider = (String) -> TimeInterval
    /// 任何会改 `nextRefreshDates` / `failureCounts` 的路径都会触发一次，
    /// 让外部把 `earliestNextRefresh` 重新 publish 到 `@Published nextRefreshAt`。
    typealias NextRefreshChangeCallback = () -> Void

    // MARK: - 内部状态（替代 AppState 里 4 个 dict）

    /// 每个 provider 独立的 refresh task（独立 timer + 独立间隔）
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 正在进行网络请求的 provider。手动刷新、菜单打开、定时器可能同时触发，
    /// 这里保证同一个 provider 同一时刻只会发出一个请求。
    private var inFlightModes: [String: RefreshMode] = [:]
    /// 手动刷新需要等待当前请求结束时挂在这里；请求的 defer 会统一唤醒。
    /// 每个 waiter 带 UUID，取消时可以精确从队列移除，避免 continuation 泄漏。
    private struct InFlightWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var inFlightWaiters: [String: [InFlightWaiter]] = [:]
    /// 各独立定时器的下一次触发时间。footer 展示其中最早的一个。
    private var nextRefreshDates: [String: Date] = [:]
    /// 连续失败计数，用于每个 provider 独立的指数退避。
    private var failureCounts: [String: Int] = [:]
    /// 各子窗口 reset time 产生的中间补刷新 Task（reset 发生 15s 后触发，不重置常规刷新节奏）
    private var midCycleTasks: [String: [Task<Void, Never>]] = [:]

    // MARK: - 依赖注入

    private let refreshHandler: RefreshHandler
    private let intervalProvider: IntervalProvider
    private let onNextRefreshChange: NextRefreshChangeCallback
    /// 可注入的时钟，生产默认为真实时间。用于 mid-cycle 补刷新计算等待时长，
    /// 也用于 schedule(for:) 写入 nextRefreshDates。
    private let now: @Sendable () -> Date
    /// reset 发生后多久触发 mid-cycle 补刷新，生产默认 15 秒。
    private let midCycleResetDelay: TimeInterval
    /// 可注入的 sleep，生产默认为真实 Task.sleep；测试可注入立即返回的实现，
    /// 不必等待真实 15 秒。
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// 每 N 次 background 刷新后补一次 .full（让 reset credits 等只在 full 抓取的字段
    /// 也能周期性更新）。生产默认 20。0 表示永不周期 full（只靠启动/手动 full）。
    private let periodicFullEveryN: Int

    /// reset credits 等“只在 .full 抓取”字段的实际刷新周期 = N × provider 间隔。
    /// UI 的新鲜度判定用它而不是 background 间隔，避免误报过期。
    /// nonisolated：纯常量，供默认参数与 UI 在非 MainActor 上下文引用。
    nonisolated static let periodicFullEveryNDefault = 20

    init(
        refreshHandler: @escaping RefreshHandler,
        intervalProvider: @escaping IntervalProvider,
        onNextRefreshChange: @escaping NextRefreshChangeCallback = {},
        now: @escaping @Sendable () -> Date = { Date() },
        midCycleResetDelay: TimeInterval = 15,
        periodicFullEveryN: Int = ProviderRefreshScheduler.periodicFullEveryNDefault,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.refreshHandler = refreshHandler
        self.intervalProvider = intervalProvider
        self.onNextRefreshChange = onNextRefreshChange
        self.now = now
        self.midCycleResetDelay = midCycleResetDelay
        self.periodicFullEveryN = max(periodicFullEveryN, 0)
        self.sleep = sleep
    }

    // MARK: - 生命周期

    /// 给 provider 调度独立 timer。新调度前会先取消旧 task。
    func schedule(for providerID: String) {
        cancel(providerID: providerID)
        let interval = intervalProvider(providerID)
        logInfo("ProviderRefreshScheduler: 为 [\(providerID)] 调度独立 timer，间隔 \(Int(interval))s")
        // 显式 @MainActor：避免 Swift 6 Task 默认不继承 MainActor 导致的 actor hop 时序问题
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var isFirstRefresh = true
            // 已执行的 background 次数；每 periodicFullEveryN 次补一次 .full，
            // 让 reset credits 等只在 full 抓取的字段周期性更新。
            var backgroundsSinceFull = 0
            while !Task.isCancelled {
                let mode: RefreshMode
                if isFirstRefresh {
                    mode = .full
                } else if self.periodicFullEveryN > 0 && backgroundsSinceFull >= self.periodicFullEveryN {
                    // 每 N 次 background 后补一次 full（仍走常规 deadline，不重置退避）。
                    mode = .full
                } else {
                    mode = .background
                }
                let result = await self.refreshHandler(providerID, mode)
                guard !Task.isCancelled else { break }

                if case .deferred = result {
                    // 配置刚变更或用户正手动刷新时，短暂重试，避免错过新配置后的首次刷新。
                    // 不更新计数器——本次并未真正完成。
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // 只在实际完成（非 deferred）后才更新计数：full 清零，background +1。
                if mode == .full {
                    backgroundsSinceFull = 0
                } else {
                    backgroundsSinceFull += 1
                }
                isFirstRefresh = false
                let succeeded: Bool
                if case .completed(let success) = result {
                    succeeded = success
                } else {
                    succeeded = false
                }
                let delay = self.nextDelay(for: providerID, baseInterval: interval, succeeded: succeeded)
                self.nextRefreshDates[providerID] = self.now().addingTimeInterval(delay)
                self.onNextRefreshChange()
                // 用可注入的 sleep（默认实现是真实 Task.sleep，生产行为不变；
                // 测试可注入立即返回的实现，避免等待真实间隔）。
                try? await self.sleep(delay)
            }
        }
        tasks[providerID] = task
    }

    func cancel(providerID: String) {
        tasks[providerID]?.cancel()
        tasks.removeValue(forKey: providerID)
        cancelMidCycleTasks(for: providerID)
        nextRefreshDates.removeValue(forKey: providerID)
        onNextRefreshChange()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for taskList in midCycleTasks.values {
            taskList.forEach { $0.cancel() }
        }
        midCycleTasks.removeAll()
        nextRefreshDates.removeAll()
        failureCounts.removeAll()
        onNextRefreshChange()
    }

    // MARK: - Mid-Cycle Reset Time 补刷新 (reset 发生 15s 后额外触发一次，不打乱 regular nextRefreshDate)

    private func cancelMidCycleTasks(for providerID: String) {
        if let existing = midCycleTasks.removeValue(forKey: providerID) {
            existing.forEach { $0.cancel() }
        }
    }

    /// 针对各子窗口的 reset time：
    /// 如果 reset time 与下一次常规刷新时间差距在 1 分钟（60 秒）以上，
    /// 则在 reset time 发生 15 秒后强制/额外刷新一次（.background 模式）。
    /// 注意：中间补刷新不会更新或修改下一次常规刷新时间 `nextRefreshDates`，不打乱整体 refresh 节奏。
    ///
    /// F3：首次成功刷新时 `nextRefreshDates[providerID]` 尚未写入（它在 handler
    /// 返回后才赋值），而本方法正是在 handler 内被调用。此时使用
    /// `now + intervalProvider(providerID)` 作为本次比较用的 provisional deadline，
    /// 不写回 `nextRefreshDates`，保持"成功/失败与退避后再算正式 deadline"的现有流程。
    func scheduleMidCycleResetRefreshes(for providerID: String, resetsAtDates: [Date]) {
        cancelMidCycleTasks(for: providerID)

        let nowDate = now()
        // 字典无值时（首次刷新）用 now + interval 作为比较用的 provisional deadline；
        // 该值只用于本函数的比较，绝不写回 nextRefreshDates。
        let provisionalDeadline = nowDate.addingTimeInterval(intervalProvider(providerID))
        let nextRefreshDate = nextRefreshDates[providerID] ?? provisionalDeadline

        let uniqueResets = Set(resetsAtDates.compactMap { $0 })
        var newTasks: [Task<Void, Never>] = []

        for resetTime in uniqueResets {
            // 检查 reset time 与 nextRefreshDate 差距在 1 分钟（60 秒）以上
            guard nextRefreshDate.timeIntervalSince(resetTime) > 60 else { continue }
            let targetDate = resetTime.addingTimeInterval(midCycleResetDelay)
            let sleepSeconds = targetDate.timeIntervalSince(nowDate)
            guard sleepSeconds > 0 else { continue }

            logInfo("ProviderRefreshScheduler: 为 [\(providerID)] 调度 resetTime 补刷新，将在 \(Int(sleepSeconds))s 后（reset后\(Int(midCycleResetDelay))s）触发")

            let task = Task { @MainActor [weak self] in
                try? await self?.sleep(sleepSeconds)
                guard let self, !Task.isCancelled else { return }
                logInfo("ProviderRefreshScheduler: [\(providerID)] 触发 resetTime 补刷新")
                _ = await self.refreshHandler(providerID, .background)
            }
            newTasks.append(task)
        }

        if !newTasks.isEmpty {
            midCycleTasks[providerID] = newTasks
        }
    }

    // MARK: - in-flight dedup（给 refreshHandler 入口用）

    /// 在 fetch 入口调用。返回 true 表示成功加入 in-flight 集合；
    /// 返回 false 表示已有同一 provider 的 fetch 在进行中，外层应直接返回 `.deferred`。
    @discardableResult
    func markInFlight(_ providerID: String, mode: RefreshMode = .background) -> Bool {
        guard inFlightModes[providerID] == nil else { return false }
        inFlightModes[providerID] = mode
        return true
    }

    func markNotInFlight(_ providerID: String) {
        inFlightModes.removeValue(forKey: providerID)
        let waiters = inFlightWaiters.removeValue(forKey: providerID) ?? []
        waiters.forEach { $0.continuation.resume(returning: ()) }
    }

    /// 等待当前请求完成。没有请求时立即返回；调用方取消时抛出 `CancellationError`。
    ///
    /// continuation 的注册与取消都由 `@MainActor` 串行保护。取消回调只负责
    /// 投递回主 actor 的精确移除操作，避免取消与请求完成同时 resume 同一个 waiter。
    func waitUntilNotInFlight(_ providerID: String) async throws {
        try Task.checkCancellation()
        guard inFlightModes[providerID] != nil else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // guard 与 append 在同一段 MainActor 执行；若请求刚好已结束，直接放行。
                guard inFlightModes[providerID] != nil else {
                    continuation.resume(returning: ())
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightWaiters[providerID, default: []].append(
                    InFlightWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelInFlightWaiter(providerID: providerID, waiterID: waiterID)
            }
        }
        // resume 与取消可能交错；即使 waiter 已被正常 resume，也不能继续执行
        // 已取消调用方的后续 full refresh。
        try Task.checkCancellation()
    }

    /// 取消一个等待者。找不到说明请求完成路径已经先移除了并 resume 了它。
    private func cancelInFlightWaiter(providerID: String, waiterID: UUID) {
        guard var waiters = inFlightWaiters[providerID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            inFlightWaiters.removeValue(forKey: providerID)
        } else {
            inFlightWaiters[providerID] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: - 成功 / 失败记录（给 refreshHandler 出口用）

    func recordSuccess(_ providerID: String) {
        failureCounts[providerID] = 0
    }

    func recordFailure(_ providerID: String) {
        // R17: 饱和加法，避免理论上的 Int 溢出。
        let current = failureCounts[providerID, default: 0]
        failureCounts[providerID] = SaturatingArithmetic.add(current, 1)
    }

    // MARK: - 观察

    /// 给 UI footer "下次自动刷新时间" 用。所有 provider 中最早的下一次触发时间。
    var earliestNextRefresh: Date? {
        nextRefreshDates.values.min()
    }

    /// 当前 in-flight 集合的快照（测试 / debug 用）
    var inFlightProviderIDs: Set<String> { Set(inFlightModes.keys) }

    /// 当前 provider 等待 in-flight 结束的 waiter 数（测试 / debug 用）。
    func inFlightWaiterCount(for providerID: String) -> Int {
        inFlightWaiters[providerID]?.count ?? 0
    }

    func inFlightMode(for providerID: String) -> RefreshMode? {
        inFlightModes[providerID]
    }

    // MARK: - 退避策略

    /// 计算下次刷新延迟：
    /// - 成功 → 直接用 baseInterval
    /// - 失败 → baseInterval × 2^failures（封顶 5 次叠加），再 cap 30 分钟，套 ±10% jitter
    ///
    /// R17: 退避指数单独用 min(actual, 5)，日志显示真实连续失败次数（不能把封顶值说成实际次数）。
    func nextDelay(for providerID: String, baseInterval: TimeInterval, succeeded: Bool) -> TimeInterval {
        guard !succeeded else { return baseInterval }
        let actualFailures = failureCounts[providerID, default: 1]
        let exponent = min(actualFailures, 5)
        let cappedDelay = min(baseInterval * pow(2, Double(exponent)), 30 * 60)
        let jitter = Double.random(in: 0.9...1.1)
        let delay = cappedDelay * jitter
        logWarn("ProviderRefreshScheduler: [\(providerID)] 连续失败 \(actualFailures) 次（退避级别封顶 5），\(Int(delay)) 秒后重试")
        return delay
    }
}
