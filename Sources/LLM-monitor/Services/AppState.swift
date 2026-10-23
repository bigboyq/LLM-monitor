import Foundation
import Combine
import AppKit

/// 设置窗口的侧栏 tab 模型。放在 Services 而不是 `SettingsView` 内部，是因为
/// `AppState.pendingSettingsTab` 要用它——信号从"主面板点节能"出发、由状态层
/// 持有，视图层只是消费方。声明留在视图里时，Services 只能反向引用
/// `SettingsView.SettingsTab`。
///
/// 纯数据 + 标识派生：只依赖 `FetcherDescriptor`（Fetchers 层），不含任何
/// SwiftUI 类型。视图侧的呈现映射（`brandAsset`，其类型 `BrandLogoAsset` 住在
/// Views）以扩展的形式留在 `Views/SettingsView.swift`。
enum SettingsTab: Identifiable {
    case general
    case energy
    case sync
    case provider(FetcherDescriptor)
    case clients

    static let generalID = "general"
    static let energyID = "energy"
    static let syncID = "sync"
    static let clientsID = "clients"

    var id: String {
        switch self {
        case .general: return Self.generalID
        case .energy: return Self.energyID
        case .sync: return Self.syncID
        case .provider(let d): return d.id
        case .clients: return Self.clientsID
        }
    }

    var displayTitle: String {
        switch self {
        case .general: return "常规"
        case .energy: return "节能"
        case .sync: return "多机联动"
        case .provider(let d): return d.settingsTabTitle ?? d.displayName
        case .clients: return "客户端"
        }
    }

    var iconSystemName: String {
        switch self {
        case .general: return "gearshape"
        case .energy: return "powersleep"
        case .sync: return "personalhotspot"
        case .provider(let d): return d.iconSystemName
        case .clients: return "terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "刷新节奏与应用启动行为"
        case .energy: return "系统睡眠健康度与防止休眠"
        case .sync: return "多台机器的用量与额度联动"
        case .provider(let d): return d.settingsTabSubtitle ?? ""
        case .clients: return "本地客户端用量与 Provider 映射"
        }
    }
}

/// 全局状态：从 ConfigStore 派生 provider 列表 + 定时刷新
@MainActor
final class AppState: ObservableObject {
    // MARK: - 公开状态（UI 绑定）

    /// 每个 provider 当前状态
    @Published private(set) var statuses: [ProviderStatus] = []

    /// 是否正在刷新（任意 provider）
    @Published private(set) var isRefreshing: Bool = false

    /// 是否处于全局刷新事务。它覆盖 quota fetch 与本地 full reconcile，
    /// UI/入口据此禁止 Manual，避免只看 loading 状态导致本地扫描期间重复刷新。
    @Published private(set) var isRefreshJobActive: Bool = false

    /// 最近一次 provider 请求完成时间（用于 footer 显示，不限定为 full refresh）
    @Published private(set) var lastRefreshAt: Date?

    /// 下次自动刷新时间
    @Published private(set) var nextRefreshAt: Date?

    /// 菜单栏健康度的时间基准。由 Provider deadline driver 在高峰窗口边界、
    /// 睡眠健康度刷新边界、状态重建和系统唤醒时推进；不再使用独立常驻 Timer。
    @Published private(set) var healthEvaluationDate = Date()

    /// 配置文件路径（UI 用）
    let configStore: ConfigStore

    /// 「节能」模块数据源：睡眠健康度评估 + 本 App 防休眠断言管理。
    /// 主面板健康灯与设置页节能 pane 直接观察它的 @Published。
    let sleepHealth = SleepHealthService()

    /// 设置窗口跳转信号：主面板 footer「节能」按钮先置 `.energy` 再打开设置
    /// 窗口；SettingsView 在出现 / 值变化时消费并清 nil（双兜底规避窗口
    /// 尚未创建时的订阅竞态）。
    @Published var pendingSettingsTab: SettingsTab?

    // MARK: - 内部

    /// 公开给 SettingsView / 调试 — 真正的 single source of truth。
    let descriptors: [FetcherDescriptor]
    /// 单 Task 调度器（最早到期唤醒 + TaskGroup 并发刷新，无 per-provider timer）
    /// + in-flight dedup；失败按 baseInterval 固定间隔随下一定时周期重试。
    /// 之前这 4 个 dict 散在 AppState 里，现在统一交给 `ProviderRefreshScheduler` 打理。
    /// `internal`（非 `private`）让测试能直接观察 `nextRefreshDates` 等状态机行为。
    var refreshScheduler: ProviderRefreshScheduler!
    /// 异步探测本地服务（antigravity / codex）是否还活着 + 缓存结果。
    /// 之前是 `externalAuthAvailability` + `authProbeTasks` 两个 dict + 3 个方法，
    /// 现在统一交给 `AuthProber` 打理。
    private var authProber: AuthProber!
    /// 显式 full refresh 与 background refresh 的合并协议（pending/waiter/claim）。
    private let manualRefreshGate = ManualRefreshGate()
    /// 远程额度恢复通知；通过协议注入，测试不会触碰系统通知中心。
    private let quotaUpdateNotifier: any QuotaUpdateNotifying
    /// 自动刷新期间到达的 wakeup 最多合并为一次，待当前事务完成后执行。
    private var pendingWakeup = false
    /// Startup 错峰期间先等待所有首拍 quota 结算，再只做一次 full reconcile。
    private var startupReconcilePendingProviderIDs: Set<String> = []
    private var startupReconcileCompleted = false

    /// 5 组本地 scanner 的编排（lazy 构造 / Provider batch reconcile / 条目隔离 / 去噪）。
    /// 扫描结果通过 `LocalUsageStatusWriting` 回写本类型。lazy：构造需要捕获 self。
    /// `internal`（非 `private`）让测试能直接触发或观测用量循环。
    lazy var localUsage = LocalUsageOrchestration(writer: self)

