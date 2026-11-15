import Foundation
import XCTest
@testable import ChocliftCore

final class PhoneClipboardPasteTests: XCTestCase {

    func testEmptyAndNilReturnNil() {
        XCTAssertNil(PhoneClipboardPaste.clamp(nil))
        XCTAssertNil(PhoneClipboardPaste.clamp(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(PhoneClipboardPaste.clamp("   "))
        XCTAssertNil(PhoneClipboardPaste.clamp("\t\n\r\n   \u{00A0}"))
    }

    func testTrimsAndCapsAt2000Characters() {
        XCTAssertEqual(PhoneClipboardPaste.maxCharacters, 2000)
        XCTAssertEqual(
            PhoneClipboardPaste.clamp("  hello from iPhone\n\t "),
            "hello from iPhone"
        )

        let exact2000 = String(repeating: "a", count: 2000)
        XCTAssertEqual(PhoneClipboardPaste.clamp(exact2000), exact2000)

        let over2000 = (0..<2450).map { idx in String(idx % 10) }.joined()
        let clampedOver = PhoneClipboardPaste.clamp(over2000)
        XCTAssertNotNil(clampedOver)
        XCTAssertEqual(clampedOver?.count, 2000)
        XCTAssertEqual(clampedOver, String(over2000.prefix(2000)))

        let paddedOver2000 = "  \n" + String(repeating: "好", count: 2300) + "  "
        let clampedCJK = PhoneClipboardPaste.clamp(paddedOver2000)
        XCTAssertEqual(clampedCJK?.count, 2000)
        XCTAssertEqual(clampedCJK, String(repeating: "好", count: 2000))
    }

    func testWireRoundTripForPastePhoneClipboard() throws {
        let message = ClientMessage.pastePhoneClipboard(text: "Plain text from phone")
        let framed = try WireFrameCodec.encode(message)
        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(framed)
        XCTAssertEqual(payloads.count, 1)
        let decoded = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        XCTAssertEqual(decoded, message)
    }

    #if os(macOS)
    @MainActor
    func testClientRejectsEmptyLocallyAndDeliversClampedPasteToAuthenticatedServer() async throws {
        let suiteName = "com.choclift.tests.r10.phonepaste.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = PhoneClipboardWireDelegate()
        let server = MacServerEngine(macID: "mac-phonepaste", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        // Pre-auth pastePhoneClipboard must require pairing and never reach the delegate
        let unauthServerEnd = server.acceptInMemoryCompanion()
        let (unauthProxy, unauthClientEnd) = InMemoryCompanionPipe.pair()
        var unauthReplies: [ServerMessage] = []
        unauthProxy.onPayload = { unauthServerEnd.send($0) }
        unauthServerEnd.onPayload = { unauthProxy.send($0) }
        unauthClientEnd.onPayload = { chunk in
            var acc = WireStreamAccumulator()
            if let frames = try? acc.appendAndExtractPayloads(chunk) {
                for frame in frames {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: frame) {
                        unauthReplies.append(msg)
                    }
                }
            }
        }
        unauthProxy.start()
        unauthServerEnd.start()
        unauthClientEnd.start()

        unauthClientEnd.send(try WireFrameCodec.encode(ClientMessage.pastePhoneClipboard(text: "Blocked before auth")))
        for _ in 0..<30 where unauthReplies.isEmpty {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(delegate.receivedTexts.isEmpty)
        XCTAssertEqual(
            unauthReplies.first,
            .pairingRequired(macID: "mac-phonepaste", macName: "Studio Mac")
        )

        // Pair and connect iPhone client
        let phone = CompanionClientEngine(
            deviceID: "iphone-paste-1",
            deviceName: "iPhone Paste",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "phonepaste"
        )
        defer { phone.disconnect() }

        var outboundFrameCount = 0
        let btHost = DiscoveredBluetoothMac(id: UUID(), name: "Studio Mac", macID: "mac-phonepaste")
        phone.simulatedBluetoothConnector = { _ in
            let serverEnd = server.acceptInMemoryCompanion()
            let (proxy, clientEnd) = InMemoryCompanionPipe.pair()
            proxy.onPayload = { data in
                outboundFrameCount += 1
                serverEnd.send(data)
            }
            serverEnd.onPayload = { proxy.send($0) }
            serverEnd.onClosed = { proxy.cancel() }
            proxy.start()
            serverEnd.start()
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

        let baselineOutbound = outboundFrameCount
        phone.lastFeedback = nil

        // Empty and whitespace-only clipboards show a local message and send nothing
        XCTAssertFalse(phone.pastePhoneClipboard(nil))
        XCTAssertEqual(phone.lastFeedback?.success, false)
        XCTAssertEqual(outboundFrameCount, baselineOutbound)
        XCTAssertTrue(delegate.receivedTexts.isEmpty)

        phone.lastFeedback = nil
        XCTAssertFalse(phone.pastePhoneClipboard("   \n\t  "))
        XCTAssertEqual(phone.lastFeedback?.success, false)
        XCTAssertEqual(outboundFrameCount, baselineOutbound)
        XCTAssertTrue(delegate.receivedTexts.isEmpty)

        // Valid over-2000 text trims, truncates to 2000, and reaches authenticated delegate
        let rawLong = "   " + String(repeating: "Z", count: 2300) + "\n"
        XCTAssertTrue(phone.pastePhoneClipboard(rawLong))
        for _ in 0..<50 where delegate.receivedTexts.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.receivedTexts.count, 1)
        XCTAssertEqual(delegate.receivedTexts.first?.count, 2000)
        XCTAssertEqual(delegate.receivedTexts.first, String(repeating: "Z", count: 2000))
    }
    #endif
}

#if os(macOS)
@MainActor
private final class PhoneClipboardWireDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var receivedTexts: [String] = []

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
        if case .pastePhoneClipboard(let text) = message {
            receivedTexts.append(text)
            reply(.actionFeedback(success: true, title: "Paste iPhone Clipboard", detail: "Inserted"))
        }
    }
}
#endif
