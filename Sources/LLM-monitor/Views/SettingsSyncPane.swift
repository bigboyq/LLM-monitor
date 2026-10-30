import SwiftUI
import AppKit
import Combine

/// Per-field write-through drafts for the fleet settings pane.
@MainActor
final class SettingsSyncDraftController: ObservableObject {
    enum Field: Hashable { case enabled, hubURL, nodeName, port, pushInterval }

    @Published private(set) var hubURLDraft: String
    @Published private(set) var nodeNameDraft: String
    @Published private(set) var portDraft: String
    @Published private(set) var pushIntervalDraft: String
    @Published private(set) var hubURLError: String?
    @Published private(set) var saveErrors: [Field: String] = [:]

    private let configStore: ConfigStore
    private let debounceNanoseconds: UInt64
    private var hubURLBaseline: String
    private var nodeNameBaseline: String
    private var portBaseline: Int
    private var pushIntervalBaseline: Int
    private var enabledBaseline: Bool
    private var hubURLTask: Task<Void, Never>?
    private var nodeNameTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?
    private var configCancellable: AnyCancellable?

    var hasSaveErrors: Bool { !saveErrors.isEmpty }

    init(configStore: ConfigStore, debounceNanoseconds: UInt64 = 600_000_000) {
        self.configStore = configStore
        self.debounceNanoseconds = debounceNanoseconds
        let sync = configStore.config.effectiveSyncConfig
        hubURLDraft = sync.hubURL
        nodeNameDraft = sync.nodeName
        portDraft = String(sync.hubPort)
        pushIntervalDraft = String(sync.pushIntervalSeconds)
        hubURLBaseline = sync.hubURL
        nodeNameBaseline = sync.nodeName
        portBaseline = sync.hubPort
        pushIntervalBaseline = sync.pushIntervalSeconds
        enabledBaseline = sync.enabled

        // ConfigStore is MainActor-isolated and publishes synchronously in applyAndSave.
        // Handle the exact new config before a later keystroke can be mistaken for stale state.
        configCancellable = configStore.$config
            .dropFirst()
            .sink { [weak self] config in self?.applyPersistedConfig(config) }
    }

    func setHubURLDraft(_ value: String) { hubURLDraft = value; schedule(.hubURL) }
    func setNodeNameDraft(_ value: String) { nodeNameDraft = value; schedule(.nodeName) }
    func setPortDraft(_ value: String) { portDraft = value; schedule(.port) }

    func saveError(for field: Field) -> String? { saveErrors[field] }

    func setEnabled(_ enabled: Bool) {
        guard enabled != configStore.config.effectiveSyncConfig.enabled else {
            clearSaveError(.enabled)
            return
        }
        persist(.enabled) { $0.enabled = enabled }
    }

    /// Slider values keep their immediate write-through behavior.
    func setPushInterval(_ seconds: Int) {
        let normalized = min(max(seconds, 0), 3600)
        pushIntervalDraft = String(normalized)
        guard normalized != configStore.config.effectiveSyncConfig.pushIntervalSeconds else {
            clearSaveError(.pushInterval)
            return
        }
        persist(.pushInterval) { $0.pushIntervalSeconds = normalized }
    }

    func submitHubURL() { cancel(.hubURL); commit(.hubURL) }
    func submitNodeName() { cancel(.nodeName); commit(.nodeName) }
    func submitPort() { cancel(.port); commit(.port) }

    /// Flush pending valid drafts when leaving the pane; invalid URL/port values still reject.
    func flushPendingEdits() {
        cancelAll()
        commit(.hubURL)
        commit(.nodeName)
        commit(.port)
    }

