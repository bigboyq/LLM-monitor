import XCTest
import Foundation
@testable import LLM_monitor

final class IconDuoSVGBuilderTests: XCTestCase {

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
}
