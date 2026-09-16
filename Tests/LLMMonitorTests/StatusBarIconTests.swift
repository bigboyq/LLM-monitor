import XCTest
import Combine
import Foundation
@testable import LLM_monitor

final class StatusBarIconTests: XCTestCase {

    func testStatusBarConfigEncodingAndDecoding() throws {
        var config = AppConfig.default
        XCTAssertEqual(config.effectiveStatusBarIconStyle, .chartBar)
        XCTAssertEqual(config.effectiveStatusBarIndicatorMode, .colored)
        XCTAssertTrue(config.effectiveStatusBarHealthDotEnabled)

        config.statusBarIconStyle = .sparkles
        config.statusBarIndicatorMode = .monochrome
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
        XCTAssertEqual(decoded.statusBarIndicatorMode, .monochrome)
        XCTAssertEqual(decoded.statusBarHealthDotEnabled, false)
        XCTAssertEqual(decoded.statusBarHealthColors, config.statusBarHealthColors)
        XCTAssertEqual(decoded.effectiveStatusBarIconStyle, .sparkles)
        XCTAssertEqual(decoded.effectiveStatusBarIndicatorMode, .monochrome)
        XCTAssertFalse(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.effectiveStatusBarHealthColors, config.statusBarHealthColors)
    }

    func testStatusBarIconStyleEnumProperties() {
        XCTAssertEqual(StatusBarIconStyle.chartBar.systemImageName, "chart.bar.fill")
        XCTAssertEqual(StatusBarIconStyle.sparkles.systemImageName, "sparkles")
        XCTAssertEqual(StatusBarIconStyle.brain.systemImageName, "brain.head.profile")
        XCTAssertEqual(StatusBarIconStyle.cpu.systemImageName, "cpu.fill")
        XCTAssertEqual(StatusBarIconStyle.quotaLogo.systemImageName, "chart.donut.fill")

        XCTAssertEqual(StatusBarIconStyle.chartBar.displayName, "柱状图")
        XCTAssertEqual(StatusBarIconStyle.sparkles.displayName, "AI 星光")
        XCTAssertEqual(StatusBarIconStyle.brain.displayName, "智能大脑")
        XCTAssertEqual(StatusBarIconStyle.cpu.displayName, "芯片")
        XCTAssertEqual(StatusBarIconStyle.quotaLogo.displayName, "App 图标")

        XCTAssertEqual(StatusBarIndicatorMode.colored.displayName, "健康度着色")
        XCTAssertEqual(StatusBarIndicatorMode.monochrome.displayName, "单色模版")
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
            lowestAvailable: 1,
            quotaHealthLevels: [.warning]
        )
        let criticalMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            lowestAvailable: 1,
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
        XCTAssertEqual(decoded.effectiveStatusBarIndicatorMode, .colored)
        XCTAssertTrue(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.providers["minimax_token_plan"]?.enabled, true)
        XCTAssertEqual(decoded.providers["minimax_token_plan"]?.apiKey, "real-key")
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

