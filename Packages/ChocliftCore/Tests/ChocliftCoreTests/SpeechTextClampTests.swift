#if canImport(AppKit)
import AppKit
#endif
import Foundation
import XCTest
@testable import ChocliftCore

final class SpeechTextClampTests: XCTestCase {
    func testSpeechPackCatalogActionsTitlesSymbolsAndWireRoundTrip() throws {
        let pack = CompanionActionCatalog.speechPack
        XCTAssertEqual(pack.map(\.id), ["speech.speak_selection", "speech.stop"])

        let speak = try XCTUnwrap(CompanionActionCatalog.action(id: "speech.speak_selection"))
        XCTAssertEqual(speak.titleZh, "朗读选中文字")
        XCTAssertEqual(speak.titleEn, "Speak Selection")
        XCTAssertEqual(speak.title(in: .chinese), "朗读选中文字")
        XCTAssertEqual(speak.title(in: .english), "Speak Selection")
        XCTAssertEqual(speak.sfSymbol, "speaker.wave.2")

        let stop = try XCTUnwrap(CompanionActionCatalog.action(id: "speech.stop"))
        XCTAssertEqual(stop.titleZh, "停止朗读")
        XCTAssertEqual(stop.titleEn, "Stop Speaking")
        XCTAssertEqual(stop.title(in: .chinese), "停止朗读")
        XCTAssertEqual(stop.title(in: .english), "Stop Speaking")
        XCTAssertEqual(stop.sfSymbol, "speaker.slash")

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

            let wire = ClientMessage.performCompanionAction(id: action.id)
            let encoded = try JSONEncoder().encode(wire)
            let decoded = try JSONDecoder().decode(ClientMessage.self, from: encoded)
            XCTAssertEqual(decoded, wire)
        }
    }

    func testEmptyAndWhitespaceSelectionsAreRejected() {
        XCTAssertEqual(SpeechTextClamp.clamp(nil), .failure(.emptySelection))
        XCTAssertNil(SpeechTextClamp.clampedText(nil))

        for blank in ["", " ", "   ", "\n", "\t\r\n  "] {
            XCTAssertEqual(SpeechTextClamp.clamp(blank), .failure(.emptySelection))
            XCTAssertNil(SpeechTextClamp.clampedText(blank))
        }
    }

    func testTextClampEnforcesFiveHundredCharacterCap() {
        XCTAssertEqual(SpeechTextClamp.maxCharacters, 500)

        let shortText = "Speak this focused selection."
        XCTAssertEqual(SpeechTextClamp.clamp(shortText), .success(shortText))
        XCTAssertEqual(SpeechTextClamp.clampedText(shortText), shortText)

        let exact500 = String(repeating: "A", count: 500)
        XCTAssertEqual(SpeechTextClamp.clamp(exact500), .success(exact500))
        XCTAssertEqual(SpeechTextClamp.clampedText(exact500)?.count, 500)

        let over501 = exact500 + "Z"
        let clamped501 = SpeechTextClamp.clampedText(over501)
        XCTAssertEqual(clamped501, exact500)
        XCTAssertEqual(clamped501?.count, 500)

        let paddedLong = "   \n" + String(repeating: "B", count: 520) + "  \n"
        let clampedPadded = SpeechTextClamp.clampedText(paddedLong)
        XCTAssertEqual(clampedPadded, String(repeating: "B", count: 500))
        XCTAssertEqual(clampedPadded?.count, 500)

        let unicodeSource = String(repeating: "朗读👨‍👩‍👧‍👦测试", count: 120) // 600 grapheme clusters
        XCTAssertEqual(unicodeSource.count, 600)
        let clampedUnicode = SpeechTextClamp.clampedText(unicodeSource)
        XCTAssertEqual(clampedUnicode?.count, 500)
        XCTAssertEqual(clampedUnicode, String(unicodeSource.prefix(500)))
    }

    func testExecuteReplacesUtteranceStopsCleanlyAndDoesNotSpeakEmptySelection() {
        var createdCount = 0
        var activeMock: MockSpeechSynthesizer?
        let controller = SpeechUtteranceController {
            createdCount += 1
            let mock = MockSpeechSynthesizer()
            activeMock = mock
            return mock
        }

        // Empty selection fails and never instantiates or triggers speech.
        let emptyOutcome = SpeechCompanionAction.execute(
            id: "speech.speak_selection",
            language: .english,
            readSelectedText: { .success("   \n\t ") },
            speak: { controller.speak($0) },
            stop: { controller.stop() }
        )
        XCTAssertFalse(emptyOutcome.success)
        XCTAssertNil(emptyOutcome.spokenText)
        XCTAssertEqual(createdCount, 0)
        XCTAssertFalse(controller.isSpeaking)

        // First Speak starts utterance capped at 500 characters.
        let firstRaw = String(repeating: "x", count: 650)
        let firstOutcome = SpeechCompanionAction.execute(
            id: "speech.speak_selection",
            language: .english,
            readSelectedText: { .success(firstRaw) },
            speak: { controller.speak($0) },
            stop: { controller.stop() }
        )
        XCTAssertTrue(firstOutcome.success)
        XCTAssertEqual(firstOutcome.spokenText?.count, 500)
        XCTAssertEqual(createdCount, 1)
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertEqual(activeMock?.events, [.start(String(repeating: "x", count: 500))])

        // Second Speak stops previous utterance and replaces it on the held synthesizer.
        let secondOutcome = SpeechCompanionAction.execute(
            id: "speech.speak_selection",
            language: .chinese,
            readSelectedText: { .success("第二段选中文字") },
            speak: { controller.speak($0) },
            stop: { controller.stop() }
        )
        XCTAssertTrue(secondOutcome.success)
        XCTAssertEqual(secondOutcome.spokenText, "第二段选中文字")
        XCTAssertEqual(createdCount, 1)
        XCTAssertTrue(controller.isSpeaking)
        XCTAssertEqual(
            activeMock?.events,
            [
                .start(String(repeating: "x", count: 500)),
                .stop,
                .start("第二段选中文字")
            ]
        )

        // Stop cancels current utterance without reading AX selection.
        var didReadOnStop = false
        let stopOutcome = SpeechCompanionAction.execute(
            id: "speech.stop",
            language: .english,
            readSelectedText: {
                didReadOnStop = true
                return .failure(.emptySelection)
            },
            speak: { controller.speak($0) },
            stop: { controller.stop() }
        )
        XCTAssertTrue(stopOutcome.success)
        XCTAssertFalse(didReadOnStop)
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertEqual(
            activeMock?.events,
            [
                .start(String(repeating: "x", count: 500)),
                .stop,
                .start("第二段选中文字"),
                .stop
            ]
        )

        // Unknown action fails without mutating synthesizer state.
        let unknownOutcome = SpeechCompanionAction.execute(
            id: "speech.unknown",
            language: .english,
            readSelectedText: { .success("Ignored") },
            speak: { controller.speak($0) },
            stop: { controller.stop() }
        )
        XCTAssertFalse(unknownOutcome.success)
        XCTAssertEqual(activeMock?.events.count, 4)
    }
}

private final class MockSpeechSynthesizer: SpeechSynthesizing {
    enum Event: Equatable {
        case start(String)
        case stop
    }

    private(set) var isSpeaking = false
    private(set) var events: [Event] = []

    @discardableResult
    func startSpeaking(_ string: String) -> Bool {
        events.append(.start(string))
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        events.append(.stop)
        isSpeaking = false
    }
}
