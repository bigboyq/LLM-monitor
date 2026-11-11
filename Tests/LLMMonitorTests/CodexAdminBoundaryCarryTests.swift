import XCTest
import Foundation
@testable import LLM_monitor

/// 单层修正模型的边界扣除测试：求解器 `solveAdminBoundaryCarry`（纯函数表驱动）、
/// `AdminBoundaryWindowCache` 进程内存缓存，以及 AppState 写回纯函数核心
/// `applyingAdminCarryWriteBacks` 与 SettingsView 定值合并 `mergedCarryAdjust`。
final class CodexAdminBoundaryCarryTests: StateTestCase {

    // MARK: - 求解器（表驱动，纯函数）

    /// 账期锚点：任意固定非 UTC 00:00 epoch（1_762_800_000 % 86400 == 67200 != 0，测试全部用相对时间推导）
    private let anchor = Date(timeIntervalSince1970: 1_762_800_000)
    /// 账期结束：锚点 + 30 天
    private var cycleEnd: Date { anchor.addingTimeInterval(30 * 86400) }

    private struct SolveCase {
        let name: String
        let boundaryTotal: Double?
        let now: Date
        let adjust: Double
        let fixedAt: Date?
        let cachedWindowReading: Double?
        let hasBoundaryOverlap: Bool
        let expectedCarry: Double
        let expectedApproximate: Bool
        let expectedFixedInCycle: Bool
        let expectedPendingWrite: Double?
        let expectedNewWindowReading: Double?

        init(
            name: String,
            boundaryTotal: Double?,
            now: Date,
            adjust: Double,
            fixedAt: Date?,
            cachedWindowReading: Double?,
            hasBoundaryOverlap: Bool = true,
            expectedCarry: Double,
            expectedApproximate: Bool,
            expectedFixedInCycle: Bool,
            expectedPendingWrite: Double?,
            expectedNewWindowReading: Double?
        ) {
            self.name = name
            self.boundaryTotal = boundaryTotal
            self.now = now
            self.adjust = adjust
            self.fixedAt = fixedAt
            self.cachedWindowReading = cachedWindowReading
            self.hasBoundaryOverlap = hasBoundaryOverlap
            self.expectedCarry = expectedCarry
            self.expectedApproximate = expectedApproximate
            self.expectedFixedInCycle = expectedFixedInCycle
            self.expectedPendingWrite = expectedPendingWrite
            self.expectedNewWindowReading = expectedNewWindowReading
        }
    }

