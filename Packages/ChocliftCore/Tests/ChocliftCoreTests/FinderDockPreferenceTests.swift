#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import Foundation
import XCTest
@testable import ChocliftCore

final class FinderDockPreferenceTests: XCTestCase {
    func testNextValueTogglesBooleanAndTreatsNilAsTrue() {
        XCTAssertTrue(FinderDockPreferenceToggle.nextValue(current: nil))
        XCTAssertTrue(FinderDockPreferenceToggle.nextValue(current: false))
        XCTAssertFalse(FinderDockPreferenceToggle.nextValue(current: true))
    }

    func testParsePreferenceValueHandlesNilBooleansNumbersAndStrings() {
        XCTAssertNil(FinderDockPreferenceToggle.parsePreferenceValue(nil))
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(true), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(false), false)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(NSNumber(value: 1)), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(NSNumber(value: 0)), false)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("YES"), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(" true \n"), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("1"), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("on"), true)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("NO"), false)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue(" false "), false)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("0"), false)
        XCTAssertEqual(FinderDockPreferenceToggle.parsePreferenceValue("off"), false)
        XCTAssertNil(FinderDockPreferenceToggle.parsePreferenceValue(""))
        XCTAssertNil(FinderDockPreferenceToggle.parsePreferenceValue("unexpected"))
        XCTAssertNil(FinderDockPreferenceToggle.parsePreferenceValue(["not_a_bool"]))
    }

    func testFinderDockPackMetadataUniquenessAndWireRoundTrip() throws {
        let pack = CompanionActionCatalog.finderDockPack
        XCTAssertEqual(pack.count, 2)
        XCTAssertEqual(pack.map(\.id), ["finder.toggle_hidden_files", "dock.toggle_autohide"])

        let finderAction = try XCTUnwrap(CompanionActionCatalog.action(id: "finder.toggle_hidden_files"))
        XCTAssertEqual(finderAction.titleZh, "显示隐藏文件")
        XCTAssertEqual(finderAction.titleEn, "Toggle Hidden Files")
        XCTAssertEqual(finderAction.title(in: .chinese), "显示隐藏文件")
        XCTAssertEqual(finderAction.title(in: .english), "Toggle Hidden Files")
        XCTAssertEqual(finderAction.sfSymbol, "eye")

        let dockAction = try XCTUnwrap(CompanionActionCatalog.action(id: "dock.toggle_autohide"))
        XCTAssertEqual(dockAction.titleZh, "自动隐藏程序坞")
        XCTAssertEqual(dockAction.titleEn, "Toggle Dock Autohide")
        XCTAssertEqual(dockAction.title(in: .chinese), "自动隐藏程序坞")
        XCTAssertEqual(dockAction.title(in: .english), "Toggle Dock Autohide")
        XCTAssertEqual(dockAction.sfSymbol, "dock.rectangle")

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.filter { $0 == "finder.toggle_hidden_files" }.count, 1)
        XCTAssertEqual(allIDs.filter { $0 == "dock.toggle_autohide" }.count, 1)

        for action in pack {
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertTrue(CompanionHotkeyLibrary.isKnownActionID(action.id))
            XCTAssertNil(SystemQuickAction(rawValue: action.id))

            #if canImport(AppKit)
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
                "Missing SF Symbol on macOS: \(action.sfSymbol)"
            )
            #endif

            let wireMessage = ClientMessage.performCompanionAction(id: action.id)
            let encoded = try JSONEncoder().encode(wireMessage)
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
            XCTAssertEqual(decoded, wireMessage)
        }
    }

    func testExecuteTogglesFinderHiddenFilesAndReportsShownOrHiddenState() {
        var store: [String: Bool] = [:]
        var restarted: [String] = []

        // Unset (nil) -> shown (true)
        let shownEn = FinderDockCompanionAction.execute(
            id: "finder.toggle_hidden_files",
            language: .english,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(shownEn.success)
        XCTAssertEqual(store["com.apple.finder:AppleShowAllFiles"], true)
        XCTAssertEqual(restarted, ["Finder"])
        XCTAssertTrue(shownEn.message.localizedCaseInsensitiveContains("shown"))

        // Shown (true) -> hidden (false)
        let hiddenEn = FinderDockCompanionAction.execute(
            id: "finder.toggle_hidden_files",
            language: .english,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(hiddenEn.success)
        XCTAssertEqual(store["com.apple.finder:AppleShowAllFiles"], false)
        XCTAssertEqual(restarted, ["Finder", "Finder"])
        XCTAssertTrue(hiddenEn.message.localizedCaseInsensitiveContains("now hidden"))

        // Hidden (false) -> shown (true) in Chinese
        let shownZh = FinderDockCompanionAction.execute(
            id: "finder.toggle_hidden_files",
            language: .chinese,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(shownZh.success)
        XCTAssertEqual(store["com.apple.finder:AppleShowAllFiles"], true)
        XCTAssertTrue(shownZh.message.contains("已显示"))

        let hiddenZh = FinderDockCompanionAction.execute(
            id: "finder.toggle_hidden_files",
            language: .chinese,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(hiddenZh.success)
        XCTAssertEqual(store["com.apple.finder:AppleShowAllFiles"], false)
        XCTAssertTrue(hiddenZh.message.contains("已隐藏"))
    }

    func testExecuteTogglesDockAutohideOnlyAndRelaunchesDock() {
        var writtenPairs: [(domain: String, key: String, value: Bool)] = []
        var store: [String: Bool] = [:]
        var restarted: [String] = []

        let enabledEn = FinderDockCompanionAction.execute(
            id: "dock.toggle_autohide",
            language: .english,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                writtenPairs.append((domain, key, value))
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(enabledEn.success)
        XCTAssertEqual(writtenPairs.count, 1)
        XCTAssertEqual(writtenPairs.first?.domain, "com.apple.dock")
        XCTAssertEqual(writtenPairs.first?.key, "autohide")
        XCTAssertEqual(writtenPairs.first?.value, true)
        XCTAssertEqual(restarted, ["Dock"])
        XCTAssertTrue(enabledEn.message.localizedCaseInsensitiveContains("enabled"))

        let disabledZh = FinderDockCompanionAction.execute(
            id: "dock.toggle_autohide",
            language: .chinese,
            readPreference: { domain, key in store["\(domain):\(key)"] },
            writePreference: { domain, key, value in
                writtenPairs.append((domain, key, value))
                store["\(domain):\(key)"] = value
                return true
            },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertTrue(disabledZh.success)
        XCTAssertEqual(store["com.apple.dock:autohide"], false)
        XCTAssertEqual(restarted, ["Dock", "Dock"])
        XCTAssertTrue(disabledZh.message.contains("已关闭"))
    }

    func testWriteFailureAndUnknownActionIDsDoNotRestartProcesses() {
        var restarted: [String] = []

        let writeFailed = FinderDockCompanionAction.execute(
            id: "finder.toggle_hidden_files",
            language: .english,
            readPreference: { _, _ in false },
            writePreference: { _, _, _ in false },
            restartProcess: { restarted.append($0) }
        )
        XCTAssertFalse(writeFailed.success)
        XCTAssertTrue(restarted.isEmpty)

        for unknownID in ["", "finder.", "dock.", "finder.unknown", " finder.toggle_hidden_files ", "dock.hide_permanently"] {
            var didReadOrWrite = false
            let result = FinderDockCompanionAction.execute(
                id: unknownID,
                language: .english,
                readPreference: { _, _ in
                    didReadOrWrite = true
                    return nil
                },
                writePreference: { _, _, _ in
                    didReadOrWrite = true
                    return true
                },
                restartProcess: { restarted.append($0) }
            )
            XCTAssertFalse(result.success, "Expected failure for \(unknownID)")
            XCTAssertFalse(didReadOrWrite)
            XCTAssertTrue(restarted.isEmpty)
        }
    }

    #if os(macOS)
    func testIsolatedCFPreferencesRoundTripWithToggle() {
        let domain = "com.choclift.tests.finderdock.\(UUID().uuidString)" as CFString
        let key = "AppleShowAllFiles" as CFString
        defer {
            CFPreferencesSetAppValue(key, nil, domain)
            _ = CFPreferencesAppSynchronize(domain)
        }

        let initial = FinderDockPreferenceToggle.parsePreferenceValue(
            CFPreferencesCopyAppValue(key, domain)
        )
        XCTAssertNil(initial)

        let firstNext = FinderDockPreferenceToggle.nextValue(current: initial)
        XCTAssertTrue(firstNext)
        CFPreferencesSetAppValue(key, firstNext ? kCFBooleanTrue : kCFBooleanFalse, domain)
        XCTAssertTrue(CFPreferencesAppSynchronize(domain))

        let afterFirstWrite = FinderDockPreferenceToggle.parsePreferenceValue(
            CFPreferencesCopyAppValue(key, domain)
        )
        XCTAssertEqual(afterFirstWrite, true)

        let secondNext = FinderDockPreferenceToggle.nextValue(current: afterFirstWrite)
        XCTAssertFalse(secondNext)
        CFPreferencesSetAppValue(key, secondNext ? kCFBooleanTrue : kCFBooleanFalse, domain)
        XCTAssertTrue(CFPreferencesAppSynchronize(domain))

        let afterSecondWrite = FinderDockPreferenceToggle.parsePreferenceValue(
            CFPreferencesCopyAppValue(key, domain)
        )
        XCTAssertEqual(afterSecondWrite, false)
    }
    #endif
}
