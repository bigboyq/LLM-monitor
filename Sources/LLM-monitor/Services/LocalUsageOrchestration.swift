import Foundation

/// 本地用量扫描编排 —— 从 AppState 拆出的第 5 组 coordinator：
/// 5 个本地 scanner（antigravity / minimax / glm-zcode / opencode / dsh）的
/// lazy 构造、触发、取消、启动时机策略与 GLM 独立定期任务。
///
/// 状态写入（ProviderStatus 字段）通过 `LocalUsageStatusWriting` 协议回调
/// AppState，保持单向依赖：orchestration → writer(AppState)。
@MainActor
final class LocalUsageOrchestration {
    /// 本地扫描的种类标识（post-refresh 触发表用）。
    enum ScanKind: String, CaseIterable, Sendable {
        case antigravity
        case minimax
        case glm
        case opencode
        case dsh
    }

    /// provider 主 quota 刷新成功后需要顺带触发的本地扫描 + auth 标记。
    /// 新增 provider 时在表里追加一行即可，不再往刷新 handler 里堆 if 分支。
    static let postRefreshTriggers: [ProviderKind: [ScanKind]] = [
        .antigravity: [.antigravity],
        .minimaxTokenPlan: [.minimax, .opencode, .dsh],
        .glmCodingPlan: [.glm, .opencode, .dsh],
        .deepseek: [.dsh]
    ]

    /// 本地用量 scanner 的启动策略：Minimax / GLM 的数据库可直接读取，
    /// 进 app 立即触发；Antigravity 需要等本地 IDE 服务和主 quota 首次成功。
    nonisolated static func scanStartsImmediately(for kind: ProviderKind) -> Bool {
        kind == .minimaxTokenPlan || kind == .glmCodingPlan
    }

    private let writer: any LocalUsageStatusWriting

    /// Antigravity 本地 token 用量 scanner：通过 `LocalUsageCoordinator` 包装
    /// singleton + Combine wire-up 逻辑，避免在编排层重复 30+ 行。
    private lazy var antigravityCoordinator = LocalUsageCoordinator<AntigravityLocalUsage>(
        providerID: writer.providerID(for: .antigravity) ?? "",
        logTag: "antigravity",
        makeScanner: { AntigravityLocalUsageScanner(fetcher: AntigravityFetcher()) },
        apply: { [weak writer] usage in writer?.applyAntigravityLocalUsage(usage) },
        setScanning: { [weak writer] isScanning in
            writer?.setScanningState(isScanning, for: writer?.providerID(for: .antigravity) ?? "")
        }
    )

    /// Minimax 本地 token 用量 scanner：只读取 v2 `runtime-state.sqlite`。
    private lazy var minimaxCoordinator = LocalUsageCoordinator<ProviderLocalUsage>(
        providerID: writer.providerID(for: .minimaxTokenPlan) ?? "",
        logTag: "minimax",
        makeScanner: { MinimaxLocalUsageScanner() },
        apply: { [weak writer] usage in writer?.applyMinimaxLocalUsage(usage) },
        setScanning: { [weak writer] isScanning in
            writer?.setScanningState(isScanning, for: writer?.providerID(for: .minimaxTokenPlan) ?? "")
        }
    )

    /// GLM 本地 token 用量 scanner：读 ZCode 的 ~/.zcode/cli/db/db.sqlite。
    private lazy var glmCoordinator = LocalUsageCoordinator<GlmLocalUsage>(
        providerID: writer.providerID(for: .glmCodingPlan) ?? "",
        logTag: "glm-local",
        makeScanner: { GlmZcodeLocalUsageScanner() },
        apply: { [weak writer] usage in writer?.applyGlmLocalUsage(usage) },
        setScanning: { [weak writer] isScanning in
            writer?.setScanningState(isScanning, for: writer?.providerID(for: .glmCodingPlan) ?? "")
        }
    )

    /// opencode 本地用量 scanner（共享后台数据源，由各卡的合并开关决定是否消费）。
    /// opencode 自身不是 menu bar provider，不挂独立 scanning 状态。
    private lazy var opencodeCoordinator = LocalUsageCoordinator<OpencodeLocalUsage>(
        providerID: "opencode",
        logTag: "opencode",
        makeScanner: { OpencodeUsageScanner() },
        apply: { [weak writer] usage in writer?.applyOpencodeUsage(usage) },
        setScanning: { _ in /* opencode 不暴露 scanning 状态 */ }
    )

