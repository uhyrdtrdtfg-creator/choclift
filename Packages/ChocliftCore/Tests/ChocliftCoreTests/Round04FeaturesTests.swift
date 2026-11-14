import XCTest
@testable import ChocliftCore

final class Round04FeaturesTests: XCTestCase {

    // MARK: - 1. Pure Mac Awake Assertion State Machine

    func testAwakeAssertionStateMachineEndsWhenLastCompanionDisconnects() {
        var machine = MacAwakeAssertionStateMachine()
        XCTAssertFalse(machine.isToggleEnabled)
        XCTAssertEqual(machine.connectedCompanionCount, 0)
        XCTAssertFalse(machine.shouldHoldAssertion)

        // Enabling while 0 companions are connected must NOT hold an assertion
        XCTAssertFalse(machine.setToggleEnabled(true))
        XCTAssertFalse(machine.isToggleEnabled)
        XCTAssertFalse(machine.shouldHoldAssertion)

        // Connect two companions (iPhone + iPad)
        XCTAssertFalse(machine.deviceConnected("iphone-1"))
        XCTAssertFalse(machine.deviceConnected("ipad-2"))
        XCTAssertEqual(machine.connectedCompanionCount, 2)
        XCTAssertFalse(machine.shouldHoldAssertion)

        // Turning phone toggle ON while companions are connected holds the assertion
        XCTAssertTrue(machine.setToggleEnabled(true))
        XCTAssertTrue(machine.isToggleEnabled)
        XCTAssertTrue(machine.shouldHoldAssertion)

        // Turning phone toggle OFF immediately ends the assertion
        XCTAssertFalse(machine.setToggleEnabled(false))
        XCTAssertFalse(machine.isToggleEnabled)
        XCTAssertFalse(machine.shouldHoldAssertion)

        // Turn toggle back ON
        XCTAssertTrue(machine.setToggleEnabled(true))
        XCTAssertTrue(machine.shouldHoldAssertion)

        // Disconnecting one companion while another remains connected keeps the assertion active
        XCTAssertTrue(machine.deviceDisconnected("iphone-1"))
        XCTAssertEqual(machine.connectedCompanionCount, 1)
        XCTAssertTrue(machine.shouldHoldAssertion)

        // Disconnecting the LAST companion immediately ends the assertion and clears the toggle
        XCTAssertFalse(machine.deviceDisconnected("ipad-2"))
        XCTAssertEqual(machine.connectedCompanionCount, 0)
        XCTAssertFalse(machine.isToggleEnabled)
        XCTAssertFalse(machine.shouldHoldAssertion)

        // Reconnecting later does NOT silently re-assert sleep prevention until toggled on again
        XCTAssertFalse(machine.updateConnectedDevices(["iphone-1"]))
        XCTAssertFalse(machine.isToggleEnabled)
        XCTAssertFalse(machine.shouldHoldAssertion)
    }

    // MARK: - 2. Frontmost App Window List Cap at 12

    func testFrontmostWindowSnapshotCapsWindowListAt12() throws {
        XCTAssertEqual(FrontmostAppWindowSnapshot.maxWindows, 12)

        // 0 windows
        let empty = FrontmostAppWindowSnapshot(bundleIdentifier: "com.apple.Safari", appName: "Safari", windows: [])
        XCTAssertTrue(empty.windows.isEmpty)
        XCTAssertEqual(empty.totalWindowCount, 0)
        XCTAssertFalse(empty.isCapped)

        // Exactly 12 windows -> preserved without capping indicator
        let twelveItems = (0..<12).map { idx in
            MacFrontmostWindowItem(id: "win-\(idx)", title: "Tab \(idx + 1)", index: idx, isMainOrFocused: idx == 0)
        }
        let exactTwelve = FrontmostAppWindowSnapshot(
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windows: twelveItems
        )
        XCTAssertEqual(exactTwelve.windows.count, 12)
        XCTAssertEqual(exactTwelve.totalWindowCount, 12)
        XCTAssertFalse(exactTwelve.isCapped)

        // 13 windows -> capped at 12, totalWindowCount preserved at 13
        let thirteenItems = (0..<13).map { idx in
            MacFrontmostWindowItem(id: "win-\(idx)", title: "Window \(idx + 1)", index: idx)
        }
        let cappedThirteen = FrontmostAppWindowSnapshot(
            bundleIdentifier: "com.apple.dt.Xcode",
            appName: "Xcode",
            windows: thirteenItems
        )
        XCTAssertEqual(cappedThirteen.windows.count, 12)
        XCTAssertEqual(cappedThirteen.windows.map(\.index), Array(0..<12))
        XCTAssertEqual(cappedThirteen.totalWindowCount, 13)
        XCTAssertTrue(cappedThirteen.isCapped)

        // 25 windows -> capped at 12
        let twentyFiveItems = (0..<25).map { idx in
            MacFrontmostWindowItem(id: "win-\(idx)", title: "Doc \(idx + 1)", index: idx)
        }
        let cappedTwentyFive = FrontmostAppWindowSnapshot(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windows: twentyFiveItems
        )
        XCTAssertEqual(cappedTwentyFive.windows.count, 12)
        XCTAssertEqual(cappedTwentyFive.totalWindowCount, 25)
        XCTAssertTrue(cappedTwentyFive.isCapped)

        // Wire JSON decode defense: if a raw JSON payload carries 18 windows, decoding clamps to 12
        struct RawUnboundedSnapshot: Encodable {
            let bundleIdentifier: String
            let appName: String
            let windows: [MacFrontmostWindowItem]
            let totalWindowCount: Int
            let isAccessibilityTrusted: Bool
        }
        let eighteenItems = (0..<18).map { idx in
            MacFrontmostWindowItem(id: "raw-\(idx)", title: "Raw \(idx + 1)", index: idx)
        }
        let rawData = try JSONEncoder().encode(
            RawUnboundedSnapshot(
                bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal",
                windows: eighteenItems,
                totalWindowCount: 18,
                isAccessibilityTrusted: true
            )
        )
        let decoded = try JSONDecoder().decode(FrontmostAppWindowSnapshot.self, from: rawData)
        XCTAssertEqual(decoded.windows.count, 12)
        XCTAssertEqual(decoded.totalWindowCount, 18)
        XCTAssertTrue(decoded.isCapped)
    }

    // MARK: - 3. Audio Output ControlStrip Round-Trip & Non-Faked Read-Only Behavior

