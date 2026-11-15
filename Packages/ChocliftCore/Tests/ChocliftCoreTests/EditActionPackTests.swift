import Foundation
import XCTest
@testable import ChocliftCore
#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
#endif

final class EditActionPackTests: XCTestCase {
    private let expectedActionIDs: [String] = [
        "edit.select_all",
        "edit.find",
        "edit.save",
        "edit.bold",
        "edit.italic",
        "edit.underline",
        "edit.paste_match_style",
        "edit.emoji",
        "edit.page_up",
        "edit.page_down"
    ]

    func testEditPackHasExactlyTenUniqueEditActionIDs() throws {
        let pack = CompanionActionCatalog.editPack
        let ids = pack.map(\.id)

        XCTAssertEqual(pack.count, 10)
        XCTAssertEqual(ids, expectedActionIDs)
        XCTAssertEqual(Set(ids).count, 10)

        for action in pack {
            XCTAssertTrue(action.id.hasPrefix("edit."))
            XCTAssertFalse(action.titleZh.isEmpty)
            XCTAssertFalse(action.titleEn.isEmpty)
            XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertEqual(CompanionActionCatalog.action(id: action.id), action)

            let wireMessage = ClientMessage.performCompanionAction(id: action.id)
            let encoded = try JSONEncoder().encode(wireMessage)
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
            XCTAssertEqual(decoded, wireMessage)
        }

        XCTAssertFalse(CompanionActionCatalog.isKnown("edit.a"))
        XCTAssertFalse(CompanionActionCatalog.isKnown("edit.quit"))
    }

    #if os(macOS)
    func testPureKeystrokeTableMapsEachEditActionToExpectedVirtualKeyAndFlags() throws {
        let table = EditCompanionActionRouting.keystrokeTable
        XCTAssertEqual(table.count, 10)
        XCTAssertEqual(Set(table.keys), Set(expectedActionIDs))

        let expectedMappings: [(id: String, virtualKey: CGKeyCode, flags: CGEventFlags)] = [
            ("edit.select_all", CGKeyCode(kVK_ANSI_A), .maskCommand),
            ("edit.find", CGKeyCode(kVK_ANSI_F), .maskCommand),
            ("edit.save", CGKeyCode(kVK_ANSI_S), .maskCommand),
            ("edit.bold", CGKeyCode(kVK_ANSI_B), .maskCommand),
            ("edit.italic", CGKeyCode(kVK_ANSI_I), .maskCommand),
            ("edit.underline", CGKeyCode(kVK_ANSI_U), .maskCommand),
            ("edit.paste_match_style", CGKeyCode(kVK_ANSI_V), [.maskAlternate, .maskShift, .maskCommand]),
            ("edit.emoji", CGKeyCode(kVK_Space), [.maskControl, .maskCommand]),
            ("edit.page_up", CGKeyCode(kVK_PageUp), []),
            ("edit.page_down", CGKeyCode(kVK_PageDown), [])
        ]

        for entry in expectedMappings {
            let mapped = try XCTUnwrap(
                EditCompanionActionRouting.keystroke(for: entry.id),
                "Missing keystroke entry for \(entry.id)"
            )
            XCTAssertEqual(mapped.virtualKey, entry.virtualKey, "Unexpected virtualKey for \(entry.id)")
            XCTAssertEqual(mapped.flags, entry.flags, "Unexpected flags for \(entry.id)")
            XCTAssertFalse(mapped.shortcutDisplay.isEmpty)
        }

        for stroke in table.values {
            XCTAssertNotEqual(stroke.virtualKey, CGKeyCode(kVK_ANSI_Q))
            if stroke.flags.isEmpty {
                XCTAssertTrue(
                    stroke.virtualKey == CGKeyCode(kVK_PageUp) || stroke.virtualKey == CGKeyCode(kVK_PageDown),
                    "Unmodified keystrokes are restricted to Page Up and Page Down"
                )
            }
        }

        XCTAssertNil(EditCompanionActionRouting.keystroke(for: "edit.unknown"))
        XCTAssertNil(EditCompanionActionRouting.keystroke(for: "a"))
    }
    #endif

