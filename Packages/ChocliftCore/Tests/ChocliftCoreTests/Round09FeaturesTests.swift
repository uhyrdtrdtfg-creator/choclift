import Foundation
import XCTest
@testable import ChocliftCore

final class Round09FeaturesTests: XCTestCase {

    // MARK: - 1. Pinned Clipboard Cap at 8 & Deduplication / Unpin

    func testPinnedClipboardItemsEnforceEightItemCapDeduplicationAndUnpin() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertTrue(profile.activePinnedClipboardItems.isEmpty)
        XCTAssertTrue(profile.canPinMoreClipboardItems)

        // Pin items 1 through 8 from Mac clipboard previews
        for index in 1...8 {
            let preview = ClipboardPreviewEvaluator.evaluate(
                pasteboardTypes: ["public.utf8-plain-text"],
                string: "Pinned item #\(index)"
            )
            XCTAssertTrue(profile.pinClipboardPreview(preview), "Expected item #\(index) to pin")
        }

        XCTAssertEqual(profile.activePinnedClipboardItems.count, 8)
        XCTAssertFalse(profile.canPinMoreClipboardItems)

        // Re-pinning an already-pinned item is idempotent and keeps count at 8
        let duplicatePreview = ClipboardPreviewEvaluator.evaluate(
            pasteboardTypes: ["public.utf8-plain-text"],
            string: "Pinned item #3"
        )
        XCTAssertTrue(profile.pinClipboardPreview(duplicatePreview))
        XCTAssertEqual(profile.activePinnedClipboardItems.count, 8)

        // 9th distinct item MUST be rejected at the 8-item cap
        let ninthPreview = ClipboardPreviewEvaluator.evaluate(
            pasteboardTypes: ["public.utf8-plain-text"],
            string: "Pinned item #9 (over cap)"
        )
        XCTAssertFalse(profile.pinClipboardPreview(ninthPreview), "9th distinct pin must be rejected")
        XCTAssertEqual(profile.activePinnedClipboardItems.count, 8)
        XCTAssertFalse(profile.isClipboardTextPinned("Pinned item #9 (over cap)"))

        // Unpinning one item frees a slot so the 9th item can now be pinned
        let removedID = profile.activePinnedClipboardItems[0].id
        XCTAssertTrue(profile.unpinClipboardItem(id: removedID))
        XCTAssertEqual(profile.activePinnedClipboardItems.count, 7)
        XCTAssertTrue(profile.canPinMoreClipboardItems)

        XCTAssertTrue(profile.pinClipboardPreview(ninthPreview))
        XCTAssertEqual(profile.activePinnedClipboardItems.count, 8)
        XCTAssertTrue(profile.isClipboardTextPinned("Pinned item #9 (over cap)"))

