import XCTest
@testable import LLM_monitor

/// 报告构建：七日日桶、权威 totals、模型明细（同样本计价）、额度通道门控、
/// 窗口行真实边界、扫描中省略日桶（§6.3 / §11）。
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
        input: Int = 100, cached: Int = 60, output: Int = 50, reasoning: Int = 20
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: "s-\(date.timeIntervalSince1970)",
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: nil
        )
    }

    private func chatGPTQuotaInfo(scannedAt: Date) -> QuotaInfo {
        let todayStart = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayStart)!
        // 日聚合与 recentSamples 保持一致（inputTokens 是 cache-inclusive 总输入），
        // 让内核的「当日 max 修补」不改变结果，断言只落在构建逻辑上。
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
                recentSamples: [
                    sample(at: now.addingTimeInterval(-60)),
                    sample(at: now.addingTimeInterval(-3600)),
                    sample(at: yesterday.addingTimeInterval(3600), input: 10, cached: 0, output: 5, reasoning: 0),
                ],
                scannedAt: scannedAt
            ),
            fetchedAt: now,
            balanceDetail: nil
        )
    }

    private func makeInput(_ statuses: [ProviderStatus]) -> UsageReportInput {
        UsageReportInput(
            identity: NodeIdentity(nodeID: UUID(), lastIssuedSeq: 0),
            nodeName: "Test-Mac",
            bindings: ClientProviderBinding.defaultBindings,
            statuses: statuses,
            now: now
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

        let yesterday = buckets[buckets.count - 2]
        XCTAssertEqual(yesterday.totals.input, 10)
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

    func testBuildOmitsDailyChannelWhileScanning() {
        var status = codexStatus(state: .ok(chatGPTQuotaInfo(scannedAt: now)))
        status.isScanningLocalUsage = true
        let report = UsageReportBuilder.build(makeInput([status]), seq: 1)
        XCTAssertNil(report.dailyBuckets, "reconcile 跑动中不宣称权威日总量（§6.3）")
        XCTAssertNotNil(report.windowUsage, "窗口/额度通道不受影响")
        XCTAssertNotNil(report.quotas)
    }
}
