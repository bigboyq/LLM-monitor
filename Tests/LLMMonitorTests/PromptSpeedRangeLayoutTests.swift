import XCTest
@testable import LLM_monitor

final class PromptSpeedRangeLayoutTests: XCTestCase {
    func testCollisionKeepsFirstLabelAtItsMarkerWhenThePairFitsToTheRight() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 40, secondAnchor: 60,
            firstColonOffset: 8, secondColonOffset: 8,
            firstWidth: 48, secondWidth: 48, gap: 6, containerWidth: 200
        )
        XCTAssertEqual(positions, [32, 86])
        XCTAssertEqual(positions[0] + 8, 40)
        XCTAssertEqual(positions[1] + 8, 94)
    }

    func testCoincidentAndZeroMarkersKeepLabelsSeparateAndInBounds() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 0,
            secondAnchor: 0,
            firstColonOffset: 12,
            secondColonOffset: 20,
            firstWidth: 52,
            secondWidth: 48,
            gap: 6,
            containerWidth: 180
        )

        XCTAssertEqual(positions.count, 2)
        XCTAssertGreaterThanOrEqual(positions[0], 0)
        XCTAssertGreaterThanOrEqual(positions[1], positions[0] + 52 + 6)
        XCTAssertLessThanOrEqual(positions[1] + 48, 180)
        XCTAssertEqual(positions[0], 0)
        XCTAssertEqual(positions[1], 58)
        XCTAssertEqual(PromptSpeedRangeGeometry.x(for: 0, scaleMaximum: 100, fallbackMaximum: 0, width: 120), 0)
    }

    func testRightEdgeCollisionMovesLabelsLeftWithoutMovingMarkerScale() {
        let positions = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 94,
            secondAnchor: 94,
            firstColonOffset: 12,
            secondColonOffset: 12,
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
            firstColonOffset: 10,
            secondColonOffset: 10,
            firstWidth: 34,
            secondWidth: 34,
            gap: 4,
            containerWidth: 72
        )

        XCTAssertGreaterThanOrEqual(positions[0], 0)
        XCTAssertGreaterThanOrEqual(positions[1], positions[0] + 34 + 4)
        XCTAssertLessThanOrEqual(positions[1] + 34, 72)
    }

    func testMeasuredPrefixAndColonWidthsAnchorLabelsWithDifferentValueWidths() {
        // Widths are layout measurements for each actual prefix/colon/value Text,
        // including the wider Chinese prefix and different numeric digit counts.
        let minPrefixWidth: CGFloat = 17
        let p50PrefixWidth: CGFloat = 26
        let recentPrefixWidth: CGFloat = 30
        let colonWidth: CGFloat = 4
        let minColonOffset = PromptSpeedLabelPlacement.colonOffset(
            prefixWidth: minPrefixWidth,
            colonWidth: colonWidth
        )
        let p50ColonOffset = PromptSpeedLabelPlacement.colonOffset(
            prefixWidth: p50PrefixWidth,
            colonWidth: colonWidth
        )
        let topOrigins = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 60,
            secondAnchor: 190,
            firstColonOffset: minColonOffset,
            secondColonOffset: p50ColonOffset,
            firstWidth: minPrefixWidth + colonWidth + 34,
            secondWidth: p50PrefixWidth + colonWidth + 55,
            gap: 6,
            containerWidth: 260
        )

        XCTAssertEqual(topOrigins[0] + minColonOffset, 60)
        XCTAssertEqual(topOrigins[1] + p50ColonOffset, 190)
        XCTAssertGreaterThanOrEqual(topOrigins[1], topOrigins[0] + minPrefixWidth + colonWidth + 34 + 6)

        let rightEdgeOrigins = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 60,
            secondAnchor: 190,
            firstColonOffset: minColonOffset,
            secondColonOffset: p50ColonOffset,
            firstWidth: minPrefixWidth + colonWidth + 34,
            secondWidth: p50PrefixWidth + colonWidth + 55,
            gap: 6,
            containerWidth: 240
        )

        XCTAssertGreaterThanOrEqual(rightEdgeOrigins[0], 0)
        XCTAssertGreaterThanOrEqual(rightEdgeOrigins[1], rightEdgeOrigins[0] + minPrefixWidth + colonWidth + 34 + 6)
        XCTAssertLessThanOrEqual(rightEdgeOrigins[1] + p50PrefixWidth + colonWidth + 55, 240)
        XCTAssertEqual(rightEdgeOrigins[1] + p50ColonOffset, 183)

        let recentColonOffset = PromptSpeedLabelPlacement.colonOffset(
            prefixWidth: recentPrefixWidth,
            colonWidth: colonWidth
        )
        let bottomOrigins = PromptSpeedLabelPlacement.resolve(
            firstAnchor: 80,
            secondAnchor: 200,
            firstColonOffset: recentColonOffset,
            secondColonOffset: p50ColonOffset,
            firstWidth: recentPrefixWidth + colonWidth + 62,
            secondWidth: p50PrefixWidth + colonWidth + 30,
            gap: 6,
            containerWidth: 240
        )

        XCTAssertEqual(bottomOrigins[0] + recentColonOffset, 80)
        XCTAssertEqual(bottomOrigins[1] + p50ColonOffset, 200)
        XCTAssertGreaterThanOrEqual(bottomOrigins[1], bottomOrigins[0] + recentPrefixWidth + colonWidth + 62 + 6)
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
