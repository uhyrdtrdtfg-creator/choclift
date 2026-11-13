import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class Round01InteractionTests: XCTestCase {

    // MARK: - 1. Destructive Action & Flow Confirmation Rule (3-Second Window)

    func testDestructiveActionClassificationCoversQuitLockAndFlowsContainingThem() {
        for action in SystemQuickAction.allCases {
            if action == .lockScreen || action == .quitApp {
                XCTAssertTrue(action.requiresDestructiveConfirmation, "\(action) must require confirmation")
            } else {
                XCTAssertFalse(action.requiresDestructiveConfirmation, "\(action) must stay one-tap")
            }
        }

        let safeFlow = ActionFlow(
            name: "Focus Split",
            emoji: "🪟",
            steps: [
                ActionFlowStep(kind: .systemAction(action: .snapWindowLeft)),
                ActionFlowStep(kind: .delay(seconds: 0.2)),
                ActionFlowStep(kind: .systemAction(action: .snapWindowRight))
            ]
        )
        XCTAssertFalse(safeFlow.requiresDestructiveConfirmation)

        let lockFlow = ActionFlow(
            name: "Wrap Up Day",
            emoji: "🔒",
            steps: [
                ActionFlowStep(kind: .systemAction(action: .volumeMute)),
                ActionFlowStep(kind: .systemAction(action: .lockScreen))
            ]
        )
        XCTAssertTrue(lockFlow.requiresDestructiveConfirmation)

        let quitFlow = ActionFlow(
            name: "Close Frontmost",
            emoji: "🛑",
            steps: [
                ActionFlowStep(kind: .systemAction(action: .quitApp))
            ]
        )
        XCTAssertTrue(quitFlow.requiresDestructiveConfirmation)

        let disabledLockFlow = ActionFlow(
            name: "Disabled Lock Step",
            emoji: "🧪",
            steps: [
                ActionFlowStep(kind: .systemAction(action: .lockScreen), isEnabled: false),
                ActionFlowStep(kind: .systemAction(action: .maximizeWindow), isEnabled: true)
            ]
        )
        XCTAssertFalse(disabledLockFlow.requiresDestructiveConfirmation)

        var profile = ChocliftDefaults.makeDefaultProfile()
        profile.flows = [safeFlow, lockFlow, quitFlow, disabledLockFlow]

        XCTAssertTrue(BarItem(kind: .systemAction(action: .lockScreen)).requiresDestructiveConfirmation(in: profile))
        XCTAssertTrue(BarItem(kind: .systemAction(action: .quitApp)).requiresDestructiveConfirmation(in: profile))
        XCTAssertFalse(BarItem(kind: .systemAction(action: .maximizeWindow)).requiresDestructiveConfirmation(in: profile))
        XCTAssertFalse(
            BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
                .requiresDestructiveConfirmation(in: profile)
        )

        XCTAssertFalse(profile.makeBarItem(for: safeFlow).requiresDestructiveConfirmation(in: profile))
        XCTAssertTrue(profile.makeBarItem(for: lockFlow).requiresDestructiveConfirmation(in: profile))
        XCTAssertTrue(profile.makeBarItem(for: quitFlow).requiresDestructiveConfirmation(in: profile))
        XCTAssertFalse(profile.makeBarItem(for: disabledLockFlow).requiresDestructiveConfirmation(in: profile))
    }

    func testDestructiveConfirmGateRequiresSecondTapWithinThreeSeconds() {
        var gate = DestructiveActionConfirmGate()
        XCTAssertEqual(gate.confirmationWindowSeconds, 3.0, accuracy: 1e-9)

        // Normal tiles run on the first tap
        XCTAssertEqual(
            gate.registerTap(targetID: "0-1", isDestructive: false, at: 10.0),
            .runImmediately
        )
        XCTAssertNil(gate.armedTargetID)

        // First tap on Lock/Quit asks for confirmation instead of running
        let firstTap = gate.registerTap(targetID: "0-7", isDestructive: true, at: 20.0)
        XCTAssertEqual(firstTap, .requireSecondTap(expiresAt: 23.0))
        XCTAssertTrue(gate.isArmed(targetID: "0-7", at: 22.9))
        XCTAssertTrue(gate.isArmed(targetID: "0-7", at: 23.0))
        XCTAssertFalse(gate.isArmed(targetID: "0-7", at: 23.01))

        // Second tap within 3 seconds confirms and disarms
        let secondTap = gate.registerTap(targetID: "0-7", isDestructive: true, at: 22.4)
        XCTAssertEqual(secondTap, .confirmedRun)
        XCTAssertNil(gate.armedTargetID)

        // Subsequent tap starts a fresh confirmation cycle
        XCTAssertEqual(
            gate.registerTap(targetID: "0-7", isDestructive: true, at: 25.0),
            .requireSecondTap(expiresAt: 28.0)
        )

        // Waiting longer than 3 seconds expires confirmation and asks again
        XCTAssertEqual(
            gate.registerTap(targetID: "0-7", isDestructive: true, at: 28.05),
            .requireSecondTap(expiresAt: 31.05)
        )

        // Tapping a different destructive tile re-arms the new tile rather than confirming the first
        XCTAssertEqual(
            gate.registerTap(targetID: "0-6", isDestructive: true, at: 29.0),
            .requireSecondTap(expiresAt: 32.0)
        )
        XCTAssertEqual(gate.armedTargetID, "0-6")

        // Tapping a non-destructive tile runs immediately and clears any armed confirmation
        XCTAssertEqual(
            gate.registerTap(targetID: "0-2", isDestructive: false, at: 29.5),
            .runImmediately
        )
        XCTAssertNil(gate.armedTargetID)
    }

    // MARK: - 2. 8pt Tap vs 40pt Page Swipe vs 0.45s Long-Press & Slider Exclusion

    func testTapLongPressPageSwipeAndSliderThresholds() {
        XCTAssertEqual(CompanionInteractionPolicy.tapMaxTranslationPoints, 8.0, accuracy: 1e-9)
        XCTAssertEqual(CompanionInteractionPolicy.pageSwipeMinHorizontalPoints, 40.0, accuracy: 1e-9)
        XCTAssertEqual(CompanionInteractionPolicy.tileLongPressDurationSeconds, 0.45, accuracy: 1e-9)
        XCTAssertEqual(CompanionInteractionPolicy.destructiveConfirmWindowSeconds, 3.0, accuracy: 1e-9)

        // Short tap within 8pt (including exact 8.0pt Euclidean boundary: 4.8^2 + 6.4^2 = 8.0^2)
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: .zero,
                pressDuration: 0.12
            ),
            .shortTap
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: 4.8, height: 6.4),
                pressDuration: 0.44
            ),
            .shortTap
        )

        // Long press at >= 0.45s within 8pt opens the slot editor and consumes release
        XCTAssertFalse(
            CompanionInteractionPolicy.shouldFireLongPressWhileHolding(
                translation: CGSize(width: 4.0, height: 3.0),
                elapsedSeconds: 0.44
            )
        )
        XCTAssertTrue(
            CompanionInteractionPolicy.shouldFireLongPressWhileHolding(
                translation: CGSize(width: 4.8, height: 6.4),
                elapsedSeconds: 0.45
            )
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: 3.0, height: 2.0),
                pressDuration: 0.45
            ),
            .longPressEdit
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: 3.0, height: 2.0),
                pressDuration: 0.55,
                didTriggerLongPress: true
            ),
            .consumedByLongPress
        )

        // Finger drift > 8pt and < 40pt neither taps, opens editor, nor swipes pages
        XCTAssertFalse(
            CompanionInteractionPolicy.shouldFireLongPressWhileHolding(
                translation: CGSize(width: 8.5, height: 0),
                elapsedSeconds: 0.60
            )
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: -24.0, height: 2.0),
                pressDuration: 0.25
            ),
            .cancelled
        )

        // Horizontal drag >= 40pt with |dx| > |dy| changes pages
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: -40.0, height: 10.0),
                pressDuration: 0.22
            ),
            .pageSwipe(delta: 1)
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: 40.0, height: -12.0),
                pressDuration: 0.22
            ),
            .pageSwipe(delta: -1)
        )

        // Predominantly vertical drag does not change pages
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: -42.0, height: 55.0),
                pressDuration: 0.28
            ),
            .cancelled
        )

        // Volume and brightness drags never open the editor and never change pages
        XCTAssertFalse(
            CompanionInteractionPolicy.shouldFireLongPressWhileHolding(
                translation: .zero,
                elapsedSeconds: 0.80,
                isControlSliderDrag: true
            )
        )
        XCTAssertEqual(
            CompanionInteractionPolicy.classifyTouchEnded(
                translation: CGSize(width: -95.0, height: 0),
                pressDuration: 0.70,
                isControlSliderDrag: true
            ),
            .sliderScrub
        )
    }

    // MARK: - 3. Reachable 8-Page Dots Pinning & Resume Follow

    func testPageDotTapPinsDeckUntilFollowFrontmostAppIsTapped() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertEqual(profile.pages.count, 8)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: profile.pages[2].id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: profile.pages[5].id)

        var follower = AppDeckFollowerState()
        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 2)
        XCTAssertTrue(follower.isFollowingFrontmostApp)

        // Tapping any of the 8 page dots jumps directly and pins manual mode
        for dotIndex in 0..<8 {
            follower.selectManualPage(index: dotIndex, in: profile)
            XCTAssertEqual(follower.currentPageIndex, dotIndex)
            XCTAssertFalse(follower.isFollowingFrontmostApp)
        }

        // Frontmost Mac app changes do not override manual page selection while pinned
        follower.selectManualPage(index: 6, in: profile)
        follower.handleFrontmostAppChanged("com.apple.Safari", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 6)
        XCTAssertFalse(follower.isFollowingFrontmostApp)

        // Tapping Follow Frontmost App unpins and jumps to the active Mac app's deck
        follower.followFrontmostApp(frontmostBundleIdentifier: "com.apple.Safari", in: profile)
        XCTAssertTrue(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 5)
    }

    // MARK: - 4. One-Level Window Move Undo & Quiet Empty Behavior

    func testWindowMoveUndoBufferIsStrictlyOneLevelAndSupportsSplitTransactions() {
        var buffer = WindowMoveUndoBuffer<String>()
        XCTAssertFalse(buffer.canUndo)
        XCTAssertNil(buffer.popUndoEntry())

        let frameA1 = WindowQuartzRect(x: 40, y: 60, width: 900, height: 700)
        let frameA2 = WindowQuartzRect(x: 0, y: 25, width: 720, height: 875)
        let frameB1 = WindowQuartzRect(x: 220, y: 90, width: 880, height: 680)

        // Single snap records one undo entry; overwriting replaces rather than stacking
        buffer.recordMove(windowID: "win-A", appName: "Safari", previousFrame: frameA1)
        XCTAssertTrue(buffer.canUndo)
        buffer.recordMove(windowID: "win-A", appName: "Safari", previousFrame: frameA2)

        let poppedSingle = buffer.popUndoEntry()
        XCTAssertEqual(
            poppedSingle,
            [WindowMoveSnapshot(windowID: "win-A", appName: "Safari", previousFrame: frameA2)]
        )
        XCTAssertFalse(buffer.canUndo)
        XCTAssertNil(buffer.popUndoEntry(), "Second undo must be nil (one level only)")

        // Multi-window Left/Right Split flow commits as a single 1-level undo entry
        buffer.beginTransaction()
        buffer.recordMove(windowID: "win-A", appName: "Safari", previousFrame: frameA1)
        buffer.recordMove(windowID: "win-B", appName: "Notes", previousFrame: frameB1)
        XCTAssertTrue(buffer.commitTransaction())
        XCTAssertTrue(buffer.canUndo)

        // Running a non-window flow leaves the existing 1-level window undo intact
        buffer.beginTransaction()
        XCTAssertFalse(buffer.commitTransaction())
        XCTAssertTrue(buffer.canUndo)

        let poppedSplit = buffer.popUndoEntry()
        XCTAssertEqual(poppedSplit?.count, 2)
        XCTAssertEqual(poppedSplit?.first?.previousFrame, frameA1)
        XCTAssertEqual(poppedSplit?.last?.previousFrame, frameB1)
        XCTAssertFalse(buffer.canUndo)
        XCTAssertNil(buffer.popUndoEntry())
    }

    func testUndoWindowMoveWireRoundTripAndQuietClientWhenNothingToUndo() throws {
        // Legacy ControlStripState JSON without canUndoWindowMove defaults to false
        let legacyJSON = #"{"volume":0.5,"isVolumeMuted":false,"brightness":0.7,"isBrightnessAvailable":true}"#
        let decodedLegacy = try JSONDecoder().decode(ControlStripState.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decodedLegacy.canUndoWindowMove)

        let undoableState = ControlStripState(
            volume: 0.5,
            isVolumeMuted: false,
            brightness: 0.7,
            isBrightnessAvailable: true,
            canUndoWindowMove: true
        )
        XCTAssertTrue(decodedLegacy.hasMeaningfulDifference(from: undoableState))

        let encodedState = try JSONEncoder().encode(undoableState)
        let roundTrippedState = try JSONDecoder().decode(ControlStripState.self, from: encodedState)
        XCTAssertTrue(roundTrippedState.canUndoWindowMove)

        // ClientMessage.undoLastWindowMove wire round-trip
        let messageFrame = try WireFrameCodec.encode(ClientMessage.undoLastWindowMove)
        var stream = WireStreamAccumulator()
        let payloads = try stream.appendAndExtractPayloads(messageFrame)
        XCTAssertEqual(payloads.count, 1)
        let decodedMessage = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        if case .undoLastWindowMove = decodedMessage {
            // Expected
        } else {
            XCTFail("Expected .undoLastWindowMove, got \(decodedMessage)")
        }

        // Calling undoLastWindowMove() when nothing is undoable stays quiet (no error toast)
        let suiteName = "com.choclift.tests.round01.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CompanionClientEngine(
            deviceID: "test-iphone",
            deviceName: "Test iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "round01"
        )
        XCTAssertFalse(client.controlStripState.canUndoWindowMove)
        XCTAssertNil(client.lastFeedback)
        client.undoLastWindowMove()
        XCTAssertNil(client.lastFeedback, "Empty window undo must stay quiet and never emit an error toast")
    }
}
