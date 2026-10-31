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

    func testFractionalMultiplier3Point33Allocation() {
        // 1. 容量分段：3.33 拆为 3 个 1.0 整段与 1 个 0.33 尾段
        let capacities = EquivalentQuotaAllocation.segmentCapacities(multiplier: 3.33)
        XCTAssertEqual(capacities.count, 4)
        XCTAssertEqual(capacities[0], 1.0)
        XCTAssertEqual(capacities[1], 1.0)
        XCTAssertEqual(capacities[2], 1.0)
        XCTAssertEqual(capacities[3], 0.33, accuracy: 0.0001)

        // 2. 实测数据场景：5h 使用 4.48 剩 85%，周使用 39.77 剩 60.3%
        // weeklyUnits = 0.603 * 3.33 ≈ 2.00799
        // 5h 剩余 0.85 < 2.008 → 5h 为瓶颈，无周告急
        let fills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.85,
            weeklyFraction: 0.603,
            multiplier: 3.33
        )
        XCTAssertEqual(fills.count, 4)
        XCTAssertEqual(fills[0], 0.85, accuracy: 0.0001, "当前 5h 窗口充满 85%")
        XCTAssertEqual(fills[1], 1.0, accuracy: 0.0001, "后续第 1 段满额")
        // 剩余 = 2.00799 - 0.85 - 1.0 = 0.15799
        XCTAssertEqual(fills[2], 0.15799, accuracy: 0.001, "后续第 2 段填入 0.158")
        XCTAssertEqual(fills[3], 0.0, accuracy: 0.0001, "尾段无额度")

        // 3. 瓶颈判定：当前 5h 为约束瓶颈
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 0.85, weeklyFraction: 0.603, multiplier: 3.33),
            .primary
        )

        // 4. 周瓶颈场景：5h 85%、周只剩 15% (0.15 * 3.33 ≈ 0.4995 < 0.85)
        XCTAssertEqual(
            EquivalentQuotaAllocation.bindingWindow(primaryFraction: 0.85, weeklyFraction: 0.15, multiplier: 3.33),
            .weekly
        )
        let bindingFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.85,
            weeklyFraction: 0.15,
            multiplier: 3.33
        )
        XCTAssertEqual(bindingFills.count, 4)
        XCTAssertEqual(bindingFills[0], 0.4995, accuracy: 0.001, "5h 被周限死在 ~50%")
        XCTAssertEqual(bindingFills[1], 0.0)
        XCTAssertEqual(bindingFills[2], 0.0)
        XCTAssertEqual(bindingFills[3], 0.0)

        // 5. Tooltip 文案测试：包含 3.33 倍说明
        let tooltip = QuotaBarTooltip.text(multiplier: 3.33, hasTriangle: true)
        XCTAssertTrue(tooltip.contains("3.33"))
        XCTAssertTrue(tooltip.contains("▼"))
    }

    func testAntigravityGeminiMultiplier4Point0Allocation() {
        // 1. 容量分段：4.0 拆为 4 个 1.0 等宽整段，无余数段
        let capacities = EquivalentQuotaAllocation.segmentCapacities(multiplier: 4.0)
        XCTAssertEqual(capacities.count, 4)
        XCTAssertEqual(capacities, [1.0, 1.0, 1.0, 1.0])

        // 2. 栅格分配：4 段每段分配 25 格，合计精确 100 格
        let ticks = capacities.map {
            SegmentedQuotaProgressBar.ticksForSegment(
                capacity: $0,
                totalCapacity: 4.0,
                segmentCount: capacities.count
            )
        }
        XCTAssertEqual(ticks, [25, 25, 25, 25])
        XCTAssertEqual(ticks.reduce(0, +), 100)

        // 3. 额度分配与分段充满测试
        let fills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.8,
            weeklyFraction: 0.5,
            multiplier: 4.0
        )
        XCTAssertEqual(fills.count, 4)
        XCTAssertEqual(fills[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(fills[1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(fills[2], 0.2, accuracy: 0.0001)
        XCTAssertEqual(fills[3], 0.0, accuracy: 0.0001)
    }
}
