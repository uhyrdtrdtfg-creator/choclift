import Foundation
import XCTest
@testable import ChocliftCore

#if canImport(AppKit)
import AppKit
#endif

final class SystemActionPackTests: XCTestCase {
    private static let expectedOrderedPairs: [(id: String, url: String)] = [
        ("system.open_settings", "x-apple.systempreferences:"),
        ("system.open_bluetooth_settings", "x-apple.systempreferences:com.apple.BluetoothSettings"),
        ("system.open_sound_settings", "x-apple.systempreferences:com.apple.preference.sound"),
        ("system.open_display_settings", "x-apple.systempreferences:com.apple.preference.displays"),
        ("system.open_network_settings", "x-apple.systempreferences:com.apple.preference.network"),
        ("system.open_notifications_settings", "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
        ("system.open_focus_settings", "x-apple.systempreferences:com.apple.Focus-Settings.extension"),
        ("system.open_keyboard_settings", "x-apple.systempreferences:com.apple.preference.keyboard"),
        ("system.open_trackpad_settings", "x-apple.systempreferences:com.apple.preference.trackpad"),
        ("system.open_battery_settings", "x-apple.systempreferences:com.apple.preference.battery")
    ]

    func testSystemPackHasExactlyTenUniqueExpectedSystemIDs() {
        let pack = CompanionActionCatalog.systemPack
        let expectedIDs = Self.expectedOrderedPairs.map(\.id)
        let actualIDs = pack.map(\.id)

        XCTAssertEqual(pack.count, 10)
        XCTAssertEqual(Set(actualIDs).count, 10)
        XCTAssertEqual(actualIDs, expectedIDs)
        XCTAssertTrue(actualIDs.allSatisfy { $0.hasPrefix("system.") })

        for action in pack {
            XCTAssertEqual(CompanionActionCatalog.action(id: action.id), action)
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
            XCTAssertFalse(action.sfSymbol.isEmpty)
            #if canImport(AppKit)
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
                "Missing SF Symbol on macOS: \(action.sfSymbol)"
            )
            #endif
        }
    }

    func testPureURLTableMapsEverySystemIDToExpectedConstantURL() throws {
        let expectedTable = Dictionary(uniqueKeysWithValues: Self.expectedOrderedPairs)

        XCTAssertEqual(SystemSettingsAction.urlTable, expectedTable)
        XCTAssertEqual(CompanionActionCatalog.systemSettingsURLByID, expectedTable)

        for (id, expectedURLString) in Self.expectedOrderedPairs {
            XCTAssertEqual(SystemSettingsAction.urlString(for: id), expectedURLString)
            XCTAssertEqual(CompanionActionCatalog.systemSettingsURLString(for: id), expectedURLString)

            let parsedURL = try XCTUnwrap(SystemSettingsAction.destinationURL(for: id))
            XCTAssertEqual(parsedURL.absoluteString, expectedURLString)
            XCTAssertEqual(parsedURL.scheme, "x-apple.systempreferences")
        }
    }

    func testUnknownIDsFailAndNeverInvokeOpenURL() {
        let unknownIDs = [
            "",
            "system.",
            "system.unknown",
            "system.open_wifi_settings",
            "system.invalid_pane",
            "window.snap_left",
            " system.open_settings ",
            "x-apple.systempreferences:"
        ]

        for unknownID in unknownIDs {
            XCTAssertNil(SystemSettingsAction.urlString(for: unknownID))
            XCTAssertNil(SystemSettingsAction.destinationURL(for: unknownID))
            XCTAssertNil(CompanionActionCatalog.systemSettingsURLString(for: unknownID))

            var openedURLs: [URL] = []
            let outcomeEn = SystemSettingsAction.execute(id: unknownID, language: .english) { url in
                openedURLs.append(url)
                return true
            }
            XCTAssertFalse(outcomeEn.success)
            XCTAssertFalse(outcomeEn.message.isEmpty)
            XCTAssertTrue(openedURLs.isEmpty)

            let outcomeZh = SystemSettingsAction.execute(id: unknownID, language: .chinese) { url in
                openedURLs.append(url)
                return true
            }
            XCTAssertFalse(outcomeZh.success)
            XCTAssertFalse(outcomeZh.message.isEmpty)
            XCTAssertTrue(openedURLs.isEmpty)
        }
    }

    func testExecuteReportsSuccessOnlyWhenWorkspaceOpenReturnsTrue() {
        for (id, expectedURLString) in Self.expectedOrderedPairs {
            var openedWhenTrue: [URL] = []
            let okEn = SystemSettingsAction.execute(id: id, language: .english) { url in
                openedWhenTrue.append(url)
                return true
            }
            XCTAssertTrue(okEn.success)
            XCTAssertEqual(openedWhenTrue.map(\.absoluteString), [expectedURLString])
            XCTAssertTrue(okEn.message.hasPrefix("Opened "))

            let okZh = SystemSettingsAction.execute(id: id, language: .chinese) { _ in true }
            XCTAssertTrue(okZh.success)
            XCTAssertTrue(okZh.message.hasPrefix("已打开"))

            var openedWhenFalse: [URL] = []
            let failedEn = SystemSettingsAction.execute(id: id, language: .english) { url in
                openedWhenFalse.append(url)
                return false
            }
            XCTAssertFalse(failedEn.success)
            XCTAssertEqual(openedWhenFalse.map(\.absoluteString), [expectedURLString])
            XCTAssertTrue(failedEn.message.hasPrefix("Could not open "))
            XCTAssertFalse(failedEn.message.localizedCaseInsensitiveContains("opened"))

            let failedZh = SystemSettingsAction.execute(id: id, language: .chinese) { _ in false }
            XCTAssertFalse(failedZh.success)
            XCTAssertTrue(failedZh.message.hasPrefix("无法打开"))
            XCTAssertFalse(failedZh.message.contains("已打开"))
        }
    }
}
