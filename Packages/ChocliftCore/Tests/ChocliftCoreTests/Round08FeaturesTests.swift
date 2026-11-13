import Foundation
import XCTest
@testable import ChocliftCore

final class Round08FeaturesTests: XCTestCase {

    // MARK: - 1. Empty Trash & Eject External Disks Never Run Before the Second Tap

    func testEmptyTrashAndEjectExternalDisksRequireSecondTapWithinThreeSeconds() {
        var controller = Round08MaintenanceConfirmController()
        XCTAssertEqual(controller.confirmationWindowSeconds, 3.0, accuracy: 1e-9)

        // Empty Trash: first tap arms 3s window and MUST NOT execute
        let trashFirstTap = controller.registerTap(
            action: .emptyTrash,
            ejectableVolumeCount: 0,
            at: 10.0
        )
        XCTAssertEqual(trashFirstTap, .requireSecondTap(expiresAt: 13.0))
        XCTAssertTrue(controller.isArmed(.emptyTrash, at: 12.9))
        XCTAssertFalse(controller.isArmed(.emptyTrash, at: 13.1))

        // After >3s expiry, tapping again re-arms instead of executing
        let trashExpiredTap = controller.registerTap(
            action: .emptyTrash,
            ejectableVolumeCount: 0,
            at: 13.2
        )
        XCTAssertEqual(trashExpiredTap, .requireSecondTap(expiresAt: 16.2))

        // Second tap within 3s confirms execution and disarms
        let trashSecondTap = controller.registerTap(
            action: .emptyTrash,
            ejectableVolumeCount: 0,
            at: 14.5
        )
        XCTAssertEqual(trashSecondTap, .confirmedExecute)
        XCTAssertFalse(controller.isArmed(.emptyTrash, at: 14.6))

        // Eject External Disks with 0 mounted external volumes stays completely quiet
        let quietTap = controller.registerTap(
            action: .ejectExternalDisks,
            ejectableVolumeCount: 0,
            at: 20.0
        )
        XCTAssertEqual(quietTap, .quietNothingToEject)
        XCTAssertFalse(controller.isArmed(.ejectExternalDisks, at: 20.1))

        // Eject External Disks with mounted external volumes: first tap arms and MUST NOT execute
        let ejectFirstTap = controller.registerTap(
            action: .ejectExternalDisks,
            ejectableVolumeCount: 2,
            at: 30.0
        )
        XCTAssertEqual(ejectFirstTap, .requireSecondTap(expiresAt: 33.0))
        XCTAssertTrue(controller.isArmed(.ejectExternalDisks, at: 31.0))

        // Tapping Empty Trash while Eject is armed switches armed target without executing either
        let switchedTap = controller.registerTap(
            action: .emptyTrash,
            ejectableVolumeCount: 2,
            at: 31.5
        )
        XCTAssertEqual(switchedTap, .requireSecondTap(expiresAt: 34.5))
        XCTAssertFalse(controller.isArmed(.ejectExternalDisks, at: 31.6))
        XCTAssertTrue(controller.isArmed(.emptyTrash, at: 31.6))

        // Re-arm Eject and confirm on the second tap within 3s
        XCTAssertEqual(
            controller.registerTap(action: .ejectExternalDisks, ejectableVolumeCount: 1, at: 40.0),
            .requireSecondTap(expiresAt: 43.0)
        )
        XCTAssertEqual(
            controller.registerTap(action: .ejectExternalDisks, ejectableVolumeCount: 1, at: 41.8),
            .confirmedExecute
        )
        XCTAssertFalse(controller.isArmed(.ejectExternalDisks, at: 41.9))
    }

    // MARK: - 2. Notification Payload Contains Count Only and Rejects Title or Body Fixtures

