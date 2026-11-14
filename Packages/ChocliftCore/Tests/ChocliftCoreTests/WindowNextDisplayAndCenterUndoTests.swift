import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class WindowNextDisplayAndCenterUndoTests: XCTestCase {

    func testMoveWindowToNextDisplayAppendedWithoutReorderingExistingActions() {
        let expectedExistingOrder: [SystemQuickAction] = [
            .maximizeWindow,
            .minimizeWindow,
            .snapWindowLeft,
            .snapWindowRight,
            .switchToNextWindow,
            .switchToPreviousWindow,
            .centerWindow,
            .toggleFullscreen,
            .sendSelectionToOrca,
            .copySelection,
            .pasteClipboard,
            .cutSelection,
            .undoAction,
            .redoAction,
            .missionControl,
            .showDesktop,
            .screenshotInteractive,
            .mediaPlayPause,
            .mediaNext,
            .mediaPrevious,
            .volumeUp,
            .volumeDown,
            .volumeMute,
            .lockScreen,
            .quitApp,
            .openEmojiPicker
        ]

        XCTAssertEqual(Array(SystemQuickAction.allCases.dropLast()), expectedExistingOrder)
        XCTAssertEqual(SystemQuickAction.allCases.last, .moveWindowToNextDisplay)
        XCTAssertEqual(SystemQuickAction.moveWindowToNextDisplay.rawValue, "move_window_to_next_display")
        XCTAssertTrue(SystemQuickAction.moveWindowToNextDisplay.isWindowAction)
        XCTAssertTrue(SystemQuickAction.moveWindowToNextDisplay.isUndoableWindowMove)
        XCTAssertTrue(SystemQuickAction.moveWindowToNextDisplay.targetsApplication)
        XCTAssertFalse(SystemQuickAction.moveWindowToNextDisplay.requiresDestructiveConfirmation)
        XCTAssertNil(SystemQuickAction.moveWindowToNextDisplay.sentKeyboardShortcut)
        XCTAssertFalse(SystemQuickAction.moveWindowToNextDisplay.supportsHoldToRepeat)
    }

    func testCenterIsUndoableAndOneUndoRestoresSavedRect() throws {
        XCTAssertTrue(SystemQuickAction.centerWindow.isUndoableWindowMove)

        var coordinator = WindowMoveCoordinator<String>()
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertNil(coordinator.lastWindowMove)

        let initialRect = CGRect(x: 48, y: 92, width: 920, height: 640)
        let visibleQuartz = CGRect(x: 0, y: 25, width: 1512, height: 920)
        var currentAXRect = initialRect

        let centered = try coordinator.performCenter(
            windowID: "win-center-1",
            appName: "Safari",
            visibleQuartz: visibleQuartz,
            readFrame: { .success(currentAXRect) },
            writeFrame: { frame in
                currentAXRect = frame
                return 0
            }
        ).get()

        XCTAssertEqual(centered, CGRect(x: 296, y: 165, width: 920, height: 640))
        XCTAssertEqual(currentAXRect, centered)
        XCTAssertTrue(coordinator.canUndo)
        XCTAssertEqual(coordinator.lastWindowMove?.windowID, "win-center-1")
        XCTAssertEqual(coordinator.lastWindowMove?.previousFrame, WindowQuartzRect(initialRect))

        // One undo restores the saved pre-center rect and clears undo state
        let undoResult = try XCTUnwrap(
            coordinator.performUndo { _, restoredFrame in
                currentAXRect = restoredFrame
                return 0
            }
        )
        let restoredSnapshots = try undoResult.get()
        XCTAssertEqual(restoredSnapshots.count, 1)
        XCTAssertEqual(currentAXRect, initialRect)
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertNil(coordinator.lastWindowMove)

        // Second undo is a no-op (one level only)
        var secondWriteCount = 0
        let secondUndo = coordinator.performUndo { _, _ in
            secondWriteCount += 1
            return 0
        }
        XCTAssertNil(secondUndo)
        XCTAssertEqual(secondWriteCount, 0)
        XCTAssertEqual(currentAXRect, initialRect)
    }

    func testNextScreenTargetMathWithTwoInjectedFrames() throws {
        let primaryQuartz = CGRect(x: 0, y: 37, width: 1512, height: 885)
        let externalQuartz = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let twoInjectedFrames = [primaryQuartz, externalQuartz]

        // 1. Window on screen 0 moves onto screen 1 keeping dimensions when it fits
        let windowOnPrimary = CGRect(x: 156, y: 120, width: 1000, height: 700)
        let toExternal = try XCTUnwrap(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                quartzVisibleFrames: twoInjectedFrames
            )
        )
        XCTAssertEqual(toExternal.sourceScreenIndex, 0)
        XCTAssertEqual(toExternal.targetScreenIndex, 1)
        XCTAssertEqual(toExternal.targetFrame.width, 1000)
        XCTAssertEqual(toExternal.targetFrame.height, 700)
        XCTAssertTrue(externalQuartz.contains(toExternal.targetFrame))

        // 2. Window on screen 1 wraps around onto screen 0
        let backToPrimary = try XCTUnwrap(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: toExternal.targetFrame,
                quartzVisibleFrames: twoInjectedFrames
            )
        )
        XCTAssertEqual(backToPrimary.sourceScreenIndex, 1)
        XCTAssertEqual(backToPrimary.targetScreenIndex, 0)
        XCTAssertEqual(backToPrimary.targetFrame.origin.x, windowOnPrimary.origin.x, accuracy: 2.0)
        XCTAssertEqual(backToPrimary.targetFrame.origin.y, windowOnPrimary.origin.y, accuracy: 2.0)
        XCTAssertEqual(backToPrimary.targetFrame.size, windowOnPrimary.size)
        XCTAssertTrue(primaryQuartz.contains(backToPrimary.targetFrame))

        // 3. Oversized window on external 4K screen clamps cleanly to smaller MacBook visible frame
        let hugeOnExternal = CGRect(x: 1600, y: 40, width: 2300, height: 1320)
        let clampedToPrimary = try XCTUnwrap(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: hugeOnExternal,
                quartzVisibleFrames: twoInjectedFrames
            )
        )
        XCTAssertEqual(clampedToPrimary.sourceScreenIndex, 1)
        XCTAssertEqual(clampedToPrimary.targetScreenIndex, 0)
        XCTAssertEqual(clampedToPrimary.targetFrame, primaryQuartz)

        // 4. AppKit screen descriptors (bottom-left origin, top-aligned external monitor with negative AppKit y)
        let appKitScreens = [
            WindowScreenDescriptor(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 885)
            ),
            WindowScreenDescriptor(
                frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1415)
            )
        ]
        let convertedPlan = try XCTUnwrap(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                appKitScreens: appKitScreens
            )
        )
        XCTAssertEqual(convertedPlan, toExternal)

        // 5. Single display returns nil (no next display to move to)
        XCTAssertNil(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                quartzVisibleFrames: [primaryQuartz]
            )
        )

        // 6. Full move + single-step undo restores exact initial rect on screen 0
        var coordinator = WindowMoveCoordinator<String>()
        var liveRect = windowOnPrimary
        let movedPlan = try coordinator.performMoveToNextDisplay(
            windowID: "win-next-1",
            appName: "Xcode",
            quartzVisibleFrames: twoInjectedFrames,
            readFrame: { .success(liveRect) },
            writeFrame: { nextRect in
                liveRect = nextRect
                return 0
            }
        ).get()
        XCTAssertEqual(liveRect, movedPlan.targetFrame)
        XCTAssertEqual(coordinator.lastWindowMove?.previousFrame, WindowQuartzRect(windowOnPrimary))

        _ = try XCTUnwrap(
            coordinator.performUndo { _, saved in
                liveRect = saved
                return 0
            }
        ).get()
        XCTAssertEqual(liveRect, windowOnPrimary)
        XCTAssertFalse(coordinator.canUndo)
    }

    func testImmovableWindowReturnsRealAXErrorWithoutRecordingUndo() {
        let twoScreens = [
            CGRect(x: 0, y: 25, width: 1440, height: 875),
            CGRect(x: 1440, y: 25, width: 1920, height: 1055)
        ]
        let lockedRect = CGRect(x: 120, y: 140, width: 800, height: 600)
        var coordinator = WindowMoveCoordinator<String>()

        // kAXErrorAttributeUnsupported (-25205) on write
        let moveRes = coordinator.performMoveToNextDisplay(
            windowID: "win-locked",
            appName: "System Settings",
            quartzVisibleFrames: twoScreens,
            readFrame: { .success(lockedRect) },
            writeFrame: { _ in -25205 }
        )
        switch moveRes {
        case .success:
            XCTFail("Expected immovable window to fail with real AX error")
        case .failure(let err):
            XCTAssertEqual(err, .axError(code: -25205))
            let englishMessage = err.message(in: .english)
            XCTAssertTrue(englishMessage.contains("kAXErrorAttributeUnsupported"))
            XCTAssertTrue(englishMessage.contains("-25205"))
        }
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertNil(coordinator.lastWindowMove)

        // kAXErrorCannotComplete (-25204) on read
        let readFailRes = coordinator.performMoveToNextDisplay(
            windowID: "win-hung",
            appName: "HungApp",
            quartzVisibleFrames: twoScreens,
            readFrame: { .failure(WindowAXStatusError(-25204)) },
            writeFrame: { _ in 0 }
        )
        if case .failure(let err) = readFailRes {
            XCTAssertEqual(err, .axError(code: -25204))
            XCTAssertTrue(err.message(in: .english).contains("kAXErrorCannotComplete (-25204)"))
        } else {
            XCTFail("Expected read AX error")
        }
        XCTAssertFalse(coordinator.canUndo)
    }

    func testGesturePadAndSlotActionListCanBindMoveWindowToNextDisplay() throws {
        // 1. Slot action list exposes moveWindowToNextDisplay in Window Layout section
        XCTAssertTrue(SystemQuickAction.windowLayoutSlotActions.contains(.moveWindowToNextDisplay))
        let macSections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: false)
        let iosSections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: true)
        XCTAssertTrue(macSections.flatMap(\.1).contains(.moveWindowToNextDisplay))
        XCTAssertTrue(iosSections.flatMap(\.1).contains(.moveWindowToNextDisplay))

        // 2. Slot BarItem and ActionFlowStep bind & round-trip without modifying BarItemKind or ActionFlowStepKind
        let slotItem = BarItem(kind: .systemAction(action: .moveWindowToNextDisplay))
        let decodedSlotItem = try JSONDecoder().decode(BarItem.self, from: JSONEncoder().encode(slotItem))
        XCTAssertEqual(decodedSlotItem, slotItem)

        let flowStep = ActionFlowStep(kind: .systemAction(action: .moveWindowToNextDisplay))
        let decodedFlowStep = try JSONDecoder().decode(ActionFlowStep.self, from: JSONEncoder().encode(flowStep))
        XCTAssertEqual(decodedFlowStep, flowStep)

        // 3. Gesture Pad configuration & CompanionClientEngine binding
        let suiteName = "com.choclift.tests.c12.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CompanionClientEngine(
            deviceID: "test-ipad-c12",
            deviceName: "Test iPad",
            platform: .iPad,
            userDefaults: defaults,
            storageKeyPrefix: "c12"
        )
        client.setGestureBinding(.twoFingerSwipeRight, action: .moveWindowToNextDisplay)
        XCTAssertEqual(
            client.profile.gestureConfig.action(for: .twoFingerSwipeRight),
            .moveWindowToNextDisplay
        )

        let framed = try WireFrameCodec.encode(ClientMessage.performQuickAction(.moveWindowToNextDisplay))
        var stream = WireStreamAccumulator()
        let payloads = try stream.appendAndExtractPayloads(framed)
        let decodedMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        XCTAssertEqual(decodedMsg, .performQuickAction(.moveWindowToNextDisplay))
    }
}
