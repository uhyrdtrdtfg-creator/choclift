import Foundation
import XCTest
@testable import ChocliftCore

#if canImport(AppKit)
import AppKit
#endif

final class SessionActionPackTests: XCTestCase {
    func testHideFrontmostAppCatalogEntryAndSingleMembership() throws {
        let expectedID = "session.hide_frontmost_app"
        XCTAssertEqual(SessionCompanionActionID.hideFrontmostApp, expectedID)

        let pack = CompanionActionCatalog.sessionPack
        XCTAssertEqual(pack.map(\.id), [expectedID])

        let action = try XCTUnwrap(CompanionActionCatalog.action(id: expectedID))
        XCTAssertEqual(action.id, expectedID)
        XCTAssertEqual(action.titleZh, "隐藏当前应用")
        XCTAssertEqual(action.titleEn, "Hide Frontmost App")
        XCTAssertEqual(action.title(in: .chinese), "隐藏当前应用")
        XCTAssertEqual(action.title(in: .english), "Hide Frontmost App")
        XCTAssertEqual(action.sfSymbol, "eye.slash")

        let catalogMatches = CompanionActionCatalog.all.filter { $0.id == expectedID }
        XCTAssertEqual(catalogMatches.count, 1)
        XCTAssertEqual(catalogMatches.first, action)
        XCTAssertTrue(CompanionActionCatalog.isKnown(expectedID))
        XCTAssertEqual(Set(CompanionActionCatalog.all.map(\.id)).count, CompanionActionCatalog.all.count)
        XCTAssertNil(SystemQuickAction(rawValue: expectedID))

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "Missing SF Symbol on macOS: \(action.sfSymbol)"
        )
        #endif

