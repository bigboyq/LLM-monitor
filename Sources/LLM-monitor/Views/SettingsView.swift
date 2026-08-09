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
        case opencode

        static let generalID = "general"
        static let opencodeID = "opencode"

        var id: String {
            switch self {
            case .general: return Self.generalID
            case .provider(let d): return d.id
            case .opencode: return Self.opencodeID
            }
        }

        var displayTitle: String {
            switch self {
            case .general: return "常规"
            case .provider(let d): return d.settingsTabTitle ?? d.displayName
            case .opencode: return "OpenCode"
            }
        }

        var iconSystemName: String {
            switch self {
            case .general: return "gearshape"
            case .provider(let d): return d.iconSystemName
            case .opencode: return "terminal"
            }
        }

        var brandAsset: BrandLogoAsset? {
            switch self {
            case .general: return nil
            case .provider(let d): return .provider(d.kind)
            case .opencode: return .opencode
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "刷新节奏与应用启动行为"
            case .provider(let d): return d.settingsTabSubtitle ?? ""
            case .opencode: return "本地 token 用量数据源诊断（不显示在菜单栏）"
            }
        }
    }

    /// 全部 tab（`.general` + descriptors 派生的 provider tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    private var allTabs: [SettingsTab] {
        [.general] + descriptors.map { .provider($0) } + [.opencode]
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
                case .opencode:
                    opencodePane
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

            SettingsSection(title: "关于") {
                SettingsControlRow("LLM Monitor") {
                    Text("版本 \(AppMetadata.version)（\(AppMetadata.build)）")
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var opencodePane: some View {
        let snapshot = state.opencodeUsageSnapshot
        let providerIDs = snapshot?.byProvider.keys.sorted() ?? []

        return VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "数据源",
                footer: "Opencode 不是一个菜单栏 provider，而是共享的本地 token 账本。扫描 opencode.db 后，数据按 providerID 分片；四张卡分别通过自己的开关决定是否合并，minimax 本地能力分片仅作诊断冗余。\n\n**刷新时机**：Opencode 不挂自己的独立 timer，扫描跟随每个 consumer provider（minimax / Codex / Antigravity / GLM）主 quota 刷新成功时触发（应用启动也会主动扫一次）。实际刷新频率 ≈ min(各 consumer provider 的 refreshIntervalSeconds)。如需更密集的扫描，加快对应 provider 的刷新间隔即可。"
            ) {
                diagnosticRow(label: "数据库路径", value: snapshot?.dbPath ?? OpencodeUsageScanner.defaultDBURL.path)
                diagnosticRow(
                    label: "扫描状态",
                    value: snapshot == nil
                        ? "等待扫描或尚未发现数据库"
                        : "已扫描 · \(snapshot?.scannedAt.map(Formatters.formatAbsolute) ?? "unknown")"
                )
                diagnosticRow(
                    label: "刷新时机",
                    value: "跟随 4 张卡的 quota 刷新（minimax / Codex / Antigravity / GLM）"
                )
            }

            SettingsSection(title: "已发现的模型数据") {
                if providerIDs.isEmpty {
                    Text("尚未发现带 token 数据的 provider。请先使用 Opencode 产生一次 assistant 调用。")
                        .font(SettingsTypography.supporting)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providerIDs, id: \.self) { providerID in
                        if let usage = snapshot?.byProvider[providerID] {
                            opencodeProviderSummary(
                                providerID: providerID,
                                usage: usage,
                                models: snapshot?.modelsByProvider[providerID] ?? [],
                                scannedAt: snapshot?.scannedAt
                            )
                        }
                    }
                }
            }
        }
    }

    private func diagnosticRow(label: String, value: String) -> some View {
        SettingsControlRow(label, alignment: .firstTextBaseline) {
            Text(value)
                .font(SettingsTypography.metadataMonospaced)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 320, alignment: .trailing)
        }
    }

    private func opencodeProviderSummary(
        providerID: String,
        usage: OpencodeProviderUsage,
        models: [String],
        scannedAt: Date?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(providerID)
                    .font(SettingsTypography.rowEmphasis)
                    .monospaced()
                Spacer()
                Text("\(Formatters.formatGroupedInt(usage.roundCount)) rounds")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
            }
            Text(models.isEmpty ? "model unknown" : models.joined(separator: ", "))
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text("近 7 天：\(usage.dailyTokenUsage.count) 天")
                if usage.cost > 0 {
                    Text("成本：\(usage.cost, format: .number.precision(.fractionLength(2)))")
                }
            }
            .font(SettingsTypography.numericValue)
            .foregroundStyle(.tertiary)

            if let today = usage.today {
                Text("今日总计：\(Formatters.formatTokenCountCompact(today.totalTokens)) tokens（Input + Cache read + Reason + Output；不含 cache write）")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    tokenBreakdown(label: "Input", value: today.inputTokens)
                    tokenBreakdown(label: "Cache", value: today.cacheReadTokens)
                    tokenBreakdown(label: "Reason", value: today.reasoningTokens)
                    tokenBreakdown(label: "Output", value: today.outputTokens)
                }
                .font(SettingsTypography.numericValue)
                .foregroundStyle(.tertiary)
                if today.cacheWriteTokens > 0 {
                    tokenBreakdown(label: "Cache write（不计入总量）", value: today.cacheWriteTokens)
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("今日暂无 token 活动")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.tertiary)
            }

            if !usage.dailyTokenUsage.isEmpty {
                DisclosureGroup("最近 7 天 token 明细") {
                    SevenDayTokenUsageHoverView(
                        days: usage.dailyTokenUsage,
                        scannedAt: scannedAt,
                        isScanning: false
                    )
                    .padding(.top, 4)
                }
                .font(SettingsTypography.metadata)
            }
        }
        .padding(.vertical, 4)
    }

    private func tokenBreakdown(label: String, value: Int) -> some View {
        Text("\(label) \(Formatters.formatTokenCountCompact(value))")
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

            opencodeMergeSection(
                isOn: $minimaxMergeOpencode,
                source: "minimax-cn-coding-plan",
                footer: "关闭时只显示本地 Scanner；开启后，OpenCode 的 Input / Cache / Reason / Output / rounds / turns 会与本地数据逐项相加。OpenCode 的 minimax 本地能力账本不参与。"
            )

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

            opencodeMergeSection(
                isOn: $chatgptMergeOpencode,
                source: "openai",
                footer: "关闭时只显示 Codex / ChatGPT 本地 Scanner；开启后，OpenCode 的 openai 数据会逐项合并到 ChatGPT 卡片。"
            )

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

            opencodeMergeSection(
                isOn: $antigravityMergeOpencode,
                source: "antigravity / google / google-vertex",
                footer: "关闭时只显示 Antigravity 本地 Scanner；开启后，匹配到的 OpenCode Antigravity provider 数据逐项合并。"
            )

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

            opencodeMergeSection(
                isOn: $glmMergeOpencode,
                source: "zhipuai-coding-plan",
                footer: "GLM 卡同时读取本机 ZCode（~/.zcode/cli/db/db.sqlite，native 源）与可选的 OpenCode 数据；本开关只控制后者。默认开启（叠加 OpenCode）。"
            )

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

            opencodeMergeSection(
                isOn: $deepseekMergeOpencode,
                source: "deepseek",
                footer: "关闭时只显示 DeepSeek 余额；开启后，OpenCode 的 deepseek 模型 Token 数据会合并展示。"
            )

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

    private func opencodeMergeSection(
        isOn: Binding<Bool>,
        source: String,
        footer: String
    ) -> some View {
        SettingsSection(title: "OpenCode 数据合并", footer: footer) {
            SettingsToggleRow(label: "合并 OpenCode 数据", isOn: isOn)
            SettingsControlRow("数据来源") {
                Text(source)
                    .font(SettingsTypography.metadataMonospaced)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
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
        .frame(width: 320, alignment: .leading)
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

        // 缺失字段走兼容默认：GLM 保持原先的 OpenCode 数据源，其余 provider 默认关闭。
        minimaxMergeOpencode = false
        chatgptMergeOpencode = false
        antigravityMergeOpencode = false
        glmMergeOpencode = true

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

        deepseekMergeOpencode = false
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