    func testSolveTableDriven() {
        let inWindowFirst = anchor.addingTimeInterval(600)
        let afterWindow = anchor.addingTimeInterval(7200)

        let cases: [SolveCase] = [
            // ① 窗口内首采：carry = 边界桶读数，approximate=false，不产出写回，
            //    读数经 newWindowReading 进内存缓存
            SolveCase(
                name: "①窗口内首采",
                boundaryTotal: 5.0, now: inWindowFirst,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 5.0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: 5.0
            ),
            // ①b 锚点之前的读数也属精准窗口（now ≤ cycleStart + 3600）
            SolveCase(
                name: "①b锚点之前的读数",
                boundaryTotal: 2.0, now: anchor.addingTimeInterval(-300),
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 2.0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: 2.0
            ),
            // ② 已定值（fixedAt 在当前账期内）：carry = adjust，自动机制完全失效
            SolveCase(
                name: "②已定值短路",
                boundaryTotal: 9.9, now: afterWindow,
                adjust: 6.6, fixedAt: anchor.addingTimeInterval(3600),
                cachedWindowReading: 3.3,
                expectedCarry: 6.6, expectedApproximate: false,
                expectedFixedInCycle: true, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
            ),
            // ②b fixedAt 属上一账期 → 不算定值，走窗口逻辑（无缓存 → 估算写回）
            SolveCase(
                name: "②b旧账期fixedAt不算定值",
                boundaryTotal: 4.0, now: afterWindow,
                adjust: 99.0, fixedAt: anchor.addingTimeInterval(-60),
                cachedWindowReading: nil,
                expectedCarry: 4.0, expectedApproximate: true,
                expectedFixedInCycle: false, expectedPendingWrite: 4.0,
                expectedNewWindowReading: nil
            ),
            // ③ 窗口内边界桶缺失（OpenAI 对 $0 日省略桶）：carry 0，缓存记录 0.0 防止窗口后 Day-1 用量反咬成估算
            SolveCase(
                name: "③窗口内桶缺失记0.0缓存",
                boundaryTotal: nil, now: inWindowFirst,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: 0.0
            ),
            // ④ 窗口已过 + 缓存命中：窗口内的最后读数 → 精确写回（approximate=false）
            SolveCase(
                name: "④缓存命中→精确写回",
                boundaryTotal: 9.9, now: afterWindow,
                adjust: 0, fixedAt: nil, cachedWindowReading: 5.5,
                expectedCarry: 5.5, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: 5.5,
                expectedNewWindowReading: nil
            ),
            // ④b 窗口已过 + 缓存命中 0.0：即使 Day-1 新产生用量 3.5，精确写回 0.0（不误估算）
            SolveCase(
                name: "④b缓存0.0→窗口后精确写回0.0",
                boundaryTotal: 3.5, now: afterWindow,
                adjust: 0, fixedAt: nil, cachedWindowReading: 0.0,
                expectedCarry: 0.0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: 0.0,
                expectedNewWindowReading: nil
            ),
            // ⑤ 窗口已过 + 无缓存：边界桶当前全额 → 估算写回（approximate=true）
            SolveCase(
                name: "⑤无缓存→估算写回",
                boundaryTotal: 7.7, now: afterWindow,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 7.7, expectedApproximate: true,
                expectedFixedInCycle: false, expectedPendingWrite: 7.7,
                expectedNewWindowReading: nil
            ),
            // ⑥ 窗口已过 + 边界桶缺失：carry 0，不写回
            SolveCase(
                name: "⑥窗口后桶缺失",
                boundaryTotal: nil, now: afterWindow,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
            ),
            // ⑦ 无边界重叠（UTC 00:00）窗口内：不缓存不写回不扣除
            SolveCase(
                name: "⑦无边界重叠窗口内不缓存",
                boundaryTotal: 5.0, now: inWindowFirst,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                hasBoundaryOverlap: false,
                expectedCarry: 0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
            ),
            // ⑧ 无边界重叠（UTC 00:00）窗口后：不估算不写回
            SolveCase(
                name: "⑧无边界重叠窗口后不写回",
                boundaryTotal: 5.0, now: afterWindow,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                hasBoundaryOverlap: false,
                expectedCarry: 0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
            ),
            // ⑨ 无边界重叠（UTC 00:00）但手动定值在当前账期内：仍生效
            SolveCase(
                name: "⑨无边界重叠手动定值仍生效",
                boundaryTotal: 5.0, now: afterWindow,
                adjust: 2.5, fixedAt: anchor.addingTimeInterval(600), cachedWindowReading: nil,
                hasBoundaryOverlap: false,
                expectedCarry: 2.5, expectedApproximate: false,
                expectedFixedInCycle: true, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
            ),
        ]

        for testCase in cases {
            let result = OpenAIApiCreditDetails.solveAdminBoundaryCarry(
                boundaryTotal: testCase.boundaryTotal,
                cycleStart: anchor,
                cycleEnd: cycleEnd,
                now: testCase.now,
                adjust: testCase.adjust,
                fixedAt: testCase.fixedAt,
                cachedWindowReading: testCase.cachedWindowReading,
                hasBoundaryOverlap: testCase.hasBoundaryOverlap
            )
            XCTAssertEqual(result.carry, testCase.expectedCarry, accuracy: 0.0001, "\(testCase.name): carry")
            XCTAssertEqual(result.approximate, testCase.expectedApproximate, "\(testCase.name): approximate")
            XCTAssertEqual(result.fixedInCycle, testCase.expectedFixedInCycle, "\(testCase.name): fixedInCycle")
            XCTAssertEqual(result.pendingWrite, testCase.expectedPendingWrite, "\(testCase.name): pendingWrite")
            XCTAssertEqual(result.newWindowReading, testCase.expectedNewWindowReading, "\(testCase.name): newWindowReading")
        }
    }

