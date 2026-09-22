import Foundation

/// 本地用量 reconcile 与扫描编排：
/// provider batch settled 或显式操作驱动一次性扫描 Task；不持有常驻 Timer/beat
/// loop。仅应用启动后的首个 reconcile 使用 full（缓存优先校验），其余 reconcile
/// 由 scanner 内部 fingerprint 决定是否复用缓存或执行增量计算，日切也复用 offset。
/// 彻底剥离 quota 依赖：quota 刷新成功不再直接 await 本地扫描。
///
/// 状态写入（ProviderStatus 字段）通过 `LocalUsageStatusWriting` 协议回调
/// AppState，保持单向依赖：orchestration → writer(AppState)。
@MainActor
final class LocalUsageOrchestration {
    struct ActiveSources: Equatable, Sendable {
        var codex = true
        var antigravity = true
        var minimax = true
        var glm = true
        var dsh = true
        var opencode = true
    }

    /// Derive source ownership from the effective provider statuses.  This is
    /// intentionally pure so config-default semantics (`isEnabled == true`
    /// when a provider has no explicit config) cannot drift between AppState
    /// and tests.
    nonisolated static func activeSources(for statuses: [ProviderStatus]) -> ActiveSources {
        let enabledKinds = Set(statuses.filter(\.isEnabled).map(\.kind))
        let hasOpenCodeConsumer = statuses.contains {
            $0.isEnabled && $0.mergeOpencodeUsage
        }
        return ActiveSources(
            codex: enabledKinds.contains(.codexChatGpt),
            antigravity: enabledKinds.contains(.antigravity),
            minimax: enabledKinds.contains(.minimaxTokenPlan),
            glm: enabledKinds.contains(.glmCodingPlan),
            dsh: enabledKinds.contains(.minimaxTokenPlan)
                || enabledKinds.contains(.glmCodingPlan)
                || enabledKinds.contains(.deepseek),
            opencode: hasOpenCodeConsumer
        )
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
        },
        onDirty: { [weak writer] in
            writer?.setLocalUsageFreshness(.dirty, for: .antigravity)
        },
        onFresh: { [weak writer] in
            writer?.setLocalUsageFreshness(.clean, for: .antigravity)
        },
        onFailed: { [weak writer] in
            writer?.setLocalUsageFreshness(.failed, for: .antigravity)
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
        },
        onFailed: { [weak writer] in
            writer?.setLocalUsageFreshness(.failed, for: .minimaxCode)
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
        },
        onFailed: { [weak writer] in
            writer?.setLocalUsageFreshness(.failed, for: .zcode)
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
        },
        onFailed: { [weak writer] in
            writer?.setLocalUsageFreshness(.failed, for: .opencode)
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
        },
        onFailed: { [weak writer] in
            writer?.setLocalUsageFreshness(.failed, for: .dsh)
        }
    )

    // MARK: - Reconcile state

    /// LocalUsage 不再拥有常驻 beat/timer。一次 reconcile 由 provider batch settled
    /// 事件或显式手动刷新投递，完成后 Task 即释放。
    private var reconcileTask: Task<Void, Never>?
    /// Provider batch 到达时已有 reconcile 在运行，合并为完成后的下一次普通 reconcile。
    private var pendingReconcile = false
    /// 显式 full 请求撞上已有 reconcile，不能被普通 reconcile 降级，必须补跑一次 full。
    private var pendingFullReconcile = false
    /// 防止已取消的旧 Task 在稍后结束时清理或覆盖新一轮 reconcile。
    private var reconcileGeneration: UInt64 = 0
    private var didCompleteInitialFullScan = false
    /// A calendar/time-zone change invalidates persisted day buckets once. This
    /// avoids restoring a snapshot grouped under the old local-day boundary
    /// while keeping normal midnight transitions on the dirty/rebase path.
    private var fullReconcileRequired = false
    private var codexSourceLifecycle: LocalUsageSourceLifecycle?
    private var codexWatchedHome: URL?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// 客户端就绪状态缓存，用于日志去噪（仅在状态变动时记录日志）
    private var clientReadinessCache: [String: Bool] = [:]
    private var activeSources = ActiveSources()
    /// 仅供测试注入客户端就绪判定覆写
    var testReadinessOverride: ((String) -> Bool)?
    /// 测试用 reconcile pass 注入点；生产路径仍使用 `scanAllClients(mode:)`。
    var testReconcilePass: (@MainActor (LocalUsageScanMode) async -> Void)?

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
        reconcileGeneration &+= 1
        antigravityCoordinator.cancelInFlight()
        minimaxCoordinator.cancelInFlight()
        glmCoordinator.cancelInFlight()
        opencodeCoordinator.cancelInFlight()
        dshCoordinator.cancelInFlight()
        reconcileTask?.cancel()
        reconcileTask = nil
        pendingReconcile = false
        pendingFullReconcile = false
        stopCodexWatcher()
        codexSourceLifecycle = nil
        codexWatchedHome = nil
    }

    /// Resolve source lifetime from enabled consumers. Shared DSH/OpenCode remain
    /// active only while their explicit consumer set is non-empty; scanner/cache
    /// values themselves are retained when a source is disabled.
    func updateActiveSources(_ active: ActiveSources) {
        activeSources = active
        antigravityCoordinator.setActive(active.antigravity)
        minimaxCoordinator.setActive(active.minimax)
        glmCoordinator.setActive(active.glm)
        dshCoordinator.setActive(active.dsh)
        opencodeCoordinator.setActive(active.opencode)
        if !active.codex {
            stopCodexWatcher()
        } else if codexSourceLifecycle != nil {
            codexSourceLifecycle?.start()
        }
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

    /// 当前应执行的下一种 reconcile。只有本进程启动后的首个 pass 使用 full；
    /// 手工、唤醒、自动 interval/reset 和日切都走 dirty，由各 scanner 的
    /// mtime/size fingerprint 决定是否需要 RPC 以及是否使用 offset。
    var nextReconcileMode: LocalUsageScanMode {
        didCompleteInitialFullScan && !fullReconcileRequired ? .dirty : .full
    }

    /// 文件事件等后台来源调用的非阻塞入口。它只投递一个短生命周期 Task，
    /// 不会阻塞当前事件处理者。
    func scheduleReconcile() {
        guard reconcileTask == nil else {
            pendingReconcile = true
            logDebug("[local-usage] reconcile queued: previous reconcile is still active")
            return
        }
        let mode = nextReconcileMode
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        logInfo("[local-usage] reconcile scheduled mode=\(mode == .full ? "full" : "dirty")")
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconcile(mode: mode)
            guard self.reconcileGeneration == generation else { return }
            self.reconcileTask = nil
            guard !Task.isCancelled else { return }
            if self.pendingReconcile {
                self.pendingReconcile = false
                self.scheduleReconcile()
            }
        }
    }

    /// 执行一次 reconcile 并等待完成。`mode` 仅供启动或测试等需要明确 full
    /// 语义的调用覆盖状态机选择；不传时使用首拍 full、后续 dirty 的状态机结果。
    func reconcile(mode requestedMode: LocalUsageScanMode? = nil) async {
        if let active = reconcileTask {
            if requestedMode == .full {
                pendingFullReconcile = true
            } else {
                pendingReconcile = true
            }
            await active.value
            if requestedMode == .full, pendingFullReconcile {
                pendingFullReconcile = false
                await reconcile(mode: .full)
            } else if requestedMode == nil, pendingReconcile {
                pendingReconcile = false
                await reconcile()
            }
            return
        }

        let mode = requestedMode ?? nextReconcileMode
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconcile(mode: mode)
        }
        reconcileTask = task
        await task.value
        guard reconcileGeneration == generation else { return }
        reconcileTask = nil

        if pendingFullReconcile {
            pendingFullReconcile = false
            await reconcile(mode: .full)
        } else if pendingReconcile {
            pendingReconcile = false
            await reconcile()
        }
    }

    /// 手动 refreshAll、单 Provider 手工刷新或系统唤醒时执行一次普通 reconcile。
    /// 已完成启动首拍后，这会让 changed session 使用 offset；未完成首拍时仍由
    /// 状态机自动保留 full 兜底。
    func triggerImmediateScanAll() async {
        await reconcile()
    }

    /// 启动阶段专用的 full reconcile。启动 quota 错峰结束后只执行这一拍，
    /// 后续手工、唤醒、自动和日切均不得复用这个入口。
    func triggerStartupFullScanAll() async {
        await reconcile(mode: .full)
    }

    /// Rebuild only Antigravity's local token cache. This is deliberately not
    /// a global reconcile: the settings-page action is an explicit recovery
    /// tool for the RPC-backed source and should not rescan unrelated clients.
    func triggerAntigravityHardFull() async {
        guard activeSources.antigravity else { return }
        // A filesystem event or provider reconcile may already have started a
        // normal scan. Let it settle before issuing the hard request; the
        // coordinator deduplicates in-flight scans and would otherwise silently
        // turn this explicit action into a no-op.
        try? await antigravityCoordinator.waitUntilSettled()
        antigravityCoordinator.trigger(mode: .hardFull)
        try? await antigravityCoordinator.waitUntilSettled()
    }

    /// Force exactly one full local pass after the system calendar or time zone
    /// changes. The next ordinary reconcile consumes the flag.
    func invalidateForCalendarChange() {
        fullReconcileRequired = true
        scheduleReconcile()
    }

    /// 执行一个本地 pass。各 source 之间没有数据依赖，因此并行启动；每个
    /// scanner 自己仍通过 pipeline mutex 串行其内部扫描。
    func scanAllClients(mode: LocalUsageScanMode = .full) async {
        let minimax: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.scanClient(
                "minimax_code",
                mode: mode,
                isActive: { self.activeSources.minimax }
            ) { self.minimaxCoordinator }
        }
        let glm: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.scanClient(
                "zcode-glm",
                mode: mode,
                isActive: { self.activeSources.glm }
            ) { self.glmCoordinator }
        }
        let opencode: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.scanClient(
                "opencode",
                mode: mode,
                isActive: { self.activeSources.opencode }
            ) { self.opencodeCoordinator }
        }
        let dsh: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.scanClient(
                "dsh",
                mode: mode,
                isActive: { self.activeSources.dsh }
            ) { self.dshCoordinator }
        }
        let antigravity: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.scanClient(
                "antigravity",
                mode: mode,
                isActive: { self.activeSources.antigravity }
            ) { self.antigravityCoordinator }
        }
        let codex: @MainActor () async -> Void = { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.scanCodexClient(mode: mode)
        }

        // Keep the small SQLite snapshots concurrent, but never overlap the
        // three heavyweight parsers. DSH can ingest a very large compressed
        // history, Antigravity holds trajectory response Data, and Codex scans
        // a large JSONL corpus; running them in one batch recreates the peak
        // memory pressure this pass is designed to remove.
        let batches: [[@MainActor () async -> Void]] = [
            [minimax, glm, opencode],
            [dsh],
            [antigravity],
            [codex]
        ]
        for batch in batches {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask { await job() }
                }
            }
        }
    }

    private func scanCodexClient(mode: LocalUsageScanMode) async {
        guard activeSources.codex else { return }
        let codexReady = checkClientReadiness("codex")
        let codexWasReady = clientReadinessCache["codex"] == true
        updateReadinessAndLog(for: "codex", isReady: codexReady)
        if codexReady || codexWasReady {
            _ = await scanCodexUsageDetails(mode: mode)
        }
    }

    /// 记录 readiness 并按需触发 scanner；返回值通过 coordinator 的生命周期
    /// interface 决定，而不是依赖具体 scanner 类型。
    private func scanClient<Usage: Equatable>(
        _ clientID: String,
        mode: LocalUsageScanMode,
        isActive: () -> Bool,
        coordinator: () -> LocalUsageCoordinator<Usage>
    ) async {
        guard !Task.isCancelled else { return }
        // Check source ownership before evaluating the lazy coordinator.  Apart
        // from avoiding needless construction, this keeps an inactive source
        // from touching its production default path during a reconcile.
        guard isActive() else { return }
        let isReady = checkClientReadiness(clientID)
        let wasReady = clientReadinessCache[clientID] == true
        updateReadinessAndLog(for: clientID, isReady: isReady)
        guard isReady || wasReady else { return }
        let becameMissing = wasReady && !isReady
        let current = coordinator()
        guard current.active else { return }
        if becameMissing { current.markDirty() }
        // FSEvents 的 dirty 状态只负责 UI freshness。每次 Provider batch 都要
        // 给 scanner 一次机会执行原有的 fingerprint 检查，否则文件在保持打开
        // 时 mtime/size 已变化但尚未产生 FSEvents，原有增量逻辑会被跳过。
        guard !Task.isCancelled else { return }
        current.trigger(mode: mode, markDirty: false)
        try? await current.waitUntilSettled()
    }

    private func performReconcile(mode: LocalUsageScanMode) async {
        if let testReconcilePass {
            await testReconcilePass(mode)
        } else {
            await scanAllClients(mode: mode)
        }
        guard !Task.isCancelled else { return }
        guard mode == .full else { return }
        didCompleteInitialFullScan = true
        fullReconcileRequired = false
    }

    private func scanCodexUsageDetails(mode: LocalUsageScanMode) async -> Bool {
        // 纯本地信息：quota 模型缺失（首胜前）也照常扫描，仅窗口用量缺省。
        // model 从共享数据层（statuses.lastSuccess）读取，是数据依赖而非事件依赖。
        guard let target = writer.codexEnrichmentTarget() else { return false }

        // The Codex source watcher remains attached while parsing. Its
        // generation gate below preserves dirty state when a write lands during
        // this scan; the next provider cycle consumes it.
        startCodexWatcher(authPath: target.authPath)
        let startedEventGeneration = codexSourceLifecycle?.eventGeneration ?? 0

        writer.setScanningState(true, for: target.providerID)
        defer {
            writer.setScanningState(false, for: target.providerID)
        }

        let details = await CodexFetcher.loadUsageDetailsAsync(
            authPath: target.authPath,
            model: target.model,
            forceFull: mode == .full
        )
        guard !Task.isCancelled else { return false }
        guard let details else { return false }
        writer.applyCodexUsageDetails(
            details,
            providerID: target.providerID,
            fetchedAt: target.fetchedAt,
            configurationGeneration: target.generation
        )
        codexSourceLifecycle?.refreshHotFiles()
        if codexSourceLifecycle?.eventGeneration == startedEventGeneration {
            writer.setLocalUsageFreshness(.clean, for: .codex)
        }
        return true
    }

    /// Codex local usage is implemented by `CodexFetcher` rather than the
    /// generic usage scanner base, but uses the same source lifecycle as every
    /// filesystem-backed scanner.
    private func startCodexWatcher(authPath: String?) {
        let home = CodexFetcher.codexHomeDirectory(authPath: authPath)
        if codexWatchedHome == home, let lifecycle = codexSourceLifecycle {
            lifecycle.start()
            return
        }

        codexSourceLifecycle?.stop()
        codexWatchedHome = home
        codexSourceLifecycle = LocalUsageSourceLifecycle(
            paths: [
                home.appendingPathComponent("sessions", isDirectory: true),
                home.appendingPathComponent("archived_sessions", isDirectory: true)
            ],
            dynamicExtensions: ["jsonl"]
        ) { [weak self] in
            guard let self else { return }
            self.writer.setLocalUsageFreshness(.dirty, for: .codex)
        }
        logInfo("[local-usage] Codex watcher configured home=\(home.path)")
        codexSourceLifecycle?.start()
    }

    private func stopCodexWatcher() {
        codexSourceLifecycle?.stop()
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
            // 等价于 AntigravityFetcher().hasLocalAuth() 的常量语义：真正的本地
            // 探测（pgrep/lsof 进程发现）推迟到 async fetch()，这里直接短路，
            // 避免每轮 reconcile 都构造一个 fetcher。
            return true
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
