import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 菜单内容区**底部 provider 兜底行**的数据投影（`ProviderStatusStrip`）与那一行
/// 的排版预算。
///
/// 这一行的存在理由很具体：菜单主体已改成客户端视角（今天烧了多少），额度那一面
/// 只剩边缘状态窗与设置页——没开边缘窗的用户必须还能在这一屏看到 provider 状态。
/// 于是"哪些 provider 在场 / 谁被折叠 / 折叠时先留谁"全是不出错就悄悄错的规则，
/// 只能靠断言钉住。
final class ProviderStatusStripTests: XCTestCase {

    // MARK: - 在场集合

    /// 未启用的 provider **不在场**。这一条由投影自己保证，而不是靠调用方记得先
    /// 过滤：漏一次的结果是菜单里冒出一张用户明确关掉的 provider 的卡。
    func testDisabledProvidersAreNotInTheStrip() {
        let snapshot = ProviderStatusStrip.snapshot(statuses: [
            Self.status(id: "on", displayName: "On", isEnabled: true),
            Self.status(id: "off", displayName: "Off", isEnabled: false)
        ])
        XCTAssertEqual(snapshot.entries.map(\.id), ["on"])
        XCTAssertEqual(snapshot.hiddenCount, 0)
    }

    /// 无额度数据的 provider（未配置 / 失败）**照样在场**——这正是兜底的意义。
    /// 曾经"没显示"和"没数据"分不清：卡片不在，用户以为没监控。
    func testProvidersWithoutQuotaDataStillAppear() {
        let snapshot = ProviderStatusStrip.snapshot(statuses: [
            Self.status(id: "ok", displayName: "OK"),
            Self.status(id: "unconfigured", displayName: "Unconfigured",
                        state: .notConfigured(reason: "缺少 API Key")),
            Self.status(id: "failed", displayName: "Failed",
                        state: .failed(message: "网络不可用", lastSuccess: nil))
        ])
        XCTAssertEqual(
            Set(snapshot.entries.map(\.id)), ["ok", "unconfigured", "failed"],
            "未配置与失败都必须在场——它们是这一行存在的意义"
        )
    }

