import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 设置页「客户端」tab 的 Provider 行默认展开态。
final class SettingsClientsPaneTests: XCTestCase {

    /// 造一个真的 SettingsView 来驱动它的方法（`clientProviderDisclosure` /
    /// `defaultProviderExpansion` 都是 SettingsView 的内部方法，具名的行视图是
    /// 私有的——测公开入口比为了测试放宽可见性更合适）。
    @MainActor
    private func makeSettings() -> (view: SettingsView, state: AppState) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-clients-pane-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)
        return (SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: []
        ), state)
    }

    // MARK: - 默认展开规则

    @MainActor
    func testASingleProviderRowStartsExpandedAndSeveralStartCollapsed() {
        // 抽成 `defaultProviderExpansion` 就是为了让这条规则有名字、有一条测试，
        // 而不是散在 ForEach 里的一句 `count == 1`。
        let (view, state) = makeSettings()
        defer { state.stop() }
        XCTAssertFalse(view.defaultProviderExpansion(forProviderCount: 0), "空列走的是空态，不该展开")
        XCTAssertTrue(view.defaultProviderExpansion(forProviderCount: 1), "只有一行时直接展开")
        for count in [2, 3, 7] {
            XCTAssertFalse(view.defaultProviderExpansion(forProviderCount: count),
                           "\(count) 行时全折叠，否则设置页要被撑到滚动")
        }
    }

    // MARK: - 默认态真的作用到 DisclosureGroup

    @MainActor
    func testDefaultExpandedReachesTheDisclosureGroup() {
        // 规则说"该展开"还不够：`@State(initialValue:)` 只在首次出现时生效，
        // 所以要量实际高度确认展开内容真的渲染出来了（折叠态只有一行标题，
        // 展开态还多出 7 天柱图 + 7 列指标）。
        let (view, state) = makeSettings()
        defer { state.stop() }
        let provider = makeSummary()
        let expanded = height(of: view.clientProviderDisclosure(provider, defaultExpanded: true))
        let collapsed = height(of: view.clientProviderDisclosure(provider, defaultExpanded: false))
        XCTAssertGreaterThan(
            expanded, collapsed + 80,
            "默认展开的 \(expanded)pt 应当明显高于默认折叠的 \(collapsed)pt"
        )
    }

    @MainActor
    func testRebuiltRowPicksUpItsNewDefault() {
        // 外层 `.id(client.id)` 是让"切到某个客户端时重新按规则来"成立的关键：
        // 少了它，SwiftUI 按位置复用上一列的展开态，这条规则会被顶掉。这里验证
        // 同一行被重建（换了默认值）时新值确实生效。
        let (view, state) = makeSettings()
        defer { state.stop() }
        let provider = makeSummary()
        let collapsed = height(of: view.clientProviderDisclosure(provider, defaultExpanded: false))
        let rebuilt = height(of: view.clientProviderDisclosure(provider, defaultExpanded: true))
        XCTAssertGreaterThan(
            rebuilt, collapsed + 80,
            "重建后 \(rebuilt)pt 应当按新默认值展开（上一轮是 \(collapsed)pt）"
        )
    }

    // MARK: - helpers

    @MainActor
    private func height(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 660))
        hosting.frame = CGRect(x: 0, y: 0, width: 660, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func makeSummary() -> ClientProviderUsageSummary {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).map { offset in
            UnifiedDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                input: 12_000 + offset * 900
            )
        }
        return ClientProviderUsageSummary(
            clientID: ClientID.antigravity,
            quotaProviderID: QuotaProviderID.antigravity,
            providerName: "Gemini Models",
            usageGroupID: "gemini",
            dailyTokenUsage: days,
            recentSamples: [],
            scannedAt: Date()
        )
    }
}
