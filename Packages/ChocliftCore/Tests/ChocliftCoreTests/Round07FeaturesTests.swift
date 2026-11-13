import Combine
import Foundation
import XCTest
@testable import ChocliftCore

final class Round07FeaturesTests: XCTestCase {
    // MARK: - 1. Read-Only Mac Battery Text (Charging, Not Charging, No Battery)

    func testMacBatteryDisplayTextForChargingNotChargingAndNoBattery() throws {
        let charging = MacBatteryStatus.battery(percent: 82, isCharging: true)
        XCTAssertTrue(charging.hasBattery)
        XCTAssertEqual(charging.chargePercent, 82)
        XCTAssertTrue(charging.isCharging)
        XCTAssertEqual(charging.displayText(in: .english), "82% · Charging")
        XCTAssertEqual(charging.displayText(in: .chinese), "82% · 充电中")
        XCTAssertEqual(charging.sfSymbol, "battery.100.bolt")

        let notCharging = MacBatteryStatus.battery(percent: 64, isCharging: false, isOnACPower: false)
        XCTAssertTrue(notCharging.hasBattery)
        XCTAssertEqual(notCharging.chargePercent, 64)
        XCTAssertFalse(notCharging.isCharging)
        XCTAssertEqual(notCharging.displayText(in: .english), "64% · Not charging")
        XCTAssertEqual(notCharging.displayText(in: .chinese), "64% · 未充电")
        XCTAssertEqual(notCharging.sfSymbol, "battery.75")

        let noBattery = MacBatteryStatus.powerAdapter
        XCTAssertFalse(noBattery.hasBattery)
        XCTAssertNil(noBattery.chargePercent)
        XCTAssertFalse(noBattery.isCharging)
        XCTAssertTrue(noBattery.isOnACPower)
        XCTAssertEqual(noBattery.displayText(in: .english), "Power adapter")
        XCTAssertEqual(noBattery.displayText(in: .chinese), "电源适配器")
        XCTAssertEqual(noBattery.sfSymbol, "powerplug.fill")

        // Clamping & IOKit dictionary parsing
        let clampedLow = MacBatteryStatus.battery(percent: -15, isCharging: false)
        XCTAssertEqual(clampedLow.chargePercent, 0)
        XCTAssertEqual(clampedLow.displayText(in: .english), "0% · Not charging")
        XCTAssertEqual(clampedLow.sfSymbol, "battery.0")

        let clampedHigh = MacBatteryStatus.battery(percent: 140, isCharging: true)
        XCTAssertEqual(clampedHigh.chargePercent, 100)
        XCTAssertEqual(clampedHigh.displayText(in: .english), "100% · Charging")

        let parsedLaptopCharging = MacBatteryStatus.fromPowerSourceDescriptions([
            [
                "Type": "InternalBattery",
                "Is Present": true,
                "Current Capacity": 45,
                "Max Capacity": 100,
                "Is Charging": true,
                "Power Source State": "AC Power"
            ]
        ])
        XCTAssertEqual(parsedLaptopCharging, .battery(percent: 45, isCharging: true, isOnACPower: true))
        XCTAssertEqual(parsedLaptopCharging.displayText(in: .english), "45% · Charging")

        let parsedLaptopUnplugged = MacBatteryStatus.fromPowerSourceDescriptions([
            [
                "Type": "InternalBattery",
                "Is Present": true,
                "Current Capacity": 91,
                "Max Capacity": 100,
                "Is Charging": false,
                "Power Source State": "Battery Power"
            ]
        ])
        XCTAssertEqual(parsedLaptopUnplugged, .battery(percent: 91, isCharging: false, isOnACPower: false))
        XCTAssertEqual(parsedLaptopUnplugged.displayText(in: .english), "91% · Not charging")

        let parsedDesktopNoBattery = MacBatteryStatus.fromPowerSourceDescriptions([])
        XCTAssertEqual(parsedDesktopNoBattery, .powerAdapter)
        XCTAssertEqual(parsedDesktopNoBattery.displayText(in: .english), "Power adapter")

        let parsedDesktopWithExternalUPSOnly = MacBatteryStatus.fromPowerSourceDescriptions([
            [
                "Type": "UPS",
                "Is Present": true,
                "Current Capacity": 100,
                "Max Capacity": 100,
                "Is Charging": false
            ]
        ])
        XCTAssertEqual(parsedDesktopWithExternalUPSOnly, .powerAdapter)
        XCTAssertEqual(parsedDesktopWithExternalUPSOnly.displayText(in: .english), "Power adapter")

        // ControlStripState Codable round-trip & backward compatibility
        let strip = ControlStripState(
            macBattery: charging,
            areFinderDesktopIconsVisible: false
        )
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(ControlStripState.self, from: data)
        XCTAssertEqual(decoded.macBattery, charging)
        XCTAssertFalse(decoded.areFinderDesktopIconsVisible)

        let legacyStrip = try JSONDecoder().decode(ControlStripState.self, from: Data("{}".utf8))
        XCTAssertNil(legacyStrip.macBattery)
        XCTAssertTrue(legacyStrip.areFinderDesktopIconsVisible)
    }

