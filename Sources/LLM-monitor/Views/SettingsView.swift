import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum SettingsFormExternalUpdateAction: Equatable {
    case ignore
    case reload
    case askUser

    static func resolve(formChanged: Bool, isDirty: Bool) -> Self {
        guard formChanged else { return .ignore }
        return isDirty ? .askUser : .reload
    }
}

struct SettingsView: View {

    @ObservedObject var configStore: ConfigStore
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var state: AppState
    /// provider 注册元信息（id 由 descriptors 拿，不再硬编码）。
    let descriptors: [FetcherDescriptor]
    /// Sync pane 草稿由设置窗持有，切换 tab 时保留未成功写入的值与错误。
    @StateObject var syncDrafts: SettingsSyncDraftController

    @State var currentTab: SettingsTab = .general

    @State var draft: SettingsFormDraft = SettingsFormDraft()
    @State var baselineDraft: SettingsFormDraft = SettingsFormDraft()

    @State var launchAtLoginDraft = SettingsLoginItemDraft(baseline: false, draft: false)
    @State var notificationAuthorization: QuotaNotificationAuthorization = .unavailable
    @State var systemNotificationTestMessage: String?
    @State var dockPositionMessage: String?
    @State var showsEdgeDockHelp: Bool = false

    @State var showMinimaxKey: Bool = false
    @State var showChatgptAdminKey: Bool = false
    @State var isAntigravityHardFullRunning: Bool = false
    @State var antigravityHardFullMessage: String?
    @State var showGlmKey: Bool = false
    @State var showDeepseekKey: Bool = false

    @State var selectedClientID: String = ClientID.antigravity

    @State var showBarkDeviceKey: Bool = false
    @State var isSendingBarkTest: Bool = false
    @State var barkTestMessage: String?

    @State var pendingNotificationProviderID: String?
    @State var isSaving: Bool = false
    @State var loadedConfigSnapshot: AppConfig?
    @State var pendingExternalConfig: AppConfig?
    @State var showsExternalConfigConflict = false
    @State var showsDiscardConfirmation = false
    @State var saveErrorMessage: String?

    var isDirty: Bool {
        draft != baselineDraft || launchAtLoginDraft.hasLocalEdit
    }

    var chatgptMonthlyQuotaLimitError: String? {
        guard draft.chatgptEnabled, draft.chatgptAdminCreditsEnabled,
              Self.validMonthlyQuotaLimit(draft.chatgptMonthlyQuotaLimit) == nil else { return nil }
        return "请输入大于 0 的有限数字。"
    }

    static func validMonthlyQuotaLimit(_ rawValue: String) -> Double? {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    func refreshNotificationAuthorization() {
        Task {
            notificationAuthorization = await SystemQuotaUpdateNotifier.authorizationStatus()
        }
    }

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

    var generalTabs: [SettingsTab] {
        [.general, .interface, .notifications, .energy, .sync]
    }

    var providerTabs: [SettingsTab] {
        sortedProviderDescriptors.map { .provider($0) }
    }

    var clientTabs: [SettingsTab] {
        sortedClientDescriptors.map { .client($0) }
    }

    /// 全部 tab（`.general` / `.energy` + descriptors 派生的 provider tab + client tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    var allTabs: [SettingsTab] {
        generalTabs + providerTabs + clientTabs
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
            refreshNotificationAuthorization()
        }
        .onReceive(state.$pendingSettingsTab) { _ in
            consumePendingSettingsTab()
        }
        .onReceive(configStore.$config.dropFirst()) { newConfig in
            // 更新设置页草稿。两道闸门：
            //  - 自己正在保存 → 保留草稿（保存会广播一次 `config`）。
            //  - 变化仅在独立即时保存的 Sync 区或边缘窗位置 → 保留 General/provider 草稿。
            //    这两类变更不属于此表单；重载会无声丢弃用户尚未保存的编辑。
            guard !isSaving else { return }
            switch SettingsFormExternalUpdateAction.resolve(
                formChanged: hasFormRelevantChange(to: newConfig),
                isDirty: isDirty
            ) {
            case .ignore:
                return
            case .askUser:
                pendingExternalConfig = newConfig
                showsExternalConfigConflict = true
                return
            case .reload:
                break
            }
            // `@Published` 在 willSet 阶段发送新值，此时 configStore.config 仍可能是旧值。
            // 直接用 publisher 给出的配置重载，避免快照与草稿回退到上一版。
            loadCurrentConfig(from: newConfig)
        }
        .onReceive(loginItemService.$state) { newState in
            launchAtLoginDraft.sync(actual: newState == .enabled)
        }
        .onChange(of: currentTab.id) { _, tabID in
            if tabID == SettingsTab.notificationsID { refreshNotificationAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentTab.id == SettingsTab.notificationsID { refreshNotificationAuthorization() }
        }
        .onDisappear {
            NSApp.setActivationPolicy(MenuBarAppActivation.policy)
        }
        .confirmationDialog(
            "配置已在其他位置更改",
            isPresented: $showsExternalConfigConflict,
            titleVisibility: .visible
        ) {
            Button("重新载入配置", role: .destructive) {
                if let pendingExternalConfig { loadCurrentConfig(from: pendingExternalConfig) }
                self.pendingExternalConfig = nil
            }
            Button("保留当前表单") {
                if let pendingExternalConfig { loadedConfigSnapshot = pendingExternalConfig }
                self.pendingExternalConfig = nil
            }
        } message: {
            Text("重新载入会丢弃当前编辑。保留当前表单后保存，会以表单中的普通设置值为准；Sync 配置和边缘窗拖动位置仍保留各自的即时保存结果。")
        }
        .confirmationDialog(
            "放弃未保存的更改？",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("尚未保存的普通设置将丢弃；Sync 已即时保存的字段和边缘窗拖动位置不会撤销。")
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
                VStack(alignment: .leading, spacing: 0) {
                    sidebarSection(title: "通用", tabs: generalTabs, topSpacing: 4)
                    sidebarSection(title: "额度", tabs: providerTabs)
                    sidebarSection(title: "用量", tabs: clientTabs)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.72))
    }

