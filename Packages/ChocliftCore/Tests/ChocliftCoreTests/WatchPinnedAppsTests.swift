import XCTest
@testable import ChocliftCore

final class WatchPinnedAppsTests: XCTestCase {
    func testSanitizeCapsAtFourAndPreservesOrder() {
        let input = [
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.apple.dt.Xcode",
            "com.apple.Music",
            "com.apple.Notes",
            "com.apple.finder"
        ]
        let sanitized = WatchPinnedApps.sanitize(input)
        XCTAssertEqual(
            sanitized,
            [
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.apple.dt.Xcode",
                "com.apple.Music"
            ]
        )
    }

    func testSanitizeDeduplicatesCaseInsensitivelyKeepingFirstOrder() {
        let input = [
            "  com.apple.Safari ",
            "com.apple.Terminal",
            "COM.APPLE.SAFARI",
            "com.apple.terminal",
            "com.apple.Music"
        ]
        let sanitized = WatchPinnedApps.sanitize(input)
        XCTAssertEqual(
            sanitized,
            [
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.apple.Music"
            ]
        )
    }

    func testSanitizeRejectsChocliftAndEmptyEntries() {
        let input = [
            "",
            "   ",
            "com.choclift",
            "com.choclift.mac",
            "com.choclift.ios",
            "com.choclift.ios.watchkitapp",
            "  COM.CHOCLIFT.MAC  ",
            "com.apple.Safari",
            "com.apple.Notes"
        ]
        XCTAssertTrue(WatchPinnedApps.isChocliftBundleIdentifier("com.choclift"))
        XCTAssertTrue(WatchPinnedApps.isChocliftBundleIdentifier("com.choclift.mac"))
        XCTAssertTrue(WatchPinnedApps.isChocliftBundleIdentifier("COM.CHOCLIFT.IOS.WATCHKITAPP"))
        XCTAssertFalse(WatchPinnedApps.isChocliftBundleIdentifier("com.apple.Safari"))

        let sanitized = WatchPinnedApps.sanitize(input)
        XCTAssertEqual(sanitized, ["com.apple.Safari", "com.apple.Notes"])
    }

    func testWorkspaceProfileSanitizesWatchPinnedAppsOnInitAndSet() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertEqual(profile.watchPinnedBundleIDs, [])

        profile.watchPinnedBundleIDs = [
            "com.choclift.mac",
            "com.apple.finder",
            "",
            "COM.APPLE.FINDER",
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.apple.Music",
            "com.apple.Notes"
        ]
        XCTAssertEqual(
            profile.watchPinnedBundleIDs,
            [
                "com.apple.finder",
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.apple.Music"
            ]
        )

        // Appending a 5th or Choclift item also runs through the setter sanitizer
        profile.watchPinnedBundleIDs.append("com.apple.Notes")
        XCTAssertEqual(profile.watchPinnedBundleIDs.count, 4)
        XCTAssertFalse(profile.watchPinnedBundleIDs.contains("com.apple.Notes"))

        profile.watchPinnedBundleIDs = ["com.choclift.mac"]
        XCTAssertEqual(profile.watchPinnedBundleIDs, [])

