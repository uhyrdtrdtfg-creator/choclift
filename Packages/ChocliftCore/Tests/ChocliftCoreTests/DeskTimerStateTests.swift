import Foundation
import XCTest
@testable import ChocliftCore

final class DeskTimerStateTests: XCTestCase {
    func testPresetsAndMissingJSONDecodeToIdleTwentyFiveMinutes() throws {
        XCTAssertEqual(DeskTimerState.presetMinutes, [5, 10, 15, 25, 45])
        XCTAssertEqual(DeskTimerState.idle.phase, .idle)
        XCTAssertEqual(DeskTimerState.idle.presetSeconds, 25 * 60)
        XCTAssertNil(DeskTimerState.idle.endsAt)

        let decodedEmpty = try JSONDecoder().decode(DeskTimerState.self, from: Data("{}".utf8))
        XCTAssertEqual(decodedEmpty, .idle)
        XCTAssertEqual(decodedEmpty.phase, .idle)
        XCTAssertEqual(decodedEmpty.presetSeconds, 25 * 60)
        XCTAssertEqual(decodedEmpty.remaining(at: Date(timeIntervalSince1970: 1_700_000_000)), 25 * 60)
    }

    func testControlStripStateEncodesDeskTimerAndDecodesLegacyJSONDefaultingToIdle() throws {
        let baseNow = Date(timeIntervalSince1970: 1_700_000_000)
        let running = DeskTimerState.started(preset: 15 * 60, now: baseNow)
        let strip = ControlStripState(deskTimer: running)

        let encoded = try JSONEncoder().encode(strip)
        var rawObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(rawObject["deskTimer"])

        let roundTripped = try JSONDecoder().decode(ControlStripState.self, from: encoded)
        XCTAssertEqual(roundTripped.deskTimer, running)
        XCTAssertTrue(roundTripped.hasMeaningfulDifference(from: ControlStripState()))

        rawObject.removeValue(forKey: "deskTimer")
        let legacyData = try JSONSerialization.data(withJSONObject: rawObject)
        let decodedLegacy = try JSONDecoder().decode(ControlStripState.self, from: legacyData)
        XCTAssertEqual(decodedLegacy.deskTimer, .idle)
    }