    @MainActor
    func testAudioOutputControlStripRoundTripAndReadOnlyNeverFakesSwitch() throws {
        // Legacy ControlStripState JSON without Round 4 keys decodes with safe defaults
        let legacyJSON = Data(#"{"volume":0.5,"isVolumeMuted":false,"brightness":0.8,"isBrightnessAvailable":true,"isMicMuted":false,"canUndoWindowMove":false}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ControlStripState.self, from: legacyJSON)
        XCTAssertFalse(decodedLegacy.isKeepMacAwakeEnabled)
        XCTAssertTrue(decodedLegacy.audioOutputDevices.isEmpty)
        XCTAssertNil(decodedLegacy.selectedAudioOutputDeviceID)
        XCTAssertTrue(decodedLegacy.canSwitchAudioOutput)

        // Round-trip with multiple CoreAudio output devices and read-only flag
        let builtIn = MacAudioOutputDevice(
            id: "BuiltInSpeakerDevice",
            audioObjectID: 48,
            name: "MacBook Pro Speakers",
            transportKind: .builtIn
        )
        let headphones = MacAudioOutputDevice(
            id: "AA-BB-CC-AirPods",
            audioObjectID: 92,
            name: "AirPods Pro",
            transportKind: .bluetooth
        )
        let state = ControlStripState(
            volume: 0.65,
            isVolumeMuted: false,
            brightness: 0.70,
            isBrightnessAvailable: true,
            isMicMuted: false,
            isKeepMacAwakeEnabled: true,
            audioOutputDevices: [builtIn, headphones],
            selectedAudioOutputDeviceID: builtIn.id,
            canSwitchAudioOutput: false
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ControlStripState.self, from: encoded)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.currentAudioOutputDevice, builtIn)
        XCTAssertFalse(decoded.canSwitchAudioOutput)

        // Read-only state with nil or unmatched selectedAudioOutputDeviceID must NEVER encode or expose a fake selected ID
        let unknownDefaultReadOnly = ControlStripState(
            audioOutputDevices: [builtIn, headphones],
            selectedAudioOutputDeviceID: nil,
            canSwitchAudioOutput: false
        )
        XCTAssertNil(unknownDefaultReadOnly.selectedAudioOutputDeviceID)
        XCTAssertNil(unknownDefaultReadOnly.currentAudioOutputDevice)
        let unknownJSON = String(decoding: try JSONEncoder().encode(unknownDefaultReadOnly), as: UTF8.self)
        XCTAssertFalse(unknownJSON.contains("selectedAudioOutputDeviceID"))

        let staleSelectedReadOnly = ControlStripState(
            audioOutputDevices: [builtIn, headphones],
            selectedAudioOutputDeviceID: "non-existent-uid",
            canSwitchAudioOutput: false
        )
        XCTAssertNil(staleSelectedReadOnly.selectedAudioOutputDeviceID)
        XCTAssertNil(staleSelectedReadOnly.currentAudioOutputDevice)
        let staleJSON = String(decoding: try JSONEncoder().encode(staleSelectedReadOnly), as: UTF8.self)
        XCTAssertFalse(staleJSON.contains("selectedAudioOutputDeviceID"))
    }

    func testAudioOutputUIDResolutionTransportFallbackAndHiddenCurrentDefaultSelected() {
        let speakers = MacAudioRawDeviceRecord(
            audioObjectID: 48,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Pro Speakers",
            transportKind: .builtIn,
            outputChannelCount: 2,
            isHidden: false
        )
        let uidLessUSB = MacAudioRawDeviceRecord(
            audioObjectID: 64,
            uid: nil,
            name: "Studio Monitor DAC",
            transportKind: .usb,
            outputChannelCount: 2,
            isHidden: false
        )
        let hiddenAggregate = MacAudioRawDeviceRecord(
            audioObjectID: 95,
            uid: "com.apple.audio.HiddenSystemOutput",
            name: "Hidden Aggregate Output",
            transportKind: .virtualOrOther,
            outputChannelCount: 2,
            isHidden: true
        )

        // When hiddenAggregate is NOT the default, it stays hidden
        let normalSnap = MacAudioOutputSwitchEngine.enumerateSnapshot(
            records: [speakers, uidLessUSB, hiddenAggregate],
            defaultOutputObjectID: 48,
            isDefaultOutputSettable: true
        )
        XCTAssertEqual(normalSnap.devices.map(\.id), ["BuiltInSpeakerDevice", "fallback:usb:studio monitor dac"])
        XCTAssertEqual(normalSnap.selectedID, "BuiltInSpeakerDevice")

        // When hiddenAggregate IS the live default, it is included and selected so the checkmark matches reality
        let hiddenDefaultSnap = MacAudioOutputSwitchEngine.enumerateSnapshot(
            records: [speakers, uidLessUSB, hiddenAggregate],
            defaultOutputObjectID: 95,
            isDefaultOutputSettable: true
        )
        XCTAssertEqual(
            hiddenDefaultSnap.devices.map(\.id),
            ["BuiltInSpeakerDevice", "fallback:usb:studio monitor dac", "com.apple.audio.HiddenSystemOutput"]
        )
        XCTAssertEqual(hiddenDefaultSnap.selectedID, "com.apple.audio.HiddenSystemOutput")

        // UID resolves first; fallback ID resolves ONLY for UID-less device and survives objectID change (64 -> 180)
        let restartedUIDLessUSB = MacAudioRawDeviceRecord(
            audioObjectID: 180,
            uid: nil,
            name: "Studio Monitor DAC",
            transportKind: .usb,
            outputChannelCount: 2,
            isHidden: false
        )
        let resolvedFallback = MacAudioOutputSwitchEngine.resolveTarget(
            requestedID: "fallback:usb:studio monitor dac",
            in: [speakers, restartedUIDLessUSB],
            defaultOutputObjectID: 48
        )
        XCTAssertEqual(resolvedFallback?.record.audioObjectID, 180)

        // Fallback ID must NOT match a device that actually has a non-empty UID
        let fallbackAgainstUIDDevice = MacAudioOutputSwitchEngine.resolveTarget(
            requestedID: MacAudioOutputDevice.fallbackID(transportKind: .builtIn, name: "MacBook Pro Speakers"),
            in: [speakers, restartedUIDLessUSB],
            defaultOutputObjectID: 48
        )
        XCTAssertNil(fallbackAgainstUIDDevice)
    }

