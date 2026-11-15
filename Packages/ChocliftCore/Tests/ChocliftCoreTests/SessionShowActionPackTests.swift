#if canImport(AppKit)
import AppKit
#endif
import Foundation
import XCTest
@testable import ChocliftCore

final class SessionShowActionPackTests: XCTestCase {
    func testSessionShowPackIDTitlesSymbolAndCatalogUniqueness() throws {
        let pack = CompanionActionCatalog.sessionShowPack
        XCTAssertEqual(pack.count, 1)

        let action = try XCTUnwrap(pack.first)
        XCTAssertEqual(action.id, "session.show_all_apps")
        XCTAssertEqual(action.id, SessionShowCompanionAction.showAllApps.rawValue)
        XCTAssertEqual(action.titleZh, "显示全部应用")
        XCTAssertEqual(action.titleEn, "Show All Apps")
        XCTAssertEqual(action.title(in: .chinese), "显示全部应用")
        XCTAssertEqual(action.title(in: .english), "Show All Apps")
        XCTAssertEqual(action.sfSymbol, "eye")

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "Missing SF Symbol on macOS: \(action.sfSymbol)"
        )
        #endif

        let packIDs = pack.map(\.id)
        XCTAssertEqual(Set(packIDs).count, packIDs.count)

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.filter { $0 == "session.show_all_apps" }.count, 1)
        XCTAssertTrue(CompanionActionCatalog.isKnown("session.show_all_apps"))
        XCTAssertEqual(CompanionActionCatalog.action(id: "session.show_all_apps"), action)
        XCTAssertTrue(CompanionHotkeyLibrary.isKnownActionID("session.show_all_apps"))

        let quickActionIDs = Set(SystemQuickAction.allCases.map(\.rawValue))
        XCTAssertFalse(quickActionIDs.contains("session.show_all_apps"))

        let wireMessage = ClientMessage.performCompanionAction(id: action.id)
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testExecuteUnhidesOnlyEligibleHiddenRegularAppsSkippingChocliftAndReportsCount() {
        let selfPID: Int32 = 900
        let candidates: [SessionShowAppCandidate] = [
            SessionShowAppCandidate(
                pid: selfPID,
                bundleIdentifier: "com.choclift.mac",
                localizedName: "Choclift",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 901,
                bundleIdentifier: "com.choclift.mac",
                localizedName: "Choclift Other PID",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 902,
                bundleIdentifier: "com.choclift.companion",
                localizedName: "Choclift Companion",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 903,
                bundleIdentifier: "com.apple.Safari",
                localizedName: "Safari",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: false
            ),
            SessionShowAppCandidate(
                pid: 904,
                bundleIdentifier: "com.apple.Notes",
                localizedName: "Notes",
                isRegularActivationPolicy: true,
                isTerminated: true,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 905,
                bundleIdentifier: "com.apple.controlcenter",
                localizedName: "Control Center",
                isRegularActivationPolicy: false,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 906,
                bundleIdentifier: "com.apple.Mail",
                localizedName: "Mail",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 907,
                bundleIdentifier: "com.apple.Terminal",
                localizedName: "Terminal",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            )
        ]

        var unhiddenPIDs: [Int32] = []
        let outcomeEn = SessionShowCompanionAction.execute(
            id: "session.show_all_apps",
            candidates: candidates,
            selfPID: selfPID,
            language: .english,
            unhide: { candidate in
                unhiddenPIDs.append(candidate.pid)
                return true
            }
        )

        XCTAssertTrue(outcomeEn.success)
        XCTAssertEqual(outcomeEn.unhiddenCount, 2)
        XCTAssertEqual(unhiddenPIDs, [906, 907])
        XCTAssertTrue(outcomeEn.message.contains("2"))

        let outcomeZh = SessionShowCompanionAction.execute(
            id: "session.show_all_apps",
            candidates: [candidates[6]],
            selfPID: selfPID,
            language: .chinese,
            unhide: { _ in true }
        )
        XCTAssertTrue(outcomeZh.success)
        XCTAssertEqual(outcomeZh.unhiddenCount, 1)
        XCTAssertTrue(outcomeZh.message.contains("1"))
    }

    func testExecuteReturnsSuccessWhenZeroAppsAreHidden() {
        let candidates: [SessionShowAppCandidate] = [
            SessionShowAppCandidate(
                pid: 500,
                bundleIdentifier: "com.choclift.mac",
                localizedName: "Choclift",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: true
            ),
            SessionShowAppCandidate(
                pid: 501,
                bundleIdentifier: "com.apple.Safari",
                localizedName: "Safari",
                isRegularActivationPolicy: true,
                isTerminated: false,
                isHidden: false
            )
        ]

        var didCallUnhide = false
        let outcomeEn = SessionShowCompanionAction.execute(
            id: "session.show_all_apps",
            candidates: candidates,
            selfPID: 500,
            language: .english,
            unhide: { _ in
                didCallUnhide = true
                return true
            }
        )

        XCTAssertTrue(outcomeEn.success)
        XCTAssertEqual(outcomeEn.unhiddenCount, 0)
        XCTAssertFalse(didCallUnhide)
        XCTAssertTrue(outcomeEn.message.localizedCaseInsensitiveContains("hidden"))

        let outcomeZh = SessionShowCompanionAction.execute(
            id: "session.show_all_apps",
            candidates: [],
            selfPID: 500,
            language: .chinese,
            unhide: { _ in
                didCallUnhide = true
                return true
            }
        )
        XCTAssertTrue(outcomeZh.success)
        XCTAssertEqual(outcomeZh.unhiddenCount, 0)
        XCTAssertFalse(didCallUnhide)
        XCTAssertTrue(outcomeZh.message.contains("隐藏"))
    }

    func testExecuteRejectsUnknownAndOtherSessionActionIDsWithoutUnhiding() {
        let hiddenSafari = SessionShowAppCandidate(
            pid: 601,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari",
            isRegularActivationPolicy: true,
            isTerminated: false,
            isHidden: true
        )

        for unknownID in ["", "session.", "session.hide_frontmost_app", " session.show_all_apps "] {
            var didCallUnhide = false
            let outcome = SessionShowCompanionAction.execute(
                id: unknownID,
                candidates: [hiddenSafari],
                selfPID: 500,
                language: .english,
                unhide: { _ in
                    didCallUnhide = true
                    return true
                }
            )
            XCTAssertFalse(outcome.success, "Expected failure for \(unknownID)")
            XCTAssertEqual(outcome.unhiddenCount, 0)
            XCTAssertFalse(didCallUnhide)
        }
    }
}
