import XCTest
import Foundation
import SwiftUI
import AppKit
@testable import LLM_monitor

final class StatusBarConfigTests: XCTestCase {

    func testStatusBarConfigEncodingAndDecoding() throws {
        var config = AppConfig.default
        XCTAssertEqual(config.effectiveStatusBarIconStyle, .chartBar)
        XCTAssertTrue(config.effectiveStatusBarHealthDotEnabled)

        config.statusBarIconStyle = .sparkles
        config.statusBarHealthDotEnabled = false
        config.statusBarHealthColors = StatusBarHealthColors(
            healthyHex: "#123456",
            warningHex: "#ABCDEF",
            criticalHex: "#654321"
        )
        config.statusBarQuotaSelection = StatusBarQuotaSelection(
            providerID: "minimax",
            source: .apiCredit(keyID: "key-1")
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.statusBarIconStyle, .sparkles)
        XCTAssertEqual(decoded.statusBarHealthDotEnabled, false)
        XCTAssertEqual(decoded.statusBarHealthColors, config.statusBarHealthColors)
        XCTAssertEqual(decoded.statusBarQuotaSelection, config.statusBarQuotaSelection)
        XCTAssertEqual(decoded.effectiveStatusBarIconStyle, .sparkles)
        XCTAssertFalse(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.effectiveStatusBarHealthColors, config.statusBarHealthColors)
    }

    func testLegacyProviderPinMigratesToPlanAndWritesOnlyNewSchema() throws {
        let data = Data(#"{"refreshIntervalSeconds":300,"providers":{},"statusBarPinnedProvider":"codex_chatgpt"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(
            decoded.statusBarQuotaSelection,
            StatusBarQuotaSelection(providerID: "codex_chatgpt", source: .plan)
        )

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["statusBarPinnedProvider"])
        XCTAssertNotNil(object["statusBarQuotaSelection"])
    }

    func testExplicitNullSelectionWinsOverLegacyProviderPin() throws {
        let data = Data(#"{"refreshIntervalSeconds":300,"providers":{},"statusBarQuotaSelection":null,"statusBarPinnedProvider":"codex_chatgpt"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertNil(decoded.statusBarQuotaSelection)
    }

    func testProviderOnlySelectionDefaultsToPlanAndActivityIdentityRoundTrips() throws {
        let data = Data(#"{"refreshIntervalSeconds":300,"providers":{},"statusBarQuotaSelection":{"providerID":"codex_chatgpt"}}"#.utf8)
        var decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.statusBarQuotaSelection, StatusBarQuotaSelection(providerID: "codex_chatgpt"))
        decoded.statusBarQuotaSelection = StatusBarQuotaSelection(
            providerID: "glm_coding_plan",
            source: .activityPlan(planID: "plan-a", entitlementID: "entitlement-b")
        )
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.statusBarQuotaSelection, decoded.statusBarQuotaSelection)
        let draft = SettingsFormDraft(from: restored, descriptors: [])
        XCTAssertEqual(draft.statusBarQuotaProvider, "glm_coding_plan")
        XCTAssertEqual(draft.statusBarQuotaSource, .activityPlan(planID: "plan-a", entitlementID: "entitlement-b"))
    }

    /// 设置页 picker 与主面板 header 使用的 App 图标设计稿必须能从资源包加载；
    /// 加载失败会静默回退，这里钉住资源打包不回退。
    func testQuotaLogoPickerPreviewUsesDesignAsset() {
        let design = MenuBarLabel.appIconDesignImage
        XCTAssertNotNil(design, "设计稿 SVG 未打入资源包，picker 与 header 将回退")
        // 菜单栏侧的中间产物：裁掉留白后归一到 22pt 画布（drawRect 再从中收窄）。
        XCTAssertEqual(design?.size.width, 22)
        XCTAssertEqual(design?.size.height, 22)
        // picker 侧拿到的是**按目标边长烘焙过的副本**，不再是这张 22pt 图本身。
        let preview = SettingsView.previewImage(for: .quotaLogo)
        XCTAssertEqual(preview.size.width, SettingsView.previewIconSide(for: .quotaLogo))
        XCTAssertNotEqual(
            preview.tiffRepresentation, design?.tiffRepresentation,
            "picker 若直接复用 22pt 的设计稿，AppKit 绘制菜单行时会按 intrinsic size 画成 22pt"
        )
    }

    @MainActor
    func testSettingsViewLoadsAndSavesStatusBarPinnedProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-pinned-provider-test-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        var initial = store.config
        initial.statusBarQuotaSelection = StatusBarQuotaSelection(providerID: "minimax_token_plan")
        try store.applyAndSave(initial)

        let state = AppState(descriptors: [], configStore: store)
        let settings = SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: []
        )
        let hosting = NSHostingView(rootView: settings)
        _ = hosting.fittingSize

        // 1. 验证 hasFormRelevantChange 能正确识别 statusBarPinnedProvider 变化
        var changed = initial
        changed.statusBarQuotaSelection = StatusBarQuotaSelection(providerID: "codex_chatgpt")
        XCTAssertTrue(SettingsView.hasFormRelevantChange(from: initial, to: changed))

        var cleared = initial
        cleared.statusBarQuotaSelection = nil
        XCTAssertTrue(SettingsView.hasFormRelevantChange(from: initial, to: cleared))

        XCTAssertFalse(SettingsView.hasFormRelevantChange(from: initial, to: initial))
    }
}