    func testNotificationPayloadContainsCountOnlyAndRejectsTitleBodyOrSenderFixtures() throws {
        let validZero = try JSONDecoder().decode(
            MacNotificationCountPayload.self,
            from: Data(#"{"count":0}"#.utf8)
        )
        XCTAssertEqual(validZero.count, 0)
        XCTAssertEqual(validZero.displayText, "0")

        let validTwelve = try JSONDecoder().decode(
            MacNotificationCountPayload.self,
            from: Data(#"{"count":12}"#.utf8)
        )
        XCTAssertEqual(validTwelve.count, 12)
        XCTAssertEqual(validTwelve.displayText, "12")

        let encodedData = try JSONEncoder().encode(validTwelve)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        XCTAssertEqual(Set(encodedObject.keys), ["count"])
        XCTAssertEqual(encodedObject["count"] as? Int, 12)

        // Reject fixture containing a notification title
        let fixtureWithTitle = Data(#"{"count":3,"title":"Bank Verification"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacNotificationCountPayload.self, from: fixtureWithTitle)) { error in
            XCTAssertEqual(
                error as? MacNotificationPayloadValidationError,
                .forbiddenContentField("title")
            )
        }

        // Reject fixture containing a notification body
        let fixtureWithBody = Data(#"{"count":1,"body":"Your one-time passcode is 849201"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacNotificationCountPayload.self, from: fixtureWithBody)) { error in
            XCTAssertEqual(
                error as? MacNotificationPayloadValidationError,
                .forbiddenContentField("body")
            )
        }

        // Reject fixture containing both title and body
        let fixtureWithTitleAndBody = Data(#"{"count":2,"title":"Messages","body":"Dinner at 7?"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacNotificationCountPayload.self, from: fixtureWithTitleAndBody)) { error in
            if case .forbiddenContentField(let key)? = error as? MacNotificationPayloadValidationError {
                XCTAssertTrue(["body", "title"].contains(key))
            } else {
                XCTFail("Expected forbiddenContentField error, got \(error)")
            }
        }

        // Reject sender and app-specific message text fixtures
        let fixtureWithSender = Data(#"{"count":5,"sender":"Alice"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacNotificationCountPayload.self, from: fixtureWithSender)) { error in
            XCTAssertEqual(
                error as? MacNotificationPayloadValidationError,
                .forbiddenContentField("sender")
            )
        }

        let fixtureWithAppText = Data(#"{"count":4,"message":"Slack ping"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MacNotificationCountPayload.self, from: fixtureWithAppText)) { error in
            XCTAssertEqual(
                error as? MacNotificationPayloadValidationError,
                .forbiddenContentField("message")
            )
        }

        // Reject negative or missing count
        XCTAssertThrowsError(
            try JSONDecoder().decode(MacNotificationCountPayload.self, from: Data(#"{"count":-2}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? MacNotificationPayloadValidationError, .negativeCount(-2))
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(MacNotificationCountPayload.self, from: Data(#"{}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? MacNotificationPayloadValidationError, .missingCount)
        }
    }

    // MARK: - 3. Camera & Microphone Privacy Status + Wi-Fi Current SSID + External Volume Filtering

    func testCameraAndMicrophonePrivacyStatusFormattingAndSanitization() throws {
        let idle = MacPrivacyCaptureStatus.inactive
        XCTAssertFalse(idle.isAnyCaptureActive)
        XCTAssertNil(idle.cameraBadgeText(in: .english))
        XCTAssertNil(idle.microphoneBadgeText(in: .english))
        XCTAssertEqual(idle.stripSummaryText(in: .english), "Cam & Mic Idle")

        let camWithApp = MacPrivacyCaptureStatus(
            isCameraInUse: true,
            cameraAppName: "FaceTime",
            isMicrophoneInUse: false,
            microphoneAppName: "ShouldBeDroppedWhenInactive"
        )
        XCTAssertTrue(camWithApp.isAnyCaptureActive)
        XCTAssertEqual(camWithApp.cameraBadgeText(in: .english), "Cam: FaceTime")
        XCTAssertNil(camWithApp.microphoneAppName)
        XCTAssertEqual(camWithApp.stripSummaryText(in: .english), "Cam: FaceTime")

        let camWithoutExposedApp = MacPrivacyCaptureStatus(
            isCameraInUse: true,
            cameraAppName: nil,
            isMicrophoneInUse: true,
            microphoneAppName: "Zoom"
        )
        XCTAssertEqual(camWithoutExposedApp.cameraBadgeText(in: .english), "Camera In Use")
        XCTAssertEqual(camWithoutExposedApp.microphoneBadgeText(in: .english), "Mic: Zoom")
        XCTAssertEqual(camWithoutExposedApp.stripSummaryText(in: .english), "Camera In Use · Mic: Zoom")

        let data = try JSONEncoder().encode(camWithoutExposedApp)
        let decoded = try JSONDecoder().decode(MacPrivacyCaptureStatus.self, from: data)
        XCTAssertEqual(decoded, camWithoutExposedApp)
    }

    func testWiFiSSIDDisplayShowsCurrentSSIDOnlyAndFallsBackToWiFiWithoutName() throws {
        XCTAssertEqual(MacWiFiStatusFormatter.displayText(ssid: "Choclift-Studio-5G"), "Choclift-Studio-5G")
        XCTAssertEqual(MacWiFiStatusFormatter.displayText(ssid: nil), "Wi-Fi")
        XCTAssertEqual(MacWiFiStatusFormatter.displayText(ssid: ""), "Wi-Fi")
        XCTAssertEqual(MacWiFiStatusFormatter.displayText(ssid: "   \n\t "), "Wi-Fi")

        let stripWithSSID = ControlStripState(wifiSSID: "Cafe Guest")
        XCTAssertEqual(stripWithSSID.wifiDisplayLabel, "Cafe Guest")

        let stripUnavailable = ControlStripState(wifiSSID: nil)
        XCTAssertEqual(stripUnavailable.wifiDisplayLabel, "Wi-Fi")

        let jsonData = try JSONEncoder().encode(stripWithSSID)
        let rawString = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(rawString.contains("Cafe Guest"))
        XCTAssertFalse(rawString.lowercased().contains("password"))
        XCTAssertFalse(rawString.lowercased().contains("bssid"))
    }

    func testExternalDiskFilterNeverIncludesStartupOrInternalSystemVolumes() {
        let startupRoot = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/"),
            localizedName: "Macintosh HD",
            isRootFileSystem: true,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isBrowsable: true
        )
        let dataSystemVolume = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/System/Volumes/Data"),
            localizedName: "Data",
            isRootFileSystem: false,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isBrowsable: false
        )
        let recoveryVolume = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/Volumes/Recovery"),
            localizedName: "Recovery",
            isRootFileSystem: false,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isBrowsable: false
        )
        let internalSecondaryPartition = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/Volumes/InternalScratch"),
            localizedName: "InternalScratch",
            isRootFileSystem: false,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isBrowsable: true
        )
        let networkShare = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/Volumes/TeamNAS"),
            localizedName: "TeamNAS",
            isRootFileSystem: false,
            isInternal: false,
            isRemovable: false,
            isEjectable: true,
            isLocal: false,
            isBrowsable: true
        )
        let externalUSBDrive = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/Volumes/Samsung T7"),
            localizedName: "Samsung T7",
            isRootFileSystem: false,
            isInternal: false,
            isRemovable: false,
            isEjectable: true,
            isLocal: true,
            isBrowsable: true
        )
        let removableSDCard = ExternalDiskVolumeCandidate(
            url: URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"),
            localizedName: "EOS_DIGITAL",
            isRootFileSystem: false,
            isInternal: true,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isBrowsable: true
        )

        let filtered = ExternalDiskFilter.eligibleVolumes(from: [
            startupRoot,
            dataSystemVolume,
            recoveryVolume,
            internalSecondaryPartition,
            networkShare,
            externalUSBDrive,
            removableSDCard
        ])

        XCTAssertEqual(filtered.map(\.localizedName), ["Samsung T7", "EOS_DIGITAL"])
        XCTAssertFalse(filtered.contains(where: { $0.url.standardizedFileURL.path == "/" }))
    }

