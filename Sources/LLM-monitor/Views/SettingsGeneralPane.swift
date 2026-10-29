import SwiftUI
import AppKit

extension SettingsView {
    /// 设置窗口图标主题 picker 的预览图缓存。
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

    /// 烘焙指定边长的预览位图。
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
    static func previewIconSide(for style: StatusBarIconStyle) -> CGFloat {
        style == .quotaLogo ? 15 : 18
    }

    var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            if currentTab.id == SettingsTab.generalID {
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

            }

            if currentTab.id == SettingsTab.interfaceID {
            SettingsSection(title: "外观", footer: "浅色 / 深色固定显示，自动跟随系统设置；保存并应用后生效。") {
                SettingsControlRow("界面外观") {
                    Picker("", selection: Binding(
                        get: { appearanceDraft },
                        set: { appearanceDraft = $0 }
                    )) {
                        ForEach(AppAppearance.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: SettingsLayout.standardControlWidth)
                }
            }

            SettingsSection(
                title: "状态栏图标",
                footer: "此处三色只用于菜单栏健康度圆点与边缘状态窗额度圆环；不改变 Provider 品牌色、额度卡进度条或其他语义状态色。App 图标是固定设计稿；Icon Duo 展示额度仪表盘。"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsControlRow("图标主题") {
                        Picker("", selection: $statusBarIconStyle) {
                            ForEach(StatusBarIconStyle.allCases) { style in
                                HStack(spacing: 8) {
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

                    SettingsControlRow("指标来源") {
                        Picker("", selection: $statusBarPinnedProvider) {
                            Text("全部聚合（非零最小值）").tag("")
                            ForEach(descriptors.filter { ProviderKind.windowedKinds.contains($0.kind) }, id: \.id) { descriptor in
                                Text(descriptor.displayName).tag(descriptor.id)
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
                        .disabled(statusBarHealthColors == .default)
                    }
                }
            }

            SettingsSection(
                title: "边缘状态窗",
                footer: "在屏幕边缘常驻各 Provider 的双环额度圆环，可自由拖拽贴靠任意屏幕边缘；悬停展开详情卡片，移开鼠标收起。"
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

                    HStack(alignment: .firstTextBaseline) {
                        Text(edgeDockMode.summary)
                            .font(SettingsTypography.status)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("了解更多…") {
                            showsEdgeDockHelp.toggle()
                        }
                        .buttonStyle(.link)
                        .font(SettingsTypography.status)
                        .popover(isPresented: $showsEdgeDockHelp, arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("边缘状态窗机制")
                                    .font(.headline)
                                Text("• 每个已启用的 Provider 对应一个双环圆：外环为 5 小时额度比例，内环为周额度比例（各取最吃紧套餐），中心为品牌图标。\n• 鼠标默认穿透点击不挡操作，移入圆环接管并展开详情卡片。\n• 贴靠屏幕与沿边位置由拖动决定并自动记忆，断开外接屏时自动回到主屏。\n• 环颜色沿用状态栏三色，全屏时可单独设置是否隐藏。")
                                    .font(SettingsTypography.status)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                            }
                            .padding(14)
                            .frame(width: 320)
                        }
                    }
                    EdgeDockModePreviewView(mode: edgeDockMode)
                    SettingsControlRow("位置") {
                        Button("恢复默认位置") { resetDockPosition() }
                            .help("重置贴靠边、沿边位置和所在屏；立即生效，不影响待保存设置")
                    }
                    if let dockPositionMessage {
                        Text(dockPositionMessage)
                            .font(SettingsTypography.status)
                            .foregroundStyle(dockPositionMessage.hasPrefix("恢复位置失败") ? .orange : .secondary)
                    }

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
            }

            if currentTab.id == SettingsTab.generalID {
            SettingsSection(title: "开机自启动", footer: "在系统登录时自动后台运行 LLM Monitor。") {
                SettingsToggleRow(label: "开启开机自启动", isOn: $launchAtLoginDraft.draft)

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
            }

            if currentTab.id == SettingsTab.notificationsID {
            notificationAuthorizationSection
            SettingsSection(
                title: "Bark 推送",
                footer: "按各 Provider 的通知配置，把 5 小时 / 周额度的恢复与耗尽事件推送到 iPhone。服务端默认官方 api.day.app，也可填自建地址；Device Key 从 Bark App 复制。正式提醒可按下方策略跳过；主动测试会忽略跳过策略并实际发送。保存后生效。"
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
                        Button("主动发送测试推送") {
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
                    Text(barkSkipWhenAwakeAndUnlocked
                        ? "正式提醒：按各 Provider 渠道发送，屏幕亮且未锁定时跳过。主动测试会发送一条测试消息，仅验证当前草稿的连接。"
                        : "正式提醒按各 Provider 渠道发送；主动测试会发送一条测试消息，仅验证当前草稿的连接。")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(ProviderKind.windowedKinds, id: \.quotaProviderID) { kind in
                if let providerID = providerID(for: kind) {
                    providerNotificationSettingsSection(providerID: providerID)
                }
            }
            }

            if currentTab.id == SettingsTab.interfaceID {
            SettingsSection(
                title: "主菜单 Provider 顺序",
                footer: "未配置时按 Provider 名称排序。这里只调整主菜单卡片；客户端和设置页保持字母排序。"
            ) {
                providerCardOrderEditor
            }
            }

            if currentTab.id == SettingsTab.generalID {
            SettingsSection(
                title: "节假日数据源",
                footer: "GLM / DeepSeek 高峰判定与高峰倍率所用的法定节假日表来源。支持 URL 或本地文件路径（本项目 JSON 快照格式，可用 scripts/sync-holiday-data.sh 生成）；填回默认地址即恢复默认（chinese-days 的 CDN JSON，App 内自动转换为快照口径）；清空表示只用随 App 打包的内置快照、不联网。取数失败时保留既有数据。"
            ) {
                HolidaySourceSection(
                    service: state.holidayCalendarService,
                    draft: $holidaySourceDraft
                )
            }
            }

            if currentTab.id == SettingsTab.generalID {
            SettingsSection(title: "关于") {
                SettingsControlRow("LLM Monitor") {
                    Text("版本 \(AppMetadata.version)（\(AppMetadata.build)）")
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.secondary)
                }
            }
            }
        }
    }

    var notificationAuthorizationSection: some View {
        SettingsSection(
            title: "系统通知权限",
            footer: "macOS 的通知样式与横幅显示由系统设置控制。授权表示允许发送，不保证系统一定显示横幅。"
        ) {
            SettingsToggleRow(
                label: "系统通知播放提示音",
                isOn: $systemNotificationSoundEnabledDraft
            )
            SettingsControlRow("当前状态") {
                Text(notificationAuthorization.displayText)
                    .font(SettingsTypography.status)
                    .foregroundStyle(notificationAuthorization == .denied ? .orange : .secondary)
            }
            if notificationAuthorization == .notDetermined {
                Button("请求系统通知权限") {
                    Task {
                        do {
                            _ = try await SystemQuotaUpdateNotifier.requestAuthorizationIfNeeded()
                            refreshNotificationAuthorization()
                        } catch {
                            saveErrorMessage = "请求通知权限失败：\(error.localizedDescription)"
                        }
                    }
                }
            } else if notificationAuthorization == .denied {
                Button("打开系统通知设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if notificationAuthorization == .authorized {
                Button("发送系统通知测试") {
                    let soundEnabled = systemNotificationSoundEnabledDraft
                    Task {
                        systemNotificationTestMessage = await SystemQuotaUpdateNotifier.sendTestNotification(
                            soundEnabled: soundEnabled
                        )
                    }
                }
            }
            if let systemNotificationTestMessage {
                Text(systemNotificationTestMessage)
                    .font(SettingsTypography.status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func providerNotificationSettingsSection(providerID: String) -> some View {
        SettingsSection(
            title: "\(providerDisplayName(for: providerID)) 额度事件提醒",
            footer: "5 小时 / 周额度恢复或耗尽时的提醒方式。选择“Bark + 系统通知”时，Bark 不可用仍发送系统通知。"
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
        .id("providerNotification.\(providerID)")
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

    func statusBarColorBinding(
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

    func hexString(from color: NSColor) -> String {
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

    /// 用当前表单草稿（未保存的配置也行）发一条 Bark 测试推送。
    /// 复用正式推送的规范化与 URL 构造；主动测试不受正式推送的屏幕跳过策略限制。
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
            barkTestMessage = await BarkQuotaNotifier.sendTestPush(config: config, respectScreenPolicy: false)
            isSendingBarkTest = false
        }
    }
}

private struct EdgeDockModePreviewView: View {
    let mode: EdgeDockMode

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 126, height: 56)
                if mode.isVisible {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: mode == .autoHideWindow ? 8 : 28, height: 42)
                        .overlay {
                            if mode != .autoHideWindow {
                                Circle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: 14, height: 14)
                            }
                        }
                        .padding(.trailing, mode == .autoHideWindow ? 0 : 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.displayName).font(SettingsTypography.rowEmphasis)
                Text(mode == .autoHideWindow ? "靠近屏幕边缘展开；可拖动圆环调整位置。" : mode.isVisible ? "可拖动圆环调整位置。" : "边缘状态窗已关闭。")
                    .font(SettingsTypography.status)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「节假日数据源」节（常规 pane）的表体：源输入 + 状态行 + 覆盖提示 + 立即更新。
struct HolidaySourceSection: View {
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

