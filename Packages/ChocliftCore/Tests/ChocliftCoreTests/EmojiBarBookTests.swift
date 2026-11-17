import XCTest
@testable import ChocliftCore

final class EmojiBarBookTests: XCTestCase {
    func testEightByEightDimensionsAndFull64Capacity() {
        var book = EmojiBarBook()
        XCTAssertEqual(EmojiBarBook.slideCount, 8)
        XCTAssertEqual(EmojiBarBook.emojisPerSlide, 8)
        XCTAssertEqual(EmojiBarBook.totalCapacity, 64)
        XCTAssertEqual(book.slides.count, 8)
        for slide in 0..<8 {
            XCTAssertEqual(book.slides[slide].count, 8)
            XCTAssertTrue(book.isSlideEmpty(slide))
            for index in 0..<8 {
                XCTAssertEqual(book.slides[slide][index], "")
                XCTAssertNil(book.emoji(slide: slide, index: index))
            }
        }
        XCTAssertEqual(book.totalSlotCount, 64)
        XCTAssertEqual(book.filledCount, 0)
        XCTAssertTrue(book.isEmpty)

        let palette = Array(EmojiCatalog.allUniqueEmojis.prefix(64))
        XCTAssertEqual(palette.count, 64)

        for slide in 0..<8 {
            for index in 0..<8 {
                let candidate = palette[slide * 8 + index]
                XCTAssertTrue(book.set(slide: slide, index: index, emoji: candidate))
            }
        }

        XCTAssertEqual(book.filledCount, 64)
        XCTAssertFalse(book.isEmpty)
        for slide in 0..<8 {
            XCTAssertFalse(book.isSlideEmpty(slide))
            for index in 0..<8 {
                let expected = palette[slide * 8 + index]
                XCTAssertEqual(book.slides[slide][index], expected)
                XCTAssertEqual(book.emoji(slide: slide, index: index), expected)
            }
        }

        // Out-of-bounds indices are rejected without mutating existing slots.
        let snapshot = book
        XCTAssertFalse(book.set(slide: -1, index: 0, emoji: "🍫"))
        XCTAssertFalse(book.set(slide: 8, index: 0, emoji: "🍫"))
        XCTAssertFalse(book.set(slide: 0, index: -1, emoji: "🍫"))
        XCTAssertFalse(book.set(slide: 0, index: 8, emoji: "🍫"))
        XCTAssertEqual(book, snapshot)
    }

    func testSanitizePadsToEightSlidesAndTrimsOversizedOrInvalidEntries() {
        var book = EmojiBarBook(slides: [["  🍫  ", "🔥"]])
        XCTAssertEqual(book.slides.count, 8)
        XCTAssertEqual(book.slides[0], ["🍫", "🔥", "", "", "", "", "", ""])
        for slide in 1..<8 {
            XCTAssertEqual(book.slides[slide], Array(repeating: "", count: 8))
        }

        // Direct mutation to fewer than 8 slides and dirty entries is repaired by sanitize().
        book.slides = [
            ["👍", "😀😂", ""],
            ["🚀"]
        ]
        book.sanitize()
        XCTAssertEqual(book.slides.count, 8)
        XCTAssertEqual(book.slides[0], ["👍", "", "", "", "", "", "", ""])
        XCTAssertEqual(book.slides[1], ["🚀", "", "", "", "", "", "", ""])
        for slide in 2..<8 {
            XCTAssertEqual(book.slides[slide], Array(repeating: "", count: 8))
        }

        // Oversized input (>8 slides or >8 slots per slide) is capped to 8x8.
        let tenSlots = ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😉"]
        let tenSlides = Array(repeating: tenSlots, count: 10)
        let sanitized = EmojiBarBook.sanitize(tenSlides)
        XCTAssertEqual(sanitized.count, 8)
        for slide in sanitized {
            XCTAssertEqual(slide, Array(tenSlots.prefix(8)))
        }
    }

