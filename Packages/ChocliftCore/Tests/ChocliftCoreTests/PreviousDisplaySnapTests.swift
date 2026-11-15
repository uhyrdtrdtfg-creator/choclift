#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

final class PreviousDisplaySnapTests: XCTestCase {

    func testDisplayMovePackExposesPreviousDisplayActionWithTitlesAndSFSymbol() throws {
        let pack = CompanionActionCatalog.displayMovePack
        XCTAssertEqual(pack.count, 1)
        XCTAssertEqual(pack.map(\.id), ["window.previous_display"])

        let action = try XCTUnwrap(CompanionActionCatalog.action(id: "window.previous_display"))
        XCTAssertTrue(CompanionActionCatalog.isKnown("window.previous_display"))
        XCTAssertEqual(pack.first, action)
        XCTAssertEqual(action.titleZh, "移到上一块屏幕")
        XCTAssertEqual(action.titleEn, "Previous Display")
        XCTAssertEqual(action.title(in: .chinese), "移到上一块屏幕")
        XCTAssertEqual(action.title(in: .english), "Previous Display")
        XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
        XCTAssertEqual(action.sfSymbol, "display.2")
        XCTAssertNil(SystemQuickAction(rawValue: "window.previous_display"))

        let allMatches = CompanionActionCatalog.all.filter { $0.id == "window.previous_display" }
        XCTAssertEqual(allMatches.count, 1)

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "SF Symbol \(action.sfSymbol) should load on macOS"
        )
        #endif