    // MARK: - 4. End-to-End Loopback Wire Verification (2-Tap Gates, Strip Sync & Unknown Frame Invariants)

    #if os(macOS)
    @MainActor
    func testLoopbackRound08TwoTapEmptyTrashAndEjectPrivacyWiFiAndUnknownFrames() async throws {
        let suiteName = "com.choclift.tests.round08.wire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round08WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r8-host", macName: "Studio Mac R8")
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

        let unknownClientJSON = Data(#"{"futureRound208ClientCommand":{"flag":true}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Unknown pre-auth frame must disconnect immediately")

        // 2. Pair and connect companion over in-memory transport
        let phone = CompanionClientEngine(
            deviceID: "iphone-r8",
            deviceName: "iPhone R8",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r8"
        )
        defer { phone.disconnect() }

        let btHost = DiscoveredBluetoothMac(
            id: UUID(),
            name: "Studio Mac R8",
            macID: "mac-r8-host"
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

        phone.requestControlStripState()
        for _ in 0..<50 where phone.controlStripState.wifiSSID != "Studio-5G" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.controlStripState.wifiDisplayLabel, "Studio-5G")
        XCTAssertEqual(
            phone.controlStripState.privacyCapture,
            MacPrivacyCaptureStatus(
                isCameraInUse: true,
                cameraAppName: "FaceTime",
                isMicrophoneInUse: true,
                microphoneAppName: "Zoom"
            )
        )
        XCTAssertEqual(phone.controlStripState.ejectableExternalVolumeCount, 0)

        // 3. Eject External Disks is quiet when ejectableExternalVolumeCount == 0
        XCTAssertEqual(phone.tapEjectExternalDisks(at: 100.0), .quietNothingToEject)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.ejectExternalDisksCount, 0)
        XCTAssertNil(phone.lastFeedback)