    private func schedule(_ field: Field) {
        cancel(field)
        let delay = debounceNanoseconds
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.commit(field)
        }
        switch field {
        case .hubURL: hubURLTask = task
        case .nodeName: nodeNameTask = task
        case .port: portTask = task
        case .enabled, .pushInterval: break
        }
    }

    private func cancel(_ field: Field) {
        switch field {
        case .hubURL: hubURLTask?.cancel(); hubURLTask = nil
        case .nodeName: nodeNameTask?.cancel(); nodeNameTask = nil
        case .port: portTask?.cancel(); portTask = nil
        case .enabled, .pushInterval: break
        }
    }

    private func cancelAll() {
        cancel(.hubURL)
        cancel(.nodeName)
        cancel(.port)
    }

    private func commit(_ field: Field) {
        cancel(field)
        switch field {
        case .hubURL:
            let trimmed = hubURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            switch SettingsSyncPane.checkHubURL(trimmed) {
            case .invalid(let message): hubURLError = message; return
            case .valid: hubURLError = nil
            }
            guard trimmed != configStore.config.effectiveSyncConfig.hubURL else {
                clearSaveError(.hubURL)
                return
            }
            persist(.hubURL) { $0.hubURL = trimmed }
        case .nodeName:
            guard nodeNameDraft != configStore.config.effectiveSyncConfig.nodeName else {
                clearSaveError(.nodeName)
                return
            }
            persist(.nodeName) { $0.nodeName = nodeNameDraft }
        case .port:
            let current = configStore.config.effectiveSyncConfig.hubPort
            switch SettingsSyncPane.portCommit(draft: portDraft, stored: current) {
            case .invalid:
                portDraft = String(current)
                clearSaveError(.port)
            case .unchanged: clearSaveError(.port)
            case .apply(let port): persist(.port) { $0.hubPort = port }
            }
        case .enabled, .pushInterval:
            break
        }
    }

    private func persist(_ field: Field, mutate: (inout SyncConfig) -> Void) {
        var config = configStore.config
        var sync = config.effectiveSyncConfig
        mutate(&sync)
        config.sync = sync
        do {
            try configStore.applyAndSave(config)
            clearSaveError(field)
        } catch {
            saveErrors[field] = "保存失败：\(error.localizedDescription)"
            logError("[fleet-settings] 保存 sync 配置失败: \(error.localizedDescription)")
        }
    }

    private func clearSaveError(_ field: Field) {
        saveErrors[field] = nil
    }

    private func applyPersistedConfig(_ config: AppConfig) {
        let sync = config.effectiveSyncConfig
        if sync.enabled != enabledBaseline {
            enabledBaseline = sync.enabled
            clearSaveError(.enabled)
        }
        if sync.hubURL != hubURLBaseline {
            cancel(.hubURL)
            hubURLBaseline = sync.hubURL
            hubURLDraft = sync.hubURL
            hubURLError = nil
            clearSaveError(.hubURL)
        }
        if sync.nodeName != nodeNameBaseline {
            cancel(.nodeName)
            nodeNameBaseline = sync.nodeName
            nodeNameDraft = sync.nodeName
            clearSaveError(.nodeName)
        }
        if sync.hubPort != portBaseline {
            cancel(.port)
            portBaseline = sync.hubPort
            portDraft = String(sync.hubPort)
            clearSaveError(.port)
        }
        if sync.pushIntervalSeconds != pushIntervalBaseline {
            pushIntervalBaseline = sync.pushIntervalSeconds
            pushIntervalDraft = String(sync.pushIntervalSeconds)
            clearSaveError(.pushInterval)
        }
    }
}

/// 设置页「多机联动」pane（§10.4）。副节点 / 主节点两套视角由 `hubURL` 派生。
///
/// 持久化走 `ConfigStore.applyAndSave` **写穿**（toggle / 字段回车即存盘），
/// 不进设置窗的草稿-保存事务：同步配置是机器身份类设置，立即生效正是这个
/// pane 的语义——角色切换、端口监听都不该等一次「保存」。
///
/// 排版走设置页统一组件（`SettingsSection` / `SettingsToggleRow` /
/// `SettingsControlRow`），与其余 pane 同一套行距与控件宽度。
struct SettingsSyncPane: View {
    @ObservedObject var state: AppState
    @StateObject private var lanAddressMonitor = LANAddressMonitor()
    @ObservedObject private var drafts: SettingsSyncDraftController
    /// 配置分段：0 = 主节点配置，1 = 副节点配置（UI 组织用；实际角色仍由
    /// 上级地址是否为空派生——填了地址就是副节点，清空就是主节点）。
    @State private var configSegment = 0