    func testQuotaLogoSVGBuilderDashboardGeometry() {
        let outer = QuotaRingMetrics(minAvailable: 0.1, avgAvailable: 0.15, colorHex: "#FB923C") // <= 15% -> critical
        let middle = QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.35, colorHex: "#2DD4BF") // 15%..40% -> warning
        let metrics = StatusBarQuotaMetrics(
            weekly: outer,
            interval: middle,
            lowestAvailable: 0.5, // > 40% -> healthy
            quotaHealthLevels: [.healthy, .warning, .critical]
        )
        let svg = QuotaLogoSVGBuilder.buildSVG(
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
        XCTAssertTrue(svg.contains("fill=\"#FFD60A\""), "顶部节能点或左弧预警状态使用黄色")
        XCTAssertTrue(svg.contains("id=\"center-sector\" data-value=\"50\""), "中心扇形展示 50% 额度")
        XCTAssertTrue(svg.contains("id=\"quota-dot-0\""))
        XCTAssertTrue(svg.contains("id=\"quota-dot-1\""))
        XCTAssertTrue(svg.contains("id=\"quota-dot-2\""))
        XCTAssertFalse(svg.contains("id=\"quota-dot-3\""), "已调整为 3 个点，不再有第 4 个点")
        XCTAssertTrue(svg.contains("r=\"36\""), "点半径放大至 r=36")
        XCTAssertTrue(svg.contains("fill=\"#FF453A\""), "包含红色状态点或周额度异常色")

        // 缺失窗口只绘制灰色底轨，不得伪装成 100% 可用。
        let weeklyOnly = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5, colorHex: "#FB923C"),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#2DD4BF", isAvailable: false),
            lowestAvailable: 0.5
        )
        let weeklyOnlySVG = QuotaLogoSVGBuilder.buildSVG(metrics: weeklyOnly)
        XCTAssertFalse(weeklyOnlySVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlySVG.contains("id=\"weekly-available\""))

        let intervalOnly = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#FB923C", isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.5, colorHex: "#2DD4BF"),
            lowestAvailable: 0.5
        )
        let intervalOnlySVG = QuotaLogoSVGBuilder.buildSVG(metrics: intervalOnly)
        XCTAssertTrue(intervalOnlySVG.contains("id=\"interval-available\""))
        XCTAssertFalse(intervalOnlySVG.contains("id=\"weekly-available\""))

        let unknownSVG = QuotaLogoSVGBuilder.buildSVG(metrics: StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#FB923C", isAvailable: false),
            interval: QuotaRingMetrics(minAvailable: 0, avgAvailable: 0, colorHex: "#2DD4BF", isAvailable: false)
        ))
        XCTAssertTrue(unknownSVG.contains("id=\"center-sector\""))
        XCTAssertTrue(unknownSVG.contains("stroke=\"#8E8E93\""), "无数据时中心保持灰色环")

        // 验证统一红黄绿标准
        XCTAssertEqual(HealthLevel.standard(forFraction: 0.50), .healthy)
        XCTAssertEqual(HealthLevel.standard(forFraction: 0.40), .warning)
        XCTAssertEqual(HealthLevel.standard(forFraction: 0.25), .warning)
        XCTAssertEqual(HealthLevel.standard(forFraction: 0.15), .critical)
        XCTAssertEqual(HealthLevel.standard(forFraction: 0.05), .critical)

        // 验证三点优先级：红 > 黄 > 绿；如果有 3 个红，则不显示黄绿
        let threeRedsMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            lowestAvailable: 0.8,
            quotaHealthLevels: [.critical, .warning, .critical, .healthy, .critical]
        )
        XCTAssertEqual(threeRedsMetrics.quotaHealthLevels, [.critical, .critical, .critical])

        let mixedMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 1, avgAvailable: 1, defaultColor: "#2DD4BF"),
            lowestAvailable: 0.8,
            quotaHealthLevels: [.healthy, .critical, .warning]
        )
        XCTAssertEqual(mixedMetrics.quotaHealthLevels, [.critical, .warning, .healthy])

        // 验证全满状态（360度整圆）
        let fullSvg = QuotaLogoSVGBuilder.buildSVG(metrics: .full, energyHealth: .healthy)
        XCTAssertTrue(fullSvg.contains("<circle id=\"center-sector\" data-value=\"100\""))

        // 验证 3 个红点全耗尽状态
        let allExhaustedMetrics = StatusBarQuotaMetrics(
            weekly: .default(minAvailable: 0, avgAvailable: 0, defaultColor: "#FB923C"),
            interval: .default(minAvailable: 0, avgAvailable: 0, defaultColor: "#2DD4BF"),
            lowestAvailable: 0.0,
            quotaHealthLevels: [.critical, .critical, .critical]
        )
        let exhaustedSvg = QuotaLogoSVGBuilder.buildSVG(metrics: allExhaustedMetrics)
        XCTAssertTrue(exhaustedSvg.contains("<circle id=\"center-sector\" data-value=\"0\""))
        XCTAssertTrue(exhaustedSvg.contains("stroke=\"#FF453A\""), "中心呈现红色空心警示环")
        XCTAssertEqual(exhaustedSvg.components(separatedBy: "fill=\"#FF453A\"").count - 1, 3, "底部固定 3 个红点")

        let image = QuotaLogoSVGBuilder.buildImage(
            metrics: metrics,
            energyHealth: .warning
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 22)
        XCTAssertEqual(image?.size.height, 22)
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
        XCTAssertEqual(metrics.lowestAvailable ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(metrics.quotaHealthLevels, [.warning, .warning, .healthy])

        // 状态栏统一使用固定 standard 阈值：短窗口 35% 同时为黄，15% 同时为红。
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

        setStandardQuota(35.0)
        let warningMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(warningMetrics.quotaHealthLevels, [.warning, .warning, .healthy])
        let warningSVG = QuotaLogoSVGBuilder.buildSVG(metrics: warningMetrics)
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\" d="), "35% 短窗口弧线仍显示可用段")
        XCTAssertTrue(warningSVG.contains("stroke=\"#FFD60A\""), "35% 短窗口弧线和套餐点均为黄色")

        setStandardQuota(15.0)
        let criticalMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(criticalMetrics.quotaHealthLevels, [.critical, .critical, .healthy])
        let criticalSVG = QuotaLogoSVGBuilder.buildSVG(metrics: criticalMetrics)
        XCTAssertTrue(criticalSVG.contains("stroke=\"#FF453A\""), "15% 短窗口弧线为红色")

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
        let weeklyOnlyStateSVG = QuotaLogoSVGBuilder.buildSVG(metrics: weeklyOnlyMetrics)
        XCTAssertFalse(weeklyOnlyStateSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlyStateSVG.contains("id=\"weekly-available\""))

        setWindowPresence(intervalStatus: .present, weeklyStatus: .absent)
        let intervalOnlyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertTrue(intervalOnlyMetrics.interval.isAvailable)
        XCTAssertFalse(intervalOnlyMetrics.weekly.isAvailable)
        let intervalOnlyStateSVG = QuotaLogoSVGBuilder.buildSVG(metrics: intervalOnlyMetrics)
        XCTAssertTrue(intervalOnlyStateSVG.contains("id=\"interval-available\""))
        XCTAssertFalse(intervalOnlyStateSVG.contains("id=\"weekly-available\""))
    }

    func testComposedMenuBarImageWithDynamicMetrics() {
        let fullMetrics = StatusBarQuotaMetrics.full
        let customMetrics = StatusBarQuotaMetrics(
            weekly: QuotaRingMetrics(minAvailable: 0.3, avgAvailable: 0.6, colorHex: "#FB923C"),
            interval: QuotaRingMetrics(minAvailable: 0.2, avgAvailable: 0.5, colorHex: "#2DD4BF"),
            lowestAvailable: 0.2,
            quotaHealthLevels: [.critical, .warning]
        )

        let fullImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: fullMetrics
        )
        let customImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: customMetrics
        )

        XCTAssertNotEqual(fullImage.tiffRepresentation, customImage.tiffRepresentation)

        let keepAwakeImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: customMetrics,
            energyHealth: .critical
        )
        let energySavingImage = MenuBarLabel.composedMenuBarImage(
            iconStyle: .quotaLogo,
            health: .healthy,
            quotaMetrics: customMetrics,
            energyHealth: .healthy
        )
        XCTAssertNotEqual(keepAwakeImage.tiffRepresentation, energySavingImage.tiffRepresentation)
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
}
