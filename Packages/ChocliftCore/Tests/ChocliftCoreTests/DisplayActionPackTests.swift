import Foundation
import XCTest
@testable import ChocliftCore

#if canImport(AppKit)
import AppKit
#endif

final class DisplayActionPackTests: XCTestCase {
    func testDisplayPackContainsUniqueStartScreenSaverActionWithTitlesAndSymbol() throws {
        let pack = CompanionActionCatalog.displayPack
        let packIDs = pack.map(\.id)

        XCTAssertEqual(pack.count, 1)
        XCTAssertEqual(packIDs, ["display.start_screensaver"])
        XCTAssertEqual(Set(packIDs).count, pack.count)

        let allIDs = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(allIDs.filter { $0 == "display.start_screensaver" }.count, 1)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertNil(SystemQuickAction(rawValue: "display.start_screensaver"))

        let action = try XCTUnwrap(CompanionActionCatalog.action(id: "display.start_screensaver"))
        XCTAssertTrue(CompanionActionCatalog.isKnown("display.start_screensaver"))
        XCTAssertEqual(pack.first, action)
        XCTAssertEqual(action.titleZh, "启动屏幕保护")
        XCTAssertEqual(action.titleEn, "Start Screen Saver")
        XCTAssertFalse(action.titleZh.isEmpty)
        XCTAssertFalse(action.titleEn.isEmpty)
        XCTAssertEqual(action.title(in: .chinese), "启动屏幕保护")
        XCTAssertEqual(action.title(in: .english), "Start Screen Saver")
        XCTAssertFalse(action.title(in: .chinese).isEmpty)
        XCTAssertFalse(action.title(in: .english).isEmpty)
        XCTAssertNotEqual(action.title(in: .chinese), action.title(in: .english))
        XCTAssertEqual(action.sfSymbol, "sparkles.tv")
        XCTAssertFalse(action.sfSymbol.isEmpty)

        #if canImport(AppKit)
        XCTAssertNotNil(
            NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
            "Missing SF Symbol on macOS: \(action.sfSymbol)"
        )
        #endif

        let message = ClientMessage.performCompanionAction(id: action.id)
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
        XCTAssertEqual(decoded, message)
    }

    func testScreenSaverEngineURLUsesPublicCoreServicesPath() {
        let expectedPath = "/System/Library/CoreServices/ScreenSaverEngine.app"
        XCTAssertEqual(DisplayCompanionAction.screenSaverEnginePath, expectedPath)
        XCTAssertEqual(DisplayCompanionAction.screenSaverEngineURL, URL(fileURLWithPath: expectedPath))
        XCTAssertTrue(DisplayCompanionAction.screenSaverEngineURL.isFileURL)
    }

    func testMissingScreenSaverEngineURLReturnsLocalizedFailureWithoutOpening() {
        var openedURLs: [URL] = []

        let failedZh = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .chinese,
            urlExists: { _ in false },
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        XCTAssertFalse(failedZh.success)
        XCTAssertFalse(failedZh.message.isEmpty)
        XCTAssertTrue(openedURLs.isEmpty)

        let failedEn = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .english,
            urlExists: { _ in false },
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        XCTAssertFalse(failedEn.success)
        XCTAssertFalse(failedEn.message.isEmpty)
        XCTAssertNotEqual(failedZh.message, failedEn.message)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testExecuteOpensScreenSaverEngineURLAndReportsOpenOutcome() {
        let expectedURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

        var openedWhenTrue: [URL] = []
        let okZh = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .chinese,
            urlExists: { $0 == expectedURL },
            openURL: { url in
                openedWhenTrue.append(url)
                return true
            }
        )
        XCTAssertTrue(okZh.success)
        XCTAssertFalse(okZh.message.isEmpty)
        XCTAssertEqual(openedWhenTrue, [expectedURL])

        let okEn = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .english,
            urlExists: { $0 == expectedURL },
            openURL: { _ in true }
        )
        XCTAssertTrue(okEn.success)
        XCTAssertFalse(okEn.message.isEmpty)
        XCTAssertNotEqual(okZh.message, okEn.message)

        var openedWhenFalse: [URL] = []
        let failedZh = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .chinese,
            urlExists: { $0 == expectedURL },
            openURL: { url in
                openedWhenFalse.append(url)
                return false
            }
        )
        XCTAssertFalse(failedZh.success)
        XCTAssertFalse(failedZh.message.isEmpty)
        XCTAssertEqual(openedWhenFalse, [expectedURL])

        let failedEn = DisplayCompanionAction.execute(
            id: "display.start_screensaver",
            language: .english,
            urlExists: { $0 == expectedURL },
            openURL: { _ in false }
        )
        XCTAssertFalse(failedEn.success)
        XCTAssertFalse(failedEn.message.isEmpty)
        XCTAssertNotEqual(failedZh.message, failedEn.message)
    }

    func testUnknownIDsFailWithoutCheckingOrOpeningURL() {
        let unknownIDs = [
            "",
            "display.",
            "display.unknown",
            "display.sleep",
            "display.lock",
            " display.start_screensaver ",
            "window.thirds_left"
        ]

        for unknownID in unknownIDs {
            var checkedURLs: [URL] = []
            var openedURLs: [URL] = []

            let failedZh = DisplayCompanionAction.execute(
                id: unknownID,
                language: .chinese,
                urlExists: { url in
                    checkedURLs.append(url)
                    return true
                },
                openURL: { url in
                    openedURLs.append(url)
                    return true
                }
            )
            XCTAssertFalse(failedZh.success)
            XCTAssertFalse(failedZh.message.isEmpty)
            XCTAssertTrue(checkedURLs.isEmpty)
            XCTAssertTrue(openedURLs.isEmpty)

            let failedEn = DisplayCompanionAction.execute(
                id: unknownID,
                language: .english,
                urlExists: { url in
                    checkedURLs.append(url)
                    return true
                },
                openURL: { url in
                    openedURLs.append(url)
                    return true
                }
            )
            XCTAssertFalse(failedEn.success)
            XCTAssertFalse(failedEn.message.isEmpty)
            XCTAssertNotEqual(failedZh.message, failedEn.message)
            XCTAssertTrue(checkedURLs.isEmpty)
            XCTAssertTrue(openedURLs.isEmpty)
        }
    }
}
