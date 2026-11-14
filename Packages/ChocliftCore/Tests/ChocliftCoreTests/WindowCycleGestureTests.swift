import XCTest
@testable import ChocliftCore
#if os(macOS)
import CoreGraphics
import Carbon.HIToolbox
#endif
#if os(iOS)
import UIKit
#endif

final class WindowCycleGestureTests: XCTestCase {
    func testDominantAxisAndThreshold() {
        XCTAssertNil(ThreeFingerPanRouting.gesture(translation: CGPoint(x: 51, y: 0)))
        XCTAssertNil(ThreeFingerPanRouting.gesture(translation: CGPoint(x: 60, y: 60)))
        XCTAssertEqual(ThreeFingerPanRouting.gesture(translation: CGPoint(x: -52, y: 20)), .threeFingerSwipeLeft)
        XCTAssertEqual(ThreeFingerPanRouting.gesture(translation: CGPoint(x: 70, y: -55)), .threeFingerSwipeRight)
        XCTAssertEqual(ThreeFingerPanRouting.gesture(translation: CGPoint(x: 20, y: -52)), .threeFingerSwipeUp)
        XCTAssertEqual(ThreeFingerPanRouting.gesture(translation: CGPoint(x: -55, y: 70)), .threeFingerSwipeDown)
    }

    func testDefaultBindingsPreserveTwoFingerSnapping() {
        let config = ChocliftDefaults.makeDefaultGestureConfiguration()
        XCTAssertEqual(config.action(for: .threeFingerSwipeLeft), .switchToPreviousWindow)
        XCTAssertEqual(config.action(for: .threeFingerSwipeRight), .switchToNextWindow)
        XCTAssertEqual(config.action(for: .threeFingerSwipeUp), .missionControl)
        XCTAssertEqual(config.action(for: .threeFingerSwipeDown), .showDesktop)
        XCTAssertEqual(config.action(for: .twoFingerSwipeLeft), .snapWindowLeft)
        XCTAssertEqual(config.action(for: .twoFingerSwipeRight), .snapWindowRight)
    }

    func testExistingProfilesGainWindowCycleBindingsWithoutOverwritingCustomBindings() throws {
        let old = GestureConfiguration(bindings: [GestureBinding(gesture: .twoFingerSwipeLeft, action: .snapWindowLeft)])
        let migrated = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(migrated.action(for: .threeFingerSwipeLeft), .switchToPreviousWindow)
        XCTAssertEqual(migrated.action(for: .threeFingerSwipeRight), .switchToNextWindow)
        let custom = GestureConfiguration(bindings: [GestureBinding(gesture: .threeFingerSwipeLeft, action: .copySelection, isEnabled: false)])
        let preserved = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(custom))
        XCTAssertNil(preserved.action(for: .threeFingerSwipeLeft))
        XCTAssertEqual(preserved.bindings.first?.action, .copySelection)
    }

    #if os(macOS)
    func testWindowCycleKeystrokesWithoutPostingEvents() throws {
        let next = try XCTUnwrap(WindowCycleKeystrokeRouting.keystroke(for: .switchToNextWindow))
        let previous = try XCTUnwrap(WindowCycleKeystrokeRouting.keystroke(for: .switchToPreviousWindow))
        XCTAssertEqual(next.virtualKey, CGKeyCode(kVK_ANSI_Grave))
        XCTAssertEqual(next.flags, .maskCommand)
        XCTAssertEqual(previous.virtualKey, CGKeyCode(kVK_ANSI_Grave))
        XCTAssertEqual(previous.flags, [.maskCommand, .maskShift])
        XCTAssertNil(WindowCycleKeystrokeRouting.keystroke(for: .snapWindowLeft))
    }
    #endif

    #if os(iOS)
    @MainActor func testThreeFingerPanFiresOnlyOncePerGesture() {
        var fired: [TouchGestureType] = []
        let coordinator = CompanionMultiTouchCoordinator { fired.append($0) }
        for (point, expected) in [(CGPoint(x: -60, y: 2), TouchGestureType.threeFingerSwipeLeft),
                                  (CGPoint(x: 60, y: 2), .threeFingerSwipeRight),
                                  (CGPoint(x: 2, y: -60), .threeFingerSwipeUp),
                                  (CGPoint(x: 2, y: 60), .threeFingerSwipeDown)] {
            coordinator.processThreeFingerPan(state: .began, translation: .zero)
            coordinator.processThreeFingerPan(state: .changed, translation: point)
            coordinator.processThreeFingerPan(state: .changed, translation: CGPoint(x: 0, y: 120))
            coordinator.processThreeFingerPan(state: .ended, translation: point)
            XCTAssertEqual(fired.last, expected)
        }
        XCTAssertEqual(fired.count, 4)
    }
    #endif
}
