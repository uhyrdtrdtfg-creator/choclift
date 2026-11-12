import Darwin
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
private final class MockMacServerDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var recentApps: [RecentAppEntry] = [
        RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true),
        RecentAppEntry(bundleIdentifier: "com.apple.Safari", appName: "Safari", isFrontmost: false, isPinned: false)
    ]
    var frontmostBundleID: String? = "com.apple.finder"
    var isEditingText = false
    var focusedAppName: String?
    var pairedDevicesSnapshot: [PairedDeviceRecord] = []

    var triggeredItems: [BarItem] = []
    var insertedEmojis: [String] = []
    var receivedGestures: [TouchGestureType] = []
    var receivedQuickActions: [SystemQuickAction] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { recentApps }
    func serverFrontmostBundleID() -> String? { frontmostBundleID }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (isEditingText, focusedAppName) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for bid in bundleIDs {
            out[bid] = Data([0x89, 0x50, 0x4E, 0x47])
        }
        return out
    }

    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {
        pairedDevicesSnapshot = devices
    }

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .triggerBarItem(let item):
            triggeredItems.append(item)
            reply(.actionFeedback(success: true, title: item.displayTitle(), detail: "Triggered"))
        case .insertEmoji(let emoji):
            insertedEmojis.append(emoji)
            reply(.actionFeedback(success: true, title: emoji, detail: "Inserted"))
        case .performGesture(let gesture):
            receivedGestures.append(gesture)
            reply(.actionFeedback(success: true, title: gesture.rawValue, detail: "Gesture Executed"))
        case .performQuickAction(let action):
            receivedQuickActions.append(action)
            reply(.actionFeedback(success: true, title: action.compactTitle(in: .english), detail: "Quick Action Executed"))
        case .updateProfile(let updated):
            profile = updated
        default:
            break
        }
    }
}