    func testAudioOutputStaleObjectIDNeverSelectsWrongDeviceAfterCoreAudioRestart() {
        let driver = MockAudioOutputHardwareDriver(
            records: [
                MacAudioRawDeviceRecord(
                    audioObjectID: 48,
                    uid: "BuiltInSpeakerDevice",
                    name: "MacBook Pro Speakers",
                    transportKind: .builtIn,
                    outputChannelCount: 2
                ),
                // Object ID 77 used to be USB DAC before coreaudiod restart, now belongs to AirPods!
                MacAudioRawDeviceRecord(
                    audioObjectID: 77,
                    uid: "AA-BB-AirPods",
                    name: "AirPods Pro",
                    transportKind: .bluetooth,
                    outputChannelCount: 2
                ),
                // USB DAC moved to object ID 142 after coreaudiod restart
                MacAudioRawDeviceRecord(
                    audioObjectID: 142,
                    uid: "USB-DAC-UID",
                    name: "USB Studio DAC",
                    transportKind: .usb,
                    outputChannelCount: 2
                )
            ],
            defaultOutputObjectID: 48,
            defaultSystemOutputObjectID: 48
        )

        for staleID in ["77", "audio-77", "audio-obj-77"] {
            let staleResult = MacAudioOutputSwitchEngine.performSwitch(
                requestedID: staleID,
                language: .english,
                using: driver
            )
            XCTAssertFalse(staleResult.success)
            XCTAssertEqual(driver.defaultOutputObjectID, 48, "Stale object ID \(staleID) must not touch AirPods (77)")
            XCTAssertEqual(staleResult.snapshot.selectedID, "BuiltInSpeakerDevice")
        }

        // Simulate UID translation returning an even newer live AudioObjectID (205) right before set
        driver.translatedUIDOverrides["USB-DAC-UID"] = 205
        driver.records[2].audioObjectID = 205

        let liveResult = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: "USB-DAC-UID",
            language: .english,
            using: driver
        )
        XCTAssertTrue(liveResult.success)
        XCTAssertEqual(driver.defaultOutputObjectID, 205)
        XCTAssertEqual(driver.defaultSystemOutputObjectID, 205)
        XCTAssertEqual(liveResult.snapshot.selectedID, "USB-DAC-UID")
    }

    func testAudioOutputSelectorListSetErrorOSStatusAndActiveProcessMigration() {
        // 1. Selector helper includes DefaultSystemOutputDevice when available & settable, skips otherwise
        XCTAssertEqual(
            MacAudioDefaultSelector.selectorsToApply(hasDefaultSystemOutput: true, isDefaultSystemOutputSettable: true),
            [.defaultOutput, .defaultSystemOutput]
        )
        XCTAssertEqual(
            MacAudioDefaultSelector.selectorsToApply(hasDefaultSystemOutput: false, isDefaultSystemOutputSettable: true),
            [.defaultOutput]
        )
        XCTAssertEqual(
            MacAudioDefaultSelector.selectorsToApply(hasDefaultSystemOutput: true, isDefaultSystemOutputSettable: false),
            [.defaultOutput]
        )

        let baseRecords = [
            MacAudioRawDeviceRecord(
                audioObjectID: 48,
                uid: "BuiltInSpeakerDevice",
                name: "MacBook Pro Speakers",
                transportKind: .builtIn,
                outputChannelCount: 2
            ),
            MacAudioRawDeviceRecord(
                audioObjectID: 92,
                uid: "USB-DAC-UID",
                name: "USB Studio DAC",
                transportKind: .usb,
                outputChannelCount: 2
            )
        ]

        // 2. Read-only property rejects without mutating defaults or faking selection
        let readOnlyDriver = MockAudioOutputHardwareDriver(
            records: baseRecords,
            defaultOutputObjectID: 48,
            defaultSystemOutputObjectID: 48,
            isDefaultOutputSettable: false
        )
        let readOnlyRes = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: "USB-DAC-UID",
            language: .english,
            using: readOnlyDriver
        )
        XCTAssertFalse(readOnlyRes.success)
        XCTAssertTrue(readOnlyRes.title.localizedCaseInsensitiveContains("Read-Only"))
        XCTAssertEqual(readOnlyDriver.defaultOutputObjectID, 48)
        XCTAssertEqual(readOnlyRes.snapshot.selectedID, "BuiltInSpeakerDevice")

        // 3. Set failure includes OSStatus, keeps previous selection marked, and does NOT claim "read-only"
        let failingDriver = MockAudioOutputHardwareDriver(
            records: baseRecords,
            defaultOutputObjectID: 48,
            defaultSystemOutputObjectID: 48,
            forcedDefaultOutputWriteStatus: 560227702 // 'what' (kAudioHardwareUnspecifiedError)
        )
        let failedRes = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: "USB-DAC-UID",
            language: .english,
            using: failingDriver
        )
        XCTAssertFalse(failedRes.success)
        XCTAssertTrue(failedRes.detail.contains("560227702"))
        XCTAssertFalse(failedRes.title.localizedCaseInsensitiveContains("read-only"))
        XCTAssertFalse(failedRes.detail.localizedCaseInsensitiveContains("read-only"))
        XCTAssertEqual(failedRes.snapshot.selectedID, "BuiltInSpeakerDevice")

        // 4. Active output process migration: settable process moves; read-only process reports honestly while defaults switch
        let processDriver = MockAudioOutputHardwareDriver(
            records: baseRecords,
            defaultOutputObjectID: 48,
            defaultSystemOutputObjectID: 48,
            runningProcesses: [
                MacAudioRunningProcessRecord(
                    processObjectID: 301,
                    pid: 4100,
                    appName: "Music",
                    outputDeviceObjectIDs: [48],
                    isOutputDeviceSettable: true
                ),
                MacAudioRunningProcessRecord(
                    processObjectID: 302,
                    pid: 4200,
                    appName: "Zoom",
                    outputDeviceObjectIDs: [48],
                    isOutputDeviceSettable: false
                )
            ]
        )
        let migratedRes = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: "USB-DAC-UID",
            language: .english,
            using: processDriver
        )
        XCTAssertTrue(migratedRes.success)
        XCTAssertEqual(migratedRes.appliedSelectors, [.defaultOutput, .defaultSystemOutput])
        XCTAssertEqual(migratedRes.readBackDefaultOutputObjectID, 92)
        XCTAssertEqual(migratedRes.readBackSystemOutputObjectID, 92)
        XCTAssertEqual(migratedRes.movedProcessCount, 1)
        XCTAssertEqual(processDriver.movedProcesses[301], 92)
        XCTAssertEqual(migratedRes.unmovedAppNames, ["Zoom"])
        XCTAssertTrue(migratedRes.detail.contains("Zoom"))
        XCTAssertEqual(migratedRes.snapshot.selectedID, "USB-DAC-UID")
    }

    // MARK: - 4. Tile Action Feedback Tracker & Auto-Expiry Without Second Toast

    func testTileActionFeedbackTrackerPureLifecycle() {
        var tracker = TileActionFeedbackTracker()
        let pageID = UUID()
        let slot0 = SlotCoordinate(pageID: pageID, slotIndex: 0)
        let slot1 = SlotCoordinate(pageID: pageID, slotIndex: 1)

        tracker.recordTileTriggered(slot: slot0)
        XCTAssertEqual(tracker.pendingSlot, slot0)
        XCTAssertNil(tracker.outcome(for: slot0))

        let banner1 = tracker.resolvePending(success: true)
        XCTAssertNotNil(banner1)
        XCTAssertEqual(tracker.outcome(for: slot0), .success)
        XCTAssertNil(tracker.outcome(for: slot1))

        // Triggering a second slot supersedes the first slot's feedback when resolved
        tracker.recordTileTriggered(slot: slot1)
        let banner2 = tracker.resolvePending(success: false)
        XCTAssertNotNil(banner2)
        XCTAssertNil(tracker.outcome(for: slot0))
        XCTAssertEqual(tracker.outcome(for: slot1), .failure)

        // Stale token from banner1 must NOT expire banner2
        if let token1 = banner1?.token {
            XCTAssertFalse(tracker.expireFeedback(matchingToken: token1))
        }
        XCTAssertEqual(tracker.outcome(for: slot1), .failure)

        // Matching token expires banner2 back to normal
        if let token2 = banner2?.token {
            XCTAssertTrue(tracker.expireFeedback(matchingToken: token2))
        }
        XCTAssertNil(tracker.outcome(for: slot1))
    }

    // MARK: - 5. End-to-End Round 4 Loopback + Pre-Auth vs Post-Auth Unknown Frame Invariant

    #if os(macOS)
    @MainActor
    func testRound04LoopbackKeepAwakeAudioSwitchWindowRaiseTileFlashAndUnknownFramePolicy() async throws {
        let suiteName = "com.choclift.tests.round04.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round04WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r4", macName: "Studio Mac R4")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        // 1. Pre-auth unknown client frame MUST disconnect immediately
        let preAuthServerEnd = server.acceptInMemoryCompanion()
        let (preAuthProxy, preAuthRawClient) = InMemoryCompanionPipe.pair()
        var preAuthClosed = false
        var preAuthReceivedFrames: [ServerMessage] = []
        var preAuthAccumulator = WireStreamAccumulator()
        preAuthProxy.onPayload = { preAuthServerEnd.send($0) }
        preAuthServerEnd.onPayload = { chunk in
            preAuthProxy.send(chunk)
        }
        preAuthServerEnd.onClosed = {
            preAuthProxy.cancel()
        }
        preAuthRawClient.onPayload = { chunk in
            if let frames = try? preAuthAccumulator.appendAndExtractPayloads(chunk) {
                for f in frames {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: f) {
                        preAuthReceivedFrames.append(msg)
                    }
                }
            }
        }
        preAuthRawClient.onClosed = {
            preAuthClosed = true
        }
        preAuthProxy.start()
        preAuthServerEnd.start()
        preAuthRawClient.start()

        let unknownPayload = Data(#"{"futureRound99ClientFeature":{"flag":true}}"#.utf8)
        var unknownLenBE = UInt32(unknownPayload.count).bigEndian
        var unknownRawFrame = Data(capacity: 4 + unknownPayload.count)
        withUnsafeBytes(of: &unknownLenBE) { unknownRawFrame.append(contentsOf: $0) }
        unknownRawFrame.append(unknownPayload)

        preAuthRawClient.send(unknownRawFrame)
        for _ in 0..<40 where !preAuthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(preAuthClosed, "Unknown pre-auth client frame must disconnect the unauthenticated session")
        XCTAssertTrue(
            preAuthReceivedFrames.contains(where: {
                if case .authFailed = $0 { return true }
                return false
            })
        )

        // 2. Pair iPhone + iPad and verify Keep Mac Awake ends when LAST companion disconnects
        let phoneServerEnd = server.acceptInMemoryCompanion()
        let (phoneProxy, phoneClientEnd) = InMemoryCompanionPipe.pair()
        phoneProxy.onPayload = { phoneServerEnd.send($0) }
        phoneServerEnd.onPayload = { phoneProxy.send($0) }
        phoneProxy.start()
        phoneServerEnd.start()

        let phone = CompanionClientEngine(
            deviceID: "iphone-r4",
            deviceName: "iPhone R4",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r4"
        )
        phone.tileFeedbackDurationSeconds = 0.12
        defer { phone.disconnect() }

        phone.connectInMemoryBluetooth(to: phoneClientEnd, targetName: "Studio Mac R4")
        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phone.submitPIN(server.currentPIN)
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        let padServerEnd = server.acceptInMemoryCompanion()
        let (padProxy, padClientEnd) = InMemoryCompanionPipe.pair()
        padProxy.onPayload = { padServerEnd.send($0) }
        padServerEnd.onPayload = { padProxy.send($0) }
        padProxy.start()
        padServerEnd.start()

        let ipad = CompanionClientEngine(
            deviceID: "ipad-r4",
            deviceName: "iPad R4",
            platform: .iPad,
            userDefaults: defaults,
            storageKeyPrefix: "ipad-r4"
        )
        defer { ipad.disconnect() }

        ipad.connectInMemoryBluetooth(to: padClientEnd, targetName: "Studio Mac R4")
        for _ in 0..<50 {
            if case .awaitingPIN = ipad.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        ipad.submitPIN(server.currentPIN)
        for _ in 0..<50 where !ipad.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ipad.connectionState.isConnected)

        // Enable Keep Mac Awake from iPhone
        phone.setKeepMacAwake(true)
        for _ in 0..<50 where !delegate.awakeMachine.shouldHoldAssertion || !ipad.controlStripState.isKeepMacAwakeEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(delegate.awakeMachine.shouldHoldAssertion)
        XCTAssertTrue(phone.controlStripState.isKeepMacAwakeEnabled)
        XCTAssertTrue(ipad.controlStripState.isKeepMacAwakeEnabled)

        // Disconnect iPad first -> iPhone is still connected, so awake assertion stays active
        ipad.disconnect()
        padClientEnd.cancel()
        padServerEnd.cancel()
        for _ in 0..<50 where server.connectedDeviceCount != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(delegate.awakeMachine.shouldHoldAssertion)

        // Disconnect iPhone (the LAST companion) -> awake assertion ends immediately
        phone.disconnect()
        phoneClientEnd.cancel()
        phoneServerEnd.cancel()
        for _ in 0..<50 where server.connectedDeviceCount != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(delegate.awakeMachine.shouldHoldAssertion)
        XCTAssertFalse(phone.controlStripState.isKeepMacAwakeEnabled)

        // 3. Reconnect iPhone using saved auth token and verify Audio Output switch, 12-window cap + raise, tile flash, and post-auth unknown frame tolerance
        let phoneServerEnd2 = server.acceptInMemoryCompanion()
        let (phoneProxy2, phoneClientEnd2) = InMemoryCompanionPipe.pair()
        phoneProxy2.onPayload = { phoneServerEnd2.send($0) }
        phoneServerEnd2.onPayload = { phoneProxy2.send($0) }
        phoneProxy2.start()
        phoneServerEnd2.start()

        phone.connectInMemoryBluetooth(to: phoneClientEnd2, targetName: "Studio Mac R4", macID: "mac-r4")
        for _ in 0..<60 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)

        // Wait for initial frontmostWindows snapshot (delegate has 15 windows -> capped at 12)
        for _ in 0..<50 where phone.frontmostWindows.windows.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.frontmostWindows.windows.count, 12)
        XCTAssertEqual(phone.frontmostWindows.totalWindowCount, 15)
        XCTAssertTrue(phone.frontmostWindows.isCapped)

        // Tap window #3 to raise
        phone.raiseFrontmostWindow(id: "win-3")
        for _ in 0..<50 where delegate.raisedWindowIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.raisedWindowIDs, ["win-3"])

        // Switch audio output device (verify phone does NOT fake switch prior to Mac confirmation)
        for _ in 0..<50 where phone.controlStripState.audioOutputDevices.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.controlStripState.selectedAudioOutputDeviceID, "built-in-spk")
        phone.selectAudioOutputDevice(id: "usb-dac")
        // Immediately after call (before async server reply), phone has NOT faked the selection
        XCTAssertEqual(phone.controlStripState.selectedAudioOutputDeviceID, "built-in-spk")
        for _ in 0..<50 where phone.controlStripState.selectedAudioOutputDeviceID != "usb-dac" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.controlStripState.selectedAudioOutputDeviceID, "usb-dac")

        // Trigger a tile on Page 0 Slot 0 -> flashes .success briefly, then returns to nil
        let page0 = phone.profile.pages[0]
        let slot0Coord = SlotCoordinate(pageID: page0.id, slotIndex: 0)
        let slot1Coord = SlotCoordinate(pageID: page0.id, slotIndex: 1)
        let slot0Item = try XCTUnwrap(page0.slots[0])

        phone.triggerBarItem(slot0Item, from: slot0Coord)
        for _ in 0..<50 where phone.tileOutcome(for: slot0Coord) == nil {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(phone.tileOutcome(for: slot0Coord), .success)
        XCTAssertNil(phone.tileOutcome(for: slot1Coord))

        // Wait for brief flash to auto-expire back to normal
        for _ in 0..<50 where phone.tileOutcome(for: slot0Coord) != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(phone.tileOutcome(for: slot0Coord))

        // Post-auth unknown client frame AND post-auth unknown server frame stay non-fatal
        phoneProxy2.send(unknownRawFrame)
        let unknownServerPayload = Data(#"{"futureRound99ServerEvent":{"ok":1}}"#.utf8)
        var sLenBE = UInt32(unknownServerPayload.count).bigEndian
        var unknownServerFrame = Data(capacity: 4 + unknownServerPayload.count)
        withUnsafeBytes(of: &sLenBE) { unknownServerFrame.append(contentsOf: $0) }
        unknownServerFrame.append(unknownServerPayload)
        phoneProxy2.send(unknownServerFrame)

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frames must remain non-fatal")
        XCTAssertEqual(server.connectedDeviceCount, 1)
    }
    #endif

    // MARK: - 7. Spotify / Media Transport Router & Hold-to-Repeat

    func testMediaTransportRouterChoosesSpotifyScriptMediaKeyOrFailureWithoutSpotifyInstalled() {
        // Command mapping: play/pause/next/previous route through MacMediaTransportCommand; volume stays on HID media keys
        XCTAssertEqual(MacMediaTransportCommand(systemAction: .mediaPlayPause), .playPause)
        XCTAssertEqual(MacMediaTransportCommand(systemAction: .mediaNext), .nextTrack)
        XCTAssertEqual(MacMediaTransportCommand(systemAction: .mediaPrevious), .previousTrack)
        XCTAssertNil(MacMediaTransportCommand(systemAction: .volumeUp))
        XCTAssertNil(MacMediaTransportCommand(systemAction: .volumeDown))
        XCTAssertNil(MacMediaTransportCommand(systemAction: .volumeMute))

        XCTAssertEqual(MacMediaTransportCommand.playPause.spotifyScriptVerb, "playpause")
        XCTAssertEqual(MacMediaTransportCommand.nextTrack.spotifyScriptVerb, "next track")
        XCTAssertEqual(MacMediaTransportCommand.previousTrack.spotifyScriptVerb, "previous track")

        // Hold-to-repeat on mediaNext remains intact
        XCTAssertTrue(HoldToRepeatPolicy.supportsHoldToRepeat(.mediaNext))
        XCTAssertFalse(HoldToRepeatPolicy.supportsHoldToRepeat(.mediaPlayPause))
        XCTAssertFalse(HoldToRepeatPolicy.supportsHoldToRepeat(.mediaPrevious))

        // 1. Spotify is Now Playing and running -> spotifyScript
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: "com.spotify.client",
                isSpotifyRunning: true
            ),
            .spotifyScript
        )

        // 2. Spotify is Now Playing, NOT running, and no other player is active -> clear failure (no fake success)
        let notRunningRoute = MacMediaTransportRouter.chooseRoute(
            nowPlayingBundleID: "com.spotify.client",
            isSpotifyRunning: false,
            hasOtherActiveMediaClient: false
        )
        XCTAssertEqual(notRunningRoute, .failure(.spotifyNotRunning))
        XCTAssertTrue(
            MacMediaTransportFailureReason.spotifyNotRunning.message(in: .english).contains("Spotify is not running")
        )

        // 3. No Now Playing session registered (common for Spotify on modern macOS) + Spotify running -> spotifyScript
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: nil,
                isSpotifyRunning: true
            ),
            .spotifyScript
        )

        // 4. Music.app or Safari owns active Now Playing -> mediaKey
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: "com.apple.Music",
                isSpotifyRunning: true,
                isNowPlayingPlaying: true,
                isSpotifyPlaying: false
            ),
            .mediaKey
        )
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: "com.apple.Safari",
                isSpotifyRunning: false,
                isNowPlayingPlaying: true
            ),
            .mediaKey
        )

        // 5. Safari holds a paused Now Playing session while Spotify is actively playing or frontmost -> spotifyScript
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: "com.apple.Safari",
                isSpotifyRunning: true,
                isNowPlayingPlaying: false,
                isSpotifyPlaying: true
            ),
            .spotifyScript
        )
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: "com.apple.Safari",
                isSpotifyRunning: true,
                isNowPlayingPlaying: false,
                isSpotifyPlaying: false,
                frontmostBundleID: "com.spotify.client"
            ),
            .spotifyScript
        )

        // 6. Spotify is NOT running and no Now Playing / active audio player exists -> clear failure
        let idleFailure = MacMediaTransportRouter.chooseRoute(
            nowPlayingBundleID: nil,
            isSpotifyRunning: false,
            hasOtherActiveMediaClient: false
        )
        XCTAssertEqual(idleFailure, .failure(.noActiveMediaPlayer))

        // 7. Spotify is NOT running, Now Playing is nil, but another app is actively outputting audio -> mediaKey
        XCTAssertEqual(
            MacMediaTransportRouter.chooseRoute(
                nowPlayingBundleID: nil,
                isSpotifyRunning: false,
                hasOtherActiveMediaClient: true
            ),
            .mediaKey
        )
    }

    // MARK: - 8. System Sound Menu Visibility & AirPlay / HomePod List Merger

    func testHiddenDeviceOmittedUnlessLiveDefaultOrSystemMenuAirPlayReceiver() {
        let builtIn = MacAudioRawDeviceRecord(
            audioObjectID: 70,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Pro Speakers",
            transportKind: .builtIn,
            outputChannelCount: 2,
            isHidden: false
        )
        let hiddenInternalOutput = MacAudioRawDeviceRecord(
            audioObjectID: 88,
            uid: "HiddenDiagnosticOutputUID",
            name: "Hidden Internal Output",
            transportKind: .virtualOrOther,
            outputChannelCount: 2,
            isHidden: true
        )
        let hiddenAirPlayReceiver = MacAudioRawDeviceRecord(
            audioObjectID: 92,
            uid: "82:1C:79:BC:CA:66-airplay",
            name: "Bedroom HomePod",
            transportKind: .airPlay,
            outputChannelCount: 2,
            isHidden: true,
            modelUID: "AudioAccessory6,1"
        )
        let privateAutoAggregate = MacAudioRawDeviceRecord(
            audioObjectID: 95,
            uid: "CADefaultDeviceAggregate-12345-0",
            name: "CADefaultDeviceAggregate",
            transportKind: .virtualOrOther,
            outputChannelCount: 2,
            isHidden: false,
            isPrivateAggregate: true
        )
        let accessibilitySpeech = MacAudioRawDeviceRecord(
            audioObjectID: 56,
            uid: "com.apple.accessibility.audioPlugin.AXSpeech.output",
            name: "AXSpeech Output",
            transportKind: .virtualOrOther,
            outputChannelCount: 2,
            isHidden: true
        )
        let userMultiOutputDevice = MacAudioRawDeviceRecord(
            audioObjectID: 104,
            uid: "~:AMS2_StackedOutput:0",
            name: "Multi-Output Device",
            transportKind: .virtualOrOther,
            outputChannelCount: 2,
            isHidden: false,
            isPrivateAggregate: false
        )

        let records = [
            builtIn,
            hiddenInternalOutput,
            hiddenAirPlayReceiver,
            privateAutoAggregate,
            accessibilitySpeech,
            userMultiOutputDevice
        ]

        // Case A: Built-in speakers are the live default (70).
        // - hiddenInternalOutput (88), privateAutoAggregate (95), and accessibilitySpeech (56) MUST be omitted.
        // - hiddenAirPlayReceiver (92) and userMultiOutputDevice (104) MUST be included.
        let snapshotWhenBuiltInDefault = MacAudioOutputSwitchEngine.enumerateSnapshot(
            records: records,
            airPlayReceivers: [],
            defaultOutputObjectID: 70,
            isDefaultOutputSettable: true
        )
        let idsWhenBuiltInDefault = snapshotWhenBuiltInDefault.devices.map(\.id)
        XCTAssertEqual(
            idsWhenBuiltInDefault,
            ["BuiltInSpeakerDevice", "82:1C:79:BC:CA:66-airplay", "~:AMS2_StackedOutput:0"]
        )
        XCTAssertEqual(snapshotWhenBuiltInDefault.selectedID, "BuiltInSpeakerDevice")

        // Case B: Hidden device (88) IS the live default output -> MUST be included so checkmark matches system state.
        let snapshotWhenHiddenDefault = MacAudioOutputSwitchEngine.enumerateSnapshot(
            records: records,
            airPlayReceivers: [],
            defaultOutputObjectID: 88,
            isDefaultOutputSettable: true
        )
        let idsWhenHiddenDefault = snapshotWhenHiddenDefault.devices.map(\.id)
        XCTAssertTrue(idsWhenHiddenDefault.contains("HiddenDiagnosticOutputUID"))
        XCTAssertEqual(snapshotWhenHiddenDefault.selectedID, "HiddenDiagnosticOutputUID")
        XCTAssertFalse(idsWhenHiddenDefault.contains("CADefaultDeviceAggregate-12345-0"))
    }

    func testAudioOutputListMergerIncludesHomePodAirPlaySurvivesCoreAudioRestartAndHandlesSelectionHonestly() throws {
        let initialRecords: [MacAudioRawDeviceRecord] = [
            MacAudioRawDeviceRecord(
                audioObjectID: 70,
                uid: "BuiltInSpeakerDevice",
                name: "MacBook Pro Speakers",
                transportKind: .builtIn,
                outputChannelCount: 2
            ),
            MacAudioRawDeviceRecord(
                audioObjectID: 84,
                uid: "USB-DAC-01",
                name: "USB Studio Headphones",
                transportKind: .usb,
                outputChannelCount: 2
            )
        ]

        let idleHomePod = MacDiscoveredAirPlayReceiver(
            deviceID: "82:1C:79:BC:CA:66",
            name: "Living Room HomePod",
            model: "AudioAccessory6,1",
            groupID: "3D6ABC46-4B95-4E19-BBCA-87C5EF239C04",
            isGroupLeader: true,
            audioBoxObjectID: 0,
            audioDeviceObjectID: 0,
            isSelectableViaCoreAudio: false
        )

        let driver = MockAudioOutputHardwareDriver(
            records: initialRecords,
            defaultOutputObjectID: 70,
            defaultSystemOutputObjectID: 70,
            airPlayReceivers: [idleHomePod]
        )

        // 1. Merged snapshot includes CoreAudio outputs + injected HomePod AirPlay receiver
        let initialSnapshot = MacAudioOutputSwitchEngine.enumerateSnapshot(using: driver)
        XCTAssertEqual(initialSnapshot.devices.map(\.name), [
            "MacBook Pro Speakers",
            "USB Studio Headphones",
            "Living Room HomePod"
        ])
        XCTAssertEqual(initialSnapshot.selectedID, "BuiltInSpeakerDevice")

        let mergedHomePod = try XCTUnwrap(initialSnapshot.devices.first(where: { $0.name == "Living Room HomePod" }))
        XCTAssertTrue(mergedHomePod.isAirPlay)
        XCTAssertEqual(mergedHomePod.transportKind, .airPlay)
        XCTAssertTrue(mergedHomePod.isHomePod)
        XCTAssertEqual(mergedHomePod.sfSymbol, "homepod.fill")
        XCTAssertEqual(mergedHomePod.id, "airplay:821c79bcca66")
        XCTAssertFalse(mergedHomePod.isSelectable)
        XCTAssertNotNil(mergedHomePod.selectionUnavailableReason(in: .english))

        // 2. Simulate CoreAudio (`coreaudiod`) restart: all AudioObjectIDs change, stable IDs survive unchanged
        driver.records = [
            MacAudioRawDeviceRecord(
                audioObjectID: 312,
                uid: "BuiltInSpeakerDevice",
                name: "MacBook Pro Speakers",
                transportKind: .builtIn,
                outputChannelCount: 2
            ),
            MacAudioRawDeviceRecord(
                audioObjectID: 419,
                uid: "USB-DAC-01",
                name: "USB Studio Headphones",
                transportKind: .usb,
                outputChannelCount: 2
            )
        ]
        driver.defaultOutputObjectID = 312
        driver.defaultSystemOutputObjectID = 312

        let postRestartSnapshot = MacAudioOutputSwitchEngine.enumerateSnapshot(using: driver)
        XCTAssertEqual(postRestartSnapshot.devices.map(\.id), initialSnapshot.devices.map(\.id))
        let postRestartHomePod = try XCTUnwrap(postRestartSnapshot.devices.first(where: { $0.isHomePod }))
        XCTAssertEqual(postRestartHomePod.id, mergedHomePod.id)

        // 3. Attempting to switch to an idle AirPlay receiver without a public selection path fails honestly
        //    and NEVER pretends the switch happened.
        let rejectedSwitch = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: mergedHomePod.id,
            language: .english,
            using: driver
        )
        XCTAssertFalse(rejectedSwitch.success)
        XCTAssertTrue(rejectedSwitch.detail.contains("Control Center"))
        XCTAssertEqual(rejectedSwitch.snapshot.selectedID, "BuiltInSpeakerDevice")
        XCTAssertEqual(driver.defaultOutputObjectID, 312)

        // 4. When CoreAudio exposes an acquirable AirPlay box / device for HomePod, selecting it picks HomePod,
        //    updates the checkmark to match, and switching back to MacBook Pro Speakers restores built-in output.
        driver.airPlayReceivers = [
            MacDiscoveredAirPlayReceiver(
                deviceID: "82:1C:79:BC:CA:66",
                name: "Living Room HomePod",
                model: "AudioAccessory6,1",
                audioBoxObjectID: 501,
                audioDeviceObjectID: 0,
                isSelectableViaCoreAudio: true
            )
        ]
        driver.onAcquireAirPlayBox = { [weak driver] boxID in
            guard boxID == 501, let driver else { return (nil, -1) }
            let airPlayDevice = MacAudioRawDeviceRecord(
                audioObjectID: 610,
                uid: "82:1C:79:BC:CA:66-airplay",
                name: "Living Room HomePod",
                transportKind: .airPlay,
                outputChannelCount: 2,
                isHidden: false,
                modelUID: "AudioAccessory6,1"
            )
            driver.records.append(airPlayDevice)
            driver.airPlayReceivers = [
                MacDiscoveredAirPlayReceiver(
                    deviceID: "82:1C:79:BC:CA:66",
                    name: "Living Room HomePod",
                    model: "AudioAccessory6,1",
                    audioBoxObjectID: 501,
                    audioDeviceObjectID: 610,
                    isSelectableViaCoreAudio: true
                )
            ]
            return (610, 0)
        }

        let selectableSnapshot = MacAudioOutputSwitchEngine.enumerateSnapshot(using: driver)
        let selectableHomePod = try XCTUnwrap(selectableSnapshot.devices.first(where: { $0.id == mergedHomePod.id }))
        XCTAssertTrue(selectableHomePod.isSelectable)

        let homePodSwitch = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: mergedHomePod.id,
            language: .english,
            using: driver
        )
        XCTAssertTrue(homePodSwitch.success)
        XCTAssertEqual(homePodSwitch.snapshot.selectedID, mergedHomePod.id)
        XCTAssertEqual(driver.defaultOutputObjectID, 610)

        let backToSpeakers = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: "BuiltInSpeakerDevice",
            language: .english,
            using: driver
        )
        XCTAssertTrue(backToSpeakers.success)
        XCTAssertEqual(backToSpeakers.snapshot.selectedID, "BuiltInSpeakerDevice")
        XCTAssertEqual(driver.defaultOutputObjectID, 312)
    }

    func testAirPlayBonjourParserExtractsHomePodDeduplicatesStereoPairsAndExcludesLocalMac() {
        let entries: [MacAirPlayBonjourServiceEntry] = [
            // HomePod 2nd-gen stereo pair ("主卧") advertising two units under the same gid
            MacAirPlayBonjourServiceEntry(
                serviceName: "821C79BCCA66@主卧",
                serviceType: "_raop._tcp",
                txtRecord: ["am": "AudioAccessory6,1"]
            ),
            MacAirPlayBonjourServiceEntry(
                serviceName: "主卧",
                serviceType: "_airplay._tcp",
                txtRecord: [
                    "deviceid": "82:1C:79:BC:CA:66",
                    "model": "AudioAccessory6,1",
                    "features": "0x4A7FCA00,0xBC354BD0",
                    "gid": "3D6ABC46-4B95-4E19-BBCA-87C5EF239C04+271ACDAC-3DE0-48C3-B27D-D70758969C07",
                    "igl": "1"
                ]
            ),
            MacAirPlayBonjourServiceEntry(
                serviceName: "主卧",
                serviceType: "_airplay._tcp",
                txtRecord: [
                    "deviceid": "90:DD:5D:AA:BB:CC",
                    "model": "AudioAccessory6,1",
                    "features": "0x4A7FCA00,0xBC354BD0",
                    "gid": "3D6ABC46-4B95-4E19-BBCA-87C5EF239C04+271ACDAC-3DE0-48C3-B27D-D70758969C07",
                    "igl": "0"
                ]
            ),
            // Two third-party AirPlay speakers sharing placeholder MAC 10:00:00:00:00:00 must NOT collide
            MacAirPlayBonjourServiceEntry(
                serviceName: "100000000000@Speaker One",
                serviceType: "_raop._tcp",
                txtRecord: ["am": "Shairport,1"]
            ),
            MacAirPlayBonjourServiceEntry(
                serviceName: "100000000000@Speaker Two",
                serviceType: "_raop._tcp",
                txtRecord: ["am": "Shairport,1"]
            ),
            // Non-audio AirPlay screen-only endpoint (no 0x200 audio bit, no RAOP) must be excluded
            MacAirPlayBonjourServiceEntry(
                serviceName: "Projector Only",
                serviceType: "_airplay._tcp",
                txtRecord: [
                    "deviceid": "AA:BB:CC:11:22:33",
                    "model": "Projector1,1",
                    "features": "0x1"
                ]
            ),
            // Local Mac's own AirPlay Receiver service must be excluded
            MacAirPlayBonjourServiceEntry(
                serviceName: "AA:BB:CC:DD:EE:FF@This MacBook Pro",
                serviceType: "_raop._tcp",
                txtRecord: ["am": "Mac14,9"]
            )
        ]

        let parsed = MacAirPlayBonjourParser.parseReceivers(
            entries: entries,
            localHardwareIdentifiers: ["aa:bb:cc:dd:ee:ff"]
        )

        XCTAssertEqual(parsed.map(\.name), ["Speaker One", "Speaker Two", "主卧"])
        let homePod = parsed.first(where: { $0.name == "主卧" })
        XCTAssertEqual(homePod?.model, "AudioAccessory6,1")
        XCTAssertEqual(homePod?.stableOutputID, "airplay:821c79bcca66")

        let speakerOne = parsed.first(where: { $0.name == "Speaker One" })
        let speakerTwo = parsed.first(where: { $0.name == "Speaker Two" })
        XCTAssertNotEqual(speakerOne?.stableOutputID, speakerTwo?.stableOutputID)
    }
}

