import XCTest
@testable import LLM_monitor

final class PromptSpeedRangeLayoutTests: XCTestCase {
    func testCollisionKeepsFirstLabelAtItsMarkerWhenThePairFitsToTheRight() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 40, secondAnchor: 60,
            firstWidth: 48, secondWidth: 48, gap: 6, containerWidth: 200
        )
        XCTAssertEqual(positions, [40, 94])
    }

    func testCoincidentAndZeroMarkersKeepLabelsSeparateAndInBounds() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 0,
            secondAnchor: 0,
            firstWidth: 52,
            secondWidth: 48,
            gap: 6,
            containerWidth: 180
        )

        XCTAssertEqual(positions.count, 2)
        XCTAssertGreaterThanOrEqual(positions[0], 0)
        XCTAssertGreaterThanOrEqual(positions[1], positions[0] + 52 + 6)
        XCTAssertLessThanOrEqual(positions[1] + 48, 180)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 0, scaleMaximum: 100, fallbackMaximum: 0, width: 120), 0)
    }

    func testRightEdgeCollisionMovesLabelsLeftWithoutMovingMarkerScale() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 94,
            secondAnchor: 94,
            firstWidth: 45,
            secondWidth: 42,
            gap: 6,
            containerWidth: 100
        )

        XCTAssertGreaterThanOrEqual(positions[0], 0)
        XCTAssertGreaterThanOrEqual(positions[1], positions[0] + 45 + 6)
        XCTAssertLessThanOrEqual(positions[1] + 42, 100)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 100, scaleMaximum: 100, fallbackMaximum: 140, width: 100), 100)
    }

    func testNarrowLayoutUsesAllAvailableWidthWithoutOverflow() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 22,
            secondAnchor: 28,
            firstWidth: 34,
            secondWidth: 34,
            gap: 4,
            containerWidth: 72
        )

        XCTAssertGreaterThanOrEqual(positions[0], 0)
        XCTAssertGreaterThanOrEqual(positions[1], positions[0] + 34 + 4)
        XCTAssertLessThanOrEqual(positions[1] + 34, 72)
    }

    func testModelsUseTheSameMenuWideScale() {
        let firstModelMarker = PromptSpeedRangeGeometry.x(
            for: 50,
            scaleMaximum: 200,
            fallbackMaximum: 80,
            width: 240
        )
        let secondModelMarker = PromptSpeedRangeGeometry.x(
            for: 50,
            scaleMaximum: 200,
            fallbackMaximum: 50,
            width: 240
        )

        XCTAssertEqual(firstModelMarker, 60)
        XCTAssertEqual(secondModelMarker, firstModelMarker)
    }
}