        // Decoding a profile JSON containing >8 pinned items sanitizes strictly down to 8
        let encoded = try JSONEncoder().encode(profile)
        var rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        rawObject["pinnedClipboardItems"] = (1...12).map { idx in
            [
                "id": UUID().uuidString,
                "text": "Imported pin \(idx)",
                "pinnedAt": 1_700_000_000 + idx
            ] as [String: Any]
        }
        let oversizedData = try JSONSerialization.data(withJSONObject: rawObject)
        let decoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: oversizedData)
        XCTAssertEqual(decoded.activePinnedClipboardItems.count, 8)
        XCTAssertEqual(decoded.activePinnedClipboardItems.first?.text, "Imported pin 1")
        XCTAssertEqual(decoded.activePinnedClipboardItems.last?.text, "Imported pin 8")
    }

    // MARK: - 2. Pinned Clipboard 280-Character Limit & Exclusion of Images / Passwords / Unobserved Text

    func testPinnedClipboardItemsEnforce280CharacterLimitAndRejectImagesPasswordsAndUnobservedText() throws {
        // Exact 280 characters is preserved verbatim
        let exact280 = String(repeating: "A", count: 280)
        let exactItem = try XCTUnwrap(PinnedClipboardItem(text: exact280))
        XCTAssertEqual(exactItem.text.count, 280)
        XCTAssertEqual(exactItem.text, exact280)

        // Over-280 ASCII text is clamped to 280 characters
        let over450 = String(repeating: "B", count: 450)
        let clampedASCII = try XCTUnwrap(PinnedClipboardItem(text: over450))
        XCTAssertEqual(clampedASCII.text.count, 280)
        XCTAssertEqual(clampedASCII.text, String(repeating: "B", count: 280))

        // Over-280 multi-scalar emoji grapheme clusters are clamped to 280 Characters cleanly
        let overEmoji = String(repeating: "👩‍💻", count: 320)
        let clampedEmoji = try XCTUnwrap(PinnedClipboardItem(text: overEmoji))
        XCTAssertEqual(clampedEmoji.text.count, 280)

        // Decoding raw JSON with >280 characters also clamps strictly to <= 280 characters
        let rawOversizedJSON = Data(
            #"{"id":"\#(UUID().uuidString)","text":"\#(over450)","pinnedAt":1700000000}"#.utf8
        )
        let decodedItem = try JSONDecoder().decode(PinnedClipboardItem.self, from: rawOversizedJSON)
        XCTAssertEqual(decodedItem.text.count, 280)

        // Empty or whitespace-only text is rejected
        XCTAssertNil(PinnedClipboardItem(text: ""))
        XCTAssertNil(PinnedClipboardItem(text: "   \n\t  "))

        // Pasteboard images, file URLs, and password/concealed items MUST NOT be stored
        var shelf: [PinnedClipboardItem] = []
        XCTAssertFalse(
            PinnedClipboardShelf.pinFromPasteboard(
                pasteboardTypes: ["public.png", "public.utf8-plain-text"],
                string: "screenshot.png",
                into: shelf
            ).didPin
        )
        XCTAssertFalse(
            PinnedClipboardShelf.pinFromPasteboard(
                pasteboardTypes: ["public.file-url", "public.utf8-plain-text"],
                string: "file:///Users/test/Desktop/secret.pdf",
                into: shelf
            ).didPin
        )
        XCTAssertFalse(
            PinnedClipboardShelf.pinFromPasteboard(
                pasteboardTypes: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"],
                string: "hunter2-password",
                into: shelf
            ).didPin
        )
        XCTAssertFalse(
            PinnedClipboardShelf.pinFromPasteboard(
                pasteboardTypes: ["com.agilebits.onepassword", "public.utf8-plain-text"],
                string: "vault-secret",
                into: shelf
            ).didPin
        )
        XCTAssertTrue(shelf.isEmpty)

        // Long plain text on pasteboard truncates to 280 chars in preview and pins as <= 280 chars
        let longPasteboardOutcome = PinnedClipboardShelf.pinFromPasteboard(
            pasteboardTypes: ["public.utf8-plain-text"],
            string: String(repeating: "Z", count: 500),
            into: shelf
        )
        XCTAssertTrue(longPasteboardOutcome.didPin)
        shelf = longPasteboardOutcome.updated
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf[0].text.count, 280)

        // Phone can ONLY pin text that already appeared in observedPreviewTexts
        var profile = ChocliftDefaults.makeDefaultProfile()
        let observed: Set<String> = ["Seen on Mac clipboard"]
        XCTAssertFalse(
            profile.pinObservedClipboardText("Never appeared on Mac clipboard", observedPreviewTexts: observed)
        )
        XCTAssertTrue(profile.activePinnedClipboardItems.isEmpty)

        XCTAssertTrue(
            profile.pinObservedClipboardText("Seen on Mac clipboard", observedPreviewTexts: observed)
        )
        XCTAssertEqual(profile.activePinnedClipboardItems.map(\.text), ["Seen on Mac clipboard"])

        // Legacy profile JSON without `pinnedClipboardItems` decodes cleanly with an empty array
        let encodedProfile = try JSONEncoder().encode(profile)
        let roundTrippedProfile = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: encodedProfile)
        XCTAssertEqual(roundTrippedProfile.activePinnedClipboardItems.map(\.text), ["Seen on Mac clipboard"])

        var legacyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedProfile) as? [String: Any])
        legacyDict.removeValue(forKey: "pinnedClipboardItems")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDict)
        let legacyDecoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertTrue(legacyDecoded.activePinnedClipboardItems.isEmpty)
    }

    // MARK: - 3. Lock Screen Never Runs Before the Second Tap (3-Second Window, Separate from Sleep Display)

    func testLockScreenRequiresSecondTapWithinThreeSecondsAndNeverRunsOnFirstTap() {
        var controller = Round09LockScreenConfirmController()
        XCTAssertEqual(controller.confirmationWindowSeconds, 3.0, accuracy: 1e-9)
        XCTAssertFalse(controller.isArmed(at: 10.0))

        // First tap MUST arm the 3-second confirmation window and MUST NOT execute lock screen
        let firstTap = controller.registerTap(at: 10.0)
        XCTAssertEqual(firstTap, .requireSecondTap(expiresAt: 13.0))
        XCTAssertTrue(controller.isArmed(at: 10.0))
        XCTAssertTrue(controller.isArmed(at: 12.95))
        XCTAssertFalse(controller.isArmed(at: 13.05))

        // Tapping after the 3-second window expires MUST re-arm rather than lock the screen
        let expiredTap = controller.registerTap(at: 13.2)
        XCTAssertEqual(expiredTap, .requireSecondTap(expiresAt: 16.2))
        XCTAssertTrue(controller.isArmed(at: 14.0))

        // Second tap within 3 seconds confirms execution and disarms immediately
        let secondTap = controller.registerTap(at: 14.8)
        XCTAssertEqual(secondTap, .confirmedExecute)
        XCTAssertFalse(controller.isArmed(at: 14.81))

        // Subsequent tap starts fresh as a first tap (does not run immediately)
        let freshFirstTap = controller.registerTap(at: 20.0)
        XCTAssertEqual(freshFirstTap, .requireSecondTap(expiresAt: 23.0))
    }

    // MARK: - 4. Now-Playing Progress Formatting & Missing-Duration Title-Only Fallback

    func testNowPlayingProgressShowsElapsedAndDurationOrTitleOnlyWhenDurationMissing() throws {
        // Both elapsed and duration provided
        let trackWithTiming = NowPlayingStatus(
            title: "Midnight City",
            artist: "M83",
            appName: "Music",
            isPlaying: true,
            elapsedSeconds: 83.7,
            durationSeconds: 244.9
        )
        XCTAssertEqual(trackWithTiming.formattedProgressText, "1:23 / 4:04")
        let rowWithTiming = try XCTUnwrap(NowPlayingProgressFormatter.rowDisplayContent(for: trackWithTiming))
        XCTAssertEqual(rowWithTiming.title, "Midnight City")
        XCTAssertEqual(rowWithTiming.progressText, "1:23 / 4:04")

        // >= 1 hour formatting + clamping elapsed to duration
        let podcast = NowPlayingStatus(
            title: "Swift Talk",
            appName: "Podcasts",
            isPlaying: true,
            elapsedSeconds: 5000,
            durationSeconds: 3725
        )
        XCTAssertEqual(podcast.formattedProgressText, "1:02:05 / 1:02:05")

        // Missing duration -> nil progressText so row shows title only
        let liveStreamNoDuration = NowPlayingStatus(
            title: "NTS Live Radio",
            appName: "Safari",
            isPlaying: true,
            elapsedSeconds: 42,
            durationSeconds: nil
        )
        XCTAssertNil(liveStreamNoDuration.formattedProgressText)
        let rowNoDuration = try XCTUnwrap(NowPlayingProgressFormatter.rowDisplayContent(for: liveStreamNoDuration))
        XCTAssertEqual(rowNoDuration.title, "NTS Live Radio")
        XCTAssertNil(rowNoDuration.progressText)

        // Zero, negative, or NaN duration -> nil progressText (title only)
        let zeroDuration = NowPlayingStatus(
            title: "Clip",
            isPlaying: false,
            elapsedSeconds: 0,
            durationSeconds: 0
        )
        XCTAssertNil(zeroDuration.formattedProgressText)
        XCTAssertNil(NowPlayingProgressFormatter.formattedProgress(elapsedSeconds: 10, durationSeconds: .nan))
        XCTAssertNil(NowPlayingProgressFormatter.formattedProgress(elapsedSeconds: nil, durationSeconds: 180))

        // Wire JSON round-trip preserves timing and strip frontmostAppName
        let strip = ControlStripState(
            nowPlaying: trackWithTiming,
            frontmostAppName: "Xcode"
        )
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(ControlStripState.self, from: data)
        XCTAssertEqual(decoded.nowPlaying?.formattedProgressText, "1:23 / 4:04")
        XCTAssertEqual(decoded.frontmostAppName, "Xcode")
    }

    // MARK: - 5. Hide Other Windows Undo Policy & Frontmost App Strip Formatter

    func testHideOtherWindowsUndoPolicyAndFrontmostAppStripFormatter() {
        XCTAssertFalse(
            HideOtherWindowsPolicy.canExistingWindowMoveUndoRestoreAppVisibility,
            "One-level WindowMoveUndoBuffer restores AX window frames only and cannot unhide NSRunningApplication visibility"
        )

        var windowUndo = WindowMoveUndoBuffer<String>()
        windowUndo.recordMove(
            windowID: "win-42",
            appName: "Xcode",
            previousFrame: WindowQuartzRect(x: 40, y: 60, width: 1200, height: 800)
        )
        XCTAssertTrue(windowUndo.canUndo)
        // Hiding other apps leaves WindowMoveUndoBuffer untouched
        XCTAssertEqual(windowUndo.lastEntry?.first?.windowID, "win-42")

        XCTAssertEqual(
            FrontmostAppStripFormatter.displayText(appName: "Safari", isConnected: true, in: .english),
            "Safari"
        )
        XCTAssertEqual(
            FrontmostAppStripFormatter.displayText(appName: "   ", isConnected: true, in: .english),
            "Desktop"
        )
        XCTAssertEqual(
            FrontmostAppStripFormatter.displayText(appName: "Safari", isConnected: false, in: .english),
            "Frontmost —"
        )
    }

    // MARK: - 6. End-to-End Loopback Wire Verification (All 5 Round 9 Features + Frame Safety)

    #if os(macOS)
    @MainActor
    func testLoopbackRound09PinnedClipboardLockScreenTwoTapHideOthersFrontmostAppAndUnknownFrames() async throws {
        let suiteName = "com.choclift.tests.round09.wire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round09WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r9-host", macName: "Studio Mac R9")
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

        let unknownClientJSON = Data(#"{"futureRound209ClientCommand":{"flag":true}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Unknown pre-auth frame must disconnect immediately")

        // 2. Pair and connect iPhone companion over in-memory transport
        let phone = CompanionClientEngine(
            deviceID: "iphone-r9",
            deviceName: "iPhone R9",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r9"
        )
        defer { phone.disconnect() }

        let btHost = DiscoveredBluetoothMac(
            id: UUID(),
            name: "Studio Mac R9",
            macID: "mac-r9-host"
        )
        var latestClientPipeEnd: InMemoryCompanionPipe?
        var latestServerPipeEnd: CompanionFrameTransport?
        phone.simulatedBluetoothConnector = { _ in
            let serverEnd = server.acceptInMemoryCompanion()
            let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
            proxy.onPayload = { serverEnd.send($0) }
            serverEnd.onPayload = { proxy.send($0) }
            serverEnd.onClosed = { proxy.cancel() }
            proxy.start()
            serverEnd.start()
            latestClientPipeEnd = clientEnd
            latestServerPipeEnd = proxy
            return clientEnd
        }
        phone.simulateDiscoveredBluetoothMacs([btHost])
        phone.connectBluetooth(to: btHost)

        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phone.submitPIN(server.currentPIN)

        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        // 3. Verify strip state sync: Now Playing progress + Frontmost App Name
        phone.requestControlStripState()
        for _ in 0..<50 where phone.controlStripState.frontmostAppName != "Xcode" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.resolvedStripFrontmostAppName, "Xcode")
        XCTAssertEqual(phone.controlStripState.nowPlaying?.formattedProgressText, "0:45 / 3:20")

        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        for _ in 0..<50 where phone.resolvedStripFrontmostAppName != "Safari" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.resolvedStripFrontmostAppName, "Safari")

        // 4. Pinned clipboard items: only items seen in Mac clipboard preview can be pinned, capped at 8,
        //    synced through workspace profile, and inserted via .focusedFieldInsert
        XCTAssertFalse(
            phone.pinClipboardPreviewText("Unobserved text that never appeared on Mac"),
            "Phone must not pin text that never appeared in Mac clipboard preview"
        )

        for idx in 1...9 {
            let text = "Mac clipboard snippet #\(idx)"
            let snapshot = ClipboardPreviewEvaluator.evaluate(
                pasteboardTypes: ["public.utf8-plain-text"],
                string: text
            )
            delegate.observedClipboardTexts.insert(text)
            server.broadcastClipboardPreview(snapshot)
            for _ in 0..<40 where phone.clipboardPreview.previewText != text {
                try await Task.sleep(for: .milliseconds(15))
            }
            if idx <= 8 {
                XCTAssertTrue(phone.pinCurrentClipboardPreview(), "Pin #\(idx) should succeed")
            } else {
                XCTAssertFalse(phone.pinCurrentClipboardPreview(), "9th pin must fail at 8-item cap")
            }
        }

        for _ in 0..<50 where delegate.profile.activePinnedClipboardItems.count != 8 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.profile.activePinnedClipboardItems.count, 8)
        XCTAssertEqual(delegate.profile.activePinnedClipboardItems.count, 8)

        let firstPin = try XCTUnwrap(phone.profile.activePinnedClipboardItems.first)
        XCTAssertTrue(phone.insertPinnedClipboardItem(firstPin))
        for _ in 0..<50 where delegate.insertedSnippets.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.insertedSnippets.count, 1)
        XCTAssertEqual(delegate.insertedSnippets.first?.text, "Mac clipboard snippet #1")
        XCTAssertEqual(delegate.insertedSnippets.first?.mode, .focusedFieldInsert)

        // 5. Lock Screen is separate from Sleep Display and MUST NOT run before the second tap
        phone.sleepMacDisplay()
        for _ in 0..<50 where delegate.sleepDisplayCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.sleepDisplayCount, 1)
        XCTAssertEqual(delegate.lockScreenCount, 0, "Sleep Display must not trigger Lock Screen")

        XCTAssertEqual(phone.tapLockMacScreen(at: 500.0), .requireSecondTap(expiresAt: 503.0))
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.lockScreenCount, 0, "Lock Screen MUST NOT run on the first tap")

        // Tap after >3s expiry re-arms without locking
        XCTAssertEqual(phone.tapLockMacScreen(at: 503.5), .requireSecondTap(expiresAt: 506.5))
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.lockScreenCount, 0, "Expired tap must re-arm and not lock")

        // Second tap within 3s executes Lock Screen
        XCTAssertEqual(phone.tapLockMacScreen(at: 504.7), .confirmedExecute)
        for _ in 0..<50 where delegate.lockScreenCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.lockScreenCount, 1)
        XCTAssertEqual(delegate.sleepDisplayCount, 1)

        // 6. Hide Other Windows hides other apps without quitting and leaves canUndoWindowMove unchanged
        delegate.stripState.canUndoWindowMove = true
        server.broadcastControlStripState(delegate.stripState)
        for _ in 0..<50 where !phone.controlStripState.canUndoWindowMove {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.controlStripState.canUndoWindowMove)

        phone.hideOtherWindows()
        for _ in 0..<50 where delegate.hideOtherAppsCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.hideOtherAppsCount, 1)
        XCTAssertTrue(
            phone.controlStripState.canUndoWindowMove,
            "Hide Other Windows must leave existing one-level window-move undo unchanged"
        )

        // 7. Unknown POST-AUTH frames stay non-fatal in both directions
        latestClientPipeEnd?.send(unknownClientFrame)
        let unknownServerJSON = Data(#"{"futureRound209ServerEvent":{"info":1}}"#.utf8)
        var sLen = UInt32(unknownServerJSON.count).bigEndian
        var unknownServerFrame = Data(capacity: 4 + unknownServerJSON.count)
        withUnsafeBytes(of: &sLen) { unknownServerFrame.append(contentsOf: $0) }
        unknownServerFrame.append(unknownServerJSON)
        latestServerPipeEnd?.send(unknownServerFrame)

        try await Task.sleep(for: .milliseconds(45))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frames must stay non-fatal")
    }
    #endif
}

