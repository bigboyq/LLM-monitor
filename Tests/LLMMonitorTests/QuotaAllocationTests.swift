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
}
