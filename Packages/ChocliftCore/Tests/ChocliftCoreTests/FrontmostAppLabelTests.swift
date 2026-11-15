import XCTest
@testable import ChocliftCore

final class FrontmostAppLabelTests: XCTestCase {
    func testReturnsNilForNilEmptyAndWhitespaceNames() {
        XCTAssertNil(FrontmostAppLabel.format(appName: nil, bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "", bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "   ", bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "\n\t  \r\n", bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(FrontmostAppLabel.format(appName: nil, bundleIdentifier: nil))
    }

    func testReturnsNilForChocliftBundleIdentifiers() {
        XCTAssertNil(FrontmostAppLabel.format(appName: "Choclift", bundleIdentifier: "com.choclift.mac"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "choclift", bundleIdentifier: "com.choclift.ios"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "ChocliftWatch", bundleIdentifier: "com.choclift.ios.watchkitapp"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "Companion", bundleIdentifier: "com.choclift.companion"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "Choclift", bundleIdentifier: "com.choclift"))
        XCTAssertNil(FrontmostAppLabel.format(appName: "Choclift", bundleIdentifier: "  COM.CHOCLIFT.MAC  "))
        XCTAssertNil(
            FrontmostAppLabel.format(
                appName: "Custom Host",
                bundleIdentifier: "dev.local.choclift-host",
                hostBundleIdentifier: "dev.local.choclift-host"
            )
        )
        XCTAssertNil(FrontmostAppLabel.format(appName: "Choclift", bundleIdentifier: nil))
        XCTAssertNil(FrontmostAppLabel.format(appName: "  choclift  ", bundleIdentifier: ""))
    }

    func testTrimsAndCapsNonChocliftNamesAtFortyCharacters() {
        XCTAssertEqual(
            FrontmostAppLabel.format(appName: "  Safari \n", bundleIdentifier: "com.apple.Safari"),
            "Safari"
        )

        let exactForty = String(repeating: "A", count: 40)
        XCTAssertEqual(
            FrontmostAppLabel.format(appName: "  \(exactForty)  ", bundleIdentifier: "com.apple.dt.Xcode"),
            exactForty
        )

        let fiftyFive = "1234567890123456789012345678901234567890ABCDEFGHIJKLMNO"
        let formatted = FrontmostAppLabel.format(
            appName: "   \(fiftyFive)   ",
            bundleIdentifier: "com.microsoft.VSCode"
        )
        XCTAssertEqual(formatted, "1234567890123456789012345678901234567890")
        XCTAssertEqual(formatted?.count, 40)
    }

    func testControlStripStateDecodeIfPresentAndSanitization() throws {
        let legacyData = Data(#"{"volume":0.5,"brightness":0.75}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ControlStripState.self, from: legacyData)
        XCTAssertNil(decodedLegacy.frontmostAppName)

        let chocliftState = ControlStripState(frontmostAppName: "Choclift")
        XCTAssertNil(chocliftState.frontmostAppName)

        let longName = String(repeating: "Z", count: 52)
        let encoded = try JSONEncoder().encode(ControlStripState(frontmostAppName: "  \(longName)  "))
        let decoded = try JSONDecoder().decode(ControlStripState.self, from: encoded)
        XCTAssertEqual(decoded.frontmostAppName, String(repeating: "Z", count: 40))
    }

    #if os(macOS)
    @MainActor
    func testPhoneAndWatchFrontmostAppLabelTracksLiveFrontmostChanges() async throws {
        let suiteName = "com.choclift.tests.frontmostlabel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = FrontmostLabelWireTestDelegate()
        let server = MacServerEngine(macID: "mac-frontmost-host", macName: "Frontmost Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-frontmost",
            deviceName: "iPhone Frontmost",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-frontmost"
        )
        let watch = CompanionClientEngine(
            deviceID: "watch-frontmost",
            deviceName: "Watch Frontmost",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch-frontmost"
        )
        defer {
            phone.disconnect()
            watch.disconnect()
        }

        let btHost = DiscoveredBluetoothMac(id: UUID(), name: "Frontmost Mac", macID: "mac-frontmost-host")
        var retainedPipes: [AnyObject] = []
        let makeConnector: () -> CompanionFrameTransport = {
            let serverEnd = server.acceptInMemoryCompanion()
            let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
            proxy.onPayload = { serverEnd.send($0) }
            serverEnd.onPayload = { proxy.send($0) }
            serverEnd.onClosed = { proxy.cancel() }
            proxy.start()
            serverEnd.start()
            retainedPipes.append(proxy)
            retainedPipes.append(clientEnd)
            return clientEnd
        }

        phone.simulatedBluetoothConnector = { _ in makeConnector() }
        watch.simulatedBluetoothConnector = { _ in makeConnector() }

        for companion in [phone, watch] {
            companion.simulateDiscoveredBluetoothMacs([btHost])
            companion.connectBluetooth(to: btHost)
            for _ in 0..<50 {
                if case .awaitingPIN = companion.connectionState { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            companion.submitPIN(server.currentPIN)
            for _ in 0..<50 where !companion.connectionState.isConnected {
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTAssertTrue(companion.connectionState.isConnected)
        }

        // Initial connect with Choclift frontmost shows nothing extra
        XCTAssertNil(phone.activeFrontmostAppLabel)
        XCTAssertNil(watch.activeFrontmostAppLabel)

        // Switching to Safari updates both phone and Watch
        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.apple.Safari", appName: "  Safari  "))
        for _ in 0..<50 where phone.activeFrontmostAppLabel != "Safari" || watch.activeFrontmostAppLabel != "Safari" {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(phone.activeFrontmostAppLabel, "Safari")
        XCTAssertEqual(watch.activeFrontmostAppLabel, "Safari")

        // Long external app name caps at 40 characters
        let longApp = String(repeating: "M", count: 48)
        let expectedCapped = String(repeating: "M", count: 40)
        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.example.long", appName: longApp))
        for _ in 0..<50 where phone.activeFrontmostAppLabel != expectedCapped || watch.activeFrontmostAppLabel != expectedCapped {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(phone.activeFrontmostAppLabel, expectedCapped)
        XCTAssertEqual(watch.activeFrontmostAppLabel, expectedCapped)

        // Switching back to Choclift hides the label on both surfaces
        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.choclift.mac", appName: "Choclift"))
        for _ in 0..<50 where phone.activeFrontmostAppLabel != nil || watch.activeFrontmostAppLabel != nil {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertNil(phone.activeFrontmostAppLabel)
        XCTAssertNil(watch.activeFrontmostAppLabel)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class FrontmostLabelWireTestDelegate: MacServerEngineDelegate {
    private let profile = ChocliftDefaults.makeDefaultProfile()

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.choclift.mac" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        if case .requestControlStripState = message {
            reply(.controlStripStateUpdated(ControlStripState(frontmostAppName: nil)))
        }
    }
}
#endif
