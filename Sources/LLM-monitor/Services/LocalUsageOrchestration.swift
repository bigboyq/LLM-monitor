import Foundation

/// 循环 B（用量循环）与本地用量扫描编排：
/// 单一 Task 循环负责所有客户端（codex / zcode-glm / opencode / dsh / minimax_code / antigravity）
/// 的本地 token 用量刷新，按全局 refreshIntervalSeconds 统一节奏运行。
/// 彻底剥离 quota 依赖：quota 刷新成功不再触发任何本地用量扫描。
///
/// 状态写入（ProviderStatus 字段）通过 `LocalUsageStatusWriting` 协议回调
/// AppState，保持单向依赖：orchestration → writer(AppState)。
@MainActor
final class LocalUsageOrchestration {
    /// 本地扫描的种类标识。
    enum ScanKind: String, CaseIterable, Sendable {
        case antigravity
        case minimax
        case glm
        case opencode
        case dsh
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

    // MARK: - 循环 B 内部状态

    /// 单一常驻本地用量扫描循环 Task
    private var usageLoopTask: Task<Void, Never>?
    /// 循环 B 睡眠等待时的休眠 Task（wakeLoop() 时精确 cancel 提前唤醒，杜绝 continuation 悬挂）
    private var sleepTask: Task<Void, any Error>?
    /// 下一拍将使用的 beat 序号（单调递增）。waiter 以登记时刻的 nextBeatID 为
    /// 目标，只有目标 beat 完成才恢复——扫描进行中到达的请求不会被当前拍提前
    /// 恢复（当前拍收尾时 waiter.target > lastFinishedBeatID）。
    private var nextBeatID: UInt64 = 1
    /// 最近一次完成的 beat 序号。
    private var lastFinishedBeatID: UInt64 = 0
    /// 等待目标 beat 完成的续体。triggerImmediateScanAll 挂起调用方，目标拍收尾
    /// 时恢复，让 refreshAll 能真正等到本地扫描完成（兑现"刷新=全部新鲜"）。
    /// stopUsageLoop 时全部恢复，避免循环停止后调用方悬挂。
    /// 未满足的 waiter 本身就是"有待处理立即扫描"的状态（target > 已完成拍），
    /// 拍间决策据此决定是否跳过睡眠，不再需要独立的请求标志。
    private var pendingBeatContinuations: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    /// 客户端就绪状态缓存，用于日志去噪（仅在状态变动时记录日志）
    private var clientReadinessCache: [String: Bool] = [:]
    /// 仅供测试注入客户端就绪判定覆写
    var testReadinessOverride: ((String) -> Bool)?
    /// 仅供测试注入休眠闭包
    var testSleepOverride: ((TimeInterval) async throws -> Void)?
    /// 仅供测试：beat 中段（5 个 scanClient 之后、codex 分支之前）的注入点，
    /// 用于确定性构造"扫描进行中收到立即扫描请求"的场景。
    var testMidBeatHook: (() -> Void)?

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

    func cancelInFlightAll() {
        antigravityCoordinator.cancelInFlight()
        minimaxCoordinator.cancelInFlight()
        glmCoordinator.cancelInFlight()
        opencodeCoordinator.cancelInFlight()
        dshCoordinator.cancelInFlight()
        stopUsageLoop()
    }

    /// 推送「活动套餐余额日志解析」开关（设置 `parseZcodeBalanceLog`）。
    /// 同时覆盖构造期初值与已加载实例；开关变化时立即触发一次 GLM 扫描，
    /// 让开启时不用等下一个刷新周期就能出现余额块，关闭时也能及时清除旧余额。
    func updateGlmBalanceLogParsing(enabled: Bool) {
        let changed = glmBalanceLogParsingEnabled != enabled
        glmBalanceLogParsingEnabled = enabled
        glmCoordinator.withLoadedScanner { ($0 as? GlmZcodeLocalUsageScanner)?.setBalanceLogParsingEnabled(enabled) }
        if changed {
            trigger(.glm)
        }
    }

    // MARK: - 循环 B（用量循环）生命周期与调度