        // 4. Empty Trash MUST NOT run on the first tap; runs ONLY on the second tap within 3s
        XCTAssertEqual(phone.tapEmptyTrash(at: 200.0), .requireSecondTap(expiresAt: 203.0))
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.emptyTrashCount, 0, "Empty Trash must not execute before the second tap")

        XCTAssertEqual(phone.tapEmptyTrash(at: 201.4), .confirmedExecute)
        for _ in 0..<50 where delegate.emptyTrashCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.emptyTrashCount, 1)

        // 5. Simulate mounting 2 external volumes + unavailable Wi-Fi SSID ("Wi-Fi" fallback)
        delegate.stripState.ejectableExternalVolumeCount = 2
        delegate.stripState.wifiSSID = nil
        server.broadcastControlStripState(delegate.stripState)
        for _ in 0..<50 where phone.controlStripState.ejectableExternalVolumeCount != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.controlStripState.wifiDisplayLabel, "Wi-Fi")

        // First tap on Eject External Disks arms 3s confirm and MUST NOT run
        XCTAssertEqual(phone.tapEjectExternalDisks(at: 300.0), .requireSecondTap(expiresAt: 303.0))
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.ejectExternalDisksCount, 0, "Eject must not execute before the second tap")

        // Expired tap (>3s) re-arms without running
        XCTAssertEqual(phone.tapEjectExternalDisks(at: 303.5), .requireSecondTap(expiresAt: 306.5))
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(delegate.ejectExternalDisksCount, 0)

        // Second tap within 3s confirms and ejects
        XCTAssertEqual(phone.tapEjectExternalDisks(at: 304.8), .confirmedExecute)
        for _ in 0..<50 where delegate.ejectExternalDisksCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.ejectExternalDisksCount, 1)
        for _ in 0..<50 where phone.controlStripState.ejectableExternalVolumeCount != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.controlStripState.ejectableExternalVolumeCount, 0)

        // 6. Unknown POST-AUTH frames stay non-fatal in both directions
        latestClientPipeEnd?.send(unknownClientFrame)
        let unknownServerJSON = Data(#"{"futureRound208ServerEvent":{"info":1}}"#.utf8)
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
private final class Round08WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var stripState = ControlStripState(
        macBattery: .powerAdapter,
        areFinderDesktopIconsVisible: true,
        privacyCapture: MacPrivacyCaptureStatus(
            isCameraInUse: true,
            cameraAppName: "FaceTime",
            isMicrophoneInUse: true,
            microphoneAppName: "Zoom"
        ),
        wifiSSID: "Studio-5G",
        ejectableExternalVolumeCount: 0
    )
    var emptyTrashCount = 0
    var ejectExternalDisksCount = 0

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
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(stripState))

        case .emptyMacTrash:
            emptyTrashCount += 1
            reply(.controlStripStateUpdated(stripState))
            reply(.actionFeedback(success: true, title: "Empty Trash", detail: "Emptied Trash"))

        case .ejectExternalDisks:
            ejectExternalDisksCount += 1
            stripState.ejectableExternalVolumeCount = 0
            server?.broadcastControlStripState(stripState)
            reply(.controlStripStateUpdated(stripState))
            reply(.actionFeedback(success: true, title: "Eject External Disks", detail: "Ejected"))

        default:
            break
        }
    }
}
#endif
