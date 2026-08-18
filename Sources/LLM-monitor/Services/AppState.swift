import Foundation
import Combine
import AppKit

/// 全局状态：从 ConfigStore 派生 provider 列表 + 定时刷新
@MainActor
final class AppState: ObservableObject {
    // MARK: - 公开状态（UI 绑定）

    /// 每个 provider 当前状态
    @Published private(set) var statuses: [ProviderStatus] = []

    /// 是否正在刷新（任意 provider）
    @Published private(set) var isRefreshing: Bool = false

    /// 最近一次 provider 请求完成时间（用于 footer 显示，不限定为 full refresh）
    @Published private(set) var lastRefreshAt: Date?

    /// 下次自动刷新时间
    @Published private(set) var nextRefreshAt: Date?

    /// 菜单栏健康度的时间基准。由 AppState 的稳定定时任务每分钟推进，避免在
    /// `MenuBarExtra` label 内嵌 `TimelineView`；后者在部分 macOS 版本上会在
    /// status item 初始化时形成持续重绘循环。
    @Published private(set) var healthEvaluationDate = Date()

    /// 配置文件路径（UI 用）
    let configStore: ConfigStore

    // MARK: - 内部

    /// 公开给 SettingsView / 调试 — 真正的 single source of truth。
    let descriptors: [FetcherDescriptor]
    /// per-provider timer + in-flight dedup + 退避 + 失败计数。
    /// 之前这 4 个 dict 散在 AppState 里，现在统一交给 `ProviderRefreshScheduler` 打理。
    /// `internal`（非 `private`）让测试能直接观察 `nextDelay` 等状态机行为。
    var refreshScheduler: ProviderRefreshScheduler!
    /// 异步探测本地服务（antigravity / codex）是否还活着 + 缓存结果。
    /// 之前是 `externalAuthAvailability` + `authProbeTasks` 两个 dict + 3 个方法，
    /// 现在统一交给 `AuthProber` 打理。
    private var authProber: AuthProber!
    /// provider 的延迟详情补齐任务（当前用于 codex 本地 usage 明细）
    private var detailTasks: [String: Task<Void, Never>] = [:]
    /// 防止被取消的旧 Codex detail task 清掉新任务的扫描状态。
    private var detailTaskTokens: [String: UUID] = [:]
    /// background 请求进行中时收到的显式 full refresh 请求。当前请求完成后只补跑一次。
    private var pendingFullRefreshIDs: Set<String> = []
    /// 仍在等待同一 background 请求的 full refresh 调用数。用于取消时只撤销
    /// 当前调用的 pending 标记，不影响其他仍在等待的调用。
    private var pendingFullRefreshWaiterCounts: [String: Int] = [:]
    /// 远程额度恢复通知；通过协议注入，测试不会触碰系统通知中心。
    private let quotaUpdateNotifier: any QuotaUpdateNotifying

    /// GLM（ZCode）本地 scanner 的独立定期触发 task。
    ///
    /// scanner 只读本地 `.db`，不依赖远端 quota，但它跟 quota 绑定触发（quota 成功
    /// 后才 scan）有一个盲区：quota 持续失败时（Key 过期 / 网络问题）scanner 永远不跑，
    /// 用户在 ZCode 里产生的新 token 消耗进不来，柱图卡在旧数据。
    ///
    /// 这个 task 用 GLM provider 的 `refreshIntervalSeconds`（与 quota 同节奏）独立
    /// 定期触发 scan，不依赖 quota 是否成功。scanner 内部的 db+WAL 指纹检查保证
    /// 指纹没变时只做一次 `stat()`（微秒级），指纹变了才跑 SQL（~1.5ms），零额外负担。
    private var glmLocalUsagePeriodicTask: Task<Void, Never>?

    /// 推进 `healthEvaluationDate`，让高峰窗口跨越分钟边界时能更新菜单栏颜色。
    private var healthClockTask: Task<Void, Never>?

    /// Antigravity 本地 token 用量 scanner：通过 `LocalUsageCoordinator` 包装
    /// singleton + Combine wire-up 逻辑，避免在 AppState 里重复 30+ 行。
    /// `lazy`：只在首次需要时构造（disable 状态下永不会触发）。
    private lazy var antigravityLocalUsageCoordinator = LocalUsageCoordinator<AntigravityLocalUsage>(
        providerID: providerID(for: .antigravity) ?? "",
        logTag: "antigravity",
        makeScanner: { AntigravityLocalUsageScanner(fetcher: AntigravityFetcher()) },
        apply: { [weak self] usage in self?.applyAntigravityLocalUsage(usage) },
        setScanning: { [weak self] isScanning in
            self?.setScanningState(isScanning, for: self?.providerID(for: .antigravity) ?? "")
        }
    )

