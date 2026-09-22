import XCTest
import Combine
import Foundation
@testable import LLM_monitor

final class StatusBarIconTests: XCTestCase {

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

        let healthyMetrics = StatusBarQuotaMetrics.full
        let warningMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            centerAvailable: 1,
            quotaHealthLevels: [.warning]
        )
        let criticalMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            centerAvailable: 1,
            quotaHealthLevels: [.critical]
        )
        let healthyQuotaLogo = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: healthyMetrics
        )
        let warningQuotaLogo = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .warning,
            quotaMetrics: warningMetrics
        )
        let criticalQuotaLogo = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .critical,
            quotaMetrics: criticalMetrics
        )
        XCTAssertNotEqual(healthyQuotaLogo.tiffRepresentation, warningQuotaLogo.tiffRepresentation)
        XCTAssertNotEqual(warningQuotaLogo.tiffRepresentation, criticalQuotaLogo.tiffRepresentation)
        XCTAssertNotEqual(
            healthyQuotaLogo.tiffRepresentation,
            MenuBarLabel.composedMenuBarImage(
                iconStyle: .quotaLogo,
                health: .healthy,
                healthColors: customColors
            ).tiffRepresentation
        )
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
        let outer = QuotaRingMetrics(minAvailable: 0.1, avgAvailable: 0.15, colorHex: "#FB923C") // < 30 → warning
        let middle = QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.35, colorHex: "#2DD4BF") // >= 30 → healthy
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
            weekly: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5, colorHex: "#FB923C"),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#2DD4BF", isAvailable: false),
            centerAvailable: 0.5
        )
        let weeklyOnlySVG = IconDuoSVGBuilder.buildSVG(metrics: weeklyOnly)
        XCTAssertFalse(weeklyOnlySVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlySVG.contains("id=\"weekly-available\""))

        let intervalOnly = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#FB923C", isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5, colorHex: "#2DD4BF"),
            centerAvailable: 0.5
        )
        let intervalOnlySVG = IconDuoSVGBuilder.buildSVG(metrics: intervalOnly)
        XCTAssertTrue(intervalOnlySVG.contains("id=\"interval-available\""))
        XCTAssertFalse(intervalOnlySVG.contains("id=\"weekly-available\""))

        let unknownSVG = IconDuoSVGBuilder.buildSVG(metrics: StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#FB923C", isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#2DD4BF", isAvailable: false)
        ))
        XCTAssertTrue(unknownSVG.contains("id=\"center-sector\""))
        XCTAssertTrue(unknownSVG.contains("stroke=\"#8E8E93\""), "无数据时中心保持灰色环")

        // 验证三点优先级：红 > 黄 > 绿；如果有 3 个红，则不显示黄绿
        let threeRedsMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            centerAvailable: 0.8,
            quotaHealthLevels: [.critical, .warning, .critical, .healthy, .critical]
        )
        XCTAssertEqual(threeRedsMetrics.quotaHealthLevels, [.critical, .critical, .critical])

        let mixedMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            centerAvailable: 0.8,
            quotaHealthLevels: [.healthy, .critical, .warning]
        )
        XCTAssertEqual(mixedMetrics.quotaHealthLevels, [.critical, .warning, .healthy])

        // 验证全满状态（360度整圆）
        let fullSvg = IconDuoSVGBuilder.buildSVG(metrics: .full, energyHealth: .healthy)
        XCTAssertTrue(fullSvg.contains("<circle id=\"center-sector\" data-value=\"100\""))

        // 验证 3 个红点全耗尽状态
        let allExhaustedMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 0, avgAvailable: 0, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 0, avgAvailable: 0, defaultColor: "#2DD4BF"),
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
        XCTAssertNil(metrics.waterHealth)
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

    func testComposedMenuBarImageWithDynamicMetrics() {
        let fullMetrics = StatusBarQuotaMetrics.full
        let customMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0.3, avgAvailable: 0.6, colorHex: "#FB923C"),
            interval: QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.5, colorHex: "#2DD4BF"),
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

    /// 经典 App 图标（上一版样式）：逆时针双环 + 中心水位杯。
    func testQuotaLogoSVGBuilderArcAndWaterCalculations() {
        let outer = QuotaRingMetrics(minAvailable: 0.3, avgAvailable: 0.7, colorHex: "#FB923C")
        let middle = QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.8, colorHex: "#2DD4BF")
        let metrics = StatusBarQuotaMetrics(weekly: outer, interval: middle, waterHealth: nil)

        // waterHealth 缺失时回退整体健康度（.healthy → 绿色水体）。
        let svg = QuotaLogoSVGBuilder.buildSVG(
            metrics: metrics,
            fallbackHealth: .healthy
        )

        // 验证 viewBox 对称且足够容纳外圈，包含刻度虚线与水位杯裁剪。
        XCTAssertTrue(svg.contains("viewBox=\"160 160 704 704\""))
        XCTAssertTrue(svg.contains("stroke-dasharray=\"32 64\""))
        XCTAssertTrue(svg.contains("clip-path=\"url(#cup)\""))
        // 验证逆时针绘制（sweep-flag 为 0）。
        XCTAssertTrue(svg.contains("A 320 320 0 0 0"))
        // 水位取 5h 最低剩余量 0.5：waterHeight = 310 * 0.5 = 155.00, y = 702 - 155 = 547.00。
        XCTAssertTrue(svg.contains("height=\"155.00\""))
        XCTAssertTrue(svg.contains("y=\"547.00\""))
        XCTAssertTrue(svg.contains("fill=\"#34C759\""))

        // waterHealth 优先于整体健康度：红色水位。
        let criticalSVG = QuotaLogoSVGBuilder.buildSVG(
            metrics: StatusBarQuotaMetrics(weekly: outer, interval: middle, waterHealth: .critical)
        )
        XCTAssertTrue(criticalSVG.contains("fill=\"#FF453A\""))

        // 缺失窗口沿用上一版语义按满环呈现：无 5h 窗口 → 满水位；
        // 无周窗口 → 外环绘制为完整圆。
        let missingInterval = QuotaLogoSVGBuilder.buildSVG(
            metrics: StatusBarQuotaMetrics(
                weekly: outer,
                interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#2DD4BF", isAvailable: false),
                waterHealth: .healthy
            )
        )
        XCTAssertTrue(missingInterval.contains("height=\"310.00\""))
        XCTAssertTrue(missingInterval.contains("y=\"392.00\""))

        let missingWeekly = QuotaLogoSVGBuilder.buildSVG(
            metrics: StatusBarQuotaMetrics(
                weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#FB923C", isAvailable: false),
                interval: middle,
                waterHealth: .healthy
            )
        )
        XCTAssertTrue(missingWeekly.contains("<circle cx=\"512\" cy=\"512\" r=\"320.0\""))

        let image = QuotaLogoSVGBuilder.buildImage(
            metrics: metrics,
            fallbackHealth: .healthy
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 22)
        XCTAssertEqual(image?.size.height, 22)
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

    /// quotaLogo 的双源一致性守门：菜单栏真实图标由 QuotaLogoSVGBuilder 运行时
    /// 生成，设置页预览却来自手写设计稿（llm-quota-730-2-dark.svg），几何常量
    /// 改一侧不改另一侧会静默漂移。这里用能复现设计稿姿态的代表性输入
    /// （外环 12 点逆时针 3/8 圈即 7:30 方向、内环 5/6 圈即 2 点方向、avg = min
    /// 不产生刻度虚线段）让生成器产出同款双弧，再与资源文件逐项比较。
    ///
    /// 比较范围：两条弧的半径 / 端点 / large-arc 标志 / stroke-width / linecap /
    /// 描边色，以及杯型路径（生成器是 clipPath、设计稿是满杯填充，本应是同
    /// 一条 d）。不比较 viewBox——生成器裁掉透明留白用 704，设计稿保留完整
    /// 1024 画布，但两者坐标系同为 1024 设计空间，元素坐标可直接对齐；不比较
    /// 水位 rect——水位高度属动态语义（随指标变化），设计稿以满杯形状表达，
    /// 生成器用 rect + clipPath 表达，水位数值本应允许不同。
    func testQuotaLogoDesignAssetGeometryMatchesBuilder() throws {
        let metrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(
                minAvailable: 0.375, avgAvailable: 0.375,
                colorHex: QuotaLogoSVGBuilder.defaultOuterColor
            ),
            interval: QuotaRingMetrics(
                minAvailable: 5.0 / 6.0, avgAvailable: 5.0 / 6.0,
                colorHex: QuotaLogoSVGBuilder.defaultMiddleColor
            )
        )
        let generated = QuotaLogoSVGBuilder.buildSVG(metrics: metrics)

        let designURL = try XCTUnwrap(
            Bundle.module.url(forResource: "llm-quota-730-2-dark", withExtension: "svg"),
            "设计稿 SVG 必须随 app target 打包（Package.swift resources 声明）"
        )
        let design = try String(contentsOf: designURL, encoding: .utf8)

        let generatedArcs = try Self.strokedArcSkeletons(in: generated)
        let designArcs = try Self.strokedArcSkeletons(in: design)
        XCTAssertEqual(generatedArcs.count, 2, "生成器应产出外环 + 内环两条弧，实际 \(generatedArcs.count) 条")
        XCTAssertEqual(designArcs.count, 2, "设计稿应包含外环 + 内环两条弧，实际 \(designArcs.count) 条")

        // 两侧都按半径降序配对：首条为外环（r=320），次条为内环（r=240）。
        for (index, pair) in zip(generatedArcs, designArcs).enumerated() {
            let (generatedArc, designArc) = pair
            XCTAssertEqual(
                generatedArc.radius, designArc.radius, accuracy: 0.5,
                "第 \(index) 条弧半径不一致：生成器 \(generatedArc.radius) vs 设计稿 \(designArc.radius)"
            )
            XCTAssertEqual(
                generatedArc.strokeWidth, designArc.strokeWidth, accuracy: 0.5,
                "第 \(index) 条弧 stroke-width 不一致：生成器 \(generatedArc.strokeWidth) vs 设计稿 \(designArc.strokeWidth)"
            )
            XCTAssertEqual(
                generatedArc.largeArcFlag, designArc.largeArcFlag,
                "第 \(index) 条弧 large-arc 标志不一致：生成器 \(generatedArc.largeArcFlag) vs 设计稿 \(designArc.largeArcFlag)"
            )
            XCTAssertEqual(
                generatedArc.endpoints, designArc.endpoints,
                "第 \(index) 条弧端点不一致（已归一为 2 位小数、忽略绘制方向）：生成器 \(generatedArc.endpoints) vs 设计稿 \(designArc.endpoints)"
            )
            XCTAssertEqual(
                generatedArc.lineCap, designArc.lineCap,
                "第 \(index) 条弧 linecap 不一致：生成器 \(generatedArc.lineCap) vs 设计稿 \(designArc.lineCap)"
            )
            XCTAssertEqual(
                generatedArc.stroke, designArc.stroke,
                "第 \(index) 条弧描边色不一致：生成器 \(generatedArc.stroke) vs 设计稿 \(designArc.stroke)"
            )
        }

        // 杯型路径：生成器在 clipPath 内、设计稿是唯一的无 stroke 填充路径。
        let generatedCup = try Self.cupPathD(in: generated)
        let designCup = try Self.cupPathD(in: design)
        XCTAssertEqual(
            Self.normalizedPathGeometry(generatedCup), Self.normalizedPathGeometry(designCup),
            "杯型 clipPath 路径不一致（数值已归一为 3 位小数）：生成器 \(generatedCup) vs 设计稿 \(designCup)"
        )
    }

    /// 提取 SVG 中所有带 stroke 且 fill="none" 的 <path> 圆弧段，按半径降序。
    /// 属性按名读取，不依赖属性出现顺序；对注释 / 空白不敏感。
    private static func strokedArcSkeletons(in svg: String) throws -> [SVGArcSkeleton] {
        try allMatches(of: #"<path\b[^>]*/>"#, in: svg).compactMap { element in
            guard let stroke = attribute("stroke", in: element),
                  attribute("fill", in: element) == "none" else { return nil }
            guard let d = attribute("d", in: element) else { return nil }
            let arc = try parseArcD(d)
            return SVGArcSkeleton(
                radius: arc.radius,
                strokeWidth: Double(attribute("stroke-width", in: element) ?? "") ?? 0,
                largeArcFlag: arc.largeArc,
                endpoints: arc.endpoints,
                lineCap: attribute("stroke-linecap", in: element) ?? "",
                stroke: stroke
            )
        }
        .sorted { $0.radius > $1.radius }
    }

    /// 解析单条圆弧 path d（"M x1 y1 A rx ry rot large sweep x2 y2"）。
    /// 端点归一为 2 位小数并按字典序排序：设计稿与生成器绘制方向相反
    /// （设计稿顺时针 sweep=1、生成器逆时针 sweep=0），同一段弧端点互换。
    private static func parseArcD(_ d: String) throws -> (radius: Double, largeArc: Int, endpoints: [String]) {
        let pattern = #"M\s+(-?[\d.]+)\s+(-?[\d.]+)\s+A\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d)\s+(\d)\s+(-?[\d.]+)\s+(-?[\d.]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsd = d as NSString
        guard let match = regex.firstMatch(in: d, range: NSRange(d.startIndex..., in: d)),
              match.numberOfRanges == 10,
              let radius = Double(nsd.substring(with: match.range(at: 3))),
              let largeArc = Int(nsd.substring(with: match.range(at: 6))) else {
            XCTFail("无法按圆弧格式解析 path d：\(d)")
            throw NSError(domain: "SVGGeometry", code: 1)
        }
        let points = [match.range(at: 1), match.range(at: 2), match.range(at: 8), match.range(at: 9)]
            .compactMap { Range($0, in: d).flatMap { Double(d[$0]) } }
            .map { String(format: "%.2f", ($0 * 100).rounded() / 100) }
        guard points.count == 4 else {
            XCTFail("圆弧端点数量异常：\(d)")
            throw NSError(domain: "SVGGeometry", code: 2)
        }
        return (radius, largeArc, [points[0] + "," + points[1], points[2] + "," + points[3]].sorted())
    }

    /// 提取杯型路径 d：优先取生成器 clipPath 内的 path；设计稿没有 clipPath，
    /// 回退取唯一的无 stroke 填充 <path>。
    private static func cupPathD(in svg: String) throws -> String {
        if let d = firstCapture(of: #"<clipPath\b[^>]*>\s*<path\b[^>]*?\bd="([^"]+)""#, in: svg) {
            return d
        }
        let filled = try allMatches(of: #"<path\b[^>]*/>"#, in: svg).filter {
            attribute("stroke", in: $0) == nil && attribute("d", in: $0) != nil
        }
        guard filled.count == 1, let d = attribute("d", in: filled[0]) else {
            XCTFail("无法唯一定位设计稿杯型填充路径，候选 \(filled.count) 条")
            throw NSError(domain: "SVGGeometry", code: 3)
        }
        return d
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// 数值归一：折叠空白、把所有数字统一为 3 位小数书写，让「392.00000」与
    /// 「392.00」这类书写差异不影响比较，几何数值本身仍敏感。
    private static func normalizedPathGeometry(_ d: String) -> String {
        let collapsed = d.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
        let matches = regex.matches(in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed))
        var result = ""
        var cursor = collapsed.startIndex
        for match in matches {
            guard let range = Range(match.range, in: collapsed) else { continue }
            result += collapsed[cursor..<range.lowerBound]
            result += Double(collapsed[range]).map { String(format: "%.3f", $0) } ?? String(collapsed[range])
            cursor = range.upperBound
        }
        result += collapsed[cursor...]
        return result
    }

    private static func allMatches(of pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// 按属性名读取元素属性值；前缀断言避免 stroke 误读 stroke-width。
    private static func attribute(_ name: String, in element: String) -> String? {
        let pattern = #"(?<![\w-])\#(name)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element)),
              let range = Range(match.range(at: 1), in: element) else { return nil }
        return String(element[range])
    }

    @MainActor
    func testStatusBarWaterHealthLevels() {
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

        var cfg = store.config
        cfg.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "key_a")
        cfg.providers["test_b"] = ProviderConfig(enabled: true, apiKey: "key_b")
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
        let day = DateComponents(year: 2026, month: 8, day: 10)
        let offPeakTime = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 10, minute: 0
        ))!
        let peakTime = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 15, minute: 0
        ))!

        func makeModel(percent: Double) -> ModelQuota {
            ModelQuota(
                modelName: "model",
                intervalTotalCount: 100,
                intervalUsageCount: Int(100.0 - percent),
                intervalRemainingPercent: percent,
                intervalStatus: .present,
                intervalResetsAt: offPeakTime.addingTimeInterval(3600),
                intervalWindowSeconds: 18000,
                weeklyTotalCount: 100,
                weeklyUsageCount: 20,
                weeklyRemainingPercent: 80.0,
                weeklyStatus: .present,
                weeklyResetsAt: offPeakTime.addingTimeInterval(86400 * 7),
                weeklyWindowSeconds: 86400 * 7
            )
        }

        func setQuotas(aPercent: Double, bPercent: Double) {
            appState.mutateStatus(for: "test_a") { st in
                st.state = ProviderStatus.State.ok(QuotaInfo(models: [makeModel(percent: aPercent)], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: offPeakTime))
            }
            appState.mutateStatus(for: "test_b") { st in
                st.state = ProviderStatus.State.ok(QuotaInfo(models: [makeModel(percent: bPercent)], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: offPeakTime))
            }
        }

        // 1. 默认绿色：min >= 40%, avg >= 60%, 非高峰
        // a=70%, b=90% -> min=70%, avg=80%
        setQuotas(aPercent: 70.0, bPercent: 90.0)
        var metrics = appState.statusBarQuotaMetrics(at: offPeakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.healthy)

        // 2. 黄色场景 A：任意 5h 额度 < 40%
        // a=35%, b=85% -> min=35% (< 40%), avg=60%
        setQuotas(aPercent: 35.0, bPercent: 85.0)
        metrics = appState.statusBarQuotaMetrics(at: offPeakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.warning)

        // 3. 黄色场景 B：avg_5h < 60%（且 min >= 40%）
        // a=50%, b=60% -> min=50%, avg=55% (< 60%)
        setQuotas(aPercent: 50.0, bPercent: 60.0)
        metrics = appState.statusBarQuotaMetrics(at: offPeakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.warning)

        // 4. 黄色场景 C：有高峰价格（即使额度全部 100%）
        setQuotas(aPercent: 100.0, bPercent: 100.0)
        metrics = appState.statusBarQuotaMetrics(at: peakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.warning)

        // 5. 红色场景 A：任意 5h 额度 < 10%
        // a=8%, b=80% -> min=8% (< 10%), avg=44%
        setQuotas(aPercent: 8.0, bPercent: 80.0)
        metrics = appState.statusBarQuotaMetrics(at: offPeakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.critical)

        // 6. 红色场景 B：avg_5h < 40%
        // a=20%, b=30% -> min=20%, avg=25% (< 40%)
        setQuotas(aPercent: 20.0, bPercent: 30.0)
        metrics = appState.statusBarQuotaMetrics(at: offPeakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.critical)

        // 7. 优先级：红 > 黄（例如 min < 10% 且处于高峰期时，判定为红色）
        setQuotas(aPercent: 5.0, bPercent: 90.0)
        metrics = appState.statusBarQuotaMetrics(at: peakTime)
        XCTAssertEqual(metrics.waterHealth, HealthLevel.critical)
    }

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
