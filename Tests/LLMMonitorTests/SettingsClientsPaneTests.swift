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
        var config = store.config
        for kind in [ProviderKind.glmCodingPlan, .deepseek, .minimaxTokenPlan] {
            config.providers[kind.providerID] = ProviderConfig(enabled: true)
        }
        try! store.applyAndSave(config)
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

    /// GLM 五类拆行 + DeepSeek / MiniMax 分片行的行名与行序。
    ///
    /// 行序不是字母序：分类行按 `GlmUsageCategory.allCases` 声明序，两个分片行
    /// （provider 而非套餐）固定排在分类行之后。行名同时钉住「日常任务 → Coding Plan」
    /// 的改名与「加速卡」的插入位（Start Plan 之后、闲时之前）。
    @MainActor
    func testZcodeRowsSplitIntoPlanLinesThenProviderSlices() {
        // 聚合逻辑已提取为 ClientUsageAggregation 纯函数：不再经 SettingsView，
        // 直接以 state.statuses 为输入断言同一口径。
        let (_, state) = makeSettings()
        defer { state.stop() }
        let usage = sliceFixture()
        state.applyGlmLocalUsage(usage)
        XCTAssertTrue(
            state.statuses.filter { [.deepseek, .minimaxTokenPlan].contains($0.kind) }.allSatisfy {
                $0.usageProjection(for: $0.lastSuccess).clientIDs.contains(ClientID.zcode)
            },
            "受支持的 ZCode 分片来源应自动参与对应 Provider 归因"
        )

        let rows = ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.zcode] ?? []
        XCTAssertEqual(
            rows.map(\.providerName),
            ["Coding Plan", "Start Plan", "加速卡", "闲时任务", "其他任务", "DeepSeek", "minimax Token Plan"]
        )
        // 分类行的 token 各自独立：Start Plan 的 900 不能混进 Coding Plan
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.providerName, $0) })
        XCTAssertEqual(byName["Coding Plan"]?.totalTokens, 1_000)
        XCTAssertEqual(byName["Start Plan"]?.totalTokens, 900)
        XCTAssertEqual(byName["加速卡"]?.totalTokens, 750)
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
        let (_, state) = makeSettings()
        defer { state.stop() }
        // 只有 Coding Plan + DeepSeek 分片有智谱 / 非智谱数据
        state.applyGlmLocalUsage(
            GlmLocalUsage(
                today: nil, dailyTokenUsage: [], scannedAt: nil,
                sessionCount: 1, eventCount: 1, failedSessionCount: 0,
                recentSamples: [fixtureSample(provider: "account:bigmodel-individual-coding-plan", input: 1_000)],
                providerSlices: [
                    ZcodeProviderSlice.deepseek.rawValue: OpencodeProviderUsage(
                        today: nil, dailyTokenUsage: [], roundCount: 1,
                        recentSamples: [fixtureSample(provider: "deepseek", input: 300, promptID: "ds:t1")]
                    )
                ]
            )
        )

        let rows = ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.zcode] ?? []
        XCTAssertEqual(
            rows.map(\.providerName), ["Coding Plan", "DeepSeek"],
            "空分类不该出现占位行；分片行与 GLM 分类互不依赖"
        )
    }

    @MainActor
    func testZcodeRowsHideZeroDisplayedUsageDespiteRetainedHistoricalSamples() throws {
        let (_, state) = makeSettings()
        defer { state.stop() }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let days = (0..<7).map { offset in
            LocalDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!
            )
        }
        let oldSample = LocalTokenUsageSample(
            completedAt: try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today)),
            modelName: "MiniMax-M3", promptID: "old-minimax",
            inputTokens: 200, cachedInputTokens: 0, outputTokens: 0,
            reasoningOutputTokens: 0, sourceProviderID: "minimax"
        )
        state.applyGlmLocalUsage(GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: Date(),
            sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: [fixtureSample(provider: "builtin:bigmodel-coding-plan", input: 100)],
            providerSlices: [
                ZcodeProviderSlice.minimax.rawValue: OpencodeProviderUsage(
                    today: nil, dailyTokenUsage: days, roundCount: 1,
                    recentSamples: [oldSample]
                ),
                ZcodeProviderSlice.deepseek.rawValue: OpencodeProviderUsage(
                    today: nil,
                    dailyTokenUsage: [LocalDailyTokenUsage(dayStart: yesterday, inputTokens: 300, totalTokens: 300)],
                    roundCount: 1, recentSamples: []
                )
            ]
        ))
        let minimax = try XCTUnwrap(state.statuses.first { $0.kind == .minimaxTokenPlan })
        XCTAssertTrue(minimax.diagnosticUsageProjection(for: minimax.lastSuccess).contributions.contains {
            $0.clientID == ClientID.zcode && $0.hasActivity
        }, "历史样本仍可保留在投影中，但不应创建全零的设置行")
        let rows = ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.zcode] ?? []
        XCTAssertEqual(rows.map(\.providerName), ["Coding Plan", "DeepSeek"])
        XCTAssertEqual(rows.last?.totalTokens, 300, "今天为零、七天内有历史用量的行应保留")
    }

    /// 支持的 ZCode 分片来源自动计入 Provider 卡片，并保留在客户端诊断页。
    @MainActor
    func testDeepseekSliceAutomaticallyContributesAndAppearsInClientDiagnostics() {
        let (_, state) = makeSettings()
        defer { state.stop() }
        state.applyGlmLocalUsage(sliceFixture())

        let deepseekStatus = try! XCTUnwrap(state.statuses.first { $0.kind == .deepseek })
        let projection = deepseekStatus.usageProjection(for: deepseekStatus.lastSuccess)
        XCTAssertTrue(
            projection.contributions.contains {
                $0.clientID == ClientID.zcode
            },
            "支持的 ZCode → DeepSeek 来源应自动进入 Provider 用量投影"
        )

        let rows = ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.zcode] ?? []
        XCTAssertTrue(
            rows.contains { $0.providerName == "DeepSeek" },
            "自动归因的用量也应出现在客户端诊断页"
        )
        XCTAssertEqual(
            rows.map(\.providerName),
            ["Coding Plan", "Start Plan", "加速卡", "闲时任务", "其他任务", "DeepSeek", "minimax Token Plan"]
        )
    }

    /// 禁用的 Provider 不应出现在客户端诊断页（guard status.isEnabled 门控）。
    @MainActor
    func testDisabledProviderIsFilteredOutFromClientUsage() {
        let (_, state) = makeSettings()
        defer { state.stop() }
        state.applyGlmLocalUsage(sliceFixture())
        state.mutateStatus(for: ProviderKind.deepseek.providerID) {
            $0.isEnabled = false
        }

        let rows = ClientUsageAggregation.clientProviderUsageByClient(for: state.statuses)[ClientID.zcode] ?? []
        XCTAssertFalse(
            rows.contains { $0.providerName == "DeepSeek" },
            "已禁用的 Provider 不应出现在客户端诊断页"
        )
    }

    // MARK: - Provider pane 的「立即刷新」按钮（设置页单刷入口）

    /// 全量五种 provider 的 SettingsView：路由断言要覆盖每个 pane 的按钮。
    /// descriptor id 直接用 `ProviderKind.providerID`，与产品注册点
    /// （`LLMMonitorApp.makeDescriptors`）同一口径。
    @MainActor
    private func makeSettingsWithAllProviders() -> (view: SettingsView, state: AppState) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-settings-refresh-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let fixtures: [(kind: ProviderKind, accent: AccentColor)] = [
            (.minimaxTokenPlan, .minimax),
            (.codexChatGpt, .chatgpt),
            (.antigravity, .antigravity),
            (.glmCodingPlan, .glm),
            (.deepseek, .deepseek)
        ]
        let descriptors = fixtures.map { fixture in
            FetcherDescriptor(
                id: fixture.kind.providerID,
                displayName: fixture.kind.providerID,
                kind: fixture.kind,
                iconSystemName: "circle",
                accentColor: fixture.accent,
                makeFetcher: { _ in
                    TestQuotaFetcher(
                        providerID: fixture.kind.providerID,
                        displayName: fixture.kind.providerID,
                        kind: fixture.kind
                    )
                }
            )
        }
        let state = AppState(descriptors: descriptors, configStore: store)
        return (SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: descriptors
        ), state)
    }

    /// 每个 pane 的按钮都要路由到**自己**的 provider id。菜单侧的同款断言
    /// （`testRefreshMenuItemRoutesItsOwnProviderID`）防的是"串卡"，这里防的是
    /// "串 pane"：五个按钮共用同一个构造器 `providerRefreshButton(for:)`，
    /// kind → id 挂错注册表就会刷了别人的卡。
    @MainActor
    func testProviderRefreshActionRoutesEachPaneToItsOwnProviderID() {
        let (view, state) = makeSettingsWithAllProviders()
        defer { state.stop() }
        for kind in ProviderKind.allCases {
            XCTAssertEqual(
                view.providerRefreshAction(for: kind)?.providerID,
                kind.providerID,
                "\(kind.rawValue) pane 的立即刷新必须路由到自己的 providerID"
            )
        }
    }

    /// 未注册的 kind 拿不到动作（按钮不出现），而不是拿一个空 id 去刷空气。
    @MainActor
    func testProviderRefreshActionIsNilForUnregisteredKind() {
        let (view, state) = makeSettings()  // 只有 glm / deepseek / minimax 三个 descriptor
        defer { state.stop() }
        XCTAssertNil(view.providerRefreshAction(for: .codexChatGpt))
        XCTAssertNil(view.providerRefreshAction(for: .antigravity))
        XCTAssertNotNil(view.providerRefreshAction(for: .glmCodingPlan))
    }

    /// 在飞禁用：空闲态（真的 AppState，isRefreshJobActive == false）可点；
    /// 在飞态按全局粒度禁用——任意刷新事务（refreshAll / 别的 provider 单刷 /
    /// Antigravity 硬重建）都让按钮置灰，不区分是哪一个 provider 在刷
    /// （见 `SettingsProviderRefreshAction.isDisabled` 注释）。
    @MainActor
    func testProviderRefreshActionDisablesWhileAnyRefreshJobIsActive() {
        let (view, state) = makeSettingsWithAllProviders()
        defer { state.stop() }
        XCTAssertEqual(
            view.providerRefreshAction(for: .glmCodingPlan)?.isDisabled,
            false,
            "空闲时按钮不应禁用"
        )
        // state.isRefreshJobActive 是 private(set)，测试无法直写；在飞语义由
        // 值类型直接钉住（视图侧经 providerRefreshAction 读到的就是它）。
        let busy = SettingsProviderRefreshAction(providerID: "glm", isRefreshJobActive: true)
        XCTAssertTrue(busy.isDisabled, "全局刷新事务在飞时按钮必须禁用")
    }

    /// perform 把 pane 所属的 providerID 原样交回宿主（宿主接
    /// `AppState.refreshOne`，与菜单兜底行右键同链路）。
    @MainActor
    func testProviderRefreshActionPerformsItsOwnProviderID() {
        let (view, state) = makeSettingsWithAllProviders()
        defer { state.stop() }
        for kind in ProviderKind.allCases {
            guard let action = view.providerRefreshAction(for: kind) else {
                XCTFail("\(kind.rawValue) 必须能构造出刷新动作")
                continue
            }
            var requested: [String] = []
            action.perform { requested.append($0) }
            XCTAssertEqual(requested, [kind.providerID], "\(kind.rawValue) 不能把刷新交给别的 provider")
        }
    }

    /// 悬停文案钉死为入口语义的唯一说明（改动需同步按钮上的 `.help`）。
    @MainActor
    func testProviderRefreshActionHelpTextMatchesSpec() {
        let action = SettingsProviderRefreshAction(providerID: "glm", isRefreshJobActive: false)
        XCTAssertEqual(action.helpText, "立即刷新该 Provider")
    }

    /// 按钮闲置 / 在飞两种形态都渲染得出来（图标 ⇄ ProgressView 的切换不崩、
    /// 不渲染成空视图）。
    @MainActor
    func testProviderRefreshButtonRendersInBothStates() {
        for isActive in [false, true] {
            let button = SettingsProviderRefreshButton(
                action: SettingsProviderRefreshAction(providerID: "glm", isRefreshJobActive: isActive),
                onRefresh: { _ in }
            )
            let hosting = NSHostingView(rootView: button)
            hosting.frame = CGRect(x: 0, y: 0, width: 60, height: 24)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(
                hosting.fittingSize.height, 0,
                "isRefreshJobActive=\(isActive) 必须真的渲染出按钮"
            )
        }
    }

    // MARK: - fixtures

    /// 一份覆盖全部分类与分片的 ZCode 快照（各家真实 provider 形态）。
    private func sliceFixture() -> GlmLocalUsage {
        let slices = [
            ZcodeProviderSlice.deepseek.rawValue: OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 1,
                recentSamples: [fixtureSample(provider: "deepseek", input: 300, promptID: "ds:t1")]
            ),
            ZcodeProviderSlice.minimax.rawValue: OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 1,
                recentSamples: [fixtureSample(provider: "minimax", input: 200, promptID: "mm:t1")]
            )
        ]
        return GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: nil,
            sessionCount: 5, eventCount: 7, failedSessionCount: 0,
            recentSamples: [
                fixtureSample(provider: "account:bigmodel-individual-coding-plan", input: 1_000, promptID: "cp:t1"),
                fixtureSample(provider: "account:bigmodel-start-plan", input: 900, promptID: "sp:t1"),
                fixtureSample(provider: "account:bigmodel-highspeed-card", input: 750, promptID: "hs:t1"),
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

    // MARK: - 客户端用量聚合（合并自 UIUsageRegressionTests）

    func testSettingsGroupingUsesOnlySevenDisplayedDays() throws {
        // 聚合逻辑已提取为 ClientUsageAggregation 纯函数：直接以构造的
        // ProviderStatus / 样本为输入断言同一口径，不再经 SettingsView。
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let template = (0..<7).map { offset in
            UnifiedDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                input: 0
            )
        }
        let inWindow = (0..<7).map { offset in
            LocalTokenUsageSample(
                completedAt: calendar.date(byAdding: .day, value: -offset, to: today)!
                    .addingTimeInterval(3600),
                modelName: "gemini-2.5-pro",
                promptID: "in-\(offset)",
                inputTokens: 100,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        }
        let outsideWindow = LocalTokenUsageSample(
            completedAt: calendar.date(byAdding: .day, value: -7, to: today)!
                .addingTimeInterval(3600),
            modelName: "claude-sonnet",
            promptID: "outside",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )
        let samples = inWindow + [outsideWindow]

        let daily = ClientUsageAggregation.dailyUsage(for: samples, matching: template)
        XCTAssertEqual(daily.count, 7)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.totalTokens }, 700)

        let contribution = ClientUsageContribution(
            clientID: ClientID.antigravity,
            displayName: "Antigravity",
            dailyTokenUsage: template,
            recentSamples: samples
        )
        let status = ProviderStatus(
            id: "antigravity",
            displayName: "Antigravity",
            kind: .antigravity,
            iconSystemName: "circle",
            accentColor: .antigravity,
            refreshIntervalSeconds: 300,
            state: .ready
        )
        let rows = ClientUsageAggregation.antigravityUsageRows(status: status, contribution: contribution)
        XCTAssertEqual(rows.map(\.usageGroupID), [AntigravityUsageGroup.gemini.rawValue])
        XCTAssertEqual(rows.first?.totalTokens, 700)

        let oldOnly = ClientUsageContribution(
            clientID: ClientID.antigravity, displayName: "Antigravity",
            dailyTokenUsage: template, recentSamples: [outsideWindow]
        )
        XCTAssertTrue(ClientUsageAggregation.antigravityUsageRows(status: status, contribution: oldOnly).isEmpty)

        var glmSamples = inWindow
        for index in glmSamples.indices {
            glmSamples[index].sourceProviderID = "builtin:bigmodel-coding-plan"
        }
        var oldOffPeak = outsideWindow
        oldOffPeak.sourceProviderID = "offpeak-idle-plan"
        let glmContribution = ClientUsageContribution(
            clientID: ClientID.zcode, displayName: "ZCode",
            dailyTokenUsage: template, recentSamples: glmSamples + [oldOffPeak]
        )
        let glmStatus = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        let glmRows = ClientUsageAggregation.glmUsageRows(status: glmStatus, contribution: glmContribution)
        XCTAssertEqual(glmRows.count, 1, "窗口外闲时样本不能创建额外分组")
        XCTAssertEqual(glmRows.first?.totalTokens, 700)
        XCTAssertEqual(glmRows.first?.recentSamples.count, 7)
    }

    func testAntigravityQuotaPoolRowsConserveDailyBucketsAndKeepUnknownSamples() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func sample(_ model: String, _ id: String, input: Int, cache: Int, output: Int, reasoning: Int) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: today.addingTimeInterval(3_600),
                modelName: model,
                promptID: id,
                inputTokens: input,
                cachedInputTokens: cache,
                outputTokens: output,
                reasoningOutputTokens: reasoning
            )
        }
        let samples = [
            sample("gemini-3.8-flash", "g", input: 10, cache: 2, output: 3, reasoning: 1),
            sample("gemini-4-argon-trial", "a", input: 20, cache: 4, output: 5, reasoning: 2),
            sample("claude-opus", "c", input: 30, cache: 6, output: 7, reasoning: 3),
            sample("future-unknown-model", "u", input: 40, cache: 8, output: 9, reasoning: 4)
        ]
        let authoritative = [UnifiedDailyTokenUsage(
            dayStart: today,
            input: 120,
            cacheRead: 30,
            output: 40,
            reasoning: 20,
            turns: 9,
            rounds: 11
        )]
        let contribution = ClientUsageContribution(
            clientID: ClientID.agy,
            displayName: "agy",
            dailyTokenUsage: authoritative,
            recentSamples: samples
        )
        let status = ProviderStatus(
            id: "antigravity", displayName: "Antigravity", kind: .antigravity,
            iconSystemName: "circle", accentColor: .antigravity,
            refreshIntervalSeconds: 300, state: .ready
        )

        let rows = ClientUsageAggregation.antigravityUsageRows(status: status, contribution: contribution)
        XCTAssertEqual(rows.map(\.providerName), [
            "Gemini Models", "Gemini 4 Argon", "Claude and GPT models", "未归属额度池"
        ])
        XCTAssertEqual(rows.map(\.clientID), Array(repeating: ClientID.agy, count: 4))
        XCTAssertEqual(rows.last?.recentSamples.map(\.promptID), ["u"])
        XCTAssertEqual(rows.map(\.recentSamples.count), [1, 1, 1, 1])

        let daily = rows.compactMap { $0.dailyTokenUsage.first }
        XCTAssertEqual(daily.reduce(0) { $0 + $1.input }, authoritative[0].input)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.cacheRead }, authoritative[0].cacheRead)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.output }, authoritative[0].output)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.reasoning }, authoritative[0].reasoning)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.turns }, authoritative[0].turns)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.rounds }, authoritative[0].rounds)

        // Unknown samples contribute their own measured usage; the remaining daily
        // difference is added to the same unattributed pool instead of overwriting it.
        XCTAssertEqual(rows.last?.dailyTokenUsage.first?.input, 72)
        XCTAssertEqual(rows.last?.dailyTokenUsage.first?.cacheRead, 18)
        XCTAssertEqual(rows.last?.dailyTokenUsage.first?.output, 25)
        XCTAssertEqual(rows.last?.dailyTokenUsage.first?.reasoning, 14)
    }

    func testAntigravitySourcesKeepTheirClientIdentityAndEmptySamplesKeepDailyTotals() {
        let today = Calendar.current.startOfDay(for: Date())
        let localDay = LocalDailyTokenUsage(
            dayStart: today,
            inputTokens: 50,
            outputTokens: 12,
            cacheReadTokens: 8,
            reasoningTokens: 4,
            totalTokens: 74,
            turns: 2,
            rounds: 3
        )
        var status = ProviderStatus(
            id: "antigravity", displayName: "Antigravity", kind: .antigravity,
            iconSystemName: "circle", accentColor: .antigravity,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.antigravityLocalUsage = AntigravityLocalUsage(
            today: localDay, dailyTokenUsage: [localDay], scannedAt: Date(),
            sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: [fixtureSample(provider: "native", input: 50)]
        )
        status.agyUsage = AgyLocalUsage(
            dailyTokenUsage: [localDay], models: ["gemini-3.8-flash"],
            recentSamples: [fixtureSample(provider: "agy", input: 50)],
            sessionsRoot: nil, sessionCount: 1, eventCount: 1, scannedAt: Date()
        )
        let opencodeSlice = OpencodeProviderUsage(
            today: localDay, dailyTokenUsage: [localDay], roundCount: 3,
            recentSamples: [fixtureSample(provider: "opencode", input: 50)]
        )
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.antigravitySourceProviderID: opencodeSlice],
            modelsByProvider: [:], dbPath: nil, scannedAt: Date()
        )

        let rowsByClient = ClientUsageAggregation.clientProviderUsageByClient(for: [status])
        for clientID in [ClientID.antigravity, ClientID.agy, ClientID.openCode] {
            let rows = try! XCTUnwrap(rowsByClient[clientID])
            XCTAssertEqual(rows.map(\.clientID), [clientID])
            XCTAssertEqual(rows.first?.totalTokens, 74)
        }

        let noSamples = ClientUsageContribution(
            clientID: ClientID.agy,
            displayName: "agy",
            dailyTokenUsage: [UnifiedDailyTokenUsage(localDay)],
            isTruncated: true,
            samplesTruncated: true
        )
        let dailyOnlyRows = ClientUsageAggregation.antigravityUsageRows(status: status, contribution: noSamples)
        XCTAssertEqual(dailyOnlyRows.map(\.usageGroupID), [AntigravityUsageGroup.unattributed.rawValue])
        XCTAssertEqual(dailyOnlyRows.first?.totalTokens, 74)
        XCTAssertTrue(dailyOnlyRows.first?.recentSamples.isEmpty == true)
        XCTAssertTrue(dailyOnlyRows.first?.isTruncated == true)
        XCTAssertTrue(dailyOnlyRows.first?.samplesTruncated == true)
    }

    // MARK: - 侧栏分节（通用 / 额度 / 用量）

    @MainActor
    func testSidebarTabsGroupedIntoGeneralQuotaAndUsageSections() {
        let (view, state) = makeSettings()
        defer { state.stop() }

        XCTAssertEqual(
            view.generalTabs.map(\.id),
            [SettingsTab.generalID, SettingsTab.interfaceID, SettingsTab.notificationsID, SettingsTab.energyID, SettingsTab.syncID]
        )
        XCTAssertEqual(view.providerTabs.count, 3)
        XCTAssertEqual(view.clientTabs.count, ClientDescriptor.all.count)
        XCTAssertEqual(view.allTabs.count, view.generalTabs.count + view.providerTabs.count + view.clientTabs.count)

        // 校验 ID 无重复（包括同名 provider 与 client，如 antigravity）
        let allIDs = view.allTabs.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "设置侧栏所有 tab 的 ID 必须唯一无冲突")
    }

    @MainActor
    func testClientTabPropertiesAndBrandAssets() {
        let openCode = ClientDescriptor.all.first { $0.id == ClientID.openCode }!
        let openCodeTab = SettingsTab.client(openCode)
        XCTAssertEqual(openCodeTab.id, "client.opencode")
        XCTAssertEqual(openCodeTab.displayTitle, "OpenCode")
        XCTAssertEqual(openCodeTab.brandAsset, .opencode)

        let antigravityClient = ClientDescriptor.all.first { $0.id == ClientID.antigravity }!
        let antigravityClientTab = SettingsTab.client(antigravityClient)
        XCTAssertEqual(antigravityClientTab.id, "client.antigravity")
        XCTAssertEqual(antigravityClientTab.iconSystemName, "paperplane.circle.fill")
        XCTAssertNil(antigravityClientTab.brandAsset)
    }
}
