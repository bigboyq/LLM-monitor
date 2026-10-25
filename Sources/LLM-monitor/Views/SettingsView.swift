import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {

    @ObservedObject var configStore: ConfigStore
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var state: AppState
    /// provider 注册元信息（id 由 descriptors 拿，不再硬编码）。
    let descriptors: [FetcherDescriptor]
    /// Sync pane 草稿由设置窗持有，切换 tab 时保留未成功写入的值与错误。
    @StateObject var syncDrafts: SettingsSyncDraftController

    @State var currentTab: SettingsTab = .general

    @State var globalInterval: Int = 300
    @State var launchAtLoginDraft = SettingsLoginItemDraft(baseline: false, draft: false)
    @State var statusBarIconStyle: StatusBarIconStyle = .chartBar
    @State var statusBarHealthDotEnabled: Bool = true
    @State var statusBarHealthColors: StatusBarHealthColors = .default

    // 贴边方向**没有** @State：设置页不提供它（见下方保存处的注释），而拖拽会在
    // 设置窗口开着的时候改它——从 @State 写回就会把用户刚拖出来的位置抹掉。
    @State var edgeDockMode: EdgeDockMode = EdgeDockConfig.default.mode
    @State var edgeDockHideInFullscreen: Bool = EdgeDockConfig.default.hideInFullscreen
    @State var edgeDockCompactSize: EdgeDockCompactSize = EdgeDockConfig.default.compactSize
    @State var edgeDockIndependentRingColors: Bool = EdgeDockConfig.default.independentRingColors

    @State var minimaxEnabled: Bool = false
    @State var minimaxInterval: Int = 0
    @State var minimaxApiKey: String = ""
    @State var showMinimaxKey: Bool = false

    @State var chatgptEnabled: Bool = false
    @State var chatgptInterval: Int = 0
    @State var chatgptAuthPath: String = ""

    @State var antigravityEnabled: Bool = false
    @State var antigravityInterval: Int = 0
    @State var isAntigravityHardFullRunning: Bool = false
    @State var antigravityHardFullMessage: String?
    @State var glmEnabled: Bool = false
    @State var glmInterval: Int = 0
    @State var glmApiKey: String = ""
    @State var showGlmKey: Bool = false
    @State var glmBalanceLogParsing: Bool = false

    @State var deepseekEnabled: Bool = false
    @State var deepseekInterval: Int = 0
    @State var deepseekApiKey: String = ""
    @State var showDeepseekKey: Bool = false

    /// 节假日数据源草稿（常规 pane）。nil 配置展示为默认上游 URL；
    /// 保存时与默认一致写 nil、显式空串写 ""（仅内置快照），见 saveAndApply。
    @State var holidaySourceDraft: String = ""

    @State var selectedClientID: String = ClientID.antigravity
    @State var providerCardOrder: [String] = []

    @State var barkEnabled: Bool = false
    @State var barkServerURL: String = BarkConfig.defaultServerURL
    @State var barkDeviceKey: String = ""
    @State var barkSound: String = ""
    @State var barkGroup: String = ""
    @State var barkTTL: String = ""
    @State var barkSkipWhenAwakeAndUnlocked: Bool = false
    @State var showBarkDeviceKey: Bool = false
    @State var isSendingBarkTest: Bool = false
    @State var barkTestMessage: String?

    /// 有 5 小时 / 周额度窗口的 provider（ChatGPT、GLM）的四类通知渠道草稿。
    /// key = providerID，value = kind → 渠道；缺失的 kind 使用默认渠道。
    @State var notifyChannels: [String: [QuotaNotificationKind: QuotaNotifyChannel]] = [:]

    @State var isSaving: Bool = false
    /// 表单当前对应的那一版配置快照，只用于「这次变化与表单无关吗」的判据。
    @State var loadedConfigSnapshot: AppConfig?
    @State var saveErrorMessage: String?

    @Environment(\.dismiss) var dismiss

    @MainActor
    init(
        configStore: ConfigStore,
        loginItemService: LoginItemService,
        state: AppState,
        descriptors: [FetcherDescriptor],
        syncDrafts: SettingsSyncDraftController? = nil
    ) {
        self.configStore = configStore
        self.loginItemService = loginItemService
        self.state = state
        self.descriptors = descriptors
        _syncDrafts = StateObject(
            wrappedValue: syncDrafts ?? SettingsSyncDraftController(configStore: configStore)
        )
    }

    /// 全部 tab（`.general` / `.energy` + descriptors 派生的 provider tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    var allTabs: [SettingsTab] {
        [.general, .energy, .sync] + sortedProviderDescriptors.map { .provider($0) } + [.clients]
    }

    var sortedProviderDescriptors: [FetcherDescriptor] {
        descriptors.sorted(by: providerDescriptorDisplayNameAscending)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                detailContent
                Divider()
                bottomActionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            minWidth: 720, idealWidth: 760,
            minHeight: 480, idealHeight: 520
        )
        .background(SettingsWindowFocusBridge())
        .onAppear {
            loginItemService.refreshStatus()
            launchAtLoginDraft.syncToActual(actual: loginItemService.isEnabled)
            loadCurrentConfig()
            // 主面板 footer「节能」等入口可能在窗口创建前就置了跳转信号；
            // 出现时兜底消费一次，规避订阅时机竞态。
            consumePendingSettingsTab()
        }
        .onReceive(state.$pendingSettingsTab) { _ in
            consumePendingSettingsTab()
        }
        .onReceive(configStore.$config.dropFirst()) { newConfig in
            // 更新设置页草稿。两道闸门：
            //  - 自己正在保存 → 保留草稿（保存会广播一次 `config`）。
            //  - 变化仅在独立即时保存的 Sync 区或边缘窗位置 → 保留 General/provider 草稿。
            //    这两类变更不属于此表单；重载会无声丢弃用户尚未保存的编辑。
            guard !isSaving, hasFormRelevantChange(to: newConfig) else { return }
            // `@Published` 在 willSet 阶段发送新值，此时 configStore.config 仍可能是旧值。
            // 直接用 publisher 给出的配置重载，避免快照与草稿回退到上一版。
            loadCurrentConfig(from: newConfig)
        }
        .onReceive(loginItemService.$state) { newState in
            launchAtLoginDraft.sync(actual: newState == .enabled)
        }
        .onDisappear {
            NSApp.setActivationPolicy(MenuBarAppActivation.policy)
        }
    }

    /// 消费主面板的设置跳转信号：切到目标 tab 并清空。
    /// onAppear + onReceive 双兜底：信号可能在设置窗口尚未创建（订阅未挂上）
    /// 时就被置值，窗口出现后靠 onAppear 再消费一次。
    func consumePendingSettingsTab() {
        guard let pending = state.pendingSettingsTab else { return }
        currentTab = pending
        state.pendingSettingsTab = nil
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allTabs) { tab in
                        let isSelected = currentTab.id == tab.id
                        Button {
                            currentTab = tab
                        } label: {
                            HStack(spacing: 8) {
                                if let brandAsset = tab.brandAsset {
                                    BrandLogoView(asset: brandAsset)
                                } else {
                                    Image(systemName: tab.iconSystemName)
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(width: 20, height: 20)
                                }

                                Text(tab.displayTitle)
                            }
                            .font(SettingsTypography.sidebarItem(isSelected: isSelected))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.72))
    }

    @ViewBuilder
    var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPaneHeader(tab: currentTab)

                switch currentTab {
                case .general:
                    generalPane
                case .energy:
                    energyPane
                case .sync:
                    SettingsSyncPane(state: state, drafts: syncDrafts)
                case .provider(let d):
                    // 派发到对应 provider 的 pane view。`providerPane(for:)` 是
                    // kind 派发，加新 provider 只需在那加一个 case，**不要**在这里
                    // 改 `SettingsTab` 枚举。
                    providerPane(for: d.kind)
                case .clients:
                    clientsPane
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var bottomActionBar: some View {
        HStack(spacing: 12) {
            if syncDrafts.hasSaveErrors && currentTab.id != SettingsTab.syncID {
                Text("多机联动配置未保存")
                    .font(SettingsTypography.status)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("查看") { currentTab = .sync }
            }
            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(SettingsTypography.status)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button("保存并应用") {
                Task {
                    isSaving = true
                    saveErrorMessage = nil
                    do {
                        try await saveAndApply()
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                    isSaving = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    func loadCurrentConfig(from publishedConfig: AppConfig? = nil) {
        let config = publishedConfig ?? configStore.config
        globalInterval = config.refreshIntervalSeconds
        statusBarIconStyle = config.effectiveStatusBarIconStyle
        statusBarHealthDotEnabled = config.effectiveStatusBarHealthDotEnabled
        statusBarHealthColors = config.effectiveStatusBarHealthColors
        let edgeDock = config.effectiveEdgeDockConfig
        edgeDockMode = edgeDock.mode
        edgeDockHideInFullscreen = edgeDock.hideInFullscreen
        edgeDockCompactSize = edgeDock.compactSize
        edgeDockIndependentRingColors = edgeDock.independentRingColors
        barkEnabled = config.bark?.enabled ?? false
        barkServerURL = config.bark?.serverURL ?? BarkConfig.defaultServerURL
        barkDeviceKey = config.bark?.deviceKey ?? ""
        barkSound = config.bark?.sound ?? ""
        barkGroup = config.bark?.group ?? ""
        barkTTL = config.bark.map { $0.ttl > 0 ? String($0.ttl) : "" } ?? ""
        barkSkipWhenAwakeAndUnlocked = config.bark?.skipWhenAwakeAndUnlocked ?? false
        barkTestMessage = nil
        // 节假日数据源：缺省键在输入框里展示为默认上游 URL（保存时与默认一致
        // 写回 nil，保持 config.json 干净；显式空串 = 仅内置快照）。
        holidaySourceDraft = config.holidaySource ?? HolidayCalendar.defaultSourceURL

        notifyChannels = [:]
        for kind in ProviderKind.windowedKinds {
            guard let id = providerID(for: kind), let pc = config.providers[id] else { continue }
            notifyChannels[id] = [
                .intervalRestored: pc.notifyIntervalRestored ?? .system,
                .intervalExhausted: pc.notifyIntervalExhausted ?? .none,
                .weeklyRestored: pc.notifyWeeklyRestored ?? .system,
                .weeklyExhausted: pc.notifyWeeklyExhausted ?? .none,
            ]
        }
        providerCardOrder = DisplayOrder.normalizedIDs(
            descriptors,
            preferredIDs: config.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )

        // OpenCode merge 状态不再进入设置表单：设置页没有独立 Toggle，
        // `clientBindings[]` 是唯一事实源（schema v1 以下配置在解码时由
        // `legacyClientBindings` 迁移）。saveAndApply 只修改本表单真正编辑的字段，
        // merge 状态随 `configStore.config` 原样透传，手工编辑不会被保存回滚。
        if let id = providerID(for: .minimaxTokenPlan), let minimax = config.providers[id] {
            minimaxEnabled = minimax.enabled
            minimaxApiKey = minimax.apiKey ?? ""
            minimaxInterval = minimax.refreshIntervalSeconds ?? 0
        }

        if let id = providerID(for: .codexChatGpt), let chatgpt = config.providers[id] {
            chatgptEnabled = chatgpt.enabled
            chatgptAuthPath = chatgpt.authPath ?? ""
            chatgptInterval = chatgpt.refreshIntervalSeconds ?? 0
        }

        if let id = providerID(for: .antigravity), let antigravity = config.providers[id] {
            antigravityEnabled = antigravity.enabled
            antigravityInterval = antigravity.refreshIntervalSeconds ?? 0
        }

        if let id = providerID(for: .glmCodingPlan), let glm = config.providers[id] {
            glmEnabled = glm.enabled
            glmApiKey = glm.apiKey ?? ""
            glmInterval = glm.refreshIntervalSeconds ?? 0
            glmBalanceLogParsing = glm.parseZcodeBalanceLog ?? false
        }

        if let id = providerID(for: .deepseek), let deepseek = config.providers[id] {
            deepseekEnabled = deepseek.enabled
            deepseekApiKey = deepseek.apiKey ?? ""
            deepseekInterval = deepseek.refreshIntervalSeconds ?? 0
        }
        // 记下"表单当前对应的是哪一版配置"，供下面的重载判据用。
        loadedConfigSnapshot = config
    }

    /// 抹平不由常规设置表单管理的配置字段：Sync（独立即时保存）与边缘窗位置三兄弟。
    ///
    /// 其余字段仍整体比较，避免逐个枚举表单字段导致新设置项漏掉热重载。
    static func formRelevantProjection(of config: AppConfig) -> AppConfig {
        var copy = config
        // Sync pane 独立逐字段即时保存，由 SettingsSyncDraftController 管理草稿与错误；
        // 它的变化不得重载这里的 General/provider 表单。
        copy.sync = nil
        // Compare effective values so a first position-only write from `nil` to an explicit
        // default payload is still ignored; mode and other form-controlled fields remain.
        var dock = copy.effectiveEdgeDockConfig
        dock.edge = EdgeDockConfig.default.edge
        dock.offset = EdgeDockConfig.default.offset
        dock.screenUUID = nil
        copy.edgeDock = dock
        return copy
    }

    /// `old` → `new` 之间，常规设置表单负责的字段有没有变化？**纯函数**。
    ///
    /// 抽成 `static` 是因为它是全部的判断逻辑，而 `loadedConfigSnapshot` 活在
    /// `@State` 里——`@State` 的写入只在视图真正进入渲染层时才可靠，直接从
    /// 单元测试驱动 `loadCurrentConfig()` 写不进去，测到的会是快照为 nil 的分支。
    static func hasFormRelevantChange(from old: AppConfig, to new: AppConfig) -> Bool {
        formRelevantProjection(of: old) != formRelevantProjection(of: new)
    }

    /// 配置变了，但**变的不是表单关心的东西**吗？
    ///
    /// Sync pane 逐字段即时写 config，常规 General/provider 表单则仍有独立的保存事务；
    /// 若把 Sync 更新也当成常规表单变化，会无声丢弃尚未保存的刷新间隔/API key 草稿。
    /// 边缘窗拖拽也会写 config，但贴边方向、沿边位置和所在屏不是表单控件，故同样忽略。
    ///
    /// 没有快照（还没载入过）时一律判 true：宁可多刷一次，也不要在状态不明时
    /// 顶着陈旧表单不刷新。
    func hasFormRelevantChange(to newConfig: AppConfig) -> Bool {
        guard let old = loadedConfigSnapshot else { return true }
        return Self.hasFormRelevantChange(from: old, to: newConfig)
    }

    func saveAndApply() async throws {
        let actualLaunchAtLogin = loginItemService.isEnabled
        let requestedLaunchAtLogin = launchAtLoginDraft.requestedValue(actual: actualLaunchAtLogin)

        var config = configStore.config
        config.refreshIntervalSeconds = globalInterval
        config.statusBarIconStyle = statusBarIconStyle
        config.statusBarHealthDotEnabled = statusBarHealthDotEnabled
        config.statusBarHealthColors = statusBarHealthColors == .default
            ? nil
            : statusBarHealthColors
        // 边缘窗：只带形态与全屏隐藏这两个**设置页真的有控件**的字段；贴边方向、
        // 沿边位置、所在屏由拖拽实时写盘，一律在保存这一刻现读
        // `configStore.config.effectiveEdgeDockConfig`。
        //
        // 三者都必须是"现读"而不是"开窗时读进 @State 再写回"：dock 的拖拽随时可能
        // 改它们，而设置窗口并没有被阻塞（dock 是独立的 nonactivating panel，用户
        // 完全可以一边开着设置、一边把 dock 拖到另一条边）。`offset` / `screenUUID`
        // 本来就是现读的；`edge` 曾经用 @State，于是"开设置 → 拖 dock → 点保存"
        // 这一条会把刚拖出来的贴边方向悄悄退回——正是上面这句话要防的事。
        // 设置页没有贴边方向的 Picker（拖动才是唯一的决定方式），所以 `edge`
        // 根本没有 UI 消费者，@State 纯属多余。
        // 用 `effectiveEdgeDockConfig` 而不是裸的 `config.edgeDock`：后者是盘上的
        // 原值，手改成 `"offset": 42` 时不会被 `normalized` 拉回 [0, 1]，于是每次
        // 在设置页点保存都会把这个越界值原样写回去，而 dock 那边显示的是钳到 0.5 的
        // 结果——两者长期不一致。`loadCurrentConfig` 已经用的是这个入口，这里对齐。
        //
        // 下面这个**逐字段重建**必须把每一个有 UI 消费者的字段都显式写出来：
        // `EdgeDockConfig` 的 init 给了默认值，漏写一个不会报错、不会警告，只会在
        // 用户点保存的那一刻把这个字段重置成默认（`edge` 曾经就踩过这个前科）。
        let existingEdgeDock = configStore.config.effectiveEdgeDockConfig
        let nextEdgeDock = EdgeDockConfig(
            mode: edgeDockMode,
            edge: existingEdgeDock.edge,
            offset: existingEdgeDock.normalized.offset,
            screenUUID: existingEdgeDock.screenUUID,
            hideInFullscreen: edgeDockHideInFullscreen,
            compactSize: edgeDockCompactSize,
            independentRingColors: edgeDockIndependentRingColors
        )
        let defaultEdgeDock = EdgeDockConfig.default
        config.edgeDock = (nextEdgeDock == defaultEdgeDock) ? nil : nextEdgeDock
        let defaultProviderOrder = descriptors
            .sorted(by: providerDescriptorDisplayNameAscending)
            .map { $0.kind.quotaProviderID }
        let effectiveProviderOrder = DisplayOrder.normalizedIDs(
            descriptors,
            preferredIDs: providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )
        config.providerCardOrder = effectiveProviderOrder == defaultProviderOrder
            ? nil
            : effectiveProviderOrder

        // 节假日数据源：与默认上游一致写 nil（不落键，保持 config.json 干净）；
        // 显式空串原样写 ""（语义 = 只用内置快照、不联网）；其余 URL / 本地路径
        // 原样保存。
        let trimmedHolidaySource = holidaySourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        config.holidaySource = trimmedHolidaySource == HolidayCalendar.defaultSourceURL
            ? nil
            : trimmedHolidaySource

        let trimmedBarkServer = trimmedString(barkServerURL) ?? BarkConfig.defaultServerURL
        let trimmedBarkKey = trimmedString(barkDeviceKey)
        let trimmedBarkSound = trimmedString(barkSound)
        if barkEnabled || trimmedBarkKey != nil {
            config.bark = BarkConfig(
                enabled: barkEnabled,
                serverURL: trimmedBarkServer,
                deviceKey: trimmedBarkKey ?? "",
                sound: trimmedBarkSound,
                skipWhenAwakeAndUnlocked: barkSkipWhenAwakeAndUnlocked ? true : nil,
                // 空 / 非数字 / <= 0 归一化为 nil：不落盘、推送不携带 ttl。
                ttl: BarkConfig.parseTTL(barkTTL),
                group: trimmedString(barkGroup)
            )
        } else {
            config.bark = nil
        }

        // 四类通知渠道：归一化逻辑收敛在 ProviderConfig.setNotifyChannel，
        // 与默认一致时写 nil，保持 config.json 干净。
        for kind in ProviderKind.windowedKinds {
            guard let id = providerID(for: kind) else { continue }
            var pc = config.providers[id] ?? ProviderConfig(enabled: false)
            let channels = notifyChannels[id] ?? [:]
            for notifyKind in QuotaNotificationKind.allCases {
                if let channel = channels[notifyKind] {
                    pc.setNotifyChannel(channel, for: notifyKind)
                }
            }
            config.providers[id] = pc
        }

        if let id = providerID(for: .minimaxTokenPlan) {
            var minimax = config.providers[id] ?? ProviderConfig(enabled: false)
            minimax.enabled = minimaxEnabled
            minimax.apiKey = trimmedString(minimaxApiKey)
            minimax.refreshIntervalSeconds = providerRefreshInterval(from: minimaxInterval)
            config.providers[id] = minimax
        }

        if let id = providerID(for: .codexChatGpt) {
            var chatgpt = config.providers[id] ?? ProviderConfig(enabled: false)
            chatgpt.enabled = chatgptEnabled
            chatgpt.authPath = trimmedString(chatgptAuthPath)
            chatgpt.refreshIntervalSeconds = providerRefreshInterval(from: chatgptInterval)
            config.providers[id] = chatgpt
        }

        if let id = providerID(for: .antigravity) {
            var antigravity = config.providers[id] ?? ProviderConfig(enabled: false)
            antigravity.enabled = antigravityEnabled
            antigravity.refreshIntervalSeconds = providerRefreshInterval(from: antigravityInterval)
            config.providers[id] = antigravity
        }

        if let id = providerID(for: .glmCodingPlan) {
            var glm = config.providers[id] ?? ProviderConfig(enabled: false)
            glm.enabled = glmEnabled
            glm.apiKey = trimmedString(glmApiKey)
            glm.refreshIntervalSeconds = providerRefreshInterval(from: glmInterval)
            // 高峰窗口固定为官方口径，无 config 字段可写；旧版本残留的
            // peakStartHour / peakEndHour / peakWeekdaysOnly 键由 JSONDecoder
            // 静默忽略，保存时也不会再写回。
            // 关闭时写 nil（配置文件不落该字段），与「字段不存在 = 不解析」一致。
            glm.parseZcodeBalanceLog = glmBalanceLogParsing ? true : nil
            config.providers[id] = glm
        }

        if let id = providerID(for: .deepseek) {
            var deepseek = config.providers[id] ?? ProviderConfig(enabled: false)
            deepseek.enabled = deepseekEnabled
            deepseek.apiKey = trimmedString(deepseekApiKey)
            deepseek.refreshIntervalSeconds = providerRefreshInterval(from: deepseekInterval)
            config.providers[id] = deepseek
        }

        do {
            try await SettingsSaveTransaction.execute(
                previousLaunchAtLogin: actualLaunchAtLogin,
                requestedLaunchAtLogin: requestedLaunchAtLogin,
                updateLoginItem: { enabled in
                    await loginItemService.setEnabled(enabled)
                    return LoginItemUpdateOutcome(
                        isEnabled: loginItemService.isEnabled,
                        errorMessage: loginItemService.lastErrorMessage,
                        requiresApproval: loginItemService.state == .requiresApproval
                    )
                },
                saveConfig: {
                    try configStore.applyAndSave(config)
                }
            )
            launchAtLoginDraft.syncToActual(actual: loginItemService.isEnabled)
        } catch {
            // LoginItemService may have changed before config save failed and the transaction
            // rolled it back. Reflect the resulting actual status even if no publisher event
            // is delivered before the view handles this error.
            launchAtLoginDraft.syncToActual(actual: loginItemService.isEnabled)
            throw error
        }
    }
}

/// 设置页 provider pane 里那枚「立即刷新」按钮的**数据形态**（路由 + 禁用
/// 决策，不含 SwiftUI 视图）。
///
/// 提成值类型与菜单侧 `ProviderStatusStripView.RefreshMenuItem` 同一理由：
/// SwiftUI `Button` 没有可寻址的测试缝，断言只能落在喂给它的这份数据与
/// `perform` 的路由上——「按钮把哪个 providerID 交出去」「在飞时禁不禁用」
/// 都在这里被单测钉住，视图只负责把结果画出来。
struct SettingsProviderRefreshAction: Equatable, Sendable {
    /// 交给 `AppState.refreshOne(providerID:)` 的 provider id。
    let providerID: String
    /// 全局刷新事务在飞标志（`AppState.isRefreshJobActive`）原样传入。
    let isRefreshJobActive: Bool

    /// 禁用判定：只看全局在飞标志。
    ///
    /// **粒度是全局的，这是刻意的**：`isRefreshJobActive` 覆盖 quota fetch 与
    /// 本地 full reconcile，且不区分"是哪一个 provider 在刷"（refreshAll、
    /// 别的 provider 的单刷、Antigravity 硬重建都算在飞）。设置页拿不到
    /// per-provider 的在飞信号，与其猜，不如任意刷新事务在飞时把所有 pane 的
    /// 按钮一起置灰——语义诚实，且与菜单 header 刷新按钮、Antigravity 重建
    /// 按钮的禁用口径完全一致。
    var isDisabled: Bool { isRefreshJobActive }

    /// 悬停文案（入口语义的唯一说明，改动需同步对应测试）。
    var helpText: String { "立即刷新该 Provider" }

    /// 执行：把 providerID 原样交回宿主（`SettingsView.refreshProviderFromSettings`）。
    func perform(_ onRefresh: (String) -> Void) {
        onRefresh(providerID)
    }
}

/// 每个 provider pane「认证与刷新」区的小型「立即刷新」按钮（图标 + `.help`）。
///
/// 在飞时图标换成小号 ProgressView 并置灰——设置页的在飞标志是全局粒度（见
/// `SettingsProviderRefreshAction.isDisabled`），进行态因此也是全局的：任意
/// 刷新事务在飞时所有 pane 的按钮一起转。按钮层置灰是第一道防线，重复点击
/// 的正确性仍由 `refreshOne` 的事务闸门兜底（两层语义，见
/// `SettingsView.refreshProviderFromSettings`）。
struct SettingsProviderRefreshButton: View {
    let action: SettingsProviderRefreshAction
    var onRefresh: (String) -> Void

    var body: some View {
        Button {
            action.perform(onRefresh)
        } label: {
            if action.isRefreshJobActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(action.isDisabled)
        .help(action.helpText)
    }
}

/// `SettingsTab` 的视图侧呈现映射。
///
/// 枚举本体住在 Services（`AppState.pendingSettingsTab` 要用它，见
/// `Services/AppState.swift`），但 `BrandLogoAsset` 是 Views 的类型——把它留在
/// 枚举里就等于把 Services → Views 的反向依赖又请回来。呈现映射按类型扩展留在
/// 视图层，调用侧（`SettingsView` 侧栏与 `SettingsComponents`）写法不变。
extension SettingsTab {
    var brandAsset: BrandLogoAsset? {
        switch self {
        case .general: return nil
        case .energy: return nil
        case .sync: return nil
        case .provider(let d): return .provider(d.kind)
        case .clients: return nil
        }
    }
}
