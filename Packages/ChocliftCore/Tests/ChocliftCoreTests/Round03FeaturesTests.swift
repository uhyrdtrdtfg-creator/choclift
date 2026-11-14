import XCTest
@testable import ChocliftCore

final class Round03FeaturesTests: XCTestCase {

    // MARK: - 1. Soundboard Name Search

    func testSoundboardNameSearchFiltering() {
        let clips = [
            SoundboardClip(name: "Airhorn Classic", filePath: "/Sounds/airhorn.wav", durationSeconds: 1.8, emoji: "📯"),
            SoundboardClip(name: "Café Rimshot Drum", filePath: "/Sounds/rimshot.aiff", durationSeconds: 1.2, emoji: "🥁"),
            SoundboardClip(name: "Sad Trombone", filePath: "/Sounds/trombone.mp3", durationSeconds: 3.4, emoji: "🎺"),
            SoundboardClip(name: "Cricket Chirp", filePath: "/Sounds/cricket.m4a", durationSeconds: 2.5, emoji: "🦗")
        ]

        // Empty or whitespace query returns all clips in board order
        XCTAssertEqual(SoundboardSearch.filter(clips, query: ""), clips)
        XCTAssertEqual(SoundboardSearch.filter(clips, query: "   \n\t "), clips)

        // Case-insensitive substring match
        let hornHits = SoundboardSearch.filter(clips, query: "AIRHORN")
        XCTAssertEqual(hornHits.map(\.name), ["Airhorn Classic"])

        // Diacritic-insensitive and multi-token out-of-order match
        let cafeDrumHits = SoundboardSearch.filter(clips, query: "drum cafe")
        XCTAssertEqual(cafeDrumHits.map(\.name), ["Café Rimshot Drum"])

        // Partial prefix across multiple clips
        let cHits = SoundboardSearch.filter(clips, query: "c")
        XCTAssertEqual(cHits.map(\.name), ["Airhorn Classic", "Café Rimshot Drum", "Cricket Chirp"])

        // Non-matching query returns empty array
        XCTAssertTrue(SoundboardSearch.filter(clips, query: "laserexplosion").isEmpty)
    }

    // MARK: - 2. 24-Sound Cap & 8-Second Duration Rejection

    func testSoundboard24CapAnd8SecondDurationRejection() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertTrue(profile.soundboardClips.isEmpty)

        // Reject > 8.0s clips and invalid durations before adding
        let overEight = SoundboardClip(
            name: "Too Long Intro",
            filePath: "/Sounds/long.wav",
            durationSeconds: 8.01
        )
        XCTAssertEqual(
            profile.addSoundboardClip(overEight),
            .failure(.durationTooLong(seconds: 8.01, maxSeconds: 8.0))
        )
        XCTAssertEqual(
            profile.addSoundboardClip(SoundboardClip(name: "Zero", filePath: "/Sounds/zero.wav", durationSeconds: 0)),
            .failure(.invalidDuration)
        )
        XCTAssertEqual(
            profile.addSoundboardClip(SoundboardClip(name: "Negative", filePath: "/Sounds/neg.wav", durationSeconds: -2.0)),
            .failure(.invalidDuration)
        )
        XCTAssertEqual(
            profile.addSoundboardClip(SoundboardClip(name: "NotAudio", filePath: "/Sounds/readme.txt", durationSeconds: 1.5)),
            .failure(.unsupportedFormat)
        )
        XCTAssertTrue(profile.soundboardClips.isEmpty)

        // Exact 8.0s boundary is allowed; fill board up to 24 sounds
        for idx in 1...SoundboardClip.maxBoardCount {
            let duration = (idx == SoundboardClip.maxBoardCount) ? 8.0 : Double((idx % 7) + 1)
            let clip = SoundboardClip(
                name: "Pad \(idx)",
                filePath: "/Sounds/pad_\(idx).aiff",
                durationSeconds: duration
            )
            let res = profile.addSoundboardClip(clip)
            if case .failure(let error) = res {
                XCTFail("Expected clip #\(idx) to succeed, got error \(error)")
            }
        }
        XCTAssertEqual(profile.soundboardClips.count, 24)