        let wireMessage = ClientMessage.performCompanionAction(id: action.id)
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testThreeInjectedFramesWalksBackwardsAndIndexZeroWrapsToLastScreen() throws {
        let screen0 = CGRect(x: 0, y: 37, width: 1512, height: 885)
        let screen1 = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let screen2 = CGRect(x: 4072, y: 25, width: 1920, height: 1055)
        let threeInjectedFrames = [screen0, screen1, screen2]

        // 1. Previous of index 0 wraps to the last screen (index 2)
        let windowOnScreen0 = CGRect(x: 156, y: 120, width: 1000, height: 700)
        let from0To2 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: windowOnScreen0,
                quartzVisibleFrames: threeInjectedFrames
            )
        )
        XCTAssertEqual(from0To2.sourceScreenIndex, 0)
        XCTAssertEqual(from0To2.targetScreenIndex, 2)
        XCTAssertEqual(from0To2.targetFrame.width, 1000)
        XCTAssertEqual(from0To2.targetFrame.height, 700)
        XCTAssertTrue(screen2.contains(from0To2.targetFrame))

        // 2. Previous of index 2 walks backwards to index 1
        let from2To1 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: from0To2.targetFrame,
                quartzVisibleFrames: threeInjectedFrames
            )
        )
        XCTAssertEqual(from2To1.sourceScreenIndex, 2)
        XCTAssertEqual(from2To1.targetScreenIndex, 1)
        XCTAssertEqual(from2To1.targetFrame.width, 1000)
        XCTAssertEqual(from2To1.targetFrame.height, 700)
        XCTAssertTrue(screen1.contains(from2To1.targetFrame))

        // 3. Previous of index 1 walks backwards to index 0, restoring relative position
        let from1To0 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: from2To1.targetFrame,
                quartzVisibleFrames: threeInjectedFrames
            )
        )
        XCTAssertEqual(from1To0.sourceScreenIndex, 1)
        XCTAssertEqual(from1To0.targetScreenIndex, 0)
        XCTAssertEqual(from1To0.targetFrame.origin.x, windowOnScreen0.origin.x, accuracy: 2.0)
        XCTAssertEqual(from1To0.targetFrame.origin.y, windowOnScreen0.origin.y, accuracy: 2.0)
        XCTAssertEqual(from1To0.targetFrame.size, windowOnScreen0.size)
        XCTAssertTrue(screen0.contains(from1To0.targetFrame))

        // 4. Oversized window on 4K screen1 clamps cleanly to smaller screen0 when moving backwards
        let hugeOnScreen1 = CGRect(x: 1600, y: 40, width: 2300, height: 1320)
        let clampedToScreen0 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: hugeOnScreen1,
                quartzVisibleFrames: threeInjectedFrames
            )
        )
        XCTAssertEqual(clampedToScreen0.sourceScreenIndex, 1)
        XCTAssertEqual(clampedToScreen0.targetScreenIndex, 0)
        XCTAssertEqual(clampedToScreen0.targetFrame, screen0)

        // 5. AppKit screen descriptors overload matches Quartz conversion
        let appKitScreens = [
            WindowScreenDescriptor(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 885)
            ),
            WindowScreenDescriptor(
                frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1415)
            ),
            WindowScreenDescriptor(
                frame: CGRect(x: 4072, y: -98, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 4072, y: -98, width: 1920, height: 1055)
            )
        ]
        let appKitPlan = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: windowOnScreen0,
                appKitScreens: appKitScreens
            )
        )
        XCTAssertEqual(appKitPlan, from0To2)

        // 6. nextDisplayTargetFrame remains unchanged (walks forward 0 -> 1)
        let forwardFrom0 = try XCTUnwrap(
            WindowDisplayGeometry.nextDisplayTargetFrame(
                windowQuartzFrame: windowOnScreen0,
                quartzVisibleFrames: threeInjectedFrames
            )
        )
        XCTAssertEqual(forwardFrom0.sourceScreenIndex, 0)
        XCTAssertEqual(forwardFrom0.targetScreenIndex, 1)
    }

    func testTwoScreensMovesToOtherScreenAndOneScreenReturnsNil() throws {
        let primaryQuartz = CGRect(x: 0, y: 37, width: 1512, height: 885)
        let secondaryQuartz = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let twoScreens = [primaryQuartz, secondaryQuartz]

        let windowOnPrimary = CGRect(x: 140, y: 110, width: 960, height: 640)
        let toOtherFrom0 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                quartzVisibleFrames: twoScreens
            )
        )
        XCTAssertEqual(toOtherFrom0.sourceScreenIndex, 0)
        XCTAssertEqual(toOtherFrom0.targetScreenIndex, 1)
        XCTAssertTrue(secondaryQuartz.contains(toOtherFrom0.targetFrame))

        let toOtherFrom1 = try XCTUnwrap(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: toOtherFrom0.targetFrame,
                quartzVisibleFrames: twoScreens
            )
        )
        XCTAssertEqual(toOtherFrom1.sourceScreenIndex, 1)
        XCTAssertEqual(toOtherFrom1.targetScreenIndex, 0)
        XCTAssertTrue(primaryQuartz.contains(toOtherFrom1.targetFrame))

        // One screen returns nil
        XCTAssertNil(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                quartzVisibleFrames: [primaryQuartz]
            )
        )
        XCTAssertNil(
            WindowDisplayGeometry.previousDisplayTargetFrame(
                windowQuartzFrame: windowOnPrimary,
                quartzScreens: []
            )
        )
    }

    func testExecutionRecordsUndoAndReturnsClearFailureOnSingleScreenOrAXError() throws {
        let appKitScreens = [
            WindowScreenDescriptor(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 885)
            ),
            WindowScreenDescriptor(
                frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1415)
            ),
            WindowScreenDescriptor(
                frame: CGRect(x: 4072, y: -98, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 4072, y: -98, width: 1920, height: 1055)
            )
        ]

        let initialRect = CGRect(x: 156, y: 120, width: 1000, height: 700)
        var liveRect = initialRect
        var coordinator = WindowMoveCoordinator<String>()

        let moveOutcome = DisplayMoveCompanionExecution.execute(
            id: DisplayMoveCompanionActionID.previousDisplay,
            coordinator: &coordinator,
            windowID: "win-prev-1",
            appName: "Xcode",
            appKitScreens: appKitScreens,
            screenNames: ["Built-in Retina Display", "Studio Display", "LG UltraFine"],
            language: .english,
            readFrame: { .success(liveRect) },
            writeFrame: { nextFrame in
                liveRect = nextFrame
                return 0
            }
        )
        XCTAssertTrue(moveOutcome.success)
        XCTAssertEqual(moveOutcome.plan?.sourceScreenIndex, 0)
        XCTAssertEqual(moveOutcome.plan?.targetScreenIndex, 2)
        XCTAssertTrue(moveOutcome.message.contains("LG UltraFine"))
        XCTAssertEqual(liveRect, moveOutcome.plan?.targetFrame)
        XCTAssertTrue(coordinator.canUndo)
        XCTAssertEqual(coordinator.lastWindowMove?.previousFrame, WindowQuartzRect(initialRect))

        // Undo restores exact initial rect
        _ = try XCTUnwrap(
            coordinator.performUndo { _, restored in
                liveRect = restored
                return 0
            }
        ).get()
        XCTAssertEqual(liveRect, initialRect)
        XCTAssertFalse(coordinator.canUndo)

        // One screen returns clear localized failure without writing or recording undo
        var singleScreenWrites = 0
        let singleZh = DisplayMoveCompanionExecution.execute(
            id: DisplayMoveCompanionActionID.previousDisplay,
            coordinator: &coordinator,
            windowID: "win-single",
            appName: "Safari",
            appKitScreens: [appKitScreens[0]],
            language: .chinese,
            readFrame: { .success(initialRect) },
            writeFrame: { _ in
                singleScreenWrites += 1
                return 0
            }
        )
        let singleEn = DisplayMoveCompanionExecution.execute(
            id: DisplayMoveCompanionActionID.previousDisplay,
            coordinator: &coordinator,
            windowID: "win-single",
            appName: "Safari",
            appKitScreens: [appKitScreens[0]],
            language: .english,
            readFrame: { .success(initialRect) },
            writeFrame: { _ in
                singleScreenWrites += 1
                return 0
            }
        )
        XCTAssertFalse(singleZh.success)
        XCTAssertFalse(singleEn.success)
        XCTAssertFalse(singleZh.message.isEmpty)
        XCTAssertFalse(singleEn.message.isEmpty)
        XCTAssertNotEqual(singleZh.message, singleEn.message)
        XCTAssertEqual(singleScreenWrites, 0)
        XCTAssertFalse(coordinator.canUndo)

        // Real AX write error surfaces error and does not record undo
        let axFail = DisplayMoveCompanionExecution.execute(
            id: DisplayMoveCompanionActionID.previousDisplay,
            coordinator: &coordinator,
            windowID: "win-locked",
            appName: "System Settings",
            appKitScreens: appKitScreens,
            language: .english,
            readFrame: { .success(initialRect) },
            writeFrame: { _ in -25205 }
        )
        XCTAssertFalse(axFail.success)
        XCTAssertTrue(axFail.message.contains("kAXErrorAttributeUnsupported"))
        XCTAssertFalse(coordinator.canUndo)
    }
}
