import Foundation
import XCTest
@testable import ChocliftCore
#if os(macOS)
import CoreGraphics
import Carbon.HIToolbox
#endif

@MainActor
final class SpacesAndAppSwitcherTests: XCTestCase {

    func testRawIDsMetadataAndWorkspaceSlotSectionPlacement() {
        XCTAssertEqual(SystemQuickAction.switchToNextSpace.rawValue, "switch_to_next_space")
        XCTAssertEqual(SystemQuickAction.switchToPreviousSpace.rawValue, "switch_to_previous_space")
        XCTAssertEqual(SystemQuickAction.toggleAppSwitcher.rawValue, "toggle_app_switcher")

        let actions: [SystemQuickAction] = [.switchToNextSpace, .switchToPreviousSpace, .toggleAppSwitcher]
        for action in actions {
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertNotEqual(action.title(in: .english), action.title(in: .chinese))
            XCTAssertFalse(action.compactTitle(in: .english).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .chinese).isEmpty)
            XCTAssertNotEqual(action.compactTitle(in: .english), action.compactTitle(in: .chinese))
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertEqual(action.accentHex, "#FFF1EC")
            XCTAssertFalse(action.isWindowAction)
            XCTAssertFalse(action.isUndoableWindowMove)
            XCTAssertFalse(action.targetsApplication)
            XCTAssertFalse(action.supportsHoldToRepeat)
            XCTAssertFalse(NotchPanelLayout.keepsPanelOpenAfterAction(action))
        }

        XCTAssertNil(SystemQuickAction.switchToNextSpace.sentKeyboardShortcut)
        XCTAssertNil(SystemQuickAction.switchToPreviousSpace.sentKeyboardShortcut)
        XCTAssertEqual(SystemQuickAction.toggleAppSwitcher.sentKeyboardShortcut, "⌘Tab")

