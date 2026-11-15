import XCTest
@testable import ChocliftCore

final class CompanionHotkeyTests: XCTestCase {
    func testOldProfileJSONWithoutHotkeysDecodesToEmptyAndEncodeWritesHotkeys() throws {
        let baseProfile = ChocliftDefaults.makeDefaultProfile()
        let encodedData = try JSONEncoder().encode(baseProfile)
        var rawJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )
        XCTAssertNotNil(rawJSON["hotkeys"])

        rawJSON.removeValue(forKey: "hotkeys")
        let legacyData = try JSONSerialization.data(withJSONObject: rawJSON)
        let decodedLegacy = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertEqual(decodedLegacy.hotkeys, [])

        let reencodedData = try JSONEncoder().encode(decodedLegacy)
        let reencodedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencodedData) as? [String: Any]
        )
        let writtenArray = try XCTUnwrap(reencodedJSON["hotkeys"] as? [Any])
        XCTAssertTrue(writtenArray.isEmpty)
    }

    func testSanitizeDropsUnknownActionsModifierlessDisallowedKeyCodeDuplicatesAndCapsAtEight() {
        let cmd = CompanionHotkeyModifiers.command
        let opt = CompanionHotkeyModifiers.option
        let ctrl = CompanionHotkeyModifiers.control

        let firstValidID = UUID()
        let duplicateSecondID = UUID()

        var candidates: [CompanionHotkey] = [
            // Unknown action ID -> dropped
            CompanionHotkey(keyCode: 0x28, carbonModifiers: cmd, actionID: "unknown.not_real", title: "Bad"),
            // No modifier -> dropped
            CompanionHotkey(keyCode: 0x28, carbonModifiers: 0, actionID: SystemQuickAction.lockScreen.rawValue, title: "NoMod"),
            // Disallowed keyCode (modifier / out-of-range) -> dropped
            CompanionHotkey(keyCode: 0x37, carbonModifiers: cmd, actionID: SystemQuickAction.lockScreen.rawValue, title: "ModifierKey"),
            CompanionHotkey(keyCode: 0xFFFF, carbonModifiers: cmd, actionID: SystemQuickAction.lockScreen.rawValue, title: "InvalidKey"),
            // Valid #1 (kept first)
            CompanionHotkey(id: firstValidID, keyCode: 0x28, carbonModifiers: cmd | opt, actionID: SystemQuickAction.lockScreen.rawValue, title: "Lock First"),
            // Duplicate chord of Valid #1 -> dropped (first kept)
            CompanionHotkey(id: duplicateSecondID, keyCode: 0x28, carbonModifiers: cmd | opt, actionID: "files.open_desktop", title: "Lock Duplicate")
        ]

        // Add 9 more distinct valid chords so total valid unique candidates = 10 -> capped at 8
        let keyCodes: [UInt16] = [0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26]
        for (index, keyCode) in keyCodes.enumerated() {
            let actionID = index.isMultiple(of: 2)
                ? "files.open_desktop"
                : SystemQuickAction.maximizeWindow.rawValue
            candidates.append(
                CompanionHotkey(
                    keyCode: keyCode,
                    carbonModifiers: ctrl | opt,
                    actionID: actionID,
                    title: "Item \(index)"
                )
            )
        }

        let sanitized = CompanionHotkeyLibrary.sanitize(candidates)
        XCTAssertEqual(sanitized.count, 8)
        XCTAssertEqual(sanitized.first?.id, firstValidID)
        XCTAssertEqual(sanitized.first?.title, "Lock First")
        XCTAssertFalse(sanitized.contains { $0.id == duplicateSecondID })
        XCTAssertFalse(sanitized.contains { $0.keyCode == 0x37 || $0.keyCode == 0xFFFF })
        XCTAssertEqual(sanitized.last?.keyCode, keyCodes[6])
    }

    func testKeyAWithCommandOptionIsAcceptedAndNoModifierOrShiftOnlyIsRejected() {
        XCTAssertTrue(CompanionHotkeyLibrary.isAllowedKeyCode(0))
        XCTAssertTrue(
            CompanionHotkeyLibrary.pickerKeyOptions.contains(
                CompanionHotkeyKeyOption(keyCode: 0x00, label: "A", category: .letters)
            )
        )
        for option in CompanionHotkeyLibrary.pickerKeyOptions {
            XCTAssertTrue(CompanionHotkeyLibrary.isAllowedKeyCode(option.keyCode))
        }

        let cmdOptA = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: SystemQuickAction.lockScreen.rawValue,
            title: "Lock via A"
        )
        let bareA = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: 0,
            actionID: SystemQuickAction.lockScreen.rawValue,
            title: "No Mod A"
        )
        let shiftOnlyA = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: CompanionHotkeyModifiers.shift,
            actionID: SystemQuickAction.lockScreen.rawValue,
            title: "Shift Only A"
        )

        let sanitized = CompanionHotkeyLibrary.sanitize([bareA, shiftOnlyA, cmdOptA])
        XCTAssertEqual(sanitized, [cmdOptA])
        XCTAssertEqual(cmdOptA.displayLabel, "⌥⌘A")
    }

    func testFlowAndQuadActionIDsSurviveSanitizeMalformedPrefixesDroppedAndCatalogIDsStillWork() {
        let cmdOpt = CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option
        let flowUUID = UUID()
        let quadUUID = UUID()

        let validFlowHotkey = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: cmdOpt,
            actionID: "flow:\(flowUUID.uuidString)",
            title: "Morning Flow"
        )
        let validQuadHotkey = CompanionHotkey(
            keyCode: 0x0B,
            carbonModifiers: cmdOpt,
            actionID: "quad:\(quadUUID.uuidString.lowercased())",
            title: "Dev Quad"
        )
        let validCatalogHotkey = CompanionHotkey(
            keyCode: 0x08,
            carbonModifiers: cmdOpt,
            actionID: "files.open_desktop",
            title: "Open Desktop"
        )
        let validQuickActionHotkey = CompanionHotkey(
            keyCode: 0x02,
            carbonModifiers: cmdOpt,
            actionID: SystemQuickAction.maximizeWindow.rawValue,
            title: "Maximize"
        )

        let badFlowUUID = CompanionHotkey(
            keyCode: 0x0E,
            carbonModifiers: cmdOpt,
            actionID: "flow:not-a-uuid",
            title: "Bad Flow"
        )
        let badQuadUUID = CompanionHotkey(
            keyCode: 0x03,
            carbonModifiers: cmdOpt,
            actionID: "quad:not-a-uuid",
            title: "Bad Quad"
        )
        let emptyFlowPrefix = CompanionHotkey(
            keyCode: 0x05,
            carbonModifiers: cmdOpt,
            actionID: "flow:",
            title: "Empty Flow"
        )
        let wrongCasePrefix = CompanionHotkey(
            keyCode: 0x04,
            carbonModifiers: cmdOpt,
            actionID: "FLOW:\(UUID().uuidString)",
            title: "Uppercase Prefix"
        )

        let sanitized = CompanionHotkeyLibrary.sanitize([
            badFlowUUID,
            badQuadUUID,
            emptyFlowPrefix,
            wrongCasePrefix,
            validFlowHotkey,
            validQuadHotkey,
            validCatalogHotkey,
            validQuickActionHotkey
        ])

        XCTAssertEqual(
            sanitized,
            [validFlowHotkey, validQuadHotkey, validCatalogHotkey, validQuickActionHotkey]
        )
        XCTAssertEqual(CompanionHotkeyLibrary.parsedFlowID(from: validFlowHotkey.actionID), flowUUID)
        XCTAssertEqual(CompanionHotkeyLibrary.parsedQuadLayoutID(from: validQuadHotkey.actionID), quadUUID)
        XCTAssertNil(CompanionHotkeyLibrary.parsedFlowID(from: "flow:not-a-uuid"))
        XCTAssertNil(CompanionHotkeyLibrary.parsedQuadLayoutID(from: "quad:not-a-uuid"))
    }

    func testResolvedTitleShowsFlowAndQuadLayoutNamesAndFallsBackToIDWhenDeleted() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let flow = ActionFlow(name: "Morning Routine", steps: [])
        let quad = QuadAppLayout(
            name: "Coding Grid",
            topLeft: QuadAppSlot(bundleIdentifier: "com.apple.Safari", appName: "Safari")
        )
        profile.upsertFlow(flow)
        profile.quadLayouts = [quad]

        let flowActionID = CompanionHotkeyLibrary.flowActionID(flow.id)
        let quadActionID = CompanionHotkeyLibrary.quadActionID(quad.id)

        let flowHotkey = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: flowActionID,
            title: flow.name
        )
        let quadHotkey = CompanionHotkey(
            keyCode: 0x0B,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: quadActionID,
            title: quad.name
        )

        XCTAssertEqual(flowHotkey.resolvedTitle(in: profile, language: .english), "Morning Routine")
        XCTAssertEqual(quadHotkey.resolvedTitle(in: profile, language: .english), "Coding Grid")

        _ = profile.deleteFlow(id: flow.id)
        profile.quadLayouts.removeAll()

        XCTAssertEqual(flowHotkey.resolvedTitle(in: profile, language: .english), flowActionID)
        XCTAssertEqual(quadHotkey.resolvedTitle(in: profile, language: .english), quadActionID)
        XCTAssertNil(CompanionHotkeyLibrary.actionTitle(for: flowActionID, in: profile, language: .english))
        XCTAssertNil(CompanionHotkeyLibrary.actionTitle(for: quadActionID, in: profile, language: .english))
    }

    func testCommandShiftLetterIsKeptShiftOnlyIsDroppedAndDisplayLabelUsesModifierGlyphs() {
        let cmdShiftK = CompanionHotkey(
            keyCode: 0x28,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.shift,
            actionID: SystemQuickAction.centerWindow.rawValue,
            title: "Center"
        )
        let shiftOnlyK = CompanionHotkey(
            keyCode: 0x28,
            carbonModifiers: CompanionHotkeyModifiers.shift,
            actionID: SystemQuickAction.centerWindow.rawValue,
            title: "Shift Only"
        )
        let allModsSpace = CompanionHotkey(
            keyCode: 0x31,
            carbonModifiers: CompanionHotkeyModifiers.command
                | CompanionHotkeyModifiers.shift
                | CompanionHotkeyModifiers.option
                | CompanionHotkeyModifiers.control,
            actionID: "files.open_downloads",
            title: "Downloads"
        )

        let sanitized = CompanionHotkeyLibrary.sanitize([shiftOnlyK, cmdShiftK, allModsSpace])
        XCTAssertEqual(sanitized, [cmdShiftK, allModsSpace])

        XCTAssertEqual(cmdShiftK.displayLabel, "⇧⌘K")
        XCTAssertEqual(allModsSpace.displayLabel, "⌃⌥⇧⌘Space")
        XCTAssertFalse(allModsSpace.displayLabel.contains("metaKey"))
    }

    func testUpsertAndDeleteCompanionHotkeyWireRoundTrip() throws {
        let hotkey = CompanionHotkey(
            id: UUID(),
            keyCode: 0x28,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: "files.open_desktop",
            title: "Open Desktop"
        )
        let upsertMessage = ClientMessage.upsertCompanionHotkey(hotkey)
        let upsertData = try JSONEncoder().encode(upsertMessage)
        let decodedUpsert = try JSONDecoder().decode(ClientMessage.self, from: upsertData)
        XCTAssertEqual(decodedUpsert, upsertMessage)

        let deleteMessage = ClientMessage.deleteCompanionHotkey(id: hotkey.id)
        let framed = try WireFrameCodec.encode(deleteMessage)
        var accumulator = WireStreamAccumulator()
        let payloads = try accumulator.appendAndExtractPayloads(framed)
        XCTAssertEqual(payloads.count, 1)
        let decodedDelete = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        XCTAssertEqual(decodedDelete, deleteMessage)
    }

    #if os(macOS)
    @MainActor
    func testAuthenticatedCompanionHotkeyMessagesReachServerAndRejectUnknownActionIDs() async {
        let suiteName = "com.choclift.tests.companion-hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = CompanionHotkeyWireDelegate()
        let server = MacServerEngine(macID: "mac-hotkeys", macName: "Hotkeys Mac")
        server.delegate = delegate
        defer { server.stop() }

        let phone = CompanionClientEngine(
            deviceID: "iphone-hotkeys",
            deviceName: "iPhone Hotkeys",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "hk"
        )
        defer { phone.disconnect() }

        let host = DiscoveredBluetoothMac(id: UUID(), name: "Hotkeys Mac", macID: "mac-hotkeys")
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

        let unknownHotkey = CompanionHotkey(
            keyCode: 0x28,
            carbonModifiers: CompanionHotkeyModifiers.command,
            actionID: "unknown.invalid_id",
            title: "Invalid"
        )
        phone.upsertCompanionHotkey(unknownHotkey)

        let malformedFlowHotkey = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: "flow:not-a-uuid",
            title: "Malformed Flow"
        )
        phone.upsertCompanionHotkey(malformedFlowHotkey)

        let flowTargetID = UUID()
        let validFlowOnKeyA = CompanionHotkey(
            keyCode: 0x00,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: CompanionHotkeyLibrary.flowActionID(flowTargetID),
            title: "Run Flow"
        )

        let validHotkey = CompanionHotkey(
            keyCode: 0x28,
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.shift,
            actionID: SystemQuickAction.lockScreen.rawValue,
            title: "Lock Screen"
        )
        phone.upsertCompanionHotkey(validHotkey)
        phone.upsertCompanionHotkey(validFlowOnKeyA)
        for _ in 0..<60 where delegate.upsertedHotkeys.count < 2 {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.upsertedHotkeys, [validHotkey, validFlowOnKeyA])

        phone.deleteCompanionHotkey(id: validHotkey.id)
        for _ in 0..<60 where delegate.deletedIDs.isEmpty {
            await CancellableDelay.sleepUntilCancelled(seconds: 0.01)
        }
        XCTAssertEqual(delegate.deletedIDs, [validHotkey.id])
    }
    #endif
}

#if os(macOS)
@MainActor
private final class CompanionHotkeyWireDelegate: MacServerEngineDelegate {
    var upsertedHotkeys: [CompanionHotkey] = []
    var deletedIDs: [UUID] = []

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
        case .upsertCompanionHotkey(let hotkey):
            upsertedHotkeys.append(hotkey)
            reply(.actionFeedback(success: true, title: hotkey.title, detail: nil))
        case .deleteCompanionHotkey(let id):
            deletedIDs.append(id)
            reply(.actionFeedback(success: true, title: "Shortcuts", detail: nil))
        default:
            break
        }
    }
}
#endif
