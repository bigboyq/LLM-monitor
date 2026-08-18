import Foundation
import Combine

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

    /// 日志前缀（如 `"[minimax-scan]"`）。生命周期日志统一用它，子类不再各自拼写。
    nonisolated let logTag: String

    private var inFlightTask: Task<Void, Never>?
    /// 每次 `scan()` / `cancelInFlight()` 递增 generation token。
    /// runScan 结束时跟 latest generation 比对，不一致就丢弃结果，
    /// 防止旧 generation 的 task 在新 generation 启动后写回状态。
    private var latestGeneration: UInt64 = 0

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
        guard inFlightTask == nil else { return }
        isScanning = true
        latestGeneration &+= 1
        let startedGeneration = latestGeneration
        inFlightTask = Task { [weak self] in
            await self?.runScan(startedGeneration: startedGeneration)
        }
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
        isScanning = false
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    private func runScan(startedGeneration: UInt64) async {
        defer {
            // 只在当前 generation 仍是 latest 时清 isScanning / inFlightTask。
            // 避免 cancel + rescan 期间，旧 gen 的 defer 把 isScanning 设 false
            // 但新 gen 还在跑，UI 闪一下"不在扫描"然后又设回 true。
            if startedGeneration == latestGeneration {
                isScanning = false
                inFlightTask = nil
            } else {
                logInfo("\(logTag) 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(latestGeneration)")
            }
        }
        let work = makeWork(startedGeneration: startedGeneration)
        await LocalUsageScanRunner.run(
            logTag: logTag,
            startedGeneration: startedGeneration,
            latestGeneration: { self.latestGeneration },
            work: work,
            applyResult: { result in
                self.lastResult = result
                self.lastError = nil
            },
            applyError: { message in
                // 失败时保留上次的 lastResult（如果之前有），UI 不闪空白
                self.lastError = message
            }
        )
    }

    /// 子类构造实际的工作闭包：通常包一层 `Self.pipelineMutex` + 调用自己的
    /// `performScanPure`（nonisolated static，重 I/O 不占 MainActor）。
    /// `startedGeneration` 供带 lastCommittedGeneration 守门的 pipeline 使用。
    func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> Usage {
        fatalError("\(type(of: self)): subclass must override makeWork(startedGeneration:)")
    }
}

// MARK: - LocalUsageScanner conformance

extension LocalUsageScannerBase: LocalUsageScanner {
    var lastResultPublisher: AnyPublisher<Usage?, Never> { $lastResult.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { $isScanning.eraseToAnyPublisher() }
}