        for compact in [false, true] {
            let sectionsEN = SystemQuickAction.slotActionSections(in: .english, compactHeaders: compact)
            let workspaceEN = sectionsEN.first { $0.0 == "Workspace & System" }
            XCTAssertNotNil(workspaceEN)
            for action in actions {
                XCTAssertTrue(workspaceEN?.1.contains(action) == true, "\(action) missing from Workspace & System")
                XCTAssertFalse(SystemQuickAction.windowLayoutSlotActions.contains(action))
            }

            let sectionsZH = SystemQuickAction.slotActionSections(in: .chinese, compactHeaders: compact)
            let workspaceZH = sectionsZH.first { $0.0 == "桌面与系统控制" }
            XCTAssertNotNil(workspaceZH)
            for action in actions {
                XCTAssertTrue(workspaceZH?.1.contains(action) == true)
            }
        }
    }

    func testOneTapConfirmationPolicyPreservesLockScreenAsOnlyDestructiveAction() {
        let profile = ChocliftDefaults.makeDefaultProfile()
        var gate = DestructiveActionConfirmGate()

        for action in [SystemQuickAction.switchToNextSpace, .switchToPreviousSpace, .toggleAppSwitcher] {
            XCTAssertFalse(action.requiresDestructiveConfirmation)
            let barItem = BarItem(kind: .systemAction(action: action))
            XCTAssertFalse(barItem.requiresDestructiveConfirmation(in: profile))
            let flow = ActionFlow(name: action.rawValue, steps: [ActionFlowStep(kind: .systemAction(action: action))])
            XCTAssertFalse(flow.requiresDestructiveConfirmation)
            XCTAssertEqual(
                gate.registerTap(targetID: action.rawValue, isDestructive: action.requiresDestructiveConfirmation, at: 10.0),
                .runImmediately
            )
        }

        XCTAssertTrue(SystemQuickAction.lockScreen.requiresDestructiveConfirmation)
        XCTAssertTrue(BarItem(kind: .systemAction(action: .lockScreen)).requiresDestructiveConfirmation(in: profile))
        XCTAssertEqual(
            gate.registerTap(
                targetID: SystemQuickAction.lockScreen.rawValue,
                isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
                at: 20.0
            ),
            .requireSecondTap(expiresAt: 23.0)
        )
    }

    func testWireAndPersistenceRoundTripForSpacesAndAppSwitcher() throws {
        for action in [SystemQuickAction.switchToNextSpace, .switchToPreviousSpace, .toggleAppSwitcher] {
            let slotItem = BarItem(kind: .systemAction(action: action))
            let decodedSlot = try JSONDecoder().decode(BarItem.self, from: JSONEncoder().encode(slotItem))
            XCTAssertEqual(decodedSlot, slotItem)

            let step = ActionFlowStep(kind: .systemAction(action: action))
            let decodedStep = try JSONDecoder().decode(ActionFlowStep.self, from: JSONEncoder().encode(step))
            XCTAssertEqual(decodedStep, step)

            let framed = try WireFrameCodec.encode(ClientMessage.performQuickAction(action))
            var stream = WireStreamAccumulator()
            let payloads = try stream.appendAndExtractPayloads(framed)
            XCTAssertEqual(payloads.count, 1)
            let decodedMessage = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
            XCTAssertEqual(decodedMessage, .performQuickAction(action))
        }
    }

    #if os(macOS)
    func testMacWorkspaceShortcutKeystrokeRoutingAndAccessibilityGate() throws {
        XCTAssertNil(WorkspaceShortcutKeystrokeRouting.keystroke(for: .switchToNextSpace))
        XCTAssertNil(WorkspaceShortcutKeystrokeRouting.keystroke(for: .switchToPreviousSpace))

        let switcher = try XCTUnwrap(WorkspaceShortcutKeystrokeRouting.keystroke(for: .toggleAppSwitcher))
        XCTAssertEqual(switcher.virtualKey, CGKeyCode(kVK_Tab))
        XCTAssertEqual(switcher.flags, .maskCommand)

        XCTAssertNil(WorkspaceShortcutKeystrokeRouting.keystroke(for: .quitApp))
        XCTAssertNil(WorkspaceShortcutKeystrokeRouting.keystroke(for: .switchToNextWindow))

        var posted: [(CGKeyCode, CGEventFlags)] = []
        for action in [SystemQuickAction.switchToNextSpace, .switchToPreviousSpace, .toggleAppSwitcher] {
            let denied = WorkspaceShortcutKeystrokeRouting.execute(
                action,
                ensureAccessibility: { false },
                deniedResult: { (false, "Accessibility permission is required to send shortcuts") },
                postKeyStroke: { posted.append(($0, $1)) }
            )
            XCTAssertFalse(denied.success)
            XCTAssertEqual(denied.message, "Accessibility permission is required to send shortcuts")
        }
        XCTAssertTrue(posted.isEmpty)

        for action in [SystemQuickAction.switchToNextSpace, .switchToPreviousSpace] {
            let skipped = WorkspaceShortcutKeystrokeRouting.execute(
                action,
                ensureAccessibility: { true },
                deniedResult: { (false, "Denied") },
                postKeyStroke: { posted.append(($0, $1)) }
            )
            XCTAssertFalse(skipped.success)
        }
        let switcherResult = WorkspaceShortcutKeystrokeRouting.execute(
            .toggleAppSwitcher,
            ensureAccessibility: { true },
            deniedResult: { (false, "Denied") },
            postKeyStroke: { posted.append(($0, $1)) }
        )
        XCTAssertTrue(switcherResult.success)

        XCTAssertEqual(posted.count, 1, "Only the app switcher still posts a keystroke")
        XCTAssertEqual(posted[0].0, CGKeyCode(kVK_Tab))
        XCTAssertEqual(posted[0].1, .maskCommand)
    }

    func testCompanionPerformQuickActionDeliversSpacesAndAppSwitcherOverPipe() async throws {
        let suiteName = "com.choclift.tests.spaces.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = SpacesWireTestDelegate()
        let server = MacServerEngine(macID: "mac-spaces-host", macName: "Spaces Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-spaces",
            deviceName: "iPhone Spaces",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "cli"
        )
        defer { phone.disconnect() }

        let btHost = DiscoveredBluetoothMac(id: UUID(), name: "Spaces Mac", macID: "mac-spaces-host")
        phone.simulatedBluetoothConnector = { _ in
            let serverEnd = server.acceptInMemoryCompanion()
            let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
            proxy.onPayload = { serverEnd.send($0) }
            serverEnd.onPayload = { proxy.send($0) }
            serverEnd.onClosed = { proxy.cancel() }
            proxy.start()
            serverEnd.start()
            return clientEnd
        }
        phone.simulateDiscoveredBluetoothMacs([btHost])
        phone.connectBluetooth(to: btHost)

        for _ in 0..<60 {
            if case .awaitingPIN = phone.connectionState { break }
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        phone.submitPIN(server.currentPIN)
        for _ in 0..<60 where !phone.connectionState.isConnected {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        let expected: [SystemQuickAction] = [.switchToPreviousSpace, .switchToNextSpace, .toggleAppSwitcher]
        for action in expected {
            phone.performQuickAction(action)
        }
        for _ in 0..<60 where delegate.receivedQuickActions.count < expected.count {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.receivedQuickActions, expected)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class SpacesWireTestDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var receivedQuickActions: [SystemQuickAction] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.apple.finder" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        if case .performQuickAction(let action) = message {
            receivedQuickActions.append(action)
            reply(.actionFeedback(success: true, title: action.title(in: .english), detail: nil))
        }
    }
}
#endif
