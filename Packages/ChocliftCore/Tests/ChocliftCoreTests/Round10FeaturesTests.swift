import Foundation
import XCTest
@testable import ChocliftCore

final class Round10FeaturesTests: XCTestCase {

    // MARK: - 1. Tile Folders Cap at 8 Children, 1 Folder Per Page, 8-Page Limit Unchanged

    func testTileFolderCapsAtEightChildrenEnforcesOneFolderPerPageAndKeepsEightPageLimit() throws {
        XCTAssertEqual(TileFolder.maxChildren, 8)
        XCTAssertEqual(TileFolder.maxFoldersPerPage, 1)
        XCTAssertEqual(BarPage.maxPages, 8)

        var folder = TileFolder(title: "Media & Window Tools", emoji: "🗂️")
        for idx in 1...8 {
            let child = BarItem(
                kind: .macApp(
                    bundleIdentifier: "com.example.Child\(idx)",
                    appName: "Child \(idx)"
                )
            )
            XCTAssertTrue(folder.addChild(child), "Child #\(idx) should fit within the 8-child cap")
        }
        XCTAssertEqual(folder.children.count, 8)
        XCTAssertFalse(folder.canAddMoreChildren)

        // 9th child MUST be rejected at the 8-child cap
        let ninthChild = BarItem(
            kind: .macApp(
                bundleIdentifier: "com.example.Child9",
                appName: "Child 9 (Over Cap)"
            )
        )
        XCTAssertFalse(folder.addChild(ninthChild), "9th child must be rejected")
        XCTAssertEqual(folder.children.count, 8)
        XCTAssertFalse(folder.children.contains(where: { $0.id == ninthChild.id }))

        // Nested folders and slot references are never allowed as folder children
        var twoChildFolder = TileFolder(title: "Small", children: Array(folder.children.prefix(2)))
        let nestedFolderItem = BarItem(kind: .folder(TileFolder(title: "Nested")))
        let slotRefItem = BarItem(kind: .slotReference(targetPageID: UUID(), targetSlotIndex: 0))
        XCTAssertFalse(twoChildFolder.addChild(nestedFolderItem))
        XCTAssertFalse(twoChildFolder.addChild(slotRefItem))
        XCTAssertEqual(twoChildFolder.children.count, 2)

        // Initializing with 12 children clamps strictly to 8
        let twelveItems = (1...12).map { idx in
            BarItem(
                kind: .shortcut(
                    shortcutName: "Shortcut \(idx)",
                    emoji: "⚡️",
                    backgroundHex: "#FFF6E3"
                )
            )
        }
        let clampedInitFolder = TileFolder(title: "Clamped", children: twelveItems)
        XCTAssertEqual(clampedInitFolder.children.count, 8)
        XCTAssertEqual(clampedInitFolder.children.first?.displayTitle(in: .english), "Shortcut 1")
        XCTAssertEqual(clampedInitFolder.children.last?.displayTitle(in: .english), "Shortcut 8")

        // Decoding JSON containing >8 children also clamps strictly to 8
        let encodedTwelve = try JSONEncoder().encode(twelveItems)
        let rawChildrenArray = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedTwelve) as? [[String: Any]])
        let oversizedFolderDict: [String: Any] = [
            "title": "Decoded Folder",
            "emoji": "📁",
            "backgroundHex": "#FFF6E3",
            "children": rawChildrenArray
        ]
        let oversizedFolderData = try JSONSerialization.data(withJSONObject: oversizedFolderDict)
        let decodedFolder = try JSONDecoder().decode(TileFolder.self, from: oversizedFolderData)
        XCTAssertEqual(decodedFolder.children.count, 8)

        // Enforce at most 1 folder tile per page without changing the 8-page limit
        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertEqual(profile.pages.count, 8)

        let firstFolderTile = BarItem(kind: .folder(folder))
        let secondFolderTile = BarItem(kind: .folder(TileFolder(title: "Second Folder")))

        XCTAssertTrue(profile.setSlotItem(firstFolderTile, pageIndex: 0, slotIndex: 0))
        XCTAssertEqual(profile.pages[0].folderSlotIndex, 0)
        profile.pages[0].slots[1] = nil
        XCTAssertFalse(
            profile.setSlotItem(secondFolderTile, pageIndex: 0, slotIndex: 1),
            "A page may contain at most one folder tile"
        )
        XCTAssertNil(profile.pages[0].slots[1])

        // Replacing the existing folder in the same slot (or placing a folder on another page) is allowed
        XCTAssertTrue(profile.setSlotItem(secondFolderTile, pageIndex: 0, slotIndex: 0))
        XCTAssertTrue(profile.setSlotItem(firstFolderTile, pageIndex: 1, slotIndex: 3))
        XCTAssertEqual(profile.pages.count, 8, "Folders must not add pages or alter the 8-page limit")
    }

    // MARK: - 2. Hold to Repeat Fires At Most Every 400 ms, Stops on Release, Only Volume Up/Down & Media Next

    func testHoldToRepeatDoesNotFireAgainBefore400MillisecondsStopsOnReleaseAndRepeatsOnlyAllowedActions() {
        XCTAssertEqual(HoldToRepeatPolicy.minimumRepeatIntervalSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(HoldToRepeatPolicy.minimumRepeatIntervalMilliseconds, 400)
        XCTAssertEqual(HoldToRepeatPolicy.repeatableActions, [.volumeUp, .volumeDown, .mediaNext])

        // Only volumeUp, volumeDown, and mediaNext repeat; all other SystemQuickActions must NOT repeat
        for action in SystemQuickAction.allCases {
            let expected = (action == .volumeUp || action == .volumeDown || action == .mediaNext)
            XCTAssertEqual(
                HoldToRepeatPolicy.supportsHoldToRepeat(action),
                expected,
                "Unexpected hold-to-repeat eligibility for \(action.rawValue)"
            )
            XCTAssertEqual(
                BarItem(kind: .systemAction(action: action)).supportsHoldToRepeat(),
                expected
            )
        }

        // Non-system tiles never repeat
        let nonSystemSafari = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        let nonSystemShortcut = BarItem(kind: .shortcut(shortcutName: "Focus", emoji: "🎯", backgroundHex: "#FFF6E3"))
        let nonSystemFolder = BarItem(kind: .folder(TileFolder(title: "Tools")))
        XCTAssertFalse(nonSystemSafari.supportsHoldToRepeat())
        XCTAssertFalse(nonSystemShortcut.supportsHoldToRepeat())
        XCTAssertFalse(nonSystemFolder.supportsHoldToRepeat())

        var nonRepeatableController = HoldToRepeatController()
        XCTAssertFalse(nonRepeatableController.beginHold(for: .mediaPlayPause, at: 10.0))
        XCTAssertFalse(nonRepeatableController.isHolding)
        XCTAssertFalse(nonRepeatableController.shouldFireRepeat(at: 10.5))

        // Verify strict 400 ms minimum interval and immediate stop on release for all 3 repeatable actions
        for repeatable in [SystemQuickAction.volumeUp, .volumeDown, .mediaNext] {
            var controller = HoldToRepeatController()
            XCTAssertTrue(controller.beginHold(for: repeatable, at: 100.000))
            XCTAssertTrue(controller.isHolding)
            XCTAssertEqual(controller.fireCount, 1)

            // Must NOT fire again before 400 ms (0.400s)
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.000))
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.120))
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.250))
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.399))
            XCTAssertEqual(controller.fireCount, 1)

            // Fires at 400 ms
            XCTAssertTrue(controller.shouldFireRepeat(at: 100.400))
            XCTAssertEqual(controller.fireCount, 2)

            // Again must NOT fire before another 400 ms elapses
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.550))
            XCTAssertFalse(controller.shouldFireRepeat(at: 100.799))
            XCTAssertTrue(controller.shouldFireRepeat(at: 100.805))
            XCTAssertEqual(controller.fireCount, 3)

            // Releasing the finger stops repeating immediately
            controller.endHold()
            XCTAssertFalse(controller.isHolding)
            XCTAssertFalse(controller.shouldFireRepeat(at: 101.500))
            XCTAssertEqual(controller.fireCount, 3)
        }
    }

    // MARK: - 3. Reorder Pages Keeps App-Deck Bindings & Follower on the Same Page ID

    @MainActor
    func testPageReorderLeftAndRightKeepsAppDeckBindingsAndFollowerOnSamePageID() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let dailyPageID = profile.pages[0].id
        let codingPageID = profile.pages[1].id
        let browserPageID = profile.pages[2].id

        // Place an identifiable tile on Coding page and pin + reference it
        let buildTile = BarItem(kind: .shortcut(shortcutName: "Run Build", emoji: "🔨", backgroundHex: "#FFF6E3"))
        profile.pages[1].slots[2] = buildTile
        XCTAssertTrue(profile.pinSlotToStrip(SlotCoordinate(pageID: codingPageID, slotIndex: 2)))
        let refTile = BarItem(kind: .slotReference(targetPageID: codingPageID, targetSlotIndex: 2))
        profile.pages[0].slots[7] = refTile

        // Bind Xcode -> codingPageID (originally index 1) and Safari -> browserPageID (originally index 2)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: codingPageID)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: browserPageID)
        XCTAssertEqual(profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode")?.id, codingPageID)
        XCTAssertEqual(profile.pages.firstIndex(where: { $0.id == codingPageID }), 1)

        var follower = AppDeckFollowerState()
        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, codingPageID)

        // Boundary guards: first page cannot move left; last page cannot move right
        XCTAssertFalse(profile.canMovePage(at: 0, direction: .left))
        XCTAssertNil(profile.movePage(at: 0, direction: .left))
        XCTAssertFalse(profile.canMovePage(at: profile.pages.count - 1, direction: .right))
        XCTAssertNil(profile.movePage(at: profile.pages.count - 1, direction: .right))

        // Move Coding page RIGHT twice (index 1 -> 2 -> 3)
        XCTAssertEqual(profile.movePage(at: 1, direction: .right), 2)
        XCTAssertEqual(profile.movePage(withID: codingPageID, direction: .right), 3)

        // Verify page.index values stay contiguous 0..<8 while page IDs moved
        XCTAssertEqual(profile.pages.map(\.index), Array(0..<8))
        XCTAssertEqual(profile.pages[0].id, dailyPageID)
        XCTAssertEqual(profile.pages[1].id, browserPageID)
        XCTAssertEqual(profile.pages[3].id, codingPageID)

        // App-aware bindings MUST follow the page ID (now at index 3), NOT the old index 1!
        let xcodeBound = try XCTUnwrap(profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode"))
        XCTAssertEqual(xcodeBound.id, codingPageID)
        XCTAssertEqual(xcodeBound.index, 3)

        let safariBound = try XCTUnwrap(profile.boundPage(forBundleIdentifier: "com.apple.Safari"))
        XCTAssertEqual(safariBound.id, browserPageID)
        XCTAssertEqual(safariBound.index, 1)

        // AppDeckFollowerState follows codingPageID to index 3
        follower.handleProfileUpdated(profile, frontmostBundleIdentifier: "com.apple.dt.Xcode")
        XCTAssertEqual(follower.currentPageIndex, 3)
        XCTAssertEqual(follower.currentPageID, codingPageID)

        // Move Coding page LEFT all the way to index 0 (3 -> 2 -> 1 -> 0)
        XCTAssertEqual(profile.movePage(withID: codingPageID, direction: .left), 2)
        XCTAssertEqual(profile.movePage(withID: codingPageID, direction: .left), 1)
        XCTAssertEqual(profile.movePage(withID: codingPageID, direction: .left), 0)
        XCTAssertEqual(profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode")?.id, codingPageID)
        XCTAssertEqual(profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode")?.index, 0)

        follower.handleProfileUpdated(profile, frontmostBundleIdentifier: "com.apple.dt.Xcode")
        XCTAssertEqual(follower.currentPageIndex, 0)
        XCTAssertEqual(follower.currentPageID, codingPageID)

        // Pinned strip slot and slotReference also follow codingPageID cleanly
        let resolvedPins = profile.resolvedPinnedStripSlots()
        XCTAssertEqual(resolvedPins.first?.pageIndex, 0)
        XCTAssertEqual(resolvedPins.first?.item.id, buildTile.id)
        XCTAssertEqual(profile.resolveBarItem(refTile).resolvedItem?.id, buildTile.id)
    }

    // MARK: - 4. Quiet Hours for Haptics (Default Off, Same-Day & Overnight Local Windows)

    @MainActor
    func testQuietHoursForHapticsDefaultOffMutesOutcomeHapticsBetweenLocalTimes() throws {
        XCTAssertFalse(HapticQuietHoursSettings.disabled.isEnabled, "Quiet hours must default to off")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))

        func localDate(hour: Int, minute: Int) -> Date {
            let comps = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 11,
                day: 14,
                hour: hour,
                minute: minute,
                second: 0
            )
            return calendar.date(from: comps)!
        }

        // Disabled -> never mutes outcome haptics when haptics are enabled
        let disabled = HapticQuietHoursSettings.disabled
        XCTAssertFalse(disabled.isQuietTime(at: localDate(hour: 23, minute: 30), calendar: calendar))
        XCTAssertTrue(
            disabled.shouldPlayOutcomeHaptics(
                hapticFeedbackEnabled: true,
                at: localDate(hour: 23, minute: 30),
                calendar: calendar
            )
        )

        // Overnight window: 22:00 (1320) -> 07:00 (420)
        let overnight = HapticQuietHoursSettings(
            isEnabled: true,
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 7 * 60
        )
        XCTAssertTrue(overnight.isQuietTime(at: localDate(hour: 22, minute: 0), calendar: calendar))
        XCTAssertTrue(overnight.isQuietTime(at: localDate(hour: 1, minute: 15), calendar: calendar))
        XCTAssertTrue(overnight.isQuietTime(at: localDate(hour: 6, minute: 59), calendar: calendar))
        XCTAssertFalse(overnight.isQuietTime(at: localDate(hour: 7, minute: 0), calendar: calendar))
        XCTAssertFalse(overnight.isQuietTime(at: localDate(hour: 21, minute: 59), calendar: calendar))

        XCTAssertFalse(
            overnight.shouldPlayOutcomeHaptics(
                hapticFeedbackEnabled: true,
                at: localDate(hour: 23, minute: 0),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            overnight.shouldPlayOutcomeHaptics(
                hapticFeedbackEnabled: true,
                at: localDate(hour: 12, minute: 0),
                calendar: calendar
            )
        )

        // Same-day window: 13:00 (780) -> 14:30 (870)
        let midday = HapticQuietHoursSettings(
            isEnabled: true,
            startMinuteOfDay: 13 * 60,
            endMinuteOfDay: 14 * 60 + 30
        )
        XCTAssertFalse(midday.isQuietTime(at: localDate(hour: 12, minute: 59), calendar: calendar))
        XCTAssertTrue(midday.isQuietTime(at: localDate(hour: 13, minute: 0), calendar: calendar))
        XCTAssertTrue(midday.isQuietTime(at: localDate(hour: 14, minute: 29), calendar: calendar))
        XCTAssertFalse(midday.isQuietTime(at: localDate(hour: 14, minute: 30), calendar: calendar))

        // CompanionClientEngine defaults off and persists setting across launches
        let suiteName = "com.choclift.tests.round10.quiet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client1 = CompanionClientEngine(
            deviceID: "iphone-quiet-1",
            deviceName: "iPhone Quiet",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "r10-quiet"
        )
        XCTAssertFalse(client1.hapticQuietHours.isEnabled)
        client1.setHapticQuietHours(overnight)
        XCTAssertFalse(client1.shouldPlayOutcomeHaptics(at: localDate(hour: 2, minute: 0), calendar: calendar))
        XCTAssertTrue(client1.shouldPlayOutcomeHaptics(at: localDate(hour: 10, minute: 0), calendar: calendar))

        let client2 = CompanionClientEngine(
            deviceID: "iphone-quiet-1",
            deviceName: "iPhone Quiet",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "r10-quiet"
        )
        XCTAssertEqual(client2.hapticQuietHours, overnight)
    }

    // MARK: - 5. Last Triggered Time Uses Existing Recent List & Never Stores Clipboard Text

    @MainActor
    func testLastTriggeredTimeFormatsCompactAgeFromExistingRecentListAndNeverStoresClipboardText() throws {
        let t0 = Date(timeIntervalSince1970: 1_730_000_000)
        XCTAssertNil(LastTriggeredTimeFormatter.compactRelativeString(since: nil, now: t0))
        XCTAssertEqual(LastTriggeredTimeFormatter.compactRelativeString(since: t0, now: t0.addingTimeInterval(4)), "now")
        XCTAssertEqual(LastTriggeredTimeFormatter.compactRelativeString(since: t0, now: t0.addingTimeInterval(25)), "25s")
        XCTAssertEqual(LastTriggeredTimeFormatter.compactRelativeString(since: t0, now: t0.addingTimeInterval(120)), "2m")
        XCTAssertEqual(LastTriggeredTimeFormatter.compactRelativeString(since: t0, now: t0.addingTimeInterval(3 * 3600)), "3h")
        XCTAssertEqual(LastTriggeredTimeFormatter.compactRelativeString(since: t0, now: t0.addingTimeInterval(2 * 86_400)), "2d")

        let suiteName = "com.choclift.tests.round10.lasttrig.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CompanionClientEngine(
            deviceID: "iphone-last-trig",
            deviceName: "iPhone Last Triggered",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "r10-lasttrig"
        )

        let safariTile = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        var profile = client.profile
        profile.pages[0].slots[0] = safariTile
        client.pushUpdatedProfile(profile)

        XCTAssertNil(client.lastTriggeredText(for: safariTile, now: t0.addingTimeInterval(120)))

        // Trigger Safari at t0 -> at t0 + 120s tile shows "2m"
        let origin = SlotCoordinate(pageID: profile.pages[0].id, slotIndex: 0)
        client.triggerBarItem(safariTile, from: origin, triggeredAt: t0)
        XCTAssertEqual(client.lastTriggeredText(for: safariTile, from: origin, now: t0.addingTimeInterval(120)), "2m")

        // Clipboard actions and text insertions MUST NEVER store clipboard text in recentlyTriggeredTiles
        client.pasteMacClipboard()
        client.insertText("TOP_SECRET_CLIPBOARD_TOKEN_999")
        _ = client.insertSnippet("ANOTHER_CLIPBOARD_SECRET_777", mode: .focusedFieldInsert)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "r10-lasttrig.recentlyTriggeredTiles"))
        let persistedJSON = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
        XCTAssertFalse(persistedJSON.contains("TOP_SECRET_CLIPBOARD_TOKEN_999"))
        XCTAssertFalse(persistedJSON.contains("ANOTHER_CLIPBOARD_SECRET_777"))
        XCTAssertEqual(client.recentlyTriggeredTiles.count, 1)
        XCTAssertEqual(client.recentlyTriggeredTiles.first?.id, safariTile.id)
    }

    // MARK: - 6. End-to-End Loopback Wire Verification (All 5 Round 10 Features + Unknown Frame Safety)

    #if os(macOS)
    @MainActor
    func testLoopbackRound10FoldersPageReorderQuietHoursMacActionExecutionAndUnknownFrames() async throws {
        let suiteName = "com.choclift.tests.round10.wire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round10WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r10-host", macName: "Studio Mac R10")
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

        let unknownClientJSON = Data(#"{"futureRound210ClientCommand":{"flag":true}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Unknown pre-auth frame must disconnect immediately")

        // 2. Pair and connect iPhone companion
        let phone = CompanionClientEngine(
            deviceID: "iphone-r10",
            deviceName: "iPhone R10",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r10"
        )
        defer { phone.disconnect() }

        let btHost = DiscoveredBluetoothMac(id: UUID(), name: "Studio Mac R10", macID: "mac-r10-host")
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

        // 3. Configure a folder with 8 child actions & bind Xcode to Page 1
        var updated = phone.profile
        let boundPageID = updated.pages[1].id
        updated.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: boundPageID)

        let children = (1...8).map { idx in
            BarItem(kind: .shortcut(shortcutName: "Folder Action \(idx)", emoji: "⚡️", backgroundHex: "#FFF6E3"))
        }
        let folderItem = BarItem(kind: .folder(TileFolder(title: "Dev Folder", emoji: "🧰", children: children)))
        XCTAssertTrue(updated.setSlotItem(folderItem, pageIndex: 1, slotIndex: 0))
        phone.pushUpdatedProfile(updated)

        for _ in 0..<50 where delegate.profile.pages[1].folderSlotIndex != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.profile.pages.count, 8)
        XCTAssertEqual(delegate.profile.pages[1].folderSlotIndex, 0)

        // 4. Enable quiet hours covering current local time: haptics mute, but Mac actions STILL run!
        let nowMin = HapticQuietHoursSettings.minuteOfDay(from: Date())
        phone.setHapticQuietHours(
            HapticQuietHoursSettings(isEnabled: true, startMinuteOfDay: nowMin - 60, endMinuteOfDay: nowMin + 60)
        )
        XCTAssertFalse(phone.shouldPlayOutcomeHaptics())

        let runTimestamp = Date(timeIntervalSince1970: 1_730_000_000)
        let folderOrigin = SlotCoordinate(pageID: boundPageID, slotIndex: 0)

        // Calling triggerBarItem on the folder itself does not send `.folder` to Mac
        phone.triggerBarItem(folderItem, from: folderOrigin, triggeredAt: runTimestamp)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(delegate.triggeredItemIDs.isEmpty)

        // Tapping child #1 inside the folder runs it on the Mac even during quiet hours, and records lastTriggeredAt
        phone.triggerBarItem(children[0], from: folderOrigin, triggeredAt: runTimestamp)
        for _ in 0..<50 where delegate.triggeredItemIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.triggeredItemIDs, [children[0].id])
        XCTAssertEqual(
            phone.lastTriggeredText(for: children[0], now: runTimestamp.addingTimeInterval(120)),
            "2m"
        )
        XCTAssertEqual(
            phone.lastTriggeredText(for: folderItem, from: folderOrigin, now: runTimestamp.addingTimeInterval(120)),
            "2m"
        )

        // 5. Reorder Page 1 right -> Page 2; verify Mac receives reorder and Xcode binding stays on boundPageID
        XCTAssertEqual(phone.movePage(at: 1, direction: .right), 2)
        for _ in 0..<50 where delegate.profile.pages[2].id != boundPageID {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode")?.id, boundPageID)
        XCTAssertEqual(delegate.profile.boundPage(forBundleIdentifier: "com.apple.dt.Xcode")?.index, 2)

        // 6. Unknown POST-AUTH frames stay non-fatal in both directions
        latestClientPipeEnd?.send(unknownClientFrame)
        let unknownServerJSON = Data(#"{"futureRound210ServerEvent":{"info":1}}"#.utf8)
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
private final class Round10WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var triggeredItemIDs: [UUID] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.apple.dt.Xcode" }
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
        case .updateProfile(let incoming):
            profile = incoming
            server?.broadcast(.profileUpdated(profile))

        case .triggerBarItem(let item):
            triggeredItemIDs.append(item.id)
            reply(.actionFeedback(success: true, title: item.displayTitle(in: .english), detail: "Ran"))

        default:
            break
        }
    }
}
#endif
