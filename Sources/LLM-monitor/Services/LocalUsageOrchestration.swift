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
    /// 立即全量扫描请求标志：triggerImmediateScanAll 置位，循环 B 在下一拍消费。
    /// 读写都在 @MainActor 上串行发生，无需加锁。
    private var immediateScanRequested = false
    /// 客户端就绪状态缓存，用于日志去噪（仅在状态变动时记录日志）
    private var clientReadinessCache: [String: Bool] = [:]
    /// 仅供测试注入客户端就绪判定覆写
    var testReadinessOverride: ((String) -> Bool)?
    /// 仅供测试注入休眠闭包
    var testSleepOverride: ((TimeInterval) async throws -> Void)?

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
    /// 同时覆盖构造期初值与已加载实例；开关打开时立即触发一次 GLM 扫描，
    /// 让卡片不用等下一个刷新周期就能出现余额块。
    func updateGlmBalanceLogParsing(enabled: Bool) {
        let changed = glmBalanceLogParsingEnabled != enabled
        glmBalanceLogParsingEnabled = enabled
        glmCoordinator.withLoadedScanner { ($0 as? GlmZcodeLocalUsageScanner)?.setBalanceLogParsingEnabled(enabled) }
        if changed, enabled {
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
        startupDelay: TimeInterval = 5
    ) {
        stopUsageLoop()
        // 丢弃上一轮循环遗留的立即扫描请求；新循环首拍本身就会立即扫描。
        immediateScanRequested = false
        logInfo("[usage-loop] 启动用量循环 B，\(Int(startupDelay))s 后跑首拍（与额度循环错峰），后续由全局刷新间隔驱动")
        usageLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if startupDelay > 0 {
                await self.interruptibleSleep(startupDelay)
                guard !Task.isCancelled else { return }
            }
            // 首拍即扫全部客户端
            await self.scanAllClients()

            while !Task.isCancelled {
                // 消费立即扫描请求（在下一拍扫描前清零，避免请求自我延续成死循环）：
                // - wake 到达时循环正在扫描中会被吞掉，靠这里的标志立即补一拍（不睡眠）；
                // - wake 到达时循环正在睡眠，wakeLoop 已提前打断睡眠，标志在本拍被
                //   消费后直接扫描，不会再多跑一拍。
                // 扫描期间新到的请求会重新置位，由再下一拍立即处理，同批触发自动归一。
                let runImmediately = self.immediateScanRequested
                self.immediateScanRequested = false
                if !runImmediately {
                    await self.interruptibleSleep(intervalProvider())
                    guard !Task.isCancelled else { break }
                }
                await self.scanAllClients()
            }
        }
    }

    /// 停止用量循环 B
    func stopUsageLoop() {
        usageLoopTask?.cancel()
        usageLoopTask = nil
        wakeLoop()
    }

    /// 手动 refreshAll 或系统唤醒时调用：置位立即扫描请求并重置睡眠计时，
    /// 由循环 B 统一执行这一拍。不在调用方并发 scanAllClients，避免与被唤醒的
    /// 循环在同一时刻对同一批文件开两拍并发扫描。
    func triggerImmediateScanAll() async {
        immediateScanRequested = true
        wakeLoop()
    }

    /// 单拍迭代全部 6 个客户端，条目级隔离
    func scanAllClients() async {
        // 1. Minimax Code
        scanClientIfReady(clientID: "minimax_code") { [weak self] in
            self?.minimaxCoordinator.trigger()
        }

        // 2. ZCode (GLM)
        scanClientIfReady(clientID: "zcode-glm") { [weak self] in
            self?.glmCoordinator.trigger()
        }

        // 3. OpenCode
        scanClientIfReady(clientID: "opencode") { [weak self] in
            self?.opencodeCoordinator.trigger()
        }

        // 4. DSH
        scanClientIfReady(clientID: "dsh") { [weak self] in
            self?.dshCoordinator.trigger()
        }

        // 5. Antigravity (轻量本地就绪判断，不依赖 quota)
        scanClientIfReady(clientID: "antigravity") { [weak self] in
            self?.antigravityCoordinator.trigger()
        }

        // 6. Codex (包含 usage details enrichment)
        let codexReady = checkClientReadiness("codex")
        updateReadinessAndLog(for: "codex", isReady: codexReady)
        if codexReady {
            await scanCodexUsageDetails()
        }
    }

    private func scanClientIfReady(clientID: String, action: () -> Void) {
        let isReady = checkClientReadiness(clientID)
        updateReadinessAndLog(for: clientID, isReady: isReady)
        guard isReady else { return }
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
            let codexDir = NSString(string: "~/.codex").expandingTildeInPath
            return fileManager.fileExists(atPath: codexDir)
        default:
            return false
        }
    }

    private func updateReadinessAndLog(for clientID: String, isReady: Bool) {
        let previous = clientReadinessCache[clientID]
        if previous != isReady {
            clientReadinessCache[clientID] = isReady
            if !isReady {
                logInfo("[usage-loop] 客户端 [\(clientID)] 未就绪或未安装，跳过扫描")
            } else if previous != nil {
                logInfo("[usage-loop] 客户端 [\(clientID)] 已就绪，恢复扫描")
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
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int)
}
