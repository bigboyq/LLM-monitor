import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum SettingsSaveTransactionError: LocalizedError, Equatable {
    case loginItemUpdateFailed(String)
    case configSaveFailed(String)
    case configSaveFailedAndLoginItemRolledBack(String)
    case configSaveFailedAndLoginItemRollbackFailed(
        configError: String,
        rollbackError: String
    )

    var errorDescription: String? {
        switch self {
        case .loginItemUpdateFailed(let message):
            return "配置尚未应用；无法更新开机自启动设置：\(message)"
        case .configSaveFailed(let message):
            return "配置保存失败；开机自启动设置未变更：\(message)"
        case .configSaveFailedAndLoginItemRolledBack(let message):
            return "配置保存失败，开机自启动设置已恢复：\(message)"
        case .configSaveFailedAndLoginItemRollbackFailed(
            let configError,
            let rollbackError
        ):
            return """
            配置保存失败（\(configError)），且无法恢复开机自启动设置（\(rollbackError)）。\
            请检查系统设置中的登录项状态。
            """
        }
    }
}

struct LoginItemUpdateOutcome: Equatable {
    let isEnabled: Bool
    let errorMessage: String?
    /// 注册已被系统接受，但仍需用户在系统设置中批准。
    let requiresApproval: Bool
}

/// 设置保存的事务边界：登录项先变更，配置随后落盘；配置失败时回滚登录项。
///
/// 依赖通过 closure 注入，视图只负责构造 AppConfig 草稿和展示最终错误。
@MainActor
enum SettingsSaveTransaction {
    static func execute(
        previousLaunchAtLogin: Bool,
        requestedLaunchAtLogin: Bool,
        updateLoginItem: (Bool) async -> LoginItemUpdateOutcome,
        saveConfig: () throws -> Void
    ) async throws {
        let shouldUpdateLoginItem = requestedLaunchAtLogin != previousLaunchAtLogin
        if shouldUpdateLoginItem {
            let update = await updateLoginItem(requestedLaunchAtLogin)
            let acceptedPendingApproval = requestedLaunchAtLogin && update.requiresApproval
            guard update.isEnabled == requestedLaunchAtLogin || acceptedPendingApproval else {
                throw SettingsSaveTransactionError.loginItemUpdateFailed(
                    update.errorMessage ?? "系统未接受状态变更"
                )
            }
        }

        do {
            try saveConfig()
        } catch {
            let configError = error.localizedDescription

            guard shouldUpdateLoginItem else {
                throw SettingsSaveTransactionError.configSaveFailed(configError)
            }

            let rollback = await updateLoginItem(previousLaunchAtLogin)
            guard rollback.isEnabled == previousLaunchAtLogin else {
                throw SettingsSaveTransactionError.configSaveFailedAndLoginItemRollbackFailed(
                    configError: configError,
                    rollbackError: rollback.errorMessage ?? "系统未恢复到保存前状态"
                )
            }

            throw SettingsSaveTransactionError.configSaveFailedAndLoginItemRolledBack(configError)
        }
    }
}

struct SettingsView: View {

    @ObservedObject var configStore: ConfigStore
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var state: AppState
    /// provider 注册元信息（id 由 descriptors 拿，不再硬编码）。
    let descriptors: [FetcherDescriptor]

    @State private var currentTab: SettingsTab = .general

    @State private var globalInterval: Int = 300
    @State private var launchAtLogin: Bool = false
    @State private var statusBarIconStyle: StatusBarIconStyle = .chartBar
    @State private var statusBarHealthDotEnabled: Bool = true

    @State private var minimaxEnabled: Bool = false
    @State private var minimaxInterval: Int = 0
    @State private var minimaxApiKey: String = ""
    @State private var showMinimaxKey: Bool = false
    @State private var minimaxMergeOpencode: Bool = false

    @State private var chatgptEnabled: Bool = false
    @State private var chatgptInterval: Int = 0
    @State private var chatgptAuthPath: String = ""
    @State private var chatgptMergeOpencode: Bool = false

    @State private var antigravityEnabled: Bool = false
    @State private var antigravityInterval: Int = 0
    @State private var antigravityMergeOpencode: Bool = false
    @State private var glmEnabled: Bool = false
    @State private var glmInterval: Int = 0
    @State private var glmApiKey: String = ""
    @State private var showGlmKey: Bool = false
    @State private var glmPeakStart: Int = GlmPeakWindow.zhipuDefault.startHour
    @State private var glmPeakEnd: Int = GlmPeakWindow.zhipuDefault.endHour
    @State private var glmPeakWeekdays: Bool = GlmPeakWindow.zhipuDefault.weekdaysOnly
    @State private var glmMergeOpencode: Bool = true

