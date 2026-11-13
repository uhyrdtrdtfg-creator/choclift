import XCTest
@testable import ChocliftCore

final class Round05FeaturesTests: XCTestCase {

    // MARK: - 1. Pin Cap at 4, Persistence Across Page Changes, Unpin, Swap & Decode Clamp

    func testPinnedStripSlotsCapAt4DeduplicationUnpinSwapAndDecodeClamp() throws {
        XCTAssertEqual(PinnedStripSlots.maxPinnedCount, 4)

        var profile = ChocliftDefaults.makeDefaultProfile()
        // Populate 6 occupied slots across pages 0, 1, and 2
        let item0 = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        let item1 = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"))
        let item2 = BarItem(kind: .systemAction(action: .maximizeWindow))
        let item3 = BarItem(kind: .systemAction(action: .missionControl))
        let item4 = BarItem(kind: .shortcut(shortcutName: "Focus Timer", emoji: "⏱️", backgroundHex: "#F3EEFF"))
        let item5 = BarItem(
            kind: .website(
                url: "https://github.com",
                title: "GitHub",
                emoji: "🐙",
                backgroundHex: "#EDF6FF",
                switchExistingTab: true
            )
        )

        profile.pages[0].slots[0] = item0
        profile.pages[0].slots[1] = item1
        profile.pages[0].slots[7] = nil // explicitly empty slot
        profile.pages[1].slots[0] = item2
        profile.pages[1].slots[2] = item3
        profile.pages[2].slots[0] = item4
        profile.pages[2].slots[1] = item5

        let c0 = SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 0)
        let c1 = SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 1)
        let c2 = SlotCoordinate(pageID: profile.pages[1].id, slotIndex: 0)
        let c3 = SlotCoordinate(pageID: profile.pages[1].id, slotIndex: 2)
        let c4 = SlotCoordinate(pageID: profile.pages[2].id, slotIndex: 0)
        let c5 = SlotCoordinate(pageID: profile.pages[2].id, slotIndex: 1)
        let emptyCoord = SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 7)

        // Empty slot cannot be pinned
        XCTAssertFalse(profile.pinSlotToStrip(emptyCoord))
        XCTAssertEqual(profile.activePinnedStripCount, 0)

        // Pinning up to 4 occupied slots succeeds
        XCTAssertTrue(profile.pinSlotToStrip(c0))
        XCTAssertTrue(profile.pinSlotToStrip(c1))
        XCTAssertTrue(profile.pinSlotToStrip(c2))
        XCTAssertTrue(profile.canPinMoreSlotsToStrip)
        XCTAssertTrue(profile.pinSlotToStrip(c3))
        XCTAssertEqual(profile.activePinnedStripCount, 4)
        XCTAssertFalse(profile.canPinMoreSlotsToStrip)

        // Re-pinning an already-pinned slot is idempotent and does not duplicate
        XCTAssertTrue(profile.pinSlotToStrip(c1))
        XCTAssertEqual(profile.activePinnedStripSlots, [c0, c1, c2, c3])

        // 5th distinct slot is rejected at cap 4
        XCTAssertFalse(profile.pinSlotToStrip(c4))
        XCTAssertFalse(profile.pinSlotToStrip(c5))
        XCTAssertEqual(profile.activePinnedStripCount, 4)
        XCTAssertEqual(profile.resolvedPinnedStripSlots().map(\.item.id), [item0.id, item1.id, item2.id, item3.id])

        // Changing active page via AppDeckFollowerState leaves all 4 pinned tiles resolved & visible
        var deckFollower = AppDeckFollowerState()
        deckFollower.handleProfileUpdated(profile, frontmostBundleIdentifier: nil)
        for pageIdx in 0..<profile.pages.count {
            deckFollower.selectManualPage(index: pageIdx, in: profile)
            XCTAssertEqual(deckFollower.currentPageIndex, pageIdx)
            XCTAssertEqual(profile.resolvedPinnedStripSlots().map(\.item.id), [item0.id, item1.id, item2.id, item3.id])
        }

        // Unpinning one slot from the slot editor frees space for a new 4th slot
        XCTAssertTrue(profile.unpinSlotFromStrip(c1))
        XCTAssertEqual(profile.activePinnedStripCount, 3)
        XCTAssertFalse(profile.isSlotPinnedToStrip(c1))
        XCTAssertTrue(profile.canPinMoreSlotsToStrip)
        XCTAssertTrue(profile.pinSlotToStrip(c4))
        XCTAssertEqual(profile.activePinnedStripSlots, [c0, c2, c3, c4])

        // Swapping slots on page 0 remaps pinned coordinate c0 (slot 0 -> slot 3)
        profile.pages[0].slots[3] = item5
        profile.swapSlots(pageIndex: 0, fromSlot: 0, toSlot: 3)
        let movedCoord = SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 3)
        XCTAssertTrue(profile.isSlotPinnedToStrip(movedCoord))
        XCTAssertFalse(profile.isSlotPinnedToStrip(c0))
        XCTAssertEqual(profile.resolvedPinnedStripSlots().first?.item.id, item0.id)

        // Clearing a pinned slot automatically prunes it from active pinned slots
        profile.pages[0].slots[3] = nil
        profile.prunePinnedStripSlots()
        XCTAssertEqual(profile.activePinnedStripCount, 3)

        // Decoding a profile JSON carrying >4 pinned coordinates clamps strictly to 4 valid occupied slots
        let baseData = try JSONEncoder().encode(profile)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: baseData) as? [String: Any])
        let rawCoords: [[String: Any]] = [c1, c1, emptyCoord, c2, c3, c4, c5].map {
            ["pageID": $0.pageID.uuidString, "slotIndex": $0.slotIndex]
        }
        jsonObject["pinnedStripSlots"] = rawCoords
        let tamperedData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: tamperedData)
        XCTAssertEqual(decoded.pinnedStripSlots.count, 4)
        XCTAssertEqual(decoded.pinnedStripSlots, [c1, c2, c3, c4])

        // Legacy profile JSON without `pinnedStripSlots` decodes cleanly to empty array
        jsonObject.removeValue(forKey: "pinnedStripSlots")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decodedLegacy = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertTrue(decodedLegacy.pinnedStripSlots.isEmpty)
    }

    // MARK: - 2. Recent List Cap at 8 & Strict No-Clipboard / No-Secret Invariant

    @MainActor
    func testRecentlyTriggeredTilesCapAt8MRUOrderAndNoSecretsRecorded() throws {
        XCTAssertEqual(RecentlyTriggeredTileList.maxEntries, 8)
        XCTAssertEqual(RecentlyTriggeredTileEntry.maxEntries, 8)

        var list = RecentlyTriggeredTileList()
        let ids = (0..<11).map { _ in UUID() }
        for index in 0..<11 {
            list.record(id: ids[index], title: "Tile \(index)")
        }

        // Capped strictly at 8 in most-recently-triggered order (10 down to 3)
        XCTAssertEqual(list.count, 8)
        XCTAssertEqual(list.entries.map(\.id), Array(ids[3...10].reversed()))
        XCTAssertEqual(list.entries.map(\.title), (3...10).reversed().map { "Tile \($0)" })

        // Re-triggering an existing tile moves it to index 0 without duplicating or exceeding 8
        list.record(id: ids[5], title: "Tile 5 Updated")
        XCTAssertEqual(list.count, 8)
        XCTAssertEqual(list.entries.first?.id, ids[5])
        XCTAssertEqual(list.entries.first?.title, "Tile 5 Updated")

        // Wire / persistence JSON decode defense: >8 entries clamps to 8
        let fourteenRawEntries = (0..<14).map { idx in
            ["id": UUID().uuidString, "title": "Raw \(idx)"]
        }
        let rawArrayData = try JSONSerialization.data(withJSONObject: ["entries": fourteenRawEntries])
        let decodedList = try JSONDecoder().decode(RecentlyTriggeredTileList.self, from: rawArrayData)
        XCTAssertEqual(decodedList.count, 8)
        XCTAssertEqual(decodedList.entries.first?.title, "Raw 0")
        XCTAssertEqual(decodedList.entries.last?.title, "Raw 7")

        // Verify each serialized entry contains ONLY `id` and `title` keys
        let singleData = try JSONEncoder().encode(RecentlyTriggeredTileEntry(id: ids[0], title: "Safari"))
        let singleDict = try XCTUnwrap(JSONSerialization.jsonObject(with: singleData) as? [String: Any])
        XCTAssertEqual(Set(singleDict.keys), ["id", "title"])

        // Verify URL query/token secrets are stripped even if someone placed a raw URL as a tile title
        let sanitizedURLTitle = RecentlyTriggeredTileEntry(
            id: UUID(),
            title: "https://internal.example.com/hook?api_key=SUPER_SECRET_KEY_999#token=ABC"
        )
        XCTAssertEqual(sanitizedURLTitle.title, "internal.example.com")
        XCTAssertFalse(sanitizedURLTitle.title.contains("SUPER_SECRET_KEY_999"))
        XCTAssertFalse(sanitizedURLTitle.title.contains("ABC"))

        // CompanionClientEngine integration: clipboard text, snippets, emojis, compact keys, and sleep display
        // are NEVER recorded in `recentlyTriggeredTiles`, and persisted JSON holds only tile id + title.
        let suiteName = "com.choclift.tests.round05.recents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CompanionClientEngine(
            deviceID: "iphone-recents-test",
            deviceName: "iPhone Recents Test",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "r5-recents"
        )

        var profile = client.profile
        let pasteItem = BarItem(kind: .systemAction(action: .pasteClipboard))
        let webSecretItem = BarItem(
            kind: .website(
                url: "https://dashboard.example.com/admin?secret=MY_WEBHOOK_SECRET_42",
                title: "Admin Dashboard",
                emoji: "🔐",
                backgroundHex: "#EDF6FF",
                switchExistingTab: true
            )
        )
        profile.pages[0].slots[0] = pasteItem
        profile.pages[0].slots[1] = webSecretItem
        client.pushUpdatedProfile(profile)

        // Trigger non-tile actions carrying sensitive strings -> must NOT enter recentlyTriggeredTiles
        client.pasteMacClipboard()
        client.insertText("MY_PRIVATE_PASSWORD_SNIPPET_8888")
        client.insertEmoji("🤫")
        client.sendCompactKey(.space)
        client.sleepMacDisplay()
        XCTAssertTrue(client.recentlyTriggeredTiles.isEmpty)

        // Trigger 10 tiles including Paste and Website with secret query parameter -> caps at 8, zero secrets stored
        client.triggerBarItem(pasteItem, from: SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 0))
        client.triggerBarItem(webSecretItem, from: SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 1))
        for idx in 0..<8 {
            let extra = BarItem(kind: .macApp(bundleIdentifier: "com.example.App\(idx)", appName: "App \(idx)"))
            client.triggerBarItem(extra)
        }
        // Re-trigger pasteItem & webSecretItem so they sit at top of the 8-entry list
        client.triggerBarItem(pasteItem, from: SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 0))
        client.triggerBarItem(webSecretItem, from: SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 1))

        XCTAssertEqual(client.recentlyTriggeredTiles.count, 8)
        XCTAssertEqual(client.recentlyTriggeredTiles[0].id, webSecretItem.id)
        XCTAssertEqual(client.recentlyTriggeredTiles[0].title, "Admin Dashboard")
        XCTAssertEqual(client.recentlyTriggeredTiles[1].id, pasteItem.id)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "r5-recents.recentlyTriggeredTiles"))
        let persistedJSONString = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
        XCTAssertFalse(persistedJSONString.contains("MY_WEBHOOK_SECRET_42"))
        XCTAssertFalse(persistedJSONString.contains("MY_PRIVATE_PASSWORD_SNIPPET_8888"))
        XCTAssertFalse(persistedJSONString.contains("dashboard.example.com"))
    }

    // MARK: - 3. Compact Key Row Allowed Keys & Wire Encoding

    func testCompactKeyRowContainsOnlyArrowsEscapeAndSpace() throws {
        XCTAssertEqual(
            CompanionCompactKey.compactRowOrder,
            [.escape, .leftArrow, .upArrow, .downArrow, .rightArrow, .space]
        )
        XCTAssertEqual(Set(CompanionCompactKey.allCases), Set(CompanionCompactKey.compactRowOrder))

        for key in CompanionCompactKey.compactRowOrder {
            let framed = try WireFrameCodec.encode(ClientMessage.sendCompactKey(key))
            let payload = framed.dropFirst(4)
            let decoded = try WireFrameCodec.decodePayload(ClientMessage.self, from: Data(payload))
            XCTAssertEqual(decoded, .sendCompactKey(key))
        }

        let sleepFramed = try WireFrameCodec.encode(ClientMessage.sleepMacDisplay)
        let decodedSleep = try WireFrameCodec.decodePayload(ClientMessage.self, from: Data(sleepFramed.dropFirst(4)))
        XCTAssertEqual(decodedSleep, .sleepMacDisplay)
    }

    // MARK: - 4. Loopback Integration: Sleep Display + Keep Awake Independence, Compact Keys, Pinned Strip, Recents & Unknown Frames

    #if os(macOS)
    @MainActor
    func testRound05LoopbackSleepDisplayKeepAwakeCompactKeysPinsRecentsAndUnknownFramePolicy() async throws {
        let suiteName = "com.choclift.tests.round05.loopback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round05WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r5", macName: "Studio Mac R5")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        // 1. Unknown PRE-AUTH frame MUST still disconnect immediately
        let unauthServerEnd = server.acceptInMemoryCompanion()
        let (unauthProxy, unauthClientEnd) = InMemoryCompanionPipe.pair()
        var receivedPreAuthMessages: [ServerMessage] = []
        var unauthAccumulator = WireStreamAccumulator()
        var unauthClosed = false
        unauthProxy.onPayload = { unauthServerEnd.send($0) }
        unauthServerEnd.onPayload = { unauthProxy.send($0) }
        unauthServerEnd.onClosed = { unauthProxy.cancel() }
        unauthClientEnd.onPayload = { data in
            if let payloads = try? unauthAccumulator.appendAndExtractPayloads(data) {
                for p in payloads {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: p) {
                        receivedPreAuthMessages.append(msg)
                    }
                }
            }
        }
        unauthClientEnd.onClosed = { unauthClosed = true }
        unauthProxy.start()
        unauthServerEnd.start()
        unauthClientEnd.start()

        let unknownClientJSON = Data(#"{"futureRound99ClientCommand":{"x":1}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Pre-auth unknown frame must disconnect immediately")
        XCTAssertTrue(receivedPreAuthMessages.contains(where: {
            if case .authFailed = $0 { return true }
            return false
        }))

        // 2. Pair iPhone over in-memory transport
        let phoneServerEnd = server.acceptInMemoryCompanion()
        let (phoneProxy, phoneClientEnd) = InMemoryCompanionPipe.pair()
        phoneProxy.onPayload = { phoneServerEnd.send($0) }
        phoneServerEnd.onPayload = { phoneProxy.send($0) }
        phoneProxy.start()
        phoneServerEnd.start()

        let phone = CompanionClientEngine(
            deviceID: "iphone-r5",
            deviceName: "iPhone R5",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r5"
        )
        defer { phone.disconnect() }

        phone.connectInMemoryBluetooth(to: phoneClientEnd, targetName: "Studio Mac R5")
        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phone.submitPIN(server.currentPIN)
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        // 3. Turn Keep Mac Awake ON, then tap Sleep Display:
        //    - Display sleep fires once
        //    - Mac is NOT locked
        //    - Keep-awake toggle & assertion remain ON without re-asserting / waking the display
        phone.setKeepMacAwake(true)
        for _ in 0..<50 where !delegate.awakeMachine.shouldHoldAssertion || !phone.controlStripState.isKeepMacAwakeEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(delegate.awakeMachine.isToggleEnabled)
        XCTAssertTrue(delegate.awakeMachine.shouldHoldAssertion)
        XCTAssertTrue(phone.controlStripState.isKeepMacAwakeEnabled)
        let togglesBeforeSleep = delegate.keepAwakeMutationCount

        phone.sleepMacDisplay()
        for _ in 0..<50 where delegate.displaySleepCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.displaySleepCount, 1)
        XCTAssertEqual(delegate.lockScreenCount, 0, "Sleep Display must not lock the Mac")
        XCTAssertTrue(delegate.awakeMachine.isToggleEnabled, "Sleep Display must not change Keep Mac Awake")
        XCTAssertTrue(delegate.awakeMachine.shouldHoldAssertion)
        XCTAssertEqual(delegate.keepAwakeMutationCount, togglesBeforeSleep, "Keep-awake assertion must not be recreated/pulsed on display sleep")
        XCTAssertTrue(phone.controlStripState.isKeepMacAwakeEnabled)

        // 4. Send all 6 compact keys in order -> delivered through input path
        for key in CompanionCompactKey.compactRowOrder {
            phone.sendCompactKey(key)
        }
        for _ in 0..<50 where delegate.receivedCompactKeys.count < CompanionCompactKey.compactRowOrder.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.receivedCompactKeys, CompanionCompactKey.compactRowOrder)

        // 5. Pin 4 tiles on phone, reject 5th, verify sync to Mac, then unpin 1
        let page0 = phone.profile.pages[0]
        var pinnedCoords: [SlotCoordinate] = []
        for slotIdx in 0..<5 {
            if phone.profile.pages[0].slots[slotIdx] == nil {
                var draft = phone.profile
                draft.pages[0].slots[slotIdx] = BarItem(
                    kind: .macApp(bundleIdentifier: "com.example.Pin\(slotIdx)", appName: "Pin \(slotIdx)")
                )
                phone.pushUpdatedProfile(draft)
            }
            pinnedCoords.append(SlotCoordinate(pageID: page0.id, slotIndex: slotIdx))
        }

        XCTAssertTrue(phone.pinSlotToStrip(pinnedCoords[0]))
        XCTAssertTrue(phone.pinSlotToStrip(pinnedCoords[1]))
        XCTAssertTrue(phone.pinSlotToStrip(pinnedCoords[2]))
        XCTAssertTrue(phone.pinSlotToStrip(pinnedCoords[3]))
        XCTAssertFalse(phone.pinSlotToStrip(pinnedCoords[4]))

        for _ in 0..<50 where delegate.profile.activePinnedStripCount != 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.profile.activePinnedStripSlots, Array(pinnedCoords.prefix(4)))

        XCTAssertTrue(phone.unpinSlotFromStrip(pinnedCoords[1]))
        for _ in 0..<50 where delegate.profile.activePinnedStripCount != 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.profile.activePinnedStripSlots, [pinnedCoords[0], pinnedCoords[2], pinnedCoords[3]])

        // 6. Trigger a pinned tile, verify it enters `recentlyTriggeredTiles`, then re-run from recent entry
        let firstPinned = try XCTUnwrap(phone.profile.resolvedPinnedStripSlots().first)
        phone.triggerBarItem(firstPinned.item, from: firstPinned.coordinate)
        for _ in 0..<50 where delegate.triggeredItemIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.triggeredItemIDs, [firstPinned.item.id])
        XCTAssertEqual(phone.recentlyTriggeredTiles.first?.id, firstPinned.item.id)

        // Re-running via `locateBarItem(withID:)` triggers the exact same tile again
        let recentEntry = try XCTUnwrap(phone.recentlyTriggeredTiles.first)
        let located = try XCTUnwrap(phone.profile.locateBarItem(withID: recentEntry.id))
        phone.triggerBarItem(located.item, from: located.coordinate)
        for _ in 0..<50 where delegate.triggeredItemIDs.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.triggeredItemIDs, [firstPinned.item.id, firstPinned.item.id])

        // 7. Unknown POST-AUTH frames stay non-fatal
        phoneClientEnd.send(unknownClientFrame)
        let unknownServerJSON = Data(#"{"futureRound99ServerBroadcast":{"y":2}}"#.utf8)
        var sLen = UInt32(unknownServerJSON.count).bigEndian
        var unknownServerFrame = Data(capacity: 4 + unknownServerJSON.count)
        withUnsafeBytes(of: &sLen) { unknownServerFrame.append(contentsOf: $0) }
        unknownServerFrame.append(unknownServerJSON)
        phoneProxy.send(unknownServerFrame)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frames must remain non-fatal")
        XCTAssertEqual(server.connectedDeviceCount, 1)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class Round05WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var awakeMachine = MacAwakeAssertionStateMachine()
    var keepAwakeMutationCount: Int = 0
    var displaySleepCount: Int = 0
    var lockScreenCount: Int = 0
    var receivedCompactKeys: [CompanionCompactKey] = []
    var triggeredItemIDs: [UUID] = []

    var controlStripState = ControlStripState()

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.apple.Safari" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { nil }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }

    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {
        let connected = Set(devices.filter(\.isCurrentlyConnected).map(\.deviceID))
        let holding = awakeMachine.updateConnectedDevices(connected)
        if controlStripState.isKeepMacAwakeEnabled != holding {
            controlStripState.isKeepMacAwakeEnabled = holding
            server?.broadcastControlStripState(controlStripState)
        }
    }

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(controlStripState))

        case .setKeepMacAwake(let enabled):
            keepAwakeMutationCount += 1
            _ = awakeMachine.deviceConnected(device.deviceID)
            let holding = awakeMachine.setToggleEnabled(enabled)
            controlStripState.isKeepMacAwakeEnabled = holding
            server?.broadcastControlStripState(controlStripState)
            reply(.controlStripStateUpdated(controlStripState))
            reply(.actionFeedback(success: true, title: "Keep Mac Awake", detail: holding ? "On" : "Off"))

        case .sleepMacDisplay:
            displaySleepCount += 1
            reply(.actionFeedback(success: true, title: "Sleep Display", detail: "Display put to sleep"))

        case .sendCompactKey(let key):
            receivedCompactKeys.append(key)
            reply(.actionFeedback(success: true, title: key.title(), detail: "Sent"))

        case .performQuickAction(let action):
            if action == .lockScreen {
                lockScreenCount += 1
            }
            reply(.actionFeedback(success: true, title: action.title(), detail: "OK"))

        case .updateProfile(let updated):
            var sanitized = updated
            sanitized.prunePinnedStripSlots()
            profile = sanitized
            server?.broadcast(.profileUpdated(sanitized), excludingDeviceID: device.deviceID)

        case .triggerBarItem(let item):
            triggeredItemIDs.append(item.id)
            reply(.actionFeedback(success: true, title: item.displayTitle(), detail: "OK"))

        default:
            break
        }
    }
}
#endif
