import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class WindowQuarterSnapTests: XCTestCase {

    func testQuarterSnapRawValuesMetadataAndOneTapPolicy() throws {
        let expectedRawPairs: [(SystemQuickAction, String, String)] = [
            (.snapWindowTopLeft, "snap_window_top_left", "rectangle.inset.topleft.filled"),
            (.snapWindowTopRight, "snap_window_top_right", "rectangle.inset.topright.filled"),
            (.snapWindowBottomLeft, "snap_window_bottom_left", "rectangle.inset.bottomleft.filled"),
            (.snapWindowBottomRight, "snap_window_bottom_right", "rectangle.inset.bottomright.filled")
        ]

        XCTAssertTrue(SystemQuickAction.lockScreen.requiresDestructiveConfirmation)

        let macSections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: false)
        let iosSections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: true)

        for (action, raw, symbol) in expectedRawPairs {
            XCTAssertEqual(action.rawValue, raw)
            XCTAssertEqual(SystemQuickAction(rawValue: raw), action)
            XCTAssertEqual(action.sfSymbol, symbol)
            XCTAssertEqual(action.accentHex, SystemQuickAction.snapWindowLeft.accentHex)
            XCTAssertTrue(action.isWindowAction)
            XCTAssertTrue(action.isUndoableWindowMove)
            XCTAssertTrue(action.targetsApplication)
            XCTAssertFalse(action.requiresDestructiveConfirmation)
            XCTAssertNil(action.sentKeyboardShortcut)
            XCTAssertFalse(action.supportsHoldToRepeat)
            XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterAction(action))

            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertNotEqual(action.title(in: .english), action.title(in: .chinese))
            XCTAssertFalse(action.compactTitle(in: .english).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .chinese).isEmpty)

            XCTAssertTrue(SystemQuickAction.windowLayoutSlotActions.contains(action))
            XCTAssertTrue(macSections.first?.1.contains(action) == true)
            XCTAssertTrue(iosSections.first?.1.contains(action) == true)

            let rawJSON = Data("\"\(raw)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(SystemQuickAction.self, from: rawJSON), action)
            let encodedAction = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(SystemQuickAction.self, from: encodedAction), action)

            let barItem = BarItem(kind: .systemAction(action: action))
            let decodedBarItem = try JSONDecoder().decode(BarItem.self, from: JSONEncoder().encode(barItem))
            XCTAssertEqual(decodedBarItem, barItem)

            let flowStep = ActionFlowStep(kind: .systemAction(action: action))
            let decodedStep = try JSONDecoder().decode(ActionFlowStep.self, from: JSONEncoder().encode(flowStep))
            XCTAssertEqual(decodedStep, flowStep)

            let framed = try WireFrameCodec.encode(ClientMessage.performQuickAction(action))
            var accumulator = WireStreamAccumulator()
            let payloads = try accumulator.appendAndExtractPayloads(framed)
            XCTAssertEqual(payloads.count, 1)
            let decodedMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
            XCTAssertEqual(decodedMsg, .performQuickAction(action))
        }
    }

    func testQuarterSnapGeometryRespectsMenuBarDockAndOddDimensions() {
        // Primary 1512x982 display with 37pt menu bar at top and 60pt Dock at bottom.
        let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let appKitVisible = CGRect(x: 0, y: 60, width: 1512, height: 885)
        let visibleQuartz = WindowDisplayGeometry.convertAppKitRectToQuartz(
            appKitVisible,
            primaryScreenHeight: primaryFrame.height
        )
        XCTAssertEqual(visibleQuartz, CGRect(x: 0, y: 37, width: 1512, height: 885))

        let topLeft = WindowDisplayGeometry.quarterFrame(for: .topLeft, visibleQuartz: visibleQuartz)
        let topRight = WindowDisplayGeometry.quarterFrame(for: .topRight, visibleQuartz: visibleQuartz)
        let bottomLeft = WindowDisplayGeometry.quarterFrame(for: .bottomLeft, visibleQuartz: visibleQuartz)
        let bottomRight = WindowDisplayGeometry.quarterFrame(for: .bottomRight, visibleQuartz: visibleQuartz)

        XCTAssertEqual(topLeft, CGRect(x: 0, y: 37, width: 756, height: 442))
        XCTAssertEqual(topRight, CGRect(x: 756, y: 37, width: 756, height: 442))
        XCTAssertEqual(bottomLeft, CGRect(x: 0, y: 480, width: 756, height: 442))
        XCTAssertEqual(bottomRight, CGRect(x: 756, y: 480, width: 756, height: 442))

        for quarter in [topLeft, topRight, bottomLeft, bottomRight] {
            XCTAssertTrue(visibleQuartz.contains(quarter))
        }
        XCTAssertEqual(topRight.maxX, visibleQuartz.maxX)
        XCTAssertEqual(bottomLeft.maxY, visibleQuartz.maxY)
        XCTAssertEqual(bottomRight.maxX, visibleQuartz.maxX)
        XCTAssertEqual(bottomRight.maxY, visibleQuartz.maxY)
        XCTAssertTrue(topLeft.intersection(bottomRight).isNull)

        // Left-side Dock (72pt) and odd width (1441pt) on secondary display.
        let oddVisible = CGRect(x: 1584, y: 25, width: 1441, height: 901)
        let secTopRight = WindowDisplayGeometry.quarterFrame(for: .topRight, visibleQuartz: oddVisible)
        let secBottomLeft = WindowDisplayGeometry.quarterFrame(for: .bottomLeft, visibleQuartz: oddVisible)
        XCTAssertEqual(secTopRight, CGRect(x: 2305, y: 25, width: 720, height: 450))
        XCTAssertEqual(secBottomLeft, CGRect(x: 1584, y: 476, width: 720, height: 450))
        XCTAssertEqual(secTopRight.maxX, oddVisible.maxX)
        XCTAssertEqual(secBottomLeft.maxY, oddVisible.maxY)
    }
}
