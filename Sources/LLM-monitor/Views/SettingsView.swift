import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SettingsView: View {

    @ObservedObject var configStore: ConfigStore
    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var state: AppState
    /// provider 注册元信息（id 由 descriptors 拿，不再硬编码）。
    let descriptors: [FetcherDescriptor]

    @State var currentTab: SettingsTab = .general

    @State var globalInterval: Int = 300
    @State var launchAtLogin: Bool = false
    @State var statusBarIconStyle: StatusBarIconStyle = .chartBar
    @State var statusBarHealthDotEnabled: Bool = true
    @State var statusBarHealthColors: StatusBarHealthColors = .default

    @State var minimaxEnabled: Bool = false
    @State var minimaxInterval: Int = 0
    @State var minimaxApiKey: String = ""
    @State var showMinimaxKey: Bool = false

    @State var chatgptEnabled: Bool = false
    @State var chatgptInterval: Int = 0
    @State var chatgptAuthPath: String = ""

    @State var antigravityEnabled: Bool = false
    @State var antigravityInterval: Int = 0
    @State var glmEnabled: Bool = false
    @State var glmInterval: Int = 0
    @State var glmApiKey: String = ""
    @State var showGlmKey: Bool = false
    @State var glmPeakStart: Int = GlmPeakWindow.zhipuDefault.startHour
    @State var glmPeakEnd: Int = GlmPeakWindow.zhipuDefault.endHour
    @State var glmPeakWeekdays: Bool = GlmPeakWindow.zhipuDefault.weekdaysOnly
    @State var glmBalanceLogParsing: Bool = false

    @State var deepseekEnabled: Bool = false
    @State var deepseekInterval: Int = 0
    @State var deepseekApiKey: String = ""
    @State var showDeepseekKey: Bool = false

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
    @State var saveErrorMessage: String?

    @Environment(\.dismiss) var dismiss

    /// 侧栏 tab 模型。`.general` 是固定的"全局设置"；provider tab 从
    /// `descriptors` 派生（侧栏渲染时按 `descriptors` 顺序展开，标题/icon
    /// 都从 descriptor 拿），加新 provider 不用改这里。
    ///
    /// 当前 tab 选中态用 `SettingsTab` 表达 —— `.general` 跟具体 descriptor
    /// 一一对应。`Identifiable` 让侧栏 `ForEach` 走 `id` 区分，切换不触发
    /// 整列重渲染；选中态判断用 `currentTab.id == tab.id`。
    enum SettingsTab: Identifiable {
        case general
        case energy
        case provider(FetcherDescriptor)
        case clients

        static let generalID = "general"
        static let energyID = "energy"
        static let clientsID = "clients"

        var id: String {
            switch self {
            case .general: return Self.generalID
            case .energy: return Self.energyID
            case .provider(let d): return d.id
            case .clients: return Self.clientsID
            }
        }

        var displayTitle: String {
            switch self {
            case .general: return "常规"
            case .energy: return "节能"
            case .provider(let d): return d.settingsTabTitle ?? d.displayName
            case .clients: return "客户端"
            }
        }

        var iconSystemName: String {
            switch self {
            case .general: return "gearshape"
            case .energy: return "powersleep"
            case .provider(let d): return d.iconSystemName
            case .clients: return "terminal"
            }
        }

        var brandAsset: BrandLogoAsset? {
            switch self {
            case .general: return nil
            case .energy: return nil
            case .provider(let d): return .provider(d.kind)
            case .clients: return nil
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "刷新节奏与应用启动行为"
            case .energy: return "系统睡眠健康度与防止休眠"
            case .provider(let d): return d.settingsTabSubtitle ?? ""
            case .clients: return "本地客户端用量与 Provider 映射"
            }
        }
    }

    /// 全部 tab（`.general` / `.energy` + descriptors 派生的 provider tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    var allTabs: [SettingsTab] {
        [.general, .energy] + sortedProviderDescriptors.map { .provider($0) } + [.clients]
    }

    var sortedProviderDescriptors: [FetcherDescriptor] {
        descriptors.sorted(by: providerDescriptorDisplayNameAscending)
    }

    /// 「App 图标」选项的预览图：直接使用设计稿 SVG（与 App 实际图标同源），
    /// 不再用 .full 示例指标现生成；资源缺失或解析失败时回退到现生成逻辑。
    /// SwiftPM 会把 .copy 资源打平到 bundle Resources 根目录，与 BrandLogo 同款查找方式。
    static let quotaLogoPreviewImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "llm-quota-730-2-dark", withExtension: "svg") else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        // 设计稿固有尺寸为 1024×1024，归一到与其他选项预览相同的 22pt 画布，
        // 避免在 picker 里显得比其他图标大；SVG 为矢量，缩小后依然清晰。
        image.size = NSSize(width: 22, height: 22)
        return image
    }()

    /// 图标主题 picker 每行的预览图。
    static func previewImage(for style: StatusBarIconStyle) -> NSImage {
        if style == .quotaLogo, let preview = quotaLogoPreviewImage {
            return preview
        }
        return MenuBarLabel.composedMenuBarImage(
            iconStyle: style,
            health: nil,
            showsHealthDot: false
        )
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
            // 主面板 footer「节能」等入口可能在窗口创建前就置了跳转信号；
            // 出现时兜底消费一次，规避订阅时机竞态。
            consumePendingSettingsTab()
        }
        .onReceive(state.$pendingSettingsTab) { _ in
            consumePendingSettingsTab()
        }
        .onReceive(configStore.$config.dropFirst()) { _ in
            // 外部编辑配置文件时，刷新设置页；保存过程中保留用户正在编辑的草稿。
            guard !isSaving else { return }
            loadCurrentConfig()
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

    var generalPane: some View {
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
                    .frame(width: SettingsLayout.standardControlWidth)
                }
            }

            SettingsSection(title: "状态栏图标", footer: "可自定义正常、预警、异常三种状态颜色；系统图标使用状态圆点。App 图标为经典双环水位样式：外环周额度、内环 5 小时额度（实线充盈到最低剩余量、虚线延伸到平均值，逆时针绘制），中心水位映射 5 小时最低剩余与警报颜色。Icon Duo 为额度仪表盘：左右弧线显示 5 小时与周额度，中心扇形按最低剩余比例动态显示 0～360°，底部三个套餐状态点与顶部节能状态圆点。") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsControlRow("图标主题") {
                        Picker("", selection: $statusBarIconStyle) {
                            ForEach(StatusBarIconStyle.allCases) { style in
                                HStack(spacing: 8) {
                                    Image(nsImage: Self.previewImage(for: style))
                                    .renderingMode(.original)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 18, height: 18)

                                    Text(style.displayName)
                                }
                                    .tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                    }

                    SettingsToggleRow(label: "显示状态圆点", isOn: $statusBarHealthDotEnabled)

                    SettingsControlRow("正常颜色") {
                        ColorPicker(
                            "",
                            selection: statusBarColorBinding(for: \.healthyHex),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }

                    SettingsControlRow("预警颜色") {
                        ColorPicker(
                            "",
                            selection: statusBarColorBinding(for: \.warningHex),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }

                    SettingsControlRow("异常颜色") {
                        ColorPicker(
                            "",
                            selection: statusBarColorBinding(for: \.criticalHex),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }
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
                title: "Bark 推送",
                footer: "按各 Provider 的通知配置，把 5 小时 / 周额度的恢复与耗尽事件推送到 iPhone。服务端默认官方 api.day.app，也可填自建地址；Device Key 从 Bark App 复制。保存后生效。"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsToggleRow(label: "启用 Bark 推送", isOn: $barkEnabled)

                    SettingsControlRow("服务端地址") {
                        TextField(
                            "",
                            text: $barkServerURL,
                            prompt: Text(BarkConfig.defaultServerURL)
                        )
                        .frame(width: SettingsLayout.standardControlWidth)
                        .disabled(!barkEnabled)
                    }

                    SettingsControlRow("Device Key") {
                        // 与 API Key 同级的推送凭证，用掩码输入 + 显示开关。
                        secretField(text: $barkDeviceKey, isVisible: $showBarkDeviceKey, prompt: "从 Bark App 复制")
                    }

                    SettingsControlRow("铃声（可选）") {
                        TextField("", text: $barkSound, prompt: Text("默认"))
                            .frame(width: SettingsLayout.standardControlWidth)
                            .disabled(!barkEnabled)
                    }

                    SettingsControlRow("分组（可选）") {
                        TextField("", text: $barkGroup, prompt: Text(BarkConfig.defaultGroup))
                            .frame(width: SettingsLayout.standardControlWidth)
                            .disabled(!barkEnabled)
                    }

                    SettingsControlRow("消息有效期 TTL（秒，可选）") {
                        TextField("", text: $barkTTL, prompt: Text("0 = 不过期"))
                            .frame(width: SettingsLayout.standardControlWidth)
                            .disabled(!barkEnabled)
                    }

                    SettingsToggleRow(
                        label: "人在电脑前时跳过推送",
                        isOn: $barkSkipWhenAwakeAndUnlocked
                    )
                    .disabled(!barkEnabled)

                    HStack(spacing: 12) {
                        Button("发送测试推送") {
                            sendBarkTest()
                        }
                        .disabled(!barkEnabled || isSendingBarkTest)

                        if let barkTestMessage {
                            Text(barkTestMessage)
                                .font(SettingsTypography.status)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
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

    var providerCardOrderEditor: some View {
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

    var providerDescriptorsInCardOrder: [FetcherDescriptor] {
        DisplayOrder.ordered(
            descriptors,
            preferredIDs: providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: providerDescriptorDisplayNameAscending
        )
    }

    func providerDescriptorDisplayNameAscending(
        _ lhs: FetcherDescriptor,
        _ rhs: FetcherDescriptor
    ) -> Bool {
        let lhsName = lhs.settingsTabTitle ?? lhs.displayName
        let rhsName = rhs.settingsTabTitle ?? rhs.displayName
        let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    func moveProviderCard(from index: Int, offset: Int) {
        var order = providerDescriptorsInCardOrder.map { $0.kind.quotaProviderID }
        let destination = index + offset
        guard order.indices.contains(index), order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        providerCardOrder = order
    }

    /// `providerPane` 派发：把 `ProviderKind` 路由到对应 provider 的设置 UI。
    /// 加新 provider：在 `FetcherDescriptor` 加一个 + 在 `LLMMonitorApp.makeDescriptors()`
    /// 注册，**这里** 加一个 `case` 写 pane view。`SettingsTab` 不用改。
    @ViewBuilder
    func providerPane(for kind: ProviderKind) -> some View {
        switch kind {
        case .minimaxTokenPlan: minimaxPane
        case .codexChatGpt:     chatgptPane
        case .antigravity:      antigravityPane
        case .glmCodingPlan:    glmPane
        case .deepseek:         deepseekPane
        }
    }

    var minimaxPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 minimax Token Plan 监测", isOn: $minimaxEnabled)
            }

            if minimaxEnabled {
                notifySection(providerID: providerID(for: .minimaxTokenPlan) ?? "")

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

    var chatgptPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 ChatGPT Plan 监测", isOn: $chatgptEnabled)
            }

            if chatgptEnabled {
                notifySection(providerID: providerID(for: .codexChatGpt) ?? "")

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
                        .frame(width: SettingsLayout.standardControlWidth)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    intervalSliderField(label: "独立刷新频率", value: $chatgptInterval)
                }
            }
        }
    }

    var antigravityPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 Antigravity 监测", isOn: $antigravityEnabled)
            }

            if antigravityEnabled {
                notifySection(providerID: providerID(for: .antigravity) ?? "")

                SettingsSection(
                    title: "刷新频率",
                    footer: "Antigravity 走自动发现：扫描 `language_server`（IDE）与 `agy` / `antigravity-cli`（CLI）进程，复用它们的本地登录态，无需任何配置。"
                ) {
                    intervalSliderField(label: "独立刷新频率", value: $antigravityInterval)
                }
            }
        }
    }

    var glmPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 GLM Coding Plan 监测", isOn: $glmEnabled)
            }

            if glmEnabled {
                notifySection(providerID: providerID(for: .glmCodingPlan) ?? "")

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

                SettingsSection(
                    title: "活动套餐余额",
                    footer: "解析 ZCode 本地日志（~/.zcode/v2/logs）中活动套餐（如周末体验套餐）的余额轮询记录，在 GLM 卡片显示用量 / 剩余 / 过期时间。只读取本地文件，不发起网络请求；ZCode 未运行时展示最近一次快照。默认关闭。"
                ) {
                    SettingsToggleRow(label: "解析活动套餐余额日志", isOn: $glmBalanceLogParsing)
                }
            }
        }
    }

    var deepseekPane: some View {
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
                    footer: "DeepSeek API 采用峰谷定价策略，高峰价格为平价（1×）的 2 倍（适用于所有计费项）。系统将自动换算北京时间并实时提示倒计时。高峰时段为北京时间工作日 9:00–12:00 和 14:00–18:00，周六、周日全天平价（1×）。"
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
                }
            }
        }
    }

    /// 四类额度事件的通知渠道配置（ChatGPT / GLM 等 5 小时 + 周额度 provider）。
    func notifySection(providerID: String) -> some View {
        SettingsSection(
            title: "通知配置",
            footer: "5 小时 / 周额度恢复或耗尽时的提醒方式。Bark 推送需要在「常规」里启用并配置 Bark。"
        ) {
            ForEach(QuotaNotificationKind.allCases) { kind in
                SettingsControlRow(kind.displayName) {
                    Picker("", selection: notifyChannelBinding(providerID: providerID, kind: kind)) {
                        ForEach(QuotaNotifyChannel.allCases) { channel in
                            Text(channel.displayName).tag(channel)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                }
            }
        }
    }

    private func notifyChannelBinding(
        providerID: String,
        kind: QuotaNotificationKind
    ) -> Binding<QuotaNotifyChannel> {
        Binding(
            get: {
                notifyChannels[providerID]?[kind]
                    ?? QuotaNotifyChannels().channel(for: kind)
            },
            set: { newValue in
                var entry = notifyChannels[providerID] ?? [:]
                entry[kind] = newValue
                notifyChannels[providerID] = entry
            }
        )
    }

    /// 高峰期小时选择行：Stepper 限定在 [min, max]，显示 "HH:00"。
    func peakHourRow(
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

    var glmApiKeyField: some View {
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
        .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
    }

    func intervalSliderField(label: String, value: Binding<Int>) -> some View {
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
            .frame(width: SettingsLayout.standardControlWidth)
        }
        .padding(.vertical, 4)
    }

    /// 通用掩码输入框（SecureField + 显示开关），用于 Device Key 等推送凭证。
    func secretField(text: Binding<String>, isVisible: Binding<Bool>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if isVisible.wrappedValue {
                    TextField("", text: text, prompt: Text(prompt))
                } else {
                    SecureField("", text: text, prompt: Text(prompt))
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
            .help(isVisible.wrappedValue ? "隐藏" : "显示")
        }
        .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
    }

    func apiKeyField(text: Binding<String>, isVisible: Binding<Bool>) -> some View {
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
        .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
    }

    /// Q8: 判断是否误粘贴了 `Bearer ` 前缀（不记录 key，仅布尔判定）。
    private static func hasBearerPrefix(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bearer ")
    }

    func selectAuthFile() {
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

    func loadCurrentConfig() {
        let config = configStore.config
        globalInterval = config.refreshIntervalSeconds
        launchAtLogin = loginItemService.isEnabled
        statusBarIconStyle = config.effectiveStatusBarIconStyle
        statusBarHealthDotEnabled = config.effectiveStatusBarHealthDotEnabled
        statusBarHealthColors = config.effectiveStatusBarHealthColors
        barkEnabled = config.bark?.enabled ?? false
        barkServerURL = config.bark?.serverURL ?? BarkConfig.defaultServerURL
        barkDeviceKey = config.bark?.deviceKey ?? ""
        barkSound = config.bark?.sound ?? ""
        barkGroup = config.bark?.group ?? ""
        barkTTL = config.bark.map { $0.ttl > 0 ? String($0.ttl) : "" } ?? ""
        barkSkipWhenAwakeAndUnlocked = config.bark?.skipWhenAwakeAndUnlocked ?? false
        barkTestMessage = nil

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
            let loadedPeakStart = min(max(glm.peakStartHour ?? GlmPeakWindow.zhipuDefault.startHour, 0), 22)
            glmPeakStart = loadedPeakStart
            glmPeakEnd = min(
                max(glm.peakEndHour ?? GlmPeakWindow.zhipuDefault.endHour, loadedPeakStart + 1),
                23
            )
            glmPeakWeekdays = glm.peakWeekdaysOnly ?? GlmPeakWindow.zhipuDefault.weekdaysOnly
            glmBalanceLogParsing = glm.parseZcodeBalanceLog ?? false
        }

        if let id = providerID(for: .deepseek), let deepseek = config.providers[id] {
            deepseekEnabled = deepseek.enabled
            deepseekApiKey = deepseek.apiKey ?? ""
            deepseekInterval = deepseek.refreshIntervalSeconds ?? 0
        }
    }

    func saveAndApply() async throws {
        let previousLaunchAtLogin = loginItemService.isEnabled

        var config = configStore.config
        config.refreshIntervalSeconds = globalInterval
        config.statusBarIconStyle = statusBarIconStyle
        config.statusBarHealthDotEnabled = statusBarHealthDotEnabled
        config.statusBarHealthColors = statusBarHealthColors == .default
            ? nil
            : statusBarHealthColors
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
            // 与默认一致时写 nil，保持 config.json 干净
            let d = GlmPeakWindow.zhipuDefault
            // 先把结束时间钳到合法区间，避免用户先把开始调高导致 end ≤ start
            let clampedStart = min(max(glmPeakStart, 0), 22)
            let clampedEnd = min(max(glmPeakEnd, clampedStart + 1), 23)
            glm.peakStartHour = clampedStart == d.startHour ? nil : clampedStart
            glm.peakEndHour = clampedEnd == d.endHour ? nil : clampedEnd
            glm.peakWeekdaysOnly = glmPeakWeekdays == d.weekdaysOnly ? nil : glmPeakWeekdays
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

    /// 用当前表单草稿（未保存的配置也行）发一条 Bark 测试推送。
    /// 复用正式推送的规范化、URL 构造与屏幕跳过策略（BarkQuotaNotifier.sendTestPush）。
    func sendBarkTest() {
        let config = BarkConfig(
            enabled: true,
            serverURL: barkServerURL,
            deviceKey: barkDeviceKey,
            sound: barkSound,
            skipWhenAwakeAndUnlocked: barkSkipWhenAwakeAndUnlocked ? true : nil,
            ttl: BarkConfig.parseTTL(barkTTL),
            group: barkGroup
        )
        isSendingBarkTest = true
        barkTestMessage = nil
        Task {
            barkTestMessage = await BarkQuotaNotifier.sendTestPush(config: config)
            isSendingBarkTest = false
        }
    }

    /// 通过 descriptors 拿实际 provider id — 不再硬编码。
    func providerID(for kind: ProviderKind) -> String? {
        descriptors.first(where: { $0.kind == kind })?.id
    }

    func providerRefreshInterval(from value: Int) -> Int? {
        value == 0 ? nil : value
    }

    func trimmedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func roundedInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(10, rounded))
    }

    func roundedProviderInterval(from value: Double) -> Int {
        let rounded = Int((value / 10).rounded() * 10)
        return min(3600, max(0, rounded))
    }

    private func statusBarColorBinding(
        for keyPath: WritableKeyPath<StatusBarHealthColors, String>
    ) -> Binding<Color> {
        Binding(
            get: {
                Color(nsColor: statusBarHealthColors.color(
                    forHex: statusBarHealthColors[keyPath: keyPath]
                ) ?? .systemGray)
            },
            set: { newColor in
                statusBarHealthColors[keyPath: keyPath] = hexString(from: NSColor(newColor))
            }
        )
    }

    private func hexString(from color: NSColor) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? NSColor.systemGray
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    func tildePath(for path: String) -> String {
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
