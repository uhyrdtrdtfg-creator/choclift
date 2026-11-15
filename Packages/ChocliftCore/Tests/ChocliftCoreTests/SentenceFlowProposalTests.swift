#if os(macOS)
import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
private final class SentenceFlowRecordingDriver: ActionFlowDriver {
    enum RecordedCall: Equatable {
        case launch(bundleID: String, appPath: String?)
        case waitWindow(bundleID: String, pid: Int32, action: SystemQuickAction)
        case systemAction(action: SystemQuickAction, target: FlowSystemActionTarget)
        case openWebsite(url: String, switchExistingTab: Bool, browserBundleIdentifier: String?)
        case runShortcut(name: String)
        case insertSnippet(snippetID: UUID, titleSnapshot: String?, preferredPID: Int32?)
        case quitApp(bundleID: String, appPath: String?)
        case openFolder(folderPath: String, bundleID: String, appPath: String?)
        case sleep(seconds: Double)
    }

    var fallbackExternalAppPID: Int32? = 700
    var recordedCalls: [RecordedCall] = []
    var runningAppsByBundleID: [String: FlowAppHandle] = [:]
    var frontmostApp: FlowAppHandle?
    private var nextPID: Int32 = 300

    func launchOrActivateApp(
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String, app: FlowAppHandle?) {
        recordedCalls.append(.launch(bundleID: bundleIdentifier, appPath: appPath))
        let handle: FlowAppHandle
        if let existing = runningAppsByBundleID[bundleIdentifier] {
            handle = existing
        } else {
            nextPID += 1
            handle = FlowAppHandle(
                bundleIdentifier: bundleIdentifier,
                appName: bundleIdentifier,
                processIdentifier: nextPID
            )
            runningAppsByBundleID[bundleIdentifier] = handle
        }
        frontmostApp = handle
        return (true, "Launched \(bundleIdentifier)", handle)
    }

    func currentFrontmostApp() -> FlowAppHandle? {
        frontmostApp
    }

    func runningApp(forBundleIdentifier bundleIdentifier: String) -> FlowAppHandle? {
        runningAppsByBundleID[bundleIdentifier]
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
        return (true, "Executed \(action.rawValue)")
    }

    func openWebsite(
        url: String,
        switchExistingTab: Bool,
        browserBundleIdentifier: String?
    ) async -> (success: Bool, message: String) {
        recordedCalls.append(.openWebsite(url: url, switchExistingTab: switchExistingTab, browserBundleIdentifier: browserBundleIdentifier))
        return (true, "Opened \(url)")
    }

    func quitApp(
        bundleIdentifier: String,
        appPath: String?
    ) -> (success: Bool, message: String) {
        recordedCalls.append(.quitApp(bundleID: bundleIdentifier, appPath: appPath))
        return (true, "Quit \(bundleIdentifier)")
    }

    func openFolderInApp(
        folderPath: String,
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String) {
        recordedCalls.append(.openFolder(folderPath: folderPath, bundleID: bundleIdentifier, appPath: appPath))
        return (true, "Opened \(folderPath)")
    }

    func runShortcut(
        named shortcutName: String
    ) async -> (success: Bool, message: String) {
        recordedCalls.append(.runShortcut(name: shortcutName))
        return (true, "Ran \(shortcutName)")
    }

    func insertSnippet(
        snippetID: UUID,
        titleSnapshot: String?,
        preferredPID: Int32?
    ) -> (success: Bool, message: String) {
        recordedCalls.append(.insertSnippet(snippetID: snippetID, titleSnapshot: titleSnapshot, preferredPID: preferredPID))
        return (true, "Inserted snippet")
    }

    func sleep(seconds: Double) async {
        recordedCalls.append(.sleep(seconds: seconds))
    }
}

