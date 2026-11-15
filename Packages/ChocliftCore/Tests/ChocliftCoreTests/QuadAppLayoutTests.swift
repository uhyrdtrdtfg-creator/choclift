import CoreGraphics
import Foundation
import XCTest
@testable import ChocliftCore

final class QuadAppLayoutTests: XCTestCase {
    func testLegacyProfileJSONWithoutQuadLayoutsDecodesToEmptyAndEncodesQuadLayouts() throws {
        let layout = QuadAppLayout(
            id: UUID(),
            name: "Dev Quad",
            topLeft: QuadAppSlot(bundleIdentifier: "com.apple.Safari", appName: "Safari"),
            bottomRight: QuadAppSlot(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        )
        var initialProfile = ChocliftDefaults.makeDefaultProfile()
        initialProfile.quadLayouts = [layout]

        let encodedData = try JSONEncoder().encode(initialProfile)
        var rawObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )
        XCTAssertNotNil(rawObject["quadLayouts"])

        rawObject.removeValue(forKey: "quadLayouts")
        let legacyData = try JSONSerialization.data(withJSONObject: rawObject)
        let decodedLegacy = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertTrue(decodedLegacy.quadLayouts.isEmpty)

        let roundTripped = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: encodedData)
        XCTAssertEqual(roundTripped.quadLayouts, [layout])
    }

    func testSanitizeDropsChocliftBundlesEmptyLayoutsDuplicateIDsAndItemsPastSix() {
        let safari = QuadAppSlot(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        let xcode = QuadAppSlot(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        let chocliftMac = QuadAppSlot(bundleIdentifier: "com.choclift.mac", appName: "Choclift")
        let chocliftCompanion = QuadAppSlot(bundleIdentifier: "com.choclift.ios", appName: "Choclift iOS")
        let blankSlot = QuadAppSlot(bundleIdentifier: "   ", appName: "Empty")

        let emptyLayout = QuadAppLayout(name: "Empty", topLeft: nil, topRight: blankSlot)
        let unnamedLayout = QuadAppLayout(name: "   ", topLeft: safari)
        let chocliftOnly = QuadAppLayout(name: "Self Only", topLeft: chocliftMac, bottomLeft: chocliftCompanion)

        let sharedID = UUID()
        let firstWithSharedID = QuadAppLayout(
            id: sharedID,
            name: "123456789012345678901234EXTRA_CHARS",
            topLeft: safari,
            topRight: chocliftMac,
            bottomLeft: chocliftCompanion,
            bottomRight: xcode
        )
        let duplicateSecond = QuadAppLayout(
            id: sharedID,
            name: "Duplicate Should Drop",
            topLeft: xcode
        )

        var candidates: [QuadAppLayout] = [
            emptyLayout,
            unnamedLayout,
            chocliftOnly,
            firstWithSharedID,
            duplicateSecond
        ]
        for index in 2...8 {
            candidates.append(
                QuadAppLayout(
                    name: "Layout \(index)",
                    topLeft: QuadAppSlot(
                        bundleIdentifier: "com.example.app\(index)",
                        appName: "App \(index)"
                    )
                )
            )
        }

        let sanitized = QuadAppLayout.sanitize(candidates)
        XCTAssertEqual(sanitized.count, 6)
        XCTAssertEqual(sanitized[0].id, sharedID)
        XCTAssertEqual(sanitized[0].name, "123456789012345678901234")
        XCTAssertEqual(sanitized[0].name.count, 24)
        XCTAssertEqual(sanitized[0].slot(for: .topLeft), safari)
        XCTAssertNil(sanitized[0].slot(for: .topRight))
        XCTAssertNil(sanitized[0].slot(for: .bottomLeft))
        XCTAssertEqual(sanitized[0].slot(for: .bottomRight), xcode)
        XCTAssertEqual(
            sanitized.dropFirst().map(\.name),
            ["Layout 2", "Layout 3", "Layout 4", "Layout 5", "Layout 6"]
        )

        let recents = [
            RecentAppEntry(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", isFrontmost: true, isPinned: false),
            RecentAppEntry(bundleIdentifier: "com.choclift.mac", appName: "Choclift", isFrontmost: false, isPinned: false)
        ]
        XCTAssertEqual(
            QuadAppSlot.resolveCompanionInput("  terminal ", recentApps: recents),
            QuadAppSlot(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
        )
        XCTAssertEqual(
            QuadAppSlot.resolveCompanionInput("  Keynote ", recentApps: recents),
            QuadAppSlot(bundleIdentifier: "Keynote", appName: "Keynote")
        )
        XCTAssertNil(QuadAppSlot.resolveCompanionInput("com.choclift.mac", recentApps: recents))
    }

    func testFourOccupiedCornersMapToFourNonOverlappingQuarterFramesIn1200x800Rect() {
        let layout = QuadAppLayout(
            name: "Four Corners",
            topLeft: QuadAppSlot(bundleIdentifier: "com.apple.Safari", appName: "Safari"),
            topRight: QuadAppSlot(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"),
            bottomLeft: QuadAppSlot(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"),
            bottomRight: QuadAppSlot(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        )
        let visibleRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let mapped = layout.quarterFrames(in: visibleRect)

        XCTAssertEqual(mapped.count, 4)
        XCTAssertEqual(mapped.map(\.corner), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        XCTAssertEqual(mapped[0].frame, CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(mapped[1].frame, CGRect(x: 600, y: 0, width: 600, height: 400))
        XCTAssertEqual(mapped[2].frame, CGRect(x: 0, y: 400, width: 600, height: 400))
        XCTAssertEqual(mapped[3].frame, CGRect(x: 600, y: 400, width: 600, height: 400))

        for i in 0..<mapped.count {
            XCTAssertTrue(visibleRect.contains(mapped[i].frame))
            for j in (i + 1)..<mapped.count {
                XCTAssertFalse(mapped[i].frame.intersects(mapped[j].frame))
                XCTAssertTrue(mapped[i].frame.intersection(mapped[j].frame).isEmpty)
            }
        }
    }

    func testWireRoundTripAndAuthenticatedDeliveryForQuadLayoutMessages() async throws {
        let layoutID = UUID()
        let layout = QuadAppLayout(
            id: layoutID,
            name: "Coding",
            topLeft: QuadAppSlot(bundleIdentifier: "com.apple.Safari", appName: "Safari"),
            bottomRight: QuadAppSlot(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
        )

        let runMsg = ClientMessage.runQuadLayout(id: layoutID)
        let runData = try JSONEncoder().encode(runMsg)
        XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: runData), runMsg)

        let upsertMsg = ClientMessage.upsertQuadLayout(layout)
        let deleteMsg = ClientMessage.deleteQuadLayout(id: layoutID)
        var accumulator = WireStreamAccumulator()
        var combined = Data()
        combined.append(try WireFrameCodec.encode(upsertMsg))
        combined.append(try WireFrameCodec.encode(runMsg))
        combined.append(try WireFrameCodec.encode(deleteMsg))
        let payloads = try accumulator.appendAndExtractPayloads(combined)
        let decodedFrames = try payloads.map { try WireFrameCodec.decodePayload(ClientMessage.self, from: $0) }
        XCTAssertEqual(decodedFrames, [upsertMsg, runMsg, deleteMsg])

        #if os(macOS)
        await assertAuthenticatedLoopbackDelivery(for: layout)
        #endif
    }

    #if os(macOS)
    @MainActor
    private func assertAuthenticatedLoopbackDelivery(for layout: QuadAppLayout) async {
        let suiteName = "com.choclift.tests.quad-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = QuadLayoutWireTestDelegate()
        let server = MacServerEngine(macID: "mac-quad", macName: "Quad Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-quad",
            deviceName: "iPhone Quad",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "quad"
        )
        defer { phone.disconnect() }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Quad Mac", macID: "mac-quad")
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

        let unknownID = UUID()
        XCTAssertFalse(phone.runQuadLayout(id: unknownID))
        XCTAssertFalse(phone.deleteQuadLayout(id: unknownID))
        XCTAssertFalse(phone.upsertQuadLayout(QuadAppLayout(name: "Empty")))
        XCTAssertFalse(
            phone.upsertQuadLayout(
                QuadAppLayout(
                    name: "Self",
                    topLeft: QuadAppSlot(bundleIdentifier: "com.choclift.mac", appName: "Choclift")
                )
            )
        )

        XCTAssertTrue(phone.upsertQuadLayout(layout))
        for _ in 0..<60 where delegate.receivedMessages.count < 1 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.receivedMessages, [.upsertQuadLayout(layout)])

        var synced = phone.profile
        synced.quadLayouts = [layout]
        server.broadcast(.profileUpdated(synced))
        for _ in 0..<60 where phone.profile.quadLayouts != [layout] {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }

        XCTAssertTrue(phone.runQuadLayout(id: layout.id))
        XCTAssertTrue(phone.deleteQuadLayout(id: layout.id))
        for _ in 0..<60 where delegate.receivedMessages.count < 3 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(
            delegate.receivedMessages,
            [
                .upsertQuadLayout(layout),
                .runQuadLayout(id: layout.id),
                .deleteQuadLayout(id: layout.id)
            ]
        )
    }
    #endif
}

#if os(macOS)
@MainActor
private final class QuadLayoutWireTestDelegate: MacServerEngineDelegate {
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
        case .upsertQuadLayout, .deleteQuadLayout, .runQuadLayout:
            receivedMessages.append(message)
            reply(.actionFeedback(success: true, title: "Quad", detail: nil))
        default:
            break
        }
    }
}
#endif
