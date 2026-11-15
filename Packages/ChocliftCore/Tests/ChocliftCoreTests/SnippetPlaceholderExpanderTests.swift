import Foundation
import XCTest
@testable import ChocliftCore

final class SnippetPlaceholderExpanderTests: XCTestCase {
    private static func makeCalendar(
        timeZoneIdentifier: String = "America/Los_Angeles",
        localeIdentifier: String = "en_US_POSIX"
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        calendar.locale = Locale(identifier: localeIdentifier)
        return calendar
    }

    /// Fixed timestamp: 2026-11-15 21:04 in America/Los_Angeles (Sunday).
    private static func makePinnedDate(in calendar: Calendar) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 11,
            day: 15,
            hour: 21,
            minute: 4,
            second: 0
        )
        return calendar.date(from: components)!
    }

    func testEachPlaceholderTokenExpandsAtPinnedDate() {
        let calendar = Self.makeCalendar()
        let fixedNow = Self.makePinnedDate(in: calendar)

        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{date}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "ignored"
            ),
            "2026-11-15"
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{time}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "ignored"
            ),
            "21:04"
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{iso_date}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "ignored"
            ),
            "2026-11-15"
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{weekday}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "ignored"
            ),
            "Sun"
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{clipboard}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "  https://github.com/uhyrdtrdtfg-creator/choclift \n\t "
            ),
            "https://github.com/uhyrdtrdtfg-creator/choclift"
        )
    }

    func testMixedBodyExpandsAllTokensInPlace() {
        let calendar = Self.makeCalendar()
        let fixedNow = Self.makePinnedDate(in: calendar)
        let body = "Standup {{date}} ({{weekday}}) at {{time}} [ISO {{iso_date}}]: {{clipboard}}"

        let expanded = SnippetPlaceholderExpander.expand(
            body,
            now: fixedNow,
            calendar: calendar,
            clipboard: "  Shipped snippet placeholders  "
        )

        XCTAssertEqual(
            expanded,
            "Standup 2026-11-15 (Sun) at 21:04 [ISO 2026-11-15]: Shipped snippet placeholders"
        )
    }

    func testUnknownAndCaseMismatchedTokensStayAsWritten() {
        let calendar = Self.makeCalendar()
        let fixedNow = Self.makePinnedDate(in: calendar)
        let body = "Keep {{unknown}}, {{DATE}}, {{Time}}, {{ISO_DATE}}, {{Weekday}}, {{CLIPBOARD}}, {{ date }}, {date}, and {{{date}}}"

        let expanded = SnippetPlaceholderExpander.expand(
            body,
            now: fixedNow,
            calendar: calendar,
            clipboard: "clip"
        )

        XCTAssertEqual(
            expanded,
            "Keep {{unknown}}, {{DATE}}, {{Time}}, {{ISO_DATE}}, {{Weekday}}, {{CLIPBOARD}}, {{ date }}, {date}, and {2026-11-15}"
        )
    }

    func testClipboardTrimsAndCapsAt280Characters() {
        let calendar = Self.makeCalendar()
        let fixedNow = Self.makePinnedDate(in: calendar)

        let raw320 = "   \n" + String(repeating: "a", count: 279) + "BCDEFGHIJKLMNOPQRSTUVWXYZ" + "  \t"
        let expanded = SnippetPlaceholderExpander.expand(
            "Clip={{clipboard}}",
            now: fixedNow,
            calendar: calendar,
            clipboard: raw320
        )

        let expectedClip = String(repeating: "a", count: 279) + "B"
        XCTAssertEqual(expectedClip.count, 280)
        XCTAssertEqual(expanded, "Clip=\(expectedClip)")

        let exact280 = String(repeating: "z", count: 280)
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "{{clipboard}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: exact280
            ),
            exact280
        )
    }

    func testNilAndWhitespaceClipboardExpandToEmptyString() {
        let calendar = Self.makeCalendar()
        let fixedNow = Self.makePinnedDate(in: calendar)

        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "Ref ({{date}}): {{clipboard}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: nil
            ),
            "Ref (2026-11-15): "
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.expand(
                "Ref ({{date}}): {{clipboard}}",
                now: fixedNow,
                calendar: calendar,
                clipboard: "   \n\t  "
            ),
            "Ref (2026-11-15): "
        )
    }

    func testClipboardContainingTokenSyntaxIsNotReExpandedAndTimeZoneIsRespected() throws {
        let laCalendar = Self.makeCalendar(timeZoneIdentifier: "America/Los_Angeles", localeIdentifier: "en_US_POSIX")
        let utcCalendar = Self.makeCalendar(timeZoneIdentifier: "UTC", localeIdentifier: "en_US_POSIX")
        let fixedNow = Self.makePinnedDate(in: laCalendar)

        // Single-pass guarantee: tokens inside clipboard text are never recursively expanded
        let recursiveAttempt = SnippetPlaceholderExpander.expand(
            "Copied {{clipboard}} on {{date}}",
            now: fixedNow,
            calendar: laCalendar,
            clipboard: "{{date}} {{time}} {{clipboard}}"
        )
        XCTAssertEqual(recursiveAttempt, "Copied {{date}} {{time}} {{clipboard}} on 2026-11-15")

        // 2026-11-15 21:04 PST (UTC-8) equals 2026-11-16 05:04 UTC (Monday)
        let utcExpanded = SnippetPlaceholderExpander.expand(
            "{{date}} {{time}} {{weekday}}",
            now: fixedNow,
            calendar: utcCalendar,
            clipboard: nil
        )
        XCTAssertEqual(utcExpanded, "2026-11-16 05:04 Mon")

        // Editor token list, preview, and stored snippet persistence
        XCTAssertEqual(
            SnippetPlaceholderExpander.supportedTokens.map(\.rawValue),
            ["{{date}}", "{{time}}", "{{iso_date}}", "{{weekday}}", "{{clipboard}}"]
        )
        XCTAssertEqual(
            SnippetPlaceholderExpander.preview(
                "Daily log {{date}}\n{{clipboard}}",
                now: fixedNow,
                calendar: laCalendar
            ),
            "Daily log 2026-11-15 [clipboard]"
        )

        var profile = ChocliftDefaults.makeDefaultProfile()
        let saved = TextSnippet(title: "Daily", body: "Standup {{date}} — {{clipboard}}")
        XCTAssertTrue(profile.upsertSnippet(saved))
        let roundTripped = try JSONDecoder().decode(
            ChocliftWorkspaceProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(roundTripped.snippet(withID: saved.id)?.body, "Standup {{date}} — {{clipboard}}")
    }
}
