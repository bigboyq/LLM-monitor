import Foundation

/// 单个 provider 一次 refresh 的结果。
///
/// - `deferred`: 请求未实际发起（已有 in-flight / 配置刚变化 / auth 缺失），
///   timer 循环里按 1s 短重试节奏继续轮询。
/// - `completed(success:)`: 请求真的完成了。成功与失败都按 baseInterval 排下一拍
///   （失败不退避：固定间隔后台刷新下，拉长重试间隔只会推迟恢复）。
enum ProviderRefreshOutcome: Sendable, Equatable {
    case deferred
    case completed(success: Bool)
}

/// 循环 A（额度循环）：集中管理所有 provider 的定时刷新。
///
/// 架构升级为单一 Task 循环：
/// - 单一常驻 Task 循环，维护每个 provider 的 nextDue 时间；
/// - 循环睡眠到"最早的下一个截止时间"（regular、mid-cycle reset 或非网络辅助 deadline）；
/// - 醒来后并发刷新所有到期的 provider（TaskGroup + 条目级 do-catch 隔离，互不阻塞）；
/// - 既有语义逐条保留：启动首拍 .full、之后 .background、每 20 次 background 补一次 full、
///   失败按 baseInterval 固定间隔随下一定时周期重试（不指数退避）、.deferred 1s 短重试早醒、
///   mid-cycle reset+15s 一次性补刷新（与 regular 共用 deadline driver）、健康窗口边界
///   （只回调 UI，不发网络请求）、ManualRefreshGate 与在飞刷新合并、配置热加载
///   stop+reschedule。`earliestNextRefresh` 仍只暴露 regular deadline。
@MainActor
final class ProviderRefreshScheduler {
    /// 实际 fetch 的回调。`AppState.refreshProviderDirectly` 是这个闭包。
    typealias RefreshHandler = (String, RefreshMode) async -> ProviderRefreshOutcome
    /// 取一个 provider 的基础刷新间隔（秒）。通常 `configStore.config.effectiveRefreshInterval(for:)`。
    typealias IntervalProvider = (String) -> TimeInterval
    /// 任何会改 `nextRefreshDates` 的路径都会触发一次，
    /// 让外部把 `earliestNextRefresh` 重新 publish 到 `@Published nextRefreshAt`。
    typealias NextRefreshChangeCallback = () -> Void
    /// 一批到期 provider 已全部返回，并且其 outcome 已写入调度状态后的通知。
    ///
    /// 保留同步回调以兼容 scheduler 的轻量测试/观察者。
    typealias BatchSettledCallback = @MainActor () -> Void
    /// 生产路径使用 async 回调，把本地 full reconcile 纳入同一个全局刷新事务。
    typealias BatchSettledAsyncCallback = @MainActor () async -> Void
    /// 全局刷新事务开始/结束通知。Manual/Wakeup 与自动 batch 共用这一个 gate。
    typealias JobActivityChangeCallback = @MainActor (Bool) -> Void
    /// 非网络辅助 deadline 到期通知。回调只应更新派生 UI 状态；它不会进入
    /// provider batch，也不会触发 refresh / failure / LocalUsage reconcile。
    typealias HealthBoundaryCallback = @MainActor (Date) -> Void

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
    /// 已执行的 background 刷新次数；每 periodicFullEveryN 次补一次 .full。
    private var backgroundsSinceFull: [String: Int] = [:]
    /// 已经完成过首次常规刷新的 provider 集合（未完成过的首拍用 .full）。
    private var hasDoneFirstRefresh: Set<String> = []
    /// reset+delay 截止时间。和常规 deadline 一样由唯一 driver 服务；到期项
    /// 会先标记为 running，再投递独立 batch task，避免 driver 在网络请求期间阻塞。
    private struct ResetCandidate: Hashable, Sendable {
        let executionAt: Date
    }
    private var resetCandidates: [String: Set<ResetCandidate>] = [:]
    /// 最近一次常规 Interval 事务完成时间。Reset 的两个 30 秒边界都以它和
    /// 下一次 Interval 为准，而不是以某个全局固定 interval 为准。
    private var lastIntervalFinishedDates: [String: Date] = [:]
    /// 全局健康窗口边界。它与 regular/reset 共用 driver 的睡眠，但不属于任一
    /// provider 的网络刷新，因此不会污染 `nextRefreshDates`。
    private var healthBoundaryDate: Date?
    private var runningProviders: Set<String> = []
    /// Wake callers waiting for a deadline batch whose task has been
    /// dispatched but whose handler has not yet entered `runRefresh`.
    private struct RunningWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var runningWaiters: [String: [RunningWaiter]] = [:]
    /// regular deadline 到期但 provider 已有外部请求时暂存；该请求完成后
    /// 直接结算 regular deadline，不再以 deferred+1s 重新发一遍。
    private var pendingRegularProviders: Set<String> = []
    private var providerGenerations: [String: UInt64] = [:]
    private var schedulerGeneration: UInt64 = 0
    private var batchTasks: [UUID: Task<Void, Never>] = [:]
    /// 全局排他刷新事务：自动 batch、Manual、Wakeup 只能有一个处于活动状态。
    private var refreshJobActive = false

