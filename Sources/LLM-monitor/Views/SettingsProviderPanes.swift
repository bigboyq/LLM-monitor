import SwiftUI
import AppKit

extension SettingsView {
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

    @ViewBuilder
    func providerAuthAndRefreshSection<AuthContent: View>(
        kind: ProviderKind,
        footer: String? = nil,
        interval: Binding<Int>,
        @ViewBuilder authContent: () -> AuthContent
    ) -> some View {
        SettingsSection(title: "认证与刷新", footer: footer) {
            authContent()
            if !(AuthContent.self == EmptyView.self) {
                Divider().padding(.vertical, 4)
            }
            intervalSliderField(label: "独立刷新频率", value: interval)
            if kind == .codexChatGpt {
                SettingsControlRow("重置卡 / 组织信息周期") {
                    secondaryInfoCycleBadge(intervalOverride: interval.wrappedValue)
                }
            } else if kind == .antigravity {
                SettingsControlRow("账号 / 套餐信息周期") {
                    secondaryInfoCycleBadge(intervalOverride: interval.wrappedValue)
                }
            } else if kind == .glmCodingPlan && draft.glmZcodeJWTEnabled {
                SettingsControlRow("重置卡 / 活动预计周期") {
                    secondaryInfoCycleBadge(intervalOverride: interval.wrappedValue)
                }
            }
            Divider().padding(.vertical, 4)
            SettingsControlRow("立即刷新") {
                providerRefreshButton(for: kind)
            }
        }
    }

    private func secondaryInfoCycleBadge(intervalOverride: Int) -> some View {
        let seconds = draft.secondaryInfoRefreshInterval(providerInterval: intervalOverride)
        return Text("预计 \(Formatters.formatInterval(seconds: seconds))")
            .font(SettingsTypography.metadata)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    var minimaxPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 minimax Token Plan 监测", isOn: $draft.minimaxEnabled)
            }