    /// 定值区间左闭右开：fixedAt == cycleStart 算定值；fixedAt == cycleEnd 不算
    func testSolveFixedAtBoundaries() {
        let resultAtStart = OpenAIApiCreditDetails.solveAdminBoundaryCarry(
            boundaryTotal: 5.0, cycleStart: anchor, cycleEnd: cycleEnd,
            now: anchor.addingTimeInterval(600), adjust: 3.0,
            fixedAt: anchor, cachedWindowReading: nil
        )
        XCTAssertTrue(resultAtStart.fixedInCycle, "fixedAt == cycleStart 属当前账期")
        XCTAssertEqual(resultAtStart.carry, 3.0, accuracy: 0.0001)

        let resultAtEnd = OpenAIApiCreditDetails.solveAdminBoundaryCarry(
            boundaryTotal: 5.0, cycleStart: anchor, cycleEnd: cycleEnd,
            now: anchor.addingTimeInterval(600), adjust: 3.0,
            fixedAt: cycleEnd, cachedWindowReading: nil
        )
        XCTAssertFalse(resultAtEnd.fixedInCycle, "fixedAt == cycleEnd 不属当前账期（左闭右开）")
        XCTAssertEqual(resultAtEnd.carry, 5.0, accuracy: 0.0001)
    }

    // MARK: - AdminBoundaryWindowCache（进程内存缓存）

    func testWindowCacheUpdateReadAndPrune() {
        // 随机 keyId：缓存的进程级 static，避免与其他用例互相污染
        let keyId = "cache-test-\(UUID().uuidString.prefix(8))"
        let epochA: Int64 = 1_000
        let epochB: Int64 = 2_000

        XCTAssertNil(AdminBoundaryWindowCache.reading(keyId: keyId, cycleStartEpoch: epochA))

        AdminBoundaryWindowCache.update(keyId: keyId, cycleStartEpoch: epochA, value: 5.0)
        XCTAssertEqual(AdminBoundaryWindowCache.reading(keyId: keyId, cycleStartEpoch: epochA) ?? 0, 5.0, accuracy: 0.0001)

        // 窗口内覆盖刷新：同 key 最新读数替换旧读数
        AdminBoundaryWindowCache.update(keyId: keyId, cycleStartEpoch: epochA, value: 6.1)
        XCTAssertEqual(AdminBoundaryWindowCache.reading(keyId: keyId, cycleStartEpoch: epochA) ?? 0, 6.1, accuracy: 0.0001)

        // 周期切换：写入新周期后旧周期条目被清理（每 key 只留最新一条）
        AdminBoundaryWindowCache.update(keyId: keyId, cycleStartEpoch: epochB, value: 2.0)
        XCTAssertEqual(AdminBoundaryWindowCache.reading(keyId: keyId, cycleStartEpoch: epochB) ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertNil(AdminBoundaryWindowCache.reading(keyId: keyId, cycleStartEpoch: epochA))
    }

    // MARK: - AppState 写回纯函数核心

    /// 未定值的 key：pendingWrite 写入 adjust + fixedAt；已定值 / 值已相同 / config 无此 key 的跳过
    func testApplyingCarryWriteBacksOnlyUnfixedKeys() throws {
        let providerID = ProviderKind.codexChatGpt.providerID
        let writeStamp = anchor.addingTimeInterval(7200)
        var config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        var provider = ProviderConfig(enabled: true)
        provider.adminApiKeys = [
            // 未定值 → 应写回
            CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 0),
            // 已定值（本账期内）→ 跳过
            CodexAdminKeyConfig(id: "k2", apiKey: "sk-admin-2", usedAmountAdjust: 1.0, usedAmountAdjustFixedAt: anchor.addingTimeInterval(60)),
            // 值相同且已带定值时间戳 → 完全 no-op
            CodexAdminKeyConfig(id: "k3", apiKey: "sk-admin-3", usedAmountAdjust: 5.5, usedAmountAdjustFixedAt: anchor.addingTimeInterval(60))
        ]
        config.providers[providerID] = provider

        func pendingCredits(keyId: String, value: Double?) -> OpenAIApiCreditDetails {
            OpenAIApiCreditDetails(
                organizationName: nil, totalQuota: 40, usedAmount: 1,
                cycleStart: anchor, cycleEnd: cycleEnd,
                keyId: keyId, carryPendingWriteValue: value
            )
        }
        let creditsList = [
            pendingCredits(keyId: "k1", value: 5.5),
            pendingCredits(keyId: "k2", value: 9.9),
            pendingCredits(keyId: "k3", value: 5.5),
            pendingCredits(keyId: "k4", value: 7.7)  // config 无此 key → 忽略
        ]

        let (updated, changedKeys) = AppState.applyingAdminCarryWriteBacks(
            creditsList, providerID: providerID, to: config, fixedAt: writeStamp
        )
        XCTAssertEqual(changedKeys, ["k1"], "只有未定值且值有变化的 key 被写回")

        let keys = try XCTUnwrap(updated.providers[providerID]?.adminApiKeys)
        XCTAssertEqual(keys[0].usedAmountAdjust, 5.5, accuracy: 0.0001)
        XCTAssertEqual(keys[0].usedAmountAdjustFixedAt, writeStamp)
        XCTAssertEqual(keys[1].usedAmountAdjust, 1.0, accuracy: 0.0001, "已定值的 key 不被写回覆盖")
        XCTAssertEqual(keys[2].usedAmountAdjustFixedAt, anchor.addingTimeInterval(60), "值相同的 key 保持原定值时间戳")
    }

