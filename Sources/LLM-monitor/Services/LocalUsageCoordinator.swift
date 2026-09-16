import Foundation
import Combine

/// 统一的本地用量 scanner wire-up 容器。
///
/// 适用：任何暴露 `@Published var lastResult: Usage?` + `@Published var isScanning: Bool`
/// + `func scan()` 的本地 scanner（当前：Antigravity、Minimax、GLM ZCode、OpenCode、DSH）。
///
/// 设计动机（9-commit refactor #9）：
/// - 之前 AppState 中四类本地 scanner 各自维护近镜像的 30+ 行：singleton cache + 2 个
///   Combine sink（lastResult→apply, isScanning→setScanningState）。
/// - 抽 LocalUsageCoordinator 后，每个 scanner 配一个 coordinator，AppState 的 trigger 方法
///   退化成 1 行 `coordinator.trigger()`，wire-up 逻辑只在 coordinator 里维护一次。
///
/// 不负责：
/// - scanner 自身的状态/缓存/失败处理（仍由具体 scanner 负责）
/// - ProviderStatus 字段的写入（由 apply 闭包负责，AppState 传闭包进来）
/// - 哪些 usage 类型、哪些 provider 字段 —— 这些都是 AppState 的领域知识
///
/// 为什么不直接做 LocalUsageScanner 协议的方法：
/// - @Published 的 $lastResult / $isScanning 是 projected value，协议里没法直接暴露
/// - 所以让具体 scanner 用计算属性 lastResultPublisher / isScanningPublisher 把
///   $xxx.eraseToAnyPublisher() 暴露出来（见四类 scanner 的扩展）
@MainActor
final class LocalUsageCoordinator<Usage: Equatable> {
    typealias Apply = (Usage?) -> Void
    typealias SetScanning = (Bool) -> Void
    typealias FreshnessChange = () -> Void

    private let providerID: String
    private let logTag: String
    private let makeScanner: () -> any LocalUsageScanner<Usage>
    private let apply: Apply
    private let setScanning: SetScanning?

    private var scanner: (any LocalUsageScanner<Usage>)?
    private var cancellables = Set<AnyCancellable>()
    private var isActive = true

    /// - Parameters:
    ///   - providerID: 用于日志 prefix（"antigravity" / "minimax"）
    ///   - logTag: 同上，单独传避免耦合 providerID
    ///   - makeScanner: 构造 scanner 的闭包，只在首次 trigger 调用时执行
    ///   - apply: scanner 拿到新结果时调用（接收方：通常写到 ProviderStatus 对应字段 + broadcast）
    ///   - setScanning: scanner 切换 isScanning 时调用（接收方：通常更新 isScanningLocalUsage 字段）。
    ///     可选 —— 不传时不订阅 isScanningPublisher，scanner 内部的状态对外不可见，
    ///     适用于"扫描状态只在 scanner 内部消费"或"暂时无 UI 消费者"的场景。
    init(
        providerID: String,
        logTag: String,
        makeScanner: @escaping () -> any LocalUsageScanner<Usage>,
        apply: @escaping Apply,
        setScanning: SetScanning? = nil,
        onDirty: FreshnessChange? = nil,
        onFresh: FreshnessChange? = nil,
        onFailed: FreshnessChange? = nil
    ) {
        self.providerID = providerID
        self.logTag = logTag
        self.makeScanner = makeScanner
        self.apply = apply
        self.setScanning = setScanning
        self.onDirty = onDirty
        self.onFresh = onFresh
        self.onFailed = onFailed
    }

    private let onDirty: FreshnessChange?
    private let onFresh: FreshnessChange?
    private let onFailed: FreshnessChange?

    /// 触发一次显式 dirty 扫描。首次调用时 lazy 构造 scanner 并 wire 状态与
    /// freshness hooks；之后复用。
    func trigger() {
        trigger(mode: .dirty)
    }

    /// 触发指定模式的扫描。scanner 仍由自身负责 in-flight dedup。
    ///
    /// `markDirty` 只用于显式失效（例如 FSEvents 或手动刷新）。Provider
    /// batch 驱动的普通 reconcile 必须传 false，让 scanner 内部继续通过
    /// mtime/size fingerprint 判断是否真的需要增量计算。
    func trigger(mode: LocalUsageScanMode, markDirty: Bool = true) {
        guard isActive else { return }
        if let s = scanner {
            if markDirty { s.markDirty() }
            s.scan(mode: mode)
            return
        }
        let s = makeScanner()
        scanner = s
        if let base = s as? LocalUsageScannerBase<Usage> {
            base.onDirty = { [weak self] in self?.onDirty?() }
            base.onFresh = { [weak self] in self?.onFresh?() }
            base.onFailed = { [weak self] in self?.onFailed?() }
        }
        wireSinks(s)
        logInfo("[\(logTag)] LocalUsageCoordinator: scanner wired up (providerID=\(providerID))")
        if markDirty { s.markDirty() }
        s.scan(mode: mode)
    }

