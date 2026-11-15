import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class ClipboardSeekCompactKeysDictationTests: XCTestCase {

    // MARK: - 1. Clipboard History Ring (Max 5, Drops Empties, Newest First, Legacy Payload Compatibility)

    func testClipboardHistoryRingKeepsAtMostFiveDropsEmptiesAndOrdersNewestFirst() throws {
        var ring = ClipboardHistoryRing()
        XCTAssertTrue(ring.entries.isEmpty)

        // Drops nil, empty, whitespace-only, and .empty snapshots
        ring.record(.empty)
        ring.record(text: nil)
        ring.record(text: "")
        ring.record(text: "   \n\t  ")
        XCTAssertTrue(ring.entries.isEmpty)

        // Records non-empty snapshots newest first and caps strictly at 5
        for index in 1...6 {
            ring.record(text: "Entry \(index)")
            ring.record(text: "  ")
        }
        XCTAssertEqual(ring.entries.count, 5)
        XCTAssertEqual(
            ring.entries.map(\.text),
            ["Entry 6", "Entry 5", "Entry 4", "Entry 3", "Entry 2"]
        )

        // Re-copying an existing entry moves it to index 0 without duplicating
        ring.record(text: "Entry 3")
        XCTAssertEqual(
            ring.entries.map(\.text),
            ["Entry 3", "Entry 6", "Entry 5", "Entry 4", "Entry 2"]
        )

        // Subsequent empty/image snapshot preserves the last 5 text entries
        ring.record(.empty)
        XCTAssertEqual(ring.entries.count, 5)
        XCTAssertEqual(ring.entries.first?.text, "Entry 3")

        // Snapshot wire round-trip + legacy payload compatibility (without recentEntries field)
        let snapshot = ClipboardPreviewSnapshot(previewText: "Entry 3").withRecentEntries(ring.entries)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ClipboardPreviewSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.recentEntries.map(\.text), ["Entry 3", "Entry 6", "Entry 5", "Entry 4", "Entry 2"])

        let legacyPayload = Data(#"{"previewText":"Legacy Only","isTruncated":false}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ClipboardPreviewSnapshot.self, from: legacyPayload)
        XCTAssertEqual(decodedLegacy.previewText, "Legacy Only")
        XCTAssertTrue(decodedLegacy.recentEntries.isEmpty)
        XCTAssertEqual(decodedLegacy.effectiveRecentEntries.map(\.text), ["Legacy Only"])
    }

    // MARK: - 2. Compact Keys Raw-Value & Wire Round-Trip (tab, return, delete)

    func testNewCompactKeysRoundTripRawValuesAndLabels() throws {
        XCTAssertEqual(CompanionCompactKey.tab.rawValue, "tab")
        XCTAssertEqual(CompanionCompactKey.returnKey.rawValue, "return")
        XCTAssertEqual(CompanionCompactKey.delete.rawValue, "delete")

        for (raw, expected) in [
            ("tab", CompanionCompactKey.tab),
            ("return", CompanionCompactKey.returnKey),
            ("delete", CompanionCompactKey.delete)
        ] {
            let parsed = try XCTUnwrap(CompanionCompactKey(rawValue: raw))
            XCTAssertEqual(parsed, expected)

            let json = try JSONEncoder().encode(parsed)
            XCTAssertEqual(String(data: json, encoding: .utf8), "\"\(raw)\"")
            XCTAssertEqual(try JSONDecoder().decode(CompanionCompactKey.self, from: json), expected)

            let framed = try WireFrameCodec.encode(ClientMessage.sendCompactKey(expected))
            let decodedMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: Data(framed.dropFirst(4)))
            XCTAssertEqual(decodedMsg, .sendCompactKey(expected))

            XCTAssertFalse(expected.title(in: .english).isEmpty)
            XCTAssertFalse(expected.title(in: .chinese).isEmpty)
            XCTAssertFalse(expected.capLabel(in: .english).isEmpty)
            XCTAssertFalse(expected.capLabel(in: .chinese).isEmpty)
            XCTAssertFalse(expected.sfSymbol.isEmpty)
            XCTAssertFalse(expected.isArrowKey)
        }

        XCTAssertTrue(CompanionCompactKey.compactRowOrder.contains(.tab))
        XCTAssertTrue(CompanionCompactKey.compactRowOrder.contains(.returnKey))
        XCTAssertTrue(CompanionCompactKey.compactRowOrder.contains(.delete))
    }

    // MARK: - 3. Relative Seek Delta (+15s / -15s Pure Math & Clear Unknown-Position Failure)

    func testRelativeSeekDeltaCalculationsAndUnknownPositionFailure() {
        // Given position 40 and duration 100, +15 -> 55
        XCTAssertEqual(
            MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: 40,
                durationSeconds: 100,
                deltaSeconds: 15
            ),
            .success(55)
        )

        // Given position 10 and duration 100, -15 -> 0
        XCTAssertEqual(
            MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: 10,
                durationSeconds: 100,
                deltaSeconds: -15
            ),
            .success(0)
        )

        // Upper clamp at duration
        XCTAssertEqual(
            MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: 92,
                durationSeconds: 100,
                deltaSeconds: 15
            ),
            .success(100)
        )

        // Unknown position fails clearly
        XCTAssertEqual(
            MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: nil,
                durationSeconds: 100,
                deltaSeconds: 15
            ),
            .failure(.missingPosition)
        )
        XCTAssertFalse(NowPlayingRelativeSeekFailure.missingPosition.message(in: .english).isEmpty)
        XCTAssertFalse(NowPlayingRelativeSeekFailure.missingPosition.message(in: .chinese).isEmpty)

        // Unknown duration fails clearly
        XCTAssertEqual(
            MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: 40,
                durationSeconds: nil,
                deltaSeconds: 15
            ),
            .failure(.missingDuration)
        )
    }

    // MARK: - 4. Dictation Is One-Tap While Lock Screen Stays Two-Tap

    func testToggleDictationIsOneTapAndLockScreenStaysTwoTap() {
        XCTAssertEqual(SystemQuickAction.toggleDictation.rawValue, "toggle_dictation")
        XCTAssertEqual(SystemQuickAction(rawValue: "toggle_dictation"), .toggleDictation)
        XCTAssertFalse(SystemQuickAction.toggleDictation.requiresDestructiveConfirmation)
        XCTAssertTrue(SystemQuickAction.lockScreen.requiresDestructiveConfirmation)

        var gate = DestructiveActionConfirmGate()
        let dictationTap = gate.registerTap(
            targetID: SystemQuickAction.toggleDictation.rawValue,
            isDestructive: SystemQuickAction.toggleDictation.requiresDestructiveConfirmation,
            at: 100.0
        )
        XCTAssertEqual(dictationTap, .runImmediately)

        let lockFirstTap = gate.registerTap(
            targetID: SystemQuickAction.lockScreen.rawValue,
            isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
            at: 101.0
        )
        XCTAssertEqual(lockFirstTap, .requireSecondTap(expiresAt: 104.0))

        let lockSecondTap = gate.registerTap(
            targetID: SystemQuickAction.lockScreen.rawValue,
            isDestructive: SystemQuickAction.lockScreen.requiresDestructiveConfirmation,
            at: 102.0
        )
        XCTAssertEqual(lockSecondTap, .confirmedRun)

        var pillConfirm = Round09LockScreenConfirmController()
        XCTAssertEqual(pillConfirm.registerTap(at: 200.0), .requireSecondTap(expiresAt: 203.0))
        XCTAssertEqual(pillConfirm.registerTap(at: 201.0), .confirmedExecute)
    }

    // MARK: - 5. End-to-End Companion Wire Verification (Clipboard History Paste, 15s Seek, Compact Keys, Dictation)

    #if os(macOS)
    func testCompanionWireClipboardHistoryPasteRelativeSeekCompactKeysAndDictation() async throws {
        let suiteName = "com.choclift.tests.xinput.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = XInputMockServerDelegate()
        let server = MacServerEngine(macID: "mac-xinput-host", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        let (serverEnd, clientEnd) = InMemoryCompanionPipe.pair()
        server.acceptCompanionTransport(serverEnd, link: .bluetooth)

        let client = CompanionClientEngine(
            deviceID: "iphone-xinput",
            deviceName: "iPhone XInput",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "xinput"
        )
        defer { client.disconnect() }

        client.connectInMemoryBluetooth(to: clientEnd, targetName: "Studio Mac")
        for _ in 0..<60 {
            if case .awaitingPIN = client.connectionState { break }
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        client.submitPIN(server.currentPIN)
        for _ in 0..<60 where !client.connectionState.isConnected {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(client.connectionState.isConnected)

        // 1. Broadcast 5 clipboard history entries; tapping one pastes via focusedFieldInsert
        var ring = ClipboardHistoryRing()
        for idx in 1...6 {
            ring.record(text: "Clip \(idx)")
        }
        let preview = ClipboardPreviewSnapshot(previewText: "Clip 6").withRecentEntries(ring.entries)
        server.broadcastClipboardPreview(preview)
        for _ in 0..<60 where client.clipboardPreview.recentEntries.count != 5 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(
            client.clipboardPreview.recentEntries.map(\.text),
            ["Clip 6", "Clip 5", "Clip 4", "Clip 3", "Clip 2"]
        )
        XCTAssertTrue(client.pasteClipboardHistoryEntry("Clip 4"))
        for _ in 0..<60 where delegate.insertedSnippets.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.insertedSnippets, ["Clip 4"])
        XCTAssertTrue(client.recentlyTriggeredTiles.isEmpty)

        // 2. Relative seek: unknown position fails clearly without sending seekNowPlaying
        server.broadcastControlStripState(
            ControlStripState(
                nowPlaying: NowPlayingStatus(
                    title: "Track",
                    appName: "Music",
                    isPlaying: true,
                    elapsedSeconds: nil,
                    durationSeconds: 100,
                    bundleIdentifier: "com.apple.Music"
                )
            )
        )
        for _ in 0..<60 where client.controlStripState.nowPlaying == nil {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertNil(client.seekNowPlayingForward15())
        XCTAssertEqual(client.lastFeedback?.success, false)
        XCTAssertTrue(delegate.seekPositions.isEmpty)

        // Known position 40 / duration 100 -> +15 = 55; then from 10 -> -15 = 0
        server.broadcastControlStripState(
            ControlStripState(
                nowPlaying: NowPlayingStatus(
                    title: "Track",
                    appName: "Music",
                    isPlaying: true,
                    elapsedSeconds: 40,
                    durationSeconds: 100,
                    bundleIdentifier: "com.apple.Music"
                )
            )
        )
        for _ in 0..<60 where client.controlStripState.nowPlaying?.elapsedSeconds != 40 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(client.seekNowPlayingForward15(), 55)
        for _ in 0..<60 where delegate.seekPositions.count < 1 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.seekPositions, [55])

        server.broadcastControlStripState(
            ControlStripState(
                nowPlaying: NowPlayingStatus(
                    title: "Track",
                    appName: "Music",
                    isPlaying: true,
                    elapsedSeconds: 10,
                    durationSeconds: 100,
                    bundleIdentifier: "com.apple.Music"
                )
            )
        )
        for _ in 0..<60 where client.controlStripState.nowPlaying?.elapsedSeconds != 10 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(client.seekNowPlayingBackward15(), 0)
        for _ in 0..<60 where delegate.seekPositions.count < 2 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.seekPositions, [55, 0])

        // 3. New compact keys + one-tap toggleDictation reach Mac server
        for key in [CompanionCompactKey.tab, .returnKey, .delete] {
            client.sendCompactKey(key)
        }
        client.performQuickAction(.toggleDictation)
        for _ in 0..<60 where delegate.receivedCompactKeys.count < 3 || delegate.receivedQuickActions.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.receivedCompactKeys, [.tab, .returnKey, .delete])
        XCTAssertEqual(delegate.receivedQuickActions, [.toggleDictation])
    }
    #endif
}

#if os(macOS)
@MainActor
private final class XInputMockServerDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var insertedSnippets: [String] = []
    var seekPositions: [Double] = []
    var receivedCompactKeys: [CompanionCompactKey] = []
    var receivedQuickActions: [SystemQuickAction] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (true, "Notes") }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}
    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .insertSnippet(let text, _):
            insertedSnippets.append(text)
        case .seekNowPlaying(let positionSeconds):
            seekPositions.append(positionSeconds)
        case .sendCompactKey(let key):
            receivedCompactKeys.append(key)
        case .performQuickAction(let action):
            receivedQuickActions.append(action)
        default:
            break
        }
    }
}
#endif
