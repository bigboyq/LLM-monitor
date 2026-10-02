import XCTest
import Foundation
@testable import LLM_monitor

final class QuotaAllocationTests: XCTestCase {

    func testBindingWindowDecisionBranches() {
        let weeklyDecision = EquivalentQuotaAllocation.bindingWindow(
            primaryFraction: 0.90, weeklyFraction: 0.10, segments: 5
        )
        XCTAssertEqual(weeklyDecision, .weekly)

        let primaryDecision = EquivalentQuotaAllocation.bindingWindow(
            primaryFraction: 0.20, weeklyFraction: 0.10, segments: 5
        )
        XCTAssertEqual(primaryDecision, .primary)
    }

    func testEquivalentQuotaAllocationSegmentFillsBoundaryConditions() {
        // 0% weekly units -> 0 fills
        let zeroFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0, weeklyFraction: 0, segments: 5
        )
        XCTAssertEqual(zeroFills, [0, 0, 0, 0, 0])

        // 100% (weeklyUnits = 5) -> [1, 1, 1, 1, 1]
        let fullFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 1.0, weeklyFraction: 1.0, segments: 5
        )
        XCTAssertEqual(fullFills, [1.0, 1.0, 1.0, 1.0, 1.0])

        // Exact tie (weeklyUnits == normalizedPrimary = 0.5) -> [0.5, 0, 0, 0, 0]
        let tieFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.5, weeklyFraction: 0.1, segments: 5
        )
        XCTAssertEqual(tieFills, [0.5, 0.0, 0.0, 0.0, 0.0])
    }

    // MARK: - segmentFills / bindingWindow 覆盖面（自 LLMMonitorTests 杂项集并入，
    // 与上面的 boundary 用例同属 EquivalentQuotaAllocation 的分配口径）

    /// EquivalentQuotaAllocation.segmentFills 3 in 1：
    /// - weekly < primary*segments → weekly 限死 (binding constraint), primary 切小
    /// - primary + 后续 weekly 占用 2 段以上 → 分离
    /// - 后续段从 primary 紧接 (无 gap)
    func testEquivalentQuotaAllocationSegmentFills() {
        // 1. 周限 < 当前 primary 总量: primary 被切到 weekly 限额, 后续段全 0
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 1, weeklyFraction: 0.08, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertTrue(fills.dropFirst().allSatisfy { $0 == 0 },
                          "weekly=0.08 比 primary 限死 0.8, 后续段全 0")
        }
        // 2. 当前 + 后续 weekly 各占独立段, 不重叠
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 0.8, weeklyFraction: 0.12, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertEqual(fills[1], 0.4, accuracy: 0.000_001)
            XCTAssertTrue(fills.dropFirst(2).allSatisfy { $0 == 0 })
        }
        // 3. weekly 余量足够时, 后续段紧接 primary 满格, 最后一个段 = 剩余 weekly
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 0.8, weeklyFraction: 0.42, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertEqual(Array(fills[1...3]), [1.0, 1.0, 1.0], "后续 3 段 weekly 余量足, 满格")
            XCTAssertEqual(fills[4], 0.4, accuracy: 0.000_001, "最后一段 = 剩余 weekly 比例")
            XCTAssertTrue(fills.dropFirst(5).allSatisfy { $0 == 0 })
        }
    }

    func testEquivalentQuotaAllocationBindingWindowDecisions() {
        // 1. 周额度先耗尽：weeklyFraction * segments < primaryFraction
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 0.80, weeklyFraction: 0.12, segments: 6),
            .weekly
        )

        // 2. 主短周期先耗尽：primaryFraction < weeklyFraction * segments
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 0.08, weeklyFraction: 0.10, segments: 6),
            .primary
        )

        // 3. 并列持平：约定优先主短周期
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 0.60, weeklyFraction: 0.10, segments: 6),
            .primary
        )

        // 4. 边界数值截断与保护
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 1.5, weeklyFraction: 0.10, segments: 6),
            .weekly
        )
    }
}
