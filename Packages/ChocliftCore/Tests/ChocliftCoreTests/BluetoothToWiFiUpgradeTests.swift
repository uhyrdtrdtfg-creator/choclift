import Combine
import Darwin
import Foundation
import Network
import XCTest
@testable import ChocliftCore

@MainActor
private final class UpgradeTestServerDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var recentApps: [RecentAppEntry] = [
        RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true)
    ]
    var frontmostBundleID: String? = "com.apple.finder"
    var isEditingText = false
    var focusedAppName: String?
    var pairedDevicesSnapshot: [PairedDeviceRecord] = []

    var controlStripState = ControlStripState(
        volume: 0.35,
        isVolumeMuted: false,
        brightness: 0.50,
        isBrightnessAvailable: true,
        isMicMuted: false,
        nowPlaying: NowPlayingStatus(
            title: "Midnight City",
            artist: "M83",
            appName: "Spotify",
            isPlaying: true,
            elapsedSeconds: 30,
            durationSeconds: 240,
            bundleIdentifier: "com.spotify.client"
        )
    )
    /// Simulates delayed hardware readback when false so post-upgrade `.requestControlStripState` returns older levels.
    var applySetControlLevelImmediately = true

    var insertedEmojis: [(emoji: String, link: CompanionLinkKind?)] = []
    var receivedControlLevels: [(kind: ControlLevelKind, level: Double, link: CompanionLinkKind?)] = []
    var receivedSeeks: [(seconds: Double, link: CompanionLinkKind?)] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { recentApps }
    func serverFrontmostBundleID() -> String? { frontmostBundleID }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (isEditingText, focusedAppName) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }

    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {
        pairedDevicesSnapshot = devices
    }

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(controlStripState))
        case .setControlLevel(let kind, let level):
            receivedControlLevels.append((kind: kind, level: level, link: device.activeLink))
            if applySetControlLevelImmediately {
                switch kind {
                case .volume:
                    controlStripState.volume = level
                case .brightness:
                    controlStripState.brightness = level
                }
            }
        case .seekNowPlaying(let seconds):
            receivedSeeks.append((seconds: seconds, link: device.activeLink))
            controlStripState.nowPlaying?.elapsedSeconds = seconds
            reply(.controlStripStateUpdated(controlStripState))
        case .insertEmoji(let emoji):
            insertedEmojis.append((emoji: emoji, link: device.activeLink))
            reply(.actionFeedback(success: true, title: emoji, detail: "Inserted"))
        default:
            break
        }
    }
}

/// Controllable in-memory `CompanionFrameTransport` pair that can hold server->client frames
/// so tests can deterministically inspect mid-handshake state before `.authSucceeded` arrives.
private final class GatedCompanionTransport: CompanionFrameTransport {
    var onReady: (() -> Void)?
    var onPayload: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    private(set) var isStarted = false
    private(set) var isClosed = false
    var holdInboundPayloads = false
    private var heldInboundPayloads: [Data] = []
    weak var peer: GatedCompanionTransport?

    static func pair() -> (server: GatedCompanionTransport, client: GatedCompanionTransport) {
        let server = GatedCompanionTransport()
        let client = GatedCompanionTransport()
        server.peer = client
        client.peer = server
        return (server, client)
    }

    func start() {
        guard !isStarted, !isClosed else { return }
        isStarted = true
        onReady?()
    }

    func send(_ data: Data) {
        guard !isClosed, let peer, !peer.isClosed else { return }
        peer.deliverInbound(data)
    }

    private func deliverInbound(_ data: Data) {
        guard !isClosed else { return }
        if holdInboundPayloads {
            heldInboundPayloads.append(data)
        } else {
            onPayload?(data)
        }
    }

    func releaseHeldInboundPayloads() {
        holdInboundPayloads = false
        guard !isClosed else {
            heldInboundPayloads.removeAll()
            return
        }
        let queued = heldInboundPayloads
        heldInboundPayloads.removeAll()
        for chunk in queued {
            onPayload?(chunk)
        }
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        heldInboundPayloads.removeAll()
        let other = peer
        peer = nil
        other?.peer = nil
        onClosed?()
        if let other, !other.isClosed {
            other.isClosed = true
            other.heldInboundPayloads.removeAll()
            other.onClosed?()
        }
    }
}

