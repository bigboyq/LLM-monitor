import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 常规 pane「配置文件」节的「打开设置目录」按钮（2.5.1）。
///
/// SwiftUI `Button` 没有可寻址的测试缝，UI 测试基建也没有 NSWorkspace 替身，
/// 所以按钮动作收敛在 `SettingsView.openSettingsDirectory()`，Finder reveal
/// 出口包成可注入闭包 `SettingsView.revealConfigDirectory`——测试注入记录闭包，
/// 断言「按钮把哪个 URL 交出去」；视图只把按钮画出来。
final class SettingsGeneralPaneTests: XCTestCase {

    /// 造一个真的 SettingsView（ConfigStore 注入临时目录，不碰用户真实的
    /// Application Support 配置）。
    @MainActor
    private func makeSettings() -> (view: SettingsView, state: AppState, configURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-general-pane-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let descriptors = [FetcherDescriptor(
            id: "glm_coding_plan",
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "circle",
            accentColor: .glm,
            makeFetcher: { _ in TestQuotaFetcher(
                providerID: "glm_coding_plan",
                displayName: "GLM Coding Plan",
                kind: .glmCodingPlan
            ) }
        )]
        let state = AppState(descriptors: descriptors, configStore: store)
        let view = SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: descriptors
        )
        return (view, state, store.configURL)
    }

    /// 按钮动作把 reveal 交给注入闭包，参数是配置目录里的 `config.json`：
    /// `activateFileViewerSelecting` 的语义是「打开参数文件所在目录并选中它」，
    /// 所以 reveal 目标必须是 config.json 本身（其 parent 即配置目录
    /// `~/Library/Application Support/LLM-monitor/`），不能是目录也不能是别的文件。
    @MainActor
    func testOpenSettingsDirectoryRevealsConfigJSONInsideConfigDirectory() {
        let (viewTemplate, state, configURL) = makeSettings()
        defer { state.stop() }

        // 注入记录闭包（闭包按引用捕获局部数组，动作触发后在这里可见）。
        var view = viewTemplate
        var revealed: [URL] = []
        view.revealConfigDirectory = { revealed.append($0) }

        XCTAssertTrue(revealed.isEmpty, "注入的 reveal 闭包不该在动作触发前被调用")

        view.openSettingsDirectory()

        XCTAssertEqual(revealed, [configURL], "reveal 目标必须是 ConfigStore 事实源里的 config.json")
        XCTAssertEqual(
            revealed.first?.lastPathComponent,
            "config.json",
            "reveal 参数必须是 config.json 文件本身（Finder 打开其所在目录并选中它），不能是目录"
        )
    }

    /// reveal 目标与 `ConfigStore.configURL` 指向同一文件：2.5.1 删除了
    /// 「用默认编辑器打开 config.json」入口（`openInDefaultEditor` /
    /// `openConfigFile`），「打开设置目录」是常规 pane 唯一的配置入口，
    /// URL 事实源只能有一个。
    @MainActor
    func testRevealTargetIsExactlyConfigStoreFactSource() {
        let (viewTemplate, state, configURL) = makeSettings()
        defer { state.stop() }

        var view = viewTemplate
        var revealed: [URL] = []
        view.revealConfigDirectory = { revealed.append($0) }
        view.openSettingsDirectory()

        XCTAssertEqual(revealed.first?.standardizedFileURL.path,
                       configURL.standardizedFileURL.path,
                       "reveal 参数必须与 ConfigStore.configURL 指向同一文件")
        XCTAssertEqual(configURL.lastPathComponent, "config.json")
    }
}
