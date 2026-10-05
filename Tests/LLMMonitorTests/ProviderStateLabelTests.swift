import XCTest
import Foundation
@testable import LLM_monitor

/// `ProviderStateLabel` 的文案与新鲜度呈现规则。对应 `ProviderStateLabel`。
final class ProviderStateLabelTests: XCTestCase {

    // MARK: - Provider state label freshness

    func testProviderStateLabelFreshnessPresentationBoundaries() {
        let refreshedAt = Date(timeIntervalSince1970: 1_000_000)
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: refreshedAt
        )
        let status = ProviderStatus(
            id: "test",
            displayName: "Test",
            kind: .codexChatGpt,
            iconSystemName: "circle",
            accentColor: .custom,
            refreshIntervalSeconds: 10,
            state: .ok(info),
            lastRefreshedAt: refreshedAt
        )
        let label = ProviderStateLabel(status: status)

        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(3)).tone, .green)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(3.001)).tone, .secondary)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(8)).tone, .secondary)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(8.001)).tone, .yellow)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(10)).tone, .yellow)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(10.001)).tone, .red)
    }

    func testProviderStateLabelTimelineCoversMinimumIntervalFirstThreshold() {
        let minimumRefreshInterval: TimeInterval = 10
        XCTAssertLessThanOrEqual(
            ProviderStateLabel.timelineIntervalSeconds,
            minimumRefreshInterval * 0.3
        )
    }

    // MARK: - 文案

    /// `.ok` 胶囊的时间跨天**不**退化成 `MM-dd HH:mm`：兜底行宽度预算按 5 字符
    /// 胶囊钉死（5 元素 × 54pt），加宽会把整行撑变形——「哪一天」由胶囊的新鲜度
    /// 颜色承担，不进时间文本。
    func testOkTitleStaysBareClockAcrossMidnight() {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!

        var status = Self.okStatus()
        status.lastRefreshedAt = yesterday
        let title = ProviderStateLabel(status: status).presentation(at: now).title

        XCTAssertEqual(title, Formatters.formatTimeOfDay(yesterday))
        XCTAssertEqual(title.count, 5, "胶囊必须是 HH:mm 五字符形态，实际：\(title)")
        XCTAssertFalse(title.contains("-"), "跨天不得退化成 MM-dd HH:mm，实际：\(title)")
        // 对照：通用 formatClock 在同样的跨天场景下会带日期（两者语义从此分家）。
        XCTAssertTrue(Formatters.formatClock(yesterday, now: now).contains("-"))
    }

    /// `.notConfigured` 的胶囊文案是「未配置」而不是「未启用」。
    ///
    /// 这个状态覆盖五种原因（缺配置块 / 缺 Key / 缺外部 auth / 缺登录…），其中
    /// 只有一种是"被禁用"；写「未启用」会让"已启用但还没填 Key"读成被关掉了，
    /// 而同一张卡下面写着的原因是"API Key 未填写"——两句话自相矛盾。
    func testNotConfiguredCapsuleSaysUnconfiguredNotDisabled() {
        let status = ProviderStatus(
            id: "p",
            displayName: "P",
            kind: .minimaxTokenPlan,
            iconSystemName: "x",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "API Key 未填写")
        )
        let presentation = ProviderStateLabel(status: status).presentation(at: Date())
        XCTAssertEqual(presentation.title, "未配置")
        XCTAssertNotEqual(presentation.title, "未启用", "「未启用」会被读成 provider 被关掉了")
        XCTAssertEqual(presentation.tone, .secondary, "色调不变：这一条只改文案")

        // 与其它状态区分得开（胶囊是这一行唯一携带的信息）。
        XCTAssertNotEqual(presentation.title, ProviderStateLabel(status: Self.okStatus()).presentation(at: Date()).title)
    }

    // MARK: - helpers

    /// 供文案对比用的 `.ok` 参照状态（单模型、双窗口在场）。
    private static func okStatus() -> ProviderStatus {
        let now = Date()
        let model = ModelQuota(
            modelName: "glm_coding_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 40,
            intervalRemainingPercent: 60,
            intervalStatus: .present,
            intervalResetsAt: now.addingTimeInterval(2 * 3600),
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 700,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: 60,
            weeklyStatus: .present,
            weeklyResetsAt: now.addingTimeInterval(3 * 24 * 3600),
            weeklyWindowSeconds: 7 * 24 * 3600
        )
        let info = QuotaInfo(
            models: [model],
            resetCredits: nil,
            planLabel: "Pro",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: now
        )
        return ProviderStatus(
            id: "glm",
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "x",
            accentColor: .glm,
            refreshIntervalSeconds: 300,
            state: .ok(info),
            lastRefreshedAt: now
        )
    }
}