    /// 在场元素的健康胶囊取值直接来自 `ProviderStateLabel`：失败是红色、未启用
    /// 之外的无数据状态是次要色。胶囊文案与颜色是这一行唯一携带的信息，取错值
    /// 不会报错、只会让用户误判。
    func testStateCapsuleToneFollowsProviderStateLabel() {
        let failed = Self.status(id: "f", displayName: "F", state: .failed(message: "x", lastSuccess: nil))
        let unconfigured = Self.status(id: "u", displayName: "U", state: .notConfigured(reason: "x"))

        let snapshot = ProviderStatusStrip.snapshot(statuses: [failed, unconfigured])
        let byID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0.status) })
        XCTAssertEqual(Set(byID.keys), ["f", "u"], "前提不成立：两个 provider 都该在场")

        let now = Date()
        XCTAssertEqual(
            ProviderStateLabel(status: byID["f"]!).presentation(at: now).tone, .red,
            "失败的 provider 必须是红胶囊"
        )
        XCTAssertEqual(
            ProviderStateLabel(status: byID["u"]!).presentation(at: now).tone, .secondary,
            "未配置没有可信额度数据，是次要色而不是绿色"
        )
    }

    // MARK: - 放不下时留谁

    /// 放不下时**留下健康最差的**，折叠掉的记进 `hiddenCount`。
    func testTruncationKeepsTheWorstHealthFirst() {
        let statuses = [
            Self.status(id: "healthy", displayName: "Healthy", health: .healthy),
            Self.status(id: "critical", displayName: "Critical", health: .critical),
            Self.status(id: "failed", displayName: "Failed",
                        state: .failed(message: "x", lastSuccess: nil)),
            Self.status(id: "warning", displayName: "Warning", health: .warning)
        ]
        let snapshot = ProviderStatusStrip.snapshot(statuses: statuses, limit: 2)
        XCTAssertEqual(
            Set(snapshot.entries.map(\.id)), ["failed", "critical"],
            "额度最差（失败 / critical）的两个必须留下"
        )
        XCTAssertEqual(snapshot.hiddenCount, 2)
    }

    /// 留下的元素之间**保持传入顺序**（用户配置顺序）：取舍换的是"留谁"，
    /// 不是"排谁"——为了塞进 4 个而把用户排好的 provider 顺序打乱，是用一个
    /// 小问题换一个大问题。
    func testKeptEntriesPreserveTheGivenOrder() {
        let statuses = [
            Self.status(id: "a", displayName: "A", health: .healthy),
            Self.status(id: "b", displayName: "B", health: .critical),
            Self.status(id: "c", displayName: "C", health: .warning),
            Self.status(id: "d", displayName: "D", state: .failed(message: "x", lastSuccess: nil))
        ]
        let snapshot = ProviderStatusStrip.snapshot(statuses: statuses, limit: 3)
        XCTAssertEqual(snapshot.entries.map(\.id), ["b", "c", "d"])
    }

    /// 优先级排序不能只看额度健康度：`.failed` / `.notConfigured` 的卡
    /// `aggregateHealthLevel()` 返回 `nil`，纯按健康度排会把最该被看见的
    /// provider 排到最后。
    func testStateOutranksQuotaHealthInThePriorityOrder() {
        let failed = Self.status(id: "failed", displayName: "Failed",
                                 state: .failed(message: "x", lastSuccess: nil))
        let critical = Self.status(id: "critical", displayName: "Critical", health: .critical)
        let unconfigured = Self.status(id: "unconfigured", displayName: "Unconfigured",
                                       state: .notConfigured(reason: "x"))
        let healthy = Self.status(id: "healthy", displayName: "Healthy", health: .healthy)

        XCTAssertGreaterThan(ProviderStatusStrip.priority(failed), ProviderStatusStrip.priority(critical))
        XCTAssertGreaterThan(ProviderStatusStrip.priority(unconfigured), ProviderStatusStrip.priority(healthy))
        XCTAssertGreaterThan(ProviderStatusStrip.priority(critical), ProviderStatusStrip.priority(healthy))
    }

    // MARK: - 单 provider 刷新（右键菜单）

    /// 菜单项标题必须带 provider 名：一行里最多四枚同款菜单项，都叫「立即刷新」
    /// 的话用户分不清点的是哪一个。
    func testRefreshMenuItemTitleNamesTheProvider() {
        let item = ProviderStatusStripView.refreshMenuItem(
            for: ProviderStatusStrip.Entry(
                status: Self.status(id: "antigravity", displayName: "Google Antigravity", kind: .antigravity)
            )
        )
        XCTAssertEqual(item.title, "刷新 Google Antigravity")
        XCTAssertEqual(item.providerID, "antigravity")
    }

    /// 点下去交出去的是**这张** provider 的 id。宿主（`MenuContentView`）拿这个
    /// id 调 `AppState.refreshOne(providerID:)`，串错 id 就是刷了别人的卡。
    func testRefreshMenuItemRoutesItsOwnProviderID() {
        let entries = ProviderStatusStrip.snapshot(statuses: Self.allProviderFixture(), limit: 4)
        var requested: [String] = []

        for entry in entries.entries {
            ProviderStatusStripView.refreshMenuItem(for: entry).perform { requested.append($0) }
        }

        XCTAssertEqual(
            Set(requested), Set(entries.entries.map(\.status.id)),
            "每个在场的 provider 都要能点到自己，且只点自己"
        )
    }

    /// 无额度数据的 provider（未配置 / 失败）**同样有单刷入口**——重试正是它们
    /// 需要的动作。若哪一步按"有数据"过滤，这一行存在的意义就少一半。
    func testProvidersWithoutQuotaDataStillGetARefreshItem() {
        let statuses = [
            Self.status(id: "failed", displayName: "Failed",
                        state: .failed(message: "网络不可用", lastSuccess: nil)),
            Self.status(id: "unconfigured", displayName: "Unconfigured",
                        state: .notConfigured(reason: "缺少 API Key"))
        ]
        let items = ProviderStatusStrip.snapshot(statuses: statuses).entries
            .map(ProviderStatusStripView.refreshMenuItem(for:))

        XCTAssertEqual(Set(items.map(\.providerID)), ["failed", "unconfigured"])
        XCTAssertEqual(
            Set(items.map(\.title)), ["刷新 Failed", "刷新 Unconfigured"],
            "两个 provider 各自有可分辨的单刷项"
        )
    }

    /// 注入回调后这一行照常渲染（contextMenu 不改布局，也不吞掉 hover 卡）。
    @MainActor
    func testStripRendersWithSingleProviderRefreshWired() {
        let snapshot = ProviderStatusStrip.snapshot(statuses: Self.allProviderFixture(), limit: 4)
        let hosting = NSHostingView(
            rootView: AnyView(ProviderStatusStripView(
                snapshot: snapshot,
                onRefreshProvider: { _ in },
                isRefreshJobActive: true
            ))
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        hosting.layoutSubtreeIfNeeded()

        let contentWidth = MenuPanelHeightBridge.width - MenuPanelHeightBridge.cardHorizontalPadding * 2
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "必须真的渲染出这一行")
        XCTAssertLessThanOrEqual(
            hosting.fittingSize.width, contentWidth + 0.5,
            "接上单刷回调后自然宽不得超出内容区"
        )
    }

    // MARK: - 排版预算

    /// 五个 provider 全启用（`ProviderKind.allCases` 的全部）时这一行不得溢出
    /// 内容区。溢出只会让最右边的胶囊被裁掉或换行，编译期与运行期都不报错。
    @MainActor
    func testStripNaturalWidthFitsTheMenuContentWidth() {
        let contentWidth = MenuPanelHeightBridge.width - MenuPanelHeightBridge.cardHorizontalPadding * 2
        let snapshot = ProviderStatusStrip.snapshot(statuses: Self.allProviderFixture(), limit: 4)
        XCTAssertEqual(snapshot.hiddenCount, 1, "前提不成立：五个 provider 必须触发折叠")

        // 宽画布量**自然宽**：给定 336pt 时任何一行都能"塞进去"（顶多被裁），
        // 那不证明放得下——只有自然宽 ≤ 内容区才是真的放得下。
        let hosting = NSHostingView(rootView: AnyView(ProviderStatusStripView(snapshot: snapshot)))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            hosting.fittingSize.width, contentWidth + 0.5,
            "兜底行自然宽 \(hosting.fittingSize.width)pt 溢出内容区 \(contentWidth)pt（四个元素 + 「+N」）"
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "必须真的渲染出行高")
    }

    /// 空快照不渲染任何东西（没有 provider 可显示时不该留一条空行 + 一条分隔线）。
    @MainActor
    func testEmptyStripRendersNothing() {
        let hosting = NSHostingView(
            rootView: AnyView(ProviderStatusStripView(
                snapshot: ProviderStatusStrip.snapshot(statuses: [])
            ))
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 336, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, 0.5, "空兜底行必须完全不占高度")
    }

    // MARK: - fixtures

    /// 五种 provider 各一个，长显示名 + 长刷新时间（胶囊最宽的形态）。
    private static func allProviderFixture() -> [ProviderStatus] {
        [
            status(id: "codex_chatgpt", displayName: "ChatGPT Plan", kind: .codexChatGpt, health: .healthy),
            status(id: "antigravity", displayName: "Google Antigravity", kind: .antigravity, health: .healthy),
            status(id: "minimax_token_plan", displayName: "MiniMax Token Plan", kind: .minimaxTokenPlan, health: .healthy),
            status(id: "glm_coding_plan", displayName: "GLM Coding Plan", kind: .glmCodingPlan, health: .healthy),
            status(id: "deepseek", displayName: "DeepSeek", kind: .deepseek, health: .healthy)
        ]
    }

    /// 一个最小可用 `ProviderStatus`。`state` 决定胶囊取值，`health` 决定额度
    /// 健康度（走一个真实窗口的 `QuotaInfo`，让 `aggregateHealthLevel()` 与生产
    /// 路径同源，而不是在测试里另写一套判定）。
    private static func status(
        id: String,
        displayName: String,
        kind: ProviderKind = .codexChatGpt,
        state overrideState: ProviderStatus.State? = nil,
        health: HealthLevel = .healthy,
        isEnabled: Bool = true
    ) -> ProviderStatus {
        let now = Date()
        // 健康度不是 `QuotaInfo` 的入参，而是由窗口剩余量推出来的：瓶颈窗口是
        // 5h 时 `aggregateActualAvailable` 给 `timeFraction = nil`，黄线固定 30%
        // （`<15` 红）。所以这里反查用量比例，而不是直接塞一个"健康度"字段——
        // 后者会让测试和生产走两套判定。
        let usedFraction: Double = switch health {
        case .healthy: 0.05
        case .warning: 0.75
        case .critical: 0.90
        }
        let remainingPercent = Double(((1 - usedFraction) * 100).rounded())
        let info = QuotaInfo(
            models: [
                ModelQuota(
                    modelName: "chatgpt_plan",
                    intervalTotalCount: 100,
                    intervalUsageCount: Int(100 - remainingPercent),
                    intervalRemainingPercent: remainingPercent,
                    intervalStatus: .present,
                    intervalResetsAt: now.addingTimeInterval(3600),
                    intervalWindowSeconds: 5 * 3600,
                    weeklyTotalCount: 100,
                    weeklyUsageCount: Int(100 - remainingPercent),
                    weeklyRemainingPercent: remainingPercent,
                    weeklyStatus: .present,
                    weeklyResetsAt: now.addingTimeInterval(6 * 24 * 3600),
                    weeklyWindowSeconds: 7 * 24 * 3600
                )
            ],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: now
        )
        return ProviderStatus(
            id: id,
            displayName: displayName,
            kind: kind,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            isEnabled: isEnabled,
            state: overrideState ?? .ok(info)
        )
    }
}