    // MARK: - 2. Awake-Reason Line Present Only While Assertion Is On

    func testAwakeReasonLinePresentOnlyWhileAssertionIsOn() {
        // Direct formatter
        XCTAssertNil(MacAwakeReasonFormatter.reasonLine(isAssertionActive: false, language: .english))
        XCTAssertNil(MacAwakeReasonFormatter.reasonLine(isAssertionActive: false, language: .chinese))
        XCTAssertEqual(
            MacAwakeReasonFormatter.reasonLine(isAssertionActive: true, language: .english),
            "Choclift is keeping the Mac awake"
        )
        XCTAssertEqual(
            MacAwakeReasonFormatter.reasonLine(isAssertionActive: true, language: .chinese),
            "Choclift 正在保持 Mac 唤醒"
        )

        // Phone control strip state
        var strip = ControlStripState(isKeepMacAwakeEnabled: false)
        XCTAssertNil(strip.awakeReasonLine(in: .english))
        XCTAssertNil(strip.awakeReasonLine(in: .chinese))

        strip.isKeepMacAwakeEnabled = true
        XCTAssertEqual(strip.awakeReasonLine(in: .english), "Choclift is keeping the Mac awake")
        XCTAssertEqual(strip.awakeReasonLine(in: .chinese), "Choclift 正在保持 Mac 唤醒")

        strip.isKeepMacAwakeEnabled = false
        XCTAssertNil(strip.awakeReasonLine(in: .english))

        // Mac menu-bar status summary
        let menuOff = MacMenuBarStatusSummary(connectedCompanionCount: 1, isKeepAwakeOn: false)
        XCTAssertNil(menuOff.awakeReasonLine(in: .english))
        XCTAssertNil(menuOff.awakeReasonLine(in: .chinese))
        XCTAssertEqual(
            menuOff.menuStatusLines(in: .english),
            ["1 Companion Connected", "Keep Awake: Off"]
        )
        XCTAssertFalse(menuOff.tooltipText(in: .english).contains("Choclift is keeping the Mac awake"))

        let menuOn = MacMenuBarStatusSummary(connectedCompanionCount: 1, isKeepAwakeOn: true)
        XCTAssertEqual(menuOn.awakeReasonLine(in: .english), "Choclift is keeping the Mac awake")
        XCTAssertEqual(menuOn.awakeReasonLine(in: .chinese), "Choclift 正在保持 Mac 唤醒")
        XCTAssertEqual(
            menuOn.menuStatusLines(in: .english),
            [
                "1 Companion Connected",
                "Keep Awake: On",
                "Choclift is keeping the Mac awake"
            ]
        )
        XCTAssertTrue(menuOn.tooltipText(in: .english).contains("Choclift is keeping the Mac awake"))
    }

    // MARK: - 3. Finder Desktop Icons Copy & Show Desktop Existing Action Path

