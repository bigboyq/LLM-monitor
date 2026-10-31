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
            Divider().padding(.vertical, 4)
            SettingsControlRow("立即刷新") {
                providerRefreshButton(for: kind)
            }
        }
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
                    footer: "开启后监测每月官方赠送的 API 额度与消耗；账单重置时间与额度上限支持按需自定义。首月统计可能存在偏差，后续按完整账期计算。"
                ) {
                    SettingsToggleRow(label: "启用 API 赠金监测", isOn: $draft.chatgptAdminCreditsEnabled)

                    if draft.chatgptAdminCreditsEnabled {
                        SettingsControlRow("Admin API Key") {
                            secretField(text: $draft.chatgptAdminApiKey, isVisible: $showChatgptAdminKey, prompt: "sk-admin-...")
                        }

                        SettingsControlRow("赠金额度 ($)") {
                            VStack(alignment: .trailing, spacing: 4) {
                                TextField("", text: $draft.chatgptMonthlyQuotaLimit, prompt: Text("40"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: SettingsLayout.standardControlWidth)
                                if let error = chatgptMonthlyQuotaLimitError {
                                    Text(error)
                                        .font(SettingsTypography.status)
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        SettingsControlRow("账单日") {
                            Picker("", selection: $draft.chatgptBillingDay) {
                                ForEach(1...31, id: \.self) { day in
                                    Text("每月 \(day) 日").tag(day)
                                }
                            }
                            .frame(width: SettingsLayout.standardControlWidth)
                        }

                        SettingsControlRow("重置时间") {
                            DatePicker("", selection: $draft.chatgptBillingTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                        }
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
        switch draft.glmAuthMode {
        case .apiKey:
            return "填写智谱 GLM Coding Plan 的 API Key（格式 `id.secret`，在 bigmodel.cn 套餐概览页新建）。此模式仅监控标准 5h 与周额度套餐。"
        case .credential:
            return "支持填写 ZCode 凭证目录（如 `~/.zcode/v2`）或 `credentials.json` 文件，也可以直接点“选择…”。自动解析登录状态，支持标准套餐、活动套餐、额度重置卡与运营活动推送。"
        }
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
                    SettingsControlRow("认证方式") {
                        Picker("", selection: $draft.glmAuthMode) {
                            ForEach(GlmAuthMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: SettingsLayout.standardControlWidth)
                    }

                    if draft.glmAuthMode == .apiKey {
                        SettingsControlRow("API Key") {
                            glmApiKeyField
                        }
                    } else {
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