    /// dsh 本地 session token 用量 scanner。dsh 不是菜单栏 provider；结果通过
    /// `usageProjection` 自动并入对应卡片。没有 UI 消费者，不传 `setScanning`。
    private lazy var dshCoordinator = LocalUsageCoordinator<DshLocalUsage>(
        providerID: "dsh",
        logTag: "dsh",
        makeScanner: { DshLocalUsageScanner() },
        apply: { [weak writer] usage in writer?.applyDshUsage(usage) }
    )

    /// GLM（ZCode）本地 scanner 的独立定期触发 task。
    ///
    /// scanner 只读本地 `.db`，不依赖远端 quota，但它跟 quota 绑定触发有一个
    /// 盲区：quota 持续失败时（Key 过期 / 网络问题）scanner 永远不跑，用户在
    /// ZCode 里产生的新 token 消耗进不来，柱图卡在旧数据。
    ///
    /// 这个 task 用 GLM provider 的 `refreshIntervalSeconds`（与 quota 同节奏）
    /// 独立定期触发 scan，不依赖 quota 是否成功。scanner 内部的 db+WAL 指纹
    /// 检查保证指纹没变时只做一次 `stat()`（微秒级），零额外负担。
    private var glmPeriodicTask: Task<Void, Never>?

    init(writer: any LocalUsageStatusWriting) {
        self.writer = writer
    }

    // MARK: - 触发

    func trigger(_ kind: ScanKind) {
        switch kind {
        case .antigravity: antigravityCoordinator.trigger()
        case .minimax: minimaxCoordinator.trigger()
        case .glm: glmCoordinator.trigger()
        case .opencode: opencodeCoordinator.trigger()
        case .dsh: dshCoordinator.trigger()
        }
    }

    /// provider 主 quota 刷新成功后的后置触发（配置表驱动）。
    /// codex 的 auth 标记与 antigravity 的 probe 标记留在 AppState（属于 auth 域）。
    func handleRefreshSuccess(kind: ProviderKind) {
        guard let triggers = Self.postRefreshTriggers[kind] else { return }
        for scanKind in triggers {
            trigger(scanKind)
        }
    }

    func cancelInFlightAll() {
        antigravityCoordinator.cancelInFlight()
        minimaxCoordinator.cancelInFlight()
        glmCoordinator.cancelInFlight()
        opencodeCoordinator.cancelInFlight()
        dshCoordinator.cancelInFlight()
        glmPeriodicTask?.cancel()
        glmPeriodicTask = nil
    }

    // MARK: - 生命周期

    /// 启动时立即触发可直读数据库的 scanner（首屏就有本地历史）；
    /// opencode / dsh 是共享数据源，不依赖某个 quota provider 是否启用。
    func startInitialScans(descriptors: [FetcherDescriptor]) {
        for descriptor in descriptors where Self.scanStartsImmediately(for: descriptor.kind) {
            switch descriptor.kind {
            case .minimaxTokenPlan: trigger(.minimax)
            case .glmCodingPlan: trigger(.glm)
            default: break
            }
        }
        trigger(.opencode)
        trigger(.dsh)
    }

    /// GLM 本地 scanner 的独立定期触发。只在 GLM provider 配置且启用时启动；
    /// 配置变更后 `cancelInFlightAll()` + 重调本方法会重建 task。
    func startGlmPeriodicTrigger(
        descriptors: [FetcherDescriptor],
        isProviderEnabled: (String) -> Bool,
        interval: TimeInterval
    ) {
        glmPeriodicTask?.cancel()
        let glmID = descriptors.first(where: { $0.kind == .glmCodingPlan })?.id
            ?? ProviderKind.glmCodingPlan.providerID
        // 仅在 GLM provider 存在且启用时定期触发（未启用没必要空跑）
        let isConfigured = descriptors.contains { $0.kind == .glmCodingPlan }
            && isProviderEnabled(glmID)
        guard isConfigured else { return }

        glmPeriodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    // 取消（配置变更 / stop）正常退出
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.trigger(.glm)
            }
        }
        logInfo("[glm-local] 独立定期触发已启动，间隔=\(Int(interval))s（不依赖 quota 成功）")
    }
}

/// 本地用量扫描结果的写入协议（AppState 实现）：orchestration 只负责扫描与
/// 触发时机，状态落盘（ProviderStatus 字段 + 广播）留给状态容器。
@MainActor
protocol LocalUsageStatusWriting: AnyObject {
    func providerID(for kind: ProviderKind) -> String?
    func setScanningState(_ isScanning: Bool, for providerID: String)
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?)
    func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?)
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?)
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?)
    func applyDshUsage(_ usage: DshLocalUsage?)
}
