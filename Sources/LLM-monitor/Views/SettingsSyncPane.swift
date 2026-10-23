import SwiftUI
import AppKit

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

    @State private var hubURLDraft = ""
    @State private var nodeNameDraft = ""
    @State private var portDraft = ""
    @State private var pushIntervalDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "多机联动",
                footer: "多副一主：留空主节点地址 = 本机是主节点（接收并合并副节点报告）；填地址 = 本机是副节点（只上报、不监听端口）。文本修改后按回车保存，立即生效。"
            ) {
                SettingsToggleRow(label: "启用多机联动", isOn: Binding(
                    get: { syncConfig.enabled },
                    set: { value in update { $0.enabled = value } }
                ))
                if syncConfig.enabled {
                    SettingsControlRow("上级主节点地址") {
                        TextField("", text: $hubURLDraft, prompt: Text("http://192.168.1.20:8787（留空 = 本机为主节点）"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsLayout.standardControlWidth)
                            .onSubmit(commitHubURL)
                            .help("按回车保存；留空时本机作为主节点")
                    }
                    roleStatusRow
                    if role == .hub {
                        hubFields
                    } else if role == .node {
                        nodeFields
                    }
                    SettingsControlRow("本机名称") {
                        TextField("", text: $nodeNameDraft, prompt: Text("默认 hostname"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsLayout.standardControlWidth)
                            .onSubmit(commitNodeName)
                            .help("其他机器的菜单节点分组里显示这个名字；默认 \(NodeIdentityStore.defaultNodeName())。按回车保存。")
                    }
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
        .onAppear { loadDrafts() }
    }

    // MARK: - 基础

    private var syncConfig: SyncConfig {
        state.configStore.config.effectiveSyncConfig
    }

    private var role: SyncRole {
        SyncRole.derive(config: state.configStore.config)
    }

    /// 角色是派生值（hubURL 决定），只读展示 + 连接状态徽标。
    private var roleStatusRow: some View {
        HStack {
            Text(roleTitle)
                .font(SettingsTypography.rowLabel)
                .foregroundStyle(.primary)
            Spacer()
            connectionBadge
        }
    }

    private var roleTitle: String {
        switch role {
        case .hub: return "角色：主节点 · 接收并合并副节点报告"
        case .node: return "角色：副节点 · 定期上报并同步全局快照"
        case .off: return "角色：未启用"
        }
    }

    private var connectionBadge: some View {
        Group {
            if state.fleetRuntimeStatus.online {
                Text("已连接\(state.fleetRuntimeStatus.lastSyncAt.map { " · 上次同步 \(Formatters.formatClock($0))" } ?? "")")
                    .foregroundStyle(.green)
            } else {
                Text(role == .hub ? "监听中" : "离线")
                    .foregroundStyle(.secondary)
            }
        }
        .font(SettingsTypography.status)
    }

    @ViewBuilder
    private var hubFields: some View {
        SettingsControlRow("监听端口") {
            TextField("", text: $portDraft, prompt: Text("8787"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit(commitPort)
                .help("按回车保存")
        }
        copyAddressButton
    }

    @ViewBuilder
    private var nodeFields: some View {
        SettingsControlRow("上报周期（秒）") {
            TextField("", text: $pushIntervalDraft, prompt: Text("60"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit(commitPushInterval)
                .help("按回车保存")
        }
    }

    /// 主节点「复制地址」：副节点粘这个就行（§10.4）。
    private var copyAddressButton: some View {
        HStack(spacing: 8) {
            Text("副节点地址：\(lanAddress)")
                .font(SettingsTypography.status)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("复制地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lanAddress, forType: .string)
            }
        }
    }

    private var lanAddress: String {
        "http://\(Self.lanAddress()):\(syncConfig.hubPort)"
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
            SettingsSection(title: "全局摘要") {
                if let snapshot = state.fleetSnapshot,
                   let today = snapshot.fleet.dailyBuckets.last {
                    LabeledContent("fleet 节点数（含本机）") {
                        Text("\(snapshot.nodes.count)")
                    }
                    LabeledContent("今日全部 token") {
                        Text(Formatters.formatTokenCountCompact(
                            today.totals.input + today.totals.cacheRead
                                + today.totals.output + today.totals.reasoning
                        ))
                    }
                } else {
                    Text("暂无全局数据")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
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

    private func update(_ mutate: (inout SyncConfig) -> Void) {
        var config = state.configStore.config
        var sync = config.sync ?? SyncConfig.default
        mutate(&sync)
        config.sync = sync
        do {
            try state.configStore.applyAndSave(config)
        } catch {
            logError("[fleet-settings] 保存 sync 配置失败: \(error.localizedDescription)")
        }
    }

    private func loadDrafts() {
        hubURLDraft = syncConfig.hubURL
        nodeNameDraft = syncConfig.nodeName
        portDraft = String(syncConfig.hubPort)
        pushIntervalDraft = String(syncConfig.pushIntervalSeconds)
    }

    private func commitHubURL() {
        update { $0.hubURL = hubURLDraft }
    }

    private func commitNodeName() {
        update { $0.nodeName = nodeNameDraft }
    }

    private func commitPort() {
        guard let port = Int(portDraft.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return }
        update { $0.hubPort = port }
    }

    private func commitPushInterval() {
        guard let seconds = Int(pushIntervalDraft.trimmingCharacters(in: .whitespaces)), seconds >= 5 else { return }
        update { $0.pushIntervalSeconds = seconds }
    }

    /// 本机局域网地址（en0 优先）；拿不到时退化 localhost——地址文本只是给用户
    /// 复制的建议值，真实连通性由副节点侧的 health 校验兜底。
    static func lanAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let current = cursor {
                let interface = current.pointee
                if let name = String(validatingUTF8: interface.ifa_name), name.hasPrefix("en"),
                   interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let sockaddrIn = interface.ifa_addr.withMemoryRebound(
                        to: sockaddr_in.self, capacity: 1
                    ) { $0.pointee }
                    var addr = sockaddrIn.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let candidate = String(cString: buffer)
                        if candidate != "127.0.0.1" {
                            address = candidate
                            break
                        }
                    }
                }
                cursor = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address ?? "127.0.0.1"
    }
}