    @State private var deepseekEnabled: Bool = false
    @State private var deepseekInterval: Int = 0
    @State private var deepseekApiKey: String = ""
    @State private var showDeepseekKey: Bool = false
    @State private var deepseekMergeOpencode: Bool = false
    @State private var deepseekPeakWeekdays: Bool = DeepseekPeakWindow.defaultWindow.weekdaysOnly

    @State private var selectedClientID: String = ClientID.antigravity
    @State private var providerCardOrder: [String] = []

    @State private var isSaving: Bool = false
    @State private var saveErrorMessage: String?

    @Environment(\.dismiss) private var dismiss

    /// 侧栏 tab 模型。`.general` 是固定的"全局设置"；provider tab 从
    /// `descriptors` 派生（侧栏渲染时按 `descriptors` 顺序展开，标题/icon
    /// 都从 descriptor 拿），加新 provider 不用改这里。
    ///
    /// 当前 tab 选中态用 `SettingsTab` 表达 —— `.general` 跟具体 descriptor
    /// 一一对应。`Identifiable` 让侧栏 `ForEach` 走 `id` 区分，切换不触发
    /// 整列重渲染；选中态判断用 `currentTab.id == tab.id`。
    enum SettingsTab: Identifiable {
        case general
        case provider(FetcherDescriptor)
        case clients

        static let generalID = "general"
        static let clientsID = "clients"

        var id: String {
            switch self {
            case .general: return Self.generalID
            case .provider(let d): return d.id
            case .clients: return Self.clientsID
            }
        }

        var displayTitle: String {
            switch self {
            case .general: return "常规"
            case .provider(let d): return d.settingsTabTitle ?? d.displayName
            case .clients: return "客户端"
            }
        }

        var iconSystemName: String {
            switch self {
            case .general: return "gearshape"
            case .provider(let d): return d.iconSystemName
            case .clients: return "terminal"
            }
        }

        var brandAsset: BrandLogoAsset? {
            switch self {
            case .general: return nil
            case .provider(let d): return .provider(d.kind)
            case .clients: return nil
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "刷新节奏与应用启动行为"
            case .provider(let d): return d.settingsTabSubtitle ?? ""
            case .clients: return "本地客户端用量与 Provider 映射"
            }
        }
    }