    @ViewBuilder
    private func sidebarSection(title: String, tabs: [SettingsTab], topSpacing: CGFloat = 12) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, topSpacing)
                .padding(.bottom, 2)

            ForEach(tabs) { tab in
                sidebarTabRow(tab)
            }
        }
    }

    @ViewBuilder
    private func sidebarTabRow(_ tab: SettingsTab) -> some View {
        let isSelected = currentTab.id == tab.id
        Button {
            currentTab = tab
        } label: {
            HStack(spacing: 8) {
                if let brandAsset = tab.brandAsset {
                    BrandLogoView(asset: brandAsset)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: tab.iconSystemName)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }

                Text(tab.displayTitle)
                    .lineLimit(1)
            }
            .font(SettingsTypography.sidebarItem(isSelected: isSelected))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var detailContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsPaneHeader(tab: currentTab)
                        .id("settings-top")

                    switch currentTab {
                    case .general:
                        generalPane
                    case .interface, .notifications:
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
                    case .client(let c):
                        clientPane(for: c)
                    case .clients:
                        clientsPane
                    }
                }
                .padding(20)
            }
            .onChange(of: currentTab.id) { _, tabID in
                if tabID == SettingsTab.notificationsID,
                   let providerID = pendingNotificationProviderID {
                    withAnimation {
                        proxy.scrollTo("providerNotification.\(providerID)", anchor: .top)
                    }
                    pendingNotificationProviderID = nil
                } else {
                    proxy.scrollTo("settings-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var bottomActionBar: some View {
        HStack(spacing: 12) {
            if isDirty {
                Text("有未保存更改")
                    .font(SettingsTypography.status)
                    .foregroundStyle(.orange)
            }
            if pendingExternalConfig != nil {
                Button("处理外部配置变更…") { showsExternalConfigConflict = true }
                    .font(SettingsTypography.status)
            }
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
                if isDirty { showsDiscardConfirmation = true }
                else { dismiss() }
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
            .disabled(isSaving || !isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    func loadCurrentConfig(from publishedConfig: AppConfig? = nil) {
        let config = publishedConfig ?? configStore.config
        draft = SettingsFormDraft(from: config, descriptors: descriptors)
        baselineDraft = draft
        loadedConfigSnapshot = config
        barkTestMessage = nil
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

    static func resettingDockPosition(in config: AppConfig) -> AppConfig {
        var copy = config
        var dock = config.effectiveEdgeDockConfig
        dock.edge = EdgeDockConfig.default.edge
        dock.offset = EdgeDockConfig.default.offset
        dock.screenUUID = nil
        copy.edgeDock = dock == .default ? nil : dock
        return copy
    }

    func resetDockPosition() {
        do {
            try configStore.applyAndSave(Self.resettingDockPosition(in: configStore.config))
            dockPositionMessage = "边缘状态窗位置已恢复默认，并立即生效。"
        } catch {
            dockPositionMessage = "恢复位置失败：\(error.localizedDescription)"
        }
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
        if draft.chatgptEnabled, draft.chatgptAdminCreditsEnabled,
           Self.validMonthlyQuotaLimit(draft.chatgptMonthlyQuotaLimit) == nil {
            throw NSError(
                domain: "SettingsValidation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "赠金额度必须是大于 0 的有限数字。"]
            )
        }

        let actualLaunchAtLogin = loginItemService.isEnabled
        let requestedLaunchAtLogin = launchAtLoginDraft.requestedValue(actual: actualLaunchAtLogin)

        var config = configStore.config
        config.refreshIntervalSeconds = draft.globalInterval
        config.statusBarIconStyle = draft.statusBarIconStyle
        config.statusBarHealthDotEnabled = draft.statusBarHealthDotEnabled
        config.statusBarHealthColors = draft.statusBarHealthColors == .default
            ? nil
            : draft.statusBarHealthColors
        config.statusBarPinnedProvider = draft.statusBarPinnedProvider.isEmpty
            ? nil
            : draft.statusBarPinnedProvider
        config.appearance = draft.appearance == .auto ? nil : draft.appearance
        config.systemNotificationSoundEnabled = draft.systemNotificationSoundEnabled ? nil : false

        let existingEdgeDock = configStore.config.effectiveEdgeDockConfig
        let nextEdgeDock = EdgeDockConfig(
            mode: draft.edgeDockMode,
            edge: existingEdgeDock.edge,
            offset: existingEdgeDock.normalized.offset,
            screenUUID: existingEdgeDock.screenUUID,
            hideInFullscreen: draft.edgeDockHideInFullscreen,
            compactSize: draft.edgeDockCompactSize,
            independentRingColors: draft.edgeDockIndependentRingColors
        )
        let defaultEdgeDock = EdgeDockConfig.default
        config.edgeDock = (nextEdgeDock == defaultEdgeDock) ? nil : nextEdgeDock
        let defaultProviderOrder = descriptors
            .sorted(by: providerDescriptorDisplayNameAscending)
            .map { $0.kind.quotaProviderID }
        let effectiveProviderOrder = DisplayOrder.normalizedIDs(
            descriptors,
            preferredIDs: draft.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )
        config.providerCardOrder = effectiveProviderOrder == defaultProviderOrder
            ? nil
            : effectiveProviderOrder

        let trimmedHolidaySource = draft.holidaySource.trimmingCharacters(in: .whitespacesAndNewlines)
        config.holidaySource = trimmedHolidaySource == HolidayCalendar.defaultSourceURL
            ? nil
            : trimmedHolidaySource

        let trimmedBarkServer = trimmedString(draft.barkServerURL) ?? BarkConfig.defaultServerURL
        let trimmedBarkKey = trimmedString(draft.barkDeviceKey)
        let trimmedBarkSound = trimmedString(draft.barkSound)
        if draft.barkEnabled || trimmedBarkKey != nil {
            config.bark = BarkConfig(
                enabled: draft.barkEnabled,
                serverURL: trimmedBarkServer,
                deviceKey: trimmedBarkKey ?? "",
                sound: trimmedBarkSound,
                skipWhenAwakeAndUnlocked: draft.barkSkipWhenAwakeAndUnlocked ? true : nil,
                // 空 / 非数字 / <= 0 归一化为 nil：不落盘、推送不携带 ttl。
                ttl: BarkConfig.parseTTL(draft.barkTTL),
                group: trimmedString(draft.barkGroup)
            )
        } else {
            config.bark = nil
        }

        // 四类通知渠道：归一化逻辑收敛在 ProviderConfig.setNotifyChannel，
        // 与默认一致时写 nil，保持 config.json 干净。
        for kind in ProviderKind.windowedKinds {
            guard let id = providerID(for: kind) else { continue }
            var pc = config.providers[id] ?? ProviderConfig(enabled: false)
            let channels = draft.notifyChannels[id] ?? [:]
            for notifyKind in QuotaNotificationKind.allCases {
                if let channel = channels[notifyKind] {
                    pc.setNotifyChannel(channel, for: notifyKind)
                }
            }
            config.providers[id] = pc
        }

        if let id = providerID(for: .minimaxTokenPlan) {
            var minimax = config.providers[id] ?? ProviderConfig(enabled: false)
            minimax.enabled = draft.minimaxEnabled
            minimax.apiKey = trimmedString(draft.minimaxApiKey)
            minimax.refreshIntervalSeconds = providerRefreshInterval(from: draft.minimaxInterval)
            config.providers[id] = minimax
        }

        if let id = providerID(for: .codexChatGpt) {
            var chatgpt = config.providers[id] ?? ProviderConfig(enabled: false)
            chatgpt.enabled = draft.chatgptEnabled
            chatgpt.authPath = trimmedString(draft.chatgptAuthPath)
            chatgpt.refreshIntervalSeconds = providerRefreshInterval(from: draft.chatgptInterval)
            chatgpt.adminApiCreditsEnabled = draft.chatgptAdminCreditsEnabled
            chatgpt.adminApiKey = trimmedString(draft.chatgptAdminApiKey)
            chatgpt.adminBillingDay = draft.chatgptBillingDay
            chatgpt.adminBillingTime = Formatters.formatTimeOfDay(draft.chatgptBillingTime)
            if let limit = Self.validMonthlyQuotaLimit(draft.chatgptMonthlyQuotaLimit) {
                chatgpt.adminMonthlyQuotaLimit = limit
            }
            config.providers[id] = chatgpt
        }

        if let id = providerID(for: .antigravity) {
            var antigravity = config.providers[id] ?? ProviderConfig(enabled: false)
            antigravity.enabled = draft.antigravityEnabled
            antigravity.refreshIntervalSeconds = providerRefreshInterval(from: draft.antigravityInterval)
            config.providers[id] = antigravity
        }

        if let id = providerID(for: .glmCodingPlan) {
            var glm = config.providers[id] ?? ProviderConfig(enabled: false)
            glm.enabled = draft.glmEnabled
            glm.apiKey = trimmedString(draft.glmApiKey)
            glm.refreshIntervalSeconds = providerRefreshInterval(from: draft.glmInterval)
            glm.parseZcodePlan = draft.glmZcodePlanEnabled ? true : nil
            glm.parseZcodeBalanceLog = nil
            glm.notifyCampaign = (draft.glmZcodePlanEnabled && draft.glmNotifyCampaign != .none) ? draft.glmNotifyCampaign : nil
            config.providers[id] = glm
        }

        if let id = providerID(for: .deepseek) {
            var deepseek = config.providers[id] ?? ProviderConfig(enabled: false)
            deepseek.enabled = draft.deepseekEnabled
            deepseek.apiKey = trimmedString(draft.deepseekApiKey)
            deepseek.refreshIntervalSeconds = providerRefreshInterval(from: draft.deepseekInterval)
            config.providers[id] = deepseek
        }

        config.clientBindings = draft.clientBindings
        config.alerts = (draft.alertThresholds == .default) ? nil : draft.alertThresholds

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
            baselineDraft = draft
        } catch {
            // LoginItemService may have changed before config save failed and the transaction
            // rolled it back. Reflect the resulting actual status even if no publisher event
            // is delivered before the view handles this error.
            launchAtLoginDraft.syncToActual(actual: loginItemService.isEnabled)
            throw error
        }
    }

    static func defaultBillingTime(hour: Int = 0, minute: Int = 0) -> Date {
        var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comp.hour = hour
        comp.minute = minute
        comp.second = 0
        return Calendar.current.date(from: comp) ?? Date()
    }

    static func parseBillingTime(from timeString: String?) -> Date {
        guard let timeString else { return defaultBillingTime(hour: 0, minute: 0) }
        let parts = timeString.split(separator: ":")
        let hour = parts.count > 0 ? (Int(parts[0]) ?? 0) : 0
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return defaultBillingTime(hour: hour, minute: minute)
    }
}

/// 设置页 provider pane 里那枚「立即刷新」按钮的**数据形态**（路由 + 禁用
/// 决策，不含 SwiftUI 视图）。
///
/// 将刷新路由提成值类型，使设置页按钮的 provider id 与在飞禁用策略可独立验证：
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
        case .interface: return nil
        case .notifications: return nil
        case .energy: return nil
        case .sync: return nil
        case .provider(let d): return .provider(d.kind)
        case .client(let c): return c.id == ClientID.openCode ? .opencode : nil
        case .clients: return nil
        }
    }
}
