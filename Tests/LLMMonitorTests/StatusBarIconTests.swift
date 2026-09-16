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
        let outer = QuotaRingMetrics(minAvailable: 0.3, avgAvailable: 0.7, colorHex: "#FB923C")
        let middle = QuotaRingMetrics(minAvailable: 0.5, avgAvailable: 0.8, colorHex: "#2DD4BF")
        let metrics = StatusBarQuotaMetrics(
            weekly: outer,
            interval: middle,
            lowestAvailable: 0.3,
            quotaHealthLevels: [.healthy, .warning, .critical]
        )
        let svg = QuotaLogoSVGBuilder.buildSVG(
            metrics: metrics,
            energyHealth: .warning
        )

        XCTAssertTrue(svg.contains("viewBox=\"0 0 704 704\""))
        XCTAssertTrue(svg.contains("id=\"interval-available\""))
        XCTAssertTrue(svg.contains("stroke-dasharray=\"800.00 1000\""))
        XCTAssertTrue(svg.contains("id=\"weekly-available\""))
        XCTAssertTrue(svg.contains("stroke-dasharray=\"700.00 1000\""))
        XCTAssertFalse(svg.contains("stroke-dasharray=\"32 64\""), "新版额度段应为连续实线")
        XCTAssertEqual(svg.components(separatedBy: "data-divider-length=\"32\"").count - 1, 2)
        XCTAssertTrue(svg.contains("stroke=\"#FF453A\""), "最低值分界线使用红色")
        XCTAssertTrue(svg.contains("id=\"minimum-value\" data-value=\"30\""), "中心应展示最低套餐额度")
        XCTAssertTrue(svg.contains("fill=\"#FFD60A\""), "顶部闪电应显示节能健康色")
        XCTAssertTrue(svg.contains("cx=\"250\" cy=\"622\" r=\"18\" fill=\"#FF453A\""))
        XCTAssertTrue(svg.contains("cx=\"318\" cy=\"622\" r=\"18\" fill=\"#FFD60A\""))
        XCTAssertTrue(svg.contains("cx=\"386\" cy=\"622\" r=\"18\" fill=\"#34C759\""))
        XCTAssertTrue(svg.contains("cx=\"454\" cy=\"622\" r=\"18\" fill=\"#34C759\""))

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
        XCTAssertEqual(metrics.quotaHealthLevels, [.warning, .healthy, .healthy, .healthy])
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