    func testRemainingAtAcrossIdleRunningAndPausedPhases() {
        let t0 = Date(timeIntervalSinceReferenceDate: 816_445_435.37)

        let idleDefault = DeskTimerState.idle
        XCTAssertEqual(idleDefault.remaining(at: t0), 1500)
        XCTAssertEqual(idleDefault.formattedRemaining(at: t0), "25:00")

        let idleZero = DeskTimerState(phase: .idle, presetSeconds: 0, remainingSeconds: 0, endsAt: nil)
        XCTAssertEqual(idleZero.remaining(at: t0), 0)
        XCTAssertEqual(idleZero.formattedRemaining(at: t0), "00:00")

        let running = DeskTimerState.started(preset: 300, now: t0)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.remaining(at: t0), 300)
        XCTAssertEqual(running.formattedRemaining(at: t0), "05:00")
        XCTAssertEqual(running.remaining(at: t0.addingTimeInterval(61)), 239)
        XCTAssertEqual(running.formattedRemaining(at: t0.addingTimeInterval(61)), "03:59")
        XCTAssertEqual(running.remaining(at: t0.addingTimeInterval(299.4)), 1)
        XCTAssertEqual(running.formattedRemaining(at: t0.addingTimeInterval(299.4)), "00:01")
        XCTAssertEqual(running.remaining(at: t0.addingTimeInterval(300)), 0)
        XCTAssertEqual(running.remaining(at: t0.addingTimeInterval(325)), 0)
    }

    func testPauseResumeAndResetPureTransitions() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let started = DeskTimerState.started(preset: 600, now: t0)
        XCTAssertEqual(started.phase, .running)
        XCTAssertEqual(started.presetSeconds, 600)
        XCTAssertEqual(started.endsAt, t0.addingTimeInterval(600))

        let paused = started.paused(at: t0.addingTimeInterval(135))
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.presetSeconds, 600)
        XCTAssertEqual(paused.remainingSeconds, 465)
        XCTAssertNil(paused.endsAt)
        XCTAssertEqual(paused.remaining(at: t0.addingTimeInterval(9_999)), 465)
        XCTAssertEqual(paused.formattedRemaining(at: t0.addingTimeInterval(9_999)), "07:45")

        let resumeTime = t0.addingTimeInterval(1_000)
        let resumed = paused.resumed(at: resumeTime)
        XCTAssertEqual(resumed.phase, .running)
        XCTAssertEqual(resumed.presetSeconds, 600)
        XCTAssertEqual(resumed.remainingSeconds, 465)
        XCTAssertEqual(resumed.endsAt, resumeTime.addingTimeInterval(465))
        XCTAssertEqual(resumed.remaining(at: resumeTime.addingTimeInterval(65)), 400)

        let resetState = resumed.reset()
        XCTAssertEqual(resetState.phase, .idle)
        XCTAssertEqual(resetState.presetSeconds, 600)
        XCTAssertEqual(resetState.remainingSeconds, 600)
        XCTAssertNil(resetState.endsAt)

        let expiredPause = started.paused(at: t0.addingTimeInterval(605))
        XCTAssertEqual(expiredPause.phase, .idle)
        XCTAssertNil(expiredPause.endsAt)
    }

    func testClientMessagesWireCodecAndServerAuthenticationGate() async throws {
        let messages: [ClientMessage] = [
            .startDeskTimer(presetSeconds: 300),
            .pauseDeskTimer,
            .resumeDeskTimer,
            .resetDeskTimer
        ]

        var combined = Data()
        for msg in messages {
            combined.append(try WireFrameCodec.encode(msg))
        }
        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(combined)
        let decoded = try payloads.map { try WireFrameCodec.decodePayload(ClientMessage.self, from: $0) }
        XCTAssertEqual(decoded, messages)

        #if os(macOS)
        await assertServerAuthAndAuthenticatedDelivery(messages: messages)
        #endif
    }

    #if os(macOS)
    @MainActor
    private func assertServerAuthAndAuthenticatedDelivery(messages: [ClientMessage]) async {
        let delegate = DeskTimerWireTestDelegate()
        let server = MacServerEngine(macID: "mac-timer", macName: "Timer Mac")
        server.delegate = delegate
        defer { server.stop() }

        // 1. Unauthenticated frame must NOT pass through to delegate
        let unauthClientEnd = server.acceptInMemoryCompanion()
        var unauthReplies: [ServerMessage] = []
        var unauthAcc = WireStreamAccumulator()
        unauthClientEnd.onPayload = { chunk in
            if let frames = try? unauthAcc.appendAndExtractPayloads(chunk) {
                for frame in frames {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: frame) {
                        unauthReplies.append(msg)
                    }
                }
            }
        }
        unauthClientEnd.start()
        if let rawStart = try? WireFrameCodec.encode(ClientMessage.startDeskTimer(presetSeconds: 300)) {
            unauthClientEnd.send(rawStart)
        }
        for _ in 0..<40 where unauthReplies.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(delegate.receivedMessages.isEmpty)
        XCTAssertEqual(unauthReplies, [.pairingRequired(macID: "mac-timer", macName: "Timer Mac")])
        unauthClientEnd.cancel()

        // 2. Authenticated companion delivers all desk timer commands and receives ControlStripState sync
        let suiteName = "com.choclift.tests.desk-timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let phone = CompanionClientEngine(
            deviceID: "iphone-timer",
            deviceName: "iPhone Timer",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "timer"
        )
        defer { phone.disconnect() }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Timer Mac", macID: "mac-timer")
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

        phone.startDeskTimer(presetSeconds: 300)
        phone.pauseDeskTimer()
        phone.resumeDeskTimer()
        phone.resetDeskTimer()

        for _ in 0..<60 where delegate.receivedMessages.count < 4 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.receivedMessages, messages)

        let syncedRunning = DeskTimerState.started(
            preset: 900,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        server.broadcastControlStripState(ControlStripState(deskTimer: syncedRunning))
        for _ in 0..<60 where phone.controlStripState.deskTimer != syncedRunning {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(phone.controlStripState.deskTimer, syncedRunning)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class DeskTimerWireTestDelegate: MacServerEngineDelegate {
    var receivedMessages: [ClientMessage] = []

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
        switch message {
        case .startDeskTimer, .pauseDeskTimer, .resumeDeskTimer, .resetDeskTimer:
            receivedMessages.append(message)
        default:
            break
        }
    }
}
#endif
