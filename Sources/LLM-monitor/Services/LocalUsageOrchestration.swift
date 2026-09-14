import Foundation

/// 本地用量 reconcile 与扫描编排：
/// provider batch settled 或显式操作驱动一次性扫描 Task；不持有常驻 Timer/beat
/// loop。首次 reconcile 与日切使用 full，其余 reconcile 只消费 dirty sources。
/// 彻底剥离 quota 依赖：quota 刷新成功不再直接 await 本地扫描。
///
/// 状态写入（ProviderStatus 字段）通过 `LocalUsageStatusWriting` 协议回调
/// AppState，保持单向依赖：orchestration → writer(AppState)。
@MainActor
final class LocalUsageOrchestration {
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
        },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .antigravity)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .antigravity)
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
        },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .minimaxCode)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .minimaxCode)
        }
    )

    /// GLM 本地 token 用量 scanner：读 ZCode 的 ~/.zcode/cli/db/db.sqlite。
    /// `makeScanner` 捕获 `glmBalanceLogParsingEnabled` 作为构造期初值；运行中的
    /// 更新走 `updateGlmBalanceLogParsing` 推送到已加载的实例。
    private lazy var glmCoordinator = LocalUsageCoordinator<GlmLocalUsage>(
        providerID: writer.providerID(for: .glmCodingPlan) ?? "",
        logTag: "glm-local",
        makeScanner: { [weak self] in
            let scanner = GlmZcodeLocalUsageScanner()
            scanner.setBalanceLogParsingEnabled(self?.glmBalanceLogParsingEnabled ?? false)
            return scanner
        },
        apply: { [weak writer] usage in writer?.applyGlmLocalUsage(usage) },
        setScanning: { [weak writer] isScanning in
            writer?.setScanningState(isScanning, for: writer?.providerID(for: .glmCodingPlan) ?? "")
        },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .zcode)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .zcode)
        }
    )

    /// GLM 活动套餐余额日志解析开关（设置 `parseZcodeBalanceLog`）。存编排层的
    /// 原因：scanner 是 lazy 构造的，构造期也要拿到正确初值，不能只推已加载实例。
    private var glmBalanceLogParsingEnabled = false

    /// opencode 本地用量 scanner（共享后台数据源，由各卡的合并开关决定是否消费）。
    /// opencode 自身不是 menu bar provider，不挂独立 scanning 状态。
    private lazy var opencodeCoordinator = LocalUsageCoordinator<OpencodeLocalUsage>(
        providerID: "opencode",
        logTag: "opencode",
        makeScanner: { OpencodeUsageScanner() },
        apply: { [weak writer] usage in writer?.applyOpencodeUsage(usage) },
        setScanning: { _ in /* opencode 不暴露 scanning 状态 */ },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .opencode)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .opencode)
        }
    )

    /// dsh 本地 session token 用量 scanner。dsh 不是菜单栏 provider；结果通过
    /// `usageProjection` 自动并入对应卡片。没有 UI 消费者，不传 `setScanning`。
    private lazy var dshCoordinator = LocalUsageCoordinator<DshLocalUsage>(
        providerID: "dsh",
        logTag: "dsh",
        makeScanner: { DshLocalUsageScanner() },
        apply: { [weak writer] usage in writer?.applyDshUsage(usage) },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .dsh)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .dsh)
        }
    )

    // MARK: - Reconcile state

    /// LocalUsage 不再拥有常驻 beat/timer。一次 reconcile 由 provider batch settled
    /// 事件或显式手动刷新投递，完成后 Task 即释放。
    private var reconcileTask: Task<Void, Never>?
    private var pendingFullReconcile = false
    private var didCompleteInitialFullScan = false
    private var lastFullScanDay: Date?
    private var codexDirty = true
    private var codexEventGeneration: UInt64 = 0
    private var codexFileSystemWatcher: LocalFSEventsWatcher?
    private var codexWatchedHome: URL?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// 客户端就绪状态缓存，用于日志去噪（仅在状态变动时记录日志）
    private var clientReadinessCache: [String: Bool] = [:]
    /// 仅供测试注入客户端就绪判定覆写
    var testReadinessOverride: ((String) -> Bool)?

    init(
        writer: any LocalUsageStatusWriting,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.calendar = calendar
        self.now = now
    }

    func cancelInFlightAll() {
        antigravityCoordinator.cancelInFlight()
        minimaxCoordinator.cancelInFlight()
        glmCoordinator.cancelInFlight()
        opencodeCoordinator.cancelInFlight()
        dshCoordinator.cancelInFlight()
        reconcileTask?.cancel()
        reconcileTask = nil
        stopCodexWatcher()
    }

    /// 推送「活动套餐余额日志解析」开关（设置 `parseZcodeBalanceLog`）。
    /// 同时覆盖构造期初值与已加载实例；开关变化只标记 GLM source dirty，
    /// 由下一次 Provider batch settle 后的 reconcile 统一处理。
    func updateGlmBalanceLogParsing(enabled: Bool) {
        let changed = glmBalanceLogParsingEnabled != enabled
        glmBalanceLogParsingEnabled = enabled
        glmCoordinator.withLoadedScanner { ($0 as? GlmZcodeLocalUsageScanner)?.setBalanceLogParsingEnabled(enabled) }
        if changed {
            glmCoordinator.markDirty()
        }
    }

    // MARK: - Reconcile lifecycle

    /// 当前应执行的下一种 reconcile。首次扫描与本地日切为 full，其余时候只
    /// 处理 scanner 自己标记为 dirty 的 source。
    var nextReconcileMode: LocalUsageScanMode {
        let today = calendar.startOfDay(for: now())
        guard didCompleteInitialFullScan, lastFullScanDay == today else { return .full }
        return .dirty
    }

    /// provider batch settled 后调用的非阻塞入口。它只投递一个短生命周期 Task，
    /// 不会把本地扫描 await 到 ProviderRefreshScheduler 的主循环。
    func scheduleReconcile() {
        guard reconcileTask == nil else { return }
        let mode = nextReconcileMode
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconcile(mode: mode)
            if !Task.isCancelled {
                self.reconcileTask = nil
            }
        }
    }

    /// ProviderRefreshScheduler 的 batch-settled 接线点。回调只需调用本方法，
    /// 本地扫描会在独立 Task 中运行。
    func reconcileAfterProviderBatch() {
        scheduleReconcile()
    }

    /// 执行一次 reconcile 并等待完成。`mode` 仅供手动/集成调用覆盖状态机选择；
    /// 不传时使用首次 full、日切 full、否则 dirty 的状态机结果。
    func reconcile(mode requestedMode: LocalUsageScanMode? = nil) async {
        if let active = reconcileTask {
            if requestedMode == .full { pendingFullReconcile = true }
            await active.value
            if requestedMode == .full, pendingFullReconcile {
                pendingFullReconcile = false
                await reconcile(mode: .full)
            }
            return
        }

        let mode = requestedMode ?? nextReconcileMode
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconcile(mode: mode)
        }
        reconcileTask = task
        await task.value
        reconcileTask = nil

        if pendingFullReconcile {
            pendingFullReconcile = false
            await reconcile(mode: .full)
        }
    }

    /// 手动 refreshAll 或系统唤醒时强制一次 full reconcile，并等待所有本地
    /// scanner settle；不要求存在 resident loop。
    func triggerImmediateScanAll() async {
        await reconcile(mode: .full)
    }

    /// 执行一个本地 pass。full 会检查所有已就绪 source；dirty 只触发 dirty
    /// source，且仍保留 ready→missing 的一次清空过渡扫描。
    func scanAllClients(mode: LocalUsageScanMode = .full) async {
        await scanClient("minimax_code", mode: mode) { [self] in
            minimaxCoordinator
        }
        guard !Task.isCancelled else { return }
        await scanClient("zcode-glm", mode: mode) { [self] in
            glmCoordinator
        }
        guard !Task.isCancelled else { return }
        await scanClient("opencode", mode: mode) { [self] in
            opencodeCoordinator
        }
        guard !Task.isCancelled else { return }
        await scanClient("dsh", mode: mode) { [self] in
            dshCoordinator
        }
        guard !Task.isCancelled else { return }
        await scanClient("antigravity", mode: mode) { [self] in
            antigravityCoordinator
        }

        let codexReady = checkClientReadiness("codex")
        let codexWasReady = clientReadinessCache["codex"] == true
        updateReadinessAndLog(for: "codex", isReady: codexReady)
        let codexTransitionedToMissing = codexWasReady && !codexReady
        if codexTransitionedToMissing { codexDirty = true }
        let shouldScanCodex = mode == .full || codexDirty || codexTransitionedToMissing
        if (codexReady || codexWasReady) && shouldScanCodex {
            _ = await scanCodexUsageDetails()
        }
    }

    /// 记录 readiness 并按需触发 scanner；返回值通过 coordinator 的生命周期
    /// interface 决定，而不是依赖具体 scanner 类型。
    private func scanClient<Usage: Equatable>(
        _ clientID: String,
        mode: LocalUsageScanMode,
        coordinator: () -> LocalUsageCoordinator<Usage>
    ) async {
        let isReady = checkClientReadiness(clientID)
        let wasReady = clientReadinessCache[clientID] == true
        updateReadinessAndLog(for: clientID, isReady: isReady)
        guard isReady || wasReady else { return }
        let becameMissing = wasReady && !isReady
        let current = coordinator()
        if becameMissing { current.markDirty() }
        guard mode == .full || current.isDirty || becameMissing else { return }
        let effectiveMode: LocalUsageScanMode =
            mode == .full || current.requiresFullScan ? .full : .dirty
        current.trigger(mode: effectiveMode)
        try? await current.waitUntilSettled()
    }

    private func performReconcile(mode: LocalUsageScanMode) async {
        await scanAllClients(mode: mode)
        guard !Task.isCancelled else { return }
        guard mode == .full else { return }
        didCompleteInitialFullScan = true
        lastFullScanDay = calendar.startOfDay(for: now())
    }

    private func scanCodexUsageDetails() async -> Bool {
        // 纯本地信息：quota 模型缺失（首胜前）也照常扫描，仅窗口用量缺省。
        // model 从共享数据层（statuses.lastSuccess）读取，是数据依赖而非事件依赖。
        guard let target = writer.codexEnrichmentTarget() else { return false }

        // Codex local parsing can touch session metadata while it reads. Keep
        // the source watcher stopped for the same scan window as other clients.
        stopCodexWatcher()
        let startedEventGeneration = codexEventGeneration

        writer.setScanningState(true, for: target.providerID)
        defer {
            writer.setScanningState(false, for: target.providerID)
            startCodexWatcher(authPath: target.authPath)
        }

        let details = await CodexFetcher.loadUsageDetailsAsync(
            authPath: target.authPath,
            model: target.model
        )
        guard !Task.isCancelled else { return false }
        writer.applyCodexUsageDetails(
            details,
            providerID: target.providerID,
            fetchedAt: target.fetchedAt,
            configurationGeneration: target.generation
        )
        if codexEventGeneration == startedEventGeneration {
            codexDirty = false
            writer.setLocalUsageFreshness(.clean, for: .codex)
        }
        return true
    }

    /// Codex local usage is implemented by `CodexFetcher` rather than the
    /// generic scanner base, so its source-owned watcher lives beside that
    /// enrichment coordinator. It still follows the same rule: FSEvents only
    /// invalidates the snapshot; the next Provider batch performs the scan.
    private func startCodexWatcher(authPath: String?) {
        let home = CodexFetcher.codexHomeDirectory(authPath: authPath)
        if codexWatchedHome == home, codexFileSystemWatcher?.isRunning == true { return }

        codexFileSystemWatcher?.stop()
        codexWatchedHome = home
        codexFileSystemWatcher = LocalFSEventsWatcher(
            paths: [
                home.appendingPathComponent("sessions", isDirectory: true),
                home.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        ) { [weak self] _ in
            guard let self else { return }
            self.codexEventGeneration &+= 1
            self.codexDirty = true
            self.writer.setLocalUsageFreshness(.dirty, for: .codex)
        }
        codexFileSystemWatcher?.start()
    }

    private func stopCodexWatcher() {
        codexFileSystemWatcher?.stop()
        codexFileSystemWatcher = nil
        codexWatchedHome = nil
    }

    func checkClientReadiness(_ clientID: String) -> Bool {
        if let override = testReadinessOverride {
            return override(clientID)
        }
        let fileManager = FileManager.default
        switch clientID {
        case "minimax_code":
            return fileManager.fileExists(atPath: MinimaxLocalUsageScanner.defaultRuntimeDBURL.path)
        case "zcode-glm":
            return fileManager.fileExists(atPath: GlmZcodeLocalUsageScanner.defaultDBURL.path)
        case "opencode":
            return fileManager.fileExists(atPath: OpencodeUsageScanner.defaultDBURL.path)
        case "dsh":
            return fileManager.fileExists(atPath: DshLocalUsageScanner.defaultSessionsRoot.path)
        case "antigravity":
            return AntigravityFetcher().hasLocalAuth()
        case "codex":
            // 与 CodexFetcher 相同的解析链（config authPath → CODEX_HOME → ~/.codex），
            // 自定义 CODEX_HOME 的用户也能被正确判定。
            return fileManager.fileExists(
                atPath: CodexFetcher.codexHomeDirectory(authPath: writer.codexConfiguredAuthPath()).path
            )
        default:
            return false
        }
    }

    private func updateReadinessAndLog(for clientID: String, isReady: Bool) {
        let previous = clientReadinessCache[clientID]
        if previous != isReady {
            clientReadinessCache[clientID] = isReady
            if !isReady {
                logInfo("[usage-loop] 客户端 [\(clientID)] 数据源缺失，跳过常规扫描（刚消失的过渡拍会补扫一次清旧数据）")
            } else if previous != nil {
                logInfo("[usage-loop] 客户端 [\(clientID)] 数据源已就绪")
            }
        }
    }

}

/// 本地用量扫描结果的写入协议（AppState 实现）：orchestration 只负责扫描与
/// 触发时机，状态落盘（ProviderStatus 字段 + 广播）留给状态容器。
@MainActor
protocol LocalUsageStatusWriting: AnyObject {
    func providerID(for kind: ProviderKind) -> String?
    func setScanningState(_ isScanning: Bool, for providerID: String)
    func setLocalUsageFreshness(_ freshness: LocalUsageFreshness, for source: LocalUsageSource)
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?)
    func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?)
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?)
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?)
    func applyDshUsage(_ usage: DshLocalUsage?)
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)?
    /// codex 在 config.json 中配置的 authPath（未配置 provider 时返回 nil，不要求
    /// enabled / lastSuccess）—— 供 readiness 沿 CodexFetcher 的解析链定位 codex home。
    func codexConfiguredAuthPath() -> String?
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int)
}

extension LocalUsageStatusWriting {
    /// Compatibility default for diagnostic/test writers that do not render
    /// provider cards. AppState overrides this to project source freshness.
    func setLocalUsageFreshness(_ freshness: LocalUsageFreshness, for source: LocalUsageSource) {}
}
