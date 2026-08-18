import Foundation

/// 注册一个 provider 需要的全部元信息。
///
/// 单例 source of truth — `LLMMonitorApp.makeDescriptors()` 构造，
/// 传给 `ConfigStore.ensureProvidersPresent` / `AppState` / `SettingsView` 用于
/// 状态派生跟设置面板 tab 渲染。provider id、displayName 和 fetcher 构造参数
/// 都集中在 `makeDescriptors`；provider 特有的设置 pane 仍由 SettingsView 路由。
struct FetcherDescriptor: Identifiable, Sendable {
    let id: String
    let displayName: String
    let kind: ProviderKind
    let iconSystemName: String
    let accentColor: AccentColor

    /// 给定该 provider 的完整配置构造 fetcher。API-key、auth path 或本地服务等
    /// provider 特有认证都封装在注册点，AppState 不再按 kind 重复构造逻辑。
    let makeFetcher: @Sendable (ProviderConfig) -> any QuotaFetcher

    // MARK: - Settings panel metadata

    /// SettingsView tab 标题（默认走 `displayName`）。
    let settingsTabTitle: String?
    /// SettingsView tab 副标题（"刷新节奏 / 认证信息"等 provider 特定说明）。
    let settingsTabSubtitle: String?

    init(
        id: String,
        displayName: String,
        kind: ProviderKind,
        iconSystemName: String,
        accentColor: AccentColor,
        makeFetcher: @escaping @Sendable (ProviderConfig) -> any QuotaFetcher,
        settingsTabTitle: String? = nil,
        settingsTabSubtitle: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.iconSystemName = iconSystemName
        self.accentColor = accentColor
        self.makeFetcher = makeFetcher
        self.settingsTabTitle = settingsTabTitle
        self.settingsTabSubtitle = settingsTabSubtitle
    }
}
