import CoreGraphics
import XCTest
@testable import ChocliftCore

final class NotchPanelGeometryTests: XCTestCase {
    private let notchedMacBook = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 885),
        safeAreaTopInset: 37,
        auxiliaryTopLeftRect: CGRect(x: 0, y: 945, width: 650, height: 37),
        auxiliaryTopRightRect: CGRect(x: 862, y: 945, width: 650, height: 37)
    )

    private let nonNotchedDisplay = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 50, width: 1440, height: 825),
        safeAreaTopInset: 0
    )

    func testTopTriggerHitTestingOnNotchedAndNonNotchedDisplays() {
        XCTAssertTrue(notchedMacBook.hasHardwareNotch)
        XCTAssertEqual(notchedMacBook.notchRect, CGRect(x: 650, y: 945, width: 212, height: 37))

        let notchedTrigger = NotchPanelLayout.topTriggerRect(for: notchedMacBook)
        // Pushed all the way to the top edge (y == frame.maxY) must still match inclusively.
        XCTAssertTrue(NotchPanelLayout.rectContainsInclusive(notchedTrigger, point: CGPoint(x: 756, y: 982)))
        XCTAssertTrue(NotchPanelLayout.rectContainsInclusive(notchedTrigger, point: CGPoint(x: 756, y: 955)))
        // Far left Apple menu and far right status bar icons are outside the notch hover entry.
        XCTAssertFalse(NotchPanelLayout.rectContainsInclusive(notchedTrigger, point: CGPoint(x: 40, y: 970)))
        XCTAssertFalse(NotchPanelLayout.rectContainsInclusive(notchedTrigger, point: CGPoint(x: 1460, y: 970)))

        XCTAssertFalse(nonNotchedDisplay.hasHardwareNotch)
        XCTAssertNil(nonNotchedDisplay.notchRect)

        let flatTrigger = NotchPanelLayout.topTriggerRect(for: nonNotchedDisplay)
        XCTAssertTrue(NotchPanelLayout.rectContainsInclusive(flatTrigger, point: CGPoint(x: 720, y: 900)))
        XCTAssertTrue(NotchPanelLayout.rectContainsInclusive(flatTrigger, point: CGPoint(x: 720, y: 882)))
        XCTAssertFalse(NotchPanelLayout.rectContainsInclusive(flatTrigger, point: CGPoint(x: 200, y: 890)))
    }

    func testPanelPlacementAndKeepAliveBridgeCorridorHaveNoDeadZone() {
        let panelSize = CGSize(width: 394, height: 252)
        let panelFrame = NotchPanelLayout.panelFrame(
            for: .topNotch,
            panelSize: panelSize,
            screen: notchedMacBook
        )
        // Top of panel aligns directly beneath the 37pt notch / menu bar.
        XCTAssertEqual(panelFrame.maxY, 945)
        XCTAssertEqual(panelFrame.midX, 756, accuracy: 1.0)

        // Moving straight or diagonally from the notch down into the panel stays inside keep-alive.
        for y in stride(from: CGFloat(982), through: panelFrame.minY + 4, by: -12) {
            XCTAssertTrue(
                NotchPanelLayout.keepAliveContains(
                    point: CGPoint(x: 756, y: y),
                    anchor: .topNotch,
                    panelFrame: panelFrame,
                    screen: notchedMacBook
                ),
                "Expected keep-alive corridor at y=\(y)"
            )
        }

        // Moving below or well outside the panel exits keep-alive.
        XCTAssertFalse(
            NotchPanelLayout.keepAliveContains(
                point: CGPoint(x: 756, y: panelFrame.minY - 30),
                anchor: .topNotch,
                panelFrame: panelFrame,
                screen: notchedMacBook
            )
        )
        XCTAssertFalse(
            NotchPanelLayout.keepAliveContains(
                point: CGPoint(x: panelFrame.minX - 40, y: panelFrame.midY),
                anchor: .topNotch,
                panelFrame: panelFrame,
                screen: notchedMacBook
            )
        )
    }

    func testHoverDwellShowPointerExitHideAndEscapeSuppression() {
        var machine = NotchPanelHoverStateMachine(
            config: NotchPanelTimingConfig(
                topHoverDwell: 0.14,
                leftEdgeHoverDwell: 0.18,
                pointerExitDelay: 0.12
            )
        )
        let screens = [notchedMacBook]
        let panelSize = CGSize(width: 394, height: 252)
        let panelFrame = NotchPanelLayout.panelFrame(for: .topNotch, panelSize: panelSize, screen: notchedMacBook)

        // 1. Entering notch starts dwell without immediately flashing.
        let t0 = machine.step(
            pointerLocation: CGPoint(x: 756, y: 980),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 10.0
        )
        XCTAssertEqual(t0, .none)
        XCTAssertFalse(machine.isVisible)

        // 2. Sweeping away before dwell completes cancels pending show.
        let tEarly = machine.step(
            pointerLocation: CGPoint(x: 756, y: 500),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 10.08
        )
        XCTAssertEqual(tEarly, .none)
        XCTAssertNil(machine.pendingHover)

        // 3. Dwelling >= 140ms shows the panel.
        _ = machine.step(
            pointerLocation: CGPoint(x: 756, y: 980),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 20.0
        )
        let tShow = machine.step(
            pointerLocation: CGPoint(x: 756, y: 978),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 20.15
        )
        XCTAssertEqual(tShow, .show(anchor: .topNotch, screenIndex: 0))
        XCTAssertTrue(machine.isVisible)

        // 4. Moving into the tile area keeps it visible.
        let tInside = machine.step(
            pointerLocation: CGPoint(x: panelFrame.midX, y: panelFrame.midY),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: panelFrame,
            now: 20.5
        )
        XCTAssertEqual(tInside, .none)
        XCTAssertTrue(machine.isVisible)

        // 5. Pointer exit hides after the exit grace delay.
        let tExitStart = machine.step(
            pointerLocation: CGPoint(x: 200, y: 200),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: panelFrame,
            now: 21.0
        )
        XCTAssertEqual(tExitStart, .none)

        let tHide = machine.step(
            pointerLocation: CGPoint(x: 200, y: 200),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: panelFrame,
            now: 21.13
        )
        XCTAssertEqual(tHide, .hide)
        XCTAssertFalse(machine.isVisible)

        // 6. Escape dismiss suppresses immediate re-open while parked in notch until pointer leaves once.
        _ = machine.step(
            pointerLocation: CGPoint(x: 756, y: 980),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 30.0
        )
        _ = machine.step(
            pointerLocation: CGPoint(x: 756, y: 980),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 30.2
        )
        XCTAssertEqual(machine.dismissImmediately(suppressUntilTriggerExit: true), .hide)

        let tParked = machine.step(
            pointerLocation: CGPoint(x: 756, y: 980),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 30.5
        )
        XCTAssertEqual(tParked, .none)
        XCTAssertFalse(machine.isVisible)

        // Leaving trigger zone clears suppression so next hover opens normally.
        _ = machine.step(
            pointerLocation: CGPoint(x: 756, y: 400),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 30.6
        )
        XCTAssertFalse(machine.suppressedTriggerUntilExit)
    }

    func testLeftEdgeDefaultOffFullScreenSuppressionAndMasterToggle() {
        var machine = NotchPanelHoverStateMachine(
            config: NotchPanelTimingConfig(topHoverDwell: 0.1, leftEdgeHoverDwell: 0.1, pointerExitDelay: 0.1)
        )
        let screens = [nonNotchedDisplay]
        let leftEdgePoint = CGPoint(x: 0, y: nonNotchedDisplay.visibleFrame.midY)

        // Left edge disabled (default): does not open.
        _ = machine.step(
            pointerLocation: leftEdgePoint,
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 1.0
        )
        let resOff = machine.step(
            pointerLocation: leftEdgePoint,
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: false,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 1.2
        )
        XCTAssertEqual(resOff, .none)

        // Left edge enabled: opens at .leftEdge.
        _ = machine.step(
            pointerLocation: leftEdgePoint,
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: true,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 2.0
        )
        let resOn = machine.step(
            pointerLocation: leftEdgePoint,
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: true,
            isFullScreenSuppressed: false,
            isMouseButtonPressed: false,
            currentPanelFrame: nil,
            now: 2.15
        )
        XCTAssertEqual(resOn, .show(anchor: .leftEdge, screenIndex: 0))

        // Master toggle off or full-screen video active immediately hides an open panel.
        let panelFrame = NotchPanelLayout.panelFrame(
            for: .leftEdge,
            panelSize: CGSize(width: 394, height: 252),
            screen: nonNotchedDisplay
        )
        let hideOnFS = machine.step(
            pointerLocation: CGPoint(x: panelFrame.midX, y: panelFrame.midY),
            screens: screens,
            isPanelEnabled: true,
            isLeftEdgeEnabled: true,
            isFullScreenSuppressed: true,
            isMouseButtonPressed: false,
            currentPanelFrame: panelFrame,
            now: 2.3
        )
        XCTAssertEqual(hideOnFS, .hide)

        // Full-screen coverage check distinguishes maximized desktop window vs full-screen video.
        let maximizedDesktop = nonNotchedDisplay.visibleFrame
        XCTAssertFalse(
            NotchPanelLayout.windowCoversFullScreen(
                windowFrameInScreenCoords: maximizedDesktop,
                screen: nonNotchedDisplay
            )
        )
        let quartzFull = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let converted = NotchPanelLayout.appKitScreenRect(fromQuartzRect: quartzFull, primaryScreenHeight: 900)
        XCTAssertTrue(
            NotchPanelLayout.windowCoversFullScreen(
                windowFrameInScreenCoords: converted,
                screen: nonNotchedDisplay
            )
        )
    }

    func testSlotFrameHitTestingWithAndWithoutNowPlayingRowUsingInjectedFrames() {
        let windowHeight: CGFloat = 292
        let tileSide: CGFloat = 76
        let gridSpacing: CGFloat = 16
        let originX: CGFloat = 32

        func makeInjectedTopLeftSlotFrames(gridTopY: CGFloat) -> [Int: CGRect] {
            var frames: [Int: CGRect] = [:]
            for row in 0..<2 {
                for col in 0..<4 {
                    let idx = row * 4 + col
                    let x = originX + CGFloat(col) * (tileSide + gridSpacing)
                    let y = gridTopY + CGFloat(row) * (tileSide + gridSpacing)
                    frames[idx] = CGRect(x: x, y: y, width: tileSide, height: tileSide)
                }
            }
            return frames
        }

        // Without now-playing row: header (18..<42) + 10pt spacing -> grid starts at top-left y = 52.
        // Row 0 in AppKit bottom-left window coords: y = 164...240; Row 1: y = 72...148.
        let topLeftWithoutNowPlaying = makeInjectedTopLeftSlotFrames(gridTopY: 52)
        let windowFramesWithoutNowPlaying = NotchPanelLayout.appKitWindowSlotFrames(
            fromTopLeftSlotFrames: topLeftWithoutNowPlaying,
            windowHeight: windowHeight
        )

        // With now-playing + transport row (28pt + 10pt spacing = 38pt): grid starts at top-left y = 90.
        // Now-playing row occupies AppKit y = 212...240; Row 0 shifts to y = 126...202; Row 1 shifts to y = 34...110.
        let topLeftWithNowPlaying = makeInjectedTopLeftSlotFrames(gridTopY: 90)
        let windowFramesWithNowPlaying = NotchPanelLayout.appKitWindowSlotFrames(
            fromTopLeftSlotFrames: topLeftWithNowPlaying,
            windowHeight: windowHeight
        )

        for (slotIdx, frame) in windowFramesWithoutNowPlaying {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: center, slotFrames: windowFramesWithoutNowPlaying),
                slotIdx
            )
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(
                    at: center,
                    topLeftSlotFrames: topLeftWithoutNowPlaying,
                    windowHeight: windowHeight
                ),
                slotIdx
            )
        }

        for (slotIdx, frame) in windowFramesWithNowPlaying {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: center, slotFrames: windowFramesWithNowPlaying),
                slotIdx
            )
        }

        for col in 0..<4 {
            let colCenterX = originX + CGFloat(col) * (tileSide + gridSpacing) + tileSide / 2

            // Point in the now-playing / transport bar (AppKit y = 226):
            // hits Row 0 when no track row is shown, and returns nil (never hits Row 0) when now-playing is shown.
            let nowPlayingPoint = CGPoint(x: colCenterX, y: 226)
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: nowPlayingPoint, slotFrames: windowFramesWithoutNowPlaying),
                col
            )
            XCTAssertNil(
                NotchPanelLayout.hitTestSlotIndex(at: nowPlayingPoint, slotFrames: windowFramesWithNowPlaying)
            )

            // Point at AppKit y = 136:
            // lands in Row 1 (slots 4..7) without now-playing, but lands in shifted Row 0 (slots 0..3) with now-playing.
            let overlapBandPoint = CGPoint(x: colCenterX, y: 136)
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: overlapBandPoint, slotFrames: windowFramesWithoutNowPlaying),
                4 + col
            )
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: overlapBandPoint, slotFrames: windowFramesWithNowPlaying),
                col
            )

            // Point in lower portion of shifted Row 1 (AppKit y = 50):
            // below the grid without now-playing (nil), inside Row 1 (slots 4..7) with now-playing.
            let lowerShiftedRowPoint = CGPoint(x: colCenterX, y: 50)
            XCTAssertNil(
                NotchPanelLayout.hitTestSlotIndex(at: lowerShiftedRowPoint, slotFrames: windowFramesWithoutNowPlaying)
            )
            XCTAssertEqual(
                NotchPanelLayout.hitTestSlotIndex(at: lowerShiftedRowPoint, slotFrames: windowFramesWithNowPlaying),
                4 + col
            )
        }

        // Inter-column and inter-row gaps and empty frame maps must return nil.
        let columnGapX = originX + tileSide + gridSpacing / 2
        XCTAssertNil(
            NotchPanelLayout.hitTestSlotIndex(
                at: CGPoint(x: columnGapX, y: 190),
                slotFrames: windowFramesWithoutNowPlaying
            )
        )
        XCTAssertNil(
            NotchPanelLayout.hitTestSlotIndex(
                at: CGPoint(x: originX + 20, y: 156),
                slotFrames: windowFramesWithoutNowPlaying
            )
        )
        XCTAssertNil(
            NotchPanelLayout.hitTestSlotIndex(
                at: CGPoint(x: originX + 20, y: 118),
                slotFrames: windowFramesWithNowPlaying
            )
        )
        XCTAssertNil(NotchPanelLayout.hitTestSlotIndex(at: CGPoint(x: 70, y: 180), slotFrames: [:]))
    }

    func testKeepOpenPolicyForVolumeStepsAndTransportActions() {
        let keepOpenActions: [SystemQuickAction] = [
            .volumeUp,
            .volumeDown,
            .mediaPrevious,
            .mediaPlayPause,
            .mediaNext
        ]
        for action in keepOpenActions {
            XCTAssertTrue(NotchPanelLayout.keepsPanelOpenAfterAction(action), "Expected \(action) to keep panel open")
        }

        let dismissingActions: [SystemQuickAction] = [
            .volumeMute,
            .maximizeWindow,
            .snapWindowLeft,
            .screenshotInteractive,
            .missionControl,
            .lockScreen,
            .copySelection
        ]
        for action in dismissingActions {
            XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterAction(action), "Expected \(action) to allow dismiss")
        }

        var profile = ChocliftDefaults.makeDefaultProfile()
        let volUpItem = BarItem(kind: .systemAction(action: .volumeUp))
        let nextItem = BarItem(kind: .systemAction(action: .mediaNext))
        let appItem = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        _ = profile.setSlotItem(volUpItem, pageIndex: 0, slotIndex: 0)
        _ = profile.setSlotItem(appItem, pageIndex: 0, slotIndex: 1)

        let page0ID = profile.pages[0].id
        let refToVolUp = BarItem(kind: .slotReference(targetPageID: page0ID, targetSlotIndex: 0))
        let refToApp = BarItem(kind: .slotReference(targetPageID: page0ID, targetSlotIndex: 1))

        XCTAssertTrue(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: volUpItem, in: profile))
        XCTAssertTrue(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: nextItem, in: profile))
        XCTAssertTrue(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: refToVolUp, in: profile))
        XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: appItem, in: profile))
        XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: refToApp, in: profile))
        XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterSlotTrigger(item: nil, in: profile))
    }
}
