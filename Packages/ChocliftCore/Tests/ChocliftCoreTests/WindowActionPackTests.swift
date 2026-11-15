#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

final class WindowActionPackTests: XCTestCase {

    func testWindowPackHasExactTenUniqueIDsTitlesAndSFSymbols() {
        let expectedIDs = [
            "window.thirds_left",
            "window.thirds_center",
            "window.thirds_right",
            "window.almost_maximize",
            "window.restore_previous_frame",
            "window.left_screen",
            "window.right_screen",
            "window.minimize_all_others",
            "window.zoom",
            "window.center_horizontally"
        ]

        let pack = CompanionActionCatalog.windowPack
        XCTAssertEqual(pack.map(\.id), expectedIDs)
        XCTAssertEqual(Set(pack.map(\.id)).count, 10)

        for action in pack {
            XCTAssertTrue(action.id.hasPrefix("window."), "Expected window. prefix for \(action.id)")
            XCTAssertFalse(action.titleZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(action.titleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertEqual(CompanionActionCatalog.action(id: action.id), action)
            #if canImport(AppKit)
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
                "SF Symbol \(action.sfSymbol) should load on macOS"
            )
            #endif
        }
    }

    func testThirdsOf900x600AndOddWidthsAreNonOverlappingWithoutGaps() {
        let visible900 = CGRect(x: 0, y: 0, width: 900, height: 600)
        let left900 = WindowPackGeometry.thirdFrame(for: .left, visibleQuartz: visible900)
        let center900 = WindowPackGeometry.thirdFrame(for: .center, visibleQuartz: visible900)
        let right900 = WindowPackGeometry.thirdFrame(for: .right, visibleQuartz: visible900)

        XCTAssertEqual(left900, CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertEqual(center900, CGRect(x: 300, y: 0, width: 300, height: 600))
        XCTAssertEqual(right900, CGRect(x: 600, y: 0, width: 300, height: 600))
        XCTAssertFalse(left900.intersects(center900))
        XCTAssertFalse(center900.intersects(right900))
        XCTAssertFalse(left900.intersects(right900))

        for oddWidth in [CGFloat(901), 902, 1441, 1513, 1729, 2561] {
            let visible = CGRect(x: 72, y: 37, width: oddWidth, height: 885)
            let left = WindowPackGeometry.thirdFrame(for: .left, visibleQuartz: visible)
            let center = WindowPackGeometry.thirdFrame(for: .center, visibleQuartz: visible)
            let right = WindowPackGeometry.thirdFrame(for: .right, visibleQuartz: visible)

            XCTAssertTrue(visible.contains(left))
            XCTAssertTrue(visible.contains(center))
            XCTAssertTrue(visible.contains(right))
            XCTAssertFalse(left.intersects(center), "Left and center overlapped for width \(oddWidth)")
            XCTAssertFalse(center.intersects(right), "Center and right overlapped for width \(oddWidth)")
            XCTAssertFalse(left.intersects(right), "Left and right overlapped for width \(oddWidth)")

            XCTAssertEqual(left.minX, visible.minX)
            XCTAssertEqual(right.maxX, visible.maxX)

            let gapLeftCenter = center.minX - left.maxX
            let gapCenterRight = right.minX - center.maxX
            XCTAssertGreaterThanOrEqual(gapLeftCenter, 0)
            XCTAssertLessThanOrEqual(gapLeftCenter, 2)
            XCTAssertGreaterThanOrEqual(gapCenterRight, 0)
            XCTAssertLessThanOrEqual(gapCenterRight, 2)
        }
    }

    func testAlmostMaximizeInsetsTwentyFourPoints() {
        let visible = CGRect(x: 0, y: 37, width: 1512, height: 885)
        let insetRect = WindowPackGeometry.almostMaximizedFrame(visibleQuartz: visible)

        XCTAssertEqual(insetRect, CGRect(x: 24, y: 61, width: 1464, height: 837))
        XCTAssertEqual(insetRect.minX - visible.minX, 24)
        XCTAssertEqual(insetRect.minY - visible.minY, 24)
        XCTAssertEqual(visible.maxX - insetRect.maxX, 24)
        XCTAssertEqual(visible.maxY - insetRect.maxY, 24)
    }

    func testCenterHorizontallyKeepsWindowSizeAndVerticalPosition() {
        let visible = CGRect(x: 100, y: 37, width: 1400, height: 880)
        let current = CGRect(x: 140, y: 195, width: 760, height: 520)
        let centered = WindowPackGeometry.horizontallyCenteredFrame(
            currentFrame: current,
            visibleQuartz: visible
        )

        XCTAssertEqual(centered, CGRect(x: 420, y: 195, width: 760, height: 520))
    }

    func testRestoreFailsWhenNoPreviousFrameIsSavedAndRestoresLastSnap() {
        var store = WindowPackFrameStore()
        var applyCount = 0

        let emptyOutcome = store.restorePreviousFrame { _ in
            applyCount += 1
            return (true, "Restored")
        }
        XCTAssertEqual(applyCount, 0)
        switch emptyOutcome {
        case .success:
            XCTFail("Expected restore to fail when no frame was saved")
        case .failure(let error):
            XCTAssertEqual(error, .noSavedFrame)
            XCTAssertFalse(error.message(in: .english).isEmpty)
            XCTAssertFalse(error.message(in: .chinese).isEmpty)
        }

        let firstFrame = CGRect(x: 80, y: 90, width: 700, height: 500)
        let secondFrame = CGRect(x: 0, y: 37, width: 504, height: 885)
        store.recordSuccessfulSnap(windowKey: "42-1", pid: 42, appName: "Safari", previousFrame: firstFrame)
        store.recordSuccessfulSnap(windowKey: "42-1", pid: 42, appName: "Safari", previousFrame: secondFrame)

        var restoredFrame: CGRect?
        let restoredOutcome = store.restorePreviousFrame { saved in
            restoredFrame = saved.previousFrame.cgRect
            return (true, "Restored Safari")
        }
        XCTAssertEqual(try? restoredOutcome.get(), "Restored Safari")
        XCTAssertEqual(restoredFrame, secondFrame)
        XCTAssertNil(store.lastSavedFrame)

        // Second restore after consuming saved frame fails again
        if case .failure(let secondError) = store.restorePreviousFrame(apply: { _ in (true, "Unexpected") }) {
            XCTAssertEqual(secondError, .noSavedFrame)
        } else {
            XCTFail("Expected second restore without new snap to fail")
        }
    }

    func testLeftAndRightScreenSelectionPicksImmediateNeighborAndFailsWhenNoNeighbor() throws {
        let leftDisplay = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        let centerDisplay = CGRect(x: 0, y: 37, width: 1512, height: 885)
        let rightDisplay = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let threeDisplays = [leftDisplay, centerDisplay, rightDisplay]

        let windowOnCenter = CGRect(x: 160, y: 120, width: 900, height: 640)
        let moveLeftFromCenter = try XCTUnwrap(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .left,
                windowQuartzFrame: windowOnCenter,
                quartzVisibleFrames: threeDisplays
            )
        )
        XCTAssertEqual(moveLeftFromCenter.sourceScreenIndex, 1)
        XCTAssertEqual(moveLeftFromCenter.targetScreenIndex, 0)
        XCTAssertTrue(leftDisplay.contains(moveLeftFromCenter.targetFrame))

        let moveRightFromCenter = try XCTUnwrap(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .right,
                windowQuartzFrame: windowOnCenter,
                quartzVisibleFrames: threeDisplays
            )
        )
        XCTAssertEqual(moveRightFromCenter.sourceScreenIndex, 1)
        XCTAssertEqual(moveRightFromCenter.targetScreenIndex, 2)
        XCTAssertTrue(rightDisplay.contains(moveRightFromCenter.targetFrame))

        // From rightmost display: left picks center (immediate neighbor, not leftmost), right fails
        let windowOnRight = CGRect(x: 1800, y: 100, width: 1000, height: 700)
        let moveLeftFromRight = try XCTUnwrap(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .left,
                windowQuartzFrame: windowOnRight,
                quartzVisibleFrames: threeDisplays
            )
        )
        XCTAssertEqual(moveLeftFromRight.sourceScreenIndex, 2)
        XCTAssertEqual(moveLeftFromRight.targetScreenIndex, 1)
        XCTAssertNil(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .right,
                windowQuartzFrame: windowOnRight,
                quartzVisibleFrames: threeDisplays
            )
        )

        // From leftmost display: right picks center (immediate neighbor, not rightmost), left fails
        let windowOnLeft = CGRect(x: -1100, y: 100, width: 900, height: 600)
        let moveRightFromLeft = try XCTUnwrap(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .right,
                windowQuartzFrame: windowOnLeft,
                quartzVisibleFrames: threeDisplays
            )
        )
        XCTAssertEqual(moveRightFromLeft.sourceScreenIndex, 0)
        XCTAssertEqual(moveRightFromLeft.targetScreenIndex, 1)
        XCTAssertNil(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .left,
                windowQuartzFrame: windowOnLeft,
                quartzVisibleFrames: threeDisplays
            )
        )

        // Single display fails in both directions
        XCTAssertNil(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .left,
                windowQuartzFrame: windowOnCenter,
                quartzVisibleFrames: [centerDisplay]
            )
        )
        XCTAssertNil(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .right,
                windowQuartzFrame: windowOnCenter,
                quartzVisibleFrames: [centerDisplay]
            )
        )

        // Vertically stacked displays do not masquerade as left/right neighbors
        let topStacked = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        let bottomStacked = CGRect(x: 204, y: 37, width: 1512, height: 885)
        XCTAssertNil(
            WindowPackGeometry.directionalDisplayTargetFrame(
                direction: .left,
                windowQuartzFrame: CGRect(x: 300, y: -800, width: 900, height: 600),
                quartzVisibleFrames: [topStacked, bottomStacked]
            )
        )
        XCTAssertFalse(WindowPackScreenMoveError.noDisplayOnLeft.message(in: .english).isEmpty)
        XCTAssertFalse(WindowPackScreenMoveError.noDisplayOnRight.message(in: .english).isEmpty)
    }
}