#if os(macOS)
@MainActor
private final class Round04WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var awakeMachine = MacAwakeAssertionStateMachine()
    var raisedWindowIDs: [String] = []

    var controlStripState = ControlStripState(
        volume: 0.6,
        isVolumeMuted: false,
        brightness: 0.75,
        isBrightnessAvailable: true,
        isMicMuted: false,
        isKeepMacAwakeEnabled: false,
        audioOutputDevices: [
            MacAudioOutputDevice(id: "built-in-spk", audioObjectID: 41, name: "Mac Studio Speakers", transportKind: .builtIn),
            MacAudioOutputDevice(id: "usb-dac", audioObjectID: 77, name: "USB Studio DAC", transportKind: .usb)
        ],
        selectedAudioOutputDeviceID: "built-in-spk",
        canSwitchAudioOutput: true
    )

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
            _ = awakeMachine.deviceConnected(device.deviceID)
            let holding = awakeMachine.setToggleEnabled(enabled)
            controlStripState.isKeepMacAwakeEnabled = holding
            server?.broadcastControlStripState(controlStripState)
            reply(.actionFeedback(success: true, title: "Keep Mac Awake", detail: holding ? "On" : "Off"))

        case .setAudioOutputDevice(let deviceID):
            guard controlStripState.canSwitchAudioOutput,
                  let matched = controlStripState.audioOutputDevices.first(where: { $0.id == deviceID }) else {
                reply(.actionFeedback(success: false, title: "Audio Output", detail: "Cannot switch"))
                return
            }
            controlStripState.selectedAudioOutputDeviceID = matched.id
            server?.broadcastControlStripState(controlStripState)
            reply(.actionFeedback(success: true, title: matched.name, detail: "Switched"))

        case .requestFrontmostAppWindows:
            let fifteenWindows = (0..<15).map { idx in
                MacFrontmostWindowItem(
                    id: "win-\(idx)",
                    title: "Safari Window \(idx + 1)",
                    index: idx,
                    isMainOrFocused: idx == 0
                )
            }
            let snapshot = FrontmostAppWindowSnapshot(
                bundleIdentifier: "com.apple.Safari",
                appName: "Safari",
                windows: fifteenWindows
            )
            reply(.frontmostWindowsUpdated(snapshot))

        case .raiseFrontmostWindow(let windowID):
            raisedWindowIDs.append(windowID)
            reply(.actionFeedback(success: true, title: "Raised", detail: windowID))

        case .triggerBarItem(let item):
            reply(.actionFeedback(success: true, title: item.displayTitle(), detail: "OK"))

        default:
            break
        }
    }
}
#endif

