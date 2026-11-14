#if os(macOS) || os(iOS) || os(watchOS)
import CoreBluetooth
import Foundation
import Network
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

    func testBluetoothClientLinkUsesWithResponseLimitDirectlyAndNeverMixesWriteTypes() throws {
        XCTAssertNil(ChocliftBluetooth.negotiatedWriteChunkSize(maximumWriteValueLength: 0))
        XCTAssertNil(ChocliftBluetooth.negotiatedWriteChunkSize(maximumWriteValueLength: -4))
        XCTAssertEqual(ChocliftBluetooth.negotiatedWriteChunkSize(maximumWriteValueLength: 24), 24)
        XCTAssertEqual(ChocliftBluetooth.negotiatedWriteChunkSize(maximumWriteValueLength: 512), ChocliftBluetooth.defaultChunkSize)

        var queriedTypes: [CBCharacteristicWriteType] = []
        var dispatchedWrites: [(Data, CBCharacteristicWriteType)] = []
        let reassembler = BluetoothFrameCodec()
        var reassembledFrames: [Data] = []
        var linkRef: BluetoothClientLink?

        let driver = BluetoothClientWriteDriver(
            isConnected: { true },
            supportsWriteWithResponse: { true },
            maximumWriteValueLength: { writeType in
                queriedTypes.append(writeType)
                return (writeType == .withResponse) ? 24 : 185
            },
            writeValue: { chunk, writeType in
                dispatchedWrites.append((chunk, writeType))
                if let extracted = try? reassembler.append(chunk) {
                    reassembledFrames.append(contentsOf: extracted)
                }
                linkRef?.didCompleteInFlightWrite()
            },
            cancelConnection: {}
        )

        let link = BluetoothClientLink(
            host: DiscoveredBluetoothMac(id: UUID(), name: "Mac", macID: "mac-unit-1"),
            writeDriver: driver
        )
        linkRef = link
        link.start()

        let pinFrame = try WireFrameCodec.encode(
            ClientMessage.submitPIN(
                pin: "654321",
                deviceID: "watch-unit-device-001",
                deviceName: "Apple Watch",
                platform: .appleWatch
            )
        )
        XCTAssertGreaterThan(pinFrame.count, 24 * 3)
        link.send(pinFrame)

        XCTAssertFalse(link.isWriteInFlight)
        XCTAssertEqual(link.pendingOutboundByteCount, 0)
        XCTAssertTrue(queriedTypes.allSatisfy { $0 == .withResponse })
        XCTAssertTrue(dispatchedWrites.allSatisfy { $0.1 == .withResponse && $0.0.count <= 24 })
        XCTAssertEqual(reassembledFrames, [pinFrame])
    }

    #if os(macOS)
    func testOneSlowATTAcknowledgmentRetriesChunkOnceWithoutCancelling() async throws {
        final class ServerPipe: CompanionFrameTransport {
            var onReady: (() -> Void)?
            var onPayload: ((Data) -> Void)?
            var onClosed: (() -> Void)?
            weak var clientLink: BluetoothClientLink?
            func start() { onReady?() }
            func send(_ data: Data) {
                Task { @MainActor [weak self] in try? self?.clientLink?.accept(data) }
            }
            func cancel() { onClosed?() }
        }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = MacServerEngine(macID: "slow-ack", macName: "Mac")
        let delegate = WatchTestServerDelegate()
        server.delegate = delegate
        defer { server.stop() }
        let pipe = ServerPipe()
        server.acceptCompanionTransport(pipe, link: .bluetooth)
        let codec = BluetoothFrameCodec()
        var slow = false
        var writes: [Data] = []
        var cancelled = 0
        var link: BluetoothClientLink!
        let driver = BluetoothClientWriteDriver(
            isConnected: { true }, supportsWriteWithResponse: { true },
            maximumWriteValueLength: { _ in 180 },
            writeValue: { data, _ in
                if slow {
                    writes.append(data)
                    if writes.count == 1 { return } // Locally delayed chunk: no ATT callback yet.
                }
                if let frames = try? codec.append(data) {
                    for frame in frames { pipe.onPayload?(frame) }
                }
                link.didCompleteInFlightWrite()
            }, cancelConnection: { cancelled += 1; pipe.cancel() })
        link = BluetoothClientLink(host: DiscoveredBluetoothMac(id: UUID(), name: "Mac", macID: server.macID),
                                   writeDriver: driver, writeAckTimeoutSeconds: 0.05)
        pipe.clientLink = link
        let client = CompanionClientEngine(deviceID: "slow-watch", deviceName: "Watch", platform: .appleWatch,
                                           userDefaults: defaults, storageKeyPrefix: "slow")
        defer { client.disconnect() }
        client.connectInMemoryBluetooth(to: link, targetName: server.macName, peripheralID: UUID())
        try await waitUntil("slow ACK client awaiting PIN") {
            if case .awaitingPIN = client.connectionState { return true }; return false
        }
        client.submitPIN(server.currentPIN)
        try await waitUntil("slow ACK client authenticated") { client.connectionState.isConnected }
        let state = client.connectionState
        slow = true
        client.performQuickAction(.lockScreen)
        for _ in 0..<7 {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(client.connectionState, state)
        }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first, writes.last)
        XCTAssertEqual(delegate.receivedQuickActions, [.lockScreen])
        XCTAssertFalse(link.isLinkClosed)
        XCTAssertFalse(link.isWriteInFlight)
        XCTAssertEqual(cancelled, 0)
    }

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

    func testWatchBLEPINPairingSplitsFrameUsingSmallerWithResponseLimitAndReceivesAuthSucceeded() async throws {
        let suiteName = "com.choclift.tests.watchpinmtu.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-watch-pin-fix", macName: "Studio MacBook Pro")
        server.delegate = delegate
        defer { server.stop() }

        // Confirm the wire-encoded submitPIN frame is much larger than the 28-byte withResponse ATT limit
        let samplePINFrame = try WireFrameCodec.encode(
            ClientMessage.submitPIN(
                pin: server.currentPIN,
                deviceID: "watch-series-11-pin",
                deviceName: "Apple Watch",
                platform: .appleWatch
            )
        )
        let withoutResponseLimit = 185
        let withResponseLimit = 28
        XCTAssertLessThan(withResponseLimit, withoutResponseLimit)
        XCTAssertGreaterThan(samplePINFrame.count, withResponseLimit * 3)

        final class ServerGATTBridge: CompanionFrameTransport {
            var onReady: (() -> Void)?
            var onPayload: ((Data) -> Void)?
            var onClosed: (() -> Void)?
            weak var clientLink: BluetoothClientLink?
            private var closed = false

            func start() {
                onReady?()
            }

            func send(_ data: Data) {
                guard !closed else { return }
                let notifyChunks = BluetoothFrameCodec.chunks(for: data, maxChunkBytes: 23)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, let link = self.clientLink, !link.isLinkClosed else { return }
                    for chunk in notifyChunks {
                        try? link.accept(chunk)
                    }
                }
            }

            func cancel() {
                guard !closed else { return }
                closed = true
                onClosed?()
            }
        }

        var queriedLimitTypes: [CBCharacteristicWriteType] = []
        var writtenChunks: [(size: Int, type: CBCharacteristicWriteType)] = []
        var locallyRejectedOversizedWrites = 0
        weak var latestClientLink: BluetoothClientLink?

        let peripheralID = UUID()
        var adv = ChocliftBluetooth.makeConnectableAdvertisementData()
        adv[CBAdvertisementDataIsConnectable] = NSNumber(value: true)
        let browser = BluetoothCompanionBrowser()
        let discoveredHost = try XCTUnwrap(
            browser.ingestAdvertisement(
                peripheralID: peripheralID,
                peripheralName: nil,
                advertisementData: adv
            )
        )

        let watch = CompanionClientEngine(
            deviceID: "watch-series-11-pin",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch-pin-mtu"
        )
        defer { watch.disconnect() }

        watch.simulatedBluetoothConnector = { host in
            let serverBridge = ServerGATTBridge()
            let serverInboundCodec = BluetoothFrameCodec()
            var linkRef: BluetoothClientLink?

            let driver = BluetoothClientWriteDriver(
                isConnected: { true },
                supportsWriteWithResponse: { true },
                maximumWriteValueLength: { writeType in
                    queriedLimitTypes.append(writeType)
                    switch writeType {
                    case .withResponse:
                        return withResponseLimit
                    case .withoutResponse:
                        return withoutResponseLimit
                    @unknown default:
                        return withResponseLimit
                    }
                },
                writeValue: { chunk, writeType in
                    let allowedLimit = (writeType == .withResponse) ? withResponseLimit : withoutResponseLimit
                    if chunk.count > allowedLimit {
                        // Exact watchOS CoreBluetooth behavior: oversized withResponse write is rejected locally
                        // and peripheral(_:didWriteValueFor:error:) is never invoked.
                        locallyRejectedOversizedWrites += 1
                        return
                    }
                    writtenChunks.append((size: chunk.count, type: writeType))
                    Task { @MainActor in
                        guard let link = linkRef, !link.isLinkClosed else { return }
                        if let frames = try? serverInboundCodec.append(chunk) {
                            for frame in frames {
                                serverBridge.onPayload?(frame)
                            }
                        }
                        link.didCompleteInFlightWrite()
                    }
                },
                cancelConnection: {
                    serverBridge.cancel()
                }
            )

            let clientLink = BluetoothClientLink(
                host: host,
                writeDriver: driver,
                simulatedMetadata: BluetoothServiceMetadata(
                    macID: server.macID,
                    macName: server.macName
                ),
                writeAckTimeoutSeconds: 0.5
            )
            linkRef = clientLink
            latestClientLink = clientLink
            serverBridge.clientLink = clientLink
            server.acceptCompanionTransport(serverBridge, link: .bluetooth)
            return clientLink
        }

        watch.simulateDiscoveredBluetoothMacs([discoveredHost], autoConnect: false)
        watch.connectBluetooth(to: discoveredHost)

        try await waitUntil("Watch reached awaitingPIN over real BluetoothClientLink") {
            if case .awaitingPIN(let id, let name, let err) = watch.connectionState {
                return id == "mac-watch-pin-fix" && name == "Studio MacBook Pro" && err == nil
            }
            return false
        }

        let chunksBeforePIN = writtenChunks.count
        watch.submitPIN(server.currentPIN)

        try await waitUntil("Watch split PIN frame within withResponse limit and received authSucceeded + icons") {
            watch.connectionState == .connected(macID: "mac-watch-pin-fix", macName: "Studio MacBook Pro") &&
            watch.activeLink == .bluetooth &&
            watch.appIconsByBundleID["com.apple.finder"] != nil &&
            latestClientLink?.isWriteInFlight == false
        }

        let pinAndPostAuthChunks = writtenChunks.dropFirst(chunksBeforePIN)
        XCTAssertEqual(locallyRejectedOversizedWrites, 0, "No BLE write may exceed maximumWriteValueLength(for: .withResponse)")
        XCTAssertFalse(queriedLimitTypes.isEmpty)
        XCTAssertTrue(
            queriedLimitTypes.allSatisfy { $0 == .withResponse },
            "BluetoothClientLink must query maximumWriteValueLength(for: .withResponse), never .withoutResponse"
        )
        XCTAssertGreaterThanOrEqual(
            pinAndPostAuthChunks.count,
            4,
            "Oversized PIN frame must be safely split across multiple <= \(withResponseLimit)B .withResponse chunks"
        )
        for recorded in writtenChunks {
            XCTAssertEqual(recorded.type, .withResponse)
            XCTAssertLessThanOrEqual(recorded.size, withResponseLimit)
        }
        XCTAssertEqual(watch.savedMacs.first?.macID, "mac-watch-pin-fix")
        XCTAssertEqual(watch.savedMacs.first?.lastBluetoothPeripheralID, peripheralID)

        // Verify saved-token reconnect also succeeds under the same smaller withResponse limit after PIN rotation
        watch.disconnect()
        server.regeneratePIN()
        watch.reconnectSavedMac( try XCTUnwrap(watch.savedMacs.first) )
        try await waitUntil("Saved-token BLE reconnect succeeded with smaller withResponse limit") {
            watch.connectionState == .connected(macID: "mac-watch-pin-fix", macName: "Studio MacBook Pro") &&
            watch.activeLink == .bluetooth
        }
        XCTAssertEqual(locallyRejectedOversizedWrites, 0)
    }

    func testWatchBLEWriteRejectionAndFailureClearInFlightLockAndSurfaceConnectionError() async throws {
        let suiteName = "com.choclift.tests.watchwriteerr.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-watch-write-err", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        enum PINWriteFailureMode {
            case attCallbackError
            case zeroMaxLengthRejection
            case silentLocalDropWithoutCallback
        }

        for mode in [
            PINWriteFailureMode.attCallbackError,
            PINWriteFailureMode.zeroMaxLengthRejection,
            PINWriteFailureMode.silentLocalDropWithoutCallback
        ] {
            let watch = CompanionClientEngine(
                deviceID: "watch-err-\(mode)",
                deviceName: "Apple Watch",
                platform: .appleWatch,
                userDefaults: isolatedDefaults,
                storageKeyPrefix: "err-\(mode)"
            )
            watch.pinGlitchRecoveryWindowSeconds = 10.0
            defer { watch.disconnect() }

            final class ServerSidePipe: CompanionFrameTransport {
                var onReady: (() -> Void)?
                var onPayload: ((Data) -> Void)?
                var onClosed: (() -> Void)?
                weak var clientLink: BluetoothClientLink?
                func start() { onReady?() }
                func send(_ data: Data) {
                    Task { @MainActor [weak self] in
                        try? self?.clientLink?.accept(data)
                    }
                }
                func cancel() { onClosed?() }
            }

            var allowWritesUntilAwaitingPIN = true
            var cancelConnectionCount = 0
            var rejectedWriteCount = 0
            var activeClientLink: BluetoothClientLink?
            let host = DiscoveredBluetoothMac(id: UUID(), name: "Mac", macID: nil)

            watch.simulatedBluetoothConnector = { targetHost in
                let serverPipe = ServerSidePipe()
                let serverCodec = BluetoothFrameCodec()
                var linkBox: BluetoothClientLink?

                let driver = BluetoothClientWriteDriver(
                    isConnected: { true },
                    supportsWriteWithResponse: { true },
                    maximumWriteValueLength: { writeType in
                        XCTAssertEqual(writeType, .withResponse)
                        if !allowWritesUntilAwaitingPIN && mode == .zeroMaxLengthRejection {
                            return 0
                        }
                        return 40
                    },
                    writeValue: { chunk, writeType in
                        XCTAssertEqual(writeType, .withResponse)
                        if allowWritesUntilAwaitingPIN {
                            Task { @MainActor in
                                guard let link = linkBox, !link.isLinkClosed else { return }
                                if let frames = try? serverCodec.append(chunk) {
                                    for frame in frames {
                                        serverPipe.onPayload?(frame)
                                    }
                                }
                                link.didCompleteInFlightWrite()
                            }
                            return
                        }

                        rejectedWriteCount += 1
                        switch mode {
                        case .attCallbackError:
                            Task { @MainActor in
                                let attError = NSError(
                                    domain: CBATTErrorDomain,
                                    code: CBATTError.writeNotPermitted.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: "ATT write not permitted"]
                                )
                                linkBox?.didFailInFlightWrite(attError)
                            }
                        case .zeroMaxLengthRejection:
                            XCTFail("writeValue must not be called when maximumWriteValueLength returns 0")
                        case .silentLocalDropWithoutCallback:
                            // Simulate CoreBluetooth dropping the write locally without ever calling didWriteValueFor
                            break
                        }
                    },
                    cancelConnection: {
                        cancelConnectionCount += 1
                        serverPipe.cancel()
                    }
                )

                let link = BluetoothClientLink(
                    host: targetHost,
                    writeDriver: driver,
                    simulatedMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName),
                    writeAckTimeoutSeconds: 0.08
                )
                linkBox = link
                activeClientLink = link
                serverPipe.clientLink = link
                server.acceptCompanionTransport(serverPipe, link: .bluetooth)
                return link
            }

            watch.simulateDiscoveredBluetoothMacs([host], autoConnect: false)
            watch.connectBluetooth(to: host)

            try await waitUntil("Watch reached awaitingPIN for mode \(mode)") {
                if case .awaitingPIN = watch.connectionState { return true }
                return false
            }

            let link = try XCTUnwrap(activeClientLink)
            allowWritesUntilAwaitingPIN = false
            watch.submitPIN(server.currentPIN)

            if mode == .silentLocalDropWithoutCallback {
                XCTAssertTrue(link.isWriteInFlight, "Write should initially be in flight before watchdog detects dropped callback")
            }

            try await waitUntil("Rejected/failed write cleared in-flight lock and surfaced connection error (\(mode))") {
                !link.isWriteInFlight &&
                link.isLinkClosed &&
                watch.connectionState == .disconnected &&
                watch.activeLink == nil &&
                watch.lastConnectionIssue != nil
            }

            if mode == .silentLocalDropWithoutCallback {
                XCTAssertEqual(rejectedWriteCount, 2, "Timeout must retry exactly once before failing the link")
            }
            XCTAssertGreaterThanOrEqual(cancelConnectionCount, 1, "Peripheral connection must be cancelled on write failure (\(mode))")
            XCTAssertFalse(watch.lastConnectionIssue?.isEmpty ?? true)
        }
    }

    func testWatchBLEPINScreenNeverAdvancesAfterIdleSweepDuringPINEntry() async throws {
        let suiteName = "com.choclift.tests.watchpinsweep.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-watch-pin-sweep", macName: "Studio MacBook Pro")
        server.delegate = delegate
        // Reproduce the exact Mac-side Bluetooth idle sweep firing while the user reads and taps the 6-digit PIN.
        server.bluetoothSessionTimeoutSeconds = 0.15
        server.heartbeatSweepIntervalSeconds = 0.03
        defer { server.stop() }

        // Models real macOS CBPeripheralManager + BluetoothCompanionAdvertiser + BluetoothServerLink behavior:
        // 1. Central subscribes once on initial GATT connect (`didSubscribeTo` -> `markReady()`).
        // 2. When MacServerEngine cancels an idle session link, CBPeripheralManager CANNOT disconnect the Watch
        //    radio (`BluetoothServerLink.cancel()` only marks the server wrapper closed and removes it from
        //    `subscribers`; the Watch remains connected and subscribed on `.awaitingPIN`).
        // 3. When the Watch subsequently writes `submitPIN`, `didReceiveWrite` allocates a fresh server link via
        //    `link(for: central)`, and CoreBluetooth does NOT fire `didSubscribeTo` a second time.
        final class RealisticCoreBluetoothServerLink: CompanionFrameTransport {
            var onReady: (() -> Void)?
            var onPayload: ((Data) -> Void)?
            var onClosed: (() -> Void)?
            var onCancelled: (() -> Void)?

            weak var clientLink: BluetoothClientLink?
            private(set) var ready = false
            private(set) var closed = false
            private let inbound = BluetoothFrameCodec()
            private let outbound = BluetoothOutboundBuffer()

            func start() {}

            func markReady() {
                guard !closed else { return }
                if !ready {
                    ready = true
                    onReady?()
                }
                flush()
            }

            func accept(_ chunk: Data) throws {
                guard !closed else { return }
                for frame in try inbound.append(chunk) {
                    onPayload?(frame)
                }
            }

            func send(_ data: Data) {
                guard !closed else { return }
                outbound.enqueue(data)
                flush()
            }

            func cancel() {
                guard !closed else { return }
                closed = true
                ready = false
                outbound.clear()
                inbound.reset()
                onCancelled?()
                onClosed?()
            }

            func flush() {
                guard ready, !closed else { return }
                outbound.drain(maxChunkBytes: 23) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self, !self.closed, let client = self.clientLink, !client.isLinkClosed else { return }
                        try? client.accept(chunk)
                    }
                    return true
                }
            }
        }

        let withResponseLimit = 28
        let withoutResponseLimit = 185
        var locallyRejectedOversizedWrites = 0
        var activeServerSubscriber: RealisticCoreBluetoothServerLink?
        var centralSubscribedOnRadio = false
        weak var latestClientLink: BluetoothClientLink?

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Mac", macID: nil)
        let watch = CompanionClientEngine(
            deviceID: "watch-pin-sweep-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "pin-sweep"
        )
        watch.heartbeatIntervalSeconds = 0.05
        defer { watch.disconnect() }

        watch.simulatedBluetoothConnector = { targetHost in
            var clientRef: BluetoothClientLink?

            @MainActor
            func serverLinkForSubscribedCentral() -> RealisticCoreBluetoothServerLink {
                if let existing = activeServerSubscriber, !existing.closed {
                    return existing
                }
                let created = RealisticCoreBluetoothServerLink()
                created.clientLink = clientRef
                created.onCancelled = {
                    if activeServerSubscriber === created {
                        activeServerSubscriber = nil
                    }
                }
                activeServerSubscriber = created
                server.acceptCompanionTransport(created, link: .bluetooth)
                return created
            }

            let driver = BluetoothClientWriteDriver(
                isConnected: { true },
                supportsWriteWithResponse: { true },
                maximumWriteValueLength: { writeType in
                    writeType == .withResponse ? withResponseLimit : withoutResponseLimit
                },
                writeValue: { chunk, writeType in
                    let limit = (writeType == .withResponse) ? withResponseLimit : withoutResponseLimit
                    if chunk.count > limit {
                        locallyRejectedOversizedWrites += 1
                        return
                    }
                    Task { @MainActor in
                        guard let client = clientRef, !client.isLinkClosed else { return }
                        let serverLink = serverLinkForSubscribedCentral()
                        try? serverLink.accept(chunk)
                        client.didCompleteInFlightWrite()
                    }
                },
                cancelConnection: {
                    centralSubscribedOnRadio = false
                    activeServerSubscriber?.cancel()
                    activeServerSubscriber = nil
                }
            )

            let clientLink = BluetoothClientLink(
                host: targetHost,
                writeDriver: driver,
                simulatedMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName),
                writeAckTimeoutSeconds: 0.4
            )
            clientRef = clientLink
            latestClientLink = clientLink

            // Initial GATT connect + CCCD subscribe (`didSubscribeTo` fires once per BLE connection).
            centralSubscribedOnRadio = true
            let initialServerLink = serverLinkForSubscribedCentral()
            initialServerLink.markReady()
            _ = centralSubscribedOnRadio
            return clientLink
        }

        watch.simulateDiscoveredBluetoothMacs([host], autoConnect: false)
        watch.connectBluetooth(to: host)

        try await waitUntil("Watch reached awaitingPIN over BLE") {
            if case .awaitingPIN(let id, let name, let err) = watch.connectionState {
                return id == "mac-watch-pin-sweep" && name == "Studio MacBook Pro" && err == nil
            }
            return false
        }

        // User spends > bluetoothSessionTimeoutSeconds reading the 6-digit PIN on Mac and tapping 6 digits on Watch.
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(
            watch.connectionState,
            .awaitingPIN(macID: "mac-watch-pin-sweep", macName: "Studio MacBook Pro", errorMessage: nil),
            "Watch UI is still rendering the PIN pad before the 6th digit is tapped"
        )

        watch.submitPIN(server.currentPIN)

        let pinDeadline = Date().addingTimeInterval(0.6)
        while Date() < pinDeadline, !watch.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            watch.connectionState,
            .connected(macID: "mac-watch-pin-sweep", macName: "Studio MacBook Pro"),
            "Watch must advance past .awaitingPIN to .connected after submitting valid 6-digit PIN"
        )
        XCTAssertEqual(watch.activeLink, .bluetooth)
        XCTAssertEqual(locallyRejectedOversizedWrites, 0)
        XCTAssertEqual(latestClientLink?.isWriteInFlight, false)
    }

    func testWatchSameLANWiFiNeverStaysConnectingForeverOnSilentHandshake() async throws {
        let suiteName = "com.choclift.tests.watchwificonnecting.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        // Part A: Same-LAN TCP listener accepts socket (`.ready` fires, `ClientMessage.hello` is sent),
        // but no ServerMessage arrives back. Watch must NOT remain in `.connecting` forever.
        let listenerQueue = DispatchQueue(label: "com.choclift.tests.silentwifi")
        let silentListener = try NWListener(using: .tcp, on: .any)
        var acceptedSockets: [NWConnection] = []
        var receivedHelloPayloads: [ClientMessage] = []
        let readyExp = expectation(description: "Silent TCP listener ready")

        silentListener.stateUpdateHandler = { state in
            if case .ready = state {
                readyExp.fulfill()
            }
        }
        silentListener.newConnectionHandler = { conn in
            conn.start(queue: listenerQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if let data {
                    Task { @MainActor in
                        var acc = WireStreamAccumulator()
                        if let frames = try? acc.appendAndExtractPayloads(data) {
                            for frame in frames {
                                if let msg = try? WireFrameCodec.decodePayload(ClientMessage.self, from: frame) {
                                    receivedHelloPayloads.append(msg)
                                }
                            }
                        }
                    }
                }
            }
            Task { @MainActor in
                acceptedSockets.append(conn)
            }
        }
        silentListener.start(queue: listenerQueue)
        defer {
            silentListener.cancel()
            for conn in acceptedSockets {
                conn.cancel()
            }
        }
        await fulfillment(of: [readyExp], timeout: 2.0)
        let silentPort = try XCTUnwrap(silentListener.port?.rawValue)

        let watchSilent = CompanionClientEngine(
            deviceID: "watch-wifi-silent",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "wifi-silent"
        )
        watchSilent.connectTimeoutSeconds = 0.22
        watchSilent.maxAutoReconnectAttempts = 0
        defer { watchSilent.disconnect() }

        watchSilent.connectToHost(host: "127.0.0.1", port: silentPort, targetName: "Same-LAN Mac")
        XCTAssertEqual(watchSilent.connectionState, .connecting(targetName: "Same-LAN Mac"))

        try await waitUntil("Watch sent ClientMessage.hello over TCP", timeoutSeconds: 0.8) {
            !receivedHelloPayloads.isEmpty
        }

        let silentDeadline = Date().addingTimeInterval(0.6)
        while Date() < silentDeadline, watchSilent.connectionState != .disconnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            watchSilent.connectionState,
            .disconnected,
            "Silent same-LAN Wi-Fi handshake must time out cleanly instead of staying .connecting forever"
        )
        XCTAssertNil(watchSilent.activeLink)
        XCTAssertNotNil(watchSilent.lastConnectionIssue)
    }

    func testWatchSameLANWiFiNeverLoopsConnectingForeverWhenDiscoveryRefreshes() async throws {
        let suiteName = "com.choclift.tests.watchwifiloop.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        // Unreachable Wi-Fi endpoint while foreground BLE discovery refreshes (`onDiscoveredChanged` /
        // `browseResultsChangedHandler`). Discovery callbacks must NOT reset `consecutiveReconnectFailures`
        // and trap the Watch in a perpetual `.connecting` retry loop.
        let watchLoop = CompanionClientEngine(
            deviceID: "watch-wifi-loop",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "wifi-loop"
        )
        watchLoop.connectTimeoutSeconds = 0.15
        watchLoop.reconnectDelaySeconds = 0.08
        watchLoop.maxAutoReconnectAttempts = 1
        defer { watchLoop.disconnect() }

        let nearbyUnpairedBLE = DiscoveredBluetoothMac(id: UUID(), name: "Mac", macID: nil)
        let discoveryNoiseTask = Task { @MainActor in
            while !Task.isCancelled {
                watchLoop.simulateDiscoveredBluetoothMacs([nearbyUnpairedBLE], autoConnect: false)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        defer { discoveryNoiseTask.cancel() }

        // Bind a silent socket that never accepts/replies or closes immediately via port 9:
        // on macOS loopback port 9 immediately fails TCP (`ECONNREFUSED`) and enters `scheduleRecoveryAttempt`.
        watchLoop.connectToHost(host: "127.0.0.1", port: 9, targetName: "Unreachable LAN Mac")

        // Allow more than (maxAutoReconnectAttempts + 1) retry cycles; if discovery resets
        // consecutiveReconnectFailures, scheduleRecoveryAttempt keeps re-entering .connecting forever.
        try await Task.sleep(for: .milliseconds(360))
        var sawConnectingAfterBudget = false
        for _ in 0..<25 {
            if case .connecting = watchLoop.connectionState {
                sawConnectingAfterBudget = true
            }
            try await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertFalse(
            sawConnectingAfterBudget,
            "Watch must not keep re-entering .connecting forever while discovery callbacks fire"
        )
        XCTAssertEqual(watchLoop.connectionState, .disconnected)
        XCTAssertNotNil(watchLoop.lastConnectionIssue)
    }

    #if os(macOS)
    func testBluetoothCompanionAdvertiserMarksRecreatedLinkReadyForAlreadySubscribedWatchCentral() async throws {
        let suiteName = "com.choclift.tests.advertiserresub.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-real-advertiser", macName: "MacBook Pro BLE")
        server.delegate = delegate
        // Force even the pairing idle window to expire before PIN submission so the server-side
        // BluetoothServerLink is cancelled while the Watch's GATT CCCD subscription remains active.
        server.bluetoothPairingTimeoutSeconds = 0.12
        server.bluetoothSessionTimeoutSeconds = 0.12
        server.heartbeatSweepIntervalSeconds = 0.03
        defer { server.stop() }

        let advertiser = BluetoothCompanionAdvertiser(macID: server.macID, macName: server.macName)
        var acceptedLinkCount = 0
        advertiser.onAccepted = { [weak server] transport in
            acceptedLinkCount += 1
            server?.acceptCompanionTransport(transport, link: .bluetooth)
        }
        defer { advertiser.stop() }

        let watchCentralID = UUID()
        let withResponseLimit = 28
        let withoutResponseLimit = 185
        weak var activeWatchLink: BluetoothClientLink?

        let watch = CompanionClientEngine(
            deviceID: "watch-real-adv-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "real-adv"
        )
        // Suppress client heartbeats so the server sweep is guaranteed to evict the initial BluetoothServerLink.
        watch.heartbeatIntervalSeconds = 60.0
        defer { watch.disconnect() }

        let notifyDriver = BluetoothServerNotifyDriver(
            centralID: watchCentralID,
            maximumUpdateValueLength: { 23 },
            sendNotification: { chunk in
                Task { @MainActor in
                    guard let link = activeWatchLink, !link.isLinkClosed else { return }
                    try? link.accept(chunk)
                }
                return true
            }
        )

        let bleHost = DiscoveredBluetoothMac(id: watchCentralID, name: "Mac", macID: nil)
        watch.simulatedBluetoothConnector = { targetHost in
            var clientRef: BluetoothClientLink?
            let writeDriver = BluetoothClientWriteDriver(
                isConnected: { true },
                supportsWriteWithResponse: { true },
                maximumWriteValueLength: { $0 == .withResponse ? withResponseLimit : withoutResponseLimit },
                writeValue: { chunk, writeType in
                    XCTAssertEqual(writeType, .withResponse)
                    XCTAssertLessThanOrEqual(chunk.count, withResponseLimit)
                    Task { @MainActor in
                        guard let client = clientRef, !client.isLinkClosed else { return }
                        try? advertiser.handleSimulatedCentralWrite(chunk, from: notifyDriver)
                        client.didCompleteInFlightWrite()
                    }
                },
                cancelConnection: {
                    Task { @MainActor in
                        advertiser.handleSimulatedCentralUnsubscribed(centralID: watchCentralID)
                    }
                }
            )
            let clientLink = BluetoothClientLink(
                host: targetHost,
                writeDriver: writeDriver,
                simulatedMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName),
                writeAckTimeoutSeconds: 0.4
            )
            clientRef = clientLink
            activeWatchLink = clientLink
            // CoreBluetooth fires didSubscribeTo ONCE when the Watch enables notifications on connect.
            advertiser.handleSimulatedCentralSubscribed(notifyDriver)
            return clientLink
        }

        watch.simulateDiscoveredBluetoothMacs([bleHost], autoConnect: false)
        watch.connectBluetooth(to: bleHost)

        try await waitUntil("Watch reached awaitingPIN via real BluetoothCompanionAdvertiser") {
            if case .awaitingPIN(let id, _, _) = watch.connectionState {
                return id == "mac-real-advertiser"
            }
            return false
        }
        XCTAssertEqual(acceptedLinkCount, 1)

        // Wait past bluetoothPairingTimeoutSeconds so the first BluetoothServerLink is cancelled on Mac,
        // without firing didSubscribeTo again on the Watch radio.
        try await Task.sleep(for: .milliseconds(220))

        watch.submitPIN(server.currentPIN)

        try await waitUntil("Recreated BluetoothServerLink marked itself ready and delivered authSucceeded + icons") {
            watch.connectionState == .connected(macID: "mac-real-advertiser", macName: "MacBook Pro BLE") &&
            watch.activeLink == .bluetooth &&
            watch.appIconsByBundleID["com.apple.finder"] != nil
        }
        XCTAssertEqual(acceptedLinkCount, 2, "Write after idle sweep must allocate a second server link that is immediately ready")
    }

    func testWatchSameLANWiFiWaitingENETDOWNFallsBackToHTTPAndCompletesPINPairing() async throws {
        let suiteName = "com.choclift.tests.watchhttpwifi.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchTestServerDelegate()
        let server = MacServerEngine(macID: "mac-lan-http-1", macName: "Same-LAN Studio Mac")
        server.delegate = delegate
        server.httpPollHoldSeconds = 1.5
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("MacServerEngine listening on ephemeral port") {
            server.isListening && (server.listeningPort ?? 0) > 0
        }
        let port = try XCTUnwrap(server.listeningPort)

        let watch = CompanionClientEngine(
            deviceID: "watch-http-wifi-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "http-wifi"
        )
        // Simulate exact watchOS NECP behavior per TN3135: NWConnection enters .waiting(.posix(.ENETDOWN)).
        watch.simulatedTCPWaitingErrorProvider = { _ in .posix(.ENETDOWN) }
        defer { watch.disconnect() }

        watch.connectToHost(host: "127.0.0.1", port: port, targetName: "Same-LAN Studio Mac")

        try await waitUntil("Watch switched from .waiting(ENETDOWN) TCP to HTTP Wi-Fi and reached .awaitingPIN") {
            if case .awaitingPIN(let id, let name, let err) = watch.connectionState {
                return id == "mac-lan-http-1" && name == "Same-LAN Studio Mac" && err == nil && watch.activeLink == .wifi
            }
            return false
        }

        watch.submitPIN(server.currentPIN)

        try await waitUntil("Watch completed PIN pairing and icon sync over HTTP Wi-Fi") {
            watch.connectionState == .connected(macID: "mac-lan-http-1", macName: "Same-LAN Studio Mac") &&
            watch.activeLink == .wifi &&
            watch.appIconsByBundleID["com.apple.finder"] != nil
        }

        watch.performQuickAction(.lockScreen)
        try await waitUntil("Quick action delivered from Watch to Mac over HTTP Wi-Fi") {
            delegate.receivedQuickActions == [.lockScreen]
        }

        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        try await waitUntil("Server broadcast delivered to Watch via HTTP long-poll") {
            watch.frontmostBundleID == "com.apple.Safari"
        }

        // Confirm an iPhone raw TCP client still connects simultaneously to the exact same Mac listener port.
        let iphone = CompanionClientEngine(
            deviceID: "iphone-raw-tcp-1",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "raw-tcp-coexist"
        )
        defer { iphone.disconnect() }
        iphone.connectToHost(host: "127.0.0.1", port: port, targetName: "Same-LAN Studio Mac")
        try await waitUntil("Raw TCP iPhone client reached awaitingPIN on the same listener port") {
            if case .awaitingPIN(let id, _, _) = iphone.connectionState {
                return id == "mac-lan-http-1"
            }
            return false
        }
    }
    #endif
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
