import XCTest
import Combine
import Foundation
@testable import LLM_monitor

final class StatusBarIconTests: XCTestCase {

    func testStatusBarIconStyleEnumProperties() {
        XCTAssertEqual(StatusBarIconStyle.chartBar.systemImageName, "chart.bar.fill")
        XCTAssertEqual(StatusBarIconStyle.sparkles.systemImageName, "sparkles")
        XCTAssertEqual(StatusBarIconStyle.brain.systemImageName, "brain.head.profile")
        XCTAssertEqual(StatusBarIconStyle.cpu.systemImageName, "cpu.fill")
        XCTAssertEqual(StatusBarIconStyle.quotaLogo.systemImageName, "chart.donut.fill")
        XCTAssertEqual(StatusBarIconStyle.iconDuo.systemImageName, "circle.circle")

        XCTAssertEqual(StatusBarIconStyle.chartBar.displayName, "柱状图")
        XCTAssertEqual(StatusBarIconStyle.sparkles.displayName, "AI 星光")
        XCTAssertEqual(StatusBarIconStyle.brain.displayName, "智能大脑")
        XCTAssertEqual(StatusBarIconStyle.cpu.displayName, "芯片")
        XCTAssertEqual(StatusBarIconStyle.quotaLogo.displayName, "App 图标")
        XCTAssertEqual(StatusBarIconStyle.iconDuo.displayName, "Icon Duo")

        // 两种 SVG 仪表盘样式均为自包含图标，不叠加通用状态圆点。
        XCTAssertFalse(StatusBarIconStyle.chartBar.isDashboardStyle)
        XCTAssertTrue(StatusBarIconStyle.quotaLogo.isDashboardStyle)
        XCTAssertTrue(StatusBarIconStyle.iconDuo.isDashboardStyle)
    }

