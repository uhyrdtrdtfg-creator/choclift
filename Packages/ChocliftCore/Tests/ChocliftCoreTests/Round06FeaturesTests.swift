import Foundation
import XCTest
@testable import ChocliftCore

final class Round06FeaturesTests: XCTestCase {

    // MARK: - 1. Snippet Insert Mode Default & Pure Focus Gating Rule

    func testSnippetInsertModeDefaultsToFocusedFieldInsertAndLegacyJSONDecodesDefault() throws {
        XCTAssertEqual(SnippetInsertMode.defaultMode, .focusedFieldInsert)
        XCTAssertEqual(SnippetInsertPolicy.defaultMode, .focusedFieldInsert)

        let snippet = TextSnippet(title: "Signature", body: "Best,\nChoclift")
        XCTAssertEqual(snippet.insertMode, .focusedFieldInsert)

        // Round-trip encode/decode preserves explicit insertMode
        let pasteSnippet = TextSnippet(title: "Webhook", body: "https://example.com/hook", insertMode: .clipboardPaste)
        let typeSnippet = TextSnippet(title: "Command", body: "git status", insertMode: .typeKeys)

        var profile = ChocliftDefaults.makeDefaultProfile()
        XCTAssertTrue(profile.upsertSnippet(snippet))
        XCTAssertTrue(profile.upsertSnippet(pasteSnippet))
        XCTAssertTrue(profile.upsertSnippet(typeSnippet))

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: encoded)
        XCTAssertEqual(decoded.snippets.map(\.insertMode), [.focusedFieldInsert, .clipboardPaste, .typeKeys])

        // Renaming a snippet preserves its insertMode
        var renamedProfile = decoded
        XCTAssertTrue(renamedProfile.renameSnippet(id: typeSnippet.id, title: "Quick Git"))
        XCTAssertEqual(renamedProfile.snippet(withID: typeSnippet.id)?.insertMode, .typeKeys)

        // Updating insertMode via setSnippetInsertMode works cleanly
        XCTAssertTrue(renamedProfile.setSnippetInsertMode(id: snippet.id, mode: .clipboardPaste))
        XCTAssertEqual(renamedProfile.snippet(withID: snippet.id)?.insertMode, .clipboardPaste)