@MainActor
final class CompanionLoopbackIntegrationTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    private nonisolated static func isLoopbackSocketAllowedByEnvironment() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else { return false }

        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        guard nameRes == 0 else { return false }

        let clientFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard clientFD >= 0 else { return false }
        defer { Darwin.close(clientFD) }

        let connRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connRes == 0
    }

    func testEndToEndPINPairingMultiDeviceSyncAndCommands() async throws {
        guard Self.isLoopbackSocketAllowedByEnvironment() else {
            throw XCTSkip("TCP loopback socket bind/connect is restricted by sandbox environment.")
        }

        let suiteName = "com.choclift.tests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = MockMacServerDelegate()
        let server = MacServerEngine(macID: "mac-test-host", macName: "Test MacBook Pro")
        server.delegate = delegate
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("server listening") { server.isListening && server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)

        let iphoneClient = CompanionClientEngine(
            deviceID: "iphone-sim-1",
            deviceName: "iPhone 17 Pro",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "iphone1"
        )
        defer { iphoneClient.disconnect() }

        iphoneClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Test MacBook Pro")

        // 1. Expect PIN challenge for new device
        try await waitUntil("iPhone awaiting PIN") {
            if case .awaitingPIN = iphoneClient.connectionState { return true }
            return false
        }

        // 2. Submit wrong PIN first -> expect error message
        iphoneClient.submitPIN("000000")
        try await waitUntil("wrong PIN rejected") {
            if case .awaitingPIN(_, _, let err) = iphoneClient.connectionState {
                return err != nil
            }
            return false
        }

        // 3. Submit valid 6-digit PIN -> expect connected + profile + icons
        iphoneClient.submitPIN(server.currentPIN)
        try await waitUntil("iPhone authenticated") {
            iphoneClient.connectionState.isConnected &&
            !iphoneClient.recentApps.isEmpty &&
            iphoneClient.appIconsByBundleID["com.apple.finder"] != nil
        }

        // 4. Connect a second companion device simultaneously (iPad Pro Multi-Device!)
        let ipadClient = CompanionClientEngine(
            deviceID: "ipad-sim-1",
            deviceName: "iPad Pro",
            platform: .iPad,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "ipad1"
        )
        defer { ipadClient.disconnect() }

        ipadClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Test MacBook Pro")
        try await waitUntil("iPad awaiting PIN") {
            if case .awaitingPIN = ipadClient.connectionState { return true }
            return false
        }
        ipadClient.submitPIN(server.currentPIN)
        try await waitUntil("iPad authenticated alongside iPhone") {
            ipadClient.connectionState.isConnected && server.connectedDeviceCount == 2
        }

        // 5. Execute BarItem, Emoji insertion, and Finger Gesture from iPhone
        let shortcutItem = BarItem(kind: .shortcut(shortcutName: "Morning Workflow", emoji: "⚡️", backgroundHex: "#6C3EB8"))
        iphoneClient.triggerBarItem(shortcutItem)
        iphoneClient.insertEmoji("🍫")
        iphoneClient.performGesture(.twoFingerSwipeUp)

        try await waitUntil("commands delivered to Mac delegate") {
            delegate.triggeredItems == [shortcutItem] &&
            delegate.insertedEmojis == ["🍫"] &&
            delegate.receivedGestures == [.twoFingerSwipeUp]
        }

        // 6. Broadcast text-field cursor focus from Mac -> both iPhone and iPad receive auto-Emoji signal
        server.broadcast(.textFieldFocusChanged(isEditingText: true, appName: "Notes"))
        try await waitUntil("text focus broadcast received") {
            iphoneClient.isEditingTextOnMac && ipadClient.isEditingTextOnMac && iphoneClient.focusedMacAppName == "Notes"
        }

        // 7. Disconnect iPhone, regenerate server PIN, and reconnect -> auto-authenticate via saved token!
        iphoneClient.disconnect()
        server.regeneratePIN()
        iphoneClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Test MacBook Pro")
        try await waitUntil("iPhone token auto-reconnect") {
            iphoneClient.connectionState.isConnected
        }

        // 8. Connect an Apple Watch companion to the exact same Mac session via PIN + TCP framing
        let watchClient = CompanionClientEngine(
            deviceID: "watch-sim-1",
            deviceName: "Apple Watch Series 11",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch1"
        )
        defer { watchClient.disconnect() }

        watchClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Test MacBook Pro")
        try await waitUntil("Apple Watch awaiting PIN") {
            if case .awaitingPIN = watchClient.connectionState { return true }
            return false
        }
        watchClient.submitPIN(server.currentPIN)
        try await waitUntil("Apple Watch authenticated alongside iPhone & iPad") {
            watchClient.connectionState.isConnected &&
            server.connectedDeviceCount == 3 &&
            delegate.pairedDevicesSnapshot.contains(where: { $0.platform == .appleWatch && $0.isCurrentlyConnected })
        }

        watchClient.performQuickAction(.mediaPlayPause)
        try await waitUntil("Apple Watch quick action delivered") {
            delegate.receivedQuickActions == [.mediaPlayPause]
        }

        // Verify Apple Watch token auto-reconnect after PIN rotation
        watchClient.disconnect()
        server.regeneratePIN()
        watchClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Test MacBook Pro")
        try await waitUntil("Apple Watch token auto-reconnect") {
            watchClient.connectionState.isConnected
        }

        let bluetoothClient = CompanionClientEngine(
            deviceID: "watch-bluetooth-1",
            deviceName: "Apple Watch Bluetooth",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch-bt"
        )
        defer { bluetoothClient.disconnect() }
        bluetoothClient.connectInMemoryBluetooth(
            to: server.acceptInMemoryCompanion(),
            targetName: "Bluetooth Mac"
        )
        try await waitUntil("Bluetooth companion awaiting PIN") {
            if case .awaitingPIN = bluetoothClient.connectionState { return true }
            return false
        }
        bluetoothClient.submitPIN(server.currentPIN)
        try await waitUntil("Bluetooth companion authenticated") {
            bluetoothClient.connectionState.isConnected && bluetoothClient.activeLink == .bluetooth
        }
        bluetoothClient.performQuickAction(.volumeUp)
        try await waitUntil("Bluetooth quick action delivered") {
            delegate.receivedQuickActions.contains(.volumeUp)
        }
    }

    func testBLEChunking20ByteMTUPartialWritesNotifyBackpressureAndTokenReconnect() async throws {
        let suiteName = "com.choclift.tests.ble.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = MockMacServerDelegate()
        let server = MacServerEngine(macID: "mac-ble-host", macName: "MacBook Pro BLE")
        server.delegate = delegate
        defer { server.stop() }

        let (serverPipe1, clientPipe1) = SimulatedBLECompanionPipe.pair(
            mtu: ChocliftBluetooth.minATTChunkSize,
            maxServerChunksPerFlush: 4,
            maxClientChunksPerFlush: 3,
            splitFirstHeaderBytes: 2
        )
        server.acceptCompanionTransport(serverPipe1, link: .bluetooth)

        // Background pump emulating CoreBluetooth's peripheralManagerIsReady(toUpdateSubscribers:)
        let pumpTask = Task { @MainActor in
            while !Task.isCancelled {
                serverPipe1.pumpReadyToUpdateSubscribers()
                clientPipe1.pumpReadyToUpdateSubscribers()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        defer { pumpTask.cancel() }

        let blePeripheralID = UUID()
        let watchBLE = CompanionClientEngine(
            deviceID: "watch-ble-sim",
            deviceName: "Apple Watch Ultra",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watch-ble-mtu"
        )
        watchBLE.reconnectDelaySeconds = 0.08
        defer { watchBLE.disconnect() }

        watchBLE.connectInMemoryBluetooth(
            to: clientPipe1,
            targetName: "MacBook Pro BLE",
            macID: nil,
            peripheralID: blePeripheralID
        )

        try await waitUntil("BLE watch awaiting PIN") {
            if case .awaitingPIN = watchBLE.connectionState { return true }
            return false
        }

        // Wrong PIN rejected over 20-byte BLE chunks
        watchBLE.submitPIN("111111")
        try await waitUntil("BLE wrong PIN rejected") {
            if case .awaitingPIN(_, _, let err) = watchBLE.connectionState {
                return err != nil
            }
            return false
        }

        // Valid 6-digit PIN authenticates and streams full profile + per-icon batches under backpressure
        watchBLE.submitPIN(server.currentPIN)
        try await waitUntil("BLE watch authenticated with profile & icons") {
            watchBLE.connectionState.isConnected &&
            watchBLE.activeLink == .bluetooth &&
            watchBLE.appIconsByBundleID["com.apple.finder"] != nil &&
            watchBLE.appIconsByBundleID["com.apple.Safari"] != nil
        }

        XCTAssertGreaterThan(serverPipe1.backpressurePauseCount, 0)
        XCTAssertGreaterThan(serverPipe1.totalChunksSent, 20)
        XCTAssertEqual(server.pairedDevices.first?.activeLink, .bluetooth)
        XCTAssertEqual(watchBLE.savedMacs.first?.lastBluetoothPeripheralID, blePeripheralID)

        watchBLE.insertEmoji("🍫")
        watchBLE.performQuickAction(.snapWindowRight)
        try await waitUntil("BLE emoji & quick action executed on Mac") {
            delegate.insertedEmojis == ["🍫"] &&
            delegate.receivedQuickActions == [.snapWindowRight]
        }

        // Simulate BLE disconnect + server PIN rotation -> automatic token reconnect over new BLE pipe
        server.regeneratePIN()
        watchBLE.simulatedBluetoothReconnectProvider = {
            let (serverPipe2, clientPipe2) = SimulatedBLECompanionPipe.pair(mtu: ChocliftBluetooth.minATTChunkSize)
            server.acceptCompanionTransport(serverPipe2, link: .bluetooth)
            return clientPipe2
        }

        serverPipe1.cancel()
        try await waitUntil("BLE watch automatically token-reconnected after drop") {
            watchBLE.connectionState.isConnected &&
            watchBLE.activeLink == .bluetooth &&
            server.connectedDeviceCount == 1
        }
    }

    func testCrossLinkWiFiAndBluetoothRoamingSharesSinglePINAndToken() async throws {
        guard Self.isLoopbackSocketAllowedByEnvironment() else {
            throw XCTSkip("TCP loopback socket bind/connect is restricted by sandbox environment.")
        }

        let suiteName = "com.choclift.tests.roam.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = MockMacServerDelegate()
        let server = MacServerEngine(macID: "mac-roam-host", macName: "Studio Roaming Mac")
        server.delegate = delegate
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("server listening") { server.isListening && server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)

        let phone = CompanionClientEngine(
            deviceID: "iphone-roam-1",
            deviceName: "iPhone Roaming",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "roam-phone"
        )
        defer { phone.disconnect() }

        // 1. Pair once over Wi-Fi TCP using the 6-digit PIN
        phone.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Roaming Mac")
        try await waitUntil("Wi-Fi awaiting PIN") {
            if case .awaitingPIN = phone.connectionState { return true }
            return false
        }
        phone.submitPIN(server.currentPIN)
        try await waitUntil("Wi-Fi connected") {
            phone.connectionState.isConnected && phone.activeLink == .wifi
        }
        XCTAssertEqual(server.pairedDevices.first?.activeLink, .wifi)

        // 2. Leave Wi-Fi, rotate Mac PIN, and connect over Bluetooth LE (even with an initially unknown BLE name/UUID)
        phone.disconnect()
        try await waitUntil("server observed Wi-Fi disconnect") {
            server.pairedDevices.first?.activeLink == nil
        }
        server.regeneratePIN()

        // Pair a second distinct Mac so savedMacs[0] is NOT "mac-roam-host"; connecting with an unknown BLE
        // name/UUID then exercises `.pairingRequired(macID, macName)` -> automatic saved-token retry without PIN!
        let otherDelegate = MockMacServerDelegate()
        let otherServer = MacServerEngine(macID: "other-mac-id", macName: "Other Office Mac")
        otherServer.delegate = otherDelegate
        defer { otherServer.stop() }
        phone.connectInMemoryBluetooth(to: otherServer.acceptInMemoryCompanion(), targetName: "Other Office Mac")
        try await waitUntil("other Mac awaiting PIN") {
            if case .awaitingPIN = phone.connectionState { return true }
            return false
        }
        phone.submitPIN(otherServer.currentPIN)
        try await waitUntil("other Mac paired") { phone.connectionState.isConnected }
        phone.disconnect()
        XCTAssertEqual(phone.savedMacs.first?.macID, "other-mac-id")

        let secondClient = CompanionClientEngine(
            deviceID: "iphone-roam-1",
            deviceName: "iPhone Roaming",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "roam-phone"
        )
        defer { secondClient.disconnect() }

        var sawAwaitingPINFlash = false
        let bleID = UUID()
        let (bleServer, bleClient) = SimulatedBLECompanionPipe.pair(
            mtu: ChocliftBluetooth.minATTChunkSize,
            splitFirstHeaderBytes: 1
        )
        server.acceptCompanionTransport(bleServer, link: .bluetooth)
        secondClient.connectInMemoryBluetooth(
            to: bleClient,
            targetName: "Truncated BLE",
            macID: nil,
            peripheralID: bleID
        )
        if case .awaitingPIN = secondClient.connectionState {
            sawAwaitingPINFlash = true
        }

        try await waitUntil("Roaming client authenticated over Bluetooth LE without PIN") {
            if case .awaitingPIN = secondClient.connectionState {
                sawAwaitingPINFlash = true
            }
            return secondClient.connectionState.isConnected &&
                secondClient.activeLink == .bluetooth &&
                server.pairedDevices.first?.activeLink == .bluetooth
        }
        XCTAssertFalse(sawAwaitingPINFlash)

        // Saved credential preserves BOTH Wi-Fi direct endpoint and BLE peripheral identifier
        let saved = try XCTUnwrap(secondClient.savedMacs.first(where: { $0.macID == "mac-roam-host" }))
        XCTAssertEqual(saved.lastDirectHost, "127.0.0.1")
        XCTAssertEqual(saved.lastDirectPort, port)
        XCTAssertEqual(saved.lastBluetoothPeripheralID, bleID)

        secondClient.performQuickAction(.maximizeWindow)
        try await waitUntil("Command over roamed BLE link executed") {
            delegate.receivedQuickActions == [.maximizeWindow]
        }

        // 3. Roam back to Wi-Fi TCP using the same saved token
        secondClient.disconnect()
        secondClient.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Roaming Mac")
        try await waitUntil("Roamed back to Wi-Fi TCP") {
            secondClient.connectionState.isConnected &&
            secondClient.activeLink == .wifi &&
            server.pairedDevices.first?.activeLink == .wifi
        }
    }

    func testSecondMacDoesNotReceiveFirstSavedMacTokenOnWire() async throws {
        let suiteName = "com.choclift.tests.secondmac.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegateA = MockMacServerDelegate()
        let serverA = MacServerEngine(macID: "mac-A-primary", macName: "MacBook Pro")
        serverA.delegate = delegateA
        defer { serverA.stop() }

        let delegateB = MockMacServerDelegate()
        let serverB = MacServerEngine(macID: "mac-B-secondary", macName: "MacBook Pro")
        serverB.delegate = delegateB
        defer { serverB.stop() }

        let client = CompanionClientEngine(
            deviceID: "iphone-multi-mac",
            deviceName: "iPhone 17 Pro",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "multimac"
        )
        defer { client.disconnect() }

        // Pair with Mac A first
        client.connectInMemoryBluetooth(
            to: serverA.acceptInMemoryCompanion(),
            targetName: "MacBook Pro",
            macID: "mac-A-primary"
        )
        try await waitUntil("Mac A awaiting PIN") {
            if case .awaitingPIN = client.connectionState { return true }
            return false
        }
        client.submitPIN(serverA.currentPIN)
        try await waitUntil("Mac A paired") { client.connectionState.isConnected }
        let savedTokenA = try XCTUnwrap(client.savedMacs.first?.authToken)
        client.disconnect()

        // Intercept wire frames sent to Mac B (which shares the same human-readable name "MacBook Pro"
        // and advertises its 32-bit macIDTag before GATT metadata or TCP hello completes)
        let serverBPipe = serverB.acceptInMemoryCompanion()
        var clientMessagesToMacB: [ClientMessage] = []
        var wireAcc = WireStreamAccumulator()

        let inspectingTransport = InspectingFrameTransport(wrapping: serverBPipe) { outboundData in
            if let payloads = try? wireAcc.appendAndExtractPayloads(outboundData) {
                for payload in payloads {
                    if let msg = try? WireFrameCodec.decodePayload(ClientMessage.self, from: payload) {
                        clientMessagesToMacB.append(msg)
                    }
                }
            }
        }

        client.connectInMemoryBluetooth(
            to: inspectingTransport,
            targetName: "MacBook Pro",
            macID: nil,
            macIDTag: ChocliftBluetooth.macIDTag(for: "mac-B-secondary"),
            peripheralID: UUID()
        )

        try await waitUntil("Mac B awaiting PIN") {
            if case .awaitingPIN(let id, _, _) = client.connectionState {
                return id == "mac-B-secondary"
            }
            return false
        }

        XCTAssertFalse(clientMessagesToMacB.isEmpty)
        for msg in clientMessagesToMacB {
            if case .hello(_, _, _, _, let sentToken) = msg {
                XCTAssertNil(sentToken, "Mac B must never receive Mac A's saved authToken (\(savedTokenA))")
            }
        }
    }

    func testMacServerHeartbeatEvictsSilentBluetoothSessionWhileKeepingActiveHeartbeatAlive() async throws {
        let suiteName = "com.choclift.tests.hb.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = MockMacServerDelegate()
        let server = MacServerEngine(macID: "mac-hb-host", macName: "Heartbeat Mac")
        server.delegate = delegate
        server.bluetoothSessionTimeoutSeconds = 0.28
        server.heartbeatSweepIntervalSeconds = 0.05
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        // Silent client: disable periodic pings after auth to emulate a BLE device vanishing without GATT unsubscribe
        let silentClient = CompanionClientEngine(
            deviceID: "watch-silent-ble",
            deviceName: "Silent Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "hb-silent"
        )
        silentClient.heartbeatIntervalSeconds = 60.0
        silentClient.maxAutoReconnectAttempts = 0
        defer { silentClient.disconnect() }

        let (silentServerPipe, silentClientPipe) = SimulatedBLECompanionPipe.pair()
        server.acceptCompanionTransport(silentServerPipe, link: .bluetooth)
        silentClient.connectInMemoryBluetooth(to: silentClientPipe, targetName: "Heartbeat Mac")
        try await waitUntil("silent client awaiting PIN") {
            if case .awaitingPIN = silentClient.connectionState { return true }
            return false
        }
        silentClient.submitPIN(server.currentPIN)
        try await waitUntil("silent client connected") { silentClient.connectionState.isConnected }

        // Active client: sends heartbeats every 60ms so it stays alive across multiple timeout sweeps
        let activeClient = CompanionClientEngine(
            deviceID: "iphone-active-ble",
            deviceName: "Active iPhone",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "hb-active"
        )
        activeClient.heartbeatIntervalSeconds = 0.06
        defer { activeClient.disconnect() }

        let (activeServerPipe, activeClientPipe) = SimulatedBLECompanionPipe.pair()
        server.acceptCompanionTransport(activeServerPipe, link: .bluetooth)
        activeClient.connectInMemoryBluetooth(to: activeClientPipe, targetName: "Heartbeat Mac")
        try await waitUntil("active client awaiting PIN") {
            if case .awaitingPIN = activeClient.connectionState { return true }
            return false
        }
        activeClient.submitPIN(server.currentPIN)
        try await waitUntil("both BLE clients connected") {
            activeClient.connectionState.isConnected && server.connectedDeviceCount == 2
        }

        // Do NOT close silentClientPipe; wait for MacServerEngine heartbeat sweep to evict only the silent BLE session
        try await waitUntil("Mac server evicted silent BLE session via heartbeat timeout", timeoutSeconds: 2.0) {
            let silentRecord = server.pairedDevices.first(where: { $0.deviceID == "watch-silent-ble" })
            let activeRecord = server.pairedDevices.first(where: { $0.deviceID == "iphone-active-ble" })
            return server.connectedDeviceCount == 1 &&
                silentRecord?.isCurrentlyConnected == false &&
                silentRecord?.activeLink == nil &&
                activeRecord?.isCurrentlyConnected == true &&
                activeRecord?.activeLink == .bluetooth
        }
        XCTAssertTrue(activeClient.connectionState.isConnected)
    }

    func testCancellingOldLinkPreservesNewLinkPINEntrySurvivesGlitchAndDisconnectIsLaunchScoped() async throws {
        let suiteName = "com.choclift.tests.lifecycle.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = MockMacServerDelegate()
        let server = MacServerEngine(macID: "mac-lifecycle-host", macName: "Lifecycle Mac")
        server.delegate = delegate
        defer { server.stop() }

        let client = CompanionClientEngine(
            deviceID: "iphone-lifecycle-1",
            deviceName: "iPhone Lifecycle",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "lifecycle"
        )
        client.reconnectDelaySeconds = 0.05
        client.pinGlitchRecoveryWindowSeconds = 2.0
        defer { client.disconnect() }

        // 1. Start connecting on a stalled old transport, immediately switch to a live transport,
        //    then close the old transport asynchronously — must NOT tear down the new session.
        let stalledOldTransport = StalledFrameTransport()
        client.connectInMemoryBluetooth(to: stalledOldTransport, targetName: "Old Stalled Link")

        let (serverPipe1, clientPipe1) = SimulatedBLECompanionPipe.pair()
        server.acceptCompanionTransport(serverPipe1, link: .bluetooth)
        client.connectInMemoryBluetooth(to: clientPipe1, targetName: "Lifecycle Mac")
        stalledOldTransport.simulateAsyncLateClose()

        try await waitUntil("new link reached awaitingPIN unaffected by old link close") {
            if case .awaitingPIN = client.connectionState { return true }
            return false
        }

        // 2. Drop the underlying transport mid-PIN-entry -> PIN pad stays open (.awaitingPIN),
        //    recovers transport in background, and completes pairing with the entered PIN.
        client.simulatedBluetoothReconnectProvider = {
            let (serverPipe2, clientPipe2) = SimulatedBLECompanionPipe.pair()
            server.acceptCompanionTransport(serverPipe2, link: .bluetooth)
            return clientPipe2
        }
        serverPipe1.cancel()
        try await Task.sleep(for: .milliseconds(20))
        if case .awaitingPIN = client.connectionState {
            // Expected: PIN entry screen survived transient drop
        } else {
            XCTFail("Expected .awaitingPIN to survive brief transport glitch, got \(client.connectionState)")
        }

        client.submitPIN(server.currentPIN)
        try await waitUntil("PIN pairing succeeded across brief transport glitch") {
            client.connectionState.isConnected && client.activeLink == .bluetooth
        }

        // 3. Manual disconnect suppresses auto-connect for the current launch only; next launch re-enables it.
        client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.activeLink)
        XCTAssertTrue(client.isAutoConnectSuppressedForCurrentLaunch)

        let nextLaunchClient = CompanionClientEngine(
            deviceID: "iphone-lifecycle-1",
            deviceName: "iPhone Lifecycle",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "lifecycle"
        )
        defer { nextLaunchClient.disconnect() }
        XCTAssertFalse(nextLaunchClient.isAutoConnectSuppressedForCurrentLaunch)
        XCTAssertEqual(nextLaunchClient.savedMacs.map(\.macID), ["mac-lifecycle-host"])

        // 4. Failed connect settles cleanly in .disconnected with a visible issue message (never an endless spinner).
        nextLaunchClient.connectTimeoutSeconds = 0.2
        nextLaunchClient.maxAutoReconnectAttempts = 0
        let unreachable = StalledFrameTransport()
        unreachable.fireCloseAfterStartSeconds = 0.05
        nextLaunchClient.connectInMemoryBluetooth(to: unreachable, targetName: "Unreachable Mac")

        try await waitUntil("failed connect settles in disconnected error state") {
            nextLaunchClient.connectionState == .disconnected &&
            nextLaunchClient.activeLink == nil &&
            nextLaunchClient.lastConnectionIssue != nil
        }
    }

    private func waitUntil(
        _ label: String,
        timeoutSeconds: TimeInterval = 3.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TimeoutError(label: label)
    }
}