    /// 无 pendingWrite（全 nil）或 provider 不在 config → 原样返回、零写回
    func testApplyingCarryWriteBacksNoOpCases() {
        let providerID = ProviderKind.codexChatGpt.providerID
        let config = AppConfig(refreshIntervalSeconds: 300, providers: [:])

        let noPending = OpenAIApiCreditDetails(
            organizationName: nil, totalQuota: 40, usedAmount: 1,
            cycleStart: anchor, cycleEnd: cycleEnd,
            keyId: "k1", carryPendingWriteValue: nil
        )
        let (unchanged, noKeys) = AppState.applyingAdminCarryWriteBacks(
            [noPending], providerID: providerID, to: config, fixedAt: anchor
        )
        XCTAssertTrue(noKeys.isEmpty)
        XCTAssertEqual(unchanged, config)

        let pendingOnly = OpenAIApiCreditDetails(
            organizationName: nil, totalQuota: 40, usedAmount: 1,
            cycleStart: anchor, cycleEnd: cycleEnd,
            keyId: "k1", carryPendingWriteValue: 3.0
        )
        let (stillUnchanged, stillNoKeys) = AppState.applyingAdminCarryWriteBacks(
            [pendingOnly], providerID: providerID, to: config, fixedAt: anchor
        )
        XCTAssertTrue(stillNoKeys.isEmpty, "provider 不在 config → 忽略")
        XCTAssertEqual(stillUnchanged, config)
    }