    func testGraphemeValidationAndScalarLimitAfterTrim() {
        var book = EmojiBarBook()

        // Valid single grapheme clusters (1 to 8 scalars after trim).
        XCTAssertTrue(book.set(slide: 0, index: 0, emoji: "🍫"))
        XCTAssertTrue(book.set(slide: 0, index: 1, emoji: "  🔥 \n\t "))
        XCTAssertTrue(book.set(slide: 0, index: 2, emoji: "❤️"))          // 2 scalars (variation selector)
        XCTAssertTrue(book.set(slide: 0, index: 3, emoji: "👍🏽"))          // 2 scalars (skin tone)
        XCTAssertTrue(book.set(slide: 0, index: 4, emoji: "🇺🇸"))          // 2 scalars (regional indicator pair)
        XCTAssertTrue(book.set(slide: 0, index: 5, emoji: "1️⃣"))          // 3 scalars (keycap)
        XCTAssertTrue(book.set(slide: 0, index: 6, emoji: "   👨‍👩‍👧‍👦   ")) // 7 scalars after trim (13 before trim)

        let eightScalarCluster = "👩🏻‍❤️‍👩🏼" // 8 Unicode scalars, 1 extended grapheme cluster
        XCTAssertEqual(eightScalarCluster.count, 1)
        XCTAssertEqual(eightScalarCluster.unicodeScalars.count, 8)
        XCTAssertTrue(book.set(slide: 0, index: 7, emoji: eightScalarCluster))

        XCTAssertEqual(book.slides[0][0], "🍫")
        XCTAssertEqual(book.slides[0][1], "🔥")
        XCTAssertEqual(book.slides[0][6], "👨‍👩‍👧‍👦")
        XCTAssertEqual(book.slides[0][7], eightScalarCluster)

        // Reject empty and whitespace-only strings; existing slot stays intact.
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: ""))
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: "   \t\n  "))
        XCTAssertEqual(book.slides[0][0], "🍫")

        // Reject multi-grapheme strings even when scalar count <= 8.
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: "😀😂"))
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: "🍫🔥"))
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: "ab"))
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: "👍 👎"))
        XCTAssertEqual(book.slides[0][0], "🍫")

        // Reject single grapheme clusters longer than 8 scalars after trim (9 and 10 scalars).
        let nineScalarCluster = "e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}"
        XCTAssertEqual(nineScalarCluster.count, 1)
        XCTAssertEqual(nineScalarCluster.unicodeScalars.count, 9)
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: nineScalarCluster))

        let tenScalarEmoji = "👩🏻‍❤️‍💋‍👩🏼"
        XCTAssertEqual(tenScalarEmoji.count, 1)
        XCTAssertEqual(tenScalarEmoji.unicodeScalars.count, 10)
        XCTAssertFalse(book.set(slide: 0, index: 0, emoji: tenScalarEmoji))
        XCTAssertEqual(book.slides[0][0], "🍫")
    }

    func testClearEmptiesSingleSlideWithoutAffectingOthers() {
        var book = EmojiBarBook()
        XCTAssertTrue(book.set(slide: 0, index: 0, emoji: "🍫"))
        XCTAssertTrue(book.set(slide: 2, index: 1, emoji: "🔥"))
        XCTAssertTrue(book.set(slide: 2, index: 6, emoji: "✨"))
        XCTAssertTrue(book.set(slide: 7, index: 7, emoji: "🚀"))

        book.clear(slide: 2)

        XCTAssertTrue(book.isSlideEmpty(2))
        XCTAssertEqual(book.slides[2], Array(repeating: "", count: 8))
        XCTAssertEqual(book.emoji(slide: 0, index: 0), "🍫")
        XCTAssertEqual(book.emoji(slide: 7, index: 7), "🚀")

        // Out-of-range clear is a safe no-op.
        book.clear(slide: -1)
        book.clear(slide: 8)
        XCTAssertEqual(book.emoji(slide: 0, index: 0), "🍫")
        XCTAssertEqual(book.emoji(slide: 7, index: 7), "🚀")
    }

    func testCodableRoundTripAndMissingBookDecodesToEightEmptySlides() throws {
        var original = EmojiBarBook()
        XCTAssertTrue(original.set(slide: 0, index: 0, emoji: "🍫"))
        XCTAssertTrue(original.set(slide: 3, index: 4, emoji: "👨‍👩‍👧‍👦"))
        XCTAssertTrue(original.set(slide: 7, index: 7, emoji: "✨"))

        let encoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(EmojiBarBook.self, from: encoded)
        XCTAssertEqual(roundTripped, original)

        // Missing slides key in direct object JSON decodes to 8 empty slides.
        let emptyObjectBook = try JSONDecoder().decode(EmojiBarBook.self, from: Data("{}".utf8))
        XCTAssertEqual(emptyObjectBook, .empty)
        XCTAssertEqual(emptyObjectBook.slides.count, 8)
        XCTAssertTrue(emptyObjectBook.isEmpty)

        // Missing book key or null book in a parent Codable container decodes to 8 empty slides.
        struct ParentEnvelope: Codable, Equatable {
            var label: String
            var emojiBarBook: EmojiBarBook
        }

        let missingKeyJSON = Data(#"{"label":"legacy"}"#.utf8)
        let decodedMissing = try JSONDecoder().decode(ParentEnvelope.self, from: missingKeyJSON)
        XCTAssertEqual(decodedMissing.label, "legacy")
        XCTAssertEqual(decodedMissing.emojiBarBook, .empty)
        XCTAssertEqual(decodedMissing.emojiBarBook.slides.count, 8)
        XCTAssertEqual(decodedMissing.emojiBarBook.totalSlotCount, 64)
        XCTAssertTrue(decodedMissing.emojiBarBook.isEmpty)

        let nullValueJSON = Data(#"{"label":"null-book","emojiBarBook":null}"#.utf8)
        let decodedNull = try JSONDecoder().decode(ParentEnvelope.self, from: nullValueJSON)
        XCTAssertEqual(decodedNull.emojiBarBook, .empty)

        // Partial/dirty slide JSON pads to 8x8 and drops invalid entries.
        let partialJSON = Data(#"{"slides":[["  🍫  ","😀😂",null,"🔥"],[]]}"#.utf8)
        let decodedPartial = try JSONDecoder().decode(EmojiBarBook.self, from: partialJSON)
        XCTAssertEqual(decodedPartial.slides.count, 8)
        XCTAssertEqual(decodedPartial.slides[0], ["🍫", "", "", "🔥", "", "", "", ""])
        for slide in 1..<8 {
            XCTAssertEqual(decodedPartial.slides[slide], Array(repeating: "", count: 8))
        }
    }
}
