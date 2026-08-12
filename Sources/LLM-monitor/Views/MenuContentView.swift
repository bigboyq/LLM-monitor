import SwiftUI

/// MenuBarExtra 点开后看到的主面板 — **纯展示**，无 sheet 无交互弹窗
struct MenuContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var loginItemService: LoginItemService
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
            footerBar
        }
        .frame(width: 360)
        .background {
            MenuPanelSurface()
        }
        .background(MenuWindowAutoCloseBridge())
        // F4: 高度上限直接施加在 NSWindow 上（contentMaxSize），不靠 SwiftUI
        // frame 拼凑。下面 fixedSize 让窗口按内容自然决定高度；window 的
        // contentMaxSize 限制它不超过屏幕可见高度的 70%。卡片少→窗口矮，全显示；
        // 卡片多到超过 70%→窗口封顶，内部 ScrollView 滚动。
        .background(MenuPanelHeightBridge())
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            let needsFetch = state.statuses.contains { s in
                if case .ready = s.state { return true }
                return false
            }
            if needsFetch {
                Task { await state.refreshAll() }
            }
            loginItemService.refreshStatus()
        }
        // 显式 .onReceive 强制 SwiftUI 订阅 publisher，绕开 MenuBarExtra 的 view 缓存
        // （@ObservedObject 在 MenuBarExtra 上有时不触发 body 重 eval）。
        // AppState 的所有 status 变更入口（mutateStatus / rebuildStatuses / setScanningState /
        // apply*LocalUsage）都 fire `statusDidChange`，view 端挂这一个就够了。
        .onReceive(state.statusDidChange) { _ in }
    }

    // MARK: - header（紧凑 padding）

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("LLM Monitor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryLabel)
            Spacer()
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 24, alignment: .trailing)
                    .help("正在刷新")
            } else {
                Button(action: { Task { await state.refreshAll() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        // 点击区域保留 26pt，但图标本身右对齐到卡片外边缘。
                        .frame(width: 26, height: 24, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("立即刷新全部")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
    }

    // MARK: - content（卡片过多时滚动，避免菜单超出屏幕）

    @ViewBuilder
    private var content: some View {
        let cards = state.statuses.filter { $0.isEnabled }

        if cards.isEmpty {
            VStack(spacing: 8) {
                if state.statuses.isEmpty {
                    Text("没有注册 provider")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("打开配置文件") { state.openConfigFile() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                } else {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("暂无启用的 Provider 监控")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primaryLabel)
                    Text("可在设置中勾选需要监控的 Provider")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("打开设置") {
                        openSettingsWindow()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    if Self.shouldShowSetupGuide(for: cards) {
                        setupGuide
                    }
                    ForEach(cards) { status in
                        ProviderCardView(status: status)
                            .contextMenu {
                                Button("立即刷新") {
                                    Task { await state.refreshOne(providerID: status.id) }
                                }
                                Button("打开配置文件…") {
                                    state.openConfigFile()
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    /// Four registered cards can all be `.notConfigured` on first launch because
    /// the template intentionally contains no usable credentials. Keep the
    /// existing passive card layout, but add one actionable route to Settings.
    static func shouldShowSetupGuide(for statuses: [ProviderStatus]) -> Bool {
        !statuses.isEmpty && statuses.allSatisfy {
            if case .notConfigured = $0.state { return true }
            return false
        }
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("开始配置 provider", systemImage: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
            Text("打开设置，启用 provider 并填写 API Key，或完成本地登录。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("打开设置") {
                openSettingsWindow()
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openSettingsWindow() {
        SettingsWindowActivator.prepareForOpening()
        openSettings()
    }

    // MARK: - footer（紧凑 padding）



    private var footerBar: some View {
        HStack(spacing: 10) {
            footerStatus
            Spacer()
            FooterActionButton(icon: "gearshape", title: "设置") {
                    openSettingsWindow()
                }
                .help("打开设置面板")
            footerSeparator
            FooterActionButton(icon: "doc.text.magnifyingglass", title: "日志") {
                state.revealLogFile()
            }
                .help("在 Finder 中显示 log.txt")
            footerSeparator
            FooterActionButton(icon: "xmark.circle", title: "退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var footerStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
            if let last = state.lastRefreshAt {
                Text("更新于 \(Formatters.formatClock(last))")
            } else if let next = state.nextRefreshAt {
                Text("下次 \(Formatters.formatClock(next))")
            } else {
                Text("就绪")
            }
            
            footerSeparator
            
            Text("自启 \(loginItemService.isEnabled ? "✓" : "✗")")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color.secondary.opacity(0.75))
    }

    private var footerSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 10)
    }
}

/// 菜单整体背景：macOS 26 交给 MenuBarExtra 的系统 popover 提供 Liquid Glass，
/// 避免在系统玻璃上再叠一层自定义 glassEffect；旧系统回退到标准材质。
/// Header / content / footer 共用这一层，避免被 Divider 切成三个视觉区域。
private struct MenuPanelSurface: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            // MenuBarExtra(.window) 已经拥有系统 Liquid Glass 背景。
            // 这里保持透明，让 header / content / footer 共享同一层系统材质。
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

/// F4: 附着到实际 menu window，直接设置 `window.contentMaxSize` =
/// `floor(visibleFrame.height × 0.70)`。高度上限放在 NSWindow 层，不靠 SwiftUI
/// frame 拼凑：`fixedSize` 让窗口按内容自然决定高度，`contentMaxSize` 只负责
/// “别超过屏幕可见高度的 70%”。卡片少→窗口矮、全显示；卡片多→窗口封顶、内部
/// ScrollView 滚动。读取 `window.screen`（菜单所在屏），不用 `NSScreen.main`。
private struct MenuPanelHeightBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> HeightProbeView {
        HeightProbeView()
    }

    func updateNSView(_ nsView: HeightProbeView, context: Context) {
        nsView.applyMaxSize()
    }

    final class HeightProbeView: NSView {
        private var lastMaxHeight: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 每次菜单窗口出现（viewDidMoveToWindow）都按当前所在屏重算 contentMaxSize。
            // MenuBarExtra popover 失焦即关、下次在当前屏重新出现，所以不需要单独监听
            // didChangeScreenNotification（也避免了 Swift 6 下 deinit 访问非 Sendable
            // observer token 的严格并发问题）。
            applyMaxSize()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // 屏幕分辨率/Dock 变化后 visibleFrame 会变，借 updateTrackingAreas 重新核对。
            applyMaxSize()
        }

        func applyMaxSize() {
            guard let window, let screen = window.screen else { return }
            let maxHeight = floor(screen.visibleFrame.height * 0.70)
            guard maxHeight != lastMaxHeight else { return }
            lastMaxHeight = maxHeight
            // contentMaxSize 限制窗口最大 content 尺寸；宽度固定 360。
            window.contentMaxSize = NSSize(width: 360, height: maxHeight)
        }
    }
}

@MainActor
private enum SettingsWindowActivator {
    static func prepareForOpening() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FooterActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(Color.secondary.opacity(0.82))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
