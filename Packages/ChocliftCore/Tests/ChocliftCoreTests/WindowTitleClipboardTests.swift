import Foundation
import XCTest
@testable import ChocliftCore

final class WindowTitleClipboardTests: XCTestCase {
    func testCatalogRegistersWindowCopyTitleOnceWithExpectedTitlesAndSymbol() throws {
        let pack = CompanionActionCatalog.windowTitlePack
        XCTAssertEqual(pack.count, 1)

        let action = try XCTUnwrap(pack.first)
        XCTAssertEqual(action.id, "window.copy_title")
        XCTAssertEqual(action.id, WindowTitleCompanionActionID.copyTitle)
        XCTAssertEqual(action.titleZh, "复制窗口标题")
        XCTAssertEqual(action.titleEn, "Copy Window Title")
        XCTAssertEqual(action.title(in: .chinese), "复制窗口标题")
        XCTAssertEqual(action.title(in: .english), "Copy Window Title")
        XCTAssertEqual(action.sfSymbol, "text.quote")

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertEqual(allIDs.filter { $0 == "window.copy_title" }.count, 1)
        XCTAssertTrue(CompanionActionCatalog.isKnown("window.copy_title"))
        XCTAssertEqual(CompanionActionCatalog.action(id: "window.copy_title"), action)
        XCTAssertTrue(CompanionHotkeyLibrary.isKnownActionID("window.copy_title"))

        let quickActionIDs = Set(SystemQuickAction.allCases.map(\.rawValue))
        XCTAssertFalse(quickActionIDs.contains("window.copy_title"))

        let wireMessage = ClientMessage.performCompanionAction(id: action.id)
        let encoded = try JSONEncoder().encode(wireMessage)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, wireMessage)
    }

    func testClampReturnsNilForNilEmptyAndBlankStrings() {
        XCTAssertNil(WindowTitleClipboardText.clamp(nil))
        XCTAssertNil(WindowTitleClipboardText.clamp(""))
        XCTAssertNil(WindowTitleClipboardText.clamp("   "))
        XCTAssertNil(WindowTitleClipboardText.clamp("\t\n\r  \n"))
        XCTAssertNil(WindowTitleClipboardText.clamp(String(repeating: " ", count: 250)))
    }

    func testClampTrimsOuterWhitespaceAndCapsAtTwoHundredCharacters() {
        XCTAssertEqual(
            WindowTitleClipboardText.clamp("Release Notes — Safari"),
            "Release Notes — Safari"
        )
        XCTAssertEqual(
            WindowTitleClipboardText.clamp("  Sprint Plan — Notes \n"),
            "Sprint Plan — Notes"
        )

        let exact200 = String(repeating: "A", count: 200)
        XCTAssertEqual(WindowTitleClipboardText.clamp(exact200), exact200)

        let over200 = (1...260).map { _ in "B" }.joined()
        let clampedOver200 = WindowTitleClipboardText.clamp(over200)
        XCTAssertEqual(clampedOver200?.count, 200)
        XCTAssertEqual(clampedOver200, String(repeating: "B", count: 200))

        let paddedOver200 = "   \n" + String(repeating: "C", count: 230) + "   "
        let clampedPadded = WindowTitleClipboardText.clamp(paddedOver200)
        XCTAssertEqual(clampedPadded?.count, 200)
        XCTAssertEqual(clampedPadded, String(repeating: "C", count: 200))

        let emojiTitle = String(repeating: "👩‍💻", count: 215)
        let clampedEmoji = WindowTitleClipboardText.clamp(emojiTitle)
        XCTAssertEqual(clampedEmoji?.count, 200)
        XCTAssertEqual(clampedEmoji, String(repeating: "👩‍💻", count: 200))
    }

    func testExecuteCopiesFrontmostNonChocliftWindowTitleAndIncludesCopiedTitleInToast() {
        let selfPID: Int32 = 400
        let safari = WindowTitleAppCandidate(
            pid: 512,
            bundleIdentifier: "com.apple.Safari",
            localizedName: "Safari"
        )

        var pastedStrings: [String] = []
        let outcomeEn = WindowTitleCompanionRouting.execute(
            id: "window.copy_title",
            isAccessibilityTrusted: true,
            frontmost: safari,
            preferred: nil,
            selfPID: selfPID,
            language: .english,
            readFocusedWindowTitle: { target in
                XCTAssertEqual(target, safari)
                return .title("  Apple Developer Documentation — AXUIElement  ")
            },
            writePasteboardString: { text in
                pastedStrings.append(text)
                return true
            }
        )

        XCTAssertTrue(outcomeEn.success)
        XCTAssertEqual(pastedStrings, ["Apple Developer Documentation — AXUIElement"])
        XCTAssertTrue(outcomeEn.message.contains("Apple Developer Documentation — AXUIElement"))

        // When Choclift itself is frontmost, falls back to preferred non-Choclift app and caps at 200 chars
        let chocliftFrontmost = WindowTitleAppCandidate(
            pid: selfPID,
            bundleIdentifier: "com.choclift.mac",
            localizedName: "Choclift"
        )
        let xcodePreferred = WindowTitleAppCandidate(
            pid: 777,
            bundleIdentifier: "com.apple.dt.Xcode",
            localizedName: "Xcode"
        )
        let longTitle = "Xcode — " + String(repeating: "窗", count: 220)
        let expectedClamped = String(longTitle.prefix(200))

        var pastedZh: [String] = []
        let outcomeZh = WindowTitleCompanionRouting.execute(
            id: "window.copy_title",
            isAccessibilityTrusted: true,
            frontmost: chocliftFrontmost,
            preferred: xcodePreferred,
            selfPID: selfPID,
            language: .chinese,
            readFocusedWindowTitle: { target in
                XCTAssertEqual(target, xcodePreferred)
                return .title(longTitle)
            },
            writePasteboardString: { text in
                pastedZh.append(text)
                return true
            }
        )

        XCTAssertTrue(outcomeZh.success)
        XCTAssertEqual(pastedZh, [expectedClamped])
        XCTAssertEqual(pastedZh.first?.count, 200)
        XCTAssertTrue(outcomeZh.message.contains(expectedClamped))
    }

    func testExecuteFailsForEmptyTitleMissingWindowChocliftOnlyOrUntrustedAXWithoutWritingPasteboard() {
        let selfPID: Int32 = 400
        let notes = WindowTitleAppCandidate(
            pid: 601,
            bundleIdentifier: "com.apple.Notes",
            localizedName: "Notes"
        )

        for blankTitle: String? in [nil, "", "   ", "\n\t "] {
            var didWrite = false
            let outcome = WindowTitleCompanionRouting.execute(
                id: "window.copy_title",
                isAccessibilityTrusted: true,
                frontmost: notes,
                preferred: nil,
                selfPID: selfPID,
                language: .english,
                readFocusedWindowTitle: { _ in .title(blankTitle) },
                writePasteboardString: { _ in
                    didWrite = true
                    return true
                }
            )
            XCTAssertFalse(outcome.success)
            XCTAssertFalse(didWrite)
            XCTAssertFalse(outcome.message.isEmpty)
        }

        // No focused window
        var didWriteNoWindow = false
        let noWindowOutcome = WindowTitleCompanionRouting.execute(
            id: "window.copy_title",
            isAccessibilityTrusted: true,
            frontmost: notes,
            preferred: nil,
            selfPID: selfPID,
            language: .english,
            readFocusedWindowTitle: { _ in .noFocusedWindow },
            writePasteboardString: { _ in
                didWriteNoWindow = true
                return true
            }
        )
        XCTAssertFalse(noWindowOutcome.success)
        XCTAssertFalse(didWriteNoWindow)

        // Only Choclift running
        let choclift = WindowTitleAppCandidate(
            pid: selfPID,
            bundleIdentifier: "com.choclift.mac",
            localizedName: "Choclift"
        )
        var didReadChoclift = false
        var didWriteChoclift = false
        let chocliftOnlyOutcome = WindowTitleCompanionRouting.execute(
            id: "window.copy_title",
            isAccessibilityTrusted: true,
            frontmost: choclift,
            preferred: choclift,
            selfPID: selfPID,
            language: .chinese,
            readFocusedWindowTitle: { _ in
                didReadChoclift = true
                return .title("Choclift Settings")
            },
            writePasteboardString: { _ in
                didWriteChoclift = true
                return true
            }
        )
        XCTAssertFalse(chocliftOnlyOutcome.success)
        XCTAssertFalse(didReadChoclift)
        XCTAssertFalse(didWriteChoclift)

        // Untrusted Accessibility prompts once and fails without reading or writing
        var promptCount = 0
        var didWriteUntrusted = false
        let untrustedOutcome = WindowTitleCompanionRouting.execute(
            id: "window.copy_title",
            isAccessibilityTrusted: false,
            frontmost: notes,
            preferred: nil,
            selfPID: selfPID,
            language: .english,
            onRequestAccessibilityPermission: { promptCount += 1 },
            readFocusedWindowTitle: { _ in .title("Secret") },
            writePasteboardString: { _ in
                didWriteUntrusted = true
                return true
            }
        )
        XCTAssertFalse(untrustedOutcome.success)
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(didWriteUntrusted)

        // Unknown action id fails cleanly
        var didWriteUnknown = false
        let unknownOutcome = WindowTitleCompanionRouting.execute(
            id: "window.unknown",
            isAccessibilityTrusted: true,
            frontmost: notes,
            preferred: nil,
            selfPID: selfPID,
            language: .english,
            readFocusedWindowTitle: { _ in .title("Notes") },
            writePasteboardString: { _ in
                didWriteUnknown = true
                return true
            }
        )
        XCTAssertFalse(unknownOutcome.success)
        XCTAssertFalse(didWriteUnknown)
    }
}
