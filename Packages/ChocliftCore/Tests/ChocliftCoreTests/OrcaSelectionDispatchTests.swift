import Foundation
import XCTest
@testable import ChocliftCore

private actor SelectionCommands {
    var commands: [OrcaCommandSpec] = []
    var spec: String?
    let loggedIn: Bool
    let kiroAgent: Bool
    init(loggedIn: Bool = true, kiroAgent: Bool = false) {
        self.loggedIn = loggedIn
        self.kiroAgent = kiroAgent
    }
    func run(_ command: OrcaCommandSpec, directory: URL?) throws -> OrcaSelectionCommandResult {
        commands.append(command)
        let args = command.arguments
        if args.contains("worker-start") {
            let index = try XCTUnwrap(args.firstIndex(of: "--spec-file"))
            spec = try String(contentsOfFile: args[index + 1], encoding: .utf8)
            return .init(exitCode: 0, output: #"{"dispatchId":"dispatch-test"}"#)
        }
        if args == ["worktree", "show", "--worktree", "active", "--json"] {
            return .init(exitCode: 0, output: #"{"result":{"worktree":{"repoId":"repo-test"}}}"#)
        }
        if args == ["agent", "list", "--json"] {
            return .init(exitCode: 0, output: kiroAgent ? #"[{"id":"kiro"}]"# : "[]")
        }
        if args.starts(with: ["worktree", "create"]) {
            return .init(exitCode: 0, output: #"{"result":{"worktree":{"path":"/tmp/choclift-test"}}}"#)
        }
        if args.starts(with: ["terminal", "create"]) {
            XCTAssertEqual(args[args.firstIndex(of: "--command")! + 1], "true")
            return .init(exitCode: 0, output: #"{"result":{"terminalHandle":"term-test"}}"#)
        }
        XCTAssertEqual(directory?.path, "/tmp/choclift-test")
        if args == ["whoami"] {
            return .init(exitCode: loggedIn ? 0 : 1, output: loggedIn ? "user" : "Not logged in")
        }
        XCTAssertEqual(args.first, "chat")
        spec = args.last
        return .init(exitCode: 0, output: "done")
    }
}

final class OrcaSelectionDispatchTests: XCTestCase {
    func testEmptySelectionDoesNotRunAnyCommand() async {
        let recorder = SelectionCommands()
        do {
            _ = try await OrcaSelectionRunner.dispatch(selection: .init(text: " \n", appName: "Editor"), orca: "/orca", kiro: "/kiro", run: { try await recorder.run($0, directory: $1) })
            XCTFail("Expected empty selection failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No text is selected")) }
        let commands = await recorder.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testSpecFileAndWorkerArguments() async throws {
        let recorder = SelectionCommands(kiroAgent: true)
        let receipt = try await OrcaSelectionRunner.dispatch(selection: .init(text: "Fix the broken button", appName: "Editor"), orca: "/orca", kiro: "/kiro", run: { try await recorder.run($0, directory: $1) })
        XCTAssertEqual(receipt.terminalID, "dispatch-test")
        let commands = await recorder.commands
        let worker = try XCTUnwrap(commands.last)
        XCTAssertEqual(worker.executablePath, "/orca")
        XCTAssertTrue(worker.arguments.contains("worker-start"))
        XCTAssertTrue(worker.arguments.contains("--spec-file"))
        XCTAssertFalse(commands.contains { $0.executablePath == "/bin/sh" })
        let spec = await recorder.spec
        XCTAssertTrue(try XCTUnwrap(spec).contains("Fix the broken button"))
        XCTAssertTrue(try XCTUnwrap(spec).contains("Source app: Editor"))
        XCTAssertFalse(try XCTUnwrap(spec).contains("UNRELATED_CLIPBOARD_SENTINEL"))
        let fileIndex = try XCTUnwrap(worker.arguments.firstIndex(of: "--spec-file"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worker.arguments[fileIndex + 1]))
    }

    func testFallbackUsesArgumentArrayAndRecordsTerminal() async throws {
        let recorder = SelectionCommands()
        let text = "Fix $(touch /tmp/danger); `echo data`"
        let receipt = try await OrcaSelectionRunner.dispatch(selection: .init(text: text, appName: "Editor"), orca: "/orca", kiro: "/kiro", run: { try await recorder.run($0, directory: $1) })
        XCTAssertEqual(receipt.terminalID, "term-test")
        let commands = await recorder.commands
        let kiro = try XCTUnwrap(commands.last)
        XCTAssertEqual(kiro.executablePath, "/kiro")
        XCTAssertTrue(kiro.arguments.contains("--no-interactive"))
        XCTAssertTrue(kiro.arguments.contains("--trust-tools="))
        XCTAssertFalse(kiro.arguments.contains("--trust-all-tools"))
        XCTAssertEqual(kiro.arguments.count, 5)
        XCTAssertFalse(commands.contains { $0.executablePath == "/bin/sh" })
    }

    func testLoginFailureDoesNotLaunchChatOrClaimSuccess() async {
        let recorder = SelectionCommands(loggedIn: false)
        do {
            _ = try await OrcaSelectionRunner.dispatch(selection: .init(text: "Problem", appName: "Editor"), orca: "/orca", kiro: "/kiro", run: { try await recorder.run($0, directory: $1) })
            XCTFail("Expected login failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("kiro-cli login")) }
        let commands = await recorder.commands
        XCTAssertFalse(commands.contains { $0.arguments.first == "chat" })
    }

    func testSpecCapAndSensitiveDataRedaction() throws {
        let spec = try OrcaSelectionDispatch.spec(for: .init(text: "TOKEN=secret ghp_abc123 /Users/other/worktree/file " + String(repeating: "x", count: 9000), appName: "Editor"))
        XCTAssertLessThanOrEqual(spec.count, 8000)
        XCTAssertFalse(spec.contains("secret"))
        XCTAssertFalse(spec.contains("ghp_abc123"))
        XCTAssertFalse(spec.contains("/Users/other"))
    }
}
