import XCTest
import Foundation
@testable import LLM_monitor

final class StatusBarQuotaMetricsTests: XCTestCase {

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
    func testStatusBarQuotaMetricsWithWeeklyTimeFactor() throws {
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

        // 固定在周六上午（非 GLM 高峰窗口：工作日 14:00–18:00）：test_b 是 GLM
        // provider，aggregateHealthLevel 的高峰保底会把期望的 healthy 压成
        // warning，用真实 Date() 的断言在高峰时段必然翻车。
        let now = Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 3, hour: 10)
        )!
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
        // 综合健康度对每个窗口独立标色后取差：A 周 30% / 剩余时间 60% = 50% → warning；
        // A 的 5h 与 B 的两个窗口均 healthy，故 A 的综合状态仍为 warning。
        XCTAssertEqual(metrics.quotaHealthLevels, [.warning, .healthy, .healthy])

        // 聚合右弧的动态黄线输入取所有周窗口剩余时间比例的最大值：A = 0.6、B = 0.2 → 0.6。
        XCTAssertEqual(metrics.weeklyTimeFraction ?? -1, 0.6, accuracy: 0.001)
        // 中心 argmin 是套餐 A（40% < 80%），双窗中心始终透传 5h 剩余时间比例（1h / 5h = 0.2）。
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)

        // 验证 statusBarPinnedProvider 锚定生效：若锚定到 test_b，则仅计算 test_b 的指标
        appState.toggleStatusBarPinnedProvider("test_b")

        let pinnedMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(pinnedMetrics.interval.minAvailable, 0.8, accuracy: 0.001)
        XCTAssertEqual(pinnedMetrics.interval.avgAvailable, 0.8, accuracy: 0.001)
        XCTAssertEqual(pinnedMetrics.weekly.minAvailable, 0.4, accuracy: 0.001)
        XCTAssertEqual(pinnedMetrics.weekly.avgAvailable, 0.4, accuracy: 0.001)
        XCTAssertEqual(pinnedMetrics.centerAvailable ?? -1, 0.8, accuracy: 0.001)

        // 取消锚定：再点一次 toggleOff，回退到全 provider 聚合
        appState.toggleStatusBarPinnedProvider("test_b")
        let unpinnedMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(unpinnedMetrics.interval.minAvailable, 0.4, accuracy: 0.001)

        // 状态栏统一 colorLevel（分母 = 100% * timeFraction）：刚重置时分母 100% →
        // 20% 为黄 (< 50%)、10% 为红 (< 20%)。
        func makeStandardModel(intervalPercent: Double) -> ModelQuota {
            ModelQuota(
                modelName: "standard-model",
                intervalTotalCount: 100,
                intervalUsageCount: Int(100.0 - intervalPercent),
                intervalRemainingPercent: intervalPercent,
                intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(5 * 3600),
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

        setStandardQuota(40.0)
        let warningMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(warningMetrics.quotaHealthLevels, [.warning, .warning, .healthy])
        let warningSVG = IconDuoSVGBuilder.buildSVG(metrics: warningMetrics)
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(warningSVG.contains("id=\"interval-available\" d="), "40% 短窗口弧线仍显示可用段")
        XCTAssertTrue(warningSVG.contains("stroke=\"#FFD60A\""), "40% 短窗口弧线和套餐点均为黄色")

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

        func parsedCodexQuota(primary: [String: Any], secondary: [String: Any]? = nil) throws -> ModelQuota {
            var rateLimit: [String: Any] = ["primary_window": primary]
            if let secondary { rateLimit["secondary_window"] = secondary }
            let data = try JSONSerialization.data(withJSONObject: ["rate_limit": rateLimit])
            return try CodexFetcher.parseUsage(CodexFetcher.parseUsageData(data))
        }

        func setCodexQuota(_ model: ModelQuota) {
            let info = QuotaInfo(
                models: [model], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now
            )
            appState.mutateStatus(for: "test_a") { $0.state = .ok(info) }
            appState.mutateStatus(for: "test_b") { $0.state = .ok(info) }
        }

        // Pro 可以只在 primary_window 返回 7d 配额。归一化后它必须进入 weekly，
        // 状态栏左弧保持空，右弧与中心均显示原始周剩余 70%。
        let proWeeklyOnly = try parsedCodexQuota(primary: [
            "used_percent": 30,
            "limit_window_seconds": 604_800,
            "reset_at": now.addingTimeInterval(3 * 86_400).timeIntervalSince1970
        ])
        XCTAssertFalse(proWeeklyOnly.hasIntervalWindow)
        XCTAssertTrue(proWeeklyOnly.hasWeeklyWindow)
        setCodexQuota(proWeeklyOnly)
        let weeklyOnlyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertFalse(weeklyOnlyMetrics.interval.isAvailable)
        XCTAssertTrue(weeklyOnlyMetrics.weekly.isAvailable)
        XCTAssertEqual(weeklyOnlyMetrics.weekly.minAvailable, 0.70, accuracy: 0.001)
        XCTAssertEqual(weeklyOnlyMetrics.centerAvailable ?? -1, 0.70, accuracy: 0.001)
        let weeklyOnlyStateSVG = IconDuoSVGBuilder.buildSVG(metrics: weeklyOnlyMetrics)
        XCTAssertFalse(weeklyOnlyStateSVG.contains("id=\"interval-available\""))
        XCTAssertTrue(weeklyOnlyStateSVG.contains("id=\"single-quota-available\""))
        XCTAssertFalse(weeklyOnlyStateSVG.contains("id=\"weekly-track\""))
        XCTAssertEqual(weeklyOnlyMetrics.singleQuota?.remainingFraction, 0.70)

        // 双窗口中周窗口耗尽时，5h 原始弧仍保留自身 75%；但有效额度（中心）归零。
        let exhaustedWeekly = try parsedCodexQuota(
            primary: [
                "used_percent": 25,
                "limit_window_seconds": 18_000,
                "reset_at": now.addingTimeInterval(3_600).timeIntervalSince1970
            ],
            secondary: [
                "used_percent": 100,
                "limit_window_seconds": 604_800,
                "reset_at": now.addingTimeInterval(3 * 86_400).timeIntervalSince1970
            ]
        )
        XCTAssertEqual(exhaustedWeekly.aggregateActualAvailable(providerKind: .codexChatGpt, at: now)?.percent, 0)
        setCodexQuota(exhaustedWeekly)
        let exhaustedWeeklyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(exhaustedWeeklyMetrics.interval.minAvailable, 0.75, accuracy: 0.001)
        XCTAssertEqual(exhaustedWeeklyMetrics.weekly.minAvailable, 0, accuracy: 0.001)
        XCTAssertEqual(exhaustedWeeklyMetrics.centerAvailable ?? -1, 0, accuracy: 0.001)

        setWindowPresence(intervalStatus: .present, weeklyStatus: .absent)
        let intervalOnlyMetrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertTrue(intervalOnlyMetrics.interval.isAvailable)
        XCTAssertFalse(intervalOnlyMetrics.weekly.isAvailable)
        let intervalOnlyStateSVG = IconDuoSVGBuilder.buildSVG(metrics: intervalOnlyMetrics)
        XCTAssertTrue(intervalOnlyStateSVG.contains("id=\"single-quota-available\""))
        XCTAssertFalse(intervalOnlyStateSVG.contains("id=\"interval-track\""))
        XCTAssertFalse(intervalOnlyStateSVG.contains("id=\"weekly-available\""))
    }

    /// 中心百分比的「实际可用」口径：每个套餐按自身存在的窗口取
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
        // 回归：虽然周额度限制了中心读数，时间仍配 5h 的 1h / 5h = 0.2，
        // 不得误用周窗口刚重置的 1.0。
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .critical, .healthy],
                       "综合健康应独立检查原始周额度，不能沿用中心折算值的健康状态")

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

        // 3. 仅周窗口：使用原始周百分比，不乘 N。GLM 周=20%、codex 周=10%，中心取 10%。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: nil, weeklyPercent: 20),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 10)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.10,
            accuracy: 0.001,
            "仅周窗口中心应保留原始周剩余百分比"
        )
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 1.0, accuracy: 0.001)

        // 4. 较高的仅周额度仍保留原始百分比，不因乘 N 而变为满格。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: nil, weeklyPercent: 40),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 30)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(
            metrics.centerAvailable ?? -1,
            0.30,
            accuracy: 0.001,
            "仅周窗口 40% 与 30% 应取 30%，不能折算为满格"
        )

        // 5. 仅 5h 窗口：直接按 5h 剩余参与，与原语义一致；中心 timeFraction
        //    统一透传其 5h 剩余时间比例（0.2）。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 25, weeklyPercent: nil),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: 35, weeklyPercent: nil)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)

        // 6. 所有套餐都没有任何窗口：中心保持 nil。
        setQuotas(a: nil, b: nil)
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertNil(metrics.centerAvailable, "所有套餐都没有任何窗口时中心应保持 nil")
        XCTAssertNil(metrics.centerTimeFraction)
    }

    /// 中心百分比的多套餐接力：已耗尽（实际可用为 0）的套餐不参与中心 min，
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
        //    中心 = B 的实际可用 35%，而非被 A 拖到 0；时间跟随 B 的 5h 短窗口。
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
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001, "B 的瓶颈为 5h 短窗口，中心 timeFraction 统一透传剩余时间比例 0.2")
        // 底部三点不排除耗尽套餐：A 的点保持红，B 的点为绿。
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .healthy, .healthy])

        // 2. timeFraction 跟随新胜出套餐：A 耗尽，B 仅周窗口 4%，只剩 20% 时间。
        //    中心保留原始 4%，时间为 0.2；4% / 20% = 20% → critical。
        setQuotas(
            a: makeModel(modelName: "glm_coding_plan", intervalPercent: 0, weeklyPercent: 0),
            b: makeModel(modelName: "chatgpt_plan", intervalPercent: nil, weeklyPercent: 4, weeklyResetFraction: 0.2)
        )
        metrics = appState.statusBarQuotaMetrics(at: now)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.04, accuracy: 0.001)
        XCTAssertEqual(
            metrics.centerTimeFraction ?? -1,
            0.2,
            accuracy: 0.001,
            "仅周套餐的中心 timeFraction 应取自周窗口"
        )
        let centerLine = IconDuoSVGBuilder.buildSVG(metrics: metrics)
            .components(separatedBy: "\n")
            .first { $0.contains("id=\"center-quota-value\"") } ?? ""
        XCTAssertTrue(centerLine.contains("data-value=\"4%\""))
        XCTAssertTrue(centerLine.contains("data-display=\"4\""))
        XCTAssertTrue(centerLine.contains("fill=\"#FF453A\""), "仅周剩余 4% 应按原始额度及周时间判红")
        XCTAssertEqual(metrics.quotaHealthLevels, [.critical, .critical, .healthy])

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
            .first { $0.contains("id=\"center-quota-value\"") } ?? ""
        XCTAssertTrue(exhaustedLine.contains("data-value=\"0%\""))
        XCTAssertTrue(exhaustedLine.contains("data-display=\"0\""))
        XCTAssertTrue(exhaustedLine.contains("fill=\"#FF453A\""))
    }

    /// 仅周窗口的中心保留原始周百分比，并透传周剩余时间；不乘周等效倍率。
    @MainActor
    func testCenterWeeklyOnlyKeepsRawPercentAndWeeklyTime() {
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
        // 仅周窗口：周剩余 4%，窗口只剩 20% 时间。
        // colorLevel(4, tf=0.2)：4 / 20 = 20%，低于 30% 红线，应为 critical。
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
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.04, accuracy: 0.001)
        XCTAssertEqual(metrics.centerTimeFraction ?? -1, 0.2, accuracy: 0.001)

        let svg = IconDuoSVGBuilder.buildSVG(metrics: metrics)
        XCTAssertTrue(svg.contains("id=\"single-quota-value\" data-value=\"4%\""))
        XCTAssertFalse(svg.contains("id=\"quota-dot-"))
        XCTAssertTrue(svg.contains("fill=\"#FF453A\""), "仅周窗口应按原始百分比及周剩余时间判红")
    }

    /// minimax 的 `video`（视频生成）是独立小配额池，不参与 iconDuo 聚合
    /// （用户裁定 2026-10）：左右弧 min/avg、中心百分比与底部三点只反映 general，
    /// 不被耗尽的 video 拖到 0 / 红。
    @MainActor
    func testMinimaxVideoDoesNotEnterQuotaLogoAggregate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var config = store.config
        config.providers["test_minimax"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(config)
        let descriptor = FetcherDescriptor(
            id: "test_minimax",
            displayName: "Minimax",
            kind: .minimaxTokenPlan,
            iconSystemName: "bubble.left",
            accentColor: .minimax,
            makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "key") }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }

        let general = ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: 100,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let video = ModelQuota(
            modelName: "video",
            intervalTotalCount: 100,
            intervalUsageCount: 100,
            intervalRemainingPercent: 0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: 100,
            weeklyRemainingPercent: 0,
            weeklyStatus: .present,
            weeklyResetsAt: Date().addingTimeInterval(7 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        state.mutateStatus(for: "test_minimax") {
            $0.state = .ok(QuotaInfo(
                models: [general, video],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            ))
        }

        let metrics = state.statusBarQuotaMetrics()
        XCTAssertTrue(metrics.interval.isAvailable)
        XCTAssertEqual(metrics.interval.minAvailable, 1.0, accuracy: 0.001, "左弧只反映 general 的 100%，不被 video 的 0% 拖到 0")
        XCTAssertEqual(metrics.interval.avgAvailable, 1.0, accuracy: 0.001)
        XCTAssertFalse(metrics.weekly.isAvailable, "general 无周窗口、video 已被排除，右弧应无读数")
        XCTAssertEqual(metrics.centerAvailable ?? -1, 1.0, accuracy: 0.001, "中心只反映 general 的实际可用 100%")
        XCTAssertEqual(metrics.quotaHealthLevels, [.healthy, .healthy, .healthy], "底部三点只按 general 判绿，不被耗尽的 video 拖红")
    }

    /// antigravity 的 Claude and GPT models 组同理不参与 iconDuo 聚合：
    /// gemini_models 独自决定左右弧、中心与底部三点读数。
    @MainActor
    func testAntigravityClaudeGroupDoesNotEnterQuotaLogoAggregate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var config = store.config
        config.providers["test_antigravity"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(config)
        let descriptor = FetcherDescriptor(
            id: "test_antigravity",
            displayName: "Antigravity",
            kind: .antigravity,
            iconSystemName: "sparkles",
            accentColor: .antigravity,
            makeFetcher: { _ in AntigravityFetcher(credentialReader: { AntigravityCredentialFixtures.valid() }) }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }

        let gemini = ModelQuota(
            modelName: AntigravityModelKind.geminiModels.rawValue,
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: 100,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        let geminiArgon = ModelQuota(
            modelName: AntigravityModelKind.geminiArgon.rawValue,
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 0,
            intervalStatus: .absent,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 100,
            weeklyUsageCount: 100,
            weeklyRemainingPercent: 0,
            weeklyStatus: .present,
            weeklyResetsAt: Date().addingTimeInterval(7 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        let claudeGroup = ModelQuota(
            modelName: AntigravityModelKind.claudeAndGptModels.rawValue,
            intervalTotalCount: 100,
            intervalUsageCount: 100,
            intervalRemainingPercent: 0,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: 100,
            weeklyRemainingPercent: 0,
            weeklyStatus: .present,
            weeklyResetsAt: Date().addingTimeInterval(7 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        state.mutateStatus(for: "test_antigravity") {
            $0.state = .ok(QuotaInfo(
                models: [gemini, geminiArgon, claudeGroup],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            ))
        }

        let metrics = state.statusBarQuotaMetrics()
        XCTAssertTrue(metrics.interval.isAvailable)
        XCTAssertEqual(metrics.interval.minAvailable, 1.0, accuracy: 0.001, "左弧只反映 gemini 组的 100%，不被 claude / argon 组的 0% 拖到 0")
        XCTAssertEqual(metrics.interval.avgAvailable, 1.0, accuracy: 0.001)
        XCTAssertFalse(metrics.weekly.isAvailable, "gemini 组无周窗口、claude / argon 组已被排除，右弧应无读数")
        XCTAssertEqual(metrics.centerAvailable ?? -1, 1.0, accuracy: 0.001, "中心只反映 gemini 组的实际可用 100%")
        XCTAssertEqual(metrics.quotaHealthLevels, [.healthy, .healthy, .healthy], "底部三点只按 gemini 组判绿，不被耗尽的 claude / argon 组拖红")
    }

    /// 回退分支：minimax 只剩 video（无 general）时回退 `activeModels`，
    /// 聚合仍反映 video 本身，而不是把有数据的 provider 聚合成「无读数」。
    @MainActor
    func testQuotaAggregateFallsBackToVideoWhenGeneralMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configURL: dir.appendingPathComponent("config.json"))
        var config = store.config
        config.providers["test_minimax"] = ProviderConfig(enabled: true, apiKey: "key")
        try? store.applyAndSave(config)
        let descriptor = FetcherDescriptor(
            id: "test_minimax",
            displayName: "Minimax",
            kind: .minimaxTokenPlan,
            iconSystemName: "bubble.left",
            accentColor: .minimax,
            makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "key") }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }

        let video = ModelQuota(
            modelName: "video",
            intervalTotalCount: 100,
            intervalUsageCount: 60,
            intervalRemainingPercent: 40,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        state.mutateStatus(for: "test_minimax") {
            $0.state = .ok(QuotaInfo(
                models: [video],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            ))
        }

        let metrics = state.statusBarQuotaMetrics()
        XCTAssertTrue(metrics.interval.isAvailable, "只有 video 时回退全集，左弧不应退化成无读数")
        XCTAssertEqual(metrics.interval.minAvailable, 0.4, accuracy: 0.001)
        XCTAssertEqual(metrics.interval.avgAvailable, 0.4, accuracy: 0.001)
        XCTAssertFalse(metrics.weekly.isAvailable)
        XCTAssertEqual(metrics.centerAvailable ?? -1, 0.4, accuracy: 0.001, "中心仍按 video 的实际可用 40% 参与聚合")
        XCTAssertEqual(metrics.quotaHealthLevels, [.healthy, .healthy, .healthy], "40% 相对 20% 剩余时间充足，video 的点为绿")
    }
}
