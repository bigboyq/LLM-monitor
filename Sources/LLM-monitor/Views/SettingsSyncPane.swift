import SwiftUI
import AppKit

/// 设置页「多机联动」pane（§10.4）。副节点 / 主节点两套视角由 `hubURL` 派生。
///
/// 持久化走 `ConfigStore.applyAndSave` **写穿**（toggle / 字段 commit 即存盘），
/// 不进设置窗的草稿-保存事务：同步配置是机器身份类设置（与 `providerCardOrder`
/// 那类草稿字段不同），立即生效正是这个 pane 的语义——角色切换、端口监听
/// 都不该等一次「保存」。
struct SettingsSyncPane: View {
    @ObservedObject var state: AppState

    @State private var hubURLDraft = ""
    @State private var nodeNameDraft = ""
    @State private var portDraft = ""
    @State private var pushIntervalDraft = ""

    var body: some View {
        Form {
            Section("多机联动") {
                enabledToggle
            }
            if syncConfig.enabled {
                roleFields
                connectionSection
                quotaSourceSection
                if state.fleetAttributionInconsistent {
                    attributionNotice
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadDrafts() }
    }

    // MARK: - 基础

    private var syncConfig: SyncConfig {
        state.configStore.config.effectiveSyncConfig
    }

    private var role: SyncRole {
        SyncRole.derive(config: state.configStore.config)
    }

    private var enabledToggle: some View {
        Toggle("启用多机联动", isOn: Binding(
            get: { syncConfig.enabled },
            set: { value in update { $0.enabled = value } }
        ))
    }

    /// 角色字段：hubURL 空 = 本机是主节点；非空 = 副节点（§6.4）。
    @ViewBuilder
    private var roleFields: some View {
        Section("本机角色") {
            TextField(
                "上级主节点地址（留空 = 本机为主节点）",
                text: $hubURLDraft
            )
            .onSubmit { commitHubURL() }
            if role == .node {
                HStack {
                    Text("角色：副节点 · 定期上报并同步全局快照")
                    Spacer()
                    connectionBadge
                }
                LabeledContent("上报周期（秒）") {
                    TextField("60", text: $pushIntervalDraft)
                        .frame(width: 80)
                        .onSubmit { commitPushInterval() }
                }
            } else if role == .hub {
                HStack {
                    Text("角色：主节点 · 接收并合并副节点报告")
                    Spacer()
                    connectionBadge
                }
                LabeledContent("监听端口") {
                    TextField("8787", text: $portDraft)
                        .frame(width: 80)
                        .onSubmit { commitPort() }
                }
                copyAddressButton
            }
            LabeledContent("本机名称（空 = hostname）") {
                TextField(NodeIdentityStore.defaultNodeName(), text: $nodeNameDraft)
                    .frame(width: 200)
                    .onSubmit { commitNodeName() }
            }
        }
    }

    private var connectionBadge: some View {
        Group {
            if state.fleetRuntimeStatus.online {
                Text("已连接\(state.fleetRuntimeStatus.lastSyncAt.map { " · 上次同步 \(Formatters.formatClock($0))" } ?? "")")
                    .foregroundStyle(.green)
            } else if role != .off {
                Text("离线")
                    .foregroundStyle(.secondary)
            }
        }
        .font(SettingsTypography.status)
    }

    /// 主节点「复制地址」：副节点粘这个就行（§10.4）。
    private var copyAddressButton: some View {
        HStack {
            let address = "http://\(Self.lanAddress()):\(syncConfig.hubPort)"
            Text("副节点地址：\(address)")
                .font(SettingsTypography.status)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("复制地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }
        }
    }

    // MARK: - 连接 / 节点（主节点视角）

    @ViewBuilder
    private var connectionSection: some View {
        if role == .hub, let snapshot = state.fleetSnapshot {
            Section("已连接节点") {
                if snapshot.nodes.isEmpty {
                    Text("暂无副节点上报。副节点在 config.json 配 \(syncConfig.hubPort) 端口地址即可接入。")
                        .font(SettingsTypography.status)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.nodes, id: \.nodeID) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.nodeName + (node.nodeID == state.fleetLocalNodeID ? "（本机）" : ""))
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
            Section("已收到的全局摘要") {
                if let today = snapshot.fleet.dailyBuckets.last {
                    LabeledContent("节点数") { Text("\(snapshot.nodes.count)") }
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
        Section("各 Provider 的额度来源") {
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
        Section {
            Label(
                "归因设置不一致：各机的客户端 × Provider 归因不同，全局数字为各机口径之和",
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
