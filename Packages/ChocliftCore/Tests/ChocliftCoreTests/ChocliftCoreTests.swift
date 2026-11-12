import XCTest
@testable import ChocliftCore
#if os(iOS)
import SwiftUI
import UIKit
#endif

final class ChocliftCoreTests: XCTestCase {
    func testDefaultProfileStructure() {
        let profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertEqual(profile.pages.count, BarPage.maxPages)
        for page in profile.pages {
            XCTAssertEqual(page.slots.count, BarPage.slotsPerPage)
        }
        XCTAssertEqual(profile.emojiSlides.count, EmojiSlide.maxSlides)
        for slide in profile.emojiSlides {
            XCTAssertEqual(slide.emojis.count, EmojiSlide.emojisPerSlide)
        }
        XCTAssertEqual(profile.gestureConfig.action(for: .twoFingerSwipeUp), .maximizeWindow)
        XCTAssertEqual(profile.gestureConfig.action(for: .twoFingerSwipeDown), .minimizeWindow)
        XCTAssertEqual(profile.gestureConfig.action(for: .threeFingerPinchIn), .copySelection)
        XCTAssertEqual(profile.gestureConfig.action(for: .threeFingerPinchOut), .pasteClipboard)
    }

    func testWireFrameCodecChunkedAndConcatenatedDecoding() throws {
        let profile = ChocliftDefaults.makeDefaultProfile()
        let msg1 = ServerMessage.profileUpdated(profile)
        let msg2 = ServerMessage.textFieldFocusChanged(isEditingText: true, appName: "Notes")
        let msg3 = ServerMessage.appIconsBatch(["com.apple.finder": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])])

        var combined = Data()
        combined.append(try WireFrameCodec.encode(msg1))
        combined.append(try WireFrameCodec.encode(msg2))
        combined.append(try WireFrameCodec.encode(msg3))

        var accumulator = WireStreamAccumulator()
        var decodedMessages: [ServerMessage] = []

        // Feed 7 bytes at a time to simulate arbitrary TCP fragmentation
        var cursor = 0
        while cursor < combined.count {
            let end = min(cursor + 7, combined.count)
            let chunk = combined.subdata(in: cursor..<end)
            let payloads = try accumulator.appendAndExtractPayloads(chunk)
            for payload in payloads {
                decodedMessages.append(try WireFrameCodec.decodePayload(ServerMessage.self, from: payload))
            }
            cursor = end
        }

        XCTAssertEqual(accumulator.bufferedByteCount, 0)
        XCTAssertEqual(decodedMessages, [msg1, msg2, msg3])
    }

    func testRecentAppTimelineSortingPinnedFirstThenChronological() {
        let now = Date()
        let entries = [
            RecentAppEntry(bundleIdentifier: "com.apple.Notes", appName: "Notes", lastActivatedAt: now.addingTimeInterval(-10), isPinned: false),
            RecentAppEntry(bundleIdentifier: "com.apple.Safari", appName: "Safari", lastActivatedAt: now.addingTimeInterval(-120), isPinned: true),
            RecentAppEntry(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", lastActivatedAt: now, isPinned: false),
            RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", lastActivatedAt: now.addingTimeInterval(-60), isPinned: true)
        ]

        let sorted = RecentAppEntry.sortTimeline(entries)
        XCTAssertEqual(sorted.map(\.bundleIdentifier), [
            "com.apple.finder",
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.apple.Notes"
        ])
    }

    func testClientMessageRoundTrip() throws {
        let clientMessages: [ClientMessage] = [
            .hello(protocolVersion: 2, deviceID: "iphone-1", deviceName: "iPhone 17 Pro", platform: .iPhone, savedAuthToken: "tok-123"),
            .hello(protocolVersion: 2, deviceID: "watch-1", deviceName: "Apple Watch Series 11", platform: .appleWatch, savedAuthToken: "tok-watch-456"),
            .submitPIN(pin: "482910", deviceID: "iphone-1", deviceName: "iPhone 17 Pro", platform: .iPhone),
            .insertEmoji("🍫"),
            .performGesture(.twoFingerSwipeUp),
            .performQuickAction(.mediaPlayPause),
            .setRecentAppPinned(bundleIdentifier: "com.apple.Safari", isPinned: true)
        ]

        var accumulator = WireStreamAccumulator()
        for original in clientMessages {
            let framed = try WireFrameCodec.encode(original)
            let payloads = try accumulator.appendAndExtractPayloads(framed)
            XCTAssertEqual(payloads.count, 1)
            let decoded = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
            XCTAssertEqual(decoded, original)
        }
    }

    func testWatchPlatformMetadataAndCompactQuickActions() {
        XCTAssertEqual(DevicePlatform.appleWatch.rawValue, "Apple Watch")
        XCTAssertEqual(DevicePlatform.appleWatch.sfSymbol, "applewatch")
        for action in SystemQuickAction.allCases {
            XCTAssertFalse(action.compactTitle(in: .english).isEmpty)
            XCTAssertFalse(action.compactTitle(in: .chinese).isEmpty)
        }
    }

    func testBluetoothFrameCodecSurvives20ByteMTUAndPartialHeaderSplits() throws {
        let profile = ChocliftDefaults.makeDefaultProfile()
        let messages: [ServerMessage] = [
            .pairingRequired(macID: "mac-ble-1", macName: "Studio MacBook Pro"),
            .authSucceeded(
                macID: "mac-ble-1",
                macName: "Studio MacBook Pro",
                authToken: "token-shared-wifi-ble",
                profile: profile,
                recentApps: [
                    RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true)
                ],
                frontmostBundleID: "com.apple.finder",
                isEditingTextOnMac: false,
                focusedAppName: "Finder",
                isAccessibilityGranted: true
            ),
            .appIconsBatch(["com.apple.finder": Data(repeating: 0xAB, count: 64)]),
            .actionFeedback(success: true, title: "Play", detail: "Executed over BLE")
        ]

        var wireStream = Data()
        for msg in messages {
            wireStream.append(try WireFrameCodec.encode(msg))
        }

        // Feed irregular 1-byte, 3-byte (partial 4-byte header at non-aligned slice offsets), and 20-byte ATT MTU chunks
        let pattern = [1, 2, 1, 3, 20, 20, 5, 20, 1, 20]
        let codec = BluetoothFrameCodec()
        var reassembledFrames: [Data] = []
        var offset = 0
        var step = 0
        while offset < wireStream.count {
            let take = min(pattern[step % pattern.count], wireStream.count - offset)
            // Slice without resetting startIndex to exercise non-zero-aligned Data slices on arm64
            let slice = wireStream[(wireStream.startIndex + offset)..<(wireStream.startIndex + offset + take)]
            let extracted = try codec.append(slice)
            reassembledFrames.append(contentsOf: extracted)
            offset += take
            step += 1
        }

        XCTAssertEqual(codec.bufferedByteCount, 0)
        XCTAssertEqual(reassembledFrames.count, messages.count)

        var accumulator = WireStreamAccumulator()
        var decoded: [ServerMessage] = []
        for wireFrame in reassembledFrames {
            let payloads = try accumulator.appendAndExtractPayloads(wireFrame)
            for payload in payloads {
                decoded.append(try WireFrameCodec.decodePayload(ServerMessage.self, from: payload))
            }
        }
        XCTAssertEqual(decoded, messages)

        // Verify oversized header throws cleanly and resets buffer
        let invalidHeader = Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00])
        XCTAssertThrowsError(try codec.append(invalidHeader))
        XCTAssertEqual(codec.bufferedByteCount, 0)
    }

    func testBluetoothOutboundBufferNotifyBackpressureAndResume() throws {
        let messages: [ClientMessage] = [
            .hello(protocolVersion: 2, deviceID: "watch-ble-1", deviceName: "Apple Watch", platform: .appleWatch, savedAuthToken: nil),
            .submitPIN(pin: "654321", deviceID: "watch-ble-1", deviceName: "Apple Watch", platform: .appleWatch),
            .updateProfile(ChocliftDefaults.makeDefaultProfile()),
            .performQuickAction(.snapWindowLeft)
        ]

        let outbound = BluetoothOutboundBuffer()
        for msg in messages {
            outbound.enqueue(try WireFrameCodec.encode(msg))
        }
        XCTAssertFalse(outbound.isEmpty)

        let codec = BluetoothFrameCodec()
        var wireFrames: [Data] = []
        var pauseCount = 0

        // Simulate CBPeripheralManager.updateValue accepting only 2 chunks of 20 bytes per ready cycle
        while !outbound.isEmpty {
            var acceptedInBurst = 0
            outbound.drain(maxChunkBytes: ChocliftBluetooth.minATTChunkSize) { chunk in
                XCTAssertLessThanOrEqual(chunk.count, ChocliftBluetooth.minATTChunkSize)
                if acceptedInBurst >= 2 {
                    pauseCount += 1
                    return false
                }
                acceptedInBurst += 1
                if let extracted = try? codec.append(chunk) {
                    wireFrames.append(contentsOf: extracted)
                }
                return true
            }
        }

        XCTAssertGreaterThan(pauseCount, 10)
        XCTAssertEqual(outbound.remainingByteCount, 0)
        XCTAssertEqual(codec.bufferedByteCount, 0)
        XCTAssertEqual(wireFrames.count, messages.count)

        var accumulator = WireStreamAccumulator()
        var decoded: [ClientMessage] = []
        for frame in wireFrames {
            for payload in try accumulator.appendAndExtractPayloads(frame) {
                decoded.append(try WireFrameCodec.decodePayload(ClientMessage.self, from: payload))
            }
        }
        XCTAssertEqual(decoded, messages)
    }

    func testSavedMacCredentialLegacyDecodingAndBluetoothIDRoundTrip() throws {
        let legacyJSON = """
        {"macID":"mac-1","macName":"Office Mac","authToken":"tok-abc","lastDirectHost":"192.168.1.12","lastDirectPort":54821,"updatedAt":1000}
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(SavedMacCredential.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.macID, "mac-1")
        XCTAssertNil(decodedLegacy.lastBluetoothPeripheralID)

        let bleID = UUID()
        let updated = SavedMacCredential(
            macID: "mac-1",
            macName: "Office Mac",
            authToken: "tok-abc",
            lastDirectHost: "192.168.1.12",
            lastDirectPort: 54821,
            lastBluetoothPeripheralID: bleID
        )
        let data = try JSONEncoder().encode(updated)
        let roundTripped = try JSONDecoder().decode(SavedMacCredential.self, from: data)
        XCTAssertEqual(roundTripped.lastBluetoothPeripheralID, bleID)
        XCTAssertEqual(roundTripped.lastDirectHost, "192.168.1.12")
    }

    func testBluetoothFrameCodecSplitsFourByteLengthHeaderAcrossChunks() throws {
        let original = ServerMessage.actionFeedback(
            success: true,
            title: "Split Header",
            detail: "4-byte big-endian length header split across BLE chunks"
        )
        let fullFrame = try WireFrameCodec.encode(original)
        XCTAssertGreaterThan(fullFrame.count, 16)

        // Case A: 2 header bytes in chunk 1, remaining 2 header bytes + partial payload in chunk 2, rest in chunk 3
        let codecTwoTwo = BluetoothFrameCodec()
        let out1 = try codecTwoTwo.append(fullFrame.subdata(in: 0..<2))
        XCTAssertTrue(out1.isEmpty)
        XCTAssertEqual(codecTwoTwo.bufferedByteCount, 2)

        let out2 = try codecTwoTwo.append(fullFrame.subdata(in: 2..<9))
        XCTAssertTrue(out2.isEmpty)
        XCTAssertEqual(codecTwoTwo.bufferedByteCount, 9)

        let out3 = try codecTwoTwo.append(fullFrame.subdata(in: 9..<fullFrame.count))
        XCTAssertEqual(out3, [fullFrame])
        XCTAssertEqual(codecTwoTwo.bufferedByteCount, 0)

        // Case B: 1 byte at a time across all 4 header bytes, then payload
        let codecByteWise = BluetoothFrameCodec()
        for idx in 0..<4 {
            let partial = try codecByteWise.append(fullFrame.subdata(in: idx..<(idx + 1)))
            XCTAssertTrue(partial.isEmpty)
            XCTAssertEqual(codecByteWise.bufferedByteCount, idx + 1)
        }
        let completed = try codecByteWise.append(fullFrame.subdata(in: 4..<fullFrame.count))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(codecByteWise.bufferedByteCount, 0)

        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(completed[0])
        XCTAssertEqual(payloads.count, 1)
        let decoded = try WireFrameCodec.decodePayload(ServerMessage.self, from: payloads[0])
        XCTAssertEqual(decoded, original)
    }

    @MainActor
    func testPostConnectionMacIdentityAndSecondSavedMacTokenIsolation() throws {
        let macAlpha = "mac-studio-alpha-001"
        let macBeta = "mac-studio-beta-002"
        let alphaPeripheralID = UUID()
        let unknownPeripheralID = UUID()

        let adv = ChocliftBluetooth.makeConnectableAdvertisementData()
        XCTAssertLessThanOrEqual(
            ChocliftBluetooth.connectableAdvertisementByteCount(adv),
            ChocliftBluetooth.maxLegacyConnectableAdvertisingBytes
        )

        let browser = BluetoothCompanionBrowser()
        let scanned = try XCTUnwrap(
            browser.ingestAdvertisement(
                peripheralID: alphaPeripheralID,
                peripheralName: nil,
                advertisementData: adv
            )
        )
        XCTAssertNil(scanned.macID)

        let metadataBytes = try BluetoothServiceMetadata(
            macID: macAlpha,
            macName: "MacBook Pro"
        ).encodedCharacteristicValue()
        let resolved = try XCTUnwrap(
            browser.applyMetadataCharacteristicValue(
                metadataBytes,
                for: alphaPeripheralID,
                fallbackName: scanned.name
            )
        )
        XCTAssertEqual(resolved.host.macID, macAlpha)
        XCTAssertEqual(resolved.host.name, "MacBook Pro")

        let suiteName = "com.choclift.tests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let seeded = [
            SavedMacCredential(macID: "mac-other-top", macName: "Home iMac", authToken: "tok-home-imac"),
            SavedMacCredential(
                macID: macAlpha,
                macName: "MacBook Pro",
                authToken: "tok-secret-alpha",
                lastBluetoothPeripheralID: alphaPeripheralID
            )
        ]
        defaults.set(try JSONEncoder().encode(seeded), forKey: "idtest.savedMacs")

        let client = CompanionClientEngine(
            deviceID: "watch-id-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "idtest"
        )

        // Exact match for saved Mac Alpha via post-connection GATT metadata macID (even though Mac Alpha is not savedMacs[0])
        XCTAssertEqual(
            client.tokenForConnectAttempt(
                macID: resolved.host.macID,
                peripheralID: unknownPeripheralID,
                directHost: nil,
                targetName: "Mac"
            ),
            "tok-secret-alpha"
        )

        // Unsaved second Mac Beta sharing the exact same display name ("MacBook Pro") MUST NOT receive Alpha's token
        XCTAssertNil(
            client.tokenForConnectAttempt(
                macID: macBeta,
                peripheralID: alphaPeripheralID,
                directHost: nil,
                targetName: "MacBook Pro"
            ),
            "Known different macID must override any cached peripheralID or display name"
        )
        XCTAssertNil(
            client.tokenForConnectAttempt(
                macID: nil,
                peripheralID: unknownPeripheralID,
                directHost: nil,
                targetName: "MacBook Pro"
            ),
            "Unidentified peripheral sharing only display name must never receive another Mac's saved token"
        )
    }

    func testMultiTouchOverlayPolicyPassesThroughSingleTouchAndCapturesMultiTouch() {
        // 0 or 1 finger must never be owned by the full-screen overlay
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 0
            )
        )
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 1
            )
        )

        // 2+ fingers inside bounds when enabled are captured for multi-touch gestures
        XCTAssertTrue(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 2
            )
        )
        XCTAssertTrue(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 3
            )
        )

        // Disabled, hidden, transparent, or out-of-bounds must never capture
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: false,
                isHidden: false,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 2
            )
        )
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: true,
                alpha: 1.0,
                isPointInside: true,
                activeTouchCount: 2
            )
        )
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 0.0,
                isPointInside: true,
                activeTouchCount: 2
            )
        )
        XCTAssertFalse(
            MultiTouchOverlayPolicy.shouldOwnHit(
                isUserInteractionEnabled: true,
                isHidden: false,
                alpha: 1.0,
                isPointInside: false,
                activeTouchCount: 2
            )
        )
    }

    #if os(iOS)
    @MainActor
    func testPassThroughMultiTouchViewLetsSingleFingerHitsReachUnderlyingControlsAndSwiftUIZStack() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let container = UIView(frame: bounds)
        let underlyingButton = UIButton(frame: CGRect(x: 24, y: 40, width: 160, height: 56))
        container.addSubview(underlyingButton)

        let coordinator = CompanionMultiTouchCoordinator { _ in }
        let overlay = CompanionPassThroughMultiTouchView(frame: bounds)
        coordinator.overlayView = overlay
        overlay.installManagedRecognizers(coordinator.makeConfiguredRecognizers())
        container.addSubview(overlay)

        let tapPoint = CGPoint(x: 80, y: 60)
        XCTAssertNil(overlay.hitTest(tapPoint, with: nil))
        XCTAssertFalse(overlay.shouldCaptureHit(at: tapPoint, activeTouchCount: 1, with: nil))
        XCTAssertTrue(overlay.shouldCaptureHit(at: tapPoint, activeTouchCount: 2, with: nil))
        XCTAssertTrue(overlay.shouldCaptureHit(at: tapPoint, activeTouchCount: 3, with: nil))
        XCTAssertTrue(container.hitTest(tapPoint, with: nil) === underlyingButton)
        XCTAssertTrue(overlay.currentRecognizerHostView === container)

        // Verify inside a real SwiftUI ZStack + UIHostingController + UIWindow (matching IOSRootTouchBarView)
        final class ProbeRefs {
            weak var button: UIButton?
            weak var overlay: CompanionPassThroughMultiTouchView?
        }
        let refs = ProbeRefs()

        struct UnderlyingProbeButton: UIViewRepresentable {
            let refs: ProbeRefs
            func makeUIView(context: Context) -> UIButton {
                let button = UIButton(type: .system)
                refs.button = button
                return button
            }
            func updateUIView(_ uiView: UIButton, context: Context) {}
        }

        struct OverlayProbe: UIViewRepresentable {
            let refs: ProbeRefs
            let coordinator: CompanionMultiTouchCoordinator
            func makeUIView(context: Context) -> CompanionPassThroughMultiTouchView {
                let view = CompanionPassThroughMultiTouchView()
                coordinator.overlayView = view
                view.installManagedRecognizers(coordinator.makeConfiguredRecognizers())
                refs.overlay = view
                return view
            }
            func updateUIView(_ uiView: CompanionPassThroughMultiTouchView, context: Context) {}
        }

        let swiftUICoordinator = CompanionMultiTouchCoordinator { _ in }
        let rootView = ZStack {
            UnderlyingProbeButton(refs: refs)
                .frame(width: 200, height: 80)
            OverlayProbe(refs: refs, coordinator: swiftUICoordinator)
                .ignoresSafeArea()
        }

        let window = UIWindow(frame: bounds)
        let hostingVC = UIHostingController(rootView: rootView)
        window.rootViewController = hostingVC
        window.makeKeyAndVisible()
        hostingVC.view.frame = bounds
        hostingVC.view.setNeedsLayout()
        hostingVC.view.layoutIfNeeded()

        XCTAssertNotNil(refs.button)
        XCTAssertNotNil(refs.overlay)
        let centerPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let hitView = window.hitTest(centerPoint, with: nil)
        XCTAssertTrue(hitView === refs.button, "Expected underlying button to win single-touch hitTest, got \(String(describing: hitView))")
        XCTAssertTrue(refs.overlay?.currentRecognizerHostView === hostingVC.view)
    }

    @MainActor
    func testMultiTouchCoordinatorRecognizersConfigurationEnablementAndGestureDispatch() {
        var triggered: [TouchGestureType] = []
        let coordinator = CompanionMultiTouchCoordinator { gesture in
            triggered.append(gesture)
        }

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = CompanionPassThroughMultiTouchView(frame: host.bounds)
        coordinator.overlayView = overlay
        let recognizers = coordinator.makeConfiguredRecognizers()
        XCTAssertEqual(recognizers.count, 4)

        for recognizer in recognizers {
            XCTAssertFalse(recognizer.delaysTouchesBegan)
            XCTAssertFalse(recognizer.delaysTouchesEnded)
        }

        overlay.installManagedRecognizers(recognizers)
        host.addSubview(overlay)
        XCTAssertEqual(host.gestureRecognizers?.count, 4)

        // Disable / re-enable propagates to all recognizers and hit policy
        overlay.setOverlayEnabled(false)
        XCTAssertTrue(recognizers.allSatisfy { !$0.isEnabled })
        XCTAssertFalse(overlay.shouldCaptureHit(at: CGPoint(x: 100, y: 100), activeTouchCount: 2, with: nil))

        overlay.setOverlayEnabled(true)
        XCTAssertTrue(recognizers.allSatisfy(\.isEnabled))
        XCTAssertTrue(overlay.shouldCaptureHit(at: CGPoint(x: 100, y: 100), activeTouchCount: 2, with: nil))

        let twoFingerPan = recognizers[0] as! UIPanGestureRecognizer
        let threeFingerPan = recognizers[1] as! UIPanGestureRecognizer
        let pinch = recognizers[2] as! UIPinchGestureRecognizer
        let twoFingerDoubleTap = recognizers[3] as! UITapGestureRecognizer

        XCTAssertEqual(twoFingerPan.minimumNumberOfTouches, 2)
        XCTAssertEqual(twoFingerPan.maximumNumberOfTouches, 2)
        XCTAssertEqual(threeFingerPan.minimumNumberOfTouches, 3)
        XCTAssertEqual(threeFingerPan.maximumNumberOfTouches, 3)
        XCTAssertTrue(pinch.delegate === coordinator)
        XCTAssertEqual(twoFingerDoubleTap.numberOfTouchesRequired, 2)
        XCTAssertEqual(twoFingerDoubleTap.numberOfTapsRequired, 2)

        // 2-finger swipes (up, down, left, right) — including single-fire deduplication within one stroke
        coordinator.processTwoFingerPan(state: .began, translation: .zero)
        coordinator.processTwoFingerPan(state: .changed, translation: CGPoint(x: 0, y: -64))
        coordinator.processTwoFingerPan(state: .changed, translation: CGPoint(x: 0, y: -120))
        coordinator.processTwoFingerPan(state: .ended, translation: CGPoint(x: 0, y: -120))

        coordinator.processTwoFingerPan(state: .began, translation: .zero)
        coordinator.processTwoFingerPan(state: .changed, translation: CGPoint(x: 0, y: 64))
        coordinator.processTwoFingerPan(state: .ended, translation: CGPoint(x: 0, y: 64))

        coordinator.processTwoFingerPan(state: .began, translation: .zero)
        coordinator.processTwoFingerPan(state: .changed, translation: CGPoint(x: -70, y: 4))
        coordinator.processTwoFingerPan(state: .ended, translation: CGPoint(x: -70, y: 4))

        coordinator.processTwoFingerPan(state: .began, translation: .zero)
        coordinator.processTwoFingerPan(state: .changed, translation: CGPoint(x: 70, y: 4))
        coordinator.processTwoFingerPan(state: .ended, translation: CGPoint(x: 70, y: 4))

        // 3-finger swipes (up, down)
        coordinator.processThreeFingerPan(state: .began, translation: .zero)
        coordinator.processThreeFingerPan(state: .changed, translation: CGPoint(x: 0, y: -68))
        coordinator.processThreeFingerPan(state: .ended, translation: CGPoint(x: 0, y: -68))

        coordinator.processThreeFingerPan(state: .began, translation: .zero)
        coordinator.processThreeFingerPan(state: .changed, translation: CGPoint(x: 0, y: 68))
        coordinator.processThreeFingerPan(state: .ended, translation: CGPoint(x: 0, y: 68))

        // Pinch in & out (1-touch ignored; >= 2 touches fires once per stroke)
        coordinator.processPinch(state: .began, scale: 1.0, touchCount: 1)
        coordinator.processPinch(state: .changed, scale: 0.55, touchCount: 1)
        coordinator.processPinch(state: .ended, scale: 0.55, touchCount: 1)

        coordinator.processPinch(state: .began, scale: 1.0, touchCount: 2)
        coordinator.processPinch(state: .changed, scale: 0.60, touchCount: 2)
        coordinator.processPinch(state: .changed, scale: 0.45, touchCount: 2)
        coordinator.processPinch(state: .ended, scale: 0.45, touchCount: 2)

        coordinator.processPinch(state: .began, scale: 1.0, touchCount: 3)
        coordinator.processPinch(state: .changed, scale: 1.50, touchCount: 3)
        coordinator.processPinch(state: .ended, scale: 1.50, touchCount: 3)

        // 2-finger double-tap
        coordinator.processTwoFingerDoubleTap(state: .began)
        coordinator.processTwoFingerDoubleTap(state: .ended)

        XCTAssertEqual(triggered, [
            .twoFingerSwipeUp,
            .twoFingerSwipeDown,
            .twoFingerSwipeLeft,
            .twoFingerSwipeRight,
            .threeFingerSwipeUp,
            .threeFingerSwipeDown,
            .threeFingerPinchIn,
            .threeFingerPinchOut,
            .twoFingerDoubleTap
        ])

        // Removing overlay detaches recognizers from host cleanly
        overlay.removeFromSuperview()
        XCTAssertEqual(host.gestureRecognizers?.count ?? 0, 0)
    }
    #endif
}