    /// [H1] 跨账期值相同时（如上周期与本周期均为 0.0）不得跳过写回：必须重盖本账期的 fixedAt
    func testApplyingCarryWriteBacksStampsNewFixedAtAcrossCyclesEvenWhenValueMatches() throws {
        let providerID = ProviderKind.codexChatGpt.providerID
        let priorStamp = anchor.addingTimeInterval(-86_400)
        let writeStamp = anchor.addingTimeInterval(7_200)

        var config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        var provider = ProviderConfig(enabled: true)
        provider.adminApiKeys = [
            CodexAdminKeyConfig(id: "k-zero", apiKey: "sk-admin-0", usedAmountAdjust: 0.0, usedAmountAdjustFixedAt: priorStamp),
            CodexAdminKeyConfig(id: "k-same", apiKey: "sk-admin-1", usedAmountAdjust: 5.0, usedAmountAdjustFixedAt: priorStamp)
        ]
        config.providers[providerID] = provider

        let creditsList = [
            OpenAIApiCreditDetails(
                organizationName: nil, totalQuota: 40, usedAmount: 1,
                cycleStart: anchor, cycleEnd: cycleEnd,
                keyId: "k-zero", carryPendingWriteValue: 0.0
            ),
            OpenAIApiCreditDetails(
                organizationName: nil, totalQuota: 40, usedAmount: 1,
                cycleStart: anchor, cycleEnd: cycleEnd,
                keyId: "k-same", carryPendingWriteValue: 5.0
            )
        ]

        let (updated, changedKeys) = AppState.applyingAdminCarryWriteBacks(
            creditsList, providerID: providerID, to: config, fixedAt: writeStamp
        )
        XCTAssertEqual(changedKeys, ["k-zero", "k-same"])

        let keys = try XCTUnwrap(updated.providers[providerID]?.adminApiKeys)
        XCTAssertEqual(keys[0].usedAmountAdjust, 0.0, accuracy: 0.0001)
        XCTAssertEqual(keys[0].usedAmountAdjustFixedAt, writeStamp)
        XCTAssertEqual(keys[1].usedAmountAdjust, 5.0, accuracy: 0.0001)
        XCTAssertEqual(keys[1].usedAmountAdjustFixedAt, writeStamp)
    }

    /// [H1] 跨越 cycleEnd 边界才完成的请求不得把旧周期扣除定值写进新周期
    func testApplyingCarryWriteBacksSkipsOutOfCycleFixedAt() {
        let providerID = ProviderKind.codexChatGpt.providerID
        var config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        var provider = ProviderConfig(enabled: true)
        provider.adminApiKeys = [
            CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 0.0)
        ]
        config.providers[providerID] = provider

        let pending = OpenAIApiCreditDetails(
            organizationName: nil, totalQuota: 40, usedAmount: 1,
            cycleStart: anchor, cycleEnd: cycleEnd,
            keyId: "k1", carryPendingWriteValue: 4.5
        )

        let (atEndConfig, atEndKeys) = AppState.applyingAdminCarryWriteBacks(
            [pending], providerID: providerID, to: config, fixedAt: cycleEnd
        )
        XCTAssertTrue(atEndKeys.isEmpty, "fixedAt == cycleEnd 属下一账期，不得写回")
        XCTAssertEqual(atEndConfig, config)