    /// Minimax 本地 token 用量 scanner：只读取 v2 `runtime-state.sqlite`。
    /// 通过 `LocalUsageCoordinator` 统一 scanner 构造、trigger、扫描状态和结果 apply。
    private lazy var minimaxLocalUsageCoordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
        providerID: providerID(for: .minimaxTokenPlan) ?? "",
        logTag: "minimax",
        makeScanner: { MinimaxLocalUsageScanner() },
        apply: { [weak self] usage in self?.applyMinimaxLocalUsage(usage) },
        setScanning: { [weak self] isScanning in
            self?.setScanningState(isScanning, for: self?.providerID(for: .minimaxTokenPlan) ?? "")
        }
    )

    /// GLM 本地 token 用量 scanner：读 ZCode（智谱官方 CLI）的 ~/.zcode/cli/db/db.sqlite
    /// `model_usage` 表。模式跟 minimax / opencode scanner 镜像。
    private lazy var glmLocalUsageCoordinator = LocalUsageCoordinator<GlmLocalUsage>(
        providerID: providerID(for: .glmCodingPlan) ?? "",
        logTag: "glm-local",
        makeScanner: { GlmZcodeLocalUsageScanner() },
        apply: { [weak self] usage in self?.applyGlmLocalUsage(usage) },
        setScanning: { [weak self] isScanning in
            self?.setScanningState(isScanning, for: self?.providerID(for: .glmCodingPlan) ?? "")
        }
    )

    /// opencode 本地用量 scanner（共享后台数据源，由四张卡各自的合并开关决定是否消费）。
    /// opencode 自身不是 menu bar provider，不挂独立 scanning 状态；启动时以及
    /// Minimax / GLM quota refresh 成功后都会触发（in-flight 去重）。
    private lazy var opencodeUsageCoordinator = LocalUsageCoordinator<OpencodeLocalUsage>(
        providerID: "opencode",
        logTag: "opencode",
        makeScanner: { OpencodeUsageScanner() },
        apply: { [weak self] usage in self?.applyOpencodeUsage(usage) },
        setScanning: { _ in /* opencode 不暴露 scanning 状态 */ }
    )

    /// dsh 本地 session token 用量 scanner。dsh 不是菜单栏 provider；它会扫描
    /// `$DSH_HOME/sessions`（默认 `~/.dsh/sessions`），按 session 中记录的 provider
    /// 分片，结果通过 `usageProjection` 自动并入 MiniMax / GLM / DeepSeek 三张卡。
    /// dsh 自身不暴露 scanning 状态（没有 UI 消费者），所以不传 `setScanning`。
    private lazy var dshUsageCoordinator = LocalUsageCoordinator<DshLocalUsage>(
        providerID: "dsh",
        logTag: "dsh",
        makeScanner: { DshLocalUsageScanner() },
        apply: { [weak self] usage in self?.applyDshUsage(usage) }
    )

    /// 统一的 statuses 广播通道。
    ///
    /// 之前是 3 个独立 publisher + 手动 `objectWillChange.send()`：
    /// - `@Published statuses` 在 MenuBarExtra 上观察失效（实测 body 不会重 eval）
    /// - `antigravityUsageDidChange` / `minimaxUsageDidChange` 单独广播 antigravity/minimax 局部 usage
    /// - `mutateStatus` 里手动 `objectWillChange.send()` 强制 reload
    ///
    /// 现在统一成一个 `statusDidChange`：所有"改 statuses 数组"或"改 status[idx] 局部字段"
    /// 的入口（`mutateStatus` / `setScanningState` / `apply*LocalUsage` / `rebuildStatuses`）
    /// 都 fire 一次，view 端只挂 1 个 `.onReceive` 即可。
    ///
    /// payload 是 `Void`（不需要把值传出去；view 只需要知道"变了"）。
    let statusDidChange = PassthroughSubject<Void, Never>()

    /// 综合所有已启用 Provider 计算的全局系统健康度等级。
    /// - 若没有启用的 provider，返回 nil。
    /// - 若任意启用的 provider 处于失败且无缓存状态或 `.critical`，返回 `.critical`。
    /// - 若任意启用的 provider 处于 `.warning` 或高峰期窗口生效中，返回 `.warning`。
    /// - 否则返回 `.healthy`。
    var systemHealthLevel: HealthLevel? {
        systemHealthLevel(at: Date())
    }

    /// 指定时刻计算系统健康度。状态栏的分钟时钟用它跨越高峰边界，测试也能
    /// 注入固定时间，避免依赖墙上时钟。
    func systemHealthLevel(at now: Date) -> HealthLevel? {
        let enabled = statuses.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        var levels: [HealthLevel] = []

        for status in enabled {
            switch status.state {
            case .failed(message: _, lastSuccess: nil):
                return .critical
            case .failed(message: _, lastSuccess: let info?):
                levels.append(info.healthLevel)
            case .ok(let info), .loading(lastSuccess: let info?):
                levels.append(info.healthLevel)
            case .notConfigured, .ready, .loading(lastSuccess: nil):
                break
            }

            if let glmPeak = status.glmPeakWindow, case .peak = glmPeak.status(at: now) {
                levels.append(.warning)
            }
            if let deepseekPeak = status.deepseekPeakWindow, case .peak = deepseekPeak.status(at: now) {
                levels.append(.warning)
            }
        }

        guard !levels.isEmpty else { return nil }
        return levels.min()
    }

    private var configMonitorSource: DispatchSourceFileSystemObject?
    private var configReloadTask: Task<Void, Never>?
    /// config.json 被删除/替换后重新挂载 watcher 的重试 task（带退避）。
    private var configWatcherRetryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// 只持久化远程 quota 最近成功时间；quota 本体仍不落盘，避免把完整响应当作用户缓存。
    private let refreshTimestampsURL: URL
    private var persistedRefreshTimes: [String: Date]
    /// R1: last-refresh.json 的写盘移到独立 actor，MainActor 不再做 encode/fsync。
    private let lastRefreshStore: LastRefreshStore
    /// 配置变更后递增。旧请求即使稍后完成，也不能覆盖新配置派生出的状态。
    private var configurationGeneration = 0

    init(
        descriptors: [FetcherDescriptor],
        configStore: ConfigStore,
        quotaUpdateNotifier: any QuotaUpdateNotifying = NoopQuotaUpdateNotifier()
    ) {
        self.descriptors = descriptors
        self.configStore = configStore
        self.quotaUpdateNotifier = quotaUpdateNotifier
        self.refreshTimestampsURL = configStore.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("last-refresh.json")
        self.persistedRefreshTimes = Self.loadPersistedRefreshTimes(
            from: configStore.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("last-refresh.json")
        )
        self.lastRefreshStore = LastRefreshStore(url: self.refreshTimestampsURL)
        self.refreshScheduler = ProviderRefreshScheduler(
            refreshHandler: { [weak self] providerID, mode in
                guard let self else { return .deferred }
                return await self.refreshProviderDirectly(providerID: providerID, mode: mode)
            },
            intervalProvider: { [configStore] providerID in
                configStore.config.effectiveRefreshInterval(for: providerID)
            },
            onNextRefreshChange: { [weak self] in
                self?.nextRefreshAt = self?.refreshScheduler.earliestNextRefresh
            }
        )
        self.authProber = AuthProber(
            fetcherProvider: { [weak self] providerID in
                guard let self,
                      let descriptor = self.descriptors.first(where: { $0.id == providerID }),
                      let pc = self.configStore.config.providers[providerID] else { return nil }
                return descriptor.makeFetcher(pc)
            },
            onChange: { [weak self] providerID, isAvailable in
                guard let self else { return }
                // 状态真变了才触发 rebuild（probe cache 内部已比对过 previous，这里 isAvailable
                // 一定不等于之前的值）。只有"离线"侧需要立刻让用户看到提示；
                // "恢复"侧依赖下一次 refresh 成功后的 markAvailable，不在这里 rebuild。
                if !isAvailable {
                    logInfo("[auth-probe] [\(providerID)] 本地服务离线，触发 rebuild + reschedule")
                    self.rebuildStatuses()
                    self.rescheduleAll()
                } else {
                    logInfo("[auth-probe] [\(providerID)] 本地服务恢复，由下次 refresh 接管")
                }
            }
        )

        logInfo("AppState: 初始化，\(descriptors.count) 个 fetcher 已注册")
        for d in descriptors {
            logInfo("  - fetcher: \(d.id) (\(d.displayName))")
        }

        rebuildStatuses()
        start()
        setupConfigSubscription()
    }

    /// 给定 provider kind 查 descriptors 拿实际 id。新增 provider 时只改 `LLMMonitorApp.makeDescriptors()`。
    private func providerID(for kind: ProviderKind) -> String? {
        descriptors.first(where: { $0.kind == kind })?.id
    }

    /// 本地用量 scanner 的启动策略：Minimax / GLM 的数据库可直接读取，
    /// Antigravity 需要等本地 IDE 服务和主 quota 首次成功。
    nonisolated static func localUsageScanStartsImmediately(for kind: ProviderKind) -> Bool {
        kind == .minimaxTokenPlan || kind == .glmCodingPlan
    }

    // MARK: - 生命周期

    func start() {
        // `stop()` 也会取消配置目录 watcher；允许生命周期重启时恢复配置热加载。
        if configMonitorSource == nil {
            startConfigWatcher()
        }

        // 为每个 enabled + auth 就绪的 provider 调度独立 timer
        cancelAllRefreshTasks()
        logInfo("AppState.start: 检查 \(statuses.count) 个 status")
        for status in statuses {
            let should = shouldAutoRefresh(providerID: status.id)
            logInfo("  [\(status.id)] shouldAutoRefresh=\(should)")
            if should {
                scheduleRefresh(for: status.id)
            }
            // 本地用量 scanner 的启动时机按 provider 特性分两种：
            // - minimax：扫描器只读本地 `.db`，跟远端 quota 无关，进 app 立即
            //   触发一次，用户首屏就看到本地历史。
            // - glm（ZCode）：同上，只读本地 `.db`，进 app 立即触发一次。
            // - antigravity：依赖本地 pgrep/lsof 探到的 Antigravity IDE 进程，
            //   进程未起时 scan 会失败；等到主 quota 首次成功（authProber.markAvailable）
            //   才触发更稳。
            // 保留这种差异是有意的（见 `testLocalUsageScanTriggerTimingPolicy` 防退化）。
            if status.isConfigured, Self.localUsageScanStartsImmediately(for: status.kind) {
                if status.kind == .minimaxTokenPlan {
                    triggerMinimaxLocalUsageScan()
                } else if status.kind == .glmCodingPlan {
                    triggerGlmLocalUsageScan()
                }
            }
        }
        // opencode 是共享数据源，不依赖某个 quota provider 是否启用；启动时主动扫描一次，
        // 让设置页诊断和已有 GLM/minimax 卡片尽早拿到本地历史。
        triggerOpencodeUsageScan()
        triggerDshUsageScan()
        // GLM 本地 scanner 的独立定期触发（不依赖 quota 成功）
        startGlmLocalUsagePeriodicTrigger()
        startHealthClock()
    }

    func stop() {
        cancelAllRefreshTasks()
        pendingFullRefreshIDs.removeAll()
        pendingFullRefreshWaiterCounts.removeAll()
        cancelAllDetailTasks()
        authProber.cancelAll()
        antigravityLocalUsageCoordinator.cancelInFlight()
        minimaxLocalUsageCoordinator.cancelInFlight()
        glmLocalUsageCoordinator.cancelInFlight()
        opencodeUsageCoordinator.cancelInFlight()
        dshUsageCoordinator.cancelInFlight()
        glmLocalUsagePeriodicTask?.cancel()
        glmLocalUsagePeriodicTask = nil
        healthClockTask?.cancel()
        healthClockTask = nil
        nextRefreshAt = nil
        configReloadTask?.cancel()
        configReloadTask = nil
        configWatcherRetryTask?.cancel()
        configWatcherRetryTask = nil
        configMonitorSource?.cancel()
        configMonitorSource = nil
    }

    /// 重新调度所有 timer（配置变更后调用）
    func rescheduleAll() {
        start()
    }

    /// `TimelineView` 放在 `MenuBarExtra` 的 label 中会让某些 AppKit/SwiftUI 组合
    /// 反复执行 `MenuBarExtraController.updateButton`，造成主线程满载和内存暴涨。
    /// 用 AppState 持有的单一定时任务发布分钟脉冲，label 只消费一个普通 Date 值。
    private func startHealthClock() {
        healthClockTask?.cancel()
        healthEvaluationDate = Date()
        healthClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.healthEvaluationDate = Date()
            }
        }
    }

    // MARK: - 公开操作

    func refreshAll() async {
        let providerIDs = statuses
            .filter { shouldAutoRefresh(providerID: $0.id) }
            .map(\.id)

        // 每个 provider 仍然并行；refreshScheduler.markInFlight 会合并重复触发。
        await withTaskGroup(of: Void.self) { group in
            for providerID in providerIDs {
                group.addTask { [self, providerID] in
                    await self.refreshProviderFully(providerID: providerID)
                }
            }
        }
    }

    func refreshOne(providerID: String) async {
        await refreshProviderFully(providerID: providerID)
    }

    /// 显式刷新不能被正在进行的 background refresh 吞掉。
    private func refreshProviderFully(providerID: String) async {
        if let activeMode = refreshScheduler.inFlightMode(for: providerID) {
            if activeMode == .background {
                pendingFullRefreshIDs.insert(providerID)
                pendingFullRefreshWaiterCounts[providerID, default: 0] += 1
            }
            do {
                try await refreshScheduler.waitUntilNotInFlight(providerID)
            } catch is CancellationError {
                if activeMode == .background {
                    removePendingFullRefreshWaiter(providerID)
                }
                return
            } catch {
                // R18: generic catch（非取消错误）也必须清理 waiter count 与 claim set，
                // 否则会泄漏并可能误触发第二次 full refresh。与 CancellationError 路径一致。
                if activeMode == .background {
                    removePendingFullRefreshWaiter(providerID)
                }
                return
            }

            guard !Task.isCancelled else {
                if activeMode == .background {
                    removePendingFullRefreshWaiter(providerID)
                }
                return
            }

            // Set 的 remove 是 MainActor 上的单次 claim：多个等待者只会有一个
            // 真正补跑 full refresh，其余等待者自然返回。
            if pendingFullRefreshIDs.remove(providerID) != nil {
                pendingFullRefreshWaiterCounts.removeValue(forKey: providerID)
                _ = await refreshProviderDirectly(providerID: providerID, mode: .full)
            }
            return
        }
        _ = await refreshProviderDirectly(providerID: providerID, mode: .full)
    }

    /// 撤销一个在 background refresh 上挂起的 full refresh 请求。
    private func removePendingFullRefreshWaiter(_ providerID: String) {
        let remaining = (pendingFullRefreshWaiterCounts[providerID] ?? 1) - 1
        if remaining > 0 {
            pendingFullRefreshWaiterCounts[providerID] = remaining
        } else {
            pendingFullRefreshWaiterCounts.removeValue(forKey: providerID)
            pendingFullRefreshIDs.remove(providerID)
        }
    }

    func openConfigFile() {
        configStore.openInDefaultEditor()
    }

    func revealLogFile() {
        let url = URL(fileURLWithPath: AppLog.shared.logFilePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 配置变化监听

    private func startConfigWatcher() {
        configMonitorSource?.cancel()
        configWatcherRetryTask?.cancel()
        configWatcherRetryTask = nil

        // 只监听 config.json 单文件本身，而不是整个配置目录：log.txt 与
        // last-refresh.json 就在同一个目录里，目录级 `.write` 监听会让每条日志
        // append / 每次时间戳落盘都触发一轮 debounce + 读盘 + 指纹比对。
        let fd = open(configStore.configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // 编辑器"先删后写"或瞬时替换会让文件短暂不存在；带退避重试，
            // 直到文件重新可打开。open() 失败只是一个 syscall，成本可忽略。
            logWarn("AppState: 配置文件暂不可监听（可能正被替换），稍后重试: \(configStore.configURL.path)")
            configWatcherRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.startConfigWatcher() }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 本应用的 writePrivate 与多数编辑器都用"临时文件 + rename"原子替换：
            // fd 仍指向旧 inode，必须重新打开新文件，否则后续变更全部丢失。
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.startConfigWatcher()
            }
            self.scheduleConfigReload()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.configMonitorSource = source
        logInfo("AppState: 配置文件监听启动 (基于 config.json 单文件 DispatchSource)")
    }

    /// 编辑器保存时可能连发多个事件（写 + 原子替换）。先 debounce，再把配置文件
    /// 读取放到 utility task，避免每个事件都在 MainActor 上同步读盘；最终的
    /// config 解码和发布仍回到 MainActor。
    private func scheduleConfigReload() {
        configReloadTask?.cancel()
        let configURL = configStore.configURL
        configReloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            let data = await Task.detached(priority: .utility) {
                ConfigStore.dataForWatcher(from: configURL)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.configReloadTask = nil
            guard self.configStore.hasChangedSinceLastRead(using: data) else { return }
            logInfo("AppState: 检测到配置文件更新，触发 reload")
            self.configStore.reload(using: data)
        }
    }

    private func setupConfigSubscription() {
        configStore.$config
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                logInfo("AppState: 检测到配置变更，开始重建状态并重新调度任务")
                self.configurationGeneration &+= 1
                self.authProber.reset()
                self.rebuildStatuses()
                self.rescheduleAll()
            }
            .store(in: &cancellables)
    }

    func rebuildStatuses() {
        statuses = descriptors.map { d in
            let pc = configStore.config.providers[d.id]
            // 抓一份"老的" status 用来保留 UI 状态（lastRefreshedAt /
            // isScanningLocalUsage / local usage）。rebuildStatuses 完整替换 statuses，
            // 这些"非 derived" 字段必须手动从旧 status 拷贝，否则 UI 会在 config 变
            // 更时丢掉"上一秒还在显示的 Antigravity 7 天图"这种状态。
            let preserved = self.preservedFields(for: d.id)
            let derived = Self.deriveProviderState(
                descriptor: d,
                providerConfig: pc,
                authProber: authProber,
                hintProvider: externalAuthHint(for:config:)
            )
            // auth 还 ok（derived == .ready）就保留旧 status 的 `.ok/.loading/.failed`
            // 状态 —— 旧 data 跟着旧 state 走，UI 不会闪白。
            // auth 失效（derived == .notConfigured）就重置成 derived 状态，
            // 把 lastSuccess / lastRefreshedAt 一起清掉。
            //
            // R4：Antigravity 本地服务暂时离线（.serviceOffline）不复用旧成功状态，
            // 也不是 notConfigured——改成 .failed("Antigravity 本地服务离线",
            // lastSuccess: oldInfo)，UI 半透明保留旧数据 + 离线提示。
            let finalState: ProviderStatus.State
            switch (derived, preserved.previousState) {
            case (.ready, let .some(oldState))
                where Self.stateHasSuccessData(oldState):
                finalState = oldState
            case (.serviceOffline(let message), let previous):
                let lastInfo = previous.flatMap { Self.lastSuccessInfo(from: $0) }
                finalState = .failed(message: message, lastSuccess: lastInfo)
            default:
                finalState = Self.deriveState(
                    descriptor: d,
                    providerConfig: pc,
                    authProber: authProber,
                    hintProvider: externalAuthHint(for:config:)
                )
            }
            // 与 ProviderRefreshScheduler 共用同一份 effective interval；外部手改配置为
            // 小于 10 秒时，卡片新鲜度与实际调度都按 10 秒计算。
            let interval = Int(configStore.config.effectiveRefreshInterval(for: d.id))

            var statusItem = ProviderStatus(
                id: d.id,
                displayName: pc?.displayName ?? d.displayName,
                kind: d.kind,
                iconSystemName: d.iconSystemName,
                accentColor: d.accentColor,
                refreshIntervalSeconds: interval,
                isEnabled: pc?.enabled ?? true,
                state: finalState,
                lastRefreshedAt: preserved.lastRefreshedAt ?? persistedRefreshTimes[d.id],
                isScanningLocalUsage: preserved.isScanningLocalUsage
            )
            // OpenCode is a Client; keep the old ProviderStatus field as a
            // compatibility projection while reading the new client binding
            // registry as the source of truth.
            statusItem.mergeOpencodeUsage = configStore.config.isClientBindingEnabled(
                clientID: ClientID.openCode,
                quotaProviderID: d.kind.quotaProviderID
            )
            statusItem.antigravityLocalUsage = preserved.antigravityLocalUsage
            statusItem.minimaxLocalUsage = preserved.minimaxLocalUsage
            statusItem.glmLocalUsage = preserved.glmLocalUsage
            statusItem.opencodeUsage = preserved.opencodeUsage
            statusItem.dshUsage = preserved.dshUsage
            // GLM 高峰期窗口是纯 config 派生（非运行时累积），每次 rebuild 直接重算。
            statusItem.glmPeakWindow = d.kind == .glmCodingPlan
                ? (pc?.glmPeakWindow ?? .zhipuDefault)
                : nil
            // DeepSeek 高峰期窗口同理（基于北京时间 + 周末平价开关）。
            statusItem.deepseekPeakWindow = d.kind == .deepseek
                ? (pc?.deepseekPeakWindow ?? .defaultWindow)
                : nil
            return statusItem
        }
        logInfo("AppState: 派生 \(statuses.count) 个 status，其中 enabled=\(statuses.filter { $0.isConfigured }.count)")
        statusDidChange.send()
        updateGlobalRefreshingState()
        scheduleExternalAuthProbes()
    }

    /// `.ok / .loading(lastSuccess:) / .failed(_, lastSuccess:)` 都算"有上次成功数据"——
    /// 这些状态的 `lastSuccess` 不为空，UI 应该有内容显示。
    /// `.notConfigured / .ready` 算"无数据"——UI 应该是 placeholder / 灰点。
    /// `nonisolated`：纯 enum 派发，无 self 状态，test 跟 sync 调用方都能直接调。
    nonisolated static func stateHasSuccessData(_ state: ProviderStatus.State) -> Bool {
        switch state {
        case .ok:
            return true
        case .loading(let previous), .failed(_, let previous):
            return previous != nil
        case .notConfigured, .ready: return false
        }
    }

    // MARK: - 内部刷新

    /// 单个 provider 的完全独立 fetch：
    /// - 不进任何 group / semaphore
    /// - 直接 fetch + 直接写自己的 status[idx]
    /// - 多个 provider 调用此方法时**完全并行，互不阻塞**
    /// `internal` 便于并发刷新状态机做无网络回归测试；产品调用仍经 scheduler/公开刷新入口。
    @MainActor
    func refreshProviderDirectly(providerID: String, mode: RefreshMode) async -> ProviderRefreshOutcome {
        guard refreshScheduler.markInFlight(providerID, mode: mode) else {
            logDebug("refreshProviderDirectly[\(providerID)]: 已有请求进行中，合并本次触发")
            return .deferred
        }
        defer {
            refreshScheduler.markNotInFlight(providerID)
            updateGlobalRefreshingState()
        }

        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else {
            logWarn("refreshProviderDirectly: 找不到 provider \(providerID) 的 idx")
            return .deferred
        }
        guard let descriptor = descriptors.first(where: { $0.id == providerID }) else { return .deferred }
        guard let pc = configStore.config.providers[providerID], pc.enabled else {
            logDebug("refreshProviderDirectly[\(providerID)]: disabled")
            return .deferred
        }

        // auth 就绪检查
        let fetcher: any QuotaFetcher
        if descriptor.kind.usesExternalAuth {
            let probe = descriptor.makeFetcher(pc)
            if !probe.hasLocalAuth() {
                logDebug("refreshProviderDirectly[\(providerID)]: hasLocalAuth=false")
                return .deferred
            }
            // 复用 probe，避免重复构造 fetcher。
            fetcher = probe
        } else {
            guard pc.usableAPIKey != nil else {
                logDebug("refreshProviderDirectly[\(providerID)]: apiKey 无效")
                return .deferred
            }
            fetcher = descriptor.makeFetcher(pc)
        }
        // 进入异步 fetch 之前抓一份当前 generation；fetch 返回时跟最新 generation 比对，
        // 不一致则丢弃旧请求结果（配置变了，状态会重建）。
        let startedAtGeneration = configurationGeneration

        // 标记 loading —— 把当前 `.ok(info)` / `.failed(_, prev)` 里的 lastSuccess
        // 提到 `.loading(lastSuccess:)`，UI 继续显示上次的 QuotaInfo（半透明）。
        // `.notConfigured / .ready / .loading` 进来时 lastSuccess = nil。
        let lastSuccessSnapshot: QuotaInfo? = {
            switch statuses[idx].state {
            case .ok(let info):        return info
            case .failed(_, let prev): return prev
            case .loading(let prev):   return prev
            case .notConfigured, .ready: return nil
            }
        }()
        mutateStatus(at: idx) { $0.state = .loading(lastSuccess: lastSuccessSnapshot) }
        updateGlobalRefreshingState()

        let startedAt = Date()
        do {
            let fetchedInfo = try await fetcher.fetch(mode: mode)
            guard startedAtGeneration == configurationGeneration else {
                logDebug("refreshProviderDirectly[\(providerID)]: 配置已变更，丢弃旧请求结果")
                return .deferred
            }
            // fetch 完成后重新查 idx（statuses 可能在 await 期间被 rebuildStatuses 等改变）
            guard let newIdx = statuses.firstIndex(where: { $0.id == providerID }) else { return .deferred }
            // 把"这次新抓的"和"上次缓存的"按 fetcher 自带的 merger 合成最终值。
            // merger 跟 fetcher 一起在 fetcher 文件里定义，policy 不在 AppState 里堆 if 分支。
            let previousInfo = statuses[newIdx].lastSuccess
            let info = fetcher.resultMerger.merge(
                new: fetchedInfo,
                previous: previousInfo,
                mode: mode
            )
            logInfo("  [\(providerID)] 刷新成功，\(info.models.count) 个 model (\(Int(Date().timeIntervalSince(startedAt) * 1000))ms)")
            for m in info.models {
                if descriptor.kind == .codexChatGpt {
                    var summary = "    - \(m.modelName): primary=\(Int(m.intervalRemainingPercent))%"
                    if m.hasWeeklyWindow {
                        summary += ", secondary=\(Int(m.weeklyRemainingPercent))%"
                    }
                    logInfo(summary)
                } else {
                    logInfo("    - \(m.modelName): 5h=\(Int(m.intervalRemainingPercent))%, 周=\(Int(m.weeklyRemainingPercent))%")
                }
            }
            if descriptor.kind == .antigravity {
                let prev = statuses[newIdx].antigravityLocalUsage
                // logDebug：BEFORE/AFTER mutate 是 debug 期间验证状态用，60s 一次的
                // antigravity refresh 不需要在 release 日志里 dump 完整 prev/after 值。
                logDebug("[antigravity/refresh] BEFORE mutate: status[\(newIdx)].antigravityLocalUsage=\(prev.map { "\($0.sessionCount) sessions" } ?? "nil")")
            }
            mutateStatus(at: newIdx) {
                $0.state = .ok(info)
                $0.lastRefreshedAt = info.fetchedAt
            }
            let quotaIncreases = QuotaIncreaseDetector.detect(
                current: info,
                previous: previousInfo
            )
            if !quotaIncreases.isEmpty {
                quotaUpdateNotifier.notify(
                    providerID: providerID,
                    providerName: statuses[newIdx].displayName,
                    increases: quotaIncreases
                )
            }
            persistedRefreshTimes[providerID] = info.fetchedAt
            persistRefreshTimes()
            if descriptor.kind == .antigravity {
                let after = statuses[newIdx].antigravityLocalUsage
                logDebug("[antigravity/refresh] AFTER mutate: status[\(newIdx)].antigravityLocalUsage=\(after.map { "\($0.sessionCount) sessions" } ?? "nil")")
            }
            lastRefreshAt = Date()

            if descriptor.kind == .codexChatGpt {
                scheduleCodexUsageDetailsRefresh(
                    providerID: providerID,
                    providerConfig: pc,
                    model: info.models.first,
                    fetchedAt: info.fetchedAt,
                    configurationGeneration: startedAtGeneration
                )
            } else {
                cancelDetailTask(for: providerID)
            }
            if descriptor.kind == .antigravity {
                authProber.markAvailable(providerID)
                // 主 quota 拿到后，异步触发本地 token 用量扫描
                // （mtime diff + JSONL cache 复用，跟 quota 同节奏）
                triggerAntigravityLocalUsageScan()
            }
            if descriptor.kind == .minimaxTokenPlan {
                // minimax 主 quota 拿到后，异步触发 v2 runtime-state 单源扫描
                // （mtime diff + WAL 增量）
                triggerMinimaxLocalUsageScan()
                // 同时触发 opencode 扫描，供各卡合并开关与诊断页更新
                triggerOpencodeUsageScan()
                triggerDshUsageScan()
            }
            if descriptor.kind == .glmCodingPlan {
                // GLM 主 quota 拿到后，触发 native ZCode + opencode 双扫描
                triggerGlmLocalUsageScan()
                triggerOpencodeUsageScan()
                triggerDshUsageScan()
            }
            if descriptor.kind == .deepseek {
                // DeepSeek quota 刷新后补扫 dsh，便利在没有 API Key / 余额请求失败时
                // 仍能看到 harness 自身的 token 活动。
                triggerDshUsageScan()
            }
            refreshScheduler.recordSuccess(providerID)
            let resetDates = info.models.flatMap { [$0.intervalResetsAt, $0.weeklyResetsAt] }.compactMap { $0 }
            refreshScheduler.scheduleMidCycleResetRefreshes(for: providerID, resetsAtDates: resetDates)
            return .completed(success: true)
        } catch {
            // 取消请求不能误判为失败：配置变更 / 停止刷新 / 窗口关闭时取消，
            // 不应设置 .failed、计入失败数、触发 auth probe / 退避。
            // HTTPClient 已经 re-throw CancellationError / URLError.cancelled，
            // 这里在 catch 入口再守一道，确保任何取消路径都走 .deferred。
            // 统一 filter 在 `CancellationFilter`，三个调用方共用。
            if CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled) {
                logDebug("refreshProviderDirectly[\(providerID)]: 请求被取消，丢弃结果")
                return .deferred
            }
            guard startedAtGeneration == configurationGeneration else {
                logDebug("refreshProviderDirectly[\(providerID)]: 配置已变更，丢弃旧请求错误")
                return .deferred
            }
            guard let newIdx = statuses.firstIndex(where: { $0.id == providerID }) else { return .deferred }
            let userMessage = QuotaError.userFacingDescription(for: error, providerKind: descriptor.kind)
            logError("  [\(providerID)] 刷新失败: \(userMessage)")
            mutateStatus(at: newIdx) {
                $0.state = .failed(message: userMessage,
                                   lastSuccess: statuses[newIdx].lastSuccess)
            }
            lastRefreshAt = Date()
            refreshScheduler.recordFailure(providerID)
            if descriptor.kind == .antigravity {
                authProber.scheduleProbe(for: providerID)
            }
            return .completed(success: false)
        }
    }

    // MARK: - 状态变更辅助

    /// 修改单个 provider 的状态，并触发统一的 `statusDidChange` 广播。
    ///
    /// 之前是 `objectWillChange.send() + in-place mutation` 模式（in-place 不触发
    /// `@Published` willSet，所以要手动 send）。现在改成"copy array → modify → assign
    /// once"：赋值触发 `@Published` willSet 自动 send `objectWillChange`，加上手动
    /// `statusDidChange.send()` 走显式 publisher 通道（绕开 MenuBarExtra 缓存），
    /// 两路保险。
    @MainActor
    func mutateStatus(at idx: Int, _ block: (inout ProviderStatus) -> Void) {
        var copy = statuses
        block(&copy[idx])
        statuses = copy
        statusDidChange.send()
    }

    @MainActor
    func mutateStatus(for providerID: String, _ block: (inout ProviderStatus) -> Void) {
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else { return }
        mutateStatus(at: idx, block)
    }

    // MARK: - per-provider 调度

    /// 该 provider 是否应进入自动刷新
    ///
    /// 之前只判 `apiKey?.isEmpty`，但 `refreshProviderDirectly` 实际用 `usableAPIKey`
    /// 拒绝空白 / 模板占位符（如 `REPLACE-WITH-YOUR-KEY`），结果：
    /// `shouldAutoRefresh = true` → `refresh = deferred` → 1s 后重试 → 死循环
    /// 现在统一用 `usableAPIKey != nil`，跟 fetch 实际行为对齐。
    private func shouldAutoRefresh(providerID: String) -> Bool {
        guard let pc = configStore.config.providers[providerID], pc.enabled else { return false }
        guard let descriptor = descriptors.first(where: { $0.id == providerID }) else { return false }
        if descriptor.kind.usesExternalAuth {
            return descriptor.makeFetcher(pc).hasLocalAuth()
        } else {
            return pc.usableAPIKey != nil
        }
    }

    private func externalAuthHint(for kind: ProviderKind, config: ProviderConfig) -> String {
        switch kind {
        case .codexChatGpt:
            let path = config.authPath ?? "~/.codex/auth.json"
            return "外部 auth 缺失：\(path)"
        case .antigravity:
            return "请先启动 Antigravity 并完成登录"
        case .minimaxTokenPlan:
            return "外部 auth 未就绪"
        case .glmCodingPlan, .deepseek:
            return "外部 auth 未就绪"
        }
    }

    // MARK: - Antigravity local usage scanner

    /// 触发一次扫描。scanner 由 `LocalUsageCoordinator` 负责 lazy 构造 + wire-up。
    /// 失败时保留上次的 lastResult（scanner 内部已经做这个保护）。
    private func triggerAntigravityLocalUsageScan() {
        // logDebug：跟 LocalUsageCoordinator.sink 的 [apply] sink fired 一致；
        // 60s 一次的 trigger 不需要污染 release 日志。scanner 内部的 [antigravity-scan] 日志
        // 仍然走 logInfo，保留诊断价值。
        logDebug("[antigravity/apply] triggerAntigravityLocalUsageScan called")
        antigravityLocalUsageCoordinator.trigger()
    }

    @MainActor
    private func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {
        applyLocalUsage(
            kind: .antigravity,
            field: \.antigravityLocalUsage,
            fieldName: "antigravityLocalUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - minimax local usage scanner

    /// 触发一次扫描。scanner 由 `LocalUsageCoordinator` 负责 lazy 构造 + wire-up。
    /// 失败时保留上次的 lastResult（scanner 内部已经做这个保护）。
    private func triggerMinimaxLocalUsageScan() {
        logDebug("[minimax/apply] triggerMinimaxLocalUsageScan called")
        minimaxLocalUsageCoordinator.trigger()
    }

    @MainActor
    private func applyMinimaxLocalUsage(_ usage: MinimaxLocalUsage?) {
        applyLocalUsage(
            kind: .minimaxTokenPlan,
            field: \.minimaxLocalUsage,
            fieldName: "minimaxLocalUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - GLM (ZCode) local usage scanner

    /// 触发一次扫描。scanner 由 `LocalUsageCoordinator` 负责 lazy 构造 + wire-up。
    /// 失败时保留上次的 lastResult（scanner 内部已经做这个保护）。
    private func triggerGlmLocalUsageScan() {
        logDebug("[glm-local/apply] triggerGlmLocalUsageScan called")
        glmLocalUsageCoordinator.trigger()
    }

    /// 启动 GLM 本地 scanner 的独立定期触发。用 GLM provider 的 `refreshIntervalSeconds`
    /// 做节奏（与 quota 同间隔），但**不依赖 quota 是否成功**——这样 GLM quota 持续失败时，
    /// 用户在 ZCode 里产生的新 token 消耗仍能定期进柱图。scanner 内部 db+WAL 指纹保证
    /// 指纹没变时只 stat()（微秒级），变了才跑 SQL。
    ///
    /// 只在 GLM provider 配置且启用时启动；配置变更后 `stop()` + `start()` 会重建本 task。
    private func startGlmLocalUsagePeriodicTrigger() {
        glmLocalUsagePeriodicTask?.cancel()
        let glmID = providerID(for: .glmCodingPlan) ?? ProviderKind.glmCodingPlan.providerID
        // 仅在 GLM provider 存在且启用时定期触发（未启用没必要空跑）
        let isConfigured = descriptors.contains { $0.kind == .glmCodingPlan }
            && (configStore.config.providers[glmID]?.enabled ?? false)
        guard isConfigured else { return }

        let interval = configStore.config.effectiveRefreshInterval(for: glmID)
        glmLocalUsagePeriodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    // 取消（配置变更 / stop）正常退出
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await MainActor.run { self.triggerGlmLocalUsageScan() }
            }
        }
        logInfo("[glm-local] 独立定期触发已启动，间隔=\(Int(interval))s（不依赖 quota 成功）")
    }

    @MainActor
    private func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {
        applyLocalUsage(
            kind: .glmCodingPlan,
            field: \.glmLocalUsage,
            fieldName: "glmLocalUsage",
            summarize: { "\($0.sessionCount) sessions" },
            usage: usage
        )
    }

    // MARK: - dsh local usage scanner（共享 session 日志 + 诊断页）

    private func triggerDshUsageScan() {
        logDebug("[dsh/apply] triggerDshUsageScan called")
        dshUsageCoordinator.trigger()
    }

    @MainActor
    private func applyDshUsage(_ usage: DshLocalUsage?) {
        var copy = statuses
        var changed = false
        for idx in copy.indices {
            if copy[idx].dshUsage != usage {
                copy[idx].dshUsage = usage
                changed = true
            }
        }
        guard changed else { return }
        statuses = copy
        statusDidChange.send()
        logDebug("[dsh/apply] providers=\(usage?.byProvider.count ?? 0), sessions=\(usage?.sessionCount ?? 0)")
    }

    // MARK: - opencode local usage scanner（GLM 卡 + 诊断页）

    private func triggerOpencodeUsageScan() {
        logDebug("[opencode/apply] triggerOpencodeUsageScan called")
        opencodeUsageCoordinator.trigger()
    }

    /// 把 opencode 扫描结果分发到四个可能的 consumer provider status。
    /// opencode 自身不是 provider，所以 coordinator 的 setScanning 闭包是 no-op。
    @MainActor
    private func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {
        // 每张卡自己决定是否合并；这里统一挂快照，关闭开关时仍可在诊断页查看。
        var copy = statuses
        var changed = false
        for kind in ProviderKind.allCases {
            guard let providerID = providerID(for: kind),
                  let idx = copy.firstIndex(where: { $0.id == providerID }) else { continue }
            let prev = copy[idx].opencodeUsage
            // OpencodeLocalUsage 自定义 == 排除 scannedAt
            if prev == usage { continue }
            copy[idx].opencodeUsage = usage
            changed = true
        }
        if changed {
            statuses = copy
            statusDidChange.send()
        }
    }

    /// 统一的"local usage apply"路径 —— antigravity / minimax (未来更多) 共享的
    /// 4 步逻辑：
    /// 1. 从 `descriptors` 找 providerID（key 来自 `kind`）
    /// 2. 在 `statuses` 里找 idx
    /// 3. no-op 检查（== 排除 `scannedAt` 之后基本命中，**不写 status、不触发 reload**）
    /// 4. 走 `mutateStatus` 改 `keyPath` 指向的字段
    ///
    /// - Parameters:
    ///   - kind: provider 类型，决定 log tag 和查 `descriptors` 的 key
    ///   - field: `ProviderStatus` 上的可写 keyPath（指向 optional usage 字段）
    ///   - fieldName: 字段名（仅用于日志；keyPath 拿不到 string 化的名字）
    ///   - summarize: 把 usage 序列化成日志摘要（避免 dump 完整 7-day daily 数组）；
    ///     用 closure 让调用方按自己的"X sessions" / "X events" 等不同口径。
    ///   - usage: scanner 拿到的新值（nil = 清空）
    ///
    /// 用 keyPath 而不是 closure set 避免每次调用都要写 `{ $0.field = v }`。
    /// `T: Equatable` 让 no-op 检查编译期就有 ==。
    @MainActor
    private func applyLocalUsage<T: Equatable>(
        kind: ProviderKind,
        field: WritableKeyPath<ProviderStatus, T?>,
        fieldName: String,
        summarize: (T) -> String,
        usage: T?
    ) {
        let logTag = "[\(kind.logTag)/apply]"
        guard let providerID = providerID(for: kind) else {
            logWarn("\(logTag) apply aborted: no provider registered for kind .\(kind)")
            return
        }
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else {
            logWarn("\(logTag) apply aborted: providerID \(providerID) not in statuses")
            return
        }
        let prev = statuses[idx][keyPath: field]
        if prev == usage {
            // no-op 命中是常态（业务字段没变只 scannedAt 变了也算 no-op，
            // 修过 == 排除 scannedAt 之后基本都命中），release 不打。
            logDebug("\(logTag) no-op: status[\(idx)].\(fieldName) already equals incoming value")
            return
        }
        let prevText = prev.map(summarize) ?? "nil"
        let newText = usage.map(summarize) ?? "nil"
        logDebug("\(logTag) reassigning statuses: \(fieldName) \(prevText) → \(newText)")
        // 走统一的 mutateStatus：copy → modify → assign + statusDidChange.send。
        mutateStatus(at: idx) { $0[keyPath: field] = usage }
        logDebug("\(logTag) done, status[\(idx)].\(fieldName)=\((statuses[idx][keyPath: field]).map(summarize) ?? "nil")")
    }

    // MARK: - 后台本地认证探测

    private func scheduleExternalAuthProbes() {
        for descriptor in descriptors where descriptor.kind == .antigravity {
            authProber.scheduleProbe(for: descriptor.id)
        }
    }

    private func updateGlobalRefreshingState() {
        self.isRefreshing = statuses.contains { if case .loading = $0.state { return true }; return false }
    }

    @MainActor
    private func scheduleCodexUsageDetailsRefresh(
        providerID: String,
        providerConfig: ProviderConfig,
        model: ModelQuota?,
        fetchedAt: Date,
        configurationGeneration: Int
    ) {
        cancelDetailTask(for: providerID)
        guard let model else { return }

        let taskToken = UUID()
        detailTaskTokens[providerID] = taskToken
        setScanningState(true, for: providerID)

        let task = Task { [weak self] in
            let details = await CodexFetcher.loadUsageDetailsAsync(
                authPath: providerConfig.authPath,
                model: model
            )
            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.finishCodexDetailTaskIfCurrent(
                        providerID: providerID,
                        taskToken: taskToken
                    )
                }
                return
            }
            await MainActor.run {
                self?.applyCodexUsageDetails(
                    details,
                    providerID: providerID,
                    fetchedAt: fetchedAt,
                    configurationGeneration: configurationGeneration,
                    taskToken: taskToken
                )
            }
        }
        detailTasks[providerID] = task
    }

    @MainActor
    private func applyCodexUsageDetails(
        _ details: CodexUsageDetails?,
        providerID: String,
        fetchedAt: Date,
        configurationGeneration: Int,
        taskToken: UUID
    ) {
        logDebug("[codex/detail] applyCodexUsageDetails: providerID=\(providerID), details is nil?=\(details == nil)")
        guard detailTaskTokens[providerID] == taskToken else {
            logDebug("[codex/detail] apply aborted: stale task token")
            return
        }
        detailTaskTokens.removeValue(forKey: providerID)
        detailTasks.removeValue(forKey: providerID)
        setScanningState(false, for: providerID)
        guard configurationGeneration == self.configurationGeneration else {
            logDebug("[codex/detail] apply aborted: configurationGeneration mismatch (\(configurationGeneration) != \(self.configurationGeneration))")
            return
        }
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else {
            logDebug("[codex/detail] apply aborted: providerID not found")
            return
        }

        var changed = false

        // Enrich active state if it holds a QuotaInfo matching fetchedAt.
        // 之前是双写（_lastSuccess + state）—— 拆出来两个分支：`_lastSuccess` 跟
        // `state` 都要 enrich 才能让 UI 跟 healthLevel 一致。State 自身持有
        // QuotaInfo（.ok / .loading(lastSuccess:) / .failed(_, lastSuccess:)）
        // 之后，只 enrich state 即可，single source of truth。
        switch statuses[idx].state {
        case .ok(let info):
            if info.fetchedAt == fetchedAt {
                if info.codexUsageDetails != details {
                    mutateStatus(at: idx) { $0.state = .ok(info.enriched(with: details)) }
                    changed = true
                }
            } else {
                logDebug("[codex/detail] active state fetchedAt mismatch: info.fetchedAt(\(info.fetchedAt)) != fetchedAt(\(fetchedAt))")
            }
        case .failed(let message, let lastSuccess):
            if let last = lastSuccess, last.fetchedAt == fetchedAt {
                if last.codexUsageDetails != details {
                    mutateStatus(at: idx) {
                        $0.state = .failed(message: message, lastSuccess: last.enriched(with: details))
                    }
                    changed = true
                }
            }
        case .loading(let lastSuccess):
            if let prev = lastSuccess, prev.fetchedAt == fetchedAt {
                if prev.codexUsageDetails != details {
                    mutateStatus(at: idx) {
                        $0.state = .loading(lastSuccess: prev.enriched(with: details))
                    }
                    changed = true
                }
            } else {
                logDebug("[codex/detail] loading state has no matching lastSuccess")
            }
        case .notConfigured, .ready:
            logDebug("[codex/detail] active state is \(statuses[idx].state), no QuotaInfo to enrich")
        }

        if changed {
            logDebug("[codex/detail] apply succeeded!")
        } else {
            logDebug("[codex/detail] apply skipped: no changes or mismatch")
        }
    }

    /// 给单个 provider 调度独立 timer（间隔由 scheduler 通过 effectiveRefreshInterval 获取）
    /// 委托给 `ProviderRefreshScheduler`，本地不再维护 timer state。
    private func scheduleRefresh(for providerID: String) {
        refreshScheduler.schedule(for: providerID)
    }

    @MainActor
    private func cancelDetailTask(for providerID: String) {
        detailTasks[providerID]?.cancel()
        detailTasks.removeValue(forKey: providerID)
        detailTaskTokens.removeValue(forKey: providerID)
        setScanningState(false, for: providerID)
    }

    private func finishCodexDetailTaskIfCurrent(providerID: String, taskToken: UUID) {
        guard detailTaskTokens[providerID] == taskToken else { return }
        detailTaskTokens.removeValue(forKey: providerID)
        detailTasks.removeValue(forKey: providerID)
        setScanningState(false, for: providerID)
    }

    @MainActor
    private func setScanningState(_ isScanning: Bool, for providerID: String) {
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }),
              statuses[idx].isScanningLocalUsage != isScanning else {
            return
        }
        // 走统一的 mutateStatus：copy → modify → assign + statusDidChange.send。
        mutateStatus(at: idx) { $0.isScanningLocalUsage = isScanning }
    }

    private func cancelAllRefreshTasks() {
        refreshScheduler.cancelAll()
    }

    private func cancelAllDetailTasks() {
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
        detailTaskTokens.removeAll()
    }

    private static func loadPersistedRefreshTimes(from url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: Date].self, from: data)
        } catch {
            logWarn("AppState: last-refresh.json 解析失败，忽略旧时间: \(error.localizedDescription)")
            return [:]
        }
    }

    private func persistRefreshTimes() {
        // R1: encode + fsync 写盘移出 MainActor。这里只把值类型快照拷贝后 enqueue，
        // 不在主线程做 JSON 编码或文件 I/O；写盘由 LastRefreshStore 合并窗口处理。
        let snapshot = persistedRefreshTimes
        Task { [lastRefreshStore] in
            await lastRefreshStore.enqueue(snapshot)
        }
    }

    // MARK: - rebuildStatuses helpers

    /// rebuildStatuses 用的"保留字段"快照 —— 把旧 status 里不属于 config 派生的字段
    /// 集中提取，避免 `rebuildStatuses` 里 4 次 `statuses.first(where: { $0.id == ... })`。
    ///
    /// 不再包含 `lastSuccess` —— 它现在跟 `state` 绑在一起（`.ok(info)` /
    /// `.loading(lastSuccess:)` / `.failed(_, lastSuccess:)`），需要时直接拿
    /// `previousState` 整体复用。
    private func preservedFields(for providerID: String) -> PreservedStatusFields {
        guard let old = statuses.first(where: { $0.id == providerID }) else {
            return PreservedStatusFields(
                lastRefreshedAt: nil,
                isScanningLocalUsage: false,
                previousState: nil,
                antigravityLocalUsage: nil,
                minimaxLocalUsage: nil,
                glmLocalUsage: nil,
                opencodeUsage: nil,
                dshUsage: nil
            )
        }
        return PreservedStatusFields(
            lastRefreshedAt: old.lastRefreshedAt,
            isScanningLocalUsage: old.isScanningLocalUsage,
            previousState: old.state,
            antigravityLocalUsage: old.antigravityLocalUsage,
            minimaxLocalUsage: old.minimaxLocalUsage,
            glmLocalUsage: old.glmLocalUsage,
            opencodeUsage: old.opencodeUsage,
            dshUsage: old.dshUsage
        )
    }

    /// 从 config + auth probe 派生一个 provider 的 `State`。抽出成 static + 闭包注入
    /// fetcher 由 descriptor 工厂构造，因此测试可以直接注入 mock descriptor。
    static func deriveState(
        descriptor: FetcherDescriptor,
        providerConfig: ProviderConfig?,
        authProber: AuthProber?,
        hintProvider: (ProviderKind, ProviderConfig) -> String
    ) -> ProviderStatus.State {
        // R4: 真正的派生走类型化 ProviderDerivation；本方法保留 State 返回类型，
        // 把 .serviceOffline 折叠成 .notConfigured 以兼容历史调用方与测试。
        switch deriveProviderState(
            descriptor: descriptor,
            providerConfig: providerConfig,
            authProber: authProber,
            hintProvider: hintProvider
        ) {
        case .ready:
            return .ready
        case .notConfigured(let reason):
            return .notConfigured(reason: reason)
        case .serviceOffline(let message):
            return .notConfigured(reason: message)
        }
    }

    /// R4: 类型化派生结果，让 `rebuildStatuses` 能区分"配置/凭据确实无效"与
    /// "已配置但本地服务暂时不可用"，后者保留 lastSuccess 而不是清空。
    enum ProviderDerivation: Equatable {
        case ready
        case notConfigured(reason: String)
        case serviceOffline(message: String)
    }

    static func deriveProviderState(
        descriptor: FetcherDescriptor,
        providerConfig: ProviderConfig?,
        authProber: AuthProber?,
        hintProvider: (ProviderKind, ProviderConfig) -> String
    ) -> ProviderDerivation {
        let id = descriptor.id
        guard let pc = providerConfig else {
            logInfo("  [\(id)] 未在 config 中配置")
            return .notConfigured(reason: "未在 config.json 中配置")
        }
        if !pc.enabled {
            logInfo("  [\(id)] 在 config 中禁用")
            return .notConfigured(reason: "已在 config.json 中禁用")
        }
        if descriptor.kind.usesExternalAuth {
            let probe = descriptor.makeFetcher(pc)
            if !probe.hasLocalAuth() {
                let hint = hintProvider(descriptor.kind, pc)
                logInfo("  [\(id)] 外部 auth 未就绪：\(hint)")
                return .notConfigured(reason: hint)
            }
            if descriptor.kind == .antigravity,
               let authProber,
               authProber.isUnavailable(id) {
                // R4: auth 文件在、配置启用，但本地 Antigravity 服务暂时不可用。
                // 与"凭据确实不存在"区分开：返回 serviceOffline，rebuildStatuses 会保留
                // lastSuccess 并以 .failed("Antigravity 本地服务离线") 展示。
                logInfo("  [\(id)] 后台探测到本地服务离线，保留 lastSuccess")
                return .serviceOffline(message: "Antigravity 本地服务离线")
            }
            logInfo("  [\(id)] 外部 auth ok，state=ready")
            return .ready
        } else {
            guard pc.usableAPIKey != nil else {
                logInfo("  [\(id)] API Key 未填写或为模板占位符")
                return .notConfigured(reason: "API Key 未填写")
            }
            logInfo("  [\(id)] 配置 ok，state=ready")
            return .ready
        }
    }

    /// R4: 从旧 State 提取 lastSuccess，供 serviceOffline 分支保留旧数据。
    nonisolated static func lastSuccessInfo(from state: ProviderStatus.State) -> QuotaInfo? {
        switch state {
        case .ok(let info):           return info
        case .loading(let prev):      return prev
        case .failed(_, let last):    return last
        case .notConfigured, .ready:  return nil
        }
    }
}

/// `rebuildStatuses` 内部用的 DTO —— 把"老 status 里需要保留的字段"打包。
struct PreservedStatusFields {
    let lastRefreshedAt: Date?
    let isScanningLocalUsage: Bool
    /// 旧 `state`，供 `rebuildStatuses` 决定是否复用（auth 还 ok 时直接保留
    /// `.ok/.loading/.failed` 状态 + 它的 QuotaInfo 数据）。
    let previousState: ProviderStatus.State?
    let antigravityLocalUsage: AntigravityLocalUsage?
    let minimaxLocalUsage: MinimaxLocalUsage?
    let glmLocalUsage: GlmLocalUsage?
    /// opencode 扫描快照（挂在各个 consumer status 上），跨 rebuildStatuses 保留
    /// 避免配置变更触发的那次 rebuild 抹掉刚扫到的共享用量导致 footer 闪空白。
    let opencodeUsage: OpencodeLocalUsage?
    let dshUsage: DshLocalUsage?
}
