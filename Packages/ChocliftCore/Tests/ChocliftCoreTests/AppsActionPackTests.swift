import Foundation
import XCTest
@testable import ChocliftCore

#if canImport(AppKit)
import AppKit
#endif

final class AppsActionPackTests: XCTestCase {
    func testAppsPackContainsUniqueOpenLaunchpadActionWithLocalizedTitlesAndSymbol() throws {
        let pack = CompanionActionCatalog.appsPack
        let packIDs = pack.map(\.id)
        XCTAssertEqual(packIDs, ["apps.open_launchpad"])
        XCTAssertEqual(Set(packIDs).count, pack.count)

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.filter { $0 == "apps.open_launchpad" }.count, 1)
        XCTAssertTrue(CompanionActionCatalog.isKnown("apps.open_launchpad"))

        let action = try XCTUnwrap(CompanionActionCatalog.action(id: "apps.open_launchpad"))
        XCTAssertEqual(action.id, "apps.open_launchpad")
        XCTAssertFalse(action.title(in: .chinese).isEmpty)
        XCTAssertFalse(action.title(in: .english).isEmpty)
        XCTAssertEqual(action.title(in: .chinese), "打开启动台")
        XCTAssertEqual(action.title(in: .english), "Open Launchpad")
        XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
        XCTAssertEqual(action.sfSymbol, "square.grid.3x3.fill")
        XCTAssertNil(SystemQuickAction(rawValue: "apps.open_launchpad"))

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "Missing SF Symbol on macOS: \(action.sfSymbol)"
        )
        #endif
    }

    func testOpenLaunchpadIsAvailableAsUserHotkeyAndOneTapWireAction() throws {
        XCTAssertTrue(CompanionHotkeyLibrary.isKnownActionID("apps.open_launchpad"))
        XCTAssertEqual(CompanionHotkeyLibrary.actionTitle(for: "apps.open_launchpad", in: .chinese), "打开启动台")
        XCTAssertEqual(CompanionHotkeyLibrary.actionTitle(for: "apps.open_launchpad", in: .english), "Open Launchpad")
        XCTAssertEqual(CompanionHotkeyLibrary.actionSymbol(for: "apps.open_launchpad"), "square.grid.3x3.fill")
        XCTAssertTrue(
            CompanionHotkeyLibrary.allActionOptions.contains(
                CompanionHotkeyActionOption(
                    id: "apps.open_launchpad",
                    sfSymbol: "square.grid.3x3.fill",
                    isSystemQuickAction: false
                )
            )
        )

        let hotkey = CompanionHotkey(
            keyCode: 0x25, // L
            carbonModifiers: CompanionHotkeyModifiers.command | CompanionHotkeyModifiers.option,
            actionID: "apps.open_launchpad",
            title: ""
        )
        let sanitized = CompanionHotkeyLibrary.sanitize([hotkey])
        XCTAssertEqual(sanitized, [hotkey])
        XCTAssertEqual(sanitized.first?.resolvedTitle(in: .english), "Open Launchpad")
        XCTAssertEqual(sanitized.first?.resolvedTitle(in: .chinese), "打开启动台")

        var gate = DestructiveActionConfirmGate()
        XCTAssertEqual(
            gate.registerTap(targetID: "apps.open_launchpad", isDestructive: false, at: 42.0),
            .runImmediately
        )

        let wireMessage = ClientMessage.performCompanionAction(id: "apps.open_launchpad")
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testLaunchpadResolutionPrefersLaunchpadBundleFallsBackToAppsBundleAndFailsWhenMissing() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let launchpadBundle = tempRoot.appendingPathComponent("Launchpad.app", isDirectory: true)
        let appsBundle = tempRoot.appendingPathComponent("Apps.app", isDirectory: true)
        let regularFile = tempRoot.appendingPathComponent("NotABundle.app", isDirectory: false)
        try Data("x".utf8).write(to: regularFile)

        // 1. Neither directory exists -> fails cleanly without synthetic keystroke fallback.
        XCTAssertEqual(
            AppsActionResolver.resolveLaunchpadApplicationURL(
                candidatePaths: [regularFile.path, launchpadBundle.path, appsBundle.path],
                fileManager: fm
            ),
            .failure(.launchpadNotFound)
        )

        // 2. macOS 26+ layout where only Apps.app exists -> resolves Apps.app.
        try fm.createDirectory(at: appsBundle, withIntermediateDirectories: true)
        XCTAssertEqual(
            AppsActionResolver.resolveLaunchpadApplicationURL(
                candidatePaths: [launchpadBundle.path, appsBundle.path],
                fileManager: fm
            ),
            .success(appsBundle.standardizedFileURL)
        )

        // 3. macOS 13–15 layout where Launchpad.app exists -> prefers Launchpad.app.
        try fm.createDirectory(at: launchpadBundle, withIntermediateDirectories: true)
        XCTAssertEqual(
            AppsActionResolver.resolveLaunchpadApplicationURL(
                candidatePaths: [launchpadBundle.path, appsBundle.path],
                fileManager: fm
            ),
            .success(launchpadBundle.standardizedFileURL)
        )
    }

    func testExecuteOpensResolvedBundleOnceAndRejectsUnknownOrMissingTargets() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let launchpadBundle = tempRoot.appendingPathComponent("Launchpad.app", isDirectory: true)
        try fm.createDirectory(at: launchpadBundle, withIntermediateDirectories: true)

        // Unknown IDs never invoke openApplication.
        for unknownID in ["", "apps.", "apps.unknown", " apps.open_launchpad ", "toggle_launchpad"] {
            var opened: [URL] = []
            let outcome = AppsActionResolver.execute(
                id: unknownID,
                language: .english,
                candidatePaths: [launchpadBundle.path],
                fileManager: fm
            ) { url in
                opened.append(url)
                return true
            }
            XCTAssertFalse(outcome.success)
            XCTAssertFalse(outcome.message.isEmpty)
            XCTAssertTrue(opened.isEmpty)
        }

        // Valid open_launchpad opens the resolved bundle once in both English and Chinese.
        var openedURLs: [URL] = []
        let okEn = AppsActionResolver.execute(
            id: "apps.open_launchpad",
            language: .english,
            candidatePaths: [launchpadBundle.path],
            fileManager: fm
        ) { url in
            openedURLs.append(url)
            return true
        }
        XCTAssertTrue(okEn.success)
        XCTAssertEqual(okEn.message, "Opened Launchpad")
        XCTAssertEqual(openedURLs, [launchpadBundle.standardizedFileURL])

        let okZh = AppsActionResolver.execute(
            id: "apps.open_launchpad",
            language: .chinese,
            candidatePaths: [launchpadBundle.path],
            fileManager: fm
        ) { _ in true }
        XCTAssertTrue(okZh.success)
        XCTAssertEqual(okZh.message, "已打开启动台")

        // Open failure reports failure message rather than pretending Launchpad opened.
        let failedEn = AppsActionResolver.execute(
            id: "apps.open_launchpad",
            language: .english,
            candidatePaths: [launchpadBundle.path],
            fileManager: fm
        ) { _ in false }
        XCTAssertFalse(failedEn.success)
        XCTAssertEqual(failedEn.message, "Could not open Launchpad")

        let failedZh = AppsActionResolver.execute(
            id: "apps.open_launchpad",
            language: .chinese,
            candidatePaths: [launchpadBundle.path],
            fileManager: fm
        ) { _ in false }
        XCTAssertFalse(failedZh.success)
        XCTAssertEqual(failedZh.message, "无法打开启动台")
    }
}