    /// 启动循环 B：以全局刷新间隔迭代所有客户端。
    /// 启动后先延迟 `startupDelay`（默认 5s）再跑首拍——与循环 A 的首次额度刷新
    /// 错峰，让 codex 明细扫描时数据层大概率已有存量 reset 时间（首拍即能产出
    /// 窗口用量），同时避免两条循环同一时刻并发扫描。延迟可被
    /// `triggerImmediateScanAll`（手动刷新/系统唤醒）提前打断，不会让用户等待。
    func startUsageLoop(
        intervalProvider: @escaping () -> TimeInterval,
        startupDelay: TimeInterval = 5,
        onBeat: (@MainActor () -> Void)? = nil
    ) {
        stopUsageLoop()
        // 重置 beat 计数；等待方已在 stopUsageLoop 里全部恢复。新循环首拍本身
        // 就会立即扫描。
        nextBeatID = 1
        lastFinishedBeatID = 0
        logInfo("[usage-loop] 启动用量循环 B，\(Int(startupDelay))s 后跑首拍（与额度循环错峰），后续由全局刷新间隔驱动")
        usageLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if startupDelay > 0 {
                await self.interruptibleSleep(startupDelay)
                guard !Task.isCancelled else { return }
            }
            while !Task.isCancelled {
                let beatID = self.nextBeatID
                self.nextBeatID += 1

                await self.scanAllClients()
                onBeat?()
                self.finishBeat(through: beatID)

                // 拍间决策：还有未满足的立即扫描请求（target > 刚完成的拍，即扫描
                // 进行中到达的请求）→ 不睡眠，立即跑它们的满足拍。睡眠/启动延迟
                // 期间到达的请求已由刚完成的拍满足（target == 该拍），自然落入
                // 睡眠分支，不会"首拍 + 立即拍"连扫两拍。
                if pendingBeatContinuations.contains(where: { $0.target > beatID }) {
                    continue
                }
                await self.interruptibleSleep(intervalProvider())
                guard !Task.isCancelled else { break }
            }
        }
    }

    /// 停止用量循环 B
    func stopUsageLoop() {
        usageLoopTask?.cancel()
        usageLoopTask = nil
        wakeLoop()
        // 循环停止后不会再有 beat 收尾，恢复所有等待方避免悬挂
        resumeAllBeatWaiters()
    }

