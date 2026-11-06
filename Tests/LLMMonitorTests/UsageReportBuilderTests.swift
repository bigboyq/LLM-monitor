import XCTest
@testable import LLM_monitor

/// 报告构建：七日日桶、源级 freshness、权威 totals、模型明细（同样本计价）、
/// 额度通道门控与窗口行真实边界（§6.3 / §11）。
final class UsageReportBuilderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_123_000)

    private func codexStatus(
        state: ProviderStatus.State = .ready,
        scanning: Bool = false,
        enabled: Bool = true
    ) -> ProviderStatus {
        var status = ProviderStatus(
            id: ProviderKind.codexChatGpt.providerID,
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "dollarsign.circle",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: state
        )
        status.isEnabled = enabled
        status.isScanningLocalUsage = scanning
        return status
    }

    private func sample(
        at date: Date, model: String = "gpt-5.5",
        input: Int = 100, cached: Int = 60, output: Int = 50, reasoning: Int = 20,
        sourceProviderID: String? = nil
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: "s-\(date.timeIntervalSince1970)",
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: sourceProviderID
        )
    }

    private func chatGPTQuotaInfo(
        scannedAt: Date,
        recentSamples overrideSamples: [LocalTokenUsageSample]? = nil
    ) -> QuotaInfo {
        let todayStart = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayStart)!
        // 日聚合与 recentSamples 保持一致（inputTokens 是 cache-inclusive 总输入），
        // 让内核的「当日 max 修补」不改变结果，断言只落在构建逻辑上。
        let recentSamples = overrideSamples ?? [
            sample(at: now.addingTimeInterval(-60)),
            sample(at: now.addingTimeInterval(-3600)),
            sample(at: yesterday.addingTimeInterval(3600), input: 10, cached: 0, output: 5, reasoning: 0),
        ]
        return QuotaInfo(
            models: [ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100, intervalUsageCount: 40,
                intervalRemainingPercent: 60, intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3 * 60 * 60),
                intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 1000, weeklyUsageCount: 400,
                weeklyRemainingPercent: 60, weeklyStatus: .present,
                weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                weeklyWindowSeconds: 7 * 24 * 60 * 60
            )],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: "user@example.com",
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                dailyTokenUsage: [
                    DailyTokenUsage(
                        dayStart: todayStart,
                        inputTokens: 200, cachedInputTokens: 120,
                        outputTokens: 100, reasoningOutputTokens: 40,
                        rounds: 2, turns: 2
                    ),
                    DailyTokenUsage(
                        dayStart: yesterday,
                        inputTokens: 10, cachedInputTokens: 0,
                        outputTokens: 5, reasoningOutputTokens: 0,
                        rounds: 1, turns: 1
                    ),
                ],
                recentSamples: recentSamples,
                scannedAt: scannedAt
            ),
            fetchedAt: now,
            balanceDetail: nil
        )
    }

    private func makeInput(_ statuses: [ProviderStatus]) -> UsageReportInput {
        UsageReportInput(
            nodeID: UUID(),
            nodeName: "Test-Mac",
            bindings: ClientProviderBinding.defaultBindings,
            statuses: statuses,
            now: now
        )
    }

    func testDeepseekModelDetailsUseConfiguredPeakMultiplier() throws {
        var status = ProviderStatus(
            id: ProviderKind.deepseek.providerID, displayName: "DeepSeek", kind: .deepseek,
            iconSystemName: "dollarsign.circle", accentColor: .deepseek,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.isEnabled = true
        status.deepseekPeakWindow = PeakWindow(startHour: 0, endHour: 24, weekdaysOnly: false, multiplier: 3)
        let usage = sample(at: now, model: "deepseek-v3-flash", input: 1_000_000, cached: 0, output: 0, reasoning: 0, sourceProviderID: "dsh:deepseek")
        let day = DshDailyUsage(
            dayStart: Calendar.current.startOfDay(for: now), inputTokens: 1_000_000,
            outputTokens: 0, totalTokens: 1_000_000, turns: 1, rounds: 1
        )
        status.dshUsage = DshLocalUsage(
            byProvider: ["deepseek": DshProviderUsage(
                today: day, dailyTokenUsage: [day], sessionCount: 1, roundCount: 1,
                recentSamples: [usage], recentSamplesTruncated: false
            )],
            modelsByProvider: ["deepseek": ["deepseek-v3-flash"]],
            sessionsRoot: nil, sessionCount: 1, eventCount: 1, scannedAt: now
        )
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)
        let entry = try XCTUnwrap(report.dailyBuckets?.flatMap(\.entries).first {
            $0.quotaProviderID == QuotaProviderID.deepseek
        })
        XCTAssertEqual(try XCTUnwrap(entry.value), 3, accuracy: 0.000001)
    }

    private func emptySampleQuotaInfo() -> QuotaInfo {
        QuotaInfo(
            models: [ModelQuota(
                modelName: "chatgpt_plan",
                intervalTotalCount: 100, intervalUsageCount: 40,
                intervalRemainingPercent: 60, intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3 * 60 * 60),
                intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 1000, weeklyUsageCount: 400,
                weeklyRemainingPercent: 60, weeklyStatus: .present,
                weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                weeklyWindowSeconds: 7 * 24 * 60 * 60
            )],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                dailyTokenUsage: [],
                recentSamples: [],
                scannedAt: now
            ),
            fetchedAt: now,
            balanceDetail: nil
        )
    }

    func testBuildProducesSevenBucketsWithAuthoritativeTotals() {
        let info = chatGPTQuotaInfo(scannedAt: now)
        let status = codexStatus(state: .ok(info))
        let report = UsageReportBuilder.build(makeInput([status]), seq: 42)

        XCTAssertEqual(report.seq, 42)
        XCTAssertEqual(report.protocolVersion, FleetProtocol.version)
        XCTAssertEqual(report.node.nodeName, "Test-Mac")
        XCTAssertEqual(report.attributionFingerprint,
                       FleetAttributionFingerprint.compute(ClientProviderBinding.defaultBindings))

        let buckets = try! XCTUnwrap(report.dailyBuckets)
        XCTAssertEqual(buckets.count, 7, "固定 today + previous six")
        XCTAssertEqual(buckets.last?.dayKey, FleetMerger.dayKey(of: now))

        let today = buckets.last!
        XCTAssertEqual(today.totals.input, 80, "input 是 uncached 口径（200 总输入 - 120 cache 命中）")
        XCTAssertEqual(today.totals.cacheRead, 120)
        XCTAssertEqual(today.totals.rounds, 2)
        XCTAssertEqual(today.clientProviders.count, 1)
        XCTAssertEqual(today.clientProviders[0].clientID, ClientID.codex)
        XCTAssertEqual(today.clientProviders[0].quotaProviderID, QuotaProviderID.openAI)
        XCTAssertTrue(today.totalsComplete)
        XCTAssertTrue(today.totals == today.clientProviders, "totals 与 clientProviders 汇总一致（hub 校验可通过）")
        XCTAssertTrue(today.modelDetailsComplete, "留存样本与日聚合对齐时明细完整")

        let yesterday = buckets[buckets.count - 2]
        XCTAssertEqual(yesterday.totals.input, 10)
        XCTAssertTrue(yesterday.modelDetailsComplete, "对齐按日独立判定，健康天不受其他天牵连")
        // 没有数据的旧日是权威零桶，不是缺失。
        XCTAssertEqual(buckets.first?.totals, FleetTotals.zero)
    }

    func testBuildEntriesGroupByModelWithSameSamplePricing() {
        let info = chatGPTQuotaInfo(scannedAt: now)
        let report = UsageReportBuilder.build(makeInput([codexStatus(state: .ok(info))]), seq: 1)
        let today = try! XCTUnwrap(report.dailyBuckets?.last)
        XCTAssertEqual(today.entries.count, 1, "同模型样本塌成一行")
        let entry = today.entries[0]
        XCTAssertEqual(entry.modelName, "gpt-5.5")
        XCTAssertEqual(entry.clientID, ClientID.codex)
        XCTAssertEqual(entry.input, 80, "两条样本的 uncached input 相加：(100-60)×2")
        XCTAssertEqual(entry.cacheRead, 120)
        XCTAssertNotNil(entry.value, "打包价目表对 gpt-5.5 有价")
        XCTAssertEqual(entry.currency, .usd)
        XCTAssertEqual(entry.coverage, .full)
    }

    func testBuildQuotaChannelOnlyForValidLastSuccess() {
        let valid = codexStatus(state: .ok(chatGPTQuotaInfo(scannedAt: now)))
        let disabled = codexStatus(state: .ok(chatGPTQuotaInfo(scannedAt: now)), enabled: false)

        var deepseek = ProviderStatus(
            id: ProviderKind.deepseek.providerID,
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "dollarsign.circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "未配置")
        )
        deepseek.isEnabled = true

        let report = UsageReportBuilder.build(makeInput([valid, disabled, deepseek]), seq: 1)
        XCTAssertEqual(report.quotas?.map(\.quotaProviderID), [QuotaProviderID.openAI],
                       "disabled / 未配置 provider 不报本机额度（§5.1）")
        XCTAssertEqual(report.quotas?.first?.planLabel, "Plus")
        XCTAssertNil(report.quotas?.first?.resetCredits)
        XCTAssertEqual(report.quotas?.first?.models.first?.modelName, "chatgpt_plan")
    }

    func testBuildWindowRowsUseRealQuotaWindowBounds() {
        let info = chatGPTQuotaInfo(scannedAt: now)
        let report = UsageReportBuilder.build(makeInput([codexStatus(state: .ok(info))]), seq: 1)
        let windows = try! XCTUnwrap(report.windowUsage)
        let interval = windows.first { $0.windowKind == "interval" }
        XCTAssertNotNil(interval, "有 interval 窗口的 model 产出一行")
        let expectedEnd = now.addingTimeInterval(3 * 60 * 60)
        let expectedStart = expectedEnd.addingTimeInterval(-5 * 60 * 60)
        XCTAssertEqual(interval?.endAt.timeIntervalSince1970 ?? 0,
                       expectedEnd.timeIntervalSince1970, accuracy: 0.5,
                       "窗口边界来自 quota 的真实 resetsAt（§10.7.1）")
        XCTAssertEqual(interval?.startAt.timeIntervalSince1970 ?? 0,
                       expectedStart.timeIntervalSince1970, accuracy: 0.5)
        // 窗口内两条样本（now-60 / now-3600 都落在 [start, end)），uncached 口径。
        XCTAssertEqual(interval?.input, 80)
        XCTAssertNotNil(interval?.value, "金额与 token 同一批样本（同源计价）")
        XCTAssertTrue(windows.contains { $0.windowKind == "weekly" }, "周窗口同样产出")
    }

    func testDisabledProviderContributesNoUsageChannels() {
        // 用户在 config 里禁用的 provider 仍保留扫描缓存 —— 那些缓存不该被
        // 上报并计入 hub 的权威合计（额度通道本来就有这道门控）。两个 codex
        // status（一份启用一份禁用）若不门控，今日 input 会翻倍成 160。
        let info = chatGPTQuotaInfo(scannedAt: now)
        let enabled = codexStatus(state: .ok(info))
        let disabled = codexStatus(state: .ok(info), enabled: false)
        let report = UsageReportBuilder.build(makeInput([enabled, disabled]), seq: 7)

        let buckets = try! XCTUnwrap(report.dailyBuckets)
        XCTAssertEqual(buckets.count, 7, "日桶仍是七天窗口")
        XCTAssertEqual(buckets.last?.totals.input, 80, "禁用 provider 的用量不计入日桶")
        XCTAssertEqual(buckets.last?.clientProviders.count, 1, "禁用 provider 不进 clientProviders")
        let enabledOnly = UsageReportBuilder.build(makeInput([enabled]), seq: 8)
        XCTAssertEqual(report.windowUsage?.count, enabledOnly.windowUsage?.count,
                       "禁用 provider 不额外贡献窗口行")
    }

    func testBuildMarksScanningSourceUnavailableAndOmitsItsDailyRows() {
        var status = codexStatus(state: .ok(chatGPTQuotaInfo(scannedAt: now)))
        status.isScanningLocalUsage = true
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)
        let today = try! XCTUnwrap(report.dailyBuckets?.last)
        XCTAssertFalse(today.totalsComplete)
        XCTAssertFalse(today.modelDetailsComplete)
        XCTAssertEqual(today.clientProviders, [], "扫描中来源不发送可能过期的贡献")
        let scanningSources = today.unavailableSources ?? []
        XCTAssertEqual(scanningSources.count, 2)
        XCTAssertTrue(scanningSources.allSatisfy { $0.reason == .scanning })
        XCTAssertEqual(
            Set(scanningSources.map(\.clientID)),
            Set([ClientID.codex, ClientID.openCode]),
            "ChatGPT 的本地扫描状态影响 Codex 与自动归因的 OpenCode 行"
        )
        XCTAssertTrue(scanningSources.allSatisfy { $0.quotaProviderID == QuotaProviderID.openAI })
        XCTAssertEqual(report.windowUsage, [], "扫描中的窗口通道省略该 provider，保留 hub 旧范围")
        XCTAssertNotNil(report.quotas)
    }

    func testBuildMarksFailedSourceUnavailableWhenItHasNoContribution() {
        // A failed scan can leave an empty projection. Sending the resulting zero
        // buckets would replace the last successful authoritative totals on hub.
        var status = codexStatus(state: .ok(QuotaInfo(
            models: [], resetCredits: nil, planLabel: "Plus", accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
        )))
        status.localUsageFreshness[.codex] = .failed
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)

        let today = try! XCTUnwrap(report.dailyBuckets?.last)
        XCTAssertFalse(today.totalsComplete, "失败扫描即使没有 contribution 也不能伪装成完整零桶")
        XCTAssertEqual(today.unavailableSources?.map(\.reason), [.failed])
        XCTAssertEqual(today.clientProviders, [])
        XCTAssertNotNil(report.quotas, "local usage freshness 不应阻断额度通道")
        XCTAssertEqual(report.windowUsage, [], "失败扫描的空窗口不能伪装成完整零值")
    }

    func testFailedAndScanningSourcesOmitWindowsButFreshEmptySourceReportsRealZero() {
        var failed = codexStatus(state: .ok(emptySampleQuotaInfo()))
        failed.localUsageFreshness[.codex] = .failed
        let failedReport = UsageReportBuilder.build(makeInput([failed]), seq: 1)
        XCTAssertEqual(failedReport.dailyBuckets?.last?.unavailableSources?.map(\.reason), [.failed])
        XCTAssertEqual(failedReport.windowUsage, [])
        XCTAssertEqual(failedReport.quotas?.count, 1, "额度仍照常上报")

        let scanning = codexStatus(state: .ok(emptySampleQuotaInfo()), scanning: true)
        let scanningReport = UsageReportBuilder.build(makeInput([scanning]), seq: 2)
        let scanningSources = scanningReport.dailyBuckets?.last?.unavailableSources ?? []
        XCTAssertEqual(scanningSources.count, 2)
        XCTAssertTrue(scanningSources.allSatisfy { $0.reason == .scanning })
        XCTAssertEqual(
            Set(scanningSources.map(\.clientID)),
            Set([ClientID.codex, ClientID.openCode]),
            "ChatGPT 的本地扫描状态影响 Codex 与自动归因的 OpenCode 行"
        )
        XCTAssertTrue(scanningSources.allSatisfy { $0.quotaProviderID == QuotaProviderID.openAI })
        XCTAssertEqual(scanningReport.windowUsage, [])
        XCTAssertEqual(scanningReport.quotas?.count, 1)

        let recovered = codexStatus(state: .ok(emptySampleQuotaInfo()))
        let recoveredReport = UsageReportBuilder.build(makeInput([recovered]), seq: 3)
        XCTAssertNotNil(recoveredReport.dailyBuckets, "freshness 恢复后重新提供权威日桶")
        XCTAssertNil(recoveredReport.dailyBuckets?.last?.unavailableSources)
        XCTAssertEqual(recoveredReport.windowUsage?.count, 2)
        XCTAssertTrue(
            recoveredReport.windowUsage?.allSatisfy {
                $0.input == 0 && $0.cacheRead == 0 && $0.output == 0 && $0.reasoning == 0
                    && $0.complete && !$0.sourceTruncated
            } == true,
            "fresh scan 明确提供的真实空样本应仍可报告完整零窗口"
        )
    }

    func testTruncatedDshSnapshotWithoutRetainedProviderFrameMarksReportIncomplete() throws {
        let scanNow = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-empty-truncated-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeSession(_ id: String, body: String, mtime: Date) throws {
            let directory = sessions.appendingPathComponent("--Project--", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("session.jsonl")
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }

        let oldWithUsage = [
            #"{"type":"session","version":0,"id":"old","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax-cn","model":"MiniMax-M3","contextWindow":1000000}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":300,"outputTokens":2}}}"#
        ].joined(separator: "\n") + "\n"
        let newestHeaderOnly = #"{"type":"session","version":0,"id":"new","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"# + "\n"
        try writeSession("old", body: oldWithUsage, mtime: Date(timeIntervalSince1970: 1_600_000_000))
        try writeSession("new", body: newestHeaderOnly, mtime: scanNow)

        let complete = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessions, cacheDir: cache, fileManager: FileManagerBox(),
            calendar: calendar, now: { scanNow }, decompressor: { $0 },
            limits: DshLocalUsageScanLimits(
                maxSessionFiles: 2, maxTotalRawBytes: 1024 * 1024,
                maxJSONLLineBytes: 8 * 1024 * 1024, maxRecentSamples: 65_536
            )
        )
        XCTAssertFalse(complete.isTruncated == true)
        XCTAssertFalse(complete.byProvider.isEmpty)

        let local = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessions, cacheDir: cache, fileManager: FileManagerBox(),
            calendar: calendar, now: { scanNow }, decompressor: { $0 },
            limits: DshLocalUsageScanLimits(
                maxSessionFiles: 1, maxTotalRawBytes: 1024 * 1024,
                maxJSONLLineBytes: 8 * 1024 * 1024, maxRecentSamples: 65_536
            )
        )
        XCTAssertTrue(local.isTruncated == true)
        XCTAssertTrue(local.byProvider.isEmpty, "保留的合法 session header 没有用量帧")

        var status = ProviderStatus(
            id: ProviderKind.minimaxTokenPlan.providerID, displayName: "MiniMax",
            kind: .minimaxTokenPlan, iconSystemName: "dollarsign.circle", accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "general", intervalTotalCount: 100, intervalUsageCount: 20,
                    intervalRemainingPercent: 80, intervalStatus: .present,
                    intervalResetsAt: scanNow.addingTimeInterval(3 * 60 * 60),
                    intervalWindowSeconds: 5 * 60 * 60,
                    weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                    weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
                )], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: scanNow, balanceDetail: nil
            ))
        )
        status.isEnabled = true
        status.dshUsage = local

        let nodeID = UUID()
        let scope = UUID().uuidString
        let store = try FleetStore(url: root.appendingPathComponent("fleet.sqlite"))
        var healthyStatus = status
        healthyStatus.dshUsage = complete
        let healthyReport = UsageReportBuilder.build(UsageReportInput(
            nodeID: nodeID, nodeName: "test", bindings: ClientProviderBinding.defaultBindings,
            statuses: [healthyStatus], now: scanNow, calendar: calendar
        ), seq: 1)
        let healthyDaily = try XCTUnwrap(healthyReport.dailyBuckets?.last)
        XCTAssertGreaterThan(healthyDaily.totals.input, 0)
        let healthyValidation = FleetReportValidator.validate(healthyReport)
        XCTAssertNil(healthyValidation.dailyBucketsError)
        try store.applyReport(healthyReport, validation: healthyValidation, scope: scope, receivedAt: scanNow)

        let enabledReport = UsageReportBuilder.build(UsageReportInput(
            nodeID: nodeID, nodeName: "test", bindings: ClientProviderBinding.defaultBindings,
            statuses: [status], now: scanNow, calendar: calendar
        ), seq: 2)
        let enabledToday = try XCTUnwrap(enabledReport.dailyBuckets?.last)
        XCTAssertFalse(enabledToday.totalsComplete)
        XCTAssertTrue(enabledToday.sourceTruncated)
        XCTAssertEqual(enabledToday.unavailableSources, [FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            reason: .truncated
        )])
        let enabledWindow = try XCTUnwrap(enabledReport.windowUsage?.first)
        XCTAssertFalse(enabledWindow.complete)
        XCTAssertTrue(enabledWindow.sourceTruncated)
        let incompleteValidation = FleetReportValidator.validate(enabledReport)
        XCTAssertNil(incompleteValidation.dailyBucketsError,
                     "带明确 unavailable source 的部分日桶应通过结构校验")
        let applyOutcome = try store.applyReport(
            enabledReport, validation: incompleteValidation, scope: scope,
            receivedAt: scanNow.addingTimeInterval(1)
        )
        XCTAssertTrue(applyOutcome.dailyApplied)
        let retained = try store.loadHubState(scope: scope)
        let retainedDaily = try XCTUnwrap(retained.nodes.first?.report.dailyBuckets?.last)
        XCTAssertEqual(retainedDaily.totals, healthyDaily.totals, "不可用 DSH 值保留 hub 上次有效贡献")
        XCTAssertEqual(retainedDaily.clientProviders, healthyDaily.clientProviders)
        XCTAssertEqual(retainedDaily.entries, healthyDaily.entries)
        XCTAssertFalse(retainedDaily.totalsComplete)
        XCTAssertEqual(retainedDaily.unavailableSources, enabledToday.unavailableSources)

        var disabledBindings = ClientProviderBinding.defaultBindings
        let dshMinimax = try XCTUnwrap(disabledBindings.firstIndex {
            $0.clientID == ClientID.dsh && $0.quotaProviderID == QuotaProviderID.minimax
        })
        disabledBindings[dshMinimax].enabled = false
        status.clientBindings = disabledBindings
        let disabledReport = UsageReportBuilder.build(UsageReportInput(
            nodeID: nodeID, nodeName: "test", bindings: disabledBindings,
            statuses: [status], now: scanNow, calendar: calendar
        ), seq: 3)
        XCTAssertFalse(disabledReport.dailyBuckets?.last?.totalsComplete == true,
                       "旧 DSH binding 开关不能隐藏其截断状态")
        XCTAssertEqual(disabledReport.dailyBuckets?.last?.unavailableSources, enabledToday.unavailableSources)
        XCTAssertFalse(disabledReport.windowUsage?.first?.complete == true)
    }

    func testFailedProviderDoesNotSuppressHealthyProviderWindowRows() {
        var failedCodex = codexStatus(state: .ok(emptySampleQuotaInfo()))
        failedCodex.localUsageFreshness[.codex] = .failed

        var glm = ProviderStatus(
            id: ProviderKind.glmCodingPlan.providerID,
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "dollarsign.circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "glm_coding_plan",
                    intervalTotalCount: 100, intervalUsageCount: 20,
                    intervalRemainingPercent: 80, intervalStatus: .present,
                    intervalResetsAt: now.addingTimeInterval(3 * 60 * 60),
                    intervalWindowSeconds: 5 * 60 * 60,
                    weeklyTotalCount: 1000, weeklyUsageCount: 200,
                    weeklyRemainingPercent: 80, weeklyStatus: .present,
                    weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                    weeklyWindowSeconds: 7 * 24 * 60 * 60
                )],
                resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
            ))
        )
        glm.isEnabled = true
        let glmDaily = DshDailyUsage(
            dayStart: Calendar.current.startOfDay(for: now),
            inputTokens: 12,
            outputTokens: 3,
            totalTokens: 15,
            turns: 1,
            rounds: 1
        )
        let glmSample = sample(
            at: now.addingTimeInterval(-60), model: "GLM-5.3",
            input: 12, cached: 0, output: 3, reasoning: 0,
            sourceProviderID: "dsh:zhipuai"
        )
        glm.dshUsage = DshLocalUsage(
            byProvider: ["zhipuai": DshProviderUsage(
                today: glmDaily,
                dailyTokenUsage: [glmDaily],
                sessionCount: 1,
                roundCount: 1,
                recentSamples: [glmSample],
                recentSamplesTruncated: false
            )],
            modelsByProvider: ["zhipuai": ["GLM-5.3"]],
            sessionsRoot: nil,
            sessionCount: 1,
            eventCount: 1,
            scannedAt: now
        )

        let report = UsageReportBuilder.build(makeInput([failedCodex, glm]), seq: 1)
        XCTAssertFalse(report.windowUsage?.contains { $0.quotaProviderID == QuotaProviderID.openAI } == true,
                       "failed provider 的窗口行省略")
        XCTAssertTrue(report.windowUsage?.contains {
            $0.quotaProviderID == QuotaProviderID.zhipu && $0.input > 0
        } == true,
                      "健康 provider 的窗口行仍正常构建")
    }

    func testFailedAndScanningWindowOmissionPreservesStoredRangeUntilFreshZero()
        throws
    {
        let nodeID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-window-freshness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FleetStore(url: directory.appendingPathComponent("fleet.sqlite"))
        let scope = UUID().uuidString

        func build(_ status: ProviderStatus, seq: Int) -> NodeUsageReport {
            UsageReportBuilder.build(UsageReportInput(
                nodeID: nodeID,
                nodeName: "Test-Mac",
                bindings: ClientProviderBinding.defaultBindings,
                statuses: [status],
                now: now
            ), seq: seq)
        }
        func apply(_ report: NodeUsageReport, receivedAt: Date) throws {
            try store.applyReport(
                report,
                validation: FleetReportValidator.validate(report),
                scope: scope,
                receivedAt: receivedAt
            )
        }

        let healthy = build(codexStatus(state: .ok(chatGPTQuotaInfo(scannedAt: now))), seq: 1)
        XCTAssertEqual(healthy.windowUsage?.count, 2)
        try apply(healthy, receivedAt: now)
        let initialState = try store.loadHubState(scope: scope)
        let acceptedRows = try XCTUnwrap(initialState.nodes.first?.windowRows)
        XCTAssertTrue(acceptedRows.contains { $0.input > 0 })

        var failed = codexStatus(state: .ok(emptySampleQuotaInfo()))
        failed.localUsageFreshness[.codex] = .failed
        let scanning = codexStatus(state: .ok(emptySampleQuotaInfo()), scanning: true)
        for (seq, status) in [(2, failed), (3, scanning)] {
            let report = build(status, seq: seq)
            XCTAssertFalse(report.dailyBuckets?.last?.totalsComplete ?? true)
            XCTAssertEqual(report.dailyBuckets?.last?.clientProviders, [])
            XCTAssertEqual(report.windowUsage, [])
            try apply(report, receivedAt: now.addingTimeInterval(TimeInterval(seq)))
            let retainedState = try store.loadHubState(scope: scope)
            let retainedRows = try XCTUnwrap(retainedState.nodes.first?.windowRows)
            XCTAssertEqual(retainedRows.map(\.recordKey), acceptedRows.map(\.recordKey))
            XCTAssertEqual(retainedRows.map(\.input), acceptedRows.map(\.input),
                           "失败/扫描中的空投影不得把 hub 已有窗口覆写为零")
        }

        let recovered = build(codexStatus(state: .ok(emptySampleQuotaInfo())), seq: 4)
        XCTAssertEqual(recovered.windowUsage?.count, 2)
        XCTAssertTrue(recovered.windowUsage?.allSatisfy { $0.input == 0 && $0.complete } == true)
        try apply(recovered, receivedAt: now.addingTimeInterval(4))
        let recoveredState = try store.loadHubState(scope: scope)
        let recoveredRows = try XCTUnwrap(recoveredState.nodes.first?.windowRows)
        XCTAssertEqual(recoveredRows.map(\.recordKey), acceptedRows.map(\.recordKey))
        XCTAssertTrue(recoveredRows.allSatisfy { $0.input == 0 && $0.complete },
                      "fresh scan 明确的真实零用量应覆盖先前窗口")
    }

    func testFailedDshPreservesHealthyMiniMaxContributionAndRecoversPerSource() {
        let dayStart = Calendar.current.startOfDay(for: now)
        let minimaxDaily = LocalDailyTokenUsage(
            dayStart: dayStart, inputTokens: 40, outputTokens: 10,
            totalTokens: 50, turns: 1, rounds: 1
        )
        let dshDaily = DshDailyUsage(
            dayStart: dayStart, inputTokens: 70, outputTokens: 20,
            totalTokens: 90, turns: 2, rounds: 2
        )
        var status = ProviderStatus(
            id: ProviderKind.minimaxTokenPlan.providerID,
            displayName: "MiniMax",
            kind: .minimaxTokenPlan,
            iconSystemName: "dollarsign.circle",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: .ready
        )
        status.minimaxLocalUsage = MinimaxLocalUsage(
            today: minimaxDaily,
            dailyTokenUsage: [minimaxDaily],
            scannedAt: now,
            sessionCount: 1,
            eventCount: 1,
            failedSessionCount: 0,
            recentSamples: []
        )
        status.dshUsage = DshLocalUsage(
            byProvider: ["minimax-cn": DshProviderUsage(
                today: dshDaily,
                dailyTokenUsage: [dshDaily],
                sessionCount: 1,
                roundCount: 2,
                recentSamples: [sample(
                    at: now.addingTimeInterval(-60), model: "MiniMax-M3",
                    input: 70, cached: 0, output: 20, reasoning: 0,
                    sourceProviderID: "dsh:minimax-cn"
                )],
                recentSamplesTruncated: false
            )],
            modelsByProvider: [:],
            sessionsRoot: nil,
            sessionCount: 1,
            eventCount: 2,
            scannedAt: now
        )

        status.localUsageFreshness[.dsh] = .failed
        let failedReport = UsageReportBuilder.build(makeInput([status]), seq: 1)
        let failedToday = try! XCTUnwrap(failedReport.dailyBuckets?.last)
        XCTAssertEqual(failedToday.totals.input, 40, "健康 MiniMax Code 贡献必须保留")
        XCTAssertEqual(failedToday.clientProviders.map(\.clientID), [ClientID.minimaxCode])
        XCTAssertFalse(failedToday.clientProviders.contains { $0.clientID == ClientID.dsh },
                       "失败 DSH 的缓存行/零值不能混进本轮健康汇总")
        XCTAssertFalse(failedToday.entries.contains { $0.clientID == ClientID.dsh },
                       "失败 DSH 的模型明细也不能混进本轮报告")
        XCTAssertEqual(failedToday.unavailableSources, [FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            reason: .failed
        )])
        XCTAssertFalse(failedToday.totalsComplete)
        XCTAssertFalse(failedToday.modelDetailsComplete)
        XCTAssertFalse(failedToday.sourceTruncated)
        XCTAssertNil(FleetReportValidator.validate(failedReport).dailyBucketsError)

        var recovered = status
        recovered.localUsageFreshness[.dsh] = .clean
        let recoveredReport = UsageReportBuilder.build(makeInput([recovered]), seq: 2)
        let recoveredToday = try! XCTUnwrap(recoveredReport.dailyBuckets?.last)
        XCTAssertEqual(recoveredToday.totals.input, 110)
        XCTAssertEqual(
            Set(recoveredToday.clientProviders.map(\.clientID)),
            Set([ClientID.minimaxCode, ClientID.dsh])
        )
        XCTAssertTrue(recoveredToday.totalsComplete)
        XCTAssertNil(recoveredToday.unavailableSources)
        XCTAssertTrue(recoveredToday.entries.contains { $0.clientID == ClientID.dsh })

        var disabledBinding = status
        var bindings = ClientProviderBinding.defaultBindings
        let dshIndex = bindings.firstIndex {
            $0.clientID == ClientID.dsh && $0.quotaProviderID == QuotaProviderID.minimax
        }!
        bindings[dshIndex].enabled = false
        disabledBinding.clientBindings = bindings
        let disabledReport = UsageReportBuilder.build(UsageReportInput(
            nodeID: UUID(), nodeName: "Test-Mac", bindings: bindings,
            statuses: [disabledBinding], now: now
        ), seq: 3)
        let disabledToday = try! XCTUnwrap(disabledReport.dailyBuckets?.last)
        XCTAssertEqual(disabledToday.totals.input, 40,
                       "旧 binding 开关不能让 failed DSH 缓存贡献计入报告")
        XCTAssertFalse(disabledToday.totalsComplete)
        XCTAssertEqual(disabledToday.unavailableSources, [FleetDailyUnavailableSource(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            reason: .failed
        )])
        XCTAssertEqual(disabledToday.clientProviders.map(\.clientID), [ClientID.minimaxCode])
        XCTAssertFalse(disabledToday.entries.contains { $0.clientID == ClientID.dsh })
    }

    func testDshSampleCapKeepsAuthoritativeDailyTotalsButMarksDetailsIncomplete() throws {
        let calendar = Calendar.current
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-dsh-sample-cap-builder-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = sessionsRoot
            .appendingPathComponent("--Project--", isDirectory: true)
            .appendingPathComponent("sample-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let firstTime = Int64((now.timeIntervalSince1970 - 100) * 1_000)
        let secondTime = Int64((now.timeIntervalSince1970 - 40) * 1_000)
        let body = [
            #"{"type":"session","version":0,"id":"sample-cap","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax-cn","model":"MiniMax-M3"}}"#,
            #"{"type":"assistant/message","seq":2,"time":\#(firstTime),"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"outputTokens":10,"reasoningTokens":0}}}"#,
            #"{"type":"assistant/message","seq":3,"time":\#(secondTime),"data":{"turn":2,"step":0,"usage":{"inputTokens":200,"outputTokens":20,"reasoningTokens":0}}}"#
        ].joined(separator: "\n") + "\n"
        try body.write(
            to: sessionDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let scannerLimits = DshLocalUsageScanLimits(
            maxSessionFiles: 8,
            maxTotalRawBytes: 1_000_000,
            maxJSONLLineBytes: 1_000_000,
            maxRecentSamples: 1
        )
        let scanNow = now
        let scanned = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { scanNow },
            limits: scannerLimits
        )
        let dshProvider = try XCTUnwrap(scanned.byProvider["minimax-cn"])
        XCTAssertEqual(dshProvider.today?.inputTokens, 300)
        XCTAssertEqual(dshProvider.recentSamples.map(\.inputTokens), [200])
        XCTAssertEqual(dshProvider.recentSamplesTruncated, true)
        let quota = QuotaInfo(
            models: [ModelQuota(
                modelName: "general",
                intervalTotalCount: 1_000, intervalUsageCount: 300,
                intervalRemainingPercent: 70, intervalStatus: .present,
                intervalResetsAt: now.addingTimeInterval(3 * 60 * 60),
                intervalWindowSeconds: 5 * 60 * 60,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
        )
        var status = ProviderStatus(
            id: ProviderKind.minimaxTokenPlan.providerID,
            displayName: "MiniMax", kind: .minimaxTokenPlan,
            iconSystemName: "dollarsign.circle", accentColor: .minimax,
            refreshIntervalSeconds: 300, state: .ok(quota)
        )
        status.dshUsage = scanned

        let nodeID = UUID()
        let report = UsageReportBuilder.build(
            UsageReportInput(
                nodeID: nodeID, nodeName: "Test-Mac",
                bindings: ClientProviderBinding.defaultBindings,
                statuses: [status], now: now, calendar: calendar
            ),
            seq: 1
        )
        let today = try XCTUnwrap(report.dailyBuckets?.last)
        XCTAssertEqual(today.totals.input, 300, "权威日总量必须包含被样本 cap 排除的事件")
        XCTAssertEqual(today.entries.reduce(0) { $0 + $1.input }, 200,
                       "模型明细只包含保留样本")
        XCTAssertTrue(today.totalsComplete, "样本 cap 不得污染权威 totals 完整性")
        XCTAssertFalse(today.modelDetailsComplete)
        XCTAssertFalse(today.sourceTruncated)

        let firstDay = try XCTUnwrap(report.dailyBuckets?.first)
        XCTAssertTrue(firstDay.modelDetailsComplete, "样本 cap (samplesTruncated=true) 仅影响样本对不齐的当天，零用量或其他对齐的天不受污染")
        let validation = FleetReportValidator.validate(report)
        XCTAssertNil(validation.dailyBucketsError,
                     "仅样本明细不完整时，权威日 totals 仍可被 Store 接受")
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-dsh-sample-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try FleetStore(url: storeRoot.appendingPathComponent("fleet.sqlite"))
        let scope = UUID().uuidString
        try store.applyReport(report, validation: validation, scope: scope, receivedAt: now)
        let storedDay = try XCTUnwrap(
            store.loadHubState(scope: scope).nodes.first(where: { $0.nodeID == nodeID })?
                .report.dailyBuckets?.last
        )
        XCTAssertEqual(storedDay.totals.input, 300)
        XCTAssertFalse(storedDay.modelDetailsComplete)

        let window = try XCTUnwrap(report.windowUsage?.first { $0.windowKind == "interval" })
        XCTAssertEqual(window.input, 200)
        XCTAssertFalse(window.complete)
        XCTAssertEqual(window.coverage, .partial)

        // 旧 binding 开关不应隐藏 DSH token 或 sample-cap incompleteness。
        var disabled = status
        var bindings = ClientProviderBinding.defaultBindings
        if let index = bindings.firstIndex(where: {
            $0.clientID == ClientID.dsh && $0.quotaProviderID == QuotaProviderID.minimax
        }) {
            bindings[index].enabled = false
        }
        disabled.clientBindings = bindings
        let disabledReport = UsageReportBuilder.build(
            UsageReportInput(
                nodeID: UUID(), nodeName: "Test-Mac", bindings: bindings,
                statuses: [disabled], now: now, calendar: calendar
            ),
            seq: 2
        )
        let disabledToday = try XCTUnwrap(disabledReport.dailyBuckets?.last)
        XCTAssertFalse(disabledToday.modelDetailsComplete)
        let disabledWindow = try XCTUnwrap(disabledReport.windowUsage?.first)
        XCTAssertEqual(disabledWindow.input, 200)
        XCTAssertFalse(disabledWindow.complete)
        XCTAssertEqual(disabledWindow.coverage, .partial)
    }

    // MARK: GLM「免 / 速 / 它」今日窗口行（与本地卡动态行同源同口径）

    private func glmStatus(
        samples: [LocalTokenUsageSample],
        offPeakWindows: [GlmOffPeakWindow] = []
    ) -> ProviderStatus {
        var status = ProviderStatus(
            id: ProviderKind.glmCodingPlan.providerID,
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "circle",
            accentColor: .glm,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [ModelQuota(
                    modelName: "glm_coding_plan",
                    intervalTotalCount: 100, intervalUsageCount: 40,
                    intervalRemainingPercent: 60, intervalStatus: .present,
                    intervalResetsAt: now.addingTimeInterval(2 * 3_600),
                    intervalWindowSeconds: 5 * 3_600,
                    weeklyTotalCount: 700, weeklyUsageCount: 300,
                    weeklyRemainingPercent: 60, weeklyStatus: .present,
                    weeklyResetsAt: now.addingTimeInterval(3 * 86_400),
                    weeklyWindowSeconds: 7 * 24 * 3_600
                )],
                resetCredits: nil, planLabel: "Pro", accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
            ))
        )
        status.glmLocalUsage = GlmLocalUsage(
            today: GlmDailyUsage(
                dayStart: Calendar.current.startOfDay(for: now),
                inputTokens: 0, rounds: 0
            ),
            dailyTokenUsage: [],
            scannedAt: now,
            sessionCount: samples.count,
            eventCount: samples.count,
            failedSessionCount: 0,
            recentSamples: samples,
            offPeakWindows: offPeakWindows
        )
        return status
    }

    private func glmSample(
        _ seconds: TimeInterval, provider: String, input: Int
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: Calendar.current.startOfDay(for: now).addingTimeInterval(seconds),
            modelName: "GLM-5.3",
            promptID: "glm-\(provider)-\(seconds)",
            inputTokens: input, cachedInputTokens: 0,
            outputTokens: 1, reasoningOutputTokens: 0,
            sourceProviderID: provider
        )
    }

    /// 三个分类各自上报一行自然日窗口（`glmStartPlan` / `glmHighspeed` /
    /// `glmOtherPlan`），token 与本地卡动态行同一份切片谓词：正常任务与闲时
    /// 样本不进这三行；边界取报告时刻所在自然日 `[startOfDay, +1d)`。
    func testBuildWindowRowsReportGlmCategoryTodayRows() throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: todayStart))
        let status = glmStatus(samples: [
            glmSample(3_600, provider: "builtin:bigmodel-start-plan", input: 100),
            glmSample(4_200, provider: "account:bigmodel-highspeed-card", input: 200),
            glmSample(4_800, provider: "builtin:bigmodel-future-plan", input: 300),
            glmSample(5_400, provider: "builtin:bigmodel-coding-plan", input: 9_999),
            glmSample(6_000, provider: "offpeak-idle-plan", input: 8_888),
        ])
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)
        let rows = try! XCTUnwrap(report.windowUsage)

        let expected: [(kind: String, input: Int)] = [
            ("glmStartPlan", 100),
            ("glmHighspeed", 200),
            ("glmOtherPlan", 300),
        ]
        for expectation in expected {
            let row = try XCTUnwrap(rows.first { $0.windowKind == expectation.kind },
                                    "\(expectation.kind) 必须成行")
            XCTAssertEqual(row.input, expectation.input,
                           "\(expectation.kind) 只含本分类今日样本（uncached 口径）")
            XCTAssertEqual(row.modelID, "glm_coding_plan")
            XCTAssertEqual(row.startAt.timeIntervalSince1970, todayStart.timeIntervalSince1970,
                           accuracy: 0.5, "\(expectation.kind) 边界起点是自然日起点")
            XCTAssertEqual(row.endAt.timeIntervalSince1970, todayEnd.timeIntervalSince1970,
                           accuracy: 0.5, "\(expectation.kind) 边界终点是次自然日起点")
            XCTAssertTrue(row.complete, "干净扫描时窗口行完整")
        }
    }

    /// 当日无样本的分类照常上报**全零**行：展示层 `visibleRows` 统一跳过全零行，
    /// 而上报侧省略会让 hub 把当日无用量的 GLM 节点误标 missing（窗口聚合只
    /// 合并边界完全相同的行，缺行的节点进 missingNodeIDs、聚合被打上不完整）。
    func testBuildWindowRowsReportZeroGlmCategoryRowsWithoutSamplesToday() throws {
        let status = glmStatus(samples: [])
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)
        let rows = try! XCTUnwrap(report.windowUsage)
        for kind in ["glmStartPlan", "glmHighspeed", "glmOtherPlan"] {
            let row = try XCTUnwrap(rows.first { $0.windowKind == kind },
                                    "\(kind) 无样本也要上报全零行，避免同边界聚合误标 missing")
            XCTAssertEqual(row.input, 0)
            XCTAssertEqual(row.cacheRead, 0)
            XCTAssertNil(row.value, "空样本的真实零窗口不伪造估算金额")
        }
    }

    /// 样本被 cap / 老化**静默**挤出且来源不带 `samplesTruncated` 标志（Codex 的
    /// suffix 裁剪没有标志位，菜单侧用 hasIncompleteSamples 对照检测兜同一场景）：
    /// builder 按日对照 entries 与权威日桶，把当日 modelDetailsComplete 打假，
    /// 不把差额伪装成自信金额；对得齐的天逐日独立保持完整。合并侧 costText
    /// 因此带上「（部分计价）」标注。
    func testSilentlyPrunedSamplesMarkOnlyMismatchedDayDetailsIncomplete() throws {
        let todayStart = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayStart)!
        // 日聚合记两条今日样本的量，recentSamples 只留存一条——差额来自无标志
        // 裁剪；昨天样本与日聚合一致，验证逐日粒度。
        let info = chatGPTQuotaInfo(scannedAt: now, recentSamples: [
            sample(at: now.addingTimeInterval(-60)),
            sample(at: yesterday.addingTimeInterval(3600), input: 10, cached: 0, output: 5, reasoning: 0),
        ])
        let report = UsageReportBuilder.build(makeInput([codexStatus(state: .ok(info))]), seq: 3)
        let buckets = try XCTUnwrap(report.dailyBuckets)

        let today = buckets.last!
        XCTAssertEqual(today.totals.input, 80, "权威日总量不受样本裁剪影响")
        XCTAssertTrue(today.totalsComplete)
        XCTAssertFalse(today.modelDetailsComplete, "entries 对不齐日桶时明细完整性必须打假")
        XCTAssertEqual(today.entries.count, 1)
        XCTAssertEqual(today.entries[0].input, 40, "entries 只覆盖留存样本")

        XCTAssertTrue(buckets[buckets.count - 2].modelDetailsComplete, "对齐的天不受同报告其他天牵连")
        XCTAssertTrue(buckets.first!.modelDetailsComplete, "权威零桶 0 == 0 仍然完整")

        let merged = FleetMerger.mergeDailyBuckets([buckets], now: now)
        let mergedToday = try XCTUnwrap(merged.first { $0.dayKey == FleetMerger.dayKey(of: now) })
        XCTAssertFalse(mergedToday.modelDetailsComplete, "标志经合并 AND 传递到 fleet 聚合")
        XCTAssertTrue(FleetUsageProjection.bucketCostText(mergedToday).contains("部分计价"),
                      "下行金额文案因明细不完整带上部分计价标注")
    }

    /// 只有权威日桶、留存样本为 0（如持久化索引只保留日汇总）：entries 为空但
    /// totals > 0——必须标 modelDetailsComplete=false，不得伪装成完整零明细。
    func testDailyTotalsWithoutSamplesReportIncompleteDetails() throws {
        let info = chatGPTQuotaInfo(scannedAt: now, recentSamples: [])
        let report = UsageReportBuilder.build(makeInput([codexStatus(state: .ok(info))]), seq: 7)
        let today = try XCTUnwrap(report.dailyBuckets?.last)
        XCTAssertEqual(today.totals.input, 80, "权威日总量仍在")
        XCTAssertEqual(today.entries.count, 0)
        XCTAssertTrue(today.totalsComplete)
        XCTAssertFalse(today.modelDetailsComplete, "仅日汇总无明细时不宣称完整")
    }

    /// 当某一天的样本被截断（samplesTruncated 标志置位）导致该天明细对不齐时，
    /// 不应污染其他对账一致的天或经过验证的零用量桶（0 == 0）。
    func testTruncatedSamplesOnOneDayDoesNotInvalidateOtherDaysWithVerifiedZeroOrMatchingBuckets() throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart)!

        let todayDaily = DshDailyUsage(
            dayStart: todayStart,
            inputTokens: 200,
            outputTokens: 20,
            totalTokens: 220,
            turns: 1,
            rounds: 2
        )
        let yesterdayDaily = DshDailyUsage(
            dayStart: yesterday,
            inputTokens: 100,
            outputTokens: 10,
            totalTokens: 110,
            turns: 1,
            rounds: 1
        )

        let yesterdaySample = sample(
            at: yesterday.addingTimeInterval(3600), model: "MiniMax-M3",
            input: 100, cached: 0, output: 10, reasoning: 0,
            sourceProviderID: "dsh:minimax-cn"
        )
        // Today's samples only cover 100 of 200 tokens (truncated)
        let todaySample = sample(
            at: todayStart.addingTimeInterval(3600), model: "MiniMax-M3",
            input: 100, cached: 0, output: 10, reasoning: 0,
            sourceProviderID: "dsh:minimax-cn"
        )

        let dshSnapshot = DshLocalUsage(
            byProvider: [
                "minimax-cn": DshProviderUsage(
                    today: todayDaily,
                    dailyTokenUsage: [yesterdayDaily, todayDaily],
                    sessionCount: 2,
                    roundCount: 3,
                    recentSamples: [yesterdaySample, todaySample],
                    recentSamplesTruncated: true
                )
            ],
            modelsByProvider: ["minimax-cn": ["MiniMax-M3"]],
            sessionsRoot: nil,
            sessionCount: 2,
            eventCount: 3,
            scannedAt: now,
            isTruncated: false
        )

        var status = ProviderStatus(
            id: ProviderKind.minimaxTokenPlan.providerID,
            displayName: "MiniMax",
            kind: .minimaxTokenPlan,
            iconSystemName: "circle",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: .ok(QuotaInfo(
                models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: now, balanceDetail: nil
            ))
        )
        status.dshUsage = dshSnapshot

        let report = UsageReportBuilder.build(
            UsageReportInput(
                nodeID: UUID(), nodeName: "Test-Mac",
                bindings: ClientProviderBinding.defaultBindings,
                statuses: [status], now: now, calendar: calendar
            ),
            seq: 1
        )
        let buckets = try XCTUnwrap(report.dailyBuckets)
        XCTAssertEqual(buckets.count, 7)

        let todayBucket = try XCTUnwrap(buckets.last)
        let yesterdayBucket = buckets[buckets.count - 2]
        let zeroBucket = try XCTUnwrap(buckets.first)

        // Today has mismatch (200 daily total vs 100 sample entries)
        XCTAssertEqual(todayBucket.totals.input, 200)
        XCTAssertFalse(todayBucket.modelDetailsComplete, "今天样本被截断且对账不齐，modelDetailsComplete 必须为 false")

        // Yesterday matches (100 daily total vs 100 sample entries)
        XCTAssertEqual(yesterdayBucket.totals.input, 100)
        XCTAssertTrue(yesterdayBucket.modelDetailsComplete, "昨天样本对齐，不受今天样本截断污染")

        // First day has 0 totals and 0 entries
        XCTAssertEqual(zeroBucket.totals.input, 0)
        XCTAssertTrue(zeroBucket.modelDetailsComplete, "零用量天对齐，不受其他天样本截断污染")
    }
}
