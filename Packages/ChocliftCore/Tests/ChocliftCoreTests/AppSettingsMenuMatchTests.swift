#if canImport(AppKit)
import AppKit
#endif
import Foundation
import XCTest
@testable import ChocliftCore

final class AppSettingsMenuMatchTests: XCTestCase {
    func testAppSettingsCatalogEntryTitlesSymbolAndWireRoundTrip() throws {
        let pack = CompanionActionCatalog.appSettingsPack
        XCTAssertEqual(pack.map(\.id), ["apps.open_settings"])

        let action = try XCTUnwrap(CompanionActionCatalog.action(id: "apps.open_settings"))
        XCTAssertEqual(action.id, AppSettingsCompanionActionID.openSettings)
        XCTAssertEqual(action.titleZh, "打开当前应用设置")
        XCTAssertEqual(action.titleEn, "Open App Settings")
        XCTAssertEqual(action.title(in: .chinese), "打开当前应用设置")
        XCTAssertEqual(action.title(in: .english), "Open App Settings")
        XCTAssertEqual(action.sfSymbol, "gear")
        XCTAssertTrue(CompanionActionCatalog.isKnown("apps.open_settings"))
        XCTAssertTrue(CompanionHotkeyLibrary.isKnownActionID("apps.open_settings"))
        XCTAssertNil(SystemQuickAction(rawValue: "apps.open_settings"))

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.filter { $0 == "apps.open_settings" }.count, 1)
        XCTAssertEqual(allIDs.last, "apps.open_settings")

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "Missing SF Symbol on macOS: \(action.sfSymbol)"
        )
        #endif

        let wireMessage = ClientMessage.performCompanionAction(id: "apps.open_settings")
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testMenuMatcherPicksFirstEnabledSettingsItemAcrossEnglishAndChineseKeywords() {
        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Safari", item: "About Safari", enabled: true),
                (menu: "Safari", item: "Settings…", enabled: true),
                (menu: "Safari", item: "Settings for example.com…", enabled: true),
                (menu: "Safari", item: "Quit Safari", enabled: true)
            ]),
            "Settings…"
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "LegacyApp", item: "About LegacyApp", enabled: true),
                (menu: "LegacyApp", item: "Preferences...", enabled: true)
            ]),
            "Preferences..."
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "访达", item: "关于访达", enabled: true),
                (menu: "访达", item: "设置…", enabled: true),
                (menu: "访达", item: "退出访达", enabled: true)
            ]),
            "设置…"
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "终端", item: "关于终端", enabled: true),
                (menu: "终端", item: "偏好设置…", enabled: true)
            ]),
            "偏好设置…"
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Code", item: "About Visual Studio Code", enabled: true),
                (menu: "Preferences", item: "Profiles", enabled: true),
                (menu: "Preferences", item: "Settings", enabled: true)
            ]),
            "Settings"
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "设置", item: "打开应用设置", enabled: true)
            ]),
            "打开应用设置"
        )
    }

    func testMenuMatcherIgnoresDisabledItemsAndReturnsNilWhenAllDisabledOrMissing() {
        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Safari", item: "About Safari", enabled: true),
                (menu: "Safari", item: "Settings…", enabled: false),
                (menu: "Safari", item: "Preferences…", enabled: true)
            ]),
            "Preferences…"
        )

        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "访达", item: "设置…", enabled: false),
                (menu: "偏好设置", item: "偏好设置…", enabled: true)
            ]),
            "偏好设置…"
        )

        XCTAssertNil(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Safari", item: "About Safari", enabled: true),
                (menu: "Safari", item: "Settings…", enabled: false),
                (menu: "Safari", item: "Preferences…", enabled: false)
            ])
        )

        XCTAssertNil(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Stickies", item: "About Stickies", enabled: true),
                (menu: "Stickies", item: "Hide Stickies", enabled: true),
                (menu: "Stickies", item: "Quit Stickies", enabled: true)
            ])
        )

        XCTAssertNil(AppSettingsMenuMatch.item(menuTitles: []))
    }

    func testMenuMatcherSkipsAppleSystemSettingsLifecycleItemsAndNonAppMenus() {
        // Apple menu's System Settings must never be pressed as the frontmost app's settings.
        XCTAssertEqual(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Apple", item: "About This Mac", enabled: true),
                (menu: "Apple", item: "System Settings…", enabled: true),
                (menu: "Safari", item: "About Safari", enabled: true),
                (menu: "Safari", item: "Settings…", enabled: true)
            ]),
            "Settings…"
        )

        XCTAssertNil(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "Apple", item: "System Settings…", enabled: true),
                (menu: "", item: "系统设置…", enabled: true),
                (menu: "Safari", item: "Settings…", enabled: false),
                (menu: "File", item: "Project Settings…", enabled: true),
                (menu: "View", item: "View Settings…", enabled: true)
            ])
        )

        // About / Hide / Quit items in an app whose own name contains "Settings" must never match.
        XCTAssertNil(
            AppSettingsMenuMatch.item(menuTitles: [
                (menu: "System Settings", item: "About System Settings", enabled: true),
                (menu: "System Settings", item: "Hide System Settings", enabled: true),
                (menu: "System Settings", item: "Quit System Settings", enabled: true),
                (menu: "系统设置", item: "关于系统设置", enabled: true),
                (menu: "系统设置", item: "退出系统设置", enabled: true)
            ])
        )
    }

    func testRoutingNeverOpensChocliftOwnSettingsAndHandlesPreferredAppAndFailures() {
        let selfPID: Int32 = 400
        let choclift = AppSettingsTargetCandidate(
            pid: selfPID,
            bundleIdentifier: "com.choclift.mac",
            localizedName: "Choclift"
        )
        let chocliftHelper = AppSettingsTargetCandidate(
            pid: 401,
            bundleIdentifier: "com.choclift.companion",
            localizedName: "Choclift Helper"
        )
        let safari = AppSettingsTargetCandidate(
            pid: 501,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )
        let notes = AppSettingsTargetCandidate(
            pid: 502,
            bundleIdentifier: "com.apple.Notes",
            localizedName: "Notes"
        )

        // Never resolves Choclift itself, even if passed as both frontmost and preferred.
        var didAttemptPress = false
        let refusedSelf = AppSettingsActionRouting.execute(
            id: "apps.open_settings",
            frontmost: choclift,
            preferred: chocliftHelper,
            selfPID: selfPID,
            language: .english,
            ensureAccessibility: { true },
            activateAndPressSettings: { _ in
                didAttemptPress = true
                return .pressed(itemTitle: "Settings…")
            }
        )
        XCTAssertFalse(refusedSelf.success)
        XCTAssertFalse(didAttemptPress)

        // Falls back to preferredPID when Choclift is frontmost.
        var pressedPIDs: [Int32] = []
        let okPreferred = AppSettingsActionRouting.execute(
            id: "apps.open_settings",
            frontmost: choclift,
            preferred: notes,
            selfPID: selfPID,
            language: .english,
            ensureAccessibility: { true },
            activateAndPressSettings: { target in
                pressedPIDs.append(target.pid)
                return .pressed(itemTitle: "Settings…")
            }
        )
        XCTAssertTrue(okPreferred.success)
        XCTAssertEqual(pressedPIDs, [502])
        XCTAssertEqual(okPreferred.message, "Opened Notes settings")

        // Prefers frontmost external app when one is already active.
        let okFrontmostZh = AppSettingsActionRouting.execute(
            id: "apps.open_settings",
            frontmost: safari,
            preferred: notes,
            selfPID: selfPID,
            language: .chinese,
            ensureAccessibility: { true },
            activateAndPressSettings: { target in
                pressedPIDs.append(target.pid)
                return .pressed(itemTitle: "设置…")
            }
        )
        XCTAssertTrue(okFrontmostZh.success)
        XCTAssertEqual(pressedPIDs, [502, 501])
        XCTAssertEqual(okFrontmostZh.message, "已打开 Safari 设置")

        // Missing or disabled menu item returns failure without keystroke fallback.
        let disabledFailure = AppSettingsActionRouting.execute(
            id: "apps.open_settings",
            frontmost: safari,
            preferred: nil,
            selfPID: selfPID,
            language: .english,
            ensureAccessibility: { true },
            activateAndPressSettings: { _ in .missingOrDisabled }
        )
        XCTAssertFalse(disabledFailure.success)
        XCTAssertTrue(disabledFailure.message.localizedCaseInsensitiveContains("Safari"))
    }
}
