import Darwin
import Foundation
import XCTest
@testable import ChocliftCore

// MARK: - Deterministic Mock ActionFlowDriver for Sequential & Targeting Verification

@MainActor
private final class RecordingFlowDriver: ActionFlowDriver {
    enum RecordedCall: Equatable {
        case launch(bundleID: String, appPath: String?)
        case waitWindow(bundleID: String, pid: Int32, action: SystemQuickAction)
        case systemAction(action: SystemQuickAction, target: FlowSystemActionTarget)
        case openWebsite(url: String, switchExistingTab: Bool)
        case runShortcut(name: String)
        case insertSnippet(snippetID: UUID, titleSnapshot: String?, preferredPID: Int32?)
        case sleep(seconds: Double)
    }

    var fallbackExternalAppPID: Int32? = 999
    var recordedCalls: [RecordedCall] = []

    var runningAppsByBundleID: [String: FlowAppHandle] = [:]
    var frontmostApp: FlowAppHandle?

    /// Custom hook invoked on `launchOrActivateApp`. If nil, registers/activates the app automatically.
    var onLaunch: ((String, String?) -> (success: Bool, message: String, app: FlowAppHandle?))?
    /// Custom hook invoked on each `sleep(seconds:)`, useful for advancing frontmost transitions deterministically.
    var onSleep: ((Int, Double) -> Void)?
    /// Custom hook invoked on `executeSystemAction`.
    var onSystemAction: ((SystemQuickAction, FlowSystemActionTarget) -> (success: Bool, message: String))?
    /// Custom hook invoked on `openWebsite`.
    var onOpenWebsite: ((String, Bool) -> (success: Bool, message: String))?
    /// Custom hook invoked on `runShortcut`.
    var onRunShortcut: ((String) -> (success: Bool, message: String))?
    /// Custom hook invoked on `insertSnippet`.
    var onInsertSnippet: ((UUID, String?, Int32?) -> (success: Bool, message: String))?

    private var sleepCount = 0
    private var nextPID: Int32 = 100

    func launchOrActivateApp(
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String, app: FlowAppHandle?) {
        recordedCalls.append(.launch(bundleID: bundleIdentifier, appPath: appPath))
        if let onLaunch {
            return onLaunch(bundleIdentifier, appPath)
        }
        let handle: FlowAppHandle
        if let existing = runningAppsByBundleID[bundleIdentifier] {
            handle = existing
        } else {
            nextPID += 1
            handle = FlowAppHandle(bundleIdentifier: bundleIdentifier, appName: bundleIdentifier, processIdentifier: nextPID)
            runningAppsByBundleID[bundleIdentifier] = handle
        }
        frontmostApp = handle
        return (true, "Launched \(bundleIdentifier)", handle)
    }

    func currentFrontmostApp() -> FlowAppHandle? {
        frontmostApp
    }

    func runningApp(forBundleIdentifier bundleIdentifier: String) -> FlowAppHandle? {
        if let exact = runningAppsByBundleID[bundleIdentifier] {
            return exact
        }
        return runningAppsByBundleID.first {
            $0.key.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }?.value
    }

    func waitForAdjustableWindowIfNeeded(
        for app: FlowAppHandle,
        action: SystemQuickAction
    ) async {
        recordedCalls.append(.waitWindow(bundleID: app.bundleIdentifier, pid: app.processIdentifier, action: action))
    }

    func executeSystemAction(
        _ action: SystemQuickAction,
        target: FlowSystemActionTarget
    ) -> (success: Bool, message: String) {
        recordedCalls.append(.systemAction(action: action, target: target))
        if let onSystemAction {
            return onSystemAction(action, target)
        }
        return (true, "Executed \(action.rawValue)")
    }

    func openWebsite(
        url: String,
        switchExistingTab: Bool
    ) async -> (success: Bool, message: String) {
        recordedCalls.append(.openWebsite(url: url, switchExistingTab: switchExistingTab))
        if let onOpenWebsite {
            return onOpenWebsite(url, switchExistingTab)
        }
        return (true, "Opened \(url)")
    }

    func runShortcut(
        named shortcutName: String
    ) async -> (success: Bool, message: String) {
        recordedCalls.append(.runShortcut(name: shortcutName))
        if let onRunShortcut {
            return onRunShortcut(shortcutName)
        }
        return (true, "Ran Shortcut \"\(shortcutName)\"")
    }

    func insertSnippet(
        snippetID: UUID,
        titleSnapshot: String?,
        preferredPID: Int32?
    ) -> (success: Bool, message: String) {
        recordedCalls.append(.insertSnippet(snippetID: snippetID, titleSnapshot: titleSnapshot, preferredPID: preferredPID))
        if let onInsertSnippet {
            return onInsertSnippet(snippetID, titleSnapshot, preferredPID)
        }
        return (true, "Inserted snippet \(titleSnapshot ?? snippetID.uuidString)")
    }

    func sleep(seconds: Double) async {
        sleepCount += 1
        recordedCalls.append(.sleep(seconds: seconds))
        onSleep?(sleepCount, seconds)
    }
}

// MARK: - Mock Mac Server Delegate Executing Real ActionFlowRunner