        let wireMessage = ClientMessage.performCompanionAction(id: expectedID)
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testResolveHideTargetRefusesChocliftAndFallsBackToPreferredExternalApp() {
        let selfPID: Int32 = 100
        let chocliftMac = SessionAppTarget(
            pid: 100,
            bundleIdentifier: "com.choclift.mac",
            localizedName: "Choclift"
        )
        let chocliftVariant = SessionAppTarget(
            pid: 101,
            bundleIdentifier: "com.choclift.companion",
            localizedName: "Choclift Companion"
        )
        let customHost = SessionAppTarget(
            pid: 102,
            bundleIdentifier: "com.example.customhost",
            localizedName: "Custom Host"
        )
        let safari = SessionAppTarget(
            pid: 201,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )
        let notes = SessionAppTarget(
            pid: 202,
            bundleIdentifier: "com.apple.Notes",
            localizedName: "Notes"
        )
        let terminatedNotes = SessionAppTarget(
            pid: 202,
            bundleIdentifier: "com.apple.Notes",
            localizedName: "Notes",
            isTerminated: true
        )
        let backgroundAgent = SessionAppTarget(
            pid: 203,
            bundleIdentifier: "com.apple.Spotlight",
            localizedName: "Spotlight",
            isRegular: false
        )
        let loginWindow = SessionAppTarget(
            pid: 204,
            bundleIdentifier: "com.apple.loginwindow",
            localizedName: "loginwindow"
        )

        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(chocliftMac, selfPID: 999))
        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(chocliftVariant, selfPID: 999))
        XCTAssertFalse(
            SessionCompanionActionRouting.isEligibleExternalApp(
                customHost,
                selfPID: 999,
                hostBundleIdentifier: "com.example.customhost"
            )
        )
        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(safari, selfPID: 201))
        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(terminatedNotes, selfPID: selfPID))
        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(backgroundAgent, selfPID: selfPID))
        XCTAssertFalse(SessionCompanionActionRouting.isEligibleExternalApp(loginWindow, selfPID: selfPID))
        XCTAssertTrue(SessionCompanionActionRouting.isEligibleExternalApp(safari, selfPID: selfPID))

        // Frontmost external regular app wins over preferredPID.
        XCTAssertEqual(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: safari,
                preferred: notes,
                selfPID: selfPID
            ),
            safari
        )

        // When Choclift (or host bundle) is frontmost, preferred external regular app is used.
        XCTAssertEqual(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: chocliftMac,
                preferred: notes,
                selfPID: selfPID
            ),
            notes
        )
        XCTAssertEqual(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: customHost,
                preferred: notes,
                selfPID: selfPID,
                hostBundleIdentifier: "com.example.customhost"
            ),
            notes
        )

        // Refuses when preferred is nil, terminated, non-regular, or Choclift itself.
        XCTAssertNil(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: chocliftMac,
                preferred: nil,
                selfPID: selfPID
            )
        )
        XCTAssertNil(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: chocliftMac,
                preferred: terminatedNotes,
                selfPID: selfPID
            )
        )
        XCTAssertNil(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: chocliftMac,
                preferred: backgroundAgent,
                selfPID: selfPID
            )
        )
        XCTAssertNil(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: chocliftMac,
                preferred: chocliftVariant,
                selfPID: selfPID
            )
        )
        XCTAssertNil(
            SessionCompanionActionRouting.resolveHideTarget(
                frontmost: loginWindow,
                preferred: notes,
                selfPID: selfPID
            )
        )
    }

    func testExecuteHidesSingleResolvedAppAndReportsClearFailures() {
        let selfPID: Int32 = 100
        let choclift = SessionAppTarget(pid: 100, bundleIdentifier: "com.choclift.mac", localizedName: "Choclift")
        let safari = SessionAppTarget(pid: 301, bundleIdentifier: "com.apple.Safari", localizedName: "Safari")

        var hiddenPIDs: [Int32] = []
        let okEn = SessionCompanionActionRouting.execute(
            id: "session.hide_frontmost_app",
            frontmost: choclift,
            preferred: safari,
            selfPID: selfPID,
            language: .english
        ) { target in
            hiddenPIDs.append(target.pid)
            return true
        }
        XCTAssertTrue(okEn.success)
        XCTAssertEqual(hiddenPIDs, [301])
        XCTAssertEqual(okEn.message, "Hid Safari")

        let okZh = SessionCompanionActionRouting.execute(
            id: "session.hide_frontmost_app",
            frontmost: safari,
            preferred: nil,
            selfPID: selfPID,
            language: .chinese
        ) { target in
            hiddenPIDs.append(target.pid)
            return true
        }
        XCTAssertTrue(okZh.success)
        XCTAssertEqual(hiddenPIDs, [301, 301])
        XCTAssertEqual(okZh.message, "已隐藏 Safari")

        var invokedOnMissing = false
        let missingTarget = SessionCompanionActionRouting.execute(
            id: "session.hide_frontmost_app",
            frontmost: choclift,
            preferred: nil,
            selfPID: selfPID,
            language: .english
        ) { _ in
            invokedOnMissing = true
            return true
        }
        XCTAssertFalse(missingTarget.success)
        XCTAssertFalse(missingTarget.message.isEmpty)
        XCTAssertFalse(invokedOnMissing)

        let rejectedHide = SessionCompanionActionRouting.execute(
            id: "session.hide_frontmost_app",
            frontmost: safari,
            preferred: nil,
            selfPID: selfPID,
            language: .english
        ) { _ in
            false
        }
        XCTAssertFalse(rejectedHide.success)
        XCTAssertEqual(rejectedHide.message, "Could not hide Safari")

        var invokedOnUnknown = false
        let unknownID = SessionCompanionActionRouting.execute(
            id: "session.unknown",
            frontmost: safari,
            preferred: nil,
            selfPID: selfPID,
            language: .english
        ) { _ in
            invokedOnUnknown = true
            return true
        }
        XCTAssertFalse(unknownID.success)
        XCTAssertFalse(unknownID.message.isEmpty)
        XCTAssertFalse(invokedOnUnknown)
    }
}