private final class MockAudioOutputHardwareDriver: MacAudioOutputHardwareDriver {
    var records: [MacAudioRawDeviceRecord]
    var airPlayReceivers: [MacDiscoveredAirPlayReceiver]
    var defaultOutputObjectID: UInt32
    var defaultSystemOutputObjectID: UInt32
    var hasDefaultSystemOutput: Bool
    var isDefaultOutputSettable: Bool
    var isDefaultSystemOutputSettable: Bool
    var forcedDefaultOutputWriteStatus: Int32?
    var forcedSystemOutputWriteStatus: Int32?
    var translatedUIDOverrides: [String: UInt32] = [:]
    var runningProcesses: [MacAudioRunningProcessRecord]?
    var movedProcesses: [UInt32: UInt32] = [:]
    var runningDeviceIDs: Set<UInt32> = []
    var onAcquireAirPlayBox: ((UInt32) -> (UInt32?, Int32))?

    init(
        records: [MacAudioRawDeviceRecord],
        defaultOutputObjectID: UInt32,
        defaultSystemOutputObjectID: UInt32,
        hasDefaultSystemOutput: Bool = true,
        isDefaultOutputSettable: Bool = true,
        isDefaultSystemOutputSettable: Bool = true,
        forcedDefaultOutputWriteStatus: Int32? = nil,
        forcedSystemOutputWriteStatus: Int32? = nil,
        runningProcesses: [MacAudioRunningProcessRecord]? = [],
        airPlayReceivers: [MacDiscoveredAirPlayReceiver] = []
    ) {
        self.records = records
        self.airPlayReceivers = airPlayReceivers
        self.defaultOutputObjectID = defaultOutputObjectID
        self.defaultSystemOutputObjectID = defaultSystemOutputObjectID
        self.hasDefaultSystemOutput = hasDefaultSystemOutput
        self.isDefaultOutputSettable = isDefaultOutputSettable
        self.isDefaultSystemOutputSettable = isDefaultSystemOutputSettable
        self.forcedDefaultOutputWriteStatus = forcedDefaultOutputWriteStatus
        self.forcedSystemOutputWriteStatus = forcedSystemOutputWriteStatus
        self.runningProcesses = runningProcesses
    }