@MainActor
private final class FlowExecutingMacServerDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var recentApps: [RecentAppEntry] = [
        RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true)
    ]
    weak var server: MacServerEngine?
    let driver: RecordingFlowDriver
    var receivedTriggerMessages: [(devicePlatform: DevicePlatform, message: ClientMessage)] = []

    init(driver: RecordingFlowDriver) {
        self.driver = driver
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { recentApps }
    func serverFrontmostBundleID() -> String? { driver.frontmostApp?.bundleIdentifier ?? "com.apple.finder" }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] {
        var icons: [String: Data] = [:]
        for id in bundleIDs {
            icons[id] = Data([0x89, 0x50, 0x4E, 0x47])
        }
        return icons
    }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .updateProfile(let updated):
            profile = updated
            server?.broadcast(.profileUpdated(updated), excludingDeviceID: device.deviceID)

        case .triggerBarItem(let item):
            receivedTriggerMessages.append((device.platform, message))
            if case .flow(let flowID, let titleSnapshot, _, _, _) = item.kind {
                Task { @MainActor in
                    guard let flow = self.profile.flow(withID: flowID) else {
                        let missing = "Flow \"\(titleSnapshot)\" not found"
                        reply(.actionFeedback(success: false, title: missing, detail: missing))
                        return
                    }
                    let res = await ActionFlowRunner.run(flow, driver: self.driver, language: .english)
                    reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))
                }
            } else {
                reply(.actionFeedback(success: true, title: item.displayTitle(in: .english), detail: "OK"))
            }

        case .triggerFlow(let flowID):
            receivedTriggerMessages.append((device.platform, message))
            Task { @MainActor in
                guard let flow = self.profile.flow(withID: flowID) else {
                    reply(.actionFeedback(success: false, title: "Flow not found", detail: "Flow not found"))
                    return
                }
                let res = await ActionFlowRunner.run(flow, driver: self.driver, language: .english)
                reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))
            }

        default:
            break
        }
    }
}

// MARK: - Unit & Integration Tests