            if draft.minimaxEnabled {
                providerAuthAndRefreshSection(kind: .minimaxTokenPlan, interval: $draft.minimaxInterval) {
                    SettingsControlRow("API Key") {
                        apiKeyField(text: $draft.minimaxApiKey, isVisible: $showMinimaxKey)
                    }
                }

                notifySection(providerID: providerID(for: .minimaxTokenPlan) ?? "")
            }
        }
    }

    var chatgptPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 ChatGPT Plan 监测", isOn: $draft.chatgptEnabled)
            }

            if draft.chatgptEnabled {
                providerAuthAndRefreshSection(
                    kind: .codexChatGpt,
                    footer: "`authPath` 支持填写 `auth.json` 文件，或它所在目录；也可以直接点“选择…”。",
                    interval: $draft.chatgptInterval
                ) {
                    SettingsControlRow("auth.json 路径") {
                        HStack(spacing: 8) {
                            TextField("", text: $draft.chatgptAuthPath, prompt: Text("~/.codex/auth.json 或 ~/.codex/"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button("选择…") {
                                selectAuthFile()
                            }
                        }
                        .frame(width: SettingsLayout.standardControlWidth)
                    }
                }

                notifySection(providerID: providerID(for: .codexChatGpt) ?? "")

                SettingsSection(
                    title: "API 赠金",
                    footer: "开启后监测每月官方赠送的 API 额度与消耗；支持配置多个 API Key 独立追踪。账单重置时间与额度上限支持按需自定义。首月统计可能存在偏差，后续按完整账期计算。"
                ) {
                    SettingsToggleRow(label: "启用 API 赠金监测", isOn: $draft.chatgptAdminCreditsEnabled)

                    if draft.chatgptAdminCreditsEnabled {
                        ForEach(Array($draft.chatgptAdminKeys.enumerated()), id: \.element.id) { index, $keyDraft in
                            CodexAdminKeyCardView(
                                keyDraft: $keyDraft,
                                index: index,
                                canDelete: draft.chatgptAdminKeys.count > 1,
                                onDelete: {
                                    if let idx = draft.chatgptAdminKeys.firstIndex(where: { $0.id == keyDraft.id }) {
                                        draft.chatgptAdminKeys.remove(at: idx)
                                    }
                                }
                            )
                        }

                        Button {
                            draft.chatgptAdminKeys.append(
                                CodexAdminKeyConfigDraft(
                                    id: UUID().uuidString,
                                    label: "",
                                    apiKey: "",
                                    monthlyQuotaLimit: "40",
                                    billingDay: 11,
                                    billingTime: SettingsFormDraft.defaultBillingTime()
                                )
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text("添加 API Key")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    var antigravityPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 Antigravity 监测", isOn: $draft.antigravityEnabled)
            }

            if draft.antigravityEnabled {
                providerAuthAndRefreshSection(
                    kind: .antigravity,
                    footer: "Antigravity 走自动发现：扫描 `language_server`（IDE）与 `agy` / `antigravity-cli`（CLI）进程，复用它们的本地登录态，无需任何配置。",
                    interval: $draft.antigravityInterval
                ) {
                    EmptyView()
                }

                notifySection(providerID: providerID(for: .antigravity) ?? "")

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

    private var glmAuthFooter: String {
        "必须填写 Coding Plan API Key（格式 `id.secret`）。开启 ZCode JWT 扩展查询后，读取本地登录凭证以获取活动套餐、重置卡和营销活动。凭证路径留空使用 `~/.zcode/v2`。"
    }

    var glmPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 GLM Coding Plan 监测", isOn: $draft.glmEnabled)
            }

            if draft.glmEnabled {
                providerAuthAndRefreshSection(
                    kind: .glmCodingPlan,
                    footer: glmAuthFooter,
                    interval: $draft.glmInterval
                ) {
                    SettingsControlRow("API Key（必填）") {
                        glmApiKeyField
                    }

                    SettingsToggleRow(label: "启用 ZCode JWT 扩展查询", isOn: $draft.glmZcodeJWTEnabled)

                    if draft.glmZcodeJWTEnabled {
                        SettingsControlRow("ZCode 凭证路径") {
                            HStack(spacing: 8) {
                                TextField("", text: $draft.glmAuthPath, prompt: Text("~/.zcode/v2 或 credentials.json"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                Button("选择…") {
                                    selectGlmAuthFile()
                                }
                            }
                            .frame(width: SettingsLayout.standardControlWidth)
                        }

                        SettingsControlRow("运营活动推送通知") {
                            Picker("", selection: $draft.glmNotifyCampaign) {
                                ForEach(QuotaNotifyChannel.allCases) { channel in
                                    Text(channel.displayName).tag(channel)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                        }
                    }
                }

                notifySection(providerID: providerID(for: .glmCodingPlan) ?? "")

                peakPricingSection(for: .glmCodingPlan)
            }
        }
    }

    var deepseekPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                SettingsToggleRow(label: "启用 DeepSeek 监测", isOn: $draft.deepseekEnabled)
            }

            if draft.deepseekEnabled {
                providerAuthAndRefreshSection(
                    kind: .deepseek,
                    footer: "填写 DeepSeek 开放平台 (platform.deepseek.com) 生成的 API Key（格式 `sk-...`）。",
                    interval: $draft.deepseekInterval
                ) {
                    SettingsControlRow("API Key") {
                        apiKeyField(text: $draft.deepseekApiKey, isVisible: $showDeepseekKey)
                    }
                }

                peakPricingSection(for: .deepseek)
            }
        }
    }

    @ViewBuilder
    private func peakPricingSection(for kind: ProviderKind) -> some View {
        if let id = providerID(for: kind),
           let window = (configStore.config.providers[id] ?? ProviderConfig()).effectivePeakWindow(for: kind) {
            SettingsSection(
                title: "高峰期提示",
                footer: kind == .glmCodingPlan
                    ? "显示当前高峰时段与相对平时的积分扣费倍率。按北京时间计算，卡片实时显示倒计时；本地用量的名义价值估算不受积分倍率影响。"
                    : "显示当前高峰时段与相对平时的价格倍率。按北京时间计算，卡片实时显示倒计时；金额估算按调用发生时的高峰倍率计算。"
            ) {
                SettingsControlRow("高峰时段定义") {
                    Text(window.scheduleLabel)
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                SettingsControlRow("高峰期\(kind == .glmCodingPlan ? "积分" : "价格")") {
                    // 只显示偏离平时的倍率；默认价（1×）不额外标注（footer 已说明「相对平时」）。
                    Text(window.multiplierLabel)
                        .font(SettingsTypography.numericValue)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// 四类额度事件的通知渠道配置（ChatGPT / GLM 等 5 小时 + 周额度 provider）。
    func notifySection(providerID: String) -> some View {
        SettingsSection(
            title: "通知配置",
            footer: "通知渠道集中在「通知」设置中管理。"
        ) {
            Button("编辑此 Provider 的通知规则") {
                pendingNotificationProviderID = providerID
                currentTab = .notifications
            }
            .help("集中设置所有 Provider 的恢复与耗尽提醒")
        }
    }

    func providerDisplayName(for id: String) -> String {
        descriptors.first { $0.id == id }?.displayName ?? id
    }

    func notifyChannelBinding(
        providerID: String,
        kind: QuotaNotificationKind
    ) -> Binding<QuotaNotifyChannel> {
        Binding(
            get: {
                draft.notifyChannels[providerID]?[kind]
                    ?? QuotaNotifyChannels().channel(for: kind)
            },
            set: { newValue in
                var entry = draft.notifyChannels[providerID] ?? [:]
                entry[kind] = newValue
                draft.notifyChannels[providerID] = entry
            }
        )
    }

    var glmApiKeyField: some View {
        HStack(spacing: 8) {
            Group {
                if showGlmKey {
                    TextField("", text: $draft.glmApiKey, prompt: Text("xxxxxxxx.xxxxxxxxxxxxxxxx"))
                } else {
                    SecureField("", text: $draft.glmApiKey, prompt: Text("xxxxxxxx.xxxxxxxxxxxxxxxx"))
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
    /// 与菜单额度页「刷新该 Provider」（`MenuContentView.refreshProviderFromMenu`）
    /// **同一条链路**——只发这个 provider 的请求、只重锚它自己的排期，其他
    /// provider 的下一拍与周期 full 计数不受影响。重复点击由 `refreshOne` 的
    /// 全局事务闸门兜底（第二个 `beginExternalJob` 拿不到 token，静默 no-op）。
    func refreshProviderFromSettings(_ providerID: String) {
        Task { await state.refreshOne(providerID: providerID) }
    }

    func providerRefreshInterval(from value: Int) -> Int? {
        value == 0 ? nil : value
    }
}

/// 单个 Codex Admin API Key 卡片控件
struct CodexAdminKeyCardView: View {
    @Binding var keyDraft: CodexAdminKeyConfigDraft
    let index: Int
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var isKeyVisible: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(keyDraft.label.isEmpty ? "API Key #\(index + 1)" : keyDraft.label)
                    .font(SettingsTypography.rowEmphasis)
                    .foregroundStyle(Color.primary)

                Spacer()

                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此 API Key")
                }
            }
            .padding(.bottom, 2)

            SettingsControlRow("Key 名称") {
                TextField("", text: $keyDraft.label, prompt: Text("例如：个人账号、团队项目"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: SettingsLayout.standardControlWidth)
                    .help("用于额度卡片中区分各个 API Key；留空时显示 API Key 序号。")
            }

            SettingsControlRow("Admin API Key") {
                HStack(spacing: 8) {
                    Group {
                        if isKeyVisible {
                            TextField("", text: $keyDraft.apiKey, prompt: Text("sk-admin-..."))
                        } else {
                            SecureField("", text: $keyDraft.apiKey, prompt: Text("sk-admin-..."))
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(isKeyVisible ? "隐藏" : "显示")
                }
                .frame(width: SettingsLayout.standardControlWidth, alignment: .leading)
            }

            SettingsControlRow("赠金额度 ($)") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("", text: $keyDraft.monthlyQuotaLimit, prompt: Text("40"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: SettingsLayout.standardControlWidth)
                    if SettingsView.validMonthlyQuotaLimit(keyDraft.monthlyQuotaLimit) == nil && !keyDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("请输入大于 0 的有限数字。")
                            .font(SettingsTypography.status)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsControlRow("账单日") {
                Picker("", selection: $keyDraft.billingDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text("每月 \(day) 日").tag(day)
                    }
                }
                .frame(width: SettingsLayout.standardControlWidth)
            }

            SettingsControlRow("重置时间") {
                DatePicker("", selection: $keyDraft.billingTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 1)
        )
    }
}