        // 25th sound is rejected with .boardFull(limit: 24)
        let twentyFifth = SoundboardClip(
            name: "Pad 25 Overflow",
            filePath: "/Sounds/pad_25.wav",
            durationSeconds: 1.0
        )
        XCTAssertEqual(
            profile.addSoundboardClip(twentyFifth),
            .failure(.boardFull(limit: 24))
        )
        XCTAssertEqual(profile.soundboardClips.count, 24)

        // Duplicate file path is rejected when space is available
        let removedID = profile.soundboardClips[0].id
        XCTAssertTrue(profile.deleteSoundboardClip(id: removedID))
        XCTAssertEqual(profile.soundboardClips.count, 23)
        let duplicatePathClip = SoundboardClip(
            name: "Duplicate Path",
            filePath: "/Sounds/pad_2.aiff",
            durationSeconds: 1.5
        )
        XCTAssertEqual(
            profile.addSoundboardClip(duplicatePathClip),
            .failure(.duplicateFile)
        )

        // Codable wire/disk defense: decoding >24 clips or >8s clips sanitizes automatically
        var rawClips: [SoundboardClip] = [
            SoundboardClip(name: "Sneaky 12s", filePath: "/Sounds/sneaky_long.mp3", durationSeconds: 12.0)
        ]
        for idx in 1...28 {
            rawClips.append(
                SoundboardClip(
                    name: "Decoded \(idx)",
                    filePath: "/Sounds/decoded_\(idx).wav",
                    durationSeconds: 2.0
                )
            )
        }
        let rawWrapper = ChocliftWorkspaceProfile(
            pages: profile.pages,
            emojiSlides: profile.emojiSlides,
            gestureConfig: profile.gestureConfig,
            soundboardClips: rawClips
        )
        XCTAssertEqual(rawWrapper.soundboardClips.count, 24)
        XCTAssertFalse(rawWrapper.soundboardClips.contains { $0.name == "Sneaky 12s" })
    }

    // MARK: - 3. Reference Tile Resolution, Missing Target State & Zero Duplicated Payload

    func testSlotReferenceResolutionWhenTargetExistsAndWhenTargetIsMissing() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let page0ID = profile.pages[0].id
        let page1ID = profile.pages[1].id

        let originalShortcut = BarItem(
            kind: .shortcut(
                shortcutName: "Deploy Staging Secret",
                emoji: "🚀",
                backgroundHex: "#F3EEFF"
            )
        )
        profile.pages[0].slots[2] = originalShortcut

        let refItem = BarItem(
            kind: .slotReference(
                targetPageID: page0ID,
                targetSlotIndex: 2
            )
        )
        profile.pages[1].slots[4] = refItem
        let refOrigin = SlotCoordinate(pageID: page1ID, slotIndex: 4)

        // 1. Verify encoded JSON for reference tile does NOT duplicate the target action payload
        let encodedRef = try JSONEncoder().encode(refItem)
        let encodedRefString = try XCTUnwrap(String(data: encodedRef, encoding: .utf8))
        XCTAssertTrue(encodedRefString.contains("slotReference"))
        XCTAssertFalse(encodedRefString.contains("Deploy Staging Secret"))
        XCTAssertFalse(encodedRefString.contains("🚀"))

        // 2. Resolves to original item while present
        let initialResolution = profile.resolveBarItem(refItem, from: refOrigin)
        guard case .resolved(let resolvedPageID, let resolvedPageIdx, _, _, let resolvedSlotIdx, let resolvedItem) = initialResolution else {
            return XCTFail("Expected reference slot to resolve to original slot")
        }
        XCTAssertEqual(resolvedPageID, page0ID)
        XCTAssertEqual(resolvedPageIdx, 0)
        XCTAssertEqual(resolvedSlotIdx, 2)
        XCTAssertEqual(resolvedItem, originalShortcut)
        XCTAssertEqual(profile.displayTitle(for: refItem, from: refOrigin, in: .english), "Deploy Staging Secret")

        // 3. Editing the original slot updates what the reference resolves to automatically
        let updatedOriginal = BarItem(
            id: originalShortcut.id,
            kind: .systemAction(action: .quitApp)
        )
        profile.pages[0].slots[2] = updatedOriginal
        XCTAssertEqual(profile.resolveBarItem(refItem, from: refOrigin).resolvedItem, updatedOriginal)
        XCTAssertTrue(refItem.requiresDestructiveConfirmation(in: profile, from: refOrigin))

        // 4. Swapping slots on page 0 keeps the reference aligned with the moved original
        profile.swapSlots(pageIndex: 0, fromSlot: 2, toSlot: 5)
        let swappedRef = try XCTUnwrap(profile.pages[1].slots[4])
        XCTAssertEqual(swappedRef.slotReferenceCoordinate, SlotCoordinate(pageID: page0ID, slotIndex: 5))
        XCTAssertEqual(profile.resolveBarItem(swappedRef, from: refOrigin).resolvedItem, updatedOriginal)

        // 5. Deleting/clearing the original slot yields quiet .missing resolution and does not require destructive confirm
        profile.pages[0].slots[5] = nil
        let missingResolution = profile.resolveBarItem(swappedRef, from: refOrigin)
        XCTAssertEqual(missingResolution, .missing)
        XCTAssertTrue(missingResolution.isMissing)
        XCTAssertNil(missingResolution.resolvedItem)
        XCTAssertFalse(swappedRef.requiresDestructiveConfirmation(in: profile, from: refOrigin))
        XCTAssertEqual(profile.displayTitle(for: swappedRef, from: refOrigin, in: .english), "Original Missing")

        // 6. Deleting the entire target page also yields .missing
        profile.pages[0].slots[5] = updatedOriginal
        XCTAssertNotNil(profile.resolveBarItem(swappedRef, from: refOrigin).resolvedItem)
        profile.pages.removeFirst()
        XCTAssertEqual(profile.resolveBarItem(swappedRef, from: refOrigin), .missing)

        // 7. Self-reference and cycle safety (A -> B -> A returns .missing)
        let cyclePageID = profile.pages[0].id
        let slotA = SlotCoordinate(pageID: cyclePageID, slotIndex: 0)
        let refAtoB = BarItem(kind: .slotReference(targetPageID: cyclePageID, targetSlotIndex: 1))
        let refBtoA = BarItem(kind: .slotReference(targetPageID: cyclePageID, targetSlotIndex: 0))
        profile.pages[0].slots[0] = refAtoB
        profile.pages[0].slots[1] = refBtoA
        XCTAssertEqual(profile.resolveBarItem(refAtoB, from: slotA), .missing)

        let selfRef = BarItem(kind: .slotReference(targetPageID: cyclePageID, targetSlotIndex: 0))
        profile.pages[0].slots[0] = selfRef
        XCTAssertEqual(profile.resolveBarItem(selfRef, from: slotA), .missing)
    }

    // MARK: - 4. System-Action Shortcut Preview Strictness

    func testSystemActionShortcutPreviewOnlyExistsForRealKeyboardShortcuts() {
        let expectedShortcuts: [SystemQuickAction: String] = [
            .switchToNextWindow: "⌘`",
            .switchToPreviousWindow: "⇧⌘`",
            .copySelection: "⌘C",
            .pasteClipboard: "⌘V",
            .cutSelection: "⌘X",
            .undoAction: "⌘Z",
            .redoAction: "⇧⌘Z",
            .lockScreen: "⌃⌘Q",
            .openEmojiPicker: "⌃⌘Space"
        ]

        for action in SystemQuickAction.allCases {
            XCTAssertEqual(
                action.sentKeyboardShortcut,
                expectedShortcuts[action],
                "Unexpected shortcut preview for \(action.rawValue)"
            )
        }
    }

    // MARK: - 5. Companion Search Across Page Tiles, Snippets & Flows

    func testCompanionWorkspaceSearchAcrossTilesSnippetsAndFlows() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        for pIdx in profile.pages.indices {
            profile.pages[pIdx].slots = Array(repeating: nil, count: BarPage.slotsPerPage)
        }

        profile.pages[0].slots[0] = BarItem(kind: .systemAction(action: .copySelection))
        profile.pages[0].slots[1] = BarItem(
            kind: .website(
                url: "https://developer.apple.com",
                title: "Apple Docs",
                emoji: "📚",
                backgroundHex: "#EDF6FF",
                switchExistingTab: true
            )
        )
        // Valid reference on page 1 pointing to page 0 slot 1
        profile.pages[1].slots[0] = BarItem(
            kind: .slotReference(targetPageID: profile.pages[0].id, targetSlotIndex: 1)
        )
        // Broken/missing reference on page 1 pointing to empty slot 7
        profile.pages[1].slots[1] = BarItem(
            kind: .slotReference(targetPageID: profile.pages[0].id, targetSlotIndex: 7)
        )

        profile.snippets = [
            TextSnippet(title: "Apple Support Reply", body: "Thanks for reaching out to support!")
        ]
        profile.flows = [
            ActionFlow(
                name: "Apple Review Prep",
                emoji: "🍏",
                backgroundHex: "#ECFAEE",
                steps: [
                    ActionFlowStep(
                        kind: .launchOrActivateApp(
                            bundleIdentifier: "com.apple.dt.Xcode",
                            appName: "Xcode",
                            appPath: nil
                        )
                    )
                ]
            )
        ]

        // Empty query returns no auto-results
        XCTAssertTrue(CompanionWorkspaceSearch.search(in: profile, query: "   ", scope: .all, language: .english).isEmpty)

        // Cross-domain search for "Apple" finds: original tile + valid reference tile + snippet + flow (4 hits), skipping missing reference
        let allApple = CompanionWorkspaceSearch.search(in: profile, query: "Apple", scope: .all, language: .english)
        XCTAssertEqual(allApple.count, 4)

        let tileOnly = CompanionWorkspaceSearch.search(in: profile, query: "Apple", scope: .tiles, language: .english)
        XCTAssertEqual(tileOnly.count, 2)

        let snippetOnly = CompanionWorkspaceSearch.search(in: profile, query: "Apple", scope: .snippets, language: .english)
        XCTAssertEqual(snippetOnly.count, 1)
        if case .snippet(let matchedSnippet) = snippetOnly[0].payload {
            XCTAssertEqual(matchedSnippet.body, "Thanks for reaching out to support!")
        } else {
            XCTFail("Expected snippet payload")
        }

        let flowOnly = CompanionWorkspaceSearch.search(in: profile, query: "Apple", scope: .flows, language: .english)
        XCTAssertEqual(flowOnly.count, 1)

        // Shortcut symbol search ("⌘C") finds Copy tile with shortcut badge
        let copyHits = CompanionWorkspaceSearch.search(in: profile, query: "⌘C", scope: .tiles, language: .english)
        XCTAssertEqual(copyHits.count, 1)
        XCTAssertEqual(copyHits[0].badgeText, "⌘C")
    }

    // MARK: - 6. Soundboard Volume Separation & Wire Auth / Unknown Frame Safety

    #if os(macOS)
    @MainActor
    func testSoundboardVolumeSeparationWatchSlotTriggerAndUnauthenticatedSafety() async throws {
        let suiteName = "com.choclift.round03.wire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clip = SoundboardClip(
            name: "rimshot",
            filePath: "/System/Library/Sounds/Glass.aiff",
            durationSeconds: 0.9,
            emoji: "🥁"
        )
        let delegate = Round03WireTestDelegate(initialClip: clip)
        let server = MacServerEngine(macID: "mac-round03-host", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        // 1. Unauthenticated client sends new Round 3 soundboard messages BEFORE PIN auth:
        //    Must NOT disconnect the client; server replies .pairingRequired and allows subsequent PIN pairing!
        let unauthPipe = server.acceptInMemoryCompanion()
        var unauthServerMessages: [ServerMessage] = []
        var unauthAcc = WireStreamAccumulator()
        unauthPipe.onPayload = { chunk in
            if let payloads = try? unauthAcc.appendAndExtractPayloads(chunk) {
                for p in payloads {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: p) {
                        unauthServerMessages.append(msg)
                    }
                }
            }
        }
        unauthPipe.start()

        unauthPipe.send(try WireFrameCodec.encode(ClientMessage.triggerSoundboardClip(soundID: clip.id)))
        unauthPipe.send(try WireFrameCodec.encode(ClientMessage.setSoundboardVolume(level: 0.42)))
        unauthPipe.send(try WireFrameCodec.encode(ClientMessage.stopSoundboardPlayback))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(delegate.triggeredSoundIDs.count, 0, "Unauthenticated soundboard trigger must not execute")
        let pairingRequiredCount = unauthServerMessages.filter {
            if case .pairingRequired = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(pairingRequiredCount, 3)

        // Verify unauthPipe is STILL connected and can complete hello + PIN auth!
        unauthPipe.send(
            try WireFrameCodec.encode(
                ClientMessage.hello(
                    protocolVersion: ChocliftDefaults.protocolVersion,
                    deviceID: "unauth-recover-phone",
                    deviceName: "Test iPhone",
                    platform: .iPhone,
                    savedAuthToken: nil
                )
            )
        )
        unauthPipe.send(
            try WireFrameCodec.encode(
                ClientMessage.submitPIN(
                    pin: server.currentPIN,
                    deviceID: "unauth-recover-phone",
                    deviceName: "Test iPhone",
                    platform: .iPhone
                )
            )
        )
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(
            unauthServerMessages.contains {
                if case .authSucceeded = $0 { return true }
                return false
            },
            "Client must remain connected after pre-auth Round 3 frames and succeed at PIN pairing"
        )

        // 2. Pair iPhone + Apple Watch via CompanionClientEngine
        let phoneServerEnd = server.acceptInMemoryCompanion()
        let (phoneProxy, phoneClientEnd) = InMemoryCompanionPipe.pair()
        phoneProxy.onPayload = { phoneServerEnd.send($0) }
        phoneServerEnd.onPayload = { phoneProxy.send($0) }
        phoneProxy.start()
        phoneServerEnd.start()

        let phoneClient = CompanionClientEngine(
            deviceID: "iphone-r3",
            deviceName: "iPhone 17",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "phone-r3"
        )
        defer { phoneClient.disconnect() }

        phoneClient.connectInMemoryBluetooth(to: phoneClientEnd, targetName: "Studio Mac")
        for _ in 0..<50 {
            if case .awaitingPIN = phoneClient.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phoneClient.submitPIN(server.currentPIN)
        for _ in 0..<50 where !phoneClient.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phoneClient.connectionState.isConnected)

        // Adjust Soundboard Volume on iPhone -> separate from system volume (0.65 stays untouched!)
        phoneClient.setSoundboardVolume(0.35)
        for _ in 0..<50 where abs(delegate.controlStripState.soundboardVolume - 0.35) > 0.001 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.controlStripState.soundboardVolume, 0.35, accuracy: 0.001)
        XCTAssertEqual(delegate.controlStripState.volume, 0.65, accuracy: 0.001)
        XCTAssertEqual(phoneClient.controlStripState.volume, 0.65, accuracy: 0.001)
        XCTAssertEqual(phoneClient.controlStripState.soundboardVolume, 0.35, accuracy: 0.001)

        // Trigger soundboard pad from iPhone
        phoneClient.triggerSoundboardClip(id: clip.id)
        for _ in 0..<50 where delegate.triggeredSoundIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.triggeredSoundIDs, [clip.id])

        // 3. Pair Apple Watch and trigger the soundboard slot on Page 0 Slot 0
        let watchServerEnd = server.acceptInMemoryCompanion()
        let (watchProxy, watchClientEnd) = InMemoryCompanionPipe.pair()
        watchProxy.onPayload = { watchServerEnd.send($0) }
        watchServerEnd.onPayload = { watchProxy.send($0) }
        watchProxy.start()
        watchServerEnd.start()

        let watchClient = CompanionClientEngine(
            deviceID: "watch-r3",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch-r3"
        )
        defer { watchClient.disconnect() }

        watchClient.connectInMemoryBluetooth(to: watchClientEnd, targetName: "Studio Mac")
        for _ in 0..<50 {
            if case .awaitingPIN = watchClient.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        watchClient.submitPIN(server.currentPIN)
        for _ in 0..<50 where !watchClient.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(watchClient.connectionState.isConnected)

        let watchSlotSound = try XCTUnwrap(watchClient.profile.pages[0].slots[0])
        watchClient.triggerBarItem(watchSlotSound)
        for _ in 0..<50 where delegate.triggeredSoundIDs.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.triggeredSoundIDs, [clip.id, clip.id])

        // Simulate an older Mac that silently ignores a newly introduced action.
        phoneClient.performQuickAction(.switchToNextWindow)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(phoneClient.lastFeedback?.success, false)
        XCTAssertTrue(phoneClient.connectionState.isConnected)

        // 4. Send unknown post-auth frame from raw client & unknown server frame to phone -> both stay connected
        let unknownClientPayload = Data(#"{"futureRound99Message":{"alpha":1}}"#.utf8)
        var lenBE = UInt32(unknownClientPayload.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientPayload.count)
        withUnsafeBytes(of: &lenBE) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientPayload)
        unauthPipe.send(unknownClientFrame)

        let unknownServerPayload = Data(#"{"futureServerEvent":{"beta":2}}"#.utf8)
        var sLenBE = UInt32(unknownServerPayload.count).bigEndian
        var unknownServerFrame = Data(capacity: 4 + unknownServerPayload.count)
        withUnsafeBytes(of: &sLenBE) { unknownServerFrame.append(contentsOf: $0) }
        unknownServerFrame.append(unknownServerPayload)
        phoneProxy.send(unknownServerFrame)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(phoneClient.connectionState.isConnected)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class Round03WireTestDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile
    var controlStripState = ControlStripState(
        volume: 0.65,
        isVolumeMuted: false,
        brightness: 0.75,
        isBrightnessAvailable: true,
        soundboardVolume: 0.80
    )
    var triggeredSoundIDs: [UUID] = []
    var stopCount: Int = 0

    init(initialClip: SoundboardClip) {
        var initial = ChocliftDefaults.makeDefaultProfile()
        _ = initial.addSoundboardClip(initialClip)
        initial.pages[0].slots[0] = initial.makeBarItem(for: initialClip)
        self.profile = initial
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { nil }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(controlStripState))
        case .setSoundboardVolume(let level):
            let clamped = ControlStripLevel.clamp(level)
            controlStripState.soundboardVolume = clamped
            profile.soundboardVolume = clamped
            reply(.controlStripStateUpdated(controlStripState))
        case .triggerSoundboardClip(let soundID):
            triggeredSoundIDs.append(soundID)
            reply(.actionFeedback(success: true, title: "Soundboard", detail: nil))
        case .stopSoundboardPlayback:
            stopCount += 1
        case .triggerBarItem(let item):
            let effective = profile.resolveBarItem(item).resolvedItem
            if let effective, case .soundboard(let soundID, _, _, _) = effective.kind {
                triggeredSoundIDs.append(soundID)
                reply(.actionFeedback(success: true, title: "Soundboard", detail: nil))
            }
        default:
            break
        }
    }
}
#endif