    func testFinderDesktopIconsCopyMentionsFinderRestartAndShowDesktopUsesExistingSystemAction() throws {
        XCTAssertEqual(
            FinderDesktopIconsToggleCopy.actionTitle(areIconsVisible: true, compact: false, language: .english),
            "Hide Desktop Icons"
        )
        XCTAssertEqual(
            FinderDesktopIconsToggleCopy.actionTitle(areIconsVisible: false, compact: false, language: .english),
            "Show Desktop Icons"
        )
        XCTAssertEqual(
            FinderDesktopIconsToggleCopy.restartNotice(in: .english),
            "Finder will restart"
        )
        XCTAssertTrue(
            FinderDesktopIconsToggleCopy.buttonCombinedLabel(areIconsVisible: true, compact: true, language: .english)
                .contains("Finder will restart")
        )
        XCTAssertTrue(
            FinderDesktopIconsToggleCopy.buttonCombinedLabel(areIconsVisible: false, compact: false, language: .english)
                .contains("Finder will restart")
        )

        XCTAssertTrue(FinderDesktopIconsToggleCopy.parseCreateDesktopValue(nil))
        XCTAssertTrue(FinderDesktopIconsToggleCopy.parseCreateDesktopValue(true))
        XCTAssertFalse(FinderDesktopIconsToggleCopy.parseCreateDesktopValue(false))
        XCTAssertTrue(FinderDesktopIconsToggleCopy.parseCreateDesktopValue(1))
        XCTAssertFalse(FinderDesktopIconsToggleCopy.parseCreateDesktopValue(0))
        XCTAssertFalse(FinderDesktopIconsToggleCopy.parseCreateDesktopValue("false"))
        XCTAssertFalse(FinderDesktopIconsToggleCopy.parseCreateDesktopValue("NO"))
        XCTAssertTrue(FinderDesktopIconsToggleCopy.parseCreateDesktopValue("true"))

        // Show Desktop uses the existing `SystemQuickAction.showDesktop` wire message and requires 1 tap (not destructive)
        let item = BarItem(kind: .systemAction(action: .showDesktop))
        let profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertFalse(item.requiresDestructiveConfirmation(in: profile))

        let encodedShowDesktop = try WireFrameCodec.encode(ClientMessage.performQuickAction(.showDesktop))
        let decodedShowDesktop = try WireFrameCodec.decodePayload(
            ClientMessage.self,
            from: Data(encodedShowDesktop.dropFirst(4))
        )
        XCTAssertEqual(decodedShowDesktop, ClientMessage.performQuickAction(.showDesktop))
    }

    // MARK: - 4. One-Tap Banner Reconnect with Saved Token + End-to-End Round 7 Wire Flow

    #if os(macOS)
    @MainActor
    func testLoopbackOneTapReconnectWithSavedTokenBatteryAwakeFinderIconsShowDesktopAndUnknownFrames() async throws {
        let suiteName = "com.choclift.tests.round07.wire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round07WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r7-host", macName: "Studio Mac R7")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        // 1. Unknown PRE-AUTH frame still disconnects immediately
        let unauthServerEnd = server.acceptInMemoryCompanion()
        let (unauthProxy, unauthClientEnd) = InMemoryCompanionPipe.pair()
        var unauthClosed = false
        unauthProxy.onPayload = { unauthServerEnd.send($0) }
        unauthServerEnd.onPayload = { unauthProxy.send($0) }
        unauthServerEnd.onClosed = { unauthProxy.cancel() }
        unauthClientEnd.onClosed = { unauthClosed = true }
        unauthProxy.start()
        unauthServerEnd.start()
        unauthClientEnd.start()

        let unknownClientJSON = Data(#"{"futureRound108ClientCommand":{"flag":true}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Unknown pre-auth frame must disconnect immediately")

        // 2. Unpaired phone cannot one-tap reconnect from banner
        let phone = CompanionClientEngine(
            deviceID: "iphone-r7",
            deviceName: "iPhone R7",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r7"
        )
        defer { phone.disconnect() }
        XCTAssertFalse(phone.canOneTapReconnectFromBanner)
        XCTAssertFalse(phone.reconnectFromDisconnectedBanner())

        // Wire simulated Bluetooth discovery + connector so `reconnectFromDisconnectedBanner()` dials a fresh pipe
        let btPeripheralID = UUID()
        let btHost = DiscoveredBluetoothMac(
            id: btPeripheralID,
            name: "Studio Mac R7",
            macID: "mac-r7-host"
        )
        var latestClientPipeEnd: InMemoryCompanionPipe?
        phone.simulatedBluetoothConnector = { _ in
            let serverEnd = server.acceptInMemoryCompanion()
            let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
            proxy.onPayload = { serverEnd.send($0) }
            serverEnd.onPayload = { proxy.send($0) }
            serverEnd.onClosed = { proxy.cancel() }
            proxy.start()
            serverEnd.start()
            latestClientPipeEnd = clientEnd
            return clientEnd
        }
        phone.simulateDiscoveredBluetoothMacs([btHost])

        // Initial pairing requires 6-digit PIN once
        phone.connectBluetooth(to: btHost)
        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if case .awaitingPIN = phone.connectionState {
            phone.submitPIN(server.currentPIN)
        } else {
            XCTFail("Expected initial pairing to request PIN")
        }

        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)
        XCTAssertEqual(phone.savedMacs.count, 1)

