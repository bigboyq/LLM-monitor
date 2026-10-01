import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 设置页「客户端」tab 的 Provider 行默认展开态。
final class SettingsClientsPaneTests: XCTestCase {

    /// 造一个真的 SettingsView 来驱动它的方法（`clientProviderDisclosure` /
    /// `defaultProviderExpansion` 都是 SettingsView 的内部方法，具名的行视图是
    /// 私有的——测公开入口比为了测试放宽可见性更合适）。
    ///
    /// descriptors 覆盖 ZCode 用量的三个消费方（GLM / DeepSeek / MiniMax）：
    /// `AppState.statuses` 由 descriptors 派生，不给就永远是空列，测不到拆行。
    /// displayName 与产品注册点保持一致（`LLMMonitorApp.makeDescriptors`），
    /// 因为分片行的行名直接取 status 的 displayName。
    @MainActor
    private func makeSettings() -> (view: SettingsView, state: AppState) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-clients-pane-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let descriptors = zcodeConsumerDescriptors()
        let state = AppState(descriptors: descriptors, configStore: store)
        return (SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: descriptors
        ), state)
    }

    @MainActor
    private func zcodeConsumerDescriptors() -> [FetcherDescriptor] {
        [
            ("glm_coding_plan", "GLM Coding Plan", .glmCodingPlan, .glm),
            ("deepseek", "DeepSeek", .deepseek, .deepseek),
            ("minimax_token_plan", "minimax Token Plan", .minimaxTokenPlan, .minimax)
        ].map { id, displayName, kind, accent in
            FetcherDescriptor(
                id: id,
                displayName: displayName,
                kind: kind,
                iconSystemName: "circle",
                accentColor: accent,
                makeFetcher: { _ in TestQuotaFetcher(providerID: id, displayName: displayName, kind: kind) }
            )
        }
    }

    // MARK: - 默认展开规则

    @MainActor
    func testASingleProviderRowStartsExpandedAndSeveralStartCollapsed() {
        // 抽成 `defaultProviderExpansion` 就是为了让这条规则有名字、有一条测试，
        // 而不是散在 ForEach 里的一句 `count == 1`。
        let (view, state) = makeSettings()
        defer { state.stop() }
        XCTAssertFalse(view.defaultProviderExpansion(forProviderCount: 0), "空列走的是空态，不该展开")
        XCTAssertTrue(view.defaultProviderExpansion(forProviderCount: 1), "只有一行时直接展开")
        for count in [2, 3, 7] {
            XCTAssertFalse(view.defaultProviderExpansion(forProviderCount: count),
                           "\(count) 行时全折叠，否则设置页要被撑到滚动")
        }
    }

    // MARK: - 默认态真的作用到 DisclosureGroup

    @MainActor
    func testDefaultExpandedReachesTheDisclosureGroup() {
        // 规则说"该展开"还不够：`@State(initialValue:)` 只在首次出现时生效，
        // 所以要量实际高度确认展开内容真的渲染出来了（折叠态只有一行标题，
        // 展开态还多出 7 天柱图 + 7 列指标）。
        let (view, state) = makeSettings()
        defer { state.stop() }
        let provider = makeSummary()
        let expanded = height(of: view.clientProviderDisclosure(provider, defaultExpanded: true))
        let collapsed = height(of: view.clientProviderDisclosure(provider, defaultExpanded: false))
        XCTAssertGreaterThan(
            expanded, collapsed + 80,
            "默认展开的 \(expanded)pt 应当明显高于默认折叠的 \(collapsed)pt"
        )
    }

    @MainActor
    func testRebuiltRowPicksUpItsNewDefault() {
        // 外层 `.id(client.id)` 是让"切到某个客户端时重新按规则来"成立的关键：
        // 少了它，SwiftUI 按位置复用上一列的展开态，这条规则会被顶掉。这里验证
        // 同一行被重建（换了默认值）时新值确实生效。
        let (view, state) = makeSettings()
        defer { state.stop() }
        let provider = makeSummary()
        let collapsed = height(of: view.clientProviderDisclosure(provider, defaultExpanded: false))
        let rebuilt = height(of: view.clientProviderDisclosure(provider, defaultExpanded: true))
        XCTAssertGreaterThan(
            rebuilt, collapsed + 80,
            "重建后 \(rebuilt)pt 应当按新默认值展开（上一轮是 \(collapsed)pt）"
        )
    }

    // MARK: - ZCode 客户端区的行（分类行 + 分片行）

    /// GLM 四类拆行 + DeepSeek / MiniMax 分片行的行名与行序。
    ///
    /// 行序不是字母序：分类行按 `GlmUsageCategory.allCases` 声明序，两个分片行
    /// （provider 而非套餐）固定排在分类行之后。行名同时钉住「日常任务 → Coding Plan」
    /// 的改名。
    @MainActor
    func testZcodeRowsSplitIntoPlanLinesThenProviderSlices() {
        let (view, state) = makeSettings()
        defer { state.stop() }
        let usage = sliceFixture()
        state.applyGlmLocalUsage(usage)
        XCTAssertTrue(
            state.statuses.filter { $0.kind != .glmCodingPlan }.allSatisfy(\.mergeZcodeUsage),
            "默认绑定（zcode → minimax / deepseek）应已开启，否则下面验不到分片行"
        )

        let rows = view.clientProviderUsageByClient()[ClientID.zcode] ?? []
        XCTAssertEqual(
            rows.map(\.providerName),
            ["Coding Plan", "Start Plan", "闲时任务", "其他任务", "DeepSeek", "minimax Token Plan"]
        )
        // 分类行的 token 各自独立：Start Plan 的 900 不能混进 Coding Plan
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.providerName, $0) })
        XCTAssertEqual(byName["Coding Plan"]?.totalTokens, 1_000)
        XCTAssertEqual(byName["Start Plan"]?.totalTokens, 900)
        XCTAssertEqual(byName["闲时任务"]?.totalTokens, 800)
        XCTAssertEqual(byName["其他任务"]?.totalTokens, 700)
        XCTAssertEqual(byName["DeepSeek"]?.totalTokens, 300)
        XCTAssertEqual(byName["minimax Token Plan"]?.totalTokens, 200)
        // 分片行的 provider 身份保留（供计价与诊断使用）
        XCTAssertEqual(
            Set(rows.map(\.quotaProviderID)),
            [
                QuotaProviderID.zhipu, QuotaProviderID.deepseek, QuotaProviderID.minimax
            ]
        )
    }

    /// 拆行只是"同一列多行"：没有 Start Plan / 闲时 / 其他用量时这些行不出现，
    /// 分片行有数据就出现（不依赖 GLM 分类行是否存在）。
    @MainActor
    func testZcodeRowsOmitEmptyCategoriesAndKeepSliceRowsIndependent() {
        let (view, state) = makeSettings()
        defer { state.stop() }
        // 只有 Coding Plan + DeepSeek 分片有智谱 / 非智谱数据
        state.applyGlmLocalUsage(
            GlmLocalUsage(
                today: nil, dailyTokenUsage: [], scannedAt: nil,
                sessionCount: 1, eventCount: 1, failedSessionCount: 0,
                recentSamples: [fixtureSample(provider: "account:bigmodel-individual-coding-plan", input: 1_000)],
                providerSlices: [
                    ZcodeProviderSlice.deepseek.rawValue: OpencodeProviderUsage(
                        today: nil, dailyTokenUsage: [], roundCount: 1, cost: 0,
                        recentSamples: [fixtureSample(provider: "deepseek", input: 300, promptID: "ds:t1")]
                    )
                ]
            )
        )

        let rows = view.clientProviderUsageByClient()[ClientID.zcode] ?? []
        XCTAssertEqual(
            rows.map(\.providerName), ["Coding Plan", "DeepSeek"],
            "空分类不该出现占位行；分片行与 GLM 分类互不依赖"
        )
    }

    /// 关闭 zcode → deepseek 绑定后 DeepSeek 行消失（GLM 分类行不受影响）。
    /// 这一格是"行展示正确"与"门控"的分界：门控在 `clientBindings`，展示层不绕过它。
    @MainActor
    func testDeepseekRowDisappearsWhenItsZcodeBindingIsOff() {
        let (view, state) = makeSettings()
        defer { state.stop() }
        state.applyGlmLocalUsage(sliceFixture())
        state.mutateStatus(for: ProviderKind.deepseek.providerID) { $0.mergeZcodeUsage = false }

        let rows = view.clientProviderUsageByClient()[ClientID.zcode] ?? []
        XCTAssertFalse(
            rows.contains { $0.providerName == "DeepSeek" },
            "绑定关闭时不该出现 DeepSeek 行"
        )
        XCTAssertEqual(
            rows.map(\.providerName),
            ["Coding Plan", "Start Plan", "闲时任务", "其他任务", "minimax Token Plan"]
        )
    }

    // MARK: - fixtures

    /// 一份覆盖全部分类与分片的 ZCode 快照（各家真实 provider 形态）。
    private func sliceFixture() -> GlmLocalUsage {
        let slices = [
            ZcodeProviderSlice.deepseek.rawValue: OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 1, cost: 0,
                recentSamples: [fixtureSample(provider: "deepseek", input: 300, promptID: "ds:t1")]
            ),
            ZcodeProviderSlice.minimax.rawValue: OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 1, cost: 0,
                recentSamples: [fixtureSample(provider: "minimax", input: 200, promptID: "mm:t1")]
            )
        ]
        return GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: nil,
            sessionCount: 4, eventCount: 6, failedSessionCount: 0,
            recentSamples: [
                fixtureSample(provider: "account:bigmodel-individual-coding-plan", input: 1_000, promptID: "cp:t1"),
                fixtureSample(provider: "account:bigmodel-start-plan", input: 900, promptID: "sp:t1"),
                fixtureSample(provider: "account:bigmodel-offpeak-idle-plan", input: 800, promptID: "op:t1"),
                fixtureSample(provider: "account:bigmodel-future-plan", input: 700, promptID: "ot:t1")
            ],
            providerSlices: slices
        )
    }

    private func fixtureSample(
        provider: String,
        input: Int,
        promptID: String = "s:t1"
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: Date(),
            modelName: provider == "deepseek" ? "deepseek-flash" : "GLM-5.3-Flash",
            promptID: promptID,
            inputTokens: input, cachedInputTokens: 0, outputTokens: 0,
            reasoningOutputTokens: 0, sourceProviderID: provider
        )
    }

    // MARK: - helpers

    @MainActor
    private func height(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 660))
        hosting.frame = CGRect(x: 0, y: 0, width: 660, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func makeSummary() -> ClientProviderUsageSummary {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).map { offset in
            UnifiedDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                input: 12_000 + offset * 900
            )
        }
        return ClientProviderUsageSummary(
            clientID: ClientID.antigravity,
            quotaProviderID: QuotaProviderID.antigravity,
            providerName: "Gemini Models",
            usageGroupID: "gemini",
            dailyTokenUsage: days,
            recentSamples: [],
            scannedAt: Date()
        )
    }
}
