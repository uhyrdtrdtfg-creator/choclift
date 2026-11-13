import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class ControlStripTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    // MARK: - 1. Pure Level Clamp & Percentage Tests

    func testLevelClampAndPercentage() {
        XCTAssertEqual(ControlStripLevel.clamp(-0.45), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(-.infinity), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(0.375), 0.375, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(1.85), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(.infinity), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ControlStripLevel.clamp(.nan), 0.0, accuracy: 1e-9)

        XCTAssertEqual(ControlStripLevel.percentage(for: -0.2), 0)
        XCTAssertEqual(ControlStripLevel.percentage(for: 0.0), 0)
        XCTAssertEqual(ControlStripLevel.percentage(for: 0.256), 26)
        XCTAssertEqual(ControlStripLevel.percentage(for: 0.734), 73)
        XCTAssertEqual(ControlStripLevel.percentage(for: 1.4), 100)
    }

    // MARK: - 2. Pure 150ms Drag Throttle Tests

    func testDragThrottleEnforces150msIntervalAndAlwaysFlushesOnDragEnd() {
        var throttle = ControlLevelDragThrottle()
        XCTAssertEqual(throttle.minimumInterval, 0.15, accuracy: 1e-9)

        // Initial drag touch sends immediately
        let initial = throttle.updateDrag(to: 0.12, at: 10.00)
        XCTAssertNotNil(initial)
        XCTAssertEqual(initial ?? -1, 0.12, accuracy: 1e-9)

        // Updates inside the 150ms window are suppressed to avoid flooding BLE
        XCTAssertNil(throttle.updateDrag(to: 0.22, at: 10.05))
        XCTAssertNil(throttle.updateDrag(to: 0.31, at: 10.149))

        // Exact 150ms step increments (including IEEE-754 0.60 - 0.45 boundary) emit cleanly
        let at150 = throttle.updateDrag(to: 0.40, at: 10.15)
        XCTAssertNotNil(at150)
        XCTAssertEqual(at150 ?? -1, 0.40, accuracy: 1e-9)

        XCTAssertNil(throttle.updateDrag(to: 0.48, at: 10.29))

        let at300 = throttle.updateDrag(to: 0.55, at: 10.30)
        XCTAssertNotNil(at300)
        XCTAssertEqual(at300 ?? -1, 0.55, accuracy: 1e-9)

        let at450 = throttle.updateDrag(to: 0.70, at: 10.45)
        XCTAssertNotNil(at450)
        XCTAssertEqual(at450 ?? -1, 0.70, accuracy: 1e-9)

        let at600 = throttle.updateDrag(to: 0.82, at: 10.60)
        XCTAssertNotNil(at600)
        XCTAssertEqual(at600 ?? -1, 0.82, accuracy: 1e-9)

        // Ending the drag only 40ms later MUST still send the final resting level
        let committed = throttle.endDrag(at: 0.91, at: 10.64)
        XCTAssertEqual(committed, 0.91, accuracy: 1e-9)

        // Back-to-back drag 20ms after endDrag still respects the 150ms BLE cooldown during drag,
        // then emits once 150ms has elapsed since the 10.64 send, and clamps > 1.0 to 1.0
        XCTAssertNil(throttle.updateDrag(to: 1.4, at: 10.66))
        let nextWindowSend = throttle.updateDrag(to: 1.4, at: 10.79)
        XCTAssertNotNil(nextWindowSend)
        XCTAssertEqual(nextWindowSend ?? -1, 1.0, accuracy: 1e-9)

        let clampedNegativeEnd = throttle.endDrag(at: -0.3, at: 10.82)
        XCTAssertEqual(clampedNegativeEnd, 0.0, accuracy: 1e-9)
    }

    // MARK: - 3. Now Playing & Diff Helpers

    func testNowPlayingDisplayAndStateDifferenceHelpers() {
        let titled = NowPlayingStatus(title: "  Veridis Quo ", artist: "Daft Punk", appName: "Music", isPlaying: true)
        XCTAssertEqual(titled.primaryDisplayText, "Veridis Quo")
        XCTAssertEqual(titled.secondaryDisplayText, "Daft Punk")
        XCTAssertTrue(titled.hasActiveMedia)

        let appOnly = NowPlayingStatus(title: "   ", artist: nil, appName: "Spotify", isPlaying: false)
        XCTAssertEqual(appOnly.primaryDisplayText, "Spotify")
        XCTAssertNil(appOnly.secondaryDisplayText)
        XCTAssertTrue(appOnly.hasActiveMedia)

        let empty = NowPlayingStatus(title: "", artist: "", appName: "  ", isPlaying: false)
        XCTAssertNil(empty.primaryDisplayText)
        XCTAssertFalse(empty.hasActiveMedia)

        let base = ControlStripState(
            volume: 0.50,
            isVolumeMuted: false,
            brightness: 0.75,
            isBrightnessAvailable: true,
            isMicMuted: false,
            nowPlaying: nil
        )
        var jitter = base
        jitter.volume = 0.502
        jitter.brightness = 0.748
        XCTAssertFalse(base.hasMeaningfulDifference(from: jitter))

        var muted = base
        muted.isMicMuted = true
        XCTAssertTrue(base.hasMeaningfulDifference(from: muted))
    }

    // MARK: - 4. Wire Codec Compatibility & Tolerant Decode Fallback

    func testWireProtocolControlStripRoundTripAndUnknownMessageFallback() throws {
        let setVolFrame = try WireFrameCodec.encode(ClientMessage.setControlLevel(kind: .volume, level: 0.64))
        var stream = WireStreamAccumulator()
        let decodedClientPayloads = try stream.appendAndExtractPayloads(setVolFrame)
        XCTAssertEqual(decodedClientPayloads.count, 1)
        let decodedSetVol = try WireFrameCodec.decodePayload(ClientMessage.self, from: decodedClientPayloads[0])
        if case .setControlLevel(let kind, let level) = decodedSetVol {
            XCTAssertEqual(kind, .volume)
            XCTAssertEqual(level, 0.64, accuracy: 1e-9)
        } else {
            XCTFail("Expected .setControlLevel, got \(decodedSetVol)")
        }

        let sampleState = ControlStripState(
            volume: 0.42,
            isVolumeMuted: true,
            brightness: 0.88,
            isBrightnessAvailable: true,
            isMicMuted: true,
            nowPlaying: NowPlayingStatus(title: "Midnight City", artist: "M83", appName: "Music", isPlaying: true)
        )
        let stateFrame = try WireFrameCodec.encode(ServerMessage.controlStripStateUpdated(sampleState))
        let statePayloads = try stream.appendAndExtractPayloads(stateFrame)
        let decodedServerMsg = try WireFrameCodec.decodePayload(ServerMessage.self, from: statePayloads[0])
        if case .controlStripStateUpdated(let roundTripped) = decodedServerMsg {
            XCTAssertEqual(roundTripped, sampleState)
        } else {
            XCTFail("Expected .controlStripStateUpdated, got \(decodedServerMsg)")
        }

        // Unknown ClientMessage case from another protocol v2 slice must decode to .unknownClientMessage
        let unknownClientJSON = Data(#"{"futureParallelSliceCommand":{"enabled":true}}"#.utf8)
        let decodedUnknownClient = try WireFrameCodec.decodePayload(ClientMessage.self, from: unknownClientJSON)
        if case .unknownClientMessage = decodedUnknownClient {
            // Expected tolerant fallback
        } else {
            XCTFail("Expected .unknownClientMessage fallback, got \(decodedUnknownClient)")
        }

        // Unknown ServerMessage case from another protocol v2 slice must decode to .unknownServerMessage
        let unknownServerJSON = Data(#"{"futureParallelSliceBroadcast":{"items":[1,2,3]}}"#.utf8)
        let decodedUnknownServer = try WireFrameCodec.decodePayload(ServerMessage.self, from: unknownServerJSON)
        if case .unknownServerMessage = decodedUnknownServer {
            // Expected tolerant fallback
        } else {
            XCTFail("Expected .unknownServerMessage fallback, got \(decodedUnknownServer)")
        }

        // Corrupt non-JSON data must still throw invalidPayload
        XCTAssertThrowsError(try WireFrameCodec.decodePayload(ServerMessage.self, from: Data([0xFF, 0x00, 0x13])))
    }

    // MARK: - 5. End-to-End Control Strip Sync, Gating & Unknown Frame Resilience

    func testControlStripSyncGatingAndUnknownFrameResilienceOverBluetoothPipe() async throws {
        let suiteName = "com.choclift.controlstrip.tests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let delegate = ControlStripMockServerDelegate()
        delegate.controlState = ControlStripState(
            volume: 0.58,
            isVolumeMuted: false,
            brightness: 0.81,
            isBrightnessAvailable: true,
            isMicMuted: false,
            nowPlaying: NowPlayingStatus(title: " Sunrise ", artist: "Norah Jones", appName: "Music", isPlaying: true)
        )

        let server = MacServerEngine(macID: "mac-strip-host", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        // Connect modern CompanionClientEngine over in-memory Bluetooth pipe
        let (modernServerEnd, modernClientEnd) = InMemoryCompanionPipe.pair()
        server.acceptCompanionTransport(modernServerEnd, link: .bluetooth)

        let modernClient = CompanionClientEngine(
            deviceID: "iphone-modern-strip",
            deviceName: "iPhone Control Strip",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "modern"
        )
        defer { modernClient.disconnect() }

        modernClient.connectInMemoryBluetooth(to: modernClientEnd, targetName: "Studio Mac")
        try await waitUntil("modern awaiting PIN") {
            if case .awaitingPIN = modernClient.connectionState { return true }
            return false
        }
        modernClient.submitPIN(server.currentPIN)

        // Verify modern client connects AND automatically pulls initial ControlStripState
        try await waitUntil("modern client synced initial controlStripState") {
            modernClient.connectionState.isConnected &&
            abs(modernClient.controlStripState.volume - 0.58) < 0.001 &&
            modernClient.controlStripState.nowPlaying?.primaryDisplayText == "Sunrise"
        }
        XCTAssertEqual(modernClient.controlStripState.brightness, 0.81, accuracy: 0.001)

        // Connect a simulated legacy v2 client that never requests or sends control-strip messages
        let (legacyServerEnd, legacyClientEnd) = InMemoryCompanionPipe.pair()
        var legacyServerFrames: [Data] = []
        var legacyAccumulator = WireStreamAccumulator()
        legacyClientEnd.onPayload = { chunk in
            if let frames = try? legacyAccumulator.appendAndExtractPayloads(chunk) {
                legacyServerFrames.append(contentsOf: frames)
            }
        }
        server.acceptCompanionTransport(legacyServerEnd, link: .bluetooth)
        legacyClientEnd.start()

        let helloFrame = try WireFrameCodec.encode(
            ClientMessage.hello(
                protocolVersion: ChocliftDefaults.protocolVersion,
                deviceID: "legacy-v2-watch",
                deviceName: "Legacy Watch",
                platform: .appleWatch,
                savedAuthToken: nil
            )
        )
        legacyClientEnd.send(helloFrame)

        try await waitUntil("legacy client challenged for PIN") { !legacyServerFrames.isEmpty }
        legacyServerFrames.removeAll()

        let pinFrame = try WireFrameCodec.encode(
            ClientMessage.submitPIN(
                pin: server.currentPIN,
                deviceID: "legacy-v2-watch",
                deviceName: "Legacy Watch",
                platform: .appleWatch
            )
        )
        legacyClientEnd.send(pinFrame)

        try await waitUntil("legacy client authenticated") {
            legacyServerFrames.contains { (payload: Data) in
                if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: payload),
                   case .authSucceeded = msg {
                    return true
                }
                return false
            }
        }
        legacyServerFrames.removeAll()

        // Modern client sets volume, brightness, mic mute, and triggers volumeMute quick action
        modernClient.setControlLevel(kind: .volume, level: 0.34)
        modernClient.setControlLevel(kind: .brightness, level: 0.72)
        modernClient.toggleMicMute()
        modernClient.performQuickAction(.volumeMute)

        try await waitUntil("server received level, mic mute, and volumeMute commands") {
            delegate.receivedLevels.count == 2 &&
            delegate.receivedMicMuteChanges == [true] &&
            delegate.receivedQuickActions == [.volumeMute]
        }
        XCTAssertEqual(delegate.receivedLevels[0].0, .volume)
        XCTAssertEqual(delegate.receivedLevels[0].1, 0.34, accuracy: 1e-6)
        XCTAssertEqual(delegate.receivedLevels[1].0, .brightness)
        XCTAssertEqual(delegate.receivedLevels[1].1, 0.72, accuracy: 1e-6)

        // Server broadcasts updated control strip state: modern client receives it, legacy client does NOT
        let pushedState = ControlStripState(
            volume: 0.25,
            isVolumeMuted: true,
            brightness: 0.65,
            isBrightnessAvailable: true,
            isMicMuted: true,
            nowPlaying: nil
        )
        server.broadcastControlStripState(pushedState)

        try await waitUntil("modern client received broadcast controlStripState") {
            modernClient.controlStripState.isVolumeMuted == true &&
            abs(modernClient.controlStripState.volume - 0.25) < 0.001 &&
            modernClient.controlStripState.nowPlaying == nil
        }

        // Give any stray frame time to arrive on legacy pipe, then verify zero controlStripStateUpdated frames arrived
        try await Task.sleep(for: .milliseconds(50))
        let legacyReceivedControlStrip = legacyServerFrames.contains { (payload: Data) in
            let text = String(data: payload, encoding: .utf8) ?? ""
            return text.contains("controlStripStateUpdated")
        }
        XCTAssertFalse(legacyReceivedControlStrip, "Legacy client must never receive gated controlStripStateUpdated frames")

        // Verify server tolerates an unknown v2 ClientMessage without disconnecting the client
        let rawUnknownClientPayload = Data(#"{"unrecognizedFutureClientAction":{"value":99}}"#.utf8)
        legacyClientEnd.send(Self.wrapRawFrame(rawUnknownClientPayload))
        legacyClientEnd.send(try WireFrameCodec.encode(ClientMessage.ping(timestamp: 123.0)))

        try await waitUntil("legacy client remains connected and receives pong after unknown ClientMessage") {
            legacyServerFrames.contains { (payload: Data) in
                if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: payload),
                   case .pong = msg {
                    return true
                }
                return false
            }
        }

        // Verify CompanionClientEngine ignores an unknown ServerMessage frame without dropping connection
        let rawUnknownServerPayload = Data(#"{"unrecognizedFutureServerEvent":{"status":"ok"}}"#.utf8)
        modernServerEnd.send(Self.wrapRawFrame(rawUnknownServerPayload))

        let postUnknownState = ControlStripState(
            volume: 0.90,
            isVolumeMuted: false,
            brightness: 0.65,
            isBrightnessAvailable: true,
            isMicMuted: false,
            nowPlaying: NowPlayingStatus(title: "Digital Love", artist: "Daft Punk", appName: "Music", isPlaying: true)
        )
        server.broadcastControlStripState(postUnknownState)

        try await waitUntil("modern client stays connected after unknown ServerMessage and receives next state") {
            modernClient.connectionState.isConnected &&
            abs(modernClient.controlStripState.volume - 0.90) < 0.001 &&
            modernClient.controlStripState.nowPlaying?.primaryDisplayText == "Digital Love"
        }
    }

    private nonisolated static func wrapRawFrame(_ payload: Data) -> Data {
        var bigEndianLength = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &bigEndianLength, count: 4)
        frame.append(payload)
        return frame
    }

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

@MainActor
private final class ControlStripMockServerDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var controlState = ControlStripState()
    var receivedLevels: [(ControlLevelKind, Double)] = []
    var receivedMicMuteChanges: [Bool] = []
    var receivedQuickActions: [SystemQuickAction] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
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
            reply(.controlStripStateUpdated(controlState))
        case .setControlLevel(let kind, let level):
            receivedLevels.append((kind, level))
            switch kind {
            case .volume:
                controlState.volume = ControlStripLevel.clamp(level)
            case .brightness:
                controlState.brightness = ControlStripLevel.clamp(level)
            }
        case .setMicMuted(let muted):
            receivedMicMuteChanges.append(muted)
            controlState.isMicMuted = muted
            reply(.controlStripStateUpdated(controlState))
        case .performQuickAction(let action):
            receivedQuickActions.append(action)
            reply(.actionFeedback(success: true, title: action.rawValue, detail: nil))
        default:
            break
        }
    }
}