@MainActor
private final class SentenceFlowMacDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile = {
        var base = ChocliftDefaults.makeDefaultProfile()
        base.settings.language = .english
        return base
    }()
    weak var server: MacServerEngine?
    let driver: SentenceFlowRecordingDriver
    let sentenceFlow: MacSentenceFlowController
    var outboundRepliesToCompanion: [ServerMessage] = []

    init(
        driver: SentenceFlowRecordingDriver,
        apiKeyProvider: @escaping () -> String?,
        client: XAIFlowProposalClient
    ) {
        self.driver = driver
        var delegateBox: SentenceFlowMacDelegate?
        self.sentenceFlow = MacSentenceFlowController(
            apiKeyProvider: apiKeyProvider,
            client: client,
            contextProvider: {
                ActionFlowProposalCatalogContext(language: .english)
            },
            onSaveFlow: { flow in
                guard let strongSelf = delegateBox else { return }
                strongSelf.profile.upsertFlow(flow)
                strongSelf.server?.broadcast(.profileUpdated(strongSelf.profile))
            },
            onExecuteFlow: { flow, _ in
                await ActionFlowRunner.run(flow, driver: driver, language: .english)
            }
        )
        delegateBox = self
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { driver.frontmostApp?.bundleIdentifier }
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
        case .proposeFlow(let sentence):
            Task { @MainActor in
                let outcome = await self.sentenceFlow.propose(
                    sentence: sentence,
                    originDeviceName: device.deviceName
                )
                let sanitized = MacSentenceFlowController.sanitizedCompanionFeedback(
                    for: outcome,
                    language: self.profile.settings.language
                )
                self.outboundRepliesToCompanion.append(sanitized)
                reply(sanitized)
            }

        case .triggerFlow(let flowID):
            Task { @MainActor in
                guard let savedFlow = self.profile.flow(withID: flowID) else {
                    let notFound = ServerMessage.actionFeedback(
                        success: false,
                        title: "Flow Not Found",
                        detail: "Flow Not Found"
                    )
                    self.outboundRepliesToCompanion.append(notFound)
                    reply(notFound)
                    return
                }
                let res = await ActionFlowRunner.run(savedFlow, driver: self.driver, language: .english)
                let msg = ServerMessage.actionFeedback(success: res.success, title: res.title, detail: res.detail)
                self.outboundRepliesToCompanion.append(msg)
                reply(msg)
            }

        default:
            break
        }
    }
}