    func isSelectorAvailable(_ selector: MacAudioDefaultSelector) -> Bool {
        switch selector {
        case .defaultOutput:
            return true
        case .defaultSystemOutput:
            return hasDefaultSystemOutput
        }
    }

    func isSelectorSettable(_ selector: MacAudioDefaultSelector) -> (isSettable: Bool, status: Int32) {
        switch selector {
        case .defaultOutput:
            return (isDefaultOutputSettable, 0)
        case .defaultSystemOutput:
            guard hasDefaultSystemOutput else { return (false, -1) }
            return (isDefaultSystemOutputSettable, 0)
        }
    }

    func readDefaultDevice(for selector: MacAudioDefaultSelector) -> (objectID: UInt32, status: Int32) {
        switch selector {
        case .defaultOutput:
            return (defaultOutputObjectID, 0)
        case .defaultSystemOutput:
            guard hasDefaultSystemOutput else { return (0, -1) }
            return (defaultSystemOutputObjectID, 0)
        }
    }

    func writeDefaultDevice(_ objectID: UInt32, for selector: MacAudioDefaultSelector) -> Int32 {
        switch selector {
        case .defaultOutput:
            if let forced = forcedDefaultOutputWriteStatus {
                return forced
            }
            defaultOutputObjectID = objectID
            return 0
        case .defaultSystemOutput:
            guard hasDefaultSystemOutput else { return -1 }
            if let forced = forcedSystemOutputWriteStatus {
                return forced
            }
            defaultSystemOutputObjectID = objectID
            return 0
        }
    }

    func readLiveDeviceRecords() -> [MacAudioRawDeviceRecord] {
        records
    }

    func readDiscoveredAirPlayReceivers() -> [MacDiscoveredAirPlayReceiver] {
        airPlayReceivers
    }

    func acquireAirPlayBox(_ boxObjectID: UInt32) -> (deviceObjectID: UInt32?, status: Int32) {
        if let onAcquireAirPlayBox {
            return onAcquireAirPlayBox(boxObjectID)
        }
        return (nil, -1)
    }

    func translateUIDToLiveObjectID(_ uid: String) -> UInt32? {
        if let override = translatedUIDOverrides[uid] {
            return override
        }
        return records.first(where: { $0.uid == uid })?.audioObjectID
    }

    func readRunningOutputProcesses(excludingCurrentProcess: Bool) -> [MacAudioRunningProcessRecord]? {
        runningProcesses
    }

    func writeProcessOutputDevice(processObjectID: UInt32, targetDeviceObjectID: UInt32) -> Int32 {
        movedProcesses[processObjectID] = targetDeviceObjectID
        return 0
    }

    func isDeviceRunningOutputAudio(_ objectID: UInt32) -> Bool {
        runningDeviceIDs.contains(objectID)
    }
}