        let (beforeStartConfig, beforeStartKeys) = AppState.applyingAdminCarryWriteBacks(
            [pending], providerID: providerID, to: config, fixedAt: anchor.addingTimeInterval(-1)
        )
        XCTAssertTrue(beforeStartKeys.isEmpty, "fixedAt < cycleStart 不属当前账期，不得写回")
        XCTAssertEqual(beforeStartConfig, config)
    }

    /// [M6] 历史标量 adminApiKey 回退模式：写回时按 effectiveAdminKeys 物化 `"default"` 条目并保留标量字段
    func testApplyingCarryWriteBacksMaterializesLegacyScalarAdminKey() throws {
        let providerID = ProviderKind.codexChatGpt.providerID
        let writeStamp = anchor.addingTimeInterval(7_200)
        var config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        config.providers[providerID] = ProviderConfig(
            enabled: true,
            adminApiCreditsEnabled: true,
            adminApiKey: "sk-admin-legacy",
            adminBillingDay: 15,
            adminBillingTime: "09:30",
            adminMonthlyQuotaLimit: 60.0,
            adminApiKeys: nil
        )

        let pending = OpenAIApiCreditDetails(
            organizationName: nil, totalQuota: 60, usedAmount: 2,
            cycleStart: anchor, cycleEnd: cycleEnd,
            keyId: "default", carryPendingWriteValue: 3.25
        )

        let (updated, changedKeys) = AppState.applyingAdminCarryWriteBacks(
            [pending], providerID: providerID, to: config, fixedAt: writeStamp
        )
        XCTAssertEqual(changedKeys, ["default"])

        let updatedProvider = try XCTUnwrap(updated.providers[providerID])
        XCTAssertEqual(updatedProvider.adminApiKey, "sk-admin-legacy")
        XCTAssertEqual(updatedProvider.adminBillingDay, 15)
        XCTAssertEqual(updatedProvider.adminBillingTime, "09:30")
        XCTAssertEqual(updatedProvider.adminMonthlyQuotaLimit, 60.0)

        let keys = try XCTUnwrap(updatedProvider.adminApiKeys)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].id, "default")
        XCTAssertEqual(keys[0].apiKey, "sk-admin-legacy")
        XCTAssertEqual(keys[0].billingDay, 15)
        XCTAssertEqual(keys[0].billingTime, "09:30")
        XCTAssertEqual(keys[0].monthlyQuotaLimit, 60.0)
        XCTAssertEqual(keys[0].usedAmountAdjust, 3.25, accuracy: 0.0001)
        XCTAssertEqual(keys[0].usedAmountAdjustFixedAt, writeStamp)

        // 空数组 [] 回退模式也应物化；无 pendingWrite 时不主动改写 adminApiKeys
        var emptyArrayConfig = config
        emptyArrayConfig.providers[providerID]?.adminApiKeys = []
        let (emptyUpdated, emptyChanged) = AppState.applyingAdminCarryWriteBacks(
            [pending], providerID: providerID, to: emptyArrayConfig, fixedAt: writeStamp
        )
        XCTAssertEqual(emptyChanged, ["default"])
        XCTAssertEqual(emptyUpdated.providers[providerID]?.adminApiKeys?.first?.usedAmountAdjust, 3.25)

        let noPending = OpenAIApiCreditDetails(
            organizationName: nil, totalQuota: 60, usedAmount: 2,
            cycleStart: anchor, cycleEnd: cycleEnd,
            keyId: "default", carryPendingWriteValue: nil
        )
        let (noOpConfig, noOpChanged) = AppState.applyingAdminCarryWriteBacks(
            [noPending], providerID: providerID, to: config, fixedAt: writeStamp
        )
        XCTAssertTrue(noOpChanged.isEmpty)
        XCTAssertNil(noOpConfig.providers[providerID]?.adminApiKeys)
    }

    /// [Minor] 启动清理历史遗留 admin-credit-carry.json 应派生自 configStore.configURL 所在目录
    @MainActor
    func testAppStateInitRemovesLegacyCarryFileInConfigDirectory() throws {
        let store = makeIsolatedConfigStore()
        let legacyFile = store.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("admin-credit-carry.json")
        try Data("{}".utf8).write(to: legacyFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))

        let state = AppState(descriptors: [], configStore: store)
        state.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    /// [H3] Codex 静默写回 admin carry 不得递增 configurationGeneration / 重建状态，
    /// 并发中的兄弟 provider 刷新不得被丢弃为 `.deferred`；而外部真实配置变更仍正常重建并丢弃旧请求。
    @MainActor
    func testRefreshAllDoesNotDeferSiblingWhenCodexTriggersAdminCarryWriteBack() async throws {
        let codexID = ProviderKind.codexChatGpt.providerID
        let siblingID = ProviderKind.deepseek.providerID

        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        config.providers[codexID] = ProviderConfig(
            enabled: true,
            adminApiCreditsEnabled: true,
            adminApiKeys: [CodexAdminKeyConfig(id: "k1", apiKey: "sk-admin-1", usedAmountAdjust: 0)]
        )
        config.providers[siblingID] = ProviderConfig(
            enabled: true,
            apiKey: "sk-sibling-test"
        )
        try store.applyAndSave(config)

        let now = Date()
        let codexStub = CarryWriteBackCodexStub(
            providerID: codexID,
            cycleStart: now.addingTimeInterval(-7200),
            cycleEnd: now.addingTimeInterval(25 * 86_400)
        )
        let siblingStub = GatedSiblingStub(providerID: siblingID)

        let descriptors = [
            FetcherDescriptor(
                id: codexID, displayName: "ChatGPT Plan", kind: .codexChatGpt,
                iconSystemName: "sparkles", accentColor: .chatgpt,
                makeFetcher: { _ in codexStub }
            ),
            FetcherDescriptor(
                id: siblingID, displayName: "DeepSeek", kind: .deepseek,
                iconSystemName: "brain", accentColor: .deepseek,
                makeFetcher: { _ in siblingStub }
            )
        ]

        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        let scheduler = state.refreshScheduler!
        // 等待 codex（错峰 0s）首拍结算并确保当前无全局事务在途
        let settled = await waitUntil {
            (scheduler.nextRefreshDate(for: codexID) ?? .distantPast) > Date() && !state.isRefreshJobActive
        }
        XCTAssertTrue(settled, "前提失败：codex 首拍未按期结算")
        // 把 sibling 的 2s 错峰推到远期，避免干扰接下来的 refreshAll
        scheduler.reanchorProvider(siblingID, at: Date(), resetDatesByProvider: [:])

        let siblingFirstDate = Date(timeIntervalSince1970: 1_900_000_100)
        let gate1 = TestAsyncGate()
        await codexStub.setPendingCarry(5.5)
        await siblingStub.arm(gate: gate1, fetchedAt: siblingFirstDate)

        let refreshTask = Task { await state.refreshAll() }

        let wroteCarry = await waitUntil {
            store.config.providers[codexID]?.adminApiKeys?.first?.usedAmountAdjustFixedAt != nil
        }
        XCTAssertTrue(wroteCarry, "codex 应完成 admin carry 写回")
        // 让 RunLoop.main 排空 Combine $config 推送；旧实现会在此处 bump generation 并丢弃 sibling
        try? await Task.sleep(nanoseconds: 50_000_000)

        await gate1.release()
        await refreshTask.value

        XCTAssertEqual(store.config.providers[codexID]?.adminApiKeys?.first?.usedAmountAdjust ?? -1, 5.5, accuracy: 0.0001)
        let siblingStatus = state.statuses.first(where: { $0.id == siblingID })
        XCTAssertEqual(
            siblingStatus?.lastSuccess?.fetchedAt, siblingFirstDate,
            "Codex 静默写回 carry 不得递增 configurationGeneration 或丢弃并发兄弟刷新"
        )

        // 反向验证：外部配置变更（如刷新间隔改变）仍必须递增 generation 并丢弃在途旧请求
        let siblingStaleDate = Date(timeIntervalSince1970: 1_900_000_200)
        let gate2 = TestAsyncGate()
        await siblingStub.arm(gate: gate2, fetchedAt: siblingStaleDate)

        let secondTask = Task { await state.refreshAll() }
        await gate2.waitUntilReached()

        var external = store.config
        external.refreshIntervalSeconds = 180
        try store.applyAndSave(external)

        let rebuilt = await waitUntil {
            state.statuses.first(where: { $0.id == siblingID })?.refreshIntervalSeconds == 180
        }
        XCTAssertTrue(rebuilt, "外部真实配置变更必须触发 rebuildStatuses")

        await gate2.release()
        await secondTask.value

        XCTAssertEqual(
            state.statuses.first(where: { $0.id == siblingID })?.lastSuccess?.fetchedAt,
            siblingFirstDate,
            "外部真实配置变更后在途旧请求应被丢弃，不得覆盖新配置状态"
        )
    }

    // MARK: - SettingsView 定值合并

    @MainActor
    func testMergedCarryAdjustBranches() {
        let stamp = anchor.addingTimeInterval(60)
        let now = anchor.addingTimeInterval(7200)

        // 用户没动 → 采用 config 现值（adjust + fixedAt 原样，含自动写回）
        let untouched = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(id: "k1", apiKey: "k", usedAmountAdjust: 5.0),
            adjustText: "5", initialAdjustText: "5",
            existing: CodexAdminKeyConfig(id: "k1", apiKey: "k", usedAmountAdjust: 5.5, usedAmountAdjustFixedAt: stamp),
            now: now
        )
        XCTAssertEqual(untouched.usedAmountAdjust, 5.5, accuracy: 0.0001)
        XCTAssertEqual(untouched.usedAmountAdjustFixedAt, stamp)

        // 用户改了 → adjust 用草稿值、定值为本拍
        let edited = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(id: "k1", apiKey: "k", usedAmountAdjust: 6.0),
            adjustText: "6", initialAdjustText: "5",
            existing: CodexAdminKeyConfig(id: "k1", apiKey: "k", usedAmountAdjust: 5.5, usedAmountAdjustFixedAt: stamp),
            now: now
        )
        XCTAssertEqual(edited.usedAmountAdjust, 6.0, accuracy: 0.0001)
        XCTAssertEqual(edited.usedAmountAdjustFixedAt, now)

        // 新增 key（config 无现值）且没动 → 维持草稿产出，未定值（交给自动机制）
        let freshUntouched = SettingsView.mergedCarryAdjust(
            drafted: CodexAdminKeyConfig(id: "k2", apiKey: "k", usedAmountAdjust: 0),
            adjustText: "0", initialAdjustText: "0",
            existing: nil,
            now: now
        )
        XCTAssertEqual(freshUntouched.usedAmountAdjust, 0, accuracy: 0.0001)
        XCTAssertNil(freshUntouched.usedAmountAdjustFixedAt)
    }
}