private final class InspectingFrameTransport: CompanionFrameTransport {
    private let wrapped: CompanionFrameTransport
    private let onOutbound: (Data) -> Void

    var onReady: (() -> Void)? {
        get { wrapped.onReady }
        set { wrapped.onReady = newValue }
    }

    var onPayload: ((Data) -> Void)? {
        get { wrapped.onPayload }
        set { wrapped.onPayload = newValue }
    }

    var onClosed: (() -> Void)? {
        get { wrapped.onClosed }
        set { wrapped.onClosed = newValue }
    }

    init(wrapping wrapped: CompanionFrameTransport, onOutbound: @escaping (Data) -> Void) {
        self.wrapped = wrapped
        self.onOutbound = onOutbound
    }

    func start() {
        wrapped.start()
    }

    func send(_ data: Data) {
        onOutbound(data)
        wrapped.send(data)
    }

    func cancel() {
        wrapped.cancel()
    }
}

private final class StalledFrameTransport: CompanionFrameTransport {
    var onReady: (() -> Void)?
    var onPayload: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    var fireCloseAfterStartSeconds: TimeInterval?

    func start() {
        if let delay = fireCloseAfterStartSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onClosed?()
            }
        }
    }

    func send(_ data: Data) {}

    func cancel() {}

    func simulateAsyncLateClose() {
        DispatchQueue.main.async { [weak self] in
            self?.onClosed?()
        }
    }
}