    /// 手动 refreshAll 或系统唤醒时调用：请求循环 B 在下一拍立即全量扫描，并
    /// 等待该拍扫描完成后才返回——refreshAll 依赖这一点兑现"刷新=全部新鲜"；
    /// 系统唤醒等 fire-and-forget 调用方多等一个 beat 也无害。
    /// 不在调用方并发 scanAllClients，避免与被唤醒的循环在同一时刻对同一批文件
    /// 开两拍并发扫描。循环未运行时直接返回。
    func triggerImmediateScanAll() async {
        guard usageLoopTask != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 目标 = 登记时刻的下一拍：扫描进行中登记的请求由下一拍满足；睡眠/
            // 启动延迟期间登记的请求由即将开始的这一拍满足。不再需要独立请求
            // 标志——未满足的 waiter 本身就是"有待处理请求"的状态，且登记
            // （同步段）必然先于 wakeLoop，不存在丢唤醒。
            pendingBeatContinuations.append((target: nextBeatID, continuation: continuation))
            wakeLoop()
        }
    }

    /// 一拍收尾：恢复目标 beat 已完成的等待方；未达目标的继续等待（它们请求的
    /// 是正在进行的扫描之后的下一拍）。
    private func finishBeat(through finishedBeatID: UInt64) {
        lastFinishedBeatID = finishedBeatID
        var remaining: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in pendingBeatContinuations {
            if waiter.target <= finishedBeatID {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingBeatContinuations = remaining
    }

    /// 恢复所有 beat 等待方（循环停止后不会再有 beat 收尾）。
    private func resumeAllBeatWaiters() {
        let waiters = pendingBeatContinuations
        pendingBeatContinuations.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    /// 单拍迭代全部 6 个客户端，条目级隔离。
    /// readiness 检查仅用于日志/诊断，不拦截就绪客户端的常规扫描；唯一例外是
    /// 数据源从"存在"变为"消失"的过渡拍要补扫一次，让 scanner 发布空/nil 快照
    /// 清掉 UI 里的旧用量（否则数据源删除后 UI 永远停在旧用量）。从未安装的
    /// 客户端不做每拍空扫，单测注入 false override 时也不会触发真实扫描。
    func scanAllClients() async {
        // 1. Minimax Code
        scanClient("minimax_code") { [weak self] in
            self?.minimaxCoordinator.trigger()
        }

        // 2. ZCode (GLM)
        scanClient("zcode-glm") { [weak self] in
            self?.glmCoordinator.trigger()
        }

        // 3. OpenCode
        scanClient("opencode") { [weak self] in
            self?.opencodeCoordinator.trigger()
        }

        // 4. DSH
        scanClient("dsh") { [weak self] in
            self?.dshCoordinator.trigger()
        }

        // 5. Antigravity (轻量本地就绪判断，不依赖 quota)
        scanClient("antigravity") { [weak self] in
            self?.antigravityCoordinator.trigger()
        }

        // 测试钩子：beat 中段的确定性注入点（构造"扫描进行中收到立即扫描请求"）
        testMidBeatHook?()

        // 6. Codex (包含 usage details enrichment)。扫描入口的守门是
        //    codexEnrichmentTarget()（config 派生，provider 未配置/未启用时跳过）；
        //    readiness 与其它客户端一致：只记日志 + 过渡拍补扫。
        let codexReady = checkClientReadiness("codex")
        let codexWasReady = clientReadinessCache["codex"] == true
        updateReadinessAndLog(for: "codex", isReady: codexReady)
        if codexReady || codexWasReady {
            await scanCodexUsageDetails()
        }
    }

    /// 记录客户端 readiness 日志（去噪）并按需触发扫描动作。
    /// readiness 本身不是扫描门槛：就绪照常扫；数据源"存在→消失"的过渡拍补扫
    /// 一次（scanner 发布空/nil 快照清掉 UI 旧值）；从未就绪的客户端保持跳过，
    /// 避免每拍空扫，也保证注入 false override 的单测不触发真实扫描。
    private func scanClient(_ clientID: String, action: () -> Void) {
        let isReady = checkClientReadiness(clientID)
        let wasReady = clientReadinessCache[clientID] == true
        updateReadinessAndLog(for: clientID, isReady: isReady)
        guard isReady || wasReady else { return }
        action()
    }

    private func scanCodexUsageDetails() async {
        // 纯本地信息：quota 模型缺失（首胜前）也照常扫描，仅窗口用量缺省。
        // model 从共享数据层（statuses.lastSuccess）读取，是数据依赖而非事件依赖。
        guard let target = writer.codexEnrichmentTarget() else { return }

        writer.setScanningState(true, for: target.providerID)
        defer { writer.setScanningState(false, for: target.providerID) }

        let details = await CodexFetcher.loadUsageDetailsAsync(
            authPath: target.authPath,
            model: target.model
        )
        guard !Task.isCancelled else { return }
        writer.applyCodexUsageDetails(
            details,
            providerID: target.providerID,
            fetchedAt: target.fetchedAt,
            configurationGeneration: target.generation
        )
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

    private func interruptibleSleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let sleepClosure = self.testSleepOverride ?? { sec in
            try await Task.sleep(for: .seconds(sec))
        }
        let task = Task {
            try await sleepClosure(seconds)
        }
        self.sleepTask = task
        _ = try? await task.value
        self.sleepTask = nil
    }

    private func wakeLoop() {
        sleepTask?.cancel()
        sleepTask = nil
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
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)?
    /// codex 在 config.json 中配置的 authPath（未配置 provider 时返回 nil，不要求
    /// enabled / lastSuccess）—— 供 readiness 沿 CodexFetcher 的解析链定位 codex home。
    func codexConfiguredAuthPath() -> String?
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int)
}