    /// 正在进行网络请求的 provider。手动刷新、菜单打开、定时器可能同时触发，
    /// 这里保证同一个 provider 同一时刻只会发出一个请求。
    private var inFlightModes: [String: RefreshMode] = [:]
    /// 最近一次请求的开始/完成活动时间。系统唤醒在这个小窗口内视为已满足，
    /// 避免唤醒通知紧跟定时批次又发一轮 full。
    private var lastRefreshActivity: [String: Date] = [:]
    nonisolated static let systemWakeCoalesceWindow: TimeInterval = 5
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
    private let onBatchSettledAsync: BatchSettledAsyncCallback?
    private let onJobActivityChange: JobActivityChangeCallback
    private let onHealthBoundary: HealthBoundaryCallback
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
    private let systemWakeWindow: TimeInterval

    /// reset credits 等“只在 .full 抓取”字段的实际刷新周期 = N × provider 间隔。
    /// UI 的新鲜度判定用它而不是 background 间隔，避免误报过期。
    /// nonisolated：纯常量，供默认参数与 UI 在非 MainActor 上下文引用。
    nonisolated static let periodicFullEveryNDefault = 20

    init(
        refreshHandler: @escaping RefreshHandler,
        intervalProvider: @escaping IntervalProvider,
        onNextRefreshChange: @escaping NextRefreshChangeCallback = {},
        onBatchSettled: @escaping BatchSettledCallback = {},
        onBatchSettledAsync: BatchSettledAsyncCallback? = nil,
        onJobActivityChange: @escaping JobActivityChangeCallback = { _ in },
        onHealthBoundary: @escaping HealthBoundaryCallback = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        midCycleResetDelay: TimeInterval = 15,
        periodicFullEveryN: Int = ProviderRefreshScheduler.periodicFullEveryNDefault,
        systemWakeCoalesceWindow: TimeInterval = ProviderRefreshScheduler.systemWakeCoalesceWindow,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.refreshHandler = refreshHandler
        self.intervalProvider = intervalProvider
        self.onNextRefreshChange = onNextRefreshChange
        self.onBatchSettled = onBatchSettled
        self.onBatchSettledAsync = onBatchSettledAsync
        self.onJobActivityChange = onJobActivityChange
        self.onHealthBoundary = onHealthBoundary
        self.now = now
        self.midCycleResetDelay = midCycleResetDelay
        self.periodicFullEveryN = max(periodicFullEveryN, 0)
        self.systemWakeWindow = max(systemWakeCoalesceWindow, 0)
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
            providerGenerations[providerID] = (providerGenerations[providerID] ?? 0) &+ 1
        }
        ensureLoopRunning()
        onNextRefreshChange()
        wake()
    }

    /// 尝试开始一个由 AppState 托管的 Manual/Wakeup 全局事务。
    /// 返回 false 表示当前已有自动或外部刷新事务；调用方不得清理 pending schedule。
    @discardableResult
    func beginExternalJob() -> Bool {
        guard !refreshJobActive else { return false }
        refreshJobActive = true
        onJobActivityChange(true)
        wake()
        return true
    }

    /// 结束 Manual/Wakeup 事务。调用方应在所有 quota 与本地 full reconcile 完成后调用。
    func endExternalJob() {
        guard refreshJobActive else { return }
        refreshJobActive = false
        onJobActivityChange(false)
        wake()
    }

    /// 从单循环中移除指定的 provider
    func cancel(providerID: String) {
        managedProviders.remove(providerID)
        nextRefreshDates.removeValue(forKey: providerID)
        resetCandidates.removeValue(forKey: providerID)
        lastIntervalFinishedDates.removeValue(forKey: providerID)
        runningProviders.remove(providerID)
        resumeRunningWaiters(for: providerID)
        pendingRegularProviders.remove(providerID)
        providerGenerations[providerID, default: 0] &+= 1
        backgroundsSinceFull.removeValue(forKey: providerID)
        hasDoneFirstRefresh.remove(providerID)
        lastRefreshActivity.removeValue(forKey: providerID)
        onNextRefreshChange()
        wake()
    }

    /// 注册或清除全局非网络健康边界。该日期只参与 driver 的下一次唤醒，
    /// 不会出现在 `earliestNextRefresh`，也不会触发 provider refresh batch。
    func scheduleHealthBoundary(at date: Date?) {
        healthBoundaryDate = date
        // 生命周期仍由 start() / cancelAll() 管理；重排已运行的 driver 时
        // 只需提前打断当前 sleep。这样初始化阶段注册边界不会偷偷启动循环。
        if loopTask != nil {
            wake()
        }
    }

    /// 停止单循环，重置所有受管状态与定时器
    func cancelAll() {
        loopTask?.cancel()
        loopTask = nil
        batchTasks.values.forEach { $0.cancel() }
        batchTasks.removeAll()
        schedulerGeneration &+= 1
        wake()
        managedProviders.removeAll()
        nextRefreshDates.removeAll()
        resetCandidates.removeAll()
        lastIntervalFinishedDates.removeAll()
        healthBoundaryDate = nil
        runningProviders.removeAll()
        resumeAllRunningWaiters()
        pendingRegularProviders.removeAll()
        providerGenerations.removeAll()
        backgroundsSinceFull.removeAll()
        hasDoneFirstRefresh.removeAll()
        lastRefreshActivity.removeAll()
        if refreshJobActive {
            refreshJobActive = false
            onJobActivityChange(false)
        }
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
            if refreshJobActive {
                _ = await interruptibleSleep(3600, targetWakeDate: nil)
                continue
            }
            let nowDate = now()
            let effectiveWakeDate = max(nowDate, lastCompletedTargetWakeDate ?? nowDate)
            lastCompletedTargetWakeDate = nil
            discardIneligibleResetCandidates(at: effectiveWakeDate)

            // 1. 收集到期项：常规 / reset deadline 到期。先把 provider 标记
            // running，driver 随即继续睡眠/服务其他 deadline，不 await 网络请求。
            var due: [(id: String, mode: RefreshMode, generation: UInt64, isRegular: Bool)] = []
            for id in managedProviders {
                let dueDate = nextRefreshDates[id] ?? nowDate
                if dueDate <= effectiveWakeDate, !runningProviders.contains(id) {
                    if inFlightModes[id] != nil {
                        pendingRegularProviders.insert(id)
                        continue
                    }
                    let mode: RefreshMode
                    if !hasDoneFirstRefresh.contains(id) {
                        mode = .full
                    } else if periodicFullEveryN > 0 && (backgroundsSinceFull[id] ?? 0) >= periodicFullEveryN {
                        mode = .full
                    } else {
                        mode = .background
                    }
                    due.append((id, mode, providerGenerations[id] ?? 0, true))
                }
            }

            if let earliestReset = nextResetCandidate,
               earliestReset.executionAt <= effectiveWakeDate {
                for id in Set(managedProviders).union(resetCandidates.keys) {
                    guard let candidates = resetCandidates[id],
                          candidates.contains(earliestReset),
                          !runningProviders.contains(id) else { continue }
                    resetCandidates[id]?.remove(earliestReset)
                    guard inFlightModes[id] == nil else { continue }
                    if !due.contains(where: { $0.id == id }) {
                        due.append((id, .background, providerGenerations[id] ?? 0, false))
                    }
                }
            }

            // 健康窗口边界是 driver 的辅助 deadline：消费后清掉当前日期，
            // 由回调根据最新状态注册下一个未来边界。它永远不进入 `due`。
            if let boundary = healthBoundaryDate, boundary <= effectiveWakeDate {
                healthBoundaryDate = nil
                onHealthBoundary(effectiveWakeDate)
            }

            if !due.isEmpty {
                due.forEach { runningProviders.insert($0.id) }
                refreshJobActive = true
                onJobActivityChange(true)
                let batch = due
                let batchGeneration = schedulerGeneration
                let batchID = UUID()
                let task = Task { @MainActor [weak self] in
                    await self?.executeBatch(batch, schedulerGeneration: batchGeneration)
                self?.batchTasks.removeValue(forKey: batchID)
                }
                batchTasks[batchID] = task
                initialBatchPending = false
            } else if initialBatchPending {
                // 空 provider 集合也有一个可观察的初始 pass，避免调用方永远
                // 等不到“第一批已结算”的信号。
                initialBatchPending = false
                let initialGeneration = schedulerGeneration
                refreshJobActive = true
                onJobActivityChange(true)
                await settleBatchCallback()
                if schedulerGeneration == initialGeneration, refreshJobActive {
                    refreshJobActive = false
                    onJobActivityChange(false)
                }
            }

            guard !Task.isCancelled else { break }

            // 3. 计算下一次最早截止时刻并休眠
            let regularDates = nextRefreshDates
                .filter {
                    managedProviders.contains($0.key)
                        && !runningProviders.contains($0.key)
                        // A regular deadline that collided with an external
                        // request is settled by that request when it returns.
                        // Keep the date for processOutcome, but do not wake the
                        // driver on the already-expired date in the meantime.
                        && !pendingRegularProviders.contains($0.key)
                        && inFlightModes[$0.key] == nil
                }
                .values
            let resetDates = nextResetCandidate.map { [$0.executionAt] } ?? []
            let auxiliaryDates = healthBoundaryDate.map { [$0] } ?? []
            guard let nextWake = (Array(regularDates) + resetDates + auxiliaryDates).min() else {
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

    private func executeBatch(
        _ batch: [(id: String, mode: RefreshMode, generation: UInt64, isRegular: Bool)],
        schedulerGeneration: UInt64
    ) async {
        var settledCount = 0
        await withTaskGroup(of: (String, ProviderRefreshOutcome, RefreshMode, UInt64, Bool).self) { group in
            for entry in batch {
                let run: @MainActor () async -> (String, ProviderRefreshOutcome, RefreshMode, UInt64, Bool) = {
                    // The batch itself settles regular deadlines below; keep
                    // runRefresh from settling the same deadline a second time.
                    let outcome = await self.runRefresh(
                        entry.id, mode: entry.mode, satisfiesRegularDeadline: false
                    )
                    return (entry.id, outcome, entry.mode, entry.generation, entry.isRegular)
                }
                group.addTask { await run() }
            }
            for await (id, outcome, mode, generation, isRegular) in group {
                guard self.providerGenerations[id] == generation else { continue }
                if isRegular {
                    self.processOutcome(providerID: id, outcome: outcome, mode: mode)
                }
                settledCount += 1
            }
        }
        for entry in batch {
            if self.schedulerGeneration == schedulerGeneration,
               self.providerGenerations[entry.id] == entry.generation {
                self.runningProviders.remove(entry.id)
                self.resumeRunningWaiters(for: entry.id)
            }
        }
        guard self.schedulerGeneration == schedulerGeneration, settledCount > 0 else {
            if self.schedulerGeneration == schedulerGeneration, refreshJobActive {
                refreshJobActive = false
                onJobActivityChange(false)
                wake()
            }
            return
        }
        onNextRefreshChange()
        await settleBatchCallback()
        guard self.schedulerGeneration == schedulerGeneration, refreshJobActive else {
            return
        }
        refreshJobActive = false
        onJobActivityChange(false)
        wake()
    }

    private func settleBatchCallback() async {
        if let onBatchSettledAsync {
            await onBatchSettledAsync()
        } else {
            onBatchSettled()
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
            // 失败不退避：后台固定间隔刷新下，拉长重试间隔只会推迟恢复；
            // 失败 provider 直接随下一定时周期重试（与成功完全相同的排期）。
            let baseInterval = intervalProvider(providerID)
            lastIntervalFinishedDates[providerID] = now()
            if !success {
                logWarn("ProviderRefreshScheduler: [\(providerID)] 刷新失败，\(Int(baseInterval)) 秒后随下一定时周期重试")
            }
            nextRefreshDates[providerID] = now().addingTimeInterval(baseInterval)
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

    /// 针对一个 Provider 的 reset candidates：
    /// - Interval <= 60 秒时完全跳过 reset；
    /// - 以 resetAt + delay 作为实际执行时间；
    /// - 实际执行时间距离上次 Interval 完成、下一次 Interval 都必须严格大于 30 秒。
    func scheduleMidCycleResetRefreshes(for providerID: String, resetsAtDates: [Date]) {
        resetCandidates.removeValue(forKey: providerID)

        let nowDate = now()
        let interval = max(intervalProvider(providerID), 0)
        guard interval > 60 else { return }

        let provisionalDeadline = nowDate.addingTimeInterval(interval)
        let nextRefreshDate: Date
        if let scheduled = nextRefreshDates[providerID], scheduled > nowDate {
            nextRefreshDate = scheduled
        } else {
            nextRefreshDate = provisionalDeadline
        }
        let lastIntervalFinished = lastIntervalFinishedDates[providerID] ?? nowDate

        let uniqueResets = Set(resetsAtDates.compactMap { $0 })
        var candidates = Set<ResetCandidate>()

        for resetTime in uniqueResets {
            let executionAt = resetTime.addingTimeInterval(midCycleResetDelay)
            guard executionAt > nowDate,
                  executionAt.timeIntervalSince(lastIntervalFinished) > 30,
                  nextRefreshDate.timeIntervalSince(executionAt) > 30 else { continue }

            logInfo("ProviderRefreshScheduler: 为 [\(providerID)] 调度 reset 补刷新，执行时间距上次 Interval/下次 Interval 均超过 30s")

            candidates.insert(ResetCandidate(executionAt: executionAt))
        }

        if !candidates.isEmpty {
            resetCandidates[providerID] = candidates
            ensureLoopRunning()
            wake()
        }
    }

    /// 丢弃已经错过或因时间线变化而不再合法的 reset；这样一次 Manual/Wakeup
    /// 重锚后不会有旧 candidate 穿透新的 Interval 时间线。
    private func discardIneligibleResetCandidates(at date: Date) {
        for providerID in Array(resetCandidates.keys) {
            guard let candidates = resetCandidates[providerID] else { continue }
            let interval = intervalProvider(providerID)
            let last = lastIntervalFinishedDates[providerID] ?? now()
            let next = nextRefreshDates[providerID] ?? date.addingTimeInterval(interval)
            let valid = candidates.filter {
                interval > 60
                    && $0.executionAt.timeIntervalSince(last) > 30
                    && next.timeIntervalSince($0.executionAt) > 30
            }
            if valid.isEmpty {
                resetCandidates.removeValue(forKey: providerID)
            } else {
                resetCandidates[providerID] = valid
            }
        }
    }

    private var nextResetCandidate: ResetCandidate? {
        resetCandidates.values.flatMap { $0 }.min { $0.executionAt < $1.executionAt }
    }

    /// Manual/Wakeup 在本地 full reconcile 完成后调用：所有 Provider 的 Interval
    /// 和 Reset 时间线同时从同一个事务完成时刻重新开始。
    func reanchorAllProviders(
        at finishedAt: Date,
        resetDatesByProvider: [String: [Date]]
    ) {
        for providerID in managedProviders {
            nextRefreshDates[providerID] = finishedAt.addingTimeInterval(intervalProvider(providerID))
            lastIntervalFinishedDates[providerID] = finishedAt
            backgroundsSinceFull[providerID] = 0
            hasDoneFirstRefresh.insert(providerID)
            pendingRegularProviders.remove(providerID)
            resetCandidates.removeValue(forKey: providerID)
        }
        for providerID in managedProviders {
            scheduleMidCycleResetRefreshes(
                for: providerID,
                resetsAtDates: resetDatesByProvider[providerID] ?? []
            )
        }
        onNextRefreshChange()
        wake()
    }

    // MARK: - in-flight dedup（给 refreshHandler 入口用）

    /// 统一的刷新执行入口：in-flight 标记、handler 调用、成败记录全部由调度器
    /// 自身完成（handler 返回即自动结算），调用方不再手动 mark/record —— 消灭
    /// 原来"AppState 驱动调度器内部状态"的回调环。
    func runRefresh(
        _ providerID: String,
        mode: RefreshMode,
        satisfiesRegularDeadline: Bool = true
    ) async -> ProviderRefreshOutcome {
        guard markInFlight(providerID, mode: mode) else {
            logDebug("ProviderRefreshScheduler: [\(providerID)] 已有请求进行中，合并本次触发")
            return .deferred
        }
        if satisfiesRegularDeadline,
           managedProviders.contains(providerID),
           let regularDate = nextRefreshDates[providerID], regularDate <= now() {
            // A manual or wake-triggered request can win the race with the
            // driver at an already-due regular deadline. Let that real request
            // advance the regular schedule instead of producing a deferred 1s
            // retry after it completes.
            pendingRegularProviders.insert(providerID)
        }
        lastRefreshActivity[providerID] = now()
        defer { markNotInFlight(providerID) }
        let outcome = await refreshHandler(providerID, mode)
        lastRefreshActivity[providerID] = now()
        if pendingRegularProviders.remove(providerID) != nil,
           providerGenerations[providerID] != nil {
            // The request that was already in flight fulfilled the regular
            // deadline. Preserve its actual mode/result and advance the next
            // regular date without generating a second fetch.
            settleExternalRegularDeadline(providerID: providerID, outcome: outcome, mode: mode)
        }
        return outcome
    }

    /// 系统唤醒专用入口。检查与登记 in-flight 在 MainActor 上串行完成，
    /// 因而不会出现 check-then-run race；唤醒不登记 ManualRefreshGate 的 pending
    /// full。已有请求或刚完成请求均视为满足本次 wake，否则只执行一次 full。
    func refreshForSystemWake(_ providerID: String) async {
        // A scheduled batch is marked running before its task gets a chance to
        // mark inFlight. A continuation closes that dispatch window without
        // polling or a check-then-run race; the completed batch satisfies this
        // wake.
        while runningProviders.contains(providerID) {
            do {
                try await waitUntilNotRunning(providerID)
            } catch {
                return
            }
        }
        if inFlightModes[providerID] != nil {
            try? await waitUntilNotInFlight(providerID)
            // runRefresh 的 defer 先唤醒 waiter，随后批次才处理 outcome；让
            // 调用方继续前主动让出一次 actor，确保 quota 状态先结算。
            await Task.yield()
            return
        }
        if let activity = lastRefreshActivity[providerID],
           now().timeIntervalSince(activity) <= systemWakeWindow {
            return
        }
        _ = await runRefresh(providerID, mode: .full)
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
        // A reset deadline may have been hidden from nextWake while this
        // external request was in flight. Re-evaluate it as soon as the
        // request ends instead of leaving the driver asleep for its fallback
        // hour-long idle interval.
        wake()
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

    /// Wait for a deadline batch to leave the driver's running set. Unlike a
    /// timer/polling loop this continuation is resumed exactly when the batch
    /// settles (or when the source is cancelled).
    private func waitUntilNotRunning(_ providerID: String) async throws {
        try Task.checkCancellation()
        guard runningProviders.contains(providerID) else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard runningProviders.contains(providerID) else {
                    continuation.resume(returning: ())
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                runningWaiters[providerID, default: []].append(
                    RunningWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRunningWaiter(providerID: providerID, waiterID: waiterID)
            }
        }
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

    private func cancelRunningWaiter(providerID: String, waiterID: UUID) {
        guard var waiters = runningWaiters[providerID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            runningWaiters.removeValue(forKey: providerID)
        } else {
            runningWaiters[providerID] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeRunningWaiters(for providerID: String) {
        let waiters = runningWaiters.removeValue(forKey: providerID) ?? []
        waiters.forEach { $0.continuation.resume(returning: ()) }
    }

    private func resumeAllRunningWaiters() {
        let waiters = runningWaiters.values.flatMap { $0 }
        runningWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: ()) }
    }

    /// Settle a regular deadline consumed by a real external request. The
    /// driver batch path invokes the same state transition but emits its
    /// batch-level callbacks after all entries complete; this path is a
    /// one-provider batch and therefore emits each callback exactly once.
    private func settleExternalRegularDeadline(
        providerID: String,
        outcome: ProviderRefreshOutcome,
        mode: RefreshMode
    ) {
        guard managedProviders.contains(providerID) else { return }
        processOutcome(providerID: providerID, outcome: outcome, mode: mode)
        onNextRefreshChange()
        onBatchSettled()
        wake()
    }

    // MARK: - 观察

    /// 给 UI footer "下次自动刷新时间" 用。所有受管 provider 中最早的下一次常规触发时间。
    var earliestNextRefresh: Date? {
        managedProviders.compactMap { nextRefreshDates[$0] }.min()
    }

    /// 当前已注册的健康边界（测试 / debug 用）。不对外映射为 nextRefreshAt。
    var scheduledHealthBoundary: Date? { healthBoundaryDate }

    /// 当前 in-flight 集合的快照（测试 / debug 用）
    var inFlightProviderIDs: Set<String> { Set(inFlightModes.keys) }

    /// 已由 deadline driver 投递、但 handler 可能尚未开始的 batch。这个
    /// seam 让 wake 合并竞态可以稳定验证，不把网络/解析逻辑暴露给 UI。
    var runningProviderIDs: Set<String> { runningProviders }

    /// 当前 provider 等待 in-flight 结束的 waiter 数（测试 / debug 用）。
    func inFlightWaiterCount(for providerID: String) -> Int {
        inFlightWaiters[providerID]?.count ?? 0
    }

    func inFlightMode(for providerID: String) -> RefreshMode? {
        inFlightModes[providerID]
    }
}