    func testUnknownStatusBarValuesFallBackWithoutDroppingProviders() throws {
        let json = """
        {
          "schemaVersion": 1,
          "refreshIntervalSeconds": 300,
          "statusBarIconStyle": "future-icon-style",
          "statusBarIndicatorMode": 42,
          "statusBarHealthDotEnabled": "not-a-boolean",
          "providers": {
            "minimax_token_plan": {
              "enabled": true,
              "apiKey": "real-key"
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.effectiveStatusBarIconStyle, .chartBar)
        XCTAssertTrue(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.providers["minimax_token_plan"]?.enabled, true)
        XCTAssertEqual(decoded.providers["minimax_token_plan"]?.apiKey, "real-key")

        // 新方案 raw value 可正常解码。
        let iconDuoJSON = """
        {"schemaVersion": 1, "refreshIntervalSeconds": 300, "statusBarIconStyle": "iconDuo", "providers": {}}
        """
        let iconDuoConfig = try JSONDecoder().decode(AppConfig.self, from: Data(iconDuoJSON.utf8))
        XCTAssertEqual(iconDuoConfig.effectiveStatusBarIconStyle, .iconDuo)
    }

    func testComposedMenuBarImageWithDynamicMetrics() {
        let fullMetrics = StatusBarQuotaMetrics.full
        let customMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0.3, avgAvailable: 0.6,),
            interval: QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.5,),
            centerAvailable: 0.2,
            quotaHealthLevels: [.critical, .warning]
        )

        // Icon Duo 随额度指标变化。
        let fullImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .iconDuo,
            health: .healthy,
            quotaMetrics: fullMetrics
        )
        let customImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .iconDuo,
            health: .healthy,
            quotaMetrics: customMetrics
        )

        XCTAssertNotEqual(fullImage.tiffRepresentation, customImage.tiffRepresentation)

        // Icon Duo 顶部点随节能/睡眠健康度变化。
        let keepAwakeImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .iconDuo,
            health: .healthy,
            quotaMetrics: customMetrics,
            energyHealth: .critical
        )
        let energySavingImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .iconDuo,
            health: .healthy,
            quotaMetrics: customMetrics,
            energyHealth: .healthy
        )
        XCTAssertNotEqual(keepAwakeImage.tiffRepresentation, energySavingImage.tiffRepresentation)
    }

    /// picker 里每一行的预览，`NSImage` 自身的 size 必须就是目标边长。
    ///
    /// 这条取代了原先"扫像素量不透明包围盒"的写法：尺寸既然已经烘焙进图片
    /// （`SettingsView.bakedPreview`），`size` 本身就是契约，不必再靠渲染结果反推。
    ///
    /// 为什么必须烘焙进图片而不是在调用处套 `.frame()`：菜单式 `Picker` 在真实窗口
    /// 里由 AppKit 的 `NSPopUpButton` 绘制，那条路径不保证尊重 SwiftUI 施加在 label
    /// 子视图上的 frame——图片的 intrinsic size 还是 22pt 就照 22pt 画，`.frame(15,15)`
    /// 被无声忽略（用户实际看到的就是 22pt 顶满整行）。尺寸归图片自己所有之后，任何
    /// 容器都改不动它。
    ///
    /// App 图标比其余样式小不是偏好，是画布约定不同：SF Symbol 与 Icon Duo 的画布
    /// 自带内边距，18pt 格里真正的不透明像素只有 13.3~14.5pt；App 图标设计稿在载入
    /// 时已裁掉透明留白，18pt 格里就是 18pt 实心图形，比最小同伴大 35%。15pt 与
    /// 菜单栏里 18pt vs 15~17pt 的观感比例（1.13）对齐。
    func testPickerPreviewImageCarriesItsOwnSide() {
        for style in StatusBarIconStyle.allCases {
            let image = SettingsView.previewImage(for: style)
            let side = SettingsView.previewIconSide(for: style)
            XCTAssertEqual(image.size.width, side, accuracy: 0.01, "\(style.displayName) 宽")
            XCTAssertEqual(image.size.height, side, accuracy: 0.01, "\(style.displayName) 高")
        }
        // 唯一该特殊的仍是 App 图标；其余共用 18pt。
        let exceptions = Set(
            StatusBarIconStyle.allCases.filter {
                SettingsView.previewIconSide(for: $0) != SettingsView.previewIconSide(for: .iconDuo)
            }
        )
        XCTAssertEqual(exceptions, [.quotaLogo], "预览尺寸的例外必须仍然只有 App 图标")
        XCTAssertEqual(SettingsView.previewIconSide(for: .iconDuo), 18)
    }

    // MARK: - quotaLogo 设计稿与生成器几何一致性

    /// 单条圆弧的几何骨架（与绘制方向无关的归一化表达，端点按字典序排序）。
    private struct SVGArcSkeleton: Equatable {
        var radius: Double
        var strokeWidth: Double
        var largeArcFlag: Int
        var endpoints: [String]
        var lineCap: String
        var stroke: String
    }

    /// Icon Duo 底部三点的高峰 floor：GLM 高峰时对应套餐点至少黄色（另一套餐的
    /// 红色仍优先）；floor 只作用于三点，弧线/中心不参与。
    @MainActor
    func testPeakFloorAppliesToQuotaDots() {
        let descriptors = [
            FetcherDescriptor(
                id: "test_a",
                displayName: "Test A",
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in CodexFetcher(authPath: nil) }
            ),
            FetcherDescriptor(
                id: "test_glm",
                displayName: "Test GLM",
                kind: .glmCodingPlan,
                iconSystemName: "bolt",
                accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
            )
        ]

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        cfg.providers["test_glm"] = ProviderConfig(
            enabled: true,
            apiKey: "key_glm",
            peakStartHour: 14,
            peakEndHour: 18,
            peakWeekdaysOnly: false
        )
        try? store.applyAndSave(cfg)

        let appState = AppState(descriptors: descriptors, configStore: store)
        defer { appState.stop() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let offPeakTime = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 10))!
        let peakTime = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 15))!

        func setQuotas(codexPercent: Double, glmPercent: Double) {
            func makeModel(percent: Double) -> ModelQuota {
                ModelQuota(
                    modelName: "model",
                    intervalTotalCount: 100,
                    intervalUsageCount: Int(100.0 - percent),
                    intervalRemainingPercent: percent,
                    intervalStatus: .present,
                    intervalResetsAt: offPeakTime.addingTimeInterval(3600),
                    intervalWindowSeconds: 5 * 3600,
                    weeklyTotalCount: 0,
                    weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0,
                    weeklyStatus: .absent,
                    weeklyResetsAt: nil,
                    weeklyWindowSeconds: nil
                )
            }
            appState.mutateStatus(for: "test_a") {
                $0.state = .ok(QuotaInfo(models: [makeModel(percent: codexPercent)], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: offPeakTime))
            }
            appState.mutateStatus(for: "test_glm") {
                $0.state = .ok(QuotaInfo(models: [makeModel(percent: glmPercent)], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: offPeakTime))
            }
        }

        // 1. 非高峰：两边 80% 都为绿。
        setQuotas(codexPercent: 80, glmPercent: 80)
        XCTAssertEqual(appState.statusBarQuotaMetrics(at: offPeakTime).quotaHealthLevels, [.healthy, .healthy, .healthy])

        // 2. 高峰：GLM 点被 floor 成黄色，codex 点保持绿色。
        XCTAssertEqual(appState.statusBarQuotaMetrics(at: peakTime).quotaHealthLevels, [.warning, .healthy, .healthy])

        // 3. 高峰 + 另一套餐红色：红色优先排在最前，GLM 点仍为黄色。
        setQuotas(codexPercent: 10, glmPercent: 80)
        XCTAssertEqual(appState.statusBarQuotaMetrics(at: peakTime).quotaHealthLevels, [.critical, .warning, .healthy])
    }
}
