import Foundation
import XCTest
@testable import ChocliftCore

final class OrcaTaskStatusTests: XCTestCase {
    func testParserMapsWorkerListFixtureIntoFourStatesAndDropsTokensAndTranscripts() throws {
        let fixtureJSON = """
        {
          "ok": true,
          "daemonToken": "dt_top_level_secret_1234567890",
          "result": {
            "workers": [
              {
                "dispatchId": "ctx_1111aaaa2222",
                "taskId": "task_working_1",
                "runId": "run_current",
                "state": "ready",
                "outcome": "in_progress",
                "liveness": "live",
                "title": "Orca task status tile",
                "terminal": "term_728e0dcb-7c29-47fd-91c8-d9b9a9c666b6",
                "terminalState": "retained",
                "workspace": "repo-1::/Users/dev/orca/workspaces/choclift-orca-status",
                "host": "local",
                "daemonToken": "dt_worker_secret_abcdef123456",
                "pairingCode": "orca://pair?code=482910&secret=xyz987",
                "env": {
                  "ORCA_DAEMON_TOKEN": "env_secret_value_999",
                  "OPENAI_API_KEY": "sk-live-secretkey1234567890"
                },
                "transcript": "=== TASK ===\\nRunning build...\\nSecret token in scrollback"
              },
              {
                "dispatchId": "ctx_2222bbbb3333",
                "taskId": "task_waiting_2",
                "runId": "run_current",
                "state": "ready",
                "outcome": "in_progress",
                "liveness": "live",
                "title": "ORCA_DAEMON_TOKEN=9f8e7d6c5b4a3210secret",
                "attention": {
                  "requiresAction": true,
                  "categories": ["question"]
                },
                "terminal": "term_waiting_handle",
                "terminalState": "active",
                "host": "local"
              },
              {
                "dispatchId": "ctx_3333cccc4444",
                "taskId": "task_failed_3",
                "runId": "run_current",
                "state": "stopped",
                "outcome": "failed",
                "liveness": "exited",
                "title": "=== TASK ===\\n$ xcodebuild test\\nerror: build failed",
                "attention": ["failure"],
                "terminal": "term_failed_handle",
                "terminalState": "retained",
                "host": "local"
              },
              {
                "dispatchId": "ctx_4444dddd5555",
                "taskId": "task_idle_4",
                "runId": "run_current",
                "state": "succeeded",
                "liveness": "unverifiable",
                "attention": ["unverifiable"],
                "title": "Earlier settled task",
                "terminal": "term_idle_handle",
                "terminalState": "retained",
                "host": "local"
              }
            ]
          }
        }
        """

        let entries = try OrcaWorkerListParser.parseEntries(Data(fixtureJSON.utf8))
        let items = entries.map(\.item)
        XCTAssertEqual(items.count, 4)

        // 1. Verify all four states are produced accurately.
        XCTAssertEqual(items.map(\.state), [.working, .waiting, .failed, .idle])

        // 2. Verify clean title survives while env-var and transcript-body titles are dropped.
        XCTAssertEqual(items[0].title, "Orca task status tile")
        XCTAssertNil(items[1].title)
        XCTAssertNil(items[2].title)
        XCTAssertEqual(items[3].title, "Earlier settled task")

        // 3. Verify focusability: running/failed local workers can focus, settled idle worker cannot.
        XCTAssertTrue(items[0].canFocusWindow)
        XCTAssertTrue(items[0].canTapToFocus)
        XCTAssertTrue(items[1].canFocusWindow)
        XCTAssertTrue(items[2].canFocusWindow)
        XCTAssertFalse(items[3].canFocusWindow)
        XCTAssertFalse(items[3].canTapToFocus)

        // 4. Verify additional token / pairing-code / JWT / high-entropy secret shapes are dropped.
        XCTAssertNil(OrcaWorkerListParser.sanitizeTitle("orca://pair?host=127.0.0.1&code=123456"))
        XCTAssertNil(OrcaWorkerListParser.sanitizeTitle("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"))
        XCTAssertNil(OrcaWorkerListParser.sanitizeTitle("Deploy with key sk-proj1234567890abcdef"))
        XCTAssertNil(OrcaWorkerListParser.sanitizeTitle("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"))
        XCTAssertNil(OrcaWorkerListParser.sanitizeTitle("Pairing code: 482910"))
        XCTAssertEqual(OrcaWorkerListParser.sanitizeTitle("Implement compact status row"), "Implement compact status row")

        // 5. Verify encoded ServerMessage wire payload contains ONLY allowed fields and zero leaked secrets/handles/paths.
        let snapshot = OrcaWorkerListParser.buildWireSnapshot(from: entries)
        XCTAssertTrue(snapshot.isOrcaRunning)
        XCTAssertEqual(snapshot.tasks.map(\.state), [.working, .waiting, .failed])

        let encodedPayload = try JSONEncoder().encode(ServerMessage.orcaStatusUpdated(snapshot))
        let wireJSONString = try XCTUnwrap(String(data: encodedPayload, encoding: .utf8))

        XCTAssertTrue(wireJSONString.contains("ctx_1111aaaa2222"))
        XCTAssertTrue(wireJSONString.contains("Orca task status tile"))

        let forbiddenLeaks = [
            "dt_top_level_secret",
            "dt_worker_secret",
            "orca://pair",
            "env_secret_value",
            "sk-live-secretkey",
            "9f8e7d6c5b4a3210secret",
            "Running build",
            "term_728e0dcb",
            "term_waiting_handle",
            "term_failed_handle",
            "/Users/dev/orca/workspaces"
        ]
        for forbidden in forbiddenLeaks {
            XCTAssertFalse(wireJSONString.contains(forbidden), "Wire payload leaked \(forbidden)")
        }
    }