    /// 节假日数据源服务（解析链 + best-effort 取数）。lazy：构造需要捕获 self。
    /// 缓存文件与 config.json 同目录（测试注入临时目录时自动隔离）。
    /// `internal` 让设置页「节假日数据源」节直接观察刷新状态与结果文案。
    lazy var holidayCalendarService: HolidayCalendarService = {
        let service = HolidayCalendarService(
            cacheURL: configStore.configURL
                .deletingLastPathComponent()
                .appendingPathComponent(HolidayCalendarService.cacheFileName),
            onCalendarApplied: { [weak self] in
                guard let self else { return }
                // 节假日表变了 → 广播一次让卡片上的高峰 pill / 额度行重算，
                // 并重排健康边界（下一次高峰/非高峰切换点可能随之移动）。
                self.statusDidChange.send()
                self.rescheduleHealthBoundary(updateEvaluationDate: true)
            }
        )
        return service
    }()

    private var sleepHealthCancellable: AnyCancellable?

    /// 多机联动（2.0 核心链路）：hub 服务 / node 推送的运行时。
    /// `sync.enabled = false`（缺省）时为 nil——现有用户零影响。
    /// `internal` 供测试注入与观测。
    private(set) var fleetSync: FleetSyncCoordinator?
    private var fleetSyncCancellable: AnyCancellable?
    /// node：hub 回传的最近快照（hub：本机装配快照）。UI 唯一的 fleet 数据入口。
    @Published private(set) var fleetSnapshot: FleetSnapshot?
    /// 同步运行时状态（连接 / 错误 / generation），设置页与菜单消费。
    @Published private(set) var fleetRuntimeStatus = FleetSyncStatusInfo()
    /// 用量 scope（§10.0 两条轴之一）：dock 浮层与菜单 hover 卡共用；仅内存态。
    @Published var fleetScope: FleetScope = .local
    private var fleetStateCancellables = Set<AnyCancellable>()

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

    private var cancellables = Set<AnyCancellable>()
    /// 只持久化远程 quota 最近成功时间；quota 本体仍不落盘，避免把完整响应当作用户缓存。
    private let refreshTimestampsURL: URL
    private var persistedRefreshTimes: [String: Date]
    /// R1: last-refresh.json 的写盘移到独立 actor，MainActor 不再做 encode/fsync。
    private let lastRefreshStore: LastRefreshStore
    /// 通知触发器基线（notification-state.json）：检测 previous 的持久源，
    /// 跨重启连续 —— 停机期间的耗尽/恢复事件重启后第一刷即可补报。
    private let triggerStateStore: TriggerStateStore
    /// 配置变更后递增。旧请求即使稍后完成，也不能覆盖新配置派生出的状态。
    private var configurationGeneration = 0
    /// rebuildStatuses 派生时顺带缓存的 "auth 就绪" 结论，供 shouldAutoRefresh
    /// 复用，避免同一次 rebuild 内为同一 provider 二次构造 fetcher + auth stat。
    private var authReadyCache: [String: Bool] = [:]

    init(
        descriptors: [FetcherDescriptor],
        configStore: ConfigStore,
        // 默认参数在非隔离上下文求值，不能直接构造 @MainActor 的 Noop；
        // 这里传 nil 由 MainActor init 兜底。
        quotaUpdateNotifier: (any QuotaUpdateNotifying)? = nil,
        // 同上：注入用于测试观察基线 reset；产品路径传 nil 由 init 构造。
        triggerStateStore: TriggerStateStore? = nil
    ) {
        self.descriptors = descriptors
        self.configStore = configStore
        self.quotaUpdateNotifier = quotaUpdateNotifier ?? NoopQuotaUpdateNotifier()
        self.triggerStateStore = triggerStateStore ?? TriggerStateStore(configURL: configStore.configURL)
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
            },
            onBatchSettledAsync: { [weak self] regularProviderIDs in
                guard let self else { return }
                if !self.startupReconcileCompleted {
                    self.startupReconcilePendingProviderIDs.subtract(regularProviderIDs)
                    guard self.startupReconcilePendingProviderIDs.isEmpty else { return }
                    self.startupReconcileCompleted = true
                    logInfo("[local-usage] Startup quota batches settled → one full reconcile")
                    await self.localUsage.triggerStartupFullScanAll()
                } else {
                    // Automatic Interval/Reset uses the normal reconcile mode;
                    // Manual/Wakeup also use the same dirty/offset-aware path.
                    logInfo("[local-usage] Provider batch settled → reconcile")
                    await self.localUsage.reconcile()
                }
            },
            onJobActivityChange: { [weak self] active in
                guard let self else { return }
                self.isRefreshJobActive = active
                guard !active, self.pendingWakeup else { return }
                self.pendingWakeup = false
                Task { await self.handleSystemWake() }
            },
            onHealthBoundary: { [weak self] boundary in
                self?.handleHealthBoundary(at: boundary)
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

        // 转发 sleepHealth 的变化到 AppState 与 statusDidChange 通道，保证主菜单与设置页即时重渲染
        self.sleepHealthCancellable = sleepHealth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.statusDidChange.send()
        }

