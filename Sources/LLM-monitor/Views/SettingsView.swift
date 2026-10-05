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

    /// 全部 tab（`.general` / `.energy` + descriptors 派生的 provider tab）。
    /// `Identifiable` 让 `ForEach` 走 `id` 区分，切换不会触发整列重渲染。
    var allTabs: [SettingsTab] {
        [.general, .energy] + sortedProviderDescriptors.map { .provider($0) } + [.clients]
    }

    var sortedProviderDescriptors: [FetcherDescriptor] {
        descriptors.sorted(by: providerDescriptorDisplayNameAscending)
    }

    /// 「App 图标」选项的预览图：直接使用 App 图标设计稿（与实际图标同源），
    /// 不再用 .full 示例指标现生成；设计稿加载失败时回退到现生成逻辑。
    /// 图标主题 picker 每行的预览图。
    ///
    /// 本调用点的输入全部固定（健康度 nil、满额度样例、默认健康色、不显示
    /// 圆点；SF 符号的动态 labelColor 由绘制闭包在绘制期解析，不会在合成时
    /// 烤进位图），预览图只随 style 变化。而设置页 body 会因拖动 Slider /
    /// ColorPicker（binding 直写 @State）高频重求值，不缓存会每 tick 重建
    /// SVG 与 NSImage。样式枚举有限（6 种），首次访问时一次性构建不可变
    /// 字典即可，天然有界；SwiftUI body 只在主线程求值，普通字典无需加锁。
    ///
    /// 每张图在这里就被**烘焙成自己的目标边长**（见 `previewIconSide`），而不是
    /// 交给调用处的 `.frame()` 去缩。原因：菜单式 `Picker` 在真实窗口里由 AppKit 的
    /// `NSPopUpButton` 绘制，那条路径不保证尊重 SwiftUI 施加在 label 子视图上的
    /// frame——只要图片的 intrinsic size 还是 22pt 的画布，它就照 22pt 画出来，
    /// `.frame(15, 15)` 被无声忽略。把尺寸做进 `NSImage.size` 之后，图标多大由图片
    /// 自己说了算，任何容器都改不动。
    private static let previewImageCache: [StatusBarIconStyle: NSImage] =
        StatusBarIconStyle.allCases.reduce(into: [:]) { cache, style in
            let composed: NSImage
            if style == .quotaLogo, let preview = MenuBarLabel.appIconDesignImage {
                composed = preview
            } else {
                composed = MenuBarLabel.composedMenuBarImage(
                    iconStyle: style,
                    health: nil,
                    showsHealthDot: false
                )
            }
            cache[style] = bakedPreview(composed, side: previewIconSide(for: style))
        }

    /// 把一张按画布尺寸的 `NSImage` 复制成指定边长的版本：位图按 2x 光栅化，
    /// `NSImage.size` 直接就是目标 pt 值，于是它被任何容器拿去做 layout 都是那个大小。
    ///
    /// 用 2x（菜单行里的预览不会超过 18pt，2x 已有 36px 余量）。绘制走
    /// `NSGraphicsContext` 而不是改 `size` 属性——只改 `size` 会让视图按新的点尺寸
    /// 拉伸同一个 `CGImage`，在 22→15 这种非整数比上会糊。
    private static func bakedPreview(_ image: NSImage, side: CGFloat) -> NSImage {
        let pixels = max(1, Int((side * 2).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let baked = NSImage(size: NSSize(width: side, height: side))
        baked.addRepresentation(rep)
        return baked
    }

    static func previewImage(for style: StatusBarIconStyle) -> NSImage {
        previewImageCache[style]
            ?? bakedPreview(
                MenuBarLabel.composedMenuBarImage(
                    iconStyle: style, health: nil, showsHealthDot: false
                ),
                side: previewIconSide(for: style)
            )
    }

    /// 图标主题 picker 里某一行的预览边长（pt）。
    ///
    /// 六种预览里只有「App 图标」需要单独定尺寸，其余共用一个 18pt 框。原因不是
    /// 偏好而是两类资源的画布约定不同：SF Symbol 与 Icon Duo 的画布**自带内边距**，
    /// 18pt 框里真正的不透明像素只有 12.4~14.5pt；而 App 图标设计稿在载入时已经
    /// 把透明留白裁掉（见 `MenuBarLabel.appIconDesignImage`），直接铺满 18pt 框就是
    /// 18pt 实心图形——比同一行里的同伴大 35%，在 20pt 高的菜单行里看着像要顶出去。
    ///
    /// 菜单栏那侧有对应的一步：`baseDrawRect` 借 `appIconDesignDrawSide` 把它从 22
    /// 收到 18（"铺满 22pt 画布看着偏大"）。picker 这条路上原本没有，于是只有这里大。
    ///
    /// 15pt 的依据：实测其余五种预览的不透明像素上沿是 14.5pt（Icon Duo），均值约
    /// 13.3pt；15pt 落在上沿偏上一点，与菜单栏里 18pt vs 15~17pt 的观感比例（1.13）
    /// 对齐——App 图标是密实图形，比细描边符号略大一点是应当的，再大就抢戏了。
    /// 由 `testPickerPreviewIconsShareOneVisualBand` 钉住。
    static func previewIconSide(for style: StatusBarIconStyle) -> CGFloat {
        style == .quotaLogo ? 15 : 18
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
        .onReceive(configStore.$config.dropFirst()) { newConfig in
            // 外部编辑配置文件时刷新设置页。两道闸门：
            //  - 自己正在保存 → 保留草稿（保存会广播一次 `config`）。
            //  - 变的只是边缘窗位置 → 保留草稿（拖 dock 会写盘，但那三个字段表单管不到；
            //    不挡的话，用户输了一半的 API key 会被盘上的旧值无声刷回去）。
            guard !isSaving, hasFormRelevantChange(to: newConfig) else { return }
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

            SettingsSection(title: "状态栏图标", footer: "可自定义正常、预警、异常三种状态颜色；系统图标使用状态圆点。App 图标直接使用设计稿（与下面的预览同一张图），是固定图片，不随额度与健康度变化。Icon Duo 为额度仪表盘：左右弧线显示 5 小时与周额度，中心扇形按最低剩余比例动态显示 0～360°，底部三个套餐状态点与顶部节能状态圆点。") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsControlRow("图标主题") {
                        Picker("", selection: $statusBarIconStyle) {
                            ForEach(StatusBarIconStyle.allCases) { style in
                                HStack(spacing: 8) {
                                    // 不加 `.resizable()` / `.frame()`：边长已经烘焙进
                                    // NSImage 自身的 size（见 previewImageCache），这里
                                    // 任何缩放 modifier 反而会把 AppKit 那条不受约束的
                                    // 绘制路径重新引进来。
                                    Image(nsImage: Self.previewImage(for: style))
                                    .renderingMode(.original)

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

                    SettingsControlRow("恢复默认颜色") {
                        Button("恢复默认") {
                            statusBarHealthColors = .default
                        }
                        .controlSize(.small)
                        // 三个颜色都还是默认值时按钮没有意义，也不该看着可点。
                        // 放在 disabled 而不是直接隐藏：控件位置会随三色是否被改过
                        // 而跳动，读起来像是设置页自己变了。
                        .disabled(statusBarHealthColors == .default)
                    }
                }
            }

            SettingsSection(
                title: "边缘状态窗",
                footer: "在屏幕边缘常驻一个小型圆环窗，每个已启用的 Provider 一个双环圆——外环是 5 小时额度剩余比例，内环是周额度剩余比例（各取该 Provider 内最吃紧的套餐），中心是品牌图标，环的颜色沿用上方状态栏三色。鼠标默认穿透不挡点击，移上去才接管；悬停在某个圆环上会在旁边展开与主菜单相同的 Provider 卡片，移开鼠标收起。可直接拖到任意边缘、任意一块显示器上，位置会记住——贴靠哪一边、停在哪块屏都由拖动决定，这里没有下拉框（屏的拔出会让 dock 自动回到主屏）。下拉框选的是 dock 在屏幕上的**形态**，四选一；全屏时是否隐藏是另一件事，单独一个开关。"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsControlRow("形态") {
                        Picker("", selection: $edgeDockMode) {
                            ForEach(EdgeDockMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                    }

                    // 选中项的一句话说明：四个选项的名字都是形态，不是行为，
                    // 光看名字分不出"小圆环"会不会长、"自动隐藏"藏的是环还是整个窗。
                    Text(edgeDockMode.summary)
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsControlRow("小圆环尺寸") {
                        Picker("", selection: $edgeDockCompactSize) {
                            ForEach(EdgeDockCompactSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                    }
                    // 简版尺寸**只在有简版消费者时才有意义**：形态选了「无」不显示，
                    // 「状态窗」常驻完整、外环是 38pt 固定值，两种情况下改这一档
                    // 屏幕上的像素一动不动。与全屏开关同一套禁用口径。
                    .disabled(!edgeDockMode.usesCompactAppearance)

                    SettingsToggleRow(label: "内外环独立取色", isOn: $edgeDockIndependentRingColors)

                    Text(
                        edgeDockIndependentRingColors
                            ? "开启后外环按 5 小时窗口、内环按周窗口各自的时间感知阈值取色；关闭后两环同色，取该 Provider 的整体健康度。"
                            : "两环同色，取该 Provider 的整体健康度；开启后可分别读出 5 小时与周窗口各自的吃紧程度。"
                    )
                    .font(SettingsTypography.status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    SettingsToggleRow(label: "全屏时不显示", isOn: $edgeDockHideInFullscreen)
                        .disabled(!edgeDockMode.isVisible)
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

            SettingsSection(
                title: "节假日数据源",
                footer: "GLM / DeepSeek 高峰判定与高峰倍率所用的法定节假日表来源。支持 URL 或本地文件路径（本项目 JSON 快照格式，可用 scripts/sync-holiday-data.sh 生成）；填回默认地址即恢复默认（chinese-days 的 CDN JSON，App 内自动转换为快照口径）；清空表示只用随 App 打包的内置快照、不联网。取数失败时保留既有数据。"
            ) {
                HolidaySourceSection(
                    service: state.holidayCalendarService,
                    draft: $holidaySourceDraft
                )
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

                    Divider()
                        .padding(.vertical, 4)

                    SettingsControlRow("立即刷新") {
                        providerRefreshButton(for: .minimaxTokenPlan)
                    }
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

                    Divider()
                        .padding(.vertical, 4)

                    SettingsControlRow("立即刷新") {
                        providerRefreshButton(for: .codexChatGpt)
                    }
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

                    Divider()
                        .padding(.vertical, 4)

                    // 立即刷新（额度重取）与下方「本地用量缓存」的强制全量重建是
                    // 两个动作：前者走 refreshOne 只重取额度并重锚排期，后者强制
                    // 重扫本地 session 缓存。并列共存，互不替换。
                    SettingsControlRow("立即刷新") {
                        providerRefreshButton(for: .antigravity)
                    }
                }

                SettingsSection(
                    title: "本地用量缓存",
                    footer: "启动扫描会优先复用 antigravity.json：未变化 session 直接使用缓存，追加变化使用 offset。只有这里的操作会对所有 session 强制重新请求 trajectory metadata，适合数据异常时恢复。"
                ) {
                    HStack(spacing: 12) {
                        Button {
                            isAntigravityHardFullRunning = true
                            antigravityHardFullMessage = nil
                            Task { @MainActor in
                                let started = await state.hardRefreshAntigravityLocalUsage()
                                isAntigravityHardFullRunning = false
                                // 失败可能是"被其他刷新事务占用"，也可能是等待中
                                // 扫描被取消（配置变更/停机）—— 统一给诚实的重试
                                // 文案，不谎报"已完成"。
                                antigravityHardFullMessage = started
                                    ? "强制全量重建已完成"
                                    : "强制全量重建未完成（被其他任务占用或中途取消），请稍后重试"
                            }
                        } label: {
                            if isAntigravityHardFullRunning {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在重建…")
                            } else {
                                Text("强制全量重建本地缓存")
                            }
                        }
                        .disabled(isAntigravityHardFullRunning || state.isRefreshJobActive)

                        if let antigravityHardFullMessage {
                            Text(antigravityHardFullMessage)
                                .font(SettingsTypography.status)
                                .foregroundStyle(.secondary)
                        }
                    }
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

                    Divider()
                        .padding(.vertical, 4)

                    SettingsControlRow("立即刷新") {
                        providerRefreshButton(for: .glmCodingPlan)
                    }
                }

                SettingsSection(
                    title: "高峰期提示",
                    footer: "高峰期内模型调用按基础积分扣费，非高峰期按 50% 抵扣（省一半）。按北京时间计算，工作日 = 周一–周五（法定节假日除外），卡片会显示距高峰期 / 高峰结束的倒计时。官方口径，不可调。"
                ) {
                    SettingsControlRow("高峰时段定义") {
                        Text("工作日 14:00–18:00（北京时间 · 法定节假日除外）")
                            .font(SettingsTypography.numericValue)
                            .foregroundStyle(.secondary)
                    }
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

                    Divider()
                        .padding(.vertical, 4)

                    SettingsControlRow("立即刷新") {
                        providerRefreshButton(for: .deepseek)
                    }
                }

                SettingsSection(
                    title: "高峰期提示",
                    footer: "DeepSeek API 采用峰谷定价策略，高峰价格为平价（1×）的 2 倍（适用于所有计费项）。系统将自动换算北京时间并实时提示倒计时。高峰时段为北京时间工作日（法定节假日除外）9:00–12:00 和 14:00–18:00，周六、周日全天平价（1×）。官方口径，不可调。"
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

    /// 把边缘窗的**位置三兄弟**（贴边方向 / 沿边位置 / 所在屏）抹平成默认值。
    ///
    /// 用它做对比，而不是逐个字段枚举"表单管得到哪些"：枚举一旦将来漏了新加的设置项，
    /// 那个字段就会静默失去热重载。抹平位置字段之后，两份配置相等 ⟺
    /// **除了 dock 停在哪，表单看到的任何东西都没变**。
    static func formRelevantProjection(of config: AppConfig) -> AppConfig {
        var copy = config
        if var dock = copy.edgeDock {
            dock.edge = EdgeDockConfig.default.edge
            dock.offset = EdgeDockConfig.default.offset
            dock.screenUUID = nil
            copy.edgeDock = dock
        }
        return copy
    }

    /// `old` → `new` 之间，除边缘窗位置外还有没有别的差异？**纯函数**。
    ///
    /// 抽成 `static` 是因为它是全部的判断逻辑，而 `loadedConfigSnapshot` 活在
    /// `@State` 里——`@State` 的写入只在视图真正进入渲染层时才可靠，直接从
    /// 单元测试驱动 `loadCurrentConfig()` 写不进去，测到的会是快照为 nil 的分支。
    static func hasFormRelevantChange(from old: AppConfig, to new: AppConfig) -> Bool {
        formRelevantProjection(of: old) != formRelevantProjection(of: new)
    }

    /// 配置变了，但**变的不是表单关心的东西**吗？
    ///
    /// 边缘窗拖拽每次松手都会写 config.json（`EdgeDockController.persistConfig`），
    /// 而它只动那三个位置字段——设置页表单一个都碰不到。少了这道判据，拖一次 dock
    /// 就会让开着的设置页收到 `configStore.$config` 广播、整张表单重载，用户正在
    /// 输入的 API key、刷新间隔、Bark 配置**无声地**刷回盘上的旧值（dock 面板是
    /// nonactivating 的，完全可以在设置窗口开着的时候拖）。
    ///
    /// 没有快照（还没载入过）时一律判 true：宁可多刷一次，也不要在状态不明时
    /// 顶着陈旧表单不刷新。
    func hasFormRelevantChange(to newConfig: AppConfig) -> Bool {
        guard let old = loadedConfigSnapshot else { return true }
        return Self.hasFormRelevantChange(from: old, to: newConfig)
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

    // MARK: - 单个 provider 的「立即刷新」（设置页侧唯一入口）

    /// pane「认证与刷新」区那枚「立即刷新」按钮的**全部决策**（路由 + 禁用）
    /// 收敛在这一个纯读函数里：路由经 `providerID(for:)` 挂到注册表（不硬编码
    /// id），禁用读全局在飞标志。返回 nil = 该 kind 没有注册 descriptor，按钮
    /// 不该出现。
    func providerRefreshAction(for kind: ProviderKind) -> SettingsProviderRefreshAction? {
        guard let providerID = providerID(for: kind) else { return nil }
        return SettingsProviderRefreshAction(
            providerID: providerID,
            isRefreshJobActive: state.isRefreshJobActive
        )
    }

    /// 「立即刷新」按钮构造入口：五个 provider pane 共用，行内写
    /// `providerRefreshButton(for: .xxx)` 即可。
    @ViewBuilder
    func providerRefreshButton(for kind: ProviderKind) -> some View {
        if let action = providerRefreshAction(for: kind) {
            SettingsProviderRefreshButton(action: action, onRefresh: refreshProviderFromSettings)
        }
    }

    /// 「立即刷新该 Provider」在设置页的唯一落点：走 `AppState.refreshOne(providerID:)`，
    /// 与菜单兜底行右键「刷新该 Provider」（`MenuContentView.refreshProviderFromMenu`）
    /// **同一条链路**——只发这个 provider 的请求、只重锚它自己的排期，其他
    /// provider 的下一拍与周期 full 计数不受影响。重复点击由 `refreshOne` 的
    /// 全局事务闸门兜底（第二个 `beginExternalJob` 拿不到 token，静默 no-op）。
    func refreshProviderFromSettings(_ providerID: String) {
        Task { await state.refreshOne(providerID: providerID) }
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

/// 「节假日数据源」节（常规 pane）的表体：源输入 + 状态行 + 覆盖提示 + 立即更新。
///
/// 单独成 View 是为了 `@ObservedObject` 观察服务端的 @Published（刷新状态 /
/// 结果文案 / 来源标记），让「立即更新」的转圈与结果行只重绘本节，不重绘整张
/// 设置表单。源文本走父级的 draft binding，与既有 draft/save 事务同轨。
private struct HolidaySourceSection: View {
    @ObservedObject var service: HolidayCalendarService
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsControlRow("数据源") {
                TextField("", text: $draft, prompt: Text(HolidayCalendar.defaultSourceURL))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: SettingsLayout.standardControlWidth)
            }

            Text(service.statusLineText)
                .font(SettingsTypography.status)
                .foregroundStyle(.secondary)

            if let warning = service.coverageWarningText {
                Text(warning)
                    .font(SettingsTypography.status)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("立即更新") {
                    Task {
                        _ = await service.refreshNow(
                            source: draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
                .disabled(service.isRefreshing)

                if service.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在更新…")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                } else if let message = service.lastRefreshMessage {
                    Text(message)
                        .font(SettingsTypography.status)
                        .foregroundStyle(message.hasPrefix("节假日更新失败") ? .orange : .secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
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
        case .provider(let d): return .provider(d.kind)
        case .clients: return nil
        }
    }
}
