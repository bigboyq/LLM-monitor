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

/// 循环 A（额度循环）：集中管理所有 provider 的定时刷新。
///
/// 架构升级为单一 Task 循环：
/// - 单一常驻 Task 循环，维护每个 provider 的 nextDue 时间与失败计数；
/// - 循环睡眠到"最早的下一个截止时间"（min(各 provider nextDue, mid-cycle reset 时刻)）；
/// - 醒来后并发刷新所有到期的 provider（TaskGroup + 条目级 do-catch 隔离，互不阻塞）；
/// - 既有语义逐条保留：启动首拍 .full、之后 .background、每 20 次 background 补一次 full、
///   失败指数退避（封顶 30min ±10% jitter）、.deferred 1s 短重试早醒、
///   mid-cycle reset+15s 一次性补刷新、ManualRefreshGate 与在飞刷新合并、配置热加载 stop+reschedule。
@MainActor
final class ProviderRefreshScheduler {
    /// 实际 fetch 的回调。`AppState.refreshProviderDirectly` 是这个闭包。
    typealias RefreshHandler = (String, RefreshMode) async -> ProviderRefreshOutcome
    /// 取一个 provider 的基础刷新间隔（秒）。通常 `configStore.config.effectiveRefreshInterval(for:)`。
    typealias IntervalProvider = (String) -> TimeInterval
    /// 任何会改 `nextRefreshDates` / `failureCounts` 的路径都会触发一次，
    /// 让外部把 `earliestNextRefresh` 重新 publish 到 `@Published nextRefreshAt`。
    typealias NextRefreshChangeCallback = () -> Void
    /// 一批到期 provider 已全部返回，并且其 outcome 已写入调度状态后的通知。
    ///
    /// 该回调是同步的、非 async 的：调用方若要启动本地用量 reconcile，应当
    /// 在回调中投递一个独立 Task，不能把本地扫描 await 到额度循环里。
    typealias BatchSettledCallback = @MainActor () -> Void

    // MARK: - 内部状态

    /// 单一常驻额度调度循环 Task
    private var loopTask: Task<Void, Never>?
    /// 睡眠等待时的休眠 Task（wake() 时精确 cancel 提前唤醒，无 continuation 悬挂风险）
    private var sleepTask: Task<Void, any Error>?
    /// 上一次休眠正常走满的目标截止时刻（在注入了极速测试 sleep 时，作为虚拟时间推进标记）
    private var lastCompletedTargetWakeDate: Date?

    /// 当前受管的所有 provider 标识
    private var managedProviders: Set<String> = []
    /// 各 provider 常规刷新的下一次触发时间。UI footer 展示其中最早的一个。
    private var nextRefreshDates: [String: Date] = [:]
    /// 连续失败计数，用于每个 provider 独立的指数退避。
    private var failureCounts: [String: Int] = [:]
    /// 已执行的 background 刷新次数；每 periodicFullEveryN 次补一次 .full。
    private var backgroundsSinceFull: [String: Int] = [:]
    /// 已经完成过首次常规刷新的 provider 集合（未完成过的首拍用 .full）。
    private var hasDoneFirstRefresh: Set<String> = []
    /// 各子窗口 reset time 产生的中间补刷新 Task（reset 发生 15s 后触发，不重置常规刷新节奏）
    private var midCycleTasks: [String: [Task<Void, Never>]] = [:]

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

    // MARK: - 依赖注入