        let initialized = ChocliftWorkspaceProfile(
            pages: profile.pages,
            emojiSlides: profile.emojiSlides,
            gestureConfig: profile.gestureConfig,
            watchPinnedBundleIDs: ["com.choclift.mac", "com.apple.Safari", "com.apple.Safari"]
        )
        XCTAssertEqual(initialized.watchPinnedBundleIDs, ["com.apple.Safari"])
        XCTAssertTrue(initialized.referencedAppBundleIdentifiers.contains("com.apple.Safari"))
    }

    func testOldProfileJSONWithoutWatchPinnedBundleIDsDecodesToEmpty() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        profile.watchPinnedBundleIDs = ["com.apple.Safari", "com.apple.Terminal"]

        let encoded = try JSONEncoder().encode(profile)
        var rawJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(rawJSON["watchPinnedBundleIDs"])

        // Simulate a pre-10.6 profile on disk/wire with no `watchPinnedBundleIDs` key.
        rawJSON.removeValue(forKey: "watchPinnedBundleIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: rawJSON)

        let decodedLegacy = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertEqual(decodedLegacy.watchPinnedBundleIDs, [])

        // Corrupted or oversized raw JSON array is sanitized on decode as well.
        rawJSON["watchPinnedBundleIDs"] = [
            "com.choclift.mac",
            "",
            "com.apple.Safari",
            "COM.APPLE.SAFARI",
            "com.apple.Terminal",
            "com.apple.dt.Xcode",
            "com.apple.Music",
            "com.apple.Notes"
        ]
        let dirtyData = try JSONSerialization.data(withJSONObject: rawJSON)
        let decodedDirty = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: dirtyData)
        XCTAssertEqual(
            decodedDirty.watchPinnedBundleIDs,
            [
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.apple.dt.Xcode",
                "com.apple.Music"
            ]
        )
    }

    func testCandidateAppsReusesClientNamesAndExcludesChocliftAndExistingPins() {
        let profile = ChocliftDefaults.makeDefaultProfile()
        let catalog = [
            InstalledAppSummary(bundleIdentifier: "com.choclift.mac", appName: "Choclift", appPath: "/Applications/Choclift.app"),
            InstalledAppSummary(bundleIdentifier: "com.apple.Safari", appName: "Safari", appPath: "/Applications/Safari.app"),
            InstalledAppSummary(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", appPath: "/Applications/Xcode.app")
        ]
        let recent = [
            RecentAppEntry(bundleIdentifier: "com.choclift.ios", appName: "Choclift iOS"),
            RecentAppEntry(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", appPath: "/System/Applications/Utilities/Terminal.app")
        ]

        let candidates = WatchPinnedApps.candidateApps(
            catalogApps: catalog,
            recentApps: recent,
            profile: profile,
            excludingBundleIDs: ["com.apple.Safari"]
        )
        XCTAssertFalse(candidates.contains { WatchPinnedApps.isChocliftBundleIdentifier($0.bundleIdentifier) })
        XCTAssertFalse(candidates.contains { $0.bundleIdentifier == "com.apple.Safari" })
        XCTAssertTrue(candidates.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" && $0.appName == "Xcode" })
        XCTAssertTrue(candidates.contains { $0.bundleIdentifier == "com.apple.Terminal" && $0.appName == "Terminal" })
    }

    func testWireRoundTripAndLoopbackDelivery() async throws {
        let msg = ClientMessage.setWatchPinnedApps(bundleIDs: ["com.apple.Safari", "com.apple.Terminal"])
        let framed = try WireFrameCodec.encode(msg)
        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(framed)
        XCTAssertEqual(payloads.count, 1)
        let decoded = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        XCTAssertEqual(decoded, msg)

        #if os(macOS)
        await assertServerAuthAndWatchSync()
        #endif
    }

    #if os(macOS)
    @MainActor
    private func assertServerAuthAndWatchSync() async {
        let suiteName = "com.choclift.tests.watch-pinned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = WatchPinnedAppsWireTestDelegate()
        let server = MacServerEngine(macID: "mac-watchpin", macName: "WatchPin Mac")
        server.delegate = delegate
        delegate.serverRef = server
        defer { server.stop() }

        // 1. Pre-auth frame must NOT be swallowed silently; server must reply with pairingRequired
        //    and never forward unauthenticated setWatchPinnedApps to the delegate.
        let unauthClient = server.acceptInMemoryCompanion()
        var unauthReplies: [ServerMessage] = []
        unauthClient.onPayload = { data in
            var acc = WireStreamAccumulator()
            if let payloads = try? acc.appendAndExtractPayloads(data) {
                for p in payloads {
                    if let decoded = try? WireFrameCodec.decodePayload(ServerMessage.self, from: p) {
                        unauthReplies.append(decoded)
                    }
                }
            }
        }
        unauthClient.start()
        if let framedPayload = try? WireFrameCodec.encode(ClientMessage.setWatchPinnedApps(bundleIDs: ["com.apple.Safari"])) {
            unauthClient.send(framedPayload)
        }
        for _ in 0..<40 where unauthReplies.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(delegate.receivedMessages.isEmpty)
        XCTAssertEqual(unauthReplies, [.pairingRequired(macID: "mac-watchpin", macName: "WatchPin Mac")])
        unauthClient.cancel()

        // 2. Pair iPhone and Apple Watch over in-memory loopback; edit from iPhone -> verify Watch receives profileUpdated
        //    and tapping on Watch sends activateRecentApp.
        let phone = CompanionClientEngine(
            deviceID: "iphone-watchpin",
            deviceName: "iPhone WatchPin",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "phone"
        )
        let watch = CompanionClientEngine(
            deviceID: "watch-watchpin",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch"
        )
        defer {
            phone.disconnect()
            watch.disconnect()
        }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "WatchPin Mac", macID: "mac-watchpin")
        for client in [phone, watch] {
            client.simulatedBluetoothConnector = { _ in
                let serverEnd = server.acceptInMemoryCompanion()
                let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
                proxy.onPayload = { serverEnd.send($0) }
                serverEnd.onPayload = { proxy.send($0) }
                serverEnd.onClosed = { proxy.cancel() }
                proxy.start()
                serverEnd.start()
                return clientEnd
            }
            client.simulateDiscoveredBluetoothMacs([host])
            client.connectBluetooth(to: host)
            for _ in 0..<60 {
                if case .awaitingPIN = client.connectionState { break }
                await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
            }
            client.submitPIN(server.currentPIN)
            for _ in 0..<60 where !client.connectionState.isConnected {
                await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
            }
            XCTAssertTrue(client.connectionState.isConnected)
        }

        // Choclift-only pin attempt rejected client-side
        XCTAssertFalse(phone.setWatchPinnedApps(["com.choclift.mac"]))

        // Valid edit from iPhone sanitizes and reaches MacServerEngineDelegate, which broadcasts profileUpdated
        XCTAssertTrue(
            phone.setWatchPinnedApps([
                "com.choclift.mac",
                "com.apple.Safari",
                "com.apple.Terminal",
                "COM.APPLE.SAFARI"
            ])
        )
        for _ in 0..<60 where watch.profile.watchPinnedBundleIDs != ["com.apple.Safari", "com.apple.Terminal"] {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(watch.profile.watchPinnedBundleIDs, ["com.apple.Safari", "com.apple.Terminal"])
        XCTAssertEqual(phone.profile.watchPinnedBundleIDs, ["com.apple.Safari", "com.apple.Terminal"])

        // Tapping a pinned app on Watch sends the existing launch/activate message
        XCTAssertTrue(watch.activateMacApp(bundleIdentifier: "com.apple.Safari"))
        for _ in 0..<60 where !delegate.receivedMessages.contains(.activateRecentApp(bundleIdentifier: "com.apple.Safari", appPath: nil)) {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertTrue(
            delegate.receivedMessages.contains(.activateRecentApp(bundleIdentifier: "com.apple.Safari", appPath: nil))
        )
    }
    #endif
}

#if os(macOS)
@MainActor
private final class WatchPinnedAppsWireTestDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var receivedMessages: [ClientMessage] = []
    weak var serverRef: MacServerEngine?

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
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
        receivedMessages.append(message)
        switch message {
        case .setWatchPinnedApps(let bundleIDs):
            profile.watchPinnedBundleIDs = WatchPinnedApps.sanitize(bundleIDs)
            profile.bumpRevision()
            serverRef?.broadcast(.profileUpdated(profile))
            reply(.actionFeedback(success: true, title: "Watch Pinned Apps", detail: nil))
        case .activateRecentApp:
            reply(.actionFeedback(success: true, title: "Safari", detail: nil))
        default:
            break
        }
    }
}
#endif