#if os(macOS)
@MainActor
private final class Round09WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var observedClipboardTexts: Set<String> = []
    var stripState = ControlStripState(
        nowPlaying: NowPlayingStatus(
            title: "Veridis Quo",
            artist: "Daft Punk",
            appName: "Music",
            isPlaying: true,
            elapsedSeconds: 45,
            durationSeconds: 200
        ),
        macBattery: .powerAdapter,
        frontmostAppName: "Xcode"
    )
    var sleepDisplayCount = 0
    var lockScreenCount = 0
    var hideOtherAppsCount = 0
    var insertedSnippets: [(text: String, mode: SnippetInsertMode)] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] {
        [RecentAppEntry(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", appPath: "/Applications/Xcode.app")]
    }
    func serverFrontmostBundleID() -> String? { "com.apple.dt.Xcode" }
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
        case .requestControlStripState:
            reply(.controlStripStateUpdated(stripState))

        case .updateProfile(let incoming):
            var sanitized = incoming
            let allowed = Set(profile.pinnedClipboardItems.map(\.text)).union(observedClipboardTexts)
            sanitized.sanitizePinnedClipboardItems(allowedTexts: allowed)
            profile = sanitized
            server?.broadcast(.profileUpdated(profile))

        case .insertSnippet(let text, let mode):
            insertedSnippets.append((text: text, mode: mode))
            reply(.actionFeedback(success: true, title: "Inserted", detail: nil))

        case .sleepMacDisplay:
            sleepDisplayCount += 1
            reply(.actionFeedback(success: true, title: "Sleep Display", detail: nil))

        case .lockMacScreen:
            lockScreenCount += 1
            reply(.actionFeedback(success: true, title: "Lock Screen", detail: nil))

        case .hideOtherApplications:
            hideOtherAppsCount += 1
            reply(.actionFeedback(success: true, title: "Hide Others", detail: nil))

        default:
            break
        }
    }
}
#endif
