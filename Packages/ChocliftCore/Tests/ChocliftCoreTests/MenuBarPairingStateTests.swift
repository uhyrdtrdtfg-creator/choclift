import XCTest
@testable import ChocliftCore

final class MenuBarPairingStateTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testActivePairingPINIsNilWhenIdleUpdatesLiveAndRetiresConsumedPIN() async throws {
        let suiteName = "com.choclift.tests.menubar.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = MenuBarPairingTestDelegate()
        let server = MacServerEngine(macID: "mac-menu-1", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        XCTAssertFalse(server.hasActivePairingSession)
        XCTAssertNil(server.activePairingPIN)

        let phone = CompanionClientEngine(
            deviceID: "iphone-menu-1",
            deviceName: "iPhone Menu",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-menu-1"
        )
        defer { phone.disconnect() }

        let btHost = DiscoveredBluetoothMac(
            id: UUID(),
            name: "Studio Mac",
            macID: "mac-menu-1"
        )
        phone.simulatedBluetoothConnector = { _ in
            server.acceptInMemoryCompanion()
        }
        phone.simulateDiscoveredBluetoothMacs([btHost], autoConnect: false)
        phone.connectBluetooth(to: btHost)

        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .awaitingPIN = phone.connectionState else {
            return XCTFail("Expected unpaired companion to enter .awaitingPIN")
        }

        XCTAssertTrue(server.hasActivePairingSession)
        let firstLivePIN = try XCTUnwrap(server.activePairingPIN)
        XCTAssertEqual(firstLivePIN, server.currentPIN)
        XCTAssertEqual(firstLivePIN.count, 6)

        // Regenerating PIN while pairing updates activePairingPIN live to a distinct code
        server.regeneratePIN()
        let refreshedLivePIN = try XCTUnwrap(server.activePairingPIN)
        XCTAssertNotEqual(refreshedLivePIN, firstLivePIN)
        XCTAssertEqual(refreshedLivePIN, server.currentPIN)

        // Old PIN must be rejected while pairing stays active
        phone.submitPIN(firstLivePIN)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(server.hasActivePairingSession)
        XCTAssertEqual(server.activePairingPIN, refreshedLivePIN)

        // Submitting the live PIN completes pairing, hides activePairingPIN, and rotates currentPIN
        phone.submitPIN(refreshedLivePIN)
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)
        XCTAssertFalse(server.hasActivePairingSession)
        XCTAssertNil(server.activePairingPIN)
        XCTAssertNotEqual(server.currentPIN, refreshedLivePIN, "Consumed one-time PIN must be retired immediately")

        // Reconnecting an already-paired companion with saved token must not expose activePairingPIN
        phone.disconnect()
        for _ in 0..<30 where server.connectedDeviceCount > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(server.activePairingPIN)

        phone.simulateDiscoveredBluetoothMacs([btHost], autoConnect: false)
        XCTAssertTrue(phone.reconnectFromDisconnectedBanner())
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)
        XCTAssertFalse(server.hasActivePairingSession)
        XCTAssertNil(server.activePairingPIN)

        // Pairing a second companion while the first stays connected exposes the fresh live PIN
        let ipad = CompanionClientEngine(
            deviceID: "ipad-menu-2",
            deviceName: "iPad Menu",
            platform: .iPad,
            userDefaults: defaults,
            storageKeyPrefix: "ipad-menu-2"
        )
        defer { ipad.disconnect() }
        ipad.simulatedBluetoothConnector = { _ in
            server.acceptInMemoryCompanion()
        }
        ipad.simulateDiscoveredBluetoothMacs([btHost], autoConnect: false)
        ipad.connectBluetooth(to: btHost)

        for _ in 0..<50 {
            if case .awaitingPIN = ipad.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(server.hasActivePairingSession)
        let secondCompanionPIN = try XCTUnwrap(server.activePairingPIN)
        XCTAssertNotEqual(secondCompanionPIN, refreshedLivePIN)
    }

    @MainActor
    func testActivePairingPINClearsOnCompanionDisconnectAndIdleSweep() async throws {
        let suiteName = "com.choclift.tests.menubar.cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = MenuBarPairingTestDelegate()
        let server = MacServerEngine(macID: "mac-menu-2", macName: "Studio Mac")
        server.delegate = delegate
        server.bluetoothPairingTimeoutSeconds = 0.12
        server.heartbeatSweepIntervalSeconds = 0.03
        defer { server.stop() }

        let btHost = DiscoveredBluetoothMac(
            id: UUID(),
            name: "Studio Mac",
            macID: "mac-menu-2"
        )
        let watch = CompanionClientEngine(
            deviceID: "watch-menu-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch-menu-1"
        )
        watch.simulatedBluetoothConnector = { _ in
            server.acceptInMemoryCompanion()
        }
        watch.simulateDiscoveredBluetoothMacs([btHost], autoConnect: false)
        watch.connectBluetooth(to: btHost)

        for _ in 0..<50 where !server.hasActivePairingSession {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(server.hasActivePairingSession)
        XCTAssertNotNil(server.activePairingPIN)

        // Cancelling/disconnecting on the companion clears activePairingPIN immediately
        watch.disconnect()
        for _ in 0..<50 where server.hasActivePairingSession {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(server.hasActivePairingSession)
        XCTAssertNil(server.activePairingPIN)

        // Abandoned raw transport that stops heartbeating is swept after pairing timeout
        let rawTransport = server.acceptInMemoryCompanion()
        rawTransport.start()
        let helloFrame = try WireFrameCodec.encode(
            ClientMessage.hello(
                protocolVersion: ChocliftDefaults.protocolVersion,
                deviceID: "abandoned-phone",
                deviceName: "Abandoned iPhone",
                platform: .iPhone,
                savedAuthToken: nil
            )
        )
        rawTransport.send(helloFrame)

        for _ in 0..<50 where !server.hasActivePairingSession {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(server.hasActivePairingSession)
        XCTAssertNotNil(server.activePairingPIN)

        for _ in 0..<50 where server.hasActivePairingSession {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(server.hasActivePairingSession)
        XCTAssertNil(server.activePairingPIN)
        rawTransport.cancel()
    }
    #endif
}

#if os(macOS)
@MainActor
private final class MenuBarPairingTestDelegate: MacServerEngineDelegate {
    let profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()

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
    ) {}
}
#endif
