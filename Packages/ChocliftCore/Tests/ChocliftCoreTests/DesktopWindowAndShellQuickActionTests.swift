import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class DesktopWindowAndShellQuickActionTests: XCTestCase {

    func testRawValueAndWireRoundTripForWindowAndShellQuickActions() throws {
        let expectedRawValues: [(SystemQuickAction, String)] = [
            (.closeFrontmostWindow, "close_frontmost_window"),
            (.newFrontmostWindow, "new_frontmost_window"),
            (.toggleLaunchpad, "toggle_launchpad"),
            (.toggleNotificationCenter, "toggle_notification_center")
        ]

        var stream = WireStreamAccumulator()
        for (action, rawValue) in expectedRawValues {
            XCTAssertEqual(action.rawValue, rawValue)
            XCTAssertEqual(SystemQuickAction(rawValue: rawValue), action)

            let encodedAction = try JSONEncoder().encode(action)
            let decodedAction = try JSONDecoder().decode(SystemQuickAction.self, from: encodedAction)
            XCTAssertEqual(decodedAction, action)

            let barItem = BarItem(kind: .systemAction(action: action))
            let decodedBarItem = try JSONDecoder().decode(BarItem.self, from: JSONEncoder().encode(barItem))
            XCTAssertEqual(decodedBarItem, barItem)

            let flowStep = ActionFlowStep(kind: .systemAction(action: action))
            let decodedStep = try JSONDecoder().decode(ActionFlowStep.self, from: JSONEncoder().encode(flowStep))
            XCTAssertEqual(decodedStep, flowStep)

            let clientMsg = ClientMessage.performQuickAction(action)
            let framed = try WireFrameCodec.encode(clientMsg)
            let payloads = try stream.appendAndExtractPayloads(framed)
            XCTAssertEqual(payloads.count, 1)
            let decodedMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
            XCTAssertEqual(decodedMsg, clientMsg)
        }
    }

    func testWindowAndShellQuickActionsAreOneTapWhileLockScreenRequiresConfirmation() {
        let oneTapActions: [SystemQuickAction] = [
            .closeFrontmostWindow,
            .newFrontmostWindow,
            .toggleLaunchpad,
            .toggleNotificationCenter
        ]

        var gate = DestructiveActionConfirmGate()
        for action in oneTapActions {
            XCTAssertFalse(action.requiresDestructiveConfirmation)
            XCTAssertFalse(action.supportsHoldToRepeat)
            let decision = gate.registerTap(
                targetID: action.rawValue,
                isDestructive: action.requiresDestructiveConfirmation,
                at: 100.0
            )
            XCTAssertEqual(decision, .runImmediately)
        }

        XCTAssertTrue(SystemQuickAction.lockScreen.requiresDestructiveConfirmation)
        let lockDecision = gate.registerTap(
            targetID: SystemQuickAction.lockScreen.rawValue,
            isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
            at: 100.0
        )
        XCTAssertEqual(
            lockDecision,
            .requireSecondTap(expiresAt: 100.0 + CompanionInteractionPolicy.destructiveConfirmWindowSeconds)
        )
    }

    func testShortcutMetadataAndSlotSectionsForWindowAndShellQuickActions() {
        XCTAssertNil(SystemQuickAction.closeFrontmostWindow.sentKeyboardShortcut)
        XCTAssertEqual(SystemQuickAction.newFrontmostWindow.sentKeyboardShortcut, "⌘N")
        XCTAssertNil(SystemQuickAction.toggleLaunchpad.sentKeyboardShortcut)
        XCTAssertNil(SystemQuickAction.toggleNotificationCenter.sentKeyboardShortcut)

        XCTAssertTrue(SystemQuickAction.closeFrontmostWindow.isWindowAction)
        XCTAssertFalse(SystemQuickAction.closeFrontmostWindow.isUndoableWindowMove)
        XCTAssertTrue(SystemQuickAction.closeFrontmostWindow.targetsApplication)

        XCTAssertFalse(SystemQuickAction.newFrontmostWindow.isWindowAction)
        XCTAssertFalse(SystemQuickAction.newFrontmostWindow.isUndoableWindowMove)
        XCTAssertTrue(SystemQuickAction.newFrontmostWindow.targetsApplication)

        XCTAssertFalse(SystemQuickAction.toggleLaunchpad.isWindowAction)
        XCTAssertFalse(SystemQuickAction.toggleLaunchpad.targetsApplication)
        XCTAssertFalse(SystemQuickAction.toggleNotificationCenter.isWindowAction)
        XCTAssertFalse(SystemQuickAction.toggleNotificationCenter.targetsApplication)

        for action in [
            SystemQuickAction.closeFrontmostWindow,
            .newFrontmostWindow,
            .toggleLaunchpad,
            .toggleNotificationCenter
        ] {
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .english).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .chinese).isEmpty)
        }

        XCTAssertTrue(SystemQuickAction.windowLayoutSlotActions.contains(.closeFrontmostWindow))
        XCTAssertTrue(SystemQuickAction.windowLayoutSlotActions.contains(.newFrontmostWindow))

        let sections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: true)
        let windowSection = sections.first { $0.0 == "Window Layout" }?.1 ?? []
        let workspaceSection = sections.first { $0.0 == "Workspace & System" }?.1 ?? []
        XCTAssertTrue(windowSection.contains(.closeFrontmostWindow))
        XCTAssertTrue(windowSection.contains(.newFrontmostWindow))
        XCTAssertTrue(workspaceSection.contains(.toggleLaunchpad))
        XCTAssertTrue(workspaceSection.contains(.toggleNotificationCenter))
    }
}