@MainActor
final class BluetoothToWiFiUpgradeTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    private func waitUntil(
        _ label: String,
        timeoutSeconds: TimeInterval = 3.0,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        if condition() { return }
        throw TimeoutError(label: label)
    }

    private static func makeUnknownServerFrame() -> Data {
        let unknownPayload = Data(#"{"futurePreAuthServerEvent":{"flag":true}}"#.utf8)
        var lengthBE = UInt32(unknownPayload.count).bigEndian
        var framed = Data(capacity: 4 + unknownPayload.count)
        withUnsafeBytes(of: &lengthBE) { framed.append(contentsOf: $0) }
        framed.append(unknownPayload)
        return framed
    }

    private nonisolated static func isLoopbackSocketAllowedByEnvironment() -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

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
        return bindResult == 0 && Darwin.listen(fd, 1) == 0
    }

    private func pairInitialBLESession(
        server: MacServerEngine,
        defaults: UserDefaults,
        storagePrefix: String,
        deviceID: String,
        peripheralID: UUID
    ) async throws {
        let pairingClient = CompanionClientEngine(
            deviceID: deviceID,
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: storagePrefix
        )
        defer { pairingClient.disconnect() }

        let (serverPipe, clientPipe) = SimulatedBLECompanionPipe.pair(
            serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
        )
        server.acceptCompanionTransport(serverPipe, link: .bluetooth)
        pairingClient.connectInMemoryBluetooth(
            to: clientPipe,
            targetName: server.macName,
            macID: server.macID,
            peripheralID: peripheralID
        )
        try await waitUntil("initial BLE awaiting PIN") {
            if case .awaitingPIN = pairingClient.connectionState { return true }
            return false
        }
        pairingClient.submitPIN(server.currentPIN)
        try await waitUntil("initial BLE paired") {
            pairingClient.connectionState.isConnected && !pairingClient.savedMacs.isEmpty
        }
    }

    func testSimulatedBLEUpgradesToWiFiOnlyAfterTCPAuthSucceedsAndReleasesBLE() async throws {
        XCTAssertEqual(ChocliftDefaults.protocolVersion, 3, "Protocol version must not be bumped")

        let suite = "com.choclift.tests.blewifi.sim.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegate = UpgradeTestServerDelegate()
        let server = MacServerEngine(macID: "mac-upgrade-sim", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        let peripheralID = UUID()
        try await pairInitialBLESession(
            server: server,
            defaults: defaults,
            storagePrefix: "sim-upgrade",
            deviceID: "iphone-upgrade-sim",
            peripheralID: peripheralID
        )
        server.regeneratePIN()

        let client = CompanionClientEngine(
            deviceID: "iphone-upgrade-sim",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "sim-upgrade"
        )
        defer { client.disconnect() }

        var activeBLEClientPipe: SimulatedBLECompanionPipe?
        var bleTransportClosed = false
        client.simulatedBluetoothConnector = { _ in
            let (serverBLE, clientBLE) = SimulatedBLECompanionPipe.pair(
                serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
            )
            activeBLEClientPipe = clientBLE
            server.acceptCompanionTransport(serverBLE, link: .bluetooth)
            let prevClosed = serverBLE.onClosed
            serverBLE.onClosed = {
                bleTransportClosed = true
                prevClosed?()
            }
            return clientBLE
        }

        // Reproduce the exact foreground launch race: BLE is available before Bonjour finishes.
        client.simulateDiscoveredBluetoothMacs(
            [DiscoveredBluetoothMac(id: peripheralID, name: server.macName, macID: server.macID)],
            autoConnect: false
        )
        XCTAssertTrue(client.discoveredMacs.isEmpty)
        client.handleAppDidBecomeActive()

        try await waitUntil("BLE session authenticated on app activation") {
            client.connectionState == .connected(macID: server.macID, macName: server.macName) &&
            client.activeLink == .bluetooth
        }
        XCTAssertNotNil(activeBLEClientPipe)

        var observedStates: [CompanionConnectionState] = []
        var observedLinks: [CompanionLinkKind?] = []
        var cancellables: Set<AnyCancellable> = []
        client.$connectionState
            .dropFirst()
            .sink { observedStates.append($0) }
            .store(in: &cancellables)
        client.$activeLink
            .dropFirst()
            .sink { observedLinks.append($0) }
            .store(in: &cancellables)

        // Hold `.authSucceeded` on the simulated Wi-Fi link so we can verify activeLink does NOT switch early.
        var gatedWiFiClient: GatedCompanionTransport?
        var tcpHelloTokenSent: String?
        client.simulatedWiFiConnector = { _ in
            let (wifiServer, wifiClient) = GatedCompanionTransport.pair()
            wifiClient.holdInboundPayloads = true
            gatedWiFiClient = wifiClient
            server.acceptCompanionTransport(wifiServer, link: .wifi)
            let serverOnPayload = wifiServer.onPayload
            wifiServer.onPayload = { raw in
                var acc = WireStreamAccumulator()
                if let payloads = try? acc.appendAndExtractPayloads(raw) {
                    for p in payloads {
                        if case let .hello(_, _, _, _, savedToken) = try? WireFrameCodec.decodePayload(ClientMessage.self, from: p) {
                            tcpHelloTokenSent = savedToken
                        }
                    }
                }
                serverOnPayload?(raw)
            }
            return wifiClient
        }

        let bonjourHost = DiscoveredMacHost(
            id: "studio-mac._choclift._tcp.local.",
            name: server.macName,
            macID: server.macID,
            endpoint: .hostPort(host: "127.0.0.1", port: 48_841),
            directHost: "127.0.0.1",
            directPort: 48_841
        )
        client.simulateDiscoveredWiFiMacs([bonjourHost])

        try await waitUntil("background TCP sent saved token hello") {
            tcpHelloTokenSent != nil
        }
        XCTAssertEqual(tcpHelloTokenSent, client.savedMacs.first?.authToken)
        XCTAssertTrue(client.isBackgroundWiFiUpgradeInFlight)
        XCTAssertEqual(client.activeLink, .bluetooth, "Must NOT switch activeLink to Wi-Fi before TCP auth succeeds")
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))
        XCTAssertTrue(observedStates.isEmpty, "Session must not drop or ask for PIN while TCP auth is pending")

        // Now deliver `.authSucceeded` on the simulated TCP link.
        gatedWiFiClient?.releaseHeldInboundPayloads()

        try await waitUntil("activeLink upgraded to Wi-Fi after TCP auth succeeded") {
            client.activeLink == .wifi && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))
        XCTAssertTrue(observedStates.isEmpty, "Upgrade cutover must never transition through .disconnected, .connecting, or .awaitingPIN")
        XCTAssertEqual(observedLinks, [.wifi])
        XCTAssertTrue(bleTransportClosed, "BLE session must be released once TCP auth succeeds")
        XCTAssertEqual(server.connectedDeviceCount, 1)
        XCTAssertEqual(server.pairedDevices.first?.activeLink, .wifi)

        // Verify post-upgrade traffic flows over Wi-Fi.
        client.insertEmoji("🍫")
        try await waitUntil("emoji delivered over upgraded Wi-Fi link") {
            delegate.insertedEmojis.contains(where: { $0.emoji == "🍫" && $0.link == .wifi })
        }
    }

    func testFailedTCPAuthConnectionAndUntrustedHostKeepAuthenticatedBLESessionUp() async throws {
        let suite = "com.choclift.tests.blewifi.fail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegate = UpgradeTestServerDelegate()
        let server = MacServerEngine(macID: "mac-ble-keep", macName: "Office Mac")
        server.delegate = delegate
        defer { server.stop() }

        let peripheralID = UUID()
        try await pairInitialBLESession(
            server: server,
            defaults: defaults,
            storagePrefix: "fail-upgrade",
            deviceID: "iphone-ble-keep",
            peripheralID: peripheralID
        )

        let client = CompanionClientEngine(
            deviceID: "iphone-ble-keep",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "fail-upgrade"
        )
        client.connectTimeoutSeconds = 0.18
        defer { client.disconnect() }

        let (serverBLE, clientBLE) = SimulatedBLECompanionPipe.pair(
            serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
        )
        var bleClosed = false
        server.acceptCompanionTransport(serverBLE, link: .bluetooth)
        let prevServerBLEClosed = serverBLE.onClosed
        serverBLE.onClosed = {
            bleClosed = true
            prevServerBLEClosed?()
        }
        client.connectInMemoryBluetooth(
            to: clientBLE,
            targetName: server.macName,
            macID: server.macID,
            peripheralID: peripheralID
        )
        try await waitUntil("BLE connected") {
            client.connectionState.isConnected && client.activeLink == .bluetooth
        }

        var stateChanges: [CompanionConnectionState] = []
        var cancellables: Set<AnyCancellable> = []
        client.$connectionState.dropFirst().sink { stateChanges.append($0) }.store(in: &cancellables)

        let wifiHost = DiscoveredMacHost(
            id: "office-mac._choclift._tcp.local.",
            name: server.macName,
            macID: server.macID,
            endpoint: .hostPort(host: "127.0.0.1", port: 48_842)
        )

        // 1. TCP `.authFailed` keeps BLE up and closes background TCP.
        var authFailedPipeClosed = false
        client.simulatedWiFiConnector = { _ in
            let (serverEnd, clientEnd) = GatedCompanionTransport.pair()
            serverEnd.start()
            serverEnd.onClosed = { authFailedPipeClosed = true }
            serverEnd.onPayload = { _ in
                if let frame = try? WireFrameCodec.encode(ServerMessage.authFailed(reason: "Token rejected")) {
                    serverEnd.send(frame)
                }
            }
            return clientEnd
        }
        client.simulateDiscoveredWiFiMacs([wifiHost])
        try await waitUntil("failed TCP auth cleaned up") {
            authFailedPipeClosed && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertEqual(client.activeLink, .bluetooth)
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))
        XCTAssertFalse(bleClosed)

        // 2. TCP `.pairingRequired` after saved token was sent (token revoked on TCP target) never asks for PIN and keeps BLE up.
        var pairingRejectedClosed = false
        client.simulatedWiFiConnector = { _ in
            let (serverEnd, clientEnd) = GatedCompanionTransport.pair()
            serverEnd.start()
            serverEnd.onClosed = { pairingRejectedClosed = true }
            serverEnd.onPayload = { _ in
                if let frame = try? WireFrameCodec.encode(ServerMessage.pairingRequired(macID: server.macID, macName: server.macName)) {
                    serverEnd.send(frame)
                }
            }
            return clientEnd
        }
        client.simulateDiscoveredWiFiMacs([wifiHost])
        try await waitUntil("token-rejected TCP upgrade cleaned up") {
            pairingRejectedClosed && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertEqual(client.activeLink, .bluetooth)
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))

        // 3. TCP connection failure (`nil` transport) and handshake timeout both keep BLE up.
        client.simulatedWiFiConnector = { _ in nil }
        client.simulateDiscoveredWiFiMacs([wifiHost])
        XCTAssertFalse(client.isBackgroundWiFiUpgradeInFlight)
        XCTAssertEqual(client.activeLink, .bluetooth)

        var retainedSilentServerEnd: GatedCompanionTransport?
        var timedOutPipeClosed = false
        client.simulatedWiFiConnector = { _ in
            let (serverEnd, clientEnd) = GatedCompanionTransport.pair()
            retainedSilentServerEnd = serverEnd
            serverEnd.start()
            serverEnd.onClosed = { timedOutPipeClosed = true }
            return clientEnd
        }
        client.simulateDiscoveredWiFiMacs([wifiHost])
        try await waitUntil("silent TCP upgrade timed out cleanly") {
            timedOutPipeClosed && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertNotNil(retainedSilentServerEnd)
        XCTAssertEqual(client.activeLink, .bluetooth)
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))

        // 4. Untrusted Bonjour host with same Mac name (`macID == nil`) must NOT receive saved token and must keep BLE up.
        var tokensSentToImposter: [String] = []
        var imposterClosed = false
        client.simulatedWiFiConnector = { _ in
            let (imposterServer, imposterClient) = GatedCompanionTransport.pair()
            imposterServer.start()
            imposterServer.onClosed = { imposterClosed = true }
            imposterServer.onPayload = { raw in
                var acc = WireStreamAccumulator()
                if let payloads = try? acc.appendAndExtractPayloads(raw) {
                    for p in payloads {
                        if case let .hello(_, _, _, _, token) = try? WireFrameCodec.decodePayload(ClientMessage.self, from: p) {
                            if let token { tokensSentToImposter.append(token) }
                            if let reply = try? WireFrameCodec.encode(ServerMessage.pairingRequired(macID: "untrusted-other-mac", macName: server.macName)) {
                                imposterServer.send(reply)
                            }
                        }
                    }
                }
            }
            return imposterClient
        }
        client.simulateDiscoveredWiFiMacs([
            DiscoveredMacHost(
                id: "imposter._choclift._tcp.local.",
                name: server.macName,
                macID: nil,
                endpoint: .hostPort(host: "127.0.0.1", port: 48_843)
            )
        ])
        try await waitUntil("imposter host rejected without leaking saved token") {
            imposterClosed && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertTrue(tokensSentToImposter.isEmpty, "Saved auth token must never be sent before Mac identity is verified")
        XCTAssertTrue(stateChanges.isEmpty, "Failed TCP attempts must never drop or alter the BLE session state")
        XCTAssertFalse(bleClosed)

        // Confirm BLE session still carries commands after all failed TCP attempts.
        client.insertEmoji("🛡")
        try await waitUntil("BLE command still works after failed TCP upgrades") {
            delegate.insertedEmojis.contains(where: { $0.emoji == "🛡" && $0.link == .bluetooth })
        }
    }

    func testRealLoopbackTCPUpgradeFromSimulatedBLEReleasesBLEWithoutSessionDrop() async throws {
        guard Self.isLoopbackSocketAllowedByEnvironment() else {
            throw XCTSkip("Loopback TCP sockets are restricted in this sandbox.")
        }

        let suite = "com.choclift.tests.blewifi.loopback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegate = UpgradeTestServerDelegate()
        let server = MacServerEngine(macID: "mac-loopback-roam", macName: "Loopback Mac")
        server.delegate = delegate
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("server bound loopback TCP port") { server.listeningPort != nil }
        let tcpPort = try XCTUnwrap(server.listeningPort)

        let peripheralID = UUID()
        try await pairInitialBLESession(
            server: server,
            defaults: defaults,
            storagePrefix: "loopback-roam",
            deviceID: "iphone-loopback-roam",
            peripheralID: peripheralID
        )
        server.regeneratePIN()

        let client = CompanionClientEngine(
            deviceID: "iphone-loopback-roam",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "loopback-roam"
        )
        defer { client.disconnect() }

        var bleServerClosed = false
        let (bleServerPipe, bleClientPipe) = SimulatedBLECompanionPipe.pair(
            serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
        )
        server.acceptCompanionTransport(bleServerPipe, link: .bluetooth)
        let prevLoopbackBLEClosed = bleServerPipe.onClosed
        bleServerPipe.onClosed = {
            bleServerClosed = true
            prevLoopbackBLEClosed?()
        }
        client.connectInMemoryBluetooth(
            to: bleClientPipe,
            targetName: server.macName,
            macID: server.macID,
            peripheralID: peripheralID
        )
        try await waitUntil("BLE session up") {
            client.connectionState == .connected(macID: server.macID, macName: server.macName) &&
            client.activeLink == .bluetooth
        }

        var stateTransitions: [CompanionConnectionState] = []
        var cancellables: Set<AnyCancellable> = []
        client.$connectionState.dropFirst().sink { stateTransitions.append($0) }.store(in: &cancellables)

        let nwPort = try XCTUnwrap(NWEndpoint.Port(rawValue: tcpPort))
        client.simulateDiscoveredWiFiMacs([
            DiscoveredMacHost(
                id: "loopback._choclift._tcp.local.",
                name: server.macName,
                macID: server.macID,
                endpoint: .hostPort(host: "127.0.0.1", port: nwPort),
                directHost: "127.0.0.1",
                directPort: tcpPort
            )
        ])

        try await waitUntil("real NWConnection TCP upgraded session from BLE to Wi-Fi") {
            client.activeLink == .wifi && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertTrue(bleServerClosed, "BLE pipe must be released once TCP auth succeeds")
        XCTAssertTrue(stateTransitions.isEmpty, "Session must remain continuously .connected across BLE eviction and TCP cutover")
        XCTAssertEqual(server.connectedDeviceCount, 1)
        XCTAssertEqual(server.pairedDevices.first?.activeLink, .wifi)

        client.insertEmoji("⚡️")
        try await waitUntil("post-upgrade command handled over real TCP") {
            delegate.insertedEmojis.contains(where: { $0.emoji == "⚡️" && $0.link == .wifi })
        }
    }

    func testInFlightVolumeBrightnessAndSeekDragsAreNotInterruptedDuringWiFiUpgrade() async throws {
        let suite = "com.choclift.tests.blewifi.drags.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegate = UpgradeTestServerDelegate()
        // Emulate delayed hardware level readback so post-upgrade `.requestControlStripState` sends stale levels.
        delegate.applySetControlLevelImmediately = false
        let server = MacServerEngine(macID: "mac-drag-roam", macName: "Media Mac")
        server.delegate = delegate
        defer { server.stop() }

        let peripheralID = UUID()
        try await pairInitialBLESession(
            server: server,
            defaults: defaults,
            storagePrefix: "drag-roam",
            deviceID: "iphone-drag-roam",
            peripheralID: peripheralID
        )

        let client = CompanionClientEngine(
            deviceID: "iphone-drag-roam",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "drag-roam"
        )
        defer { client.disconnect() }

        let (bleServerPipe, bleClientPipe) = SimulatedBLECompanionPipe.pair(
            mtu: 24,
            serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
        )
        server.acceptCompanionTransport(bleServerPipe, link: .bluetooth)
        client.connectInMemoryBluetooth(
            to: bleClientPipe,
            targetName: server.macName,
            macID: server.macID,
            peripheralID: peripheralID
        )
        try await waitUntil("BLE connected with Now Playing") {
            client.connectionState.isConnected &&
            client.activeLink == .bluetooth &&
            client.controlStripState.nowPlaying?.isSeekable == true
        }

        // Begin seek drag, volume drag, and brightness drag while on BLE.
        var volumeThrottle = ControlLevelDragThrottle()
        var brightnessThrottle = ControlLevelDragThrottle()
        let t0: TimeInterval = 100.0
        if let v1 = volumeThrottle.updateDrag(to: 0.62, at: t0) {
            client.setControlLevel(kind: .volume, level: v1)
        }
        if let b1 = brightnessThrottle.updateDrag(to: 0.44, at: t0) {
            client.setControlLevel(kind: .brightness, level: b1)
        }
        let scrubPreview = client.updateNowPlayingScrub(normalizedProgress: 0.5)
        XCTAssertEqual(scrubPreview ?? -1, 120.0, accuracy: 0.01)
        XCTAssertTrue(client.nowPlayingScrub.isScrubbing)

        var gatedWiFiClient: GatedCompanionTransport?
        client.simulatedWiFiConnector = { _ in
            let (wifiServer, wifiClient) = GatedCompanionTransport.pair()
            wifiClient.holdInboundPayloads = true
            gatedWiFiClient = wifiClient
            server.acceptCompanionTransport(wifiServer, link: .wifi)
            return wifiClient
        }

        // Simulate BLE outbound backpressure right as the user drags further and LAN appears.
        bleClientPipe.maxChunksPerFlush = 1
        client.simulateDiscoveredWiFiMacs([
            DiscoveredMacHost(
                id: "media-mac._choclift._tcp.local.",
                name: server.macName,
                macID: server.macID,
                endpoint: .hostPort(host: "127.0.0.1", port: 48_844)
            )
        ])

        try await waitUntil("background Wi-Fi upgrade started") {
            client.isBackgroundWiFiUpgradeInFlight
        }

        // Continue dragging volume, brightness, and seek while TCP handshake is mid-flight.
        if let v2 = volumeThrottle.updateDrag(to: 0.78, at: t0 + 0.20) {
            client.setControlLevel(kind: .volume, level: v2)
        }
        if let b2 = brightnessThrottle.updateDrag(to: 0.86, at: t0 + 0.20) {
            client.setControlLevel(kind: .brightness, level: b2)
        }
        _ = client.updateNowPlayingScrub(normalizedProgress: 0.6)

        gatedWiFiClient?.releaseHeldInboundPayloads()
        try await waitUntil("upgraded to Wi-Fi during active drags") {
            client.activeLink == .wifi && !client.isBackgroundWiFiUpgradeInFlight
        }
        // Allow post-upgrade `.controlStripStateUpdated` refresh to settle.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(client.connectionState.isConnected)
        XCTAssertTrue(client.nowPlayingScrub.isScrubbing, "In-flight seek scrub must not be cancelled by Wi-Fi upgrade")
        XCTAssertEqual(client.nowPlayingScrub.previewPositionSeconds ?? -1, 144.0, accuracy: 0.01)
        XCTAssertEqual(client.controlStripState.volume, 0.78, accuracy: 0.001, "In-flight volume drag must not snap back")
        XCTAssertEqual(client.controlStripState.brightness, 0.86, accuracy: 0.001, "In-flight brightness drag must not snap back")

        // Finish all three drags after upgrade completes; final values must commit cleanly over Wi-Fi.
        delegate.applySetControlLevelImmediately = true
        let finalVolume = volumeThrottle.endDrag(at: 0.84, at: t0 + 0.35)
        client.setControlLevel(kind: .volume, level: finalVolume)
        let finalBrightness = brightnessThrottle.endDrag(at: 0.91, at: t0 + 0.35)
        client.setControlLevel(kind: .brightness, level: finalBrightness)
        let committedSeek = client.commitNowPlayingScrub(normalizedProgress: 0.75)
        XCTAssertEqual(committedSeek ?? -1, 180.0, accuracy: 0.01)
        XCTAssertFalse(client.nowPlayingScrub.isScrubbing)

        try await waitUntil("final volume, brightness, and seek delivered over Wi-Fi") {
            delegate.receivedControlLevels.contains(where: { $0.kind == .volume && abs($0.level - 0.84) < 0.001 && $0.link == .wifi }) &&
            delegate.receivedControlLevels.contains(where: { $0.kind == .brightness && abs($0.level - 0.91) < 0.001 && $0.link == .wifi }) &&
            delegate.receivedSeeks.contains(where: { abs($0.seconds - 180.0) < 0.01 && $0.link == .wifi })
        }
    }

    func testUserDisconnectSuppressesAutoReconnectAndPreAuthUnknownFramesDisconnect() async throws {
        let suite = "com.choclift.tests.blewifi.disconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegate = UpgradeTestServerDelegate()
        let server = MacServerEngine(macID: "mac-sec-host", macName: "Security Mac")
        server.delegate = delegate
        defer { server.stop() }

        let peripheralID = UUID()
        try await pairInitialBLESession(
            server: server,
            defaults: defaults,
            storagePrefix: "sec-roam",
            deviceID: "iphone-sec-roam",
            peripheralID: peripheralID
        )

        // 1. Primary pre-auth unknown frame disconnects immediately.
        let unauthClient = CompanionClientEngine(
            deviceID: "iphone-unauth",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "sec-unauth"
        )
        unauthClient.maxAutoReconnectAttempts = 0
        defer { unauthClient.disconnect() }

        let (unauthServerEnd, unauthClientEnd) = GatedCompanionTransport.pair()
        unauthServerEnd.start()
        unauthClient.connectInMemoryBluetooth(to: unauthClientEnd, targetName: "Security Mac")
        unauthServerEnd.send(Self.makeUnknownServerFrame())
        try await waitUntil("primary pre-auth unknown frame disconnected") {
            unauthClient.connectionState == .disconnected && unauthServerEnd.isClosed
        }

        // 2. Pre-auth unknown frame on background TCP upgrade disconnects the TCP attempt while keeping BLE up.
        let client = CompanionClientEngine(
            deviceID: "iphone-sec-roam",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "sec-roam"
        )
        defer { client.disconnect() }

        let (bleServerPipe, bleClientPipe) = SimulatedBLECompanionPipe.pair(
            serverMetadata: BluetoothServiceMetadata(macID: server.macID, macName: server.macName)
        )
        server.acceptCompanionTransport(bleServerPipe, link: .bluetooth)
        client.connectInMemoryBluetooth(
            to: bleClientPipe,
            targetName: server.macName,
            macID: server.macID,
            peripheralID: peripheralID
        )
        try await waitUntil("BLE connected before unknown pre-auth TCP frame") {
            client.connectionState.isConnected && client.activeLink == .bluetooth
        }

        var upgradePipeClosed = false
        client.simulatedWiFiConnector = { _ in
            let (serverEnd, clientEnd) = GatedCompanionTransport.pair()
            serverEnd.start()
            serverEnd.onClosed = { upgradePipeClosed = true }
            serverEnd.onPayload = { _ in
                serverEnd.send(Self.makeUnknownServerFrame())
            }
            return clientEnd
        }

        let wifiHost = DiscoveredMacHost(
            id: "sec-mac._choclift._tcp.local.",
            name: server.macName,
            macID: server.macID,
            endpoint: .hostPort(host: "127.0.0.1", port: 48_845)
        )
        client.simulateDiscoveredWiFiMacs([wifiHost])
        try await waitUntil("pre-auth unknown frame on upgrade TCP disconnected TCP socket") {
            upgradePipeClosed && !client.isBackgroundWiFiUpgradeInFlight
        }
        XCTAssertEqual(client.activeLink, .bluetooth)
        XCTAssertEqual(client.connectionState, .connected(macID: server.macID, macName: server.macName))

        // 3. Upgrade to Wi-Fi, then user disconnects: neither BLE nor Wi-Fi auto-reconnects.
        client.simulatedWiFiConnector = { _ in
            let (wifiServer, wifiClient) = GatedCompanionTransport.pair()
            server.acceptCompanionTransport(wifiServer, link: .wifi)
            return wifiClient
        }
        client.simulateDiscoveredWiFiMacs([wifiHost])
        try await waitUntil("upgraded to Wi-Fi before user disconnect") {
            client.activeLink == .wifi
        }

        client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.activeLink)
        XCTAssertTrue(client.isAutoConnectSuppressedForCurrentLaunch)

        client.simulatedBluetoothConnector = { _ in
            XCTFail("User disconnect must not auto-reconnect BLE")
            return nil
        }
        client.simulatedWiFiConnector = { _ in
            XCTFail("User disconnect must not auto-reconnect Wi-Fi")
            return nil
        }
        client.simulateDiscoveredBluetoothMacs([
            DiscoveredBluetoothMac(id: peripheralID, name: server.macName, macID: server.macID)
        ])
        client.simulateDiscoveredWiFiMacs([wifiHost])
        client.handleAppDidBecomeActive()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.activeLink)
    }

    func testMultiSavedMacIsolationZeroTXTIdentityVerifyAndEvictionCutoverWindowCommands() async throws {
        let suite = "com.choclift.tests.blewifi.multi.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let delegateA = UpgradeTestServerDelegate()
        let serverA = MacServerEngine(macID: "mac-home-a", macName: "Home Mac")
        serverA.delegate = delegateA
        defer { serverA.stop() }

        let delegateB = UpgradeTestServerDelegate()
        let serverB = MacServerEngine(macID: "mac-work-b", macName: "Work Mac")
        serverB.delegate = delegateB
        defer { serverB.stop() }

        let peripheralA = UUID()
        let peripheralB = UUID()
        try await pairInitialBLESession(
            server: serverA,
            defaults: defaults,
            storagePrefix: "multi-roam",
            deviceID: "iphone-multi-roam",
            peripheralID: peripheralA
        )
        try await pairInitialBLESession(
            server: serverB,
            defaults: defaults,
            storagePrefix: "multi-roam",
            deviceID: "iphone-multi-roam",
            peripheralID: peripheralB
        )

        let client = CompanionClientEngine(
            deviceID: "iphone-multi-roam",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "multi-roam"
        )
        defer { client.disconnect() }

        let (bleServerA, bleClientA) = SimulatedBLECompanionPipe.pair(
            serverMetadata: BluetoothServiceMetadata(macID: serverA.macID, macName: serverA.macName)
        )
        serverA.acceptCompanionTransport(bleServerA, link: .bluetooth)
        client.connectInMemoryBluetooth(
            to: bleClientA,
            targetName: serverA.macName,
            macID: serverA.macID,
            peripheralID: peripheralA
        )
        try await waitUntil("connected to Mac A over BLE") {
            client.connectionState == .connected(macID: serverA.macID, macName: serverA.macName) &&
            client.activeLink == .bluetooth &&
            client.controlStripState.nowPlaying?.isSeekable == true
        }

        // Another saved Mac (Mac B) appearing on Bonjour must NOT trigger a TCP upgrade while connected to Mac A.
        var unexpectedConnects = 0
        client.simulatedWiFiConnector = { _ in
            unexpectedConnects += 1
            return nil
        }
        client.simulateDiscoveredWiFiMacs([
            DiscoveredMacHost(
                id: "work-mac._choclift._tcp.local.",
                name: serverB.macName,
                macID: serverB.macID,
                endpoint: .hostPort(host: "127.0.0.1", port: 48_846)
            )
        ])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(unexpectedConnects, 0)
        XCTAssertEqual(client.activeLink, .bluetooth)
        XCTAssertEqual(client.connectionState, .connected(macID: serverA.macID, macName: serverA.macName))

        // Now Mac A appears with `macID == nil` (TXT not yet populated): client must verify Mac A's identity first,
        // send Mac A's token, hold `.connected` across server BLE eviction, and flush cutover-window commands on Wi-Fi.
        var gatedWiFiClient: GatedCompanionTransport?
        var bleEvictedOnServer = false
        let prevBLEClosed = bleServerA.onClosed
        bleServerA.onClosed = {
            bleEvictedOnServer = true
            prevBLEClosed?()
        }

        var helloTokensObserved: [String?] = []
        client.simulatedWiFiConnector = { _ in
            let (wifiServer, wifiClient) = GatedCompanionTransport.pair()
            gatedWiFiClient = wifiClient
            serverA.acceptCompanionTransport(wifiServer, link: .wifi)
            let origOnPayload = wifiServer.onPayload
            wifiServer.onPayload = { raw in
                var acc = WireStreamAccumulator()
                if let payloads = try? acc.appendAndExtractPayloads(raw) {
                    for p in payloads {
                        if case let .hello(_, _, _, _, token) = try? WireFrameCodec.decodePayload(ClientMessage.self, from: p) {
                            helloTokensObserved.append(token)
                            if token != nil {
                                // Hold `.authSucceeded` so BLE eviction (`onClosed`) arrives BEFORE `.authSucceeded`!
                                wifiClient.holdInboundPayloads = true
                            }
                        }
                    }
                }
                origOnPayload?(raw)
            }
            return wifiClient
        }

        var stateChanges: [CompanionConnectionState] = []
        var cancellables: Set<AnyCancellable> = []
        client.$connectionState.dropFirst().sink { stateChanges.append($0) }.store(in: &cancellables)

        _ = client.updateNowPlayingScrub(normalizedProgress: 0.25)
        client.simulateDiscoveredWiFiMacs([
            DiscoveredMacHost(
                id: "home-mac._choclift._tcp.local.",
                name: serverA.macName,
                macID: nil,
                endpoint: .hostPort(host: "127.0.0.1", port: 48_847)
            )
        ])

        try await waitUntil("server evicted BLE while TCP authSucceeded is still in flight") {
            bleEvictedOnServer && helloTokensObserved.count == 2
        }
        // Allow BLE `onClosed` Task to run on MainActor while `.authSucceeded` is still held.
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertNil(helloTokensObserved[0], "First hello on unverified TXT record must omit token")
        XCTAssertNotNil(helloTokensObserved[1], "Second hello after pairingRequired verified Mac A must send token")
        XCTAssertTrue(stateChanges.isEmpty, "BLE eviction during token handoff must not drop connectionState")

        // Commit volume, brightness, and seek during the exact BLE-evicted / pre-promotion cutover window.
        client.setControlLevel(kind: .volume, level: 0.73)
        client.setControlLevel(kind: .brightness, level: 0.68)
        _ = client.commitNowPlayingScrub(normalizedProgress: 0.5)

        gatedWiFiClient?.releaseHeldInboundPayloads()
        try await waitUntil("cutover completed to Wi-Fi and queued drag commits flushed") {
            client.activeLink == .wifi &&
            delegateA.receivedControlLevels.contains(where: { $0.kind == .volume && abs($0.level - 0.73) < 0.001 && $0.link == .wifi }) &&
            delegateA.receivedControlLevels.contains(where: { $0.kind == .brightness && abs($0.level - 0.68) < 0.001 && $0.link == .wifi }) &&
            delegateA.receivedSeeks.contains(where: { abs($0.seconds - 120.0) < 0.01 && $0.link == .wifi })
        }
        XCTAssertTrue(stateChanges.isEmpty)
    }
}