    @MainActor
    init(state: AppState, drafts: SettingsSyncDraftController? = nil) {
        self.state = state
        let controller = drafts ?? SettingsSyncDraftController(configStore: state.configStore)
        _drafts = ObservedObject(wrappedValue: controller)
    }

    var draftController: SettingsSyncDraftController { drafts }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "多机联动",
                footer: "多副一主：留空主节点地址 = 本机是主节点（接收并合并副节点报告）；填地址 = 本机是副节点（只上报、不监听端口）。修改后自动保存并即时生效（亦可按回车立即生效）。"
            ) {
                SettingsToggleRow(label: "启用多机联动", isOn: Binding(
                    get: { syncConfig.enabled },
                    set: { value in drafts.setEnabled(value) }
                ))
                if let error = drafts.saveError(for: .enabled) {
                    saveErrorLabel(error)
                }
                roleStatusRow
                nodeNameRow
                Picker("", selection: $configSegment) {
                    Text("主节点配置").tag(0)
                    Text("副节点配置").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                if configSegment == 0 {
                    hubFields
                } else {
                    nodeFields
                }
            }

            if syncConfig.enabled {
                connectionSection
                quotaSourceSection
                if state.fleetAttributionInconsistent {
                    attributionNotice
                }
            }
        }
        .onAppear {
            configSegment = role == .node ? 1 : 0
            lanAddressMonitor.start()
        }
        .onDisappear {
            drafts.flushPendingEdits()
            lanAddressMonitor.stop()
        }
        // 配置管线每次落盘后（rebuildStatuses → statusDidChange）强制重排：
        // 角色行/连接徽标读的是 configStore.config，AppState 自己不发
        // objectWillChange，不挂这条保存后界面会停留在旧角色。
        .onReceive(state.statusDidChange) { _ in }
    }

    // MARK: - 基础

    private var syncConfig: SyncConfig {
        state.configStore.config.effectiveSyncConfig
    }

    private var role: SyncRole {
        SyncRole.derive(config: state.configStore.config)
    }

    /// 本机名称：默认值在输入框 placeholder 展示。
    private var nodeNameRow: some View {
        SettingsControlRow("本机名称") {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("", text: Binding(
                    get: { drafts.nodeNameDraft },
                    set: { drafts.setNodeNameDraft($0) }
                ), prompt: Text("默认：\(SyncConfig.defaultNodeName())"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: SettingsLayout.standardControlWidth)
                    .onSubmit(drafts.submitNodeName)
                    .help("其他机器的菜单节点分组里显示这个名字；留空 = 默认名称。修改后自动保存并即时生效（亦可按回车立即生效）。")
                if let error = drafts.saveError(for: .nodeName) {
                    saveErrorLabel(error)
                }
            }
        }
    }

    /// 连接状态（只读）：主节点 = 监听情况；副节点 = 与主节点的连接情况。
    /// 角色不再用文字复述——分段选择与上级地址的填空已表达角色。
    ///
    /// 失败原因（`fleetRuntimeStatus.lastError`）必须一并露出来：只写「离线」
    /// 两个字时用户无从下手（地址写错 / 漏了 scheme / 主节点没开 / 端口不通）。
    /// 该字段是 `@Published` 驱动的，运行时失败原因一变这里就跟着变。
    private var roleStatusRow: some View {
        SettingsControlRow("连接状态", alignment: .top) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.connectionText(
                    enabled: syncConfig.enabled,
                    role: role,
                    hubPort: syncConfig.hubPort,
                    status: state.fleetRuntimeStatus
                ))
                    .font(SettingsTypography.status)
                    .foregroundStyle(syncConfig.enabled && state.fleetRuntimeStatus.online ? .green : .secondary)
                    .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                if syncConfig.enabled,
                   let lastError = Self.visibleConnectionError(
                    enabled: syncConfig.enabled,
                    lastError: state.fleetRuntimeStatus.lastError
                   ), !lastError.isEmpty {
                    Text(lastError)
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func connectionText(
        enabled: Bool,
        role: SyncRole,
        hubPort: Int,
        status: FleetSyncStatusInfo
    ) -> String {
        guard enabled else { return "未启用" }
        if role == .hub {
            return status.online
                ? "监听中（端口 \(hubPort)）"
                : "未监听"
        }
        guard status.online else { return "离线" }
        return "已连接\(status.lastSyncAt.map { " · 上次同步 \(Formatters.formatClock($0))" } ?? "")"
    }

    static func visibleConnectionError(enabled: Bool, lastError: String?) -> String? {
        enabled ? lastError : nil
    }

    private func saveErrorLabel(_ message: String) -> some View {
        Text(message)
            .font(SettingsTypography.metadata)
            .foregroundStyle(.red)
            .multilineTextAlignment(.trailing)
            .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 主节点配置：监听端口在前；主节点地址（本机局域网 IP）右侧「复制」。
    @ViewBuilder
    private var hubFields: some View {
        SettingsControlRow("监听端口") {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("", text: Binding(
                    get: { drafts.portDraft },
                    set: { drafts.setPortDraft($0) }
                ), prompt: Text("8787"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .onSubmit(drafts.submitPort)
                    .help("修改后自动保存并即时生效（亦可按回车立即生效）")
                if let error = drafts.saveError(for: .port) {
                    saveErrorLabel(error)
                }
            }
        }
        SettingsControlRow("主节点地址") { hubAddressControl }
    }

    /// 主节点地址一格：地址文案 + 「复制」。
    ///
    /// 局域网地址来自异步缓存（`getifaddrs` 不在 View 求值期间执行）。取不到时给的是提示而不是
    /// 地址——127.0.0.1 只有本机能访问，副节点拿它当主节点地址永远连不上，
    /// 摆在「主节点地址」这一格里等于骗用户去复制一条废地址。
    ///
    /// 探测与挑选规则见 `LANAddressResolver`：按硬件语义挑接口
    /// （Wi-Fi → 有线 → 其它），排除虚拟 / 桥接接口，不拿 127.0.0.1 兜底。
    private var hubAddressControl: some View {
        let addressText = lanAddressMonitor.address.map { "http://\($0):\(syncConfig.hubPort)" }
        return HStack(spacing: 8) {
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(addressText ?? "未检测到局域网地址")
                    .font(SettingsTypography.status)
                    .foregroundStyle(addressText == nil ? .orange : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if addressText == nil {
                    Text("请检查网络连接")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button("复制") {
                guard let addressText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addressText, forType: .string)
            }
            .disabled(addressText == nil)
        }
        .frame(width: SettingsLayout.standardControlWidth)
    }

    /// 副节点配置：上报频率滑条（0 = 跟随常规里的全局刷新间隔）+ 主节点地址。
    @ViewBuilder
    private var nodeFields: some View {
        SettingsControlRow("主节点地址", alignment: .top) {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("", text: Binding(
                    get: { drafts.hubURLDraft },
                    set: { drafts.setHubURLDraft($0) }
                ), prompt: Text("http://192.168.1.20:8787"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: SettingsLayout.standardControlWidth)
                    .onSubmit(drafts.submitHubURL)
                    .help("清空则本机变回主节点。修改后自动保存并即时生效（亦可按回车立即生效）")
                // 校验不过时的原因就地显示：地址没落盘，用户看得见自己输的是什么、
                // 为什么不能用（行内错误文案来自 `checkHubURL`）。
                if let hubURLError = drafts.hubURLError {
                    Text(hubURLError)
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .frame(width: SettingsLayout.standardControlWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = drafts.saveError(for: .hubURL) {
                    saveErrorLabel(error)
                }
            }
        }
        SettingsControlRow("上报频率", alignment: .top) {
            VStack(alignment: .trailing, spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(Int(drafts.pushIntervalDraft) ?? 0) },
                        set: { drafts.setPushInterval(Int($0)) }
                    ),
                    in: 0...3600,
                    label: { EmptyView() },
                    minimumValueLabel: {
                        Text("跟随常规").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    },
                    maximumValueLabel: {
                        Text("1 小时").font(SettingsTypography.metadata).foregroundStyle(.secondary)
                    }
                )
                Text("当前：\(Self.pushIntervalText(drafts.pushIntervalDraft))")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
                if let error = drafts.saveError(for: .pushInterval) {
                    saveErrorLabel(error)
                }
            }
            .frame(width: SettingsLayout.standardControlWidth)
        }
    }

    private static func pushIntervalText(_ raw: String) -> String {
        guard let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) else { return "跟随常规" }
        return seconds <= 0 ? "跟随常规（全局刷新间隔）" : Formatters.formatInterval(seconds: seconds)
    }


    // MARK: - 已连接节点（主节点视角，不含本机）

    /// 副节点列表只列**别人**：hub 自己虽以节点身份参加合并（§7.2），
    /// 但它对本机用户不是「连接对象」，列出来只有噪音。
    private var remoteNodes: [FleetNodeSnapshot] {
        guard let snapshot = state.fleetSnapshot else { return [] }
        return snapshot.nodes.filter { $0.nodeID != state.fleetLocalNodeID }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if role == .hub {
            SettingsSection(
                title: "已连接节点",
                footer: "副节点在 config.json 填上面的地址即可接入。离线节点在保留期内仍计入同日合计；「移除」删除该节点的全部同步数据。"
            ) {
                if remoteNodes.isEmpty {
                    Text("暂无副节点上报")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                }
                ForEach(remoteNodes, id: \.nodeID) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.nodeName)
                            Text("最后上报 \(Formatters.formatClock(node.lastSeenAt)) · seq \(node.seq)")
                                .font(SettingsTypography.status)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(node.stale ? "离线" : "在线")
                            .foregroundStyle(node.stale ? .orange : .green)
                            .font(SettingsTypography.status)
                        Button("移除") {
                            state.fleetSync?.removeNodeFromFleet(nodeID: node.nodeID)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 各 provider 额度来源（§10.3 / §7.7）

    private var quotaSourceSection: some View {
        SettingsSection(
            title: "各 Provider 的额度来源",
            footer: "生效额度 = 本机有效额度优先，否则取 fleet 选举结果；菜单、图标与卡片读的都是这一份。"
        ) {
            ForEach(ProviderKind.allCases, id: \.providerID) { kind in
                let effective = state.fleetEffectiveQuota(for: kind)
                HStack {
                    Text(state.descriptors.first { $0.kind == kind }?.displayName ?? kind.providerID)
                    Spacer()
                    Text(effective.quota == nil
                         ? "无"
                         : (effective.isLocal ? "本机" : (effective.sourceTagText ?? "远端")))
                        .foregroundStyle(effective.isStale ? .orange : .secondary)
                        .font(SettingsTypography.status)
                }
            }
        }
    }

    /// 归因指纹不一致 → 标黄提示（§7.8：不阻断、不弹窗）。
    private var attributionNotice: some View {
        SettingsSection(title: "归因设置不一致") {
            Label(
                "各机的客户端 × Provider 归因不同，全局数字为各机口径之和",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(SettingsTypography.status)
        }
    }

    // MARK: - 持久化（写穿）

    /// 主节点地址校验结果。空串合法（清空 = 本机变回主节点）；非空必须能解析成
    /// http/https URL 且 host 非空。
    enum HubURLCheck: Equatable {
        case valid
        case invalid(String)
    }

    /// 主节点地址校验。规则与 `SyncClient.init` 的解析口径一致（能解析成 URL、
    /// scheme 是 http/https、host 非空），**同一把尺子**——这里放过的东西到了
    /// 运行期也一定能用，不会出现「设置页说填好了、连的时候才炸」。
    static func checkHubURL(_ raw: String) -> HubURLCheck {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 清空 = 本机变回主节点（`SyncRole.derive` 按「空即 hub」派生），合法。
        if trimmed.isEmpty { return .valid }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else {
            return .invalid(
                "主节点地址需为完整地址（http:// 或 https:// 开头），例如 http://192.168.1.20:8787"
            )
        }
        return .valid
    }

    /// 端口字段的提交判定。
    enum PortCommit: Equatable {
        /// 与已存值相同：不落盘。
        case unchanged
        /// 合法的新端口：落盘。
        case apply(Int)
        /// 非法（不是整数 / 超出 1...65535）：不落盘，输入框回滚到已存值。
        case invalid
    }

    /// 端口草稿的落盘判定。
    static func portCommit(draft: String, stored: Int) -> PortCommit {
        guard let port = Int(draft.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return .invalid }
        return port == stored ? .unchanged : .apply(port)
    }

}