private actor CarryWriteBackCodexStubState {
    var pendingCarry: Double?

    func setPendingCarry(_ value: Double?) {
        pendingCarry = value
    }
}

private struct CarryWriteBackCodexStub: QuotaFetcher {
    let providerID: String
    let displayName = "ChatGPT Plan"
    let kind: ProviderKind = .codexChatGpt
    let cycleStart: Date
    let cycleEnd: Date
    private let state = CarryWriteBackCodexStubState()

    func setPendingCarry(_ value: Double?) async {
        await state.setPendingCarry(value)
    }

    func hasLocalAuth() -> Bool { true }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let pending = await state.pendingCarry
        let credit = OpenAIApiCreditDetails(
            organizationName: "Personal",
            totalQuota: 40,
            usedAmount: 1.0,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            fetchedAt: Date(),
            lastAttemptFailed: false,
            keyId: "k1",
            carryDeduction: pending ?? 0,
            carryApproximate: pending != nil,
            carryFixedInCycle: false,
            carryPendingWriteValue: pending
        )
        return QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Plus",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            openAIApiCredits: credit,
            openAIApiCreditsList: [credit]
        )
    }
}

private actor GatedSiblingStubState {
    var gate: TestAsyncGate?
    var fetchedAt = Date()

    func arm(gate: TestAsyncGate?, fetchedAt: Date) {
        self.gate = gate
        self.fetchedAt = fetchedAt
    }

    func takeGateAndDate() -> (TestAsyncGate?, Date) {
        let currentGate = gate
        gate = nil
        return (currentGate, fetchedAt)
    }
}

private struct GatedSiblingStub: QuotaFetcher {
    let providerID: String
    let displayName = "DeepSeek"
    let kind: ProviderKind = .deepseek
    private let state = GatedSiblingStubState()

    func arm(gate: TestAsyncGate?, fetchedAt: Date) async {
        await state.arm(gate: gate, fetchedAt: fetchedAt)
    }

    func hasLocalAuth() -> Bool { true }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let (gate, date) = await state.takeGateAndDate()
        if let gate {
            await gate.hold()
        }
        return QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: date
        )
    }
}