        rebuildStatuses()
        start()
        // 节假日数据源：seed 源基线（后续 config 变更据此判定「源变了」）。
        // 启动取数由 App 入口触发，不在测试会构造的 init/start 路径上发网络请求。
        holidayCalendarService.adoptSource(configStore.config.effectiveHolidaySource)
        setupConfigSubscription()
    }

    /// 给定 provider kind 查 descriptors 拿实际 id。新增 provider 时只改 `LLMMonitorApp.makeDescriptors()`。
    func providerID(for kind: ProviderKind) -> String? {
        descriptors.first(where: { $0.kind == kind })?.id
    }

    // MARK: - 生命周期

    func start() {
        // `stop()` 也会取消配置 watcher；允许生命周期重启时恢复配置热加载。
        configStore.startWatching()

        // 多机联动：仅在配置显式启用时启动（缺省 false）。
        if configStore.config.effectiveSyncConfig.enabled {
            startFleetSync()
        }

        // 启动时立即对「节能」睡眠健康度进行一次首评（不等错峰延迟，立即展示健康灯）
        sleepHealth.refreshNow()

        // 循环 A：将所有 enabled + auth 就绪的 provider 纳入额度循环
        cancelAllRefreshTasks()
        logInfo("AppState.start: 检查 \(statuses.count) 个 status")
        startupReconcilePendingProviderIDs = []
        startupReconcileCompleted = false
        for status in statuses {
            let should = shouldAutoRefresh(providerID: status.id)
            logInfo("  [\(status.id)] shouldAutoRefresh=\(should)")
            if should {
                startupReconcilePendingProviderIDs.insert(status.id)
                scheduleRefresh(for: status.id)
            }
        }
        refreshScheduler.staggerInitialRefreshes(at: Date())
        // 即使没有任何启用的 Provider，也要完成一次空 pass，
        // 这样 LocalUsage 才能在 Provider 流程之后执行首次 Full Scan。
        refreshScheduler.start()
        rescheduleHealthBoundary(updateEvaluationDate: true)
    }

    func stop() {
        pendingWakeup = false
        cancelAllRefreshTasks()
        manualRefreshGate.reset()
        authProber.cancelAll()
        localUsage.cancelInFlightAll()
        nextRefreshAt = nil
        sleepHealth.stop()
        configStore.stopWatching()
        fleetSync?.stop()
        // 停机兜底：基线正常走 actor 异步串行落盘，进程可能在 encode + fsync 的
        // 毫秒级窗口里退出而丢掉最后一次基线（重启后停机期间的耗尽/恢复就补报不了）。
        // stop() 是同步路径，不能 await actor，这里同步写完再返回。
        triggerStateStore.flushSynchronously()
    }

    // MARK: - 多机联动接线（2.0 核心链路）

    /// 构造并启动 `FleetSyncCoordinator`：身份走 Keychain，状态存同目录
    /// `fleet.sqlite`（独立于 token-monitor 缓存，§5.7）。构造失败只记日志，
    /// 不影响主功能——本地显示永不依赖网络（§3 不变量 3）。
    private func startFleetSync() {
        if let fleetSync {
            fleetSync.update(config: configStore.config, statuses: statuses)
            return
        }
        do {
            let storeURL = configStore.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("fleet.sqlite")
            let coordinator = FleetSyncCoordinator(
                identityStore: NodeIdentityStore(backend: KeychainNodeIdentityBackend()),
                store: try FleetStore(url: storeURL)
            )
            fleetSync = coordinator
            // coordinator 的两个 @Published 转发到 AppState：视图只观察 AppState，
            // 不感知协调器对象。快照 / 状态变化同样驱动整屏菜单重排。
            coordinator.$latestSnapshot
                .receive(on: RunLoop.main)
                .sink { [weak self] snapshot in self?.fleetSnapshot = snapshot }
                .store(in: &fleetStateCancellables)
            coordinator.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] info in self?.fleetRuntimeStatus = info }
                .store(in: &fleetStateCancellables)
            // 所有 statuses 变更（quota 刷新、scanner 应用、rebuildStatuses）
            // 都驱动同步运行时：hub 防抖重建本机报告，node 唤醒推送循环。
            fleetSyncCancellable = statusDidChange.sink { [weak self] _ in
                guard let self, let fleetSync = self.fleetSync else { return }
                fleetSync.update(config: self.configStore.config, statuses: self.statuses)
            }
            coordinator.start(config: configStore.config, statuses: statuses)
        } catch {
            logError("[fleet] fleet.sqlite 初始化失败，多机联动未启动: \(error.localizedDescription)")
        }
    }

    // MARK: - Fleet UI 解析入口（§7.7 / §10）

    /// 本机稳定 nodeID（菜单节点行的「本机」标记、生效额度来源判断）。
    var fleetLocalNodeID: UUID? { fleetSync?.localNodeID }

    /// 生效额度：本机有效 `lastSuccess` 优先，否则 elected（§7.7 统一入口）。
    /// 所有读额度的界面（iconDuo / 卡片 / 状态条）都从这里取，口径只有一处。
    func fleetEffectiveQuota(for kind: ProviderKind) -> FleetEffectiveQuota {
        FleetUsageProjection.effectiveQuota(
            status: statuses.first { $0.kind == kind },
            elected: fleetSnapshot?.electedQuotas ?? [],
            for: kind.quotaProviderID
        )
    }

    /// 菜单 fleet 汇总（今日全部 + 节点分组）；无快照时 nil → 菜单保持今天的样子。
    var fleetMenuSummary: FleetMenuSummary? {
        guard let fleetSnapshot else { return nil }
        return FleetUsageProjection.menuSummary(
            snapshot: fleetSnapshot,
            localNodeID: fleetSync?.localNodeID
        )
    }

    /// 入列并集（§7.7）：本机已启用 provider ∪ 仅存在 elected 额度的 provider。
    /// elected-only 的 provider 合成一个最小 status（state = .ok(elected)，
    /// 卡片上另有来源标注「来自 X」说明这不是本机抓取）。
    func fleetVisibleStatuses() -> [ProviderStatus] {
        var result = statuses
        guard let snapshot = fleetSnapshot, !snapshot.electedQuotas.isEmpty else { return result }
        let enabledKinds = Set(statuses.filter(\.isEnabled).map(\.kind))
        for elected in snapshot.electedQuotas {
            guard let kind = ProviderKind.allCases.first(where: { $0.quotaProviderID == elected.quotaProviderID }),
                  !enabledKinds.contains(kind),
                  !statuses.contains(where: { $0.kind == kind })
            else { continue }
            let info = QuotaInfo(
                models: elected.models,
                resetCredits: elected.resetCredits,
                planLabel: elected.planLabel,
                accountEmail: elected.accountEmail,
                codexUsageDetails: nil,
                fetchedAt: elected.fetchedAt,
                balanceDetail: elected.balanceDetail
            )
            let descriptor = descriptors.first { $0.kind == kind }
            result.append(ProviderStatus(
                id: kind.providerID,
                displayName: descriptor?.displayName ?? kind.providerID,
                kind: kind,
                iconSystemName: descriptor?.iconSystemName ?? "dollarsign.circle",
                accentColor: .custom,
                refreshIntervalSeconds: 300,
                state: .ok(info)
            ))
        }
        return result
    }

    /// statuses 的「生效额度视图」（§10.1 圆环改造）：入列并集之上，把本机
    /// 没有有效额度、但 fleet 有 elected 的卡替换为 `.ok(elected)`——边缘窗
    /// 常驻圆环据此读到 fleet 余量（hover 卡另有来源标注说明非本机抓取）。
    /// 本机有有效额度时原样保留（本机优先，§2.1）。
    func fleetQuotaEffectiveStatuses() -> [ProviderStatus] {
        fleetVisibleStatuses().map { status in
            let localValid = !(status.lastSuccess?.activeModels.isEmpty ?? true)
            if localValid { return status }
            let effective = fleetEffectiveQuota(for: status.kind)
            guard let quota = effective.quota else { return status }
            var copy = status
            copy.state = .ok(quota)
            return copy
        }
    }

    /// hover 卡 / dock 浮层共用的 fleet 上下文（§10.1）。无快照时 nil：
    /// 卡片回到现状渲染。
    func fleetCardContext(for kind: ProviderKind) -> FleetCardContext? {
        guard let snapshot = fleetSnapshot else { return nil }
        return FleetCardContext(
            scope: fleetScope,
            multiNode: snapshot.nodes.count > 1,
            usage: FleetUsageProjection.cardUsage(
                snapshot: snapshot,
                quotaProviderID: kind.quotaProviderID,
                preferredWindowEnds: Self.preferredWindowEnds(
                    of: fleetEffectiveQuota(for: kind)
                )
            ),
            effectiveQuota: fleetEffectiveQuota(for: kind),
            onScopeChange: { [weak self] newScope in
                self?.fleetScope = newScope
            }
        )
    }

    /// 当前生效额度的窗口边界（§10.7.1 W 裁定）：全局窗口范围显示优先匹配
    /// 该边界，无匹配时取已报告窗口中 `endAt` 最新者。
    static func preferredWindowEnds(of effective: FleetEffectiveQuota) -> [String: Date] {
        guard let model = effective.quota?.primaryModel else { return [:] }
        var ends: [String: Date] = [:]
        if model.hasIntervalWindow { ends["interval"] = model.intervalResetsAt }
        if model.hasWeeklyWindow { ends["weekly"] = model.weeklyResetsAt }
        return ends
    }

    /// fleet 内归因设置是否不一致（§7.8：提示，不阻断）。
    var fleetAttributionInconsistent: Bool {
        fleetSync?.attributionFingerprintsInconsistent ?? false
    }

    /// 配置变更后的重排入口（差异化：只重锚新增 / 重新启用 / interval 变化的 provider）。
    /// 函数名是历史遗留——语义早已不是"重新调度所有"。
    ///
    /// **刻意不是冷启动**：本路径只由「配置写盘」触发（设置页保存、拖 dock
    /// 松手 App 自写 config、auth 探测翻转），而这些操作与刷新无关。走 `start()`
    /// 会在每次写盘后 `cancelAllRefreshTasks()` 清掉全部 deadline 与首刷标记，
    /// 紧接着把每个 provider 的 `nextRefreshDates` 重置为 `now()` —— 于是任何一次
    /// 配置改动都变成"所有 provider 立刻重抓一遍"，而且因为 `hasDoneFirstRefresh`
    /// 一起被清掉，重抓一律走更贵的 `.full`。
    ///
    /// 改为走 scheduler 的差异化重排：仍启用且间隔未变的 provider 原样保留既有
    /// deadline 与首刷状态（下一拍继续 `.background`），只有新增 / 重新启用 /
    /// 间隔变化的 provider 才走初始排期。`start()` 作为**真启动**入口语义不变。
    func rescheduleAll() {
        // `startWatching` 幂等：配置重载路径上 watcher 本来就在跑，这里只是
        // 保持与 start() 一致的"随时可重载"不变量。
        configStore.startWatching()
        sleepHealth.refreshNow()

        let managedProviderIDs = statuses
            .filter { shouldAutoRefresh(providerID: $0.id) }
            .map(\.id)
        logInfo("AppState.rescheduleAll: 配置重载差异化重排，\(managedProviderIDs.count)/\(statuses.count) 个 provider 进入额度循环")
        refreshScheduler.reconfigure(managed: managedProviderIDs)
        rescheduleHealthBoundary(updateEvaluationDate: true)
    }

    // MARK: - 公开操作

    func refreshAll() async {
        guard let token = refreshScheduler.beginExternalJob() else {
            logDebug("AppState.refreshAll: 已有刷新事务进行中，忽略本次 Manual")
            return
        }
        defer { refreshScheduler.endExternalJob(token) }

        let providerIDs = statuses
            .filter { shouldAutoRefresh(providerID: $0.id) }
            .map(\.id)

        // 手动刷新是明确契约："刷新=全部新鲜"。顺序执行：先等额度循环跑完这一拍
        // （quota 窗口 / reset 时间就位），再请求并等待一次用量循环补拍——codex
        // 窗口用量依赖刚落地的 reset 时间，两拍并发跑就可能用旧窗口出结果。
        // 自动定时节拍不受影响：两条循环仍各自独立运行。
        await withTaskGroup(of: Void.self) { group in
            for providerID in providerIDs {
                // 刻意不写 `@MainActor` 闭包属性：Swift 6.4 的 region isolation
                // 检查器处理不了 `@MainActor [capture list]` 这个组合，会直接吐
                // "Please file a bug" 并中断整段检查。子任务的 MainActor 隔离由
                // 下面 await 跨 actor 调用点保证，语义不变。
                group.addTask { [self, providerID] in
                    await self.refreshProviderFully(providerID: providerID, jobToken: token)
                }
            }
        }
        guard refreshScheduler.isCurrentJob(token) else { return }
        await localUsage.triggerImmediateScanAll()
        guard refreshScheduler.isCurrentJob(token) else { return }
        startupReconcilePendingProviderIDs.removeAll()
        startupReconcileCompleted = true
        refreshScheduler.reanchorAllProviders(
            at: Date(),
            resetDatesByProvider: currentResetDatesByProvider()
        )
    }

    /// 系统从睡眠唤醒后的刷新。唤醒走 scheduler 的 refreshForSystemWake 合并
    /// 协议：在飞请求先等待结算（不静默丢弃，也不并发补发第二个请求），刚完成
    /// 过请求的 provider 在活动窗口内直接合并；只有真正需要补拍的 provider 才
    /// 发一次 full，且该请求若赶上已到期的 regular deadline 会按现有协议只结算
    /// 它自己的时间线。唤醒不重锚任何 provider 的排期——其他 provider 的下一拍
    /// 保持原样，由各自的 deadline driver 接管。
    func handleSystemWake() async {
        guard let token = refreshScheduler.beginExternalJob() else {
            pendingWakeup = true
            return
        }
        defer { refreshScheduler.endExternalJob(token) }

        // 睡眠期间可能跨过多个窗口边界；先用当前墙钟更新一次健康 UI，
        // 再安排下一个未来边界。Wakeup 是一次全局排他事务。
        sleepHealth.refreshNow()
        rescheduleHealthBoundary(updateEvaluationDate: true)
        let providerIDs = statuses
            .filter { shouldAutoRefresh(providerID: $0.id) }
            .map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for providerID in providerIDs {
                // 刻意不写 `@MainActor` 闭包属性：Swift 6.4 的 region isolation
                // 检查器处理不了 `@MainActor [捕获列表]` 这个组合，会报
                // "Please file a bug" 并中断整段检查。隔离由下面的
                // `await self.refreshScheduler.…` 调用点保证，语义与原来逐字相同。
                group.addTask { [self, providerID] in
                    guard await self.refreshScheduler.isCurrentJob(token) else { return }
                    await self.refreshScheduler.refreshForSystemWake(providerID)
                }
            }
        }
        guard refreshScheduler.isCurrentJob(token) else { return }
        await localUsage.triggerImmediateScanAll()
        guard refreshScheduler.isCurrentJob(token) else { return }
        startupReconcilePendingProviderIDs.removeAll()
        startupReconcileCompleted = true
    }

    /// 系统时区改变后重排本地窗口边界，并让本地日桶执行一次 full 重建；
    /// 之后恢复普通 dirty/rebase 路径。不触发 Provider 网络刷新。时区变化
    /// 会移动 UTC 偏移，事件归入哪个"日"可能改变，因此走 cold rebuild。
    func handleSystemClockOrTimeZoneChange() {
        rescheduleHealthBoundary(updateEvaluationDate: true)
        localUsage.invalidateForCalendarChange()
    }

    /// 纯系统时钟平移（不改时区）：所有日桶按事件时间戳 + 当前时区归日，
    /// 时钟平移不改变归桶，无需代价最高的 cold rebuild——只需重排健康边界，
    /// 并安排一次普通 reconcile 重切 today/7 天窗口（启动未完成时状态机自动
    /// 保留 full 兜底）。
    func handleSystemClockChange() {
        rescheduleHealthBoundary(updateEvaluationDate: true)
        localUsage.scheduleReconcile()
    }

    func refreshOne(providerID: String) async {
        guard let token = refreshScheduler.beginExternalJob() else {
            logDebug("AppState.refreshOne: 已有刷新事务进行中，忽略本次 Manual")
            return
        }
        defer { refreshScheduler.endExternalJob(token) }
        await refreshProviderFully(providerID: providerID, jobToken: token)
        guard refreshScheduler.isCurrentJob(token) else { return }
        await localUsage.triggerImmediateScanAll()
        guard refreshScheduler.isCurrentJob(token) else { return }
        startupReconcilePendingProviderIDs.removeAll()
        startupReconcileCompleted = true
        // 只重锚被刷新的 provider：刷新一张卡片不应把其他 provider 的下一拍
        // 推后一个完整间隔，也不应清掉它们的周期 full 计数与 reset 补刷新点。
        refreshScheduler.reanchorProvider(
            providerID,
            at: Date(),
            resetDatesByProvider: currentResetDatesByProvider()
        )
    }

    /// Provider 卡 7 天区块时间戳的点击入口：只补拍一次本地用量 reconcile，
    /// 不发额度请求、不重锚任何 provider 的排期。
    func triggerLocalUsageRescan() async {
        await localUsage.triggerImmediateScanAll()
    }

    /// Settings-page recovery action: rebuild Antigravity's local token cache
    /// under the same global gate as Manual/Wakeup/automatic refresh jobs.
    /// It intentionally does not issue a quota refresh or rescan other clients.
    /// 返回值透传编排层的真实结果：只有 hard 扫描确实启动并 settle 完成才算
    /// 成功，取消 / 被其他刷新事务抢占都如实报失败。
    @discardableResult
    func hardRefreshAntigravityLocalUsage() async -> Bool {
        guard let token = refreshScheduler.beginExternalJob() else {
            return false
        }
        defer { refreshScheduler.endExternalJob(token) }
        let completed = await localUsage.triggerAntigravityHardFull()
        return completed && refreshScheduler.isCurrentJob(token)
    }

    /// 显式刷新不能被正在进行的 background refresh 吞掉。
    private func refreshProviderFully(
        providerID: String,
        jobToken: RefreshJobToken
    ) async {
        if let activeMode = refreshScheduler.inFlightMode(for: providerID) {
            if activeMode == .background {
                manualRefreshGate.registerPending(providerID)
            }
            do {
                try await refreshScheduler.waitUntilNotInFlight(providerID)
            } catch {
                // R18: 取消与非取消错误都必须撤销本次 pending 登记，否则会泄漏并
                // 可能在 background 结束后误触发第二次 full refresh。
                if activeMode == .background {
                    manualRefreshGate.withdrawPending(providerID)
                }
                return
            }

            guard refreshScheduler.isCurrentJob(jobToken), !Task.isCancelled else {
                if activeMode == .background {
                    manualRefreshGate.withdrawPending(providerID)
                }
                return
            }

            // Set 的 remove 是 MainActor 上的单次 claim：多个等待者只会有一个
            // 真正补跑 full refresh，其余等待者自然返回。
            if manualRefreshGate.claimPendingFullRefresh(providerID) {
                guard refreshScheduler.isCurrentJob(jobToken) else { return }
                _ = await refreshScheduler.runRefresh(
                    providerID,
                    mode: .full,
                    satisfiesRegularDeadline: false
                )
                guard refreshScheduler.isCurrentJob(jobToken) else { return }
            }
            return
        }
        guard refreshScheduler.isCurrentJob(jobToken), !Task.isCancelled else { return }
        _ = await refreshScheduler.runRefresh(
            providerID,
            mode: .full,
            satisfiesRegularDeadline: false
        )
        guard refreshScheduler.isCurrentJob(jobToken) else { return }
    }

    private func currentResetDatesByProvider() -> [String: [Date]] {
        Dictionary(uniqueKeysWithValues: statuses.map { status in
            let dates = status.lastSuccess?.models
                .flatMap { [$0.intervalResetsAt, $0.weeklyResetsAt] }
                .compactMap { $0 } ?? []
            return (status.id, dates)
        })
    }

    func openConfigFile() {
        configStore.openInDefaultEditor()
    }

    func revealLogFile() {
        let url = URL(fileURLWithPath: AppLog.shared.logFilePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 配置变化监听

    private func setupConfigSubscription() {
        configStore.$config
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newConfig in
                guard let self else { return }
                logInfo("AppState: 检测到配置变更，开始重建状态并重新调度任务")
                self.configurationGeneration &+= 1
                self.authReadyCache.removeAll()
                self.authProber.reset()
                self.rebuildStatuses()
                self.rescheduleAll()
                // 运行期打开多机联动开关（start() 之后再启用）。
                if newConfig.effectiveSyncConfig.enabled, self.fleetSync == nil {
                    self.startFleetSync()
                }
                // 节假日数据源变更 → 重新走解析链并按需取数；源未变时内部 no-op。
                self.holidayCalendarService.handleConfigChange(
                    source: newConfig.effectiveHolidaySource
                )
            }
            .store(in: &cancellables)
    }

    func rebuildStatuses() {
        // GLM 活动套餐余额日志解析开关跟随配置（init 与每次配置变更都会走到这里）。
        localUsage.updateGlmBalanceLogParsing(
            enabled: configStore.config.providers[providerID(for: .glmCodingPlan)
                ?? ProviderKind.glmCodingPlan.providerID]?.parseZcodeBalanceLog ?? false
        )
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
            if d.kind.usesExternalAuth {
                authReadyCache[d.id] = (derived == .ready)
            } else {
                authReadyCache[d.id] = (pc?.usableAPIKey != nil)
            }
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
                // 复用上面已算出的 derived，不再走 deriveState 二次派生；
                // 折叠规则与 deriveState 一致：serviceOffline → notConfigured。
                switch derived {
                case .ready:
                    finalState = .ready
                case .notConfigured(let reason):
                    finalState = .notConfigured(reason: reason)
                case .serviceOffline(let message):
                    finalState = .notConfigured(reason: message)
                }
            }
            // 与 ProviderRefreshScheduler 共用同一份 effective interval；外部手改配置为
            // 小于 10 秒时，卡片新鲜度与实际调度都按 10 秒计算。
            let interval = Int(configStore.config.effectiveRefreshInterval(for: d.id))

            if case .notConfigured = finalState {
                // 触发器基线跟着状态一起清：重新配置后回到"首帧只建基线"语义。
                triggerStateStore.reset(providerID: d.id)
            }

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
                isScanningLocalUsage: preserved.isScanningLocalUsage,
                localUsageFreshness: preserved.localUsageFreshness
            )
            // client → quota 绑定注册表逐字跟随 config（P2 单一事实源）：共享账本
            // 切片（opencode / zcode 分片）的门控与 dsh 帧的归属解析都由
            // `status.clientBindings` 派生，不再有派生 bool（旧 mergeOpencodeUsage /
            // mergeZcodeUsage 已删除）。
            statusItem.clientBindings = configStore.config.clientBindings
            statusItem.antigravityLocalUsage = preserved.antigravityLocalUsage
            statusItem.minimaxLocalUsage = preserved.minimaxLocalUsage
            statusItem.glmLocalUsage = preserved.glmLocalUsage
            statusItem.opencodeUsage = preserved.opencodeUsage
            statusItem.dshUsage = preserved.dshUsage
            // GLM 高峰期窗口固定为官方口径（`GlmPeakWindow.zhipuDefault`，与
            // DeepSeek 同形状：北京时间 + Rule A 工作日），无 config 字段可调；
            // 旧配置残留的 peak* 键由 JSONDecoder 静默忽略。
            statusItem.glmPeakWindow = d.kind == .glmCodingPlan ? .zhipuDefault : nil
            // DeepSeek 高峰期窗口同理：官方固定口径（北京时间工作日 9–12 / 14–18，
            // 高峰永不含周末），无 config 字段可调，直接用默认窗口。
            statusItem.deepseekPeakWindow = d.kind == .deepseek
                ? .defaultWindow
                : nil
            return statusItem
        }
        // `ProviderStatus.isEnabled` is the effective value: a missing
        // provider config intentionally defaults to enabled.  Deriving from
        // the raw config dictionary would incorrectly stop default sources.
        localUsage.updateActiveSources(LocalUsageOrchestration.activeSources(for: statuses))
        logInfo("AppState: 派生 \(statuses.count) 个 status，其中 enabled=\(statuses.filter { $0.isConfigured }.count)")
        statusDidChange.send()
        updateGlobalRefreshingState()
        scheduleExternalAuthProbes()
        rescheduleHealthBoundary(updateEvaluationDate: true)
    }

    /// 取所有启用 Provider 的最近高峰窗口边界。GLM 与 DeepSeek 统一使用北京时间
    /// 日历（`PeakWindow.beijingCalendar`）；重复的绝对时刻通过 Set 自然合并。边界
    /// 是显示/UI deadline，不属于任何 Provider 的 regular/reset 网络刷新。
    private func nextHealthBoundary(after date: Date) -> Date? {
        var candidates = Set<Date>()
        for status in statuses where status.isEnabled {
            if let window = status.glmPeakWindow,
               case .peak(until: let boundary) = window.status(at: date, calendar: PeakWindow.beijingCalendar),
               boundary > date {
                candidates.insert(boundary)
            }
            if let window = status.deepseekPeakWindow,
               case .peak(until: let boundary) = window.status(at: date, calendar: PeakWindow.beijingCalendar),
               boundary > date {
                candidates.insert(boundary)
            }
            if let window = status.glmPeakWindow,
               case .offPeak(until: let boundary) = window.status(at: date, calendar: PeakWindow.beijingCalendar),
               boundary > date {
                candidates.insert(boundary)
            }
            if let window = status.deepseekPeakWindow,
               case .offPeak(until: let boundary) = window.status(at: date, calendar: PeakWindow.beijingCalendar),
               boundary > date {
                candidates.insert(boundary)
            }
        }
        // SleepHealthService 读取本机断言和 AC 电源配置，两者都可能在 App
        // 运行期间变化。复用 ProviderRefreshScheduler 的单一 deadline driver，
        // 避免重新引入一个无法统一取消/唤醒的常驻 Timer。
        candidates.insert(date.addingTimeInterval(5 * 60))
        return candidates.min()
    }

    private func rescheduleHealthBoundary(updateEvaluationDate: Bool, referenceDate: Date = Date()) {
        let current = referenceDate
        if updateEvaluationDate {
            healthEvaluationDate = current
        }
        refreshScheduler.scheduleHealthBoundary(at: nextHealthBoundary(after: current))
    }

    private func handleHealthBoundary(at boundary: Date) {
        // Scheduler 已消费并清除了旧 deadline；更新 UI 时间基准后，基于新的
        // 半开区间状态注册下一边界，保证同一边界只回调一次。
        // 使用 driver 实际到达的 deadline，避免墙钟在边界附近轻微倒退时重新
        // 注册同一个 `until` 并造成重复回调。
        sleepHealth.refreshNow()
        rescheduleHealthBoundary(
            updateEvaluationDate: true,
            referenceDate: max(Date(), boundary)
        )
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
    /// in-flight 标记与成败记录由 `ProviderRefreshScheduler.runRefresh` 统一负责
    /// （本方法是 scheduler 的 refreshHandler）。
    /// `internal` 便于并发刷新状态机做无网络回归测试；产品调用仍经 scheduler/公开刷新入口。
    @MainActor
    func refreshProviderDirectly(providerID: String, mode: RefreshMode) async -> ProviderRefreshOutcome {
        defer { updateGlobalRefreshingState() }
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
                    var summary = "    - \(m.modelName): primary=\(Formatters.formatQuotaPercent(m.intervalRemainingPercent))"
                    if m.hasWeeklyWindow {
                        summary += ", secondary=\(Formatters.formatQuotaPercent(m.weeklyRemainingPercent))"
                    }
                    logInfo(summary)
                } else {
                    logInfo("    - \(m.modelName): 5h=\(Formatters.formatQuotaPercent(m.intervalRemainingPercent)), 周=\(Formatters.formatQuotaPercent(m.weeklyRemainingPercent))")
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
            // 通知检测只对窗口类 provider 生效：DeepSeek 的余额口径被二值化为
            // 0/100，不具备窗口语义（余额触发器暂不接入）。previous 取持久化
            // 基线而非内存 lastSuccess——重启后仍能捕捉停机期间的事件；每次
            // 成功刷新后无条件回写基线（与是否配置触发器无关）。
            let quotaEvents: [QuotaEvent]
            if ProviderKind.windowedKinds.contains(descriptor.kind) {
                quotaEvents = QuotaEventDetector.detect(
                    current: info,
                    previousSnapshot: triggerStateStore.snapshot(for: providerID)
                )
                triggerStateStore.update(providerID: providerID, info: info)
            } else {
                quotaEvents = []
            }
            if !quotaEvents.isEmpty {
                let notifyConfig = configStore.config.providers[providerID]
                quotaUpdateNotifier.notify(
                    providerID: providerID,
                    providerName: statuses[newIdx].displayName,
                    events: quotaEvents,
                    channels: QuotaNotifyChannels(
                        intervalRestored: notifyConfig?.notifyIntervalRestored,
                        intervalExhausted: notifyConfig?.notifyIntervalExhausted,
                        weeklyRestored: notifyConfig?.notifyWeeklyRestored,
                        weeklyExhausted: notifyConfig?.notifyWeeklyExhausted
                    )
                )
            }
            persistedRefreshTimes[providerID] = info.fetchedAt
            persistRefreshTimes()
            if descriptor.kind == .antigravity {
                let after = statuses[newIdx].antigravityLocalUsage
                logDebug("[antigravity/refresh] AFTER mutate: status[\(newIdx)].antigravityLocalUsage=\(after.map { "\($0.sessionCount) sessions" } ?? "nil")")
            }
            lastRefreshAt = Date()

            if descriptor.kind == .antigravity {
                authProber.markAvailable(providerID)
            }
            let resetDates = info.models.flatMap { [$0.intervalResetsAt, $0.weeklyResetsAt] }.compactMap { $0 }
            refreshScheduler.scheduleMidCycleResetRefreshes(for: providerID, resetsAtDates: resetDates)
            return .completed(success: true)
        } catch {
            // 取消请求不能误判为失败：配置变更 / 停止刷新 / 窗口关闭时取消，
            // 不应设置 .failed、触发 auth probe；取消走 .deferred，不进入失败排期。
            // HTTPClient 已经 re-throw CancellationError / URLError.cancelled，
            // 这里在 catch 入口再守一道，确保任何取消路径都走 .deferred。
            // 统一 filter 在 `CancellationFilter`，与 LocalUsageScanRunner 共用。
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

    /// 批量修改 Provider 状态，仅在闭包返回 true 时赋值并触发统一广播。
    @MainActor
    @discardableResult
    func mutateStatuses(_ block: (inout [ProviderStatus]) -> Bool) -> Bool {
        var copy = statuses
        let changed = block(&copy)
        if changed {
            statuses = copy
            statusDidChange.send()
        }
        return changed
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
    /// `shouldAutoRefresh = true` → `refresh = deferred` 时仍保留任务，
    /// 但 scheduler 按正常 Interval 重试，避免离线 provider 形成死循环。
    private func shouldAutoRefresh(providerID: String) -> Bool {
        guard let pc = configStore.config.providers[providerID], pc.enabled else { return false }
        // rebuildStatuses 派生时已算过 auth 就绪结论（含 fetcher 构造 + auth stat），
        // 直接复用，避免主线程三重构造 fetcher。
        if let cached = authReadyCache[providerID] {
            // Antigravity 的本地服务可能在 LLM Monitor 之后才启动。
            // 探测到离线时仍需保留刷新任务，才能在服务稍后启动后自动恢复；
            // 否则 rescheduleAll() 会把它永久过滤掉，手动“刷新全部”也无法触发。
            if cached == false,
               descriptors.first(where: { $0.id == providerID })?.kind == .antigravity {
                logDebug("shouldAutoRefresh[\(providerID)]: 本地服务暂时离线，保留恢复重试")
                return true
            }
            return cached
        }
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
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? {
        guard let codexID = providerID(for: .codexChatGpt),
              let idx = statuses.firstIndex(where: { $0.id == codexID }),
              let pc = configStore.config.providers[codexID],
              pc.enabled else {
            return nil
        }
        let lastSuccess = statuses[idx].lastSuccess
        return (
            providerID: codexID,
            authPath: pc.authPath,
            model: lastSuccess?.models.first,
            fetchedAt: lastSuccess?.fetchedAt ?? Date(),
            generation: configurationGeneration
        )
    }

    /// codex 在 config.json 中配置的 authPath（~ 开头不在此展开，由
    /// CodexFetcher.codexHomeDirectory 按统一解析链处理）。provider 未在 config
    /// 中配置时返回 nil；不要求 enabled / lastSuccess —— readiness 仅做诊断，
    /// 门槛由 codexEnrichmentTarget() 的 config 派生守门负责。
    @MainActor
    func codexConfiguredAuthPath() -> String? {
        guard let codexID = providerID(for: .codexChatGpt) else { return nil }
        return configStore.config.providers[codexID]?.authPath
    }

    @MainActor
    func applyCodexUsageDetails(
        _ details: CodexUsageDetails?,
        providerID: String,
        fetchedAt: Date,
        configurationGeneration: Int
    ) {
        logDebug("[codex/detail] applyCodexUsageDetails: providerID=\(providerID), details is nil?=\(details == nil)")
        guard configurationGeneration == self.configurationGeneration else {
            logDebug("[codex/detail] apply aborted: configurationGeneration mismatch (\(configurationGeneration) != \(self.configurationGeneration))")
            return
        }
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }) else {
            logDebug("[codex/detail] apply aborted: providerID not found")
            return
        }

        var changed = false

        // Enrich 当前 state 持有的 QuotaInfo。LocalUsage reconcile 与额度刷新解耦后，details 的
        // 产出时机与 quota 更新时序无关：不再要求 fetchedAt 严格相等——扫描使用的
        // reset 时间来自数据层存量（可能有半拍滞后），下一次 Provider batch 后的
        // reconcile 自动对齐新窗口。
        // State 自身持有 QuotaInfo（.ok / .loading(lastSuccess:) / .failed(_, lastSuccess:)），
        // 只 enrich state 即可，single source of truth。
        switch statuses[idx].state {
        case .ok(let info):
            if info.codexUsageDetails != details {
                mutateStatus(at: idx) { $0.state = .ok(info.enriched(with: details)) }
                changed = true
            }
        case .failed(let message, let lastSuccess):
            if let last = lastSuccess, last.codexUsageDetails != details {
                mutateStatus(at: idx) {
                    $0.state = .failed(message: message, lastSuccess: last.enriched(with: details))
                }
                changed = true
            }
        case .loading(let lastSuccess):
            if let prev = lastSuccess, prev.codexUsageDetails != details {
                mutateStatus(at: idx) {
                    $0.state = .loading(lastSuccess: prev.enriched(with: details))
                }
                changed = true
            }
        case .notConfigured, .ready:
            logDebug("[codex/detail] active state is \(statuses[idx].state), no QuotaInfo to enrich")
        }

        if changed {
            logDebug("[codex/detail] apply succeeded!")
        } else {
            logDebug("[codex/detail] apply skipped: no changes")
        }
    }

    /// 把 provider 登记进 `ProviderRefreshScheduler`（单 Task 调度器，到期即并发
    /// 刷新，无独立 timer）；本地不再维护 timer state。
    private func scheduleRefresh(for providerID: String) {
        refreshScheduler.schedule(for: providerID)
    }

    @MainActor
    func setScanningState(_ isScanning: Bool, for providerID: String) {
        guard let idx = statuses.firstIndex(where: { $0.id == providerID }),
              statuses[idx].isScanningLocalUsage != isScanning else {
            return
        }
        // 走统一的 mutateStatus：copy → modify → assign + statusDidChange.send。
        mutateStatus(at: idx) { $0.isScanningLocalUsage = isScanning }
    }

    /// Project a scanner-owned freshness transition onto every card that
    /// consumes that source. Shared sources (DSH/OpenCode) therefore stay
    /// consistent without a global watcher/path registry.
    @MainActor
    func setLocalUsageFreshness(_ freshness: LocalUsageFreshness, for source: LocalUsageSource) {
        let affectedKinds: Set<ProviderKind>
        switch source {
        case .codex:
            affectedKinds = [.codexChatGpt]
        case .antigravity, .agy:
            affectedKinds = [.antigravity]
        case .minimaxCode:
            affectedKinds = [.minimaxTokenPlan]
        case .zcode:
            affectedKinds = Set(Self.zcodeConsumerKinds)
        case .dsh, .opencode:
            affectedKinds = Set(ProviderKind.allCases)
        }

        var copy = statuses
        var changed = false
        for idx in copy.indices where affectedKinds.contains(copy[idx].kind) {
            guard copy[idx].localUsageFreshness[source] != freshness else { continue }
            logDebug("[local-usage] \(copy[idx].id) source=\(source.rawValue) freshness=\(freshness.rawValue)")
            copy[idx].localUsageFreshness[source] = freshness
            changed = true
        }
        guard changed else { return }
        statuses = copy
        statusDidChange.send()
    }

    private func cancelAllRefreshTasks() {
        refreshScheduler.cancelAll()
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
}
