import Foundation
import XCTest
@testable import ChocliftCore

final class AudioInputPickerTests: XCTestCase {

    // MARK: - 1. Enumeration & Classification (Built-in Mic, Headset Mic, USB Mic)

    func testAudioInputEnumerationClassifiesBuiltInHeadsetAndUSBMicsAndExcludesOutputs() {
        let builtInSpeakers = MacAudioRawDeviceRecord(
            audioObjectID: 70,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Pro Speakers",
            transportKind: .builtIn,
            outputChannelCount: 2,
            inputChannelCount: 0,
            canBeDefaultInput: false
        )
        let builtInMic = MacAudioRawDeviceRecord(
            audioObjectID: 77,
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Pro Microphone",
            transportKind: .builtIn,
            outputChannelCount: 0,
            modelUID: "Digital Mic",
            inputChannelCount: 1,
            canBeDefaultInput: true,
            inputDataSourceCode: MacAudioInputKind.internalMicrophoneFourCC
        )
        let wiredHeadsetMic = MacAudioRawDeviceRecord(
            audioObjectID: 84,
            uid: "BuiltInHeadphoneInputDevice",
            name: "External Microphone",
            transportKind: .builtIn,
            outputChannelCount: 0,
            inputChannelCount: 1,
            canBeDefaultInput: true,
            inputDataSourceCode: MacAudioInputKind.headsetMicrophoneFourCC
        )
        let bluetoothHeadsetMic = MacAudioRawDeviceRecord(
            audioObjectID: 91,
            uid: "AA-BB-CC-AirPods-In",
            name: "AirPods Pro",
            transportKind: .bluetooth,
            outputChannelCount: 2,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )
        let usbMic = MacAudioRawDeviceRecord(
            audioObjectID: 108,
            uid: "AppleUSBAudioEngine:Blue:Yeti:001",
            name: "Yeti Stereo Microphone",
            transportKind: .usb,
            outputChannelCount: 2,
            inputChannelCount: 2,
            canBeDefaultInput: true
        )
        let privateAutoAggregate = MacAudioRawDeviceRecord(
            audioObjectID: 130,
            uid: "CADefaultDeviceAggregate-501-0",
            name: "Aggregate Input",
            transportKind: .virtualOrOther,
            outputChannelCount: 0,
            isHidden: true,
            isPrivateAggregate: true,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )

        let snapshot = MacAudioInputSwitchEngine.enumerateSnapshot(
            records: [
                builtInSpeakers,
                builtInMic,
                wiredHeadsetMic,
                bluetoothHeadsetMic,
                usbMic,
                privateAutoAggregate
            ],
            defaultInputObjectID: 77,
            isDefaultInputSettable: true
        )

        XCTAssertTrue(snapshot.canSwitch)
        XCTAssertEqual(snapshot.selectedID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(
            snapshot.devices.map(\.id),
            [
                "BuiltInMicrophoneDevice",
                "BuiltInHeadphoneInputDevice",
                "AA-BB-CC-AirPods-In",
                "AppleUSBAudioEngine:Blue:Yeti:001"
            ]
        )
        XCTAssertEqual(
            snapshot.devices.map(\.inputKind),
            [.builtInMic, .headsetMic, .headsetMic, .usbMic]
        )
        XCTAssertEqual(snapshot.devices[0].inputSubtitle(in: .english), "Built-in Mic")
        XCTAssertEqual(snapshot.devices[1].inputSubtitle(in: .english), "Headset Mic")
        XCTAssertEqual(snapshot.devices[2].inputSubtitle(in: .english), "Headset Mic")
        XCTAssertEqual(snapshot.devices[3].inputSubtitle(in: .english), "USB Mic")
    }

    // MARK: - 2. UID Resolution, Missing-UID Fallback & Hidden Live Default

    func testAudioInputUIDResolutionMissingUIDFallbackAndHiddenLiveDefault() {
        let builtInMic = MacAudioRawDeviceRecord(
            audioObjectID: 77,
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Pro Microphone",
            transportKind: .builtIn,
            outputChannelCount: 0,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )
        let uidLessUSBMic = MacAudioRawDeviceRecord(
            audioObjectID: 96,
            uid: nil,
            name: "USB Podcast Mic",
            transportKind: .usb,
            outputChannelCount: 0,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )
        let hiddenSystemInput = MacAudioRawDeviceRecord(
            audioObjectID: 140,
            uid: "com.apple.audio.HiddenInput",
            name: "Hidden System Input",
            transportKind: .virtualOrOther,
            outputChannelCount: 0,
            isHidden: true,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )

        // Hidden input stays omitted when not the live default
        let normalSnap = MacAudioInputSwitchEngine.enumerateSnapshot(
            records: [builtInMic, uidLessUSBMic, hiddenSystemInput],
            defaultInputObjectID: 77,
            isDefaultInputSettable: true
        )
        XCTAssertEqual(
            normalSnap.devices.map(\.id),
            ["BuiltInMicrophoneDevice", "fallback-input:usb:usb podcast mic"]
        )
        XCTAssertEqual(normalSnap.selectedID, "BuiltInMicrophoneDevice")

        // Hidden input IS included and checked when it is the live default
        let hiddenDefaultSnap = MacAudioInputSwitchEngine.enumerateSnapshot(
            records: [builtInMic, uidLessUSBMic, hiddenSystemInput],
            defaultInputObjectID: 140,
            isDefaultInputSettable: true
        )
        XCTAssertEqual(hiddenDefaultSnap.selectedID, "com.apple.audio.HiddenInput")

        // Fallback ID survives coreaudiod object ID change (96 -> 212) ONLY for UID-less device
        let restartedUIDLessUSBMic = MacAudioRawDeviceRecord(
            audioObjectID: 212,
            uid: nil,
            name: "USB Podcast Mic",
            transportKind: .usb,
            outputChannelCount: 0,
            inputChannelCount: 1,
            canBeDefaultInput: true
        )
        let resolvedFallback = MacAudioInputSwitchEngine.resolveTarget(
            requestedID: "fallback-input:usb:usb podcast mic",
            in: [builtInMic, restartedUIDLessUSBMic],
            defaultInputObjectID: 77
        )
        XCTAssertEqual(resolvedFallback?.record.audioObjectID, 212)

        // Fallback ID never matches a device that actually has a non-empty UID
        let fallbackAgainstUIDDevice = MacAudioInputSwitchEngine.resolveTarget(
            requestedID: MacAudioInputDevice.fallbackID(transportKind: .builtIn, name: "MacBook Pro Microphone"),
            in: [builtInMic, restartedUIDLessUSBMic],
            defaultInputObjectID: 77
        )
        XCTAssertNil(fallbackAgainstUIDDevice)
    }

    // MARK: - 3. Stale Object ID Never Selects Wrong Input & Live UID Re-Resolution Before Set

    func testStaleObjectIDNeverSelectsWrongInputAndUIDIsReResolvedBeforeSet() {
        let driver = MockAudioInputHardwareDriver(
            records: [
                MacAudioRawDeviceRecord(
                    audioObjectID: 48,
                    uid: "BuiltInMicrophoneDevice",
                    name: "MacBook Pro Microphone",
                    transportKind: .builtIn,
                    outputChannelCount: 0,
                    inputChannelCount: 1
                ),
                // Object ID 77 used to be USB Mic before coreaudiod restart; now belongs to Headset Mic!
                MacAudioRawDeviceRecord(
                    audioObjectID: 77,
                    uid: "Headset-Mic-UID",
                    name: "External Microphone",
                    transportKind: .builtIn,
                    outputChannelCount: 0,
                    inputChannelCount: 1,
                    inputDataSourceCode: MacAudioInputKind.headsetMicrophoneFourCC
                ),
                // USB Mic moved to object ID 142 after coreaudiod restart
                MacAudioRawDeviceRecord(
                    audioObjectID: 142,
                    uid: "USB-Mic-UID",
                    name: "USB Studio Mic",
                    transportKind: .usb,
                    outputChannelCount: 0,
                    inputChannelCount: 1
                )
            ],
            defaultInputObjectID: 48
        )

        // 1. Stale object ID strings cannot select object ID 77 (Headset Mic)
        for staleID in ["77", "audio-77", "audio-obj-77", "142"] {
            let staleResult = MacAudioInputSwitchEngine.performSwitch(
                requestedID: staleID,
                language: .english,
                using: driver
            )
            XCTAssertFalse(staleResult.success)
            XCTAssertEqual(driver.defaultInputObjectID, 48, "Stale object ID \(staleID) must never select wrong mic")
            XCTAssertEqual(driver.writeCallObjectIDs, [], "Stale object ID must never invoke writeDefaultInputDevice")
            XCTAssertEqual(staleResult.snapshot.selectedID, "BuiltInMicrophoneDevice")
        }

        // 2. Race condition: if UID translation fails (returns nil) right before set because USB mic unplugged
        // and object ID 142 was recycled, performSwitch must abort instead of writing cached 142!
        driver.disableAutoUIDLookupFor.insert("USB-Mic-UID")
        let unpluggedBeforeSetResult = MacAudioInputSwitchEngine.performSwitch(
            requestedID: "USB-Mic-UID",
            language: .english,
            using: driver
        )
        XCTAssertFalse(unpluggedBeforeSetResult.success)
        XCTAssertEqual(driver.defaultInputObjectID, 48)
        XCTAssertEqual(driver.writeCallObjectIDs, [])
        XCTAssertEqual(unpluggedBeforeSetResult.snapshot.selectedID, "BuiltInMicrophoneDevice")
        driver.disableAutoUIDLookupFor.removeAll()

        // 3. Race condition: if UID translation returns an object ID that now belongs to a DIFFERENT UID (77 = Headset),
        // performSwitch detects the mismatch and aborts before writing!
        driver.translatedUIDOverrides["USB-Mic-UID"] = 77
        let hijackedObjectIDResult = MacAudioInputSwitchEngine.performSwitch(
            requestedID: "USB-Mic-UID",
            language: .english,
            using: driver
        )
        XCTAssertFalse(hijackedObjectIDResult.success)
        XCTAssertEqual(driver.defaultInputObjectID, 48)
        XCTAssertEqual(driver.writeCallObjectIDs, [])
        XCTAssertEqual(hijackedObjectIDResult.snapshot.selectedID, "BuiltInMicrophoneDevice")

        // 4. Live UID re-resolution returns new live object ID (209) immediately before set -> sets 209 cleanly!
        driver.translatedUIDOverrides["USB-Mic-UID"] = 209
        driver.records[2].audioObjectID = 209

        let liveResult = MacAudioInputSwitchEngine.performSwitch(
            requestedID: "USB-Mic-UID",
            language: .english,
            using: driver
        )
        XCTAssertTrue(liveResult.success)
        XCTAssertEqual(driver.translatedUIDQueries.last, "USB-Mic-UID")
        XCTAssertEqual(driver.writeCallObjectIDs, [209])
        XCTAssertEqual(driver.defaultInputObjectID, 209)
        XCTAssertEqual(liveResult.snapshot.selectedID, "USB-Mic-UID")
    }

    // MARK: - 4. OSStatus Failure Reporting & Non-Moving Checkmark

    func testAudioInputFailureShowsOSStatusAndDoesNotMoveCheckmark() {
        let records = [
            MacAudioRawDeviceRecord(
                audioObjectID: 48,
                uid: "BuiltInMicrophoneDevice",
                name: "MacBook Pro Microphone",
                transportKind: .builtIn,
                outputChannelCount: 0,
                inputChannelCount: 1
            ),
            MacAudioRawDeviceRecord(
                audioObjectID: 92,
                uid: "USB-Mic-UID",
                name: "USB Studio Mic",
                transportKind: .usb,
                outputChannelCount: 0,
                inputChannelCount: 1
            )
        ]

        // 1. CoreAudio write returns non-zero OSStatus ('what' = 560227702)
        let failingDriver = MockAudioInputHardwareDriver(
            records: records,
            defaultInputObjectID: 48,
            forcedWriteStatus: 560227702
        )
        let failedRes = MacAudioInputSwitchEngine.performSwitch(
            requestedID: "USB-Mic-UID",
            language: .english,
            using: failingDriver
        )
        XCTAssertFalse(failedRes.success)
        XCTAssertEqual(failedRes.defaultInputStatus, 560227702)
        XCTAssertTrue(failedRes.detail.contains("560227702"), "Failure detail must show OSStatus: \(failedRes.detail)")
        XCTAssertFalse(failedRes.title.localizedCaseInsensitiveContains("read-only"))
        XCTAssertEqual(failingDriver.defaultInputObjectID, 48)
        XCTAssertEqual(failedRes.snapshot.selectedID, "BuiltInMicrophoneDevice", "Checkmark must remain on previous input")

        // 2. Read-only property never writes or fakes selection
        let readOnlyDriver = MockAudioInputHardwareDriver(
            records: records,
            defaultInputObjectID: 48,
            isDefaultInputSettableFlag: false
        )
        let readOnlyRes = MacAudioInputSwitchEngine.performSwitch(
            requestedID: "USB-Mic-UID",
            language: .english,
            using: readOnlyDriver
        )
        XCTAssertFalse(readOnlyRes.success)
        XCTAssertTrue(readOnlyRes.title.localizedCaseInsensitiveContains("Read-Only"))
        XCTAssertEqual(readOnlyDriver.writeCallObjectIDs, [])
        XCTAssertEqual(readOnlyRes.snapshot.selectedID, "BuiltInMicrophoneDevice")
    }

    // MARK: - 5. ControlStripState Round-Trip, Legacy Decode & Device Change Refresh Detection

    func testControlStripStateAudioInputRoundTripLegacyDecodeAndChangeRefresh() throws {
        let legacyJSON = Data(#"{"volume":0.5,"isVolumeMuted":false,"brightness":0.8,"isBrightnessAvailable":true,"isMicMuted":false,"canUndoWindowMove":false}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ControlStripState.self, from: legacyJSON)
        XCTAssertTrue(decodedLegacy.audioInputDevices.isEmpty)
        XCTAssertNil(decodedLegacy.selectedAudioInputDeviceID)
        XCTAssertTrue(decodedLegacy.canSwitchAudioInput)

        let builtInMic = MacAudioInputDevice(
            id: "BuiltInMicrophoneDevice",
            audioObjectID: 77,
            name: "MacBook Pro Microphone",
            transportKind: .builtIn,
            inputKind: .builtInMic
        )
        let usbMic = MacAudioInputDevice(
            id: "USB-Mic-UID",
            audioObjectID: 108,
            name: "USB Studio Mic",
            transportKind: .usb,
            inputKind: .usbMic
        )

        let stateA = ControlStripState(
            audioInputDevices: [builtInMic],
            selectedAudioInputDeviceID: builtInMic.id,
            canSwitchAudioInput: true
        )
        let stateBHotPlugged = ControlStripState(
            audioInputDevices: [builtInMic, usbMic],
            selectedAudioInputDeviceID: builtInMic.id,
            canSwitchAudioInput: true
        )
        let stateCSwitched = ControlStripState(
            audioInputDevices: [builtInMic, usbMic],
            selectedAudioInputDeviceID: usbMic.id,
            canSwitchAudioInput: true
        )

        XCTAssertTrue(stateBHotPlugged.hasMeaningfulDifference(from: stateA), "Hot-plugging a mic must trigger refresh")
        XCTAssertTrue(stateCSwitched.hasMeaningfulDifference(from: stateBHotPlugged), "Changing default mic must trigger refresh")

        let encoded = try JSONEncoder().encode(stateCSwitched)
        let decoded = try JSONDecoder().decode(ControlStripState.self, from: encoded)
        XCTAssertEqual(decoded, stateCSwitched)
        XCTAssertEqual(decoded.currentAudioInputDevice, usbMic)

        // Stale selectedAudioInputDeviceID is never exposed or encoded
        let staleInputState = ControlStripState(
            audioInputDevices: [builtInMic],
            selectedAudioInputDeviceID: "unplugged-usb-mic",
            canSwitchAudioInput: false
        )
        XCTAssertNil(staleInputState.selectedAudioInputDeviceID)
        XCTAssertNil(staleInputState.currentAudioInputDevice)
        let staleJSON = String(decoding: try JSONEncoder().encode(staleInputState), as: UTF8.self)
        XCTAssertFalse(staleJSON.contains("selectedAudioInputDeviceID"))
    }

    // MARK: - 6. iPhone & Watch Same Command, Protocol v3 Unchanged, OSStatus Non-Move & Non-Fatal Unknown Post-Auth Frames

    @MainActor
    func testIPhoneAndWatchSendSameInputCommandRefreshOnDeviceChangeKeepProtocolV3AndIgnoreUnknownPostAuthFrames() async throws {
        XCTAssertEqual(ChocliftDefaults.protocolVersion, 3, "Protocol version must remain v3 without a bump")

        let suiteName = "com.choclift.audioinput.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let driver = MockAudioInputHardwareDriver(
            records: [
                MacAudioRawDeviceRecord(
                    audioObjectID: 77,
                    uid: "BuiltInMicrophoneDevice",
                    name: "MacBook Pro Microphone",
                    transportKind: .builtIn,
                    outputChannelCount: 0,
                    inputChannelCount: 1
                ),
                MacAudioRawDeviceRecord(
                    audioObjectID: 95,
                    uid: "Headset-Mic-UID",
                    name: "AirPods Pro",
                    transportKind: .bluetooth,
                    outputChannelCount: 2,
                    inputChannelCount: 1
                )
            ],
            defaultInputObjectID: 77
        )

        let delegate = AudioInputLoopbackDelegate(driver: driver)
        let server = MacServerEngine(macID: "mac-input-host", macName: "Studio Mac Input")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        // Pre-auth unknown frame must still disconnect immediately
        let (unauthSrv, unauthCli) = InMemoryCompanionPipe.pair()
        var unauthClosed = false
        unauthCli.onClosed = { unauthClosed = true }
        server.acceptCompanionTransport(unauthSrv, link: .bluetooth)
        unauthCli.start()
        unauthCli.send(Self.wrapRawFrame(Data(#"{"futurePreAuthFrame":{"x":1}}"#.utf8)))
        try await waitUntil("pre-auth unknown frame disconnected") { unauthClosed }

        // Pair and connect iPhone and Watch
        let (phoneSrv, phonePipe) = InMemoryCompanionPipe.pair()
        server.acceptCompanionTransport(phoneSrv, link: .bluetooth)
        let phone = CompanionClientEngine(
            deviceID: "iphone-input-1",
            deviceName: "iPhone 17",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-input-1"
        )
        phone.connectInMemoryBluetooth(to: phonePipe, targetName: "Studio Mac Input")
        try await waitUntil("phone awaiting PIN") {
            if case .awaitingPIN = phone.connectionState { return true }
            return false
        }
        phone.submitPIN(server.currentPIN)

        let (watchSrv, watchPipe) = InMemoryCompanionPipe.pair()
        server.acceptCompanionTransport(watchSrv, link: .bluetooth)
        let watch = CompanionClientEngine(
            deviceID: "watch-input-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: defaults,
            storageKeyPrefix: "watch-input-1"
        )
        watch.connectInMemoryBluetooth(to: watchPipe, targetName: "Studio Mac Input")
        try await waitUntil("watch awaiting PIN") {
            if case .awaitingPIN = watch.connectionState { return true }
            return false
        }
        watch.submitPIN(server.currentPIN)
        defer {
            phone.disconnect()
            watch.disconnect()
        }

        try await waitUntil("phone and watch synced initial audio inputs") {
            phone.connectionState.isConnected &&
            watch.connectionState.isConnected &&
            phone.controlStripState.audioInputDevices.count == 2 &&
            watch.controlStripState.audioInputDevices.count == 2
        }
        XCTAssertEqual(phone.controlStripState.selectedAudioInputDeviceID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(watch.controlStripState.selectedAudioInputDeviceID, "BuiltInMicrophoneDevice")

        // 1. iPhone selects Headset Mic -> must NOT optimistically move checkmark before server reply
        phone.selectAudioInputDevice(id: "Headset-Mic-UID")
        XCTAssertEqual(phone.controlStripState.selectedAudioInputDeviceID, "BuiltInMicrophoneDevice")

        try await waitUntil("both companions updated to Headset-Mic-UID") {
            phone.controlStripState.selectedAudioInputDeviceID == "Headset-Mic-UID" &&
            watch.controlStripState.selectedAudioInputDeviceID == "Headset-Mic-UID"
        }

        // 2. Hot-plug USB Mic on Mac -> refresh broadcasts to both iPhone and Watch
        driver.records.append(
            MacAudioRawDeviceRecord(
                audioObjectID: 120,
                uid: "USB-Mic-UID",
                name: "USB Condenser Mic",
                transportKind: .usb,
                outputChannelCount: 0,
                inputChannelCount: 1
            )
        )
        delegate.syncFromDriverAndBroadcast()
        try await waitUntil("both companions refreshed 3 mics after USB hot-plug") {
            phone.controlStripState.audioInputDevices.count == 3 &&
            watch.controlStripState.audioInputDevices.count == 3
        }

        // 3. Force OSStatus failure (-50) when Watch tries to select USB Mic -> shows OSStatus & checkmark stays on Headset Mic
        driver.forcedWriteStatus = -50
        watch.selectAudioInputDevice(id: "USB-Mic-UID")
        try await waitUntil("watch received OSStatus -50 failure feedback") {
            watch.lastFeedback?.success == false &&
            (watch.lastFeedback?.detail?.contains("-50") == true)
        }
        XCTAssertEqual(watch.controlStripState.selectedAudioInputDeviceID, "Headset-Mic-UID")
        XCTAssertEqual(phone.controlStripState.selectedAudioInputDeviceID, "Headset-Mic-UID")

        // 4. Clear failure; Watch selects USB Mic with the exact same command -> both companions move checkmark
        driver.forcedWriteStatus = 0
        watch.selectAudioInputDevice(id: "USB-Mic-UID")
        try await waitUntil("both companions updated to USB-Mic-UID") {
            watch.controlStripState.selectedAudioInputDeviceID == "USB-Mic-UID" &&
            phone.controlStripState.selectedAudioInputDeviceID == "USB-Mic-UID"
        }

        // Verify iPhone and Watch sent the exact same ClientMessage command variant (.setAudioInputDevice)
        XCTAssertEqual(
            delegate.receivedInputMessages,
            [
                .setAudioInputDevice(deviceID: "Headset-Mic-UID"),
                .setAudioInputDevice(deviceID: "USB-Mic-UID"),
                .setAudioInputDevice(deviceID: "USB-Mic-UID")
            ]
        )

        // 5. Unknown post-auth client AND server frames stay non-fatal
        phonePipe.send(Self.wrapRawFrame(Data(#"{"futurePostAuthClientAction":{"id":"xyz"}}"#.utf8)))
        phoneSrv.send(Self.wrapRawFrame(Data(#"{"futurePostAuthServerNotice":{"v":2}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frames must stay non-fatal")
        XCTAssertTrue(watch.connectionState.isConnected)

        // Session still works after unknown post-auth frames
        phone.selectAudioInputDevice(id: "BuiltInMicrophoneDevice")
        try await waitUntil("phone switched back to BuiltInMicrophoneDevice after unknown frames") {
            phone.controlStripState.selectedAudioInputDeviceID == "BuiltInMicrophoneDevice" &&
            watch.controlStripState.selectedAudioInputDeviceID == "BuiltInMicrophoneDevice"
        }
    }

    // MARK: - Helpers

    private static func wrapRawFrame(_ payload: Data) -> Data {
        var bigEndianLength = UInt32(payload.count).bigEndian
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &bigEndianLength) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    @MainActor
    private func waitUntil(
        _ label: String,
        timeoutSeconds: TimeInterval = 2.5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(12))
        }
        if condition() { return }
        XCTFail("Timed out waiting for: \(label)")
    }
}

// MARK: - Test Doubles

private final class MockAudioInputHardwareDriver: MacAudioInputHardwareDriver {
    var records: [MacAudioRawDeviceRecord]
    var defaultInputObjectID: UInt32
    var isDefaultInputSettableFlag: Bool
    var forcedWriteStatus: Int32
    var translatedUIDOverrides: [String: UInt32] = [:]
    var disableAutoUIDLookupFor: Set<String> = []
    var translatedUIDQueries: [String] = []
    var writeCallObjectIDs: [UInt32] = []

    init(
        records: [MacAudioRawDeviceRecord],
        defaultInputObjectID: UInt32,
        isDefaultInputSettableFlag: Bool = true,
        forcedWriteStatus: Int32 = 0
    ) {
        self.records = records
        self.defaultInputObjectID = defaultInputObjectID
        self.isDefaultInputSettableFlag = isDefaultInputSettableFlag
        self.forcedWriteStatus = forcedWriteStatus
    }

    func isDefaultInputSettable() -> (isSettable: Bool, status: Int32) {
        (isDefaultInputSettableFlag, 0)
    }

    func readDefaultInputDevice() -> (objectID: UInt32, status: Int32) {
        (defaultInputObjectID, 0)
    }

    func writeDefaultInputDevice(_ objectID: UInt32) -> Int32 {
        writeCallObjectIDs.append(objectID)
        guard forcedWriteStatus == 0 else {
            return forcedWriteStatus
        }
        defaultInputObjectID = objectID
        return 0
    }

    func readLiveDeviceRecords() -> [MacAudioRawDeviceRecord] {
        records
    }

    func translateUIDToLiveObjectID(_ uid: String) -> UInt32? {
        translatedUIDQueries.append(uid)
        if disableAutoUIDLookupFor.contains(uid) {
            return nil
        }
        if let overrideID = translatedUIDOverrides[uid] {
            return overrideID
        }
        return records.first(where: { $0.uid == uid })?.audioObjectID
    }
}

@MainActor
private final class AudioInputLoopbackDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    let driver: MockAudioInputHardwareDriver
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var controlState: ControlStripState
    var receivedInputMessages: [ClientMessage] = []

    init(driver: MockAudioInputHardwareDriver) {
        self.driver = driver
        let snap = MacAudioInputSwitchEngine.enumerateSnapshot(using: driver)
        self.controlState = ControlStripState(
            audioOutputDevices: [
                MacAudioOutputDevice(id: "BuiltInSpeakerDevice", audioObjectID: 70, name: "MacBook Pro Speakers", transportKind: .builtIn)
            ],
            selectedAudioOutputDeviceID: "BuiltInSpeakerDevice",
            canSwitchAudioOutput: true,
            audioInputDevices: snap.devices,
            selectedAudioInputDeviceID: snap.selectedID,
            canSwitchAudioInput: snap.canSwitch
        )
    }

    func syncFromDriverAndBroadcast() {
        let snap = MacAudioInputSwitchEngine.enumerateSnapshot(using: driver)
        controlState.audioInputDevices = snap.devices
        controlState.selectedAudioInputDeviceID = snap.selectedID
        controlState.canSwitchAudioInput = snap.canSwitch
        server?.broadcastControlStripState(controlState)
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { nil }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(controlState))
        case .setAudioInputDevice(let deviceID):
            receivedInputMessages.append(message)
            let res = MacAudioInputSwitchEngine.performSwitch(
                requestedID: deviceID,
                language: .english,
                using: driver
            )
            controlState.audioInputDevices = res.snapshot.devices
            controlState.selectedAudioInputDeviceID = res.snapshot.selectedID
            controlState.canSwitchAudioInput = res.snapshot.canSwitch
            server?.broadcastControlStripState(controlState)
            reply(.controlStripStateUpdated(controlState))
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))
        default:
            break
        }
    }
}
