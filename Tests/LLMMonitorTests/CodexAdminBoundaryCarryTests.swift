import XCTest
import Foundation
@testable import LLM_monitor

/// 单层修正模型的边界扣除测试：求解器 `solveAdminBoundaryCarry`（纯函数表驱动）、
/// `AdminBoundaryWindowCache` 进程内存缓存，以及 AppState 写回纯函数核心
/// `applyingAdminCarryWriteBacks` 与 SettingsView 定值合并 `mergedCarryAdjust`。
final class CodexAdminBoundaryCarryTests: XCTestCase {

    // MARK: - 求解器（表驱动，纯函数）

    /// 账期锚点：任意固定 epoch（测试全部用相对时间推导）
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
        let expectedCarry: Double
        let expectedApproximate: Bool
        let expectedFixedInCycle: Bool
        let expectedPendingWrite: Double?
        let expectedNewWindowReading: Double?
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
            // ③ 窗口内边界桶缺失：carry 0，不产出写回、不更新缓存
            SolveCase(
                name: "③窗口内桶缺失",
                boundaryTotal: nil, now: inWindowFirst,
                adjust: 0, fixedAt: nil, cachedWindowReading: nil,
                expectedCarry: 0, expectedApproximate: false,
                expectedFixedInCycle: false, expectedPendingWrite: nil,
                expectedNewWindowReading: nil
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
        ]

        for testCase in cases {
            let result = OpenAIApiCreditDetails.solveAdminBoundaryCarry(
                boundaryTotal: testCase.boundaryTotal,
                cycleStart: anchor,
                cycleEnd: cycleEnd,
                now: testCase.now,
                adjust: testCase.adjust,
                fixedAt: testCase.fixedAt,
                cachedWindowReading: testCase.cachedWindowReading
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
