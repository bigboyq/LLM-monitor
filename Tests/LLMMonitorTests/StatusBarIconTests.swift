import XCTest
import Combine
import Foundation
@testable import LLM_monitor

final class StatusBarIconTests: XCTestCase {

    /// `consumesQuotaMetrics` 必须与「合成图像时真的读了额度指标的那个 switch 分支」
    /// 保持一致。
    ///
    /// 这两件事现在是**两处独立陈述**：判据在 `ConfigStore.swift`，消费点在
    /// `MenuBarLabel.composedMenuBarImage` 的 `case .iconDuo`。将来加第二个仪表盘样式
    /// 时，最自然的改法是去加 `case`——判据不会跟着改，于是签名不再携带
    /// `quotaMetrics`、图像永远不重合成，那个样式就**静默冻结**在旧值上：没有编译
    /// 错误，也没有失败的测试。
    ///
    /// 本测试把"消费额度指标的样式集合"钉成**恰好是 `.iconDuo`**。再加一个仪表盘样式
    /// 时它会红，提醒同步改判据。
    func testOnlyIconDuoConsumesQuotaMetrics() {
        let consumers = StatusBarIconStyle.allCases.filter(\.consumesQuotaMetrics)
        XCTAssertEqual(
            consumers, [.iconDuo],
            "消费额度指标的样式必须与 MenuBarLabel 里读取 quotaMetrics 的分支一致"
        )
        // 交叉核对：`.quotaLogo` 是固定设计稿，四种系统符号只随健康度变色，
        // 都不该被算进来。
        for style in StatusBarIconStyle.allCases where style != .iconDuo {
            XCTAssertFalse(
                style.consumesQuotaMetrics,
                "\(style.rawValue) 不消费额度指标（App 图标是固定设计稿，系统符号只随健康度变色）"
            )
        }
    }

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

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.statusBarIconStyle, .sparkles)
        XCTAssertEqual(decoded.statusBarHealthDotEnabled, false)
        XCTAssertEqual(decoded.statusBarHealthColors, config.statusBarHealthColors)
        XCTAssertEqual(decoded.effectiveStatusBarIconStyle, .sparkles)
        XCTAssertFalse(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.effectiveStatusBarHealthColors, config.statusBarHealthColors)
    }

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

    func testStatusBarHealthDots() {
        XCTAssertNil(MenuBarLabel.statusDotColor(for: nil))
        XCTAssertEqual(
            MenuBarLabel.statusDotColor(for: .healthy),
            StatusBarHealthColors.default.healthyColor
        )
        XCTAssertEqual(
            MenuBarLabel.statusDotColor(for: .warning),
            StatusBarHealthColors.default.warningColor
        )
        XCTAssertEqual(
            MenuBarLabel.statusDotColor(for: .critical),
            StatusBarHealthColors.default.criticalColor
        )

        let customColors = StatusBarHealthColors(
            healthyHex: "#112233",
            warningHex: "#445566",
            criticalHex: "#778899"
        )
        XCTAssertEqual(
            MenuBarLabel.statusDotColor(for: .warning, colors: customColors),
            customColors.warningColor
        )

        let image = MenuBarLabel.composedMenuBarImage(
            iconStyle: .chartBar,
            health: .critical
        )
        XCTAssertEqual(image.size.width, 22)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertFalse(image.isTemplate)
        let healthyImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .chartBar,
            health: .healthy
        )
        XCTAssertNotEqual(image.tiffRepresentation, healthyImage.tiffRepresentation)

        let hiddenDotImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .chartBar,
            health: .critical,
            showsHealthDot: false
        )
        let unconfiguredImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .chartBar,
            health: nil
        )
        XCTAssertEqual(hiddenDotImage.tiffRepresentation, unconfiguredImage.tiffRepresentation)

        let quotaLogoImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: nil,
            showsHealthDot: false
        )
        XCTAssertEqual(quotaLogoImage.size.width, 22)
        XCTAssertEqual(quotaLogoImage.size.height, 22)
        XCTAssertFalse(quotaLogoImage.isTemplate)
        XCTAssertNotNil(quotaLogoImage.tiffRepresentation)

        // App 图标是**固定设计稿**：健康度、额度指标、自定义颜色都不再参与绘制，
        // 菜单栏里画出来的那张必须与设置页 picker 预览逐像素同源（预览同样直接用
        // `appIconDesignImage`）。以前这里是断言"三档健康度画出三张不同的图"。
        let healthyQuotaLogo = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: .full
        )
        let criticalQuotaLogo = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .critical,
            quotaMetrics: StatusBarQuotaMetrics(
                weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false),
                interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false),
                centerAvailable: nil,
                quotaHealthLevels: [.critical]
            ),
            healthColors: customColors
        )
        XCTAssertEqual(healthyQuotaLogo.tiffRepresentation, criticalQuotaLogo.tiffRepresentation)
        XCTAssertEqual(
            healthyQuotaLogo.tiffRepresentation,
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .quotaLogo,
                health: .healthy,
                healthColors: customColors
            ).tiffRepresentation
        )
        // 自带完整图形，仍不叠加通用状态圆点。
        XCTAssertEqual(
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .quotaLogo,
                health: .healthy,
                showsHealthDot: true
            ).tiffRepresentation,
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .quotaLogo,
                health: .healthy,
                showsHealthDot: false
            ).tiffRepresentation
        )

        // Icon Duo 同样为自包含仪表盘：不叠加通用状态圆点。
        let iconDuoImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .iconDuo,
            health: nil,
            showsHealthDot: false
        )
        XCTAssertEqual(iconDuoImage.size.width, 22)
        XCTAssertEqual(iconDuoImage.size.height, 22)
        XCTAssertFalse(iconDuoImage.isTemplate)
        XCTAssertNotNil(iconDuoImage.tiffRepresentation)
        XCTAssertEqual(
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .iconDuo,
                health: .healthy,
                showsHealthDot: true
            ).tiffRepresentation,
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .iconDuo,
                health: .healthy,
                showsHealthDot: false
            ).tiffRepresentation
        )
        // 两种仪表盘样式渲染结果互不相同。
        XCTAssertNotEqual(quotaLogoImage.tiffRepresentation, iconDuoImage.tiffRepresentation)
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

    @MainActor
    func testAppStateSystemHealthLevel() {
        let descriptors = [
            FetcherDescriptor(
                id: "test_a",
                displayName: "Test A",
                kind: .minimaxTokenPlan,
                iconSystemName: "bubble.left",
                accentColor: .minimax,
                makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "key") }
            ),
            FetcherDescriptor(
                id: "test_b",
                displayName: "Test B",
                kind: .codexChatGpt,
                iconSystemName: "sparkles",
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

        let configURL = dir.appendingPathComponent("config.json")
        let store = ConfigStore(configURL: configURL)
        // Custom test descriptors are not part of ConfigStore's built-in
        // template. Explicitly disable them so the test does not inherit
        // AppState's compatibility fallback for a missing provider entry.
        var initialConfig = store.config
        for id in ["test_a", "test_b", "test_glm"] {
            initialConfig.providers[id] = ProviderConfig(enabled: false)
        }
        try? store.applyAndSave(initialConfig)
        let appState = AppState(descriptors: descriptors, configStore: store)
        defer { appState.stop() }

        // 默认全未启用 -> nil
        XCTAssertNil(appState.systemHealthLevel)

        // 启用 test_a 设为 ok / healthy
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(cfg)
        appState.rebuildStatuses()

        let healthyModel = ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 20,
            intervalRemainingPercent: 80.0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 18000,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let healthyInfo = QuotaInfo(
            models: [healthyModel],
            resetCredits: nil,
            planLabel: "Standard",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        appState.mutateStatus(for: "test_a") { st in
            st.state = .ok(healthyInfo)
        }

        XCTAssertEqual(appState.systemHealthLevel, .healthy)

        // 设为 warning
        let warningModel = ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 80,
            intervalRemainingPercent: 20.0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 18000,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let warningInfo = QuotaInfo(
            models: [warningModel],
            resetCredits: nil,
            planLabel: "Standard",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )

        appState.mutateStatus(for: "test_a") { st in
            st.state = .ok(warningInfo)
        }

        XCTAssertEqual(appState.systemHealthLevel, .warning)

        // 设为 critical 失败
        appState.mutateStatus(for: "test_a") { st in
            st.state = .failed(message: "Auth error", lastSuccess: nil)
        }

        XCTAssertEqual(appState.systemHealthLevel, .critical)

        // 时间派生状态可注入固定 now：同一份 provider 数据在高峰边界前后应切换。
        cfg = store.config
        cfg.providers["test_glm"] = ProviderConfig(
            enabled: true,
            apiKey: "key",
            peakStartHour: 14,
            peakEndHour: 18,
            peakWeekdaysOnly: false
        )
        try? store.applyAndSave(cfg)
        appState.rebuildStatuses()
        appState.mutateStatus(for: "test_a") { $0.state = .ok(healthyInfo) }
        appState.mutateStatus(for: "test_glm") { $0.state = .ok(healthyInfo) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = DateComponents(year: 2026, month: 8, day: 10)
        let beforePeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 13, minute: 59
        ))!
        let duringPeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 14, minute: 0
        ))!
        let afterPeak = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 18, minute: 0
        ))!

        XCTAssertEqual(appState.systemHealthLevel(at: beforePeak), .healthy)
        XCTAssertEqual(appState.systemHealthLevel(at: duringPeak), .warning)
        XCTAssertEqual(appState.systemHealthLevel(at: afterPeak), .healthy)
    }

    func testIconDuoSVGBuilderDashboardGeometry() {
        // colorLevel 统一判定：周 avg 15% → 15 不小于 15、小于固定黄线 30 → warning；
        // 5h avg 35% → ≥ 30 → healthy；中心 50% → healthy。
        let outer = QuotaRingMetrics(minAvailable: 0.1, avgAvailable: 0.15,) // < 30 → warning
        let middle = QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.35,) // >= 30 → healthy
        let metrics = StatusBarQuotaMetrics(
            weekly: outer,
            interval: middle,
            centerAvailable: 0.5, // >= 30 → healthy
            quotaHealthLevels: [.healthy, .warning, .critical]
        )
        // 新字段默认 nil：既有构造点不被破坏，弧线/中心退回固定 30% 黄线。
        XCTAssertNil(metrics.weeklyTimeFraction)
        XCTAssertNil(metrics.centerTimeFraction)
        let svg = IconDuoSVGBuilder.buildSVG(
            metrics: metrics,
            energyHealth: .warning
        )

        XCTAssertTrue(svg.contains("viewBox=\"0 0 704 704\""))
        XCTAssertTrue(svg.contains("id=\"interval-track\""))
        XCTAssertTrue(svg.contains("id=\"interval-available\""))
        XCTAssertTrue(svg.contains("id=\"weekly-track\""))
        XCTAssertTrue(svg.contains("id=\"weekly-available\""))
        XCTAssertTrue(svg.contains("id=\"energy-dot\""))
        XCTAssertTrue(svg.contains("r=\"48\""), "顶部节能点半径放大至 r=48")
        XCTAssertTrue(svg.contains("fill=\"#FFD60A\""), "顶部节能点（warning）或右弧预警色使用黄色")
        XCTAssertTrue(svg.contains("id=\"center-sector\" data-value=\"50\""), "中心扇形展示 50% 额度")
        XCTAssertTrue(svg.contains("id=\"quota-dot-0\""))
        XCTAssertTrue(svg.contains("id=\"quota-dot-1\""))
        XCTAssertTrue(svg.contains("id=\"quota-dot-2\""))
        XCTAssertFalse(svg.contains("id=\"quota-dot-3\""), "已调整为 3 个点，不再有第 4 个点")
        XCTAssertTrue(svg.contains("r=\"36\""), "点半径放大至 r=36")
        XCTAssertTrue(svg.contains("fill=\"#FF453A\""), "包含红色状态点（critical 套餐点）")

        // 69.5% 必须走 SVG large-arc，绘制约 250°，不能错误显示成不足四分之一。
        let currentQuotaMetrics = StatusBarQuotaMetrics(
            weekly: outer,
            interval: middle,
            centerAvailable: 0.695
        )
        let currentQuotaSVG = IconDuoSVGBuilder.buildSVG(metrics: currentQuotaMetrics)
        XCTAssertTrue(currentQuotaSVG.contains("id=\"center-sector\" data-value=\"70\""))
        XCTAssertTrue(
            currentQuotaSVG.contains("A 135.00 135.00 0 1 1"),
            "超过 50% 的中心扇形必须使用 large-arc，69.5% 应约为 250°"
        )

        // 缺失窗口只绘制灰色底轨，不得伪装成 100% 可用。
        let weeklyOnly = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5,),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false),
            centerAvailable: 0.5
        )
        let weeklyOnlySVG = IconDuoSVGBuilder.buildSVG(metrics: weeklyOnly)
        XCTAssertFalse(weeklyOnlySVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlySVG.contains("id=\"weekly-available\""))

        let intervalOnly = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5,),
            centerAvailable: 0.5
        )
        let intervalOnlySVG = IconDuoSVGBuilder.buildSVG(metrics: intervalOnly)
        XCTAssertTrue(intervalOnlySVG.contains("id=\"interval-available\""))
        XCTAssertFalse(intervalOnlySVG.contains("id=\"weekly-available\""))

        let unknownSVG = IconDuoSVGBuilder.buildSVG(metrics: StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, isAvailable: false)
        ))
        XCTAssertTrue(unknownSVG.contains("id=\"center-sector\""))
        XCTAssertTrue(unknownSVG.contains("stroke=\"#8E8E93\""), "无数据时中心保持灰色环")

        // 验证三点优先级：红 > 黄 > 绿；如果有 3 个红，则不显示黄绿
        let threeRedsMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 1, avgAvailable: 1),
            interval: QuotaRingMetrics(minAvailable: 1, avgAvailable: 1),
            centerAvailable: 0.8,
            quotaHealthLevels: [.critical, .warning, .critical, .healthy, .critical]
        )
        XCTAssertEqual(threeRedsMetrics.quotaHealthLevels, [.critical, .critical, .critical])

        let mixedMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 1, avgAvailable: 1),
            interval: QuotaRingMetrics(minAvailable: 1, avgAvailable: 1),
            centerAvailable: 0.8,
            quotaHealthLevels: [.healthy, .critical, .warning]
        )
        XCTAssertEqual(mixedMetrics.quotaHealthLevels, [.critical, .warning, .healthy])

        // 验证全满状态（360度整圆）
        let fullSvg = IconDuoSVGBuilder.buildSVG(metrics: .full, energyHealth: .healthy)
        XCTAssertTrue(fullSvg.contains("<circle id=\"center-sector\" data-value=\"100\""))

        // 验证 3 个红点全耗尽状态
        let allExhaustedMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0),
            centerAvailable: 0.0,
            quotaHealthLevels: [.critical, .critical, .critical]
        )
        let exhaustedSvg = IconDuoSVGBuilder.buildSVG(metrics: allExhaustedMetrics)
        XCTAssertTrue(exhaustedSvg.contains("<circle id=\"center-sector\" data-value=\"0\""))
        XCTAssertTrue(exhaustedSvg.contains("stroke=\"#FF453A\""), "中心呈现红色空心警示环")
        XCTAssertEqual(exhaustedSvg.components(separatedBy: "fill=\"#FF453A\"").count - 1, 3, "底部固定 3 个红点")

        let image = IconDuoSVGBuilder.buildImage(
            metrics: metrics,
            energyHealth: .warning
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 22)
        XCTAssertEqual(image?.size.height, 22)
    }

    @MainActor
    func testDeepSeekBalanceDoesNotEnterQuotaLogoAggregate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var config = store.config
        config.providers["deepseek"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(config)
        let descriptor = FetcherDescriptor(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "flame",
            accentColor: .deepseek,
            makeFetcher: { _ in DeepseekFetcher(apiKey: "key") }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }

        let zeroBalance = ModelQuota(
            modelName: "deepseek_balance",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 0,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        state.mutateStatus(for: "deepseek") {
            $0.state = .ok(QuotaInfo(
                models: [zeroBalance],
                resetCredits: nil,
                planLabel: "¥0.00",
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            ))
        }

        let metrics = state.statusBarQuotaMetrics()
        XCTAssertFalse(metrics.interval.isAvailable)
        XCTAssertFalse(metrics.weekly.isAvailable)
        XCTAssertNil(metrics.centerAvailable)
        XCTAssertEqual(metrics.quotaHealthLevels, [.healthy, .healthy, .healthy])
    }

    @MainActor
    func testStatusBarQuotaMetricsWithWeeklyTimeFactor() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        cfg.providers["test_b"] = ProviderConfig(enabled: true, apiKey: "key_b")
        try? store.applyAndSave(cfg)

        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in CodexFetcher(authPath: nil) }
        )
        let descB = FetcherDescriptor(
            id: "test_b",
            displayName: "Test B",
            kind: .glmCodingPlan,
            iconSystemName: "sparkles",
            accentColor: .glm,
            makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
        )

        let appState = AppState(descriptors: [descA, descB], configStore: store)
        appState.stop()

        let now = Date()
        let totalWeekSeconds = 7.0 * 24 * 3600

        // 模型 A：5h 剩余 40%；周剩余 30%，但还剩 60% 的时间 (30% / 60% = 50% 可用度)
        let resetA = now.addingTimeInterval(totalWeekSeconds * 0.6)
        let modelA = ModelQuota(
            modelName: "model_a",
            intervalTotalCount: 100,
            intervalUsageCount: 60,
            intervalRemainingPercent: 40.0,
            intervalStatus: .present,
            intervalResetsAt: now.addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: 70,
            weeklyRemainingPercent: 30.0,
            weeklyStatus: .present,
            weeklyResetsAt: resetA,
            weeklyWindowSeconds: Int(totalWeekSeconds)
        )

        // 模型 B：5h 剩余 80%；周剩余 40%，但只剩 20% 的时间 (40% / 20% = 200% -> 封顶 100%)
        let resetB = now.addingTimeInterval(totalWeekSeconds * 0.2)
        let modelB = ModelQuota(
            modelName: "model_b",
            intervalTotalCount: 100,
            intervalUsageCount: 20,
            intervalRemainingPercent: 80.0,
            intervalStatus: .present,
            intervalResetsAt: now.addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: 60,
            weeklyRemainingPercent: 40.0,
            weeklyStatus: .present,
            weeklyResetsAt: resetB,
            weeklyWindowSeconds: Int(totalWeekSeconds)
        )

        appState.mutateStatus(for: "test_a") { st in
            st.state = .ok(QuotaInfo(models: [modelA], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
        }
        appState.mutateStatus(for: "test_b") { st in
            st.state = .ok(QuotaInfo(models: [modelB], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
        }

        let metrics = appState.statusBarQuotaMetrics(at: now)

        // 5h 额度：纯原始比例。min = 40% (0.4), avg = (40 + 80) / 2 = 60% (0.6)
        XCTAssertEqual(metrics.interval.minAvailable, 0.4, accuracy: 0.001)
        XCTAssertEqual(metrics.interval.avgAvailable, 0.6, accuracy: 0.001)

        // 周额度：恢复为纯原始百分比，不带时间系数。
        // A: 30% (0.3)
        // B: 40% (0.4)
        // min = 0.3, avg = (0.3 + 0.4) / 2 = 0.35
        XCTAssertEqual(metrics.weekly.minAvailable, 0.3, accuracy: 0.001)
        XCTAssertEqual(metrics.weekly.avgAvailable, 0.35, accuracy: 0.001)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.4,
            accuracy: 0.001,
            "中心应取实际可用 min(5h, 周×N) 的最低值：A = min(40%, 30%×6=180%) = 40%，B = min(80%, 40%×5=200%) = 80%，两者取 min 仍为 40%"
        )
        // 套餐点统一 colorLevel（实际可用口径）：A = min(5h 40%, 周 30%×6→100) = 40，
        // 瓶颈 5h → 固定 30% 黄线 → healthy；B = min(5h 80%, 周 40%×5→100) = 80 → healthy。
        // （旧 standard 阈值下 A/B 均为 warning。）
        XCTAssertEqual(metrics.quotaHealthLevels, [.healthy, .healthy, .healthy])

        // 聚合右弧的动态黄线输入取所有周窗口剩余时间比例的最大值：A = 0.6、B = 0.2 → 0.6。
        XCTAssertEqual(metrics.weeklyTimeFraction ?? -1, 0.6, accuracy: 0.001)
        // 中心 argmin 是套餐 A（40% < 80%），瓶颈为 5h 短窗口 → timeFraction 为 nil。
        XCTAssertNil(metrics.centerTimeFraction)

        // 状态栏统一 colorLevel：短窗口固定 30% 黄线 → 20% 为黄、10% 为红
        // （旧 standard 阈值下 35% 黄 / 15% 红，现已随统一规则重算）。
        func makeStandardModel(intervalPercent: Double) -> ModelQuota {
            ModelQuota(
                modelName: "standard-model",
                intervalTotalCount: 100,
                intervalUsageCount: Int(100.0 - intervalPercent),
                intervalRemainingPercent: intervalPercent,
                intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3600),
                intervalWindowSeconds: 5 * 3600,
                weeklyTotalCount: 100,
                weeklyUsageCount: 20,
                weeklyRemainingPercent: 80.0,
                weeklyStatus: .present,
                weeklyResetsAt: now.addingTimeInterval(totalWeekSeconds),
                weeklyWindowSeconds: Int(totalWeekSeconds)
            )
        }

        func setStandardQuota(_ intervalPercent: Double) {
            let info = QuotaInfo(
                models: [makeStandardModel(intervalPercent: intervalPercent)],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: now
            )
            appState.mutateStatus(for: "test_a") { $0.state = .ok(info) }
            appState.mutateStatus(for: "test_b") { $0.state = .ok(info) }
        }

        setStandardQuota(20.0)
        let warningMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(warningMetrics.quotaHealthLevels, [.warning, .warning, .healthy])
        let warningSVG = IconDuoSVGBuilder.buildSVG(metrics: warningMetrics)
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\" d="), "20% 短窗口弧线仍显示可用段")
        XCTAssertTrue(warningSVG.contains("stroke=\"#FFD60A\""), "20% 短窗口弧线和套餐点均为黄色")

        setStandardQuota(10.0)
        let criticalMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(criticalMetrics.quotaHealthLevels, [.critical, .critical, .healthy])
        let criticalSVG = IconDuoSVGBuilder.buildSVG(metrics: criticalMetrics)
        XCTAssertTrue(criticalSVG.contains("stroke=\"#FF453A\""), "10% 短窗口弧线为红色")

        func makeWindowPresenceModel(intervalStatus: QuotaWindowStatus, weeklyStatus: QuotaWindowStatus) -> ModelQuota {
            ModelQuota(
                modelName: "presence-model",
                intervalTotalCount: 100,
                intervalUsageCount: 50,
                intervalRemainingPercent: 50,
                intervalStatus: intervalStatus,
                intervalResetsAt: intervalStatus.isPresent ? now.addingTimeInterval(3600) : nil,
                intervalWindowSeconds: intervalStatus.isPresent ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: 50,
                weeklyRemainingPercent: 50,
                weeklyStatus: weeklyStatus,
                weeklyResetsAt: weeklyStatus.isPresent ? now.addingTimeInterval(totalWeekSeconds) : nil,
                weeklyWindowSeconds: weeklyStatus.isPresent ? Int(totalWeekSeconds) : nil
            )
        }

        func setWindowPresence(intervalStatus: QuotaWindowStatus, weeklyStatus: QuotaWindowStatus) {
            let info = QuotaInfo(
                models: [makeWindowPresenceModel(intervalStatus: intervalStatus, weeklyStatus: weeklyStatus)],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: now
            )
            appState.mutateStatus(for: "test_a") { $0.state = .ok(info) }
            appState.mutateStatus(for: "test_b") { $0.state = .ok(info) }
        }

        setWindowPresence(intervalStatus: .absent, weeklyStatus: .present)
        let weeklyOnlyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertFalse(weeklyOnlyMetrics.interval.isAvailable)
        XCTAssertTrue(weeklyOnlyMetrics.weekly.isAvailable)
        let weeklyOnlyStateSVG = IconDuoSVGBuilder.buildSVG(metrics: weeklyOnlyMetrics)
        XCTAssertFalse(weeklyOnlyStateSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlyStateSVG.contains("id=\"weekly-available\""))

        setWindowPresence(intervalStatus: .present, weeklyStatus: .absent)
        let intervalOnlyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertTrue(intervalOnlyMetrics.interval.isAvailable)
        XCTAssertFalse(intervalOnlyMetrics.weekly.isAvailable)
        let intervalOnlyStateSVG = IconDuoSVGBuilder.buildSVG(metrics: intervalOnlyMetrics)
        XCTAssertTrue(intervalOnlyStateSVG.contains("id=\"interval-available\""))
        XCTAssertFalse(intervalOnlyStateSVG.contains("id=\"weekly-available\""))
    }

    /// 中心扇形的「实际可用」口径：每个套餐按自身存在的窗口取
    /// min(5h 剩余, 周剩余 × 周等效倍率 N)，与卡片分段条一致。
    @MainActor
    func testStatusBarQuotaMetricsCenterUsesActualAvailable() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        cfg.providers["test_b"] = ProviderConfig(enabled: true, apiKey: "key_b")
        try? store.applyAndSave(cfg)

        // 两个 provider 覆盖不同周倍率：glmCodingPlan N=5、codexChatGpt N=6。
        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .glmCodingPlan,
            iconSystemName: "sparkles",
            accentColor: .glm,
            makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
        )
        let descB = FetcherDescriptor(
            id: "test_b",
            displayName: "Test B",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in CodexFetcher(authPath: nil) }
        )

        let appState = AppState(descriptors: [descA, descB], configStore: store)
        appState.stop()

        let now = Date()
        let totalWeekSeconds = 7.0 * 24 * 3600

        func makeModel(modelName: String, intervalPercent: Double?, weeklyPercent: Double?) -> ModelQuota {
            ModelQuota(
                modelName: modelName,
                intervalTotalCount: 100,
                intervalUsageCount: 100 - Int(intervalPercent ?? 0),
                intervalRemainingPercent: intervalPercent ?? 0,
                intervalStatus: intervalPercent != nil ? .present : .absent,
                intervalResetsAt: intervalPercent != nil ? now.addingTimeInterval(3600) : nil,
                intervalWindowSeconds: intervalPercent != nil ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: 100 - Int(weeklyPercent ?? 0),
                weeklyRemainingPercent: weeklyPercent ?? 0,
                weeklyStatus: weeklyPercent != nil ? .present : .absent,
                weeklyResetsAt: weeklyPercent != nil ? now.addingTimeInterval(totalWeekSeconds) : nil,
                weeklyWindowSeconds: weeklyPercent != nil ? Int(totalWeekSeconds) : nil
            )
        }

        func setQuotas(a: ModelQuota?, b: ModelQuota?) {
            appState.mutateStatus(for: "test_a") {
                $0.state = .ok(QuotaInfo(models: a.map { [$0] } ?? [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
            }
            appState.mutateStatus(for: "test_b") {
                $0.state = .ok(QuotaInfo(models: b.map { [$0] } ?? [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
            }
        }

        // 1. 周 × N < 5h：周额度是瓶颈。GLM 5h=80%、周=10%（10%×5=50%）；
        //    codex 5h=90%、周=15%（15%×6=90%）。中心取两套餐最低 50%。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 80, weeklyPercent: 10),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 90, weeklyPercent: 15)
        )
        var metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.50,
            accuracy: 0.001,
            "周×N(50%) 先于 5h(80%) 耗尽时，中心应显示实际可用 50%"
        )
        // 左右弧仍为原始物理剩余，不受实际可用口径影响。
        XCTAssertEqual(metrics.interval.minAvailable, 0.80, accuracy: 0.001)
        XCTAssertEqual(metrics.weekly.minAvailable, 0.10, accuracy: 0.001)
        // 中心 argmin 是套餐 A（50% < 90%），瓶颈为周窗口且刚重置 → timeFraction = 1.0
        // 透传给中心 colorLevel（动态黄线 min(time%, 50)）。
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 1.0, accuracy: 0.001)

        // 2. 周 × N ≥ 5h：5h 仍是瓶颈。GLM 5h=30%、周=50%（250% ≥ 30%）；
        //    codex 5h=40%、周=20%（120% ≥ 40%）。中心取最低 30%。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 30, weeklyPercent: 50),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 40, weeklyPercent: 20)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.30,
            accuracy: 0.001,
            "周×N 仍有余量时，中心不应被压到 5h 剩余以下"
        )

        // 3. 仅周窗口：按 周 × N 参与。GLM 周=20%（×5 = 100% 封顶）、
        //    codex 周=10%（×6 = 60%）。中心取最低 60%。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: nil, weeklyPercent: 20),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 10)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.60,
            accuracy: 0.001,
            "仅周窗口按 周×N 参与中心：20%×5 封顶为 100%，10%×6 = 60%"
        )

        // 4. 仅周窗口且 周 × N 超过 1：clamp 到 1.0，不产生超过满格的中心值。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: nil, weeklyPercent: 40),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 30)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            1.0,
            accuracy: 0.001,
            "40%×5 与 30%×6 均超过满格，中心应 clamp 到 100%"
        )

        // 5. 仅 5h 窗口：直接按 5h 剩余参与，与原语义一致；瓶颈是 5h 短窗口
        //    → 中心 timeFraction 保持 nil（固定 30% 黄线）。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 25, weeklyPercent: nil),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 35, weeklyPercent: nil)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.25, accuracy: 0.001)
        XCTAssertNil(metrics.centerTimeFraction)

        // 6. 所有套餐都没有任何窗口：中心保持 nil。
        setQuotas(a: nil, b: nil)
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertNil(metrics.centerAvailable, "所有套餐都没有任何窗口时中心应保持 nil")
        XCTAssertNil(metrics.centerTimeFraction)
    }

    /// 中心扇形的多套餐接力：已耗尽（实际可用为 0）的套餐不参与中心 min，
    /// 中心跟随仍在服役的接力套餐（含 timeFraction）；底部三点不排除耗尽
    /// 套餐（用完的套餐点保持红）；全部套餐耗尽时中心回退 0（红）。
    @MainActor
    func testStatusBarQuotaMetricsCenterSkipsExhaustedPlans() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        cfg.providers["test_b"] = ProviderConfig(enabled: true, apiKey: "key_b")
        try? store.applyAndSave(cfg)

        // 两个 provider 覆盖不同周倍率：glmCodingPlan N=5、codexChatGpt N=6。
        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .glmCodingPlan,
            iconSystemName: "sparkles",
            accentColor: .glm,
            makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
        )
        let descB = FetcherDescriptor(
            id: "test_b",
            displayName: "Test B",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in CodexFetcher(authPath: nil) }
        )

        let appState = AppState(descriptors: [descA, descB], configStore: store)
        appState.stop()

        let now = Date()
        let totalWeekSeconds = 7.0 * 24 * 3600

        func makeModel(
            modelName: String,
            intervalPercent: Double?,
            weeklyPercent: Double?,
            weeklyResetFraction: Double = 1.0
        ) -> ModelQuota {
            ModelQuota(
                modelName: modelName,
                intervalTotalCount: 100,
                intervalUsageCount: 100 - Int(intervalPercent ?? 0),
                intervalRemainingPercent: intervalPercent ?? 0,
                intervalStatus: intervalPercent != nil ? .present : .absent,
                intervalResetsAt: intervalPercent != nil ? now.addingTimeInterval(3600) : nil,
                intervalWindowSeconds: intervalPercent != nil ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: 100 - Int(weeklyPercent ?? 0),
                weeklyRemainingPercent: weeklyPercent ?? 0,
                weeklyStatus: weeklyPercent != nil ? .present : .absent,
                weeklyResetsAt: weeklyPercent != nil ? now.addingTimeInterval(totalWeekSeconds * weeklyResetFraction) : nil,
                weeklyWindowSeconds: weeklyPercent != nil ? Int(totalWeekSeconds) : nil
            )
        }

        func setQuotas(a: ModelQuota?, b: ModelQuota?) {
            appState.mutateStatus(for: "test_a") {
                $0.state = .ok(QuotaInfo(models: a.map { [$0] } ?? [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
            }
            appState.mutateStatus(for: "test_b") {
                $0.state = .ok(QuotaInfo(models: b.map { [$0] } ?? [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
            }
        }

        // 1. 接力：套餐 A 耗尽（5h 与周均 0），套餐 B 仍有 35%（仅 5h 窗口）。
        //    中心 = B 的实际可用 35%，而非被 A 拖到 0；瓶颈是 B 的 5h 短窗口
        //    → timeFraction 为 nil（固定 30% 黄线）。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 0, weeklyPercent: 0),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 35, weeklyPercent: nil)
        )
        var metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.35,
            accuracy: 0.001,
            "接力场景：A 耗尽后中心应显示接力套餐 B 的实际可用 35%，而不是 0"
        )
        XCTAssertNil(metrics.centerTimeFraction, "B 的瓶颈为 5h 短窗口，中心 timeFraction 应为 nil")
        // 底部三点不排除耗尽套餐：A 的点保持红，B 的点为绿。
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .healthy, .healthy])

        // 2. timeFraction 跟随新胜出套餐：A 耗尽，B 仅周窗口 4%（codex ×6 = 24%）
        //    且窗口只剩 20% 时间。中心 = 24%，timeFraction = 0.2 透传（动态黄线
        //    min(20, 50) = 20 → 24 ≥ 20 绿色；若沿用被排除套餐的 nil/固定 30%
        //    黄线会虚黄）。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 0, weeklyPercent: 0),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 4, weeklyResetFraction: 0.2)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.24, accuracy: 0.001)
        XCTAssertEqual(
            metrics.centerTimeFraction ?? -1,
            0.2,
            accuracy: 0.001,
            "中心 timeFraction 应取自接力套餐 B 的瓶颈周窗口"
        )
        let centerLine = IconDuoSVGBuilder.buildSVG(metrics: metrics)
            .components(separatedBy: "\n")
            .first { $0.contains("id=\"center-sector\"") } ?? ""
        XCTAssertTrue(centerLine.contains("data-value=\"24\""))
        XCTAssertTrue(centerLine.contains("fill=\"#34C759\""), "中心应按 B 的动态黄线判绿，不得虚黄")
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .healthy, .healthy])

        // 3. 全部套餐耗尽：中心回退 0（红色空心环），无胜出套餐 → timeFraction nil。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 0, weeklyPercent: 0),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 0, weeklyPercent: nil)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.0, accuracy: 0.001, "全部套餐耗尽时中心应为 0（红）")
        XCTAssertNil(metrics.centerTimeFraction)
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .critical, .healthy])
        let exhaustedLine = IconDuoSVGBuilder.buildSVG(metrics: metrics)
            .components(separatedBy: "\n")
            .first { $0.contains("id=\"center-sector\"") } ?? ""
        XCTAssertTrue(exhaustedLine.contains("data-value=\"0\""))
        XCTAssertTrue(exhaustedLine.contains("stroke=\"#FF453A\""))
    }

    /// 中心扇形的 timeFraction 透传：周瓶颈且临近重置（late window）时，
    /// 动态黄线 min(time%, 50) 收紧，中心不能按「无时间系数的固定 30%」虚黄。
    @MainActor
    func testCenterTimeFractionWeeklyBindingPassthrough() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        try? store.applyAndSave(cfg)

        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in CodexFetcher(authPath: nil) }
        )
        let appState = AppState(descriptors: [descA], configStore: store)
        appState.stop()

        let now = Date()
        let totalWeekSeconds = 7.0 * 24 * 3600
        // 仅周窗口：周剩余 4%（codex ×6 = 24%），窗口只剩 20% 时间。
        // colorLevel(24, tf=0.2)：黄线 = min(20, 50) = 20 → 24 ≥ 20 → 绿。
        // 若 timeFraction 未透传（nil → 固定 30% 黄线），24 < 30 会虚黄。
        let model = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 0,
            intervalStatus: .absent,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 100,
            weeklyUsageCount: 96,
            weeklyRemainingPercent: 4,
            weeklyStatus: .present,
            weeklyResetsAt: now.addingTimeInterval(totalWeekSeconds * 0.2),
            weeklyWindowSeconds: Int(totalWeekSeconds)
        )
        appState.mutateStatus(for: "test_a") {
            $0.state = .ok(QuotaInfo(models: [model], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: now))
        }

        let metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.24, accuracy: 0.001)
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)

        let svg = IconDuoSVGBuilder.buildSVG(metrics: metrics)
        XCTAssertTrue(svg.contains("id=\"center-sector\" data-value=\"24\""))
        XCTAssertFalse(svg.contains("#FFD60A"), "周瓶颈 late-window 时中心按动态黄线应为绿色，不得虚黄（无任何黄色元素）")
        XCTAssertTrue(svg.contains("#34C759"), "中心应为绿色")
    }

    /// 左弧的动态黄线透传（修复回归）：ChatGPT Plan 单 7d 主窗口下，左弧与
    /// 中心扇形必须同向——20% 额度 + 20% 窗口时间时两者都按动态黄线
    /// min(time%, 50) 判绿，而不是左弧固定 30% 黄线判黄、与中心反向。
    /// 5h 短窗口（<24h）行为不变：固定 30% 黄线，20% 仍为黄。
    @MainActor
    func testIconDuoLeftArcUsesLongIntervalTimeFraction() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        try? store.applyAndSave(cfg)

        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in CodexFetcher(authPath: nil) }
        )
        let appState = AppState(descriptors: [descA], configStore: store)
        appState.stop()

        let now = Date()
        let sevenDays = 7.0 * 24 * 3600

        func setChatGPTPlanQuota(intervalPercent: Double, windowSeconds: Double) {
            let model = ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100,
                intervalUsageCount: 100 - Int(intervalPercent),
                intervalRemainingPercent: intervalPercent,
                intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(windowSeconds * 0.2),
                intervalWindowSeconds: Int(windowSeconds),
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: 0,
                weeklyStatus: .absent,
                weeklyResetsAt: nil,
                weeklyWindowSeconds: nil
            )
            appState.mutateStatus(for: "test_a") {
                $0.state = .ok(QuotaInfo(
                    models: [model],
                    resetCredits: nil,
                    planLabel: nil,
                    accountEmail: nil,
                    codexUsageDetails: nil,
                    fetchedAt: now
                ))
            }
        }

        // 1. 长 interval 窗口（7d）：20% 额度 + 20% 窗口时间 → 左弧与中心同绿。
        setChatGPTPlanQuota(intervalPercent: 20, windowSeconds: sevenDays)
        let metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.interval.avgAvailable, 0.2, accuracy: 0.001)
        XCTAssertEqual(metrics.intervalTimeFraction ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)
        let svg = IconDuoSVGBuilder.buildSVG(metrics: metrics)
        XCTAssertTrue(svg.contains("id=\"interval-available\""))
        XCTAssertFalse(svg.contains("#FFD60A"), "长窗口 20%+20% 时左弧与中心都按动态黄线判绿，不得出现黄色")
        XCTAssertTrue(svg.contains("#34C759"), "左弧应与中心扇形一致为绿色")

        // 2. 短 interval 窗口（5h）：行为不变——固定 30% 黄线，20% 仍为黄。
        setChatGPTPlanQuota(intervalPercent: 20, windowSeconds: 5 * 3600)
        let shortMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertNil(shortMetrics.intervalTimeFraction, "5h 短窗口不应产生 interval 剩余时间比例")
        let shortSVG = IconDuoSVGBuilder.buildSVG(metrics: shortMetrics)
        XCTAssertTrue(shortSVG.contains("#FFD60A"), "5h 短窗口 20% 左弧仍为固定 30% 黄线的黄色")
    }

    /// 修复回归：状态栏 SF Symbol 圆点（systemHealthLevel）与卡片头部点
    /// （ProviderStatus.aggregateHealthLevel）必须同口径。GLM N=5 反例：
    /// 5h 剩 40%（无 reset 时间）、周剩 8%（8%×5=40%，并列瓶颈取 5h →
    /// 固定 30% 黄线 → 绿）；旧实现走逐窗口 healthLevel 时周 8% 直接判红，
    /// 两处颜色反向。
    @MainActor
    func testSystemHealthLevelMatchesCardAggregateHealthLevel() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var cfg = store.config
        cfg.providers["test_glm"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(cfg)

        let descriptors = [
            FetcherDescriptor(
                id: "test_glm",
                displayName: "Test GLM",
                kind: .glmCodingPlan,
                iconSystemName: "bolt",
                accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
            )
        ]
        let appState = AppState(descriptors: descriptors, configStore: store)
        defer { appState.stop() }

        let glmModel = ModelQuota(
            modelName: "glm_coding_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 60,
            intervalRemainingPercent: 40.0,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 100,
            weeklyUsageCount: 92,
            weeklyRemainingPercent: 8.0,
            weeklyStatus: .present,
            weeklyResetsAt: Date().addingTimeInterval(7 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        let info = QuotaInfo(
            models: [glmModel],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
        appState.mutateStatus(for: "test_glm") { $0.state = .ok(info) }

        let status = appState.statuses.first(where: { $0.id == "test_glm" })!
        XCTAssertEqual(status.aggregateHealthLevel(), .healthy, "卡片头部点按实际可用口径（周 × 5，瓶颈 5h）应为绿")
        // 旧逐窗口口径对该反例判红（周 8% < 15 直接 critical），保留交叉断言。
        XCTAssertEqual(info.healthLevel, .critical)
        XCTAssertEqual(appState.systemHealthLevel, status.aggregateHealthLevel(), "状态栏 SF Symbol 圆点必须与卡片头部点同色")
        XCTAssertEqual(appState.systemHealthLevel, .healthy)
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

    /// 设置页 picker 与主面板 header 使用的 App 图标设计稿必须能从资源包加载；
    /// 加载失败会静默回退，这里钉住资源打包不回退。
    func testQuotaLogoPickerPreviewUsesDesignAsset() {
        let preview = MenuBarLabel.appIconDesignImage
        XCTAssertNotNil(preview, "设计稿 SVG 未打入资源包，picker 与 header 将回退")
        // 归一到与各处预览一致的 22pt 画布。
        XCTAssertEqual(preview?.size.width, 22)
        XCTAssertEqual(preview?.size.height, 22)
        XCTAssertEqual(
            SettingsView.previewImage(for: .quotaLogo).tiffRepresentation,
            preview?.tiffRepresentation
        )
        // 其余样式始终走现生成逻辑。
        XCTAssertEqual(SettingsView.previewImage(for: .iconDuo).size.width, 22)
    }

    /// 主面板 header 使用的完整 App 图标（icon-master.png）必须能从资源包加载。
    func testHeaderAppIconMasterImageLoads() {
        let master = MenuBarLabel.appIconMasterImage
        XCTAssertNotNil(master, "icon-master.png 未打入资源包，header 将回退到系统符号")
        XCTAssertEqual(master?.size.width, 22)
        XCTAssertEqual(master?.size.height, 22)
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

    // MARK: - App 图标设计稿：载入时裁掉透明留白 + 菜单栏绘制边长

    /// 光栅化一张图并返回其不透明像素的包围盒（归一化到 0...1）。
    @MainActor
    private func opaqueBounds(of image: NSImage, edge: Int = 256) -> CGRect? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        // NSBitmapImageRep 的像素在 restore 之前就写好了，直接读 bitmapData。
        let bytes = bitmap.bitmapData!
        let bytesPerRow = bitmap.bytesPerRow
        var minX = edge, maxX = -1, minY = edge, maxY = -1
        for y in 0..<edge {
            for x in 0..<edge where bytes[y * bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(edge), y: CGFloat(minY) / CGFloat(edge),
            width: CGFloat(maxX - minX + 1) / CGFloat(edge),
            height: CGFloat(maxY - minY + 1) / CGFloat(edge)
        )
    }

    @MainActor
    func testDesignAssetIsLoadedAlreadyCropped() {
        // 设计稿原始画布里图形只占约 59%，其余是透明留白；载入时必须裁掉，菜单栏与
        // 设置页 picker 两个消费方才都拿到"图形本身"，谁再按原画布缩放都不会小 41%。
        //
        // 判据是**包围盒贴住四条边**，不是"不透明像素占比高"：这张图是个环，环心
        // 天生是透明的，裁干净之后覆盖率也只有 54%——用覆盖率判会把裁好的图判成没裁。
        //
        // 这条断言同时钉住一个静默失效的坑：包围盒靠"光栅化后扫描 alpha"算，
        // 而 `CGContext.makeImage()` 快照的是上下文的**当前**内容，先取 image 再
        // 绘制会得到全透明图，扫不到不透明像素 → 退回整幅画布：图标还是那么小，
        // 却不报错不崩溃。顺序写反时只有这条会红。
        let image = try? XCTUnwrap(MenuBarLabel.appIconDesignImage)
        XCTAssertNotNil(image)
        guard let design = image else { return }
        let bounds = try? XCTUnwrap(opaqueBounds(of: design))
        XCTAssertNotNil(bounds)
        guard let box = bounds else { return }
        for (name, value) in [("minX", box.minX), ("minY", box.minY),
                              ("maxX", 1 - box.maxX), ("maxY", 1 - box.maxY)] {
            XCTAssertLessThan(value, 0.02, "内容与 \(name) 侧之间还有 \(value * 100)% 的留白没裁掉")
        }
        XCTAssertEqual(box.width, box.height, accuracy: 0.02, "裁剪保宽高比，这张设计稿是正方形")
    }

    func testBaseDrawRectSizesTheAppIconToEighteenPoints() {
        // 「App 图标」是这张表里唯一单独定边长的：细描边环比实心字形看着小，
        // 但铺满 22pt 画布又偏大，18pt 是菜单栏里不抢戏也不显小的那一档。
        let rect = MenuBarLabel.baseDrawRect(for: .quotaLogo, canvas: 22)
        XCTAssertEqual(rect.width, 18, accuracy: 0.001)
        XCTAssertEqual(rect.height, 18, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 11, accuracy: 0.001, "必须居中，否则图标偏在一侧")
        XCTAssertEqual(rect.midY, 11, accuracy: 0.001)
    }

    func testBaseDrawRectKeepsTheInsetBoxForEveryOtherStyle() {
        // 其余样式一律 1pt 边距的 20pt 框：SF Symbol 自带内边距、Icon Duo 是紧凑
        // 画布，靠这个框把视觉尺寸压到 15~17pt。别顺手把它们也改成 18pt。
        for style in [StatusBarIconStyle.chartBar, .sparkles, .brain, .cpu, .iconDuo] {
            let rect = MenuBarLabel.baseDrawRect(for: style, canvas: 22)
            XCTAssertEqual(rect, CGRect(x: 1, y: 1, width: 20, height: 20), "\(style.displayName)")
        }
    }

    func testBaseDrawRectNeverExceedsTheCanvas() {
        // 画布被改小（比如以后跟随外观调整）时，绘制框不能溢出画布。
        for canvas in [CGFloat(22), 18, 16] {
            for style in StatusBarIconStyle.allCases {
                let rect = MenuBarLabel.baseDrawRect(for: style, canvas: canvas)
                XCTAssertLessThanOrEqual(rect.width, canvas, "\(style.rawValue) @ \(canvas)")
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(style.rawValue) @ \(canvas)")
            }
        }
    }

    @MainActor
    // MARK: - 统一 colorLevel 判定（方案 A）

    /// `ModelQuota.aggregateHealthLevel`：binding 选择与并列取 5h、周 × N 折算、
    /// 高峰 floor、无窗口 .critical。
    func testModelQuotaAggregateHealthLevel() {
        let week = 7.0 * 24 * 3600

        func makeModel(
            intervalPercent: Double?,
            weeklyPercent: Double?,
            weeklyTimeFraction: Double = 1.0
        ) -> ModelQuota {
            ModelQuota(
                modelName: "model",
                intervalTotalCount: 100,
                intervalUsageCount: 100 - Int(intervalPercent ?? 0),
                intervalRemainingPercent: intervalPercent ?? 0,
                intervalStatus: intervalPercent != nil ? .present : .absent,
                intervalResetsAt: intervalPercent != nil ? Date().addingTimeInterval(3600) : nil,
                intervalWindowSeconds: intervalPercent != nil ? 5 * 3600 : nil,
                weeklyTotalCount: 100,
                weeklyUsageCount: 100 - Int(weeklyPercent ?? 0),
                weeklyRemainingPercent: weeklyPercent ?? 0,
                weeklyStatus: weeklyPercent != nil ? .present : .absent,
                weeklyResetsAt: weeklyPercent != nil
                    ? Date().addingTimeInterval(week * weeklyTimeFraction)
                    : nil,
                weeklyWindowSeconds: weeklyPercent != nil ? Int(week) : nil
            )
        }

        // 1. 无任何窗口 → .critical（对齐 statusBarHealthLevel 的历史语义）。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan),
            .critical
        )

        // 2. 仅 5h 短窗口：固定 30% 黄线、< 15 红。35% 绿 / 25% 黄 / 10% 红。
        XCTAssertEqual(makeModel(intervalPercent: 35, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .healthy)
        XCTAssertEqual(makeModel(intervalPercent: 25, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .warning)
        XCTAssertEqual(makeModel(intervalPercent: 10, weeklyPercent: nil).aggregateHealthLevel(providerKind: .glmCodingPlan), .critical)

        // 3. 仅周窗口：周 × N 折算参与。GLM N=5：周 8% → 40%，瓶颈周（tf≈1 →
        //    黄线 50）→ 黄。若未折算，8% 会直接落进 < 15 的红区。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: 8).aggregateHealthLevel(providerKind: .glmCodingPlan),
            .warning
        )
        // codex N=6：周 6% → 36% → 黄（原始 6% 为红，折算改变判定）。
        XCTAssertEqual(
            makeModel(intervalPercent: nil, weeklyPercent: 6).aggregateHealthLevel(providerKind: .codexChatGpt),
            .warning
        )

        // 4. 双窗口并列（5h 40% = 周 8%×5）：并列取 5h → tf 为 nil（固定 30% 黄线）
        //    → 40% 绿。若错误地取周瓶颈（tf≈1 → 黄线 50），40% 会是黄。
        XCTAssertEqual(
            makeModel(intervalPercent: 40, weeklyPercent: 8).aggregateHealthLevel(providerKind: .glmCodingPlan),
            .healthy
        )

        // 5. 高峰 floor：healthy 被压到 warning；critical 保持 critical（红色优先）。
        XCTAssertEqual(
            makeModel(intervalPercent: 80, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: true),
            .warning
        )
        XCTAssertEqual(
            makeModel(intervalPercent: 80, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: false),
            .healthy
        )
        XCTAssertEqual(
            makeModel(intervalPercent: 10, weeklyPercent: nil)
                .aggregateHealthLevel(providerKind: .glmCodingPlan, isPeakPrice: true),
            .critical
        )
    }

    /// `ProviderStatus.aggregateHealthLevel`：nil 透传（灰点）、空窗口 .critical、
    /// deepseek 余额卡头点与旧 `healthLevel` 行为一致、GLM 高峰 floor。
    func testProviderStatusAggregateHealthLevel() {
        func makeBalanceModel(percent: Double) -> ModelQuota {
            ModelQuota(
                modelName: "deepseek_balance",
                intervalTotalCount: 0,
                intervalUsageCount: 0,
                intervalRemainingPercent: percent,
                intervalStatus: .present,
                intervalResetsAt: nil,
                intervalWindowSeconds: nil,
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: 0,
                weeklyStatus: .absent,
                weeklyResetsAt: nil,
                weeklyWindowSeconds: nil
            )
        }

        func makeStatus(
            kind: ProviderKind,
            state: ProviderStatus.State,
            glmPeakWindow: PeakWindow? = nil
        ) -> ProviderStatus {
            var status = ProviderStatus(
                id: "t", displayName: "T", kind: kind,
                iconSystemName: "c", accentColor: .minimax,
                refreshIntervalSeconds: 60, state: state
            )
            status.glmPeakWindow = glmPeakWindow
            return status
        }

        // 1. lastSuccess 为 nil → nil（保持灰点语义）。
        XCTAssertNil(makeStatus(kind: .codexChatGpt, state: .ready).aggregateHealthLevel())
        XCTAssertNil(
            makeStatus(kind: .glmCodingPlan, state: .loading(lastSuccess: nil)).aggregateHealthLevel()
        )

        // 2. deepseek 余额模型：新路径与旧 `healthLevel` 完全一致（50% 绿 / 0% 红），
        //    卡头点现状颜色不变。
        for percent in [50.0, 0.0] {
            let status = makeStatus(
                kind: .deepseek,
                state: .ok(QuotaInfo(
                    models: [makeBalanceModel(percent: percent)],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            )
            XCTAssertEqual(status.aggregateHealthLevel(), status.healthLevel)
        }
        XCTAssertEqual(
            makeStatus(
                kind: .deepseek,
                state: .ok(QuotaInfo(
                    models: [makeBalanceModel(percent: 50)],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            ).aggregateHealthLevel(),
            .healthy
        )

        // 3. 有数据但 models 为空（无有效窗口 model）→ .critical（对齐 QuotaInfo.healthLevel 现状）。
        XCTAssertEqual(
            makeStatus(
                kind: .minimaxTokenPlan,
                state: .ok(QuotaInfo(
                    models: [],
                    resetCredits: nil, planLabel: nil, accountEmail: nil,
                    codexUsageDetails: nil, fetchedAt: Date()
                ))
            ).aggregateHealthLevel(),
            .critical
        )

        // 4. GLM 高峰 floor：高峰时 healthy → warning；非高峰保持 healthy。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let offPeak = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 10))!
        let peak = calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 15))!
        let glmHealthy = makeStatus(
            kind: .glmCodingPlan,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "glm_coding_plan",
                    intervalTotalCount: 100, intervalUsageCount: 20,
                    intervalRemainingPercent: 80,
                    intervalStatus: .present,
                    intervalResetsAt: Date().addingTimeInterval(3600),
                    intervalWindowSeconds: 5 * 3600,
                    weeklyTotalCount: 0, weeklyUsageCount: 0,
                    weeklyRemainingPercent: 0, weeklyStatus: .absent,
                    weeklyResetsAt: nil, weeklyWindowSeconds: nil
                )],
                resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: Date()
            )),
            glmPeakWindow: PeakWindow(startHour: 14, endHour: 18, weekdaysOnly: false)
        )
        XCTAssertEqual(glmHealthy.aggregateHealthLevel(at: offPeak), .healthy)
        XCTAssertEqual(glmHealthy.aggregateHealthLevel(at: peak), .warning, "高峰时卡头点保底黄色")
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