@MainActor
final class ActionFlowsTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    // MARK: 1. Decoding, Backward/Forward Compatibility & Profile Sync Model

    func testLegacyWorkspaceProfileWithoutFlowsKeyDecodesCleanly() throws {
        let defaultProfile = ChocliftDefaults.makeDefaultProfile()
        let encoded = try JSONEncoder().encode(defaultProfile)

        // Strip "flows" key to simulate a pre-flows workspace_profile.json on disk or from an older peer
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObject.removeValue(forKey: "flows")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)

        let decoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertTrue(decoded.flows.isEmpty)
        XCTAssertEqual(decoded.pages.count, 8)
        XCTAssertEqual(decoded.pages[0].slots[0]?.bundleIdentifier, "com.apple.finder")
        XCTAssertEqual(decoded.emojiSlides.count, 8)
    }

    func testFlowAndBarItemRoundTripClampingAndForwardSafeDecoding() throws {
        let splitFlow = ActionFlow.makeSplitScreenTemplate(
            leftBundleIdentifier: "com.apple.Safari",
            leftAppName: "Safari",
            rightBundleIdentifier: "com.apple.Notes",
            rightAppName: "Notes",
            timeoutSeconds: 99.0, // Should clamp to maxTimeoutSeconds (10.0s)
            language: .english
        )
        var customFlow = splitFlow
        customFlow.steps.append(ActionFlowStep(kind: .delay(seconds: 42.0))) // Should clamp to maxDelaySeconds (10.0s)

        var profile = ChocliftDefaults.makeDefaultProfile()
        profile.upsertFlow(customFlow)
        profile.pages[0].slots[7] = profile.makeBarItem(for: customFlow)

        let data = try JSONEncoder().encode(profile)
        let roundTripped = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: data)

        XCTAssertEqual(roundTripped.flows.count, 1)
        let decodedFlow = try XCTUnwrap(roundTripped.flows.first)
        XCTAssertEqual(decodedFlow.id, customFlow.id)
        XCTAssertEqual(decodedFlow.steps.count, 7)

        // Verify timeout and delay clamping
        if case .waitForAppFrontmost(_, _, let clampedTimeout) = decodedFlow.steps[1].kind {
            XCTAssertEqual(clampedTimeout, ActionFlowStep.maxTimeoutSeconds, accuracy: 0.001)
        } else {
            XCTFail("Expected waitForAppFrontmost at index 1")
        }
        if case .delay(let clampedDelay) = decodedFlow.steps[6].kind {
            XCTAssertEqual(clampedDelay, ActionFlowStep.maxDelaySeconds, accuracy: 0.001)
        } else {
            XCTFail("Expected delay at index 6")
        }

        // Verify BarItemKind.flow round-trips cleanly
        let slotItem = try XCTUnwrap(roundTripped.pages[0].slots[7])
        XCTAssertEqual(slotItem.flowID, customFlow.id)
        XCTAssertEqual(slotItem.displayTitle(in: .english), customFlow.name)

        // Verify ClientMessage.triggerFlow wire frame round-trip
        let wireFrame = try WireFrameCodec.encode(ClientMessage.triggerFlow(flowID: customFlow.id))
        var acc = WireStreamAccumulator()
        let payloads = try acc.appendAndExtractPayloads(wireFrame)
        XCTAssertEqual(payloads.count, 1)
        let decodedMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payloads[0])
        XCTAssertEqual(decodedMsg, .triggerFlow(flowID: customFlow.id))

        // Verify unknown future step type decodes as .unsupported instead of failing profile decode
        let futureStepJSON = """
        {
          "id": "\(UUID().uuidString)",
          "isEnabled": true,
          "kind": { "type": "future_applescript_step", "source": "beep" }
        }
        """.data(using: .utf8)!
        let futureStep = try JSONDecoder().decode(ActionFlowStep.self, from: futureStepJSON)
        XCTAssertEqual(futureStep.kind, .unsupported(rawType: "future_applescript_step"))

        // Verify unknown future BarItemKind in a BarPage slot decodes safely to nil without failing the page
        let pageWithUnknownSlotJSON = """
        {
          "id": "\(UUID().uuidString)",
          "index": 0,
          "title": "Daily",
          "iconEmoji": "🍫",
          "slots": [
            {
              "id": "\(UUID().uuidString)",
              "kind": { "futureWidget": { "widgetID": "abc" } }
            },
            null
          ]
        }
        """.data(using: .utf8)!
        let safePage = try JSONDecoder().decode(BarPage.self, from: pageWithUnknownSlotJSON)
        XCTAssertEqual(safePage.slots.count, BarPage.slotsPerPage)
        XCTAssertNil(safePage.slots[0])
    }

    func testProfileFlowCRUDUpdatesPlacedSlotsAndReorders() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        var flowA = ActionFlow.makeOpenWaitMaximizeTemplate(bundleIdentifier: "com.apple.Safari", appName: "Safari", language: .english)
        let flowB = ActionFlow.makeSplitScreenTemplate(
            leftBundleIdentifier: "com.apple.Terminal",
            leftAppName: "Terminal",
            rightBundleIdentifier: "com.apple.dt.Xcode",
            rightAppName: "Xcode",
            language: .english
        )

        profile.upsertFlow(flowA)
        profile.upsertFlow(flowB)
        XCTAssertEqual(profile.flows.map(\.id), [flowA.id, flowB.id])
        XCTAssertTrue(profile.referencedAppBundleIdentifiers.contains("com.apple.Terminal"))
        XCTAssertTrue(profile.referencedAppBundleIdentifiers.contains("com.apple.dt.Xcode"))

        // Place flowA on Page 1 Slot 0
        profile.pages[0].slots[0] = profile.makeBarItem(for: flowA)
        XCTAssertEqual(profile.pages[0].slots[0]?.displayTitle(in: .english), "Safari Focus Maximize")

        // Rename flowA and disable one step -> placed slot snapshot updates automatically
        flowA.name = "Safari Reader Maximize"
        flowA.emoji = "🧭"
        flowA.steps[1].isEnabled = false
        profile.upsertFlow(flowA)

        if case .flow(let id, let title, let emoji, _, let stepCount) = profile.pages[0].slots[0]?.kind {
            XCTAssertEqual(id, flowA.id)
            XCTAssertEqual(title, "Safari Reader Maximize")
            XCTAssertEqual(emoji, "🧭")
            XCTAssertEqual(stepCount, 2)
        } else {
            XCTFail("Expected updated .flow BarItem in slot")
        }

        // Reorder flows
        profile.moveFlow(from: 0, to: 1)
        XCTAssertEqual(profile.flows.map(\.id), [flowB.id, flowA.id])
        profile.moveFlows(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(profile.flows.map(\.id), [flowA.id, flowB.id])

        // Delete flowA -> removes flow and clears placed slot
        XCTAssertTrue(profile.deleteFlow(id: flowA.id))
        XCTAssertEqual(profile.flows.map(\.id), [flowB.id])
        XCTAssertNil(profile.pages[0].slots[0])
    }

    // MARK: 2. Sequential Execution Order & Strict Intended-App Window Targeting

    func testExample1OpenWaitUntilFrontmostThenMaximizeRunsInExactOrder() async {
        let driver = RecordingFlowDriver()
        let safariHandle = FlowAppHandle(bundleIdentifier: "com.apple.Safari", appName: "Safari", processIdentifier: 410)
        let finderHandle = FlowAppHandle(bundleIdentifier: "com.apple.finder", appName: "Finder", processIdentifier: 100)

        // Simulate Safari launching asynchronously: still Finder frontmost until 2nd poll cycle
        driver.frontmostApp = finderHandle
        driver.onLaunch = { bundleID, _ in
            driver.runningAppsByBundleID[bundleID] = safariHandle
            // Not frontmost yet right after openApplication returns!
            return (true, "Launching Safari", safariHandle)
        }
        driver.onSleep = { pollIteration, _ in
            if pollIteration >= 2 {
                driver.frontmostApp = safariHandle
            }
        }

        let flow = ActionFlow.makeOpenWaitMaximizeTemplate(
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            timeoutSeconds: 2.0,
            language: .english
        )

        let result = await ActionFlowRunner.run(flow, driver: driver, language: .english)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.executedStepCount, 3)
        XCTAssertNil(result.failedStepIndex)

        // Expected call sequence:
        // 1. launch Safari
        // 2. sleep poll #1 (still Finder)
        // 3. sleep poll #2 (Safari becomes frontmost)
        // 4. waitWindow for Safari PID 410 before maximizeWindow
        // 5. executeSystemAction(.maximizeWindow, .strictApp("com.apple.Safari", 410))
        XCTAssertEqual(driver.recordedCalls.count, 5)
        XCTAssertEqual(driver.recordedCalls[0], .launch(bundleID: "com.apple.Safari", appPath: nil))
        if case .sleep = driver.recordedCalls[1] {} else { XCTFail("Expected poll sleep 1") }
        if case .sleep = driver.recordedCalls[2] {} else { XCTFail("Expected poll sleep 2") }
        XCTAssertEqual(
            driver.recordedCalls[3],
            .waitWindow(bundleID: "com.apple.Safari", pid: 410, action: .maximizeWindow)
        )
        XCTAssertEqual(
            driver.recordedCalls[4],
            .systemAction(
                action: .maximizeWindow,
                target: .strictApp(bundleIdentifier: "com.apple.Safari", processIdentifier: 410)
            )
        )
    }

    func testExample2OpenAppALeftAndAppBRightTargetsIntendedAppsStrictly() async {
        let driver = RecordingFlowDriver()
        driver.fallbackExternalAppPID = 999 // Unrelated app PID that must NEVER be snapped!

        let appA = FlowAppHandle(bundleIdentifier: "com.apple.Safari", appName: "Safari", processIdentifier: 501)
        let appB = FlowAppHandle(bundleIdentifier: "com.apple.Notes", appName: "Notes", processIdentifier: 602)

        // Test both implicit active-flow-app targeting (targetBundleIdentifier == nil) and template targeting
        let flow = ActionFlow(
            name: "Coding + Notes Split",
            emoji: "🪟",
            steps: [
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: appA.bundleIdentifier, appName: appA.appName)),
                ActionFlowStep(kind: .waitForAppFrontmost(bundleIdentifier: "", timeoutSeconds: 2.0)),
                ActionFlowStep(kind: .systemAction(action: .snapWindowLeft)), // Implicitly bound to App A!
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: appB.bundleIdentifier, appName: appB.appName)),
                ActionFlowStep(kind: .waitForAppFrontmost(bundleIdentifier: "", timeoutSeconds: 2.0)),
                ActionFlowStep(kind: .systemAction(action: .snapWindowRight)) // Implicitly bound to App B!
            ]
        )

        driver.onLaunch = { bundleID, _ in
            if bundleID == appA.bundleIdentifier {
                driver.runningAppsByBundleID[bundleID] = appA
                driver.frontmostApp = appA
                return (true, "Opened Safari", appA)
            } else {
                driver.runningAppsByBundleID[bundleID] = appB
                driver.frontmostApp = appB
                return (true, "Opened Notes", appB)
            }
        }

        let result = await ActionFlowRunner.run(flow, driver: driver, language: .english)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.executedStepCount, 6)

        XCTAssertEqual(
            driver.recordedCalls,
            [
                .launch(bundleID: "com.apple.Safari", appPath: nil),
                .waitWindow(bundleID: "com.apple.Safari", pid: 501, action: .snapWindowLeft),
                .systemAction(
                    action: .snapWindowLeft,
                    target: .strictApp(bundleIdentifier: "com.apple.Safari", processIdentifier: 501)
                ),
                .launch(bundleID: "com.apple.Notes", appPath: nil),
                .waitWindow(bundleID: "com.apple.Notes", pid: 602, action: .snapWindowRight),
                .systemAction(
                    action: .snapWindowRight,
                    target: .strictApp(bundleIdentifier: "com.apple.Notes", processIdentifier: 602)
                )
            ]
        )
    }

    // MARK: 3. Failure Stopping & Step-Named Action Feedback

    func testFlowStopsImmediatelyWhenWaitFrontmostTimesOutWithoutSnappingWrongWindow() async {
        let driver = RecordingFlowDriver()
        let appA = FlowAppHandle(bundleIdentifier: "com.apple.Safari", appName: "Safari", processIdentifier: 501)
        let appB = FlowAppHandle(bundleIdentifier: "com.apple.Notes", appName: "Notes", processIdentifier: 602)

        driver.onLaunch = { bundleID, _ in
            if bundleID == appA.bundleIdentifier {
                driver.runningAppsByBundleID[bundleID] = appA
                driver.frontmostApp = appA
                return (true, "Opened Safari", appA)
            } else {
                // App B launches in background, but App A remains frontmost!
                driver.runningAppsByBundleID[bundleID] = appB
                driver.frontmostApp = appA
                return (true, "Opened Notes", appB)
            }
        }

        let flow = ActionFlow.makeSplitScreenTemplate(
            leftBundleIdentifier: appA.bundleIdentifier,
            leftAppName: appA.appName,
            rightBundleIdentifier: appB.bundleIdentifier,
            rightAppName: appB.appName,
            timeoutSeconds: 0.2,
            language: .english
        )

        let result = await ActionFlowRunner.run(flow, driver: driver, language: .english)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.executedStepCount, 4) // Steps 1..4 succeeded; Step 5 (Wait for Notes Frontmost) failed
        XCTAssertEqual(result.failedStepIndex, 4)
        XCTAssertTrue(result.title.contains("Step 5"), "Title should name Step 5, got: \(result.title)")
        XCTAssertTrue(result.title.contains("Notes"), "Title should name Notes, got: \(result.title)")
        XCTAssertTrue(result.detail.contains("Step 5"), "Detail should name Step 5, got: \(result.detail)")

        // Critically: Step 6 (snapWindowRight) MUST NEVER have been executed!
        let executedSnaps = driver.recordedCalls.compactMap { call -> SystemQuickAction? in
            if case .systemAction(let action, _) = call { return action }
            return nil
        }
        XCTAssertEqual(executedSnaps, [.snapWindowLeft])
    }

    func testFlowStopsBeforeSnapIfIntendedAppTerminatedAfterWait() async {
        let driver = RecordingFlowDriver()
        let appA = FlowAppHandle(bundleIdentifier: "com.apple.Safari", appName: "Safari", processIdentifier: 501)
        driver.onLaunch = { _, _ in
            // App A launched then immediately quit/crashed before snapWindowLeft
            driver.runningAppsByBundleID.removeAll()
            driver.frontmostApp = nil
            return (true, "Opened Safari", appA)
        }

        let flow = ActionFlow(
            name: "Safe Snap",
            steps: [
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: "com.apple.Safari", appName: "Safari")),
                ActionFlowStep(kind: .systemAction(action: .snapWindowLeft))
            ]
        )

        let result = await ActionFlowRunner.run(flow, driver: driver, language: .english)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertTrue(result.title.contains("Step 2"))
        XCTAssertTrue(result.detail.contains("not running"))

        // Verify executeSystemAction was NEVER called on fallback frontmost app
        let anySystemActionCalled = driver.recordedCalls.contains {
            if case .systemAction = $0 { return true }
            return false
        }
        XCTAssertFalse(anySystemActionCalled)
    }

    // MARK: 4. Multi-Device Loopback + BLE Integration (iPhone, iPad, Apple Watch)

    func testTriggeredFlowsFromIPhoneIPadAndWatchReachMacHandlerInOrderAndReportStepFailure() async throws {
        guard Self.isLoopbackSocketAllowedByEnvironment() else {
            throw XCTSkip("TCP loopback socket bind/connect is restricted by sandbox environment.")
        }

        let suiteName = "com.choclift.flowtests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let driver = RecordingFlowDriver()
        let delegate = FlowExecutingMacServerDelegate(driver: driver)
        let server = MacServerEngine(macID: "mac-flow-host", macName: "Studio Mac")
        server.delegate = delegate
        delegate.server = server
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("server listening") { server.isListening && server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)

        // 1. Pair iPhone over Wi-Fi TCP using 6-digit PIN
        let iphone = CompanionClientEngine(
            deviceID: "iphone-flow-1",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "iphoneFlow"
        )
        defer { iphone.disconnect() }
        iphone.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Mac")
        try await waitUntil("iPhone awaiting PIN") {
            if case .awaitingPIN = iphone.connectionState { return true }
            return false
        }
        iphone.submitPIN(server.currentPIN)
        try await waitUntil("iPhone connected") { iphone.connectionState.isConnected }

        // 2. Pair iPad over Wi-Fi TCP using 6-digit PIN
        let ipad = CompanionClientEngine(
            deviceID: "ipad-flow-1",
            deviceName: "iPad Pro",
            platform: .iPad,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "ipadFlow"
        )
        defer { ipad.disconnect() }
        ipad.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Mac")
        try await waitUntil("iPad awaiting PIN") {
            if case .awaitingPIN = ipad.connectionState { return true }
            return false
        }
        ipad.submitPIN(server.currentPIN)
        try await waitUntil("iPad connected") { ipad.connectionState.isConnected }

        // 3. Pair Apple Watch over Bluetooth transport with PIN, then reconnect with saved token
        let watch = CompanionClientEngine(
            deviceID: "watch-flow-1",
            deviceName: "Apple Watch",
            platform: .appleWatch,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "watchFlow"
        )
        defer { watch.disconnect() }
        let btClientEnd1 = server.acceptInMemoryCompanion()
        watch.connectInMemoryBluetooth(to: btClientEnd1, targetName: "Studio Mac", macID: "mac-flow-host")
        try await waitUntil("Watch awaiting PIN") {
            if case .awaitingPIN = watch.connectionState { return true }
            return false
        }
        watch.submitPIN(server.currentPIN)
        try await waitUntil("Watch connected via PIN") { watch.connectionState.isConnected }

        // Reconnect Watch using saved token session to verify token compatibility with flows
        watch.disconnect()
        let btClientEnd2 = server.acceptInMemoryCompanion()
        watch.connectInMemoryBluetooth(to: btClientEnd2, targetName: "Studio Mac", macID: "mac-flow-host")
        try await waitUntil("Watch reconnected via saved token") { watch.connectionState.isConnected }

        // 4. Configure both required example flows on iPad, place them on Chocolate Bar Page 1 Slots 0 & 1, and sync
        let focusFlow = ActionFlow.makeOpenWaitMaximizeTemplate(
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            language: .english
        )
        let splitFlow = ActionFlow.makeSplitScreenTemplate(
            leftBundleIdentifier: "com.apple.Safari",
            leftAppName: "Safari",
            rightBundleIdentifier: "com.apple.Notes",
            rightAppName: "Notes",
            language: .english
        )

        var editedProfile = ipad.profile
        editedProfile.upsertFlow(focusFlow)
        editedProfile.upsertFlow(splitFlow)
        editedProfile.pages[0].slots[0] = editedProfile.makeBarItem(for: focusFlow)
        editedProfile.pages[0].slots[1] = editedProfile.makeBarItem(for: splitFlow)
        ipad.pushUpdatedProfile(editedProfile)

        try await waitUntil("iPhone and Watch synced flows and Chocolate Bar slots") {
            iphone.profile.flows.count == 2 &&
            watch.profile.flows.count == 2 &&
            iphone.profile.pages[0].slots[0]?.flowID == focusFlow.id &&
            watch.profile.pages[0].slots[1]?.flowID == splitFlow.id
        }

        // 5. Trigger Example 1 from iPhone slot -> reaches Mac handler in order
        driver.recordedCalls.removeAll()
        let iphoneSlot0 = try XCTUnwrap(iphone.profile.pages[0].slots[0])
        iphone.triggerBarItem(iphoneSlot0)

        try await waitUntil("iPhone received flow completion feedback") {
            iphone.lastFeedback?.title == focusFlow.name && iphone.lastFeedback?.success == true
        }
        XCTAssertEqual(driver.recordedCalls.count, 3)
        XCTAssertEqual(driver.recordedCalls[0], .launch(bundleID: "com.apple.Safari", appPath: nil))
        if case .waitWindow(let bid, _, let act) = driver.recordedCalls[1] {
            XCTAssertEqual(bid, "com.apple.Safari")
            XCTAssertEqual(act, .maximizeWindow)
        } else {
            XCTFail("Expected waitWindow before maximize")
        }
        if case .systemAction(let act, .strictApp(let bid, _)) = driver.recordedCalls[2] {
            XCTAssertEqual(act, .maximizeWindow)
            XCTAssertEqual(bid, "com.apple.Safari")
        } else {
            XCTFail("Expected strictApp maximizeWindow")
        }

        // 6. Trigger Example 2 (Split Screen) from Apple Watch slot -> reaches Mac handler in exact 6-step order
        driver.recordedCalls.removeAll()
        let watchSlot1 = try XCTUnwrap(watch.profile.pages[0].slots[1])
        watch.triggerBarItem(watchSlot1)

        try await waitUntil("Watch received split-screen flow feedback") {
            watch.lastFeedback?.title == splitFlow.name && watch.lastFeedback?.success == true
        }
        let watchStepActions = driver.recordedCalls.compactMap { call -> String? in
            switch call {
            case .launch(let bid, _):
                return "launch:\(bid)"
            case .systemAction(let act, .strictApp(let bid, _)):
                return "action:\(act.rawValue)->\(bid)"
            default:
                return nil
            }
        }
        XCTAssertEqual(
            watchStepActions,
            [
                "launch:com.apple.Safari",
                "action:snap_window_left->com.apple.Safari",
                "launch:com.apple.Notes",
                "action:snap_window_right->com.apple.Notes"
            ]
        )

        // 7. Trigger direct .triggerFlow from iPad when App B fails to launch -> stops and names Step 4
        driver.recordedCalls.removeAll()
        driver.onLaunch = { bundleID, _ in
            if bundleID == "com.apple.Notes" {
                return (false, "App not found on Mac (com.apple.Notes)", nil)
            }
            let safari = FlowAppHandle(bundleIdentifier: bundleID, appName: "Safari", processIdentifier: 777)
            driver.runningAppsByBundleID[bundleID] = safari
            driver.frontmostApp = safari
            return (true, "Activated Safari", safari)
        }

        ipad.lastFeedback = nil
        ipad.triggerFlow(id: splitFlow.id)

        try await waitUntil("iPad received failed-step feedback") {
            ipad.lastFeedback != nil
        }
        let failureToast = try XCTUnwrap(ipad.lastFeedback)
        XCTAssertFalse(failureToast.success)
        XCTAssertTrue(failureToast.title.contains("Step 4"), "Expected Step 4 in toast title: \(failureToast.title)")
        XCTAssertTrue((failureToast.detail ?? "").contains("Open Notes"), "Expected failed step name in detail: \(failureToast.detail ?? "")")
    }

    // MARK: - 6. Website, Shortcut, and Snippet Flow Steps (Backward Decode, Sequential Execution & Real Error Halting)

    func testLegacyV1_0_21FlowWithoutNewStepCasesDecodesCleanly() throws {
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Legacy Workspace Setup",
          "emoji": "🪟",
          "backgroundHex": "#ECFAFE",
          "updatedAt": 1700000000,
          "steps": [
            {
              "id": "AAAAAAAA-0000-0000-0000-000000000001",
              "isEnabled": true,
              "kind": {
                "type": "launch_or_activate_app",
                "bundleIdentifier": "com.apple.Safari",
                "appName": "Safari"
              }
            },
            {
              "id": "AAAAAAAA-0000-0000-0000-000000000002",
              "isEnabled": true,
              "kind": {
                "type": "wait_for_app_frontmost",
                "bundleIdentifier": "",
                "timeoutSeconds": 2.5
              }
            },
            {
              "id": "AAAAAAAA-0000-0000-0000-000000000003",
              "isEnabled": true,
              "kind": {
                "type": "delay",
                "seconds": 0.4
              }
            },
            {
              "id": "AAAAAAAA-0000-0000-0000-000000000004",
              "isEnabled": true,
              "kind": {
                "type": "system_action",
                "action": "maximize_window"
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(ActionFlow.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Legacy Workspace Setup")
        XCTAssertEqual(decoded.steps.count, 4)
        XCTAssertEqual(decoded.steps[0].kind, .launchOrActivateApp(bundleIdentifier: "com.apple.Safari", appName: "Safari", appPath: nil))
        XCTAssertEqual(decoded.steps[1].kind, .waitForAppFrontmost(bundleIdentifier: "", appName: nil, timeoutSeconds: 2.5))
        XCTAssertEqual(decoded.steps[2].kind, .delay(seconds: 0.4))
        XCTAssertEqual(decoded.steps[3].kind, .systemAction(action: .maximizeWindow, targetBundleIdentifier: nil, targetAppName: nil))
    }

    func testWebsiteShortcutAndSnippetStepsRoundTripCodingAndDefaults() throws {
        let snippetID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let flow = ActionFlow(
            name: "Morning Triage",
            emoji: "🚀",
            backgroundHex: "#EFF8FF",
            steps: [
                ActionFlowStep(kind: .openWebsite(url: " https://linear.app/team ", title: " Linear ", switchExistingTab: true)),
                ActionFlowStep(kind: .openWebsite(url: "https://github.com/notifications", title: "   ", switchExistingTab: false)),
                ActionFlowStep(kind: .runShortcut(shortcutName: " Daily Standup Notes ")),
                ActionFlowStep(kind: .insertSnippet(snippetID: snippetID, titleSnapshot: " Standup Template "))
            ]
        )

        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(ActionFlow.self, from: data)
        XCTAssertEqual(decoded, flow)
        XCTAssertEqual(decoded.steps[0].kind, .openWebsite(url: "https://linear.app/team", title: "Linear", switchExistingTab: true))
        XCTAssertEqual(decoded.steps[1].kind, .openWebsite(url: "https://github.com/notifications", title: nil, switchExistingTab: false))
        XCTAssertEqual(decoded.steps[2].kind, .runShortcut(shortcutName: "Daily Standup Notes"))
        XCTAssertEqual(decoded.steps[3].kind, .insertSnippet(snippetID: snippetID, titleSnapshot: "Standup Template"))

        // Minimal JSON payloads with omitted optional keys + malformed insert_snippet missing snippetID
        let minimalJSON = """
        [
          {
            "kind": { "type": "open_website", "url": "https://example.com" }
          },
          {
            "kind": { "type": "run_shortcut", "shortcutName": "Focus Mode" }
          },
          {
            "kind": { "type": "insert_snippet", "snippetID": "\(snippetID.uuidString)" }
          },
          {
            "kind": { "type": "insert_snippet", "titleSnapshot": "Broken Missing UUID" }
          }
        ]
        """
        let minimalSteps = try JSONDecoder().decode([ActionFlowStep].self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(minimalSteps.count, 4)
        XCTAssertEqual(minimalSteps[0].kind, .openWebsite(url: "https://example.com", title: nil, switchExistingTab: true))
        XCTAssertEqual(minimalSteps[1].kind, .runShortcut(shortcutName: "Focus Mode"))
        XCTAssertEqual(minimalSteps[2].kind, .insertSnippet(snippetID: snippetID, titleSnapshot: nil))
        XCTAssertEqual(minimalSteps[3].kind, .unsupported(rawType: "insert_snippet:missing_snippet_id"))
    }

    func testFlowRunsWebsiteShortcutAndSnippetSequentiallyAndPassesPreferredPID() async {
        let driver = RecordingFlowDriver()
        driver.fallbackExternalAppPID = 4242

        let snippetA = UUID()
        let snippetB = UUID()

        let flow = ActionFlow(
            name: "Research & Draft",
            steps: [
                // Before any app step, insertSnippet receives fallbackExternalAppPID (4242)
                ActionFlowStep(kind: .insertSnippet(snippetID: snippetA, titleSnapshot: "Header")),
                ActionFlowStep(kind: .openWebsite(url: "github.com/apple/swift", title: "Swift Repo", switchExistingTab: true)),
                ActionFlowStep(kind: .runShortcut(shortcutName: "Prepare Scratchpad")),
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: "com.apple.Notes", appName: "Notes")),
                // After launching Notes, insertSnippet receives Notes's processIdentifier
                ActionFlowStep(kind: .insertSnippet(snippetID: snippetB, titleSnapshot: "Review Checklist"))
            ]
        )

        let result = await ActionFlowRunner.run(flow, driver: driver, language: .english)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.executedStepCount, 5)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertNil(result.failedStepTitle)

        let notesPID = try! XCTUnwrap(driver.runningAppsByBundleID["com.apple.Notes"]?.processIdentifier)
        XCTAssertEqual(
            driver.recordedCalls,
            [
                .insertSnippet(snippetID: snippetA, titleSnapshot: "Header", preferredPID: 4242),
                .openWebsite(url: "https://github.com/apple/swift", switchExistingTab: true),
                .runShortcut(name: "Prepare Scratchpad"),
                .launch(bundleID: "com.apple.Notes", appPath: nil),
                .insertSnippet(snippetID: snippetB, titleSnapshot: "Review Checklist", preferredPID: notesPID)
            ]
        )
    }

    func testFailedWebsiteShortcutAndSnippetStepsStopFlowImmediatelyAndReportStepNumberAndRealError() async {
        let snippetID = UUID()

        // Case A: Invalid URL in step 2 stops before step 3 and never invokes driver.openWebsite
        do {
            let driver = RecordingFlowDriver()
            let flow = ActionFlow(
                name: "Bad Website Flow",
                steps: [
                    ActionFlowStep(kind: .delay(seconds: 0.1)),
                    ActionFlowStep(kind: .openWebsite(url: "https://", title: "Broken Link", switchExistingTab: true)),
                    ActionFlowStep(kind: .runShortcut(shortcutName: "Should Not Run"))
                ]
            )
            let res = await ActionFlowRunner.run(flow, driver: driver, language: .english)
            XCTAssertFalse(res.success)
            XCTAssertEqual(res.executedStepCount, 1)
            XCTAssertEqual(res.failedStepIndex, 1)
            XCTAssertTrue(res.title.contains("Step 2"), "Unexpected title: \(res.title)")
            XCTAssertTrue(res.detail.contains("Invalid URL: https://"), "Expected real URL validation error in detail: \(res.detail)")
            XCTAssertEqual(driver.recordedCalls, [.sleep(seconds: 0.1)])
        }

        // Case B: Shortcut failure at 1-based Step 3 (with Step 1 disabled!) reports Step 3 and real CLI error, halting before Step 4
        do {
            let driver = RecordingFlowDriver()
            let realCLIError = "Error: The operation couldn’t be completed. Couldn’t find shortcut \"Missing Shortcut\"."
            driver.onRunShortcut = { _ in
                (false, realCLIError)
            }

            let flow = ActionFlow(
                name: "Shortcut Failure Flow",
                steps: [
                    ActionFlowStep(kind: .delay(seconds: 0.2), isEnabled: false), // Step 1 disabled
                    ActionFlowStep(kind: .openWebsite(url: "https://example.com", title: "Example", switchExistingTab: false)), // Step 2
                    ActionFlowStep(kind: .runShortcut(shortcutName: "Missing Shortcut")), // Step 3 fails!
                    ActionFlowStep(kind: .insertSnippet(snippetID: snippetID, titleSnapshot: "Never Inserted")) // Step 4 must not run
                ]
            )

            let res = await ActionFlowRunner.run(flow, driver: driver, language: .english)
            XCTAssertFalse(res.success)
            XCTAssertEqual(res.executedStepCount, 1)
            XCTAssertEqual(res.failedStepIndex, 2)
            XCTAssertTrue(res.title.contains("Step 3"), "Expected 1-based Step 3 even when Step 1 is disabled: \(res.title)")
            XCTAssertTrue(res.detail.contains("Step 3"), "Expected Step 3 in detail: \(res.detail)")
            XCTAssertTrue(res.detail.contains(realCLIError), "Expected real CLI error in detail: \(res.detail)")
            XCTAssertEqual(
                driver.recordedCalls,
                [
                    .openWebsite(url: "https://example.com", switchExistingTab: false),
                    .runShortcut(name: "Missing Shortcut")
                ]
            )
        }

        // Case C: Deleted or failed snippet step stops flow, reports Step 2 and real snippet error, never marks flow successful
        do {
            let driver = RecordingFlowDriver()
            let realSnippetError = "Snippet \"Deleted Signature\" was deleted"
            driver.onInsertSnippet = { _, _, _ in
                (false, realSnippetError)
            }

            let flow = ActionFlow(
                name: "Snippet Failure Flow",
                steps: [
                    ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: "com.apple.Notes", appName: "Notes")),
                    ActionFlowStep(kind: .insertSnippet(snippetID: snippetID, titleSnapshot: "Deleted Signature")),
                    ActionFlowStep(kind: .systemAction(action: .maximizeWindow))
                ]
            )

            let res = await ActionFlowRunner.run(flow, driver: driver, language: .english)
            XCTAssertFalse(res.success)
            XCTAssertEqual(res.executedStepCount, 1)
            XCTAssertEqual(res.failedStepIndex, 1)
            XCTAssertTrue(res.title.contains("Step 2"), "Unexpected title: \(res.title)")
            XCTAssertTrue(res.detail.contains(realSnippetError), "Expected real snippet error in detail: \(res.detail)")
            XCTAssertEqual(
                driver.recordedCalls,
                [
                    .launch(bundleID: "com.apple.Notes", appPath: nil),
                    .insertSnippet(
                        snippetID: snippetID,
                        titleSnapshot: "Deleted Signature",
                        preferredPID: driver.runningAppsByBundleID["com.apple.Notes"]?.processIdentifier
                    )
                ]
            )
        }
    }

    func testLoopbackSyncAndFailureReportingForWebsiteShortcutAndSnippetFlow() async throws {
        guard Self.isLoopbackSocketAllowedByEnvironment() else {
            throw XCTSkip("Local TCP loopback sockets are blocked by this sandbox environment.")
        }

        let suiteName = "com.choclift.flowtests.ext.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let driver = RecordingFlowDriver()
        let delegate = FlowExecutingMacServerDelegate(driver: driver)

        let snippet = TextSnippet(title: "PR Template", body: "## Summary\n- Ready for review", insertMode: .clipboardPaste)
        _ = delegate.profile.upsertSnippet(snippet)

        let server = MacServerEngine(macID: "mac-flow-ext-host", macName: "Studio Mac")
        server.delegate = delegate
        delegate.server = server
        server.start(preferredPort: 0, advertiseBonjour: false, advertiseBluetooth: false)
        defer { server.stop() }

        try await waitUntil("Server listening") { server.isListening && server.listeningPort != nil }
        let port = try XCTUnwrap(server.listeningPort)

        let iphone = CompanionClientEngine(
            deviceID: "iphone-flow-ext-1",
            deviceName: "Test iPhone",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "iphoneFlowExt"
        )
        let ipad = CompanionClientEngine(
            deviceID: "ipad-flow-ext-1",
            deviceName: "Test iPad",
            platform: .iPad,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "ipadFlowExt"
        )
        defer {
            iphone.disconnect()
            ipad.disconnect()
        }

        iphone.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Mac")
        try await waitUntil("iPhone awaiting PIN") {
            if case .awaitingPIN = iphone.connectionState { return true }
            return false
        }
        iphone.submitPIN(server.currentPIN)
        try await waitUntil("iPhone connected") { iphone.connectionState.isConnected }

        ipad.connectToHost(host: "127.0.0.1", port: port, targetName: "Studio Mac")
        try await waitUntil("iPad awaiting PIN") {
            if case .awaitingPIN = ipad.connectionState { return true }
            return false
        }
        ipad.submitPIN(server.currentPIN)
        try await waitUntil("iPad connected") { ipad.connectionState.isConnected }

        // Create flow with Website + Shortcut + Snippet steps on iPhone and push to Mac & iPad
        let comboFlow = ActionFlow(
            name: "PR Ship Flow",
            emoji: "🌐",
            backgroundHex: "#ECFAFE",
            steps: [
                ActionFlowStep(kind: .openWebsite(url: "https://github.com/pulls", title: "GitHub PRs", switchExistingTab: true)),
                ActionFlowStep(kind: .runShortcut(shortcutName: "Copy Branch Ticket")),
                ActionFlowStep(kind: .insertSnippet(snippetID: snippet.id, titleSnapshot: snippet.title))
            ]
        )
        var edited = iphone.profile
        edited.upsertFlow(comboFlow)
        iphone.pushUpdatedProfile(edited)

        try await waitUntil("Mac & iPad receive synced comboFlow") {
            delegate.profile.flow(withID: comboFlow.id) == comboFlow &&
            ipad.profile.flow(withID: comboFlow.id) == comboFlow
        }

        // 1. Successful trigger from iPad runs all 3 steps in order
        ipad.lastFeedback = nil
        ipad.triggerFlow(id: comboFlow.id)
        try await waitUntil("iPad receives success feedback") {
            ipad.lastFeedback?.title == comboFlow.name && ipad.lastFeedback?.success == true
        }
        XCTAssertEqual(
            driver.recordedCalls,
            [
                .openWebsite(url: "https://github.com/pulls", switchExistingTab: true),
                .runShortcut(name: "Copy Branch Ticket"),
                .insertSnippet(snippetID: snippet.id, titleSnapshot: "PR Template", preferredPID: 999)
            ]
        )

        // 2. Failing shortcut on Step 2 halts before Step 3 (snippet) and reports Step 2 + real error back to iPhone
        driver.recordedCalls.removeAll()
        driver.onRunShortcut = { name in
            (false, "Shortcut \"\(name)\" failed with exit code 1")
        }
        iphone.lastFeedback = nil
        iphone.triggerFlow(id: comboFlow.id)
        try await waitUntil("iPhone receives failure feedback") {
            iphone.lastFeedback != nil
        }
        let errToast = try XCTUnwrap(iphone.lastFeedback)
        XCTAssertFalse(errToast.success)
        XCTAssertTrue(errToast.title.contains("Step 2"), "Expected Step 2 in title: \(errToast.title)")
        XCTAssertTrue((errToast.detail ?? "").contains("Shortcut \"Copy Branch Ticket\" failed with exit code 1"))
        XCTAssertEqual(
            driver.recordedCalls,
            [
                .openWebsite(url: "https://github.com/pulls", switchExistingTab: true),
                .runShortcut(name: "Copy Branch Ticket")
            ]
        )
    }

    // MARK: - Helpers

    private nonisolated static func isLoopbackSocketAllowedByEnvironment() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else { return false }

        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        guard nameRes == 0 else { return false }

        let clientFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard clientFD >= 0 else { return false }
        defer { Darwin.close(clientFD) }

        let connRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connRes == 0
    }

    private func waitUntil(
        _ description: String,
        timeoutSeconds: TimeInterval = 4.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw TimeoutError(label: description)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