        // Legacy JSON without `insertMode` decodes strictly to `.focusedFieldInsert`
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "title": "Legacy Reply",
            "body": "Thanks for your note!"
        ])
        let legacyDecoded = try JSONDecoder().decode(TextSnippet.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.insertMode, .focusedFieldInsert)
    }

    func testTypingModeIsRejectedWhenNoFieldIsFocusedAndAllowedWhenFieldIsFocused() {
        // Availability check
        XCTAssertFalse(SnippetInsertPolicy.isModeAvailable(.typeKeys, isFieldFocused: false))
        XCTAssertTrue(SnippetInsertPolicy.isModeAvailable(.typeKeys, isFieldFocused: true))
        XCTAssertTrue(SnippetInsertPolicy.isModeAvailable(.focusedFieldInsert, isFieldFocused: false))
        XCTAssertTrue(SnippetInsertPolicy.isModeAvailable(.clipboardPaste, isFieldFocused: false))

        // Typing mode when NO field is focused -> rejected (strict no-op)
        let unfocusedTyping = SnippetInsertPolicy.evaluate(
            body: "echo hello",
            mode: .typeKeys,
            isFieldFocused: false
        )
        XCTAssertEqual(unfocusedTyping, .rejectedNoFocusedField)
        XCTAssertFalse(unfocusedTyping.isExecutable)

        // Typing mode when a field IS focused -> types through key path
        let focusedTyping = SnippetInsertPolicy.evaluate(
            body: "echo hello",
            mode: .typeKeys,
            isFieldFocused: true
        )
        XCTAssertEqual(focusedTyping, .typeThroughKeyPath("echo hello"))
        XCTAssertTrue(focusedTyping.isExecutable)

        // Default focused-field insert preserves clipboard when focused, rejected when unfocused
        XCTAssertEqual(
            SnippetInsertPolicy.evaluate(body: "Hi there", mode: .focusedFieldInsert, isFieldFocused: true),
            .focusedFieldInsertPreservingClipboard("Hi there")
        )
        XCTAssertEqual(
            SnippetInsertPolicy.evaluate(body: "Hi there", mode: .focusedFieldInsert, isFieldFocused: false),
            .rejectedNoFocusedField
        )

        // Clipboard paste works through clipboard
        XCTAssertEqual(
            SnippetInsertPolicy.evaluate(body: "Paste me", mode: .clipboardPaste, isFieldFocused: false),
            .pasteThroughClipboard("Paste me")
        )

        // Empty body is always rejected
        for mode in SnippetInsertMode.allCases {
            XCTAssertEqual(
                SnippetInsertPolicy.evaluate(body: "", mode: mode, isFieldFocused: true),
                .rejectedEmptyText
            )
        }
    }

    // MARK: - 2. Launch at Login Default-Off & Registration State Machine

    func testLaunchAtLoginDefaultsOffAndAddsAndRemovesLoginItem() throws {
        final class MockLoginService: LaunchAtLoginServing {
            var status: LaunchAtLoginRegistrationStatus = .notRegistered
            var registerCalls = 0
            var unregisterCalls = 0
            var nextRegisterStatus: LaunchAtLoginRegistrationStatus = .enabled

            func currentStatus() -> LaunchAtLoginRegistrationStatus { status }

            func register() throws {
                registerCalls += 1
                status = nextRegisterStatus
            }

            func unregister() throws {
                unregisterCalls += 1
                status = .notRegistered
            }
        }

        let mock = MockLoginService()
        var machine = LaunchAtLoginStateMachine()
        XCTAssertFalse(machine.isEnabled, "Launch at login must default to off")
        XCTAssertFalse(machine.requiresApproval)
        XCTAssertEqual(mock.registerCalls, 0)

        // Disabling when already off is idempotent and never throws
        try machine.setEnabled(false, using: mock)
        XCTAssertFalse(machine.isEnabled)
        XCTAssertEqual(mock.unregisterCalls, 0)

        // Enabling registers login item
        try machine.setEnabled(true, using: mock)
        XCTAssertTrue(machine.isEnabled)
        XCTAssertEqual(mock.registerCalls, 1)

        // Disabling unregisters login item
        try machine.setEnabled(false, using: mock)
        XCTAssertFalse(machine.isEnabled)
        XCTAssertEqual(mock.unregisterCalls, 1)

        // System Settings requires-approval path is surfaced accurately and can be unregistered
        mock.nextRegisterStatus = .requiresApproval
        try machine.setEnabled(true, using: mock)
        XCTAssertFalse(machine.isEnabled)
        XCTAssertTrue(machine.requiresApproval)

        try machine.setEnabled(false, using: mock)
        XCTAssertFalse(machine.isEnabled)
        XCTAssertFalse(machine.requiresApproval)
        XCTAssertEqual(mock.unregisterCalls, 2)
    }

    // MARK: - 3. Menu-Bar Status Summary (Connected Companions + Keep-Awake)

    func testMenuBarStatusShowsConnectedCompanionCountAndKeepAwakeState() {
        let idle = MacMenuBarStatusSummary(connectedCompanionCount: 0, isKeepAwakeOn: false)
        XCTAssertEqual(idle.symbolName, "rectangle.grid.2x2")
        XCTAssertEqual(idle.menuBarTitle(in: .english), "0 · Awake Off")
        XCTAssertEqual(idle.menuBarTitle(in: .chinese), "0 · 常亮关")
        XCTAssertTrue(idle.tooltipText(in: .english).contains("0 Companions Connected"))
        XCTAssertTrue(idle.tooltipText(in: .english).contains("Keep Awake: Off"))

        let activeAwake = MacMenuBarStatusSummary(connectedCompanionCount: 2, isKeepAwakeOn: true)
        XCTAssertEqual(activeAwake.symbolName, "rectangle.grid.2x2.fill")
        XCTAssertEqual(activeAwake.menuBarTitle(in: .english), "2 · Awake On")
        XCTAssertEqual(activeAwake.menuBarTitle(in: .chinese), "2 · 常亮开")
        XCTAssertTrue(activeAwake.tooltipText(in: .english).contains("2 Companions Connected"))
        XCTAssertTrue(activeAwake.tooltipText(in: .english).contains("Keep Awake: On"))

        // Defensive clamp for negative counts
        let clamped = MacMenuBarStatusSummary(connectedCompanionCount: -4, isKeepAwakeOn: false)
        XCTAssertEqual(clamped.connectedCompanionCount, 0)
        XCTAssertEqual(clamped.menuBarTitle(in: .english), "0 · Awake Off")
    }

    // MARK: - 4. Empty-Slot Hint vs Filled Tile

    func testEmptySlotShowsAddHintAndFilledTileNeverShowsAdd() {
        XCTAssertTrue(EmptySlotHintPolicy.shouldShowAddHint(for: nil))
        XCTAssertEqual(EmptySlotHintPolicy.plusSymbolName(for: nil), "plus")
        XCTAssertEqual(EmptySlotHintPolicy.hintLabel(for: nil, language: .english), "Add")
        XCTAssertEqual(EmptySlotHintPolicy.hintLabel(for: nil, language: .chinese), "添加")
        XCTAssertEqual(
            EmptySlotHintPolicy.accessibilityLabel(for: nil, slotIndex: 0, resolvedFilledTitle: nil, language: .english),
            "Add · Empty Slot #1"
        )

        let filled = BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        XCTAssertFalse(EmptySlotHintPolicy.shouldShowAddHint(for: filled))
        XCTAssertNil(EmptySlotHintPolicy.plusSymbolName(for: filled))
        XCTAssertNil(EmptySlotHintPolicy.hintLabel(for: filled, language: .english))
        XCTAssertNil(EmptySlotHintPolicy.hintLabel(for: filled, language: .chinese))
        XCTAssertEqual(
            EmptySlotHintPolicy.accessibilityLabel(for: filled, slotIndex: 0, resolvedFilledTitle: "Safari", language: .english),
            "Safari"
        )
    }

    // MARK: - 5. Page Switcher Names, Truncation, and Pinning App-Aware Following

    func testPageSwitcherFormatsNamesTruncatesLongTitlesAndPinsAppFollowingUntilResumed() {
        XCTAssertEqual(
            PageSwitcherTitleFormatter.displayTitle(rawTitle: "Web & Docs", pageIndex: 3, language: .english),
            "Web & Docs"
        )
        XCTAssertEqual(
            PageSwitcherTitleFormatter.displayTitle(rawTitle: "   ", pageIndex: 2, language: .english),
            "Page 3"
        )

        let veryLong = "Super Long Custom Video Editing Timeline Layout Page"
        let truncated = PageSwitcherTitleFormatter.displayTitle(
            rawTitle: veryLong,
            pageIndex: 0,
            maxCharacters: 20,
            language: .english
        )
        XCTAssertEqual(truncated.count, 20)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertFalse(truncated == "1")

        // App-aware following: tapping ANY page name (even the currently visible page!) selects it and pins following
        // until Follow Frontmost App is tapped.
        var profile = ChocliftDefaults.makeDefaultProfile()
        let dailyPage = profile.pages[0]
        let workspacePage = profile.pages[1]
        let quickActionsPage = profile.pages[2]
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.finder", pageID: dailyPage.id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: workspacePage.id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: quickActionsPage.id)

        var follower = AppDeckFollowerState()
        follower.handleFrontmostAppChanged("com.apple.finder", in: profile)
        XCTAssertTrue(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 0)

        // Tap "Daily" (index 0 — same as current!) in switcher -> pins Page 0 so Xcode switch does NOT steal focus
        follower.selectManualPage(index: 0, in: profile)
        XCTAssertFalse(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 0)

        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 0, "Pinned page must hold even when frontmost app changes")
        XCTAssertFalse(follower.isFollowingFrontmostApp)

        // Tap "Quick Actions" (index 2) by name -> switches to index 2 and stays pinned
        follower.selectManualPage(index: 2, in: profile)
        XCTAssertEqual(follower.currentPageIndex, 2)
        XCTAssertFalse(follower.isFollowingFrontmostApp)

        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 2)

        // Tap Follow Frontmost App -> resumes following and jumps to Xcode's bound Workspace page (index 1)
        follower.followFrontmostApp(frontmostBundleIdentifier: "com.apple.dt.Xcode", in: profile)
        XCTAssertTrue(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, workspacePage.id)
    }

    // MARK: - 6. Wire Loopback: Snippet Modes, Focus Gate & Pre/Post-Auth Unknown Frame Invariants

    #if os(macOS)
    @MainActor
    func testLoopbackSnippetModesFocusGatingAndUnknownFrameInvariants() async throws {
        let suiteName = "com.choclift.tests.round06.wire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = Round06WireTestDelegate()
        let server = MacServerEngine(macID: "mac-r6-host", macName: "Studio Mac R6")
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

        let unknownClientJSON = Data(#"{"futureRound99ClientCommand":{"z":42}}"#.utf8)
        var uLen = UInt32(unknownClientJSON.count).bigEndian
        var unknownClientFrame = Data(capacity: 4 + unknownClientJSON.count)
        withUnsafeBytes(of: &uLen) { unknownClientFrame.append(contentsOf: $0) }
        unknownClientFrame.append(unknownClientJSON)
        unauthClientEnd.send(unknownClientFrame)

        for _ in 0..<40 where !unauthClosed {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(unauthClosed, "Unknown pre-auth frame must disconnect immediately")

        // 2. Pair companion over in-memory transport
        let phoneServerEnd = server.acceptInMemoryCompanion()
        let (phoneProxy, phoneClientEnd) = InMemoryCompanionPipe.pair()
        phoneProxy.onPayload = { phoneServerEnd.send($0) }
        phoneServerEnd.onPayload = { phoneProxy.send($0) }
        phoneProxy.start()
        phoneServerEnd.start()

        let phone = CompanionClientEngine(
            deviceID: "iphone-r6",
            deviceName: "iPhone R6",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-r6"
        )
        defer { phone.disconnect() }

        phone.connectInMemoryBluetooth(to: phoneClientEnd, targetName: "Studio Mac R6")
        for _ in 0..<50 {
            if case .awaitingPIN = phone.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phone.submitPIN(server.currentPIN)
        for _ in 0..<50 where !phone.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.connectionState.isConnected)
        XCTAssertFalse(phone.isEditingTextOnMac)

        let defaultSnippet = TextSnippet(title: "Default", body: "Preserve Clipboard")
        let pasteSnippet = TextSnippet(title: "Paste", body: "Clipboard Paste", insertMode: .clipboardPaste)
        let typeSnippet = TextSnippet(title: "Type", body: "Type Keys", insertMode: .typeKeys)

        // 3. When NO field is focused on Mac (`isEditingTextOnMac == false`), typing mode does nothing!
        XCTAssertFalse(phone.triggerSnippet(typeSnippet))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(delegate.executedPlans.isEmpty)

        // Even if a raw `.insertSnippet(..., mode: .typeKeys)` frame arrives while Mac has no focused field,
        // the server policy rejects it cleanly without executing keystrokes.
        phoneClientEnd.send(try WireFrameCodec.encode(ClientMessage.insertSnippet(text: "Race", mode: .typeKeys)))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(delegate.executedPlans.isEmpty)

        // Clipboard paste works even without focused field
        XCTAssertTrue(phone.triggerSnippet(pasteSnippet))
        for _ in 0..<50 where delegate.executedPlans.count < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.executedPlans, [.pasteThroughClipboard("Clipboard Paste")])

        // 4. Focus a field on Mac -> both default focused-field insert AND typing mode execute cleanly!
        delegate.isFieldFocused = true
        server.broadcast(.textFieldFocusChanged(isEditingText: true, appName: "Notes"))
        for _ in 0..<50 where !phone.isEditingTextOnMac {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(phone.isEditingTextOnMac)

        XCTAssertTrue(phone.triggerSnippet(defaultSnippet))
        XCTAssertTrue(phone.triggerSnippet(typeSnippet))
        for _ in 0..<50 where delegate.executedPlans.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            delegate.executedPlans,
            [
                .pasteThroughClipboard("Clipboard Paste"),
                .focusedFieldInsertPreservingClipboard("Preserve Clipboard"),
                .typeThroughKeyPath("Type Keys")
            ]
        )

        // 5. Unknown POST-AUTH frames stay non-fatal
        phoneClientEnd.send(unknownClientFrame)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(phone.connectionState.isConnected, "Unknown post-auth frames must stay non-fatal")
        XCTAssertEqual(server.connectedDeviceCount, 1)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class Round06WireTestDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var isFieldFocused: Bool = false
    var executedPlans: [SnippetExecutionPlan] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { "com.apple.Notes" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) {
        (isFieldFocused, isFieldFocused ? "Notes" : nil)
    }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .insertSnippet(let text, let mode):
            let plan = SnippetInsertPolicy.evaluate(
                body: text,
                mode: mode,
                isFieldFocused: isFieldFocused
            )
            guard plan.isExecutable else {
                if mode != .typeKeys {
                    reply(.actionFeedback(success: false, title: "Snippet", detail: "No focused field"))
                }
                return
            }
            executedPlans.append(plan)
            reply(.actionFeedback(success: true, title: "Snippet", detail: "Executed"))
        default:
            break
        }
    }
}
#endif
