import SwiftUI

/// MenuBarExtra label is always mounted, including while the menu itself is closed.
/// It is therefore a stable public-API bridge for both menu actions and notification
/// responses, without relying on private window/controller discovery.
struct ProviderDetailRouteBridge: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                if state.pendingProviderDetailRoute != nil { openDetailWindow() }
            }
            .onReceive(state.providerDetailRouteRequests) { _ in
                openDetailWindow()
            }
    }

    private func openDetailWindow() {
        MenuBarAppActivation.activateForWindowPresentation()
        openWindow(id: ProviderDetailWindowView.windowID)
    }
}

/// A single reusable window with the complete shared ProviderCardView. AppState
/// retains the latest route in memory so a scene mounted after the request can
/// recover it; repeated requests also travel through the request publisher.
struct ProviderDetailWindowView: View {
    static let windowID = "provider-detail"

    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore
    @Environment(\.openSettings) private var openSettings
    @State private var route: ProviderDetailRoute?
    @State private var displayClock = DisplayClock()

    var body: some View {
        Group {
            if let route {
                detail(for: route)
            } else {
                ContentUnavailableView("没有待查看的 Provider", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .frame(minWidth: EdgeDockTheme.popoverWidth, idealWidth: EdgeDockTheme.popoverWidth, minHeight: 420, idealHeight: 700)
        .onAppear(perform: receivePendingRoute)
        .onReceive(state.providerDetailRouteRequests) { route in
            self.route = route
            displayClock.start()
        }
        .onDisappear {
            displayClock.stop()
        }
    }

    @ViewBuilder
    private func detail(for route: ProviderDetailRoute) -> some View {
        switch ProviderDetailRouting.target(
            route: route,
            statuses: state.statuses,
            descriptors: state.descriptors
        ) {
        case .enabled(let status):
            DisplayClockScope(clock: displayClock) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let modelName = route.modelName {
                            Label("通知关联模型：\(modelName)", systemImage: "bell.badge")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ProviderCardView(
                            status: status,
                            fleet: state.fleetCardContext(for: status.kind),
                            isPinnedToStatusBar: configStore.config.statusBarPinnedProvider == status.id,
                            presentation: .complete,
                            configStore: configStore
                        )
                    }
                    .frame(minWidth: EdgeDockTheme.popoverWidth - LayoutMetrics.cardColumnHorizontalPadding * 2, maxWidth: .infinity)
                    .padding(.horizontal, LayoutMetrics.cardColumnHorizontalPadding)
                    .padding(.vertical, LayoutMetrics.cardColumnHorizontalPadding)
                }
                .environment(\.hoverRevealMode, .alwaysVisible)
                .environment(\.usageHistoryLayoutMode, .expanded)
                .environment(\.quotaWindowSegmentEditable, true)
                .environment(\.cardQuotaRefreshAction, { id in
                    Task { await state.refreshOne(providerID: id) }
                })
                .environment(\.cardUsageRefreshAction, {
                    Task { await state.triggerLocalUsageRescan() }
                })
                .environment(\.cardPinStatusBarAction, { id in
                    state.toggleStatusBarPinnedProvider(id)
                })
            }
            .onAppear { displayClock.start() }
        case .disabled(let kind):
            unavailable(
                title: "Provider 已停用",
                detail: "该 Provider 当前未启用。启用并完成配置后，完整详情会显示在这里。",
                settingsTab: state.descriptors.first(where: { $0.kind == kind }).map(SettingsTab.provider) ?? .notifications
            )
        case .missing:
            unavailable(
                title: "Provider 不可用",
                detail: "通知关联的 Provider 已不在当前版本中。可以检查通知配置。",
                settingsTab: .notifications
            )
        }
    }

    private func unavailable(title: String, detail: String, settingsTab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.circle")
                .font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
            Button("打开相关设置") {
                state.pendingSettingsTab = settingsTab
                MenuBarAppActivation.activateForWindowPresentation()
                openSettings()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("打开相关设置")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func receivePendingRoute() {
        if let pending = state.pendingProviderDetailRoute { route = pending }
        displayClock.start()
    }
}