    func testChocliftBundleIsRefusedAsTarget() {
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("com.choclift.mac"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("com.choclift.ios"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("com.choclift.ios.watchkitapp"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("com.choclift"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("COM.CHOCLIFT.MAC"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle(" com.choclift.mac "))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle("com.apple.loginwindow"))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle(nil))
        XCTAssertFalse(EditCompanionActionRouting.isAllowedTargetBundle(""))
        XCTAssertFalse(
            EditCompanionActionRouting.isAllowedTargetBundle(
                "com.custom.choclift.dev",
                selfBundleIdentifier: "com.custom.choclift.dev"
            )
        )

        XCTAssertTrue(EditCompanionActionRouting.isAllowedTargetBundle("com.apple.TextEdit"))
        XCTAssertTrue(EditCompanionActionRouting.isAllowedTargetBundle("com.apple.Safari"))
        XCTAssertTrue(EditCompanionActionRouting.isAllowedTargetBundle("com.apple.Notes"))

        let chocliftFrontmost = EditTargetCandidate(
            pid: 101,
            bundleIdentifier: "com.choclift.mac",
            localizedName: "Choclift"
        )
        let samePIDCandidate = EditTargetCandidate(
            pid: 777,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit"
        )
        let terminatedCandidate = EditTargetCandidate(
            pid: 888,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit",
            isTerminated: true
        )
        let textEditCandidate = EditTargetCandidate(
            pid: 502,
            bundleIdentifier: "com.apple.TextEdit",
            localizedName: "TextEdit"
        )
        let safariCandidate = EditTargetCandidate(
            pid: 603,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )

        XCTAssertFalse(EditCompanionActionRouting.isEligibleTarget(chocliftFrontmost, selfPID: 777))
        XCTAssertFalse(EditCompanionActionRouting.isEligibleTarget(samePIDCandidate, selfPID: 777))
        XCTAssertFalse(EditCompanionActionRouting.isEligibleTarget(terminatedCandidate, selfPID: 777))
        XCTAssertTrue(EditCompanionActionRouting.isEligibleTarget(textEditCandidate, selfPID: 777))

        XCTAssertNil(
            EditCompanionActionRouting.resolveTarget(
                frontmost: chocliftFrontmost,
                preferred: nil,
                selfPID: 777
            )
        )
        XCTAssertNil(
            EditCompanionActionRouting.resolveTarget(
                frontmost: chocliftFrontmost,
                preferred: chocliftFrontmost,
                selfPID: 777
            )
        )
        XCTAssertEqual(
            EditCompanionActionRouting.resolveTarget(
                frontmost: chocliftFrontmost,
                preferred: textEditCandidate,
                selfPID: 777
            ),
            textEditCandidate
        )
        XCTAssertEqual(
            EditCompanionActionRouting.resolveTarget(
                frontmost: safariCandidate,
                preferred: textEditCandidate,
                selfPID: 777
            ),
            safariCandidate
        )
    }

    #if os(macOS)
    func testExecuteRefusesChocliftBundleAndDeniedAccessibilityWithoutPostingEvents() throws {
        var captured: [(virtualKey: CGKeyCode, flags: CGEventFlags)] = []

        for id in expectedActionIDs {
            let refusedChoclift = EditCompanionActionRouting.execute(
                id: id,
                frontmostBundleIdentifier: "com.choclift.mac",
                ensureAccessibility: { true },
                deniedResult: { (false, "Denied") },
                postKeystroke: { captured.append(($0, $1)) }
            )
            XCTAssertFalse(refusedChoclift.success)
        }
        XCTAssertTrue(captured.isEmpty)

        for id in expectedActionIDs {
            let denied = EditCompanionActionRouting.execute(
                id: id,
                frontmostBundleIdentifier: "com.apple.TextEdit",
                ensureAccessibility: { false },
                deniedResult: { (false, "Accessibility permission is required to send shortcuts") },
                postKeystroke: { captured.append(($0, $1)) }
            )
            XCTAssertFalse(denied.success)
            XCTAssertEqual(denied.message, "Accessibility permission is required to send shortcuts")
        }
        XCTAssertTrue(captured.isEmpty)

        for id in expectedActionIDs {
            let delivered = EditCompanionActionRouting.execute(
                id: id,
                frontmostBundleIdentifier: "com.apple.TextEdit",
                ensureAccessibility: { true },
                deniedResult: { (false, "Denied") },
                postKeystroke: { captured.append(($0, $1)) }
            )
            XCTAssertTrue(delivered.success)
            XCTAssertFalse(delivered.message.isEmpty)
        }
        XCTAssertEqual(captured.count, 10)

        for (index, id) in expectedActionIDs.enumerated() {
            let expected = try XCTUnwrap(EditCompanionActionRouting.keystroke(for: id))
            XCTAssertEqual(captured[index].virtualKey, expected.virtualKey)
            XCTAssertEqual(captured[index].flags, expected.flags)
        }
    }
    #endif
}
