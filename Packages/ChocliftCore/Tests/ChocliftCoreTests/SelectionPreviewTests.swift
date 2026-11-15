import XCTest
@testable import ChocliftCore

final class SelectionPreviewTests: XCTestCase {
    func testClampRejectsNilEmptyAndWhitespaceOnlyInputs() {
        XCTAssertNil(SelectionPreviewText.clamp(nil))
        XCTAssertNil(SelectionPreviewText.clamp(""))
        XCTAssertNil(SelectionPreviewText.clamp("   "))
        XCTAssertNil(SelectionPreviewText.clamp("\n\t  \r\n "))
        let leadingSpacesThenTail = String(repeating: " ", count: 405) + "tail"
        XCTAssertNil(SelectionPreviewText.clamp(leadingSpacesThenTail))
    }

    func testClampPreservesUpToFourHundredCharactersAndCapsLongerText() {
        let short = "Hello from Mac AX selection"
        XCTAssertEqual(SelectionPreviewText.clamp(short), short)

        let exact400 = String(repeating: "a", count: 400)
        let clampedExact = SelectionPreviewText.clamp(exact400)
        XCTAssertEqual(clampedExact?.count, 400)
        XCTAssertEqual(clampedExact, exact400)

        let over400 = (0..<525).map { _ in "x" }.joined()
        let clampedOver = SelectionPreviewText.clamp(over400)
        XCTAssertEqual(clampedOver?.count, 400)
        XCTAssertEqual(clampedOver, String(repeating: "x", count: 400))

        let unicodeOver400 = String(repeating: "选中🚀", count: 160) // 480 Extended Grapheme Clusters
        let clampedUnicode = SelectionPreviewText.clamp(unicodeOver400)
        XCTAssertEqual(clampedUnicode?.count, 400)
        XCTAssertEqual(clampedUnicode, String(unicodeOver400.prefix(400)))
    }

    func testWatchPreviewCapsAtEightyCharacters() {
        let text120 = String((0..<120).map { Character(UnicodeScalar(65 + ($0 % 26))!) })
        let watch = SelectionPreviewText.watchPreview(text120)
        XCTAssertEqual(watch?.count, 80)
        XCTAssertEqual(watch, String(text120.prefix(80)))

        let snapshot = SelectionPreviewSnapshot(
            text: SelectionPreviewText.clamp(String(repeating: "中", count: 450))!,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(snapshot.text.count, 400)
        XCTAssertEqual(snapshot.watchPreviewText.count, 80)
        XCTAssertEqual(snapshot.watchPreviewText, String(repeating: "中", count: 80))
    }

    func testSecureElementDetectionRejectsPasswordFieldsAndManagers() {
        XCTAssertTrue(SelectionPreviewText.isSecureElement(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(SelectionPreviewText.isSecureElement(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(SelectionPreviewText.isSecureElement(role: "AXTextField", subrole: nil, bundleIdentifier: "com.apple.Passwords"))
        XCTAssertTrue(SelectionPreviewText.isSecureElement(role: "AXTextField", subrole: nil, bundleIdentifier: "com.apple.keychainaccess"))
        XCTAssertTrue(SelectionPreviewText.isSecureElement(role: "AXTextField", subrole: nil, bundleIdentifier: "com.agilebits.onepassword7"))
        XCTAssertFalse(SelectionPreviewText.isSecureElement(role: "AXTextArea", subrole: nil, bundleIdentifier: "com.apple.TextEdit"))
    }

    func testCatalogContainsCopySelectionToPhoneAction() {
        let action = CompanionActionCatalog.action(id: "selection.copy_to_phone")
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.titleZh, "复制选中到手机")
        XCTAssertEqual(action?.titleEn, "Copy Selection to Phone")
        XCTAssertTrue(CompanionActionCatalog.isKnown("selection.copy_to_phone"))
    }

    func testSelectionPreviewWireRoundTrip() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_763_200_000)
        let original = ServerMessage.selectionPreview(text: "Selected line 42", capturedAt: capturedAt)
        let framed = try WireFrameCodec.encode(original)

        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(framed)
        XCTAssertEqual(payloads.count, 1)

        let decoded = try WireFrameCodec.decodePayload(ServerMessage.self, from: payloads[0])
        XCTAssertEqual(decoded, original)
    }

    #if os(macOS)
    @MainActor
    func testBroadcastSelectionPreviewDeliversToPhoneAndWatchCompanions() async {
        let suiteName = "com.choclift.tests.selection-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = SelectionPreviewTestServerDelegate()
        let server = MacServerEngine(macID: "mac-sel", macName: "Selection Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-sel",
            deviceName: "Selection iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "phone"
        )
        let watch = CompanionClientEngine(
            deviceID: "watch-sel",
            deviceName: "Selection Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch"
        )
        defer {
            phone.disconnect()
            watch.disconnect()
        }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Selection Mac", macID: "mac-sel")
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

        let rawSelection = String((0..<460).map { Character(UnicodeScalar(97 + ($0 % 26))!) })
        let clamped = try! XCTUnwrap(SelectionPreviewText.clamp(rawSelection))
        let capturedAt = Date(timeIntervalSince1970: 1_763_200_123)
        server.broadcast(.selectionPreview(text: clamped, capturedAt: capturedAt))

        for _ in 0..<60 where phone.latestSelectionPreview == nil || watch.latestSelectionPreview == nil {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }

        XCTAssertEqual(phone.latestSelectionPreview?.text.count, 400)
        XCTAssertEqual(phone.latestSelectionPreview?.text, clamped)
        XCTAssertEqual(phone.latestSelectionPreview?.capturedAt, capturedAt)
        XCTAssertEqual(watch.latestSelectionPreview?.watchPreviewText.count, 80)
        XCTAssertEqual(watch.latestSelectionPreview?.watchPreviewText, String(clamped.prefix(80)))

        phone.disconnect()
        XCTAssertNil(phone.latestSelectionPreview)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class SelectionPreviewTestServerDelegate: MacServerEngineDelegate {
    func serverCurrentProfile() -> ChocliftWorkspaceProfile { ChocliftDefaults.makeDefaultProfile() }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.apple.TextEdit" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {}
}
#endif
