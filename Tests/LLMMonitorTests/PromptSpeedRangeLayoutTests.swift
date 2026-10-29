import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

final class PromptSpeedRangeLayoutTests: XCTestCase {
    func testSharedDomainMapsEndpointsAndInterpolates() {
        let sharedRange = 10.0...210.0

        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 10, scaleRange: sharedRange, width: 240), 0)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 50, scaleRange: sharedRange, width: 240), 48)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 210, scaleRange: sharedRange, width: 240), 240)
    }

    func testZeroIsAValidSharedEndpointAndDegenerateDomainCentersMarkers() {
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 0, scaleRange: 0...100, width: 120), 0)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 40, scaleRange: 0...100, width: 120), 48)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 0, scaleRange: 0...0, width: 120), 60)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 8, scaleRange: 8...8, width: 120), 60)
    }

    func testConstantModelUsesItsPositionInsideTheSharedDomain() {
        let sharedRange = 0.0...100.0
        let x = PromptSpeedRangeGeometry.x(for: 25, scaleRange: sharedRange, width: 200)
        XCTAssertEqual(x, 50, "模型行常量不应把自己的范围单独拉伸到整条线")
    }

    @MainActor
    func testFixedValueColumnsFitNarrowWidthsAndShowMissingLatestAsDash() {
        let statistics = PromptSpeedStatistics(
            minimum: 10,
            maximum: 30,
            p50: 20,
            latest: nil,
            validPromptCount: 3,
            totalPromptCount: 4
        )
        let view = PromptSpeedRangeLineView(statistics: statistics, scaleRange: 0...40)
        XCTAssertTrue(view.accessibilityLabel.contains("最近 Prompt —"))
        XCTAssertFalse(view.accessibilityLabel.contains("P50"), "P50 已在模型首行，不在范围图重复朗读")

        for width: CGFloat in [72, 160, 320] {
            let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 100)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, width + 0.5)
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        }
    }
}