        // 3. Disconnect, rotate Mac PIN, and verify one-tap banner reconnect uses saved token WITHOUT asking for PIN again
        phone.disconnect()
        server.regeneratePIN()
        phone.simulateDiscoveredBluetoothMacs([btHost])
        XCTAssertEqual(phone.connectionState, .disconnected)
        XCTAssertTrue(phone.canOneTapReconnectFromBanner)
        XCTAssertNil(phone.controlStripState.macBattery)
        XCTAssertNil(phone.controlStripState.awakeReasonLine(in: .english))

        var observedStatesDuringReconnect: [CompanionConnectionState] = []
        let cancellable = phone.$connectionState.sink { state in
            observedStatesDuringReconnect.append(state)
        }
        defer { cancellable.cancel() }

        XCTAssertTrue(phone.reconnectFromDisconnectedBanner())
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected, "Banner tap must reconnect using saved token")
        let askedForPINAgain = observedStatesDuringReconnect.contains { state in
            if case .awaitingPIN = state { return true }
            return false
        }
        XCTAssertFalse(askedForPINAgain, "One-tap reconnect must NOT ask for the PIN again")

        // 4. Verify Mac battery sync, Keep-Awake reason sync, Finder desktop icons toggle, and Show Desktop quick action
        for _ in 0..<50 where phone.controlStripState.macBattery == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            phone.controlStripState.macBattery?.displayText(in: .english),
            "Power adapter"
        )
        XCTAssertNil(phone.controlStripState.awakeReasonLine(in: .english))

        phone.setKeepMacAwake(true)
        for _ in 0..<50 where !phone.controlStripState.isKeepMacAwakeEnabled || !delegate.stripState.isKeepMacAwakeEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            phone.controlStripState.awakeReasonLine(in: .english),
            "Choclift is keeping the Mac awake"
        )

        phone.toggleFinderDesktopIcons()
        for _ in 0..<50 where phone.controlStripState.areFinderDesktopIconsVisible {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(phone.controlStripState.areFinderDesktopIconsVisible)
        XCTAssertEqual(delegate.finderIconsCommands, [false])

        phone.performQuickAction(.showDesktop)
        for _ in 0..<50 where delegate.receivedQuickActions.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.receivedQuickActions, [.showDesktop])

        // 5. Unknown POST-AUTH frame stays non-fatal
        latestClientPipeEnd?.send(unknownClientFrame)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frame must remain non-fatal")
    }
    #endif
}

#if os(macOS)
@MainActor
private final class Round07WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var stripState = ControlStripState(
        isKeepMacAwakeEnabled: false,
        macBattery: .powerAdapter,
        areFinderDesktopIconsVisible: true
    )
    var finderIconsCommands: [Bool] = []
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
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(stripState))

        case .setKeepMacAwake(let enabled):
            stripState.isKeepMacAwakeEnabled = enabled
            server?.broadcastControlStripState(stripState)
            reply(.controlStripStateUpdated(stripState))
            reply(.actionFeedback(success: true, title: "Keep Mac Awake", detail: nil))

        case .setFinderDesktopIconsVisible(let visible):
            finderIconsCommands.append(visible)
            stripState.areFinderDesktopIconsVisible = visible
            server?.broadcastControlStripState(stripState)
            reply(.controlStripStateUpdated(stripState))
            reply(.actionFeedback(success: true, title: "Finder Desktop Icons", detail: "Finder restarted"))

        case .performQuickAction(let action):
            receivedQuickActions.append(action)
            reply(.actionFeedback(success: true, title: action.title(in: .english), detail: "Executed"))

        default:
            break
        }
    }
}
#endif