    func testTaskListHydrationAndAllSettledIdleSnapshot() throws {
        let workersJSON = """
        {
          "ok": true,
          "result": {
            "workers": [
              {
                "dispatchId": "ctx_settled_1",
                "taskId": "task_settled_1",
                "runId": "run_done",
                "workerState": "succeeded",
                "dispatchStatus": "completed",
                "terminalState": "released"
              }
            ]
          }
        }
        """
        let tasksJSON = """
        {
          "ok": true,
          "result": {
            "tasks": [
              {
                "id": "task_settled_1",
                "dispatchId": "ctx_settled_1",
                "title": "Verify wire framing"
              },
              {
                "id": "task_secret_2",
                "title": "ghp_1234567890abcdefghijklmnopqrstuv"
              }
            ]
          }
        }
        """

        let titles = OrcaWorkerListParser.parseTaskTitles(Data(tasksJSON.utf8))
        XCTAssertEqual(titles.byTaskID["task_settled_1"], "Verify wire framing")
        XCTAssertNil(titles.byTaskID["task_secret_2"])

        let entries = try OrcaWorkerListParser.parseEntries(
            Data(workersJSON.utf8),
            taskTitlesByID: titles.byTaskID,
            taskTitlesByDispatchID: titles.byDispatchID
        )
        let snapshot = OrcaWorkerListParser.buildWireSnapshot(from: entries)
        XCTAssertTrue(snapshot.isOrcaRunning)
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.state, .idle)
        XCTAssertEqual(snapshot.tasks.first?.title, "Verify wire framing")
        XCTAssertFalse(snapshot.tasks.first?.canFocusWindow ?? true)
    }

    func testCommandBuilderEnforcesDirectOrcaBinaryAndNoShells() throws {
        XCTAssertThrowsError(try OrcaCommandBuilder.validateExecutablePath("/bin/sh"))
        XCTAssertThrowsError(try OrcaCommandBuilder.validateExecutablePath("/bin/zsh"))
        XCTAssertThrowsError(try OrcaCommandBuilder.validateExecutablePath("/usr/bin/git"))
        XCTAssertThrowsError(try OrcaCommandBuilder.validateExecutablePath("orca"))

        let workerCmd = try OrcaCommandBuilder.workerListCommand(
            executablePath: "/Applications/Orca.app/Contents/Resources/bin/orca",
            limit: 25,
            full: true
        )
        XCTAssertEqual(workerCmd.executablePath, "/Applications/Orca.app/Contents/Resources/bin/orca")
        XCTAssertEqual(workerCmd.arguments, ["orchestration", "worker-list", "--full", "--limit", "25", "--json"])

        let focusCmd = try OrcaCommandBuilder.terminalSwitchCommand(
            executablePath: "/usr/local/bin/orca",
            terminalHandle: "term_728e0dcb-7c29-47fd-91c8-d9b9a9c666b6"
        )
        XCTAssertEqual(focusCmd.arguments, ["terminal", "switch", "--terminal", "term_728e0dcb-7c29-47fd-91c8-d9b9a9c666b6", "--json"])
        XCTAssertThrowsError(
            try OrcaCommandBuilder.terminalSwitchCommand(
                executablePath: "/usr/local/bin/orca",
                terminalHandle: "--malicious-flag"
            )
        )

        let env = OrcaCommandBuilder.cleanSubprocessEnvironment(homeDirectory: "/Users/tester")
        XCTAssertEqual(Set(env.keys), ["HOME", "PATH", "LANG"])
    }

    #if os(macOS)
    func testLiveReadOnlyOrcaSnapshotIfRunning() throws {
        guard let executablePath = OrcaCommandBuilder.resolveExecutablePath() else {
            return
        }
        let spec = try OrcaCommandBuilder.workerListCommand(
            executablePath: executablePath,
            limit: 10,
            full: true
        )
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: spec.executablePath)
        proc.arguments = spec.arguments
        proc.environment = OrcaCommandBuilder.cleanSubprocessEnvironment()
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? Pipe()
        try proc.run()
        let workerData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, !workerData.isEmpty else {
            // Orca binary is installed, but the runtime is not currently running.
            return
        }

        var entries = try OrcaWorkerListParser.parseEntries(workerData)
        if let runID = entries.first?.runID {
            let taskSpec = try OrcaCommandBuilder.taskListCommand(executablePath: executablePath, runID: runID)
            let taskProc = Process()
            taskProc.executableURL = URL(fileURLWithPath: taskSpec.executablePath)
            taskProc.arguments = taskSpec.arguments
            taskProc.environment = OrcaCommandBuilder.cleanSubprocessEnvironment()
            let taskPipe = Pipe()
            taskProc.standardOutput = taskPipe
            taskProc.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? Pipe()
            try taskProc.run()
            let taskData = taskPipe.fileHandleForReading.readDataToEndOfFile()
            taskProc.waitUntilExit()
            if taskProc.terminationStatus == 0, !taskData.isEmpty {
                let titles = OrcaWorkerListParser.parseTaskTitles(taskData)
                entries = try OrcaWorkerListParser.parseEntries(
                    workerData,
                    taskTitlesByID: titles.byTaskID,
                    taskTitlesByDispatchID: titles.byDispatchID
                )
            }
        }

        let snapshot = OrcaWorkerListParser.buildWireSnapshot(from: entries)
        XCTAssertTrue(snapshot.isOrcaRunning)
        XCTAssertFalse(snapshot.displayRows.isEmpty)
        for row in snapshot.tasks {
            XCTAssertFalse(row.state == .idle && row.canFocusWindow)
        }
    }
    #endif

    @MainActor
    func testPostAuthUnknownServerFrameIsIgnoredWhilePreAuthUnknownFrameDisconnects() async throws {
        let suiteName = "com.choclift.orca.wire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Helper to build a valid length-prefixed frame with an unrecognized ServerMessage case.
        func makeUnknownServerFrame() -> Data {
            let unknownPayload = Data(#"{"futureUnknownServerEvent":{"detail":"ignored"}}"#.utf8)
            var lengthBE = UInt32(unknownPayload.count).bigEndian
            var framed = Data(capacity: 4 + unknownPayload.count)
            withUnsafeBytes(of: &lengthBE) { framed.append(contentsOf: $0) }
            framed.append(unknownPayload)
            return framed
        }

        // 1. Pre-auth unknown ServerMessage frame still disconnects cleanly.
        let (preAuthServerEnd, preAuthClientEnd) = InMemoryCompanionPipe.pair()
        preAuthServerEnd.start()
        let preAuthClient = CompanionClientEngine(
            deviceID: "iphone-preauth",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "preauth"
        )
        preAuthClient.maxAutoReconnectAttempts = 0
        defer { preAuthClient.disconnect() }

        preAuthClient.connectInMemoryBluetooth(to: preAuthClientEnd, targetName: "Studio Mac")
        preAuthServerEnd.send(makeUnknownServerFrame())

        for _ in 0..<40 where preAuthClient.connectionState != .disconnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(preAuthClient.connectionState, .disconnected)

        // 2. Post-auth unknown ServerMessage frame is ignored without dropping the session,
        // and subsequent known frames (such as .orcaStatusUpdated) are processed normally.
        #if os(macOS)
        let delegate = OrcaWireTestDelegate()
        delegate.orcaSnapshot = OrcaTaskStatusSnapshot(
            isOrcaRunning: true,
            tasks: [
                OrcaTaskStatusItem(
                    dispatchID: "ctx_live_1",
                    state: .working,
                    title: "Orca task status tile",
                    canFocusWindow: true
                )
            ]
        )
        let server = MacServerEngine(macID: "mac-orca-host", macName: "Orca Mac")
        server.delegate = delegate
        defer { server.stop() }

        let serverTransport = server.acceptInMemoryCompanion()
        let (proxyToClient, clientPipe) = InMemoryCompanionPipe.pair()
        proxyToClient.onPayload = { data in serverTransport.send(data) }
        serverTransport.onPayload = { data in proxyToClient.send(data) }
        proxyToClient.start()
        serverTransport.start()

        let client = CompanionClientEngine(
            deviceID: "iphone-postauth",
            deviceName: "iPhone Pro",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "postauth"
        )
        defer { client.disconnect() }

        client.connectInMemoryBluetooth(to: clientPipe, targetName: "Orca Mac")
        for _ in 0..<50 {
            if case .awaitingPIN = client.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        client.submitPIN(server.currentPIN)
        for _ in 0..<50 where !client.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.connectionState.isConnected)
        XCTAssertEqual(client.orcaStatus, delegate.orcaSnapshot)

        // Inject an unknown ServerMessage frame concatenated right ahead of a new .orcaStatusUpdated frame.
        let updatedSnapshot = OrcaTaskStatusSnapshot(
            isOrcaRunning: true,
            tasks: [
                OrcaTaskStatusItem(
                    dispatchID: "ctx_failed_2",
                    state: .failed,
                    title: "Fix unit test",
                    canFocusWindow: true
                )
            ]
        )
        var combinedBurst = makeUnknownServerFrame()
        combinedBurst.append(try WireFrameCodec.encode(ServerMessage.orcaStatusUpdated(updatedSnapshot)))
        proxyToClient.send(combinedBurst)

        for _ in 0..<50 where client.orcaStatus != updatedSnapshot {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.connectionState.isConnected)
        XCTAssertEqual(client.orcaStatus, updatedSnapshot)

        // Tapping the failed row sends .focusOrcaTask(dispatchID:) to the Mac server.
        client.focusOrcaTask(dispatchID: "ctx_failed_2")
        for _ in 0..<50 where delegate.focusedDispatchIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.focusedDispatchIDs, ["ctx_failed_2"])

        // 3. Verify a legacy protocolVersion=2 session never receives .orcaStatusUpdated frames.
        let legacyPipe = server.acceptInMemoryCompanion()
        var legacyFrames: [Data] = []
        var legacyAcc = WireStreamAccumulator()
        legacyPipe.onPayload = { chunk in
            if let extracted = try? legacyAcc.appendAndExtractPayloads(chunk) {
                legacyFrames.append(contentsOf: extracted)
            }
        }
        legacyPipe.start()
        let savedToken = try XCTUnwrap(client.savedMacs.first?.authToken)
        legacyPipe.send(
            try WireFrameCodec.encode(
                ClientMessage.hello(
                    protocolVersion: 2,
                    deviceID: "legacy-v2-phone",
                    deviceName: "Legacy iPhone",
                    platform: .iPhone,
                    savedAuthToken: nil
                )
            )
        )
        legacyPipe.send(
            try WireFrameCodec.encode(
                ClientMessage.submitPIN(
                    pin: server.currentPIN,
                    deviceID: "legacy-v2-phone",
                    deviceName: "Legacy iPhone",
                    platform: .iPhone
                )
            )
        )
        _ = savedToken
        server.broadcast(
            .orcaStatusUpdated(updatedSnapshot),
            minimumProtocolVersion: ChocliftDefaults.orcaStatusMinProtocolVersion
        )
        try await Task.sleep(for: .milliseconds(50))

        let decodedLegacyMessages = try legacyFrames.map {
            try WireFrameCodec.decodePayload(ServerMessage.self, from: $0)
        }
        XCTAssertFalse(
            decodedLegacyMessages.contains {
                if case .orcaStatusUpdated = $0 { return true }
                return false
            }
        )
        #endif
    }
}

#if os(macOS)
@MainActor
private final class OrcaWireTestDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var orcaSnapshot: OrcaTaskStatusSnapshot?
    var focusedDispatchIDs: [String] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { orcaSnapshot }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        if case .focusOrcaTask(let dispatchID) = message {
            focusedDispatchIDs.append(dispatchID)
            reply(.actionFeedback(success: true, title: "Orca", detail: "Switched"))
        }
    }
}
#endif