    func waitUntilSettled() async throws {
        guard let scanner else { return }
        try await scanner.waitUntilSettled()
    }

    /// coordinator 尚未 lazy 构造时视作 dirty，以确保首次 reconcile 必定建并扫描。
    var isDirty: Bool {
        scanner?.isDirty ?? true
    }

    var lastFreshAt: Date? {
        scanner?.lastFreshAt
    }

    func markDirty() {
        scanner?.markDirty()
    }

    func markFresh(at date: Date = Date()) {
        scanner?.markFresh(at: date)
    }

    /// 取消当前 in-flight scan（如果有）。配置变更 / AppState.stop() 调用,
    /// 防止旧 generation 写回新状态。
    func cancelInFlight() {
        scanner?.cancelInFlight()
        (scanner as? LocalUsageScannerBase<Usage>)?.stopWatching()
    }

    /// Source activity follows the explicit AppState consumer resolver. An inactive
    /// source releases its vnode/FSEvents registration but keeps scanner/cache state;
    /// reactivation only reattaches the watcher and the next batch decides whether
    /// the fingerprint requires work.
    func setActive(_ active: Bool) {
        guard isActive != active else {
            if active { (scanner as? LocalUsageScannerBase<Usage>)?.restartWatching() }
            return
        }
        isActive = active
        guard let base = scanner as? LocalUsageScannerBase<Usage> else { return }
        if active {
            base.restartWatching()
        } else {
            base.cancelInFlight()
            base.stopWatching()
        }
    }

    var active: Bool { isActive }

    /// 已构造的 scanner 上执行副作用（如推送运行时开关）；未构造时 no-op。
    /// 构造期的初值应由 makeScanner 闭包自己应用，不依赖本方法。
    func withLoadedScanner(_ body: (any LocalUsageScanner<Usage>) -> Void) {
        guard let scanner else { return }
        body(scanner)
    }

    private func wireSinks(_ s: any LocalUsageScanner<Usage>) {
        s.lastResultPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self else { return }
                // 用 debug 级别 + 简单摘要：完整 usage 对象含 7 天 daily token 数组，
                // info 级别每分钟会刷出大段日志，污染 release 日志。详情走 release 的
                // logDebug，development 想看完整内容再开。
                logDebug("[\(self.logTag)/apply] sink fired: result=\(result == nil ? "nil" : "updated")")
                self.apply(result)
            }
            .store(in: &cancellables)

        if let setScanning {
            s.isScanningPublisher
                .receive(on: DispatchQueue.main)
                .sink { isScanning in
                    setScanning(isScanning)
                }
                .store(in: &cancellables)
        }
    }
}

/// 本地用量 scanner 协议：把 `@Published lastResult` + `@Published isScanning`
/// 暴露成 `AnyPublisher`，方便 LocalUsageCoordinator 跨具体类型工作。
///
/// 适用：Antigravity、Minimax、GLM ZCode、OpenCode、DSH scanner（都是 @MainActor）
/// 不适用：QuotaFetcher（外部接口，不是本地 scanner）
///
/// 标 `@MainActor` 是因为：所有具体 scanner 都是 `@MainActor`（它们是
/// ObservableObject + @Published 字段 + 持有 SQLite reader / FileManager 状态），
/// LocalUsageCoordinator 也是 `@MainActor`，协议跟着标一致最省事，避免
/// "conformance crosses into main actor" warning。
///
/// `Usage` 标 primary associated type（`protocol LocalUsageScanner<Usage>`），
/// 才能在 existential 里用 `any LocalUsageScanner<Usage>` 语法（Swift 5.7+）。
@MainActor
protocol LocalUsageScanner<Usage>: AnyObject {
    associatedtype Usage: Equatable
    var lastResultPublisher: AnyPublisher<Usage?, Never> { get }
    var isScanningPublisher: AnyPublisher<Bool, Never> { get }
    func scan()
    func scan(mode: LocalUsageScanMode)
    var isDirty: Bool { get }
    var lastFreshAt: Date? { get }
    func markDirty()
    func markFresh(at date: Date)
    func waitUntilSettled() async throws
    /// 取消当前 in-flight scan（如果有）。配置变更 / stop 时调用,
    /// 防止旧扫描结果写回新状态。
    func cancelInFlight()
}
