import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class AppearanceAndNightShiftQuickActionsTests: XCTestCase {

    func testQuickActionRawValuesMetadataAndWorkspaceSectionPlacement() throws {
        XCTAssertEqual(SystemQuickAction.toggleAppearance.rawValue, "toggle_appearance")
        XCTAssertEqual(SystemQuickAction.toggleNightShift.rawValue, "toggle_night_shift")

        for action in [SystemQuickAction.toggleAppearance, .toggleNightShift] {
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertNotEqual(action.title(in: .english), action.title(in: .chinese))
            XCTAssertFalse(action.compactTitle(in: .english).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .chinese).isEmpty)
            XCTAssertNotEqual(action.compactTitle(in: .english), action.compactTitle(in: .chinese))
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertNil(action.sentKeyboardShortcut)
            XCTAssertFalse(action.isWindowAction)
            XCTAssertFalse(action.isUndoableWindowMove)
            XCTAssertFalse(action.targetsApplication)
            XCTAssertFalse(action.supportsHoldToRepeat)
        }

        for compact in [false, true] {
            let sections = SystemQuickAction.slotActionSections(in: .english, compactHeaders: compact)
            let workspaceSection = try XCTUnwrap(sections.first(where: { $0.0 == "Workspace & System" }))
            XCTAssertTrue(workspaceSection.1.contains(.toggleAppearance))
            XCTAssertTrue(workspaceSection.1.contains(.toggleNightShift))
        }

        for action in [SystemQuickAction.toggleAppearance, .toggleNightShift] {
            let framed = try WireFrameCodec.encode(ClientMessage.performQuickAction(action))
            var stream = WireStreamAccumulator()
            let payloads = try stream.appendAndExtractPayloads(framed)
            let decoded = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
            XCTAssertEqual(decoded, .performQuickAction(action))
        }
    }

    func testToggleAppearanceAndNightShiftAreOneTapWhileLockScreenStaysTwoTap() {
        XCTAssertFalse(SystemQuickAction.toggleAppearance.requiresDestructiveConfirmation)
        XCTAssertFalse(SystemQuickAction.toggleNightShift.requiresDestructiveConfirmation)
        XCTAssertTrue(SystemQuickAction.lockScreen.requiresDestructiveConfirmation)

        var gate = DestructiveActionConfirmGate()
        XCTAssertEqual(
            gate.registerTap(
                targetID: SystemQuickAction.toggleAppearance.rawValue,
                isDestructive: SystemQuickAction.toggleAppearance.requiresDestructiveConfirmation,
                at: 10.0
            ),
            .runImmediately
        )
        XCTAssertEqual(
            gate.registerTap(
                targetID: SystemQuickAction.toggleNightShift.rawValue,
                isDestructive: SystemQuickAction.toggleNightShift.requiresDestructiveConfirmation,
                at: 10.2
            ),
            .runImmediately
        )

        let firstLockTap = gate.registerTap(
            targetID: SystemQuickAction.lockScreen.rawValue,
            isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
            at: 20.0
        )
        XCTAssertEqual(
            firstLockTap,
            .requireSecondTap(expiresAt: 20.0 + CompanionInteractionPolicy.destructiveConfirmWindowSeconds)
        )
        XCTAssertEqual(
            gate.registerTap(
                targetID: SystemQuickAction.lockScreen.rawValue,
                isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
                at: 21.0
            ),
            .confirmedRun
        )

        let displayFlow = ActionFlow(
            name: "Lights Out Toggle",
            steps: [
                ActionFlowStep(kind: .systemAction(action: .toggleAppearance)),
                ActionFlowStep(kind: .systemAction(action: .toggleNightShift))
            ]
        )
        XCTAssertFalse(displayFlow.requiresDestructiveConfirmation)
    }

    func testNextInterfaceStyleDecisionAndVerifiedDefaultsExecution() throws {
        XCTAssertEqual(MacAppearanceToggle.nextInterfaceStyleValue(from: nil), "Dark")
        XCTAssertEqual(MacAppearanceToggle.nextInterfaceStyleValue(from: "Light"), "Dark")
        XCTAssertEqual(MacAppearanceToggle.nextInterfaceStyleValue(from: ""), "Dark")
        XCTAssertNil(MacAppearanceToggle.nextInterfaceStyleValue(from: "Dark"))
        XCTAssertNil(MacAppearanceToggle.nextInterfaceStyleValue(from: " dark \n"))

        let suiteName = "com.choclift.tests.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var notificationCount = 0

        // nil -> Dark
        let fromNil = MacAppearanceToggle.perform(in: defaults, language: .english) {
            notificationCount += 1
        }
        XCTAssertTrue(fromNil.success)
        XCTAssertEqual(fromNil.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: MacAppearanceToggle.interfaceStyleKey), "Dark")
        XCTAssertTrue(fromNil.detail.localizedCaseInsensitiveContains("dark"))
        XCTAssertEqual(notificationCount, 1)

        // "Dark" -> light (key deleted)
        let fromDark = MacAppearanceToggle.perform(in: defaults, language: .english) {
            notificationCount += 1
        }
        XCTAssertTrue(fromDark.success)
        XCTAssertEqual(fromDark.mode, .light)
        XCTAssertNil(defaults.object(forKey: MacAppearanceToggle.interfaceStyleKey))
        XCTAssertTrue(fromDark.detail.localizedCaseInsensitiveContains("light"))
        XCTAssertEqual(notificationCount, 2)

        // "Light" -> Dark
        defaults.set("Light", forKey: MacAppearanceToggle.interfaceStyleKey)
        let fromLight = MacAppearanceToggle.perform(in: defaults, language: .chinese) {
            notificationCount += 1
        }
        XCTAssertTrue(fromLight.success)
        XCTAssertEqual(fromLight.mode, .dark)
        XCTAssertEqual(defaults.string(forKey: MacAppearanceToggle.interfaceStyleKey), "Dark")
        XCTAssertTrue(fromLight.detail.contains("深色"))
        XCTAssertEqual(notificationCount, 3)

        // Verification mismatch fails closed
        let unverified = MacAppearanceToggle.perform(
            language: .english,
            readCurrent: { nil },
            writeNext: { _ in true },
            postThemeChangedNotification: {},
            readBack: { nil }
        )
        XCTAssertFalse(unverified.success)
        XCTAssertNil(unverified.mode)
    }

    func testNightShiftToggleVerificationAndFailClosedBehavior() {
        XCTAssertNil(MacNightShiftToggle.parseStatusDictionary(nil))
        XCTAssertNil(MacNightShiftToggle.parseStatusDictionary(["BlueReductionAvailable": 1]))
        XCTAssertEqual(
            MacNightShiftToggle.parseStatusDictionary([
                "BlueReductionAvailable": 1,
                "BlueReductionEnabled": 0
            ]),
            MacNightShiftToggle.StatusSnapshot(isAvailable: true, isEnabled: false)
        )

        var simulatedStatus = MacNightShiftToggle.StatusSnapshot(isAvailable: true, isEnabled: false)
        let turnedOn = MacNightShiftToggle.perform(
            language: .english,
            isSupported: { true },
            readStatus: { simulatedStatus },
            writeEnabled: { next in
                simulatedStatus = MacNightShiftToggle.StatusSnapshot(isAvailable: true, isEnabled: next)
                return true
            }
        )
        XCTAssertTrue(turnedOn.success)
        XCTAssertEqual(turnedOn.isEnabled, true)
        XCTAssertEqual(turnedOn.detail, "Night Shift turned on")

        let turnedOff = MacNightShiftToggle.perform(
            language: .english,
            isSupported: { true },
            readStatus: { simulatedStatus },
            writeEnabled: { next in
                simulatedStatus = MacNightShiftToggle.StatusSnapshot(isAvailable: true, isEnabled: next)
                return true
            }
        )
        XCTAssertTrue(turnedOff.success)
        XCTAssertEqual(turnedOff.isEnabled, false)
        XCTAssertEqual(turnedOff.detail, "Night Shift turned off")

        // Fails closed when unsupported, unavailable, or read-back does not reflect the toggle
        let unsupported = MacNightShiftToggle.perform(
            language: .english,
            isSupported: { false },
            readStatus: { simulatedStatus },
            writeEnabled: { _ in true }
        )
        XCTAssertFalse(unsupported.success)
        XCTAssertEqual(unsupported.detail, "Night Shift could not be toggled on this Mac")

        let staleReadBack = MacNightShiftToggle.perform(
            language: .english,
            isSupported: { true },
            readStatus: { MacNightShiftToggle.StatusSnapshot(isAvailable: true, isEnabled: false) },
            writeEnabled: { _ in true }
        )
        XCTAssertFalse(staleReadBack.success)
        XCTAssertEqual(staleReadBack.detail, "Night Shift could not be toggled on this Mac")
    }
}
