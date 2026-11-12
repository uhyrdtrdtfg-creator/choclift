#if os(macOS) || os(iOS) || os(watchOS)
import CoreBluetooth
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class BluetoothWatchConnectionTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    private final class WatchTestServerDelegate: MacServerEngineDelegate {
        var profile = ChocliftDefaults.makeDefaultProfile()
        var recentApps: [RecentAppEntry] = [
            RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true)
        ]
        var receivedQuickActions: [SystemQuickAction] = []

        func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
        func serverCurrentRecentApps() -> [RecentAppEntry] { recentApps }
        func serverFrontmostBundleID() -> String? { "com.apple.finder" }
        func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, "Finder") }
        func serverIsAccessibilityGranted() -> Bool { true }
        func serverIcons(for bundleIDs: [String]) -> [String: Data] {
            Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, Data([0x89, 0x50, 0x4E, 0x47])) })
        }
        func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}
        func serverDidReceiveAuthenticatedMessage(
            _ message: ClientMessage,
            from device: PairedDeviceRecord,
            reply: @escaping @MainActor (ServerMessage) -> Void
        ) {
            if case .performQuickAction(let action) = message {
                receivedQuickActions.append(action)
                reply(.actionFeedback(success: true, title: action.compactTitle(in: .english), detail: "Executed"))
            }
        }
    }

    func testConnectableAdvertisementPayloadStaysWithin31BytesAndContainsOnlyServiceUUID() {
        let payload = ChocliftBluetooth.makeConnectableAdvertisementData()

        let advertisedUUIDs = payload[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        XCTAssertEqual(
            advertisedUUIDs,
            [ChocliftBluetooth.serviceUUID],
            "Connectable primary advertisement must contain only the single 128-bit Choclift service UUID"
        )
        XCTAssertEqual(ChocliftBluetooth.serviceUUID.data.count, 16)
        XCTAssertNil(
            payload[CBAdvertisementDataLocalNameKey],
            "CBPeripheralManager.startAdvertising provides no separate scan-response parameter, so LocalName must not bloat the primary connectable payload"
        )

        let byteCount = ChocliftBluetooth.connectableAdvertisementByteCount(payload)
        // 3 bytes BLE Flags AD structure + (2-byte AD header + 16-byte 128-bit Service UUID) = 21 bytes
        XCTAssertEqual(byteCount, 21)
        XCTAssertLessThanOrEqual(byteCount, ChocliftBluetooth.maxLegacyConnectableAdvertisingBytes)

        #if os(macOS)
        let advertiser = BluetoothCompanionAdvertiser(
            macID: "mac-watch-adv-001",
            macName: "Xiaobo’s Studio MacBook Pro (16-inch)"
        )
        let macPayload = advertiser.connectableAdvertisementData
        XCTAssertEqual(macPayload[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], [ChocliftBluetooth.serviceUUID])
        XCTAssertNil(macPayload[CBAdvertisementDataLocalNameKey])
        XCTAssertLessThanOrEqual(
            ChocliftBluetooth.connectableAdvertisementByteCount(macPayload),
            ChocliftBluetooth.maxLegacyConnectableAdvertisingBytes
        )
        #endif

        // Verify the calculator detects legacy 31-byte overflow when a second UUID or Mac name is stuffed into startAdvertising
        let twoUUIDOverflowPayload: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [
                ChocliftBluetooth.serviceUUID,
                CBUUID(string: "C40C11F7-9999-4A11-9B2E-43484F434C49")
            ],
            CBAdvertisementDataLocalNameKey: "Xiaobo’s MacBook Pro"
        ]
        XCTAssertGreaterThan(
            ChocliftBluetooth.connectableAdvertisementByteCount(twoUUIDOverflowPayload),
            ChocliftBluetooth.maxLegacyConnectableAdvertisingBytes
        )
    }

    func testWatchScannerAcceptsConnectableSingleUUIDAdvertisementAndResolvesGATTMetadata() throws {
        let browser = BluetoothCompanionBrowser()
        let peripheralID = UUID()

        // Non-connectable downgraded advertisements are dropped by the Watch scanner
        var nonConnectable = ChocliftBluetooth.makeConnectableAdvertisementData()
        nonConnectable[CBAdvertisementDataIsConnectable] = NSNumber(value: false)
        XCTAssertNil(
            browser.ingestAdvertisement(
                peripheralID: peripheralID,
                peripheralName: "Downgraded Mac",
                advertisementData: nonConnectable
            )
        )
        XCTAssertTrue(browser.discovered.isEmpty)

        // Connectable 21-byte single-UUID advertisement (even before scan response supplies peripheralName) is accepted
        var connectable = ChocliftBluetooth.makeConnectableAdvertisementData()
        connectable[CBAdvertisementDataIsConnectable] = NSNumber(value: true)
        let initialHost = try XCTUnwrap(
            browser.ingestAdvertisement(
                peripheralID: peripheralID,
                peripheralName: nil,
                advertisementData: connectable
            )
        )
        XCTAssertEqual(initialHost.id, peripheralID)
        XCTAssertEqual(initialHost.name, "Mac")
        XCTAssertNil(initialHost.macID)
        XCTAssertEqual(browser.discovered, [initialHost])

        // Post-connection GATT metadata characteristic read resolves authoritative macID and macName
        var callbackHost: DiscoveredBluetoothMac?
        browser.onMetadataResolved = { callbackHost = $0 }

        #if os(macOS)
        let advertiser = BluetoothCompanionAdvertiser(
            macID: "mac-gatt-id-777",
            macName: "Studio MacBook Pro"
        )
        let metadataData = advertiser.encodedMetadata()
        #else
        let metadataData = try BluetoothServiceMetadata(
            macID: "mac-gatt-id-777",
            macName: "Studio MacBook Pro"
        ).encodedCharacteristicValue()
        #endif

        let resolved = try XCTUnwrap(
            browser.applyMetadataCharacteristicValue(
                metadataData,
                for: peripheralID,
                fallbackName: initialHost.name
            )
        )
        XCTAssertEqual(resolved.host.macID, "mac-gatt-id-777")
        XCTAssertEqual(resolved.host.name, "Studio MacBook Pro")
        XCTAssertEqual(callbackHost, resolved.host)
        XCTAssertEqual(browser.discovered.first?.macID, "mac-gatt-id-777")

        // Oversized Mac names clamp cleanly within the 512-byte BLE ATT attribute read limit while preserving macID
        let hugeName = String(repeating: "巧", count: 260)
        let clampedData = try BluetoothServiceMetadata(macID: "mac-huge-name", macName: hugeName).encodedCharacteristicValue()
        XCTAssertLessThanOrEqual(clampedData.count, BluetoothServiceMetadata.maxGATTAttributeBytes)
        let decodedClamped = try BluetoothServiceMetadata.decodeCharacteristicValue(clampedData)
        XCTAssertEqual(decodedClamped.macID, "mac-huge-name")
        XCTAssertFalse(decodedClamped.macName.isEmpty)
    }

    #if os(macOS)
    func testAppleWatchBLEConnectPostConnectionMetadataReconnectAndUnpairedProbeSkip() async throws {
        let suiteName = "com.choclift.tests.watchble.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let pairedDelegate = WatchTestServerDelegate()
        let pairedServer = MacServerEngine(macID: "mac-paired-watch", macName: "Xiaobo’s MacBook Pro")
        pairedServer.delegate = pairedDelegate
        defer { pairedServer.stop() }

        let colleagueDelegate = WatchTestServerDelegate()
        let colleagueServer = MacServerEngine(macID: "mac-colleague-unpaired", macName: "Colleague’s MacBook Pro")
        colleagueServer.delegate = colleagueDelegate
        defer { colleagueServer.stop() }

        let browser = BluetoothCompanionBrowser()
        let initialPeripheralID = UUID()
        var adv = pairedServer.isBluetoothAdvertising
            ? ChocliftBluetooth.makeConnectableAdvertisementData()
            : ChocliftBluetooth.makeConnectableAdvertisementData()
        adv[CBAdvertisementDataIsConnectable] = NSNumber(value: true)
        let discoveredInitial = try XCTUnwrap(
            browser.ingestAdvertisement(
                peripheralID: initialPeripheralID,
                peripheralName: nil,
                advertisementData: adv
            )
        )
        XCTAssertNil(discoveredInitial.macID)
        XCTAssertEqual(discoveredInitial.name, "Mac")

        let watch = CompanionClientEngine(
            deviceID: "watch-series-11",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch-ble-fix"
        )
        watch.reconnectDelaySeconds = 0.05
        defer { watch.disconnect() }

        var activePumps: [SimulatedBLECompanionPipe] = []
        let pumpTask = Task { @MainActor in
            while !Task.isCancelled {
                for pipe in activePumps {
                    pipe.pumpReadyToUpdateSubscribers()
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        defer { pumpTask.cancel() }

        var serverByPeripheralID: [UUID: MacServerEngine] = [
            initialPeripheralID: pairedServer
        ]
        var leakedTokensToColleague: [String] = []

        watch.simulatedBluetoothConnector = { host in
            guard let targetServer = serverByPeripheralID[host.id] else { return nil }
            let (serverPipe, clientPipe) = SimulatedBLECompanionPipe.pair(
                mtu: ChocliftBluetooth.minATTChunkSize,
                maxServerChunksPerFlush: 4,
                maxClientChunksPerFlush: 3,
                splitFirstHeaderBytes: 2
            )
            activePumps.append(contentsOf: [serverPipe, clientPipe])
            if targetServer === colleagueServer {
                var wireAcc = WireStreamAccumulator()
                let originalAccept = targetServer
                originalAccept.acceptCompanionTransport(serverPipe, link: .bluetooth)
                let previousOnPayload = serverPipe.onPayload
                serverPipe.onPayload = { data in
                    if let payloads = try? wireAcc.appendAndExtractPayloads(data) {
                        for payload in payloads {
                            if let msg = try? WireFrameCodec.decodePayload(ClientMessage.self, from: payload),
                               case .hello(_, _, _, _, let token?) = msg {
                                leakedTokensToColleague.append(token)
                            }
                        }
                    }
                    previousOnPayload?(data)
                }
            } else {
                targetServer.acceptCompanionTransport(serverPipe, link: .bluetooth)
            }
            return clientPipe
        }

        // 1. Fresh Watch BLE pairing starting from a 1-UUID advertisement with nil macID and generic "Mac" name
        watch.simulateDiscoveredBluetoothMacs([discoveredInitial])
        watch.connectBluetooth(to: discoveredInitial)

        try await waitUntil("Watch resolved Mac metadata and reached awaitingPIN") {
            if case .awaitingPIN(let id, let name, _) = watch.connectionState {
                return id == "mac-paired-watch" && name == "Xiaobo’s MacBook Pro"
            }
            return false
        }

        watch.submitPIN(pairedServer.currentPIN)
        try await waitUntil("Watch authenticated over BLE") {
            watch.connectionState == .connected(macID: "mac-paired-watch", macName: "Xiaobo’s MacBook Pro") &&
            watch.activeLink == .bluetooth &&
            watch.appIconsByBundleID["com.apple.finder"] != nil
        }

        watch.performQuickAction(.mediaPlayPause)
        try await waitUntil("Watch quick action delivered over BLE") {
            pairedDelegate.receivedQuickActions == [.mediaPlayPause]
        }

        // 2. Simulate fresh app launch + rotated PIN + rotated BLE peripheral UUID + an unpaired colleague Mac listed first!
        watch.disconnect()
        pairedServer.regeneratePIN()

        let colleaguePeripheralID = UUID()
        let rotatedPairedPeripheralID = UUID()
        serverByPeripheralID = [
            colleaguePeripheralID: colleagueServer,
            rotatedPairedPeripheralID: pairedServer
        ]

        let relaunchedWatch = CompanionClientEngine(
            deviceID: "watch-series-11",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch-ble-fix"
        )
        relaunchedWatch.simulatedBluetoothConnector = watch.simulatedBluetoothConnector
        defer { relaunchedWatch.disconnect() }

        var sawUnexpectedPINPrompt = false
        // Both peripherals advertise ONLY serviceUUID (name "Mac", macID nil); colleague peripheral appears first
        relaunchedWatch.simulateDiscoveredBluetoothMacs(
            [
                DiscoveredBluetoothMac(id: colleaguePeripheralID, name: "Mac", macID: nil),
                DiscoveredBluetoothMac(id: rotatedPairedPeripheralID, name: "Mac", macID: nil)
            ],
            autoConnect: false
        )
        relaunchedWatch.handleAppDidBecomeActive()

        try await waitUntil("Relaunched Watch skipped colleague Mac via GATT metadata and auto-reconnected to paired Mac") {
            if case .awaitingPIN = relaunchedWatch.connectionState {
                sawUnexpectedPINPrompt = true
            }
            return relaunchedWatch.connectionState == .connected(macID: "mac-paired-watch", macName: "Xiaobo’s MacBook Pro") &&
                relaunchedWatch.activeLink == .bluetooth
        }

        XCTAssertFalse(sawUnexpectedPINPrompt, "Auto-connect probe must never pop PIN entry for an unpaired nearby Mac")
        XCTAssertTrue(leakedTokensToColleague.isEmpty, "Saved auth token must never be sent to an unpaired Mac")
        XCTAssertEqual(relaunchedWatch.savedMacs.first?.lastBluetoothPeripheralID, rotatedPairedPeripheralID)
        XCTAssertEqual(
            relaunchedWatch.discoveredBluetoothMacs.first(where: { $0.id == colleaguePeripheralID })?.macID,
            "mac-colleague-unpaired"
        )
    }

    func testWiFiDropFallsBackToSingleUUIDBluetoothAndResolvesSavedMacPostConnection() async throws {
        let suiteName = "com.choclift.tests.watchfallback.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-wifi-ble-fallback", macName: "Office Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        // Seed credential as if Watch originally paired over Wi-Fi (lastBluetoothPeripheralID is nil!)
        let wifiOnlyCredential = SavedMacCredential(
            macID: "mac-wifi-ble-fallback",
            macName: "Office Studio Mac",
            authToken: "tok-wifi-shared-999",
            lastDirectHost: "127.0.0.1",
            lastDirectPort: 9,
            lastBluetoothPeripheralID: nil
        )
        // Register the same token on the Mac server
        let serverWithPaired = MacServerEngine(
            macID: "mac-wifi-ble-fallback",
            macName: "Office Studio Mac",
            initialPairedDevices: [
                PairedDeviceRecord(
                    deviceID: "watch-fallback-1",
                    deviceName: "Apple Watch",
                    platform: .appleWatch,
                    authToken: "tok-wifi-shared-999",
                    pairedAt: Date(),
                    lastSeenAt: Date()
                )
            ]
        )
        serverWithPaired.delegate = delegate
        defer { serverWithPaired.stop() }

        isolatedDefaults.set(try JSONEncoder().encode([wifiOnlyCredential]), forKey: "fb.savedMacs")

        let blePeripheralID = UUID()
        let watch = CompanionClientEngine(
            deviceID: "watch-fallback-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "fb"
        )
        watch.connectTimeoutSeconds = 0.25
        defer { watch.disconnect() }

        watch.simulatedBluetoothConnector = { host in
            guard host.id == blePeripheralID else { return nil }
            let (sPipe, cPipe) = SimulatedBLECompanionPipe.pair(mtu: ChocliftBluetooth.minATTChunkSize)
            serverWithPaired.acceptCompanionTransport(sPipe, link: .bluetooth)
            return cPipe
        }

        // Watch discovers connectable 1-UUID BLE advertisement (macID nil, generic "Mac" name)
        watch.disconnect()
        // Re-create client so intentionalDisconnect is false, setdiscovered BLE Mac after starting doomed Wi-Fi connect
        let activeWatch = CompanionClientEngine(
            deviceID: "watch-fallback-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "fb"
        )
        activeWatch.connectTimeoutSeconds = 0.25
        activeWatch.simulatedBluetoothConnector = watch.simulatedBluetoothConnector
        defer { activeWatch.disconnect() }

        // Start doomed Wi-Fi TCP connection to closed port, while BLE advertisement is discovered
        activeWatch.connectToHost(host: "127.0.0.1", port: 9, targetName: "Office Studio Mac")
        activeWatch.simulateDiscoveredBluetoothMacs([
            DiscoveredBluetoothMac(id: blePeripheralID, name: "Mac", macID: nil)
        ])

        try await waitUntil("Wi-Fi connection failed over to single-UUID BLE and authenticated via post-connection metadata") {
            activeWatch.connectionState == .connected(macID: "mac-wifi-ble-fallback", macName: "Office Studio Mac") &&
            activeWatch.activeLink == .bluetooth
        }
        XCTAssertEqual(activeWatch.savedMacs.first?.lastBluetoothPeripheralID, blePeripheralID)
    }
    #endif

    private func waitUntil(
        _ label: String,
        timeoutSeconds: TimeInterval = 3.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimeoutError(label: label)
    }
}
#endif
