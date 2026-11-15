import XCTest
@testable import ChocliftCore

final class CompanionActionCatalogTests: XCTestCase {
    func testCatalogListsFiftyUniqueActionsAndRejectsUnknownIds() {
        let ids = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 60)
        XCTAssertEqual(ids.filter { $0.hasPrefix("window.") }.count, 14)
        XCTAssertEqual(ids.filter { $0.hasPrefix("media.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("files.") }.count, 12)
        XCTAssertEqual(ids.filter { $0.hasPrefix("edit.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("system.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("apps.") }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "apps.open_launchpad" }.count, 1)
        XCTAssertNil(CompanionActionCatalog.action(id: "not_a_real_action"))
        XCTAssertFalse(CompanionActionCatalog.isKnown("not_a_real_action"))
    }

    func testPerformCompanionActionRoundTrips() throws {
        let message = ClientMessage.performCompanionAction(id: "window.example")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
        XCTAssertEqual(decoded, message)
    }

    #if os(macOS)
    @MainActor
    func testCompanionActionReachesTheAuthenticatedHandler() async {
        let suiteName = "com.choclift.tests.companion-action.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = CompanionActionWireDelegate()
        let server = MacServerEngine(macID: "mac-actions", macName: "Actions Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-actions",
            deviceName: "iPhone Actions",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "cli"
        )
        defer { phone.disconnect() }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Actions Mac", macID: "mac-actions")
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
        phone.simulateDiscoveredBluetoothMacs([host])
        phone.connectBluetooth(to: host)
        for _ in 0..<60 {
            if case .awaitingPIN = phone.connectionState { break }
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        phone.submitPIN(server.currentPIN)
        for _ in 0..<60 where !phone.connectionState.isConnected {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        phone.performCompanionAction(id: "files.open_desktop")
        for _ in 0..<60 where delegate.receivedActionIDs.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.receivedActionIDs, ["files.open_desktop"])
    }
    #endif
}

#if os(macOS)
@MainActor
private final class CompanionActionWireDelegate: MacServerEngineDelegate {
    var receivedActionIDs: [String] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { ChocliftDefaults.makeDefaultProfile() }
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
        if case .performCompanionAction(let id) = message {
            receivedActionIDs.append(id)
            reply(.actionFeedback(success: true, title: id, detail: nil))
        }
    }
}
#endif
