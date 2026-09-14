import Foundation
import Combine

/// 扫描请求的覆盖范围。
enum LocalUsageScanMode: Sendable, Equatable {
    case full
    case dirty
}

/// 本地用量 scanner 的共享生命周期基座 —— 5 个 scanner（antigravity / minimax /
/// glm-zcode / opencode / dsh）手工镜像的外壳收口：
///
/// - `@Published lastResult / isScanning / lastError` 状态
/// - `scan()` in-flight dedup + `cancelInFlight()` 取消
/// - generation token 守门（旧 worker 不写回新状态）
/// - `LocalUsageScanRunner` 接线（启动/完成/出错的 generation check + 取消过滤）
/// - `LocalUsageScanner` 协议 conformance（`lastResultPublisher` / `isScanningPublisher`）
///
/// 子类只需实现 `makeWork(startedGeneration:)`，返回包好各自 mutex + `performScanPure`
/// 的工作闭包。pipeline 语义（缓存格式、指纹、lastCommittedGeneration 守门）留在子类。
///
/// `pipelineLock`（默认 fatalError）返回子类的 `static let pipelineMutex`——泛型类
/// 不能持有 static 存储属性，mutex 由每个 concrete 子类声明并跨实例共享。
@MainActor
class LocalUsageScannerBase<Usage: Equatable>: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: Usage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    /// Lifecycle hooks installed by LocalUsageCoordinator.  A scanner owns its
    /// FSEvents stream and calls `markDirty()` from that stream; the hook lets
    /// the coordinator project that source-level transition to the UI without
    /// maintaining a global watcher registry.
    var onDirty: (@MainActor () -> Void)?
    var onFresh: (@MainActor () -> Void)?

    /// 日志前缀（如 `"[minimax-scan]"`）。生命周期日志统一用它，子类不再各自拼写。
    nonisolated let logTag: String

    private var inFlightTask: Task<Void, Never>?
    private struct ScanWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var scanWaiters: [ScanWaiter] = []
    /// 每次 `scan()` / `cancelInFlight()` 递增 generation token。
    /// runScan 结束时跟 latest generation 比对，不一致就丢弃结果，
    /// 防止旧 generation 的 task 在新 generation 启动后写回状态。
    private var latestGeneration: UInt64 = 0
    /// 与 generation 分开计数：取消/重启扫描不等于 source 发生变化。
    private var dirtyRevision: UInt64 = 0
    private(set) var isDirty = true
    private(set) var lastFreshAt: Date?

    /// 子类返回自己的 `static let pipelineMutex`。整个扫描 pipeline 的串行锁：
    /// cancel+rescan 时两个 worker 会 race cache 写（新 worker 读到旧 disk 状态，
    /// 算完写入 = 回滚新 worker 的 view），用 async-aware 的 AsyncMutex 串行整个
    /// pipeline 彻底消除 revert 风险。
    nonisolated var pipelineLock: AsyncMutex {
        fatalError("\(type(of: self)): subclass must override pipelineLock")
    }

    init(logTag: String, cachedResult: Usage?) {
        self.logTag = logTag
        self.lastResult = cachedResult
    }

    /// 触发一次扫描。如果上一次还在跑，直接忽略（dedup）。
    func scan() {
        markDirty()
        scan(mode: .dirty)
    }

    /// 触发指定模式的扫描。如果上一次还在跑，直接合并到现有 in-flight scan。
    /// 旧 scanner 只需继续实现原有的 makeWork 接口即可工作。
    func scan(mode: LocalUsageScanMode) {
        guard inFlightTask == nil else { return }
        // The scanner must not observe its own reads or cache writes as source
        // mutations. Concrete scanners stop their stream here and recreate it
        // after this scan settles.
        stopWatching()
        isScanning = true
        latestGeneration &+= 1
        let startedGeneration = latestGeneration
        let startedDirtyRevision = dirtyRevision
        inFlightTask = Task { [weak self] in
            await self?.runScan(
                startedGeneration: startedGeneration,
                mode: mode,
                startedDirtyRevision: startedDirtyRevision
            )
        }
    }

    /// 标记 source 需要在下一次 dirty reconcile 中重新处理。
    func markDirty() {
        let wasDirty = isDirty
        dirtyRevision &+= 1
        isDirty = true
        if !wasDirty {
            logDebug("\(logTag) freshness clean → dirty")
        }
        onDirty?()
    }

    /// 显式声明 scanner 已产出 fresh 快照。基座在成功且期间没有新 dirty
    /// revision 时自动调用；外部适配器也可调用此方法接入自己的 freshness。
    func markFresh(at date: Date = Date()) {
        isDirty = false
        lastFreshAt = date
        logDebug("\(logTag) freshness → clean")
        onFresh?()
    }

    /// 等待当前扫描 settle。没有 in-flight 时立即返回；调用方取消时抛出
    /// CancellationError。取消 scanner 本身会恢复所有 waiter，避免停机悬挂。
    func waitUntilSettled() async throws {
        try Task.checkCancellation()
        guard inFlightTask != nil else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard inFlightTask != nil else {
                    continuation.resume(returning: ())
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                scanWaiters.append(ScanWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelScanWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
    }

    /// 取消当前 in-flight scan。配置变更 / AppState.stop() 调用，
    /// 防止旧扫描结果写回新状态。实际效果：
    /// 1. generation 递增 —— 旧 runScan 完成时 generation 比对失败，主动 return
    /// 2. Task.cancel() —— 让继承取消状态的扫描工作尽快抛 CancellationError
    /// 3. isScanning 立即清 false —— 防止"cancel 后不 rescan"时 UI 永远显示
    ///    "scanning..."（generation 守门本意是不让旧任务干扰新任务，但 cancel
    ///    不 rescan 时旧任务 defer 因 generation 不匹配跳过清理，isScanning 卡在
    ///    true，需要 cancel 主动补）
    func cancelInFlight() {
        latestGeneration &+= 1
        markDirty()
        isScanning = false
        inFlightTask?.cancel()
        inFlightTask = nil
        resumeAllScanWaiters()
    }

    /// Concrete scanners override this to stop their own FSEvents stream.
    /// Keeping the lifecycle hook on the scanner base prevents a process-wide
    /// watcher registry and lets AppState stop all source streams on shutdown.
    func stopWatching() {}

    /// Concrete scanners recreate their per-source FSEvents stream after a
    /// scan. The default keeps non-filesystem adapters source-compatible.
    func restartWatching() {}

    private func runScan(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode,
        startedDirtyRevision: UInt64
    ) async {
        defer {
            // 只在当前 generation 仍是 latest 时清 isScanning / inFlightTask。
            // 避免 cancel + rescan 期间，旧 gen 的 defer 把 isScanning 设 false
            // 但新 gen 还在跑，UI 闪一下"不在扫描"然后又设回 true。
            if startedGeneration == latestGeneration {
                isScanning = false
                inFlightTask = nil
                resumeAllScanWaiters()
                restartWatching()
            } else {
                logInfo("\(logTag) 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(latestGeneration)")
            }
        }
        let work = makeWork(startedGeneration: startedGeneration, mode: mode)
        await LocalUsageScanRunner.run(
            logTag: logTag,
            startedGeneration: startedGeneration,
            latestGeneration: { self.latestGeneration },
            work: work,
            applyResult: { result in
                self.lastResult = result
                self.lastError = nil
                if self.dirtyRevision == startedDirtyRevision {
                    self.markFresh()
                }
            },
            applyError: { message in
                // 失败时保留上次的 lastResult（如果之前有），UI 不闪空白；
                // 未被 FSEvents 提前标记的失败也必须保持 dirty，避免继续展示
                // 一个无法确认新鲜度的快照。
                self.markDirty()
                self.lastError = message
            }
        )
    }

    private func cancelScanWaiter(_ waiterID: UUID) {
        guard let index = scanWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = scanWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeAllScanWaiters() {
        let waiters = scanWaiters
        scanWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: ()) }
    }

    /// 子类构造实际的工作闭包：通常包一层 `Self.pipelineMutex` + 调用自己的
    /// `performScanPure`（nonisolated static，重 I/O 不占 MainActor）。
    /// `startedGeneration` 供带 lastCommittedGeneration 守门的 pipeline 使用。
    func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> Usage {
        fatalError("\(type(of: self)): subclass must override makeWork(startedGeneration:)")
    }

    /// 新 mode-aware scanner 的适配点。默认转发到旧接口，具体 scanner 可以
    /// 分批迁移而不需要一次性修改所有实现文件。
    func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> Usage {
        makeWork(startedGeneration: startedGeneration)
    }
}

// MARK: - LocalUsageScanner conformance

extension LocalUsageScannerBase: LocalUsageScanner {
    var lastResultPublisher: AnyPublisher<Usage?, Never> { $lastResult.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { $isScanning.eraseToAnyPublisher() }
}