    private let refreshHandler: RefreshHandler
    private let intervalProvider: IntervalProvider
    private let onNextRefreshChange: NextRefreshChangeCallback
    private let onBatchSettled: BatchSettledCallback
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
        onBatchSettled: @escaping BatchSettledCallback = {},
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
        self.onBatchSettled = onBatchSettled
        self.now = now
        self.midCycleResetDelay = midCycleResetDelay
        self.periodicFullEveryN = max(periodicFullEveryN, 0)
        self.sleep = sleep
    }

    // MARK: - 生命周期

    /// 启动调度循环。即使当前没有 managed provider，也会完成一次空的初始
    /// batch，并触发 `onBatchSettled`。后续 provider 可通过 `schedule(for:)`
    /// 动态加入。
    func start() {
        ensureLoopRunning()
        wake()
    }

    /// 注册 provider 进入单循环。若该 provider 之前未设置 nextRefreshDate，则立即安排首拍。
    func schedule(for providerID: String) {
        managedProviders.insert(providerID)
        let interval = intervalProvider(providerID)
        logInfo("ProviderRefreshScheduler: 将 [\(providerID)] 纳入额度循环，基础间隔 \(Int(interval))s")

        if nextRefreshDates[providerID] == nil {
            nextRefreshDates[providerID] = now()
        }
        ensureLoopRunning()
        onNextRefreshChange()
        wake()
    }

    /// 从单循环中移除指定的 provider
    func cancel(providerID: String) {
        managedProviders.remove(providerID)
        nextRefreshDates.removeValue(forKey: providerID)
        cancelMidCycleTasks(for: providerID)
        failureCounts.removeValue(forKey: providerID)
        backgroundsSinceFull.removeValue(forKey: providerID)
        hasDoneFirstRefresh.remove(providerID)
        onNextRefreshChange()
        wake()
    }

    /// 停止单循环，重置所有受管状态与定时器
    func cancelAll() {
        loopTask?.cancel()
        loopTask = nil
        wake()
        managedProviders.removeAll()
        nextRefreshDates.removeAll()
        for taskList in midCycleTasks.values {
            taskList.forEach { $0.cancel() }
        }
        midCycleTasks.removeAll()
        failureCounts.removeAll()
        backgroundsSinceFull.removeAll()
        hasDoneFirstRefresh.removeAll()
        onNextRefreshChange()
    }

    // MARK: - 循环 A 主驱动

    private func ensureLoopRunning() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    private func runLoop() async {
        var initialBatchPending = true
        while !Task.isCancelled {
            let nowDate = now()
            let effectiveWakeDate = max(nowDate, lastCompletedTargetWakeDate ?? nowDate)
            lastCompletedTargetWakeDate = nil

            // 1. 收集到期项：常规刷新到期
            var regularDue: [String] = []
            for id in managedProviders {
                let due = nextRefreshDates[id] ?? nowDate
                if due <= effectiveWakeDate {
                    regularDue.append(id)
                }
            }

            // 2. 并发调度到期项（TaskGroup + 条目级隔离）
            if !regularDue.isEmpty {
                await withTaskGroup(of: (String, ProviderRefreshOutcome, RefreshMode).self) { group in
                    for id in regularDue {
                        let mode: RefreshMode
                        if !hasDoneFirstRefresh.contains(id) {
                            mode = .full
                        } else if periodicFullEveryN > 0 && (backgroundsSinceFull[id] ?? 0) >= periodicFullEveryN {
                            mode = .full
                        } else {
                            mode = .background
                        }
                        // 把 MainActor 隔离的任务体先做成隔离闭包值（隔离闭包值本身
                        // 是 Sendable），child task 只捕获这个 Sendable 值、调用时再
                        // 跳回 MainActor。直接给 addTask 传 `@MainActor` 闭包会触发
                        // region-based isolation checker 的已知误报，Swift 6 门禁
                        // 编译失败。strong capture：runLoop 本身就强持有 self，
                        // group 在同一 await 内全部消费完，weak 不会延长生命周期。
                        let run: @MainActor () async -> (String, ProviderRefreshOutcome, RefreshMode) = {
                            let outcome = await self.runRefresh(id, mode: mode)
                            return (id, outcome, mode)
                        }
                        group.addTask { await run() }
                    }
                    for await (id, outcome, mode) in group {
                        self.processOutcome(providerID: id, outcome: outcome, mode: mode)
                    }
                }
                onNextRefreshChange()
                // 必须在 TaskGroup 完成、且每个 outcome 都已 process 后通知。
                onBatchSettled()
                initialBatchPending = false
            } else if initialBatchPending {
                // 空 provider 集合也有一个可观察的初始 pass，避免调用方永远
                // 等不到“第一批已结算”的信号。
                initialBatchPending = false
                onBatchSettled()
            }

            guard !Task.isCancelled else { break }

            // 3. 计算下一次最早截止时刻并休眠
            let managedDates = nextRefreshDates.filter { managedProviders.contains($0.key) }
            guard let nextWake = managedDates.values.min() else {
                _ = await interruptibleSleep(3600, targetWakeDate: nil)
                continue
            }

            let sleepSeconds = max(nextWake.timeIntervalSince(now()), 0)
            let completed = await interruptibleSleep(sleepSeconds, targetWakeDate: nextWake)
            if completed {
                lastCompletedTargetWakeDate = nextWake
            }
        }
    }

    private func processOutcome(providerID: String, outcome: ProviderRefreshOutcome, mode: RefreshMode) {
        guard managedProviders.contains(providerID) else { return }

        switch outcome {
        case .deferred:
            nextRefreshDates[providerID] = now().addingTimeInterval(1.0)
        case .completed(let success):
            hasDoneFirstRefresh.insert(providerID)
            if mode == .full {
                backgroundsSinceFull[providerID] = 0
            } else {
                backgroundsSinceFull[providerID, default: 0] += 1
            }
            let baseInterval = intervalProvider(providerID)
            let delay = nextDelay(for: providerID, baseInterval: baseInterval, succeeded: success)
            nextRefreshDates[providerID] = now().addingTimeInterval(delay)
        }
    }

    @discardableResult
    private func interruptibleSleep(_ seconds: TimeInterval, targetWakeDate: Date?) async -> Bool {
        guard seconds > 0 else { return true }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.sleep(seconds)
        }
        self.sleepTask = task
        do {
            try await task.value
            self.sleepTask = nil
            return true
        } catch {
            self.sleepTask = nil
            return false
        }
    }

    private func wake() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    // MARK: - Mid-Cycle Reset Time 补刷新 (reset 发生 15s 后额外触发一次，不打乱 regular nextRefreshDate)

    private func cancelMidCycleTasks(for providerID: String) {
        if let oldTasks = midCycleTasks.removeValue(forKey: providerID) {
            for task in oldTasks { task.cancel() }
        }
    }

    /// 针对各子窗口的 reset time：
    /// 如果 reset time 与下一次常规刷新时间差距在 1 分钟（60 秒）以上，
    /// 则在 reset time 发生 15 秒后强制/额外刷新一次（.background 模式）。
    func scheduleMidCycleResetRefreshes(for providerID: String, resetsAtDates: [Date]) {
        cancelMidCycleTasks(for: providerID)

        let nowDate = now()
        let provisionalDeadline = nowDate.addingTimeInterval(intervalProvider(providerID))
        // The regular refresh handler calls this before processOutcome records the
        // next regular deadline.  At that point the existing date is the deadline
        // that just fired, so it must not make a reset that is well inside the next
        // interval look like it is already too close to the regular refresh.
        let nextRefreshDate: Date
        if let scheduled = nextRefreshDates[providerID], scheduled > nowDate {
            nextRefreshDate = scheduled
        } else {
            nextRefreshDate = provisionalDeadline
        }

        let uniqueResets = Set(resetsAtDates.compactMap { $0 })
        var newTasks: [Task<Void, Never>] = []

        for resetTime in uniqueResets {
            guard nextRefreshDate.timeIntervalSince(resetTime) > 60 else { continue }
            let targetDate = resetTime.addingTimeInterval(midCycleResetDelay)
            let sleepSeconds = targetDate.timeIntervalSince(nowDate)
            guard sleepSeconds > 0 else { continue }

            logInfo("ProviderRefreshScheduler: 为 [\(providerID)] 调度 resetTime 补刷新，将在 \(Int(sleepSeconds))s 后（reset后\(Int(midCycleResetDelay))s）触发")

            let task = Task { @MainActor [weak self] in
                try? await self?.sleep(sleepSeconds)
                guard let self, !Task.isCancelled else { return }
                logInfo("ProviderRefreshScheduler: [\(providerID)] 触发 resetTime 补刷新")
                _ = await self.runRefresh(providerID, mode: .background)
                // reset-time 补刷新也是一个完整的 Provider batch（只是只有
                // 一个 provider），因此同样必须在 outcome 结算后驱动 reconcile。
                guard !Task.isCancelled else { return }
                self.onBatchSettled()
            }
            newTasks.append(task)
        }

        if !newTasks.isEmpty {
            midCycleTasks[providerID] = newTasks
        }
    }

    // MARK: - in-flight dedup（给 refreshHandler 入口用）

    /// 统一的刷新执行入口：in-flight 标记、handler 调用、成败记录全部由调度器
    /// 自身完成（handler 返回即自动结算），调用方不再手动 mark/record —— 消灭
    /// 原来"AppState 驱动调度器内部状态"的回调环。
    func runRefresh(_ providerID: String, mode: RefreshMode) async -> ProviderRefreshOutcome {
        guard markInFlight(providerID, mode: mode) else {
            logDebug("ProviderRefreshScheduler: [\(providerID)] 已有请求进行中，合并本次触发")
            return .deferred
        }
        defer { markNotInFlight(providerID) }
        let outcome = await refreshHandler(providerID, mode)
        switch outcome {
        case .completed(let success):
            if success {
                recordSuccess(providerID)
            } else {
                recordFailure(providerID)
            }
        case .deferred:
            break
        }
        return outcome
    }

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

    /// 给 UI footer "下次自动刷新时间" 用。所有受管 provider 中最早的下一次常规触发时间。
    var earliestNextRefresh: Date? {
        managedProviders.compactMap { nextRefreshDates[$0] }.min()
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