    /// 全部 tab（`.general` + descriptors 派生的 provider tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    private var allTabs: [SettingsTab] {
        [.general] + sortedProviderDescriptors.map { .provider($0) } + [.clients]
    }

    private var sortedProviderDescriptors: [FetcherDescriptor] {
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
            loadCurrentConfig()
            loginItemService.refreshStatus()
        }
        .onReceive(configStore.$config.dropFirst()) { _ in
            // 外部编辑配置文件时，刷新设置页；保存过程中保留用户正在编辑的草稿。
            guard !isSaving else { return }
            loadCurrentConfig()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var sidebar: some View {
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
    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPaneHeader(tab: currentTab)

                switch currentTab {
                case .general:
                    generalPane
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

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
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

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "全局刷新间隔",
                footer: "没有设置独立频率的 Provider 将继承此刷新时间。"
            ) {
                SettingsControlRow("刷新频率", alignment: .top) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(globalInterval) },
                                set: { globalInterval = roundedInterval(from: $0) }
                            ),
                            in: 10...3600,
                            label: { EmptyView() },
                            minimumValueLabel: {
                                Text("10 秒").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                            },
                            maximumValueLabel: {
                                Text("1 小时").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                            }
                        )

                        Text("当前：\(Formatters.formatInterval(seconds: globalInterval))")
                            .font(SettingsTypography.numericValue)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 320)
                }
            }

            SettingsSection(title: "状态栏图标", footer: "右下角状态圆点：绿色表示额度健康，橙色表示预警，红色表示异常。") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsControlRow("图标主题") {
                        Picker("", selection: $statusBarIconStyle) {
                            ForEach(StatusBarIconStyle.allCases) { style in
                                Label(style.displayName, systemImage: style.systemImageName)
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160, alignment: .trailing)
                    }

                    SettingsToggleRow(label: "显示状态圆点", isOn: $statusBarHealthDotEnabled)
                }
            }

            SettingsSection(title: "开机自启动", footer: "在系统登录时自动后台运行 LLM Monitor。") {
                SettingsToggleRow(label: "开启开机自启动", isOn: $launchAtLogin)

                if let lastErrorMessage = loginItemService.lastErrorMessage, !lastErrorMessage.isEmpty {
                    Text(lastErrorMessage)
                        .font(SettingsTypography.status)
                        .foregroundStyle(.orange)
                } else if loginItemService.state == .requiresApproval {
                    Text("已提交登录项请求，请到系统设置 > 通用 > 登录项里批准")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.orange)
                }
            }

            SettingsSection(
                title: "主菜单 Provider 顺序",
                footer: "未配置时按 Provider 名称排序。这里只调整主菜单卡片；客户端和设置页保持字母排序。"
            ) {
                providerCardOrderEditor
            }

            SettingsSection(title: "关于") {
                SettingsControlRow("LLM Monitor") {
                    Text("版本 \(AppMetadata.version)（\(AppMetadata.build)）")
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providerCardOrderEditor: some View {
        let providers = providerDescriptorsInCardOrder
        return VStack(spacing: 0) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, descriptor in
                HStack(spacing: 8) {
                    BrandLogoView(asset: BrandLogoAsset.provider(descriptor.kind))
                    Text(descriptor.displayName)
                        .font(SettingsTypography.rowEmphasis)
                    Spacer()
                    Button {
                        moveProviderCard(from: index, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("上移")

                    Button {
                        moveProviderCard(from: index, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == providers.count - 1)
                    .help("下移")
                }
                .padding(.vertical, 6)

                if index < providers.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private var providerDescriptorsInCardOrder: [FetcherDescriptor] {
        DisplayOrder.ordered(
            descriptors,
            preferredIDs: providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )
    }

    private func providerDescriptorDisplayNameAscending(
        _ lhs: FetcherDescriptor,
        _ rhs: FetcherDescriptor
    ) -> Bool {
        let lhsName = lhs.settingsTabTitle ?? lhs.displayName
        let rhsName = rhs.settingsTabTitle ?? rhs.displayName
        let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private func moveProviderCard(from index: Int, offset: Int) {
        var order = providerDescriptorsInCardOrder.map { $0.kind.quotaProviderID }
        let destination = index + offset
        guard order.indices.contains(index), order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        providerCardOrder = order
    }

    private var clientsPane: some View {
        let clients = sortedClientDescriptors

        return VStack(alignment: .leading, spacing: 16) {
            clientTabBar(clients)

            if let client = clients.first(where: { $0.id == selectedClientID }) {
                let providers = clientProviderUsage(for: client.id)
                SettingsSection(
                    title: "已识别的 Provider",
                    footer: providers.isEmpty
                        ? "暂未发现这个客户端产生的本地 Token 数据。使用客户端完成一次模型调用后，重新扫描即可显示。"
                        : "仅显示最近扫描到实际 Token 活动的 Provider。展开行可查看总 Token、缓存命中率和按公开 API 单价估算的价值。"
                ) {
                    if providers.isEmpty {
                        emptyClientState(client)
                    } else {
                        ForEach(providers) { provider in
                            clientProviderDisclosure(provider)
                        }
                    }
                }
            }
        }
        .onAppear {
            if sortedClientDescriptors.contains(where: { $0.id == selectedClientID }) == false {
                selectedClientID = sortedClientDescriptors.first?.id ?? ClientID.antigravity
            }
        }
    }

    private var sortedClientDescriptors: [ClientDescriptor] {
        ClientDescriptor.all.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func clientTabBar(_ clients: [ClientDescriptor]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(clients) { client in
                    let selected = selectedClientID == client.id
                    let providerCount = clientProviderUsage(for: client.id).count
                    Button {
                        selectedClientID = client.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: client.iconSystemName)
                                .font(.system(size: 12, weight: .medium))
                            Text(client.displayName)
                                .font(SettingsTypography.metadata)
                            if providerCount > 0 {
                                Text("\(providerCount)")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12))
                                    )
                            }
                        }
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func clientProviderUsage(for clientID: String) -> [ClientProviderUsageSummary] {
        var rows: [ClientProviderUsageSummary] = []
        for status in state.statuses {
            let projection = status.usageProjection(for: status.lastSuccess)
            for contribution in projection.contributions {
                guard contribution.clientID == clientID, contribution.hasActivity else { continue }
                if clientID == ClientID.antigravity, status.kind == .antigravity {
                    rows.append(contentsOf: antigravityUsageRows(status: status, contribution: contribution))
                } else {
                    rows.append(
                        ClientProviderUsageSummary(
                            clientID: clientID,
                            quotaProviderID: status.kind.quotaProviderID,
                            providerName: status.displayName,
                            usageGroupID: status.kind.quotaProviderID,
                            dailyTokenUsage: contribution.dailyTokenUsage,
                            recentSamples: contribution.recentSamples,
                            scannedAt: contribution.scannedAt,
                            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                        )
                    )
                }
            }
        }
        return rows.sorted {
            if $0.providerName != $1.providerName {
                return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
            }
            return $0.usageGroupID < $1.usageGroupID
        }
    }

    /// Antigravity owns one quota account but can produce several billable model
    /// families. Split the settings rows using the model name recorded in each
    /// local sample so each row gets its own token totals and price estimate.
    private func antigravityUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        let groups: [AntigravityUsageGroup: [LocalTokenUsageSample]]
        if contribution.recentSamples.isEmpty {
            groups = [.other: []]
        } else {
            groups = Dictionary(grouping: contribution.recentSamples) {
                AntigravityUsageGroup.classify(modelName: $0.modelName)
            }
        }

        return groups.keys.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.rawValue < $1.rawValue
        }.map { group in
            let samples = groups[group] ?? []
            let daily = samples.isEmpty
                ? contribution.dailyTokenUsage
                : dailyUsage(for: samples, matching: contribution.dailyTokenUsage)
            return ClientProviderUsageSummary(
                clientID: ClientID.antigravity,
                quotaProviderID: status.kind.quotaProviderID,
                providerName: group.displayName,
                usageGroupID: group.rawValue,
                dailyTokenUsage: daily,
                recentSamples: samples,
                scannedAt: contribution.scannedAt,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
    }

    private func dailyUsage(
        for samples: [LocalTokenUsageSample],
        matching template: [UnifiedDailyTokenUsage]
    ) -> [UnifiedDailyTokenUsage] {
        let calendar = Calendar.current
        var byDay = Dictionary(
            uniqueKeysWithValues: template.map { day in
                (calendar.startOfDay(for: day.dayStart), UnifiedDailyTokenUsage(dayStart: day.dayStart))
            }
        )

        for usage in UnifiedTokenUsageAggregator.days(from: samples, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: usage.dayStart)
            byDay[dayStart] = byDay[dayStart].map { $0 + usage } ?? usage
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private func emptyClientState(_ client: ClientDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: client.iconSystemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("尚未识别到 \(client.displayName) 的 Token 用量")
                .font(SettingsTypography.rowEmphasis)
            Text(client.subtitle)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func clientProviderDisclosure(_ provider: ClientProviderUsageSummary) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                SevenDayTokenUsageHoverView(
                    days: provider.dailyTokenUsage,
                    scannedAt: provider.scannedAt,
                    isScanning: false,
                    priceByDay: provider.priceTextByDay
                )

                // 第 1 行：聚合指标（总 Token / 命中率 / 价值），放在一起做整体评估。
                HStack(alignment: .top, spacing: 16) {
                    usageMetric(label: "总 Token", value: Formatters.formatTokenCountCompact(provider.totalTokens))
                    usageMetric(label: "命中率", value: provider.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    usageMetric(label: "价值", value: costText(provider.costEstimate))
                }

                // 第 2 行：分项 Token 桶，让 cache / output / reason 的相对比例一眼可读。
                HStack(alignment: .top, spacing: 16) {
                    usageMetric(label: "Input", value: Formatters.formatTokenCountCompact(provider.inputTokens))
                    usageMetric(label: "Cache", value: Formatters.formatTokenCountCompact(provider.cacheReadTokens))
                    usageMetric(label: "Output", value: Formatters.formatTokenCountCompact(provider.outputTokens))
                    usageMetric(label: "Reason", value: Formatters.formatTokenCountCompact(provider.reasoningTokens))
                }

                if provider.unpricedModelUsage.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未定价模型")
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.orange)
                        ForEach(provider.unpricedModelUsage) { model in
                            Text("\(model.modelName) · \(Formatters.formatTokenCountCompact(model.totalTokens)) tokens · \(model.sampleCount) 次")
                                .font(SettingsTypography.metadata)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if provider.costEstimate.pricedModelNames.isEmpty == false {
                    Text("计价模型：\(provider.costEstimate.pricedModelNames.joined(separator: ", ")) · 价格目录更新于 \(ModelPricingCatalog.lastUpdated)")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
                if let scannedAt = provider.scannedAt {
                    Text("最近扫描：\(Formatters.formatAbsolute(scannedAt))")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Color.accentColor)
                Text(provider.providerName)
                    .font(SettingsTypography.rowEmphasis)
                Spacer()
                Text(Formatters.formatTokenCountCompact(provider.totalTokens) + " tokens")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
            }
        }
        .font(SettingsTypography.metadata)
    }

    private func usageMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
            Text(value)
                .font(SettingsTypography.numericValue)
        }
    }

    private func costText(_ estimate: ModelCostEstimate) -> String {
        guard let value = estimate.value, let currency = estimate.currency else {
            return "未定价"
        }
        return String(format: "%@%.2f", currency.symbol, value)
    }

    /// `providerPane` 派发：把 `ProviderKind` 路由到对应 provider 的设置 UI。
    /// 加新 provider：在 `FetcherDescriptor` 加一个 + 在 `LLMMonitorApp.makeDescriptors()`
    /// 注册，**这里** 加一个 `case` 写 pane view。`SettingsTab` 不用改。
    @ViewBuilder
    private func providerPane(for kind: ProviderKind) -> some View {
        switch kind {
        case .minimaxTokenPlan: minimaxPane
        case .codexChatGpt:     chatgptPane
        case .antigravity:      antigravityPane
        case .glmCodingPlan:    glmPane
        case .deepseek:         deepseekPane
        }
    }

    private var minimaxPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 minimax Token Plan 监测", isOn: $minimaxEnabled)
            }

            if minimaxEnabled {
                SettingsSection(title: "认证与刷新") {
                    SettingsControlRow("API Key") {
                        apiKeyField(text: $minimaxApiKey, isVisible: $showMinimaxKey)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    intervalSliderField(label: "独立刷新频率", value: $minimaxInterval)
                }
            }
        }
    }

    private var chatgptPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 ChatGPT Plan 监测", isOn: $chatgptEnabled)
            }

            if chatgptEnabled {
                SettingsSection(
                    title: "认证与刷新",
                    footer: "`authPath` 支持填写 `auth.json` 文件，或它所在目录；也可以直接点“选择…”。"
                ) {
                    SettingsControlRow("auth.json 路径") {
                        HStack(spacing: 8) {
                            TextField("", text: $chatgptAuthPath, prompt: Text("~/.codex/auth.json 或 ~/.codex/"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button("选择…") {
                                selectAuthFile()
                            }
                        }
                        .frame(width: 320)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    intervalSliderField(label: "独立刷新频率", value: $chatgptInterval)
                }
            }
        }
    }

    private var antigravityPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 Antigravity 监测", isOn: $antigravityEnabled)
            }

            if antigravityEnabled {
                SettingsSection(
                    title: "刷新频率",
                    footer: "Antigravity 走自动发现：扫描 `language_server`（IDE）与 `agy` / `antigravity-cli`（CLI）进程，复用它们的本地登录态，无需任何配置。"
                ) {
                    intervalSliderField(label: "独立刷新频率", value: $antigravityInterval)
                }
            }
        }
    }

    private var glmPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 GLM Coding Plan 监测", isOn: $glmEnabled)
            }

            if glmEnabled {
                SettingsSection(
                    title: "认证与刷新",
                    footer: "填写智谱 GLM Coding Plan 的 API Key（格式 `id.secret`，在 bigmodel.cn 套餐概览页新建）。该 Key 也是 Anthropic / OpenAI 协议接入用的同一个 Key。"
                ) {
                    SettingsControlRow("API Key") {
                        glmApiKeyField
                    }

                    Divider()
                        .padding(.vertical, 4)

                    intervalSliderField(label: "独立刷新频率", value: $glmInterval)
                }

                SettingsSection(
                    title: "高峰期提示",
                    footer: "高峰期内模型调用按基础积分扣费，非高峰期按 50% 抵扣（省一半）。按本机时区计算，卡片会显示距高峰期 / 高峰结束的倒计时。默认：周一–周五 14:00–18:00。"
                ) {
                    peakHourRow(label: "开始", value: $glmPeakStart, max: 22)
                    peakHourRow(label: "结束", value: $glmPeakEnd, min: glmPeakStart + 1)
                    Divider().padding(.vertical, 4)
                    SettingsToggleRow(label: "仅工作日（周一–周五）", isOn: $glmPeakWeekdays)
                }
            }
        }
    }

    private var deepseekPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 DeepSeek 监测", isOn: $deepseekEnabled)
            }

            if deepseekEnabled {
                SettingsSection(
                    title: "认证与刷新",
                    footer: "填写 DeepSeek 开放平台 (platform.deepseek.com) 生成的 API Key（格式 `sk-...`）。"
                ) {
                    SettingsControlRow("API Key") {
                        apiKeyField(text: $deepseekApiKey, isVisible: $showDeepseekKey)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    intervalSliderField(label: "独立刷新频率", value: $deepseekInterval)
                }

                SettingsSection(
                    title: "高峰期提示",
                    footer: "DeepSeek API 采用峰谷定价策略，高峰时段价格为平时价格的 2 倍（适用于所有计费项）。系统将自动换算北京时间并实时提示倒计时。高峰时段：北京时间工作日 9:00–12:00 和 14:00–18:00。开启「仅工作日」后，周六、周日全天按平价（1×）计费。"
                ) {
                    SettingsControlRow("高峰时段定义") {
                        Text("北京时间工作日 9:00–12:00, 14:00–18:00")
                            .font(SettingsTypography.numericValue)
                            .foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 4)
                    SettingsControlRow("高峰期价格") {
                        Text("2× 价格 (平时 1×)")
                            .font(SettingsTypography.numericValue)
                            .foregroundStyle(.red)
                    }
                    Divider().padding(.vertical, 4)
                    SettingsToggleRow(label: "仅工作日（周一–周五）", isOn: $deepseekPeakWeekdays)
                }
            }
        }
    }

    /// 高峰期小时选择行：Stepper 限定在 [min, max]，显示 "HH:00"。
    private func peakHourRow(
        label: String,
        value: Binding<Int>,
        min: Int = 0,
        max: Int = 23
    ) -> some View {
        SettingsControlRow(label) {
            Stepper(value: value, in: min...max) {
                Text(String(format: "%02d:00", value.wrappedValue))
                    .font(SettingsTypography.rowValueMonospaced)
            }
        }
    }

    private var glmApiKeyField: some View {
        HStack(spacing: 8) {
            Group {
                if showGlmKey {
                    TextField("", text: $glmApiKey, prompt: Text("xxxxxxxx.xxxxxxxxxxxxxxxx"))
                } else {
                    SecureField("", text: $glmApiKey, prompt: Text("xxxxxxxx.xxxxxxxxxxxxxxxx"))
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                showGlmKey.toggle()
            } label: {
                Image(systemName: showGlmKey ? "eye.slash" : "eye")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(showGlmKey ? "隐藏 API Key" : "显示 API Key")
        }
        .frame(width: 320, alignment: .leading)
    }

    private func intervalSliderField(label: String, value: Binding<Int>) -> some View {
        SettingsControlRow(label, alignment: .top) {
            VStack(alignment: .trailing, spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = roundedProviderInterval(from: $0) }
                    ),
                    in: 0...3600,
                    label: { EmptyView() },
                    minimumValueLabel: {
                        Text("继承 (0 秒)").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    },
                    maximumValueLabel: {
                        Text("1 小时").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    }
                )

                Text(value.wrappedValue == 0
                     ? "当前：继承全局（\(Formatters.formatInterval(seconds: globalInterval))）"
                     : "当前：\(Formatters.formatInterval(seconds: value.wrappedValue))")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320)
        }
        .padding(.vertical, 4)
    }

    private func apiKeyField(text: Binding<String>, isVisible: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if isVisible.wrappedValue {
                        TextField("", text: text, prompt: Text("sk-cp-..."))
                    } else {
                        SecureField("", text: text, prompt: Text("sk-cp-..."))
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(isVisible.wrappedValue ? "隐藏 API Key" : "显示 API Key")
            }
            // Q8: 检测误粘贴 'Bearer ' 前缀，给非阻断 soft warning；不阻止保存，
            // 不记录 key 到日志。未来 key 格式变化不会被这条规则阻止。
            if Self.hasBearerPrefix(text.wrappedValue) {
                Label("API Key 通常不需要 “Bearer ” 前缀，将按原值保存。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("若你是从 Authorization 头里复制的，去掉 “Bearer ” 前缀只保留 Key 本体通常更合适。")
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    /// Q8: 判断是否误粘贴了 `Bearer ` 前缀（不记录 key，仅布尔判定）。
    private static func hasBearerPrefix(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bearer ")
    }

    private func selectAuthFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            chatgptAuthPath = tildePath(for: url.path)
        }
    }

    private func loadCurrentConfig() {
        let config = configStore.config
        globalInterval = config.refreshIntervalSeconds
        launchAtLogin = loginItemService.isEnabled
        statusBarIconStyle = config.effectiveStatusBarIconStyle
        statusBarHealthDotEnabled = config.effectiveStatusBarHealthDotEnabled
        providerCardOrder = DisplayOrder.normalizedIDs(
            descriptors,
            preferredIDs: config.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )

        // OpenCode merge 状态从 `ProviderConfig.mergeOpencodeUsage` 读取；
        // schema v1 配置缺失该字段时走 `shouldMergeOpencodeUsage(for:)` 的兼容默认值
        // (GLM 默认真，其余默假)。`clientBindings[]` 与之同步，写回时由 saveAndApply
        // 同步更新两个字段。
        if let id = providerID(for: .minimaxTokenPlan), let minimax = config.providers[id] {
            minimaxEnabled = minimax.enabled
            minimaxApiKey = minimax.apiKey ?? ""
            minimaxInterval = minimax.refreshIntervalSeconds ?? 0
            minimaxMergeOpencode = minimax.shouldMergeOpencodeUsage(for: .minimaxTokenPlan)
        }

        if let id = providerID(for: .codexChatGpt), let chatgpt = config.providers[id] {
            chatgptEnabled = chatgpt.enabled
            chatgptAuthPath = chatgpt.authPath ?? ""
            chatgptInterval = chatgpt.refreshIntervalSeconds ?? 0
            chatgptMergeOpencode = chatgpt.shouldMergeOpencodeUsage(for: .codexChatGpt)
        }

        if let id = providerID(for: .antigravity), let antigravity = config.providers[id] {
            antigravityEnabled = antigravity.enabled
            antigravityInterval = antigravity.refreshIntervalSeconds ?? 0
            antigravityMergeOpencode = antigravity.shouldMergeOpencodeUsage(for: .antigravity)
        }

        if let id = providerID(for: .glmCodingPlan), let glm = config.providers[id] {
            glmEnabled = glm.enabled
            glmApiKey = glm.apiKey ?? ""
            glmInterval = glm.refreshIntervalSeconds ?? 0
            glmMergeOpencode = glm.shouldMergeOpencodeUsage(for: .glmCodingPlan)
            let loadedPeakStart = min(max(glm.peakStartHour ?? GlmPeakWindow.zhipuDefault.startHour, 0), 22)
            glmPeakStart = loadedPeakStart
            glmPeakEnd = min(
                max(glm.peakEndHour ?? GlmPeakWindow.zhipuDefault.endHour, loadedPeakStart + 1),
                23
            )
            glmPeakWeekdays = glm.peakWeekdaysOnly ?? GlmPeakWindow.zhipuDefault.weekdaysOnly
        }

        if let id = providerID(for: .deepseek), let deepseek = config.providers[id] {
            deepseekEnabled = deepseek.enabled
            deepseekApiKey = deepseek.apiKey ?? ""
            deepseekInterval = deepseek.refreshIntervalSeconds ?? 0
            deepseekMergeOpencode = deepseek.shouldMergeOpencodeUsage(for: .deepseek)
            deepseekPeakWeekdays = deepseek.deepseekPeakWeekdaysOnly ?? DeepseekPeakWindow.defaultWindow.weekdaysOnly
        }
    }

    private func saveAndApply() async throws {
        let previousLaunchAtLogin = loginItemService.isEnabled

        var config = configStore.config
        config.refreshIntervalSeconds = globalInterval
        config.statusBarIconStyle = statusBarIconStyle
        config.statusBarHealthDotEnabled = statusBarHealthDotEnabled
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

        if let id = providerID(for: .minimaxTokenPlan) {
            var minimax = config.providers[id] ?? ProviderConfig(enabled: false)
            minimax.enabled = minimaxEnabled
            minimax.apiKey = trimmedString(minimaxApiKey)
            minimax.refreshIntervalSeconds = providerRefreshInterval(from: minimaxInterval)
            minimax.mergeOpencodeUsage = storedOpencodeMergeValue(
                minimaxMergeOpencode,
                for: .minimaxTokenPlan
            )
            config.providers[id] = minimax
        }

        if let id = providerID(for: .codexChatGpt) {
            var chatgpt = config.providers[id] ?? ProviderConfig(enabled: false)
            chatgpt.enabled = chatgptEnabled
            chatgpt.authPath = trimmedString(chatgptAuthPath)
            chatgpt.refreshIntervalSeconds = providerRefreshInterval(from: chatgptInterval)
            chatgpt.mergeOpencodeUsage = storedOpencodeMergeValue(
                chatgptMergeOpencode,
                for: .codexChatGpt
            )
            config.providers[id] = chatgpt
        }

        if let id = providerID(for: .antigravity) {
            var antigravity = config.providers[id] ?? ProviderConfig(enabled: false)
            antigravity.enabled = antigravityEnabled
            antigravity.refreshIntervalSeconds = providerRefreshInterval(from: antigravityInterval)
            antigravity.mergeOpencodeUsage = storedOpencodeMergeValue(
                antigravityMergeOpencode,
                for: .antigravity
            )
            config.providers[id] = antigravity
        }

        if let id = providerID(for: .glmCodingPlan) {
            var glm = config.providers[id] ?? ProviderConfig(enabled: false)
            glm.enabled = glmEnabled
            glm.apiKey = trimmedString(glmApiKey)
            glm.refreshIntervalSeconds = providerRefreshInterval(from: glmInterval)
            glm.mergeOpencodeUsage = storedOpencodeMergeValue(
                glmMergeOpencode,
                for: .glmCodingPlan
            )
            // 与默认一致时写 nil，保持 config.json 干净
            let d = GlmPeakWindow.zhipuDefault
            // 先把结束时间钳到合法区间，避免用户先把开始调高导致 end ≤ start
            let clampedStart = min(max(glmPeakStart, 0), 22)
            let clampedEnd = min(max(glmPeakEnd, clampedStart + 1), 23)
            glm.peakStartHour = clampedStart == d.startHour ? nil : clampedStart
            glm.peakEndHour = clampedEnd == d.endHour ? nil : clampedEnd
            glm.peakWeekdaysOnly = glmPeakWeekdays == d.weekdaysOnly ? nil : glmPeakWeekdays
            config.providers[id] = glm
        }

        if let id = providerID(for: .deepseek) {
            var deepseek = config.providers[id] ?? ProviderConfig(enabled: false)
            deepseek.enabled = deepseekEnabled
            deepseek.apiKey = trimmedString(deepseekApiKey)
            deepseek.refreshIntervalSeconds = providerRefreshInterval(from: deepseekInterval)
            deepseek.mergeOpencodeUsage = storedOpencodeMergeValue(
                deepseekMergeOpencode,
                for: .deepseek
            )
            let ds = DeepseekPeakWindow.defaultWindow
            deepseek.deepseekPeakWeekdaysOnly = deepseekPeakWeekdays == ds.weekdaysOnly ? nil : deepseekPeakWeekdays
            config.providers[id] = deepseek
        }

        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.minimax,
            enabled: minimaxMergeOpencode
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            enabled: chatgptMergeOpencode
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.antigravity,
            enabled: antigravityMergeOpencode
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu,
            enabled: glmMergeOpencode
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek,
            enabled: deepseekMergeOpencode
        )

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: previousLaunchAtLogin,
            requestedLaunchAtLogin: launchAtLogin,
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
    }

    private func storedOpencodeMergeValue(_ value: Bool, for kind: ProviderKind) -> Bool? {
        let defaultValue = kind == .glmCodingPlan
        return value == defaultValue ? nil : value
    }

    /// 通过 descriptors 拿实际 provider id — 不再硬编码。
    private func providerID(for kind: ProviderKind) -> String? {
        descriptors.first(where: { $0.kind == kind })?.id
    }

    private func providerRefreshInterval(from value: Int) -> Int? {
        value == 0 ? nil : value
    }

    private func trimmedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func roundedInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(10, rounded))
    }

    private func roundedProviderInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(0, rounded))
    }

    private func tildePath(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix) {
            return "~/" + String(path.dropFirst(homePrefix.count))
        }
        return path
    }
}