@MainActor
final class SentenceFlowProposalTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    private func waitUntil(
        _ label: String,
        timeoutSeconds: Double = 3.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw TimeoutError(label: label)
    }

    private static func makeResponsesAPIEnvelopeData(assistantJSONText: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": "resp_test_001",
            "object": "response",
            "model": "grok-4.7",
            "status": "completed",
            "output": [
                [
                    "type": "reasoning",
                    "status": "completed",
                    "encrypted_content": "enc_reasoning_blob"
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "status": "completed",
                    "content": [
                        [
                            "type": "output_text",
                            "text": assistantJSONText
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: 1. Fixture JSON Decoding (Launch Step + Delay)

    func testFixtureJSONWithLaunchStepAndDelayDecodesIntoDraft() throws {
        let fixtureJSON = """
        {
          "name": "Open Safari & Pause",
          "emoji": "🧭",
          "backgroundHex": "#ECFAFE",
          "steps": [
            {
              "type": "launch_or_activate_app",
              "bundleIdentifier": "com.apple.Safari",
              "appName": "Safari"
            },
            {
              "type": "delay",
              "seconds": 1.25
            }
          ]
        }
        """

        let draft = try ActionFlowDraftDecoder.decodeDraft(
            from: fixtureJSON,
            sourceSentence: "Open Safari and wait 1.25 seconds",
            originDeviceName: "Mac Studio"
        )

        XCTAssertEqual(draft.sourceSentence, "Open Safari and wait 1.25 seconds")
        XCTAssertEqual(draft.originDeviceName, "Mac Studio")
        XCTAssertEqual(draft.flow.name, "Open Safari & Pause")
        XCTAssertEqual(draft.flow.emoji, "🧭")
        XCTAssertEqual(draft.flow.backgroundHex, "#ECFAFE")
        XCTAssertEqual(draft.flow.steps.count, 2)
        XCTAssertEqual(
            draft.flow.steps[0].kind,
            .launchOrActivateApp(bundleIdentifier: "com.apple.Safari", appName: "Safari", appPath: nil)
        )
        XCTAssertEqual(draft.flow.steps[1].kind, .delay(seconds: 1.25))

        // Nested "kind" representation is also accepted
        let nestedFixtureJSON = """
        {
          "name": "Nested Launch & Delay",
          "emoji": "⚡️",
          "backgroundHex": "#FFF3E0",
          "steps": [
            {
              "isEnabled": true,
              "kind": {
                "type": "launch_or_activate_app",
                "bundleIdentifier": "com.apple.Notes",
                "appName": "Notes"
              }
            },
            {
              "isEnabled": true,
              "kind": {
                "type": "delay",
                "seconds": 0.5
              }
            }
          ]
        }
        """
        let nestedDraft = try ActionFlowDraftDecoder.decodeDraft(from: nestedFixtureJSON)
        XCTAssertEqual(nestedDraft.flow.steps.count, 2)
        XCTAssertEqual(
            nestedDraft.flow.steps[0].kind,
            .launchOrActivateApp(bundleIdentifier: "com.apple.Notes", appName: "Notes", appPath: nil)
        )
        XCTAssertEqual(nestedDraft.flow.steps[1].kind, .delay(seconds: 0.5))
    }

    // MARK: 2. Unknown Step Type Fails the Draft (Never Becomes a Runnable Step)

    func testUnknownStepTypeFailsDraftDecoding() {
        let unknownStepFixture = """
        {
          "name": "Dangerous Shell Flow",
          "emoji": "🛑",
          "backgroundHex": "#FFE4E6",
          "steps": [
            {
              "type": "launch_or_activate_app",
              "bundleIdentifier": "com.apple.Terminal",
              "appName": "Terminal"
            },
            {
              "type": "execute_shell_command",
              "command": "rm -rf /tmp/demo"
            }
          ]
        }
        """

        XCTAssertThrowsError(try ActionFlowDraftDecoder.decodeDraft(from: unknownStepFixture)) { error in
            XCTAssertEqual(
                error as? ActionFlowProposalError,
                .unknownStepType("execute_shell_command")
            )
        }

        let unknownSystemActionFixture = """
        {
          "name": "Unknown System Action",
          "steps": [
            {
              "type": "system_action",
              "action": "format_hard_drive"
            }
          ]
        }
        """

        XCTAssertThrowsError(try ActionFlowDraftDecoder.decodeDraft(from: unknownSystemActionFixture)) { error in
            XCTAssertEqual(
                error as? ActionFlowProposalError,
                .unknownStepType("system_action:format_hard_drive")
            )
        }
    }

    // MARK: 3. Confirm Is Separate From Propose, and Propose Never Calls the Executor

    func testProposeNeverCallsExecutorAndConfirmSavesThenRunsFlow() async throws {
        let fixtureDraftJSON = """
        {
          "name": "Safari Focus",
          "emoji": "🧭",
          "backgroundHex": "#ECFAFE",
          "steps": [
            {
              "type": "launch_or_activate_app",
              "bundleIdentifier": "com.apple.Safari",
              "appName": "Safari"
            },
            {
              "type": "delay",
              "seconds": 0.75
            }
          ]
        }
        """
        let responseData = try Self.makeResponsesAPIEnvelopeData(assistantJSONText: fixtureDraftJSON)

        final class RequestRecorder: @unchecked Sendable {
            var requests: [URLRequest] = []
        }
        let recorder = RequestRecorder()

        let mockClient = XAIFlowProposalClient(
            transport: { request in
                recorder.requests.append(request)
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (responseData, http)
            }
        )

        let driver = SentenceFlowRecordingDriver()
        var savedFlows: [ActionFlow] = []
        var executorInvocations = 0

        let controller = MacSentenceFlowController(
            apiKeyProvider: { "xai-unit-test-fake-key-12345" },
            client: mockClient,
            contextProvider: { ActionFlowProposalCatalogContext(language: .english) },
            onSaveFlow: { flow in
                savedFlows.append(flow)
            },
            onExecuteFlow: { flow, source in
                executorInvocations += 1
                XCTAssertEqual(source, "Mac Studio")
                return await ActionFlowRunner.run(flow, driver: driver, language: .english)
            }
        )

        // 1. Propose creates a pending draft, saves NOTHING, and NEVER calls the executor.
        let outcome = await controller.propose(sentence: "Open Safari then wait 0.75 seconds")
        let proposedDraft = try outcome.get()

        XCTAssertEqual(controller.pendingDraft, proposedDraft)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(savedFlows.isEmpty, "propose() must not save the flow before Mac confirmation")
        XCTAssertEqual(executorInvocations, 0, "propose() must never call the flow executor")
        XCTAssertTrue(driver.recordedCalls.isEmpty, "propose() must never run any ActionFlowDriver step")

        // Verify xAI Responses endpoint, model grok-4.7, Bearer header, and system prompt step kinds
        XCTAssertEqual(recorder.requests.count, 1)
        let sentRequest = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sentRequest.url?.absoluteString, "https://api.x.ai/v1/responses")
        XCTAssertEqual(sentRequest.httpMethod, "POST")
        XCTAssertEqual(sentRequest.value(forHTTPHeaderField: "Authorization"), "Bearer xai-unit-test-fake-key-12345")

        let sentBody = try XCTUnwrap(sentRequest.httpBody)
        let sentJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        XCTAssertEqual(sentJSON["model"] as? String, "grok-4.7")
        XCTAssertEqual(sentJSON["store"] as? Bool, false)
        let inputMessages = try XCTUnwrap(sentJSON["input"] as? [[String: Any]])
        XCTAssertEqual(inputMessages.count, 2)
        XCTAssertEqual(inputMessages[0]["role"] as? String, "system")
        XCTAssertEqual(inputMessages[1]["role"] as? String, "user")
        XCTAssertEqual(inputMessages[1]["content"] as? String, "Open Safari then wait 0.75 seconds")

        let systemPrompt = try XCTUnwrap(inputMessages[0]["content"] as? String)
        for allowedTag in ActionFlowSystemPromptBuilder.allowedStepTypeTags {
            XCTAssertTrue(systemPrompt.contains("\"\(allowedTag)\""), "System prompt must list \(allowedTag)")
        }
        XCTAssertEqual(ActionFlowSystemPromptBuilder.allowedStepTypeTags.count, 9)

        // 2. Cancel discards the draft without saving or executing; subsequent confirm is a no-op.
        controller.cancelDraft()
        XCTAssertNil(controller.pendingDraft)
        let confirmAfterCancel = await controller.confirmDraft()
        XCTAssertNil(confirmAfterCancel)
        XCTAssertTrue(savedFlows.isEmpty)
        XCTAssertEqual(executorInvocations, 0)
        XCTAssertTrue(driver.recordedCalls.isEmpty)

        // 3. Propose again, then explicitly call separate confirmDraft() -> saves and executes.
        let secondOutcome = await controller.propose(sentence: "Open Safari then wait 0.75 seconds")
        let secondDraft = try secondOutcome.get()
        XCTAssertEqual(executorInvocations, 0)
        XCTAssertTrue(savedFlows.isEmpty)

        let maybeRunResult = await controller.confirmDraft(expectedDraftID: secondDraft.id)
        let runResult = try XCTUnwrap(maybeRunResult)
        XCTAssertTrue(runResult.success)
        XCTAssertNil(controller.pendingDraft)
        XCTAssertEqual(savedFlows.count, 1)
        XCTAssertEqual(savedFlows.first?.id, secondDraft.flow.id)
        XCTAssertEqual(executorInvocations, 1)
        XCTAssertEqual(
            driver.recordedCalls,
            [
                .launch(bundleID: "com.apple.Safari", appPath: nil),
                .sleep(seconds: 0.75)
            ]
        )
    }

    // MARK: 4. Missing Key, HTTP Status / Decode Errors, Key Resolver & Secret Redaction

    func testMissingKeyHTTPStatusDecodeErrorsAndKeyRedaction() async throws {
        final class CallCounter: @unchecked Sendable {
            var count = 0
        }
        let transportCalls = CallCounter()
        let unusedClient = XAIFlowProposalClient(transport: { req in
            transportCalls.count += 1
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), http)
        })

        var savedFlows: [ActionFlow] = []
        var executedCount = 0

        let missingKeyController = MacSentenceFlowController(
            apiKeyProvider: { nil },
            client: unusedClient,
            contextProvider: { ActionFlowProposalCatalogContext(language: .english) },
            onSaveFlow: { savedFlows.append($0) },
            onExecuteFlow: { _, _ in
                executedCount += 1
                return ActionFlowRunResult(success: true, title: "", detail: "", executedStepCount: 0)
            }
        )

        // Missing XAI_API_KEY explains the problem and never pretends a flow was created
        let missingOutcome = await missingKeyController.propose(sentence: "Open Notes")
        XCTAssertEqual(missingOutcome, Result<ActionFlowDraft, ActionFlowProposalError>.failure(.missingAPIKey))
        XCTAssertNil(missingKeyController.pendingDraft)
        XCTAssertTrue(savedFlows.isEmpty)
        XCTAssertEqual(executedCount, 0)
        XCTAssertEqual(transportCalls.count, 0)
        let missingMsg = try XCTUnwrap(missingKeyController.errorMessage)
        XCTAssertTrue(missingMsg.contains("XAI_API_KEY"))
        XCTAssertTrue(missingMsg.lowercased().contains("no flow was created"))

        // HTTP status error surfaces status code and redacts any echoed secret key
        let secretKey = "xai-super-secret-never-leak-8888"
        let http401Client = XAIFlowProposalClient(transport: { req in
            let body = #"{"error":{"message":"Invalid key xai-super-secret-never-leak-8888 provided"}}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        })
        let statusController = MacSentenceFlowController(
            apiKeyProvider: { secretKey },
            client: http401Client,
            contextProvider: { ActionFlowProposalCatalogContext(language: .english) },
            onSaveFlow: { savedFlows.append($0) },
            onExecuteFlow: { _, _ in
                executedCount += 1
                return ActionFlowRunResult(success: true, title: "", detail: "", executedStepCount: 0)
            }
        )
        let httpOutcome = await statusController.propose(sentence: "Open Notes")
        if case .failure(.httpStatus(let code, _)) = httpOutcome {
            XCTAssertEqual(code, 401)
        } else {
            XCTFail("Expected .httpStatus(401), got \(httpOutcome)")
        }
        let statusErrText = try XCTUnwrap(statusController.errorMessage)
        XCTAssertTrue(statusErrText.contains("401"))
        XCTAssertFalse(statusErrText.contains(secretKey), "Error message must never expose XAI_API_KEY")
        XCTAssertNil(statusController.pendingDraft)

        // Malformed model JSON surfaces decode error without creating a draft
        let badJSONData = try Self.makeResponsesAPIEnvelopeData(assistantJSONText: "{not valid json")
        let badJSONClient = XAIFlowProposalClient(transport: { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (badJSONData, http)
        })
        let decodeErrController = MacSentenceFlowController(
            apiKeyProvider: { secretKey },
            client: badJSONClient,
            contextProvider: { ActionFlowProposalCatalogContext(language: .english) },
            onSaveFlow: { savedFlows.append($0) },
            onExecuteFlow: { _, _ in
                executedCount += 1
                return ActionFlowRunResult(success: true, title: "", detail: "", executedStepCount: 0)
            }
        )
        let decodeOutcome = await decodeErrController.propose(sentence: "Open Notes")
        if case .failure(.draftDecodeFailed) = decodeOutcome {
            // Expected
        } else {
            XCTFail("Expected .draftDecodeFailed, got \(decodeOutcome)")
        }
        XCTAssertNotNil(decodeErrController.errorMessage)
        XCTAssertNil(decodeErrController.pendingDraft)
        XCTAssertEqual(executedCount, 0)

        // Verify XAIAPIKeyResolver reads from environment or local git-ignored files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("xai_key_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let envFile = tempDir.appendingPathComponent(".env")
        try #"export XAI_API_KEY="file-dotenv-key-777""#.write(to: envFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            XAIAPIKeyResolver.resolveKey(environment: ["XAI_API_KEY": "env-priority-key"], candidateFileURLs: [envFile]),
            "env-priority-key"
        )
        XCTAssertEqual(
            XAIAPIKeyResolver.resolveKey(environment: [:], candidateFileURLs: [envFile]),
            "file-dotenv-key-777"
        )
    }

    // MARK: 5. Phone-to-Mac Companion Message Isolation (No Key, No Raw Response, No Phone Confirm)

    func testPhoneSendsSentenceOnlyAndCannotRunOrConfirmWithoutMacConfirmation() async throws {
        let suiteName = "com.choclift.sentenceflow.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let fakeSecretKey = "xai-mac-only-key-do-not-send-to-phone"
        let rawModelJSON = """
        {
          "name": "Open Finder & Wait",
          "emoji": "🗂️",
          "backgroundHex": "#ECFAFE",
          "steps": [
            {
              "type": "launch_or_activate_app",
              "bundleIdentifier": "com.apple.finder",
              "appName": "Finder"
            },
            {
              "type": "delay",
              "seconds": 0.25
            }
          ]
        }
        """
        let envelopeData = try Self.makeResponsesAPIEnvelopeData(assistantJSONText: rawModelJSON)
        let mockClient = XAIFlowProposalClient(transport: { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (envelopeData, http)
        })

        let driver = SentenceFlowRecordingDriver()
        let delegate = SentenceFlowMacDelegate(
            driver: driver,
            apiKeyProvider: { fakeSecretKey },
            client: mockClient
        )
        let server = MacServerEngine(macID: "mac-sentence-host", macName: "Studio Mac")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        let iphone = CompanionClientEngine(
            deviceID: "iphone-sentence-1",
            deviceName: "Xiaobo iPhone",
            platform: .iPhone,
            userDefaults: isolatedDefaults,
            storageKeyPrefix: "iphoneSentence"
        )
        defer { iphone.disconnect() }

        let link = server.acceptInMemoryCompanion()
        iphone.connectInMemoryBluetooth(to: link, targetName: "Studio Mac", macID: "mac-sentence-host")
        try await waitUntil("iPhone awaiting PIN") {
            if case .awaitingPIN = iphone.connectionState { return true }
            return false
        }
        iphone.submitPIN(server.currentPIN)
        try await waitUntil("iPhone connected") { iphone.connectionState.isConnected }

        // Wire protocol round-trip check for ClientMessage.proposeFlow
        let encodedFrame = try WireFrameCodec.encode(ClientMessage.proposeFlow(sentence: "Open Finder then pause"))
        var accumulator = WireStreamAccumulator()
        let decodedPayloads = try accumulator.appendAndExtractPayloads(encodedFrame)
        XCTAssertEqual(decodedPayloads.count, 1)
        let decodedMessage = try WireFrameCodec.decodePayload(ClientMessage.self, from: decodedPayloads[0])
        XCTAssertEqual(decodedMessage, ClientMessage.proposeFlow(sentence: "Open Finder then pause"))

        // iPhone sends only the sentence text
        XCTAssertTrue(iphone.proposeFlow(sentence: "Open Finder and pause 0.25s"))

        try await waitUntil("Mac draft ready & phone notified") {
            delegate.sentenceFlow.pendingDraft != nil && !delegate.outboundRepliesToCompanion.isEmpty
        }

        let pendingDraft = try XCTUnwrap(delegate.sentenceFlow.pendingDraft)
        XCTAssertEqual(pendingDraft.originDeviceName, "Xiaobo iPhone")
        XCTAssertTrue(delegate.profile.flows.isEmpty, "Draft must not be saved until Mac confirms")
        XCTAssertTrue(iphone.profile.flows.isEmpty, "Phone must not receive unconfirmed draft flow")
        XCTAssertTrue(driver.recordedCalls.isEmpty, "Executor must not run before Mac confirms")

        // Verify phone never received API key, raw model JSON, or draft ID
        for replyMsg in delegate.outboundRepliesToCompanion {
            let replyJSON = String(decoding: try JSONEncoder().encode(replyMsg), as: UTF8.self)
            XCTAssertFalse(replyJSON.contains(fakeSecretKey))
            XCTAssertFalse(replyJSON.contains("launch_or_activate_app"))
            XCTAssertFalse(replyJSON.contains("com.apple.finder"))
            XCTAssertFalse(replyJSON.contains(pendingDraft.flow.id.uuidString))
        }

        // Even if the phone attempts triggerFlow with the draft's UUID before Mac confirms, nothing runs
        iphone.triggerFlow(id: pendingDraft.flow.id)
        try await waitUntil("Unconfirmed triggerFlow rejected") {
            delegate.outboundRepliesToCompanion.count >= 2
        }
        XCTAssertTrue(driver.recordedCalls.isEmpty, "Phone cannot run an unconfirmed draft")

        // Mac user taps Confirm -> saves flow, syncs profile, and executes steps on Mac
        let maybeConfirmedRun = await delegate.sentenceFlow.confirmDraft()
        let runResult = try XCTUnwrap(maybeConfirmedRun)
        XCTAssertTrue(runResult.success)
        XCTAssertEqual(delegate.profile.flows.count, 1)
        XCTAssertEqual(
            driver.recordedCalls,
            [
                .launch(bundleID: "com.apple.finder", appPath: nil),
                .sleep(seconds: 0.25)
            ]
        )
    }
}
#endif
